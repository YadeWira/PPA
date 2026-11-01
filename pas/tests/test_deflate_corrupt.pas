{ Layer 2a under damage: in every zlib stream of the files in the directory,
  every bit of the first N bytes flipped, one at a time, and the stream cut
  at every length up to N and at 256 more points. A variant may fail to
  decode, with its reason; one that decodes must come back bit for bit.
  Never an exception. Also: the cap on the bytes a stream may hold is kept.

    test_deflate_corrupt <directory> [N] }
program test_deflate_corrupt;
{$I ../ppa.inc}
uses SysUtils, Classes, ppapng, ppadeflate;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

const MAX_PLAIN = 1 shl 26;

var
  failures, variants, decoded: Int64;

procedure Check(const v: TBytes; raw: Boolean; const what, name: string);
var z: TZStream; r: TZResult;
begin
  Inc(variants);
  try
    r := VerifyRoundTrip(v, raw, MAX_PLAIN, z);
    if r.Ok then Inc(decoded);
    if r.err <> zeNoRoundTrip then Exit;
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
  i, n: Integer; s, b, bit, cut, step: SizeInt; raw: Boolean;
  d, a, v: TBytes; p: TPng; z: TZStream; r: TZResult;
begin
  dir := ParamStr(1); n := StrToIntDef(ParamStr(2), 256);
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  failures := 0; variants := 0; decoded := 0;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    if not ppapng.Decompose(d, p).Ok then Continue;
    for s := 0 to High(p.streams) do begin
      if not (p.streams[s].kind in [skIdat, skFdat]) then Continue;
      a := p.streams[s].data;
      raw := not IsZlibHeader(a);
      name := Format('%s stream %d', [ExtractFileName(files[i]), s]);
      for b := 0 to High(a) do begin
        if b >= n then Break;
        for bit := 0 to 7 do begin
          v := Copy(a);
          v[b] := v[b] xor (1 shl bit);
          Check(v, raw, Format('bit %d of byte %d', [bit, b]), name);
        end;
      end;
      for cut := 0 to Length(a) - 1 do begin
        if cut > n then Break;
        Check(Copy(a, 0, cut), raw, Format('cut at %d', [cut]), name);
      end;
      step := Length(a) div 256 + 1;
      cut := n + 1;
      while cut < Length(a) do begin
        Check(Copy(a, 0, cut), raw, Format('cut at %d', [cut]), name);
        Inc(cut, step);
      end;
      { the cap: one byte less than it holds is refused }
      r := Decode(a, raw, MAX_PLAIN, z);
      if r.Ok and (Length(z.plain) > 0) then begin
        r := Decode(a, raw, Length(z.plain) - 1, z);
        if r.err <> zeTooLarge then begin
          Inc(failures); Writeln('  FAIL cap not kept: ', r.Text, '  ', name);
        end;
      end;
    end;
  end;
  Writeln(files.Count, ' files, ', variants, ' damaged streams, ', decoded, ' of them decode, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.
