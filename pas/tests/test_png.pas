{ Layer 1: every file of the PNG family in the directory, decomposed into
  chunks and image streams and recomposed, must give the same file byte for
  byte. Anything after the signature decomposes, so the only accepted
  failure is NotPng (a file that is not of the family). An exception is a
  FAILURE (out of range, overflow): no file, broken or not, may produce one.

    test_png <directory> [minimum round trips] [-v] }
program test_png;
{$I ../ppa.inc}
uses SysUtils, Classes, ppapng;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

const
  KIND_NAME: array[TPngKind] of string = ('PNG', 'MNG', 'JNG');
  STREAM_NAME: array[TStreamKind] of string = ('IDAT', 'fdAT', 'JDAT', 'JDAA');

{ The streams must hold exactly what their chunks carry. }
function Consistent(const p: TPng): Boolean;
var sum: array of SizeInt; i: SizeInt;
begin
  sum := nil; SetLength(sum, Length(p.streams));
  for i := 0 to High(p.chunks) do
    with p.chunks[i] do
      if stream >= 0 then
        if typ = CT_fdAT then Inc(sum[stream], len - 4) else Inc(sum[stream], len);
  Result := True;
  for i := 0 to High(p.streams) do
    if sum[i] <> Length(p.streams[i].data) then Result := False;
end;

function Summary(const p: TPng): string;
var i: SizeInt; n: array[TStreamKind] of Integer; k: TStreamKind;
begin
  for k := Low(k) to High(k) do n[k] := 0;
  for i := 0 to High(p.streams) do Inc(n[p.streams[i].kind]);
  Result := Format('%s %d chunks', [KIND_NAME[p.kind], Length(p.chunks)]);
  for k := Low(k) to High(k) do
    if n[k] > 0 then Result := Result + Format(' %dx%s', [n[k], STREAM_NAME[k]]);
  if Length(p.trailer) > 0 then Result := Result + Format(' +%d trailing', [Length(p.trailer)]);
end;

var
  dir: string; files, reasons: TStringList; sr: TSearchRec;
  i, k, minimum, ok, failures: Integer; verbose: Boolean;
  d: TBytes; p: TPng; r: TPngResult; key: string;
begin
  dir := ParamStr(1); minimum := StrToIntDef(ParamStr(2), 1); verbose := ParamStr(3) = '-v';
  files := TStringList.Create; files.Sorted := True;
  reasons := TStringList.Create; reasons.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  ok := 0; failures := 0;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    try
      r := VerifyRoundTrip(d, p);
      if r.Ok and not Consistent(p) then begin Inc(failures); key := 'INCONSISTENT'; end
      else if r.Ok then begin Inc(ok); key := 'ok'; end
      else begin
        key := r.Text; Delete(key, Pos('@', key), MaxInt);
        if r.err <> peNotPng then Inc(failures);
      end;
      if verbose or (key <> 'ok') and (key <> 'NotPng') then begin
        if r.Ok then Writeln('  ', key:14, '  ', Summary(p), '  ', ExtractFileName(files[i]))
        else Writeln('  ', key:14, '  ', r.Text, '  ', ExtractFileName(files[i]));
      end;
    except
      on e: Exception do begin
        Inc(failures); key := 'EXCEPTION';
        Writeln('  FAIL ', e.ClassName, ': ', e.Message, '  ', ExtractFileName(files[i]));
      end;
    end;
    k := reasons.IndexOf(key);
    if k < 0 then reasons.AddObject(key, TObject(PtrInt(1)))
    else reasons.Objects[k] := TObject(PtrInt(reasons.Objects[k]) + 1);
  end;
  for i := 0 to reasons.Count - 1 do Writeln('  ', reasons[i]:14, ' ', PtrInt(reasons.Objects[i]):6);
  if ok < minimum then begin Inc(failures); Writeln('  FAIL: round trips ', ok, ' < minimum ', minimum); end;
  Writeln(files.Count, ' files, ', ok, ' identical round trips, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.
