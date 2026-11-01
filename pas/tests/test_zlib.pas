{ Layer 2b, its predictor: for every zlib stream of every file of the PNG
  family in the directory, the zlib parameters (level, strategy, memLevel,
  windowBits) that give the same blocks and tokens, if there are any. The
  candidates come from the stream's header: its FLEVEL says which levels,
  its CINFO the smallest window (libpng may write a smaller one than it
  used). A stream that matches is then encoded from the predicted choices
  and must give the same bits.

    test_zlib <directory> [-v] }
program test_zlib;
{$I ../ppa.inc}
uses SysUtils, Classes, ppapng, ppadeflate, ppazlib;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

const MAX_PLAIN = 1 shl 30;
  STRAT_NAME: array[0..4] of string = ('default', 'filtered', 'huffman', 'rle', 'fixed');

function FindParams(const z: TZStream; out prm: TZlibParams): Boolean;
var lvMin, lvMax, wbMin, lv, st, ml, wb: Integer; e: TZStream;
const ML_ORDER: array[0..8] of Integer = (8, 9, 7, 6, 5, 4, 3, 2, 1);
begin
  Result := False;
  case z.header[1] shr 6 of
    0: begin lvMin := 1; lvMax := 1; end;
    1: begin lvMin := 2; lvMax := 5; end;
    2: begin lvMin := 6; lvMax := 6; end;
  else begin lvMin := 7; lvMax := 9; end;
  end;
  wbMin := (z.header[0] shr 4) + 8;
  if z.raw then begin lvMin := 1; lvMax := 9; wbMin := 15; end;
  for wb := 15 downto wbMin do
    for ml := 0 to 8 do
      for st := 0 to 4 do
        for lv := lvMin to lvMax do begin
          { FLEVEL 0 is also every level with huffman or rle }
          if (st in [Z_HUFFMAN_ONLY, Z_RLE]) and (lv <> lvMin) then Continue;
          prm.level := lv; prm.strategy := st; prm.memLevel := ML_ORDER[ml]; prm.wbits := wb;
          if ZlibChoices(z.plain, prm, @z, e) then Exit(True);
        end;
  { huffman and rle write FLEVEL 0 whatever the level }
  if z.header[1] shr 6 <> 0 then Exit;
end;

var
  dir, name: string; files: TStringList; sr: TSearchRec;
  i: Integer; nStreams, matched, failures, notDecoded: Int64; verbose: Boolean;
  d, back: TBytes; p: TPng; z, e: TZStream; prm: TZlibParams; s, k: SizeInt;
  byParams: TStringList; key: string;
begin
  dir := ParamStr(1); verbose := ParamStr(2) = '-v';
  files := TStringList.Create; files.Sorted := True;
  byParams := TStringList.Create; byParams.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  nStreams := 0; matched := 0; failures := 0; notDecoded := 0;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    name := ExtractFileName(files[i]);
    if not ppapng.Decompose(d, p).Ok then Continue;
    for s := 0 to High(p.streams) do begin
      if not (p.streams[s].kind in [skIdat, skFdat]) then Continue;
      Inc(nStreams);
      if not ppadeflate.Decode(p.streams[s].data, not IsZlibHeader(p.streams[s].data), MAX_PLAIN, z).Ok then begin
        Inc(notDecoded); Continue;
      end;
      try
        if FindParams(z, prm) then begin
          Inc(matched);
          key := Format('level %d %s memLevel %d', [prm.level, STRAT_NAME[prm.strategy], prm.memLevel]);
          { the predicted choices, written, must be the stream }
          ZlibChoices(z.plain, prm, nil, e);
          e.raw := z.raw; e.header := z.header; e.adlerOk := z.adlerOk; e.tail := z.tail; e.endPad := z.endPad;
          back := Encode(e);
          if (Length(back) <> Length(p.streams[s].data)) or not CompareMem(@back[0], @p.streams[s].data[0], Length(back)) then begin
            Inc(failures); Writeln('  FAIL predicted choices do not give the same bits, stream ', s, '  ', name);
          end;
          if verbose then Writeln(Format('  %-40s wbits %2d  stream %d  %s', [key, prm.wbits, s, name]));
        end else begin
          key := 'no zlib parameters';
          if verbose then Writeln(Format('  %-40s header %.2x%.2x  stream %d  %s', [key, z.header[0], z.header[1], s, name]));
        end;
      except
        on ex: Exception do begin
          Inc(failures); key := 'EXCEPTION';
          Writeln('  FAIL ', ex.ClassName, ': ', ex.Message, '  stream ', s, '  ', name);
        end;
      end;
      k := byParams.IndexOf(key);
      if k < 0 then byParams.AddObject(key, TObject(PtrInt(1)))
      else byParams.Objects[k] := TObject(PtrInt(byParams.Objects[k]) + 1);
    end;
  end;
  for i := 0 to byParams.Count - 1 do Writeln('  ', byParams[i]:40, ' ', PtrInt(byParams.Objects[i]):6);
  Writeln(nStreams, ' streams, ', matched, ' told by their zlib parameters, ', notDecoded, ' not decoded, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.
