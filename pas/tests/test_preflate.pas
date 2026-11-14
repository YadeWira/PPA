{ ppapreflate, one deflate stream's API: every deflate stream in the
  directory through Analyze, and each recipe written and read back (kind 0
  as codec stream version 2 writes it and in RecipeBytes' format; kind 1
  in RecipeBytes') and rebuilt (on 1 thread and, cut in segments, on 4),
  which must give the stream back bit for bit. A file of the PNG family
  gives its image streams (IDAT, fdAT); any other file is one stream (.raw:
  bare deflate; else zlib if its header says so, bare otherwise).

    test_preflate <directory> [minimum streams] [-all0 | -none0 | -all01] [-min1 N] [-minok N] [-only TEXT] [-codec] [-v]

  -all0: every stream must have a kind-0 recipe (zlib's parameters: the
  regression set); -none0: none may (streams zlib does not write alone:
  each must be reported as kind 1, not taken or not deflate, cleanly);
  -all01: every stream must have a kind-0 or kind-1 recipe (zlib with its
  flushes and parameter changes); -min1 N: at least N of kind 1; -minok
  N: at least N with a recipe (kind 0 or 1); -only
  TEXT: only the files whose name holds TEXT. -codec:
  also, per file, ppacodec.Compress with maxVersion 2 must give the very
  stream it gives by default (and ppa1's MODE_STATIC call the same), and
  versions it does not write must be refused. The last line has a digest
  of every recipe's bytes, the same from the C and the Pascal code.

  Then, whatever the directory, crafted cases: streams that are deflate
  but not zlib's (stored blocks of compressible bytes, a stream's blocks
  written with fixed codes), bytes that are not deflate, damaged kind-0
  recipes (each cut, each value of each byte), streams zlib's emulation
  makes with flushes and parameter changes in each zlib version (Analyze
  must find a kind-1 recipe that gives them back), and damaged kind-1
  recipes and flows: refused, never raised on. }
program test_preflate;
{$I ../ppa.inc}
uses {$ifdef UNIX} cthreads, {$endif} SysUtils, Classes, DateUtils, ppapng, ppadeflate, ppazlib, ppapreflate,
  ppacodec;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

const MAX_PLAIN = 1 shl 30;

var
  failures, nStreams, nKind0, nKind1, nNotDeflate, nNotTaken, bytesKind0, bytesKind1: Int64;
  verbose: Boolean;
  recipeHash: QWord;   { FNV-1a of every recipe's bytes, in order }

procedure Fail(const s: string);
begin
  Inc(failures); Writeln('  FAIL ', s);
end;

function Same(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

procedure HashRecipe(const b: TBytes);
var i: SizeInt;
begin
  for i := 0 to High(b) do begin
    {$push}{$Q-}{$R-}
    recipeHash := (recipeHash xor b[i]) * QWord($100000001B3);
    {$pop}
  end;
end;

function SameRecipe(const a, b: TDeflRecipe): Boolean;
var k: SizeInt;
begin
  Result := (a.kind = b.kind) and (a.prm.level = b.prm.level) and (a.prm.strategy = b.prm.strategy) and
    (a.prm.memLevel = b.prm.memLevel) and (a.prm.wbits = b.prm.wbits) and (a.raw = b.raw) and
    (a.adlerOk = b.adlerOk) and (a.header[0] = b.header[0]) and (a.header[1] = b.header[1]) and
    (a.endPad = b.endPad) and Same(a.tail, b.tail) and (a.flow.variant = b.flow.variant) and
    (Length(a.flow.events) = Length(b.flow.events));
  if Result then
    for k := 0 to High(a.flow.events) do
      if (a.flow.events[k].pos <> b.flow.events[k].pos) or (a.flow.events[k].kind <> b.flow.events[k].kind) or
         (a.flow.events[k].level <> b.flow.events[k].level) or (a.flow.events[k].strategy <> b.flow.events[k].strategy) then
        Exit(False);
end;

function FlowText(const r: TDeflRecipe): string;
const NAMES: array[ZE_SYNC..ZE_PARAMS] of string = ('sync', 'full', 'partial', 'block', 'params');
var c: array[ZE_SYNC..ZE_PARAMS] of Integer; k: SizeInt; i: Integer;
begin
  FillChar(c, SizeOf(c), 0);
  for k := 0 to High(r.flow.events) do Inc(c[r.flow.events[k].kind]);
  Result := Format(' zlib flushes %d:', [r.flow.variant]);
  for i := ZE_SYNC to ZE_PARAMS do if c[i] > 0 then Result := Result + Format(' %s %d', [NAMES[i], c[i]]);
  for k := 0 to High(r.flow.events) do
    if r.flow.events[k].kind = ZE_PARAMS then
      Result := Result + Format(' (@%d L%d s%d)', [r.flow.events[k].pos, r.flow.events[k].level, r.flow.events[k].strategy]);
end;

{ one stream: analysed; a recipe written, read back, rebuilt. Returns its
  status; kind, the recipe's kind (-1 without one) }
function CheckStream(const a: TBytes; framing: TDeflFraming; const name: string; out kind: Integer): TDeflStatus;
var plain, rb, back: TBytes; r, r2: TDeflRecipe; pos: SizeInt; saveMin, saveSeg: SizeInt;
begin
  Inc(nStreams);
  kind := -1;
  Result := Analyze(a, framing, MAX_PLAIN, plain, r);
  case Result of
    dsNotDeflate: begin Inc(nNotDeflate); if verbose then Writeln('  not deflate  ', name); Exit; end;
    dsNotTaken: begin Inc(nNotTaken); if verbose then Writeln('  not taken    ', name); Exit; end;
  end;
  kind := r.kind;
  if r.kind = RECIPE_ZLIB then begin Inc(nKind0); Inc(bytesKind0, Length(a)); end
  else begin Inc(nKind1); Inc(bytesKind1, Length(a)); end;
  if verbose then begin
    Write(Format('  kind %d: level %d strategy %d memLevel %d wbits %d%s  %d bytes',
      [r.kind, r.prm.level, r.prm.strategy, r.prm.memLevel, r.prm.wbits, BoolToStr(r.raw, ' raw', ''), Length(a)]));
    if r.kind = RECIPE_ZLIB_FLOW then Write(FlowText(r));
    Writeln('  ', name);
  end;
  if not RecipeValid(r) then begin Fail('recipe not valid: ' + name); Exit; end;
  { kind 0: as codec stream version 2 writes it, and read back }
  if r.kind = RECIPE_ZLIB then begin
    rb := RecipeBytesV2(r);
    pos := 0;
    if (ReadRecipeV2(rb, pos, Length(a), r2) <> rrOk) or (pos <> Length(rb)) or not SameRecipe(r, r2) then begin
      Fail('recipe not read back (version 2): ' + name); Exit;
    end;
  end;
  { any kind in RecipeBytes' format }
  rb := RecipeBytes(r);
  HashRecipe(rb);
  pos := 0;
  if (ReadRecipe(rb, pos, Length(plain), Length(a), r2) <> rrOk) or (pos <> Length(rb)) or not SameRecipe(r, r2) then begin
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

procedure Ev(var f: TZlibFlow; pos: SizeInt; kind: Byte; lv: Byte = 0; sg: Byte = 0);
begin
  SetLength(f.events, Length(f.events) + 1);
  f.events[High(f.events)].pos := pos; f.events[High(f.events)].kind := kind;
  f.events[High(f.events)].level := lv; f.events[High(f.events)].strategy := sg;
end;

{ streams zlib's emulation makes with flushes and parameter changes, in
  each zlib version: Analyze must give each back (kind 1, or kind 0 where
  the flow happens to change nothing) }
procedure CraftedFlows;
var k, v, j, kind: Integer; z: TZStream; plain, a: TBytes; prm: TZlibParams; f: TZlibFlow; e: TZStream;
  n: SizeInt; good: SizeInt; st: TDeflStatus; made: Integer;
begin
  made := 0;
  for k := 0 to High(samples) do begin
    if not Parse(samples[k], dfAuto, MAX_PLAIN, z).Ok then Continue;
    { the first 64 KB of its bytes are enough (and keep it quick) }
    plain := Copy(z.plain, 0, 1 shl 16); n := Length(plain);
    if n < 2000 then Continue;
    for v := ZV_NEW to ZV_LAST do
      for j := 0 to 5 do begin
        prm.level := 6; prm.strategy := Z_DEFAULT_STRATEGY; prm.memLevel := 8; prm.wbits := 15;
        f := Default(TZlibFlow); f.variant := v;
        case j of
          0: begin Ev(f, n div 4, ZE_SYNC); Ev(f, n div 2, ZE_SYNC); Ev(f, 3 * n div 4, ZE_SYNC); end;
          1: begin prm.level := 9; Ev(f, n div 3, ZE_FULL); Ev(f, 2 * n div 3, ZE_SYNC); end;
          2: begin prm.level := 1; prm.memLevel := 7; Ev(f, n div 5, ZE_PARTIAL); Ev(f, n div 5 + 7, ZE_PARTIAL);
               Ev(f, n div 2, ZE_PARTIAL); Ev(f, n div 2 + 20, ZE_PARTIAL); end;
          3: begin Ev(f, 0, ZE_SYNC); Ev(f, n div 2, ZE_BLOCK); Ev(f, n div 2, ZE_PARAMS, 1, Z_DEFAULT_STRATEGY); end;
          4: begin prm.level := 9; Ev(f, n div 3, ZE_BLOCK); Ev(f, n div 3, ZE_PARAMS, 9, Z_FILTERED);
               Ev(f, 2 * n div 3, ZE_SYNC); Ev(f, 2 * n div 3, ZE_PARAMS, 4, Z_DEFAULT_STRATEGY); end;
          5: begin Ev(f, n div 3, ZE_PARTIAL); Ev(f, n div 3, ZE_SYNC); Ev(f, n - 1, ZE_FULL); Ev(f, n, ZE_SYNC); end;
        end;
        if not ZlibFlowValid(f, prm, n) then begin Fail(Format('crafted flow %d not valid', [j])); Continue; end;
        ZlibChoicesFlow(plain, prm, f, nil, e, good);
        e.raw := z.raw; e.header := z.header; e.adlerOk := z.adlerOk; e.endPad := 0; e.tail := nil;
        if e.raw then e.adlerOk := False;
        a := Encode(e);
        st := CheckStream(a, dfAuto, Format('crafted: flow %d zlib %d sample %d', [j, v, k]), kind);
        if st <> dsOk then Fail(Format('crafted flow %d (zlib flushes %d) of sample %d: not taken', [j, v, k]));
        Inc(made);
      end;
    if made >= 36 then Break;
  end;
  if (Length(samples) > 0) and (made = 0) then Fail('no crafted flow was made');
end;

{ a change of loop after a flush (deflate_fast or deflate_rle, then a
  filtered deflate_slow: it starts with prev_length 0, where zlib's
  longest_match wants the byte before each candidate the same as the byte
  before the scan): the C loop and the Pascal reference must make the
  same choices, at many places in each sample }
procedure LoopSwitchFlows;
var k, v, j, i: Integer; z, ec, ep: TZStream; plain: TBytes; prm: TZlibParams; f: TZlibFlow; n, q, good: SizeInt;
  was: Boolean; made: Integer;
begin
  made := 0;
  was := UseZlibC;
  for k := 0 to High(samples) do begin
    if k >= 4 then Break;
    if not Parse(samples[k], dfAuto, MAX_PLAIN, z).Ok then Continue;
    plain := Copy(z.plain, 0, 1 shl 16); n := Length(plain);
    if n < 2000 then Continue;
    for v := ZV_NEW to ZV_LAST do
      for j := 0 to 3 do
        for i := 1 to 8 do begin
          q := n * i div 9;
          prm.memLevel := 8; prm.wbits := 15;
          f := Default(TZlibFlow); f.variant := v;
          case j of
            0: begin prm.level := 1; prm.strategy := Z_DEFAULT_STRATEGY; Ev(f, q, ZE_BLOCK); Ev(f, q, ZE_PARAMS, 9, Z_FILTERED); end;
            1: begin prm.level := 6; prm.strategy := Z_RLE; Ev(f, q, ZE_SYNC); Ev(f, q, ZE_PARAMS, 6, Z_FILTERED); end;
            2: begin prm.level := 2; prm.strategy := Z_DEFAULT_STRATEGY; Ev(f, q, ZE_FULL); Ev(f, q, ZE_PARAMS, 8, Z_FILTERED); end;
            3: begin prm.level := 3; prm.strategy := Z_HUFFMAN_ONLY; Ev(f, q div 2, ZE_PARTIAL); Ev(f, q div 2, ZE_PARAMS, 3, 0);
                 Ev(f, q, ZE_SYNC); Ev(f, q, ZE_PARAMS, 9, Z_FILTERED); end;
          end;
          if not ZlibFlowValid(f, prm, n) then begin Fail(Format('loop switch flow %d not valid', [j])); Continue; end;
          try
            UseZlibC := True; ZlibChoicesFlow(plain, prm, f, nil, ec, good);
            UseZlibC := False; ZlibChoicesFlow(plain, prm, f, nil, ep, good);
          finally
            UseZlibC := was;
          end;
          if (Length(ec.tokLen) <> Length(ep.tokLen)) or (Length(ec.blocks) <> Length(ep.blocks)) or
             ((Length(ec.tokLen) > 0) and (not CompareMem(@ec.tokLen[0], @ep.tokLen[0], Length(ec.tokLen) * 2) or
              not CompareMem(@ec.tokVal[0], @ep.tokVal[0], Length(ec.tokVal) * 2))) then
            Fail(Format('loop switch flow %d (zlib flushes %d) at %d of sample %d: C and Pascal differ', [j, v, q, k]));
          Inc(made);
        end;
  end;
  if (Length(samples) > 0) and (made = 0) then Fail('no loop switch flow was made');
end;

{ kind-1 recipes damaged: each cut, each value of the first bytes;
  flows out of order, past the bytes, a loop changed without a flush, too
  many events: refused, or read and rebuilt without raising }
procedure DamagedFlows;
var z: TZStream; plain, rb, a, back: TBytes; r, r2: TDeflRecipe; n, pos: SizeInt; i, v: Integer; rr: TRecipeRead;
begin
  if Length(samples) = 0 then Exit;
  if not Parse(samples[0], dfAuto, MAX_PLAIN, z).Ok then Exit;
  { 4 KB of its bytes: every damaged recipe is rebuilt }
  plain := Copy(z.plain, 0, 4096); n := Length(plain);
  if n < 64 then Exit;
  r := Default(TDeflRecipe);
  r.kind := RECIPE_ZLIB_FLOW; r.prm.level := 6; r.prm.strategy := 0; r.prm.memLevel := 8; r.prm.wbits := 15;
  r.raw := True; r.tail := TBytes.Create(1, 2);
  Ev(r.flow, n div 3, ZE_SYNC); Ev(r.flow, n div 3, ZE_PARAMS, 2, 0); Ev(r.flow, n div 2, ZE_PARTIAL);
  Ev(r.flow, n div 2, ZE_BLOCK); Ev(r.flow, n div 2, ZE_PARAMS, 9, Z_FILTERED); Ev(r.flow, n, ZE_FULL);
  rb := RecipeBytes(r);
  pos := 0;
  if (ReadRecipe(rb, pos, n, 100, r2) <> rrOk) or not SameRecipe(r, r2) then Fail('a kind-1 recipe not read back');
  if not Rebuild(plain, r, back) then Fail('a kind-1 recipe not rebuilt');
  for i := 0 to Length(rb) - 1 do begin
    pos := 0;
    if ReadRecipe(Copy(rb, 0, i), pos, n, 100, r2) = rrOk then Fail('a cut kind-1 recipe was read: ' + IntToStr(i));
  end;
  pos := 0;
  if ReadRecipe(rb, pos, n div 3 - 1, 100, r2) = rrOk then Fail('a kind-1 recipe past its bytes was read');
  for i := 0 to Length(rb) - 1 do
    for v := 0 to 255 do begin
      a := Copy(rb, 0, Length(rb));
      a[i] := v;
      pos := 0;
      try
        rr := ReadRecipe(a, pos, n, 100, r2);
        if (rr = rrOk) and (not RecipeValid(r2) or not ZlibFlowValid(r2.flow, r2.prm, n)) then Fail('a kind-1 recipe read out of range');
        if rr = rrOk then Rebuild(plain, r2, back);
      except
        on e: Exception do Fail('damaged kind-1 recipe raised ' + e.ClassName);
      end;
    end;
  { a count of events no bytes hold: refused before it is kept }
  a := TBytes.Create(RECIPE_FORMAT, RECIPE_ZLIB_FLOW, 6, 0, 8, 15, 0, $FF, $FF, $FF, $FF, $07);
  pos := 0;
  if ReadRecipe(a, pos, MAX_PLAIN, 100, r2) = rrOk then Fail('a kind-1 recipe of 2^31 events was read');
  { flows Rebuild must refuse }
  r2 := r; r2.flow.events := Copy(r.flow.events, 0, Length(r.flow.events));
  r2.flow.events[0].pos := n div 2 + 1;
  if Rebuild(plain, r2, back) then Fail('events out of order rebuilt');
  r2 := r; r2.flow.events := Copy(r.flow.events, 0, Length(r.flow.events));
  r2.flow.events[High(r2.flow.events)].pos := n + 1;
  if Rebuild(plain, r2, back) then Fail('an event past the bytes rebuilt');
  r2 := r; r2.flow.events := nil; Ev(r2.flow, n div 2, ZE_PARAMS, 1, 0);
  if Rebuild(plain, r2, back) then Fail('deflate_slow to deflate_fast without a flush rebuilt');
  r2 := r; r2.flow.events := nil; Ev(r2.flow, n div 2, ZE_PARAMS, 6, Z_RLE);
  if Rebuild(plain, r2, back) then Fail('a strategy change without a flush rebuilt');
  r2 := r; r2.flow.events := nil; Ev(r2.flow, n div 2, ZE_PARAMS, 9, 0);
  if not Rebuild(plain, r2, back) then Fail('a level change of the same loop not rebuilt');
  r2 := r; r2.flow.variant := ZV_LAST + 1;
  if Rebuild(plain, r2, back) then Fail('an unknown zlib version rebuilt');
  r2 := r; r2.flow.events := Copy(r.flow.events, 0, Length(r.flow.events)); r2.flow.events[1].level := 0;
  if Rebuild(plain, r2, back) then Fail('a level 0 change rebuilt');
  r2 := r; r2.flow.events := Copy(r.flow.events, 0, Length(r.flow.events)); r2.flow.events[0].kind := 6;
  if Rebuild(plain, r2, back) then Fail('an unknown event rebuilt');
  r2 := r; r2.kind := RECIPE_ZLIB;
  if Rebuild(plain, r2, back) then Fail('a kind-0 recipe with events rebuilt');
  { at one position: a partial, a sync, a full flush and a change at most }
  r2 := r; r2.flow.events := nil;
  Ev(r2.flow, 10, ZE_PARTIAL); Ev(r2.flow, 10, ZE_SYNC); Ev(r2.flow, 10, ZE_FULL); Ev(r2.flow, 10, ZE_PARAMS, 1, 0);
  if not Rebuild(plain, r2, back) then Fail('four events at one position not rebuilt');
  Ev(r2.flow, 10, ZE_SYNC);
  if Rebuild(plain, r2, back) then Fail('five events at one position rebuilt');
end;

procedure Crafted;
var a, rb, back, plain: TBytes; z, zf: TZStream; r, r2: TDeflRecipe; i, k, v, n, kind: Integer; pos: SizeInt;
  st: TDeflStatus; fixedNotTaken: Integer; rr: TRecipeRead;
begin
  { stored blocks of compressible bytes: deflate, never zlib's (it stores
    only what its codes would not make smaller) }
  n := 3000;
  a := nil; SetLength(a, 5 + n);
  a[0] := 1; a[1] := n and 255; a[2] := n shr 8; a[3] := not a[1]; a[4] := not a[2];
  for i := 0 to n - 1 do a[5 + i] := i mod 7;
  st := CheckStream(a, dfRaw, 'crafted: stored', kind);
  if st <> dsNotTaken then Fail('crafted stored stream: not reported as not taken');
  { not deflate: block type 3; and nothing at all }
  a := nil; SetLength(a, 4); a[0] := 7;
  if CheckStream(a, dfRaw, 'crafted: block type 3', kind) <> dsNotDeflate then Fail('block type 3: not reported as not deflate');
  if CheckStream(nil, dfAuto, 'crafted: empty', kind) <> dsNotDeflate then Fail('empty: not reported as not deflate');
  a := nil; SetLength(a, 2); a[0] := $78; a[1] := $9C;
  if CheckStream(a, dfZlib, 'crafted: header only', kind) <> dsNotDeflate then Fail('header only: not reported as not deflate');

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
    st := CheckStream(a, dfAuto, 'crafted: fixed codes ' + IntToStr(k), kind);
    if st = dsNotTaken then Inc(fixedNotTaken)
    else if st = dsNotDeflate then Fail('fixed codes: not deflate');
    { the same stream with bytes after it, and with a wrong Adler-32: kind 0,
      the framing kept }
    a := Copy(samples[k], 0, Length(samples[k]));
    SetLength(a, Length(a) + 3); a[High(a)] := 1; a[High(a) - 1] := 2; a[High(a) - 2] := 3;
    if (CheckStream(a, dfAuto, 'crafted: tail ' + IntToStr(k), kind) <> dsOk) or (kind <> RECIPE_ZLIB) then
      Fail('a stream with a tail: not kind 0');
    if not z.raw and z.adlerOk and (Length(z.tail) = 0) then begin
      a := Copy(samples[k], 0, Length(samples[k]));
      a[High(a)] := a[High(a)] xor 1;
      if (CheckStream(a, dfAuto, 'crafted: bad adler ' + IntToStr(k), kind) <> dsOk) or (kind <> RECIPE_ZLIB) then
        Fail('a stream with a bad Adler-32: not kind 0');
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
    r2 := r; r2.kind := 2;
    if Rebuild(plain, r2, back) or (back <> nil) then Fail('a recipe of an unknown kind rebuilt');
    r2 := r; r2.prm.level := 0;
    if Rebuild(plain, r2, back) then Fail('a recipe of level 0 rebuilt');
    { the same in RecipeBytes' format: each cut refused }
    rb := RecipeBytes(r);
    for n := 0 to Length(rb) - 1 do begin
      pos := 0;
      if ReadRecipe(Copy(rb, 0, n), pos, Length(plain), 100, r2) = rrOk then Fail('a cut recipe (format 1) was read: ' + IntToStr(n));
    end;
  end;
  CraftedFlows;
  LoopSwitchFlows;
  DamagedFlows;
end;

var
  files: TStringList; sr: TSearchRec; dir, name, ext, only: string; i, minimum, min1, minOk, kind: Integer;
  all0, none0, all01, codec: Boolean;
  d: TBytes; p: TPng; s: SizeInt; st: TDeflStatus; t0: TDateTime; framing: TDeflFraming;
  dirStreams, dirBytes0, dirBytes1, dirKind0, dirKind1, dirNotTaken, dirNotDeflate: Int64;

  procedure Expect(const what: string);
  begin
    if all0 and ((st <> dsOk) or (kind <> RECIPE_ZLIB)) then Fail('not kind 0: ' + what);
    if none0 and (st = dsOk) and (kind = RECIPE_ZLIB) then Fail('kind 0: ' + what);
    if all01 and (st <> dsOk) then Fail('no recipe: ' + what);
  end;

begin
  dir := ParamStr(1); minimum := StrToIntDef(ParamStr(2), 1);
  all0 := False; none0 := False; all01 := False; codec := False; verbose := False; min1 := 0; minOk := 0; only := '';
  for i := 2 to ParamCount do
    if ParamStr(i) = '-all0' then all0 := True
    else if ParamStr(i) = '-none0' then none0 := True
    else if ParamStr(i) = '-all01' then all01 := True
    else if (ParamStr(i) = '-min1') and (i < ParamCount) then min1 := StrToInt(ParamStr(i + 1))
    else if (ParamStr(i) = '-only') and (i < ParamCount) then only := ParamStr(i + 1)
    else if (ParamStr(i) = '-minok') and (i < ParamCount) then minOk := StrToInt(ParamStr(i + 1))
    else if ParamStr(i) = '-codec' then codec := True
    else if ParamStr(i) = '-v' then verbose := True;
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat
      if ((sr.Attr and faDirectory) = 0) and (sr.Name <> 'MANIFEST.tsv') and ((only = '') or (Pos(only, sr.Name) > 0)) then
        files.Add(dir + '/' + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  failures := 0; nStreams := 0; nKind0 := 0; nKind1 := 0; nNotDeflate := 0; nNotTaken := 0;
  bytesKind0 := 0; bytesKind1 := 0;
  recipeHash := QWord($CBF29CE484222325);
  samples := nil;
  t0 := Now;
  for i := 0 to files.Count - 1 do begin
    name := ExtractFileName(files[i]);
    d := ReadFile(files[i]);
    try
      if ppapng.Decompose(d, p).Ok then begin
        for s := 0 to High(p.streams) do
          if p.streams[s].kind in [skIdat, skFdat] then begin
            st := CheckStream(p.streams[s].data, dfAuto, name + ' #' + IntToStr(s), kind);
            Expect(name + ' #' + IntToStr(s));
            if (st = dsOk) and (kind = RECIPE_ZLIB) and (Length(samples) < 8) and (Length(p.streams[s].data) < 1 shl 20) then begin
              SetLength(samples, Length(samples) + 1);
              samples[High(samples)] := p.streams[s].data;
            end;
          end;
        if codec then CheckCodec(d, name);
      end else begin
        ext := LowerCase(ExtractFileExt(name));
        if ext = '.raw' then framing := dfRaw else framing := dfAuto;
        st := CheckStream(d, framing, name, kind);
        Expect(name);
      end;
    except
      on e: Exception do Fail(e.ClassName + ': ' + e.Message + '  ' + name);
    end;
  end;
  { the directory's own counts; then the crafted cases' }
  dirStreams := nStreams; dirBytes0 := bytesKind0; dirBytes1 := bytesKind1; dirKind0 := nKind0; dirKind1 := nKind1;
  dirNotTaken := nNotTaken; dirNotDeflate := nNotDeflate;
  Writeln(Format('recipes %.16x', [recipeHash]));
  try
    Crafted;
  except
    on e: Exception do Fail('crafted cases: ' + e.ClassName + ': ' + e.Message);
  end;
  if dirStreams < minimum then Fail(Format('%d streams < minimum %d', [dirStreams, minimum]));
  if dirKind1 < min1 then Fail(Format('%d kind 1 < minimum %d', [dirKind1, min1]));
  if dirKind0 + dirKind1 < minOk then Fail(Format('%d with a recipe < minimum %d', [dirKind0 + dirKind1, minOk]));
  Writeln(Format('%d streams: %d kind 0 (%d bytes), %d kind 1 (%d bytes) (written, read and rebuilt the same), ' +
    '%d not taken, %d not deflate; crafted: %d kind 0, %d kind 1, %d not taken, %d not deflate; %.1f s; %d failures',
    [dirStreams, dirKind0, dirBytes0, dirKind1, dirBytes1, dirNotTaken, dirNotDeflate,
     nKind0 - dirKind0, nKind1 - dirKind1, nNotTaken - dirNotTaken, nNotDeflate - dirNotDeflate,
     SecondSpan(Now, t0), failures]));
  if failures > 0 then Halt(1);
end.
