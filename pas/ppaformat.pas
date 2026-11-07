{ Codec layer 7, the file: a .ppa is ONE compressed file, the codec stream
  (layer 6) with the original's size, BLAKE3-128 hash and extension. The
  layout and every limit are in doc/FORMAT.md; it follows PJA's .pja.

    HEADER - 8 B
      magic       4 B   "PPA" 0x01
      version     1 B   1
      flags       1 B   bit 0: stored (the payload is the original itself)
      reserved    2 B   0
    DESCRIPTOR
      orig_size   u64 LE
      hash        16 B  BLAKE3-128 of the original
      ext_len     1 B   0 to 15
      ext         the original's extension, without the dot, as written:
                  letters, digits, '_' and '-'
      ext_check   4 B   the first 4 bytes of BLAKE3 of ext_len and ext
    PAYLOAD - the rest

  The writer validates its descriptor with the same function the reader
  uses: what is written can be opened. The reader validates everything,
  refuses a size above the caller's cap, and only then decodes, with the
  declared size as the cap; the result must have that size and hash. }
unit ppaformat;

{$I ppa.inc}
{$ifopt R-}{$fatal ppaformat: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppaformat: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, ppablake3, ppacodec;

const
  FORMAT_VERSION = 1;
  HEADER_SIZE = 8;
  { the smallest codec stream: its version byte and the coder's 4 bytes }
  MIN_PAYLOAD = 5;
  { How many times its payload a declared size may be, checked before
    decoding. As PJA's: a last-resort cap, not a tight bound (a PNG of one
    colour shrinks a lot more than a photo). The user's cap still applies. }
  MAX_EXPANSION_RATIO = 65536;
  MAX_EXT = 15;

var
  { For the tests and ppa selftest only: a codec stream no smaller than the
    original is written all the same, not the original stored, so that the
    stream of a small sample is what gets compared. From the environment:
    PPA_TEST_KEEP_STREAM=1. }
  TestKeepStream: Boolean = False;

type
  TFormatError = (
    feNone, feShortFile, feNotPpa, feFutureVersion, feUnknownFlag,
    feReservedNotZero, feBadOrigSize, feRatioExceeded, fePayloadOutOfRange,
    feBadExtension, feTooLarge, feDamaged, feSizeMismatch, feHashMismatch,
    { the codec stream inside is of a version this release does not know (a
      newer PPA's; damage on that byte looks the same) }
    feFutureStream,
    { memory the system did not give while decoding }
    feNoMemory);

  TDescriptor = record
    stored: Boolean;
    origSize: QWord;
    hash: THash16;
    ext: string;
    payloadPos, payloadLen: SizeInt;
  end;

function FormatErrorText(e: TFormatError): string;
{ letters, digits, '_' and '-', at most MAX_EXT }
function ValidExtension(const ext: string): Boolean;

{ original -> .ppa. ext: the original's extension (left out if not valid).
  stored when the codec does not take the file or does not make it smaller;
  why says why it was stored ('' when it was not). threads: the codec's
  (ppacodec.Compress); stats: what the codec did with it. }
function Pack(const original: TBytes; const ext: string; verify: Boolean;
  out ppa: TBytes; out stored: Boolean; out why: string; threads: Integer = 1): Boolean;
function Pack(const original: TBytes; const ext: string; verify: Boolean;
  out ppa: TBytes; out stored: Boolean; out why: string; out stats: TCodecStats; threads: Integer): Boolean;
{ The header and descriptor, validated }
function Inspect(const ppa: TBytes; out d: TDescriptor): TFormatError;
{ .ppa -> original. maxOut: the caller's cap (0 = none). detail: the
  codec's reason when it is feDamaged. On feHashMismatch, original is what
  the codec gave (for x's --keep-corrupt, which keeps it under another
  name); on any other error it is empty. }
function Unpack(const ppa: TBytes; maxOut: QWord; out original: TBytes;
  out d: TDescriptor; out detail: string; threads: Integer = 1): TFormatError;
{ The bytes start as a .ppa does (its magic) }
function IsPpa(const d: TBytes): Boolean;

implementation

uses ppastage;

const
  MAGIC: array[0..3] of Byte = (Ord('P'), Ord('P'), Ord('A'), 1);

function FormatErrorText(e: TFormatError): string;
const T: array[TFormatError] of string = ('', 'too short to be a .ppa',
  'not a .ppa file', 'made by a newer PPA (format version not known)', 'unknown flag',
  'reserved bytes not zero', 'bad original size', 'declared size too large for its payload',
  'payload of a wrong size', 'bad extension field', 'larger than the allowed output',
  'damaged', 'damaged: the result has another size', 'damaged: the result has another hash',
  'made by a newer PPA (stream version not known)', 'out of memory');
begin
  Result := T[e];
end;

function ValidExtension(const ext: string): Boolean;
var c: Char;
begin
  Result := Length(ext) <= MAX_EXT;
  for c in ext do
    if not (c in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then Result := False;
end;

function ExtensionCheck(const ext: string): LongWord;
var a: TBytes; h: THash16; i: Integer;
begin
  a := nil; SetLength(a, 1 + Length(ext));
  a[0] := Length(ext);
  for i := 1 to Length(ext) do a[i] := Ord(ext[i]);
  h := Blake3_128(a);
  Result := LongWord(h[0]) or (LongWord(h[1]) shl 8) or (LongWord(h[2]) shl 16) or (LongWord(h[3]) shl 24);
end;

{ The descriptor's numbers, the same verdict for the writer and the reader }
function ValidateSizes(stored: Boolean; origSize: QWord; payloadLen: SizeInt): TFormatError;
begin
  Result := feNone;
  if (origSize = 0) or (origSize > QWord(High(Int64))) then Exit(feBadOrigSize);
  if stored then begin
    if payloadLen < 1 then Exit(fePayloadOutOfRange);
    if origSize <> QWord(payloadLen) then Exit(feBadOrigSize);
  end else begin
    if payloadLen < MIN_PAYLOAD then Exit(fePayloadOutOfRange);
    { by division: no overflow }
    if (origSize - 1) div MAX_EXPANSION_RATIO >= QWord(payloadLen) then Exit(feRatioExceeded);
  end;
end;

function Inspect(const ppa: TBytes; out d: TDescriptor): TFormatError;
var i, pos, n: SizeInt; check: LongWord; flags: Byte;
begin
  d := Default(TDescriptor);
  if Length(ppa) < HEADER_SIZE then Exit(feShortFile);
  for i := 0 to 3 do if ppa[i] <> MAGIC[i] then Exit(feNotPpa);
  if ppa[4] > FORMAT_VERSION then Exit(feFutureVersion);
  if ppa[4] < 1 then Exit(feNotPpa);
  flags := ppa[5];
  if (flags and $FE) <> 0 then Exit(feUnknownFlag);
  if (ppa[6] <> 0) or (ppa[7] <> 0) then Exit(feReservedNotZero);
  d.stored := (flags and 1) <> 0;
  pos := HEADER_SIZE;
  if Length(ppa) - pos < 8 + 16 + 1 then Exit(feShortFile);
  d.origSize := 0;
  for i := 7 downto 0 do d.origSize := (d.origSize shl 8) or ppa[pos + i];
  Inc(pos, 8);
  for i := 0 to 15 do d.hash[i] := ppa[pos + i];
  Inc(pos, 16);
  n := ppa[pos]; Inc(pos);
  if n > MAX_EXT then Exit(feBadExtension);
  if Length(ppa) - pos < n + 4 then Exit(feShortFile);
  SetLength(d.ext, n);
  for i := 1 to n do d.ext[i] := Chr(ppa[pos + i - 1]);
  Inc(pos, n);
  check := LongWord(ppa[pos]) or (LongWord(ppa[pos + 1]) shl 8) or (LongWord(ppa[pos + 2]) shl 16) or (LongWord(ppa[pos + 3]) shl 24);
  Inc(pos, 4);
  if not ValidExtension(d.ext) or (check <> ExtensionCheck(d.ext)) then Exit(feBadExtension);
  d.payloadPos := pos;
  d.payloadLen := Length(ppa) - pos;
  Result := ValidateSizes(d.stored, d.origSize, d.payloadLen);
end;

function IsPpa(const d: TBytes): Boolean;
var i: Integer;
begin
  Result := Length(d) >= 4;
  if Result then
    for i := 0 to 3 do if d[i] <> MAGIC[i] then Exit(False);
end;

function Pack(const original: TBytes; const ext: string; verify: Boolean;
  out ppa: TBytes; out stored: Boolean; out why: string; threads: Integer): Boolean;
var stats: TCodecStats;
begin
  Result := Pack(original, ext, verify, ppa, stored, why, stats, threads);
end;

function Pack(const original: TBytes; const ext: string; verify: Boolean;
  out ppa: TBytes; out stored: Boolean; out why: string; out stats: TCodecStats; threads: Integer): Boolean;
var
  stream, payload: TBytes; e: string; h: THash16;
  pos, i: SizeInt; check: LongWord;
begin
  Result := False;
  ppa := nil; why := ''; stored := False;
  stats := Default(TCodecStats);
  if Length(original) = 0 then begin why := 'empty file'; Exit; end;
  stored := not Compress(original, stream, why, stats, verify, threads);
  if not stored and (Length(stream) >= Length(original)) and not TestKeepStream then begin
    stored := True; why := 'the codec does not make it smaller';
  end;
  if stored then payload := original else payload := stream;
  if ValidExtension(ext) then e := ext else e := '';
  if ValidateSizes(stored, Length(original), Length(payload)) <> feNone then begin
    { a stream the reader would refuse is not written: store instead }
    stored := True; payload := original; why := 'the codec stream is outside the format''s limits';
    if ValidateSizes(stored, Length(original), Length(payload)) <> feNone then Exit;
  end;
  StageEnter(stHash);
  h := Blake3_128(original);
  StageEnter(stNone);
  SetLength(ppa, HEADER_SIZE + 8 + 16 + 1 + Length(e) + 4 + Length(payload));
  for i := 0 to 3 do ppa[i] := MAGIC[i];
  ppa[4] := FORMAT_VERSION;
  ppa[5] := Ord(stored);
  ppa[6] := 0; ppa[7] := 0;
  pos := HEADER_SIZE;
  for i := 0 to 7 do ppa[pos + i] := Byte(QWord(Length(original)) shr (8 * i));
  Inc(pos, 8);
  for i := 0 to 15 do ppa[pos + i] := h[i];
  Inc(pos, 16);
  ppa[pos] := Length(e); Inc(pos);
  for i := 1 to Length(e) do ppa[pos + i - 1] := Ord(e[i]);
  Inc(pos, Length(e));
  check := ExtensionCheck(e);
  for i := 0 to 3 do ppa[pos + i] := Byte(check shr (8 * i));
  Inc(pos, 4);
  Move(payload[0], ppa[pos], Length(payload));
  Result := True;
end;

function Unpack(const ppa: TBytes; maxOut: QWord; out original: TBytes;
  out d: TDescriptor; out detail: string; threads: Integer): TFormatError;
var stream: TBytes; h: THash16; i: Integer; fail: TDecodeFailure;
begin
  original := nil; detail := '';
  Result := Inspect(ppa, d);
  if Result <> feNone then Exit;
  if (maxOut > 0) and (d.origSize > maxOut) then Exit(feTooLarge);
  if d.stored then original := Copy(ppa, d.payloadPos, d.payloadLen)
  else begin
    stream := Copy(ppa, d.payloadPos, d.payloadLen);
    if not DecompressEx(stream, Int64(d.origSize), original, detail, fail, threads) then begin
      StageEnter(stNone);
      original := nil;
      case fail of
        dfFuture: Exit(feFutureStream);
        dfMemory: Exit(feNoMemory);
      else Exit(feDamaged);
      end;
    end;
  end;
  if QWord(Length(original)) <> d.origSize then begin StageEnter(stNone); original := nil; Exit(feSizeMismatch); end;
  StageEnter(stHash);
  h := Blake3_128(original);
  StageEnter(stNone);
  for i := 0 to 15 do
    if h[i] <> d.hash[i] then Exit(feHashMismatch);
end;

initialization
  TestKeepStream := GetEnvironmentVariable('PPA_TEST_KEEP_STREAM') = '1';
end.
