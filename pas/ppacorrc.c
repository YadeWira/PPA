/* Recipe kind 3's hot loops (ppacorr.pas): the predictor's search (zlib's
   longest_match on the predictor's own chains) and the rank walk. Same
   results as ppacorr's SearchPas and RankPas, which are the reference;
   test_preflate compares the two on every stream it is given.

   No library, no runtime: plain C, built by build_c.sh. */
#include <stdint.h>

typedef intptr_t sz;

/* ppacorr.pas's TPredState, field for field */
typedef struct {
  const uint8_t *plain; sz n;
  int32_t *head; int32_t *prev;
  sz ins;
  sz hmask, hshift;
  sz chain, nice, good, maxDist;
  sz hops;
  /* the C search's own links (ppacorr allocates them for it): each
     position's order in its hash chain (ord, by position and PREV_MASK; hcnt
     counts each hash's insertions) and the chains of the same 4 bytes'
     hash (head4: 2^16, link4: by position and PREV_MASK) */
  int32_t *ord; int32_t *hcnt; int32_t *head4; int32_t *link4;
} pcstate_t;

#define MIN_MATCH 3
#define MAX_MATCH 258
#define WINDOW 32768
#define PREV_MASK 65535

static inline sz hash3(const pcstate_t *s, sz q) {
  const uint8_t *p = s->plain + q;
  return (((((sz)p[0] << s->hshift) ^ p[1]) << s->hshift) ^ p[2]) & s->hmask;
}

static inline sz hash4(const pcstate_t *s, sz q) {
  uint32_t v; __builtin_memcpy(&v, s->plain + q, 4);
  return (sz)((v * 2654435761u) >> 16);
}

static void insert_up_to(pcstate_t *s, sz k) {
  if (k > s->n - MIN_MATCH) k = s->n - MIN_MATCH;
  while (s->ins <= k) {
    sz i = s->ins, h = hash3(s, i);
    s->prev[i & PREV_MASK] = s->head[h];
    s->head[h] = (int32_t)i;
    s->ord[i & PREV_MASK] = s->hcnt[h]++;
    if (i + 3 < s->n) {
      sz h4 = hash4(s, i);
      s->link4[i & PREV_MASK] = s->head4[h4];
      s->head4[h4] = (int32_t)i;
    }
    s->ins++;
  }
}

static sz chain_start(pcstate_t *s, sz q) {
  if (q < s->ins) return s->prev[q & PREV_MASK];
  insert_up_to(s, q - 1);
  return s->head[hash3(s, q)];
}

/* the length of the common prefix of a and b, at most max (max >= start) */
static inline sz common(const uint8_t *a, const uint8_t *b, sz start, sz max) {
  sz len = start;
  while (len + 8 <= max) {
    uint64_t x, y;
    __builtin_memcpy(&x, a + len, 8); __builtin_memcpy(&y, b + len, 8);
    if (x != y) {
      /* little-endian: the first differing byte is the lowest; elsewhere
         the bytes one by one below */
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
      return len + (__builtin_ctzll(x ^ y) >> 3);
#else
      break;
#endif
    }
    len += 8;
  }
  while (len < max && a[len] == b[len]) len++;
  return len;
}

sz pc_search(pcstate_t *s, sz q, sz prevLen, sz *dist) {
  const uint8_t *pl = s->plain;
  sz cur, limit, chainLen, bestLen, nice, look, len, maxLen;
  *dist = 0;
  look = s->n - q;
  if (look < MIN_MATCH || prevLen >= look) return 0;
  cur = chain_start(s, q);
  if (cur <= 0 || q - cur > s->maxDist) return 0;
  limit = q > s->maxDist ? q - s->maxDist : 0;
  chainLen = s->chain;
  if (prevLen >= s->good) chainLen >>= 2;
  if (chainLen < 1) chainLen = 1;
  nice = s->nice; if (nice > look) nice = look;
  maxLen = MAX_MATCH; if (maxLen > look) maxLen = look;
  bestLen = prevLen;
  {
    sz start = cur, startOrd = s->ord[cur & PREV_MASK], budget = chainLen;
    do {
      if (pl[cur + bestLen] == pl[q + bestLen] && pl[cur + bestLen - 1] == pl[q + bestLen - 1] &&
          pl[cur] == pl[q] && pl[cur + 1] == pl[q + 1]) {
        len = common(pl + cur, pl + q, 2, maxLen);
        if (len > bestLen) {
          bestLen = len; *dist = q - cur;
          if (len >= nice) goto done;
        }
      }
      if (bestLen >= MIN_MATCH && look > MIN_MATCH) goto skip;
      cur = s->prev[cur & PREV_MASK];
      chainLen--;
    } while (cur > limit && chainLen != 0);
    goto done;
  skip:
    /* From here only a candidate with the same 4 bytes as q can be longer
       than bestLen (>= 3): the walk goes along q's 4-byte chain instead,
       visiting the same candidates zlib's would, in the same order, up to
       the same hop (counted by the positions' order in their hash chain,
       the same for all of them: their first 3 bytes are q's). */
    {
      sz c4 = q < s->ins ? s->link4[q & PREV_MASK] : s->head4[hash4(s, q)];
      uint32_t key; __builtin_memcpy(&key, pl + q, 4);
      (void)start;
      while (c4 >= cur) c4 = s->link4[c4 & PREV_MASK];
      while (c4 > limit) {
        uint32_t v; __builtin_memcpy(&v, pl + c4, 4);
        if (v == key) {
          if (startOrd - s->ord[c4 & PREV_MASK] >= budget) break;
          if (pl[c4 + bestLen] == pl[q + bestLen] && pl[c4 + bestLen - 1] == pl[q + bestLen - 1]) {
            len = common(pl + c4, pl + q, 4, maxLen);
            if (len > bestLen) {
              bestLen = len; *dist = q - c4;
              if (len >= nice) break;
            }
          }
        }
        c4 = s->link4[c4 & PREV_MASK];
      }
    }
  }
done:
  if (bestLen > prevLen) return bestLen;
  *dist = 0;
  return 0;
}

sz pc_rank(pcstate_t *s, sz q, sz len, sz target, sz wantRank) {
  const uint8_t *pl = s->plain;
  sz cur, hops = 0, rank = 0;
  if (len < MIN_MATCH || q + len > s->n) return -1;
  cur = chain_start(s, q);
  while (cur >= 0 && q - cur <= WINDOW && hops < s->hops) {
    if (pl[cur + len - 1] == pl[q + len - 1] && common(pl + cur, pl + q, 0, len) == len) {
      if (wantRank) { if (rank == target) return q - cur; }
      else if (q - cur == target) return rank;
      rank++;
    }
    cur = s->prev[cur & PREV_MASK];
    hops++;
  }
  return -1;
}
