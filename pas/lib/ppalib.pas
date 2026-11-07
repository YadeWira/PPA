{ libppa: PPA as a shared library with a C interface (ppa.h), for archivers
  and other programs. Shaped as PJA's libpja (pas/lib/pjalib.pas).

    pas/lib/build.sh <out dir>   -> ppa.so / ppa.dll / ppa.dylib

  Built with the C part (pas/build_c.sh, position-independent), the filter
  (ppafilter.c) and the 7-Zip codec plugin (ppa7z.c). ppa_compress and
  ppa_decompress are ppaformat's Pack and Unpack (a .ppa); the filter is C,
  and calls back here for memory and for the codec on each file it finds
  (ppacodec's Compress and Decompress, the bare stream). The same file is a
  7-Zip / 7-Zip-zstd plugin: the functions 7-Zip looks for
  (GetNumberOfMethods, GetMethodProperty, CreateDecoder, CreateEncoder,
  CreateObject, GetModuleProp) are ppa7z.c's, exported from here.

  No exception leaves the library: every export catches them and returns
  an error code. The settings the command's tests take from the
  environment (PPA_TEST_*, PPA_NOC) are put back to their defaults when the
  library loads: a host's environment must not change PPA's streams. }
library ppa;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}{$ifdef windows}ppaheap,{$endif}
  Classes, SysUtils, ppacpu, ppaformat, ppacodec, ppasysinfo, ppastage, pjamodel;

{$L ppafilter.o}
{$L ppa7z.o}

const
  PPA_OK = 0;
  PPA_E_NOT_TAKEN = 1;
  PPA_E_DATA = 2;
  PPA_E_MEMORY = 3;
  PPA_E_ARG = 6;
  PPA_E_VERSION = 7;
  { ppa_decompress's own cap on an original's size }
  MAX_ORIGINAL = QWord(1) shl 31;
  VERSION_TEXT: PChar = 'ppa ' + VERSION;

type
  {$packrecords c}
  { ppafilter.c's job_t: a file to compress, or a stream to decompress }
  TJob = record
    input: PByte;
    size, expected: SizeUInt;
    output: PByte;
    outSize: SizeUInt;
    ok, threads: LongInt;
    done: LongInt;
    { decoding, not ok: 1 when the stream is of a later version (PPA_E_VERSION) }
    newer: LongInt;
  end;
  PJob = ^TJob;
  { ppafilter.c's host_t }
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
function ppafilter_encode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
  threads: LongInt): LongInt; cdecl; external;
function ppafilter_decode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
  threads: LongInt): LongInt; cdecl; external;

type
  { ppa7z.c's host7z_t }
  THost7z = record
    bstr: function(bytes: Pointer; len: LongWord): Pointer; cdecl;
    alloc: function(size: SizeUInt): Pointer; cdecl;
    release: procedure(p: Pointer); cdecl;
    threads: LongInt;
  end;
  { 7-Zip's calling convention for its exports and interfaces }
  HRESULT = LongInt;

procedure ppa7z_host(constref h: THost7z); cdecl; external;
function ppa7z_GetNumberOfMethods(n: PLongWord): HRESULT; cdecl; external;
function ppa7z_GetMethodProperty(index, prop: LongWord; v: Pointer): HRESULT; cdecl; external;
function ppa7z_CreateDecoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function ppa7z_CreateEncoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function ppa7z_CreateObject(clsid, iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function ppa7z_GetModuleProp(prop: LongWord; v: Pointer): HRESULT; cdecl; external;

{$ifdef windows}
function SysAllocStringByteLen(s: Pointer; len: LongWord): Pointer; stdcall; external 'oleaut32.dll';

function MakeBstr(bytes: Pointer; len: LongWord): Pointer; cdecl;
begin
  Result := SysAllocStringByteLen(bytes, len);
end;
{$else}
function malloc(size: SizeUInt): Pointer; cdecl; external 'c';

{ 7-Zip's BSTR outside Windows (CPP/Common/MyWindows.cpp): from malloc, a
  32-bit byte count, the bytes, and two zero bytes; 7-Zip frees it }
function MakeBstr(bytes: Pointer; len: LongWord): Pointer; cdecl;
var p: PByte;
begin
  p := malloc(SizeUInt(len) + 4 + 4);
  if p = nil then Exit(nil);
  PLongWord(p)^ := len;
  Result := p + 4;
  if len > 0 then Move(bytes^, Result^, len);
  FillChar((p + 4 + len)^, 4, 0);
end;
{$endif}

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

{ bytes -> a fresh buffer for the caller, nil when there is no memory; one
  byte more, so that an empty result is not a null pointer }
function Hand(const b: TBytes; out output: PByte; out outSize: SizeUInt): Boolean;
begin
  outSize := Length(b);
  output := HostAlloc(outSize + 1);
  Result := output <> nil;
  if Result and (outSize > 0) then Move(b[0], output^, outSize);
end;

function InBytes(input: PByte; size: SizeUInt): TBytes;
begin
  Result := nil;
  SetLength(Result, size);
  if size > 0 then Move(input^, Result[0], size);
end;

{ PJA's codec (a JNG's JPEG) keeps its models in threadvars, about 18 MB,
  which nothing frees when a host's thread ends: given back at the end of
  every call that may have used them (the vendored PJA has no parking) }
procedure GiveBackModels;
begin
  try
    ReleaseThreadModels;
  except
  end;
end;

{ a caller's thread count: 1 to 64, as the 7-Zip plugin takes them; the
  filter keeps 8 jobs a thread, and a count past that would overflow }
function Threads1to64(threads: LongInt): LongInt;
begin
  if threads < 1 then Result := 1
  else if threads > 64 then Result := 64
  else Result := threads;
end;

{ one of the filter's jobs. Encoding: the file as PPA's codec stream, not
  ok when PPA does not take it. Decoding: the file back, of `expected`
  bytes. }
procedure RunJob(var j: TJob; packing: Boolean; threads: Integer);
var b: TBytes; why: string; st: TCodecStats; fail: TDecodeFailure;
begin
  j.output := nil; j.outSize := 0; j.ok := 0; j.newer := 0;
  try
    if packing then begin
      if not Compress(InBytes(j.input, j.size), b, why, st, True, threads) then Exit;
    end else begin
      if not DecompressEx(InBytes(j.input, j.size), Int64(j.expected), b, why, fail, threads) then begin
        if fail = dfFuture then j.newer := 1;
        Exit;
      end;
    end;
    if Hand(b, j.output, j.outSize) then j.ok := 1;
  except
    if j.output <> nil then FreeMem(j.output);
    j.output := nil; j.ok := 0;
  end;
end;

type
  { the filter's pool: threads that take the jobs in the order they come
    and run them; the filter waits for each one in its own order }
  TPool = class;
  TPoolThread = class(TThread)
    pool: TPool;
    procedure Execute; override;
  end;
  TPool = class
    lock: TRTLCriticalSection;
    work, finished: PRTLEvent;
    queue: array of PJob;
    head, count: Integer;
    stop, packing: Boolean;
    workers: array of TPoolThread;
    function Take(out j: PJob): Boolean;
  end;

{ the next job, or nil; False when the pool is closing and nothing is left }
function TPool.Take(out j: PJob): Boolean;
begin
  EnterCriticalSection(lock);
  j := nil;
  if head < count then begin j := queue[head]; Inc(head); end;
  if head = count then begin head := 0; count := 0; end;
  Result := (j <> nil) or not stop;
  LeaveCriticalSection(lock);
end;

procedure TPoolThread.Execute;
var j: PJob;
begin
  while pool.Take(j) do
    if j = nil then RTLEventWaitFor(pool.work, 20)
    else begin
      RunJob(j^, pool.packing, j^.threads);
      InterLockedExchange(j^.done, 1);
      RTLEventSetEvent(pool.finished);
    end;
  GiveBackModels;
end;

function OpenPool(threads, packing: LongInt): Pointer; cdecl;
var p: TPool; k: Integer;
begin
  Result := nil;
  p := nil;
  try
    threads := Threads1to64(threads);
    p := TPool.Create;
    InitCriticalSection(p.lock);
    p.work := RTLEventCreate;
    p.finished := RTLEventCreate;
    p.packing := packing <> 0;
    SetLength(p.queue, 64);
    SetLength(p.workers, threads);
    { a thread the system refuses (a host at its limit): the pool goes on
      with the ones it gave; with none, the failure below }
    for k := 0 to threads - 1 do begin
      try
        p.workers[k] := TPoolThread.Create(True);
      except
        on EThread do begin
          if k = 0 then raise;
          SetLength(p.workers, k);
          Break;
        end;
      end;
      p.workers[k].pool := p;
      p.workers[k].Start;
    end;
    Result := p;
  except
    { the workers started before the failure: stopped and freed, or they
      would wait on a pool nobody holds }
    if p <> nil then begin
      p.stop := True;
      for k := 0 to High(p.workers) do
        if p.workers[k] <> nil then begin
          RTLEventSetEvent(p.work);
          if not p.workers[k].Suspended then p.workers[k].WaitFor;
          p.workers[k].Free;
        end;
    end;
    Result := nil;
  end;
end;

procedure SubmitJob(pool: Pointer; job: PJob); cdecl;
var p: TPool;
begin
  p := TPool(pool);
  EnterCriticalSection(p.lock);
  if p.count = Length(p.queue) then SetLength(p.queue, 2 * Length(p.queue));
  p.queue[p.count] := job;
  Inc(p.count);
  LeaveCriticalSection(p.lock);
  RTLEventSetEvent(p.work);
end;

procedure WaitJob(pool: Pointer; job: PJob); cdecl;
begin
  while InterLockedCompareExchange(job^.done, 1, 1) = 0 do
    RTLEventWaitFor(TPool(pool).finished, 20);
end;

procedure ClosePool(pool: Pointer); cdecl;
var p: TPool; k: Integer;
begin
  p := TPool(pool);
  EnterCriticalSection(p.lock);
  p.stop := True;
  LeaveCriticalSection(p.lock);
  for k := 0 to High(p.workers) do begin
    RTLEventSetEvent(p.work);
    p.workers[k].WaitFor;
    p.workers[k].Free;
  end;
  RTLEventDestroy(p.work);
  RTLEventDestroy(p.finished);
  DoneCriticalSection(p.lock);
  p.Free;
end;

function ppa_version: PChar; cdecl;
begin
  Result := VERSION_TEXT;
end;

{ ppa_compress and ppa_decompress run the codec on the caller's thread.
  out and outSize are pointers, not out parameters, so that a null one is
  an error and not a crash. }
function ppa_compress(input: PByte; size: SizeUInt; output: PPByte; outSize: PSizeUInt;
                      threads: LongInt): LongInt; cdecl;
var ppa: TBytes; stored: Boolean; why: string;
begin
  if (output = nil) or (outSize = nil) then Exit(PPA_E_ARG);
  output^ := nil; outSize^ := 0;
  if (input = nil) and (size > 0) then Exit(PPA_E_ARG);
  threads := Threads1to64(threads);
  try
    try
      { not taken, empty, not made smaller, or (a bug) not given back: the
        caller keeps the bytes its own way }
      if not Pack(InBytes(input, size), '', True, ppa, stored, why, threads) or stored then
        Exit(PPA_E_NOT_TAKEN);
      if Hand(ppa, output^, outSize^) then Result := PPA_OK else Result := PPA_E_MEMORY;
    finally
      GiveBackModels;
    end;
  except
    Result := PPA_E_MEMORY;
  end;
end;

function ppa_decompress(input: PByte; size: SizeUInt; output: PPByte; outSize: PSizeUInt;
                        maxSize: SizeUInt; threads: LongInt): LongInt; cdecl;
var original: TBytes; desc: TDescriptor; e: TFormatError; detail: string; cap: QWord;
begin
  if (output = nil) or (outSize = nil) then Exit(PPA_E_ARG);
  output^ := nil; outSize^ := 0;
  if (input = nil) and (size > 0) then Exit(PPA_E_ARG);
  threads := Threads1to64(threads);
  cap := MAX_ORIGINAL;
  if (maxSize > 0) and (maxSize < cap) then cap := maxSize;
  try
    try
      e := Unpack(InBytes(input, size), cap, original, desc, detail, threads);
      case e of
        feNone: if Hand(original, output^, outSize^) then Result := PPA_OK else Result := PPA_E_MEMORY;
        feTooLarge, feNoMemory: Result := PPA_E_MEMORY;
        { a newer PPA's .ppa, or codec stream inside it }
        feFutureVersion, feFutureStream: Result := PPA_E_VERSION;
      else
        { feHashMismatch included: what Unpack gave is not handed out }
        Result := PPA_E_DATA;
      end;
    finally
      GiveBackModels;
    end;
  except
    Result := PPA_E_MEMORY;
  end;
end;

procedure ppa_free(p: Pointer); cdecl;
begin
  FreeMem(p);
end;

function ppa_filter_encode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
                           threads: LongInt): LongInt; cdecl;
begin
  try
    Result := ppafilter_encode(read, readCtx, write, writeCtx, Threads1to64(threads));
  except
    Result := PPA_E_MEMORY;
  end;
end;

function ppa_filter_decode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
                           threads: LongInt): LongInt; cdecl;
begin
  try
    Result := ppafilter_decode(read, readCtx, write, writeCtx, Threads1to64(threads));
  except
    Result := PPA_E_MEMORY;
  end;
end;

{ the 7-Zip plugin's exports: STDAPI, __stdcall on Windows x86 }
function GetNumberOfMethods(n: PLongWord): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := ppa7z_GetNumberOfMethods(n);
end;

function GetMethodProperty(index, prop: LongWord; v: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := ppa7z_GetMethodProperty(index, prop, v);
end;

function CreateDecoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := ppa7z_CreateDecoder(index, iid, obj);
end;

function CreateEncoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := ppa7z_CreateEncoder(index, iid, obj);
end;

function CreateObject(clsid, iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := ppa7z_CreateObject(clsid, iid, obj);
end;

function GetModuleProp(prop: LongWord; v: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := ppa7z_GetModuleProp(prop, v);
end;

var host: THost; host7z: THost7z;

exports
  ppa_version, ppa_compress, ppa_decompress, ppa_free, ppa_filter_encode, ppa_filter_decode,
  GetNumberOfMethods, GetMethodProperty, CreateDecoder, CreateEncoder, CreateObject, GetModuleProp;

begin
  IsMultiThread := True;
  { the command's test settings, whatever the host's environment says }
  ResetTestSettings;
  TestKeepStream := False;
  SetCodePath(cpC);
  StagesOn := False;
  host.alloc := @HostAlloc;
  host.release := @HostRelease;
  host.poolOpen := @OpenPool;
  host.poolSubmit := @SubmitJob;
  host.poolWait := @WaitJob;
  host.poolClose := @ClosePool;
  ppafilter_host(host);
  host7z.bstr := @MakeBstr;
  host7z.alloc := @HostAlloc;
  host7z.release := @HostRelease;
  { 7-Zip on 32 bits: fewer, each file's slow model takes about 140 MB }
  host7z.threads := CpuCount;
  if host7z.threads > 8 then host7z.threads := 8;
  if (SizeOf(Pointer) = 4) and (host7z.threads > 2) then host7z.threads := 2;
  ppa7z_host(host7z);
end.
