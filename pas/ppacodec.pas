{ Codec layer 6: a file of the PNG family -> the compressed stream, and
  back, verified at compress time.

  The stream: one byte of version, then everything through one arithmetic
  coder:
    - the file's structure (layer 1: its chunks, what each image stream's
      chunks are cut into, the bytes after the end) and, for each image
      stream, how it is kept: as an image (layers 2-5: zlib's parameters,
      what is around its deflate data, and the image's own bytes and
      filters, modelled), or as its bytes. This part is written as bytes
      (numbers as varints) and coded with the byte model;
    - each image stream's content, in order: CodeImage, or the byte model.

  An image stream is kept as an image when its deflate stream decodes, its
  image fits its header (layer 3), zlib's parameters give its very bits
  back (layer 2b) and they are checked to do so; otherwise as its bytes. A
  JNG's JPEG is kept as its bytes for now (PJA's codec will take it).

  Compress verifies: it decompresses its own stream and compares (each
  image's deflate stream as the bytes it inflates to: zlib's parameters
  were checked to give it from them, bit for bit, when planned). A file
  that is not of the family, or that does not come back, is not taken (the
  file layer stores it as it is). Decompress never raises: a damaged or
  hostile stream gives False. The size of every image is capped before it
  is decoded: deflate cannot expand more than 1032 times, so an image
  stream of L bytes holds at most about 1032 L. }
unit ppacodec;

{$I ppa.inc}
{$ifopt R-}{$fatal ppacodec: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppacodec: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  { The first byte of every stream. A new version never stops reading the
    older ones: 1, PPA 0.1.0's; 2, the static model's 320 contexts (the
    channel before's residual among them). }
  STREAM_VERSION = 2;

var
  { the images ppafast takes (8-bit samples, not a palette) with it, about
    ten times as quick to decompress; False: every image with ppamodel's
    slower model, a few percent smaller (ppa --max) }
  FastModel: Boolean = True;
  { For the tests and ppa selftest only: every image a model can take goes
    with MODE_IMAGE, MODE_FAST or MODE_STATIC instead of the one
    ChooseModel picks (-1), so small samples run each model (the stream
    says each image's model: it decodes as any other). From the
    environment: PPA_TEST_MODEL=slow, fast or static. }
  TestModel: Integer = -1;
  { For pas/tests/test_zpaqlargs only: with a model given, every image the
    model takes stays with it, even when the file would be smaller with
    it as bytes (CompressRaw's last choice skipped), so the tests' tiny
    images still give the decoder static images of every size. }
  KeepGivenModel: Boolean = False;

const
  { how each image stream is kept, the byte the stream writes for it }
  MODE_BYTES = 0;
  { the slow model (ppamodel) }
  MODE_IMAGE = 1;
  { a JNG's JPEG through PJA's codec }
  MODE_JPEG = 2;
  { the fast adaptive model (ppafast) }
  MODE_FAST = 3;
  { the static model (ppastatic) }
  MODE_STATIC = 4;
  MODE_NAMES: array[MODE_BYTES..MODE_STATIC] of string = ('bytes', 'slow model', 'JPEG (PJA)', 'fast model',
    'static model');

type
  TCodecStats = record
    images, imageBytes: Integer;      { image streams kept as images, and their bytes }
    rawStreams, rawBytes: Integer;    { image streams kept as bytes }
    { the image streams kept each way, and the bands the images were cut into }
    modes: array[MODE_BYTES..MODE_STATIC] of Integer;
    bands: Integer;
  end;

{ data -> stream; False (with why) if the file is not taken. threads: one
  file's image streams (their zlib parameters) and bands go to as many; 1:
  everything in the calling thread. The stream is the same whatever the
  threads. model: -1, each image the model ChooseModel picks (TestModel
  for the tests); MODE_STATIC, MODE_FAST or MODE_IMAGE, every image that
  model can take with it (the zpaq-std plugin's ppa1: the static model,
  the one its ZPAQL decodes). A parameter, not a global: the plugin's
  calls run on several threads at once, and the ppa command's streams do
  not change. }
function Compress(const data: TBytes; out stream: TBytes; out why: string;
  out stats: TCodecStats; verify: Boolean = True; threads: Integer = 1; model: Integer = -1): Boolean;
{ stream -> data; maxOut caps the file. False (with why) on any damage.
  threads: the bands decoded and the deflate streams rebuilt on as many. }
function Decompress(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string;
  threads: Integer = 1): Boolean;

type
  { why a stream did not decode: damaged (or not a stream); written by a
    newer PPA (its version byte, or a JNG's JPEG stream of a newer PJA:
    damage on that byte looks the same); memory the system did not give }
  TDecodeFailure = (dfNone, dfDamaged, dfFuture, dfMemory);

{ The settings the tests read from the environment (PPA_TEST_BAND_BYTES,
  PPA_TEST_BANDS_REVERSE, PPA_TEST_MODEL, PPA_TEST_PAR_BYTES) back to their
  defaults, and FastModel on: a library loaded into another program
  (libppa) must not take them from that program's environment, where
  PPA_TEST_BAND_BYTES would even make streams others cannot read. }
procedure ResetTestSettings;

{ Decompress, and why it failed }
function DecompressEx(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string;
  out failure: TDecodeFailure; threads: Integer = 1): Boolean;

implementation

uses Math, ppapng, ppadeflate, ppazlib, ppapixels, ppaarith, ppamodel, ppafast, ppastatic, ppathreads, ppastage,
  ppablake3, pjablake3, pjacodec, pjamodel, pjav7;

const
  IMAGE_MODES = [MODE_IMAGE, MODE_FAST, MODE_STATIC];
  { A non-interlaced image goes in horizontal bands of at least this many
    unfiltered bytes, at most MAX_BANDS, each its own arithmetic stream with
    its own model, coded and decoded in parallel. The count depends only on
    the image: the same file on every machine and with any threads.
    Measured on 01/11/2026: a 7.2 MB photo in 2, 4, 8 bands costs 0.3%,
    0.7%, 1.2%; a 1.9 MB RGBA frame in 2 bands 1.6%. }
  BAND_BYTES = 2 * 1024 * 1024;
  MAX_BANDS = 16;
  { the model of an image of 8-bit samples (ChooseModel), by its size on a
    sample of SAMPLE_BYTES: the static one unless STATIC_LOSS percent larger
    than the fast one; the slow one where SLOW_GAIN percent smaller than
    the fast one }
  SLOW_GAIN = 10;
  STATIC_LOSS = 15;
  STATIC_MIN_BYTES = 256 * 1024;
  SAMPLE_BYTES = 256 * 1024;
  INTERLACED_TRY_BYTES = 1024 * 1024;

var
  { For the tests only, from the environment: PPA_TEST_BAND_BYTES makes the
    bands smaller (so that small samples have several; a stream made so
    decodes only with the same value), PPA_TEST_BANDS_REVERSE=1 decodes
    them last first on one thread (a band that read another's bytes would
    fail), as PJA's PJA_BANDS_REVERSE. }
  BandBytes: Int64 = BAND_BYTES;
  BandsReverse: Boolean = False;

const
  { deflate's largest expansion is 1032:1, plus room for small streams }
  MAX_INFLATE_RATIO = 1100;
  { all the images of one file together, filtered: the compressor keeps the
    ones past it as bytes, and the decompressor refuses a stream that asks
    for more (a few hundred bytes could otherwise make it allocate many
    gigabytes, each image within its own stream's bound). The same on every
    platform: it decides the stream. }
  MAX_TOTAL_IMAGE_BYTES = Int64(2) shl 30;
  { the structure (meta) may be this much longer than the file, no more:
    the decompressor (and ppa1's ZPAQL decoder) refuses a longer one. Only
    the images' pixel tails (bytes a zlib stream holds after the image) can
    make it so: the compressor keeps such images as bytes }
  META_SLACK = 1024 * 1024;
  { each band coded at once takes its own model, about 140 MB: a 32-bit
    process (2 GB of addresses, on Windows) codes at most this many }
  MAX_BANDS_AT_ONCE_32 = 4;

{ the threads for bands: the codec's, fewer on 32 bits (memory) }
function BandThreads(threads: Integer): Integer;
begin
  Result := threads;
  if (SizeOf(Pointer) = 4) and (Result > MAX_BANDS_AT_ONCE_32) then Result := MAX_BANDS_AT_ONCE_32;
end;

{ ---------------------------------------------------------------- the structure as bytes }

type
  TWriter = record
    b: TBytes;
    n: SizeInt;
    procedure Put(x: Byte);
    procedure PutVar(x: QWord);
    procedure PutBytes(const a: TBytes; first, len: SizeInt);
    function Bytes: TBytes;
  end;

  TReader = record
    b: TBytes;
    pos: SizeInt;
    ok: Boolean;
    function Get: Byte;
    function GetVar(max: QWord): QWord;
    function GetBytes(len: SizeInt): TBytes;
  end;

procedure TWriter.Put(x: Byte);
begin
  if n = Length(b) then SetLength(b, 2 * n + 256);
  b[n] := x; Inc(n);
end;

procedure TWriter.PutVar(x: QWord);
begin
  while x >= 128 do begin Put(Byte(x and 127) or 128); x := x shr 7; end;
  Put(Byte(x));
end;

procedure TWriter.PutBytes(const a: TBytes; first, len: SizeInt);
var i: SizeInt;
begin
  for i := first to first + len - 1 do Put(a[i]);
end;

function TWriter.Bytes: TBytes;
begin
  Result := Copy(b, 0, n);
end;

function TReader.Get: Byte;
begin
  if (not ok) or (pos >= Length(b)) then begin ok := False; Exit(0); end;
  Result := b[pos]; Inc(pos);
end;

{ a varint up to max; anything above, or cut short, sets ok False }
function TReader.GetVar(max: QWord): QWord;
var x: Byte; shift: Integer;
begin
  Result := 0; shift := 0;
  repeat
    x := Get;
    if not ok then Exit(0);
    if shift > 56 then begin ok := False; Exit(0); end;
    Result := Result or (QWord(x and 127) shl shift);
    Inc(shift, 7);
  until x < 128;
  if Result > max then begin ok := False; Result := 0; end;
end;

function TReader.GetBytes(len: SizeInt): TBytes;
begin
  Result := nil;
  if (not ok) or (len < 0) or (len > Length(b) - pos) then begin ok := False; Exit; end;
  Result := Copy(b, pos, len);
  Inc(pos, len);
end;

procedure PutBe32(var w: TWriter; v: LongWord);
begin
  w.Put(Byte(v shr 24)); w.Put(Byte(v shr 16)); w.Put(Byte(v shr 8)); w.Put(Byte(v));
end;

function GetBe32(var r: TReader): LongWord;
begin
  Result := LongWord(r.Get) shl 24;
  Result := Result or (LongWord(r.Get) shl 16);
  Result := Result or (LongWord(r.Get) shl 8);
  Result := Result or LongWord(r.Get);
end;

{ ---------------------------------------------------------------- bands }

type
  TBandJob = record
    s: SizeInt;              { the image stream }
    firstRow, rows: SizeInt;
  end;

{ the lines per band of an image (all of them: one band) }
function BandRows(const px: TPixels): SizeInt;
var nb, h: SizeInt;
begin
  h := px.passes[0].height;
  Result := h;
  if (Length(px.passes) <> 1) or (h = 0) then Exit;
  nb := FilteredSize(px) div BandBytes;
  if nb > MAX_BANDS then nb := MAX_BANDS;
  if nb < 1 then nb := 1;
  Result := (h + nb - 1) div nb;
end;

procedure AddBands(var jobs: array of TBandJob; var n: SizeInt; s: SizeInt; const px: TPixels);
var r, y: SizeInt;
begin
  r := BandRows(px);
  y := 0;
  repeat
    jobs[n].s := s; jobs[n].firstRow := y; jobs[n].rows := r;
    Inc(n);
    Inc(y, r);
  until y >= px.passes[0].height;
end;

function BandCount(const px: TPixels): SizeInt;
var r: SizeInt;
begin
  r := BandRows(px);
  if r <= 0 then Exit(1);
  Result := (px.passes[0].height + r - 1) div r;
  if Result < 1 then Result := 1;
end;

{ ---------------------------------------------------------------- what each image stream keeps }

type
  TStreamPlan = record
    mode: Integer;
    prm: TZlibParams;
    z: TZStream;          { encoder: the decoded stream }
    px: TPixels;          { encoder: the image }
    jpeg: TBytes;         { encoder: PJA's stream of a JNG's JPEG }
  end;

{ Whether stream s is a JNG's JPEG that PJA's codec takes and makes smaller
  (it verifies its own stream), and its plan. threads: PJA's bands. }
function PlanJpeg(const p: TPng; s: SizeInt; threads: Integer; out plan: TStreamPlan): Boolean;
var r: TCodecResult;
begin
  Result := False;
  plan := Default(TStreamPlan);
  plan.mode := MODE_BYTES;
  if not (p.streams[s].kind in [skJdat, skJdaa]) or (Length(p.streams[s].data) = 0) then Exit;
  r := pjacodec.Compress(p.streams[s].data, plan.jpeg, True, threads, False, True, True);
  if not r.Ok or (Length(plan.jpeg) >= Length(p.streams[s].data)) then begin plan.jpeg := nil; Exit; end;
  plan.mode := MODE_JPEG;
  Result := True;
end;

{ Which model an image of 8-bit samples takes: the three code a sample of
  it (the lines in the middle, SAMPLE_BYTES of them, or all of it when
  small). The static one, the quickest by far to decompress, unless it is
  more than STATIC_LOSS percent larger than the fast one (drawings); then
  the slow one if it is SLOW_GAIN percent smaller than the fast one, else
  the fast one. Photographs take the static model. }
function ChooseModel(var px: TPixels): Integer;
var y0, rows, rb, h: SizeInt; e: TArithEncoder; sStatic, sFast, sSlow: SizeInt;
begin
  Result := MODE_FAST;
  rb := px.passes[0].rowBytes; h := px.passes[0].height;
  if (rb = 0) or (h = 0) then Exit;
  if Length(px.passes) <> 1 then begin
    { interlaced: no band to take, the whole image or nothing }
    if FilteredSize(px) > INTERLACED_TRY_BYTES then Exit(MODE_STATIC);
    y0 := 0; rows := High(SizeInt);
  end else begin
    rows := SAMPLE_BYTES div rb;
    if rows < 8 then rows := 8;
    if rows >= h then begin y0 := 0; rows := h; end else y0 := (h - rows) div 2;
  end;
  e.Init; CodeImageFast(px, y0, rows, @e, nil); sFast := Length(e.Finish);
  { a small image: its tables would weigh, and its time does not matter }
  if FilteredSize(px) >= STATIC_MIN_BYTES then begin
    sStatic := Length(EncodeImageStatic(px, y0, rows));
    if Int64(sStatic) * 100 <= Int64(sFast) * (100 + STATIC_LOSS) then Exit(MODE_STATIC);
  end;
  e.Init; CodeImageBand(px, y0, rows, @e, nil); sSlow := Length(e.Finish);
  if Int64(sSlow) * 100 < Int64(sFast) * (100 - SLOW_GAIN) then Result := MODE_IMAGE;
end;

{ Whether stream s can be kept as an image, and its plan. model: Compress's
  (-1: TestModel's, which is -1 outside the tests) }
function PlanImage(const p: TPng; s: SizeInt; model: Integer; out plan: TStreamPlan): Boolean;
var info: TImageInfo; e: TZStream; back: TBytes; a: TBytes;
begin
  if model < 0 then model := TestModel;
  Result := False;
  plan := Default(TStreamPlan);
  plan.mode := MODE_BYTES;
  if not (p.streams[s].kind in [skIdat, skFdat]) then Exit;
  a := p.streams[s].data;
  if Length(a) = 0 then Exit;
  if not ppadeflate.Decode(a, not IsZlibHeader(a), MAX_IMAGE_BYTES, plan.z).Ok then Exit;
  if not StreamImage(p, s, info) then Exit;
  if not Unfilter(plan.z.plain, info, plan.px) then Exit;
  { the choices zlib makes with them (all of them: the search compared
    every block), written, must be the stream }
  if not FindZlibParams(plan.z, plan.prm, e) then Exit;
  e.raw := plan.z.raw; e.header := plan.z.header; e.adlerOk := plan.z.adlerOk;
  e.endPad := plan.z.endPad; e.tail := plan.z.tail;
  back := Encode(e);
  if (Length(back) <> Length(a)) or not CompareMem(@back[0], @a[0], Length(a)) then Exit;
  { a model given takes every image it can (ChooseModel's trials skipped) }
  if (model = MODE_IMAGE) or ((model in [MODE_FAST, MODE_STATIC]) and FastEligible(info)) then
    plan.mode := model
  else if FastModel and FastEligible(info) then plan.mode := ChooseModel(plan.px)
  else plan.mode := MODE_IMAGE;
  Result := True;
end;

{ ---------------------------------------------------------------- compress }

type
  { what Compress's verification knows of an image stream already: its
    inflated bytes and its deflate stream, which zlib's parameters were
    checked, bit for bit, to give from them (PlanImage) }
  TKnownStream = record
    plain, data: TBytes;
  end;
  TKnownStreams = array of TKnownStream;
  PKnownStreams = ^TKnownStreams;

function CompressRaw(const data: TBytes; out stream: TBytes; out why: string;
  out stats: TCodecStats; threads, model: Integer; out known: TKnownStreams): Boolean;
var
  p: TPng; r: TPngResult; w: TWriter; meta: TBytes;
  plans: array of TStreamPlan;
  i, s: SizeInt;
  sub0: TBytes;
  jobs: array of TBandJob; subs: array of TBytes; nJobs, nJpeg: SizeInt;
  total: Int64; big: SizeInt; grew: Boolean; coded: array of Int64;
  drop: array of Boolean; anyDrop: Boolean; saved: array of TStreamPlan; meta2, sub0b: TBytes;
  jpegLens: array of SizeInt; oldLen, newLen: Int64; k: SizeInt;

  procedure PlanOne(k: SizeInt);
  begin
    if p.streams[k].kind in [skJdat, skJdaa] then PlanJpeg(p, k, 1, plans[k])
    else PlanImage(p, k, model, plans[k]);
  end;

  procedure CodeBand(k: SizeInt);
  var e: TArithEncoder;
  begin
    if plans[jobs[k].s].mode = MODE_STATIC then begin
      subs[k] := EncodeImageStatic(plans[jobs[k].s].px, jobs[k].firstRow, jobs[k].rows);
      Exit;
    end;
    e.Init;
    if plans[jobs[k].s].mode = MODE_FAST then CodeImageFast(plans[jobs[k].s].px, jobs[k].firstRow, jobs[k].rows, @e, nil)
    else CodeImageBand(plans[jobs[k].s].px, jobs[k].firstRow, jobs[k].rows, @e, nil);
    subs[k] := e.Finish;
  end;

  { the structure: the chunks (each one's own data, or its stream's
    number), the bytes after them, each stream's mode and parameters }
  function BuildMeta: TBytes;
  var w: TWriter; i, s: SizeInt; c: TChunk;
  begin
    w := Default(TWriter);
    w.Put(Ord(p.kind));
    w.PutVar(Length(p.chunks));
    for i := 0 to High(p.chunks) do begin
      c := p.chunks[i];
      PutBe32(w, c.typ);
      w.PutVar(c.len);
      w.Put(Ord(c.crcOk) or (Ord(c.stream >= 0) shl 1));
      if not c.crcOk then PutBe32(w, c.crc);
      if c.stream >= 0 then begin
        w.PutVar(c.stream);
        if c.typ = CT_fdAT then PutBe32(w, c.seq);
      end else
        w.PutBytes(c.data, 0, Length(c.data));
    end;
    w.PutVar(Length(p.trailer));
    w.PutBytes(p.trailer, 0, Length(p.trailer));
    w.PutVar(Length(p.streams));
    for s := 0 to High(p.streams) do begin
      w.Put(Ord(p.streams[s].kind));
      w.PutVar(p.streams[s].header + 1);
      w.PutVar(p.streams[s].frame + 1);
      w.Put(plans[s].mode);
      if plans[s].mode in IMAGE_MODES then
        with plans[s] do begin
          w.Put(prm.level); w.Put(prm.strategy); w.Put(prm.memLevel); w.Put(prm.wbits);
          w.Put(Ord(z.raw) or (Ord(z.adlerOk) shl 1));
          w.Put(z.header[0]); w.Put(z.header[1]); w.Put(z.endPad);
          w.PutVar(Length(z.tail)); w.PutBytes(z.tail, 0, Length(z.tail));
          w.PutVar(Length(px.tail)); w.PutBytes(px.tail, 0, Length(px.tail));
        end;
    end;
    Result := w.Bytes;
  end;

  { what the verification knows, and the stats, of the plans }
  procedure Tally;
  var s: SizeInt;
  begin
    stats := Default(TCodecStats);
    known := nil;
    SetLength(known, Length(p.streams));
    for s := 0 to High(p.streams) do begin
      if plans[s].mode in IMAGE_MODES then begin
        known[s].plain := plans[s].z.plain;
        known[s].data := p.streams[s].data;
      end;
      Inc(stats.modes[plans[s].mode]);
      if plans[s].mode in IMAGE_MODES + [MODE_JPEG] then begin Inc(stats.images); Inc(stats.imageBytes, Length(p.streams[s].data)); end
      else begin Inc(stats.rawStreams); Inc(stats.rawBytes, Length(p.streams[s].data)); end;
    end;
  end;

  { substream 0: the structure m, and the streams kept as bytes }
  function Sub0Of(m: TBytes): TBytes;
  var enc: TArithEncoder; bm, rm: TByteModel; s: SizeInt;
  begin
    enc.Init;
    enc.Direct(Length(m), 32);
    bm.Init;
    CodeBytes(bm, m, 0, Length(m), @enc, nil);
    rm.Init;
    for s := 0 to High(p.streams) do
      if plans[s].mode = MODE_BYTES then CodeBytes(rm, p.streams[s].data, 0, Length(p.streams[s].data), @enc, nil);
    Result := enc.Finish;
  end;

  function VarLen(x: QWord): Integer;
  begin
    Result := 1;
    while x >= 128 do begin Inc(Result); x := x shr 7; end;
  end;

  { the stream's length: its header, substream 0 of n0 bytes, the bands of
    the images not in skip (nil: all of them), the JPEGs }
  function StreamLen(n0: SizeInt; const skip: array of Boolean): Int64;
  var i, n: SizeInt;
  begin
    n := 1 + Length(jpegLens);
    Result := n0 + VarLen(n0);
    for i := 0 to nJobs - 1 do
      if (Length(skip) = 0) or not skip[jobs[i].s] then begin
        Inc(n);
        Inc(Result, Int64(Length(subs[i])) + VarLen(Length(subs[i])));
      end;
    for i := 0 to High(jpegLens) do Inc(Result, Int64(jpegLens[i]) + VarLen(jpegLens[i]));
    Inc(Result, 1 + VarLen(n));
  end;

begin
  Result := False;
  stream := nil;
  stats := Default(TCodecStats);
  StageEnter(stParse);
  r := ppapng.Decompose(data, p);
  if not r.Ok then begin why := 'not a PNG, MNG or JNG file'; Exit; end;

  plans := nil;
  SetLength(plans, Length(p.streams));
  { each stream's plan on its own: the zlib parameter search is the slow
    part, and the streams' are independent }
  ParallelFor(Length(p.streams), threads, @PlanOne);
  { past MAX_TOTAL_IMAGE_BYTES of images, the rest as bytes }
  total := 0;
  for s := 0 to High(p.streams) do
    if plans[s].mode in IMAGE_MODES then begin
      Inc(total, FilteredSize(plans[s].px) + Int64(Length(plans[s].px.tail)));
      if total > MAX_TOTAL_IMAGE_BYTES then begin
        plans[s].mode := MODE_BYTES;
        plans[s].px := Default(TPixels);
        plans[s].z := Default(TZStream);
      end;
    end;
  { a model given (the plugin's): an image whose coding with it comes out
    much larger than its own deflate stream (a quarter and 4 KiB more), or
    of 64 KiB or more and not smaller, goes again as bytes: noise takes the
    static model badly, up to four times its stream, past what the plugin
    may return, and a group of zpaq-std's files must not grow for one of
    them (zpaq-std's owner saw 9 files go from 1,345,329 to 1,534,422
    bytes). A small image a little larger keeps the model (its tables cost
    more than its pixels).
    The ppa command's streams (model -1) do not take this path. }
  repeat
  grew := False;
  { a structure longer than the decoders take: the images with the
    longest pixel tails as bytes, until it fits (a file the decoder could
    not give back otherwise; no other file's stream changes) }
  meta := BuildMeta;
  while Int64(Length(meta)) > Int64(Length(data)) + META_SLACK do begin
    big := -1;
    for s := 0 to High(p.streams) do
      if (plans[s].mode in IMAGE_MODES) and (Length(plans[s].px.tail) > 0) and
         ((big < 0) or (Length(plans[s].px.tail) > Length(plans[big].px.tail))) then big := s;
    if big < 0 then begin why := 'structure larger than the file may be'; Exit; end;
    plans[big].mode := MODE_BYTES;
    plans[big].px := Default(TPixels);
    plans[big].z := Default(TZStream);
    meta := BuildMeta;
  end;
  Tally;

  { substream 0: the structure, and the streams kept as bytes }
  sub0 := Sub0Of(meta);
  { then each band of each image, in order, in parallel }
  nJobs := 0;
  for s := 0 to High(p.streams) do
    if plans[s].mode in IMAGE_MODES then Inc(nJobs, BandCount(plans[s].px));
  jobs := nil; SetLength(jobs, nJobs);
  nJobs := 0;
  for s := 0 to High(p.streams) do
    if plans[s].mode in IMAGE_MODES then AddBands(jobs, nJobs, s, plans[s].px);
  subs := nil; SetLength(subs, nJobs);
  stats.bands := nJobs;
  StageEnter(stEncode);
  ParallelFor(nJobs, BandThreads(threads), @CodeBand);
  if model >= 0 then begin
    coded := nil; SetLength(coded, Length(p.streams));
    for i := 0 to nJobs - 1 do Inc(coded[jobs[i].s], Length(subs[i]));
    for s := 0 to High(p.streams) do
      if (plans[s].mode in IMAGE_MODES) and ((coded[s] > Int64(Length(p.streams[s].data)) * 5 div 4 + 4096) or
          ((Length(p.streams[s].data) >= 65536) and (coded[s] >= Length(p.streams[s].data)))) then begin
        plans[s].mode := MODE_BYTES;
        plans[s].px := Default(TPixels);
        plans[s].z := Default(TZStream);
        grew := True;
      end;
  end;
  until not grew;

  { then, with a model given (unless KeepGivenModel): the file as a whole.
    An image of that model whose coding does not beat its own deflate
    bytes (a small frame's tables, noise) goes as bytes if the file
    comes out smaller
    so: an APNG or MNG of many small frames paid each frame's tables, up
    to twice the file, under the rule above (those 9 files: 1,534,422
    bytes before this, 1,294,937 with it). Only substream 0 is coded
    again (whatever the threads, the same stream): the other images'
    bands do not change. The ppa command's streams (model -1) do not take
    this path. }
  jpegLens := nil;
  for s := 0 to High(p.streams) do
    if plans[s].mode = MODE_JPEG then begin
      SetLength(jpegLens, Length(jpegLens) + 1);
      jpegLens[High(jpegLens)] := Length(plans[s].jpeg);
    end;
  if (model >= 0) and not KeepGivenModel then begin
    drop := nil; SetLength(drop, Length(p.streams));
    anyDrop := False;
    for s := 0 to High(p.streams) do
      if (plans[s].mode = model) and (coded[s] >= Length(p.streams[s].data)) then begin
        drop[s] := True; anyDrop := True;
      end;
    if anyDrop then begin
      saved := Copy(plans, 0, Length(plans));
      for s := 0 to High(p.streams) do
        if drop[s] then plans[s].mode := MODE_BYTES;
      meta2 := BuildMeta;
      sub0b := Sub0Of(meta2);
      oldLen := StreamLen(Length(sub0), []);
      newLen := StreamLen(Length(sub0b), drop);
      if newLen < oldLen then begin
        for s := 0 to High(p.streams) do
          if drop[s] then begin
            plans[s].px := Default(TPixels);
            plans[s].z := Default(TZStream);
          end;
        meta := meta2;
        sub0 := sub0b;
        k := 0;
        for i := 0 to nJobs - 1 do
          if not drop[jobs[i].s] then begin
            jobs[k] := jobs[i]; subs[k] := subs[i]; Inc(k);
          end;
        nJobs := k;
        SetLength(jobs, nJobs); SetLength(subs, nJobs);
        Tally;
        stats.bands := nJobs;
      end else
        plans := saved;
      saved := nil;
    end;
  end;

  { then each JNG JPEG's PJA stream, in order }
  nJpeg := 0;
  for s := 0 to High(p.streams) do
    if plans[s].mode = MODE_JPEG then Inc(nJpeg);
  SetLength(subs, nJobs + nJpeg);
  i := nJobs;
  for s := 0 to High(p.streams) do
    if plans[s].mode = MODE_JPEG then begin subs[i] := plans[s].jpeg; Inc(i); end;

  { the stream: version, the substreams' count and lengths, the substreams }
  w := Default(TWriter);
  w.Put(STREAM_VERSION);
  w.PutVar(1 + Length(subs));
  w.PutVar(Length(sub0));
  for i := 0 to High(subs) do w.PutVar(Length(subs[i]));
  w.PutBytes(sub0, 0, Length(sub0));
  for i := 0 to High(subs) do w.PutBytes(subs[i], 0, Length(subs[i]));
  stream := w.Bytes;
  Result := True;
end;

function DecompressRaw(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string;
  threads: Integer; stages: Boolean; known: PKnownStreams; out future: Boolean): Boolean; forward;
function DecompressSafe(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string;
  threads: Integer; stages: Boolean; known: PKnownStreams; out failure: TDecodeFailure): Boolean; forward;

function Compress(const data: TBytes; out stream: TBytes; out why: string;
  out stats: TCodecStats; verify: Boolean; threads, model: Integer): Boolean;
var back: TBytes; why2: string; was: TStage; known: TKnownStreams; fail: TDecodeFailure;
begin
  why := '';
  was := StageEnter(stNone);
  StageEnter(was);
  { the slow model's tables kept from band to band (ppamodel's pool) }
  ModelPoolHold;
  try
  Result := CompressRaw(data, stream, why, stats, threads, model, known);
  if not Result or not verify then begin StageEnter(was); Exit; end;
  { The stream decompressed and compared with the file, whole. Each image's
    deflate stream is not written again: what the decoder refilters is
    compared with the inflated bytes instead, whose deflate stream zlib's
    parameters were checked, bit for bit, to give (PlanImage), and the same
    code would give it here; a quarter of the compression's time. }
  StageEnter(stVerify);
  if not DecompressSafe(stream, Length(data), back, why2, threads, False, @known, fail) or (Length(back) <> Length(data)) or
     ((Length(data) > 0) and not CompareMem(@back[0], @data[0], Length(data))) then begin
    why := 'the codec did not give the same file back (a PPA bug: please report it)';
    if why2 <> '' then why := why + ': ' + why2;
    stream := nil;
    Result := False;
  end;
  StageEnter(was);
  finally
    ModelPoolRelease;
  end;
end;

{ ---------------------------------------------------------------- decompress }

{ CodeBytes decoding n bytes, in pieces: False as soon as the decoder has
  read past the end of its data. The encoder's stream never makes it:
  the decoder takes a byte exactly where the encoder wrote one, and
  Finish wrote the last four, so it never goes past their end. A damaged
  stream reads zeros there (ppaarith) and, without this, decoded all of
  the structure's length before anything checked it: a megabyte through
  the byte model from a stream of a few bytes, half a second, for every
  file of a filter's stream (found by fuzzing). }
function DecodeBytes(var m: TByteModel; var data: TBytes; n: SizeInt; var dec: TArithDecoder): Boolean;
const PIECE = 4096;
var q, k: SizeInt;
begin
  q := 0;
  while q < n do begin
    k := n - q;
    if k > PIECE then k := PIECE;
    CodeBytes(m, data, q, k, nil, @dec);
    Inc(q, k);
    if dec.p > Length(dec.d) then Exit(False);
  end;
  Result := True;
end;

function DecompressRaw(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string;
  threads: Integer; stages: Boolean; known: PKnownStreams; out future: Boolean): Boolean;
var
  dec: TArithDecoder; bm, rm: TByteModel;
  metaLen: Cardinal; meta: TBytes; r: TReader;
  p: TPng; nChunks, nStreams, total, len: Int64; i, s: SizeInt;
  flags: Byte; c: TChunk;
  modes: array of Integer; prms: array of TZlibParams; zs: array of TZStream; pxTails: array of TBytes;
  streamLen: array of Int64;
  info: TImageInfo; pxs: array of TPixels; plains: array of TBytes;
  maxSmall: Int64;
  nSubs: Int64; subLen, subPos: array of Int64;
  jobs: array of TBandJob; nJobs, nJpeg: SizeInt; jpegSub: array of SizeInt;
  bandBad: array of Boolean;
  nImages, zThreads: Integer;
  imgSize: SizeInt; allImages: Int64;

  function Bad(const s: string): Boolean;
  begin
    why := s; Result := False;
  end;

  procedure DecodeBand(k: SizeInt);
  var d: TArithDecoder;
  begin
    if modes[jobs[k].s] = MODE_STATIC then begin
      if not DecodeImageStatic(pxs[jobs[k].s], jobs[k].firstRow, jobs[k].rows, stream, subPos[k + 1], subLen[k + 1],
                               stream[0]) then
        bandBad[k] := True;
      Exit;
    end;
    d.Init(Copy(stream, subPos[k + 1], subLen[k + 1]), 0);
    if modes[jobs[k].s] = MODE_FAST then CodeImageFast(pxs[jobs[k].s], jobs[k].firstRow, jobs[k].rows, nil, @d)
    else CodeImageBand(pxs[jobs[k].s], jobs[k].firstRow, jobs[k].rows, nil, @d);
  end;

  procedure Rebuild(k: SizeInt);
  var e: TZStream; r: TCodecResult; j: TBytes;
  begin
    if modes[k] = MODE_JPEG then begin
      { PJA's stream back to the JPEG, which must be exactly as long as
        the chunks say }
      r := pjacodec.Decompress(Copy(stream, subPos[jpegSub[k]], subLen[jpegSub[k]]), j,
        streamLen[k] + 1024, 1, streamLen[k]);
      if r.Ok then p.streams[k].data := j else p.streams[k].data := nil;
      if r.err = ceFutureVersion then future := True;
      Exit;
    end;
    if not (modes[k] in IMAGE_MODES) then Exit;
    if known <> nil then begin
      { Compress's verification: the refiltered bytes must be the inflated
        ones, whose stream is known }
      if (k <= High(known^)) and (Length(plains[k]) = Length(known^[k].plain)) and (Length(plains[k]) > 0) and
         CompareMem(@plains[k][0], @known^[k].plain[0], Length(plains[k])) then
        p.streams[k].data := known^[k].data
      else p.streams[k].data := nil;
      plains[k] := nil;
      Exit;
    end;
    ZlibChoices(plains[k], prms[k], nil, e, zThreads);
    e.raw := zs[k].raw; e.adlerOk := zs[k].adlerOk; e.header := zs[k].header;
    e.endPad := zs[k].endPad; e.tail := zs[k].tail;
    p.streams[k].data := Encode(e);
    plains[k] := nil;
  end;

begin
  Result := False;
  data := nil; why := ''; future := False;
  if Length(stream) < 1 then Exit(Bad('empty stream'));
  { a version this release does not know: a newer PPA's (a new version
    never stops reading the older ones; 0 is none) }
  if stream[0] > STREAM_VERSION then begin
    future := True;
    Exit(Bad(Format('stream version %d: made by a newer PPA', [stream[0]])));
  end;
  if stream[0] < 1 then Exit(Bad(Format('stream version %d not known', [stream[0]])));
  { the substreams' count and lengths: they must fit in the stream }
  r := Default(TReader);
  r.b := stream; r.pos := 1; r.ok := True;
  nSubs := r.GetVar(Length(stream));
  if not r.ok or (nSubs < 1) then Exit(Bad('bad substream table'));
  subLen := nil; SetLength(subLen, nSubs);
  total := 0;
  for i := 0 to nSubs - 1 do begin
    subLen[i] := r.GetVar(Length(stream));
    Inc(total, subLen[i]);
    if not r.ok or (total > Length(stream)) then Exit(Bad('bad substream table'));
  end;
  if r.pos + total <> Length(stream) then Exit(Bad('bad substream table'));
  subPos := nil; SetLength(subPos, nSubs);
  subPos[0] := r.pos;
  for i := 1 to nSubs - 1 do subPos[i] := subPos[i - 1] + subLen[i - 1];
  if stages then StageEnter(stDecode);
  dec.Init(Copy(stream, subPos[0], subLen[0]), 0);
  metaLen := dec.Direct(32);
  { the structure holds the file's chunks other than the image data, and
    little more }
  if Int64(metaLen) > maxOut + META_SLACK then Exit(Bad('structure larger than the file may be'));
  meta := nil; SetLength(meta, metaLen);
  bm.Init;
  if not DecodeBytes(bm, meta, metaLen, dec) then Exit(Bad('bad structure'));

  r := Default(TReader);
  r.b := meta; r.pos := 0; r.ok := True;
  p := Default(TPng);
  i := r.Get;
  if i > Ord(High(TPngKind)) then Exit(Bad('bad file kind'));
  p.kind := TPngKind(i);
  maxSmall := maxOut;
  { a chunk is at least 12 bytes of the file: no more than the declared
    size holds (a few bytes of stream must not allocate for millions) }
  nChunks := r.GetVar(Min(MAX_CHUNKS, maxOut div 12 + 1));
  if not r.ok then Exit(Bad('bad structure'));
  SetLength(p.chunks, nChunks);
  total := 8;
  for i := 0 to nChunks - 1 do begin
    c := Default(TChunk);
    c.typ := GetBe32(r);
    c.len := r.GetVar(MAX_CHUNK_LEN);
    flags := r.Get;
    if not r.ok or (flags > 3) then Exit(Bad('bad structure'));
    Inc(total, 12 + c.len);
    if total > maxOut then Exit(Bad('the file would be larger than declared'));
    c.crcOk := (flags and 1) <> 0;
    if not c.crcOk then c.crc := GetBe32(r);
    if (flags and 2) <> 0 then begin
      c.stream := r.GetVar(MAX_CHUNKS);
      if c.typ = CT_fdAT then begin
        if c.len < 4 then Exit(Bad('bad structure'));
        c.seq := GetBe32(r);
      end;
    end else begin
      c.stream := -1;
      c.data := r.GetBytes(c.len);
    end;
    if not r.ok then Exit(Bad('bad structure'));
    p.chunks[i] := c;
  end;
  len := r.GetVar(maxSmall);
  p.trailer := r.GetBytes(len);
  Inc(total, len);
  if not r.ok or (total > maxOut) then Exit(Bad('bad structure'));

  { each stream comes from one chunk or more }
  nStreams := r.GetVar(nChunks);
  if not r.ok then Exit(Bad('bad structure'));
  SetLength(p.streams, nStreams);
  modes := nil; SetLength(modes, nStreams);
  prms := nil; SetLength(prms, nStreams);
  zs := nil; SetLength(zs, nStreams);
  pxTails := nil; SetLength(pxTails, nStreams);
  streamLen := nil; SetLength(streamLen, nStreams);
  for i := 0 to nChunks - 1 do
    with p.chunks[i] do
      if stream >= 0 then begin
        if stream >= nStreams then Exit(Bad('bad structure'));
        if typ = CT_fdAT then Inc(streamLen[stream], len - 4) else Inc(streamLen[stream], len);
      end;
  for s := 0 to nStreams - 1 do begin
    i := r.Get;
    if i > Ord(High(TStreamKind)) then Exit(Bad('bad structure'));
    p.streams[s].kind := TStreamKind(i);
    p.streams[s].header := Int64(r.GetVar(nChunks)) - 1;
    p.streams[s].frame := Int64(r.GetVar(nChunks)) - 1;
    modes[s] := r.Get;
    if not r.ok or (modes[s] > MODE_STATIC) then Exit(Bad('bad structure'));
    if (modes[s] = MODE_JPEG) and not (p.streams[s].kind in [skJdat, skJdaa]) then Exit(Bad('bad structure'));
    if modes[s] in IMAGE_MODES then begin
      prms[s].level := r.Get; prms[s].strategy := r.Get; prms[s].memLevel := r.Get; prms[s].wbits := r.Get;
      if (prms[s].level < 1) or (prms[s].level > 9) or (prms[s].strategy > Z_FIXED) or
         (prms[s].memLevel < 1) or (prms[s].memLevel > 9) or (prms[s].wbits < 8) or (prms[s].wbits > 15) then
        Exit(Bad('bad zlib parameters'));
      flags := r.Get;
      if flags > 3 then Exit(Bad('bad structure'));
      zs[s].raw := (flags and 1) <> 0;
      zs[s].adlerOk := (flags and 2) <> 0;
      zs[s].header[0] := r.Get; zs[s].header[1] := r.Get; zs[s].endPad := r.Get;
      len := r.GetVar(streamLen[s]);
      zs[s].tail := r.GetBytes(len);
      len := r.GetVar(MAX_IMAGE_BYTES);
      pxTails[s] := r.GetBytes(len);
      if not r.ok then Exit(Bad('bad structure'));
    end;
  end;
  if r.pos <> Length(meta) then Exit(Bad('bad structure'));

  { the streams kept as bytes, from substream 0; each image's layout }
  rm.Init;
  plains := nil; SetLength(plains, nStreams);
  pxs := nil; SetLength(pxs, nStreams);
  nJobs := 0; allImages := 0;
  for s := 0 to nStreams - 1 do begin
    if modes[s] = MODE_BYTES then begin
      SetLength(p.streams[s].data, streamLen[s]);
      if not DecodeBytes(rm, p.streams[s].data, streamLen[s], dec) then Exit(Bad('bad structure'));
    end else if modes[s] in IMAGE_MODES then begin
      { the image's size checked before anything is allocated for it, and
        all the images' together: deflate expands 1032 times at most, so
        their streams, inside the declared size, bound them }
      if not StreamImage(p, s, info) or not LayoutSize(info, imgSize) then Exit(Bad('bad image header'));
      if (modes[s] in [MODE_FAST, MODE_STATIC]) and not FastEligible(info) then Exit(Bad('bad structure'));
      if imgSize + Int64(Length(pxTails[s])) > MAX_INFLATE_RATIO * streamLen[s] + 1024 then
        Exit(Bad('image larger than its stream can hold'));
      Inc(allImages, imgSize + Int64(Length(pxTails[s])));
      if (allImages > MAX_TOTAL_IMAGE_BYTES) or (allImages > MAX_INFLATE_RATIO * maxOut + 1024) then
        Exit(Bad('images larger than the file can hold'));
      if not InitLayout(info, pxs[s]) then Exit(Bad('bad image header'));
      Inc(nJobs, BandCount(pxs[s]));
    end;
  end;
  nJpeg := 0;
  for s := 0 to nStreams - 1 do
    if modes[s] = MODE_JPEG then Inc(nJpeg);
  if nJobs + nJpeg <> nSubs - 1 then Exit(Bad('substreams for another number of bands'));
  { each JNG JPEG's substream }
  jpegSub := nil; SetLength(jpegSub, nStreams);
  i := 1 + nJobs;
  for s := 0 to nStreams - 1 do
    if modes[s] = MODE_JPEG then begin jpegSub[s] := i; Inc(i); end;
  { each band from its own substream, in parallel }
  jobs := nil; SetLength(jobs, nJobs);
  bandBad := nil; SetLength(bandBad, nJobs);
  nJobs := 0;
  for s := 0 to nStreams - 1 do
    if modes[s] in IMAGE_MODES then AddBands(jobs, nJobs, s, pxs[s]);
  if BandsReverse then
    for i := nJobs - 1 downto 0 do DecodeBand(i)
  else
    ParallelFor(nJobs, BandThreads(threads), @DecodeBand);
  for i := 0 to nJobs - 1 do
    if bandBad[i] then Exit(Bad('image band damaged'));
  if stages then StageEnter(stRebuild);
  for s := 0 to nStreams - 1 do
    if modes[s] in IMAGE_MODES then begin
      pxs[s].tail := pxTails[s];
      plains[s] := Refilter(pxs[s]);
      pxs[s] := Default(TPixels);
    end;
  { then each image's deflate stream, zlib's choices written: independent,
    on as many threads as given; and the threads left to each, to cut its
    deflate stream into segments (ppazlib's parallel rebuild: a photo's,
    alone, on all of them) }
  nImages := 0;
  for s := 0 to nStreams - 1 do
    if modes[s] in IMAGE_MODES then Inc(nImages);
  zThreads := threads;
  if nImages > 1 then begin
    if nImages < threads then zThreads := threads div nImages else zThreads := 1;
  end;
  ParallelFor(nStreams, threads, @Rebuild);
  for s := 0 to nStreams - 1 do
    if (modes[s] in IMAGE_MODES + [MODE_JPEG]) and (Length(p.streams[s].data) <> streamLen[s]) then
      Exit(Bad('image stream damaged or of another length'));

  data := Compose(p);
  Result := True;
end;

function Decompress(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string;
  threads: Integer): Boolean;
var fail: TDecodeFailure;
begin
  Result := DecompressEx(stream, maxOut, data, why, fail, threads);
end;

function DecompressEx(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string;
  out failure: TDecodeFailure; threads: Integer): Boolean;
var was: TStage;
begin
  was := StageEnter(stNone);
  StageEnter(was);
  Result := DecompressSafe(stream, maxOut, data, why, threads, True, nil, failure);
  StageEnter(was);
end;

function DecompressSafe(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string;
  threads: Integer; stages: Boolean; known: PKnownStreams; out failure: TDecodeFailure): Boolean;
var future: Boolean;
begin
  failure := dfNone;
  future := False;
  ModelPoolHold;
  try
  try
    Result := DecompressRaw(stream, maxOut, data, why, threads, stages, known, future);
    if not Result then
      if future then failure := dfFuture else failure := dfDamaged;
  except
    { memory the system did not give: said so (a 32-bit host on a large
      image), not taken for damage }
    on e: EOutOfMemory do begin
      data := nil;
      why := 'out of memory';
      failure := dfMemory;
      Result := False;
    end;
    on e: Exception do begin
      { a damaged stream must not get here; if one does, it is refused, not
        crashed on }
      data := nil;
      why := 'damaged stream (' + e.ClassName + ')';
      failure := dfDamaged;
      Result := False;
    end;
  end;
  finally
    ModelPoolRelease;
  end;
end;

procedure ResetTestSettings;
begin
  BandBytes := BAND_BYTES;
  BandsReverse := False;
  TestModel := -1;
  FastModel := True;
  ppazlib.PAR_MIN_BYTES := 1024 * 1024;
  ppazlib.PAR_SEG_MIN := 256 * 1024;
end;

initialization
  { PJA's codec, called from the codec's threads, keeps models in threadvars }
  OnThreadEnd := @ReleaseThreadModels;
  { BLAKE3's chunks four at a time in SSE2: PJA's C (pjasysc.c), which
    pjav7 gives pjablake3 and which ppablake3, the same code, takes too
    (the same hash; tests/test_blake3 checks the vectors) }
  ppablake3.Blake3Chunks := ppablake3.TBlake3Chunks(pjablake3.Blake3Chunks);
  BandBytes := StrToInt64Def(GetEnvironmentVariable('PPA_TEST_BAND_BYTES'), BAND_BYTES);
  if BandBytes < 1 then BandBytes := BAND_BYTES;
  BandsReverse := GetEnvironmentVariable('PPA_TEST_BANDS_REVERSE') = '1';
  if GetEnvironmentVariable('PPA_TEST_MODEL') = 'slow' then TestModel := MODE_IMAGE
  else if GetEnvironmentVariable('PPA_TEST_MODEL') = 'fast' then TestModel := MODE_FAST
  else if GetEnvironmentVariable('PPA_TEST_MODEL') = 'static' then TestModel := MODE_STATIC;
end.
