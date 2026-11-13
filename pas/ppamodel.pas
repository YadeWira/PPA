{ Codec layer 5: the context model of an image's bytes (layer 3's
  unfiltered bytes) and of its lines' filters, coded with layer 4.

  First version, a prototype to measure against: each byte is coded bit by
  bit, most significant first; each bit's probability mixes six contexts
  made of the byte's neighbours in the same channel (W, N, NW, NE, the
  gradient W + N - NW, and the residual the previous channel of the same
  pixel left), each a table of adaptive counters indexed by a hash of the
  context and the bits of the byte coded so far. The mixer's weights are
  chosen by the channel and the bit's position. A line's filter is coded
  with the previous line's filter as context.

  Integer arithmetic only, 32 bits wherever a ZPAQL decoder would need it:
  the mixer's terms are bounded so that no sum leaves 32 bits.

  CodeImage both encodes (enc given: reads px) and decodes (dec given:
  writes px.filters and px.data, px's layout already set), the same code
  for both, so that they cannot drift apart. }
unit ppamodel;

{$I ppa.inc}
{$ifdef PPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal ppamodel: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal ppamodel: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, ppaarith, ppapixels;

type
  PArithEncoder = ^TArithEncoder;
  PArithDecoder = ^TArithDecoder;

procedure CodeImage(var px: TPixels; enc: PArithEncoder; dec: PArithDecoder);
{ The same for lines firstRow .. firstRow + rows - 1 of a non-interlaced
  image (a band), with a model of its own: bands code and decode
  independently. An interlaced image is always coded whole. }
procedure CodeImageBand(var px: TPixels; firstRow, rows: SizeInt; enc: PArithEncoder; dec: PArithDecoder);

type
  { The model of plain bytes (a file's chunks, streams kept as bytes):
    orders 0 to 3, mixed. It keeps learning from one call to the next. }
  TByteModel = record
    t: array[0..3] of array of TAdaptiveBit;   { see TCounter: p xor $8000 }
    w: array[0..7, 0..4] of Integer;
    hist: Cardinal;    { the last bytes coded }
    procedure Init;
  end;

{ data[first .. first + n - 1]: encoded (enc given) or decoded into it }
procedure CodeBytes(var m: TByteModel; var data: TBytes; first, n: SizeInt;
  enc: PArithEncoder; dec: PArithDecoder);

var
  { the pixel loop in C (ppamodelc.c); False: in Pascal, the reference.
    PPA_NOC=1 in the environment makes it False: the suite codes the same
    images both ways and demands the same streams }
  UseC: Boolean = True;

{ The model's tables (128 MB, zeros) kept for the next band while anyone
  holds the pool: a band takes a block the last one gave back and zeros it,
  instead of asking the system for new memory, which zeros every page again
  as it is touched (on the corpus, a ninth of ppa x). Holds nest; the last
  release frees what is kept. The codec holds it for each call, the command
  for its whole run. }
procedure ModelPoolHold;
procedure ModelPoolRelease;

implementation

{$L ppamodelc.o}

const
  NCTX = 8;
  MATCH_BITS = 20;
  MIN_MATCH_LEN = 6;
  NIN = NCTX + 2;               { the contexts, the match model and a bias }
  NINP = 12;                    { a weight set's row in memory: NIN and zeros, whole vectors for the C }
  TABLE_BITS = 22;
  TABLE_MASK = (1 shl TABLE_BITS) - 1;
  { a table is buckets of 16 counters, 64 bytes: the 15 nodes of one
    nibble's binary tree, so that a nibble's 4 bits read one cache line }
  BUCKET_BITS = TABLE_BITS - 4;
  TABLE_ALIGN = 2 * 1024 * 1024;
  COUNTER_LIMIT = 60;
  MIXER_SETS = 16 * 8 + 8 * 8;  { channel (up to 16 bytes a pixel) x bit position; activity x bit position }
  W_MAX = 1 shl 19;
  LEARNING_RATE = 12;
  FILTER_LIMIT = 30;

type
  { TAdaptiveBit's counter, its probability kept as p xor $8000: memory
    filled with zeros (as SetLength gives it) is every counter at 1/2, so a
    model of millions of counters starts without a loop over them }
  TCounter = record
    q: Word;
    n: Byte;
    pad: Byte;      { 4 bytes: 16 to a cache line }
  end;

function CounterP(const c: TCounter): Integer; inline;
begin
  Result := c.q xor $8000;
end;

{ TAdaptiveBit.Update, on the stored form }
procedure CounterUpdate(var c: TCounter; bit, limit: Integer); inline;
var p, target: Integer; q: Int64;
begin
  p := c.q xor $8000;
  if bit <> 0 then target := PROB_ONE - 1 else target := 1;
  q := Int64(target - p) * RECIPROCAL[c.n];
  q := SarInt64(q + (SarInt64(q, 63) and $FFFF), 16);
  c.q := Word(p + q) xor $8000;
  if (c.n < limit) and (c.n < MAX_LIMIT) then Inc(c.n);
end;

type
  PCounter = ^TCounter;
  TCounterArray = array of TCounter;
  TModel = record
    tall: TCounterArray;                      { the tables' memory, with room to align }
    t: array[0..NCTX - 1] of PCounter;        { the tables, in tall }
    w: array[0..MIXER_SETS - 1, 0..NINP - 1] of Integer;
    filt: array[0..5, 1..7] of TAdaptiveBit;
    apm: array of Word;     { [16][256][33] }
    mtab: array of Cardinal;
    mm: array[0..31] of TCounter;
    mptr, mlen: SizeInt;
  end;

type
  { ppamodelc.c's rowargs_t }
  TRowArgs = record
    row, prior: PByte;
    rb, bpp, hasPrior: SizeInt;
    t: array[0..NCTX - 1] of Pointer;
    w: PInteger;
    recip: PInteger;
    stretchTab: PSmallInt;
    squashTab: PWord;
    bucketBits, limit, wMax, rate, stretchMax: SizeInt;
    x1, x2, x: PCardinal;
    buf: PByte;
    pos: PSizeInt;
    len: SizeInt;
    encoding: SizeInt;
    apm: PWord;
    prior2: PByte;
    data: PByte;
    rowPos: SizeInt;
    mtab: PCardinal;
    mbits: SizeInt;
    mptr, mlen: PSizeInt;
    mm: Pointer;
    sample16: SizeInt;
    bandStart: SizeInt;
  end;

procedure ppam_row(var a: TRowArgs); cdecl; external name 'ppam_row';

type
  { ppamodelc.c's bytesargs_t: CodeBytes in C }
  TBytesArgs = record
    t: array[0..3] of Pointer;
    w: PInteger;
    hist: PCardinal;
    data: PByte; n: SizeInt;
    recip: PInteger; stretchTab: PSmallInt; squashTab: PWord;
    x1, x2, x: PCardinal;
    buf: PByte;
    pos: PSizeInt;
    len: SizeInt;
    encoding: SizeInt;
  end;

procedure ppam_bytes(var a: TBytesArgs); cdecl; external name 'ppam_bytes';

var
  PoolLock: TRTLCriticalSection;
  PoolHolds: Integer = 0;
  PoolFree: array of TCounterArray;   { blocks given back, each of TALL_LEN }

const
  TALL_LEN = NCTX * (TABLE_MASK + 1) + TABLE_ALIGN div SizeOf(TCounter);

procedure ModelPoolHold;
begin
  EnterCriticalSection(PoolLock);
  Inc(PoolHolds);
  LeaveCriticalSection(PoolLock);
end;

procedure ModelPoolRelease;
begin
  EnterCriticalSection(PoolLock);
  Dec(PoolHolds);
  if PoolHolds <= 0 then begin PoolHolds := 0; PoolFree := nil; end;
  LeaveCriticalSection(PoolLock);
end;

{ the tables' block: one given back (zeroed here), or a new one (zeros) }
procedure TakeTables(var m: TModel);
var n: SizeInt;
begin
  m.tall := nil;
  EnterCriticalSection(PoolLock);
  n := Length(PoolFree);
  if n > 0 then begin
    m.tall := PoolFree[n - 1];
    PoolFree[n - 1] := nil;
    SetLength(PoolFree, n - 1);
  end;
  LeaveCriticalSection(PoolLock);
  if m.tall <> nil then FillChar(m.tall[0], TALL_LEN * SizeOf(TCounter), 0)
  else SetLength(m.tall, TALL_LEN);
end;

{ the block back to the pool, while it is held; else freed }
procedure GiveTables(var m: TModel);
begin
  EnterCriticalSection(PoolLock);
  if (PoolHolds > 0) and (Length(m.tall) = TALL_LEN) then begin
    SetLength(PoolFree, Length(PoolFree) + 1);
    PoolFree[High(PoolFree)] := m.tall;
  end;
  LeaveCriticalSection(PoolLock);
  m.tall := nil;
end;

procedure InitModel(var m: TModel);
var i, j: Integer; a: PtrUInt;
begin
  { one block for every table, zeros (every counter at 1/2), the tables
    aligned to 2 MiB: a bucket is then one cache line, and a system that
    backs memory with large pages can back all of it }
  TakeTables(m);
  a := (TABLE_ALIGN - PtrUInt(@m.tall[0]) mod TABLE_ALIGN) mod TABLE_ALIGN;
  for i := 0 to NCTX - 1 do
    m.t[i] := PCounter(PByte(@m.tall[0]) + a) + i * (TABLE_MASK + 1);
  for i := 0 to MIXER_SETS - 1 do
    for j := 0 to NINP - 1 do
      if j < NIN then m.w[i, j] := (1 shl 16) div NCTX else m.w[i, j] := 0;
  for i := 0 to 5 do for j := 1 to 7 do m.filt[i, j].Init;
  m.mtab := nil;
  SetLength(m.mtab, 1 shl MATCH_BITS);
  FillChar(m.mm, SizeOf(m.mm), 0);
  m.mptr := 0; m.mlen := 0;
  m.apm := nil;
  SetLength(m.apm, 16 * 256 * 33);
  for i := 0 to 16 * 256 - 1 do
    for j := 0 to 32 do m.apm[i * 33 + j] := Squash(j * 128 - 2048);
end;

{ hashes wrap around on purpose }
{$push}{$Q-}{$R-}
function Hash(a, b, c: Cardinal): Cardinal;
begin
  Result := (a * Cardinal(2654435761)) xor (b * Cardinal(2246822519)) xor (c * Cardinal(3266489917));
  Result := Result xor (Result shr 15);
end;

{ the hash of a context and a nibble (0: the byte's first; 16 + the first
  nibble: its second): its high bits choose the bucket, its low 16 bits
  are the bucket's check }
function BucketHash(ctx, nib: Cardinal): Cardinal; inline;
begin
  Result := ctx xor (nib * Cardinal(2654435761));
  Result := Result xor (Result shr 13) * Cardinal(2246822519);
end;
{$pop}

function Clamp255(v: Integer): Integer; inline;
begin
  if v < 0 then Result := 0 else if v > 255 then Result := 255 else Result := v;
end;

{ The first counter of the bucket for hash h. Its counter 0 is not a tree
  node (a check there, emptying a bucket another context has, was tried:
  worse, 31/10/2026). }
{$push}{$Q-}{$R-}
{ the match model's hash of the MINLEN bytes before pos+1 (wraps around on
  purpose) }
function MatchHash(const d: TBytes; pos: SizeInt; bits: Integer): Cardinal;
var i: Integer;
begin
  Result := 0;
  for i := 1 to MIN_MATCH_LEN do Result := (Result + d[pos + 1 - i] + 1) * Cardinal(2654435761);
  Result := Result shr (32 - bits);
end;

function PixelKey(k, cur: Cardinal): Cardinal; inline;
begin
  Result := (k * Cardinal($1000193)) xor cur;
end;
{$pop}

function BucketOf(h: Cardinal): Cardinal; inline;
begin
  Result := ((h shr (32 - BUCKET_BITS)) and ((1 shl BUCKET_BITS) - 1)) shl 4;
end;

{ One line of pixels, the Pascal reference of ppamodelc.c's ppam_row: the
  same arithmetic, step by step, so that both give the same stream. }
procedure PascalRow(var m: TModel; var px: TPixels; row, prior, rb: SizeInt; y, y0, bandStart: SizeInt;
  enc: PArithEncoder; dec: PArithDecoder);
var
  bpp, x, k, i, s0, p0, nb, bpos, mptr, mlen, cand, l, ai: SizeInt;
  hasPrior: Boolean;
  W, N, NW, NE, NN, WW, grad, avg, res, res2, dW, dN, act, d, jj, nd, b: Integer;
  w16, n16, nw16, g16, a16, hi, lg, la: Integer;
  base, bkt, idx: array[0..NCTX - 1] of Cardinal;
  st: array[0..NIN - 1] of Integer;
  np, cur, partial, h: Cardinal;
  value, expected, mbucket, j, node, dot, dot2, p, pm, bit, err, mexp, sp, sidx, lo, wt, pa, g, v, ws, ws2, byteV: Integer;
  apBase: SizeInt;
begin
  bpp := px.bpp;
  { the band's first line has none above: bands decode independently }
  hasPrior := y > y0;
  k := bpp - 1;
  for x := 0 to rb - 1 do begin
    Inc(k); if k = bpp then k := 0;
    if x >= bpp then W := px.data[row + x - bpp] else W := 0;
    if hasPrior then N := px.data[prior + x] else N := W;
    if hasPrior and (x >= bpp) then NW := px.data[prior + x - bpp] else NW := N;
    if hasPrior and (x + bpp < rb) then NE := px.data[prior + x + bpp] else NE := N;
    grad := Clamp255(W + N - NW);
    d := Abs(W - NW) + Abs(N - NW) + Abs(N - NE);
    if d = 0 then act := 0 else if d < 4 then act := 1 else if d < 8 then act := 2
    else if d < 16 then act := 3 else if d < 32 then act := 4 else if d < 64 then act := 5
    else if d < 128 then act := 6 else act := 7;
    avg := (W + N + 1) shr 1;
    dW := 0; dN := 0; res2 := 0;
    if k > 1 then begin
      i := x - 2;
      if i >= bpp then jj := px.data[row + i - bpp] else jj := 0;
      if hasPrior then nd := px.data[prior + i] else nd := jj;
      if hasPrior and (i >= bpp) then b := px.data[prior + i - bpp] else b := nd;
      res2 := px.data[row + i] - Clamp255(jj + nd - b);
    end;
    if k > 0 then begin
      i := x - 1;
      res := px.data[row + i];
      if i >= bpp then jj := px.data[row + i - bpp] else jj := 0;
      if hasPrior then nd := px.data[prior + i] else nd := jj;
      if hasPrior and (i >= bpp) then b := px.data[prior + i - bpp] else b := nd;
      dW := res - jj;
      dN := res - nd;
      res := res - Clamp255(jj + nd - b);
    end else res := 0;
    base[0] := Hash(k, W, 1);
    base[1] := Hash(k, N, 2);
    base[2] := Hash(k, Clamp255(N + dN), 3);
    base[3] := Hash(k, Cardinal(avg) + (Cardinal(Clamp255(NE)) shl 8), 4);
    base[4] := Hash(k, Clamp255(W + dW), 5);
    if hasPrior and (y > y0 + 1) then NN := px.data[prior - rb + x] else NN := N;
    if x >= 2 * bpp then WW := px.data[row + x - 2 * bpp] else WW := W;
    if k > 1 then v := (res + res2) div 2 else v := res;
    base[5] := Hash(k, Cardinal(Clamp255(grad + v)) or (Cardinal(res2 + 256) shl 8), 7);
    base[6] := Hash(k, Cardinal(Clamp255(2 * N - NN)) or (Cardinal(Clamp255(2 * W - WW)) shl 8), 8);
    if px.info.depth = 16 then begin
      s0 := x - (k and 1);
      if s0 >= bpp then w16 := (px.data[row + s0 - bpp] shl 8) or px.data[row + s0 - bpp + 1] else w16 := 0;
      if hasPrior then n16 := (px.data[prior + s0] shl 8) or px.data[prior + s0 + 1] else n16 := w16;
      if hasPrior and (s0 >= bpp) then nw16 := (px.data[prior + s0 - bpp] shl 8) or px.data[prior + s0 - bpp + 1]
      else nw16 := n16;
      g16 := w16 + n16 - nw16;
      if g16 < 0 then g16 := 0;
      if g16 > 65535 then g16 := 65535;
      a16 := (w16 + n16 + 1) shr 1;
      if (k and 1) = 0 then begin
        base[5] := Hash(k, g16 shr 4, 11);
        base[6] := Hash(k, a16 shr 4, 12);
      end else begin
        hi := px.data[row + s0] shl 8; lg := g16 - hi; la := a16 - hi;
        if lg < -1 then lg := -1;
        if lg > 256 then lg := 256;
        if la < -1 then la := -1;
        if la > 256 then la := 256;
        base[5] := Hash(k, lg + 1, 13);
        base[6] := Hash(k, Cardinal(la + 1) or (Cardinal(lg + 1) shl 9), 14);
      end;
    end;
    np := 0; cur := 0;
    p0 := x - k;
    if bpp < 4 then nb := bpp else nb := 4;
    for i := 0 to nb - 1 do begin
      np := np shl 8;
      if hasPrior then np := np or px.data[prior + p0 + i];
    end;
    for i := 0 to k - 1 do cur := (cur shl 8) or px.data[row + p0 + i];
    base[7] := Hash(PixelKey(k, cur), np, 10);

    if enc <> nil then value := px.data[row + x] else value := 0;
    partial := 1;
    bpos := row + x;
    mptr := m.mptr; mlen := m.mlen;
    if mlen > 0 then expected := px.data[mptr] else expected := 0;
    if mlen > 15 then mbucket := 15 else mbucket := mlen;
    for i := 0 to NCTX - 1 do bkt[i] := BucketOf(BucketHash(base[i], 0));
    for j := 7 downto 0 do begin
      if j = 3 then
        for i := 0 to NCTX - 1 do bkt[i] := BucketOf(BucketHash(base[i], partial));
      if j >= 4 then node := partial
      else node := (1 shl (3 - j)) or Integer(partial and ((1 shl (3 - j)) - 1));
      ws := (k and 15) * 8 + j;
      ws2 := 128 + act * 8 + j;
      dot := 0; dot2 := 0;
      for i := 0 to NCTX - 1 do begin
        idx[i] := bkt[i] + Cardinal(node);
        st[i] := STRETCH_TAB[(m.t[i][idx[i]].q xor $8000) shr 4];
        Inc(dot, (m.w[ws, i] * st[i]) div 8192);
        Inc(dot2, (m.w[ws2, i] * st[i]) div 8192);
      end;
      mexp := -1;
      if (mlen > 0) and ((Cardinal(expected or 256) shr (j + 1)) = partial) then begin
        mexp := (expected shr j) and 1;
        sp := STRETCH_TAB[(m.mm[mbucket * 2 + mexp].q xor $8000) shr 4];
        if mexp = 1 then st[NCTX] := sp else st[NCTX] := -sp;
      end else st[NCTX] := 0;
      Inc(dot, (m.w[ws, NCTX] * st[NCTX]) div 8192);
      Inc(dot2, (m.w[ws2, NCTX] * st[NCTX]) div 8192);
      st[NCTX + 1] := 256;
      Inc(dot, (m.w[ws, NCTX + 1] * st[NCTX + 1]) div 8192);
      Inc(dot2, (m.w[ws2, NCTX + 1] * st[NCTX + 1]) div 8192);
      dot := (dot + dot2) div 16;
      if dot > STRETCH_MAX then dot := STRETCH_MAX;
      if dot < -STRETCH_MAX - 1 then dot := -STRETCH_MAX - 1;
      p := SQUASH_TAB[dot + 2048];
      if p < 1 then p := 1;
      if p > 65535 then p := 65535;
      sidx := dot + 2048; lo := sidx shr 7; wt := sidx and 127;
      apBase := ((k and 15) * 256 + SizeInt(partial)) * 33;
      pa := (m.apm[apBase + lo] * (128 - wt) + m.apm[apBase + lo + 1] * wt) shr 7;
      pm := p;
      p := (p + 3 * pa) shr 2;
      if p < 1 then p := 1;
      if p > 65535 then p := 65535;
      if enc <> nil then begin bit := (value shr j) and 1; enc^.Encode(bit, p); end
      else bit := dec^.Decode(p);
      ai := lo + (wt shr 6);
      if bit = 1 then g := 65535 else g := 0;
      m.apm[apBase + ai] := Word(m.apm[apBase + ai] + (g - m.apm[apBase + ai]) div 64);
      err := ((bit shl 16) - pm) div 16;
      for i := 0 to NIN - 1 do begin
        v := m.w[ws, i] + (st[i] * err * LEARNING_RATE) div 65536;
        if v > W_MAX then v := W_MAX;
        if v < -W_MAX then v := -W_MAX;
        m.w[ws, i] := v;
        v := m.w[ws2, i] + (st[i] * err * LEARNING_RATE) div 65536;
        if v > W_MAX then v := W_MAX;
        if v < -W_MAX then v := -W_MAX;
        m.w[ws2, i] := v;
      end;
      for i := 0 to NCTX - 1 do CounterUpdate(m.t[i][idx[i]], bit, COUNTER_LIMIT);
      if mexp >= 0 then CounterUpdate(m.mm[mbucket * 2 + mexp], Ord(bit = mexp), COUNTER_LIMIT);
      partial := partial * 2 + Cardinal(bit);
    end;
    byteV := Integer(partial and $FF);
    if dec <> nil then px.data[row + x] := byteV;
    if (mlen > 0) and (px.data[mptr] = byteV) then begin Inc(mlen); Inc(mptr); end else mlen := 0;
    if bpos + 1 - bandStart >= MIN_MATCH_LEN then begin
      h := MatchHash(px.data, bpos, MATCH_BITS);
      if mlen = 0 then begin
        cand := m.mtab[h];
        if cand > 0 then begin
          l := 0;
          while (l < 32) and (cand - 1 - l >= bandStart) and (px.data[cand - 1 - l] = px.data[bpos - l]) do Inc(l);
          if l >= MIN_MATCH_LEN then begin mlen := l; mptr := cand; end;
        end;
      end;
      m.mtab[h] := Cardinal(bpos + 1);
    end;
    if mlen > 65535 then mlen := 65535;
    m.mptr := mptr; m.mlen := mlen;
  end;
end;

procedure CodeImage(var px: TPixels; enc: PArithEncoder; dec: PArithDecoder);
begin
  CodeImageBand(px, 0, High(SizeInt), enc, dec);
end;

procedure CodeImageBand(var px: TPixels; firstRow, rows: SizeInt; enc: PArithEncoder; dec: PArithDecoder);
var
  y0, y1: SizeInt;
  m: TModel;
  pi_, y, rb, bpp, row, prior: SizeInt;
  prevFilter, f, node, bit, j, i: Integer;
  ra: TRowArgs;

  function CodeBit(var c: TAdaptiveBit; bitIn, limit: Integer): Integer;
  begin
    if enc <> nil then begin enc^.Encode(bitIn, c.p); Result := bitIn; end
    else Result := dec^.Decode(c.p);
    c.Update(Result, limit);
  end;

begin
  InitModel(m);
  try
  bpp := px.bpp;
  prevFilter := 5;
  ra := Default(TRowArgs);
  ra.bpp := bpp;
  for i := 0 to NCTX - 1 do ra.t[i] := m.t[i];
  ra.w := @m.w[0, 0];
  ra.recip := @RECIPROCAL[0];
  ra.stretchTab := @STRETCH_TAB[0];
  ra.squashTab := @SQUASH_TAB[0];
  ra.bucketBits := BUCKET_BITS; ra.limit := COUNTER_LIMIT; ra.wMax := W_MAX;
  ra.rate := LEARNING_RATE; ra.stretchMax := STRETCH_MAX;
  ra.encoding := Ord(enc <> nil);
  ra.apm := @m.apm[0];
  if Length(px.data) > 0 then ra.data := @px.data[0] else ra.data := nil;
  ra.mtab := @m.mtab[0]; ra.mbits := MATCH_BITS;
  ra.mptr := @m.mptr; ra.mlen := @m.mlen; ra.mm := @m.mm[0];
  ra.sample16 := Ord(px.info.depth = 16);
  for pi_ := 0 to High(px.passes) do begin
    rb := px.passes[pi_].rowBytes;
    { a band of a non-interlaced image, or every line }
    y0 := 0; y1 := px.passes[pi_].height - 1;
    if Length(px.passes) = 1 then begin
      if firstRow > y0 then y0 := firstRow;
      if (rows < High(SizeInt) - firstRow) and (firstRow + rows - 1 < y1) then y1 := firstRow + rows - 1;
    end;
    for y := y0 to y1 do begin
      { the line's filter: 3 bits, a binary tree }
      if enc <> nil then f := px.filters[px.passes[pi_].firstLine + y] else f := 0;
      node := 1;
      for j := 2 downto 0 do begin
        bit := CodeBit(m.filt[prevFilter, node], (f shr j) and 1, FILTER_LIMIT);
        node := node * 2 + bit;
      end;
      f := node - 8;
      { a damaged stream can give 5 to 7, which no PNG has: refused here
        (the filter is a context's index below, and the release build checks
        no ranges) }
      if f > 4 then raise Exception.Create('damaged stream: a line filter above 4');
      if dec <> nil then px.filters[px.passes[pi_].firstLine + y] := f;
      prevFilter := f;
      row := px.passes[pi_].first + y * rb;
      prior := row - rb;
      if UseC then begin
        if rb = 0 then Continue;
        ra.row := @px.data[row];
        if y > y0 then begin ra.prior := @px.data[prior]; ra.hasPrior := 1; end
        else begin ra.prior := @px.data[row]; ra.hasPrior := 0; end;
        if y > y0 + 1 then ra.prior2 := @px.data[prior - rb] else ra.prior2 := nil;
        ra.bandStart := px.passes[pi_].first + y0 * rb;
        ra.rowPos := row;
        ra.rb := rb;
        if enc <> nil then begin
          { room for the worst: 16 bits out for every bit in }
          if enc^.n + 16 * rb + 64 > Length(enc^.d) then SetLength(enc^.d, 2 * (enc^.n + 16 * rb + 64));
          ra.x1 := @enc^.x1; ra.x2 := @enc^.x2; ra.x := nil;
          ra.buf := @enc^.d[0]; ra.pos := @enc^.n; ra.len := Length(enc^.d);
        end else begin
          ra.x1 := @dec^.x1; ra.x2 := @dec^.x2; ra.x := @dec^.x;
          if Length(dec^.d) > 0 then ra.buf := @dec^.d[0] else ra.buf := nil;
          ra.pos := @dec^.p; ra.len := Length(dec^.d);
        end;
        ppam_row(ra);
        Continue;
      end;
      PascalRow(m, px, row, prior, rb, y, y0, px.passes[pi_].first + y0 * rb, enc, dec);
    end;
  end;
  finally
    GiveTables(m);
  end;
end;

const
  BYTE_TABLE_BITS = 18;
  BYTE_TABLE_MASK = (1 shl BYTE_TABLE_BITS) - 1;
  BYTE_LIMIT = 127;

procedure TByteModel.Init;
var i, j: Integer;
begin
  for i := 0 to 3 do begin
    t[i] := nil;
    SetLength(t[i], BYTE_TABLE_MASK + 1);   { zeros: every counter at 1/2 }
  end;
  for i := 0 to 7 do for j := 0 to 4 do w[i, j] := (1 shl 16) div 4;
  hist := 0;
end;

{$push}{$Q-}{$R-}
function ByteSlot(order: Integer; hist, partial: Cardinal): Cardinal; inline;
var h: Cardinal;
begin
  case order of
    0: h := 0;
    1: h := hist and $FF;
    2: h := hist and $FFFF;
  else h := hist and $FFFFFF;
  end;
  h := (h + Cardinal(order) shl 24) * Cardinal(2654435761);
  Result := ((h shr (32 - BYTE_TABLE_BITS)) xor ((partial * Cardinal(2246822519)) shr (32 - BYTE_TABLE_BITS))) and BYTE_TABLE_MASK;
end;
{$pop}

{ CodeBytes in C (ppamodelc.c's ppam_bytes), the same bits: the encoder's
  buffer made large enough for each piece first (a bit's probability is at
  least 1/65536, and a range may be down to one value: at most four
  bytes out a bit) }
procedure CodeBytesC(var m: TByteModel; var data: TBytes; first, n: SizeInt;
  enc: PArithEncoder; dec: PArithDecoder);
const PIECE = 4096;
var a: TBytesArgs; i: Integer; k, need: SizeInt;
begin
  a := Default(TBytesArgs);
  for i := 0 to 3 do a.t[i] := @m.t[i][0];
  a.w := @m.w[0, 0]; a.hist := @m.hist;
  a.recip := @RECIPROCAL[0]; a.stretchTab := @STRETCH_TAB[0]; a.squashTab := @SQUASH_TAB[0];
  a.encoding := Ord(enc <> nil);
  while n > 0 do begin
    k := n; if k > PIECE then k := PIECE;
    a.data := @data[first]; a.n := k;
    if enc <> nil then begin
      need := enc^.n + 33 * k + 16;
      if Length(enc^.d) < need then
        if 2 * Length(enc^.d) > need then SetLength(enc^.d, 2 * Length(enc^.d)) else SetLength(enc^.d, need);
      a.x1 := @enc^.x1; a.x2 := @enc^.x2; a.buf := @enc^.d[0]; a.pos := @enc^.n;
    end else begin
      a.x1 := @dec^.x1; a.x2 := @dec^.x2; a.x := @dec^.x; a.pos := @dec^.p;
      a.len := Length(dec^.d);
      if a.len > 0 then a.buf := @dec^.d[0] else a.buf := nil;
    end;
    ppam_bytes(a);
    first := first + k; n := n - k;   { (Dec is the decoder here) }
  end;
end;

procedure CodeBytes(var m: TByteModel; var data: TBytes; first, n: SizeInt;
  enc: PArithEncoder; dec: PArithDecoder);
var
  q: SizeInt; j, i, bit, dot, p, err, value: Integer;
  partial: Cardinal; idx: array[0..3] of Cardinal; st: array[0..4] of Integer;
begin
  if UseC and (n > 0) then begin CodeBytesC(m, data, first, n, enc, dec); Exit; end;
  { the Pascal reference }
  for q := first to first + n - 1 do begin
    if enc <> nil then value := data[q] else value := 0;
    partial := 1;
    for j := 7 downto 0 do begin
      dot := 0;
      for i := 0 to 3 do begin
        idx[i] := ByteSlot(i, m.hist, partial);
        st[i] := Stretch(m.t[i][idx[i]].p xor $8000);
        Inc(dot, (m.w[j, i] * st[i]) div 8192);
      end;
      st[4] := 256;
      Inc(dot, (m.w[j, 4] * st[4]) div 8192);
      p := Squash(dot div 8);
      if enc <> nil then begin bit := (value shr j) and 1; enc^.Encode(bit, p); end
      else bit := dec^.Decode(p);
      err := ((bit shl 16) - p) div 16;
      for i := 0 to 4 do begin
        m.w[j, i] := m.w[j, i] + (st[i] * err * LEARNING_RATE) div 65536;
        if m.w[j, i] > W_MAX then m.w[j, i] := W_MAX;
        if m.w[j, i] < -W_MAX then m.w[j, i] := -W_MAX;
      end;
      for i := 0 to 3 do begin
        m.t[i][idx[i]].p := m.t[i][idx[i]].p xor $8000;
        m.t[i][idx[i]].Update(bit, BYTE_LIMIT);
        m.t[i][idx[i]].p := m.t[i][idx[i]].p xor $8000;
      end;
      partial := partial * 2 + Cardinal(bit);
    end;
    value := Integer(partial and $FF);
    if dec <> nil then data[q] := value;
    m.hist := ((m.hist shl 8) or Cardinal(value)) and $FFFFFF;
  end;
end;

initialization
  UseC := GetEnvironmentVariable('PPA_NOC') <> '1';
  InitCriticalSection(PoolLock);
finalization
  PoolFree := nil;
  DoneCriticalSection(PoolLock);
end.
