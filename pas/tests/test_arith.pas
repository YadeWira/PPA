{ Layer 4: the arithmetic coder gives back every bit, whatever the
  probabilities (also the extreme ones and wrong ones), and costs what the
  probabilities say; the counters and the stretch/squash tables are sane:
  squash increasing, stretch its inverse within one step.

    test_arith }
program test_arith;
{$I ../ppa.inc}
uses SysUtils, ppaarith;

var
  failures: Integer;

procedure Fail(const s: string);
begin
  Inc(failures); Writeln('  FAIL ', s);
end;

{ a fixed pseudo-random sequence (xorshift32), the same everywhere }
var rng: Cardinal = 2463534242;
function Rnd: Cardinal;
begin
  rng := rng xor (rng shl 13); rng := rng xor (rng shr 17); rng := rng xor (rng shl 5);
  Result := rng;
end;

procedure RoundTrip(n: Integer; mode: Integer);
var
  bits, probs: array of Integer; i, b: Integer; e: TArithEncoder; d: TArithDecoder;
  out_: TBytes; ideal: Double; c: TAdaptiveBit;
begin
  bits := nil; probs := nil; SetLength(bits, n); SetLength(probs, n);
  ideal := 0;
  for i := 0 to n - 1 do begin
    case mode of
      0: probs[i] := Integer(Rnd mod 65535) + 1;          { any }
      1: if Rnd and 1 = 0 then probs[i] := 1 else probs[i] := 65535;   { extremes }
      2: probs[i] := 60000;                                 { skewed }
    end;
    { the bit follows its probability, except in mode 1 where half are wrong }
    if mode = 1 then bits[i] := Integer(Rnd and 1)
    else if Integer(Rnd mod 65536) < probs[i] then bits[i] := 1 else bits[i] := 0;
    if bits[i] = 1 then ideal := ideal - Ln(probs[i] / 65536) / Ln(2)
    else ideal := ideal - Ln(1 - probs[i] / 65536) / Ln(2);
  end;
  e.Init;
  for i := 0 to n - 1 do e.Encode(bits[i], probs[i]);
  e.Direct($A5, 8);
  out_ := e.Finish;
  d.Init(out_);
  for i := 0 to n - 1 do begin
    b := d.Decode(probs[i]);
    if b <> bits[i] then begin Fail(Format('mode %d: bit %d differs', [mode, i])); Exit; end;
  end;
  if d.Direct(8) <> $A5 then Fail(Format('mode %d: direct bits differ', [mode]));
  if (mode <> 1) and (Length(out_) * 8 > ideal * 1.01 + 64) then
    Fail(Format('mode %d: %d bytes for %.0f bits', [mode, Length(out_), ideal]));
  Writeln(Format('  mode %d: %d bits in %d bytes (ideal %.0f bytes)', [mode, n, Length(out_), ideal / 8]));
  { a counter fed only ones goes up, only zeros down, and stays inside }
  c.Init;
  for i := 1 to 10000 do c.Update(1, 255);
  if (c.p < 65000) then Fail('counter does not go up');
  for i := 1 to 10000 do c.Update(0, 30);
  if (c.p > 2500) or (c.p < 1) then Fail(Format('counter does not go down: %d', [c.p]));
end;

var x, p, prev: Integer;
begin
  failures := 0;
  RoundTrip(1000000, 0);
  RoundTrip(1000000, 1);
  RoundTrip(1000000, 2);
  prev := 0;
  for x := -2048 to 2047 do begin
    p := Squash(x);
    if p < prev then Fail(Format('squash decreases at %d', [x]));
    prev := p;
  end;
  if (Squash(0) < 32700) or (Squash(0) > 32840) then Fail(Format('squash(0) = %d', [Squash(0)]));
  for p := 1 to 65535 do begin
    x := Stretch(p);
    if Abs(Squash(x) - p) > 400 + p div 40 then begin Fail(Format('stretch(%d) = %d, squash back %d', [p, x, Squash(x)])); Break; end;
  end;
  Writeln(Format('  squash(-2048) %d, squash(0) %d, squash(2047) %d; stretch(32768) %d',
    [Squash(-2048), Squash(0), Squash(2047), Stretch(32768)]));
  if failures = 0 then Writeln('arithmetic coder, counters and tables: 0 failures')
  else begin Writeln(failures, ' failures'); Halt(1); end;
end.
