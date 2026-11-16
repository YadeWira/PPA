{ libdeflate's deflate, exact: the stream libdeflate_deflate_compress
  writes for a stream's bytes at a level (1 to 12), from libdeflate's own
  compressor (vendor/libdeflate, unmodified, built by ppaldfc.c). Recipe
  kind 2, encoder 2 (ppapreflate) names libdeflate, its variant and its
  level. oxipng writes with it: its -o1 is level 10, -o2 level 11, -o3 and
  over level 12; libdeflate's own default is 6.

  Variant LDFV_119: libdeflate 1.19 to 1.26, which give the same bytes at
  every level (checked on the corpus's PNG streams; 1.18 and before
  sometimes differ, another variant if ever). The compressor is C only:
  libdeflate itself is the reference (there is no Pascal path for it, and
  PPA_NOC does not change it). One call with all the bytes, as oxipng and
  libdeflate's zlib and gzip wrappers make it. }
unit ppalibdeflate;

{$I ppa.inc}
{$ifopt R-}{$fatal ppalibdeflate: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppalibdeflate: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, ppadeflate;

const
  LDF_LEVEL_MIN = 1;
  LDF_LEVEL_MAX = 12;
  { the variants: libdeflate 1.19 to 1.26 }
  LDFV_119 = 0;
  LDFV_LAST = LDFV_119;

type
  TLdfParams = record
    variant: Integer;   { 0..LDFV_LAST }
    level: Integer;     { LDF_LEVEL_MIN..LDF_LEVEL_MAX }
  end;

function LdfValid(const p: TLdfParams): Boolean;

{ plain -> the raw deflate stream libdeflate writes at p's level; False on
  p LdfValid refuses or no memory }
function LdfDeflate(const plain: TBytes; const p: TLdfParams; out raw: TBytes): Boolean;

{ The same as choices (blocks, tokens, plain: raw deflate, no framing),
  for ppadeflate.Encode with a recipe's framing. }
function LdfChoices(const plain: TBytes; const p: TLdfParams; out e: TZStream): Boolean;

{ The level whose stream is z's deflate data (a: z's stream, as parsed):
  tried only when z's first dynamic blocks have libdeflate's trees
  (ppacorr.LibdeflateTrees), or z has no dynamic block and few bytes;
  oxipng's levels first (12, 11, 10), then libdeflate's default (6), then
  the others. choices: LdfChoices of it. }
function FindLdfParams(const a: TBytes; const z: TZStream; out p: TLdfParams; out choices: TZStream): Boolean;

const
  { a stream with no dynamic block (stored or static ones: few bytes, or
    none that compress) is tried at every level up to this many bytes }
  LDF_TRY_UNTREED = 1 shl 16;
  { the dynamic blocks whose trees must be libdeflate's (the first ones) }
  LDF_CHECK_BLOCKS = 2;

implementation

uses ppacorr;

{$L ppaldfc.o}
{ memcpy, memmove, memset, memcmp for ppaldfc.c and ppazopc.c (ppazopfli) }
{$L ppamemc.o}

type
  TAllocFn = function(n: SizeUInt): Pointer; cdecl;
  TReleaseFn = procedure(p: Pointer); cdecl;

function ppa_ldf_compress(level: LongInt; input: Pointer; n: SizeUInt; output: Pointer; cap: SizeUInt;
  alloc: TAllocFn; release: TReleaseFn): SizeUInt; cdecl; external name 'ppa_ldf_compress';
function ppa_ldf_bound(n: SizeUInt): SizeUInt; cdecl; external name 'ppa_ldf_bound';

{ libdeflate's memory: FreePascal's heap (thread-safe), nil when there is none }
function LdfAlloc(n: SizeUInt): Pointer; cdecl;
begin
  try
    Result := GetMem(n);
  except
    Result := nil;
  end;
end;

procedure LdfRelease(p: Pointer); cdecl;
begin
  FreeMem(p);
end;

function LdfValid(const p: TLdfParams): Boolean;
begin
  Result := (p.variant >= 0) and (p.variant <= LDFV_LAST) and (p.level >= LDF_LEVEL_MIN) and
    (p.level <= LDF_LEVEL_MAX);
end;

function LdfDeflate(const plain: TBytes; const p: TLdfParams; out raw: TBytes): Boolean;
var cap, n: SizeUInt; src: Pointer; empty: Byte;
begin
  raw := nil;
  if not LdfValid(p) then Exit(False);
  cap := ppa_ldf_bound(Length(plain));
  SetLength(raw, cap);
  empty := 0;
  if Length(plain) > 0 then src := @plain[0] else src := @empty;
  n := ppa_ldf_compress(p.level, src, Length(plain), @raw[0], cap, @LdfAlloc, @LdfRelease);
  if n = 0 then begin raw := nil; Exit(False); end;
  SetLength(raw, n);
  Result := True;
end;

function LdfChoices(const plain: TBytes; const p: TLdfParams; out e: TZStream): Boolean;
var raw: TBytes;
begin
  e := Default(TZStream);
  if not LdfDeflate(plain, p, raw) then Exit(False);
  { libdeflate's own stream, read back: always deflate, the same bytes }
  Result := Decode(raw, True, Length(plain), e).Ok and (Length(e.plain) = Length(plain)) and
    ((Length(plain) = 0) or CompareMem(@e.plain[0], @plain[0], Length(plain)));
end;

{ z's deflate data in a: where it starts (after a zlib header) and how
  many bytes it takes (up to the Adler-32 and the tail) }
procedure DeflateSpan(const a: TBytes; const z: TZStream; out first, len: SizeInt);
begin
  if z.raw then first := 0 else first := 2;
  len := Length(a) - first - Length(z.tail);
  if z.adlerOk then Dec(len, 4);
end;

function FindLdfParams(const a: TBytes; const z: TZStream; out p: TLdfParams; out choices: TZStream): Boolean;
const ORDER: array[0..11] of Integer = (12, 11, 10, 6, 9, 8, 7, 5, 4, 3, 2, 1);
var bi, seen, k, first, len: SizeInt; raw: TBytes;
begin
  Result := False;
  p := Default(TLdfParams);
  choices := Default(TZStream);
  { the quick test: the first dynamic blocks' trees }
  seen := 0;
  for bi := 0 to High(z.blocks) do
    if z.blocks[bi].btype = btDynamic then begin
      if not LibdeflateTrees(z, bi) then Exit;
      Inc(seen);
      if seen = LDF_CHECK_BLOCKS then Break;
    end;
  if (seen = 0) and (Length(z.plain) > LDF_TRY_UNTREED) then Exit;
  DeflateSpan(a, z, first, len);
  if len <= 0 then Exit;
  p.variant := LDFV_119;
  for k := 0 to High(ORDER) do begin
    p.level := ORDER[k];
    if not LdfDeflate(z.plain, p, raw) or (Length(raw) <> len) then Continue;
    { every byte but the last the same (the last one holds the bits after
      the last block, the stream's endPad, which the recipe's framing
      keeps); the caller rebuilds the whole stream and compares it }
    if (len > 1) and not CompareMem(@raw[0], @a[first], len - 1) then Continue;
    if LdfChoices(z.plain, p, choices) then Exit(True);
  end;
  p := Default(TLdfParams);
end;

end.
