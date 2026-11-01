{ Layer 6: every file in the directory through the codec: compressed
  (which verifies), decompressed and compared. A file the codec does not
  take is reported with its reason (the file layer stores it); one taken
  that does not come back is a FAILURE, as is an exception. Prints the
  sizes against the originals.

    test_codec <directory> [minimum taken] [-v] }
program test_codec;
{$I ../ppa.inc}
uses SysUtils, Classes, DateUtils, ppacodec;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  files: TStringList; sr: TSearchRec; dir, name, why: string;
  i, minimum: Integer; verbose: Boolean;
  d, st, back: TBytes; stats: TCodecStats;
  taken, failures, inBytes, outBytes, notTaken, images, raws: Int64;
  t0: TDateTime;
begin
  dir := ParamStr(1); minimum := StrToIntDef(ParamStr(2), 1); verbose := ParamStr(3) = '-v';
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  taken := 0; failures := 0; inBytes := 0; outBytes := 0; notTaken := 0; images := 0; raws := 0;
  t0 := Now;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    name := ExtractFileName(files[i]);
    try
      if not Compress(d, st, why, stats) then begin
        Inc(notTaken);
        if Pos('bug', why) > 0 then begin Inc(failures); Writeln('  FAIL ', why, '  ', name); end
        else if verbose then Writeln('  not taken: ', why, '  ', name);
        Continue;
      end;
      if not Decompress(st, Length(d), back, why) or (Length(back) <> Length(d)) or
         ((Length(d) > 0) and not CompareMem(@back[0], @d[0], Length(d))) then begin
        Inc(failures); Writeln('  FAIL does not come back: ', why, '  ', name); Continue;
      end;
      Inc(taken); Inc(inBytes, Length(d)); Inc(outBytes, Length(st));
      Inc(images, stats.images); Inc(raws, stats.rawStreams);
      if verbose then
        Writeln(Format('  %9d -> %9d (%6.2f%%)  %d as images, %d as bytes  %s',
          [Length(d), Length(st), 100 * Length(st) / Length(d), stats.images, stats.rawStreams, name]));
    except
      on e: Exception do begin
        Inc(failures); Writeln('  FAIL ', e.ClassName, ': ', e.Message, '  ', name);
      end;
    end;
  end;
  if taken < minimum then begin Inc(failures); Writeln('  FAIL: taken ', taken, ' < minimum ', minimum); end;
  if inBytes = 0 then inBytes := 1;
  Writeln(Format('%d files taken: %d -> %d bytes = %.2f%%; image streams: %d as images, %d as bytes; %d not taken; %.1f s; %d failures',
    [taken, inBytes, outBytes, 100 * outBytes / inBytes, images, raws, notTaken, SecondSpan(Now, t0), failures]));
  if failures > 0 then Halt(1);
end.
