{ ppa selftest (doc/CLI.md): the samples inside the binary (ppaselftest.inc,
  written by tools/gen_selftest.py: each colour type the models take, a
  palette, 16 bits, Adam7, an APNG, an MNG and two JNG, some with a model
  forced so that the static, fast and slow models all run) compressed and
  extracted on both code paths (the C loops and their Pascal references,
  ppasysinfo), with one thread and with two. Each .ppa has to be the very
  bytes the include names (size and BLAKE3-128), on every path, and each
  has to come back as its sample. A build that a compiler, a platform or a
  machine got wrong says so here. From PJA 0.9.7 (pas/pjaselftest.pas). }
unit ppaselftest;

{$I ppa.inc}
{$ifopt R-}{$fatal ppaselftest: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppaselftest: overflow checks ($Q+) are mandatory}{$endif}

interface

uses ppasysinfo;

{ Prints a line per path and a summary (only failures and the summary with
  quiet). 0 when every check passed, 1 if not. onePath: only `only`
  (--path). }
function RunSelftest(quiet: Boolean; onePath: Boolean = False; only: TCodePath = cpC): Integer;

implementation

uses SysUtils, ppablake3, ppaformat, ppacodec, ppainfo;

{$I ppaselftest.inc}

function SameBytes(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

function RunSelftest(quiet: Boolean; onePath: Boolean; only: TCodePath): Integer;
const THREAD_COUNTS: array[0..1] of Integer = (1, 2);
var was, p: TCodePath; k, t, checks, failed, pathFailed, paths, wasModel: Integer; data, got, back: TBytes;
    stored, wasFast, wasKeep: Boolean; why, detail, names: string; desc: TDescriptor; e: TFormatError;
begin
  was := CurrentCodePath;
  wasModel := TestModel;
  wasFast := FastModel;
  wasKeep := TestKeepStream;
  checks := 0; failed := 0; paths := 0; names := '';
  if not quiet then begin
    if onePath then
      Writeln('ppa selftest: ', SELFTEST_COUNT, ' samples inside the binary, on the code path ',
              CODE_PATH_NAMES[only], ' (--path), with 1 and 2 threads')
    else
      Writeln('ppa selftest: ', SELFTEST_COUNT, ' samples inside the binary, on both code paths (c pascal),',
              ' with 1 and 2 threads');
    for k := 0 to SELFTEST_COUNT - 1 do begin
      SelftestSample(k, data);
      Writeln('  ', SELFTEST_NAMES[k], ': ', Length(data), ' B -> ', SELFTEST_PPA_SIZES[k], ' B, .ppa blake3-128 ',
              SELFTEST_PPA_HASHES[k]);
    end;
  end;
  try
    { the default model choice, whatever the command line said (--max) }
    FastModel := True;
    { each sample's stream, even where it is no smaller than the sample }
    TestKeepStream := True;
    for p := Low(TCodePath) to High(TCodePath) do begin
      if onePath and (p <> only) then Continue;
      Inc(paths);
      if names <> '' then names := names + ' ';
      names := names + CODE_PATH_NAMES[p];
      SetCodePath(p);
      pathFailed := 0;
      for k := 0 to SELFTEST_COUNT - 1 do begin
        SelftestSample(k, data);
        TestModel := SELFTEST_MODELS[k];
        for t := 0 to High(THREAD_COUNTS) do begin
          Inc(checks);
          why := '';
          if not Pack(data, SELFTEST_EXTS[k], True, got, stored, why, THREAD_COUNTS[t]) or stored then
            why := 'compress failed: ' + why
          else if (Length(got) <> SELFTEST_PPA_SIZES[k]) or (HexBytes(Blake3_128(got)) <> SELFTEST_PPA_HASHES[k]) then
            why := 'a different .ppa: ' + IntToStr(Length(got)) + ' B, blake3-128 ' + HexBytes(Blake3_128(got))
          else begin
            why := '';
            e := Unpack(got, QWord(Length(data)), back, desc, detail, THREAD_COUNTS[t]);
            if e <> feNone then why := 'extract failed: ' + FormatErrorText(e) + ' ' + detail
            else if not SameBytes(back, data) then why := 'extracted to other bytes';
          end;
          if why <> '' then begin
            Inc(failed); Inc(pathFailed);
            Writeln(StdErr, 'ppa: selftest: ', SELFTEST_NAMES[k], ' on ', CODE_PATH_NAMES[p], ' with ',
                    THREAD_COUNTS[t], ' thread(s): ', why);
          end;
        end;
      end;
      if not quiet then begin
        if pathFailed = 0 then Writeln('  path ', CODE_PATH_NAMES[p], ': ok')
        else Writeln('  path ', CODE_PATH_NAMES[p], ': ', pathFailed, ' FAILED');
      end;
    end;
  finally
    SetCodePath(was);
    TestModel := wasModel;
    FastModel := wasFast;
    TestKeepStream := wasKeep;
  end;
  if failed = 0 then begin
    Writeln('selftest: ', checks, ' of ', checks, ' checks passed on ', paths, ' path(s) (', names,
            '): every .ppa the expected bytes, every sample back');
    Result := 0;
  end else begin
    Writeln(StdErr, 'ppa: selftest: ', failed, ' of ', checks, ' checks FAILED. This is a bug in PPA: please run',
            ' ppa report and open an issue at ', ISSUES_URL);
    Result := 1;
  end;
end;

end.
