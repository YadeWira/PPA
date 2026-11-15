{ ppaminiz against miniz itself.

    test_miniz LIST [-find]

  LIST: lines "PLAIN DEFL FLAGS VARIANT" (DEFL: miniz's raw deflate of PLAIN
  with tdefl's FLAGS, decimal; VARIANT 0 or 1, ppaminiz.MZV_*). Each line:
  MinizChoices of PLAIN, written, must be DEFL bit for bit, and with DEFL's
  own choices as the ref it must follow them to the end. -find: and
  FindMinizParams on DEFL must find flags whose choices are DEFL's. The
  last line: "N ok, M failed". }
program test_miniz;

{$I ppa.inc}

uses SysUtils, Classes, ppadeflate, ppaminiz;

function ReadAll(const fn: string): TBytes;
var f: TFileStream;
begin
  f := TFileStream.Create(fn, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, f.Size);
    if f.Size > 0 then f.ReadBuffer(Result[0], f.Size);
  finally
    f.Free;
  end;
end;

function Same(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

var
  list: TStringList; parts: TStringArray;
  i, good, bad: Integer;
  plain, defl, back: TBytes;
  p, q: TMinizParams;
  e, z, c: TZStream;
  find, ok: Boolean;
  why: string;
begin
  if ParamCount < 1 then begin WriteLn('usage: test_miniz LIST [-find]'); Halt(2); end;
  find := (ParamCount >= 2) and (ParamStr(2) = '-find');
  list := TStringList.Create;
  list.LoadFromFile(ParamStr(1));
  good := 0; bad := 0;
  for i := 0 to list.Count - 1 do begin
    parts := list[i].Split([#9]);
    if Length(parts) < 4 then Continue;
    plain := ReadAll(parts[0]);
    defl := ReadAll(parts[1]);
    p.flags := StrToInt(parts[2]);
    p.variant := StrToInt(parts[3]);
    ok := True; why := '';
    if not MinizChoices(plain, p, nil, False, e) then begin ok := False; why := 'no choices'; end
    else begin
      back := Encode(e);
      if not Same(back, defl) then begin ok := False; why := Format('differs (%d vs %d bytes)', [Length(back), Length(defl)]); end;
    end;
    if ok then begin
      if not ppadeflate.Decode(defl, True, High(SizeInt), z).Ok then begin ok := False; why := 'not deflate'; end
      else if not MinizChoices(z.plain, p, @z, False, c) then begin ok := False; why := 'ref not followed'; end;
    end;
    if ok and find then begin
      if not FindMinizParams(z, q, c) then begin ok := False; why := 'not found'; end
      else if not Same(Encode(c), defl) then begin ok := False; why := Format('found %x/%d, not the stream', [q.flags, q.variant]); end;
    end;
    if ok then Inc(good)
    else begin
      Inc(bad);
      WriteLn('FAIL ', parts[1], ' flags ', parts[2], ' v', parts[3], ': ', why);
    end;
  end;
  WriteLn(good, ' ok, ', bad, ' failed');
  if bad > 0 then Halt(1);
end.
