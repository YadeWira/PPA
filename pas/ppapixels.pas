{ Codec layer 3: the bytes a PNG image's zlib stream holds (filtered
  scanlines, one filter byte before each) split into each line's filter and
  the image's own bytes, and back to the SAME bytes.

  A PNG encoder chooses one filter per line (None, Sub, Up, Average,
  Paeth); with the filter recorded, filtering again is exact. Each Adam7
  pass is its own sub-image with its own lines, and a pass with no columns
  or no rows has no lines at all. The bytes are kept as the image has them:
  a line of 1, 2 or 4-bit samples keeps the bits that pad its last byte.

  What does not fit is not taken: a filter byte above 4, or fewer bytes than
  the image needs. Bytes after the image (some encoders write them) are kept
  as they are. }
unit ppapixels;

{$I ppa.inc}
{$ifopt R-}{$fatal ppapixels: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppapixels: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, ppapng;

const
  { Cap on an image's bytes, filter bytes included: 1 GB. }
  MAX_IMAGE_BYTES = SizeInt(1) shl 30;

type
  TImageInfo = record
    width, height: LongWord;
    depth: Byte;        { bits per sample: 1, 2, 4, 8, 16 }
    colorType: Byte;    { 0 gray, 2 RGB, 3 palette, 4 gray+alpha, 6 RGBA }
    interlace: Byte;    { 0 none, 1 Adam7 }
  end;

  TPass = record
    width, height: SizeInt;   { in pixels; 0 = the pass has no lines }
    rowBytes: SizeInt;        { a line's bytes, without its filter byte }
    first: SizeInt;           { where its lines start in TPixels.data }
    firstLine: SizeInt;       { its first line's index in TPixels.filters }
  end;

  TPixels = record
    info: TImageInfo;
    bpp: SizeInt;                    { bytes per pixel, at least 1: the filters' distance }
    passes: array of TPass;          { 1, or 7 with Adam7 }
    filters: TBytes;                 { each line's filter, in order }
    data: TBytes;                    { the lines without their filter bytes, unfiltered }
    tail: TBytes;                    { bytes after the image }
  end;

{ Whether colour type and depth are a valid PNG pair, and its channels }
function Channels(colorType, depth: Byte): Integer;

{ The image an image stream of the file holds: an IDAT's from its IHDR (or
  a JNG's alpha channel from its JHDR), an fdAT's frame from its fcTL with
  the IHDR's depth and colour type. False when there is no such header, or
  for JDAT and JDAA (they are JPEG). }
function StreamImage(const p: TPng; s: SizeInt; out info: TImageInfo): Boolean;

{ px's layout for the image (bpp, passes, filters and data sized, not
  filled); False if the image is not valid or too large }
function InitLayout(const info: TImageInfo; out px: TPixels): Boolean;
{ How many filtered bytes the image takes (filter bytes included) }
function FilteredSize(const px: TPixels): SizeInt;

{ The image's filtered bytes -> px. False if they do not fit the image. }
function Unfilter(const plain: TBytes; const info: TImageInfo; out px: TPixels): Boolean;
{ px -> the filtered bytes }
function Refilter(const px: TPixels): TBytes;

implementation

const
  ADAM7_X0: array[0..6] of Integer = (0, 4, 0, 2, 0, 1, 0);
  ADAM7_Y0: array[0..6] of Integer = (0, 0, 4, 0, 2, 0, 1);
  ADAM7_DX: array[0..6] of Integer = (8, 8, 4, 4, 2, 2, 1);
  ADAM7_DY: array[0..6] of Integer = (8, 8, 8, 4, 4, 2, 2);

function Channels(colorType, depth: Byte): Integer;
begin
  Result := 0;
  case colorType of
    0: if depth in [1, 2, 4, 8, 16] then Result := 1;
    2: if depth in [8, 16] then Result := 3;
    3: if depth in [1, 2, 4, 8] then Result := 1;
    4: if depth in [8, 16] then Result := 2;
    6: if depth in [8, 16] then Result := 4;
  end;
end;

function Be32(const d: TBytes; i: SizeInt): LongWord; inline;
begin
  Result := (LongWord(d[i]) shl 24) or (LongWord(d[i + 1]) shl 16) or
            (LongWord(d[i + 2]) shl 8) or LongWord(d[i + 3]);
end;

function StreamImage(const p: TPng; s: SizeInt; out info: TImageInfo): Boolean;
var h, fr: SizeInt;
begin
  Result := False;
  info := Default(TImageInfo);
  if not (p.streams[s].kind in [skIdat, skFdat]) then Exit;
  h := p.streams[s].header;
  if h < 0 then Exit;
  with p.chunks[h] do begin
    if (typ = CT_IHDR) and (Length(data) >= 13) then begin
      info.width := Be32(data, 0); info.height := Be32(data, 4);
      info.depth := data[8]; info.colorType := data[9]; info.interlace := data[12];
    end else if (typ = CT_JHDR) and (Length(data) >= 16) then begin
      { a JNG's alpha channel in IDAT: gray, the alpha's depth }
      info.width := Be32(data, 0); info.height := Be32(data, 4);
      info.depth := data[12]; info.colorType := 0; info.interlace := data[15];
    end else Exit;
  end;
  if p.streams[s].kind = skFdat then begin
    fr := p.streams[s].frame;
    if (fr < 0) or (Length(p.chunks[fr].data) < 12) then Exit;
    info.width := Be32(p.chunks[fr].data, 4); info.height := Be32(p.chunks[fr].data, 8);
  end else if (p.streams[s].frame >= 0) then ;
  Result := True;
end;

function Paeth(a, b, c: Integer): Integer; inline;
var p, pa, pb, pc: Integer;
begin
  p := a + b - c;
  pa := Abs(p - a); pb := Abs(p - b); pc := Abs(p - c);
  if (pa <= pb) and (pa <= pc) then Result := a
  else if pb <= pc then Result := b
  else Result := c;
end;

{ The passes' layout; False if the image is too large }
function Layout(var px: TPixels; bitsPerPixel: SizeInt): Boolean;
var np, i: Integer; w, h, total, lines: SizeInt;
begin
  Result := False;
  if px.info.interlace = 1 then np := 7 else np := 1;
  SetLength(px.passes, np);
  total := 0; lines := 0;
  for i := 0 to np - 1 do begin
    if np = 1 then begin w := px.info.width; h := px.info.height; end
    else begin
      if px.info.width > LongWord(ADAM7_X0[i]) then
        w := (SizeInt(px.info.width) - ADAM7_X0[i] + ADAM7_DX[i] - 1) div ADAM7_DX[i] else w := 0;
      if px.info.height > LongWord(ADAM7_Y0[i]) then
        h := (SizeInt(px.info.height) - ADAM7_Y0[i] + ADAM7_DY[i] - 1) div ADAM7_DY[i] else h := 0;
    end;
    if (w = 0) or (h = 0) then begin w := 0; h := 0; end;
    px.passes[i].width := w;
    px.passes[i].height := h;
    { width up to 2^31 and 64 bits per pixel: fits in 64 bits }
    px.passes[i].rowBytes := (Int64(w) * bitsPerPixel + 7) div 8;
    px.passes[i].first := total;
    px.passes[i].firstLine := lines;
    if (h > 0) and (px.passes[i].rowBytes + 1 > (MAX_IMAGE_BYTES - total - lines) div h) then Exit;
    Inc(total, px.passes[i].rowBytes * h);
    Inc(lines, h);
  end;
  SetLength(px.filters, lines);
  SetLength(px.data, total);
  Result := True;
end;

function InitLayout(const info: TImageInfo; out px: TPixels): Boolean;
var ch: Integer; bits: SizeInt;
begin
  Result := False;
  px := Default(TPixels);
  px.info := info;
  ch := Channels(info.colorType, info.depth);
  if (ch = 0) or (info.interlace > 1) or (info.width = 0) or (info.height = 0) then Exit;
  bits := SizeInt(ch) * info.depth;
  px.bpp := (bits + 7) div 8;
  Result := Layout(px, bits);
end;

function FilteredSize(const px: TPixels): SizeInt;
begin
  Result := Length(px.data) + Length(px.filters);
end;

function Unfilter(const plain: TBytes; const info: TImageInfo; out px: TPixels): Boolean;
var
  i: Integer; need: SizeInt;
  pi_, y, x, rb, src, dst, prior, bpp: SizeInt;
  f: Byte; a, b, c: Integer;
begin
  Result := False;
  if not InitLayout(info, px) then Exit;
  bpp := px.bpp;
  need := FilteredSize(px);
  if Length(plain) < need then Exit;

  src := 0;
  for pi_ := 0 to High(px.passes) do begin
    rb := px.passes[pi_].rowBytes;
    for y := 0 to px.passes[pi_].height - 1 do begin
      f := plain[src]; Inc(src);
      if f > 4 then Exit;
      px.filters[px.passes[pi_].firstLine + y] := f;
      dst := px.passes[pi_].first + y * rb;
      prior := dst - rb;           { the line above, in the same pass }
      for x := 0 to rb - 1 do begin
        if x >= bpp then a := px.data[dst + x - bpp] else a := 0;
        if y > 0 then b := px.data[prior + x] else b := 0;
        if (x >= bpp) and (y > 0) then c := px.data[prior + x - bpp] else c := 0;
        case f of
          0: i := plain[src + x];
          1: i := plain[src + x] + a;
          2: i := plain[src + x] + b;
          3: i := plain[src + x] + (a + b) shr 1;
        else i := plain[src + x] + Paeth(a, b, c);
        end;
        px.data[dst + x] := Byte(i and $FF);
      end;
      Inc(src, rb);
    end;
  end;
  SetLength(px.tail, Length(plain) - src);
  if Length(px.tail) > 0 then Move(plain[src], px.tail[0], Length(px.tail));
  Result := True;
end;

function Refilter(const px: TPixels): TBytes;
var pi_, y, x, rb, o, dst, prior, bpp: SizeInt; f: Byte; a, b, c, v: Integer;
begin
  Result := nil;
  SetLength(Result, Length(px.data) + Length(px.filters) + Length(px.tail));
  bpp := px.bpp;
  o := 0;
  for pi_ := 0 to High(px.passes) do begin
    rb := px.passes[pi_].rowBytes;
    for y := 0 to px.passes[pi_].height - 1 do begin
      f := px.filters[px.passes[pi_].firstLine + y];
      Result[o] := f; Inc(o);
      dst := px.passes[pi_].first + y * rb;
      prior := dst - rb;
      for x := 0 to rb - 1 do begin
        if x >= bpp then a := px.data[dst + x - bpp] else a := 0;
        if y > 0 then b := px.data[prior + x] else b := 0;
        if (x >= bpp) and (y > 0) then c := px.data[prior + x - bpp] else c := 0;
        v := px.data[dst + x];
        case f of
          0: ;
          1: Dec(v, a);
          2: Dec(v, b);
          3: Dec(v, (a + b) shr 1);
        else Dec(v, Paeth(a, b, c));
        end;
        Result[o + x] := Byte(v and $FF);
      end;
      Inc(o, rb);
    end;
  end;
  if Length(px.tail) > 0 then Move(px.tail[0], Result[o], Length(px.tail));
end;

end.
