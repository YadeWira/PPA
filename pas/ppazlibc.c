/* Layer 2b's predictor, its hot spot in C: zlib's longest_match, bit for
   bit what ppazlib's Pascal LongestMatch does (the suite runs the predictor
   both ways and demands the same choices; PPA_NOC=1 picks the Pascal one).
   Positions are absolute into the input; a byte past its end reads as 0, as
   the Pascal's Win does. Takes no memory and calls no library. */
#include <stdint.h>

#define MAX_MATCH 258

/* how many bytes a and b have equal from the start, up to top: 8 at a time
   where the compiler gives a count of trailing zeros, the same count */
static inline intptr_t common(const uint8_t *a, const uint8_t *b, intptr_t from, intptr_t top) {
  intptr_t len = from;
#if defined(__GNUC__) || defined(__clang__)
  while (len + 8 <= top) {
    uint64_t x, y, d;
    __builtin_memcpy(&x, a + len, 8);
    __builtin_memcpy(&y, b + len, 8);
    d = x ^ y;
    if (d) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
      return len + (__builtin_ctzll(d) >> 3);
#else
      return len + (__builtin_clzll(d) >> 3);
#endif
    }
    len += 8;
  }
#endif
  while (len < top && a[len] == b[len]) len++;
  return len;
}

static inline uint8_t win(const uint8_t *p, intptr_t n, intptr_t i) { return i < n ? p[i] : 0; }

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
