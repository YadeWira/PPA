{ Measurement and round trip of layer 5's static model (ppastatic): every
  8-bit image of every file of the PNG family in the directory, coded and
  decoded back (it must come back), with the sizes against the zlib stream,
  and a CRC-32 of the coded streams (the same with PPA_NOC=1: the Pascal
  reference).

    measure_static <directory> [-v] }
program measure_static;
{$I ../ppa.inc}
uses SysUtils, Classes, DateUtils, ppacrc, ppapng, ppadeflate, ppapixels, ppafast, ppastatic;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var
  files: TStringList; sr: TSearchRec; dir: string;
  i: Integer; s: SizeInt; verbose: Boolean;
  d, coded: TBytes; p: TPng; z: TZStream; info: TImageInfo; px, back: TPixels;
  streamBytes, codedBytes, rawBytes, failures, images: Int64;
  crc: LongWord; tEnc, tDec: Int64; t: TDateTime;
begin
  dir := ParamStr(1); verbose := ParamStr(2) = '-v';
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  streamBytes := 0; codedBytes := 0; rawBytes := 0; failures := 0; images := 0; tEnc := 0; tDec := 0;
  crc := CRC32_INIT;
  for i := 0 to files.Count - 1 do begin
    try d := ReadFile(files[i]); ppapng.Decompose(d, p); except Continue; end;
    for s := 0 to High(p.streams) do begin
      if not (p.streams[s].kind in [skIdat, skFdat]) then Continue;
      if not ppadeflate.Decode(p.streams[s].data, not IsZlibHeader(p.streams[s].data), MAX_IMAGE_BYTES, z).Ok then Continue;
      if not StreamImage(p, s, info) then Continue;
      if not FastEligible(info) then Continue;
      if not Unfilter(z.plain, info, px) then Continue;
      t := Now;
      coded := EncodeImageStatic(px, 0, High(SizeInt));
      tEnc := tEnc + MilliSecondsBetween(Now, t);
      crc := Crc32Update(crc, coded, 0, Length(coded));
      back := px; back.data := nil; SetLength(back.data, Length(px.data));
      back.filters := nil; SetLength(back.filters, Length(px.filters));
      t := Now;
      if not DecodeImageStatic(back, 0, High(SizeInt), coded, 0, Length(coded)) then begin
        Inc(failures); Writeln('NOT DECODED: ', files[i], ' stream ', s);
      end;
      tDec := tDec + MilliSecondsBetween(Now, t);
      Inc(images);
      if (CompareByte(back.data[0], px.data[0], Length(px.data)) <> 0) or
         (CompareByte(back.filters[0], px.filters[0], Length(px.filters)) <> 0) then begin
        Inc(failures); Writeln('FAILED: ', files[i], ' stream ', s);
      end;
      Inc(streamBytes, Length(p.streams[s].data)); Inc(codedBytes, Length(coded)); Inc(rawBytes, Length(px.data));
      if verbose then
        Writeln(Format('%10d -> %10d (%6.2f%%)  %dx%d ct%d  %s', [Length(p.streams[s].data), Length(coded),
          100 * Length(coded) / Length(p.streams[s].data), info.width, info.height, info.colorType, ExtractFileName(files[i])]));
    end;
  end;
  Writeln(Format('%d images: zlib streams %d bytes, static model %d bytes = %.2f%% (%d bytes unfiltered), crc %.8X, encode %.1f s, decode %.1f s, %d failures',
    [images, streamBytes, codedBytes, 100 * codedBytes / (streamBytes + Ord(streamBytes = 0)), rawBytes, Int64(Crc32Final(crc)),
     tEnc / 1000, tDec / 1000, failures]));
  if failures > 0 then Halt(1);
end.
