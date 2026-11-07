{ ppa bench (doc/CLI.md): how fast this machine compresses and extracts
  the given files. For each file, the best of N runs of: a (with the
  verification), a --no-verify, x; each in milliseconds and MB/s of the
  original, with where a's and x's time goes (ppastage). The .ppa is
  written to a folder of its own in the system's temporary folder, timed,
  and deleted: nothing is written beside the inputs. A .ppa given as input
  is only extracted. From PJA 0.9.7 (pas/pjabench.pas). }
unit ppabench;

{$I ppa.inc}
{$ifopt R-}{$fatal ppabench: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppabench: overflow checks ($Q+) are mandatory}{$endif}

interface

uses Classes;

{ 0 when every file went through, 1 if any failed }
function RunBench(files: TStrings; runs, threads: Integer): Integer;

implementation

uses SysUtils, ppablake3, ppaformat, ppafs, ppastage, ppasysinfo, ppainfo;

function Ms(t: Double): string;
begin
  Result := DotNumber(t * 1000, 2) + ' ms';
end;

function Rate(bytes: Int64; t: Double): string;
begin
  if t <= 0 then Exit('-');
  Result := DotNumber(bytes / (1024 * 1024) / t, 2) + ' MB/s';
end;

{ the stages that took time, "parse 1.20 ms, encode 3.40 ms" }
function StageText(const t: TStageTimes): string;
var s: TStage;
begin
  Result := '';
  for s := Succ(stNone) to High(TStage) do
    if t[s] > 0 then begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + STAGE_NAMES[s] + ' ' + Ms(t[s]);
    end;
end;

function ReadFile(const f: string; out d: TBytes; out msg: string): Boolean;
var s: TFileStream;
begin
  d := nil; msg := '';
  Result := False;
  try
    s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone);
    try
      if s.Size > High(LongInt) then begin msg := 'larger than 2 GiB'; Exit; end;
      SetLength(d, s.Size);
      if s.Size > 0 then s.ReadBuffer(d[0], s.Size);
    finally
      s.Free;
    end;
    Result := True;
  except
    on e: Exception do msg := e.Message;
  end;
end;

function RunBench(files: TStrings; runs, threads: Integer): Integer;
var k, run: Integer; d, ppa, back: TBytes; ok, stored: Boolean; why, detail: string; desc: TDescriptor;
    e: TFormatError; msg, tmp, path: string;
    t0, best, bestNv, bestX, bestW, tw: Double; st, stBest, stX, stXBest: TStageTimes;
    totalIn, totalInA: Int64; totalA, totalNv, totalX: Double; fr: TFsResult; o: TOutcome; givenPpa: Boolean;
    fails: Integer;
begin
  Result := 0;
  fails := 0;
  Writeln('ppa bench: the best of ', runs, ' run(s) of each; ', threads, ' thread(s) a file; MB = 2^20 bytes');
  Write(SystemText(True));
  Writeln;
  tmp := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'ppa-bench-' + IntToStr(GetProcessID);
  if not ForceDirectories(tmp) then begin
    Writeln(StdErr, 'ppa: bench: cannot make ', tmp);
    Exit(1);
  end;
  StagesOn := True;
  totalIn := 0; totalInA := 0; totalA := 0; totalNv := 0; totalX := 0;
  try
    for k := 0 to files.Count - 1 do begin
      if not ReadFile(files[k], d, msg) then begin
        Writeln(StdErr, 'ppa: ', files[k], ': ', msg); Inc(fails); Continue;
      end;
      givenPpa := ppaformat.IsPpa(d);
      ok := True; e := ppaformat.feNone; why := '';
      best := -1; bestNv := -1; bestX := -1; bestW := -1;
      stBest := Default(TStageTimes); stXBest := Default(TStageTimes);
      if givenPpa then ppa := d
      else begin
        for run := 1 to runs do begin
          StageReset;
          t0 := Seconds;
          ok := Pack(d, Copy(ExtractFileExt(files[k]), 2, MaxInt), True, ppa, stored, why, threads);
          t0 := Seconds - t0;
          st := StageTimes;
          if not ok then Break;
          if (best < 0) or (t0 < best) then begin best := t0; stBest := st; end;
          StageReset;
          t0 := Seconds;
          ok := Pack(d, Copy(ExtractFileExt(files[k]), 2, MaxInt), False, ppa, stored, why, threads);
          t0 := Seconds - t0;
          if not ok then Break;
          if (bestNv < 0) or (t0 < bestNv) then bestNv := t0;
          { the write, as a's: a temporary, verified, renamed }
          path := IncludeTrailingPathDelimiter(tmp) + 'bench.ppa';
          tw := Seconds;
          fr := WriteVerified(path, ppa, Blake3_128(ppa), omDelete, True, o);
          tw := Seconds - tw;
          DeleteFile(path);
          if fr.Ok and ((bestW < 0) or (tw < bestW)) then bestW := tw;
        end;
        if not ok then begin
          Writeln(StdErr, 'ppa: ', files[k], ': ', why); Inc(fails); Continue;
        end;
      end;
      for run := 1 to runs do begin
        StageReset;
        t0 := Seconds;
        e := Unpack(ppa, 0, back, desc, detail, threads);
        t0 := Seconds - t0;
        stX := StageTimes;
        if e <> ppaformat.feNone then Break;
        if (bestX < 0) or (t0 < bestX) then begin bestX := t0; stXBest := stX; end;
      end;
      if e <> ppaformat.feNone then begin
        Writeln(StdErr, 'ppa: ', files[k], ': ', FormatErrorText(e)); Inc(fails); Continue;
      end;
      Write(ExtractFileName(files[k]), ': ', Length(back), ' B -> ', Length(ppa), ' B');
      if Length(back) > 0 then Write(' (', DotNumber(100 * Length(ppa) / Length(back), 2), '%)');
      Writeln;
      if not givenPpa then begin
        Writeln('  a              ', Ms(best), '  ', Rate(Length(back), best), '  (', StageText(stBest), ')');
        Writeln('  a --no-verify  ', Ms(bestNv), '  ', Rate(Length(back), bestNv));
        { as a's: flushed to the disk before the rename, unless --no-sync
          (in the temporary directory's file system, often a tmpfs) }
        if bestW >= 0 then begin
          if SyncToDisk then Writeln('  write          ', Ms(bestW))
          else Writeln('  write          ', Ms(bestW), '  (--no-sync)');
        end;
        totalA := totalA + best; totalNv := totalNv + bestNv;
        Inc(totalInA, Length(back));
      end;
      Writeln('  x              ', Ms(bestX), '  ', Rate(Length(back), bestX), '  (', StageText(stXBest), ')');
      totalX := totalX + bestX;
      Inc(totalIn, Length(back));
    end;
  finally
    StagesOn := False;
    RemoveDir(tmp);
  end;
  if files.Count > 1 then begin
    Writeln('all: ', totalIn, ' B');
    if totalA > 0 then begin
      Writeln('  a              ', Ms(totalA), '  ', Rate(totalInA, totalA));
      Writeln('  a --no-verify  ', Ms(totalNv), '  ', Rate(totalInA, totalNv));
    end;
    Writeln('  x              ', Ms(totalX), '  ', Rate(totalIn, totalX));
  end;
  if fails > 0 then Result := 1;
end;

end.
