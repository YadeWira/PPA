{ ppaguardheap: a memory manager for TESTS only (Linux), never in a release.

  Each block gets its own mmap, its last byte the last before a PROT_NONE
  page: a read or write past the end of any heap block faults right there,
  where the process heap of Windows XP faulted only now and then. What it
  is for: FreePascal turns `movzx` + `and $mask` into a wider `mov` + `and`
  (its peephole optimizer, x86 and x86-64 alike), so `w[i] and $1F` of an
  array of Word loads 4 bytes, 2 past the last element (ppadeflate's
  clenSeq, found by it).

  First in the uses of a test program, or without touching it:
    fpc -Fu<pas/tests> -Fappaguardheap ...
  pas/tests/guard.sh builds the layer tests and the command so and runs them.

  Blocks start where their end puts them (PPA_GUARD_ALIGN=1): nothing in
  PPA needs more alignment from the heap (every layer and the command ran
  so, C and Pascal, 32 and 64 bits).

  The environment:
    PPA_GUARD_ALIGN=n   the start of each block aligned to n bytes (1 by
                        default: the end exact, so even 1 byte past faults;
                        the tail is then up to n - 1 bytes of slack)
    PPA_GUARD_MIN=n     blocks under n bytes go to FreePascal's heap (0 by
                        default: every block guarded)
    PPA_GUARD_OFF=1     nothing guarded (the same build, for comparing)

  A fault prints the faulting address and instruction (map it with
  addr2line -e <program> <pc>, or gdb) and exits with 86. A fault inside
  the guard page just after a block says so ("guard").

  Every block costs two mappings (vm.max_map_count) and at least two pages
  of address space. }
unit ppaguardheap;

{$mode objfpc}

interface

implementation

{$ifdef linux}
uses BaseUnix;

const
  GUARD_MARK = PtrUInt({$ifdef cpu64}$C0FFEE5AFE6A4D00{$else}$C0FE6A4D{$endif});
  PAGE = 4096;

type
  PHeader = ^THeader;
  THeader = packed record
    size, mark: PtrUInt;
  end;

var
  old: TMemoryManager;
  align: PtrUInt = 1;
  minSize: PtrUInt = 0;

function Mine(p: Pointer): Boolean; inline;
begin
  Result := PHeader(p - SizeOf(THeader))^.mark = GUARD_MARK;
end;

{ the mapping that holds a block of size n at p: from the page of its
  header to the guard page after its end, included }
procedure Span(p: Pointer; n: PtrUInt; out base: Pointer; out len: PtrUInt);
var b, g: PtrUInt;
begin
  b := (PtrUInt(p) - SizeOf(THeader)) and not PtrUInt(PAGE - 1);
  g := (PtrUInt(p) + n + PAGE - 1) and not PtrUInt(PAGE - 1);
  base := Pointer(b);
  len := g + PAGE - b;
end;

function Take(size: PtrUInt): Pointer;
var
  data, len: PtrUInt;
  base: Pointer;
  p: PtrUInt;
begin
  if size < minSize then Exit(old.GetMem(size));
  if size > High(PtrUInt) div 2 then Exit(nil);
  { the data pages: the block, its header and the alignment's slack }
  data := (size + SizeOf(THeader) + align + PAGE - 1) and not PtrUInt(PAGE - 1);
  len := data + PAGE;
  base := Fpmmap(nil, len, PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if (base = MAP_FAILED) or (base = nil) then Exit(nil);
  if Fpmprotect(base + data, PAGE, PROT_NONE) <> 0 then
  begin
    Fpmunmap(base, len);
    Exit(nil);
  end;
  p := (PtrUInt(base) + data - size) and not (align - 1);
  PHeader(p - SizeOf(THeader))^.size := size;
  PHeader(p - SizeOf(THeader))^.mark := GUARD_MARK;
  Result := Pointer(p);
end;

function GGetMem(size: PtrUInt): Pointer;
begin
  Result := Take(size);
end;

function GAllocMem(size: PtrUInt): Pointer;
begin
  Result := Take(size);
  { fresh mappings are zero; FreePascal's blocks are not }
  if (Result <> nil) and (size < minSize) then FillChar(Result^, size, 0);
end;

function GFreeMem(p: Pointer): PtrUInt;
var base: Pointer; len: PtrUInt;
begin
  if p = nil then Exit(0);
  if not Mine(p) then Exit(old.FreeMem(p));
  Result := PHeader(p - SizeOf(THeader))^.size;
  PHeader(p - SizeOf(THeader))^.mark := 0;
  Span(p, Result, base, len);
  Fpmunmap(base, len);
end;

function GFreeMemSize(p: Pointer; size: PtrUInt): PtrUInt;
begin
  Result := GFreeMem(p);
end;

function GMemSize(p: Pointer): PtrUInt;
begin
  if not Mine(p) then Exit(old.MemSize(p));
  Result := PHeader(p - SizeOf(THeader))^.size;
end;

function GReAllocMem(var p: Pointer; size: PtrUInt): Pointer;
var q: Pointer; n: PtrUInt;
begin
  if size = 0 then
  begin
    GFreeMem(p);
    p := nil;
    Exit(nil);
  end;
  if p = nil then
  begin
    p := Take(size);
    Exit(p);
  end;
  q := Take(size);
  if q = nil then Exit(nil);
  n := GMemSize(p);
  if n > size then n := size;
  Move(p^, q^, n);
  GFreeMem(p);
  p := q;
  Result := q;
end;

{ the fault: where, what, then out (no exception: the code under test
  catches them and would call it a data error) }
procedure Put(const s: ShortString);
begin
  FpWrite(2, @s[1], Length(s));
end;

function Hex(v: PtrUInt): ShortString;
const d: array[0..15] of Char = '0123456789abcdef';
var i: Integer;
begin
  Result := '0x';
  for i := SizeOf(PtrUInt) * 2 - 1 downto 0 do
    Result := Result + d[(v shr (i * 4)) and 15];
end;

procedure OnFault(sig: cint; info: PSigInfo; ctx: Pointer); cdecl;
var addr, pc, off: PtrUInt;
begin
  addr := PtrUInt(info^._sifields._sigfault._addr);
  { ucontext_t: uc_mcontext.gregs[REG_RIP] / [REG_EIP] }
  {$ifdef cpux86_64}pc := PPtrUInt(ctx + 40 + 16 * 8)^;{$endif}
  {$ifdef cpui386}pc := PPtrUInt(ctx + 20 + 14 * 4)^;{$endif}
  off := addr and (PAGE - 1);
  Put('ppaguardheap: SIGSEGV at ' + Hex(addr) + ', pc ' + Hex(pc));
  if (addr <> 0) and (off < 64) then Put(' (guard? ' + Hex(off) + ' into its page)');
  Put(#10);
  FpExit(86);
end;

procedure Install;
var
  g: TMemoryManager;
  act: SigActionRec;
  e: PChar;
  v: PtrUInt;
begin
  e := FpGetEnv('PPA_GUARD_OFF');
  if (e <> nil) and (e[0] = '1') then Exit;
  e := FpGetEnv('PPA_GUARD_ALIGN');
  if e <> nil then
  begin
    v := 0;
    while e^ in ['0'..'9'] do begin v := v * 10 + Ord(e^) - Ord('0'); Inc(e); end;
    if (v > 0) and (v <= PAGE) and (v and (v - 1) = 0) then align := v;
  end;
  e := FpGetEnv('PPA_GUARD_MIN');
  if e <> nil then
  begin
    v := 0;
    while e^ in ['0'..'9'] do begin v := v * 10 + Ord(e^) - Ord('0'); Inc(e); end;
    minSize := v;
  end;
  GetMemoryManager(old);
  g := old;
  g.GetMem := @GGetMem;
  g.FreeMem := @GFreeMem;
  g.FreeMemSize := @GFreeMemSize;
  g.AllocMem := @GAllocMem;
  g.ReAllocMem := @GReAllocMem;
  g.MemSize := @GMemSize;
  SetMemoryManager(g);

  FillChar(act, SizeOf(act), 0);
  act.sa_handler := SigActionHandler(@OnFault);
  act.sa_flags := SA_SIGINFO;
  FpSigAction(SIGSEGV, @act, nil);
  FpSigAction(SIGBUS, @act, nil);
end;

initialization
  Install;
{$endif}
end.
