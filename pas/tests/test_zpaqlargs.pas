{ What the zpaq-std plugin's codec ppa1 asks of its ZPAQL decoder (pas/plugin/
  ppazpaqlargs: the query's H and M, and the detection), on images of many
  sizes built here and on the files given:

  - each image built (gray, gray + alpha, RGB, RGBA; Adam7 or not; widths
    from 1 to 20,000 pixels; zlib's level, strategy, memLevel 1..9 and
    window 2^9..2^15; its IDAT cut into many chunks; an APNG of frames of
    other sizes; bytes after IEND; an IDAT with a 3 MiB pixels' tail, whose
    image goes as bytes) is taken by the detection, compressed with
    every image static (KeepGivenModel) and as the plugin does (an image
    that does not beat its deflate bytes may go as bytes, the plugin's
    stream no larger), and both streams' needs
    (Ppa1Needs) hold: the records' part is the image's chunks and
    substreams, the image part at least its lines' and deflate's for some
    memLevel and window, M at least the segment, the stream and the largest
    image's plain bytes; $3 and $4 their logs, within the limits;
  - the refusals: palette, 1/2/4/16 bits, a JNG, an MNG with a JNG inside,
    images past PPA1_MAX_IMAGE_BYTES (and one just under it taken), and as
    many tiny frames as PPA1_IMAGE_COST_BYTES lets (one more refused); and the
    query of a stream with a slow-model image, of a JNG's, of a damaged
    or cut one: -1;
  - every file and image taken is also written to <out dir> as NAME.seg
    (what zpaq-std hands the decoder: the original size, u32 LE, and the
    stream), NAME.orig (the file) and NAME.needs ("hWords mBytes ph pm
    images byteStreams"),
    for check_zpaqlargs.py, which runs the decoder itself with exactly
    that H and M (and one word, one byte less: error()).

    test_zpaqlargs <out dir> [<dir or file> ...] }
program test_zpaqlargs;
{$I ../ppa.inc}
uses {$ifdef unix}cthreads,{$endif} SysUtils, Classes, ppacodec, ppapng, ppazlib, ppadeflate, ppacrc,
  ppapixels, ppazpaqlargs;

var cells, failures, written: Integer; outDir: string;

procedure Check(ok: Boolean; const what: string);
begin
  Inc(cells);
  if not ok then begin Inc(failures); Writeln('  FAIL: ', what); end;
end;

function ReadFile(const name: string): TBytes;
var f: TFileStream;
begin
  Result := nil;
  f := TFileStream.Create(name, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, f.Size);
    if f.Size > 0 then f.ReadBuffer(Result[0], f.Size);
  finally f.Free; end;
end;

procedure WriteFile(const name: string; const b: TBytes);
var f: TFileStream;
begin
  f := TFileStream.Create(name, fmCreate);
  try if Length(b) > 0 then f.WriteBuffer(b[0], Length(b)); finally f.Free; end;
end;

procedure Put(var d: TBytes; const b: array of Byte);
var i, n: SizeInt;
begin
  n := Length(d);
  SetLength(d, n + Length(b));
  for i := 0 to High(b) do d[n + i] := b[i];
end;

procedure PutBytes(var d: TBytes; const b: TBytes; first, len: SizeInt);
var n: SizeInt;
begin
  if len <= 0 then Exit;
  n := Length(d);
  SetLength(d, n + len);
  Move(b[first], d[n], len);
end;

procedure PutBe32(var d: TBytes; v: LongWord);
begin
  Put(d, [v shr 24, (v shr 16) and 255, (v shr 8) and 255, v and 255]);
end;

procedure Chunk(var d: TBytes; const typ: string; const data: TBytes);
var c: TBytes; i: Integer;
begin
  PutBe32(d, Length(data));
  c := nil; SetLength(c, 4);
  for i := 0 to 3 do c[i] := Ord(typ[i + 1]);
  PutBytes(c, data, 0, Length(data));
  PutBytes(d, c, 0, Length(c));
  PutBe32(d, Crc32(c, 0, Length(c)));
end;

function Be(v: LongWord): TBytes;
begin
  Result := nil; PutBe32(Result, v);
end;

function Ihdr(w, h: LongWord; depth, ct, lace: Byte): TBytes;
begin
  Result := nil;
  PutBe32(Result, w); PutBe32(Result, h);
  Put(Result, [depth, ct, 0, 0, lace]);
end;

var Seed: LongWord = 12345;
{$push}{$Q-}{$R-}
function Rnd: LongWord;
begin
  Seed := Seed * 1103515245 + 12345;
  Result := Seed shr 16;
end;
{$pop}

{ the filtered lines of a w x h image of nc 8-bit channels (Adam7 or not):
  each line's filter from 0..4, its bytes a smooth gradient with noise }
function Lines(w, h, nc: Int64; lace: Integer): TBytes;
const X0: array[0..6] of Integer = (0, 4, 0, 2, 0, 1, 0); Y0: array[0..6] of Integer = (0, 0, 4, 0, 2, 0, 1);
      DX: array[0..6] of Integer = (8, 8, 4, 4, 2, 2, 1); DY: array[0..6] of Integer = (8, 8, 8, 4, 4, 2, 2);
var p, np: Integer; pw, ph, y, x: Int64; o: SizeInt;
begin
  Result := nil;
  if lace = 1 then np := 7 else np := 1;
  o := 0;
  for p := 0 to np - 1 do begin
    pw := w; ph := h;
    if np = 7 then begin
      pw := 0; ph := 0;
      if w > X0[p] then pw := (w - X0[p] + DX[p] - 1) div DX[p];
      if h > Y0[p] then ph := (h - Y0[p] + DY[p] - 1) div DY[p];
      if (pw = 0) or (ph = 0) then Continue;
    end;
    SetLength(Result, o + ph * (pw * nc + 1));
    for y := 0 to ph - 1 do begin
      Result[o] := Rnd mod 5; Inc(o);
      for x := 0 to pw * nc - 1 do begin
        Result[o] := Byte((x * 3 + y * 5 + (x div nc) + (Rnd and 7)) and 255); Inc(o);
      end;
    end;
  end;
end;

{ plain's zlib stream with these parameters }
function Zlib(const plain: TBytes; level, strategy, memLevel, wbits: Integer): TBytes;
var prm: TZlibParams; z: TZStream; h: Word;
begin
  prm.level := level; prm.strategy := strategy; prm.memLevel := memLevel; prm.wbits := wbits;
  ZlibChoices(plain, prm, nil, z);
  h := ZlibHeader(prm);
  z.raw := False; z.header[0] := h shr 8; z.header[1] := h and 255;
  z.adlerOk := True; z.endPad := 0; z.tail := nil;
  Result := Encode(z);
end;

const SIG_PNG: array[0..7] of Byte = ($89, $50, $4E, $47, $0D, $0A, $1A, $0A);
      SIG_MNG: array[0..7] of Byte = ($8A, $4D, $4E, $47, $0D, $0A, $1A, $0A);
      SIG_JNG: array[0..7] of Byte = ($8B, $4A, $4E, $47, $0D, $0A, $1A, $0A);

{ a PNG: its IDAT cut into pieces of cut bytes (0: one) }
function MakePng(w, h: LongWord; ct, lace: Byte; level, strategy, memLevel, wbits: Integer; cut: SizeInt;
  const after: TBytes): TBytes;
const CHANNELS_OF: array[0..6] of Integer = (1, 0, 3, 0, 2, 0, 4);
var z: TBytes; p, n: SizeInt;
begin
  Result := nil;
  Put(Result, SIG_PNG);
  Chunk(Result, 'IHDR', Ihdr(w, h, 8, ct, lace));
  z := Zlib(Lines(w, h, CHANNELS_OF[ct], lace), level, strategy, memLevel, wbits);
  if cut <= 0 then cut := Length(z);
  p := 0;
  while p < Length(z) do begin
    n := Length(z) - p; if n > cut then n := cut;
    Chunk(Result, 'IDAT', Copy(z, p, n));
    Inc(p, n);
  end;
  Chunk(Result, 'IEND', nil);
  PutBytes(Result, after, 0, Length(after));
end;

{ an APNG: the default image w x h, then frames of other sizes in fdAT }
function MakeApng(w, h: LongWord; ct: Byte): TBytes;
const CHANNELS_OF: array[0..6] of Integer = (1, 0, 3, 0, 2, 0, 4);
var fc, z, fd: TBytes; f, seq: Integer; fw, fh: LongWord;
begin
  Result := nil; seq := 0;
  Put(Result, SIG_PNG);
  Chunk(Result, 'IHDR', Ihdr(w, h, 8, ct, 0));
  fc := nil; PutBe32(fc, 3); PutBe32(fc, 0);
  Chunk(Result, 'acTL', fc);
  for f := 0 to 2 do begin
    if f = 0 then begin fw := w; fh := h; end else begin fw := w div (f + 1) + f; fh := h div (f + 2) + 1; end;
    fc := nil; PutBe32(fc, seq); Inc(seq); PutBe32(fc, fw); PutBe32(fc, fh); PutBe32(fc, 0); PutBe32(fc, 0);
    Put(fc, [0, 1, 0, 100, 0, 0]);
    Chunk(Result, 'fcTL', fc);
    z := Zlib(Lines(fw, fh, CHANNELS_OF[ct], 0), 6, 0, 8, 15);
    if f = 0 then Chunk(Result, 'IDAT', z)
    else begin
      fd := Be(seq); Inc(seq);
      PutBytes(fd, z, 0, Length(z));
      Chunk(Result, 'fdAT', fd);
    end;
  end;
  Chunk(Result, 'IEND', nil);
end;

{ an MNG of two PNG images; jng: a JNG between them }
function MakeMng(jng: Boolean): TBytes;
var m: TBytes; z, j: TBytes;
begin
  Result := nil;
  Put(Result, SIG_MNG);
  m := nil; PutBe32(m, 16); PutBe32(m, 16); PutBe32(m, 1); PutBe32(m, 0); PutBe32(m, 0); PutBe32(m, 0); PutBe32(m, 1);
  Chunk(Result, 'MHDR', m);
  Chunk(Result, 'IHDR', Ihdr(16, 16, 8, 2, 0));
  z := Zlib(Lines(16, 16, 3, 0), 9, 0, 9, 15);
  Chunk(Result, 'IDAT', z);
  Chunk(Result, 'IEND', nil);
  if jng then begin
    j := nil; PutBe32(j, 16); PutBe32(j, 16); Put(j, [10, 8, 8, 0, 0, 0, 0, 0]);
    Chunk(Result, 'JHDR', j);
    j := nil; Put(j, [$FF, $D8, $FF, $D9]);
    Chunk(Result, 'JDAT', j);
    Chunk(Result, 'IEND', nil);
  end;
  Chunk(Result, 'IHDR', Ihdr(8, 4, 8, 6, 1));
  z := Zlib(Lines(8, 4, 4, 1), 1, 0, 1, 9);
  Chunk(Result, 'IDAT', z);
  Chunk(Result, 'IEND', nil);
  Chunk(Result, 'MEND', nil);
end;

{ a PNG of another depth or a palette }
function MakeOther(depth, ct: Byte): TBytes;
var nc, rb, y: Integer; plain: TBytes;
begin
  Result := nil;
  Put(Result, SIG_PNG);
  Chunk(Result, 'IHDR', Ihdr(9, 5, depth, ct, 0));
  if ct = 3 then begin plain := nil; Put(plain, [0, 0, 0, 255, 255, 255]); Chunk(Result, 'PLTE', plain); end;
  case ct of 0, 3: nc := 1; 2: nc := 3; 4: nc := 2; else nc := 4; end;
  rb := (9 * nc * depth + 7) div 8;
  plain := nil; SetLength(plain, 5 * (rb + 1));
  for y := 0 to High(plain) do plain[y] := Byte(y * 7);
  for y := 0 to 4 do plain[y * (rb + 1)] := 0;
  Chunk(Result, 'IDAT', Zlib(plain, 6, 0, 8, 15));
  Chunk(Result, 'IEND', nil);
end;

{ an IHDR claiming w x h RGBA, with a token IDAT: the detection reads the
  header only }
function HeaderOnly(w, h: LongWord): TBytes;
begin
  Result := nil;
  Put(Result, SIG_PNG);
  Chunk(Result, 'IHDR', Ihdr(w, h, 8, 6, 0));
  Chunk(Result, 'IDAT', Zlib(Lines(4, 1, 4, 0), 6, 0, 8, 15));
  Chunk(Result, 'IEND', nil);
end;

{ an APNG of n frames of 1 x 1 gray, all with the same zlib stream (the
  frames made apart, then put together at once: Put grows the array) }
function TinyApng(n: Integer): TBytes;
var fc, z, fd, frames: TBytes; f, seq: Integer; used: SizeInt;
begin
  Result := nil; seq := 0;
  Put(Result, SIG_PNG);
  Chunk(Result, 'IHDR', Ihdr(1, 1, 8, 0, 0));
  fc := nil; PutBe32(fc, n); PutBe32(fc, 0);
  Chunk(Result, 'acTL', fc);
  z := Zlib(Lines(1, 1, 1, 0), 6, 0, 8, 15);
  frames := nil; used := 0;
  for f := 0 to n - 1 do begin
    fd := nil;
    fc := nil; PutBe32(fc, seq); Inc(seq); PutBe32(fc, 1); PutBe32(fc, 1); PutBe32(fc, 0); PutBe32(fc, 0);
    Put(fc, [0, 1, 0, 100, 0, 0]);
    Chunk(fd, 'fcTL', fc);
    if f = 0 then Chunk(fd, 'IDAT', z)
    else begin
      fc := Be(seq); Inc(seq);
      PutBytes(fc, z, 0, Length(z));
      Chunk(fd, 'fdAT', fc);
    end;
    if used + Length(fd) > Length(frames) then SetLength(frames, 2 * (used + Length(fd)));
    Move(fd[0], frames[used], Length(fd));
    Inc(used, Length(fd));
  end;
  PutBytes(Result, frames, 0, used);
  Chunk(Result, 'IEND', nil);
end;

function ChannelsOf(ct: Integer): Integer;
begin
  case ct of 0: Result := 1; 2: Result := 3; 4: Result := 2; else Result := 4; end;
end;

{ a stream's needs (Ppa1Needs), checked, and written with the file for
  check_zpaqlargs.py }
function Needs(const name: string; const d, stream: TBytes; out nd: TPpa1Needs): Boolean;
var seg: TBytes; t: Text; i: Integer;
begin
  Result := Ppa1Needs(stream, nd);
  if not Result then begin Check(False, name + ': no needs for its stream'); Exit; end;
  Check(Ppa1Args(stream) = nd.ph or (nd.pm shl 8), name + ': the query is $3 | $4 << 8');
  Check((nd.ph = Log2Up(nd.hWords)) and (nd.pm = Log2Up(nd.mBytes)) and (nd.ph <= PPA1_MAX_PH) and (nd.pm <= PPA1_MAX_PM),
        name + ': $3, $4 within the limits');
  Check(nd.mBytes >= 4 + Int64(Length(stream)) + nd.largest, name + ': M holds the segment and the plain bytes');
  Check(nd.hWords >= PPA1_ZPAQL_STATIC_WORDS + PPA1_ZPAQL_SUB_WORDS * nd.nSubs + PPA1_ZPAQL_CHUNK_WORDS * nd.nChunks +
        PPA1_ZPAQL_STREAM_WORDS * nd.nStreams + nd.widest, name + ': H holds the records and the lines');
  if outDir <> '' then begin
    seg := nil; SetLength(seg, 4 + Length(stream));
    for i := 0 to 3 do seg[i] := (Length(d) shr (8 * i)) and 255;
    Move(stream[0], seg[4], Length(stream));
    WriteFile(outDir + name + '.seg', seg);
    WriteFile(outDir + name + '.orig', d);
    Assign(t, outDir + name + '.needs'); Rewrite(t);
    Writeln(t, nd.hWords, ' ', nd.mBytes, ' ', nd.ph, ' ', nd.pm, ' ', nd.images, ' ', nd.byteStreams);
    Close(t);
    Inc(written);
  end;
end;

{ the plugin's compress (not verified: zpaq-std decodes), then the needs.
  The plugin sends an image whose coding does not beat its own deflate
  bytes as bytes when the file comes out smaller so, which most of the
  tiny images built here are; keep: the stream with every image static
  as well (ppacodec.KeepGivenModel, the plugin's choice skipped), the one
  returned, so that the built images still give the decoder static
  images of every size, their H checked exactly. The plugin's own stream
  is checked and written too (NAME_own, when it differs), and must be no
  larger. }
function Take(const name: string; const d: TBytes; out stream: TBytes; out nd: TPpa1Needs;
  keep: Boolean = True): Boolean;
var why: string; stats: TCodecStats; own: TBytes; ownNd: TPpa1Needs;
begin
  Result := False;
  stream := nil;
  if not Ppa1Takes(d, why) then begin Check(False, name + ': detection refuses it: ' + why); Exit; end;
  if not Compress(d, own, why, stats, False, 1, MODE_STATIC) then begin Check(False, name + ': compress: ' + why); Exit; end;
  if not keep then begin
    stream := own;
    Result := Needs(name, d, stream, nd);
    Exit;
  end;
  KeepGivenModel := True;
  try
    if not Compress(d, stream, why, stats, False, 1, MODE_STATIC) then begin
      Check(False, name + ': compress, every image static: ' + why); Exit;
    end;
  finally KeepGivenModel := False; end;
  Check(Length(own) <= Length(stream), name + ': the plugin''s stream no larger than every image static');
  if (Length(own) <> Length(stream)) or not CompareMem(@own[0], @stream[0], Length(own)) then
    if not Needs(name + '_own', d, own, ownNd) then Exit;
  Result := Needs(name, d, stream, nd);
end;

{ an image built: taken, one static image, its records and lines exactly }
procedure Built(const name: string; const d: TBytes; w, nc: Int64; chunks: Integer);
var stream: TBytes; nd: TPpa1Needs; rec, img, ml, wb: Int64; any: Boolean;
begin
  if not Take(name, d, stream, nd) then Exit;
  Check((nd.images >= 1) and (nd.byteStreams = 0), name + ': every image static');
  Check(nd.nChunks = chunks, name + Format(': %d chunks (%d)', [chunks, nd.nChunks]));
  rec := PPA1_ZPAQL_STATIC_WORDS + PPA1_ZPAQL_SUB_WORDS * nd.nSubs + PPA1_ZPAQL_CHUNK_WORDS * nd.nChunks +
         PPA1_ZPAQL_STREAM_WORDS * nd.nStreams;
  img := nd.hWords - rec;
  { the lines' or deflate's for some memLevel and window (zlib's parameters
    found may be others than the ones it was written with, if they give
    the same stream) }
  any := img = 5 * (w + 4) * nc;
  for ml := 1 to 9 do
    for wb := 9 to 15 do
      if (img = ZWords(ml, wb)) and (img >= 5 * (w + 4) * nc) then any := True;
  Check(any and (img >= 5 * (w + 4) * nc), name + ': H''s image part: lines or deflate''s');
end;

procedure Refused(const name: string; const d: TBytes);
var why: string; stream: TBytes; stats: TCodecStats;
begin
  Check(not Ppa1Takes(d, why), name + ': refused by the detection');
  { and its stream, compressed as the plugin does, not ppa1's }
  if Compress(d, stream, why, stats, False, 1, MODE_STATIC) then
    Check(Ppa1Args(stream) < 0, name + ': the query refuses its stream');
end;

const
  WIDTHS: array[0..9] of LongWord = (1, 2, 3, 7, 17, 64, 255, 1000, 4097, 20000);
var
  weight: Int64;
  i, ct, lace, ml, wb, lv, sg, nFiles: Integer; w, h: LongWord; d, stream, after: TBytes; nd: TPpa1Needs;
  why, name: string; files: TStringList; sr: TSearchRec; stats: TCodecStats; png: TPng;
begin
  cells := 0; failures := 0; written := 0;
  if ParamCount < 1 then begin Writeln('usage: test_zpaqlargs <out dir> [<dir or file> ...]'); Halt(2); end;
  outDir := IncludeTrailingPathDelimiter(ParamStr(1));
  ForceDirectories(outDir);

  { the widths, each color type, Adam7 or not: a few lines each }
  for i := 0 to High(WIDTHS) do
    for ct := 0 to 6 do begin
      if not (ct in [0, 2, 4, 6]) then Continue;
      for lace := 0 to 1 do begin
        w := WIDTHS[i];
        h := 1 + (3000 div w) mod 23;
        if (w >= 4097) and (lace = 1) then Continue;
        d := MakePng(w, h, ct, lace, 6, 0, 8, 15, 0, nil);
        Built(Format('w%d_h%d_ct%d_i%d', [w, h, ct, lace]), d, w, ChannelsOf(ct), 3);
      end;
    end;
  { zlib's parameters: every memLevel and window, levels and strategies
    (deflate's scratch, 3 * 2^(memLevel+6) + 2^wbits words, against the
    lines of a narrow image) }
  for ml := 1 to 9 do
    for wb := 9 to 15 do begin
      lv := 1 + (ml * 7 + wb) mod 9;
      sg := (ml + wb) mod 4;
      d := MakePng(40, 30, 2, 0, lv, sg, ml, wb, 0, nil);
      Built(Format('z_l%d_s%d_m%d_w%d', [lv, sg, ml, wb]), d, 40, 3, 3);
    end;
  { the IDAT in many chunks; bytes after IEND }
  d := MakePng(300, 40, 6, 0, 9, 0, 9, 15, 97, nil);
  Check(Decompose(d, png).Ok and (Length(png.chunks) > 20), 'the IDAT in many chunks');
  Built('chunks97', d, 300, 4, Length(png.chunks));
  after := nil; for i := 0 to 999 do Put(after, [Byte(i * 31)]);
  d := MakePng(50, 20, 4, 1, 4, 1, 7, 14, 0, after);
  Built('after_iend', d, 50, 2, 3);
  { an APNG; an MNG of two images }
  d := MakeApng(120, 50, 6);
  Built('apng', d, 120, 4, 9);
  d := MakeMng(False);
  Built('mng2', d, 16, 3, 8);
  { an IDAT that inflates to the image and then 3 MiB of zeros (its
    pixels' tail): a structure of that tail would pass the file and 1 MB,
    which both decoders refuse, so the image goes as bytes, and the file
    still comes back; a short tail keeps the image static }
  for i := 0 to 1 do begin
    after := Lines(8, 8, 3, 0);
    if i = 0 then SetLength(after, Length(after) + 3 shl 20) else SetLength(after, Length(after) + 300);
    d := nil;
    Put(d, SIG_PNG);
    Chunk(d, 'IHDR', Ihdr(8, 8, 8, 2, 0));
    Chunk(d, 'IDAT', Zlib(after, 9, 0, 9, 15));
    Chunk(d, 'IEND', nil);
    if i = 0 then name := 'tail_3mb' else name := 'tail_300';
    if Take(name, d, stream, nd) then begin
      Check((nd.images = i) and (nd.byteStreams = 1 - i), name + ': the image static only with a short tail');
      Check(Decompress(stream, Length(d), after, why) and (Length(after) = Length(d)) and
            CompareMem(@after[0], @d[0], Length(d)), name + ': the file back');
    end;
  end;

  { the refusals }
  Refused('palette', MakeOther(8, 3));
  Refused('palette4', MakeOther(4, 3));
  Refused('gray1', MakeOther(1, 0));
  Refused('gray4', MakeOther(4, 0));
  Refused('gray16', MakeOther(16, 0));
  Refused('rgb16', MakeOther(16, 2));
  Refused('rgba16', MakeOther(16, 6));
  Refused('mng_with_jng', MakeMng(True));
  d := nil; Put(d, SIG_JNG); PutBytes(d, MakeMng(True), 8, Length(MakeMng(True)) - 8);
  Check(not Ppa1Takes(d, why), 'a JNG: refused by the detection');
  { the size cap, from the header: 1360 x 1360 RGBA is 7,372,560 bytes
    filtered, past 7 MiB: refused; 1350 x 1350 (7,291,350), taken, and
    its weight those bytes and PPA1_IMAGE_COST_BYTES }
  Check(not Ppa1Takes(HeaderOnly(1360, 1360), why), 'images past PPA1_MAX_IMAGE_BYTES: refused');
  Check(Ppa1Takes(HeaderOnly(1350, 1350), why, weight) and (weight = 1350 * 5401 + PPA1_IMAGE_COST_BYTES),
    'images just under PPA1_MAX_IMAGE_BYTES: taken, with their weight');
  Check(not Ppa1Takes(HeaderOnly(1360, 1360), why, weight) and (weight = 0), 'a file refused weighs 0');
  Check(not Ppa1Takes(HeaderOnly(268435456, 1), why), 'a width of 2^28: refused');
  { each image costs PPA1_IMAGE_COST_BYTES more: 1 x 1 frames (2 bytes
    each, filtered), as many as fit taken, one more refused }
  i := PPA1_MAX_IMAGE_BYTES div (PPA1_IMAGE_COST_BYTES + 2);
  Check(Ppa1Takes(TinyApng(i), why), Format('an APNG of %d tiny frames: taken', [i]));
  Check(not Ppa1Takes(TinyApng(i + 1), why), Format('an APNG of %d tiny frames: refused', [i + 1]));
  { a stream with a slow-model image is not ppa1's; nor is a damaged or a
    cut one }
  if Compress(MakeOther(8, 3), stream, why, stats, False, 1) then
    Check(Ppa1Args(stream) < 0, 'the query of a palette image''s stream: -1');
  d := MakePng(64, 64, 2, 0, 6, 0, 8, 15, 0, nil);
  if Compress(d, stream, why, stats, False, 1, MODE_STATIC) then begin
    Check(Ppa1Args(Copy(stream, 0, Length(stream) - 1)) < 0, 'the query of a cut stream: -1');
    stream[0] := 1;
    Check(Ppa1Args(stream) < 0, 'the query of a stream of another version: -1');
    stream[0] := 2;
    for i := 1 to High(stream) do begin
      stream[i] := stream[i] xor $A5;
      Ppa1Args(stream);     { no exception, whatever it says }
      stream[i] := stream[i] xor $A5;
    end;
    Check(True, 'the query of every damaged byte: no exception');
  end;

  { the files given: those the detection takes }
  nFiles := 0;
  files := TStringList.Create;
  for i := 2 to ParamCount do
    if DirectoryExists(ParamStr(i)) then begin
      if FindFirst(IncludeTrailingPathDelimiter(ParamStr(i)) + '*', faAnyFile, sr) = 0 then begin
        repeat
          if (sr.Attr and faDirectory) = 0 then files.Add(IncludeTrailingPathDelimiter(ParamStr(i)) + sr.Name);
        until FindNext(sr) <> 0;
        FindClose(sr);
      end;
    end else files.Add(ParamStr(i));
  files.Sort;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    name := ExtractFileName(files[i]);
    if not Ppa1Takes(d, why) then Continue;
    Inc(nFiles);
    Take('f_' + name, d, stream, nd, False);
  end;
  files.Free;

  Writeln(cells, ' cells, ', failures, ' failures; ', written, ' segments for check_zpaqlargs.py (', nFiles, ' of the files given)');
  if (failures > 0) or (cells < 400) then Halt(1);
end.
