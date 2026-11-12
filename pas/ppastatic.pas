{ Codec layer 5, the static model: 8-bit images (gray, gray and alpha, RGB,
  RGBA) at the speed of a table lookup a sample. Each sample is predicted by
  LOCO-I's MED (or, a colour channel, by the channel before plus MED of the
  differences to it); its residual is a symbol of one of 320 contexts (an
  energy bin from the residuals around and the channel before's, by
  channel, and the channel before's residual in five levels), coded by rANS with frequencies counted over the band and sent
  before it. Within about a tenth of the slow model's size on photographs;
  drawings are left to the others (ppacodec's choice).

  A band's substream: the length of its first part (a varint); the first
  part, an arithmetic stream of the byte model holding each context's
  frequencies and each line's filter; then the rANS bytes.

  The line loop is in C (ppastaticc.c); PascalStaticRow here is its
  reference, line for line, and the suite demands the same streams from
  both. Integer arithmetic only. }
unit ppastatic;
{$I ppa.inc}
{$ifdef PPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal ppastatic: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal ppastatic: overflow checks ($Q+) are mandatory}{$endif}
{$endif}
{$packrecords c}

interface

uses SysUtils, ppaarith, ppapixels, ppamodel;

{ lines firstRow .. firstRow + rows - 1 of a non-interlaced image (a band),
  or an interlaced image whole, as a substream }
function EncodeImageStatic(var px: TPixels; firstRow, rows: SizeInt): TBytes;
{ the same back from sub[first .. first + len - 1] into px (its layout set);
  False on any damage. streamVersion: the codec stream's (1: the 64
  contexts PPA 0.1.0 wrote, without the channel before's residual; 2: the
  320) }
function DecodeImageStatic(var px: TPixels; firstRow, rows: SizeInt; const sub: TBytes; first, len: SizeInt;
  streamVersion: Integer = 2): Boolean;

var
  { the line loop in C (ppastaticc.c); False: in Pascal, the reference.
    PPA_NOC=1 in the environment makes it False }
  UseStaticC: Boolean = True;

implementation

{$L ppastaticc.o}

const
  SM_PAD = 2;
  SM_PB = 12;
  SM_TOT = 1 shl SM_PB;
  SM_L = Cardinal(1) shl 23;
  N_CTX = 320;
  { the energy bins' thresholds }
  SM_TH: array[0..14] of Integer = (1, 2, 3, 5, 7, 10, 14, 20, 28, 40, 56, 80, 112, 160, 224);

type
  { ppastaticc.c's sm_args_t }
  TStaticArgs = record
    mode: SizeInt;
    px: PByte; fe: PSmallInt;
    w, nc, y: SizeInt;
    src: PByte;
    ebin: PByte;
    rq: PByte;
    cnt: PCardinal;
    rctx: PWord; rsym: PByte; rn: PSizeInt;
    freq, cum: PWord;
    slot: PByte;
    x: PCardinal; buf: PByte; pos: PSizeInt; len: SizeInt;
    { 1: the 64 contexts of stream version 1 (decoding it); 2: the 320 }
    ctxv: SizeInt;
  end;

  TStaticTables = record
    freq: array[0..N_CTX - 1, 0..255] of Word;
    cum: array[0..N_CTX - 1, 0..256] of Word;
    { the symbol at slot 16 k: where the search for a slot's starts }
    slot: array[0..N_CTX - 1, 0..SM_TOT div 16 - 1] of Byte;
  end;
  PStaticTables = ^TStaticTables;

var
  EBIN: array[0..4095] of Byte;
  { the channel before's residual, -255 .. 255: below -2, -2 or -1, 0, 1
    or 2, above 2 }
  RQ_LEVEL: array[0..510] of Byte;

procedure ppas_row(var a: TStaticArgs); cdecl; external name 'ppas_row';

{ ---- the reference: ppastaticc.c's ppas_row, line for line ---- }

function Med3(a, b, c: Integer): Integer; inline;
var lo, hi: Integer;
begin
  if a < b then begin lo := a; hi := b; end else begin lo := b; hi := a; end;
  if c < hi then hi := c;
  if lo > hi then Result := lo else Result := hi;
end;

procedure PascalStaticRow(var a: TStaticArgs);
var
  w, nc, y, xx, ch, i, k, W_, N_, NW_, NE_, P, dW, dN, dNW, fW, fN, fNW, fNE, en, ctx, X_, e, sym, er,
    resPrev, xPrev, rq: Integer;
  rs, rn, pos: SizeInt;
  cur, up: PByte; fc, fu: PSmallInt;
  x, s, f: Cardinal;
begin
  w := a.w; nc := a.nc; y := a.y;
  rs := (w + 2 * SM_PAD) * nc;
  cur := a.px + (y and 1) * rs + SM_PAD * nc;
  up := a.px + ((y + 1) and 1) * rs + SM_PAD * nc;
  fc := a.fe + (y and 1) * rs + SM_PAD * nc;
  fu := a.fe + ((y + 1) and 1) * rs + SM_PAD * nc;
  if a.mode = 1 then rn := a.rn^ else rn := 0;
  if a.mode = 2 then begin x := a.x^; pos := a.pos^; end else begin x := 0; pos := 0; end;
  if y = 0 then up := cur;
  for k := 0 to SM_PAD * nc - 1 do up[w * nc + k] := up[(w - 1) * nc + k mod nc];
  for xx := 0 to w - 1 do begin
    resPrev := 0; xPrev := 0;
    for ch := 0 to nc - 1 do begin
      i := xx * nc + ch;
      W_ := cur[i - nc]; N_ := up[i]; NW_ := up[i - nc]; NE_ := up[i + nc];
      if (ch = 0) or (ch = 3) or (nc < 3) then P := Med3(W_, N_, W_ + N_ - NW_)
      else begin
        dW := W_ - cur[i - nc - 1]; dN := N_ - up[i - 1]; dNW := NW_ - up[i - nc - 1];
        P := xPrev + Med3(dW, dN, dW + dN - dNW);
        if P < 0 then P := 0 else if P > 255 then P := 255;
      end;
      fW := fc[i - nc]; fN := fu[i]; fNW := fu[i - nc]; fNE := fu[i + nc];
      en := Abs(fW) + Abs(fN) + ((Abs(fNW) + Abs(fNE)) shr 1) + ((Abs(W_ - N_) + Abs(N_ - NE_)) shr 3);
      if ch <> 0 then en := en + 2 * Abs(resPrev);
      if en > 4095 then en := 4095;
      rq := RQ_LEVEL[resPrev + 255];
      if a.ctxv = 1 then ctx := EBIN[en] * 4 + (ch and 3)
      else ctx := (EBIN[en] * 4 + (ch and 3)) * 5 + rq;
      if a.mode <> 2 then begin
        X_ := a.src[i];
        e := X_ - P;
        if e < -128 then e := e + 256;
        if e > 127 then e := e - 256;
        if e >= 0 then sym := 2 * e else sym := -2 * e - 1;
        if a.mode = 0 then Inc(a.cnt[ctx * 256 + sym])
        else begin a.rctx[rn] := ctx; a.rsym[rn] := sym; Inc(rn); end;
      end else begin
        s := x and (SM_TOT - 1);
        sym := a.slot[ctx * (SM_TOT div 16) + Integer(s shr 4)];
        while a.cum[ctx * 257 + sym + 1] <= s do Inc(sym);
        { the Word into a Cardinal first: Cardinal(a.freq[..]) loads 4 bytes
          (FreePascal's movzx + and made a mov, -O2 x86-64), 2 past the
          element: into cum here, but no read past what it means to read }
        f := a.freq[ctx * 256 + sym];
        x := f * (x shr SM_PB) + s - a.cum[ctx * 257 + sym];
        while x < SM_L do begin
          if (pos >= 0) and (pos < a.len) then x := (x shl 8) or a.buf[pos] else x := x shl 8;
          Inc(pos);
        end;
        if (sym and 1) <> 0 then e := -((sym + 1) shr 1) else e := sym shr 1;
        X_ := (P + e) and 255;
        a.src[i] := X_;
      end;
      cur[i] := X_;
      er := X_ - P;
      fc[i] := er;
      resPrev := er; xPrev := X_;
    end;
  end;
  if a.mode = 1 then a.rn^ := rn;
  if a.mode = 2 then begin a.x^ := x; a.pos^ := pos; end;
end;

{ ---- a band's walk ---- }

type
  TStaticWalk = record
    px: array of Byte;
    fe: array of SmallInt;
    a: TStaticArgs;
  end;

procedure BandRange(const px: TPixels; pi_, firstRow, rows: SizeInt; out y0, y1: SizeInt);
begin
  y0 := 0; y1 := px.passes[pi_].height - 1;
  if Length(px.passes) = 1 then begin
    if firstRow > y0 then y0 := firstRow;
    if (rows < High(SizeInt) - firstRow) and (firstRow + rows - 1 < y1) then y1 := firstRow + rows - 1;
  end;
end;

{ every line of the band (or image), in mode m; filters: each line's
  filter, read (encoding) or written (decoding, after it was decoded) }
procedure Walk(var px: TPixels; firstRow, rows: SizeInt; var a: TStaticArgs);
var pi_, y, y0, y1, rb, rs: SizeInt; wk: TStaticWalk;
begin
  for pi_ := 0 to High(px.passes) do begin
    rb := px.passes[pi_].rowBytes;
    BandRange(px, pi_, firstRow, rows, y0, y1);
    if (rb = 0) or (y1 < y0) then Continue;
    rs := (rb div px.bpp + 2 * SM_PAD) * px.bpp;
    wk.px := nil; SetLength(wk.px, 2 * rs);
    wk.fe := nil; SetLength(wk.fe, 2 * rs);
    a.px := @wk.px[0]; a.fe := @wk.fe[0];
    a.w := rb div px.bpp; a.nc := px.bpp;
    for y := y0 to y1 do begin
      a.y := y - y0;
      a.src := @px.data[px.passes[pi_].first + y * rb];
      if UseStaticC then ppas_row(a) else PascalStaticRow(a);
    end;
  end;
end;

{ ---- the tables ---- }

{ the counts scaled to SM_TOT, every symbol seen at least 1; an unused
  context keeps none }
procedure Normalize(const cnt: array of Cardinal; var freq: array of Word);
var s, best, d, take: Integer; tot, sum: Int64;
begin
  tot := 0;
  for s := 0 to 255 do begin Inc(tot, cnt[s]); freq[s] := 0; end;
  if tot = 0 then Exit;
  sum := 0; best := 0;
  for s := 0 to 255 do
    if cnt[s] > 0 then begin
      freq[s] := (Int64(cnt[s]) * SM_TOT) div tot;
      if freq[s] < 1 then freq[s] := 1;
      Inc(sum, freq[s]);
      if cnt[s] > cnt[best] then best := s;
    end;
  d := SM_TOT - sum;
  if d > 0 then Inc(freq[best], d);
  while d < 0 do begin
    { from the largest frequency, the first of them }
    best := 0;
    for s := 1 to 255 do if freq[s] > freq[best] then best := s;
    take := freq[best] - 1;
    if take > -d then take := -d;
    Dec(freq[best], take);
    Inc(d, take);
  end;
end;

procedure PutVar(var b: TBytes; var n: SizeInt; v: Cardinal);
begin
  repeat
    if n = Length(b) then SetLength(b, 2 * n + 256);
    if v >= 128 then b[n] := Byte(v and 127) or 128 else b[n] := Byte(v);
    Inc(n);
    v := v shr 7;
  until v = 0;
end;

function GetVar(const b: TBytes; var p: SizeInt; out v: Cardinal): Boolean;
var sh: Integer; c: Byte;
begin
  Result := False; v := 0; sh := 0;
  repeat
    if (p >= Length(b)) or (sh > 28) then Exit;
    c := b[p]; Inc(p);
    v := v or (Cardinal(c and 127) shl sh);
    Inc(sh, 7);
  until c < 128;
  Result := True;
end;

{ the filters of the band's lines, in order }
procedure CollectFilters(const px: TPixels; firstRow, rows: SizeInt; var b: TBytes; var n: SizeInt; put: Boolean);
var pi_, y, y0, y1: SizeInt;
begin
  for pi_ := 0 to High(px.passes) do begin
    BandRange(px, pi_, firstRow, rows, y0, y1);
    for y := y0 to y1 do begin
      if put then begin
        if n = Length(b) then SetLength(b, 2 * n + 256);
        b[n] := px.filters[px.passes[pi_].firstLine + y];
      end;
      Inc(n);
    end;
  end;
end;

function EncodeImageStatic(var px: TPixels; firstRow, rows: SizeInt): TBytes;
var
  a: TStaticArgs;
  cnt: array of Cardinal;
  t: PStaticTables;
  rsym, meta, ans, part: TBytes;
  rctx: array of Word;
  rn, k, n, mn, on, i, nf: SizeInt;
  c, s, last, used: Integer;
  x, xmax: Cardinal; fr: Cardinal;
  enc: TArithEncoder; bm: TByteModel;
begin
  New(t);
  try
    FillChar(t^, SizeOf(TStaticTables), 0);
    a := Default(TStaticArgs);
    a.ebin := @EBIN[0]; a.rq := @RQ_LEVEL[0]; a.ctxv := 2;
    { the counts }
    cnt := nil; SetLength(cnt, N_CTX * 256);
    a.mode := 0; a.cnt := @cnt[0];
    Walk(px, firstRow, rows, a);
    n := 0;
    for k := 0 to High(cnt) do Inc(n, cnt[k]);
    for c := 0 to N_CTX - 1 do begin
      Normalize(cnt[c * 256 .. c * 256 + 255], t^.freq[c]);
      t^.cum[c, 0] := 0;
      for s := 0 to 255 do t^.cum[c, s + 1] := t^.cum[c, s] + t^.freq[c, s];
    end;
    { the symbols, in order }
    rctx := nil; SetLength(rctx, n + 1); rsym := nil; SetLength(rsym, n + 1);
    rn := 0;
    a.mode := 1; a.rctx := @rctx[0]; a.rsym := @rsym[0]; a.rn := @rn;
    Walk(px, firstRow, rows, a);
    { the first part: the frequencies, the filters }
    meta := nil; mn := 0;
    for c := 0 to N_CTX - 1 do begin
      used := 0;
      for s := 0 to 255 do if t^.freq[c, s] > 0 then Inc(used);
      PutVar(meta, mn, used);
      last := -1;
      for s := 0 to 255 do
        if t^.freq[c, s] > 0 then begin
          PutVar(meta, mn, s - last - 1);
          PutVar(meta, mn, t^.freq[c, s] - 1);
          last := s;
        end;
    end;
    nf := mn;
    CollectFilters(px, firstRow, rows, meta, mn, True);
    SetLength(meta, mn);
    enc.Init;
    enc.Direct(mn, 32);
    enc.Direct(nf, 32);
    bm.Init;
    CodeBytes(bm, meta, 0, mn, @enc, nil);
    part := enc.Finish;
    { rANS: the symbols last first, the bytes then reversed }
    ans := nil; SetLength(ans, rn + rn div 2 + 64); on := 0;
    x := SM_L;
    {$push}{$R-}{$Q-}
    for k := rn - 1 downto 0 do begin
      c := rctx[k]; s := rsym[k];
      fr := t^.freq[c, s];
      { a symbol the counts did not see: never, unless the two walks differ;
        without this the loop below would never end }
      if fr = 0 then raise Exception.Create('ppastatic: a symbol without a frequency');
      xmax := ((SM_L shr SM_PB) shl 8) * fr;
      while x >= xmax do begin
        if on = Length(ans) then SetLength(ans, 2 * on + 64);
        ans[on] := Byte(x); Inc(on); x := x shr 8;
      end;
      x := ((x div fr) shl SM_PB) + (x mod fr) + t^.cum[c, s];
    end;
    {$pop}
    if on + 4 > Length(ans) then SetLength(ans, on + 4);
    for i := 0 to 3 do begin ans[on] := Byte(x); Inc(on); x := x shr 8; end;
    { the substream }
    Result := nil; n := 0;
    PutVar(Result, n, Length(part));
    SetLength(Result, n + Length(part) + on);
    if Length(part) > 0 then Move(part[0], Result[n], Length(part));
    Inc(n, Length(part));
    for i := 0 to on - 1 do Result[n + i] := ans[on - 1 - i];
  finally
    Dispose(t);
  end;
end;

function DecodeImageStatic(var px: TPixels; firstRow, rows: SizeInt; const sub: TBytes; first, len: SizeInt;
  streamVersion: Integer): Boolean;
var
  t: PStaticTables;
  a: TStaticArgs;
  head, part, meta: TBytes;
  p, plen, mn, nf, nlines, k, pos: SizeInt;
  v, used, gap, f: Cardinal;
  c, s, j, last: Integer;
  sum: Cardinal;
  dec: TArithDecoder; bm: TByteModel;
  x: Cardinal;
  pi_, y, y0, y1: SizeInt;
  rans: TBytes;
  usedCtx: Integer;
begin
  Result := False;
  if streamVersion = 1 then usedCtx := 64 else usedCtx := N_CTX;
  if (first < 0) or (len < 1) or (first + len > Length(sub)) then Exit;
  { the first part's length }
  if len < 10 then head := Copy(sub, first, len) else head := Copy(sub, first, 10);
  p := 0;
  if not GetVar(head, p, v) then Exit;
  plen := v;
  if p + plen > len then Exit;
  part := Copy(sub, first + p, plen);
  rans := Copy(sub, first + p + plen, len - p - plen);
  dec.Init(part, 0);
  mn := dec.Direct(32);
  nf := dec.Direct(32);
  nlines := 0; meta := nil;
  CollectFilters(px, firstRow, rows, meta, nlines, False);
  if (nf > mn) or (mn - nf <> nlines) or (nf > N_CTX * 256 * 3 * 3 + N_CTX * 2) then Exit;
  meta := nil; SetLength(meta, mn);
  bm.Init;
  CodeBytes(bm, meta, 0, mn, nil, @dec);
  New(t);
  try
    FillChar(t^, SizeOf(TStaticTables), 0);
    { the frequencies, checked: each used context sums to SM_TOT }
    p := 0;
    for c := 0 to usedCtx - 1 do begin
      if (p >= nf) or not GetVar(meta, p, used) or (used > 256) then Exit;
      last := -1; sum := 0;
      for k := 1 to used do begin
        if not GetVar(meta, p, gap) or not GetVar(meta, p, f) or (p > nf) then Exit;
        s := last + 1 + Integer(gap);
        if (gap > 255) or (s > 255) or (f >= SM_TOT) then Exit;
        t^.freq[c, s] := f + 1;
        Inc(sum, f + 1);
        last := s;
      end;
      if used = 0 then t^.freq[c, 0] := SM_TOT   { never used: any table will do }
      else if sum <> SM_TOT then Exit;
      t^.cum[c, 0] := 0;
      for s := 0 to 255 do begin
        t^.cum[c, s + 1] := t^.cum[c, s] + t^.freq[c, s];
        for j := t^.cum[c, s] to t^.cum[c, s + 1] - 1 do
          if j and 15 = 0 then t^.slot[c, j shr 4] := s;
      end;
    end;
    if p <> nf then Exit;
    { the filters }
    k := nf;
    for pi_ := 0 to High(px.passes) do begin
      BandRange(px, pi_, firstRow, rows, y0, y1);
      for y := y0 to y1 do begin
        if meta[k] > 4 then Exit;
        px.filters[px.passes[pi_].firstLine + y] := meta[k];
        Inc(k);
      end;
    end;
    { the pixels }
    if Length(rans) < 4 then Exit;
    x := (Cardinal(rans[0]) shl 24) or (Cardinal(rans[1]) shl 16) or (Cardinal(rans[2]) shl 8) or rans[3];
    { the encoder's state is SM_L to 2^31 - 1: below, a damaged stream (0
      would never leave the renormalization loop) }
    if (x < SM_L) or (x >= SM_L shl 8) then Exit;
    pos := 4;
    a := Default(TStaticArgs);
    a.mode := 2; a.ebin := @EBIN[0]; a.rq := @RQ_LEVEL[0];
    if streamVersion = 1 then a.ctxv := 1 else a.ctxv := 2;
    a.freq := @t^.freq[0, 0]; a.cum := @t^.cum[0, 0]; a.slot := @t^.slot[0, 0];
    a.x := @x; a.buf := @rans[0]; a.pos := @pos; a.len := Length(rans);
    Walk(px, firstRow, rows, a);
    Result := True;
  finally
    Dispose(t);
  end;
end;

var e, b: Integer;
initialization
  for e := 0 to 4095 do begin
    b := 0;
    while (b < 15) and (e >= SM_TH[b]) do Inc(b);
    EBIN[e] := b;
  end;
  for e := -255 to 255 do
    if e < -2 then RQ_LEVEL[e + 255] := 0
    else if e < 0 then RQ_LEVEL[e + 255] := 1
    else if e = 0 then RQ_LEVEL[e + 255] := 2
    else if e <= 2 then RQ_LEVEL[e + 255] := 3
    else RQ_LEVEL[e + 255] := 4;
  UseStaticC := GetEnvironmentVariable('PPA_NOC') <> '1';
end.
