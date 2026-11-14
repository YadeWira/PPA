{ Recipe kind 3 (doc/PREFLATE.md): a zlib-like predictor, and the
  corrections that make what it predicts the stream, bit for bit.

  The predictor follows the stream's own parse (a forced parse). At each
  token it proposes one from the bytes alone, as zlib's deflate_slow (or
  deflate_fast) would from the same place: hash chains over every position,
  longest_match with a chain, nice, good and lazy of the recipe's, the
  lazy match one position ahead; then the stream's real token is taken,
  and the predictor goes on from where that token ends. Only where the two
  differ is something coded. Every other choice an encoder makes is coded
  the same way, against a guess: where a block ends (zlib's symbol count),
  its type (stored first, then fixed against dynamic by zlib's sizes), a
  stored block's length and pad bits, whether it is the last, a dynamic
  block's code lengths (zlib's trees over the block's own symbol counts),
  HLIT, HDIST, how the lengths are run-length coded (zlib's send_tree on
  each tree or on both at once, or each symbol explicitly), the code-length
  code and HCLEN, a 258 written as 284. Every field of ppadeflate's
  TDeflateBlock and every token can be coded whatever it is (a verbatim
  escape where a guess has no room: a match's distance outside the chains,
  any code length), so every stream Decode reads has a kind-3 recipe.

  The corrections are binary decisions and small numbers, coded with
  ppaarith's arithmetic coder and adaptive bits of this unit's own, one
  model for each kind of decision and its context. Encoder and decoder run
  the same driver (Drive): the encoder gives it the stream's choices and
  it codes them, the decoder gets them back from it; the rebuild writes
  each block as soon as it has it (ppadeflate's TDeflWriter), so it holds
  one block's tokens, never the stream's.

  A recipe decodes only with the predictor and models that made it: they
  are frozen by PRED_VERSION (doc/PREFLATE.md, the versioning rule).

  The search and the rank walk (the hot loops) are also in C (ppacorrc.c);
  this is their reference, and both give the same corrections. Our own
  code: the idea of a forced parse and of coding a distance as its rank
  among the candidates is preflate's (Dirk Steinke), none of its code. }
unit ppacorr;

{$I ppa.inc}
{ PPA_FAST: the release build, without range and overflow checks. Every
  value a recipe gives is checked before it indexes anything or reaches
  the writer; the checked build is the reference. }
{$ifdef PPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal ppacorr: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal ppacorr: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, ppadeflate;

const
  { the predictor and the models (doc/PREFLATE.md): a recipe of another
    version is refused }
  PRED_VERSION = 1;
  { TPredParams.flags: deflate_slow's filters: a match of 5 or fewer dropped
    (Z_FILTERED); a match of 3 further than 4096 dropped (TOO_FAR) }
  PF_FILTERED = 1;
  PF_TOOFAR = 2;
  PF_ALL = 3;
  PRED_MAX_CHAIN = 4096;
  PRED_MAX_SYMEND = 1 shl 20;

type
  TPredParams = record
    predVersion: Integer; { PRED_VERSION }
    chain: Integer;       { 1..PRED_MAX_CHAIN: candidates a search may look at }
    nice: Integer;        { 3..258: a match this long ends the search }
    lazy: Integer;        { 0: no lazy match (deflate_fast); 3..258: max_lazy }
    good: Integer;        { 3..258: chain / 4 when the match to beat is this long }
    hbits: Integer;       { 8..16: the hash's bits (zlib: memLevel + 7) }
    maxDist: Integer;     { 1..32768: the farthest a predicted match reaches }
    flags: Integer;       { PF_* }
    symEnd: Integer;      { 0..PRED_MAX_SYMEND: a block's predicted symbols (0: none) }
  end;

{ Whether p is one CorrRebuild can use. }
function PredValid(const p: TPredParams): Boolean;

{ The corrections of z's blocks and tokens against the predictor p. With
  stopTokens >= 0, only up to token stopTokens (or plain byte stopTokens *
  16): the parameter search's measure, not a recipe. }
function CorrEncode(const z: TZStream; const p: TPredParams; stopTokens: SizeInt = -1): TBytes;

{ plain and its corrections -> the stream, framed as frame says (raw,
  header, adlerOk, endPad, tail; its blocks and tokens are not read).
  False, and no stream, on corrections that do not give a stream within
  the caps (a block count, distances, lengths, pad bits); never raises but
  for memory. }
function CorrRebuild(const plain: TBytes; const p: TPredParams; const corr: TBytes;
  const frame: TZStream; out stream: TBytes): Boolean;

{ The parameters whose corrections of z's first blocks are the smallest. }
procedure CorrChooseParams(const z: TZStream; out p: TPredParams);

var
  { the search and the rank walk in C (ppacorrc.c); False: in Pascal, the
    reference. PPA_NOC=1 in the environment makes it False }
  UseCorrC: Boolean = True;

implementation

uses ppaarith, ppazlib;

{$L ppacorrc.o}

const
  MIN_MATCH = 3;
  MAX_MATCH = 258;
  TOO_FAR = 4096;
  WINDOW = 32768;
  { prev[] covers twice the window: a position's link is kept until the
    one 65536 later is inserted, and nothing past the next two positions
    is ever inserted early }
  PREV_SIZE = 65536;
  PREV_MASK = PREV_SIZE - 1;
  { candidates the rank walk looks at, at most; past them a distance is
    escaped (written as is) }
  RANK_HOPS = 4096;
  RANK_ESC = 13;          { the escape's bucket: ranks are buckets 0..12 }
  { blocks a rebuild makes, at most: 2 a byte and some (zlib's flushes can
    make two empty blocks at a position) }
  BLOCKS_MORE = 4096;
  NIL_POS = -1;

  LEN_BASE: array[257..285] of Word = (
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258);
  LEN_EXTRA: array[257..285] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0);
  DIST_BASE: array[0..29] of Word = (
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577);
  DIST_EXTRA: array[0..29] of Byte = (
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13);
  CLEN_ORDER: array[0..18] of Byte = (
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);

var
  LenSym: array[3..258] of Word;
  DistSym: array[1..32768] of Byte;

{ ---------------------------------------------------------------- the predictor's state }

type
  { ppacorrc.c's pcstate_t, field for field }
  TPredState = record
    plain: PByte; n: SizeInt;
    head: PLongInt; prev: PLongInt;   { head: 2^hbits; prev: PREV_SIZE, by position and PREV_MASK }
    ins: SizeInt;                     { the positions before ins are inserted }
    hmask, hshift: SizeInt;
    chain, nice, good, maxDist: SizeInt;
    hops: SizeInt;
    { the C search's own links (unused here): each position's order in its
      hash chain, each hash's count, the chains of 4 bytes' hash }
    ord, hcnt, head4, link4: PLongInt;
  end;

function pc_search(var s: TPredState; q, prevLen: SizeInt; out dist: SizeInt): SizeInt; cdecl; external name 'pc_search';
function pc_rank(var s: TPredState; q, len, target, wantRank: SizeInt): SizeInt; cdecl; external name 'pc_rank';

function Hash3(const s: TPredState; q: SizeInt): SizeInt; inline;
begin
  Result := (((SizeInt(s.plain[q]) shl s.hshift) xor s.plain[q + 1]) shl s.hshift xor s.plain[q + 2]) and s.hmask;
end;

{ every position up to k (those with 3 bytes) into the chains }
procedure InsertUpTo(var s: TPredState; k: SizeInt);
var h: SizeInt;
begin
  if k > s.n - MIN_MATCH then k := s.n - MIN_MATCH;
  while s.ins <= k do begin
    h := Hash3(s, s.ins);
    s.prev[s.ins and PREV_MASK] := s.head[h];
    s.head[h] := s.ins;
    Inc(s.ins);
  end;
end;

{ the newest position before q with q's hash (q + 3 <= n) }
function ChainStart(var s: TPredState; q: SizeInt): SizeInt;
begin
  if q < s.ins then Exit(s.prev[q and PREV_MASK]);
  InsertUpTo(s, q - 1);
  Result := s.head[Hash3(s, q)];
end;

{ zlib's longest_match at q from the newest position with q's hash: a
  match longer than prevLen (its length, dist its distance), or 0. Chains
  as zlib's: position 0 is never a candidate (NIL), candidates up to
  maxDist back, chain / 4 when prevLen >= good, nice capped to what is
  left }
function SearchPas(var s: TPredState; q, prevLen: SizeInt; out dist: SizeInt): SizeInt;
var cur, limit, chainLen, bestLen, nice, look, len, maxLen: SizeInt; pl: PByte;
begin
  Result := 0; dist := 0;
  look := s.n - q;
  if (look < MIN_MATCH) or (prevLen >= look) then Exit;
  cur := ChainStart(s, q);
  if (cur <= 0) or (q - cur > s.maxDist) then Exit;
  if q > s.maxDist then limit := q - s.maxDist else limit := 0;
  chainLen := s.chain;
  if prevLen >= s.good then chainLen := chainLen shr 2;
  if chainLen < 1 then chainLen := 1;
  nice := s.nice; if nice > look then nice := look;
  maxLen := MAX_MATCH; if maxLen > look then maxLen := look;
  bestLen := prevLen;
  pl := s.plain;
  repeat
    if (pl[cur + bestLen] = pl[q + bestLen]) and (pl[cur + bestLen - 1] = pl[q + bestLen - 1]) and
       (pl[cur] = pl[q]) and (pl[cur + 1] = pl[q + 1]) then begin
      len := 2;
      while (len < maxLen) and (pl[cur + len] = pl[q + len]) do Inc(len);
      if len > bestLen then begin
        bestLen := len; dist := q - cur;
        if len >= nice then Break;
      end;
    end;
    cur := s.prev[cur and PREV_MASK];
    Dec(chainLen);
  until (cur <= limit) or (chainLen = 0);
  if bestLen > prevLen then Result := bestLen else dist := 0;
end;

{ The rank walk: the candidates before q (its whole chain, up to WINDOW
  back, position 0 included, at most hops of them) whose match is at least
  len long, newest first. wantRank = 1: the distance of the one of rank
  target; 0: the rank of distance target. -1 when there is none. }
function RankPas(var s: TPredState; q, len, target, wantRank: SizeInt): SizeInt;
var cur, hops, nRank, k: SizeInt; pl: PByte;
begin
  Result := -1;
  if (len < MIN_MATCH) or (q + len > s.n) then Exit;
  cur := ChainStart(s, q);
  hops := 0; nRank := 0;
  pl := s.plain;
  while (cur >= 0) and (q - cur <= WINDOW) and (hops < s.hops) do begin
    if pl[cur + len - 1] = pl[q + len - 1] then begin
      k := 0;
      while (k < len) and (pl[cur + k] = pl[q + k]) do Inc(k);
      if k = len then begin
        if wantRank <> 0 then begin
          if nRank = target then Exit(q - cur);
        end else if q - cur = target then Exit(nRank);
        Inc(nRank);
      end;
    end;
    cur := s.prev[cur and PREV_MASK];
    Inc(hops);
  end;
end;

function Search(var s: TPredState; q, prevLen: SizeInt; out dist: SizeInt): SizeInt; inline;
begin
  if UseCorrC then Result := pc_search(s, q, prevLen, dist) else Result := SearchPas(s, q, prevLen, dist);
end;

function Rank(var s: TPredState; q, len, target, wantRank: SizeInt): SizeInt; inline;
begin
  if UseCorrC then Result := pc_rank(s, q, len, target, wantRank) else Result := RankPas(s, q, len, target, wantRank);
end;

{ ---------------------------------------------------------------- the models }

type
  { an adaptive bit: P(1) in 22 bits; fast at first (1/1.5, 1/2.5, ...),
    then at about 1/RATE_LIMIT }
  TPBit = record
    p: LongWord;
    n: Byte;
  end;

const
  P_ONE = 1 shl 22;
  RATE_LIMIT = 255;

var
  RATE: array[0..RATE_LIMIT] of LongWord;   { 65536 / (n + 1.5) }

type
  TModels = record
    stored: array[0..3] of TPBit;          { by the previous block's type (3: none) }
    stLenMax, padZero, final: TPBit;
    blockEnd: array[0..3] of TPBit;        { 0, 1 first token, 2 at symEnd, 3 at the previous block's count }
    dyn: array[0..1] of TPBit;             { by zlib's choice }
    hit: array[0..15] of TPBit;            { predicted length's bucket x the last token missed }
    isLit, sameLen: array[0..7] of TPBit;
    lenTree: array[0..7, 1..255] of TPBit;
    as284: TPBit;
    rankK: array[0..2, 0..RANK_ESC - 1] of TPBit;
    treeSame: array[0..1] of TPBit;
    lenSame: array[0..31] of TPBit;        { predicted length x symbol used }
    lenVal: array[0..15, 1..15] of TPBit;
    hlitSame, hdistSame, hclenSame: TPBit;
    sel0, sel1: array[0..2] of TPBit;      { by the previous block's }
    seqLit: array[0..23] of TPBit;
    seq16, seq18: TPBit;
    seqMax: array[16..18] of TPBit;
    clenSame: TPBit;
    clenS: array[0..7] of TPBit;
  end;

  { one run of the driver: encoding (the stream's choices given) or
    decoding (got back) }
  TCoder = record
    enc: Boolean;
    ae: TArithEncoder;
    ad: TArithDecoder;
    function Bit(var m: TPBit; b: Integer): Integer;
    function Direct(v: SizeInt; bits: Integer): SizeInt;
    { v in [0, 2^bits) through a binary tree of models t[1..2^bits - 1] }
    function Tree(var t: array of TPBit; bits: Integer; v: Integer): Integer;
  end;

procedure InitModels(var m: TModels);
var p: PByte; i: SizeInt;
begin
  { every TPBit at 1/2, none updated }
  p := @m;
  for i := 0 to SizeOf(m) div SizeOf(TPBit) - 1 do begin
    PLongWord(p + i * SizeOf(TPBit))^ := P_ONE div 2;
    (p + i * SizeOf(TPBit) + SizeOf(LongWord))^ := 0;
  end;
end;

function TCoder.Bit(var m: TPBit; b: Integer): Integer;
var pr: Integer;
begin
  pr := m.p shr 6;
  if pr < 1 then pr := 1 else if pr > 65535 then pr := 65535;
  if enc then begin
    ae.Encode(b, pr); Result := b;
  end else
    Result := ad.Decode(pr);
  if Result <> 0 then Inc(m.p, ((QWord(P_ONE) - m.p) * RATE[m.n]) shr 16)
  else Dec(m.p, (QWord(m.p) * RATE[m.n]) shr 16);
  if m.n < RATE_LIMIT then Inc(m.n);
end;

function TCoder.Direct(v: SizeInt; bits: Integer): SizeInt;
begin
  if bits = 0 then Exit(0);
  if enc then begin ae.Direct(Cardinal(v), bits); Result := v; end
  else Result := SizeInt(ad.Direct(bits));
end;

function TCoder.Tree(var t: array of TPBit; bits: Integer; v: Integer): Integer;
var node, k, b: Integer;
begin
  node := 1;
  for k := bits - 1 downto 0 do begin
    b := Bit(t[node - 1], (v shr k) and 1);
    node := 2 * node + b;
  end;
  Result := node - (1 shl bits);
end;

{ ---------------------------------------------------------------- the driver }

function LenBucket(l: SizeInt): Integer;
begin
  case l of
    0: Result := 0;
    3: Result := 1;
    4..5: Result := 2;
    6..8: Result := 3;
    9..16: Result := 4;
    17..64: Result := 5;
    65..257: Result := 6;
  else Result := 7;
  end;
end;

function PredValid(const p: TPredParams): Boolean;
begin
  Result := (p.predVersion = PRED_VERSION) and (p.chain >= 1) and (p.chain <= PRED_MAX_CHAIN) and
    (p.nice >= MIN_MATCH) and (p.nice <= MAX_MATCH) and
    ((p.lazy = 0) or ((p.lazy >= MIN_MATCH) and (p.lazy <= MAX_MATCH))) and
    (p.good >= MIN_MATCH) and (p.good <= MAX_MATCH) and (p.hbits >= 8) and (p.hbits <= 16) and
    (p.maxDist >= 1) and (p.maxDist <= WINDOW) and (p.flags >= 0) and (p.flags <= PF_ALL) and
    (p.symEnd >= 0) and (p.symEnd <= PRED_MAX_SYMEND);
end;

type
  TDriveOut = record
    { decoding: where the blocks go }
    w: TDeflWriter;
    frame: TZStream;     { the plain, the framing; tokens of the block in hand }
  end;

{ The one driver of encoding and decoding. Encoding: z is the stream
  (blocks, tokens, plain), its choices coded into c.ae; stopTokens as
  CorrEncode's. Decoding: z.plain is the plain, the blocks are written
  into o.w as they come. False: corrections that give no stream. }
function Drive(var c: TCoder; const z: TZStream; const prm: TPredParams; stopTokens: SizeInt;
  var o: TDriveOut): Boolean;
var
  m: TModels;
  s: TPredState;
  head, prev, ordA, hcnt, head4, link4: array of LongInt;
  plain: PByte;
  n, p, bi, nBlocks, maxBlocks, t, rt, nTokB, cap: SizeInt;
  rb, b: TDeflateBlock;
  prevType, lastTokens, lastMiss, lastSel, lastTreeSame: Integer;
  cachePos, cacheLen, cacheDist: SizeInt;
  lfreq: array[0..285] of Integer;
  dfreq: array[0..29] of Integer;
  isStored, isEnd, isDyn, fixedNoBigger, final: Boolean;
  maxLen, len, k: SizeInt;
  tokLen, tokVal: array of Word;   { decoding: the block's tokens }
  pb: TDeflateBlock;

  procedure Grow(need: SizeInt);
  begin
    if need > Length(tokLen) then begin
      cap := 2 * Length(tokLen) + 1024;
      if cap < need then cap := need;
      SetLength(tokLen, cap); SetLength(tokVal, cap);
    end;
  end;

  { the predicted token at p: pl 0 a literal, else a match (pl, pd) }
  procedure Predict(out pl, pd: SizeInt);
  var l1, d1, l2, d2: SizeInt;
  begin
    pl := 0; pd := 0;
    if cachePos = p then begin l1 := cacheLen; d1 := cacheDist; end
    else begin
      l1 := Search(s, p, MIN_MATCH - 1, d1);
      if (prm.lazy > 0) and (l1 > 0) and (l1 <= 5) and (((prm.flags and PF_FILTERED) <> 0) or
         ((l1 = MIN_MATCH) and (d1 > TOO_FAR) and ((prm.flags and PF_TOOFAR) <> 0))) then l1 := 0;
    end;
    cachePos := -1;
    if l1 < MIN_MATCH then Exit;
    if (prm.lazy = 0) or (l1 >= prm.lazy) then begin pl := l1; pd := d1; Exit; end;
    l2 := Search(s, p + 1, l1, d2);
    if (l2 > 0) and (l2 <= 5) and ((prm.flags and PF_FILTERED) <> 0) then l2 := 0;
    if l2 > l1 then begin
      cachePos := p + 1; cacheLen := l2; cacheDist := d2;
      Exit;   { a literal }
    end;
    pl := l1; pd := d1;
  end;

  { one token at p: coded against the prediction; decoding, into the
    block's tokens. False on one that cannot be }
  function DoToken(realLen, realVal: SizeInt): Boolean;
  var pl, pd, bucket, hit, rl, rd, as284, L, D, r, kk, mant, lb, rk: SizeInt;
  begin
    Result := False;
    Predict(pl, pd);
    bucket := LenBucket(pl);
    as284 := 0; rl := 0; rd := 0;
    if c.enc then begin
      rl := realLen; rd := realVal;
      if rl = LEN_258_AS_284 then begin rl := MAX_MATCH; as284 := 1; end;
    end;
    hit := c.Bit(m.hit[bucket * 2 + lastMiss], Ord((rl = pl) and ((pl = 0) or (rd = pd))));
    if hit <> 0 then begin
      L := pl; D := pd;
    end else begin
      L := -1; D := 0;
      if (pl > 0) and (c.Bit(m.isLit[bucket], Ord(rl = 0)) <> 0) then L := 0;
      if L <> 0 then begin
        { a match: its length, then its distance's rank among the
          candidates at least that long }
        if (pl > 0) and (c.Bit(m.sameLen[bucket], Ord(rl = pl)) <> 0) then L := pl
        else L := MIN_MATCH + c.Tree(m.lenTree[bucket], 8, rl - MIN_MATCH);
        if L > n - p then Exit;
        if L <= 8 then lb := 0 else if L <= 32 then lb := 1 else lb := 2;
        r := RANK_ESC; rk := -1;
        if c.enc then begin
          rk := Rank(s, p, L, rd, 0);
          if rk >= 0 then begin
            r := 0;
            while (SizeInt(2) shl r) <= rk + 1 do Inc(r);
          end;
        end;
        { the bucket, unary: bucket k holds ranks 2^k - 1 .. 2^(k+1) - 2 }
        kk := 0;
        while (kk < RANK_ESC) and (c.Bit(m.rankK[lb, kk], Ord(r = kk)) = 0) do Inc(kk);
        if kk = RANK_ESC then begin
          D := c.Direct(rd - 1, 15) + 1;
          if D > p then Exit;
          for r := 0 to L - 1 do
            if plain[p - D + r] <> plain[p + r] then Exit;
        end else begin
          mant := c.Direct(rk + 1 - (SizeInt(1) shl kk), kk);
          rk := (SizeInt(1) shl kk) - 1 + mant;
          if c.enc then D := rd
          else begin
            D := Rank(s, p, L, rk, 1);
            if D <= 0 then Exit;
          end;
        end;
      end;
    end;
    if L = MAX_MATCH then as284 := c.Bit(m.as284, as284);
    lastMiss := 1 - hit;
    { the token }
    if L = 0 then begin
      if not c.enc then begin
        Grow(nTokB + 1);
        tokLen[nTokB] := 0; tokVal[nTokB] := plain[p];
      end;
      Inc(lfreq[plain[p]]);
      Inc(p);
    end else begin
      if not c.enc then begin
        Grow(nTokB + 1);
        if as284 <> 0 then tokLen[nTokB] := LEN_258_AS_284 else tokLen[nTokB] := L;
        tokVal[nTokB] := D;
      end;
      if as284 <> 0 then Inc(lfreq[284]) else Inc(lfreq[LenSym[L]]);
      Inc(dfreq[DistSym[D]]);
      Inc(p, L);
    end;
    Inc(nTokB);
    Result := True;
  end;

  { the explicit run-length coding of lens[0..total-1] }
  function DoSeqExplicit(const lens: array of Byte; total: Integer; var seq: array of Word; var nSeq: Integer;
    const rseq: array of Word): Boolean;
  var i, v, zr, pr, cls, rcls, rcnt, ctx, cnt, lo, hi, prevCls, bits: Integer; a16, a17, a18: Boolean;
  begin
    Result := False;
    i := 0; nSeq := 0; prevCls := 0;
    while i < total do begin
      v := lens[i];
      zr := 0;
      if v = 0 then while (i + zr < total) and (zr < 138) and (lens[i + zr] = 0) do Inc(zr);
      pr := 0;
      if i > 0 then while (i + pr < total) and (pr < 6) and (lens[i + pr] = lens[i - 1]) do Inc(pr);
      a16 := pr >= 3; a17 := zr >= 3; a18 := zr >= 11;
      rcls := 0; rcnt := 1;
      if c.enc then begin
        if nSeq > High(rseq) then Exit;
        rcls := rseq[nSeq] and $1F;
        if rcls < 16 then rcls := 0;
        case rcls of
          16: rcnt := 3 + rseq[nSeq] shr 5;
          17: rcnt := 3 + rseq[nSeq] shr 5;
          18: rcnt := 11 + rseq[nSeq] shr 5;
        end;
      end;
      cls := 0;
      if a16 or a17 then begin
        if a18 then ctx := 2 else ctx := 1;
        ctx := (prevCls * 2 + Ord(v = 0)) * 3 + ctx;
        if c.Bit(m.seqLit[ctx], Ord(rcls = 0)) = 0 then begin
          if a16 and a17 then begin
            if c.Bit(m.seq16, Ord(rcls = 16)) <> 0 then cls := 16
            else if a18 and (c.Bit(m.seq18, Ord(rcls = 18)) <> 0) then cls := 18
            else cls := 17;
          end else if a16 then cls := 16
          else if a18 and (c.Bit(m.seq18, Ord(rcls = 18)) <> 0) then cls := 18
          else cls := 17;
        end;
      end;
      if cls = 0 then begin
        seq[nSeq] := v; Inc(nSeq); Inc(i);
        prevCls := 0;
        Continue;
      end;
      case cls of
        16: begin lo := 3; hi := pr; bits := 2; end;
        17: begin lo := 3; hi := zr; if hi > 10 then hi := 10; bits := 3; end;
      else begin lo := 11; hi := zr; bits := 7; end;
      end;
      if c.Bit(m.seqMax[cls], Ord(rcnt = hi)) <> 0 then cnt := hi
      else begin
        cnt := lo + c.Direct(rcnt - lo, bits);
        if cnt > hi then Exit;
      end;
      seq[nSeq] := Word(cls or ((cnt - lo) shl 5)); Inc(nSeq);
      Inc(i, cnt);
      prevCls := cls - 15;
      if prevCls > 1 then prevCls := 1;
    end;
    Result := True;
  end;

  function SameHeader(const x, y: TDeflateBlock): Boolean;
  var i: Integer;
  begin
    Result := (x.hlit = y.hlit) and (x.hdist = y.hdist) and (x.hclen = y.hclen) and
      (Length(x.clenSeq) = Length(y.clenSeq));
    if not Result then Exit;
    for i := 0 to 18 do if x.clen[i] <> y.clen[i] then Exit(False);
    for i := 0 to 287 do if x.litLen[i] <> y.litLen[i] then Exit(False);
    for i := 0 to 31 do if x.distLen[i] <> y.distLen[i] then Exit(False);
    for i := 0 to High(x.clenSeq) do if x.clenSeq[i] <> y.clenSeq[i] then Exit(False);
  end;

  function SameSeq(const a: array of Word; na: Integer; const b: array of Word): Boolean;
  var i: Integer;
  begin
    if na <> Length(b) then Exit(False);
    for i := 0 to na - 1 do if a[i] <> b[i] then Exit(False);
    Result := True;
  end;

  { a dynamic block's header, coded against zlib's trees over its symbol
    counts (pb): into b }
  function DoTree: Boolean;
  var
    A, P: array[0..315] of Byte;
    i, last, hlit, hdist, total, sel, nSeq, n0, n1, hclen, phclen: Integer;
    lens: array[0..315] of Byte;
    dl: array[0..29] of Byte;
    seq, s0, s1: array[0..316] of Word;
    kf: Integer;
    rseq: array of Word;
    same: Boolean;
    sfreq: array[0..18] of Integer;
    pclen: array[0..18] of Byte;
  begin
    Result := False;
    for i := 0 to 285 do P[i] := pb.litLen[i];
    for i := 0 to 29 do P[286 + i] := pb.distLen[i];
    if c.enc then begin
      for i := 0 to 285 do A[i] := rb.litLen[i];
      for i := 0 to 29 do A[286 + i] := rb.distLen[i];
    end else FillChar(A, SizeOf(A), 0);
    same := True;
    if c.enc then for i := 0 to 315 do if A[i] <> P[i] then same := False;
    same := c.Bit(m.treeSame[lastTreeSame], Ord(same)) <> 0;
    lastTreeSame := Ord(same);
    if same then A := P
    else
      for i := 0 to 315 do begin
        if i < 286 then kf := Ord(lfreq[i] > 0) else kf := Ord(dfreq[i - 286] > 0);
        if c.Bit(m.lenSame[P[i] * 2 + kf], Ord(A[i] = P[i])) <> 0 then A[i] := P[i]
        else A[i] := c.Tree(m.lenVal[P[i]], 4, A[i]);
      end;
    { HLIT and HDIST: at least what the lengths need }
    last := 256;
    for i := 0 to 285 do if A[i] <> 0 then last := i;
    if last < 256 then last := 256;
    hlit := last + 1;
    if c.Bit(m.hlitSame, Ord(rb.hlit = hlit)) = 0 then begin
      hlit := 257 + c.Direct(rb.hlit - 257, 5);
      if (hlit <= last) or (hlit > 286) then Exit;
    end;
    last := 0;
    for i := 0 to 29 do if A[286 + i] <> 0 then last := i;
    hdist := last + 1;
    if c.Bit(m.hdistSame, Ord(rb.hdist = hdist)) = 0 then begin
      hdist := 1 + c.Direct(rb.hdist - 1, 5);
      if (hdist <= last) or (hdist > 30) then Exit;
    end;
    total := hlit + hdist;
    for i := 0 to hlit - 1 do lens[i] := A[i];
    for i := 0 to hdist - 1 do lens[hlit + i] := A[286 + i];
    { the run-length coding: zlib's on each tree (0), on both at once (1),
      or explicit (2) }
    n0 := 0; ZlibSendTree(lens, hlit, s0, n0);
    for i := 0 to hdist - 1 do dl[i] := lens[hlit + i];
    n1 := 0; ZlibSendTree(dl, hdist, s1, n1);
    for i := 0 to n1 - 1 do s0[n0 + i] := s1[i];
    Inc(n0, n1);
    n1 := 0; ZlibSendTree(lens, total, s1, n1);
    sel := 2;
    if c.enc then begin
      rseq := rb.clenSeq;
      if SameSeq(s0, n0, rseq) then sel := 0 else if SameSeq(s1, n1, rseq) then sel := 1;
    end;
    if c.Bit(m.sel0[lastSel], Ord(sel = 0)) <> 0 then sel := 0
    else if c.Bit(m.sel1[lastSel], Ord(sel = 1)) <> 0 then sel := 1
    else sel := 2;
    lastSel := sel;
    case sel of
      0: begin nSeq := n0; for i := 0 to n0 - 1 do seq[i] := s0[i]; end;
      1: begin nSeq := n1; for i := 0 to n1 - 1 do seq[i] := s1[i]; end;
    else
      if not DoSeqExplicit(lens, total, seq, nSeq, rseq) then Exit;
    end;
    { the code-length code: zlib's over the symbols' counts }
    FillChar(sfreq, SizeOf(sfreq), 0);
    for i := 0 to nSeq - 1 do Inc(sfreq[seq[i] and $1F]);
    ZlibBlTree(sfreq, pclen, phclen);
    same := True;
    if c.enc then for i := 0 to 18 do if rb.clen[i] <> pclen[i] then same := False;
    if c.Bit(m.clenSame, Ord(same)) <> 0 then
      for i := 0 to 18 do b.clen[i] := pclen[i]
    else
      for i := 0 to 18 do
        if c.Bit(m.clenS[pclen[i]], Ord(rb.clen[i] = pclen[i])) <> 0 then b.clen[i] := pclen[i]
        else b.clen[i] := c.Direct(rb.clen[i], 3);
    { HCLEN: at least what clen needs }
    hclen := 19;
    while (hclen > 4) and (b.clen[CLEN_ORDER[hclen - 1]] = 0) do Dec(hclen);
    if c.Bit(m.hclenSame, Ord(rb.hclen = hclen)) = 0 then begin
      i := 4 + c.Direct(rb.hclen - 4, 4);
      if (i < hclen) or (i > 19) then Exit;
      hclen := i;
    end;
    b.hlit := hlit; b.hdist := hdist; b.hclen := hclen;
    FillChar(b.litLen, SizeOf(b.litLen), 0);
    FillChar(b.distLen, SizeOf(b.distLen), 0);
    for i := 0 to hlit - 1 do b.litLen[i] := A[i];
    for i := 0 to hdist - 1 do b.distLen[i] := A[286 + i];
    SetLength(b.clenSeq, nSeq);
    for i := 0 to nSeq - 1 do b.clenSeq[i] := seq[i];
    Result := True;
  end;

begin
  Result := False;
  InitModels(m);
  plain := nil;
  if Length(z.plain) > 0 then plain := @z.plain[0];
  n := Length(z.plain);
  { the predictor }
  head := nil; SetLength(head, SizeInt(1) shl prm.hbits);
  for k := 0 to High(head) do head[k] := NIL_POS;
  prev := nil; SetLength(prev, PREV_SIZE);
  s := Default(TPredState);
  s.plain := plain; s.n := n; s.head := @head[0]; s.prev := @prev[0]; s.ins := 0;
  s.hmask := (SizeInt(1) shl prm.hbits) - 1; s.hshift := (prm.hbits + MIN_MATCH - 1) div MIN_MATCH;
  s.chain := prm.chain; s.nice := prm.nice; s.good := prm.good; s.maxDist := prm.maxDist;
  s.hops := RANK_HOPS;
  if UseCorrC then begin
    SetLength(ordA, PREV_SIZE); SetLength(link4, PREV_SIZE);
    SetLength(hcnt, SizeInt(1) shl prm.hbits);
    SetLength(head4, 1 shl 16);
    for k := 0 to High(head4) do head4[k] := NIL_POS;
    s.ord := @ordA[0]; s.hcnt := @hcnt[0]; s.head4 := @head4[0]; s.link4 := @link4[0];
  end;
  cachePos := -1; cacheLen := 0; cacheDist := 0;
  tokLen := nil; tokVal := nil;
  p := 0; bi := 0; nBlocks := 0;
  maxBlocks := 2 * n + BLOCKS_MORE;
  prevType := 3; lastTokens := -1; lastMiss := 0; lastSel := 0; lastTreeSame := 0;
  rb := Default(TDeflateBlock);
  repeat
    if c.enc then begin
      if bi > High(z.blocks) then Exit;
      rb := z.blocks[bi];
    end else if nBlocks >= maxBlocks then Exit;
    b := Default(TDeflateBlock);
    isStored := c.Bit(m.stored[prevType], Ord(rb.btype = btStored)) <> 0;
    if isStored then begin
      b.btype := btStored;
      maxLen := n - p; if maxLen > 65535 then maxLen := 65535;
      if c.Bit(m.stLenMax, Ord(rb.storedLen = maxLen)) <> 0 then len := maxLen
      else begin
        len := c.Direct(rb.storedLen, 16);
        if len > n - p then Exit;
      end;
      if c.Bit(m.padZero, Ord(rb.pad = 0)) = 0 then begin
        b.pad := c.Direct(rb.pad, 7);
        if not c.enc and (b.pad shr WriterStoredPadBits(o.w) <> 0) then Exit;
      end;
      b.plainPos := p; b.storedLen := len;
      Inc(p, len);
      prevType := 0;
    end else begin
      FillChar(lfreq, SizeOf(lfreq), 0); FillChar(dfreq, SizeOf(dfreq), 0);
      lfreq[256] := 1;
      nTokB := 0;
      t := 0;
      repeat
        if p >= n then isEnd := True
        else begin
          if t = 0 then k := 1
          else if (prm.symEnd > 0) and (t = prm.symEnd) then k := 2
          else if t = lastTokens then k := 3
          else k := 0;
          isEnd := c.Bit(m.blockEnd[k], Ord(t = rb.nTokens)) <> 0;
        end;
        if isEnd then Break;
        if c.enc then begin
          rt := rb.firstToken + t;
          { the parameter search's measure: far enough }
          if (stopTokens >= 0) and ((rt >= stopTokens) or (p >= 16 * stopTokens)) then Exit(True);
          if not DoToken(z.tokLen[rt], z.tokVal[rt]) then Exit;
        end else if not DoToken(0, 0) then Exit;
        Inc(t);
      until False;
      if c.enc and (t <> rb.nTokens) then Exit;
      lastTokens := t;
      pb := Default(TDeflateBlock);
      ZlibTrees(lfreq, dfreq, pb, fixedNoBigger);
      isDyn := c.Bit(m.dyn[Ord(fixedNoBigger)], Ord(rb.btype = btDynamic)) <> 0;
      if isDyn then begin
        b.btype := btDynamic;
        if not DoTree then Exit;
        if c.enc and not SameHeader(b, rb) then Exit;
        prevType := 2;
      end else begin
        b.btype := btFixed;
        prevType := 1;
      end;
      b.nTokens := t;
    end;
    final := False;
    if p >= n then final := c.Bit(m.final, Ord(rb.final)) <> 0;
    b.final := final;
    if c.enc then begin
      if rb.final <> final then Exit;
      Inc(bi);
      if (stopTokens >= 0) and (p >= 16 * stopTokens) and not final then Exit(True);
    end else begin
      b.firstToken := 0;
      o.frame.tokLen := tokLen; o.frame.tokVal := tokVal;
      WriterBlock(o.w, o.frame, b);
      o.frame.tokLen := nil; o.frame.tokVal := nil;
    end;
    Inc(nBlocks);
  until final;
  if c.enc and (bi <> Length(z.blocks)) then Exit;
  if p <> n then Exit;
  Result := True;
end;

function CorrEncode(const z: TZStream; const p: TPredParams; stopTokens: SizeInt): TBytes;
var c: TCoder; o: TDriveOut;
begin
  if not PredValid(p) then raise Exception.Create('ppacorr: CorrEncode with parameters PredValid refuses');
  c := Default(TCoder);
  c.enc := True;
  c.ae.Init;
  o := Default(TDriveOut);
  if not Drive(c, z, p, stopTokens, o) then raise Exception.Create('ppacorr: a stream the driver cannot code');
  Result := c.ae.Finish;
end;

function CorrRebuild(const plain: TBytes; const p: TPredParams; const corr: TBytes;
  const frame: TZStream; out stream: TBytes): Boolean;
var c: TCoder; o: TDriveOut; z: TZStream;
begin
  stream := nil;
  Result := False;
  if not PredValid(p) then Exit;
  c := Default(TCoder);
  c.enc := False;
  c.ad.Init(corr, 0);
  o := Default(TDriveOut);
  o.frame := Default(TZStream);
  o.frame.raw := frame.raw; o.frame.header := frame.header; o.frame.adlerOk := frame.adlerOk;
  o.frame.endPad := frame.endPad; o.frame.tail := frame.tail; o.frame.plain := plain;
  WriterBegin(o.w, o.frame);
  z := Default(TZStream);
  z.plain := plain;
  if not Drive(c, z, p, -1, o) then Exit;
  if o.frame.endPad shr WriterEndPadBits(o.w) <> 0 then Exit;
  stream := WriterFinish(o.w, o.frame);
  Result := True;
end;

{ ---------------------------------------------------------------- the parameters }

{ a[0..n-1] in increasing order (Shell's sort) }
procedure SortSizes(var a: array of SizeInt; n: SizeInt);
var gap, i, j, v: SizeInt;
begin
  gap := 1;
  while gap < n div 3 do gap := 3 * gap + 1;
  while gap > 0 do begin
    for i := gap to n - 1 do begin
      v := a[i]; j := i;
      while (j >= gap) and (a[j - gap] > v) do begin a[j] := a[j - gap]; Dec(j, gap); end;
      a[j] := v;
    end;
    gap := gap div 3;
  end;
end;

procedure CorrChooseParams(const z: TZStream; out p: TPredParams);
const
  { zlib's good lazy nice chain, by level }
  CONFIG: array[1..9, 0..3] of Integer = (
    (4, 4, 8, 4), (4, 5, 16, 8), (4, 6, 32, 32),
    (4, 4, 16, 16), (8, 16, 32, 32), (8, 16, 128, 128),
    (8, 32, 128, 256), (32, 128, 258, 1024), (32, 258, 258, 4096));
  { the first blocks, up to the one holding this token: what the
    candidates are measured on }
  SEARCH_STOP = 1 shl 13;
var
  best, cand: TPredParams; bestCost, cost: SizeInt; lv, f, i, k, hb, cnt, bestCnt: Integer;
  nonStored: Boolean;
  counts: array of SizeInt;

  procedure TryParams(const q: TPredParams);
  begin
    if not PredValid(q) then Exit;
    cost := Length(CorrEncode(z, q, SEARCH_STOP));
    if (bestCost < 0) or (cost < bestCost) then begin bestCost := cost; best := q; end;
  end;

begin
  p := Default(TPredParams);
  p.predVersion := PRED_VERSION; p.chain := 128; p.nice := 128; p.lazy := 16; p.good := 8;
  p.hbits := 15; p.maxDist := WINDOW - 262; p.flags := PF_TOOFAR;
  { the symbols a block holds: the commonest count of the blocks that end
    before the last (twice at least) }
  counts := nil;
  SetLength(counts, Length(z.blocks));
  k := 0;
  for i := 0 to High(z.blocks) - 1 do
    if (z.blocks[i].btype <> btStored) and (z.blocks[i].nTokens > 0) then begin
      counts[k] := z.blocks[i].nTokens; Inc(k);
    end;
  SortSizes(counts, k);
  bestCnt := 1;
  i := 0;
  while i < k do begin
    f := i;
    while (f < k) and (counts[f] = counts[i]) do Inc(f);
    cnt := f - i;
    { the commonest; of as common, the smallest (the first in order) }
    if cnt > bestCnt then begin bestCnt := cnt; p.symEnd := counts[i]; end;
    i := f;
  end;
  if p.symEnd > PRED_MAX_SYMEND then p.symEnd := 0;
  nonStored := False;
  for i := 0 to High(z.blocks) do if (z.blocks[i].btype <> btStored) and (z.blocks[i].nTokens > 0) then nonStored := True;
  if not nonStored then Exit;
  { zlib's levels (deflate_fast at 1-3), the filtered strategy, and two of
    no limits (lazy and greedy); then the best one's hash and window }
  bestCost := -1; best := p;
  for lv := 1 to 9 do
    for f := 0 to 1 do begin
      if (f = 1) and (lv <= 3) then Continue;
      cand := p;
      cand.good := CONFIG[lv, 0]; cand.nice := CONFIG[lv, 2]; cand.chain := CONFIG[lv, 3];
      if lv <= 3 then begin cand.lazy := 0; cand.flags := 0; cand.good := MIN_MATCH + 1; end
      else begin
        cand.lazy := CONFIG[lv, 1];
        cand.flags := PF_TOOFAR;
        if f = 1 then cand.flags := PF_TOOFAR or PF_FILTERED;
      end;
      if cand.good < MIN_MATCH then cand.good := MIN_MATCH;
      TryParams(cand);
    end;
  cand := p; cand.chain := PRED_MAX_CHAIN; cand.nice := MAX_MATCH; cand.lazy := MAX_MATCH; cand.good := MAX_MATCH;
  cand.flags := 0; cand.maxDist := WINDOW;
  TryParams(cand);
  cand.lazy := 0;
  TryParams(cand);
  cand := best;
  for hb := 16 downto 12 do
    if hb <> best.hbits then begin cand.hbits := hb; TryParams(cand); end;
  cand := best;
  if cand.maxDist <> WINDOW then begin cand.maxDist := WINDOW; TryParams(cand); end;
  cand := best;
  if cand.lazy > 0 then begin cand.flags := cand.flags xor PF_TOOFAR; TryParams(cand); end;
  p := best;
end;

procedure MakeTables;
var s, l, i: Integer;
begin
  for s := 257 to 284 do
    for l := LEN_BASE[s] to LEN_BASE[s] + (1 shl LEN_EXTRA[s]) - 1 do
      if l <= 258 then LenSym[l] := s;
  LenSym[258] := 285;
  for s := 0 to 29 do
    for i := DIST_BASE[s] to DIST_BASE[s] + (1 shl DIST_EXTRA[s]) - 1 do
      DistSym[i] := s;
  for i := 0 to RATE_LIMIT do RATE[i] := 131072 div (2 * i + 3);
end;

initialization
  UseCorrC := GetEnvironmentVariable('PPA_NOC') <> '1';
  MakeTables;
end.
