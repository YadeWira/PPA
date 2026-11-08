{ dump_streams: what a zpaq-std PCOMP port of PPA's decoder must reproduce,
  file by file, as plain files a CPython or zpaqlvm test can read.

    dump_streams <out dir> <file or directory>... [-c] [-natural]

  Each file is compressed with ppacodec.Compress (verified) with TestModel
  = MODE_STATIC: every image the static model can take (8-bit gray, gray +
  alpha, RGB, RGBA: ppafast.FastEligible) goes with it; the others (palette,
  1/2/4/16-bit) with the model PPA's own choice gives them (the slow one,
  MODE_IMAGE). -natural also compresses it a second time with PPA's own
  choice (ChooseModel), only to record that choice in the json
  ("natural_mode"). The stream is then parsed and decoded again HERE, step
  by step, the way a decoder must (substream 0 through the arithmetic coder
  and the byte model, each band through ppastatic.DecodeImageStatic,
  Refilter, ZlibChoices + Encode), and every step is checked against an
  independent path (ppadeflate.Decode of the original bytes, Unfilter, the
  chunk bytes read straight from the original file). The decoding steps run
  the Pascal reference code (UseZlibC, UseDeflateC, UseStaticC, UsePixC,
  UseC, UseFastC False): -c keeps PPA's C instead (the same bytes).

  OUTPUTS, per input file NAME (its base name, extension kept), in <out dir>:

  NAME.stream   what Compress returns, byte for byte (what the zpaq block
                holds after zpaq-std's u32 size). Layout (ppacodec.pas):
                  byte    STREAM_VERSION (2)
                  varint  nSubs = 1 + bands + JNG JPEG streams
                  varint  length of each substream, nSubs of them
                  bytes   substream 0, then each band's substream (image
                          streams in order, each image's bands top to
                          bottom), then each JNG JPEG's PJA stream
                varint = LEB128: 7 bits a byte, low first, bit 7 = more.
  NAME.sub0     substream 0 decoded: the arithmetic decoder (ppaarith) first
                gives metaLen with Direct(32) (32 bits at p = 1/2, msb
                first, NOT in this file), then metaLen bytes through a
                fresh ppamodel.TByteModel (CodeBytes), then each stream
                kept as bytes (mode 0), in stream order, through a SECOND
                fresh TByteModel, same decoder. NAME.sub0 = the meta bytes
                followed by those streams' bytes (json "sub0").
                Meta layout (CompressRaw): byte kind (0 PNG, 1 MNG, 2 JNG);
                varint nChunks; per chunk: be32 type, varint len, byte flags
                (bit0 CRC is right = recomputed, bit1 data in a stream),
                [be32 crc if not bit0], bit1 ? (varint stream, [be32 seq
                if fdAT]) : len bytes of data; varint trailerLen, its bytes;
                varint nStreams; per stream: byte kind (0 IDAT, 1 fdAT,
                2 JDAT, 3 JDAA), varint header+1, varint frame+1, byte mode
                (0 bytes, 1 slow, 2 JPEG, 3 fast, 4 static); modes 1,3,4
                add: bytes level, strategy, memLevel, wbits, flags (bit0
                raw deflate, bit1 adlerOk), CMF, FLG, endPad; varint zTail
                len + bytes; varint pxTail len + bytes.
  NAME.json     the layout, parsed from the stream (keys below).
  NAME.img<s>.filt   image stream s's filtered lines, as PNG stores them:
                each line = filter byte + rowBytes bytes, Adam7 passes in
                order (empty passes have no lines), WITHOUT the pxTail
                (bytes after the image inside the zlib data, rare).
  NAME.img<s>.pix    the unfiltered lines without filter bytes (TPixels.
                data): pass by pass, each pass height x rowBytes, packed
                as PNG packs samples (16-bit big endian, 1/2/4-bit packed).
                For static images this is exactly what DecodeImageStatic
                writes into px.data (it also writes px.filters, the filter
                bytes, which come from the band's first part, *.meta).
  NAME.z<s>.plain    zlib stream s's plain input: .filt + pxTail.
  NAME.z<s>.deflate  the bytes PPA's Encode gives from .plain and the
                parameters (ZlibChoices(level, strategy, memLevel, wbits),
                then Encode with raw/header/adlerOk/endPad/zTail): the
                whole stream as the IDAT/fdAT chunks hold it concatenated
                (fdAT without its sequence numbers), zlib header and
                Adler-32 included. Checked equal to the bytes read from the
                original file at the chunks' offsets.
  NAME.s<s>.b<j>.meta  static image s, band j: its first part decoded (the
                byte model's bytes): nf bytes of frequency tables (per
                context 0..319: varint used, then per used symbol varint
                gap, varint freq-1) then one filter byte per line of the
                band (json band "freq_bytes", "lines").
  Written only for image streams (modes 1, 3, 4); streams kept as bytes
  (mode 0: zlib that no parameters reproduce, level 0, ...) are in
  NAME.sub0, JNG JPEGs (mode 2) are PJA streams.

  JSON keys: file, size, taken, why, stream_len, stream_version, n_subs,
  substreams [<index, offset, length, what: "sub0"|"band"|"jpeg", stream,
  band>], sub0 <meta_len, file_len, byte_streams [<stream, offset,
  length>]>, kind, chunks [<index, type, len, file_offset (of the length
  field), data_offset, crc_ok, stream, seq>], trailer_len, streams [<index,
  kind, header_chunk, frame_chunk, mode, mode_name, natural_mode, length,
  chunks, file_ranges [[data offset, length]...], image <width, height,
  color_type, bit_depth, interlace, bpp, filtered_bytes, pix_bytes,
  px_tail_len, passes [<width, height, row_bytes, first, first_line>],
  bands [<sub, first_row, rows, sub_offset, sub_len, part_len, meta_len,
  freq_bytes, lines, rans_len>]>, zlib <level, strategy, mem_level,
  window_bits, raw, adler_ok, header [CMF, FLG], end_pad, tail_len,
  tail_hex, plain_len, deflate_len, deflate_ok, n_blocks, blocks
  [[type 0 stored/1 fixed/2 dynamic, final, tokens, stored len]...]>>],
  checks <...: each true when it held>.

  stdout: one "RESULT" line per file (tab separated, see the header line)
  and a "TOTAL" line. Exit code 1 if any check failed. }
program dump_streams;
{$I ../ppa.inc}
uses {$ifdef UNIX} cthreads, {$endif} SysUtils, Classes, Math, StrUtils, ppacodec, ppapng, ppadeflate, ppazlib, ppapixels,
  ppaarith, ppamodel, ppafast, ppastatic;

const
  BAND_BYTES = 2 * 1024 * 1024;   { ppacodec's, private there }
  MAX_BANDS = 16;
  KIND_NAMES: array[0..2] of string = ('png', 'mng', 'jng');
  SKIND_NAMES: array[0..3] of string = ('IDAT', 'fdAT', 'JDAT', 'JDAA');
  MNAMES: array[0..4] of string = ('bytes', 'slow', 'jpeg', 'fast', 'static');

type
  EParse = class(Exception);
  TI64 = array of Int64;

  TMChunk = record
    typ: LongWord; len: Int64; flags: Byte; crc: LongWord; stream: Int64; seq: LongWord;
    fileOff: Int64;
  end;
  TMStream = record
    kind, mode: Integer; header, frame: Int64;
    level, strategy, memLevel, wbits, zflags, h0, h1, endPad: Integer;
    zTail, pxTail: TBytes;
    len: Int64;
  end;
  TParsed = record
    version: Integer;
    nSubs: Int64;
    subLen, subPos: array of Int64;
    meta: TBytes;
    kind: Integer;
    chunks: array of TMChunk;
    trailerLen: Int64;
    streams: array of TMStream;
  end;

var
  BandBytes: Int64 = BAND_BYTES;
  failedAny: Boolean = False;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

procedure WriteBytes(const f: string; const b: TBytes; first, len: SizeInt);
var s: TFileStream;
begin
  s := TFileStream.Create(f, fmCreate);
  try if len > 0 then s.WriteBuffer(b[first], len); finally s.Free; end;
end;

function Same(const a: TBytes; ao: SizeInt; const b: TBytes; bo, n: SizeInt): Boolean;
begin
  if (ao < 0) or (bo < 0) or (ao + n > Length(a)) or (bo + n > Length(b)) then Exit(False);
  Result := (n = 0) or CompareMem(@a[ao], @b[bo], n);
end;

function SameAll(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and Same(a, 0, b, 0, Length(a));
end;

function Hex(const b: TBytes): string;
var i: SizeInt;
begin
  Result := '';
  for i := 0 to High(b) do Result := Result + LowerCase(IntToHex(b[i], 2));
end;

function JB(b: Boolean): string;
begin
  if b then Result := 'true' else Result := 'false';
end;

function JS(const s: string): string;
var i: Integer;
begin
  Result := '"';
  for i := 1 to Length(s) do
    if (s[i] = '"') or (s[i] = '\') then Result := Result + '\' + s[i]
    else if s[i] < ' ' then Result := Result + '\u' + IntToHex(Ord(s[i]), 4)
    else Result := Result + s[i];
  Result := Result + '"';
end;

{ ---------------------------------------------------------------- the stream, parsed }

function GetB(const b: TBytes; var p: SizeInt): Byte;
begin
  if p >= Length(b) then raise EParse.Create('cut short');
  Result := b[p]; Inc(p);
end;

function GetV(const b: TBytes; var p: SizeInt): Int64;
var x: Byte; sh: Integer;
begin
  Result := 0; sh := 0;
  repeat
    x := GetB(b, p);
    if sh > 56 then raise EParse.Create('varint too long');
    Result := Result or (Int64(x and 127) shl sh);
    Inc(sh, 7);
  until x < 128;
end;

function GetBe32(const b: TBytes; var p: SizeInt): LongWord;
var i: Integer;
begin
  Result := 0;
  for i := 1 to 4 do Result := (Result shl 8) or GetB(b, p);
end;

function GetN(const b: TBytes; var p: SizeInt; n: Int64): TBytes;
begin
  if (n < 0) or (n > Length(b) - p) then raise EParse.Create('cut short');
  Result := Copy(b, p, n); Inc(p, n);
end;

{ the stream's table, substream 0 decoded: meta (returned in P) and the
  bytes streams appended into sub0 }
procedure ParseStream(const st: TBytes; out P: TParsed; out sub0: TBytes; out byteOff: TI64);
var
  q: SizeInt; i, s: SizeInt; dec: TArithDecoder; bm, rm: TByteModel; metaLen: Cardinal; tot: Int64;
  ms: TMStream; c: TMChunk; data: TBytes; at: Int64;
begin
  P := Default(TParsed);
  q := 0;
  P.version := GetB(st, q);
  P.nSubs := GetV(st, q);
  SetLength(P.subLen, P.nSubs); SetLength(P.subPos, P.nSubs);
  for i := 0 to P.nSubs - 1 do P.subLen[i] := GetV(st, q);
  tot := q;
  for i := 0 to P.nSubs - 1 do begin P.subPos[i] := tot; Inc(tot, P.subLen[i]); end;
  if tot <> Length(st) then raise EParse.Create('substream table');
  dec.Init(Copy(st, P.subPos[0], P.subLen[0]), 0);
  metaLen := dec.Direct(32);
  P.meta := nil; SetLength(P.meta, metaLen);
  bm.Init;
  CodeBytes(bm, P.meta, 0, metaLen, nil, @dec);
  { the meta }
  q := 0;
  P.kind := GetB(P.meta, q);
  SetLength(P.chunks, GetV(P.meta, q));
  at := 8;
  for i := 0 to High(P.chunks) do begin
    c := Default(TMChunk);
    c.fileOff := at;
    c.typ := GetBe32(P.meta, q);
    c.len := GetV(P.meta, q);
    c.flags := GetB(P.meta, q);
    if c.flags and 1 = 0 then c.crc := GetBe32(P.meta, q);
    c.stream := -1;
    if c.flags and 2 <> 0 then begin
      c.stream := GetV(P.meta, q);
      if c.typ = CT_fdAT then c.seq := GetBe32(P.meta, q);
    end else GetN(P.meta, q, c.len);
    Inc(at, 12 + c.len);
    P.chunks[i] := c;
  end;
  P.trailerLen := GetV(P.meta, q);
  GetN(P.meta, q, P.trailerLen);
  SetLength(P.streams, GetV(P.meta, q));
  for i := 0 to High(P.chunks) do
    with P.chunks[i] do
      if stream >= 0 then begin
        if stream > High(P.streams) then raise EParse.Create('chunk stream');
        if typ = CT_fdAT then Inc(P.streams[stream].len, len - 4) else Inc(P.streams[stream].len, len);
      end;
  for s := 0 to High(P.streams) do begin
    ms := P.streams[s];
    ms.kind := GetB(P.meta, q);
    ms.header := GetV(P.meta, q) - 1;
    ms.frame := GetV(P.meta, q) - 1;
    ms.mode := GetB(P.meta, q);
    if ms.mode in [MODE_IMAGE, MODE_FAST, MODE_STATIC] then begin
      ms.level := GetB(P.meta, q); ms.strategy := GetB(P.meta, q);
      ms.memLevel := GetB(P.meta, q); ms.wbits := GetB(P.meta, q);
      ms.zflags := GetB(P.meta, q);
      ms.h0 := GetB(P.meta, q); ms.h1 := GetB(P.meta, q); ms.endPad := GetB(P.meta, q);
      ms.zTail := GetN(P.meta, q, GetV(P.meta, q));
      ms.pxTail := GetN(P.meta, q, GetV(P.meta, q));
    end;
    P.streams[s] := ms;
  end;
  if q <> Length(P.meta) then raise EParse.Create('meta has bytes left');
  { the streams kept as bytes, through a second model, same decoder }
  sub0 := Copy(P.meta, 0, Length(P.meta));
  rm.Init;
  byteOff := nil; SetLength(byteOff, Length(P.streams));
  for s := 0 to High(P.streams) do begin
    byteOff[s] := -1;
    if P.streams[s].mode = MODE_BYTES then begin
      data := nil; SetLength(data, P.streams[s].len);
      CodeBytes(rm, data, 0, Length(data), nil, @dec);
      byteOff[s] := Length(sub0);
      SetLength(sub0, Length(sub0) + Length(data));
      if Length(data) > 0 then Move(data[0], sub0[byteOff[s]], Length(data));
    end;
  end;
end;

{ ppacodec's bands, as it cuts them }
function BandRows(const px: TPixels): SizeInt;
var nb, h: SizeInt;
begin
  h := px.passes[0].height;
  Result := h;
  if (Length(px.passes) <> 1) or (h = 0) then Exit;
  nb := FilteredSize(px) div BandBytes;
  if nb > MAX_BANDS then nb := MAX_BANDS;
  if nb < 1 then nb := 1;
  Result := (h + nb - 1) div nb;
end;

{ ---------------------------------------------------------------- one file }

var
  totFiles, totTaken, totImg, totStatic, totFast, totSlow, totBytesStreams, totJpeg, totNatStatic, totNatOther,
    totZ, totZOk, totZBytes, totPlain, totBands, totIn, totStream, totFail, totAllStaticFiles: Int64;
  keepC, natural: Boolean;
  outDir: string;

procedure SetC(on: Boolean);
begin
  ppazlib.UseZlibC := on; ppadeflate.UseDeflateC := on; ppastatic.UseStaticC := on; ppapixels.UsePixC := on;
  ppamodel.UseC := on; ppafast.UseFastC := on;
end;

procedure DoFile(const path: string);
var
  d, st, st2, sub0, a, plainOrig, plain, enc, bmeta: TBytes;
  stats: TCodecStats; why, name, base, errs: string;
  P, P2: TParsed; byteOff: TI64;
  png: TPng; L: TStringList;
  s, i, j, k, sub, nb, r, y, nImgStatic, nImgOther, nZ, nZOk, nBands: SizeInt;
  info: TImageInfo; px, pxRef: TPixels; z, zc: TZStream; prm: TZlibParams;
  checks: TStringList;
  okAll, ok, allStatic: Boolean;
  first: Boolean; line: string;
  pp: SizeInt; plen: Int64; adec: TArithDecoder; bm: TByteModel; mn, nf: Cardinal;
  filtLen: SizeInt; ranges: string; nat: Integer;
  bt: array[0..2] of Integer;

  procedure Check(const what: string; b: Boolean);
  begin
    checks.Add('    ' + JS(what) + ': ' + JB(b));
    if not b then begin okAll := False; errs := errs + ' ' + what; end;
  end;

begin
  d := ReadFile(path);
  name := ExtractFileName(path);
  base := IncludeTrailingPathDelimiter(outDir) + name;
  Inc(totFiles); Inc(totIn, Length(d));
  L := TStringList.Create; checks := TStringList.Create;
  okAll := True; errs := '';
  nImgStatic := 0; nImgOther := 0; nZ := 0; nZOk := 0; nBands := 0; allStatic := True;
  try
    L.Add('{');
    L.Add('  "file": ' + JS(name) + ', "size": ' + IntToStr(Length(d)) + ',');
    { natural choice first, if asked }
    P2 := Default(TParsed);
    if natural then begin
      TestModel := -1;
      SetC(True);
      if Compress(d, st2, why, stats, False, 1) then begin
        try ParseStream(st2, P2, sub0, byteOff); except P2 := Default(TParsed); end;
      end;
    end;
    TestModel := MODE_STATIC;
    SetC(True);
    if not Compress(d, st, why, stats, True, 1) then begin
      L.Add('  "taken": false, "why": ' + JS(why));
      L.Add('}');
      L.SaveToFile(base + '.json');
      if Pos('bug', why) > 0 then begin okAll := False; errs := ' compress: ' + why; end;
      Writeln(Format('RESULT'#9'%s'#9'0'#9'0'#9'0'#9'0'#9'0'#9'0'#9'0'#9'0'#9'0'#9'0'#9'0'#9'0'#9'0'#9'%d'#9'%s'#9'%s',
        [name, Length(d), JB(okAll), 'not taken: ' + why + errs]));
      if not okAll then begin Inc(totFail); failedAny := True; end;
      Exit;
    end;
    Inc(totTaken); Inc(totStream, Length(st));
    WriteBytes(base + '.stream', st, 0, Length(st));
    if not keepC then SetC(False);

    ParseStream(st, P, sub0, byteOff);
    WriteBytes(base + '.sub0', sub0, 0, Length(sub0));
    Check('version_is_2', P.version = 2);

    if ppapng.Decompose(d, png).err <> peNone then raise EParse.Create('Decompose failed');
    Check('chunks_match_decompose', Length(png.chunks) = Length(P.chunks));
    Check('streams_match_decompose', Length(png.streams) = Length(P.streams));
    if Length(png.chunks) = Length(P.chunks) then begin
      ok := True;
      for i := 0 to High(P.chunks) do
        ok := ok and (png.chunks[i].typ = P.chunks[i].typ) and (png.chunks[i].len = P.chunks[i].len) and
          (png.chunks[i].stream = P.chunks[i].stream) and (png.chunks[i].crcOk = (P.chunks[i].flags and 1 <> 0));
      Check('chunk_fields_match_decompose', ok);
      { the chunk offsets: each length field read from the file }
      ok := True;
      for i := 0 to High(P.chunks) do
        ok := ok and (P.chunks[i].fileOff + 8 <= Length(d)) and
          ((LongWord(d[P.chunks[i].fileOff]) shl 24 or LongWord(d[P.chunks[i].fileOff + 1]) shl 16 or
            LongWord(d[P.chunks[i].fileOff + 2]) shl 8 or d[P.chunks[i].fileOff + 3]) = P.chunks[i].len);
      Check('chunk_offsets_in_file', ok);
    end;

    L.Add('  "taken": true, "why": "",');
    L.Add(Format('  "stream_len": %d, "stream_version": %d, "n_subs": %d,', [Length(st), P.version, P.nSubs]));
    L.Add('  "kind": ' + JS(KIND_NAMES[Min(P.kind, 2)]) + ', "trailer_len": ' + IntToStr(P.trailerLen) + ',');
    { substreams: which is which }
    line := '  "substreams": [' + Format('{"index": 0, "offset": %d, "length": %d, "what": "sub0"}',
      [P.subPos[0], P.subLen[0]]);
    L.Add(line);
    { the bands, computed as ppacodec cuts them }
    sub := 1;
    for s := 0 to High(P.streams) do
      if P.streams[s].mode in [MODE_IMAGE, MODE_FAST, MODE_STATIC] then begin
        if not StreamImage(png, s, info) or not InitLayout(info, px) then raise EParse.Create('image header');
        r := BandRows(px);
        y := 0;
        repeat
          if sub < P.nSubs then
            L.Add(Format('    ,{"index": %d, "offset": %d, "length": %d, "what": "band", "stream": %d, "band": %d}',
              [sub, P.subPos[sub], P.subLen[sub], s, y div Max(r, 1)]));
          Inc(sub); Inc(y, r);
        until (y >= px.passes[0].height) or (r <= 0);
      end;
    for s := 0 to High(P.streams) do
      if P.streams[s].mode = MODE_JPEG then begin
        if sub < P.nSubs then
          L.Add(Format('    ,{"index": %d, "offset": %d, "length": %d, "what": "jpeg", "stream": %d}',
            [sub, P.subPos[sub], P.subLen[sub], s]));
        Inc(sub);
      end;
    L.Add('  ],');
    Check('substream_count', sub = P.nSubs);

    line := Format('  "sub0": {"meta_len": %d, "file_len": %d, "byte_streams": [', [Length(P.meta), Length(sub0)]);
    first := True;
    for s := 0 to High(P.streams) do
      if P.streams[s].mode = MODE_BYTES then begin
        if not first then line := line + ', ';
        line := line + Format('{"stream": %d, "offset": %d, "length": %d}', [s, byteOff[s], P.streams[s].len]);
        first := False;
        Check(Format('bytes_stream_%d_matches', [s]), Same(sub0, byteOff[s], png.streams[s].data, 0, P.streams[s].len)
          and (Length(png.streams[s].data) = P.streams[s].len));
      end;
    L.Add(line + ']},');

    L.Add('  "chunks": [');
    for i := 0 to High(P.chunks) do
      with P.chunks[i] do
        L.Add(Format('    %s{"index": %d, "type": %s, "len": %d, "file_offset": %d, "data_offset": %d, "crc_ok": %s, "stream": %d, "seq": %d}',
          [IfThen(i > 0, ',', ''), i, JS(ChunkName(typ)), len, fileOff, fileOff + 8, JB(flags and 1 <> 0), stream, seq]));
    L.Add('  ],');

    { the streams }
    L.Add('  "streams": [');
    sub := 1;
    for s := 0 to High(P.streams) do begin
      with P.streams[s] do begin
        nat := -1;
        if (natural) and (s <= High(P2.streams)) then nat := P2.streams[s].mode;
        if mode = MODE_BYTES then Inc(totBytesStreams)
        else if mode = MODE_JPEG then Inc(totJpeg)
        else if mode = MODE_STATIC then begin Inc(nImgStatic); Inc(totStatic); end
        else begin
          Inc(nImgOther); allStatic := False;
          if mode = MODE_FAST then Inc(totFast) else Inc(totSlow);
        end;
        if mode <> MODE_STATIC then allStatic := False;
        if natural and (mode in [MODE_IMAGE, MODE_FAST, MODE_STATIC]) then
          if nat = MODE_STATIC then Inc(totNatStatic) else Inc(totNatOther);
        ranges := ''; line := '';
        for i := 0 to High(P.chunks) do
          if P.chunks[i].stream = s then begin
            if line <> '' then begin line := line + ', '; ranges := ranges + ', '; end;
            line := line + IntToStr(i);
            if P.chunks[i].typ = CT_fdAT then
              ranges := ranges + Format('[%d, %d]', [P.chunks[i].fileOff + 12, P.chunks[i].len - 4])
            else ranges := ranges + Format('[%d, %d]', [P.chunks[i].fileOff + 8, P.chunks[i].len]);
          end;
        L.Add(Format('    %s{"index": %d, "kind": %s, "header_chunk": %d, "frame_chunk": %d, "mode": %d, "mode_name": %s, "natural_mode": %d, "length": %d,',
          [IfThen(s > 0, ',', ''), s, JS(SKIND_NAMES[Min(kind, 3)]), header, frame, mode, JS(MNAMES[Min(mode, 4)]), nat, len]));
        L.Add('     "chunks": [' + line + '], "file_ranges": [' + ranges + ']');
        { the stream's bytes straight from the original file }
        a := nil; SetLength(a, len); k := 0;
        for i := 0 to High(P.chunks) do
          if P.chunks[i].stream = s then begin
            if P.chunks[i].typ = CT_fdAT then j := P.chunks[i].fileOff + 12 else j := P.chunks[i].fileOff + 8;
            nb := P.chunks[i].len; if P.chunks[i].typ = CT_fdAT then Dec(nb, 4);
            if Same(d, j, d, j, nb) and (k + nb <= len) then Move(d[j], a[k], nb);
            Inc(k, nb);
          end;
        Check(Format('stream_%d_file_bytes_are_decompose', [s]), SameAll(a, png.streams[s].data));

        if mode in [MODE_IMAGE, MODE_FAST, MODE_STATIC] then begin
          if not StreamImage(png, s, info) then raise EParse.Create('image header');
          { the independent path: the original stream inflated, unfiltered }
          if not ppadeflate.Decode(a, zflags and 1 <> 0, MAX_IMAGE_BYTES, z).Ok then raise EParse.Create('Decode');
          plainOrig := z.plain;
          ok := Unfilter(plainOrig, info, pxRef);
          Check(Format('stream_%d_unfilters', [s]), ok);
          { the decoder's path }
          if mode = MODE_STATIC then begin
            if not InitLayout(info, px) then raise EParse.Create('layout');
            px.tail := pxTail;
          end else px := pxRef;
          filtLen := FilteredSize(px);
          L.Add(Format('     ,"image": {"width": %d, "height": %d, "color_type": %d, "bit_depth": %d, "interlace": %d, "bpp": %d, "filtered_bytes": %d, "pix_bytes": %d, "px_tail_len": %d,',
            [info.width, info.height, info.colorType, info.depth, info.interlace, px.bpp, filtLen, Length(px.data), Length(pxTail)]));
          line := '       "passes": [';
          for i := 0 to High(px.passes) do
            with px.passes[i] do
              line := line + IfThen(i > 0, ', ', '') + Format('{"width": %d, "height": %d, "row_bytes": %d, "first": %d, "first_line": %d}',
                [width, height, rowBytes, first, firstLine]);
          L.Add(line + '],');
          L.Add('       "bands": [');
          r := BandRows(px); y := 0; j := 0;
          repeat
            if mode = MODE_STATIC then begin
              if sub >= P.nSubs then raise EParse.Create('band without substream');
              { the band's first part, decoded, for a model port's check }
              pp := P.subPos[sub]; plen := GetV(st, pp);
              adec.Init(Copy(st, pp, plen), 0);
              mn := adec.Direct(32); nf := adec.Direct(32);
              bmeta := nil; SetLength(bmeta, mn);
              bm.Init; CodeBytes(bm, bmeta, 0, mn, nil, @adec);
              WriteBytes(Format('%s.s%d.b%d.meta', [base, s, j]), bmeta, 0, mn);
              ok := DecodeImageStatic(px, y, r, st, P.subPos[sub], P.subLen[sub], P.version);
              Check(Format('stream_%d_band_%d_decodes', [s, j]), ok);
              L.Add(Format('         %s{"sub": %d, "first_row": %d, "rows": %d, "sub_offset": %d, "sub_len": %d, "part_len": %d, "meta_len": %d, "freq_bytes": %d, "lines": %d, "rans_len": %d}',
                [IfThen(j > 0, ',', ''), sub, y, Min(r, px.passes[0].height - y), P.subPos[sub], P.subLen[sub], plen, mn, nf, mn - nf,
                 P.subLen[sub] - (pp - P.subPos[sub]) - plen]));
            end else
              L.Add(Format('         %s{"sub": %d, "first_row": %d, "rows": %d, "sub_offset": %d, "sub_len": %d}',
                [IfThen(j > 0, ',', ''), sub, y, Min(r, px.passes[0].height - y), P.subPos[sub], P.subLen[sub]]));
            Inc(sub); Inc(j); Inc(nBands); Inc(totBands);
            Inc(y, r);
          until (y >= px.passes[0].height) or (r <= 0);
          L.Add('       ]}');
          if mode = MODE_STATIC then begin
            Check(Format('stream_%d_pix_equal_unfilter', [s]), SameAll(px.data, pxRef.data));
            Check(Format('stream_%d_filters_equal_unfilter', [s]), SameAll(px.filters, pxRef.filters));
          end;
          plain := Refilter(px);
          Check(Format('stream_%d_refilter_equals_inflated', [s]), SameAll(plain, plainOrig));
          WriteBytes(Format('%s.img%d.filt', [base, s]), plain, 0, Min(filtLen, Length(plain)));
          WriteBytes(Format('%s.img%d.pix', [base, s]), px.data, 0, Length(px.data));
          WriteBytes(Format('%s.z%d.plain', [base, s]), plain, 0, Length(plain));
          { the deflate stream rebuilt from the plain bytes and the stream's parameters }
          prm.level := level; prm.strategy := strategy; prm.memLevel := memLevel; prm.wbits := wbits;
          ZlibChoices(plain, prm, nil, zc, 1);
          zc.raw := zflags and 1 <> 0; zc.adlerOk := zflags and 2 <> 0;
          zc.header[0] := h0; zc.header[1] := h1; zc.endPad := endPad; zc.tail := zTail;
          enc := Encode(zc);
          WriteBytes(Format('%s.z%d.deflate', [base, s]), enc, 0, Length(enc));
          ok := SameAll(enc, a);
          Check(Format('stream_%d_deflate_equals_file', [s]), ok);
          Inc(nZ); Inc(totZ); Inc(totZBytes, Length(enc)); Inc(totPlain, Length(plain));
          if ok then begin Inc(nZOk); Inc(totZOk); end;
          bt[0] := 0; bt[1] := 0; bt[2] := 0;
          line := '';
          for i := 0 to High(zc.blocks) do
            with zc.blocks[i] do begin
              Inc(bt[Ord(btype)]);
              line := line + IfThen(i > 0, ',', '') + Format('[%d,%d,%d,%d]', [Ord(btype), Ord(final), nTokens, storedLen]);
            end;
          L.Add(Format('     ,"zlib": {"level": %d, "strategy": %d, "mem_level": %d, "window_bits": %d, "raw": %s, "adler_ok": %s, "header": [%d, %d], "end_pad": %d, "tail_len": %d, "tail_hex": %s,',
            [level, strategy, memLevel, wbits, JB(zflags and 1 <> 0), JB(zflags and 2 <> 0), h0, h1, endPad, Length(zTail),
             JS(IfThen(Length(zTail) <= 64, Hex(zTail), ''))]));
          L.Add(Format('       "plain_len": %d, "deflate_len": %d, "deflate_ok": %s, "n_blocks": %d, "n_stored": %d, "n_fixed": %d, "n_dynamic": %d,',
            [Length(plain), Length(enc), JB(ok), Length(zc.blocks), bt[0], bt[1], bt[2]]));
          L.Add('       "blocks": [' + line + ']}');
        end;
        L.Add('     }');
      end;
    end;
    L.Add('  ],');
    if nImgStatic + nImgOther = 0 then allStatic := False;
    if allStatic then Inc(totAllStaticFiles);
    Inc(totImg, nImgStatic + nImgOther);
    L.Add('  "checks": {');
    for i := 0 to checks.Count - 1 do
      if i < checks.Count - 1 then L.Add(checks[i] + ',') else L.Add(checks[i]);
    L.Add('  }');
    L.Add('}');
    L.SaveToFile(base + '.json');
  except
    on e: Exception do begin
      okAll := False; errs := errs + ' EXCEPTION ' + e.ClassName + ': ' + e.Message;
      L.Add('  "exception": ' + JS(e.ClassName + ': ' + e.Message));
      L.SaveToFile(base + '.json.partial');
    end;
  end;
  if not okAll then begin Inc(totFail); failedAny := True; end;
  Writeln(Format('RESULT'#9'%s'#9'1'#9'%d'#9'%d'#9'%d'#9'%d'#9'%d'#9'%d'#9'%d'#9'%d'#9'%d'#9'%d'#9'%d'#9'%s'#9'%d'#9'%s'#9'%s',
    [name, Length(P.streams), nImgStatic, nImgOther, stats.modes[MODE_BYTES], stats.modes[MODE_JPEG], nBands, nZ, nZOk,
     Length(st), Length(P.meta), Length(sub0), JB(allStatic), Length(d), JB(okAll), Trim(errs)]));
  L.Free; checks.Free;
end;

var
  files: TStringList; sr: TSearchRec; i: Integer; arg: string;
begin
  BandBytes := StrToInt64Def(GetEnvironmentVariable('PPA_TEST_BAND_BYTES'), BAND_BYTES);
  if BandBytes < 1 then BandBytes := BAND_BYTES;
  outDir := ParamStr(1);
  if (outDir = '') or (ParamCount < 2) then begin
    Writeln('usage: dump_streams <out dir> <file or directory>... [-c] [-natural]');
    Halt(2);
  end;
  ForceDirectories(outDir);
  files := TStringList.Create; files.Sorted := True; files.Duplicates := dupIgnore;
  for i := 2 to ParamCount do begin
    arg := ParamStr(i);
    if arg = '-c' then keepC := True
    else if arg = '-natural' then natural := True
    else if DirectoryExists(arg) then begin
      if FindFirst(arg + '/*', faAnyFile, sr) = 0 then begin
        repeat if (sr.Attr and faDirectory) = 0 then files.Add(arg + '/' + sr.Name); until FindNext(sr) <> 0;
        FindClose(sr);
      end;
    end else files.Add(arg);
  end;
  Writeln('#RESULT'#9'file'#9'taken'#9'streams'#9'img_static'#9'img_other'#9'bytes_streams'#9'jpeg_streams'#9'bands'#9 +
    'zlib'#9'zlib_ok'#9'stream_len'#9'meta_len'#9'sub0_len'#9'all_static'#9'file_len'#9'ok'#9'errors');
  for i := 0 to files.Count - 1 do DoFile(files[i]);
  Writeln(Format('TOTAL'#9'files=%d taken=%d images=%d static=%d fast=%d slow=%d bytes_streams=%d jpeg=%d natural_static=%d natural_other=%d bands=%d zlib=%d zlib_ok=%d deflate_bytes=%d plain_bytes=%d in=%d stream=%d all_static_files=%d failed_files=%d',
    [totFiles, totTaken, totImg, totStatic, totFast, totSlow, totBytesStreams, totJpeg, totNatStatic, totNatOther, totBands,
     totZ, totZOk, totZBytes, totPlain, totIn, totStream, totAllStaticFiles, totFail]));
  files.Free;
  if failedAny then Halt(1);
end.
