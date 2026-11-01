{ Layer 1 under damage: every bit of the first N bytes of each file flipped,
  one at a time, and the file cut at every length up to N and then at 256
  more points. Each variant must decompose and come back byte for byte, or
  be NotPng (only when the signature was hit). Never an exception, never a
  different rebuild.

    test_png_corrupt <directory> [N] }
program test_png_corrupt;
{$I ../ppa.inc}
uses SysUtils, Classes, ppapng;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  failures, variants: Int64;

procedure Check(const v: TBytes; signatureHit: Boolean; const what, name: string);
var p: TPng; r: TPngResult;
begin
  Inc(variants);
  try
    r := VerifyRoundTrip(v, p);
    if r.Ok then Exit;
    if (r.err = peNotPng) and signatureHit then Exit;
    Inc(failures);
    if failures <= 20 then Writeln('  FAIL ', r.Text, '  ', what, '  ', name);
  except
    on e: Exception do begin
      Inc(failures);
      if failures <= 20 then Writeln('  FAIL ', e.ClassName, ': ', e.Message, '  ', what, '  ', name);
    end;
  end;
end;

var
  dir, name: string; files: TStringList; sr: TSearchRec;
  i, n: Integer; b, bit, cut, step: SizeInt;
  d, v: TBytes;
begin
  dir := ParamStr(1); n := StrToIntDef(ParamStr(2), 256);
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  failures := 0; variants := 0;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    name := ExtractFileName(files[i]);
    for b := 0 to High(d) do begin
      if b >= n then Break;
      for bit := 0 to 7 do begin
        v := Copy(d);
        v[b] := v[b] xor (1 shl bit);
        Check(v, b < 8, Format('bit %d of byte %d', [bit, b]), name);
      end;
    end;
    for cut := 0 to Length(d) - 1 do begin
      if cut > n then Break;
      Check(Copy(d, 0, cut), cut < 8, Format('cut at %d', [cut]), name);
    end;
    step := Length(d) div 256 + 1;
    cut := n + 1;
    while cut < Length(d) do begin
      Check(Copy(d, 0, cut), False, Format('cut at %d', [cut]), name);
      Inc(cut, step);
    end;
  end;
  Writeln(files.Count, ' files, ', variants, ' damaged variants, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.
