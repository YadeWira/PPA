{ Measurement, not a test: how long each phase of the codec takes on each
  image stream of a file (the phases Compress and Decompress go through).

    measure_phases <file> }
program measure_phases;
{$I ../ppa.inc}
uses SysUtils, Classes, DateUtils, ppapng, ppadeflate, ppazlib, ppapixels, ppaarith, ppamodel;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

var t: TDateTime;
procedure Lap(const what: string);
begin
  Writeln(Format('  %-34s %8.3f s', [what, MilliSecondsBetween(Now, t) / 1000]));
  t := Now;
end;

var
  d, coded, plain, back: TBytes; p: TPng; z, e: TZStream; info: TImageInfo; px, px2: TPixels;
  prm: TZlibParams; enc: TArithEncoder; dec: TArithDecoder; s: SizeInt;
begin
  d := ReadFile(ParamStr(1));
  t := Now;
  ppapng.Decompose(d, p); Lap('layer 1: decompose');
  for s := 0 to High(p.streams) do begin
    if not (p.streams[s].kind in [skIdat, skFdat]) then Continue;
    Writeln('stream ', s, ': ', Length(p.streams[s].data), ' bytes');
    t := Now;
    ppadeflate.Decode(p.streams[s].data, not IsZlibHeader(p.streams[s].data), MAX_IMAGE_BYTES, z); Lap('2a: inflate and record');
    StreamImage(p, s, info); Unfilter(z.plain, info, px); Lap('3: unfilter');
    if not FindZlibParams(z, prm) then begin Writeln('  no zlib parameters'); Continue; end;
    Lap(Format('2b: find zlib params (level %d st %d ml %d)', [prm.level, prm.strategy, prm.memLevel]));
    ZlibChoices(z.plain, prm, nil, e); Lap('2b: zlib choices (one run)');
    e.raw := z.raw; e.header := z.header; e.adlerOk := z.adlerOk; e.endPad := z.endPad; e.tail := z.tail;
    back := Encode(e); Lap('2a: encode the deflate bits');
    enc.Init; CodeImage(px, @enc, nil); coded := enc.Finish; Lap('5: model, encode');
    px2 := px; px2.data := nil; SetLength(px2.data, Length(px.data)); px2.filters := nil; SetLength(px2.filters, Length(px.filters));
    dec.Init(coded); CodeImage(px2, nil, @dec); Lap('5: model, decode');
    plain := Refilter(px2); Lap('3: refilter');
    Writeln(Format('  plain %d bytes, coded %d', [Length(plain), Length(coded)]));
  end;
end.
