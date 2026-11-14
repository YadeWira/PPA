{ ppapreflate, one deflate stream's API: every deflate stream in the
  directory through Analyze, and each recipe written and read back (kind 0
  as codec stream version 2 writes it and in RecipeBytes' format; kind 1
  in RecipeBytes') and rebuilt (on 1 thread and, cut in segments, on 4),
  which must give the stream back bit for bit. A file of the PNG family
  gives its image streams (IDAT, fdAT); any other file is one stream (.raw:
  bare deflate; else zlib if its header says so, bare otherwise).

    test_preflate <directory> [minimum streams] [-all0 | -none0 | -all01 | -all013] [-min1 N] [-min3 N] [-minok N]
                  [-max01] [-only TEXT] [-codec] [-diffc] [-flips] [-tsv FILE] [-v]

  -all0: every stream must have a kind-0 recipe (zlib's parameters: the
  regression set); -none0: none may (streams zlib does not write alone:
  each must be reported as kind 1, not taken or not deflate, cleanly);
  -all01: every stream must have a kind-0 or kind-1 recipe (zlib with its
  flushes and parameter changes); -all013: every deflate stream must have
  a recipe (kind 3, a zlib-like predictor and corrections, takes any);
  -min1 N, -min3 N: at least N of kind 1, of kind 3; -minok N: at least N
  with a recipe; -max01: recipes of kinds 0 and 1 only (as before kind 3);
  -only TEXT: only the files whose name holds TEXT. -diffc: each kind-3
  recipe also made and rebuilt with the other code (C or Pascal: ppacorr's
  hot loops), which must give the same. -tsv FILE: a line per stream
  (file, stream, bytes, plain, kind, recipe bytes, analyse and rebuild
  milliseconds). -flips: the kind-3 crafted cases too (below). -codec:
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
  recipes and flows: refused, never raised on. With -flips: every field of a
  stream's blocks changed in turn (ppadeflate.TDeflateBlock: the last
  block, types, stored lengths and pad bits, HLIT, HDIST, HCLEN, the
  code-length code, the run-length coding, code lengths, 258 as 284, empty
  blocks, tokens): each must still have a recipe (kind 3) that gives it
  back; and damaged kind-3 recipes: refused or rebuilt, never raised on. }
program test_preflate;
{$I ../ppa.inc}
uses {$ifdef UNIX} cthreads, {$endif} SysUtils, Classes, DateUtils, ppapng, ppadeflate, ppazlib, ppapreflate,
  ppacodec, ppacorr;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

const MAX_PLAIN = 1 shl 30;
  CLEN_ORDER_T: array[0..18] of Byte = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);

var
  failures, nStreams, nKind0, nKind1, nNotDeflate, nNotTaken, bytesKind0, bytesKind1: Int64;
  nKind3, bytesKind3, recipeKind3: Int64;
  verbose, diffc, tsvOn, flips: Boolean;
  maxKindArg: Integer = RECIPE_KIND_LAST;
  tsv: TextFile;
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

function SamePred(const a, b: TPredParams): Boolean;
begin
  Result := (a.predVersion = b.predVersion) and (a.chain = b.chain) and (a.nice = b.nice) and (a.lazy = b.lazy) and
    (a.good = b.good) and (a.hbits = b.hbits) and (a.maxDist = b.maxDist) and (a.flags = b.flags) and
    (a.symEnd = b.symEnd) and (a.tree = b.tree);
end;

function SameRecipe(const a, b: TDeflRecipe): Boolean;
var k: SizeInt;
begin
  Result := (a.kind = b.kind) and (a.prm.level = b.prm.level) and (a.prm.strategy = b.prm.strategy) and
    (a.prm.memLevel = b.prm.memLevel) and (a.prm.wbits = b.prm.wbits) and (a.raw = b.raw) and
    (a.adlerOk = b.adlerOk) and (a.header[0] = b.header[0]) and (a.header[1] = b.header[1]) and
    (a.endPad = b.endPad) and Same(a.tail, b.tail) and (a.flow.variant = b.flow.variant) and
    (Length(a.flow.events) = Length(b.flow.events)) and SamePred(a.pred, b.pred) and Same(a.corr, b.corr);
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
procedure TsvLine(const name: string; a, plain: SizeInt; kind: Integer; recipe: SizeInt; msA, msR: Int64);
begin
  if tsvOn then Writeln(tsv, Format('%s'#9'%d'#9'%d'#9'%d'#9'%d'#9'%d'#9'%d', [name, a, plain, kind, recipe, msA, msR]));
end;

{ a kind-3 recipe made again, and rebuilt, with the other code (ppacorr's
  hot loops in C or in Pascal): the same parameters, corrections, stream }
procedure CheckOtherCode(const a: TBytes; framing: TDeflFraming; const r: TDeflRecipe; const name: string);
var z: TZStream; was: Boolean; p2: TPredParams; c2, back: TBytes; r2: TDeflRecipe;
begin
  if not Parse(a, framing, MAX_PLAIN, z).Ok then begin Fail('diffc: does not parse: ' + name); Exit; end;
  was := UseCorrC;
  try
    UseCorrC := not was;
    CorrChooseParams(z, p2);
    if not SamePred(p2, r.pred) then begin Fail('C and Pascal choose other kind-3 parameters: ' + name); Exit; end;
    c2 := CorrEncode(z, p2);
    if not Same(c2, r.corr) then begin Fail('C and Pascal make other kind-3 corrections: ' + name); Exit; end;
    r2 := r;
    if not Rebuild(z.plain, r2, back) or not Same(back, a) then Fail('kind 3 rebuilt by the other code differs: ' + name);
  finally
    UseCorrC := was;
  end;
end;

function CheckStream(const a: TBytes; framing: TDeflFraming; const name: string; out kind: Integer): TDeflStatus;
var plain, rb, back: TBytes; r, r2: TDeflRecipe; pos: SizeInt; saveMin, saveSeg: SizeInt; t0: TDateTime;
  msA, msR: Int64;
begin
  Inc(nStreams);
  kind := -1;
  t0 := Now;
  Result := Analyze(a, framing, MAX_PLAIN, plain, r, maxKindArg);
  msA := MilliSecondsBetween(Now, t0);
  case Result of
    dsNotDeflate: begin Inc(nNotDeflate); if verbose then Writeln('  not deflate  ', name); TsvLine(name, Length(a), 0, -2, 0, msA, 0); Exit; end;
    dsNotTaken: begin Inc(nNotTaken); if verbose then Writeln('  not taken    ', name); TsvLine(name, Length(a), Length(plain), -1, 0, msA, 0); Exit; end;
  end;
  kind := r.kind;
  if r.kind = RECIPE_ZLIB then begin Inc(nKind0); Inc(bytesKind0, Length(a)); end
  else if r.kind = RECIPE_ZLIB_FLOW then begin Inc(nKind1); Inc(bytesKind1, Length(a)); end
  else begin Inc(nKind3); Inc(bytesKind3, Length(a)); end;
  if verbose then begin
    if r.kind = RECIPE_CORR then
      Write(Format('  kind 3: chain %d nice %d lazy %d good %d hbits %d maxDist %d flags %d symEnd %d%s  %d bytes, corrections %d',
        [r.pred.chain, r.pred.nice, r.pred.lazy, r.pred.good, r.pred.hbits, r.pred.maxDist, r.pred.flags, r.pred.symEnd,
         BoolToStr(r.raw, ' raw', ''), Length(a), Length(r.corr)]))
    else
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
  t0 := Now;
  if not Rebuild(plain, r2, back, 1) or not Same(back, a) then begin Fail('rebuild differs: ' + name); Exit; end;
  msR := MilliSecondsBetween(Now, t0);
  if r.kind = RECIPE_CORR then Inc(recipeKind3, Length(rb));
  TsvLine(name, Length(a), Length(plain), r.kind, Length(rb), msA, msR);
  if diffc and (r.kind = RECIPE_CORR) then CheckOtherCode(a, framing, r, name);
  if r.kind = RECIPE_CORR then Exit;   { (one thread: segments are kind 0's) }
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

{ zlib built with TOO_FAR = 32767 (pngcrush's): on each sample's bytes,
  the stream deflate_slow makes when it keeps a match of 3 however far (no
  flush), where that is not zlib's own, must come back as kind 1 with
  ZV_NO_TOO_FAR (kind 0 cannot say it) }
procedure TooFarFlows;
var a, back, plain: TBytes; i, j, k: SizeInt; kind: Integer; prm: TZlibParams; f: TZlibFlow; z, e, e2: TZStream;
  good: SizeInt; r: TDeflRecipe; st: TDeflStatus; sameToks: Boolean; made: Integer;
begin
  made := 0;
  for k := 0 to High(samples) do begin
    if not Parse(samples[k], dfAuto, MAX_PLAIN, z).Ok then Continue;
    plain := Copy(z.plain, 0, 1 shl 16);
    for j := 0 to 1 do begin
      prm.level := 6 + 3 * j; prm.strategy := Z_DEFAULT_STRATEGY; prm.memLevel := 8 + j; prm.wbits := 15;
      f := Default(TZlibFlow); f.variant := ZV_NEW or ZV_NO_TOO_FAR;
      ZlibChoicesFlow(plain, prm, f, nil, e, good);
      f.variant := ZV_NEW;
      ZlibChoicesFlow(plain, prm, f, nil, e2, good);
      sameToks := Length(e.tokLen) = Length(e2.tokLen);
      if sameToks then for i := 0 to High(e.tokLen) do if e.tokLen[i] <> e2.tokLen[i] then sameToks := False;
      if sameToks then Continue;
      e.raw := z.raw; e.header := z.header; e.adlerOk := z.adlerOk and not z.raw; e.endPad := 0; e.tail := nil;
      a := Encode(e);
      st := CheckStream(a, dfAuto, Format('crafted: TOO_FAR 32767, level %d, sample %d', [prm.level, k]), kind);
      if (st <> dsOk) or (kind <> RECIPE_ZLIB_FLOW) then
        Fail(Format('crafted TOO_FAR, level %d, sample %d: not kind 1 (kind %d)', [prm.level, k, kind]))
      else begin
        st := Analyze(a, dfAuto, MAX_PLAIN, back, r, RECIPE_ZLIB_FLOW);
        if (st <> dsOk) or (r.flow.variant and ZV_NO_TOO_FAR = 0) then Fail('crafted TOO_FAR: not ZV_NO_TOO_FAR');
      end;
      Inc(made);
    end;
    if made >= 4 then Break;
  end;
  { (samples with no match of 3 past 4096 make none: not a failure) }
  if verbose and (made = 0) then Writeln('  no crafted TOO_FAR stream: the samples have no match of 3 past 4096');
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
  { the writer says so, never writes it (a caller's bug) }
  try RecipeBytes(r2); Fail('RecipeBytes wrote a flow out of order'); except on e: Exception do ; end;
  r2.flow.events[0].pos := n div 3; r2.flow.variant := ZV_LAST + 1;
  try RecipeBytes(r2); Fail('RecipeBytes wrote an unknown variant'); except on e: Exception do ; end;
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
  r2 := r; r2.flow.variant := 8;
  if Rebuild(plain, r2, back) then Fail('an unknown variant flag rebuilt');
  r2 := r; r2.flow.variant := ZV_LAST or ZV_NO_TOO_FAR;
  if not Rebuild(plain, r2, back) then Fail('zlib built with TOO_FAR 32767 not rebuilt');
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

{ ---------------------------------------------------------------- kind 3 }

{ a kind-3 recipe damaged: every cut refused; every value of each byte
  (all of them for the first 24, a few for the rest) read and rebuilt, or
  refused, never raised on; corrections of random bytes on 64 KB of
  bytes, with each predictor: rebuilt or refused, never raised on }
procedure DamagedCorr(const a: TBytes);
var plain, rb, x, back, big: TBytes; r, r2: TDeflRecipe; i, v, k, nOk: Integer; pos: SizeInt; rr: TRecipeRead;
  z: TZStream; seed: LongWord;
begin
  if Analyze(a, dfRaw, MAX_PLAIN, plain, r) <> dsOk then begin Fail('damaged kind 3: no recipe'); Exit; end;
  if r.kind <> RECIPE_CORR then begin Fail('damaged kind 3: not kind 3'); Exit; end;
  rb := RecipeBytes(r);
  for i := 0 to Length(rb) - 1 do begin
    pos := 0;
    if ReadRecipe(Copy(rb, 0, i), pos, Length(plain), 100, r2) = rrOk then
      Fail(Format('a cut kind-3 recipe was read: %d of %d, corrections %d', [i, Length(rb), Length(r.corr)]));
  end;
  nOk := 0;
  for i := 0 to Length(rb) - 1 do
    for v := 0 to 255 do begin
      if (i >= 24) and (v mod 37 <> 0) then Continue;
      x := Copy(rb, 0, Length(rb));
      x[i] := v;
      pos := 0;
      try
        rr := ReadRecipe(x, pos, Length(plain), 100, r2);
        if (rr = rrOk) and not RecipeValid(r2) then Fail('a kind-3 recipe read out of range');
        if (rr = rrOk) and Rebuild(plain, r2, back) then Inc(nOk);
      except
        on e: Exception do Fail('damaged kind-3 recipe raised ' + e.ClassName + ' at ' + IntToStr(i));
      end;
    end;
  if nOk = 0 then Fail('no damaged kind-3 recipe was rebuilt');
  { random corrections: on the first sample's bytes, or the stored stream's }
  big := plain;
  if (Length(samples) > 0) and Parse(samples[0], dfAuto, MAX_PLAIN, z).Ok then big := Copy(z.plain, 0, 1 shl 16);
  seed := 12345;
  for k := 0 to 199 do begin
    r2 := r;
    r2.corr := nil; SetLength(r2.corr, 1 + k mod 64);
    for i := 0 to High(r2.corr) do begin
      {$push}{$Q-}{$R-}
      seed := seed * 1103515245 + 12345;
      {$pop}
      r2.corr[i] := Byte(seed shr 16);
    end;
    r2.pred.lazy := (k mod 3) * 32;
    r2.pred.chain := 1 + (k * 37) mod PRED_MAX_CHAIN;
    r2.pred.symEnd := (k mod 5) * 100;
    r2.pred.hbits := 8 + k mod 9;
    r2.pred.tree := k mod (PRED_TREE_LAST + 1);
    r2.pred.flags := k mod (PF_ALL + 1);
    try
      Rebuild(big, r2, back);
    except
      on e: Exception do Fail('kind-3 random corrections raised ' + e.ClassName);
    end;
  end;
end;

{ a distance past the rank walk's 4096 candidates: 4200 positions with the
  same 3 bytes, then a match (5 bytes) of the oldest; kind 3 must give it
  back, through the escape (its bits are counted) }
procedure RankEscape;
var e: TZStream; a, plain: TBytes; k, q, nT: SizeInt; kind: Integer; prm: TPredParams; corr: TBytes;
begin
  e := Default(TZStream);
  e.raw := True;
  plain := nil; SetLength(plain, 4200 * 5 + 5);
  q := 0;
  for k := 0 to 4200 do begin
    plain[q] := Ord('a'); plain[q + 1] := Ord('b'); plain[q + 2] := Ord('c');
    if k < 4200 then begin plain[q + 3] := k and 255; plain[q + 4] := k shr 8; end
    else begin plain[q + 3] := 0; plain[q + 4] := 0; end;
    Inc(q, 5);
  end;
  e.plain := plain;
  nT := 4200 * 5 + 1;
  SetLength(e.tokLen, nT); SetLength(e.tokVal, nT);
  for k := 0 to 4200 * 5 - 1 do begin e.tokLen[k] := 0; e.tokVal[k] := plain[k]; end;
  e.tokLen[nT - 1] := 5; e.tokVal[nT - 1] := 4200 * 5;
  SetLength(e.blocks, 1);
  e.blocks[0] := Default(TDeflateBlock);
  e.blocks[0].btype := btFixed; e.blocks[0].final := True; e.blocks[0].nTokens := nT;
  a := Encode(e);
  if (CheckStream(a, dfRaw, 'crafted: rank escape', kind) <> dsOk) or (kind <> RECIPE_CORR) then begin
    Fail('rank escape: no kind-3 recipe'); Exit;
  end;
  CorrChooseParams(e, prm);
  FillChar(CorrStat, SizeOf(CorrStat), 0);
  CorrStatOn := True;
  try corr := CorrEncode(e, prm); finally CorrStatOn := False; end;
  if CorrStat[6] < 15 then Fail(Format('rank escape: the distance cost %.1f bits, not escaped', [CorrStat[6]]));
end;

{ a match of 258 at distance 32768 (and as 284) past the rank walk's 4096
  candidates (8000 positions between with its first 3 bytes): the escape
  must be able to say 32768 }
procedure FarEscape;
var e: TZStream; a, plain: TBytes; k, q, nT: SizeInt; kind, v: Integer; seed: LongWord;
begin
  for v := 0 to 1 do begin
    e := Default(TZStream);
    e.raw := True;
    plain := nil; SetLength(plain, 32768 + 258);
    seed := 99;
    for k := 0 to 257 do begin
      {$push}{$Q-}{$R-} seed := seed * 1103515245 + 12345; {$pop}
      plain[k] := Byte(seed shr 16);
    end;
    q := 258;
    while q < 32768 do begin
      {$push}{$Q-}{$R-} seed := seed * 1103515245 + 12345; {$pop}
      plain[q] := plain[q mod 4];
      if q mod 4 = 3 then plain[q] := Byte(seed shr 16);
      Inc(q);
    end;
    for k := 0 to 257 do plain[32768 + k] := plain[k];
    e.plain := plain;
    nT := 32768 + 1;
    SetLength(e.tokLen, nT); SetLength(e.tokVal, nT);
    for k := 0 to 32767 do begin e.tokLen[k] := 0; e.tokVal[k] := plain[k]; end;
    if v = 0 then e.tokLen[nT - 1] := 258 else e.tokLen[nT - 1] := LEN_258_AS_284;
    e.tokVal[nT - 1] := 32768;
    SetLength(e.blocks, 1);
    e.blocks[0] := Default(TDeflateBlock);
    e.blocks[0].btype := btFixed; e.blocks[0].final := True; e.blocks[0].nTokens := nT;
    a := Encode(e);
    if (CheckStream(a, dfRaw, 'crafted: escape of 32768', kind) <> dsOk) or (kind <> RECIPE_CORR) then
      Fail(Format('escape of 32768 (%d): no kind-3 recipe', [v]));
  end;
end;

function LenSymOf(l: Integer): Integer;
const BASE: array[257..285] of Word = (3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258);
begin
  if l = LEN_258_AS_284 then Exit(284);
  if l = 258 then Exit(285);
  Result := 284;
  while BASE[Result] > l do Dec(Result);
end;

function DistSymOf(d: Integer): Integer;
const BASE: array[0..29] of Word = (1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577);
begin
  Result := 29;
  while BASE[Result] > d do Dec(Result);
end;

{ block b of e made dynamic with zlib's trees over its tokens }
procedure MakeDynamic(const e: TZStream; var b: TDeflateBlock);
var lf: array[0..285] of Integer; df: array[0..29] of Integer; t: SizeInt; fixedNoBigger: Boolean;
begin
  FillChar(lf, SizeOf(lf), 0); FillChar(df, SizeOf(df), 0);
  lf[256] := 1;
  for t := b.firstToken to b.firstToken + b.nTokens - 1 do
    if e.tokLen[t] = 0 then Inc(lf[e.tokVal[t]])
    else begin Inc(lf[LenSymOf(e.tokLen[t])]); Inc(df[DistSymOf(e.tokVal[t])]); end;
  ZlibTrees(lf, df, b, fixedNoBigger);
  b.btype := btDynamic;
end;

{ b's code lengths written again: hlit, hdist given; the run-length coding
  zlib's (rle 0), none (1), or zlib's on both trees at once (2); the
  code-length code zlib's, or flat (every symbol used 5 bits) }
procedure RewriteHeader(var b: TDeflateBlock; hlit, hdist, rle: Integer; flat: Boolean; hclen19: Boolean);
var lens: array[0..315] of Byte; dl: array[0..29] of Byte; seq, s2: array[0..316] of Word; n, n2, i, hc: Integer;
  f: array[0..18] of Integer; cl: array[0..18] of Byte;
begin
  for i := 0 to hlit - 1 do lens[i] := b.litLen[i];
  for i := 0 to hdist - 1 do begin lens[hlit + i] := b.distLen[i]; dl[i] := b.distLen[i]; end;
  n := 0;
  case rle of
    0: begin
      ZlibSendTree(lens, hlit, seq, n);
      n2 := 0; ZlibSendTree(dl, hdist, s2, n2);
      for i := 0 to n2 - 1 do seq[n + i] := s2[i];
      Inc(n, n2);
    end;
    1: for i := 0 to hlit + hdist - 1 do begin seq[n] := lens[i]; Inc(n); end;
  else ZlibSendTree(lens, hlit + hdist, seq, n);
  end;
  FillChar(f, SizeOf(f), 0);
  for i := 0 to n - 1 do Inc(f[seq[i] and $1F]);
  ZlibBlTree(f, cl, hc);
  if flat then begin
    for i := 0 to 18 do if f[i] > 0 then cl[i] := 5 else cl[i] := 0;
    hc := 19;
    while (hc > 4) and (cl[CLEN_ORDER_T[hc - 1]] = 0) do Dec(hc);
  end;
  if hclen19 then hc := 19;
  b.hlit := hlit; b.hdist := hdist; b.hclen := hc;
  for i := 0 to 18 do b.clen[i] := cl[i];
  SetLength(b.clenSeq, n);
  for i := 0 to n - 1 do b.clenSeq[i] := seq[i];
end;

{ Every field of a stream's blocks changed in turn, on a stream zlib makes
  of a sample's first 40 KB with runs and a period of 32768 added: each
  stream, written and decoded back to the same bytes, must have a recipe
  (kind 3 where kinds 0 and 1 cannot) that gives it back. }
procedure FieldFlips;
var
  z, e0, e, d: TZStream; plain, a: TBytes; prm: TZlibParams; i, j, k, kind, made, n3: Integer;
  t, n, q: SizeInt; b: TDeflateBlock; st: TDeflStatus; w: TDeflWriter; res: TZResult;

  procedure Check(const what: string);
  begin
    a := Encode(e);
    res := Decode(a, e.raw, MAX_PLAIN, d);
    if not res.Ok or not Same(d.plain, plain) then begin Fail('field flip ' + what + ': not the same bytes (' + res.Text + ')'); Exit; end;
    st := CheckStream(a, dfRaw, 'flip: ' + what, kind);
    if st <> dsOk then Fail('field flip ' + what + ': no recipe')
    else if kind = RECIPE_CORR then Inc(n3);
    Inc(made);
  end;

  procedure Fresh;
  var k: Integer;
  begin
    e := e0;
    e.blocks := Copy(e0.blocks, 0, Length(e0.blocks));
    for k := 0 to High(e.blocks) do e.blocks[k].clenSeq := Copy(e0.blocks[k].clenSeq, 0, Length(e0.blocks[k].clenSeq));
    e.tokLen := Copy(e0.tokLen, 0, Length(e0.tokLen));
    e.tokVal := Copy(e0.tokVal, 0, Length(e0.tokVal));
  end;

  { e with block i's tokens cut at token t (relative): two blocks, each dynamic }
  procedure SplitAt(i: Integer; t: SizeInt);
  var b1, b2: TDeflateBlock; k: Integer;
  begin
    b1 := e.blocks[i]; b2 := b1;
    b1.nTokens := t; b1.final := False;
    b2.firstToken := b1.firstToken + t; b2.nTokens := e.blocks[i].nTokens - t;
    b1.clenSeq := nil; b2.clenSeq := nil;
    MakeDynamic(e, b1); MakeDynamic(e, b2);
    SetLength(e.blocks, Length(e.blocks) + 1);
    for k := High(e.blocks) downto i + 2 do e.blocks[k] := e.blocks[k - 1];
    e.blocks[i] := b1; e.blocks[i + 1] := b2;
  end;

  procedure Insert(i: Integer; const nb: TDeflateBlock);
  var k: Integer;
  begin
    SetLength(e.blocks, Length(e.blocks) + 1);
    for k := High(e.blocks) downto i + 1 do e.blocks[k] := e.blocks[k - 1];
    e.blocks[i] := nb;
  end;

  { the plain position where block i starts }
  function PlainAt(i: Integer): SizeInt;
  var bb: Integer; tt: SizeInt;
  begin
    Result := 0;
    for bb := 0 to i - 1 do
      if e.blocks[bb].btype = btStored then Inc(Result, e.blocks[bb].storedLen)
      else for tt := e.blocks[bb].firstToken to e.blocks[bb].firstToken + e.blocks[bb].nTokens - 1 do
        if e.tokLen[tt] = 0 then Inc(Result) else if e.tokLen[tt] = LEN_258_AS_284 then Inc(Result, 258) else Inc(Result, e.tokLen[tt]);
  end;

  { the pad bits a stored block written as block i has }
  function PadBits(i: Integer): Integer;
  var bb: Integer;
  begin
    WriterBegin(w, e);
    for bb := 0 to i - 1 do WriterBlock(w, e, e.blocks[bb]);
    Result := WriterStoredPadBits(w);
  end;

  { block i (holding plain from pos q, len bytes) made stored blocks of the
    given sizes, pads all ones }
  procedure MakeStored(i: Integer; q: SizeInt; const sizes: array of SizeInt);
  var fin: Boolean; nb: TDeflateBlock; ss, k: Integer;
  begin
    fin := e.blocks[i].final;
    for k := i to High(e.blocks) - 1 do e.blocks[k] := e.blocks[k + 1];
    SetLength(e.blocks, Length(e.blocks) - 1);
    for ss := 0 to High(sizes) do begin
      nb := Default(TDeflateBlock);
      nb.btype := btStored; nb.plainPos := q; nb.storedLen := sizes[ss];
      nb.final := fin and (ss = High(sizes));
      nb.firstToken := 0;
      Insert(i + ss, nb);
      e.blocks[i + ss].pad := (1 shl PadBits(i + ss)) - 1;
      Inc(q, sizes[ss]);
    end;
  end;

var sz: array of SizeInt; total, far: SizeInt; kk: Integer;
begin
  if Length(samples) = 0 then Exit;
  { the sample with the most bytes }
  plain := nil;
  for i := 0 to High(samples) do
    if Parse(samples[i], dfAuto, MAX_PLAIN, z).Ok and (Length(z.plain) > Length(plain)) then plain := z.plain;
  { 36 KB: the sample's first 20 (repeated if it has fewer), 3000 zeros
    (matches of 258), and the first 13 KB again 32768 after they began
    (distance 32768) }
  if Length(plain) = 0 then Exit;
  n := Length(plain);
  SetLength(plain, 20000);
  for q := n to High(plain) do plain[q] := Byte(plain[q - n] + q div n);
  plain := Copy(plain, 0, 20000);
  n := Length(plain);
  SetLength(plain, n + 3000 + 13000);
  FillChar(plain[n], 3000, 0);
  for q := n + 3000 to High(plain) do if q >= 32768 then plain[q] := plain[q - 32768] else plain[q] := Byte(q * 7);
  prm.level := 6; prm.strategy := Z_DEFAULT_STRATEGY; prm.memLevel := 3; prm.wbits := 15;
  ZlibChoices(plain, prm, nil, e0);
  e0.raw := True; e0.adlerOk := False; e0.endPad := 0; e0.tail := nil; e0.header[0] := 0; e0.header[1] := 0;
  made := 0; n3 := 0;
  Fresh; Check('none');
  { the last block: an empty one after it, fixed, stored, dynamic }
  for j := 0 to 2 do begin
    Fresh;
    e.blocks[High(e.blocks)].final := False;
    b := Default(TDeflateBlock); b.final := True; b.firstToken := Length(e.tokLen);
    b.btype := TBlockType(j);
    if b.btype = btStored then b.plainPos := Length(plain);
    if b.btype = btDynamic then MakeDynamic(e, b);
    Insert(Length(e.blocks), b);
    Check('empty last block ' + IntToStr(j));
  end;
  { empty blocks in between, each type }
  for j := 0 to 2 do begin
    Fresh;
    b := Default(TDeflateBlock); b.firstToken := e.blocks[1].firstToken;
    b.btype := TBlockType(j);
    if b.btype = btStored then b.plainPos := PlainAt(1);
    if b.btype = btDynamic then MakeDynamic(e, b);
    Insert(1, b);
    if b.btype = btStored then e.blocks[1].pad := (1 shl PadBits(1)) - 1;
    Check('empty block ' + IntToStr(j));
  end;
  { types: one block fixed; all fixed; a fixed one made dynamic again with
    every header field changed }
  Fresh; e.blocks[0].btype := btFixed; Check('block 0 fixed');
  Fresh; for i := 0 to High(e.blocks) do e.blocks[i].btype := btFixed; Check('all fixed');
  for j := 0 to 7 do begin
    Fresh;
    i := Length(e.blocks) div 2;
    b := e.blocks[i];
    case j of
      0: RewriteHeader(b, 286, b.hdist, 0, False, False);
      1: RewriteHeader(b, b.hlit, 30, 0, False, False);
      2: RewriteHeader(b, b.hlit, b.hdist, 0, False, True);
      3: RewriteHeader(b, b.hlit, b.hdist, 0, True, False);
      4: RewriteHeader(b, b.hlit, b.hdist, 1, False, False);
      5: RewriteHeader(b, b.hlit, b.hdist, 2, False, False);
      6: begin   { the fixed codes' lengths as a dynamic block's }
           for k := 0 to 285 do if k < 144 then b.litLen[k] := 8 else if k < 256 then b.litLen[k] := 9
             else if k < 280 then b.litLen[k] := 7 else b.litLen[k] := 8;
           for k := 0 to 29 do b.distLen[k] := 5;
           RewriteHeader(b, 286, 30, 0, False, False);
         end;
      7: begin   { lengths one longer where there is room: incomplete codes }
           for k := 0 to b.hlit - 1 do if (b.litLen[k] > 0) and (b.litLen[k] < 15) then Inc(b.litLen[k]);
           RewriteHeader(b, b.hlit, b.hdist, 0, False, False);
         end;
    end;
    e.blocks[i] := b;
    Check('header field ' + IntToStr(j));
  end;
  { 258 as 284: in a fixed block (every code there), and in a dynamic one
    made for it }
  for j := 0 to 1 do begin
    Fresh;
    k := 0;
    for i := 0 to High(e.blocks) do
      for t := e.blocks[i].firstToken to e.blocks[i].firstToken + e.blocks[i].nTokens - 1 do
        if e.tokLen[t] = 258 then begin
          e.tokLen[t] := LEN_258_AS_284; Inc(k);
          if j = 0 then e.blocks[i].btype := btFixed else MakeDynamic(e, e.blocks[i]);
        end;
    if k = 0 then Fail('field flip: no match of 258 to write as 284');
    Check('258 as 284 ' + IntToStr(j));
  end;
  { block ends: one block cut in two, at its first token and in its middle }
  Fresh; SplitAt(0, 1); Check('block cut at 1');
  Fresh; SplitAt(Length(e.blocks) div 2, e.blocks[Length(e.blocks) div 2].nTokens div 3); Check('block cut in the middle');
  { stored: a block made stored, in pieces of 1000, 7 and the rest (non-zero
    pads), and the whole stream stored in blocks of at most 65535 }
  Fresh;
  i := 1; q := PlainAt(i);
  total := PlainAt(i + 1) - q;
  if total > 1007 then begin
    SetLength(sz, 3); sz[0] := 1000; sz[1] := 7; sz[2] := total - 1007;
    MakeStored(i, q, sz);
    Check('stored pieces');
  end;
  Fresh;
  e.blocks := nil; e.tokLen := nil; e.tokVal := nil;
  q := 0; sz := nil;
  while q < Length(plain) do begin
    SetLength(sz, Length(sz) + 1);
    sz[High(sz)] := Length(plain) - q; if sz[High(sz)] > 65535 then sz[High(sz)] := 65535;
    Inc(q, sz[High(sz)]);
  end;
  b := Default(TDeflateBlock); b.btype := btFixed; b.final := True;
  Insert(0, b);
  MakeStored(0, 0, sz);
  Check('stored only');
  { tokens: a match cut into a literal and a shorter match; a match moved to
    the farthest distance that holds it (32768 where it can); a run of
    literals where there was a match }
  for j := 0 to 2 do begin
    Fresh;
    i := Length(e.blocks) - 1; k := 0;
    q := PlainAt(i);
    SetLength(e.tokLen, Length(e.tokLen) + 300); SetLength(e.tokVal, Length(e.tokVal) + 300);
    t := e.blocks[i].firstToken;
    while (t < e.blocks[i].firstToken + e.blocks[i].nTokens) and (k < 40) do begin
      if (e.tokLen[t] >= 4) and (e.tokLen[t] <= 258) then begin
        case j of
          0: begin  { literal + match one shorter }
               Move(e.tokLen[t], e.tokLen[t + 1], (Length(e.tokLen) - t - 1) * 2);
               Move(e.tokVal[t], e.tokVal[t + 1], (Length(e.tokVal) - t - 1) * 2);
               e.tokLen[t] := 0; e.tokVal[t] := plain[q];
               Dec(e.tokLen[t + 1]);
               Inc(e.blocks[i].nTokens);
               Inc(q); Inc(t); Inc(k);
             end;
          1: begin  { the farthest distance it can have }
               far := 32768; if far > q then far := q;
               while far > e.tokVal[t] do begin
                 if CompareMem(@plain[q - far], @plain[q], e.tokLen[t]) then Break;
                 Dec(far);
               end;
               if far <> e.tokVal[t] then begin e.tokVal[t] := far; Inc(k); end;
             end;
          2: if e.tokLen[t] <= 8 then begin  { literals }
               n := e.tokLen[t];
               Move(e.tokLen[t + 1], e.tokLen[t + n], (Length(e.tokLen) - t - n) * 2);
               Move(e.tokVal[t + 1], e.tokVal[t + n], (Length(e.tokVal) - t - n) * 2);
               for kk := 0 to n - 1 do begin e.tokLen[t + kk] := 0; e.tokVal[t + kk] := plain[q + kk]; end;
               Inc(e.blocks[i].nTokens, n - 1);
               Inc(t, n - 1); Inc(q, n - 1); Inc(k);
             end;
        end;
      end;
      if e.tokLen[t] = 0 then Inc(q) else Inc(q, e.tokLen[t]);
      Inc(t);
    end;
    SetLength(e.tokLen, e.blocks[i].firstToken + e.blocks[i].nTokens);
    SetLength(e.tokVal, Length(e.tokLen));
    MakeDynamic(e, e.blocks[i]);
    Check('tokens ' + IntToStr(j));
  end;
  { framing: bytes after it, a pad after the last block }
  Fresh; e.tail := TBytes.Create(1, 2, 3); e.endPad := 0;
  WriterBegin(w, e); for i := 0 to High(e.blocks) do WriterBlock(w, e, e.blocks[i]);
  e.endPad := (1 shl WriterEndPadBits(w)) - 1;
  Check('end pad and tail');
  if made < 24 then Fail(Format('field flips: only %d made', [made]));
  if n3 = 0 then Fail('field flips: none kind 3');
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
  if (maxKindArg >= RECIPE_CORR) and ((st <> dsOk) or (kind <> RECIPE_CORR)) then Fail('crafted stored stream: not kind 3');
  { without kind 3: not taken }
  if Analyze(a, dfRaw, MAX_PLAIN, plain, r, RECIPE_ZLIB_FLOW) <> dsNotTaken then
    Fail('crafted stored stream: not reported as not taken by kinds 0 and 1');
  if flips and (maxKindArg >= RECIPE_CORR) then DamagedCorr(a);
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
    { zlib's choices but with fixed codes: kinds 0 and 1 cannot, kind 3 can }
    if (st = dsNotTaken) or ((st = dsOk) and (kind = RECIPE_CORR)) then Inc(fixedNotTaken)
    else if st = dsNotDeflate then Fail('fixed codes: not deflate');
    if (maxKindArg >= RECIPE_CORR) and (st <> dsOk) then Fail('fixed codes: no recipe');
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
  if (Length(samples) > 0) and (fixedNotTaken = 0) then Fail('no fixed-code stream was refused by kinds 0 and 1');

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
  if maxKindArg >= RECIPE_ZLIB_FLOW then TooFarFlows;
  LoopSwitchFlows;
  DamagedFlows;
  if flips and (maxKindArg >= RECIPE_CORR) then begin FieldFlips; RankEscape; FarEscape; end;
end;

var
  files: TStringList; sr: TSearchRec; dir, name, ext, only: string; i, minimum, min1, minOk, kind: Integer;
  all0, none0, all01, all013, codec: Boolean; min3: Integer; tsvName: string;
  d: TBytes; p: TPng; s: SizeInt; st: TDeflStatus; t0: TDateTime; framing: TDeflFraming;
  dirStreams, dirBytes0, dirBytes1, dirKind0, dirKind1, dirNotTaken, dirNotDeflate: Int64;
  dirKind3, dirBytes3, dirRecipe3: Int64;

  procedure Expect(const what: string);
  begin
    if all0 and ((st <> dsOk) or (kind <> RECIPE_ZLIB)) then Fail('not kind 0: ' + what);
    if none0 and (st = dsOk) and (kind = RECIPE_ZLIB) then Fail('kind 0: ' + what);
    if all01 and (st <> dsOk) then Fail('no recipe: ' + what);
    if all013 and (st = dsNotTaken) then Fail('no recipe (kind 3 takes every deflate stream): ' + what);
  end;

begin
  dir := ParamStr(1); minimum := StrToIntDef(ParamStr(2), 1);
  all0 := False; none0 := False; all01 := False; all013 := False; codec := False; verbose := False; min1 := 0; minOk := 0;
  only := ''; min3 := 0; tsvName := ''; diffc := False; flips := False;
  for i := 2 to ParamCount do
    if ParamStr(i) = '-all0' then all0 := True
    else if ParamStr(i) = '-none0' then none0 := True
    else if ParamStr(i) = '-all01' then all01 := True
    else if ParamStr(i) = '-all013' then all013 := True
    else if ParamStr(i) = '-max01' then maxKindArg := RECIPE_ZLIB_FLOW
    else if ParamStr(i) = '-diffc' then diffc := True
    else if ParamStr(i) = '-flips' then flips := True
    else if (ParamStr(i) = '-min3') and (i < ParamCount) then min3 := StrToInt(ParamStr(i + 1))
    else if (ParamStr(i) = '-tsv') and (i < ParamCount) then tsvName := ParamStr(i + 1)
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
  bytesKind0 := 0; bytesKind1 := 0; nKind3 := 0; bytesKind3 := 0; recipeKind3 := 0;
  tsvOn := tsvName <> '';
  if tsvOn then begin AssignFile(tsv, tsvName); Rewrite(tsv); end;
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
  dirNotTaken := nNotTaken; dirNotDeflate := nNotDeflate; dirKind3 := nKind3; dirBytes3 := bytesKind3; dirRecipe3 := recipeKind3;
  if tsvOn then CloseFile(tsv);
  tsvOn := False;
  Writeln(Format('recipes %.16x', [recipeHash]));
  try
    Crafted;
  except
    on e: Exception do Fail('crafted cases: ' + e.ClassName + ': ' + e.Message);
  end;
  if dirStreams < minimum then Fail(Format('%d streams < minimum %d', [dirStreams, minimum]));
  if dirKind1 < min1 then Fail(Format('%d kind 1 < minimum %d', [dirKind1, min1]));
  if dirKind3 < min3 then Fail(Format('%d kind 3 < minimum %d', [dirKind3, min3]));
  if dirKind0 + dirKind1 + dirKind3 < minOk then Fail(Format('%d with a recipe < minimum %d', [dirKind0 + dirKind1 + dirKind3, minOk]));
  Writeln(Format('%d streams: %d kind 0 (%d bytes), %d kind 1 (%d bytes), %d kind 3 (%d bytes, recipes %d bytes) ' +
    '(written, read and rebuilt the same), %d not taken, %d not deflate; crafted: %d kind 0, %d kind 1, %d kind 3, ' +
    '%d not taken, %d not deflate; %.1f s; %d failures',
    [dirStreams, dirKind0, dirBytes0, dirKind1, dirBytes1, dirKind3, dirBytes3, dirRecipe3, dirNotTaken, dirNotDeflate,
     nKind0 - dirKind0, nKind1 - dirKind1, nKind3 - dirKind3, nNotTaken - dirNotTaken, nNotDeflate - dirNotDeflate,
     SecondSpan(Now, t0), failures]));
  if failures > 0 then Halt(1);
end.
