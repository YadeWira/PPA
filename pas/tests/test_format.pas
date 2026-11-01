{ Layer 7, the .ppa file: every sample packed and unpacked; then damaged
  (every bit of the header, the descriptor and the payload's first bytes
  flipped, one byte in 499 of the rest, and every cut up to 64 bytes and
  16 more points):
  Unpack must give an error, or exactly the original (a bit the decoder
  never reads), never another file and never an exception. And the
  descriptor's limits, in the writer and the reader alike.

    test_format <directory> }
program test_format;
{$I ../ppa.inc}
uses SysUtils, Classes, ppaformat, ppablake3;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var failures, variants, refused: Int64;

procedure Check(ok: Boolean; const what: string);
begin
  if not ok then begin Inc(failures); Writeln('  FAIL ', what); end;
end;

procedure Damaged(const v, orig: TBytes; const what: string);
var o: TBytes; d: TDescriptor; e: TFormatError; detail: string;
begin
  Inc(variants);
  try
    e := Unpack(v, 0, o, d, detail);
    if e <> feNone then begin Inc(refused); Exit; end;
    Check((Length(o) = Length(orig)) and ((Length(o) = 0) or CompareMem(@o[0], @orig[0], Length(o))),
      'a damaged .ppa gave another file: ' + what);
  except
    on ex: Exception do Check(False, ex.ClassName + ' on ' + what);
  end;
end;

function Expect(const v: TBytes; want: TFormatError; const what: string): Boolean;
var o: TBytes; d: TDescriptor; e: TFormatError; detail: string;
begin
  e := Unpack(v, 0, o, d, detail);
  Result := e = want;
  Check(Result, Format('%s: %s instead of %s', [what, FormatErrorText(e), FormatErrorText(want)]));
end;

var
  files: TStringList; sr: TSearchRec; dir: string;
  i: Integer; b, bit, cut, step: SizeInt;
  d, p, v, o: TBytes; stored: Boolean; why, detail: string; desc: TDescriptor; e: TFormatError;
  nStored, nCoded: Integer;
begin
  dir := ParamStr(1);
  failures := 0; variants := 0; refused := 0; nStored := 0; nCoded := 0;
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    Check(Pack(d, 'PNG', True, p, stored, why), 'Pack ' + files[i]);
    if stored then Inc(nStored) else Inc(nCoded);
    e := Unpack(p, 0, o, desc, detail);
    Check((e = feNone) and (Length(o) = Length(d)) and CompareMem(@o[0], @d[0], Length(d)) and (desc.ext = 'PNG'),
      'round trip ' + files[i]);
    Check(Unpack(p, Length(d) - 1, o, desc, detail) = feTooLarge, 'the cap ' + files[i]);
    for b := 0 to High(p) do begin
      if (b >= 56) and (b mod 499 <> 0) then Continue;
      for bit := 0 to 7 do begin
        v := Copy(p); v[b] := v[b] xor (1 shl bit);
        Damaged(v, d, Format('bit %d of byte %d of %s', [bit, b, files[i]]));
      end;
    end;
    for cut := 0 to Length(p) - 1 do begin
      if cut > 64 then Break;
      Damaged(Copy(p, 0, cut), d, Format('cut at %d of %s', [cut, files[i]]));
    end;
    step := Length(p) div 16 + 1; cut := 65;
    while cut < Length(p) do begin Damaged(Copy(p, 0, cut), d, Format('cut at %d', [cut])); Inc(cut, step); end;
  end;

  { the header and descriptor cases, on a stored file and a coded one }
  d := ReadFile(files[0]);
  Pack(d, 'png', True, p, stored, why);
  v := Copy(p); v[4] := 2; Expect(v, feFutureVersion, 'version 2');
  v := Copy(p); v[4] := 0; Expect(v, feNotPpa, 'version 0');
  v := Copy(p); v[5] := v[5] or 2; Expect(v, feUnknownFlag, 'flag bit 1');
  v := Copy(p); v[7] := 1; Expect(v, feReservedNotZero, 'reserved byte');
  v := Copy(p); FillChar(v[8], 8, 0); Expect(v, feBadOrigSize, 'size 0');
  v := Copy(p); v[8] := $FF; v[9] := $FF; v[10] := $FF; v[11] := $FF; v[12] := $FF; v[13] := $FF;
  Expect(v, feRatioExceeded, 'size far above the payload');
  v := Copy(p); v[32] := 16; Expect(v, feBadExtension, 'extension of 16');
  v := Copy(p); v[33] := Ord('.'); Expect(v, feBadExtension, 'extension with a dot');
  v := Copy(p); v[5] := v[5] xor 1; e := Unpack(v, 0, o, desc, detail);
  Check(e <> feNone, 'the stored flag flipped');
  Check(not ValidExtension('a.b') and not ValidExtension('a/b') and not ValidExtension('0123456789abcdef')
        and ValidExtension('JPEG_x-1') and ValidExtension(''), 'ValidExtension');
  Pack(d, '../x', True, p, stored, why);
  Check((Inspect(p, desc) = feNone) and (desc.ext = ''), 'an invalid extension is left out');
  v := nil; Check(not Pack(v, 'png', True, p, stored, why), 'an empty file is not packed');

  Writeln(Format('%d files (%d coded, %d stored), %d damaged variants (%d refused), %d failures',
    [files.Count, nCoded, nStored, variants, refused, failures]));
  if failures > 0 then Halt(1);
end.
