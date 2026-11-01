{ The ppa command (doc/CLI.md).

    ppa a [options] FILE...    image.png -> image.ppa
    ppa x [options] FILE...    image.ppa -> image.png (the original's extension)
    ppa list FILE...           what each .ppa holds

  Nothing is written under an output's name unless it verified: `a`
  decompresses its own stream and compares (unless --no-verify), `x` checks
  the size and the hash; and the output goes to a temporary name first,
  renamed only when complete. An existing output is not replaced without
  -f. Several files go to several threads (-th), and each file's lines
  come out in the order of the inputs. Exit status: 0 every file went
  through, 1 any failed, 2 usage. }
program ppa;

{$I ppa.inc}

uses
  {$ifdef UNIX} cthreads, {$endif}
  SysUtils, Classes, ppaformat, ppablake3, ppacodec, ppacpu;

const
  VERSION = '0.1.0';

type
  { a file to do, and what it says, printed when every file before it is done }
  TJob = record
    name: string;
    outText, errText: string;
    failed, done: Boolean;
  end;

var
  cmd, outPath, outDir: string;
  force, quiet, dryRun, noVerify: Boolean;
  maxOut: QWord = 256 * 1024 * 1024;
  threads: Integer;
  jobs: array of TJob;
  nextJob, nextPrint, failures: LongInt;
  printLock: TRTLCriticalSection;

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
  Writeln('  -th N, --threads=N threads (default: the processors, up to 8), one file each');
  Writeln('  --no-verify        a: do not decompress the result to check it first');
  Writeln('  --max-output=SIZE  x: refuse a declared original above SIZE (256M; K/M/G; 0 = none)');
  Writeln('  -n, --dry-run      do everything but write');
  Writeln('  -q, --quiet        only errors');
  Writeln('  --version');
end;

procedure Say(var j: TJob; const s: string);
begin
  if not quiet then j.outText := j.outText + s + LineEnding;
end;

procedure Err(var j: TJob; const s: string);
begin
  j.failed := True;
  j.errText := j.errText + 'ppa: ' + s + LineEnding;
end;

function ReadAll(var j: TJob; const f: string; out d: TBytes): Boolean;
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
    on e: Exception do Err(j, f + ': cannot read: ' + e.Message);
  end;
end;

{ To a temporary name next to it, then renamed: a half-written output never
  has the output's name. }
function WriteAll(var j: TJob; const f: string; const d: TBytes): Boolean;
var s: TFileStream; tmp: string;
begin
  Result := False;
  if FileExists(f) and not force then begin Err(j, f + ': exists (use -f to replace it)'); Exit; end;
  if dryRun then Exit(True);
  tmp := f + '.ppa-tmp' + IntToStr(GetProcessID) + '-' + IntToStr(PtrUInt(GetThreadID) mod 1000000);
  try
    s := TFileStream.Create(tmp, fmCreate);
    try
      if Length(d) > 0 then s.WriteBuffer(d[0], Length(d));
    finally s.Free; end;
    if FileExists(f) then DeleteFile(f);
    if not RenameFile(tmp, f) then begin DeleteFile(tmp); Err(j, f + ': cannot rename the output into place'); Exit; end;
    Result := True;
  except
    on e: Exception do begin
      if FileExists(tmp) then DeleteFile(tmp);
      Err(j, f + ': cannot write: ' + e.Message);
    end;
  end;
end;

function OutputName(const input, newExt: string; single: Boolean): string;
var stem: string;
begin
  stem := ChangeFileExt(ExtractFileName(input), '');
  if newExt <> '' then stem := stem + '.' + newExt;
  if (outPath <> '') and single and not DirectoryExists(outPath) and
     not (outPath[Length(outPath)] in ['/', '\']) then Exit(outPath);
  if outPath <> '' then Exit(IncludeTrailingPathDelimiter(outPath) + stem);
  if outDir <> '' then Exit(IncludeTrailingPathDelimiter(outDir) + stem);
  if ExtractFilePath(input) = '' then Result := stem
  else Result := IncludeTrailingPathDelimiter(ExtractFilePath(input)) + stem;
end;

procedure DoCompress(var j: TJob; single: Boolean);
var d, p: TBytes; stored: Boolean; why, o, ext: string;
begin
  if not ReadAll(j, j.name, d) then Exit;
  ext := ExtractFileExt(j.name);
  if (ext <> '') and (ext[1] = '.') then Delete(ext, 1, 1);
  if not Pack(d, ext, not noVerify, p, stored, why) then begin Err(j, j.name + ': ' + why); Exit; end;
  if stored and (Pos('bug', why) > 0) then Err(j, j.name + ': ' + why + ' (stored as it is)');
  o := OutputName(j.name, 'ppa', single);
  if not WriteAll(j, o, p) then Exit;
  if stored then
    Say(j, j.name + ' -> ' + o + ': stored, ' + IntToStr(Length(d)) + ' -> ' + IntToStr(Length(p)) + ' (' + why + ')')
  else
    Say(j, j.name + ' -> ' + o + ': ' + IntToStr(Length(d)) + ' -> ' + IntToStr(Length(p)) +
      Format(' (%.2f%%)', [100 * Length(p) / Length(d)]));
end;

function KindExtension(const d: TBytes): string;
begin
  Result := 'png';
  if (Length(d) >= 2) and (d[0] = $8A) and (d[1] = Ord('M')) then Result := 'mng';
  if (Length(d) >= 2) and (d[0] = $8B) and (d[1] = Ord('J')) then Result := 'jng';
end;

procedure DoExtract(var j: TJob; single: Boolean);
var d, orig: TBytes; desc: TDescriptor; e: TFormatError; detail, ext, o: string;
begin
  if not ReadAll(j, j.name, d) then Exit;
  e := Unpack(d, maxOut, orig, desc, detail);
  if e <> feNone then begin
    if detail <> '' then Err(j, j.name + ': ' + FormatErrorText(e) + ' (' + detail + ')')
    else Err(j, j.name + ': ' + FormatErrorText(e));
    Exit;
  end;
  ext := desc.ext;
  if ext = '' then ext := KindExtension(orig);
  o := OutputName(j.name, ext, single);
  if not WriteAll(j, o, orig) then Exit;
  Say(j, j.name + ' -> ' + o + ': ' + IntToStr(Length(orig)) + ' bytes, verified');
end;

procedure DoList(var j: TJob);
var d: TBytes; desc: TDescriptor; e: TFormatError; i: Integer; h: string;
begin
  if not ReadAll(j, j.name, d) then Exit;
  e := Inspect(d, desc);
  if e <> feNone then begin Err(j, j.name + ': ' + FormatErrorText(e)); Exit; end;
  h := '';
  for i := 0 to 15 do h := h + LowerCase(IntToHex(desc.hash[i], 2));
  { list prints even with -q: it is what was asked for }
  if desc.stored then
    j.outText := j.outText + Format('%s: %d bytes stored, .%s, BLAKE3-128 %s', [j.name, desc.origSize, desc.ext, h]) + LineEnding
  else
    j.outText := j.outText + Format('%s: %d -> %d bytes, .%s, BLAKE3-128 %s', [j.name, desc.origSize, desc.payloadLen, desc.ext, h]) + LineEnding;
end;

procedure RunJob(k: Integer);
var single: Boolean;
begin
  single := Length(jobs) = 1;
  try
    if cmd = 'a' then DoCompress(jobs[k], single)
    else if cmd = 'x' then DoExtract(jobs[k], single)
    else DoList(jobs[k]);
  except
    on e: Exception do Err(jobs[k], jobs[k].name + ': ' + e.ClassName + ': ' + e.Message);
  end;
  { print every finished file whose turn it is, in the order of the inputs }
  EnterCriticalSection(printLock);
  try
    jobs[k].done := True;
    if jobs[k].failed then Inc(failures);
    while (nextPrint < Length(jobs)) and jobs[nextPrint].done do begin
      if jobs[nextPrint].outText <> '' then Write(jobs[nextPrint].outText);
      if jobs[nextPrint].errText <> '' then Write(StdErr, jobs[nextPrint].errText);
      jobs[nextPrint].outText := ''; jobs[nextPrint].errText := '';
      Inc(nextPrint);
    end;
  finally
    LeaveCriticalSection(printLock);
  end;
end;

procedure Work;
var k: LongInt;
begin
  repeat
    k := InterLockedIncrement(nextJob) - 1;
    if k >= Length(jobs) then Break;
    RunJob(k);
  until False;
end;

type
  TWorker = class(TThread)
    procedure Execute; override;
  end;

procedure TWorker.Execute;
begin
  Work;
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

procedure UsageError(const s: string);
begin
  Writeln(StdErr, 'ppa: ', s);
  Halt(2);
end;

var
  a, v: string; files: TStringList; i, n, workers: Integer; endOpts: Boolean;
  pool: array of TWorker;
begin
  if ParamCount < 1 then begin Usage; Halt(2); end;
  cmd := ParamStr(1);
  if (cmd = '--version') or (cmd = '-V') then begin
    Writeln('ppa ', VERSION, ' (stream version ', STREAM_VERSION, ', format version ', FORMAT_VERSION, ')'); Halt(0);
  end;
  if (cmd = '-h') or (cmd = '--help') then begin Usage; Halt(0); end;
  if (cmd <> 'a') and (cmd <> 'x') and (cmd <> 'list') then begin Usage; Halt(2); end;
  threads := CpuCount;
  if threads > 8 then threads := 8;
  files := TStringList.Create;
  endOpts := False;
  i := 2;
  while i <= ParamCount do begin
    a := ParamStr(i);
    if endOpts or (a = '') or (a[1] <> '-') then files.Add(a)
    else if a = '--' then endOpts := True
    else if a = '-o' then begin Inc(i); if i > ParamCount then UsageError('-o needs a path'); outPath := ParamStr(i); end
    else if Copy(a, 1, 13) = '--output-dir=' then outDir := Copy(a, 14, MaxInt)
    else if (a = '-f') or (a = '--force') then force := True
    else if (a = '-q') or (a = '--quiet') then quiet := True
    else if (a = '-n') or (a = '--dry-run') then dryRun := True
    else if a = '--no-verify' then noVerify := True
    else if (a = '-th') or (Copy(a, 1, 10) = '--threads=') then begin
      if a = '-th' then begin Inc(i); if i > ParamCount then UsageError('-th needs a number'); v := ParamStr(i); end
      else v := Copy(a, 11, MaxInt);
      if not TryStrToInt(v, n) or (n < 1) or (n > 64) then UsageError('threads: a number from 1 to 64, not "' + v + '"');
      threads := n;
    end
    else if Copy(a, 1, 13) = '--max-output=' then begin
      if not ParseSize(Copy(a, 14, MaxInt), maxOut) then UsageError('bad size: ' + a);
    end else UsageError('unknown option: ' + a);
    Inc(i);
  end;
  if files.Count = 0 then begin Usage; Halt(2); end;
  if (outPath <> '') and (files.Count > 1) and not DirectoryExists(outPath) then
    UsageError('-o with several inputs must be a directory');

  jobs := nil;
  SetLength(jobs, files.Count);
  for i := 0 to files.Count - 1 do begin
    jobs[i] := Default(TJob);
    jobs[i].name := files[i];
  end;
  { the threads go to files first, and what is left to each file's image
    streams (zlib's parameters and deflate streams) }
  workers := threads;
  if workers > files.Count then workers := files.Count;
  if workers < 1 then workers := 1;
  CodecThreads := threads div workers;
  nextJob := 0; nextPrint := 0; failures := 0;
  InitCriticalSection(printLock);
  pool := nil;
  SetLength(pool, workers - 1);
  for i := 0 to High(pool) do pool[i] := TWorker.Create(False);
  Work;
  for i := 0 to High(pool) do begin pool[i].WaitFor; pool[i].Free; end;
  DoneCriticalSection(printLock);
  if failures > 0 then begin
    if files.Count > 1 then Writeln(StdErr, 'ppa: ', failures, ' of ', files.Count, ' files failed');
    Halt(1);
  end;
end.
