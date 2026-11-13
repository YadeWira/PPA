{ ppapreflate, one deflate stream's API: every deflate stream in the
  directory through Analyze, and each recipe through RecipeBytesV2 and
  ReadRecipeV2 and Rebuild (on 1 thread and, cut in segments, on 4), which
  must give the stream back bit for bit. A file of the PNG family gives its
  image streams (IDAT, fdAT); any other file is one stream (.raw: bare
  deflate; else zlib if its header says so, bare otherwise).

    test_preflate <directory> [minimum streams] [-all0 | -none0] [-codec] [-v]

  -all0: every stream must have a kind-0 recipe (zlib's parameters: the
  regression set); -none0: none may (streams zlib does not write: each
  must be reported as not taken or not deflate, cleanly). -codec: also,
  per file, ppacodec.Compress with maxVersion 2 must give the very stream
  it gives by default (and ppa1's MODE_STATIC call the same), and versions
  it does not write must be refused. Then, whatever the directory, crafted
  cases: streams that are deflate but not zlib's (stored blocks of
  compressible bytes, a stream's blocks written with fixed codes), bytes
  that are not deflate, and damaged recipes (each cut, each value of each
  byte): refused, never raised on. }
program test_preflate;
{$I ../ppa.inc}
uses {$ifdef UNIX} cthreads, {$endif} SysUtils, Classes, DateUtils, ppapng, ppadeflate, ppazlib, ppapreflate,
  ppacodec;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

const MAX_PLAIN = 1 shl 30;

var
  failures, nStreams, nKind0, nNotDeflate, nNotTaken, bytesKind0: Int64;
  verbose: Boolean;

procedure Fail(const s: string);
begin
  Inc(failures); Writeln('  FAIL ', s);
end;

function Same(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

function SameRecipe(const a, b: TDeflRecipe): Boolean;
begin
  Result := (a.kind = b.kind) and (a.prm.level = b.prm.level) and (a.prm.strategy = b.prm.strategy) and
    (a.prm.memLevel = b.prm.memLevel) and (a.prm.wbits = b.prm.wbits) and (a.raw = b.raw) and
    (a.adlerOk = b.adlerOk) and (a.header[0] = b.header[0]) and (a.header[1] = b.header[1]) and
    (a.endPad = b.endPad) and Same(a.tail, b.tail);
end;

{ one stream: analysed; a recipe written, read back, rebuilt. Returns its
  status }
function CheckStream(const a: TBytes; framing: TDeflFraming; const name: string): TDeflStatus;
var plain, rb, back: TBytes; r, r2: TDeflRecipe; pos: SizeInt; saveMin, saveSeg: SizeInt;
begin
  Inc(nStreams);
  Result := Analyze(a, framing, MAX_PLAIN, plain, r);
  case Result of
    dsNotDeflate: begin Inc(nNotDeflate); if verbose then Writeln('  not deflate  ', name); Exit; end;
    dsNotTaken: begin Inc(nNotTaken); if verbose then Writeln('  not kind 0   ', name); Exit; end;
  end;
  Inc(nKind0); Inc(bytesKind0, Length(a));
  if verbose then
    Writeln(Format('  kind 0: level %d strategy %d memLevel %d wbits %d%s  %d bytes  %s',
      [r.prm.level, r.prm.strategy, r.prm.memLevel, r.prm.wbits, BoolToStr(r.raw, ' raw', ''), Length(a), name]));
  if not RecipeValid(r) then begin Fail('recipe not valid: ' + name); Exit; end;
  { as codec stream version 2 writes it, and read back }
  rb := RecipeBytesV2(r);
  pos := 0;
  if (ReadRecipeV2(rb, pos, Length(a), r2) <> rrOk) or (pos <> Length(rb)) or not SameRecipe(r, r2) then begin
    Fail('recipe not read back: ' + name); Exit;
  end;
  if not Rebuild(plain, r2, back, 1) or not Same(back, a) then begin Fail('rebuild differs: ' + name); Exit; end;
  { cut into segments (ppazlib's parallel rebuild) on 4 threads: the same }
  saveMin := ppazlib.PAR_MIN_BYTES; saveSeg := ppazlib.PAR_SEG_MIN;
  ppazlib.PAR_MIN_BYTES := 512; ppazlib.PAR_SEG_MIN := 128;
  try
    if not Rebuild(plain, r2, back, 4) or not Same(back, a) then Fail('rebuild on 4 threads differs: ' + name);
  finally
    ppazlib.PAR_MIN_BYTES := saveMin; ppazlib.PAR_SEG_MIN := saveSeg;
  end;
end;

{ ppacodec.Compress and maxVersion: version 2 is what it writes today }
procedure CheckCodec(const d: TBytes; const name: string);
var s0, s2: TBytes; why: string; stats: TCodecStats; t0, t2: Boolean;
begin
  t0 := Compress(d, s0, why, stats, False, 1);
  t2 := Compress(d, s2, why, stats, False, 1, -1, 2);
  if (t0 <> t2) or not Same(s0, s2) then Fail('Compress with maxVersion 2 differs: ' + name);
  if t0 and (s0[0] <> 2) then Fail('Compress wrote a version other than 2: ' + name);
  { ppa1's call (the zpaq-std plugin) }
  t0 := Compress(d, s0, why, stats, False, 1, MODE_STATIC);
  t2 := Compress(d, s2, why, stats, False, 1, MODE_STATIC, 2);
  if (t0 <> t2) or not Same(s0, s2) then Fail('Compress (MODE_STATIC) with maxVersion 2 differs: ' + name);
  if Compress(d, s2, why, stats, False, 1, -1, 1) or (s2 <> nil) then Fail('maxVersion 1 not refused: ' + name);
  if Compress(d, s2, why, stats, False, 1, -1, STREAM_VERSION + 1) then Fail('maxVersion 3 not refused: ' + name);
end;

{ ---------------------------------------------------------------- crafted cases }

var samples: array of TBytes;   { image streams with a kind-0 recipe, for the crafted cases }

procedure Crafted;
var a, rb, back, plain: TBytes; z, zf: TZStream; r, r2: TDeflRecipe; i, k, v, n: Integer; pos: SizeInt;
  st: TDeflStatus; fixedNotTaken: Integer; rr: TRecipeRead;
begin
  { stored blocks of compressible bytes: deflate, never zlib's (it stores
    only what its codes would not make smaller) }
  n := 3000;
  a := nil; SetLength(a, 5 + n);
  a[0] := 1; a[1] := n and 255; a[2] := n shr 8; a[3] := not a[1]; a[4] := not a[2];
  for i := 0 to n - 1 do a[5 + i] := i mod 7;
  st := CheckStream(a, dfRaw, 'crafted: stored');
  if st <> dsNotTaken then Fail('crafted stored stream: not reported as not taken');
  { not deflate: block type 3; and nothing at all }
  a := nil; SetLength(a, 4); a[0] := 7;
  if CheckStream(a, dfRaw, 'crafted: block type 3') <> dsNotDeflate then Fail('block type 3: not reported as not deflate');
  if CheckStream(nil, dfAuto, 'crafted: empty') <> dsNotDeflate then Fail('empty: not reported as not deflate');
  a := nil; SetLength(a, 2); a[0] := $78; a[1] := $9C;
  if CheckStream(a, dfZlib, 'crafted: header only') <> dsNotDeflate then Fail('header only: not reported as not deflate');

  { each sample's blocks written with fixed codes: deflate the bytes decode
    from, rarely zlib's choice (when it is, it must still round-trip) }
  fixedNotTaken := 0;
  for k := 0 to High(samples) do begin
    if not Parse(samples[k], dfAuto, MAX_PLAIN, z).Ok then begin Fail('sample does not parse'); Continue; end;
    zf := z;
    zf.blocks := Copy(z.blocks, 0, Length(z.blocks));
    for i := 0 to High(zf.blocks) do
      if zf.blocks[i].btype = btDynamic then zf.blocks[i].btype := btFixed;
    a := Encode(zf);
    st := CheckStream(a, dfAuto, 'crafted: fixed codes ' + IntToStr(k));
    if st = dsNotTaken then Inc(fixedNotTaken)
    else if st = dsNotDeflate then Fail('fixed codes: not deflate');
    { the same stream with bytes after it, and with a wrong Adler-32: kind 0,
      the framing kept }
    a := Copy(samples[k], 0, Length(samples[k]));
    SetLength(a, Length(a) + 3); a[High(a)] := 1; a[High(a) - 1] := 2; a[High(a) - 2] := 3;
    if CheckStream(a, dfAuto, 'crafted: tail ' + IntToStr(k)) <> dsOk then Fail('a stream with a tail: not kind 0');
    if not z.raw and z.adlerOk and (Length(z.tail) = 0) then begin
      a := Copy(samples[k], 0, Length(samples[k]));
      a[High(a)] := a[High(a)] xor 1;
      if CheckStream(a, dfAuto, 'crafted: bad adler ' + IntToStr(k)) <> dsOk then Fail('a stream with a bad Adler-32: not kind 0');
    end;
  end;
  if (Length(samples) > 0) and (fixedNotTaken = 0) then Fail('no fixed-code stream was refused');

  { damaged recipes: every cut of one with a tail, every value of each of its
    first 8 bytes. Refused, or read and then rebuilt (or refused) without
    raising }
  if Length(samples) > 0 then begin
    Analyze(samples[0], dfAuto, MAX_PLAIN, plain, r);
    r.tail := TBytes.Create(9, 8, 7);
    rb := RecipeBytesV2(r);
    for n := 0 to Length(rb) - 1 do begin
      pos := 0;
      if ReadRecipeV2(Copy(rb, 0, n), pos, 100, r2) = rrOk then Fail('a cut recipe was read: ' + IntToStr(n));
    end;
    pos := 0;
    if ReadRecipeV2(rb, pos, 2, r2) = rrOk then Fail('a tail past maxTail was read');
    for i := 0 to 7 do
      for v := 0 to 255 do begin
        a := Copy(rb, 0, Length(rb));
        a[i] := v;
        pos := 0;
        try
          rr := ReadRecipeV2(a, pos, 100, r2);
          if (rr = rrOk) and not RecipeValid(r2) then Fail('parameters read out of range');
          if (rr = rrBadParams) and RecipeValid(r2) then Fail('parameters in range refused');
          if (i = 4) and (v > 3) and (rr = rrOk) then Fail('flags above 3 read');
          if rr = rrOk then Rebuild(Copy(plain, 0, 200), r2, back);
        except
          on e: Exception do Fail('damaged recipe raised ' + e.ClassName);
        end;
      end;
    r2 := r; r2.kind := 1;
    if Rebuild(plain, r2, back) or (back <> nil) then Fail('a recipe of an unknown kind rebuilt');
    r2 := r; r2.prm.level := 0;
    if Rebuild(plain, r2, back) then Fail('a recipe of level 0 rebuilt');
  end;
end;

var
  files: TStringList; sr: TSearchRec; dir, name, ext: string; i, minimum: Integer; all0, none0, codec: Boolean;
  d: TBytes; p: TPng; s: SizeInt; st: TDeflStatus; t0: TDateTime; framing: TDeflFraming;
  dirStreams, dirBytes, dirKind0, dirNotTaken, dirNotDeflate: Int64;
begin
  dir := ParamStr(1); minimum := StrToIntDef(ParamStr(2), 1);
  all0 := False; none0 := False; codec := False; verbose := False;
  for i := 2 to ParamCount do
    if ParamStr(i) = '-all0' then all0 := True
    else if ParamStr(i) = '-none0' then none0 := True
    else if ParamStr(i) = '-codec' then codec := True
    else if ParamStr(i) = '-v' then verbose := True;
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat
      if ((sr.Attr and faDirectory) = 0) and (sr.Name <> 'MANIFEST.tsv') then files.Add(dir + '/' + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  failures := 0; nStreams := 0; nKind0 := 0; nNotDeflate := 0; nNotTaken := 0; bytesKind0 := 0;
  samples := nil;
  t0 := Now;
  for i := 0 to files.Count - 1 do begin
    name := ExtractFileName(files[i]);
    d := ReadFile(files[i]);
    try
      if ppapng.Decompose(d, p).Ok then begin
        for s := 0 to High(p.streams) do
          if p.streams[s].kind in [skIdat, skFdat] then begin
            st := CheckStream(p.streams[s].data, dfAuto, name + ' #' + IntToStr(s));
            if all0 and (st <> dsOk) then Fail('not kind 0: ' + name + ' #' + IntToStr(s));
            if none0 and (st = dsOk) then Fail('kind 0: ' + name + ' #' + IntToStr(s));
            if (st = dsOk) and (Length(samples) < 8) and (Length(p.streams[s].data) < 1 shl 20) then begin
              SetLength(samples, Length(samples) + 1);
              samples[High(samples)] := p.streams[s].data;
            end;
          end;
        if codec then CheckCodec(d, name);
      end else begin
        ext := LowerCase(ExtractFileExt(name));
        if ext = '.raw' then framing := dfRaw else framing := dfAuto;
        st := CheckStream(d, framing, name);
        if all0 and (st <> dsOk) then Fail('not kind 0: ' + name);
        if none0 and (st = dsOk) then Fail('kind 0: ' + name);
      end;
    except
      on e: Exception do Fail(e.ClassName + ': ' + e.Message + '  ' + name);
    end;
  end;
  { the directory's own counts; then the crafted cases' }
  dirStreams := nStreams; dirBytes := bytesKind0; dirKind0 := nKind0; dirNotTaken := nNotTaken; dirNotDeflate := nNotDeflate;
  try
    Crafted;
  except
    on e: Exception do Fail('crafted cases: ' + e.ClassName + ': ' + e.Message);
  end;
  if dirStreams < minimum then Fail(Format('%d streams < minimum %d', [dirStreams, minimum]));
  Writeln(Format('%d streams: %d kind 0 (%d bytes; written, read and rebuilt the same), %d not kind 0, ' +
    '%d not deflate; crafted: %d kind 0, %d not kind 0, %d not deflate; %.1f s; %d failures',
    [dirStreams, dirKind0, dirBytes, dirNotTaken, dirNotDeflate, nKind0 - dirKind0, nNotTaken - dirNotTaken,
     nNotDeflate - dirNotDeflate, SecondSpan(Now, t0), failures]));
  if failures > 0 then Halt(1);
end.
