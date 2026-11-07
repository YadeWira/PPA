{ What a file is and what PPA does with it, for the command's info, report
  and --json (doc/CLI.md). From PJA 0.9.7 (pas/pjainfo.pas): the tree and
  its text and JSON are the same code; what fills it is PPA's.

  A description is a tree (TInfoNode) that prints as indented text or as
  one line of JSON. DescribeData fills it from the file's structure: the
  PNG family's chunks (PNG, APNG, MNG, JNG, Apple's CgBI), the image's
  header, each image stream and its zlib header; or a .ppa's descriptor
  and stream. DescribeAction says what PPA does with the file: for a .ppa,
  whether x extracts and verifies it; for anything else, a dry run of a.

  Nothing here prints what a file holds: no pixels, no text of its
  metadata (tEXt, zTXt, iTXt, iCCP, eXIf...: only how many bytes). }
unit ppainfo;

{$I ppa.inc}
{$ifopt R-}{$fatal ppainfo: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppainfo: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, Classes;

type
  TInfoKind = (ikObject, ikList, ikText, ikNumber, ikBool);

  TInfoNode = class
  public
    kind: TInfoKind;
    { its name in the object that holds it ('' in a list) }
    key: string;
    { text, a number written out, or true / false }
    value: string;
    { an object in a list, or under an object: how it prints as text, on
      one line ('' prints its fields under it) }
    line: string;
    items: array of TInfoNode;
    constructor Create(k: TInfoKind; const name: string = '');
    destructor Destroy; override;
    function Add(n: TInfoNode): TInfoNode;
    { an object or a list under this object (or, with name '', an item of
      this list) }
    function Obj(const name: string = ''): TInfoNode;
    function List(const name: string): TInfoNode;
    procedure Str(const name, v: string);
    procedure Num(const name: string; v: Int64);
    procedure Fixed(const name: string; v: Double; digits: Integer = 2);
    procedure Bool(const name: string; v: Boolean);
    { the child of that name, or nil }
    function Find(const name: string): TInfoNode;
    { JSON, on one line }
    function Json: string;
    { indented text, one line per field }
    procedure Render(lines: TStrings; indent: Integer = 0);
  end;

const
  { report: above this, no dry run (the structure only, with a note) }
  REPORT_ESTIMATE_MAX = 64 * 1024 * 1024;

{ The file's structure into n: a .ppa's, a PNG family file's, or "format:
  unknown" }
procedure DescribeData(const d: TBytes; n: TInfoNode);
{ What PPA does with the file: for a .ppa, whether x extracts and verifies
  it (maxOutput as x's --max-output); for anything else, whether a takes
  it, which models its images take and what size, or why it stores it as
  it is. dryRun False: no dry run (a file above REPORT_ESTIMATE_MAX in a
  report), a note instead. One line of text in `line`. }
procedure DescribeAction(const d: TBytes; const ext: string; verify: Boolean; threads: Integer;
                         maxOutput: QWord; dryRun: Boolean; n: TInfoNode; out line: string);
{ A file for `ppa info` and `ppa report`: its name, then its structure
  (DescribeData), then what PPA does with it, as "ppa" (DescribeAction).
  The caller frees it. }
function DescribeFile(const name: string; const d: TBytes; verify: Boolean; threads: Integer;
                      maxOutput: QWord; dryRun: Boolean): TInfoNode;
{ a string for JSON, quoted; bytes that are not UTF-8 go as \u00XX }
function JsonString(const s: string): string;
{ bytes as hex digits }
function HexBytes(const b: array of Byte): string;
{ "1748 B", "15.3 KB", "12.0 MB" }
function HumanSize(n: QWord): string;
{ a number with a dot, whatever the locale }
function DotNumber(v: Double; digits: Integer): string;

implementation

uses ppablake3, ppaformat, ppacodec, ppapng, ppapixels;

function DotNumber(v: Double; digits: Integer): string;
var fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;
  Result := FloatToStrF(v, ffFixed, 18, digits, fs);
end;

function HumanSize(n: QWord): string;
begin
  if n >= 10 * 1024 * 1024 then Result := DotNumber(n / (1024 * 1024), 1) + ' MB'
  else if n >= 10 * 1024 then Result := DotNumber(n / 1024, 1) + ' KB'
  else Result := IntToStr(n) + ' B';
end;

function HexBytes(const b: array of Byte): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(b) do Result := Result + LowerCase(IntToHex(b[i], 2));
end;

{ the length of the UTF-8 sequence at s[i], 0 if there is none }
function Utf8Len(const s: string; i: Integer): Integer;
var c: Byte; k, n: Integer;
begin
  c := Ord(s[i]);
  if c < $80 then Exit(1);
  if (c >= $C2) and (c <= $DF) then n := 2
  else if (c >= $E0) and (c <= $EF) then n := 3
  else if (c >= $F0) and (c <= $F4) then n := 4
  else Exit(0);
  if i + n - 1 > Length(s) then Exit(0);
  for k := 1 to n - 1 do
    if Ord(s[i + k]) and $C0 <> $80 then Exit(0);
  Result := n;
end;

function JsonString(const s: string): string;
var i, n: Integer; c: Char;
begin
  Result := '"';
  i := 1;
  while i <= Length(s) do begin
    c := s[i];
    case c of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
      #0..#7, #11, #14..#31, #127: Result := Result + '\u00' + LowerCase(IntToHex(Ord(c), 2));
    else
      n := Utf8Len(s, i);
      if n = 0 then Result := Result + '\u00' + LowerCase(IntToHex(Ord(c), 2))
      else begin
        Result := Result + Copy(s, i, n);
        Inc(i, n);
        Continue;
      end;
    end;
    Inc(i);
  end;
  Result := Result + '"';
end;

{ ---------- TInfoNode ---------- }

constructor TInfoNode.Create(k: TInfoKind; const name: string);
begin
  inherited Create;
  kind := k;
  key := name;
end;

destructor TInfoNode.Destroy;
var i: Integer;
begin
  for i := 0 to High(items) do items[i].Free;
  inherited Destroy;
end;

function TInfoNode.Add(n: TInfoNode): TInfoNode;
var k: Integer;
begin
  { a field given twice keeps the last value }
  if (kind = ikObject) and (n.key <> '') then
    for k := 0 to High(items) do
      if items[k].key = n.key then begin
        items[k].Free;
        items[k] := n;
        Exit(n);
      end;
  SetLength(items, Length(items) + 1);
  items[High(items)] := n;
  Result := n;
end;

function TInfoNode.Obj(const name: string): TInfoNode;
begin
  Result := Add(TInfoNode.Create(ikObject, name));
end;

function TInfoNode.List(const name: string): TInfoNode;
begin
  Result := Add(TInfoNode.Create(ikList, name));
end;

procedure TInfoNode.Str(const name, v: string);
begin
  Add(TInfoNode.Create(ikText, name)).value := v;
end;

procedure TInfoNode.Num(const name: string; v: Int64);
begin
  Add(TInfoNode.Create(ikNumber, name)).value := IntToStr(v);
end;

procedure TInfoNode.Fixed(const name: string; v: Double; digits: Integer);
begin
  Add(TInfoNode.Create(ikNumber, name)).value := DotNumber(v, digits);
end;

procedure TInfoNode.Bool(const name: string; v: Boolean);
begin
  if v then Add(TInfoNode.Create(ikBool, name)).value := 'true'
  else Add(TInfoNode.Create(ikBool, name)).value := 'false';
end;

function TInfoNode.Find(const name: string): TInfoNode;
var k: Integer;
begin
  Result := nil;
  for k := 0 to High(items) do
    if items[k].key = name then Exit(items[k]);
end;

function TInfoNode.Json: string;
var k: Integer;
begin
  case kind of
    ikText: Result := JsonString(value);
    ikNumber, ikBool: Result := value;
    ikList: begin
      Result := '[';
      for k := 0 to High(items) do begin
        if k > 0 then Result := Result + ',';
        Result := Result + items[k].Json;
      end;
      Result := Result + ']';
    end;
  else
    Result := '{';
    for k := 0 to High(items) do begin
      if k > 0 then Result := Result + ',';
      Result := Result + JsonString(items[k].key) + ':' + items[k].Json;
    end;
    Result := Result + '}';
  end;
end;

procedure TInfoNode.Render(lines: TStrings; indent: Integer);
var k: Integer; pad: string; it: TInfoNode;
begin
  pad := StringOfChar(' ', indent);
  for k := 0 to High(items) do begin
    it := items[k];
    if kind = ikList then begin
      if (it.kind = ikObject) and (it.line = '') then begin
        lines.Add(pad + '-');
        it.Render(lines, indent + 2);
      end else if it.kind = ikObject then lines.Add(pad + '- ' + it.line)
      else if it.kind in [ikObject, ikList] then begin
        lines.Add(pad + '-');
        it.Render(lines, indent + 2);
      end else lines.Add(pad + '- ' + it.value);
    end else if it.kind in [ikObject, ikList] then begin
      if (it.kind = ikObject) and (it.line <> '') then lines.Add(pad + it.key + ': ' + it.line)
      else if Length(it.items) = 0 then lines.Add(pad + it.key + ': (none)')
      else begin
        lines.Add(pad + it.key + ':');
        it.Render(lines, indent + 2);
      end;
    end else lines.Add(pad + it.key + ': ' + it.value);
  end;
end;

{ ---------- the PNG family ---------- }

const
  { the chunks whose data is metadata: only their sizes are told }
  METADATA_CHUNKS: array[0..6] of string = ('tEXt', 'zTXt', 'iTXt', 'iCCP', 'eXIf', 'tIME', 'caBX');
  { image streams listed one by one (an APNG may have hundreds) }
  MAX_LISTED_STREAMS = 32;

function Be32At(const d: TBytes; i: SizeInt): LongWord;
begin
  if (i < 0) or (i + 4 > Length(d)) then Exit(0);
  Result := (LongWord(d[i]) shl 24) or (LongWord(d[i + 1]) shl 16) or (LongWord(d[i + 2]) shl 8) or LongWord(d[i + 3]);
end;

function IsMetadata(const name: string): Boolean;
var k: Integer;
begin
  for k := 0 to High(METADATA_CHUNKS) do
    if METADATA_CHUNKS[k] = name then Exit(True);
  Result := False;
end;

{ a chunk's name, printable: a damaged type shows as hex }
function SafeChunkName(typ: LongWord): string;
var k: Integer; c: Char;
begin
  Result := ChunkName(typ);
  for k := 1 to 4 do begin
    c := Result[k];
    if not (c in ['A'..'Z', 'a'..'z']) then Exit('0x' + IntToHex(typ, 8));
  end;
end;

function ColorTypeName(ct: Byte): string;
begin
  case ct of
    0: Result := 'gray';
    2: Result := 'RGB';
    3: Result := 'palette';
    4: Result := 'gray and alpha';
    6: Result := 'RGBA';
  else
    Result := 'unknown (' + IntToStr(ct) + ')';
  end;
end;

function JngColorName(ct: Byte): string;
begin
  case ct of
    8: Result := 'gray';
    10: Result := 'colour';
    12: Result := 'gray and alpha';
    14: Result := 'colour and alpha';
  else
    Result := 'unknown (' + IntToStr(ct) + ')';
  end;
end;

{ the data of the first chunk of that type, or False }
function FirstChunk(const p: TPng; typ: LongWord; out data: TBytes): Boolean;
var i: SizeInt;
begin
  data := nil;
  for i := 0 to High(p.chunks) do
    if (p.chunks[i].typ = typ) and (p.chunks[i].stream < 0) then begin
      data := p.chunks[i].data;
      Exit(True);
    end;
  Result := False;
end;

const
  CT_acTL = $6163544C;
  CT_CgBI = $43674249;

procedure DescribeIhdr(const h: TBytes; n: TInfoNode);
var o: TInfoNode; il: string;
begin
  if Length(h) < 13 then begin n.Str('image', 'IHDR too short'); Exit; end;
  o := n.Obj('image');
  o.Num('width', Be32At(h, 0));
  o.Num('height', Be32At(h, 4));
  o.Num('bit_depth', h[8]);
  o.Str('color_type', ColorTypeName(h[9]));
  if h[12] = 0 then il := 'none' else if h[12] = 1 then il := 'Adam7' else il := 'unknown (' + IntToStr(h[12]) + ')';
  o.Str('interlace', il);
  o.line := IntToStr(Be32At(h, 0)) + ' x ' + IntToStr(Be32At(h, 4)) + ', ' + IntToStr(h[8]) + '-bit ' +
            ColorTypeName(h[9]);
  if h[12] = 1 then o.line := o.line + ', interlaced (Adam7)';
end;

procedure DescribePng(const d: TBytes; n: TInfoNode);
var
  p: TPng; r: TPngResult; i, s, k: SizeInt; data: TBytes;
  names: array of string; counts, bytes: array of Int64;
  crcBad, meta, chunksOf: Int64; nm, fmt, zl, line: string; lst, o, probs: TInfoNode;
  cmf, flg: Byte; hasEnd: Boolean;
begin
  r := Decompose(d, p);
  if not r.Ok then begin
    n.Str('format', 'unknown');
    n.Num('size', Length(d));
    Exit;
  end;
  case p.kind of
    pkMng: fmt := 'MNG';
    pkJng: fmt := 'JNG';
  else
    if FirstChunk(p, CT_acTL, data) then fmt := 'APNG' else fmt := 'PNG';
    if (Length(p.chunks) > 0) and (p.chunks[0].typ = CT_CgBI) then fmt := fmt + ' (Apple CgBI)';
  end;
  n.Str('format', fmt);
  n.Num('size', Length(d));

  { the chunks by type, in the order each type first comes }
  names := nil; counts := nil; bytes := nil;
  crcBad := 0; meta := 0; hasEnd := False;
  for i := 0 to High(p.chunks) do begin
    nm := SafeChunkName(p.chunks[i].typ);
    if not p.chunks[i].crcOk then Inc(crcBad);
    if IsMetadata(nm) then Inc(meta, p.chunks[i].len);
    if (p.chunks[i].typ = CT_IEND) or (p.chunks[i].typ = CT_MEND) then hasEnd := True;
    k := 0;
    while (k < Length(names)) and (names[k] <> nm) do Inc(k);
    if k = Length(names) then begin
      SetLength(names, k + 1); SetLength(counts, k + 1); SetLength(bytes, k + 1);
      names[k] := nm; counts[k] := 0; bytes[k] := 0;
    end;
    Inc(counts[k]);
    Inc(bytes[k], p.chunks[i].len);
  end;
  n.Num('chunk_count', Length(p.chunks));
  lst := n.List('chunks');
  for k := 0 to High(names) do begin
    o := lst.Obj;
    o.Str('type', names[k]);
    o.Num('count', counts[k]);
    o.Num('bytes', bytes[k]);
    o.line := names[k] + ' x' + IntToStr(counts[k]) + ', ' + HumanSize(bytes[k]);
    if IsMetadata(names[k]) then o.line := o.line + ' (metadata: its size only)';
  end;
  n.Num('metadata_bytes', meta);

  { the image's header }
  case p.kind of
    pkPng:
      if FirstChunk(p, CT_IHDR, data) then begin
        DescribeIhdr(data, n);
        if FirstChunk(p, CT_acTL, data) and (Length(data) >= 8) then begin
          o := n.Find('image');
          if o <> nil then begin
            o.Num('frames', Be32At(data, 0));
            o.Num('plays', Be32At(data, 4));
            o.line := o.line + ', ' + IntToStr(Be32At(data, 0)) + ' frame(s)';
          end;
        end;
      end;
    pkMng:
      if FirstChunk(p, CT_MHDR, data) and (Length(data) >= 12) then begin
        o := n.Obj('mng');
        o.Num('width', Be32At(data, 0));
        o.Num('height', Be32At(data, 4));
        o.Num('ticks_per_second', Be32At(data, 8));
        o.line := IntToStr(Be32At(data, 0)) + ' x ' + IntToStr(Be32At(data, 4)) + ', ' +
                  IntToStr(Be32At(data, 8)) + ' ticks a second';
      end;
    pkJng:
      if FirstChunk(p, CT_JHDR, data) and (Length(data) >= 16) then begin
        o := n.Obj('image');
        o.Num('width', Be32At(data, 0));
        o.Num('height', Be32At(data, 4));
        o.Str('color_type', JngColorName(data[8]));
        o.Num('sample_depth', data[9]);
        o.Num('alpha_depth', data[12]);
        o.line := IntToStr(Be32At(data, 0)) + ' x ' + IntToStr(Be32At(data, 4)) + ', ' + JngColorName(data[8]) +
                  ', JPEG of ' + IntToStr(data[9]) + '-bit samples';
        if data[12] > 0 then o.line := o.line + ', alpha of ' + IntToStr(data[12]) + ' bits';
      end;
  end;

  { the image streams }
  n.Num('image_stream_count', Length(p.streams));
  lst := n.List('image_streams');
  for s := 0 to High(p.streams) do begin
    if s = MAX_LISTED_STREAMS then begin
      lst.Add(TInfoNode.Create(ikText)).value := 'and ' + IntToStr(Length(p.streams) - s) + ' more';
      Break;
    end;
    o := lst.Obj;
    case p.streams[s].kind of
      skIdat: nm := 'IDAT';
      skFdat: nm := 'fdAT';
      skJdat: nm := 'JDAT';
    else nm := 'JDAA';
    end;
    chunksOf := 0;
    for i := 0 to High(p.chunks) do
      if p.chunks[i].stream = s then Inc(chunksOf);
    o.Str('kind', nm);
    o.Num('bytes', Length(p.streams[s].data));
    o.Num('chunks', chunksOf);
    line := nm + ', ' + HumanSize(Length(p.streams[s].data)) + ' in ' + IntToStr(chunksOf) + ' chunk(s)';
    data := p.streams[s].data;
    if p.streams[s].kind in [skJdat, skJdaa] then begin
      if (Length(data) >= 2) and (data[0] = $FF) and (data[1] = $D8) then line := line + ', JPEG'
      else if p.streams[s].kind = skJdaa then line := line + ', not a JPEG'
      else line := line + ', not a JPEG';
    end else if Length(data) >= 2 then begin
      cmf := data[0]; flg := data[1];
      zl := LowerCase(IntToHex(cmf, 2) + IntToHex(flg, 2));
      o.Str('zlib_header', zl);
      if ((cmf and $0F) = 8) and (((Word(cmf) shl 8) or flg) mod 31 = 0) then begin
        o.Num('window', 1 shl ((cmf shr 4) + 8));
        case flg shr 6 of
          0: o.Str('level_hint', 'fastest');
          1: o.Str('level_hint', 'fast');
          2: o.Str('level_hint', 'default');
        else o.Str('level_hint', 'maximum');
        end;
        line := line + ', zlib ' + zl + ' (' + o.Find('level_hint').value + ', ' +
                IntToStr((1 shl ((cmf shr 4) + 8)) div 1024) + ' KB window)';
      end else line := line + ', no zlib header (' + zl + ')';
    end;
    o.line := line;
  end;

  n.Num('trailer_bytes', Length(p.trailer));
  probs := n.List('problems');
  if crcBad > 0 then probs.Add(TInfoNode.Create(ikText)).value := IntToStr(crcBad) + ' chunk(s) with a CRC that does not match';
  if Length(p.trailer) > 0 then
    probs.Add(TInfoNode.Create(ikText)).value := IntToStr(Length(p.trailer)) + ' B after the last chunk';
  if not hasEnd then probs.Add(TInfoNode.Create(ikText)).value := 'no IEND (or MEND): the file ends early';
end;

{ ---------- a .ppa ---------- }

procedure DescribePpa(const d: TBytes; n: TInfoNode);
var desc: TDescriptor; e: TFormatError; pos: SizeInt; v: QWord; sh: Integer;
begin
  n.Str('format', '.ppa');
  n.Num('size', Length(d));
  e := Inspect(d, desc);
  if e <> feNone then begin
    n.Str('error', FormatErrorText(e));
    Exit;
  end;
  n.Num('format_version', d[4]);
  n.Bool('stored', desc.stored);
  n.Num('original_size', desc.origSize);
  n.Str('extension', desc.ext);
  n.Str('blake3_128', HexBytes(desc.hash));
  n.Num('payload_bytes', desc.payloadLen);
  if desc.origSize > 0 then n.Fixed('ratio_percent', 100 * Length(d) / desc.origSize);
  if desc.stored or (desc.payloadLen < 1) then Exit;
  n.Num('stream_version', d[desc.payloadPos]);
  { the substreams' count: the structure and the streams kept as bytes,
    then one a band, then one a JNG's JPEG (doc/CODEC.md) }
  pos := desc.payloadPos + 1; v := 0; sh := 0;
  while (pos < Length(d)) and (sh < 63) do begin
    v := v or (QWord(d[pos] and 127) shl sh);
    Inc(sh, 7);
    if d[pos] < 128 then begin n.Num('substreams', v); Break; end;
    Inc(pos);
  end;
end;

procedure DescribeData(const d: TBytes; n: TInfoNode);
begin
  if IsPpa(d) then DescribePpa(d, n)
  else DescribePng(d, n);
end;

{ ---------- what PPA does ---------- }

function Plural(k: Integer; const one: string): string;
begin
  if k = 1 then Result := '1 ' + one else Result := IntToStr(k) + ' ' + one + 's';
end;

procedure DescribeAction(const d: TBytes; const ext: string; verify: Boolean; threads: Integer;
                         maxOutput: QWord; dryRun: Boolean; n: TInfoNode; out line: string);
var ppa, orig: TBytes; desc: TDescriptor; e: TFormatError; detail, why, models: string; stored, ok: Boolean;
    st: TCodecStats; m: Integer; o: TInfoNode; cap: QWord;
begin
  if IsPpa(d) then begin
    n.Str('command', 'x');
    if maxOutput = High(QWord) then cap := 0 else cap := maxOutput;
    e := Unpack(d, cap, orig, desc, detail, threads);
    n.Bool('ok', e = feNone);
    if e = feNone then begin
      n.Num('original_size', Length(orig));
      line := 'extracts it: ' + IntToStr(Length(orig)) + ' B, size and BLAKE3-128 verified';
    end else begin
      why := FormatErrorText(e);
      if detail <> '' then why := why + ' (' + detail + ')';
      n.Str('error', why);
      if e = feTooLarge then line := 'does not extract it: the original is larger than --max-output'
      else line := 'does not extract it: ' + why;
    end;
    Exit;
  end;
  n.Str('command', 'a');
  if not dryRun then begin
    n.Bool('estimated', False);
    line := 'not estimated: the file is larger than ' + IntToStr(REPORT_ESTIMATE_MAX div (1024 * 1024)) +
            ' MB (ppa info does the dry run)';
    Exit;
  end;
  n.Bool('estimated', True);
  ok := Pack(d, ext, verify, ppa, stored, why, st, threads);
  n.Bool('ok', ok);
  if not ok then begin
    n.Bool('takes', False);
    n.Str('error', why);
    line := 'refuses it: ' + why;
    Exit;
  end;
  n.Bool('takes', True);
  n.Bool('stored', stored);
  n.Num('ppa_size', Length(ppa));
  if Length(d) > 0 then n.Fixed('ratio_percent', 100 * Length(ppa) / Length(d));
  if stored then begin
    n.Str('why_stored', why);
    { the codec's own check failed: what a report is for }
    if Pos('bug', why) > 0 then n.Str('internal_error', why);
    line := 'stores it as it is (' + why + '): ' + IntToStr(Length(d)) + ' B -> ' + IntToStr(Length(ppa)) + ' B';
    Exit;
  end;
  o := n.Obj('image_streams');
  models := '';
  for m := Low(st.modes) to High(st.modes) do begin
    o.Num(StringReplace(StringReplace(MODE_NAMES[m], ' ', '_', [rfReplaceAll]), '(PJA)', 'pja', []), st.modes[m]);
    if (st.modes[m] > 0) and (m <> MODE_BYTES) then begin
      if models <> '' then models := models + ', ';
      models := models + IntToStr(st.modes[m]) + ' ' + MODE_NAMES[m];
    end;
  end;
  n.Num('bands', st.bands);
  if st.images = 0 then models := 'no image modelled'
  else models := Plural(st.images, 'image stream') + ' modelled (' + models + ')';
  if st.rawStreams > 0 then models := models + ', ' + Plural(st.rawStreams, 'image stream') + ' as bytes';
  line := 'takes it: ' + models + ', ' + IntToStr(Length(d)) + ' B -> ' + IntToStr(Length(ppa)) + ' B';
  if Length(d) > 0 then line := line + ' (' + DotNumber(100 * Length(ppa) / Length(d), 2) + '%)';
end;

function DescribeFile(const name: string; const d: TBytes; verify: Boolean; threads: Integer;
                      maxOutput: QWord; dryRun: Boolean): TInfoNode;
var act, bug: TInfoNode; summary, ext: string;
begin
  Result := TInfoNode.Create(ikObject);
  Result.Str('file', name);
  { a bug met here is what a report is for: it goes in the description,
    as internal_error, instead of ending the command }
  try
    DescribeData(d, Result);
  except
    on e: Exception do Result.Str('internal_error', 'describing it: ' + e.ClassName + ': ' + e.Message);
  end;
  act := TInfoNode.Create(ikObject, 'ppa');
  ext := ExtractFileExt(name);
  if ext <> '' then Delete(ext, 1, 1);
  try
    DescribeAction(d, ext, verify, threads, maxOutput, dryRun, act, summary);
  except
    on e: Exception do begin
      summary := 'internal error: ' + e.ClassName + ': ' + e.Message;
      Result.Str('internal_error', e.ClassName + ': ' + e.Message);
    end;
  end;
  bug := act.Find('internal_error');
  if (bug <> nil) and (Result.Find('internal_error') = nil) then Result.Str('internal_error', bug.value);
  act.line := summary;
  act.Str('summary', summary);
  Result.Add(act);
end;

end.
