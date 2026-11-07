{ Codec layer 5, the fast model of an image's bytes: 8-bit samples (gray,
  gray and alpha, RGB, RGBA), each predicted by eight predictors blended
  by their errors around it (a colour channel on its difference to the
  channel before), its residual coded with a few binary decisions from
  counters (zero or not, a second guess, the sign, the magnitude's class
  and bits; the first ones mixed) and a match model. About ten times as quick as ppamodel's
  bit-by-bit model, within a few percent of its size on photographs.
  The lines' filters are coded as ppamodel codes them.
  The pixel loop is in C (ppafastc.c); PascalFastRow here is its reference,
  the same arithmetic, and the suite demands the same streams from both.
  Integer arithmetic only. }
unit ppafast;
{$I ppa.inc}
{$ifdef PPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal ppafast: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal ppafast: overflow checks ($Q+) are mandatory}{$endif}
{$endif}
{$packrecords c}

interface

uses SysUtils, ppaarith, ppapixels, ppamodel;

{ the images the fast model takes: 8-bit samples, not a palette }
function FastEligible(const info: TImageInfo): Boolean;

{ as ppamodel.CodeImageBand: lines firstRow .. firstRow + rows - 1 of a
  non-interlaced image (a band, its own model), or an interlaced image whole }
procedure CodeImageFast(var px: TPixels; firstRow, rows: SizeInt; enc: PArithEncoder; dec: PArithDecoder);

var
  { the pixel loop in C (ppafastc.c); False: in Pascal, the reference.
    PPA_NOC=1 in the environment makes it False }
  UseFastC: Boolean = True;

implementation

{$L ppafastc.o}

const
  N_PRED = 8;
  E_BINS = 16;
  QT = 4;
  Q_EB = 1;
  FM_PAD = 2;
  H_BITS = 18;            { the hashed counters: 2^18 (1 MB) }
  C_BITS = 16;            { the last value of each exact neighbourhood: 2^16 }
  M_BITS = 18;            { the match model's positions: 2^18 }
  FILTER_LIMIT = 30;
  W_LIMIT = 131071;       { a weight's bound: four inputs and the bias stay inside 32 bits }
  { the energy bins' thresholds }
  EB_TH: array[0..E_BINS - 2] of Integer = (1, 2, 3, 5, 7, 10, 14, 20, 28, 40, 56, 80, 112, 160, 224);

type
  TFCounter = record
    p: Word;
    n, pad: Byte;
  end;
  PFCounter = ^TFCounter;
  TFMix = record
    w: array[0..127, 0..4] of LongInt;
    apm: array[0..127, 0..32] of Word;
  end;
  { ppafastc.c's fm_tables_t }
  TFastTables = record
    nzm: array[0..3, 0..624, 0..3] of TFCounter;
    qd: array[0..3, 0..9, 0..3] of TFCounter;
    qs: array[0..3, 0..624] of TFCounter;
    ns: array[0..3, 0..624] of TFCounter;
    ncl: array[0..1, 0..3, 0..624] of TFCounter;
    cls: array[0..3, 0..E_BINS - 1, 0..7] of TFCounter;
    mant: array[0..3, 0..E_BINS - 1, 0..7] of TFCounter;
    low: array[0..3, 0..7, 0..7] of TFCounter;
    mz, mq: TFMix;
    mc: array[0..1] of TFMix;
  end;
  PFastTables = ^TFastTables;
  PFMix = ^TFMix;
  { ppafastc.c's fm_args_t }
  TFastArgs = record
    t: PFastTables;
    h: PFCounter; hbits: SizeInt;
    ctab: PWord; cbits: SizeInt;
    mtab: PCardinal; mbits: SizeInt;
    px: PByte; fe: PSmallInt; pe: PByte;
    w, nc, y: SizeInt;
    data: PByte; rowPos, bandStart: SizeInt;
    mptr, mlen: PSizeInt;
    recip: PInteger; stretchTab: PSmallInt; squashTab: PWord;
    invsq: PInteger; ebin: PByte; q3: PByte;
    x1, x2, x: PCardinal; buf: PByte; pos: PSizeInt; len, encoding: SizeInt;
  end;

  { the model's state for one band or image }
  TFastModel = record
    t: PFastTables;
    h: array of TFCounter;
    ctab: array of Word;
    mtab: array of Cardinal;
    px: array of Byte;
    fe: array of SmallInt;
    pe: array of Byte;
    mptr, mlen: SizeInt;
  end;

var
  INVSQ: array[0..1023] of Integer;
  EBIN: array[0..2047] of Byte;
  Q3: array[0..511] of Byte;

procedure ppaf_row(var a: TFastArgs); cdecl; external name 'ppaf_row';

function FastEligible(const info: TImageInfo): Boolean;
begin
  Result := (info.depth = 8) and (info.colorType in [0, 2, 4, 6]);
end;

procedure InitTables(t: PFastTables);
var i, j: Integer; c: PFCounter; mixes: array[0..3] of PFMix;
begin
  FillChar(t^, SizeOf(TFastTables), 0);
  { every counter at 1/2: the counters are the record's start, up to mz }
  c := PFCounter(t);
  while PByte(c) < PByte(@t^.mz) do begin c^.p := 32768; Inc(c); end;
  mixes[0] := @t^.mz; mixes[1] := @t^.mq; mixes[2] := @t^.mc[0]; mixes[3] := @t^.mc[1];
  for i := 0 to 3 do
    for j := 0 to 127 do begin
      mixes[i]^.w[j, 0] := 16384; mixes[i]^.w[j, 1] := 16384;
      mixes[i]^.w[j, 2] := 16384; mixes[i]^.w[j, 3] := 16384; mixes[i]^.w[j, 4] := 0;
    end;
end;

procedure InitApm(t: PFastTables);
var i, j, k: Integer; mixes: array[0..3] of PFMix;
begin
  mixes[0] := @t^.mz; mixes[1] := @t^.mq; mixes[2] := @t^.mc[0]; mixes[3] := @t^.mc[1];
  for i := 0 to 3 do
    for j := 0 to 127 do
      for k := 0 to 32 do mixes[i]^.apm[j, k] := Squash((k - 16) * 128);
end;

procedure InitModel(var m: TFastModel; w, nc: SizeInt);
var i: SizeInt; rs: SizeInt;
begin
  New(m.t);
  InitTables(m.t);
  InitApm(m.t);
  m.h := nil; SetLength(m.h, SizeInt(1) shl H_BITS);
  for i := 0 to High(m.h) do m.h[i].p := 32768;
  m.ctab := nil; SetLength(m.ctab, SizeInt(1) shl C_BITS);
  m.mtab := nil; SetLength(m.mtab, SizeInt(1) shl M_BITS);
  rs := (w + 2 * FM_PAD) * nc;
  m.px := nil; SetLength(m.px, 3 * rs);
  m.fe := nil; SetLength(m.fe, 2 * rs);
  m.pe := nil; SetLength(m.pe, 3 * rs * 8);
  m.mptr := 0; m.mlen := 0;
end;

{ a pass or a band starts: its lines see nothing before it }
procedure NewPass(var m: TFastModel; w, nc: SizeInt);
var rs: SizeInt;
begin
  rs := (w + 2 * FM_PAD) * nc;
  if Length(m.px) < 3 * rs then begin
    SetLength(m.px, 3 * rs); SetLength(m.fe, 2 * rs); SetLength(m.pe, 3 * rs * 8);
  end;
  FillChar(m.px[0], Length(m.px), 0);
  FillChar(m.fe[0], Length(m.fe) * SizeOf(SmallInt), 0);
  FillChar(m.pe[0], Length(m.pe), 0);
end;

{ ---- the reference: ppafastc.c's ppaf_row, the same arithmetic (the C is specialized by pixel size and direction, its blend in SSE2 or SWAR) ---- }

type
  TCoder = record
    x1, x2, x: Cardinal;
    buf: PByte; pos, len: SizeInt;
    enc: Boolean;
  end;

function CodeBitP(var c: TCoder; bit, p: Integer): Integer;
var xm: Cardinal; b: Byte;
begin
  xm := c.x1 + Cardinal((QWord(c.x2 - c.x1) * Cardinal(p)) shr 16);
  if c.enc then begin
    if bit <> 0 then c.x2 := xm else c.x1 := xm + 1;
    while ((c.x1 xor c.x2) and $FF000000) = 0 do begin
      c.buf[c.pos] := Byte(c.x2 shr 24); Inc(c.pos);
      c.x1 := c.x1 shl 8; c.x2 := (c.x2 shl 8) or 255;
    end;
  end else begin
    if c.x <= xm then begin bit := 1; c.x2 := xm; end else begin bit := 0; c.x1 := xm + 1; end;
    while ((c.x1 xor c.x2) and $FF000000) = 0 do begin
      if (c.pos >= 0) and (c.pos < c.len) then b := c.buf[c.pos] else b := 0;
      Inc(c.pos);
      c.x1 := c.x1 shl 8; c.x2 := (c.x2 shl 8) or 255; c.x := (c.x shl 8) or b;
    end;
  end;
  Result := bit;
end;

function ClampI(v, a, b: Integer): Integer; inline;
begin
  if v < a then Result := a else if v > b then Result := b else Result := v;
end;

function Clamp255(v: Integer): Integer; inline;
begin
  if v < 0 then Result := 0 else if v > 255 then Result := 255 else Result := v;
end;

{ the C's cupd: p toward the target by RECIPROCAL[n] / 65536 of the way, the product's floor }
procedure CUpd(var c: TFCounter; bit, lim: Integer);
var d: Integer;
begin
  if bit <> 0 then d := 65535 - c.p else d := 1 - c.p;
  c.p := Word(c.p + Integer(SarInt64(Int64(d) * RECIPROCAL[c.n], 16)));
  if c.n < lim then Inc(c.n);
end;

function MixBit(var c: TCoder; var m: TFMix; apm: Boolean; var c0, c1, c2, c3: TFCounter;
  sel, bit: Integer): Integer;
var s0, s1, s2, s3, dot, p, pf, lo, wt, err, ai, g: Integer;
begin
  s0 := STRETCH_TAB[c0.p shr 4]; s1 := STRETCH_TAB[c1.p shr 4];
  s2 := STRETCH_TAB[c2.p shr 4]; s3 := STRETCH_TAB[c3.p shr 4];
  dot := SarLongint(m.w[sel, 0] * s0 + m.w[sel, 1] * s1 + m.w[sel, 2] * s2 + m.w[sel, 3] * s3 + m.w[sel, 4] * 256, 16);
  dot := ClampI(dot, -2047, 2047);
  p := SQUASH_TAB[dot + 2048];
  lo := 0; wt := 0;
  if apm then begin
    lo := (dot + 2048) shr 7; wt := (dot + 2048) and 127;
    pf := SarLongint(p + 3 * SarLongint(m.apm[sel, lo] * (128 - wt) + m.apm[sel, lo + 1] * wt, 7), 2);
  end else pf := p;
  pf := ClampI(pf, 32, 65535 - 32);
  bit := CodeBitP(c, bit, pf);
  err := SarLongint((bit shl 16) - p, 4);
  m.w[sel, 0] := ClampI(m.w[sel, 0] + SarLongint(s0 * err, 10), -W_LIMIT, W_LIMIT);
  m.w[sel, 1] := ClampI(m.w[sel, 1] + SarLongint(s1 * err, 10), -W_LIMIT, W_LIMIT);
  m.w[sel, 2] := ClampI(m.w[sel, 2] + SarLongint(s2 * err, 10), -W_LIMIT, W_LIMIT);
  m.w[sel, 3] := ClampI(m.w[sel, 3] + SarLongint(s3 * err, 10), -W_LIMIT, W_LIMIT);
  m.w[sel, 4] := ClampI(m.w[sel, 4] + SarLongint(256 * err, 10), -W_LIMIT, W_LIMIT);
  CUpd(c0, bit, 255); CUpd(c1, bit, 255); CUpd(c2, bit, 255); CUpd(c3, bit, 255);
  if apm then begin
    ai := lo + (wt shr 6);
    if bit <> 0 then g := 65535 else g := 0;
    m.apm[sel, ai] := Word(m.apm[sel, ai] + SarLongint(g - m.apm[sel, ai], 6));
  end;
  Result := bit;
end;

{ the C's mixbit2: two counters (weights 0, 1 and the bias's, 4) }
function MixBit2(var c: TCoder; var m: TFMix; apm: Boolean; var c0, c1: TFCounter; sel, bit: Integer): Integer;
var s0, s1, dot, p, pf, lo, wt, err, ai, g: Integer;
begin
  s0 := STRETCH_TAB[c0.p shr 4]; s1 := STRETCH_TAB[c1.p shr 4];
  dot := SarLongint(m.w[sel, 0] * s0 + m.w[sel, 1] * s1 + m.w[sel, 4] * 256, 16);
  dot := ClampI(dot, -2047, 2047);
  p := SQUASH_TAB[dot + 2048];
  lo := 0; wt := 0;
  if apm then begin
    lo := (dot + 2048) shr 7; wt := (dot + 2048) and 127;
    pf := SarLongint(p + 3 * SarLongint(m.apm[sel, lo] * (128 - wt) + m.apm[sel, lo + 1] * wt, 7), 2);
  end else pf := p;
  pf := ClampI(pf, 32, 65535 - 32);
  bit := CodeBitP(c, bit, pf);
  err := SarLongint((bit shl 16) - p, 4);
  m.w[sel, 0] := ClampI(m.w[sel, 0] + SarLongint(s0 * err, 10), -W_LIMIT, W_LIMIT);
  m.w[sel, 1] := ClampI(m.w[sel, 1] + SarLongint(s1 * err, 10), -W_LIMIT, W_LIMIT);
  m.w[sel, 4] := ClampI(m.w[sel, 4] + SarLongint(256 * err, 10), -W_LIMIT, W_LIMIT);
  CUpd(c0, bit, 255); CUpd(c1, bit, 255);
  if apm then begin
    ai := lo + (wt shr 6);
    if bit <> 0 then g := 65535 else g := 0;
    m.apm[sel, ai] := Word(m.apm[sel, ai] + SarLongint(g - m.apm[sel, ai], 6));
  end;
  Result := bit;
end;

function OneBit(var c: TCoder; var k: TFCounter; bit: Integer): Integer;
begin
  bit := CodeBitP(c, bit, ClampI(k.p, 32, 65535 - 32));
  CUpd(k, bit, 60);
  Result := bit;
end;

function Fold(e: Integer): Integer; inline;
begin
  if e < -128 then Result := e + 256 else if e > 127 then Result := e - 256 else Result := e;
end;

{$push}{$Q-}{$R-}
function Hsh(a: Cardinal): Cardinal; inline;
begin
  a := a * Cardinal(2654435761);
  Result := a xor (a shr 15);
end;

function HIdx(h, add, mul: Cardinal; shift: Integer): SizeInt; inline;
begin
  Result := SizeInt(Cardinal((h + add) * mul) shr shift);
end;
{$pop}

procedure PascalFastRow(var m: TFastModel; var a: TFastArgs);
var
  T: PFastTables;
  hs, cs, w, nc, y, x, ch, i, chx, k, j: Integer;
  rs: SizeInt;
  cur, up, up2, ec, eu, eu2, data, src: PByte;
  fc, fu: PSmallInt;
  mptr, mlen, spos, cand, l: SizeInt;
  c: TCoder;
  resPrev, resPrev2, xPrev, W_, N_, NW_, NE_, mx, mn, dW, dN, dNW, dNE, dWW, dNN: Integer;
  pr: array[0..N_PRED - 1] of Integer;
  cp: array[0..N_PRED - 1] of Integer;
  sw, sp, pmx, pmn, e8, wt, q, P, fW, fN, fNW, fNE, energy, eb, eb4, sg, sel, mexp, mst, X_, e, z: Integer;
  hx, hn, hh, t_: Cardinal; k6: QWord;
  cslot: PWord;
  qq, c2, src2, cv, qi, sn, av0, kk, more, av, er: Integer;

  function Q3v(v: Integer): Integer; inline;
  begin
    Result := Q3[v and 511];
  end;

  function HC(h, add, mul: Cardinal): PFCounter; inline;
  begin
    Result := @m.h[HIdx(h, add, mul, hs)];
  end;

begin
  T := m.t;
  hs := 32 - H_BITS; cs := 32 - C_BITS;
  w := a.w; nc := a.nc; y := a.y;
  rs := (w + 2 * FM_PAD) * nc;
  cur := @m.px[(y mod 3) * rs + FM_PAD * nc];
  up := @m.px[((y + 2) mod 3) * rs + FM_PAD * nc];
  up2 := @m.px[((y + 1) mod 3) * rs + FM_PAD * nc];
  fc := @m.fe[(y and 1) * rs + FM_PAD * nc];
  fu := @m.fe[((y + 1) and 1) * rs + FM_PAD * nc];
  ec := @m.pe[((y mod 3) * rs + FM_PAD * nc) * 8];
  eu := @m.pe[(((y + 2) mod 3) * rs + FM_PAD * nc) * 8];
  eu2 := @m.pe[(((y + 1) mod 3) * rs + FM_PAD * nc) * 8];
  data := a.data; src := data + a.rowPos;
  mptr := a.mptr^; mlen := a.mlen^;
  c.x1 := a.x1^; c.x2 := a.x2^; c.enc := a.encoding <> 0;
  if c.enc then c.x := 0 else c.x := a.x^;
  c.buf := a.buf; c.pos := a.pos^; c.len := a.len;

  { as the C: the buffers start at zero (NewPass), the left padding stays so }
  if y = 0 then begin up := cur; up2 := cur; end else if y = 1 then up2 := up;
  for k := 0 to FM_PAD * nc - 1 do up[w * nc + k] := up[(w - 1) * nc + k mod nc];

  for x := 0 to w - 1 do begin
    resPrev := 0; resPrev2 := 0; xPrev := 0;
    for ch := 0 to nc - 1 do begin
      i := x * nc + ch; chx := ch and 3;
      W_ := cur[i - nc]; N_ := up[i]; NW_ := up[i - nc]; NE_ := up[i + nc];
      if (ch = 0) or (ch = 3) or (nc < 3) then begin
        if W_ > N_ then begin mx := W_; mn := N_; end else begin mx := N_; mn := W_; end;
        pr[0] := W_; pr[1] := N_; pr[2] := NE_; pr[3] := W_ + N_ - NW_;
        if NW_ >= mx then pr[4] := mn else if NW_ <= mn then pr[4] := mx else pr[4] := W_ + N_ - NW_;
        pr[5] := (W_ + NE_ + 1) shr 1;
        pr[6] := 2 * W_ - cur[i - 2 * nc]; pr[7] := 2 * N_ - up2[i];
      end else begin
        dW := W_ - cur[i - nc - 1]; dN := N_ - up[i - 1]; dNW := NW_ - up[i - nc - 1]; dNE := NE_ - up[i + nc - 1];
        dWW := cur[i - 2 * nc] - cur[i - 2 * nc - 1]; dNN := up2[i] - up2[i - 1];
        if dW > dN then begin mx := dW; mn := dN; end else begin mx := dN; mn := dW; end;
        pr[0] := xPrev + dW; pr[1] := xPrev + dN; pr[2] := xPrev + dNE; pr[3] := xPrev + dW + dN - dNW;
        if dNW >= mx then pr[4] := xPrev + mn else if dNW <= mn then pr[4] := xPrev + mx
        else pr[4] := xPrev + dW + dN - dNW;
        pr[5] := xPrev + SarLongint(dW + dNE + 1, 1);
        pr[6] := xPrev + 2 * dW - dWW; pr[7] := xPrev + 2 * dN - dNN;
      end;
      sw := 0; sp := 0; pmx := 0; pmn := 255;
      for k := 0 to N_PRED - 1 do begin
        e8 := 2 * (ec[(i - nc) * 8 + k] + eu[i * 8 + k]) + eu[(i - nc) * 8 + k] + eu[(i + nc) * 8 + k]
              + ec[(i - 2 * nc) * 8 + k] + eu2[i * 8 + k];
        if e8 > 1023 then e8 := 1023;
        wt := INVSQ[e8];
        q := Clamp255(pr[k]);
        cp[k] := q;
        sw := sw + wt; sp := sp + wt * q;
        if q > pmx then pmx := q;
        if q < pmn then pmn := q;
      end;
      P := (sp + (sw shr 1)) div sw;
      fW := fc[i - nc]; fN := fu[i]; fNW := fu[i - nc]; fNE := fu[i + nc];
      energy := Abs(fW) + Abs(fN) + ((Abs(fNW) + Abs(fNE)) shr 1) + (pmx - pmn);
      if ch <> 0 then energy := energy + 2 * Abs(resPrev);
      if energy > 2047 then energy := 2047;
      eb := EBIN[energy]; eb4 := eb shr 2;
      sg := Q3v(fW) + 5 * Q3v(fN) + 25 * Q3v(resPrev) + 125 * Q3v(resPrev2);
      hx := Hsh(Cardinal(xPrev) or (Cardinal((P - xPrev) and 511) shl 8) or (Cardinal(chx) shl 17) or (Cardinal(eb4) shl 19));
      {$push}{$Q-}{$R-}
      hn := (Cardinal(W_) or (Cardinal(N_) shl 8) or (Cardinal(NE_) shl 16) or (Cardinal(NW_) shl 24)) * Cardinal($9E3779B1)
            xor Cardinal(chx + 1) * Cardinal($85EBCA6B);
      {$pop}
      sel := eb or (Ord(chx > 0) shl 4);
      spos := a.rowPos + i;
      if mlen > 0 then mexp := data[mptr] else mexp := -1;
      if mlen = 0 then mst := 0 else if mexp <> P then mst := 3 else if mlen < 16 then mst := 1 else mst := 2;
      if c.enc then begin X_ := src[i]; e := Fold(X_ - P); end else begin X_ := 0; e := 0; end;
      z := MixBit2(c, T^.mz, True, T^.nzm[chx, sg, mst], HC(hx, 0, 1)^, sel, Ord(e = 0));
      cslot := @m.ctab[hn shr cs];
      if z = 0 then begin
        qq := 0; c2 := -1; src2 := 0;
        cv := cslot^ - 1;
        if mst = 3 then begin c2 := mexp; src2 := 4; end
        else if eb > Q_EB then
        else if (cslot^ <> 0) and (Abs(cv - P) > QT) then begin c2 := cv; src2 := 0; end
        else if Abs(W_ - P) > QT then begin c2 := W_; src2 := 1; end
        else if Abs(N_ - P) > QT then begin c2 := N_; src2 := 2; end
        else if Abs(NE_ - P) > QT then begin c2 := NE_; src2 := 3; end;
        if c2 >= 0 then begin
          qi := src2 * 2 + Ord(cslot^ <> 0);
          qq := MixBit(c, T^.mq, False, T^.qd[chx, qi, eb4], T^.qs[chx, sg], HC(hx, 5, $2545F491)^,
            HC(hn, 5, $2545F491)^, qi or (Ord(chx > 0) shl 4), Ord(c.enc and (X_ = c2)));
          if qq <> 0 then e := Fold(c2 - P);
        end;
        if qq = 0 then begin
          sn := OneBit(c, T^.ns[chx, sg], Ord(e < 0));
          if sn <> 0 then av0 := -e else av0 := e;
          k := 0;
          if c.enc then begin
            j := av0 or 1;
            while j > 1 do begin j := j shr 1; Inc(k); end;
          end;
          kk := 0;
          for j := 0 to 6 do begin
            if j < 2 then begin
              {$push}{$Q-}{$R-}
              t_ := Cardinal(sn shl 1 or j) * Cardinal($27D4EB2F) + 3;
              {$pop}
              more := MixBit2(c, T^.mc[j], False, T^.ncl[j, chx, sg], HC(hx, t_, $165667B1)^, sel, Ord(k > j));
            end else more := OneBit(c, T^.cls[chx, eb, j], Ord(k > j));
            if more = 0 then Break;
            Inc(kk);
          end;
          av := 1;
          for j := kk - 1 downto 0 do
            if j = kk - 1 then av := av * 2 + OneBit(c, T^.mant[chx, eb, kk], (av0 shr j) and 1)
            else av := av * 2 + OneBit(c, T^.low[chx, kk, j], (av0 shr j) and 1);
          if sn <> 0 then e := -av else e := av;
        end;
      end;
      if not c.enc then begin X_ := (P + e) and 255; src[i] := X_; end;
      cur[i] := X_;
      cslot^ := Word(X_ + 1);
      er := X_ - P;
      fc[i] := er;
      for k := 0 to N_PRED - 1 do ec[i * 8 + k] := Abs(X_ - cp[k]);
      if (mlen > 0) and (mexp = X_) then begin Inc(mlen); Inc(mptr); end else mlen := 0;
      if spos + 1 - a.bandStart >= 6 then begin
        k6 := QWord(data[spos - 5]) or (QWord(data[spos - 4]) shl 8) or (QWord(data[spos - 3]) shl 16) or
              (QWord(data[spos - 2]) shl 24) or (QWord(data[spos - 1]) shl 32) or (QWord(data[spos]) shl 40);
        {$push}{$Q-}{$R-}
        hh := Cardinal((k6 * QWord($9E3779B97F4A7C15)) shr (64 - M_BITS));
        {$pop}
        if mlen = 0 then begin
          cand := m.mtab[hh];
          if (cand > 0) and (cand <= spos) then begin
            l := 0;
            while (l < 32) and (cand - 1 - l >= a.bandStart) and (data[cand - 1 - l] = data[spos - l]) do Inc(l);
            if l >= 6 then begin mlen := l; mptr := cand; end;
          end;
        end;
        m.mtab[hh] := Cardinal(spos + 1);
      end;
      if mlen > 65535 then mlen := 65535;
      resPrev2 := resPrev; resPrev := er; xPrev := X_;
    end;
  end;
  a.mptr^ := mptr; a.mlen^ := mlen;
  a.x1^ := c.x1; a.x2^ := c.x2;
  if not c.enc then a.x^ := c.x;
  a.pos^ := c.pos;
end;

procedure CodeImageFast(var px: TPixels; firstRow, rows: SizeInt; enc: PArithEncoder; dec: PArithDecoder);
var
  m: TFastModel;
  filt: array[0..5, 1..7] of TAdaptiveBit;
  pi_, y, y0, y1, rb, row: SizeInt;
  prevFilter, f, node, bit, j, i: Integer;
  a: TFastArgs;

  function CodeBit(var cb: TAdaptiveBit; bitIn, limit: Integer): Integer;
  begin
    if enc <> nil then begin enc^.Encode(bitIn, cb.p); Result := bitIn; end
    else Result := dec^.Decode(cb.p);
    cb.Update(Result, limit);
  end;

begin
  InitModel(m, 1, px.bpp);
  try
    for i := 0 to 5 do for j := 1 to 7 do filt[i, j].Init;
    prevFilter := 5;
    a := Default(TFastArgs);
    a.t := m.t;
    a.h := @m.h[0]; a.hbits := H_BITS;
    a.ctab := @m.ctab[0]; a.cbits := C_BITS;
    a.mtab := @m.mtab[0]; a.mbits := M_BITS;
    a.nc := px.bpp;
    if Length(px.data) > 0 then a.data := @px.data[0] else a.data := nil;
    a.mptr := @m.mptr; a.mlen := @m.mlen;
    a.recip := @RECIPROCAL[0]; a.stretchTab := @STRETCH_TAB[0]; a.squashTab := @SQUASH_TAB[0];
    a.invsq := @INVSQ[0]; a.ebin := @EBIN[0]; a.q3 := @Q3[0];
    a.encoding := Ord(enc <> nil);
    for pi_ := 0 to High(px.passes) do begin
      rb := px.passes[pi_].rowBytes;
      y0 := 0; y1 := px.passes[pi_].height - 1;
      if Length(px.passes) = 1 then begin
        if firstRow > y0 then y0 := firstRow;
        if (rows < High(SizeInt) - firstRow) and (firstRow + rows - 1 < y1) then y1 := firstRow + rows - 1;
      end;
      if rb > 0 then begin
        NewPass(m, rb div px.bpp, px.bpp);
        a.px := @m.px[0]; a.fe := @m.fe[0]; a.pe := @m.pe[0];
        a.w := rb div px.bpp;
      end;
      for y := y0 to y1 do begin
        if enc <> nil then f := px.filters[px.passes[pi_].firstLine + y] else f := 0;
        node := 1;
        for j := 2 downto 0 do begin
          bit := CodeBit(filt[prevFilter, node], (f shr j) and 1, FILTER_LIMIT);
          node := node * 2 + bit;
        end;
        f := node - 8;
        { a damaged stream can give 5 to 7, which no PNG has: refused here
          (the filter is a context's index below, and the release build checks
          no ranges) }
        if f > 4 then raise Exception.Create('damaged stream: a line filter above 4');
        if dec <> nil then px.filters[px.passes[pi_].firstLine + y] := f;
        prevFilter := f;
        if rb = 0 then Continue;
        row := px.passes[pi_].first + y * rb;
        a.y := y - y0;
        a.rowPos := row;
        a.bandStart := px.passes[pi_].first + y0 * rb;
        if enc <> nil then begin
          { room for the worst: 24 bytes out for every sample in }
          if enc^.n + 24 * rb + 64 > Length(enc^.d) then SetLength(enc^.d, 2 * (enc^.n + 24 * rb + 64));
          a.x1 := @enc^.x1; a.x2 := @enc^.x2; a.x := nil;
          a.buf := @enc^.d[0]; a.pos := @enc^.n; a.len := Length(enc^.d);
        end else begin
          a.x1 := @dec^.x1; a.x2 := @dec^.x2; a.x := @dec^.x;
          if Length(dec^.d) > 0 then a.buf := @dec^.d[0] else a.buf := nil;
          a.pos := @dec^.p; a.len := Length(dec^.d);
        end;
        if UseFastC then ppaf_row(a) else PascalFastRow(m, a);
      end;
    end;
  finally
    Dispose(m.t);
  end;
end;

var e, b: Integer;
initialization
  for e := 0 to 1023 do begin
    INVSQ[e] := 131068 div ((e + 2) * (e + 2));
    if INVSQ[e] < 1 then INVSQ[e] := 1;
  end;
  for e := 0 to 2047 do begin
    b := 0;
    while (b < E_BINS - 1) and (e >= EB_TH[b]) do Inc(b);
    EBIN[e] := b;
  end;
  for e := -256 to 255 do
    if e > 2 then Q3[e and 511] := 4 else if e > 0 then Q3[e and 511] := 3
    else if e < -2 then Q3[e and 511] := 0 else if e < 0 then Q3[e and 511] := 1 else Q3[e and 511] := 2;
  UseFastC := GetEnvironmentVariable('PPA_NOC') <> '1';
end.
