{ Layer 3: every image stream of every file of the PNG family in the
  directory, inflated (layer 2a), unfiltered and filtered again, must give
  the same bytes. An image that does not fit (a filter above 4, too few
  bytes) is reported with its reason; one that is taken and does not come
  back is a FAILURE, as is an exception.

    test_pixels <directory> [minimum taken] [-v | -dump DIR]

  -dump writes, for each taken non-interlaced 8-bit image (gray, RGB,
  RGBA), its unfiltered bytes to DIR/N.raw with a line "N file ctype" on
  stdout, for tests/pxcheck.py to compare against ImageMagick. }
program test_pixels;
{$I ../ppa.inc}
uses SysUtils, Classes, ppapng, ppadeflate, ppapixels;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  dir, name, key, dumpDir: string; files, reasons: TStringList; sr: TSearchRec;
  i, k, minimum: Integer; taken, failures, nDump: Int64; verbose, dump: Boolean;
  d, back: TBytes; p: TPng; z: TZStream; info: TImageInfo; px: TPixels; s: SizeInt;
  fs: TFileStream; tails, adam7: Int64;
begin
  dir := ParamStr(1); minimum := StrToIntDef(ParamStr(2), 1);
  verbose := ParamStr(3) = '-v'; dump := ParamStr(3) = '-dump'; dumpDir := ParamStr(4);
  files := TStringList.Create; files.Sorted := True;
  reasons := TStringList.Create; reasons.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  taken := 0; failures := 0; nDump := 0; tails := 0; adam7 := 0;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    name := ExtractFileName(files[i]);
    if not ppapng.Decompose(d, p).Ok then Continue;
    for s := 0 to High(p.streams) do begin
      if not (p.streams[s].kind in [skIdat, skFdat]) then Continue;
      try
        if not ppadeflate.Decode(p.streams[s].data, not IsZlibHeader(p.streams[s].data), MAX_IMAGE_BYTES, z).Ok then
          key := 'not inflated'
        else if not StreamImage(p, s, info) then key := 'no header'
        else if not Unfilter(z.plain, info, px) then key := 'does not fit'
        else begin
          back := Refilter(px);
          if (Length(back) <> Length(z.plain)) or ((Length(back) > 0) and not CompareMem(@back[0], @z.plain[0], Length(back))) then begin
            Inc(failures); key := 'NOT BACK';
            Writeln('  FAIL refiltered bytes differ, stream ', s, '  ', name);
          end else begin
            Inc(taken); key := 'taken';
            if Length(px.tail) > 0 then Inc(tails);
            if info.interlace = 1 then Inc(adam7);
            if dump and (info.interlace = 0) and (info.depth = 8) and (info.colorType in [0, 2, 6]) and (s = 0) then begin
              fs := TFileStream.Create(Format('%s/%d.raw', [dumpDir, nDump]), fmCreate);
              try if Length(px.data) > 0 then fs.WriteBuffer(px.data[0], Length(px.data)); finally fs.Free; end;
              Writeln(nDump, ' ', files[i], ' ', info.colorType);
              Inc(nDump);
            end;
          end;
        end;
        if verbose and (key <> 'taken') then Writeln('  ', key:14, '  stream ', s, '  ', name);
      except
        on e: Exception do begin
          Inc(failures); key := 'EXCEPTION';
          Writeln('  FAIL ', e.ClassName, ': ', e.Message, '  stream ', s, '  ', name);
        end;
      end;
      k := reasons.IndexOf(key);
      if k < 0 then reasons.AddObject(key, TObject(PtrInt(1)))
      else reasons.Objects[k] := TObject(PtrInt(reasons.Objects[k]) + 1);
    end;
  end;
  if dump then Exit;
  for i := 0 to reasons.Count - 1 do Writeln('  ', reasons[i]:14, ' ', PtrInt(reasons.Objects[i]):6);
  Writeln('  ', adam7, ' interlaced, ', tails, ' with bytes after the image');
  if taken < minimum then begin Inc(failures); Writeln('  FAIL: taken ', taken, ' < minimum ', minimum); end;
  Writeln(taken, ' images taken and back, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.
