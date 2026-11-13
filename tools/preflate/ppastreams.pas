{ ppastreams: the deflate streams of PNG-family files as PPA sees them, one
  line each, and optionally the streams themselves, for the preflate harness
  (tools/preflate/README.md). Nothing here changes PPA: it calls the units
  PPA compresses with (ppapng.Decompose, ppadeflate.Decode, ppazlib's
  search, ppadeflate.Encode), the way ppacodec.PlanImage does.

    ppastreams [-dump DIR] FILE...
    ppastreams -stream FILE...


  Prints, tab separated: file, stream index, kind (IDAT, fdAT), framing
  (zlib, raw), stream bytes, plain bytes, blocks (stored/fixed/dynamic),
  decode result, zlib (the parameters "L<level> S<strategy> M<memLevel>
  W<wbits>" that give it back bit for bit, or "-"). With -dump, each stream
  that decodes is written to DIR/<file name>.<index>.z (zlib framing) or
  .raw (bare deflate), byte for byte as the file holds it.

  -stream: each FILE is one stream itself (a .raw file bare deflate, any
  other zlib-framed if its first two bytes are a zlib header), stream index
  0, kind "file". }
program ppastreams;
{$I ../../pas/ppa.inc}
uses SysUtils, Classes, ppapng, ppadeflate, ppazlib;

const MAX_PLAIN = 1 shl 30;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

procedure WriteBytes(const f: string; const a: TBytes); var s: TFileStream;
begin s := TFileStream.Create(f, fmCreate); try if Length(a) > 0 then s.WriteBuffer(a[0], Length(a)); finally s.Free; end; end;

function Describe(const a: TBytes; raw: Boolean): string;
var z, e: TZStream; r: TZResult; prm: TZlibParams; back: TBytes; b: SizeInt;
    nb: array[TBlockType] of Integer; res, zs: string;
begin
  zs := '-';
  r := ppadeflate.Decode(a, raw, MAX_PLAIN, z);
  FillChar(nb, SizeOf(nb), 0);
  if r.Ok then res := 'ok' else res := r.Text;
  if r.Ok then begin
    for b := 0 to High(z.blocks) do Inc(nb[z.blocks[b].btype]);
    if FindZlibParams(z, prm, e) then begin
      e.raw := z.raw; e.header := z.header; e.adlerOk := z.adlerOk;
      e.endPad := z.endPad; e.tail := z.tail;
      back := Encode(e);
      if (Length(back) = Length(a)) and CompareMem(@back[0], @a[0], Length(a)) then
        zs := Format('L%d S%d M%d W%d', [prm.level, prm.strategy, prm.memLevel, prm.wbits]);
    end;
  end;
  Result := Format('%d'#9'%d/%d/%d'#9'%s'#9'%s', [Length(z.plain), nb[btStored], nb[btFixed], nb[btDynamic], res, zs]);
end;

var
  i, first: Integer; s: SizeInt; streamMode, raw: Boolean; dumpDir, kind, name: string;
  d: TBytes; p: TPng; pr: TPngResult;
begin
  first := 1; dumpDir := ''; streamMode := False;
  if ParamStr(1) = '-dump' then begin dumpDir := ParamStr(2); first := 3; end;
  if ParamStr(1) = '-stream' then begin streamMode := True; first := 2; end;
  for i := first to ParamCount do begin
    name := ParamStr(i);
    d := ReadFile(name);
    if streamMode then begin
      raw := (ExtractFileExt(name) = '.raw') or not IsZlibHeader(d);
      Write(name, #9'0'#9'file'#9);
      if raw then Write('raw') else Write('zlib');
      Writeln(#9, Length(d), #9, Describe(d, raw));
      Continue;
    end;
    pr := ppapng.Decompose(d, p);
    if not pr.Ok then begin
      Writeln(name, #9'-'#9'-'#9'-'#9'0'#9'0'#9'-'#9'not PNG family: ', pr.Text, #9'-');
      Continue;
    end;
    for s := 0 to High(p.streams) do begin
      case p.streams[s].kind of
        skIdat: kind := 'IDAT';
        skFdat: kind := 'fdAT';
      else Continue;   { JDAT/JDAA: JPEG, PJA's }
      end;
      raw := not IsZlibHeader(p.streams[s].data);
      if dumpDir <> '' then begin
        if raw then WriteBytes(Format('%s/%s.%d.raw', [dumpDir, ExtractFileName(name), s]), p.streams[s].data)
        else WriteBytes(Format('%s/%s.%d.z', [dumpDir, ExtractFileName(name), s]), p.streams[s].data);
      end;
      if raw then Write(name, #9, s, #9, kind, #9'raw') else Write(name, #9, s, #9, kind, #9'zlib');
      Writeln(#9, Length(p.streams[s].data), #9, Describe(p.streams[s].data, raw));
    end;
  end;
end.
