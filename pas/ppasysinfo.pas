{ What the command says about itself and the machine: its version and
  commit, the compilers, the target, the system, the processor, and the
  code path its hot loops take (--version, report, bench, selftest), and
  --path, which chooses that path. From PJA 0.9.7 (pas/pjasysinfo.pas),
  with PPA's paths.

  The paths: every hot loop of PPA is in C (ppa*c.c: zlib's matches, the
  deflate tokens, the filters, the three models), with SSE2 or NEON where
  the build has them, and in Pascal, the reference each C loop is checked
  against. Both give the same bits (the suite and selftest check it); only
  the speed changes. c is the default; pascal (or PPA_NOC=1) takes the
  references. The JPEG inside a JNG goes through PJA's codec (vendor/pja),
  whose model takes SSE4.1 and AVX2 by cpuid (PJA_NOASM=1, PJA_NOAVX2=1). }
unit ppasysinfo;

{$I ppa.inc}
{$ifopt R-}{$fatal ppasysinfo: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppasysinfo: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, ppainfo;

type
  TCodePath = (cpC, cpPascal);

const
  VERSION = '0.2.0';
  CODE_PATH_NAMES: array[TCodePath] of string = ('c', 'pascal');
  ISSUES_URL = 'https://github.com/YadeWira/PPA/issues';

var
  { set by the program, which is compiled every time: a unit's .ppu would
    keep an old commit }
  BuildCommit: string = '';
  BuildDate: string = '';

function ParseCodePath(const s: string; out p: TCodePath): Boolean;
function CurrentCodePath: TCodePath;
{ every hot loop to the C or to the Pascal; only while no file is being
  worked on }
procedure SetCodePath(p: TCodePath);

{ "x86_64-linux" }
function TargetName: string;
function FpcVersion: string;
function CCompiler: string;
{ the C loops' vector code: "sse2" }
function CSimd: string;
{ the processor's name, as it gives it ('' when it does not) }
function CpuName: string;
{ what PJA's JPEG model (a JNG's JPEG) takes: "sse4.1 avx2", or "plain" }
function JpegSimd: string;
{ the system, as it names itself: "Linux 6.12.1 x86_64", "Windows 10.0 build 19045" }
function SystemName: string;
{ the threads by default: the processors, up to 8 }
function DefaultThreads: Integer;

{ everything above, as fields of n }
procedure DescribeSystem(n: TInfoNode);
{ one block of text, "name: value" a line, for --version, report and bench;
  withVersion: the first line PPA's version }
function SystemText(withVersion: Boolean): string;

implementation

uses
  {$ifdef UNIX} BaseUnix, {$endif}
  {$ifdef MSWINDOWS} Windows, {$endif}
  Classes, ppacpu, ppacodec, ppaformat, ppafast, ppastatic, ppamodel, ppazlib, ppapixels, ppadeflate;

{$L ppasysc.o}
function ppasys_cc: PChar; cdecl; external;
function ppasys_simd: PChar; cdecl; external;

function ParseCodePath(const s: string; out p: TCodePath): Boolean;
var q: TCodePath;
begin
  for q := Low(TCodePath) to High(TCodePath) do
    if LowerCase(s) = CODE_PATH_NAMES[q] then begin p := q; Exit(True); end;
  p := cpC;
  Result := False;
end;

function CurrentCodePath: TCodePath;
begin
  if UseFastC then Result := cpC else Result := cpPascal;
end;

procedure SetCodePath(p: TCodePath);
var c: Boolean;
begin
  c := p = cpC;
  UseFastC := c; UseStaticC := c; ppamodel.UseC := c; UseZlibC := c; UsePixC := c; UseDeflateC := c;
end;

function TargetName: string;
begin
  Result := LowerCase({$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%});
end;

function FpcVersion: string;
begin
  Result := {$I %FPCVERSION%};
end;

function CCompiler: string;
begin
  Result := StrPas(ppasys_cc);
end;

function CSimd: string;
begin
  Result := StrPas(ppasys_simd);
end;

{$ifdef CPUX86_64}
{$asmmode intel}
procedure CpuId(leaf, sub: LongWord; out a, b, c, d: LongWord);
var ra, rb, rc, rd: LongWord;
begin
  asm
    push rbx
    mov eax, leaf
    mov ecx, sub
    cpuid
    mov ra, eax
    mov rb, ebx
    mov rc, ecx
    mov rd, edx
    pop rbx
  end ['rax', 'rcx', 'rdx'];
  a := ra; b := rb; c := rc; d := rd;
end;

function XGetBv0: LongWord;
var r: LongWord;
begin
  asm
    xor ecx, ecx
    xgetbv
    mov r, eax
  end ['rax', 'rcx', 'rdx'];
  Result := r;
end;
{$endif}

{$ifdef CPUI386}
{$asmmode intel}
{ cpuid on 32-bit x86, for the processor's name only (ebx kept: a
  position-independent library keeps its GOT there) }
procedure CpuId(leaf, sub: LongWord; out a, b, c, d: LongWord);
var ra, rb, rc, rd: LongWord;
begin
  asm
    push ebx
    mov eax, leaf
    mov ecx, sub
    cpuid
    mov ra, eax
    mov rb, ebx
    mov rc, ecx
    mov rd, edx
    pop ebx
  end ['eax', 'ecx', 'edx'];
  a := ra; b := rb; c := rc; d := rd;
end;
{$endif}

function HasSse41: Boolean;
{$ifdef CPUX86_64} var a, b, c, d: LongWord; {$endif}
begin
  Result := False;
  {$ifdef CPUX86_64}
  CpuId(1, 0, a, b, c, d);
  Result := c and (1 shl 19) <> 0;
  {$endif}
end;

{ AVX2, and the system saving the 256-bit registers }
function HasAvx2: Boolean;
{$ifdef CPUX86_64} var a, b, c, d, top: LongWord; {$endif}
begin
  Result := False;
  {$ifdef CPUX86_64}
  CpuId(0, 0, top, b, c, d);
  if top < 7 then Exit;
  CpuId(1, 0, a, b, c, d);
  if (c and (1 shl 27) = 0) or (c and (1 shl 28) = 0) then Exit;
  if XGetBv0 and 6 <> 6 then Exit;
  CpuId(7, 0, a, b, c, d);
  Result := b and (1 shl 5) <> 0;
  {$endif}
end;

function CpuName: string;
{$if defined(CPUX86_64) or defined(CPUI386)} var b, c, d, top: LongWord; leaf: LongWord; i: Integer; regs: array[0..3] of LongWord;
                   raw: array[0..47] of Char; {$endif}
{$ifdef LINUX} var f: TStringList; k: Integer; {$endif}
begin
  Result := '';
  {$if defined(CPUX86_64) or defined(CPUI386)}
  CpuId($80000000, 0, top, b, c, d);
  if top >= $80000004 then begin
    for leaf := $80000002 to $80000004 do begin
      CpuId(leaf, 0, regs[0], regs[1], regs[2], regs[3]);
      for i := 0 to 3 do Move(regs[i], raw[(leaf - $80000002) * 16 + i * 4], 4);
    end;
    for i := 0 to 47 do
      if raw[i] = #0 then Break
      else if raw[i] in [#32..#126] then Result := Result + raw[i];
    Result := Trim(Result);
  end;
  {$endif}
  {$ifdef LINUX}
  if Result = '' then begin
    f := TStringList.Create;
    try
      try
        f.LoadFromFile('/proc/cpuinfo');
        for k := 0 to f.Count - 1 do
          if (Pos('model name', f[k]) = 1) or (Pos('Model', f[k]) = 1) or (Pos('Hardware', f[k]) = 1) then begin
            Result := Trim(Copy(f[k], Pos(':', f[k]) + 1, MaxInt));
            if Result <> '' then Break;
          end;
      except
        Result := '';
      end;
    finally
      f.Free;
    end;
  end;
  {$endif}
end;

{ as pjamodel decides it when it starts (vendor/pja: its UseSse41 and
  UseAvx2, which it does not export) }
function JpegSimd: string;
var sse41: Boolean;
begin
  Result := '';
  sse41 := HasSse41 and (SysUtils.GetEnvironmentVariable('PJA_NOASM') <> '1');
  if sse41 then Result := 'sse4.1';
  if sse41 and HasAvx2 and (SysUtils.GetEnvironmentVariable('PJA_NOAVX2') <> '1') then Result := Result + ' avx2';
  if Result = '' then Result := 'plain';
end;

{$ifdef MSWINDOWS}
type
  { RTL_OSVERSIONINFOW is OSVERSIONINFOW }
  TRtlGetVersion = function(var v: TOSVersionInfoW): LongInt; stdcall;
{$endif}

function SystemName: string;
{$ifdef UNIX} var u: UtsName; {$endif}
{$ifdef MSWINDOWS} var v: TOSVersionInfoA; w: TOSVersionInfoW; get: TRtlGetVersion; {$endif}
begin
  Result := '';
  {$ifdef UNIX}
  if fpUname(u) = 0 then
    Result := StrPas(PChar(@u.sysname[0])) + ' ' + StrPas(PChar(@u.release[0])) + ' ' + StrPas(PChar(@u.machine[0]));
  {$endif}
  {$ifdef MSWINDOWS}
  FillChar(v, SizeOf(v), 0);
  v.dwOSVersionInfoSize := SizeOf(v);
  FillChar(w, SizeOf(w), 0);
  w.dwOSVersionInfoSize := SizeOf(w);
  { GetVersionEx says 6.2 on any Windows past 8 to a program without a
    manifest: ntdll's RtlGetVersion tells the truth (on XP too) }
  get := TRtlGetVersion(GetProcAddress(GetModuleHandle('ntdll.dll'), 'RtlGetVersion'));
  if (@get <> nil) and (get(w) = 0) then begin
    v.dwMajorVersion := w.dwMajorVersion; v.dwMinorVersion := w.dwMinorVersion; v.dwBuildNumber := w.dwBuildNumber;
  end;
  if (w.dwMajorVersion <> 0) or GetVersionExA(@v) then
    Result := 'Windows ' + IntToStr(v.dwMajorVersion) + '.' + IntToStr(v.dwMinorVersion) + ' build ' +
              IntToStr(v.dwBuildNumber)
  else Result := 'Windows';
  {$endif}
  if Result = '' then Result := {$I %FPCTARGETOS%};
end;

function DefaultThreads: Integer;
begin
  Result := CpuCount;
  if Result > 8 then Result := 8;
  if Result < 1 then Result := 1;
end;

procedure DescribeSystem(n: TInfoNode);
begin
  n.Str('ppa', VERSION);
  n.Num('stream_version', STREAM_VERSION);
  n.Num('format_version', FORMAT_VERSION);
  n.Str('commit', BuildCommit);
  n.Str('built', BuildDate);
  n.Str('fpc', FpcVersion);
  n.Str('c_compiler', CCompiler);
  n.Str('c_simd', CSimd);
  n.Str('target', TargetName);
  n.Str('system', SystemName);
  n.Str('cpu', CpuName);
  n.Str('code_path', CODE_PATH_NAMES[CurrentCodePath]);
  n.Str('jpeg_model_simd', JpegSimd);
  n.Num('processors', CpuCount);
  n.Num('default_threads', DefaultThreads);
end;

function SystemText(withVersion: Boolean): string;
var n: TInfoNode; sl: TStringList; k: Integer;
begin
  Result := '';
  n := TInfoNode.Create(ikObject);
  sl := TStringList.Create;
  try
    DescribeSystem(n);
    n.Render(sl);
    for k := 0 to sl.Count - 1 do
      if withVersion or (k > 0) then Result := Result + sl[k] + LineEnding;
  finally
    sl.Free;
    n.Free;
  end;
end;

end.
