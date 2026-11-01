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

implementation

const
  NCTX = 6;
  NIN = NCTX + 1;               { the contexts and a bias }
  TABLE_BITS = 20;
  TABLE_MASK = (1 shl TABLE_BITS) - 1;
  COUNTER_LIMIT = 60;
  MIXER_SETS = 16 * 8;          { channel (up to 16 bytes a pixel) x bit position }
  W_MAX = 1 shl 19;
  LEARNING_RATE = 12;
  FILTER_LIMIT = 30;

type
  TModel = record
    t: array[0..NCTX - 1] of array of TAdaptiveBit;
    w: array[0..MIXER_SETS - 1, 0..NIN - 1] of Integer;
    filt: array[0..5, 1..7] of TAdaptiveBit;
  end;

procedure InitModel(var m: TModel);
var i, j: Integer;
begin
  for i := 0 to NCTX - 1 do begin
    m.t[i] := nil;
    SetLength(m.t[i], TABLE_MASK + 1);
    for j := 0 to TABLE_MASK do m.t[i][j].Init;
  end;
  for i := 0 to MIXER_SETS - 1 do
    for j := 0 to NIN - 1 do m.w[i, j] := (1 shl 16) div NCTX;
  for i := 0 to 5 do for j := 1 to 7 do m.filt[i, j].Init;
end;

{ hashes wrap around on purpose }
{$push}{$Q-}{$R-}
function Hash(a, b, c: Cardinal): Cardinal; inline;
begin
  Result := (a * Cardinal(2654435761)) xor (b * Cardinal(2246822519)) xor (c * Cardinal(3266489917));
  Result := Result xor (Result shr 15);
end;

function Slot(base, partial: Cardinal): Cardinal; inline;
begin
  Result := ((base shr (32 - TABLE_BITS)) xor ((partial * Cardinal(2654435761)) shr (32 - TABLE_BITS))) and TABLE_MASK;
end;
{$pop}

function Clamp255(v: Integer): Integer; inline;
begin
  if v < 0 then Result := 0 else if v > 255 then Result := 255 else Result := v;
end;

procedure CodeImage(var px: TPixels; enc: PArithEncoder; dec: PArithDecoder);
var
  m: TModel;
  pi_, y, x, rb, bpp, row, prior, k: SizeInt;
  W, N, NW, NE, grad, avg, res, prevFilter, f, node, bit, j, i: Integer;
  ctxBase: array[0..NCTX - 1] of Cardinal;
  st: array[0..NIN - 1] of Integer;
  idx: array[0..NCTX - 1] of Cardinal;
  dot, p, err, ws, b, value: Integer;
  partial: Cardinal;

  function CodeBit(var c: TAdaptiveBit; bitIn, limit: Integer): Integer;
  begin
    if enc <> nil then begin enc^.Encode(bitIn, c.p); Result := bitIn; end
    else Result := dec^.Decode(c.p);
    c.Update(Result, limit);
  end;

begin
  InitModel(m);
  bpp := px.bpp;
  prevFilter := 5;
  for pi_ := 0 to High(px.passes) do begin
    rb := px.passes[pi_].rowBytes;
    for y := 0 to px.passes[pi_].height - 1 do begin
      { the line's filter: 3 bits, a binary tree }
      if enc <> nil then f := px.filters[px.passes[pi_].firstLine + y] else f := 0;
      node := 1;
      for j := 2 downto 0 do begin
        bit := CodeBit(m.filt[prevFilter, node], (f shr j) and 1, FILTER_LIMIT);
        node := node * 2 + bit;
      end;
      f := node - 8;
      if dec <> nil then px.filters[px.passes[pi_].firstLine + y] := f;
      prevFilter := f;
      row := px.passes[pi_].first + y * rb;
      prior := row - rb;
      for x := 0 to rb - 1 do begin
        k := x mod bpp;
        if x >= bpp then W := px.data[row + x - bpp] else W := 0;
        if y > 0 then N := px.data[prior + x] else N := W;
        if (y > 0) and (x >= bpp) then NW := px.data[prior + x - bpp] else NW := N;
        if (y > 0) and (x + bpp < rb) then NE := px.data[prior + x + bpp] else NE := N;
        grad := Clamp255(W + N - NW);
        avg := (W + N + 1) shr 1;
        { what the previous channel of this pixel left over its gradient }
        if (k > 0) then begin
          i := x - 1;
          res := px.data[row + i];
          if i >= bpp then j := px.data[row + i - bpp] else j := 0;
          if y > 0 then node := px.data[prior + i] else node := j;
          if (y > 0) and (i >= bpp) then b := px.data[prior + i - bpp] else b := node;
          res := res - Clamp255(j + node - b);
        end else res := 0;
        ctxBase[0] := Hash(k, W, 1);
        ctxBase[1] := Hash(k, N, 2);
        ctxBase[2] := Hash(k, grad, 3);
        ctxBase[3] := Hash(k, avg + (Cardinal(Clamp255(NE)) shl 8), 4);
        ctxBase[4] := Hash(k, (W shr 2) or ((N shr 2) shl 6) or ((NE shr 2) shl 12), 5);
        ctxBase[5] := Hash(k, Cardinal(Clamp255(grad + res)) or (Cardinal(res + 256) shl 8), 6);
        if enc <> nil then value := px.data[row + x] else value := 0;
        partial := 1;
        for j := 7 downto 0 do begin
          ws := (k and 15) * 8 + j;
          dot := 0;
          for i := 0 to NCTX - 1 do begin
            idx[i] := Slot(ctxBase[i], partial);
            st[i] := Stretch(m.t[i][idx[i]].p);
            Inc(dot, (m.w[ws, i] * st[i]) div 8192);
          end;
          st[NCTX] := 256;
          Inc(dot, (m.w[ws, NCTX] * st[NCTX]) div 8192);
          p := Squash(dot div 8);
          if enc <> nil then begin bit := (value shr j) and 1; enc^.Encode(bit, p); end
          else bit := dec^.Decode(p);
          { the mixer learns from the error, the counters from the bit }
          err := ((bit shl 16) - p) div 16;
          for i := 0 to NIN - 1 do begin
            m.w[ws, i] := m.w[ws, i] + (st[i] * err * LEARNING_RATE) div 65536;
            if m.w[ws, i] > W_MAX then m.w[ws, i] := W_MAX;
            if m.w[ws, i] < -W_MAX then m.w[ws, i] := -W_MAX;
          end;
          for i := 0 to NCTX - 1 do m.t[i][idx[i]].Update(bit, COUNTER_LIMIT);
          partial := partial * 2 + Cardinal(bit);
        end;
        if dec <> nil then px.data[row + x] := Byte(partial and $FF);
      end;
    end;
  end;
end;

end.
