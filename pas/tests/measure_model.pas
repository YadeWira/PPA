{ Measurement and round trip of layer 5's model: every image of every file
  of the PNG family in the directory, its unfiltered bytes and filters coded
  by the model and decoded again (they must come back), with the sizes:
  coded against the zlib stream the image came in.

    measure_model <directory> [-v] }
program measure_model;
{$I ../ppa.inc}
uses SysUtils, Classes, DateUtils, ppacrc, ppapng, ppadeflate, ppapixels, ppaarith, ppamodel;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  files: TStringList; sr: TSearchRec; dir, name: string;
  i: Integer; s: SizeInt; verbose: Boolean;
  d, coded: TBytes; p: TPng; z: TZStream; info: TImageInfo; px, back: TPixels;
  e: TArithEncoder; dc: TArithDecoder;
  streamBytes, codedBytes, rawBytes, failures, images: Int64;
  t0: TDateTime; crc: LongWord;
begin
  dir := ParamStr(1); verbose := ParamStr(2) = '-v';
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  streamBytes := 0; codedBytes := 0; rawBytes := 0; failures := 0; images := 0;
  t0 := Now; crc := CRC32_INIT;
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    name := ExtractFileName(files[i]);
    if not ppapng.Decompose(d, p).Ok then Continue;
    for s := 0 to High(p.streams) do begin
      if not (p.streams[s].kind in [skIdat, skFdat]) then Continue;
      if not ppadeflate.Decode(p.streams[s].data, not IsZlibHeader(p.streams[s].data), MAX_IMAGE_BYTES, z).Ok then Continue;
      if not StreamImage(p, s, info) or not Unfilter(z.plain, info, px) then Continue;
      e.Init;
      CodeImage(px, @e, nil);
      coded := e.Finish;
      { decode into a copy with the same layout }
      back := px;
      back.filters := nil; SetLength(back.filters, Length(px.filters));
      back.data := nil; SetLength(back.data, Length(px.data));
      dc.Init(coded);
      CodeImage(back, nil, @dc);
      if (Length(px.data) > 0) and not CompareMem(@back.data[0], @px.data[0], Length(px.data)) or
         (Length(px.filters) > 0) and not CompareMem(@back.filters[0], @px.filters[0], Length(px.filters)) then begin
        Inc(failures); Writeln('  FAIL decoded image differs, stream ', s, '  ', name);
      end;
      Inc(images);
      Inc(streamBytes, Length(p.streams[s].data));
      Inc(codedBytes, Length(coded));
      crc := Crc32Update(crc, coded, 0, Length(coded));
      Inc(rawBytes, Length(px.data));
      if verbose then
        Writeln(Format('  %8d -> %8d (%6.2f%%)  %dx%d ct%d d%d  stream %d  %s',
          [Length(p.streams[s].data), Length(coded), 100 * Length(coded) / Length(p.streams[s].data),
           info.width, info.height, info.colorType, info.depth, s, name]));
    end;
  end;
  { the CRC-32 of every coded stream: the C loop and the Pascal one
    (PPA_NOC=1) must give the same }
  Writeln(Format('%d images: zlib streams %d bytes, model %d bytes = %.2f%% (%d bytes unfiltered), crc %.8x, %.1f s, %d failures',
    [images, streamBytes, codedBytes, 100 * codedBytes / streamBytes, rawBytes, Crc32Final(crc), SecondSpan(Now, t0), failures]));
  if failures > 0 then Halt(1);
end.
