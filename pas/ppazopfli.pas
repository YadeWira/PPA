{ zopfli's deflate, exact: the stream ZopfliDeflate writes for a stream's
  bytes with given options (iterations, block splitting), from zopfli's
  own code (vendor/zopfli, zopfli 1.0.3, unmodified, built by ppazopc.c).
  Recipe kind 2, encoder 3 (ppapreflate) names zopfli, its variant and its
  options. zopflipng writes with it (15 iterations for images under
  200,000 bytes, 5 over; 60 and 20 with -m), advpng -z4 too (5).

  Variant ZOPV_103: zopfli 1.0.3 (and its master branch, the same deflate)
  with PPA's correctly rounded log(): the same bits on every platform
  (ppazopc.c). Variant ZOPV_RS08: the Rust port, the zopfli crate 0.8
  (oxipng 10's --zopfli: 15 iterations unless --zi says), whose optimal
  pass differs from 1.0.3's in three places (ppazopc.c), with a correctly
  rounded log2; since codec stream version 6. The compressor is C only: zopfli itself is the reference
  (PPA_NOC does not change it). One call with all the bytes (ZopfliDeflate,
  btype 2, final), as zopflipng and zopfli's containers make it.

  zopfli is slow: rebuilding costs a zopfli run (about 0.2 MB/s of bytes
  at zopflipng's settings), so the codec takes this recipe for small
  images only at the default level, and for all at -3 (ppacodec). }
unit ppazopfli;

{$I ppa.inc}
{$ifopt R-}{$fatal ppazopfli: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppazopfli: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, ppadeflate;

const
  { the variants: zopfli 1.0.3 with a correctly rounded log; the Rust port
    (the zopfli crate 0.8, which oxipng's --zopfli links: its optimal pass
    differs in three places, ppazopc.c), with a correctly rounded log2;
    since codec stream version 6 }
  ZOPV_103 = 0;
  ZOPV_RS08 = 1;
  ZOPV_LAST = ZOPV_RS08;
  { the options' range a recipe may hold: iterations (a recipe of more
    would take too long to rebuild to be a stream anyone wrote) and the
    most blocks a split makes (zopfli's default 15; 0, no limit) }
  ZOP_ITER_MAX = 1000;
  ZOP_BSMAX_MAX = 1000;
  { flags: block splitting (zopfli's default), splitting last (instead of
    first; zopfli's option, not its default) }
  ZOPF_SPLIT = 1;
  ZOPF_SPLIT_LAST = 2;
  ZOPF_ALL = ZOPF_SPLIT or ZOPF_SPLIT_LAST;

type
  TZopParams = record
    variant: Integer;     { 0..ZOPV_LAST }
    iterations: Integer;  { 1..ZOP_ITER_MAX }
    flags: Integer;       { ZOPF_* }
    bsMax: Integer;       { 0..ZOP_BSMAX_MAX }
  end;

function ZopValid(const p: TZopParams): Boolean;

{ plain -> the raw deflate stream zopfli writes with p; False on p
  ZopValid refuses, no memory, or (32-bit x86) a processor without SSE2 }
function ZopDeflate(const plain: TBytes; const p: TZopParams; out raw: TBytes): Boolean;

{ The same as choices (blocks, tokens, plain: raw deflate, no framing),
  for ppadeflate.Encode with a recipe's framing. }
function ZopChoices(const plain: TBytes; const p: TZopParams; out e: TZStream): Boolean;

{ The options whose stream is z's deflate data (a: z's stream, as parsed),
  for at most maxPlain bytes (0: none). zopfli splits before it iterates
  and optimises each piece on its own, so a candidate number of
  iterations is tried on the first piece alone, against the stream's first
  tokens; the one that gives them is run whole and compared. First on the
  stream's first block (zopfli's first piece when it kept its first split:
  cheap): every candidate when one of its first dynamic blocks has the
  code lengths zopfli itself gives its tokens (its GetDynamicLengths),
  else zopflipng's two (15 or 5, by size, and the other); then, with
  zopfli's trees, on the first piece of zopfli's own split. Splitting
  first with 15 blocks at most, its default. Each candidate in each
  variant up to maxVariant (codec stream version 5 holds variant 0 only).
  choices: ZopChoices of it. }
function FindZopParams(const a: TBytes; const z: TZStream; maxPlain: SizeInt; out p: TZopParams;
  out choices: TZStream; maxVariant: Integer = ZOPV_LAST): Boolean;

const
  { the first dynamic blocks one of which must have zopfli's trees }
  ZOP_CHECK_BLOCKS = 4;
  { zopflipng's size for its "large" iterations }
  ZOP_LARGE = 200000;

implementation

uses Math;

{$L ppazopc.o}

type
  TAllocFn = function(n: SizeUInt): Pointer; cdecl;
  TReleaseFn = procedure(p: Pointer); cdecl;
  PPointer = ^Pointer;
  TSlotFn = function: PPointer; cdecl;

procedure ppa_zop_init(slot: TSlotFn); cdecl; external name 'ppa_zop_init';
function ppa_zop_deflate(variant, iterations, split, splitLast, bsMax: LongInt; input: PByte; n: SizeUInt;
  output: PByte; cap: SizeUInt; alloc: TAllocFn; release: TReleaseFn): SizeUInt; cdecl; external name 'ppa_zop_deflate';
function ppa_zop_split(bsMax: LongInt; input: PByte; n: SizeUInt; pts: PSizeUInt; max: SizeUInt;
  alloc: TAllocFn; release: TReleaseFn): SizeUInt; cdecl; external name 'ppa_zop_split';
function ppa_zop_piece(variant, iterations: LongInt; input: PByte; start, stop: SizeUInt; litlens, dists: PWord;
  cap: SizeUInt; alloc: TAllocFn; release: TReleaseFn): SizeUInt; cdecl; external name 'ppa_zop_piece';
function ppa_zop_lengths(litlens, dists: PWord; n: SizeUInt; llLengths, dLengths: PLongWord;
  alloc: TAllocFn; release: TReleaseFn): LongInt; cdecl; external name 'ppa_zop_lengths';

threadvar
  { the running zopfli call's context (ppazopc.c keeps its memory there) }
  ZopCtx: Pointer;

function ZopSlot: PPointer; cdecl;
begin
  Result := @ZopCtx;
end;

{ zopfli's memory: FreePascal's heap (thread-safe), nil when there is none }
function ZopAlloc(n: SizeUInt): Pointer; cdecl;
begin
  try
    Result := GetMem(n);
  except
    Result := nil;
  end;
end;

procedure ZopRelease(p: Pointer); cdecl;
begin
  FreeMem(p);
end;

function ZopValid(const p: TZopParams): Boolean;
begin
  Result := (p.variant >= 0) and (p.variant <= ZOPV_LAST) and (p.iterations >= 1) and
    (p.iterations <= ZOP_ITER_MAX) and (p.flags and not ZOPF_ALL = 0) and (p.bsMax >= 0) and
    (p.bsMax <= ZOP_BSMAX_MAX);
end;

function ZopDeflate(const plain: TBytes; const p: TZopParams; out raw: TBytes): Boolean;
var cap, n: SizeUInt; src: PByte; empty: Byte;
begin
  raw := nil;
  if not ZopValid(p) then Exit(False);
  { stored blocks at worst: 5 bytes a 65,535 }
  cap := SizeUInt(Length(plain)) + SizeUInt(Length(plain)) div 16 + 4096;
  SetLength(raw, cap);
  empty := 0;
  if Length(plain) > 0 then src := @plain[0] else src := @empty;
  n := ppa_zop_deflate(p.variant, p.iterations, Ord(p.flags and ZOPF_SPLIT <> 0), Ord(p.flags and ZOPF_SPLIT_LAST <> 0),
    p.bsMax, src, Length(plain), @raw[0], cap, @ZopAlloc, @ZopRelease);
  if n = 0 then begin raw := nil; Exit(False); end;
  SetLength(raw, n);
  Result := True;
end;

function ZopChoices(const plain: TBytes; const p: TZopParams; out e: TZStream): Boolean;
var raw: TBytes;
begin
  e := Default(TZStream);
  if not ZopDeflate(plain, p, raw) then Exit(False);
  Result := Decode(raw, True, Length(plain), e).Ok and (Length(e.plain) = Length(plain)) and
    ((Length(plain) = 0) or CompareMem(@e.plain[0], @plain[0], Length(plain)));
end;

{ Whether dynamic block bi of z has the code lengths zopfli itself gives
  its tokens (ppa_zop_lengths: zopfli's GetDynamicLengths, ties as it
  breaks them) }
function ZopTrees(const z: TZStream; bi: SizeInt): Boolean;
var ll, dd: array of Word; t, k: SizeInt; lens: array[0..287] of LongWord; dl: array[0..31] of LongWord;
begin
  Result := False;
  with z.blocks[bi] do begin
    if (btype <> btDynamic) or (nTokens = 0) then Exit;
    SetLength(ll, nTokens); SetLength(dd, nTokens);
    for t := 0 to nTokens - 1 do begin
      k := firstToken + t;
      if z.tokLen[k] = LEN_258_AS_284 then Exit;
      if z.tokLen[k] = 0 then begin ll[t] := z.tokVal[k]; dd[t] := 0; end
      else begin ll[t] := z.tokLen[k]; dd[t] := z.tokVal[k]; end;
    end;
    if ppa_zop_lengths(@ll[0], @dd[0], nTokens, @lens[0], @dl[0], @ZopAlloc, @ZopRelease) = 0 then Exit;
    for k := 0 to 287 do if litLen[k] <> lens[k] then Exit;
    for k := 0 to 31 do if distLen[k] <> dl[k] then Exit;
  end;
  Result := True;
end;

{ z's deflate data in a: where it starts and how many bytes it takes }
procedure DeflateSpan(const a: TBytes; const z: TZStream; out first, len: SizeInt);
begin
  if z.raw then first := 0 else first := 2;
  len := Length(a) - first - Length(z.tail);
  if z.adlerOk then Dec(len, 4);
end;

function FindZopParams(const a: TBytes; const z: TZStream; maxPlain: SizeInt; out p: TZopParams;
  out choices: TZStream; maxVariant: Integer): Boolean;
const
  TRIES_SMALL: array[0..8] of Integer = (15, 60, 5, 20, 1, 10, 30, 50, 100);
  TRIES_LARGE: array[0..8] of Integer = (5, 20, 15, 60, 1, 10, 30, 50, 100);
var
  bi, seen, first, len: SizeInt; n, np, stop, t: SizeUInt;
  pts: array[0..63] of SizeUInt; trees, tried: Boolean;

  { the stream's tokens that cover plain[0..stop): how many, 0 if they do not end there }
  function TokensTo(stop: SizeUInt): SizeUInt;
  var at: SizeUInt;
  begin
    Result := 0; at := 0;
    while (at < stop) and (Result < SizeUInt(Length(z.tokLen))) do begin
      if z.tokLen[Result] = 0 then Inc(at)
      else if z.tokLen[Result] = LEN_258_AS_284 then Exit(0)
      else Inc(at, z.tokLen[Result]);
      Inc(Result);
    end;
    if at <> stop then Result := 0;
  end;

  { each candidate number of iterations on plain[0..stop) against the
    stream's first tokens; the one that gives them, run whole and compared }
  function TryPiece(stop: SizeUInt; tries: Integer): Boolean;
  var cnt, k, at: SizeUInt; ll, dd: array of Word; it, v: Integer; same: Boolean; raw: TBytes;
  begin
    Result := False;
    cnt := TokensTo(stop);
    if cnt = 0 then Exit;
    SetLength(ll, cnt + 1); SetLength(dd, cnt + 1);
    for k := 0 to tries - 1 do
    for v := 0 to maxVariant do begin
      if n < ZOP_LARGE then it := TRIES_SMALL[k] else it := TRIES_LARGE[k];
      p.variant := v;
      if ppa_zop_piece(v, it, @z.plain[0], 0, stop, @ll[0], @dd[0], cnt, @ZopAlloc, @ZopRelease) <> cnt then Continue;
      same := True;
      for at := 0 to cnt - 1 do
        if dd[at] = 0 then begin
          if (z.tokLen[at] <> 0) or (z.tokVal[at] <> ll[at]) then begin same := False; Break; end;
        end else if (z.tokLen[at] <> ll[at]) or (z.tokVal[at] <> dd[at]) then begin same := False; Break; end;
      if not same then Continue;
      p.iterations := it;
      if not ZopDeflate(z.plain, p, raw) or (Length(raw) <> len) then Continue;
      if (len > 1) and not CompareMem(@raw[0], @a[first], len - 1) then Continue;
      if ZopChoices(z.plain, p, choices) then Exit(True);
    end;
  end;

begin
  Result := False;
  p := Default(TZopParams);
  choices := Default(TZStream);
  n := Length(z.plain);
  if (n = 0) or (SizeInt(n) > maxPlain) then Exit;
  DeflateSpan(a, z, first, len);
  if len <= 0 then Exit;
  p.variant := ZOPV_103; p.flags := ZOPF_SPLIT; p.bsMax := 15;
  { do the first dynamic blocks look zopfli's? }
  seen := 0; trees := False;
  for bi := 0 to High(z.blocks) do
    if z.blocks[bi].btype = btDynamic then begin
      if ZopTrees(z, bi) then begin trees := True; Break; end;
      Inc(seen);
      if seen = ZOP_CHECK_BLOCKS then Break;
    end;
  { first, cheap: zopfli's first piece is the stream's first block when it
    kept its first split (its blocks are grouped again only when that
    makes the stream smaller) }
  tried := False;
  if (Length(z.blocks) > 0) and (z.blocks[0].btype <> btStored) then begin
    stop := 0;
    for t := z.blocks[0].firstToken to z.blocks[0].firstToken + z.blocks[0].nTokens - 1 do
      if z.tokLen[t] = 0 then Inc(stop) else Inc(stop, z.tokLen[t]);
    if (stop > 0) and (stop <= 1000000) then begin
      tried := True;
      if TryPiece(stop, IfThen(trees, Length(TRIES_SMALL), 2)) then Exit(True);
    end;
  end;
  { then zopfli's own split (a fraction of a run), for a stream whose
    first dynamic blocks look zopfli's }
  if not trees then begin p := Default(TZopParams); Exit; end;
  np := ppa_zop_split(15, @z.plain[0], n, @pts[0], Length(pts), @ZopAlloc, @ZopRelease);
  if np = SizeUInt(-1) then begin p := Default(TZopParams); Exit; end;
  if np > 0 then stop := pts[0] else stop := n;
  if stop > 1000000 then stop := 1000000;
  if stop > n then stop := n;
  if (not tried or (stop <> 0)) and TryPiece(stop, Length(TRIES_SMALL)) then Exit(True);
  p := Default(TZopParams);
end;

initialization
  ppa_zop_init(@ZopSlot);
end.
