{ Layer 2a: every zlib stream of every file of the PNG family in the
  directory (the IDAT of each image, the fdAT of each APNG frame), decoded
  into its bytes and its encoder's choices and encoded again, must give the
  same bits. A stream that does not decode is reported with its reason (the
  upper layers keep it as it is); one that decodes and does not come back
  is a FAILURE, as is an exception.

    test_deflate <directory> [minimum streams back] [-v | -dump DIR]

  -dump writes each stream that decodes to DIR/N.z (N.raw if bare deflate)
  and prints the length and CRC-32 of its bytes, for tests/zcheck.py to
  check against Python's zlib that they are the bytes it holds. }
program test_deflate;
{$I ../ppa.inc}
uses SysUtils, Classes, ppacrc, ppapng, ppadeflate;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

const MAX_PLAIN = 1 shl 30;

var
  dir, name, key: string; files, reasons: TStringList; sr: TSearchRec;
  i, k, minimum: Integer; ok, failures, nStreams, nRaw: Int64;
  verbose, dump: Boolean; dumpDir: string; fs: TFileStream;
  d: TBytes; p: TPng; pr: TPngResult; z: TZStream; r: TZResult;
  s, b: SizeInt;
  stats: array[TBlockType] of Int64; pads, l284, badAdler, tails, plainBytes, streamBytes: Int64;
begin
  dir := ParamStr(1); minimum := StrToIntDef(ParamStr(2), 1);
  verbose := ParamStr(3) = '-v'; dump := ParamStr(3) = '-dump'; dumpDir := ParamStr(4);
  files := TStringList.Create; files.Sorted := True;
  reasons := TStringList.Create; reasons.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  ok := 0; failures := 0; nStreams := 0; nRaw := 0;
  FillChar(stats, SizeOf(stats), 0);
  pads := 0; l284 := 0; badAdler := 0; tails := 0; plainBytes := 0; streamBytes := 0;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    name := ExtractFileName(files[i]);
    pr := ppapng.Decompose(d, p);
    if not pr.Ok then Continue;
    for s := 0 to High(p.streams) do begin
      if not (p.streams[s].kind in [skIdat, skFdat]) then Continue;
      Inc(nStreams);
      try
        { an iPhone's CgBI PNG has bare deflate, without the zlib header }
        if not IsZlibHeader(p.streams[s].data) then Inc(nRaw);
        r := ppadeflate.VerifyRoundTrip(p.streams[s].data, not IsZlibHeader(p.streams[s].data), MAX_PLAIN, z);
        if r.Ok then begin
          Inc(ok); key := 'ok';
          Inc(plainBytes, Length(z.plain)); Inc(streamBytes, Length(p.streams[s].data));
          for b := 0 to High(z.blocks) do begin
            Inc(stats[z.blocks[b].btype]);
            if (z.blocks[b].btype = btStored) and (z.blocks[b].pad <> 0) then Inc(pads);
          end;
          if z.endPad <> 0 then Inc(pads);
          for b := 0 to High(z.tokLen) do if z.tokLen[b] = LEN_258_AS_284 then Inc(l284);
          if not z.raw and not z.adlerOk then Inc(badAdler);
          if Length(z.tail) > 0 then Inc(tails);
          if dump then begin
            if z.raw then key := '.raw' else key := '.z';
            key := Format('%s/%d%s', [dumpDir, ok, key]);
            fs := TFileStream.Create(key, fmCreate);
            try fs.WriteBuffer(p.streams[s].data[0], Length(p.streams[s].data)); finally fs.Free; end;
            Writeln(ExtractFileName(key), ' ', Length(z.plain), ' ', IntToHex(Crc32(z.plain, 0, Length(z.plain)), 8));
            key := 'ok';
          end;
        end else begin
          key := r.Text; Delete(key, Pos('@', key), MaxInt);
          if r.err = zeNoRoundTrip then Inc(failures);
        end;
        if (verbose and (key <> 'ok')) or (r.err = zeNoRoundTrip) then
          Writeln('  ', key:12, '  ', r.Text, '  stream ', s, '  ', name);
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
  for i := 0 to reasons.Count - 1 do Writeln('  ', reasons[i]:12, ' ', PtrInt(reasons.Objects[i]):6);
  Writeln(Format('  blocks: %d stored, %d fixed, %d dynamic; %d non-zero pads, %d bare deflate, %d wrong Adler-32, %d with bytes after, %d matches of 258 as 284',
    [stats[btStored], stats[btFixed], stats[btDynamic], pads, nRaw, badAdler, tails, l284]));
  Writeln(Format('  %d stream bytes hold %d bytes', [streamBytes, plainBytes]));
  if ok < minimum then begin Inc(failures); Writeln('  FAIL: streams back ', ok, ' < minimum ', minimum); end;
  Writeln(nStreams, ' streams, ', ok, ' identical round trips, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.
