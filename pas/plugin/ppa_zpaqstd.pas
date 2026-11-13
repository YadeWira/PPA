{ ppa_zpaqstd: PPA as a zpaq-std plugin for -sa / -sat / -sae (codecs for
  specific formats), on zpaq-std's plugin ABI 1 (compressors/plug/zs_codec.h
  in YadeWira/zpaq-std). Shaped as PJA's (pas/plugin/pja_zpaqstd.pas).

    pas/plugin/build.sh <out dir>   -> ppa.so, ppa.dll (64 bits), ppa32.dll

  zpaq-std looks for codecs/ppa.so (codecs\ppa.dll) next to its binary.

  One codec, ppa1 (0): a file of the PNG family (PNG, APNG, MNG) as PPA's
  codec stream, version 2, every image with the static model (ppastatic),
  the image streams PPA does not reproduce kept as their bytes. Its name is
  frozen with that stream and its ZPAQL decoder: a new stream or a new
  decoder is a new name, and ppa1 stays here to read.

  Exported C functions:
  - zpaqstd_codecs_v1(i): ppa1 at 0, NULL past it; zpaqstd_codec_v1: ppa1.
    compress() gets a file's block (the file, and zpaq-std's list of
    fragments after it when the file is alone or the last of its group) and
    gives back ppacodec.Compress's stream with every image forced to the
    static model (its model parameter, not the global TestModel: several
    calls run at once, and the ppa command's streams do not change), but
    for those whose coding does not beat their own deflate bytes when the
    file comes out smaller with them as bytes (many small frames); the
    bytes after the file's last chunk ride in its structure, so the
    fragments come back too. It does not verify the stream itself: zpaq-std
    decodes every block (-sa: with this plugin's decompress, -sat: also
    with the ZPAQL) and compares before writing it. A stream the ZPAQL
    would not decode (an image of another model, a JNG's JPEG) or whose
    decoder would pass PPA1_MAX_PH / PPA1_MAX_PM is refused (ZS_ERR_DATA),
    and zpaq-std compresses that file as -m says.
    decompress() is ppacodec.Decompress, with zpaq-std's exact original
    size as the cap. data(ZS_DATA_ZPAQL_ARGS) is its ZPAQL decoder
    (ppa1zpaql.inc, from pas/plugin/zpaql/ through tools/zpaql/
    gen_ppadec.py), which every block carries so that any zpaq reads it
    without this plugin; its config is comp 0 0 $3 $4 0, H and M from
    query(ZS_QUERY_ZPAQL_ARGS) ($3 | $4 << 8, ppazpaqlargs.Ppa1Args), and
    data(ZS_DATA_ZPAQL) is NULL, so that a zpaq-std that cannot fill $3 and
    $4 uses none. The decoder starts afresh after each segment, so
    query(ZS_QUERY_SEGMENTS) says 1: several files may share a block;
    query(ZS_QUERY_WEIGHT) a file's images' bytes and
    query(ZS_QUERY_GROUP_WEIGHT) 7 MiB, the most a group of them may weigh.
    data(ZS_DATA_INFO) is the card zpaq-std shows in codecinfoex.
  - zpaqstd_detect_v1: 1 if ppa1 takes the file (2 for one of the PNG
    family it does not take, for +rcmd), by its bytes only, and
    only what its ZPAQL decodes (ppazpaqlargs.Ppa1Takes): a PNG, APNG or
    MNG (no JNG, no MNG holding a JNG) whose every image is 8-bit gray, gray
    + alpha, RGB or RGBA (Adam7 or not), its images within
    PPA1_MAX_IMAGE_BYTES and its decoder's memory within the limits. No
    global state: several threads may ask at once.
  - zpaqstd_threads_v1(n): how many threads zpaq-std runs; each compress()
    and decompress() then gives its file n / (the calls running at that
    moment) threads (the zlib parameter search, the bands). The streams are
    the same with any number.

  Levels: one stream, so one level (1); the level zpaq-std passes is not
  looked at.

  CONTRACT with zpaq-std: the library field starts with "ppa1: PPA stream
  v2, static model" for as long as this codec writes and reads that
  stream. }
library ppa_zpaqstd;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}{$ifdef windows}ppaheap,{$endif}
  SysUtils, ppacodec, ppasysinfo, ppastage, ppazpaqlargs;

const
  ZS_CODEC_ABI = 1;
  ZS_ERR_DATA = -1;
  ZS_ERR_MEMORY = -2;
  ZS_QUERY_ZPAQL_ARGS = 2;
  ZS_QUERY_SEGMENTS = 3;
  ZS_QUERY_WEIGHT = 4;
  ZS_QUERY_GROUP_WEIGHT = 5;
  ZS_DATA_ZPAQL = 2;
  ZS_DATA_INFO = 3;
  ZS_DATA_ZPAQL_ARGS = 4;

  { zpaq-std hands the codecs files up to 64 MB (ZS_SA_MAXFILE) and groups
    of 32 MB; above this, refuse }
  MAX_BLOCK = SizeUInt(1) shl 30;
  PPA1_LEVEL = 1;

type
  {$packrecords c}
  TBoundFn      = function(n: SizeUInt; level: LongInt): SizeUInt; cdecl;
  TCompressFn   = function(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
                           level: LongInt): Int64; cdecl;
  TDecompressFn = function(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
                           param: LongInt): Int64; cdecl;
  TQueryFn      = function(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
  TDataFn       = function(what: LongInt; size: PSizeUInt): Pointer; cdecl;

  TZsCodec = record
    abi: LongInt;
    name: PChar;
    library_: PChar;
    min_level, max_level: LongInt;
    bound: TBoundFn;
    compress_: TCompressFn;     { the "_": apart from ppacodec's }
    decompress_: TDecompressFn;
    query: TQueryFn;
    data: TDataFn;
  end;
  PZsCodec = ^TZsCodec;
  {$packrecords default}

var
  { zpaqstd_threads_v1's n, and the calls running }
  ThreadsGiven: LongInt = 1;
  Running: LongInt = 0;

{ a call starts: the threads its file gets; Leave when it ends }
function Enter: Integer;
var k: LongInt;
begin
  k := InterLockedIncrement(Running);
  if k < 1 then k := 1;
  Result := ThreadsGiven div k;
  if Result < 1 then Result := 1;
end;

procedure Leave;
begin
  InterLockedDecrement(Running);
end;

procedure zpaqstd_threads_v1(n: LongInt); cdecl;
begin
  if n < 1 then n := 1;
  if n > 256 then n := 256;
  ThreadsGiven := n;
end;

function Bytes(src: Pointer; n: SizeUInt): TBytes;
begin
  Result := nil;
  SetLength(Result, n);
  if n > 0 then Move(src^, Result[0], n);
end;

{ The stream is the file modelled, usually smaller; but tiny images of
  noise (each band's tables, each image's records) come out up to about
  twice the file (an APNG of 6 x 6 RGBA noise frames: 2.02), and a stream
  past cap makes compress() fail, which sends the file's whole group to -m:
  room for 2.5 times the file. }
function CodecBound(n: SizeUInt; level: LongInt): SizeUInt; cdecl;
begin
  if n > MAX_BLOCK then Exit(0);
  Result := 2 * n + n div 2 + 1048576;
end;

function CompressIn(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt; threads: Integer): Int64;
var stream: TBytes; why: string; stats: TCodecStats;
begin
  if (n > MAX_BLOCK) or (src = nil) then Exit(ZS_ERR_DATA);
  try
    { no verification here: zpaq-std decodes every block and compares }
    if not Compress(Bytes(src, n), stream, why, stats, False, threads, MODE_STATIC) then Exit(ZS_ERR_DATA);
    { only what the ZPAQL decodes, within its memory }
    if Ppa1Args(stream) < 0 then Exit(ZS_ERR_DATA);
    if SizeUInt(Length(stream)) > cap then Exit(ZS_ERR_DATA);
    if Length(stream) > 0 then Move(stream[0], dst^, Length(stream));
    Result := Length(stream);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function CodecCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt; level: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := CompressIn(src, n, dst, cap, t); finally Leave; end;
end;

function DecompressIn(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt; threads: Integer): Int64;
var data: TBytes; why: string; fail: TDecodeFailure;
begin
  if (n > MAX_BLOCK) or (cap > MAX_BLOCK) or (src = nil) then Exit(ZS_ERR_DATA);
  try
    if not DecompressEx(Bytes(src, n), Int64(cap), data, why, fail, threads) then begin
      if fail = dfMemory then Exit(ZS_ERR_MEMORY);
      Exit(ZS_ERR_DATA);
    end;
    { cap is the original's exact size }
    if SizeUInt(Length(data)) <> cap then Exit(ZS_ERR_DATA);
    if Length(data) > 0 then Move(data[0], dst^, Length(data));
    Result := Length(data);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function CodecDecompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt; param: LongInt): Int64; cdecl;
var t: Integer;
begin
  t := Enter;
  try Result := DecompressIn(src, n, dst, cap, t); finally Leave; end;
end;

{ query(ZS_QUERY_ZPAQL_ARGS): for compress()'s output, $3 | $4 << 8 (log2 of
  the decoder's H in words and of its M in bytes, for this very stream), or
  negative. query(ZS_QUERY_SEGMENTS): 1, several files a block.
  query(ZS_QUERY_WEIGHT) of a file (its own bytes, as detect gets them):
  its images' filtered bytes and PPA1_IMAGE_COST_BYTES an image, from the
  headers alone (the same everywhere, whatever the threads), 0 for a file
  ppa1 does not take; query(ZS_QUERY_GROUP_WEIGHT): PPA1_GROUP_WEIGHT,
  past which zpaq-std starts another group, so that zpaq without the
  plugin decodes no block for much longer than one file. }
function CodecQuery(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
var why: string; weight: Int64;
begin
  Result := -1;
  if what = ZS_QUERY_SEGMENTS then Exit(1);
  if what = ZS_QUERY_GROUP_WEIGHT then Exit(PPA1_GROUP_WEIGHT);
  if what = ZS_QUERY_WEIGHT then begin
    Result := 0;
    if (src = nil) or (n < 8) or (n > MAX_BLOCK) then Exit;
    try
      if Ppa1Takes(Bytes(src, n), why, weight) then Result := weight;
    except
      Result := 0;
    end;
    Exit;
  end;
  if (what <> ZS_QUERY_ZPAQL_ARGS) or (n > MAX_BLOCK) or (src = nil) then Exit;
  try
    Result := Ppa1Args(Bytes(src, n));
  except
    Result := -1;
  end;
end;

{ 1: ppa1 takes the file; 2: a file of the PNG family (PNG, APNG, MNG,
  JNG: by its signature) ppa1 does not take, which zpaq-std 2.9.0's +rcmd
  stores with the card's fallback_ma / fallback_m (older zpaq-std and runs
  without +rcmd read 2 as 0); 0: anything else }
function zpaqstd_detect_v1(codecName: PChar; src: Pointer; n: SizeUInt): LongInt; cdecl;
const TAIL: array[0..6] of Byte = ($4E, $47, $0D, $0A, $1A, $0A, 0);
var why: string; p: PByte; k: Integer; isFamily: Boolean;
begin
  Result := 0;
  if (codecName = nil) or (src = nil) or (n < 8) then Exit;
  if StrComp(codecName, 'ppa1') <> 0 then Exit;
  { \x89PNG, \x8AMNG, \x8BJNG, then \r\n\x1A\n }
  p := src;
  isFamily := ((p[0] = $89) and (p[1] = $50)) or ((p[0] = $8A) and (p[1] = $4D)) or ((p[0] = $8B) and (p[1] = $4A));
  for k := 0 to 5 do
    if p[2 + k] <> TAIL[k] then isFamily := False;
  if not isFamily then Exit;
  Result := 2;
  if n > MAX_BLOCK then Exit;
  try
    if Ppa1Takes(Bytes(src, n), why) then Result := 1;
  except
    Result := 2;
  end;
end;

const
  { the card zpaq-std shows in codecinfoex: key=value lines. The commit is
    the one build.sh sets in PPA_COMMIT, empty when built otherwise }
  PPA1_INFO: AnsiString =
    'name=ppa1'#10 +
    'version=' + VERSION + ' (stream v2, static model)'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PPA'#10 +
    'license=MIT'#10 +
    'commit=' + {$I %PPA_COMMIT%} + #10 +
    'format=PPA codec stream v2 of a PNG, APNG or MNG file: every image with the static model, ' +
    'the image streams PPA does not reproduce kept as bytes'#10 +
    'notes=lossless: the original rebuilt byte for byte (its deflate streams written again with their ' +
    'zlib parameters); images of 8-bit gray, gray+alpha, RGB, RGBA, Adam7 or not (no palette, ' +
    '1/2/4/16 bits, JNG); ZPAQL config comp 0 0 $3 $4 0 (H and M from the query)'#10 +
    { +rcmd (zpaq-std 2.9.0): the methods for the PNG, MNG and JNG files ppa1
      does not take, measured on 11/11/2026 on 50 of them (37.2 MB, the
      corpus's palette, 16-bit, JNG and large files): bzip3:9 85.9% in
      6.5 s, flzma2:10 86.4% in 7.4 s (0.8 s to extract), zstd:19 86.6%,
      lzma:9 86.6%, deflate:12 86.8% in 1.6 s; -m4 86.8% in 3.2 s, -m1
      87.4% in 0.3 s, -m5 84.9% but in 147 s (46 times -m4's for 1.9
      points, so last), kanzi:9 85.5% in 39 s left out }
    'fallback_ma=bzip3:9,flzma2:10,zstd:19,lzma:9,deflate:12'#10 +
    'fallback_m=4,1,2,3,5'#10;

{ data(): the ZPAQL decoder only as ZS_DATA_ZPAQL_ARGS (its H and M come
  from the query), and the card; anything else, ZS_DATA_ZPAQL included, nil }
function CodecData(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin
  if what = ZS_DATA_ZPAQL_ARGS then begin
    if size <> nil then size^ := Length(PPA1_ZPAQL) + 1;
    Exit(PAnsiChar(PPA1_ZPAQL));
  end;
  if what = ZS_DATA_INFO then begin
    if size <> nil then size^ := Length(PPA1_INFO);
    Exit(PAnsiChar(PPA1_INFO));
  end;
  if size <> nil then size^ := 0;
  Result := nil;
end;

const
  ZsCodec: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'ppa1';
    library_: 'ppa1: PPA stream v2, static model (YadeWira/PPA)';
    min_level: PPA1_LEVEL;
    max_level: PPA1_LEVEL;
    bound: @CodecBound;
    compress_: @CodecCompress;
    decompress_: @CodecDecompress;
    query: @CodecQuery;
    data: @CodecData
  );

function zpaqstd_codec_v1: PZsCodec; cdecl;
begin
  Result := @ZsCodec;
end;

function zpaqstd_codecs_v1(i: LongInt): PZsCodec; cdecl;
begin
  if i = 0 then Result := @ZsCodec else Result := nil;
end;

{ FPC 3.2.2 exports these names as written on Darwin too, where the C
  symbol of dlsym("zpaqstd_codecs_v1") is "_zpaqstd_codecs_v1" }
{$ifdef darwin}
exports
  zpaqstd_codec_v1 name '_zpaqstd_codec_v1',
  zpaqstd_codecs_v1 name '_zpaqstd_codecs_v1',
  zpaqstd_detect_v1 name '_zpaqstd_detect_v1',
  zpaqstd_threads_v1 name '_zpaqstd_threads_v1';
{$else}
exports
  zpaqstd_codec_v1 name 'zpaqstd_codec_v1',
  zpaqstd_codecs_v1 name 'zpaqstd_codecs_v1',
  zpaqstd_detect_v1 name 'zpaqstd_detect_v1',
  zpaqstd_threads_v1 name 'zpaqstd_threads_v1';
{$endif}

begin
  IsMultiThread := True;
  { the command's test settings, whatever zpaq-std's environment says:
    PPA_TEST_BAND_BYTES would make streams the ZPAQL cuts otherwise }
  ResetTestSettings;
  SetCodePath(cpC);
  StagesOn := False;
end.
