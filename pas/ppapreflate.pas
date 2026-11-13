{ Layer 2 as one stream's API: a deflate stream (zlib-framed or bare) ->
  the bytes it holds and a recipe, and back to the SAME bits. Nothing here
  knows of PNG: the codec (ppacodec) uses it for each image stream, and PDA
  (documents) will use it for the deflate streams of PDFs and ZIPs.

  A recipe is what the bytes alone do not say:
    - the framing: bare deflate or a zlib header (its 2 bytes as written),
      whether the 4 bytes after the data are their Adler-32, the bits after
      the last block (endPad), and whatever follows (tail; the Adler-32 is
      there when it is not the right one);
    - how the deflate data is made from the bytes. Kind 0 (RECIPE_ZLIB), the
      only one so far: zlib's parameters (level, strategy, memLevel,
      windowBits), whose choices (ppazlib), written (ppadeflate.Encode),
      are the stream bit for bit.
  Later kinds (flushes, other encoders, a predictor and its corrections:
  PPA 0.3.0's "own preflate") add to the recipe; a kind-0 recipe is written
  exactly as codec stream version 2 writes an image stream's (WriteRecipeV2),
  so moving the codec here changed none of its streams.

  Analyze verifies: it gives a recipe only when Rebuild of it gives the
  stream back, bit for bit. Rebuild checks the recipe first and is False
  on one it cannot use; it raises only when memory runs out. }
unit ppapreflate;

{$I ppa.inc}
{$ifopt R-}{$fatal ppapreflate: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppapreflate: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, ppadeflate, ppazlib;

const
  { the recipe kinds: 0, zlib's parameters give the stream exactly }
  RECIPE_ZLIB = 0;

type
  { how the stream is framed: bare deflate, zlib, or zlib when its first two
    bytes are a zlib header deflate can follow (ppadeflate.IsZlibHeader),
    bare otherwise }
  TDeflFraming = (dfRaw, dfZlib, dfAuto);

  { what Analyze made of a stream: a recipe; not a deflate stream (or more
    than maxPlain bytes); a deflate stream no recipe kind gives back }
  TDeflStatus = (dsOk, dsNotDeflate, dsNotTaken);

  TDeflRecipe = record
    kind: Integer;                   { RECIPE_ZLIB }
    prm: TZlibParams;                { kind 0: zlib's parameters }
    { the framing, as ppadeflate.TZStream has it }
    raw: Boolean;
    adlerOk: Boolean;
    header: array[0..1] of Byte;
    endPad: Byte;
    tail: TBytes;
  end;

  { why ReadRecipeV2 refused: cut short or a field out of range; zlib
    parameters out of range }
  TRecipeRead = (rrOk, rrBad, rrBadParams);

{ The stream a -> its blocks, tokens and bytes (ppadeflate.Decode), framed
  as framing says. maxPlain caps the bytes it may hold. Never raises on any
  input. }
function Parse(const a: TBytes; framing: TDeflFraming; maxPlain: SizeInt; out z: TZStream): TZResult;

{ The recipe of a stream already parsed (z, from a): dsOk when one gives a
  back bit for bit (checked), dsNotTaken otherwise. }
function FindRecipe(const a: TBytes; const z: TZStream; out recipe: TDeflRecipe): TDeflStatus;

{ Parse and FindRecipe: a -> the bytes it holds and its recipe. }
function Analyze(const a: TBytes; framing: TDeflFraming; maxPlain: SizeInt; out plain: TBytes;
  out recipe: TDeflRecipe): TDeflStatus;

{ Whether a recipe is one Rebuild can use: a known kind, its parameters in
  range. }
function RecipeValid(const recipe: TDeflRecipe): Boolean;

{ The bytes and their recipe -> the stream. threads: one stream's rebuild
  cut into segments on as many (ppazlib's parallel rebuild; the same bits
  whatever the threads). False, and no stream, on a recipe RecipeValid
  refuses. }
function Rebuild(const plain: TBytes; const recipe: TDeflRecipe; out stream: TBytes; threads: Integer = 1): Boolean;

{ A kind-0 recipe as codec stream version 2 writes an image stream's
  deflate part: level, strategy, memLevel, windowBits, a byte of flags (1:
  raw, 2: adlerOk), the 2 header bytes, endPad, the tail's length (a
  varint, 7 bits a byte, low first) and the tail. }
function RecipeBytesV2(const recipe: TDeflRecipe): TBytes;
{ The same read back from b at pos (moved past it). maxTail caps the tail's
  length. Never raises; on rrBad or rrBadParams, pos and recipe are left
  anywhere. }
function ReadRecipeV2(const b: TBytes; var pos: SizeInt; maxTail: QWord; out recipe: TDeflRecipe): TRecipeRead;

implementation

function Parse(const a: TBytes; framing: TDeflFraming; maxPlain: SizeInt; out z: TZStream): TZResult;
var raw: Boolean;
begin
  case framing of
    dfRaw: raw := True;
    dfZlib: raw := False;
  else raw := not IsZlibHeader(a);
  end;
  Result := ppadeflate.Decode(a, raw, maxPlain, z);
end;

{ the framing of z into r }
procedure TakeFraming(const z: TZStream; var r: TDeflRecipe);
begin
  r.raw := z.raw; r.adlerOk := z.adlerOk; r.header := z.header;
  r.endPad := z.endPad; r.tail := z.tail;
end;

{ the recipe's framing onto the choices e }
procedure PutFraming(const r: TDeflRecipe; var e: TZStream);
begin
  e.raw := r.raw; e.adlerOk := r.adlerOk; e.header := r.header;
  e.endPad := r.endPad; e.tail := r.tail;
end;

function FindRecipe(const a: TBytes; const z: TZStream; out recipe: TDeflRecipe): TDeflStatus;
var e: TZStream; back: TBytes;
begin
  Result := dsNotTaken;
  recipe := Default(TDeflRecipe);
  recipe.kind := RECIPE_ZLIB;
  { the choices zlib makes with them (all of them: the search compared
    every block), written, must be the stream }
  if not FindZlibParams(z, recipe.prm, e) then Exit;
  TakeFraming(z, recipe);
  PutFraming(recipe, e);
  back := Encode(e);
  if (Length(back) <> Length(a)) or (Length(a) = 0) or not CompareMem(@back[0], @a[0], Length(a)) then Exit;
  Result := dsOk;
end;

function Analyze(const a: TBytes; framing: TDeflFraming; maxPlain: SizeInt; out plain: TBytes;
  out recipe: TDeflRecipe): TDeflStatus;
var z: TZStream;
begin
  plain := nil;
  recipe := Default(TDeflRecipe);
  if (Length(a) = 0) or not Parse(a, framing, maxPlain, z).Ok then Exit(dsNotDeflate);
  Result := FindRecipe(a, z, recipe);
  if Result = dsOk then plain := z.plain;
end;

function RecipeValid(const recipe: TDeflRecipe): Boolean;
begin
  with recipe.prm do
    Result := (recipe.kind = RECIPE_ZLIB) and (level >= 1) and (level <= 9) and
      (strategy >= Z_DEFAULT_STRATEGY) and (strategy <= Z_FIXED) and
      (memLevel >= 1) and (memLevel <= 9) and (wbits >= 8) and (wbits <= 15);
end;

function Rebuild(const plain: TBytes; const recipe: TDeflRecipe; out stream: TBytes; threads: Integer): Boolean;
var e: TZStream;
begin
  stream := nil;
  if not RecipeValid(recipe) then Exit(False);
  ZlibChoices(plain, recipe.prm, nil, e, threads);
  PutFraming(recipe, e);
  stream := Encode(e);
  Result := True;
end;

{ ---------------------------------------------------------------- codec stream version 2's fields }

function RecipeBytesV2(const recipe: TDeflRecipe): TBytes;
var n, i: SizeInt; x: QWord;

  procedure Put(v: Byte);
  begin
    if n = Length(Result) then SetLength(Result, 2 * n + 16);
    Result[n] := v; Inc(n);
  end;

begin
  Result := nil; n := 0;
  with recipe do begin
    Put(prm.level); Put(prm.strategy); Put(prm.memLevel); Put(prm.wbits);
    Put(Ord(raw) or (Ord(adlerOk) shl 1));
    Put(header[0]); Put(header[1]); Put(endPad);
    x := Length(tail);
    while x >= 128 do begin Put(Byte(x and 127) or 128); x := x shr 7; end;
    Put(Byte(x));
    for i := 0 to High(tail) do Put(tail[i]);
  end;
  SetLength(Result, n);
end;

function ReadRecipeV2(const b: TBytes; var pos: SizeInt; maxTail: QWord; out recipe: TDeflRecipe): TRecipeRead;
var ok: Boolean; flags: Byte; len: QWord;

  { a byte; past the end, 0 and ok False (as the codec's reader) }
  function Get: Byte;
  begin
    if (not ok) or (pos >= Length(b)) then begin ok := False; Exit(0); end;
    Result := b[pos]; Inc(pos);
  end;

  { a varint up to max; anything above, or cut short, sets ok False }
  function GetVar(max: QWord): QWord;
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

begin
  ok := True;
  recipe := Default(TDeflRecipe);
  recipe.kind := RECIPE_ZLIB;
  recipe.prm.level := Get; recipe.prm.strategy := Get; recipe.prm.memLevel := Get; recipe.prm.wbits := Get;
  { as version 2 read them: bytes cut short read as 0, a level out of range }
  if not RecipeValid(recipe) then Exit(rrBadParams);
  flags := Get;
  if flags > 3 then Exit(rrBad);
  recipe.raw := (flags and 1) <> 0;
  recipe.adlerOk := (flags and 2) <> 0;
  recipe.header[0] := Get; recipe.header[1] := Get; recipe.endPad := Get;
  len := GetVar(maxTail);
  if not ok or (len > QWord(Length(b) - pos)) then Exit(rrBad);
  recipe.tail := Copy(b, pos, len);
  Inc(pos, len);
  Result := rrOk;
end;

end.
