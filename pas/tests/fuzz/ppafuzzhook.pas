{ ppafuzzhook: for FUZZING only, never in a release.

  The decoder refuses a damaged stream; where an exception gets raised
  inside it, ppacodec.DecompressSafe (and the library's exports, and the
  filter's jobs) catch it and call it damage. That is right for a user, and
  it hides from a fuzzer the exceptions that are bugs: a range or overflow
  check (-Cr -Co, or the units' own $R+ $Q+), an access violation that
  FreePascal turned into EAccessViolation, an explicit ERangeError of a
  bounds check (ppacrc, ppablake3), an invalid pointer.

  This unit hooks RaiseProc, which the RTL calls on every raise before any
  handler runs: an exception of any class but the plain Exception (what
  the decoders raise on purpose for damage: ppamodel, ppafast, ppastatic,
  ppathreads' rethrow) and EOutOfMemory prints its class, message and the
  backtrace (-gl: file:line) to stderr and kills the process with SIGABRT,
  which AFL++ and libFuzzer take for a crash.

  Put first in the uses, or without touching a program: fpc -Fappafuzzhook
  (after ppaguardheap or cmem, when one is used: -Fappaguardheap,ppafuzzhook).

  PPA_FUZZ_HOOK=0 in the environment turns it off (to see what the code
  does with the exception). }
unit ppafuzzhook;

{$mode objfpc}{$H+}

interface

implementation

{ No SysUtils here: as the first unit of a library (-Facmem,ppafuzzhook) it
  would start before cthreads. The classes are told by name, and an
  Exception's message read where SysUtils keeps it (its first field). }
uses BaseUnix;

procedure Say(const s: string);
begin
  if s <> '' then FpWrite(2, s[1], Length(s));
end;

function Within(c: TClass; const name: string): Boolean;
begin
  while c <> nil do begin
    if c.ClassName = name then Exit(True);
    c := c.ClassParent;
  end;
  Result := False;
end;

procedure OnRaise(Obj: TObject; Addr: CodePointer; FrameCount: Longint; Frame: PCodePointer);
var i: Longint; s: string;
begin
  if (Obj = nil) or (Obj.ClassName = 'Exception') or Within(Obj.ClassType, 'EOutOfMemory') then Exit;
  s := 'ppafuzzhook: ' + Obj.ClassName;
  if Within(Obj.ClassType, 'Exception') then s := s + ': ' + PAnsiString(PByte(Obj) + SizeOf(Pointer))^;
  s := s + LineEnding + BackTraceStrFunc(Addr) + LineEnding;
  for i := 0 to FrameCount - 1 do s := s + BackTraceStrFunc(Frame[i]) + LineEnding;
  Say(s);
  FpKill(FpGetpid, SIGABRT);
  FpExit(134);
end;

var off: PChar;
initialization
  off := FpGetEnv(PChar('PPA_FUZZ_HOOK'));
  if (off = nil) or (off^ <> '0') then RaiseProc := @OnRaise;
end.
