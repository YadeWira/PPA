/* Layer 2b's predictor, its hot spot in C: zlib's longest_match, bit for
   bit what ppazlib's Pascal LongestMatch does (the suite runs the predictor
   both ways and demands the same choices; PPA_NOC=1 picks the Pascal one).
   Positions are absolute into the input; a byte past its end reads as 0, as
   the Pascal's Win does. Takes no memory and calls no library. */
#include <stdint.h>

#define MAX_MATCH 258

static inline uint8_t win(const uint8_t *p, intptr_t n, intptr_t i) { return i < n ? p[i] : 0; }

/* how many bytes a and b have equal from the start, up to top: 4 at a time
   on little-endian machines, with a count of trailing zeros of 32 bits (a
   64-bit one would call libgcc on 32-bit x86, and this object calls no
   library); the same count either way */
static inline intptr_t common(const uint8_t *a, const uint8_t *b, intptr_t from, intptr_t top) {
  intptr_t len = from;
#if (defined(__GNUC__) || defined(__clang__)) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  while (len + 4 <= top) {
    uint32_t x, y, d;
    __builtin_memcpy(&x, a + len, 4);
    __builtin_memcpy(&y, b + len, 4);
    d = x ^ y;
    if (d) return len + (__builtin_ctz(d) >> 3);
    len += 4;
  }
#endif
  while (len < top && a[len] == b[len]) len++;
  return len;
}

/* the longest match for the string at scan, walking the hash chain from
   cur; returns the best length (not yet capped to the lookahead) and sets
   *matchStart where it improves on bestLen */
intptr_t ppaz_longest(const uint8_t *plain, intptr_t n, const intptr_t *prev, intptr_t wmask,
                      intptr_t scan, intptr_t cur, intptr_t limit, intptr_t chain,
                      intptr_t bestLen, intptr_t nice, intptr_t *matchStart) {
  uint8_t e1 = win(plain, n, scan + bestLen - 1), e = win(plain, n, scan + bestLen);
  const uint8_t s0 = win(plain, n, scan), s1 = win(plain, n, scan + 1);
  const intptr_t avail = n - scan;   /* bytes from scan to the end */
  do {
    const intptr_t m = cur;
    if (win(plain, n, m + bestLen) == e && win(plain, n, m + bestLen - 1) == e1 &&
        win(plain, n, m) == s0 && win(plain, n, m + 1) == s1) {
      const intptr_t top = avail < MAX_MATCH ? avail : MAX_MATCH;
      intptr_t len = common(plain + m, plain + scan, 3, top);
      if (len >= avail && len < MAX_MATCH) len = MAX_MATCH;   /* reaches the end: capped by the caller */
      if (len > bestLen) {
        *matchStart = cur;
        bestLen = len;
        if (len >= nice) break;
        e1 = win(plain, n, scan + bestLen - 1);
        e = win(plain, n, scan + bestLen);
      }
    }
    cur = prev[cur & wmask];
    chain--;
  } while (cur > limit && chain != 0);
  return bestLen;
}

/* longest_match again, the same result, with the hash chain skipped where
   no candidate can do better: a candidate improves on bestLen only with at
   least bestLen + 1 bytes the same, so only the positions with the same 3
   bytes count while bestLen is 2, the same 4 from 3 on, the same 8 from 7
   on. nx[1..2] link each position to the last one before it with the same
   4 and 8 bytes (0: none; -1: not known, a table's collision); the same
   3 bytes are found on zlib's own chain, walked (a table for them cost
   more to keep than it saved: 4.5% of the time on photographs); ord
   numbers each position in its hash chain, so a jump from the scan to q
   costs zlib's walk ord[scan] - ord[q] steps (curMatch, the first, is step
   0) and the chain's length still ends the search where zlib's ends. A
   candidate the walk reaches with fewer bytes the same than the chain it
   is on is not possible: one newer with more would have been met first.
   Where a link is not known, zlib's chain is walked from there to the next
   position with the key. */
static inline int skip_level(intptr_t bestLen, int lmax) {
  const int l = bestLen >= 15 ? 3 : bestLen >= 7 ? 2 : bestLen >= 3 ? 1 : 0;
  return l < lmax ? l : lmax;
}
static const intptr_t SKIP_KEY[4] = {3, 4, 8, 16};
#if (defined(__GNUC__) || defined(__clang__)) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define ZK_LE 1
#endif

/* the bytes of the key of level lv at a and b the same (lv 0: 3 bytes, 1:
   4, 2: 8, 3: 16; both have that many bytes to read) */
static inline int same_key(const uint8_t *plain, intptr_t a, intptr_t b, int lv) {
#ifdef ZK_LE
  if (lv >= 2) {
    uint64_t x, y; __builtin_memcpy(&x, plain + a, 8); __builtin_memcpy(&y, plain + b, 8);
    if (lv == 2 || x != y) return x == y;
    __builtin_memcpy(&x, plain + a + 8, 8); __builtin_memcpy(&y, plain + b + 8, 8); return x == y;
  }
  { uint32_t x, y; __builtin_memcpy(&x, plain + a, 4); __builtin_memcpy(&y, plain + b, 4);
    return lv == 1 ? x == y : ((x ^ y) & 0xFFFFFFu) == 0; }
#else
  const int k = lv == 3 ? 16 : lv == 2 ? 8 : lv == 1 ? 4 : 3;
  for (int i = 0; i < k; i++) if (plain[a + i] != plain[b + i]) return 0;
  return 1;
#endif
}

static intptr_t longest_skip(const uint8_t *plain, intptr_t n, const intptr_t *prev, intptr_t *const nx[4],
                             const uint32_t *ord, intptr_t wmask, intptr_t scan, intptr_t cur, intptr_t limit,
                             intptr_t chain, intptr_t bestLen, intptr_t nice, intptr_t *matchStart) {
  if (bestLen < 2 || scan + 4 > n)
    return ppaz_longest(plain, n, prev, wmask, scan, cur, limit, chain, bestLen, nice, matchStart);
  const uint32_t o0 = ord[scan & wmask];
  const intptr_t avail = n - scan;
  const intptr_t top = avail < MAX_MATCH ? avail : MAX_MATCH;
  /* the 16 bytes' links where they are kept (zlib's levels 8 and 9) */
  const int lmax = nx[3] && scan + 16 <= n ? 3 : scan + 8 <= n ? 2 : 1;
  int lv = skip_level(bestLen, lmax);
  intptr_t from = scan;                 /* the position whose link q is */
  intptr_t q = lv ? nx[lv][scan & wmask] : -1;
  for (;;) {
    if (q < 0) {
      /* not known (a table's collision): zlib's chain from `from`, every
         position on it a candidate, to the first with the key; the ones
         before it cannot do better (their key differs, and the key is no
         longer than bestLen + 1) */
      q = prev[from & wmask];
      while (q != 0 && (q > limit || q == cur) && (uint32_t)(o0 - ord[q & wmask] - 1) < (uint32_t)chain &&
             !same_key(plain, q, scan, lv))
        q = prev[q & wmask];
    }
    if (q == 0 || (q <= limit && q != cur)) break;          /* none left (zlib takes curMatch anyway) */
    if ((uint32_t)(o0 - ord[q & wmask] - 1) >= (uint32_t)chain) break;   /* past zlib's chain */
    /* as zlib: a candidate without the byte at bestLen the same cannot do better */
    if (bestLen >= top || plain[q + bestLen] == plain[scan + bestLen]) {
      intptr_t len = common(plain + q, plain + scan, 0, top);
      if (len >= avail && len < MAX_MATCH) len = MAX_MATCH;
      if (len > bestLen) {
        *matchStart = q;
        bestLen = len;
        if (len >= nice) break;
        const int l2 = skip_level(bestLen, lmax);
        if (l2 > lv) {
          /* a longer chain from here: q's own if q has its key, else the
             scan's, whose first is older than q */
          lv = l2;
          from = len >= SKIP_KEY[lv] ? q : scan;
          q = nx[lv][from & wmask];   /* lv > 0 here */
          continue;
        }
      }
    }
    from = q;
    q = lv ? nx[lv][q & wmask] : -1;
  }
  return bestLen;
}

/* ---- zlib's deflate_slow and deflate_fast, the loop around longest_match:
   bit for bit what ppazlib's Pascal DeflateSlow and DeflateFast do, with
   the chains skipped as above. Runs until a block is full (returns
   ZD_FLUSH: Pascal flushes it and calls again), the input ends (ZD_DONE)
   or the choices part from the reference (ZD_STOP). ppazlib.pas's
   TZDeflate is this struct, field for field. */
enum { ZD_DONE = 0, ZD_FLUSH = 1, ZD_STOP = 2, ZD_SEGEND = 3 };
#define MIN_MATCH 3
#define TOO_FAR 4096

typedef struct {
  const uint8_t *plain; intptr_t n;
  intptr_t wsize, wmask, maxDist, hashMask, hashShift;
  intptr_t *head, *prev, *nx4, *nx8; uint32_t *ord, *cnt, *t4, *t8;
  intptr_t insH;
  intptr_t strstart, matchStart, prevMatch, winBase;
  intptr_t matchLength, prevLength, matchAvailable;
  intptr_t goodMatch, maxLazy, niceMatch, maxChain, filtered, fast;
  uint16_t *tokLen, *tokVal; intptr_t nTok;
  const uint16_t *refLen, *refVal; intptr_t refN, checkNow, stop;
  int32_t *lfreq, *dfreq; intptr_t symNext, symEnd;
  const uint8_t *lengthCode, *distCode;
  intptr_t pending;              /* after a flush: the literal's strstart++ still to do */
  intptr_t skipBits;             /* the tables t4, t8 (t16): 2^skipBits positions each */
  intptr_t *nx16; uint32_t *t16; /* the same 16 bytes, where the chains are long (levels 8, 9); else 0 */
  /* a segment (ppazlib's parallel rebuild, deflate_slow only): stop at the
     top of the loop once strstart reaches stopAt (0: never); after each
     match, where the parse is as it starts (no match pending, none found
     yet), its position and the tokens so far, up to maxSync of them; endLit:
     the literal deflate_slow emits after its loop was emitted */
  intptr_t stopAt;
  intptr_t *syncPos, *syncTok; intptr_t nSync, maxSync;
  intptr_t endLit;
  intptr_t syncLo, syncHi;       /* only the positions up to syncLo and from syncHi are kept */
} zdeflate_t;

#if (defined(__GNUC__) || defined(__clang__)) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define ZD_LE 1
#endif

static inline uint64_t zd_load8(const uint8_t *p) { uint64_t v; __builtin_memcpy(&v, p, 8); return v; }

#ifndef ZD_PF
#define ZD_PF 4
#endif
static inline void zd_skip(zdeflate_t *s, intptr_t str) {
  const uint8_t *p = s->plain;
  const intptr_t i = str & s->wmask, n = s->n;
  const int sb = (int)s->skipBits;
  s->ord[i] = s->cnt[s->insH]++;
#ifdef ZD_LE
  if (str + ZD_PF + 8 <= n) {
    /* little-endian, 8 bytes to read: the keys out of one load (the 3 and 4
       first bytes are its low ones), and the tables' slots a few positions
       ahead fetched meanwhile (a hint: nothing depends on it) */
    const uint64_t f8 = zd_load8(p + str + ZD_PF);
    const uint32_t f4 = (uint32_t)f8;
    __builtin_prefetch(&s->t4[(f4 * 2246822519u) >> (32 - sb)]);
    __builtin_prefetch(&s->t8[(uint32_t)((f8 * 0x9E3779B97F4A7C15ull) >> (64 - sb))]);
    const uint64_t k8 = zd_load8(p + str);
    const uint32_t k4 = (uint32_t)k8;
    uint32_t h = (k4 * 2246822519u) >> (32 - sb);
    intptr_t c = s->t4[h];
    s->nx4[i] = (c == 0 || str - c >= s->wsize) ? 0 : (uint32_t)zd_load8(p + c) == k4 ? c : -1;
    s->t4[h] = (uint32_t)str;
    h = (uint32_t)((k8 * 0x9E3779B97F4A7C15ull) >> (64 - sb));
    c = s->t8[h];
    s->nx8[i] = (c == 0 || str - c >= s->wsize) ? 0 : zd_load8(p + c) == k8 ? c : -1;
    s->t8[h] = (uint32_t)str;
    if (s->t16) {
      if (str + 16 <= n) {
        const uint64_t k8b = zd_load8(p + str + 8);
        h = (uint32_t)(((k8 ^ (k8b * 0xC2B2AE3D27D4EB4Full)) * 0x9E3779B97F4A7C15ull) >> (64 - sb));
        c = s->t16[h];
        s->nx16[i] = (c == 0 || str - c >= s->wsize) ? 0 : (zd_load8(p + c) == k8 && zd_load8(p + c + 8) == k8b) ? c : -1;
        s->t16[h] = (uint32_t)str;
      } else s->nx16[i] = -1;
    }
    return;
  }
#endif
  /* near the end, or not little-endian: the keys a byte at a time (the
     hashes may differ from the fast path's: only collisions do, and a
     collision only ever costs zlib's walk) */
  const uint32_t k3 = p[str] | (uint32_t)p[str + 1] << 8 | (uint32_t)p[str + 2] << 16;
  uint32_t h;
  intptr_t c;
  if (str + 3 < n) {
    const uint32_t k4 = k3 | (uint32_t)p[str + 3] << 24;
    h = (k4 * 2246822519u) >> (32 - sb);
    c = s->t4[h];
    if (c == 0 || str - c >= s->wsize) s->nx4[i] = 0;
    else s->nx4[i] = (p[c] | (uint32_t)p[c + 1] << 8 | (uint32_t)p[c + 2] << 16 | (uint32_t)p[c + 3] << 24) == k4 ? c : -1;
    s->t4[h] = (uint32_t)str;
  } else s->nx4[i] = -1;
  if (str + 7 < n) {
    uint64_t k8 = 0, kc;
    for (int b = 7; b >= 0; b--) k8 = k8 << 8 | p[str + b];
    h = (uint32_t)((k8 * 0x9E3779B97F4A7C15ull) >> (64 - sb));
    c = s->t8[h];
    if (c == 0 || str - c >= s->wsize) s->nx8[i] = 0;
    else {
      kc = 0;
      for (int b = 7; b >= 0; b--) kc = kc << 8 | p[c + b];
      s->nx8[i] = kc == k8 ? c : -1;
    }
    s->t8[h] = (uint32_t)str;
  } else s->nx8[i] = -1;
  if (s->t16) {
    if (str + 15 < n) {
      uint64_t a8 = 0, b8 = 0, ca = 0, cb = 0;
      for (int b = 7; b >= 0; b--) { a8 = a8 << 8 | p[str + b]; b8 = b8 << 8 | p[str + 8 + b]; }
      h = (uint32_t)(((a8 ^ (b8 * 0xC2B2AE3D27D4EB4Full)) * 0x9E3779B97F4A7C15ull) >> (64 - sb));
      c = s->t16[h];
      if (c == 0 || str - c >= s->wsize) s->nx16[i] = 0;
      else {
        for (int b = 7; b >= 0; b--) { ca = ca << 8 | p[c + b]; cb = cb << 8 | p[c + 8 + b]; }
        s->nx16[i] = (ca == a8 && cb == b8) ? c : -1;
      }
      s->t16[h] = (uint32_t)str;
    } else s->nx16[i] = -1;
  }
}

static inline intptr_t zd_insert(zdeflate_t *s, intptr_t str) {
  s->insH = ((s->insH << s->hashShift) ^ win(s->plain, s->n, str + MIN_MATCH - 1)) & s->hashMask;
  const intptr_t r = s->head[s->insH];
  s->prev[str & s->wmask] = r;
  s->head[s->insH] = str;
  if (str + 2 < s->n) zd_skip(s, str);
  return r;
}

static inline intptr_t zd_longest(zdeflate_t *s, intptr_t cur) {
  const intptr_t look = s->n - s->strstart;
  intptr_t chain = s->maxChain, nice = s->niceMatch;
  const intptr_t limit = s->strstart > s->maxDist ? s->strstart - s->maxDist : 0;
  if (s->prevLength >= s->goodMatch) chain >>= 2;
  if (nice > look) nice = look;
  intptr_t *const nx[4] = {0, s->nx4, s->nx8, s->nx16};   /* level 0: zlib's chain */
  const intptr_t best = longest_skip(s->plain, s->n, s->prev, nx, s->ord, s->wmask, s->strstart,
                                     cur, limit, chain, s->prevLength, nice, &s->matchStart);
  return best <= look ? best : look;
}

static inline void zd_token(zdeflate_t *s, intptr_t len, intptr_t dist) {
  s->tokLen[s->nTok] = (uint16_t)len; s->tokVal[s->nTok] = (uint16_t)dist;
  if (s->checkNow && (s->nTok >= s->refN || s->refLen[s->nTok] != len || s->refVal[s->nTok] != dist)) s->stop = 1;
  s->nTok++;
}
static inline int zd_lit(zdeflate_t *s, int c) {
  zd_token(s, 0, c);
  s->lfreq[c]++;
  return ++s->symNext == s->symEnd;
}
static inline int zd_dist(zdeflate_t *s, intptr_t dist, intptr_t lenMinus3) {
  zd_token(s, lenMinus3 + MIN_MATCH, dist);
  s->lfreq[s->lengthCode[lenMinus3] + 257]++;
  s->dfreq[s->distCode[dist - 1]]++;
  return ++s->symNext == s->symEnd;
}

intptr_t ppaz_deflate(zdeflate_t *s) {
  if (s->pending) { s->strstart++; s->pending = 0; }
  for (;;) {
    if (s->stop) return ZD_STOP;
    if (s->stopAt && s->strstart >= s->stopAt) return ZD_SEGEND;
    while (s->strstart - s->winBase >= s->wsize + s->maxDist) s->winBase += s->wsize;
    const intptr_t look = s->n - s->strstart;
    if (look == 0) break;
    intptr_t hashHead = 0;
    if (look >= MIN_MATCH) hashHead = zd_insert(s, s->strstart);
    if (s->fast) {
      int bflush;
      if (hashHead != 0 && s->strstart - hashHead <= s->maxDist) s->matchLength = zd_longest(s, hashHead);
      if (s->matchLength >= MIN_MATCH) {
        bflush = zd_dist(s, s->strstart - s->matchStart, s->matchLength - MIN_MATCH);
        if (s->matchLength <= s->maxLazy && look - s->matchLength >= MIN_MATCH) {
          s->matchLength--;
          do { s->strstart++; zd_insert(s, s->strstart); s->matchLength--; } while (s->matchLength != 0);
          s->strstart++;
        } else {
          s->strstart += s->matchLength;
          s->matchLength = 0;
          s->insH = win(s->plain, s->n, s->strstart);
          s->insH = ((s->insH << s->hashShift) ^ win(s->plain, s->n, s->strstart + 1)) & s->hashMask;
        }
      } else {
        bflush = zd_lit(s, s->plain[s->strstart]);
        s->strstart++;
      }
      if (bflush) return ZD_FLUSH;
      continue;
    }
    s->prevLength = s->matchLength; s->prevMatch = s->matchStart;
    s->matchLength = MIN_MATCH - 1;
    if (hashHead != 0 && s->prevLength < s->maxLazy && s->strstart - hashHead <= s->maxDist) {
      s->matchLength = zd_longest(s, hashHead);
      if (s->matchLength <= 5 && (s->filtered || (s->matchLength == MIN_MATCH && s->strstart - s->matchStart > TOO_FAR)))
        s->matchLength = MIN_MATCH - 1;
    }
    if (s->prevLength >= MIN_MATCH && s->matchLength <= s->prevLength) {
      const intptr_t maxInsert = s->strstart + look - MIN_MATCH;
      const int bflush = zd_dist(s, s->strstart - 1 - s->prevMatch, s->prevLength - MIN_MATCH);
      s->prevLength -= 2;
      do {
        s->strstart++;
        if (s->strstart <= maxInsert) zd_insert(s, s->strstart);
        s->prevLength--;
      } while (s->prevLength != 0);
      s->matchAvailable = 0;
      s->matchLength = MIN_MATCH - 1;
      s->strstart++;
      if (s->syncPos && s->nSync < s->maxSync && (s->strstart <= s->syncLo || s->strstart >= s->syncHi)) {
        s->syncPos[s->nSync] = s->strstart; s->syncTok[s->nSync] = s->nTok; s->nSync++;
      }
      if (bflush) return ZD_FLUSH;
    } else if (s->matchAvailable) {
      if (zd_lit(s, s->plain[s->strstart - 1])) { s->pending = 1; return ZD_FLUSH; }
      s->strstart++;
    } else {
      s->matchAvailable = 1;
      s->strstart++;
    }
  }
  if (!s->fast && s->matchAvailable) {
    zd_lit(s, s->plain[s->strstart - 1]);
    s->matchAvailable = 0;
    s->endLit = 1;
  }
  return ZD_DONE;
}

/* A segment's start: every position from `from` to `to` - 1 inserted as
   deflate_slow inserts them (all of them, up to n - MIN_MATCH), the hash
   started as fill_window starts it: the chains and the skip links at `to`
   are then the ones the whole run has there, within the window */
void ppaz_preinsert(zdeflate_t *s, intptr_t from, intptr_t to) {
  const uint8_t *p = s->plain;
  if (from + 1 < s->n) s->insH = (((intptr_t)p[from] << s->hashShift) ^ p[from + 1]) & s->hashMask;
  for (intptr_t str = from; str < to; str++)
    if (str + MIN_MATCH <= s->n) zd_insert(s, str);
}
