{ Measurement, not a test: what it would cost to store a zlib stream's
  choices given the bytes it holds, with a predictor simple enough for a
  ZPAQL decoder. The bytes known, a stream's tokens are its parse: for each
  token, literal or match, and for a match its length and its distance; the
  distance is told as a rank among the earlier positions that start with
  the same 3 bytes (most recent first) and match at least as long. Prints
  order-0 entropy estimates of each part, against the stream's size.

    measure_parse <directory> }
program measure_parse;
{$I ../ppa.inc}
uses SysUtils, Classes, Math, ppapng, ppadeflate;

function ReadFile(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

const
  HASH_BITS = 16;
  WINDOW = 32768;
  MAX_WALK = 65536;
  RANK_ESCAPE = 64;     { ranks at or above it go as escape + raw bits }

type
  THist = array of Int64;

function Entropy(const h: THist): Double;
var i: Integer; total: Int64; p: Double;
begin
  total := 0; Result := 0;
  for i := 0 to High(h) do Inc(total, h[i]);
  if total = 0 then Exit;
  for i := 0 to High(h) do
    if h[i] > 0 then begin p := h[i] / total; Result := Result - h[i] * Log2(p); end;
end;

var
  files: TStringList; sr: TSearchRec; dir: string;
  i, k: Integer; s, t, pos, q, j, walk, rank, bucket, extra: SizeInt;
  d: TBytes; p: TPng; z: TZStream;
  head: array of SizeInt; prev: array of SizeInt;
  hFlag, hLen, hRank, hLit: THist;
  rawBits, headerBits, streamBytes, plainBytes, nTok, nMatch, escapes: Int64;
  found: Boolean;

  function Hash(x: SizeInt): Integer; inline;
  begin
    Result := ((Integer(z.plain[x]) shl 10) xor (Integer(z.plain[x + 1]) shl 5) xor z.plain[x + 2]) and ((1 shl HASH_BITS) - 1);
  end;

  procedure Insert(x: SizeInt); inline;
  var h: Integer;
  begin
    if x + 2 >= Length(z.plain) then Exit;
    h := Hash(x);
    prev[x and (WINDOW - 1)] := head[h];
    head[h] := x;
  end;

begin
  dir := ParamStr(1);
  files := TStringList.Create; files.Sorted := True;
  if FindFirst(dir + '/*', faAnyFile, sr) = 0 then begin
    repeat if (sr.Attr and faDirectory) = 0 then files.Add(dir + '/' + sr.Name); until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  hFlag := nil; SetLength(hFlag, 2);
  hLen := nil; SetLength(hLen, 259);
  hRank := nil; SetLength(hRank, 64);
  hLit := nil; SetLength(hLit, 256);
  rawBits := 0; headerBits := 0; streamBytes := 0; plainBytes := 0; nTok := 0; nMatch := 0; escapes := 0;
  head := nil; SetLength(head, 1 shl HASH_BITS);
  prev := nil; SetLength(prev, WINDOW);
  for i := 0 to files.Count - 1 do begin
    d := ReadFile(files[i]);
    if not ppapng.Decompose(d, p).Ok then Continue;
    for s := 0 to High(p.streams) do begin
      if not (p.streams[s].kind in [skIdat, skFdat]) then Continue;
      if not ppadeflate.Decode(p.streams[s].data, not IsZlibHeader(p.streams[s].data), 1 shl 30, z).Ok then Continue;
      Inc(streamBytes, Length(p.streams[s].data));
      Inc(plainBytes, Length(z.plain));
      for k := 0 to High(z.blocks) do
        if z.blocks[k].btype = btDynamic then
          Inc(headerBits, 14 + 3 * z.blocks[k].hclen + 5 * Length(z.blocks[k].clenSeq));
      for k := 0 to High(head) do head[k] := -1;
      pos := 0;
      for t := 0 to High(z.tokLen) do begin
        { the tokens of stored blocks are none: their bytes go as literals here }
        Inc(nTok);
        if z.tokLen[t] = 0 then begin
          Inc(hFlag[0]); Inc(hLit[z.plain[pos]]);
          Insert(pos); Inc(pos);
          Continue;
        end;
        Inc(hFlag[1]); Inc(nMatch);
        k := z.tokLen[t]; if k = LEN_258_AS_284 then k := 258;
        Inc(hLen[k]);
        { the rank of the match's source among the candidates }
        rank := 0; found := False; walk := 0;
        if pos + 2 < Length(z.plain) then begin
          q := head[Hash(pos)];
          while (q >= 0) and (pos - q <= WINDOW) and (walk < MAX_WALK) do begin
            if q = pos - z.tokVal[t] then begin found := True; Break; end;
            j := 0;
            while (j < k) and (z.plain[q + j] = z.plain[pos + j]) do Inc(j);
            if j >= k then Inc(rank);
            q := prev[q and (WINDOW - 1)];
            Inc(walk);
          end;
        end;
        if not found then begin Inc(escapes); rank := RANK_ESCAPE; end;
        if rank < 16 then bucket := rank
        else begin
          { 16.. : log buckets, extra bits raw }
          extra := Floor(Log2(rank - 15));
          bucket := 16 + extra;
          if bucket > 63 then bucket := 63;
          Inc(rawBits, extra);
        end;
        if not found then Inc(rawBits, 15);
        Inc(hRank[bucket]);
        for j := 0 to k - 1 do begin Insert(pos + j); end;
        Inc(pos, k);
      end;
    end;
  end;
  Writeln(Format('streams: %d bytes holding %d bytes; %d tokens, %d matches (%d not found in the chain)',
    [streamBytes, plainBytes, nTok, nMatch, escapes]));
  Writeln(Format('  literal/match flags  %10.0f bytes', [Entropy(hFlag) / 8]));
  Writeln(Format('  match lengths        %10.0f bytes', [Entropy(hLen) / 8]));
  Writeln(Format('  distance ranks       %10.0f bytes (+ %d raw)', [Entropy(hRank) / 8, rawBits div 8]));
  Writeln(Format('  dynamic headers      %10d bytes (as written)', [headerBits div 8]));
  Writeln(Format('  total parse          %10.0f bytes = %.2f%% of the streams',
    [(Entropy(hFlag) + Entropy(hLen) + Entropy(hRank) + rawBits + headerBits) / 8,
     100 * (Entropy(hFlag) + Entropy(hLen) + Entropy(hRank) + rawBits + headerBits) / 8 / streamBytes]));
  Write('  rank histogram:');
  for k := 0 to 20 do Write(' ', hRank[k]);
  Writeln;
end.
