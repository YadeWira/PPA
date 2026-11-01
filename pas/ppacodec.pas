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

  Compress verifies: it decompresses its own stream and compares. A file
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
    older ones. }
  STREAM_VERSION = 1;

type
  TCodecStats = record
    images, imageBytes: Integer;      { image streams kept as images, and their bytes }
    rawStreams, rawBytes: Integer;    { image streams kept as bytes }
  end;

{ data -> stream; False (with why) if the file is not taken. }
function Compress(const data: TBytes; out stream: TBytes; out why: string;
  out stats: TCodecStats; verify: Boolean = True): Boolean;
{ stream -> data; maxOut caps the file. False (with why) on any damage. }
function Decompress(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string): Boolean;

implementation

uses ppapng, ppadeflate, ppazlib, ppapixels, ppaarith, ppamodel;

const
  MODE_BYTES = 0;
  MODE_IMAGE = 1;
  { deflate's largest expansion is 1032:1, plus room for small streams }
  MAX_INFLATE_RATIO = 1100;

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

{ ---------------------------------------------------------------- what each image stream keeps }

type
  TStreamPlan = record
    mode: Integer;
    prm: TZlibParams;
    z: TZStream;          { encoder: the decoded stream }
    px: TPixels;          { encoder: the image }
  end;

{ Whether stream s can be kept as an image, and its plan }
function PlanImage(const p: TPng; s: SizeInt; out plan: TStreamPlan): Boolean;
var info: TImageInfo; e: TZStream; back: TBytes; a: TBytes;
begin
  Result := False;
  plan := Default(TStreamPlan);
  plan.mode := MODE_BYTES;
  if not (p.streams[s].kind in [skIdat, skFdat]) then Exit;
  a := p.streams[s].data;
  if Length(a) = 0 then Exit;
  if not ppadeflate.Decode(a, not IsZlibHeader(a), MAX_IMAGE_BYTES, plan.z).Ok then Exit;
  if not StreamImage(p, s, info) then Exit;
  if not Unfilter(plan.z.plain, info, plan.px) then Exit;
  if not FindZlibParams(plan.z, plan.prm) then Exit;
  { the choices zlib makes, written, must be the stream }
  ZlibChoices(plan.z.plain, plan.prm, nil, e);
  e.raw := plan.z.raw; e.header := plan.z.header; e.adlerOk := plan.z.adlerOk;
  e.endPad := plan.z.endPad; e.tail := plan.z.tail;
  back := Encode(e);
  if (Length(back) <> Length(a)) or not CompareMem(@back[0], @a[0], Length(a)) then Exit;
  plan.mode := MODE_IMAGE;
  Result := True;
end;

{ ---------------------------------------------------------------- compress }

function CompressRaw(const data: TBytes; out stream: TBytes; out why: string;
  out stats: TCodecStats): Boolean;
var
  p: TPng; r: TPngResult; w: TWriter; meta: TBytes;
  plans: array of TStreamPlan;
  i, s: SizeInt; c: TChunk;
  enc: TArithEncoder; bm, rm: TByteModel; body: TBytes;
begin
  Result := False;
  stream := nil;
  stats := Default(TCodecStats);
  r := ppapng.Decompose(data, p);
  if not r.Ok then begin why := 'not a PNG, MNG or JNG file'; Exit; end;

  plans := nil;
  SetLength(plans, Length(p.streams));
  for s := 0 to High(p.streams) do begin
    PlanImage(p, s, plans[s]);
    if plans[s].mode = MODE_IMAGE then begin Inc(stats.images); Inc(stats.imageBytes, Length(p.streams[s].data)); end
    else begin Inc(stats.rawStreams); Inc(stats.rawBytes, Length(p.streams[s].data)); end;
  end;

  { the structure }
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
    if plans[s].mode = MODE_IMAGE then
      with plans[s] do begin
        w.Put(prm.level); w.Put(prm.strategy); w.Put(prm.memLevel); w.Put(prm.wbits);
        w.Put(Ord(z.raw) or (Ord(z.adlerOk) shl 1));
        w.Put(z.header[0]); w.Put(z.header[1]); w.Put(z.endPad);
        w.PutVar(Length(z.tail)); w.PutBytes(z.tail, 0, Length(z.tail));
        w.PutVar(Length(px.tail)); w.PutBytes(px.tail, 0, Length(px.tail));
      end;
  end;
  meta := w.Bytes;

  enc.Init;
  enc.Direct(Length(meta), 32);
  bm.Init;
  CodeBytes(bm, meta, 0, Length(meta), @enc, nil);
  rm.Init;
  for s := 0 to High(p.streams) do
    if plans[s].mode = MODE_IMAGE then CodeImage(plans[s].px, @enc, nil)
    else CodeBytes(rm, p.streams[s].data, 0, Length(p.streams[s].data), @enc, nil);
  body := enc.Finish;

  SetLength(stream, 1 + Length(body));
  stream[0] := STREAM_VERSION;
  if Length(body) > 0 then Move(body[0], stream[1], Length(body));
  Result := True;
end;

function Compress(const data: TBytes; out stream: TBytes; out why: string;
  out stats: TCodecStats; verify: Boolean): Boolean;
var back: TBytes; why2: string;
begin
  why := '';
  Result := CompressRaw(data, stream, why, stats);
  if not Result or not verify then Exit;
  if not Decompress(stream, Length(data), back, why2) or (Length(back) <> Length(data)) or
     ((Length(data) > 0) and not CompareMem(@back[0], @data[0], Length(data))) then begin
    why := 'the codec did not give the same file back (a PPA bug: please report it)';
    if why2 <> '' then why := why + ': ' + why2;
    stream := nil;
    Result := False;
  end;
end;

{ ---------------------------------------------------------------- decompress }

function DecompressRaw(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string): Boolean;
var
  dec: TArithDecoder; bm, rm: TByteModel;
  metaLen: Cardinal; meta: TBytes; r: TReader;
  p: TPng; nChunks, nStreams, total, len: Int64; i, s: SizeInt;
  flags: Byte; c: TChunk;
  modes: array of Integer; prms: array of TZlibParams; zs: array of TZStream; pxTails: array of TBytes;
  streamLen: array of Int64;
  info: TImageInfo; px: TPixels; plain: TBytes; e: TZStream;
  maxSmall: Int64;

  function Bad(const s: string): Boolean;
  begin
    why := s; Result := False;
  end;

begin
  Result := False;
  data := nil; why := '';
  if Length(stream) < 1 then Exit(Bad('empty stream'));
  if stream[0] <> STREAM_VERSION then Exit(Bad(Format('stream version %d not known', [stream[0]])));
  dec.Init(stream, 1);
  metaLen := dec.Direct(32);
  { the structure holds the file's chunks other than the image data, and
    little more }
  if Int64(metaLen) > maxOut + 1024 * 1024 then Exit(Bad('structure larger than the file may be'));
  meta := nil; SetLength(meta, metaLen);
  bm.Init;
  CodeBytes(bm, meta, 0, metaLen, nil, @dec);

  r := Default(TReader);
  r.b := meta; r.pos := 0; r.ok := True;
  p := Default(TPng);
  i := r.Get;
  if i > Ord(High(TPngKind)) then Exit(Bad('bad file kind'));
  p.kind := TPngKind(i);
  maxSmall := maxOut;
  nChunks := r.GetVar(MAX_CHUNKS);
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

  nStreams := r.GetVar(MAX_CHUNKS);
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
    if not r.ok or (modes[s] > MODE_IMAGE) then Exit(Bad('bad structure'));
    if modes[s] = MODE_IMAGE then begin
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

  { the image streams' contents }
  rm.Init;
  for s := 0 to nStreams - 1 do begin
    if modes[s] = MODE_BYTES then begin
      SetLength(p.streams[s].data, streamLen[s]);
      CodeBytes(rm, p.streams[s].data, 0, streamLen[s], nil, @dec);
    end else begin
      if not StreamImage(p, s, info) or not InitLayout(info, px) then Exit(Bad('bad image header'));
      if FilteredSize(px) + Int64(Length(pxTails[s])) > MAX_INFLATE_RATIO * streamLen[s] + 1024 then
        Exit(Bad('image larger than its stream can hold'));
      CodeImage(px, nil, @dec);
      px.tail := pxTails[s];
      plain := Refilter(px);
      ZlibChoices(plain, prms[s], nil, e);
      e.raw := zs[s].raw; e.adlerOk := zs[s].adlerOk; e.header := zs[s].header;
      e.endPad := zs[s].endPad; e.tail := zs[s].tail;
      p.streams[s].data := Encode(e);
      if Length(p.streams[s].data) <> streamLen[s] then Exit(Bad('image stream of another length'));
    end;
  end;

  data := Compose(p);
  Result := True;
end;

function Decompress(const stream: TBytes; maxOut: Int64; out data: TBytes; out why: string): Boolean;
begin
  try
    Result := DecompressRaw(stream, maxOut, data, why);
  except
    on e: Exception do begin
      { a damaged stream must not get here; if one does, it is refused, not
        crashed on }
      data := nil;
      why := 'damaged stream (' + e.ClassName + ')';
      Result := False;
    end;
  end;
end;

end.
