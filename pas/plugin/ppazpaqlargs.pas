{ How much memory the zpaq-std codec ppa1's ZPAQL decoder takes for a given
  stream (pas/plugin/zpaql/, compiled into ppa1zpaql.inc): what the plugin's
  query ZS_QUERY_ZPAQL_ARGS returns ($3 = log2 of H in words, $4 = log2 of M
  in bytes, for the config comp 0 0 $3 $4 0), and what its detection checks
  before compressing.

  The count follows the decoder's alloc() and mcheck() calls one by one
  (ppadec.zl's header, tools/zpaql/test_ppadec.py's needs()): change one,
  change the other. The suite runs the decoder with exactly these sizes
  and with one word or byte less (pas/tests/test_zpaqlargs.pas,
  check_zpaqlargs.py): the first must give the file back, the second
  error().

  H: PPA1_ZPAQL_STATIC_WORDS (the program's arrays, tables, variables)
     + 2 * substreams + 8 * chunks + 24 * streams (their records)
     + the most of, over the static images:
         5 * (width + 4) * channels           (model.zl's lines), and
         3 * 2^(memLevel+6) + 2^max(wbits,9)  (deflate.zl's zwords)
  M: the segment (4 + the stream's length)
     + substream 0's bytes (the meta, then the streams kept as bytes)
     + the static streams' lengths (their deflate streams, kept for the
       file's chunks)
     + the most of, over the static images:
         its plain length (filtered lines + the pixels' tail)
         + its largest band's first part (mn: the static model's tables
           and a filter byte a line, the band's Direct(32) first word) }
unit ppazpaqlargs;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses SysUtils, ppapng, ppapixels, ppafast, ppaarith, ppamodel;

{$I ppa1zpaql.inc}

const
  { the largest H and M a block may ask for: 2^26 words (256 MB), 2^28
    bytes (256 MB), as PJA's JPEG 2000 decoder, which zpaq 7.15 runs on
    32 bits (zpaq-std's owner, 08/11/2026) }
  PPA1_MAX_PH = 26;
  PPA1_MAX_PM = 28;
  { The images of one file, filtered, together: the detection takes no file
    with more. 7 MiB (Wira, 11/11/2026): zpaq without the plugin runs the
    ZPAQL decoder at up to 4.2 s a MiB of image (smooth content, zlib level
    9, measured with zpaq 7.15 and zpaq-std 2.7.2's JIT on two Xeon
    E5-2697A v4), so no file takes it more than about 30 s. }
  PPA1_MAX_IMAGE_BYTES = Int64(7) shl 20;
  { a file's weight (query ZS_QUERY_WEIGHT): its images' filtered bytes,
    each counted PPA1_IMAGE_COST_BYTES more, as against
    PPA1_MAX_IMAGE_BYTES; zpaq-std closes a group of ppa1's files before
    their weights pass PPA1_GROUP_WEIGHT (ZS_QUERY_GROUP_WEIGHT): a block
    then takes about as long as its largest file, without the plugin }
  PPA1_GROUP_WEIGHT = Int64(7) shl 20;
  { what each image costs the decoders whatever its size (each band's byte
    model and tables made afresh: about 2.3 ms in zpaq's JIT ZPAQL, 7 ms in
    the plugin's decompress), counted with the plain bytes against
    PPA1_MAX_IMAGE_BYTES: at most 8192 images, an APNG of 3000 tiny frames
    would otherwise take seconds to minutes in a 200 KB file. }
  PPA1_IMAGE_COST_BYTES = 8192;
  { the decoder's stream version, modes and limits (model.zl) }
  PPA1_MODE_BYTES = 0;
  PPA1_MODE_STATIC = 4;
  PPA1_BAND_BYTES = 2 * 1024 * 1024;   { ppacodec.BAND_BYTES }
  PPA1_MAX_BANDS = 16;                 { ppacodec.MAX_BANDS }
  { a band's first part: at most the 320 contexts' tables and two words
    each (model.zl: nf <= N_CTX * 256 * 9 + N_CTX * 2), and a byte a line }
  PPA1_MAX_TABLE_BYTES = 320 * 256 * 9 + 320 * 2;

type
  TPpa1Needs = record
    hWords, mBytes: Int64;    { what the decoder takes, exactly }
    ph, pm: Integer;          { log2 of them, rounded up: $3, $4 }
    nSubs, nChunks, nStreams: Int64;
    images, byteStreams: Integer;   { static image streams, streams kept as bytes }
    plain: Int64;             { the static images' plain bytes, together }
    largest: Int64;           { the largest image's plain bytes }
    widest: Int64;            { the largest 5 * (width + 4) * channels }
  end;

{ log2 of n rounded up (0 for n <= 1) }
function Log2Up(n: Int64): Integer;
{ zdeflate's scratch, in words of H (deflate.zl's zwords) }
function ZWords(memLevel, wbits: Integer): Int64;
{ What the decoder takes for this stream (compress()'s output, without
  zpaq-std's 4 bytes of size): False if it is not a stream ppa1's ZPAQL
  decodes (another version, a JNG, a JPEG, an image of a model other than
  the static one, an image the static model does not take, a damaged
  table). }
function Ppa1Needs(const stream: TBytes; out nd: TPpa1Needs): Boolean;
{ query(ZS_QUERY_ZPAQL_ARGS): $3 | $4 << 8, or -1 (not ppa1's, or past
  PPA1_MAX_PH / PPA1_MAX_PM) }
function Ppa1Args(const stream: TBytes): Int64;
{ The detection, before compressing, on the file's bytes: a PNG, an APNG or
  an MNG (no JNG, and no JNG inside an MNG) whose every image the static
  model takes (8-bit gray, gray + alpha, RGB, RGBA, Adam7 or not), within
  PPA1_MAX_IMAGE_BYTES (each image counted PPA1_IMAGE_COST_BYTES more), whose decoder fits PPA1_MAX_PH and PPA1_MAX_PM
  (counted as if each image went static and the stream were as long as
  the file: compress() checks the real ones). why: what refused it. }
function Ppa1Takes(const d: TBytes; out why: string): Boolean;
{ the same, and the file's weight (ZS_QUERY_WEIGHT; 0 when not taken) }
function Ppa1Takes(const d: TBytes; out why: string; out weight: Int64): Boolean;

implementation

const
  CT_JSEP = $4A534550;
  CT_JDAA_DELTA = $4A644141;   { 'JdAA' }

function Log2Up(n: Int64): Integer;
begin
  Result := 0;
  while (Int64(1) shl Result) < n do Inc(Result);
end;

function ZWords(memLevel, wbits: Integer): Int64;
begin
  if wbits < 9 then wbits := 9;
  Result := (Int64(3) shl (memLevel + 6)) + (Int64(1) shl wbits);
end;

{ ---------------------------------------------------------------- the stream, as model.zl reads it }

type
  EStop = class(Exception);

  TRd = record
    b: TBytes;
    pos, stop: SizeInt;
    function Get: Byte;
    function GetVar: Int64;
    function GetVarMax(mx: Int64): Int64;
    function GetBe32: LongWord;
  end;

procedure NotOurs;
begin
  raise EStop.Create('not ppa1');
end;

function TRd.Get: Byte;
begin
  if pos >= stop then NotOurs;
  Result := b[pos];
  Inc(pos);
end;

{ model.zl's getvar: at most 5 bytes }
function TRd.GetVar: Int64;
var sh: Integer; c: Byte;
begin
  Result := 0; sh := 0;
  repeat
    if sh > 28 then NotOurs;
    c := Get;
    Result := Result or (Int64(c and 127) shl sh);
    Inc(sh, 7);
  until c < 128;
  if Result > $FFFFFFFF then NotOurs;
end;

function TRd.GetVarMax(mx: Int64): Int64;
begin
  Result := GetVar;
  if Result > mx then NotOurs;
end;

function TRd.GetBe32: LongWord;
begin
  Result := LongWord(Get) shl 24;
  Result := Result or (LongWord(Get) shl 16);
  Result := Result or (LongWord(Get) shl 8);
  Result := Result or Get;
end;

function Be32At(const b: TBytes; a: SizeInt): LongWord;
begin
  if (a < 0) or (a + 4 > Length(b)) then NotOurs;
  Result := (LongWord(b[a]) shl 24) or (LongWord(b[a + 1]) shl 16) or (LongWord(b[a + 2]) shl 8) or b[a + 3];
end;

const
  A7X0: array[0..6] of Integer = (0, 4, 0, 2, 0, 1, 0);
  A7Y0: array[0..6] of Integer = (0, 0, 4, 0, 2, 0, 1);
  A7DX: array[0..6] of Integer = (8, 8, 4, 4, 2, 2, 1);
  A7DY: array[0..6] of Integer = (8, 8, 8, 4, 4, 2, 2);

type
  { an image's layout (model.zl's layout()), static model only }
  TLay = record
    w, h, nc: Int64;
    npass: Integer;
    ph: array[0..6] of Int64;
    filt: Int64;       { filtered bytes: lines and their filter bytes }
  end;

{ the passes of a w x h image of nc 8-bit channels, Adam7 or not, as
  model.zl's layout() (its limits: w < 2^28, h < 2^30, the image below 2^30) }
function Layout(w, h, nc: Int64; lace: Integer; out L: TLay): Boolean;
var i: Integer; pw, rb, total, lines: Int64;
begin
  Result := False;
  L := Default(TLay);
  if (nc < 1) or (lace > 1) or (w = 0) or (h = 0) or (w >= 268435456) or (h >= 1073741824) then Exit;
  L.w := w; L.h := h; L.nc := nc;
  if lace = 1 then L.npass := 7 else L.npass := 1;
  total := 0; lines := 0;
  for i := 0 to L.npass - 1 do begin
    pw := w; L.ph[i] := h;
    if L.npass = 7 then begin
      pw := 0; L.ph[i] := 0;
      if w > A7X0[i] then pw := (w - A7X0[i] + A7DX[i] - 1) div A7DX[i];
      if h > A7Y0[i] then L.ph[i] := (h - A7Y0[i] + A7DY[i] - 1) div A7DY[i];
    end;
    if (pw = 0) or (L.ph[i] = 0) then begin pw := 0; L.ph[i] := 0; end;
    rb := pw * nc;
    if (L.ph[i] > 0) and (rb + 1 > (1073741824 - total - lines) div L.ph[i]) then Exit;
    Inc(total, rb * L.ph[i]);
    Inc(lines, L.ph[i]);
  end;
  L.filt := total + lines;
  Result := True;
end;

{ ppacodec.BandRows, model.zl's bandrows() }
function BandRowsOf(const L: TLay): Int64;
var nb: Int64;
begin
  Result := L.ph[0];
  if L.npass <> 1 then Exit;
  nb := L.filt div PPA1_BAND_BYTES;
  if nb > PPA1_MAX_BANDS then nb := PPA1_MAX_BANDS;
  if nb < 1 then nb := 1;
  Result := (L.ph[0] + nb - 1) div nb;
end;

{ lines of the band firstRow .. firstRow + rows - 1 (all of an interlaced image) }
function BandLines(const L: TLay; firstRow, rows: Int64): Int64;
var i: Integer; y0, y1: Int64;
begin
  Result := 0;
  for i := 0 to L.npass - 1 do begin
    y0 := 0; y1 := L.ph[i];
    if L.npass = 1 then begin
      y0 := firstRow;
      if firstRow + rows < y1 then y1 := firstRow + rows;
    end;
    if y1 > y0 then Inc(Result, y1 - y0);
  end;
end;

function Ppa1Needs(const stream: TBytes; out nd: TPpa1Needs): Boolean;
type
  TCh = record typ: LongWord; len, flags, stream, data: Int64; end;
  TSt = record kind, header, frame, mode, ml, wb, pxTail, len: Int64; end;
var
  r: TRd; i, j: SizeInt; v, total, p, metaLen, sz, mn, nf, maxMn, plen, pfirst, sub, rows, nb, nBands: Int64;
  subPos, subLen: array of Int64; chunks: array of TCh; sts: array of TSt;
  dec: TArithDecoder; bm: TByteModel; meta: TBytes; L: TLay;
  c: SizeInt; w, h: Int64; depth, ct, lace: Integer; part: TBytes;
  mx, hx, mxImg, orig: Int64;
begin
  Result := False;
  nd := Default(TPpa1Needs);
  try
    { parsestream: the version, the substreams' table }
    if (Length(stream) < 2) or (stream[0] <> PPA1_ZPAQL_STREAM_VERSION) then Exit;
    r := Default(TRd);
    r.b := stream; r.pos := 1; r.stop := Length(stream);
    nd.nSubs := r.GetVarMax(Length(stream));
    if nd.nSubs < 1 then Exit;
    subPos := nil; subLen := nil;
    SetLength(subPos, nd.nSubs); SetLength(subLen, nd.nSubs);
    total := 0;
    for i := 0 to nd.nSubs - 1 do begin
      subLen[i] := r.GetVarMax(Length(stream));
      Inc(total, subLen[i]);
      if total > Length(stream) then Exit;
    end;
    if r.pos + total <> Length(stream) then Exit;
    p := r.pos;
    for i := 0 to nd.nSubs - 1 do begin subPos[i] := p; Inc(p, subLen[i]); end;

    { decodesub0: the meta through a fresh byte model }
    dec.Init(Copy(stream, subPos[0], subLen[0]), 0);
    metaLen := dec.Direct(32);
    { the structure holds the chunks other than the image data: never more
      than the stream could have shrunk (the decoder: origsize + 1 MB) }
    if metaLen > Int64(1100) * Length(stream) + 1048576 then Exit;
    meta := nil; SetLength(meta, metaLen);
    bm.Init;
    CodeBytes(bm, meta, 0, metaLen, nil, @dec);
    r := Default(TRd);
    r.b := meta; r.pos := 0; r.stop := metaLen;
    { the kind: a PNG or an MNG, never a JNG }
    i := r.Get;
    if i > 1 then Exit;
    nd.nChunks := r.GetVarMax(MAX_CHUNKS);
    chunks := nil; SetLength(chunks, nd.nChunks);
    for i := 0 to nd.nChunks - 1 do begin
      chunks[i].typ := r.GetBe32;
      chunks[i].len := r.GetVar;
      chunks[i].flags := r.Get;
      if chunks[i].flags > 3 then Exit;
      { no JNG inside an MNG }
      if (chunks[i].typ = CT_JHDR) or (chunks[i].typ = CT_JDAT) or (chunks[i].typ = CT_JDAA) or
         (chunks[i].typ = CT_JSEP) or (chunks[i].typ = CT_JDAA_DELTA) then Exit;
      if chunks[i].flags and 1 = 0 then r.GetBe32;
      chunks[i].stream := -1;
      if chunks[i].flags and 2 <> 0 then begin
        chunks[i].stream := r.GetVarMax(MAX_CHUNKS);
        if chunks[i].typ = CT_fdAT then begin
          if chunks[i].len < 4 then Exit;
          r.GetBe32;
        end;
      end else begin
        chunks[i].data := r.pos;
        if chunks[i].len > r.stop - r.pos then Exit;
        Inc(r.pos, chunks[i].len);
      end;
    end;
    { the bytes after the last chunk }
    v := r.GetVar;
    if v > r.stop - r.pos then Exit;
    Inc(r.pos, v);
    { the file: its signature, its chunks, those bytes; zpaq-std's original
      size is its length, and the decoders take no structure longer than
      it and 1 MB (decodesub0's metalen > origsize + 1048576) }
    orig := 8 + v;
    for i := 0 to nd.nChunks - 1 do Inc(orig, 12 + chunks[i].len);
    if metaLen > orig + 1048576 then Exit;
    nd.nStreams := r.GetVarMax(nd.nChunks);
    sts := nil; SetLength(sts, nd.nStreams);
    for i := 0 to nd.nChunks - 1 do
      if chunks[i].stream >= 0 then begin
        if chunks[i].stream >= nd.nStreams then Exit;
        if chunks[i].typ = CT_fdAT then Inc(sts[chunks[i].stream].len, chunks[i].len - 4)
        else Inc(sts[chunks[i].stream].len, chunks[i].len);
      end;
    for i := 0 to nd.nStreams - 1 do begin
      sts[i].kind := r.Get;
      { IDAT and fdAT only: a JNG's JDAT and JDAA are not ppa1's }
      if sts[i].kind > 1 then Exit;
      sts[i].header := r.GetVarMax(nd.nChunks) - 1;
      sts[i].frame := r.GetVarMax(nd.nChunks) - 1;
      sts[i].mode := r.Get;
      if (sts[i].mode <> PPA1_MODE_BYTES) and (sts[i].mode <> PPA1_MODE_STATIC) then Exit;
      if sts[i].mode = PPA1_MODE_STATIC then begin
        v := r.Get;                             { level 1 .. 9 }
        if (v < 1) or (v > 9) then Exit;
        if r.Get > 4 then Exit;                 { strategy }
        sts[i].ml := r.Get;
        sts[i].wb := r.Get;
        if (sts[i].ml < 1) or (sts[i].ml > 9) or (sts[i].wb < 8) or (sts[i].wb > 15) then Exit;
        if r.Get > 3 then Exit;                 { flags }
        r.Get; r.Get; r.Get;                    { CMF, FLG, endPad }
        v := r.GetVarMax(sts[i].len);           { the zlib tail }
        if v > r.stop - r.pos then Exit;
        Inc(r.pos, v);
        sts[i].pxTail := r.GetVarMax(1073741824);
        if sts[i].pxTail > r.stop - r.pos then Exit;
        Inc(r.pos, sts[i].pxTail);
      end;
    end;
    if r.pos <> r.stop then Exit;

    { substream 0's bytes; each image's layout, bands, first parts }
    mx := metaLen;
    hx := 0; mxImg := 0;
    nBands := 0;
    for i := 0 to nd.nStreams - 1 do begin
      if sts[i].mode = PPA1_MODE_BYTES then begin
        Inc(mx, sts[i].len);
        Inc(nd.byteStreams);
        Continue;
      end;
      { layout(): its header chunk, an IHDR of the meta; an fdAT's size
        from its fcTL }
      c := sts[i].header;
      if (c < 0) or (c >= nd.nChunks) or (chunks[c].typ <> CT_IHDR) or (chunks[c].len < 13) or
         (chunks[c].flags and 2 <> 0) then Exit;
      w := Be32At(meta, chunks[c].data);
      h := Be32At(meta, chunks[c].data + 4);
      depth := meta[chunks[c].data + 8];
      ct := meta[chunks[c].data + 9];
      lace := meta[chunks[c].data + 12];
      if sts[i].kind = 1 then begin
        c := sts[i].frame;
        if (c < 0) or (c >= nd.nChunks) or (chunks[c].len < 12) or (chunks[c].flags and 2 <> 0) then Exit;
        w := Be32At(meta, chunks[c].data + 4);
        h := Be32At(meta, chunks[c].data + 8);
      end;
      if depth <> 8 then Exit;
      case ct of
        0: v := 1;
        2: v := 3;
        4: v := 2;
        6: v := 4;
      else Exit;
      end;
      if not Layout(w, h, v, lace, L) then Exit;
      sz := L.filt + sts[i].pxTail;
      { as the decoder: no image larger than its stream can hold }
      if (sts[i].len < 3904000) and (sz > 1100 * sts[i].len + 1024) then Exit;
      Inc(nd.plain, sz);
      if sz > nd.largest then nd.largest := sz;
      if nd.plain > 2147483647 then Exit;
      Inc(nd.images);
      Inc(mx, sts[i].len);
      { H: the lines, or deflate's scratch }
      v := 5 * (L.w + 4) * L.nc;
      if v > nd.widest then nd.widest := v;
      if v > hx then hx := v;
      v := ZWords(sts[i].ml, sts[i].wb);
      if v > hx then hx := v;
      { M: the plain bytes and the largest band's first part }
      rows := BandRowsOf(L);
      nb := (L.ph[0] + rows - 1) div rows;
      if nb < 1 then nb := 1;
      maxMn := 0;
      for j := 0 to nb - 1 do begin
        sub := 1 + nBands + j;
        if sub >= nd.nSubs then Exit;
        { the band: varint partLen, then the arithmetic part, whose first
          two Direct(32) words are mn and nf }
        r := Default(TRd);
        r.b := stream; r.pos := subPos[sub]; r.stop := subPos[sub] + subLen[sub];
        if subLen[sub] < 1 then Exit;
        plen := r.GetVar;
        if plen > r.stop - r.pos then Exit;
        pfirst := r.pos;
        part := Copy(stream, pfirst, plen);
        dec.Init(part, 0);
        mn := dec.Direct(32);
        nf := dec.Direct(32);
        if (nf > mn) or (mn - nf <> BandLines(L, Int64(j) * rows, rows)) or (nf > PPA1_MAX_TABLE_BYTES) then Exit;
        if mn > maxMn then maxMn := mn;
      end;
      Inc(nBands, nb);
      if sz + maxMn > mxImg then mxImg := sz + maxMn;
    end;
    if nBands <> nd.nSubs - 1 then Exit;
    nd.hWords := PPA1_ZPAQL_STATIC_WORDS + PPA1_ZPAQL_SUB_WORDS * nd.nSubs + PPA1_ZPAQL_CHUNK_WORDS * nd.nChunks +
                 PPA1_ZPAQL_STREAM_WORDS * nd.nStreams + hx;
    nd.mBytes := 4 + Int64(Length(stream)) + mx + mxImg;
    nd.ph := Log2Up(nd.hWords);
    nd.pm := Log2Up(nd.mBytes);
    Result := True;
  except
    on EStop do Result := False;
  end;
end;

function Ppa1Args(const stream: TBytes): Int64;
var nd: TPpa1Needs;
begin
  Result := -1;
  if not Ppa1Needs(stream, nd) then Exit;
  if (nd.ph > PPA1_MAX_PH) or (nd.pm > PPA1_MAX_PM) then Exit;
  Result := nd.ph or (nd.pm shl 8);
end;

{ ---------------------------------------------------------------- the detection }

function Ppa1Takes(const d: TBytes; out why: string): Boolean;
var weight: Int64;
begin
  Result := Ppa1Takes(d, why, weight);
end;

function Ppa1Takes(const d: TBytes; out why: string; out weight: Int64): Boolean;
var
  p: TPng; s, i: SizeInt; info: TImageInfo; L: TLay; nc, plain, hx, mx, mxImg, bands, rows, nb, j: Int64;
begin
  Result := False;
  why := '';
  weight := 0;
  if not Decompose(d, p).Ok then begin why := 'not a PNG, APNG or MNG file'; Exit; end;
  if p.kind = pkJng then begin why := 'a JNG'; Exit; end;
  for i := 0 to High(p.chunks) do
    case p.chunks[i].typ of
      CT_JHDR, CT_JDAT, CT_JDAA, CT_JSEP, CT_JDAA_DELTA: begin why := 'a JNG inside the MNG'; Exit; end;
      CT_IHDR:
        { every image, whether its data is reproduced or not }
        if (Length(p.chunks[i].data) < 13) or (p.chunks[i].data[8] <> 8) or
           not (p.chunks[i].data[9] in [0, 2, 4, 6]) or (p.chunks[i].data[12] > 1) then begin
          why := 'an image the static model does not take (palette, 1/2/4/16 bits)'; Exit;
        end;
    end;
  if Length(p.streams) = 0 then begin why := 'no image'; Exit; end;
  plain := 0; hx := 0; mxImg := 0; bands := 0;
  mx := 0;
  for s := 0 to High(p.streams) do begin
    { an IDAT or fdAT stream of an IHDR's image (none of a delta image,
      a BASI's, an MNG object's without its IHDR) }
    if not StreamImage(p, s, info) or (p.chunks[p.streams[s].header].typ <> CT_IHDR) or not FastEligible(info) then begin
      why := 'image data the static model does not take'; Exit;
    end;
    nc := Channels(info.colorType, info.depth);
    if not Layout(info.width, info.height, nc, info.interlace, L) then begin why := 'an image of a size not taken'; Exit; end;
    Inc(plain, L.filt + PPA1_IMAGE_COST_BYTES);
    if plain > PPA1_MAX_IMAGE_BYTES then begin why := 'images larger (or more) than ppa1 takes'; Exit; end;
    { as if static, with memLevel 9 and a window of 2^15 (the largest) }
    j := 5 * (L.w + 4) * L.nc;
    if j > hx then hx := j;
    if ZWords(9, 15) > hx then hx := ZWords(9, 15);
    Inc(mx, Length(p.streams[s].data));
    rows := BandRowsOf(L);
    nb := (L.ph[0] + rows - 1) div rows;
    if nb < 1 then nb := 1;
    Inc(bands, nb);
    { the band's first part: the tables and a byte a line }
    if L.filt + PPA1_MAX_TABLE_BYTES + L.h > mxImg then mxImg := L.filt + PPA1_MAX_TABLE_BYTES + L.h;
  end;
  if Log2Up(PPA1_ZPAQL_STATIC_WORDS + PPA1_ZPAQL_SUB_WORDS * (1 + bands) + PPA1_ZPAQL_CHUNK_WORDS * Length(p.chunks) +
            PPA1_ZPAQL_STREAM_WORDS * Length(p.streams) + hx) > PPA1_MAX_PH then begin
    why := 'its decoder would need more H than ppa1 asks for'; Exit;
  end;
  { M: the segment as long as the file, the meta and the streams no longer
    than the file either }
  if Log2Up(4 + Int64(Length(d)) + Int64(Length(d)) + mx + mxImg) > PPA1_MAX_PM then begin
    why := 'its decoder would need more M than ppa1 asks for'; Exit;
  end;
  weight := plain;
  Result := True;
end;

end.
