{ One deflate stream at a time, as libppa's ppa_deflate_* (ppa.h) give it
  to a C program: PDA's PDF and ZIP streams. A stream -> the bytes it holds
  and a recipe (ppapreflate's, behind a byte of version), and back to the
  same bits.

  A context (TDeflCtx) is one thread's: it holds the size cap and the last
  stream's recipe, tried first on the next stream (a document's streams are
  mostly made by the same encoder with the same settings: PDA's batch). A
  recipe is the same whichever context made or reads it; what the hint
  changes is how long the search takes, and which of the recipes that give
  the stream back is found when there are several.

  A recipe's bytes: the codec stream version that holds it (3 to
  STREAM_VERSION: ppapreflate.RecipeVersion, kind 0's taken as 3), then
  RecipeBytes (doc/PREFLATE.md) with no tail. A reader refuses a version
  above its own STREAM_VERSION (DC_VERSION): a later PPA's encoder. }
unit ppadeflctx;

{$I ppa.inc}

interface

uses SysUtils, ppadeflate, ppazlib, ppapreflate, ppacodec;

const
  { the results, ppa.h's codes }
  DC_OK = 0;
  DC_NOT_TAKEN = 1;
  DC_DATA = 2;
  DC_MEMORY = 3;
  DC_ARG = 6;
  DC_VERSION = 7;
  { the flags: the framing (bits 0-1), the level (bits 4-5, LEVEL_*; 0:
    LEVEL_DEFAULT) }
  DEFL_RAW = 1;
  DEFL_ZLIB = 2;
  DEFL_AUTO = 3;
  DEFL_LEVEL_SHIFT = 4;
  DEFL_FLAGS_KNOWN = 3 or (3 shl DEFL_LEVEL_SHIFT);
  { the cap on a stream's bytes when the caller gives none }
  DEFL_MAX_PLAIN_DEFAULT = SizeInt(1) shl 30;

type
  TDeflCtx = class
    maxPlain: SizeInt;
    { the last stream's recipe, when it is of a kind worth trying again
      (zlib's parameters, miniz, libdeflate: each costs one encode) }
    havePrev: Boolean;
    prev: TDeflRecipe;
    { how many streams the hint gave (the tests') }
    hits: SizeInt;
    { zlib's tables, kept from one stream to the next }
    scratch: TZlibScratch;
    constructor Create(aMaxPlain: SizeUInt);
    { src[0..n) -> plain, recipe; consumed: where the deflate data ends
      (with the Adler-32 when zlib-framed and it is the right one): the
      bytes after it are the caller's, not in the recipe. DC_DATA: not a
      deflate stream, errPos the byte where that showed. }
    function Analyze(src: PByte; n: SizeUInt; flags: LongInt; out plain, recipe: TBytes;
      out consumed, errPos: SizeUInt): LongInt;
    { plain and a recipe of Analyze's -> the stream. maxOut caps it (0: no
      cap). }
    function Rebuild(plain: PByte; plainSize: SizeUInt; rec: PByte; recSize: SizeUInt;
      maxOut: SizeUInt; out stream: TBytes; out errPos: SizeUInt): LongInt;
  end;

{ the version byte a recipe is written with }
function DeflRecipeVersion(const r: TDeflRecipe): Integer;

implementation

function DeflRecipeVersion(const r: TDeflRecipe): Integer;
begin
  Result := RecipeVersion(r);
  if Result < 3 then Result := 3;
end;

constructor TDeflCtx.Create(aMaxPlain: SizeUInt);
begin
  inherited Create;
  if (aMaxPlain = 0) or (aMaxPlain > SizeUInt(DEFL_MAX_PLAIN_DEFAULT)) then maxPlain := DEFL_MAX_PLAIN_DEFAULT
  else maxPlain := aMaxPlain;
end;

function Same(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

{ a zlib header but for FDICT (a preset dictionary: not taken) }
function IsFdictHeader(src: PByte; n: SizeUInt): Boolean;
begin
  Result := (n >= 2) and ((src[0] and $0F) = 8) and ((src[0] shr 4) <= 7) and
            ((src[1] and $20) <> 0) and (((LongWord(src[0]) shl 8) or src[1]) mod 31 = 0);
end;

function TDeflCtx.Analyze(src: PByte; n: SizeUInt; flags: LongInt; out plain, recipe: TBytes;
  out consumed, errPos: SizeUInt): LongInt;
var a, back, rb: TBytes; z: TZStream; res: TZResult; r: TDeflRecipe; framing: TDeflFraming;
    level: Integer; found: Boolean;
begin
  plain := nil; recipe := nil; consumed := 0; errPos := 0;
  r := Default(TDeflRecipe); back := nil;
  if (flags and not DEFL_FLAGS_KNOWN) <> 0 then Exit(DC_ARG);
  case flags and 3 of
    DEFL_RAW: framing := dfRaw;
    DEFL_ZLIB: framing := dfZlib;
    DEFL_AUTO: framing := dfAuto;
  else Exit(DC_ARG);
  end;
  level := (flags shr DEFL_LEVEL_SHIFT) and 3;
  if level = 0 then level := LEVEL_DEFAULT;
  if n = 0 then Exit(DC_DATA);
  { a preset dictionary: the stream needs bytes it does not hold }
  if (framing <> dfRaw) and IsFdictHeader(src, n) then Exit(DC_NOT_TAKEN);
  SetLength(a, n);
  Move(src^, a[0], n);
  res := Parse(a, framing, maxPlain, z);
  if res.err = zeTooLarge then Exit(DC_MEMORY);
  if not res.Ok then begin
    errPos := res.pos;
    Exit(DC_DATA);
  end;
  { what follows is the caller's }
  consumed := n - SizeUInt(Length(z.tail));
  if Length(z.tail) > 0 then begin
    SetLength(a, consumed);
    z.tail := nil;
  end;
  found := False;
  { the last stream's recipe, on this one's bytes and framing }
  if havePrev then begin
    r := prev;
    r.raw := z.raw; r.adlerOk := z.adlerOk; r.header := z.header;
    r.endPad := z.endPad; r.tail := nil;
    found := ppapreflate.Rebuild(z.plain, r, back, 1, @scratch) and Same(back, a);
    if found then Inc(hits);
  end;
  if not found then begin
    if FindRecipe(a, z, r, RECIPE_KIND_LAST, 1, ENC_LAST, ZOP_MAX_BY_LEVEL[level]) <> dsOk then
      Exit(DC_NOT_TAKEN);
    havePrev := (r.kind = RECIPE_ZLIB) or
      ((r.kind = RECIPE_ENCODER) and (r.encoder in [ENC_MINIZ, ENC_LIBDEFLATE]));
    if havePrev then prev := r;
  end;
  rb := RecipeBytes(r);
  SetLength(recipe, Length(rb) + 1);
  recipe[0] := DeflRecipeVersion(r);
  Move(rb[0], recipe[1], Length(rb));
  plain := z.plain;
  Result := DC_OK;
end;

function TDeflCtx.Rebuild(plain: PByte; plainSize: SizeUInt; rec: PByte; recSize: SizeUInt;
  maxOut: SizeUInt; out stream: TBytes; out errPos: SizeUInt): LongInt;
var b, p: TBytes; pos: SizeInt; r: TDeflRecipe;
begin
  stream := nil; errPos := 0;
  if recSize = 0 then Exit(DC_DATA);
  if rec[0] > STREAM_VERSION then Exit(DC_VERSION);
  if rec[0] < 3 then Exit(DC_DATA);
  SetLength(b, recSize);
  Move(rec^, b[0], recSize);
  pos := 1;
  if ReadRecipe(b, pos, plainSize, 0, r) <> rrOk then begin
    errPos := 1;
    Exit(DC_DATA);
  end;
  if (SizeUInt(pos) <> recSize) or (DeflRecipeVersion(r) <> rec[0]) then begin
    errPos := pos;
    Exit(DC_DATA);
  end;
  SetLength(p, plainSize);
  if plainSize > 0 then Move(plain^, p[0], plainSize);
  if not ppapreflate.Rebuild(p, r, stream, 1, @scratch) then begin
    errPos := 1;
    Exit(DC_DATA);
  end;
  if (maxOut > 0) and (SizeUInt(Length(stream)) > maxOut) then begin
    stream := nil;
    Exit(DC_MEMORY);
  end;
  Result := DC_OK;
end;

end.
