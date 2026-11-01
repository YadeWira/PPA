{ Codec layer 1: a file of the PNG family (PNG, APNG, MNG, JNG) split into
  its chunks and its image data streams, and back to the SAME file, byte for
  byte.

  The four share one layout: an 8-byte signature and then chunks of
  length (4 bytes, big endian), type (4 letters), data, and a CRC-32 over
  type and data. What differs is which chunks carry the image:

    IDAT  the zlib stream of a PNG image, split over as many chunks as the
          encoder liked (also a JNG's alpha channel, and each PNG embedded
          in an MNG);
    fdAT  the zlib stream of each later APNG frame, after a 4-byte sequence
          number;
    JDAT  the JPEG of a JNG image, split the same way;
    JDAA  a JNG's alpha channel as a JPEG.

  The data of those chunks is gathered into one stream per image (per frame
  for fdAT), the way a decoder reads it: everything between an image's
  header (IHDR or JHDR) and its IEND, even if other chunks come in between.
  The upper layers model the streams; this layer only has to give them back
  in the same chunks.

  What an encoder chooses and has to be recorded: where each stream is cut
  into chunks (each chunk's length), each fdAT's sequence number, and a CRC
  that is not the right one (kept as it is; a right one is computed again).
  Everything else is kept verbatim: the other chunks, and the bytes after
  the last chunk (after IEND or MEND, or from where the bytes stop being a
  chunk: a file cut short keeps what it has).

  Not interpreted here: what is inside the streams, and the zlib streams of
  zTXt, iTXt and iCCP. VerifyRoundTrip rebuilds and compares against the
  original. }
unit ppapng;

{$I ppa.inc}
{$ifopt R-}{$fatal ppapng: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppapng: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  { Cap on chunks in one file. Each one is at least 12 bytes, so 4M chunks
    are a 48 MB file of nothing but chunk headers. }
  MAX_CHUNKS = 1 shl 22;
  { The PNG specification (5.3): a chunk's length is at most 2^31 - 1. }
  MAX_CHUNK_LEN = $7FFFFFFF;

  { chunk types, as the big-endian number of their 4 letters }
  CT_IHDR = $49484452; CT_IDAT = $49444154; CT_IEND = $49454E44;
  CT_fcTL = $6663544C; CT_fdAT = $66644154;
  CT_JHDR = $4A484452; CT_JDAT = $4A444154; CT_JDAA = $4A444141;
  CT_MHDR = $4D484452; CT_MEND = $4D454E44;

type
  TPngKind = (pkPng, pkMng, pkJng);

  TPngError = (
    peNone,
    peNotPng,      { no PNG, MNG or JNG signature }
    peTooMany,     { more than MAX_CHUNKS chunks }
    { decomposed, but does not give back the same bytes }
    peNoRoundTrip);

  TPngResult = record
    err: TPngError;
    pos: Int64;    { byte of the original where it was detected }
    function Ok: Boolean;
    { "NotPng@0" }
    function Text: string;
  end;

  TStreamKind = (skIdat, skFdat, skJdat, skJdaa);

  TImageStream = record
    kind: TStreamKind;
    { the chunk holding its image's header (IHDR, JHDR), -1 if none came
      before it }
    header: SizeInt;
    { fdAT: the chunk of the fcTL it follows; -1 for the others }
    frame: SizeInt;
    { the data of its chunks, in order; fdAT without the sequence numbers }
    data: TBytes;
  end;

  TChunk = record
    typ: LongWord;     { the 4 type bytes, big endian }
    len: SizeInt;      { the data's length, as the file says }
    crc: LongWord;     { the CRC in the file }
    crcOk: Boolean;    { it is the CRC of type and data: computed again }
    { -1: the data is `data`; else the stream it belongs to, which holds it
      (fdAT: all but the sequence number) }
    stream: SizeInt;
    seq: LongWord;     { fdAT: the sequence number }
    data: TBytes;
  end;

  TPng = record
    kind: TPngKind;
    chunks: array of TChunk;
    streams: array of TImageStream;
    { the bytes after the last chunk }
    trailer: TBytes;
  end;

function ChunkName(typ: LongWord): string;

{ d -> p. Never raises on any input: a file that is not of the family
  gives peNotPng, anything else after the signature decomposes. }
function Decompose(const d: TBytes; out p: TPng): TPngResult;
{ p -> the file }
function Compose(const p: TPng): TBytes;
{ Decompose, Compose, and compare. }
function VerifyRoundTrip(const d: TBytes; out p: TPng): TPngResult;

implementation

uses ppacrc;

const
  SIG_TAIL: array[2..7] of Byte = (Ord('N'), Ord('G'), $0D, $0A, $1A, $0A);

function TPngResult.Ok: Boolean;
begin
  Result := err = peNone;
end;

function TPngResult.Text: string;
const NAMES: array[TPngError] of string = ('None', 'NotPng', 'TooMany', 'NoRoundTrip');
begin
  Result := NAMES[err] + '@' + IntToStr(pos);
end;

function ChunkName(typ: LongWord): string;
begin
  Result := Chr(typ shr 24) + Chr((typ shr 16) and $FF) + Chr((typ shr 8) and $FF) + Chr(typ and $FF);
end;

function Be32(const d: TBytes; i: SizeInt): LongWord; inline;
begin
  Result := (LongWord(d[i]) shl 24) or (LongWord(d[i + 1]) shl 16) or
            (LongWord(d[i + 2]) shl 8) or LongWord(d[i + 3]);
end;

procedure PutBe32(var d: TBytes; i: SizeInt; v: LongWord); inline;
begin
  d[i] := Byte(v shr 24); d[i + 1] := Byte(v shr 16);
  d[i + 2] := Byte(v shr 8); d[i + 3] := Byte(v);
end;

function IsLetter(b: Byte): Boolean; inline;
begin
  Result := ((b >= Ord('A')) and (b <= Ord('Z'))) or ((b >= Ord('a')) and (b <= Ord('z')));
end;

function SignatureKind(const d: TBytes; out kind: TPngKind): Boolean;
var i: Integer;
begin
  Result := False;
  kind := pkPng;
  if Length(d) < 8 then Exit;
  case d[0] of
    $89: if d[1] = Ord('P') then kind := pkPng else Exit;
    $8A: if d[1] = Ord('M') then kind := pkMng else Exit;
    $8B: if d[1] = Ord('J') then kind := pkJng else Exit;
  else Exit;
  end;
  for i := 2 to 7 do
    if d[i] <> SIG_TAIL[i] then Exit;
  Result := True;
end;

function Decompose(const d: TBytes; out p: TPng): TPngResult;
var
  pos, n, start, dataLen: SizeInt;
  len, typ: LongWord;
  c: TChunk;
  { growing arrays: used lengths, trimmed at the end }
  nChunks, nStreams: SizeInt;
  used: array of SizeInt;
  { the image being read: its header chunk and its streams, -1 = none yet }
  header, curIdat, curJdat, curJdaa, curFdat, frame: SizeInt;

  function NewStream(kind: TStreamKind; frm: SizeInt): SizeInt;
  begin
    if nStreams = Length(p.streams) then begin
      SetLength(p.streams, 2 * nStreams + 4);
      SetLength(used, Length(p.streams));
    end;
    Result := nStreams; Inc(nStreams);
    p.streams[Result].kind := kind;
    p.streams[Result].header := header;
    p.streams[Result].frame := frm;
    p.streams[Result].data := nil;
    used[Result] := 0;
  end;

  procedure Append(s: SizeInt; first, cnt: SizeInt);
  var cap: SizeInt;
  begin
    if cnt <= 0 then Exit;
    cap := Length(p.streams[s].data);
    if used[s] + cnt > cap then begin
      if 2 * cap > used[s] + cnt then cap := 2 * cap else cap := used[s] + cnt;
      SetLength(p.streams[s].data, cap);
    end;
    Move(d[first], p.streams[s].data[used[s]], cnt);
    Inc(used[s], cnt);
  end;

  procedure NewImage(hdr: SizeInt);
  begin
    header := hdr;
    curIdat := -1; curJdat := -1; curJdaa := -1; curFdat := -1; frame := -1;
  end;

begin
  p.chunks := nil; p.streams := nil; p.trailer := nil;
  Result.err := peNone; Result.pos := 0;
  if not SignatureKind(d, p.kind) then begin Result.err := peNotPng; Exit; end;

  nChunks := 0; nStreams := 0; used := nil;
  NewImage(-1);
  pos := 8;
  n := Length(d);
  while n - pos >= 12 do begin
    len := Be32(d, pos);
    if len > MAX_CHUNK_LEN then Break;
    if SizeInt(len) > n - pos - 12 then Break;
    if not (IsLetter(d[pos + 4]) and IsLetter(d[pos + 5]) and
            IsLetter(d[pos + 6]) and IsLetter(d[pos + 7])) then Break;
    if nChunks = MAX_CHUNKS then begin Result.err := peTooMany; Result.pos := pos; Exit; end;
    typ := Be32(d, pos + 4);
    dataLen := SizeInt(len);
    start := pos + 8;

    c.typ := typ; c.len := dataLen; c.stream := -1; c.seq := 0; c.data := nil;
    c.crc := Be32(d, start + dataLen);
    c.crcOk := Crc32(d, pos + 4, dataLen + 4) = c.crc;

    case typ of
      CT_IHDR, CT_JHDR: NewImage(nChunks);
      CT_fcTL: begin frame := nChunks; curFdat := -1; end;
    end;

    case typ of
      CT_IDAT: begin
        if curIdat < 0 then curIdat := NewStream(skIdat, -1);
        c.stream := curIdat;
        Append(c.stream, start, dataLen);
      end;
      CT_JDAT: begin
        if curJdat < 0 then curJdat := NewStream(skJdat, -1);
        c.stream := curJdat;
        Append(c.stream, start, dataLen);
      end;
      CT_JDAA: begin
        if curJdaa < 0 then curJdaa := NewStream(skJdaa, -1);
        c.stream := curJdaa;
        Append(c.stream, start, dataLen);
      end;
      CT_fdAT:
        { an fdAT too short for its sequence number stays verbatim }
        if dataLen >= 4 then begin
          if curFdat < 0 then curFdat := NewStream(skFdat, frame);
          c.stream := curFdat;
          c.seq := Be32(d, start);
          Append(c.stream, start + 4, dataLen - 4);
        end;
    end;
    if c.stream < 0 then begin
      SetLength(c.data, dataLen);
      if dataLen > 0 then Move(d[start], c.data[0], dataLen);
    end;

    if nChunks = Length(p.chunks) then SetLength(p.chunks, 2 * nChunks + 16);
    p.chunks[nChunks] := c;
    Inc(nChunks);
    pos := start + dataLen + 4;

    if typ = CT_IEND then begin
      NewImage(-1);
      { a PNG or a JNG ends here; an MNG goes on until MEND }
      if p.kind <> pkMng then Break;
    end;
    if typ = CT_MEND then Break;
  end;

  SetLength(p.chunks, nChunks);
  SetLength(p.streams, nStreams);
  for n := 0 to nStreams - 1 do SetLength(p.streams[n].data, used[n]);
  SetLength(p.trailer, Length(d) - pos);
  if Length(p.trailer) > 0 then Move(d[pos], p.trailer[0], Length(p.trailer));
end;

function Compose(const p: TPng): TBytes;
const SIG_FIRST: array[TPngKind] of Byte = ($89, $8A, $8B);
const SIG_SECOND: array[TPngKind] of Char = ('P', 'M', 'J');
var
  total, o, i, s, dlen, crcStart: SizeInt;
  off: array of SizeInt;  { how much of each stream the chunks so far took }
  c32: LongWord;
begin
  total := 8 + Length(p.trailer);
  for i := 0 to High(p.chunks) do Inc(total, 12 + p.chunks[i].len);
  Result := nil;
  SetLength(Result, total);

  Result[0] := SIG_FIRST[p.kind]; Result[1] := Ord(SIG_SECOND[p.kind]);
  for i := 2 to 7 do Result[i] := SIG_TAIL[i];
  o := 8;
  off := nil;
  SetLength(off, Length(p.streams));
  for i := 0 to High(p.chunks) do
    with p.chunks[i] do begin
      PutBe32(Result, o, LongWord(len));
      PutBe32(Result, o + 4, typ);
      crcStart := o + 4;
      Inc(o, 8);
      if stream < 0 then begin
        if len > 0 then Move(data[0], Result[o], len);
        Inc(o, len);
      end else begin
        s := stream;
        dlen := len;
        if typ = CT_fdAT then begin
          PutBe32(Result, o, seq);
          Inc(o, 4); Dec(dlen, 4);
        end;
        if dlen > 0 then Move(p.streams[s].data[off[s]], Result[o], dlen);
        Inc(off[s], dlen);
        Inc(o, dlen);
      end;
      if crcOk then c32 := Crc32(Result, crcStart, o - crcStart) else c32 := crc;
      PutBe32(Result, o, c32);
      Inc(o, 4);
    end;
  if Length(p.trailer) > 0 then Move(p.trailer[0], Result[o], Length(p.trailer));
end;

function VerifyRoundTrip(const d: TBytes; out p: TPng): TPngResult;
var r: TBytes; i: SizeInt;
begin
  Result := Decompose(d, p);
  if not Result.Ok then Exit;
  r := Compose(p);
  if Length(r) <> Length(d) then begin
    Result.err := peNoRoundTrip;
    if Length(r) < Length(d) then Result.pos := Length(r) else Result.pos := Length(d);
    Exit;
  end;
  for i := 0 to High(d) do
    if r[i] <> d[i] then begin Result.err := peNoRoundTrip; Result.pos := i; Exit; end;
end;

end.
