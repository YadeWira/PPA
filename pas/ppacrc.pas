{ The two checksums the PNG family carries: CRC-32 (ISO 3309, the one every
  chunk ends with) and Adler-32 (the one every zlib stream ends with).

  This is the Pascal reference version: one table lookup per byte. A faster
  one, if it is ever needed, is measured against this one. }
unit ppacrc;

{$I ppa.inc}
{$ifopt R-}{$fatal ppacrc: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppacrc: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  CRC32_INIT = $FFFFFFFF;

{ Running CRC-32: start with CRC32_INIT, feed with Crc32Update, finish with
  Crc32Final. }
function Crc32Update(crc: LongWord; const a: TBytes; first, len: SizeInt): LongWord;
function Crc32Byte(crc: LongWord; b: Byte): LongWord; inline;
function Crc32Final(crc: LongWord): LongWord; inline;
{ The CRC-32 of a[first..first+len-1] }
function Crc32(const a: TBytes; first, len: SizeInt): LongWord;

{ Adler-32 of a[first..first+len-1], starting from `adler` (1 for a new stream) }
function Adler32(adler: LongWord; const a: TBytes; first, len: SizeInt): LongWord;

implementation

var
  CrcTable: array[0..255] of LongWord;

procedure MakeTable;
var n, k: Integer; c: LongWord;
begin
  for n := 0 to 255 do begin
    c := LongWord(n);
    for k := 0 to 7 do
      if (c and 1) <> 0 then c := $EDB88320 xor (c shr 1) else c := c shr 1;
    CrcTable[n] := c;
  end;
end;

function Crc32Byte(crc: LongWord; b: Byte): LongWord; inline;
begin
  Result := CrcTable[(crc xor b) and $FF] xor (crc shr 8);
end;

function Crc32Update(crc: LongWord; const a: TBytes; first, len: SizeInt): LongWord;
var i: SizeInt;
begin
  Result := crc;
  for i := first to first + len - 1 do
    Result := CrcTable[(Result xor a[i]) and $FF] xor (Result shr 8);
end;

function Crc32Final(crc: LongWord): LongWord; inline;
begin
  Result := crc xor $FFFFFFFF;
end;

function Crc32(const a: TBytes; first, len: SizeInt): LongWord;
begin
  Result := Crc32Final(Crc32Update(CRC32_INIT, a, first, len));
end;

function Adler32(adler: LongWord; const a: TBytes; first, len: SizeInt): LongWord;
const
  ADLER_BASE = 65521;
  { the most bytes before s2 can overflow 32 bits (zlib's NMAX) }
  NMAX = 5552;
var s1, s2: LongWord; i, n: SizeInt;
begin
  s1 := adler and $FFFF; s2 := adler shr 16;
  i := first;
  while len > 0 do begin
    if len < NMAX then n := len else n := NMAX;
    Dec(len, n);
    while n > 0 do begin
      Inc(s1, a[i]); Inc(s2, s1);
      Inc(i); Dec(n);
    end;
    s1 := s1 mod ADLER_BASE; s2 := s2 mod ADLER_BASE;
  end;
  Result := (s2 shl 16) or s1;
end;

initialization
  MakeTable;
end.
