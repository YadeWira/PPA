{ fuzz_decode: one input through PPA's decoder, for a fuzzer (AFL++ in qemu
  mode; pas/tests/fuzz/run.sh) and for reproducing what it found.

    fuzz_decode ppa    <file>   a .ppa: ppaformat.Unpack (the header, then
                                ppacodec.DecompressEx on the codec stream)
    fuzz_decode stream <file>   a bare codec stream: ppacodec.DecompressEx
    fuzz_decode filter <file>   a PPAF stream: ppafilter.c's decoder, each
                                file's stream through DecompressEx, on this
                                thread (the pool runs a job when it is
                                submitted)

  Exit 0 whether the input decoded or was refused: a refusal is the right
  answer to a damaged input. What is a finding: a crash (a fault, or
  ppafuzzhook's SIGABRT on an exception that is a bug), a guard-page fault
  of ppaguardheap (exit 86: AFL_CRASH_EXITCODE=86), a hang.

  Build it with ppafuzzhook (and ppaguardheap) first in the uses, as run.sh
  does: fpc -Fappaguardheap,ppafuzzhook. PPA_NOC=1: the Pascal paths instead
  of the C ones. Output is capped at MAX_OUT. }
program fuzz_decode;

{$mode objfpc}{$H+}

uses
  SysUtils, ppacodec, ppaformat, ppasysinfo, pjamodel;

{$L ppafilter.o}

const
  MAX_OUT = 64 * 1024 * 1024;

type
  {$packrecords c}
  TJob = record
    input: PByte;
    size, expected: SizeUInt;
    output: PByte;
    outSize: SizeUInt;
    ok, threads: LongInt;
    done: LongInt;
    cause: LongInt;
  end;
  PJob = ^TJob;
  THost = record
    alloc: function(size: SizeUInt): Pointer; cdecl;
    release: procedure(p: Pointer); cdecl;
    poolOpen: function(threads, packing: LongInt): Pointer; cdecl;
    poolSubmit: procedure(pool: Pointer; job: PJob); cdecl;
    poolWait: procedure(pool: Pointer; job: PJob); cdecl;
    poolClose: procedure(pool: Pointer); cdecl;
  end;
  {$packrecords default}
  TReadFn = function(ctx, buf: Pointer; size: SizeUInt): PtrInt; cdecl;
  TWriteFn = function(ctx: Pointer; buf: Pointer; size: SizeUInt): LongInt; cdecl;

procedure ppafilter_host(constref h: THost); cdecl; external;
function ppafilter_decode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
  threads: LongInt): LongInt; cdecl; external;

var
  input: TBytes;
  inPos: SizeInt;
  outTotal: QWord;

function HostAlloc(size: SizeUInt): Pointer; cdecl;
begin
  try
    Result := GetMem(size);
  except
    Result := nil;
  end;
end;

procedure HostRelease(p: Pointer); cdecl;
begin
  FreeMem(p);
end;

function PoolOpen(threads, packing: LongInt): Pointer; cdecl;
begin
  Result := Pointer(1);
end;

{ the job runs now, as ppalib's RunJob decodes one }
procedure PoolSubmit(pool: Pointer; job: PJob); cdecl;
var b, inb: TBytes; why: string; fail: TDecodeFailure;
begin
  job^.output := nil; job^.outSize := 0; job^.ok := 0; job^.cause := 0;
  try
    inb := nil; SetLength(inb, job^.size);
    if job^.size > 0 then Move(job^.input^, inb[0], job^.size);
    if job^.expected > MAX_OUT then Exit;
    if not DecompressEx(inb, Int64(job^.expected), b, why, fail, 1) then begin
      if fail = dfFuture then job^.cause := 1 else if fail = dfMemory then job^.cause := 2;
      Exit;
    end;
    job^.outSize := Length(b);
    job^.output := GetMem(job^.outSize + 1);
    if job^.outSize > 0 then Move(b[0], job^.output^, job^.outSize);
    job^.ok := 1;
  except
    on EOutOfMemory do job^.cause := 2;
  end;
  job^.done := 1;
end;

procedure PoolWait(pool: Pointer; job: PJob); cdecl;
begin
end;

procedure PoolClose(pool: Pointer); cdecl;
begin
end;

function ReadIn(ctx, buf: Pointer; size: SizeUInt): PtrInt; cdecl;
var n: SizeInt;
begin
  n := Length(input) - inPos;
  if SizeUInt(n) > size then n := size;
  if n > 0 then Move(input[inPos], buf^, n);
  Inc(inPos, n);
  Result := n;
end;

function WriteOut(ctx: Pointer; buf: Pointer; size: SizeUInt): LongInt; cdecl;
begin
  Inc(outTotal, size);
  if outTotal > 4 * QWord(MAX_OUT) then Exit(1);
  Result := 0;
end;

function ReadFile(const name: string): TBytes;
var f: THandle; n: Int64;
begin
  Result := nil;
  f := FileOpen(name, fmOpenRead or fmShareDenyNone);
  if f = THandle(-1) then begin WriteLn(StdErr, 'fuzz_decode: cannot open ', name); Halt(2); end;
  n := FileSeek(f, Int64(0), fsFromEnd);
  FileSeek(f, 0, fsFromBeginning);
  SetLength(Result, n);
  if (n > 0) and (FileRead(f, Result[0], n) <> n) then begin WriteLn(StdErr, 'fuzz_decode: short read'); Halt(2); end;
  FileClose(f);
end;

var
  mode, why: string; host: THost; data: TBytes; d: TDescriptor; e: TFormatError;
  fail: TDecodeFailure; ok: Boolean; rc: LongInt;
begin
  if ParamCount < 2 then begin WriteLn(StdErr, 'usage: fuzz_decode ppa|stream|filter <file>'); Halt(2); end;
  ResetTestSettings;
  if GetEnvironmentVariable('PPA_NOC') = '1' then SetCodePath(cpPascal) else SetCodePath(cpC);
  mode := ParamStr(1);
  input := ReadFile(ParamStr(2));
  if mode = 'ppa' then begin
    e := Unpack(input, MAX_OUT, data, d, why, 1);
    WriteLn(FormatErrorText(e), ' ', Length(data), ' ', why);
  end else if mode = 'stream' then begin
    ok := DecompressEx(input, MAX_OUT, data, why, fail, 1);
    WriteLn(ok, ' ', Length(data), ' ', why);
  end else if mode = 'filter' then begin
    host.alloc := @HostAlloc; host.release := @HostRelease;
    host.poolOpen := @PoolOpen; host.poolSubmit := @PoolSubmit;
    host.poolWait := @PoolWait; host.poolClose := @PoolClose;
    ppafilter_host(host);
    inPos := 0; outTotal := 0;
    rc := ppafilter_decode(@ReadIn, nil, @WriteOut, nil, 1);
    WriteLn(rc, ' ', outTotal);
  end else begin WriteLn(StdErr, 'fuzz_decode: no mode ', mode); Halt(2); end;
  ReleaseThreadModels;
end.
