{ The ppa command (doc/CLI.md).

    ppa a [options] FILE...    image.png -> image.ppa
    ppa x [options] FILE...    image.ppa -> image.png (the original's extension)
    ppa list FILE...           what each .ppa holds

  Nothing is written under an output's name unless it verified: `a`
  decompresses its own stream and compares (unless --no-verify), `x` checks
  the size and the hash; and the output goes to a temporary name first,
  renamed only when complete. An existing output is not replaced without
  -f. Exit status: 0 every file went through, 1 any failed, 2 usage. }
program ppa;

{$I ppa.inc}

uses SysUtils, Classes, ppaformat, ppablake3, ppacodec;

const
  VERSION = '0.1.0';

var
  outPath, outDir: string;
  force, quiet, dryRun, noVerify: Boolean;
  maxOut: QWord = 256 * 1024 * 1024;
  failures: Integer = 0;

procedure Usage;
begin
  Writeln('PPA ', VERSION, ': lossless recompression of PNG, APNG, MNG and JNG files');
  Writeln;
  Writeln('  ppa a [options] FILE...    compress: image.png -> image.ppa');
  Writeln('  ppa x [options] FILE...    extract: image.ppa -> image.png, byte for byte');
  Writeln('  ppa list FILE...           what each .ppa holds');
  Writeln;
  Writeln('  -o PATH            output name (one input), or a directory');
  Writeln('  --output-dir=DIR   output directory');
  Writeln('  -f, --force        replace an existing output (only with one that verified)');
  Writeln('  --no-verify        a: do not decompress the result to check it first');
  Writeln('  --max-output=SIZE  x: refuse a declared original above SIZE (256M; K/M/G; 0 = none)');
  Writeln('  -n, --dry-run      do everything but write');
  Writeln('  -q, --quiet        only errors');
  Writeln('  --version');
end;

procedure Err(const s: string);
begin
  Inc(failures);
  Writeln(StdErr, 'ppa: ', s);
end;

function ReadAll(const f: string; out d: TBytes): Boolean;
var s: TFileStream;
begin
  Result := False; d := nil;
  try
    s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone);
    try
      SetLength(d, s.Size);
      if s.Size > 0 then s.ReadBuffer(d[0], s.Size);
      Result := True;
    finally s.Free; end;
  except
    on e: Exception do Err(f + ': cannot read: ' + e.Message);
  end;
end;

{ To a temporary name next to it, then renamed: a half-written output never
  has the output's name. }
function WriteAll(const f: string; const d: TBytes): Boolean;
var s: TFileStream; tmp: string;
begin
  Result := False;
  if FileExists(f) and not force then begin Err(f + ': exists (use -f to replace it)'); Exit; end;
  if dryRun then Exit(True);
  tmp := f + '.ppa-tmp' + IntToStr(GetProcessID);
  try
    s := TFileStream.Create(tmp, fmCreate);
    try
      if Length(d) > 0 then s.WriteBuffer(d[0], Length(d));
    finally s.Free; end;
    if FileExists(f) then DeleteFile(f);
    if not RenameFile(tmp, f) then begin DeleteFile(tmp); Err(f + ': cannot rename the output into place'); Exit; end;
    Result := True;
  except
    on e: Exception do begin
      if FileExists(tmp) then DeleteFile(tmp);
      Err(f + ': cannot write: ' + e.Message);
    end;
  end;
end;

function OutputName(const input, newExt: string; single: Boolean): string;
var stem: string;
begin
  stem := ChangeFileExt(ExtractFileName(input), '');
  if newExt <> '' then stem := stem + '.' + newExt;
  if (outPath <> '') and single and not DirectoryExists(outPath) and
     not ((outPath <> '') and (outPath[Length(outPath)] in ['/', '\'])) then Exit(outPath);
  if outPath <> '' then Exit(IncludeTrailingPathDelimiter(outPath) + stem);
  if outDir <> '' then Exit(IncludeTrailingPathDelimiter(outDir) + stem);
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(input)) + stem;
  if ExtractFilePath(input) = '' then Result := stem;
end;

function SizeText(n: Int64): string;
begin
  Result := IntToStr(n);
end;

procedure DoCompress(const f: string; single: Boolean);
var d, p: TBytes; stored: Boolean; why, o, ext: string;
begin
  if not ReadAll(f, d) then Exit;
  ext := ExtractFileExt(f);
  if (ext <> '') and (ext[1] = '.') then Delete(ext, 1, 1);
  if not Pack(d, ext, not noVerify, p, stored, why) then begin Err(f + ': ' + why); Exit; end;
  if stored and (Pos('bug', why) > 0) then Err(f + ': ' + why + ' (stored as it is)');
  o := OutputName(f, 'ppa', single);
  if not WriteAll(o, p) then Exit;
  if not quiet then begin
    if stored then
      Writeln(f, ' -> ', o, ': stored, ', SizeText(Length(d)), ' -> ', SizeText(Length(p)), ' (', why, ')')
    else
      Writeln(f, ' -> ', o, ': ', SizeText(Length(d)), ' -> ', SizeText(Length(p)),
        Format(' (%.2f%%)', [100 * Length(p) / Length(d)]));
  end;
end;

function KindExtension(const d: TBytes): string;
begin
  Result := 'png';
  if (Length(d) >= 2) and (d[0] = $8A) and (d[1] = Ord('M')) then Result := 'mng';
  if (Length(d) >= 2) and (d[0] = $8B) and (d[1] = Ord('J')) then Result := 'jng';
end;

procedure DoExtract(const f: string; single: Boolean);
var d, orig: TBytes; desc: TDescriptor; e: TFormatError; detail, ext, o: string;
begin
  if not ReadAll(f, d) then Exit;
  e := Unpack(d, maxOut, orig, desc, detail);
  if e <> feNone then begin
    if detail <> '' then Err(f + ': ' + FormatErrorText(e) + ' (' + detail + ')')
    else Err(f + ': ' + FormatErrorText(e));
    Exit;
  end;
  ext := desc.ext;
  if ext = '' then ext := KindExtension(orig);
  o := OutputName(f, ext, single);
  if not WriteAll(o, orig) then Exit;
  if not quiet then Writeln(f, ' -> ', o, ': ', SizeText(Length(orig)), ' bytes, verified');
end;

procedure DoList(const f: string);
var d: TBytes; desc: TDescriptor; e: TFormatError; i: Integer; h: string;
begin
  if not ReadAll(f, d) then Exit;
  e := Inspect(d, desc);
  if e <> feNone then begin Err(f + ': ' + FormatErrorText(e)); Exit; end;
  h := '';
  for i := 0 to 15 do h := h + LowerCase(IntToHex(desc.hash[i], 2));
  if desc.stored then
    Writeln(f, ': ', desc.origSize, ' bytes stored, .', desc.ext, ', BLAKE3-128 ', h)
  else
    Writeln(f, ': ', desc.origSize, ' -> ', desc.payloadLen, ' bytes, .', desc.ext, ', BLAKE3-128 ', h);
end;

function ParseSize(const s: string; out v: QWord): Boolean;
var n: string; mul: QWord; x: Int64;
begin
  n := s; mul := 1;
  if (n <> '') and (UpCase(n[Length(n)]) in ['K', 'M', 'G']) then begin
    case UpCase(n[Length(n)]) of 'K': mul := 1024; 'M': mul := 1024 * 1024; 'G': mul := 1024 * 1024 * 1024; end;
    Delete(n, Length(n), 1);
  end;
  Result := TryStrToInt64(n, x) and (x >= 0);
  if Result then v := QWord(x) * mul;
end;

var
  cmd, a: string; files: TStringList; i: Integer; endOpts: Boolean;
begin
  if ParamCount < 1 then begin Usage; Halt(2); end;
  cmd := ParamStr(1);
  if (cmd = '--version') or (cmd = '-V') then begin Writeln('ppa ', VERSION, ' (stream version ', STREAM_VERSION, ', format version ', FORMAT_VERSION, ')'); Halt(0); end;
  if (cmd = '-h') or (cmd = '--help') then begin Usage; Halt(0); end;
  if (cmd <> 'a') and (cmd <> 'x') and (cmd <> 'list') then begin Usage; Halt(2); end;
  files := TStringList.Create;
  endOpts := False;
  i := 2;
  while i <= ParamCount do begin
    a := ParamStr(i);
    if endOpts or (a = '') or (a[1] <> '-') then files.Add(a)
    else if a = '--' then endOpts := True
    else if a = '-o' then begin Inc(i); if i > ParamCount then begin Usage; Halt(2); end; outPath := ParamStr(i); end
    else if Copy(a, 1, 13) = '--output-dir=' then outDir := Copy(a, 14, MaxInt)
    else if (a = '-f') or (a = '--force') then force := True
    else if (a = '-q') or (a = '--quiet') then quiet := True
    else if (a = '-n') or (a = '--dry-run') then dryRun := True
    else if a = '--no-verify' then noVerify := True
    else if Copy(a, 1, 13) = '--max-output=' then begin
      if not ParseSize(Copy(a, 14, MaxInt), maxOut) then begin Writeln(StdErr, 'ppa: bad size: ', a); Halt(2); end;
    end else begin Writeln(StdErr, 'ppa: unknown option: ', a); Halt(2); end;
    Inc(i);
  end;
  if files.Count = 0 then begin Usage; Halt(2); end;
  if (outPath <> '') and (files.Count > 1) and not DirectoryExists(outPath) then begin
    Writeln(StdErr, 'ppa: -o with several inputs must be a directory'); Halt(2);
  end;
  for i := 0 to files.Count - 1 do
    if cmd = 'a' then DoCompress(files[i], files.Count = 1)
    else if cmd = 'x' then DoExtract(files[i], files.Count = 1)
    else DoList(files[i]);
  if failures > 0 then Halt(1);
end.
