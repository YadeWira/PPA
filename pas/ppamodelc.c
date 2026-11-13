/* Layer 5's pixel loop, in C: one line of an image's unfiltered bytes,
   coded or decoded with ppamodel's model, bit for bit what ppamodel's
   Pascal reference does (the suite codes the same images with both and
   demands identical streams; PPA_NOC=1 picks the Pascal one).

   Called through ppamodel.pas, which owns every table and every buffer:
   this file takes no memory and calls no library, so the object links the
   same with FreePascal on every platform. Integer arithmetic only, the
   same as the Pascal: divisions truncate toward zero in both, products stay
   in 32 bits where the Pascal's do, the counters' update in 64. Build with
   -O3 -fwrapv -ffp-contract=off (pas/build_c.sh). */
#include <stdint.h>

#define NCTX 8
#define NIN (NCTX + 2)   /* the contexts, the match model and a bias */
#define NINP 12          /* a weight set's row: NIN and zeros (ppamodel's NINP) */

/* The mixer works on whole rows, NINP lanes, in GCC's and clang's vector
   types: SSE2 on x86, NEON on arm64, plain code where there is neither.
   Each lane does exactly what the Pascal does to one input (a division
   truncates toward zero: x / 2^s is (x + (x < 0 ? 2^s - 1 : 0)) >> s), so
   the sums and the weights are the reference's, bit for bit. */
typedef int32_t v4 __attribute__((vector_size(16)));
#define NV (NINP / 4)

/* macros, not functions: a vector passed or returned has no ABI where
   the build has no vector unit (32-bit x86 without SSE) */
#define LOAD4(v, p) __builtin_memcpy(&(v), (p), sizeof(v4))
#define STORE4(p, v) __builtin_memcpy((p), &(v), sizeof(v4))
#define DIV_POW2(x, s) (((x) + (((x) >> 31) & ((1 << (s)) - 1))) >> (s))
#define HSUM4(v) ((v)[0] + (v)[1] + (v)[2] + (v)[3])
#define MINLEN 6

/* ppamodel's TCounter: the probability as p xor 0x8000, its count */
typedef struct { uint16_t q; uint8_t n, pad; } ctr_t;

/* ppamodel.TRowArgs, as FreePascal lays it out: pointers and SizeInt */
typedef struct {
  uint8_t *row;            /* the line, written when decoding */
  const uint8_t *prior;    /* the line above in the same pass, or the line itself */
  intptr_t rb, bpp, hasPrior;
  ctr_t *t[NCTX];
  int32_t *w;              /* the mixer: [16 * 8][NIN] */
  const int32_t *recip;    /* ppaarith.RECIPROCAL */
  const int16_t *stretch;  /* ppaarith.STRETCH_TAB */
  const uint16_t *squash;  /* ppaarith.SQUASH_TAB */
  intptr_t bucketBits, limit, wMax, rate, stretchMax;
  uint32_t *x1, *x2, *x;   /* the coder's state (x: the decoder's only) */
  uint8_t *buf;            /* the encoder's output, or the decoder's input */
  intptr_t *pos;           /* where in buf */
  intptr_t len;            /* the decoder's input length */
  intptr_t encoding;
  uint16_t *apm;           /* the final refinement: [16][256][33] */
  const uint8_t *prior2;   /* the line two above in the same pass, or NULL */
  /* the match model: the image's bytes from the start, where this line
     starts in them, a hash table of positions, its bits, the match's state
     (where it points, how long it is) and its counters [16][2] */
  const uint8_t *data;
  intptr_t rowPos;
  uint32_t *mtab;
  intptr_t mbits;
  intptr_t *mptr, *mlen;
  ctr_t *mm;
  intptr_t sample16;       /* 16-bit samples: two bytes each, high first */
  intptr_t bandStart;      /* where the band starts in data: nothing before it is read */
} rowargs_t;

static inline uint32_t hash3(uint32_t a, uint32_t b, uint32_t c) {
  uint32_t r = (a * 2654435761u) ^ (b * 2246822519u) ^ (c * 3266489917u);
  return r ^ (r >> 15);
}

static inline uint32_t bucket_hash(uint32_t ctx, uint32_t nib) {
  uint32_t r = ctx ^ (nib * 2654435761u);
  return r ^ ((r >> 13) * 2246822519u);
}

/* ppamodel's CounterUpdate: p moves toward the target by recip[n] / 65536
   of the way, the product truncated toward zero, and n counts up to nmax.
   No branch, no 64-bit product: |target - p| < 2^16 and recip[n] < 2^16, so
   |product| fits 32 bits unsigned, and truncating toward zero is the floor
   of |product| / 2^16 with the sign put back. */
static inline void ctr_update(ctr_t *c, int target, const int32_t *recip, int nmax) {
  int pp = c->q ^ 0x8000, d = target - pp, sg = d >> 31;
  uint32_t m = ((uint32_t)((d ^ sg) - sg) * (uint32_t)recip[c->n]) >> 16;
  int q = ((int)m ^ sg) - sg;
  c->q = (uint16_t)((uint16_t)(pp + q) ^ 0x8000);
  c->n = (uint8_t)(c->n + (c->n < nmax));
}

static inline int abs_i(int v) { return v < 0 ? -v : v; }
static inline int clamp255(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }

void ppam_row(rowargs_t *a) {
  uint8_t *row = a->row;
  const uint8_t *prior = a->prior;
  const intptr_t rb = a->rb, bpp = a->bpp;
  const int hasPrior = (int)a->hasPrior;
  const uint32_t bmask = ((uint32_t)1 << a->bucketBits) - 1;
  const int bshift = 32 - (int)a->bucketBits;
  const int limit = (int)a->limit, wMax = (int)a->wMax, rate = (int)a->rate, smax = (int)a->stretchMax;
  const int enc = (int)a->encoding;
  uint32_t x1 = *a->x1, x2 = *a->x2, x = enc ? 0 : *a->x;
  intptr_t pos = *a->pos;
  uint8_t *buf = a->buf;
  const intptr_t len = a->len;
  intptr_t k = bpp - 1;
  ctr_t *t[NCTX];
  const int16_t *stretch = a->stretch;
  const int32_t *recip = a->recip;
  const int nmax = limit < 255 ? limit : 255;
  for (int i = 0; i < NCTX; i++) t[i] = a->t[i];
  /* the inputs past NIN stay 0: their lanes add nothing, change no weight */

  for (intptr_t xx = 0; xx < rb; xx++) {
    int W, N, NW, NE, grad, avg, res, act;
    uint32_t base[NCTX], bkt[NCTX], idx[NCTX];
    int32_t st[NINP];
    for (int i = NIN; i < NINP; i++) st[i] = 0;
    if (++k == bpp) k = 0;
    W = xx >= bpp ? row[xx - bpp] : 0;
    N = hasPrior ? prior[xx] : W;
    NW = (hasPrior && xx >= bpp) ? prior[xx - bpp] : N;
    NE = (hasPrior && xx + bpp < rb) ? prior[xx + bpp] : N;
    grad = clamp255(W + N - NW);
    {
      int d = abs_i(W - NW) + abs_i(N - NW) + abs_i(N - NE);
      act = d == 0 ? 0 : d < 4 ? 1 : d < 8 ? 2 : d < 16 ? 3 : d < 32 ? 4 : d < 64 ? 5 : d < 128 ? 6 : 7;
    }
    avg = (W + N + 1) >> 1;
    int dW = 0, dN = 0, res2 = 0;
    if (k > 1) {
      /* the channel two before (R for B): its residual over its gradient */
      intptr_t i = xx - 2;
      int j = i >= bpp ? row[i - bpp] : 0;
      int nd = hasPrior ? prior[i] : j;
      int b = (hasPrior && i >= bpp) ? prior[i - bpp] : nd;
      res2 = row[i] - clamp255(j + nd - b);
    }
    if (k > 0) {
      intptr_t i = xx - 1;
      int j, nd, b;
      res = row[i];
      j = i >= bpp ? row[i - bpp] : 0;
      nd = hasPrior ? prior[i] : j;
      b = (hasPrior && i >= bpp) ? prior[i - bpp] : nd;
      dW = res - j;             /* the previous channel's change from W */
      dN = res - nd;            /* and from N */
      res -= clamp255(j + nd - b);
    } else res = 0;
    base[0] = hash3((uint32_t)k, (uint32_t)W, 1);
    base[1] = hash3((uint32_t)k, (uint32_t)N, 2);
    base[2] = hash3((uint32_t)k, (uint32_t)clamp255(N + dN), 3);
    base[3] = hash3((uint32_t)k, (uint32_t)avg + ((uint32_t)clamp255(NE) << 8), 4);
    base[4] = hash3((uint32_t)k, (uint32_t)clamp255(W + dW), 5);
    {
      int NN = (hasPrior && a->prior2) ? a->prior2[xx] : N;
      int WW = xx >= 2 * bpp ? row[xx - 2 * bpp] : W;
      base[5] = hash3((uint32_t)k, (uint32_t)clamp255(grad + (k > 1 ? (res + res2) / 2 : res)) | ((uint32_t)(res2 + 256) << 8), 7);
      base[6] = hash3((uint32_t)k, (uint32_t)clamp255(2 * N - NN) | ((uint32_t)clamp255(2 * W - WW) << 8), 8);
    }
    if (a->sample16) {
      /* 16-bit samples: predicted as 16-bit values. The high byte by the
         prediction's top bits; the low one by what the prediction leaves
         once the high byte is known */
      intptr_t s0 = xx - (k & 1);              /* the sample's high byte */
      int w16, n16, nw16, g16, a16;
      w16 = s0 >= bpp ? (row[s0 - bpp] << 8) | row[s0 - bpp + 1] : 0;
      n16 = hasPrior ? (prior[s0] << 8) | prior[s0 + 1] : w16;
      nw16 = (hasPrior && s0 >= bpp) ? (prior[s0 - bpp] << 8) | prior[s0 - bpp + 1] : n16;
      g16 = w16 + n16 - nw16;
      if (g16 < 0) g16 = 0;
      if (g16 > 65535) g16 = 65535;
      a16 = (w16 + n16 + 1) >> 1;
      if ((k & 1) == 0) {
        base[5] = hash3((uint32_t)k, (uint32_t)(g16 >> 4), 11);
        base[6] = hash3((uint32_t)k, (uint32_t)(a16 >> 4), 12);
      } else {
        int hi = row[s0] << 8, lg = g16 - hi, la = a16 - hi;
        if (lg < -1) lg = -1;
        if (lg > 256) lg = 256;
        if (la < -1) la = -1;
        if (la > 256) la = 256;
        base[5] = hash3((uint32_t)k, (uint32_t)(lg + 1), 13);
        base[6] = hash3((uint32_t)k, (uint32_t)(la + 1) | ((uint32_t)(lg + 1) << 9), 14);
      }
    }
    {
      /* the whole pixel above (up to 4 bytes), with the bytes of this
         pixel coded so far */
      uint32_t np = 0, cur = 0;
      intptr_t p0 = xx - k, nb = bpp < 4 ? bpp : 4;
      for (intptr_t i = 0; i < nb; i++) np = (np << 8) | (hasPrior ? prior[p0 + i] : 0);
      for (intptr_t i = 0; i < k; i++) cur = (cur << 8) | row[p0 + i];
      base[7] = hash3((uint32_t)k * 0x1000193u ^ cur, np, 10);
    }

    int value = enc ? row[xx] : 0;
    uint32_t partial = 1;
    const intptr_t bpos = a->rowPos + xx;
    intptr_t mptr = *a->mptr, mlen = *a->mlen;
    int expected = mlen > 0 ? a->data[mptr] : 0;
    int mbucket = mlen > 15 ? 15 : (int)mlen;
    for (int i = 0; i < NCTX; i++) bkt[i] = ((bucket_hash(base[i], 0) >> bshift) & bmask) << 4;
    for (int j = 7; j >= 0; j--) {
      int node, dot, dot2, p, bit, err;
      int32_t *w, *w2;
      if (j == 3)
        for (int i = 0; i < NCTX; i++) bkt[i] = ((bucket_hash(base[i], partial) >> bshift) & bmask) << 4;
      if (j >= 4) node = (int)partial;
      else node = (1 << (3 - j)) | (int)(partial & ((1u << (3 - j)) - 1));
      w = a->w + ((k & 15) * 8 + j) * NINP;
      w2 = a->w + (128 + act * 8 + j) * NINP;
      for (int i = 0; i < NCTX; i++) {
        idx[i] = bkt[i] + (uint32_t)node;
        st[i] = stretch[(t[i][idx[i]].q ^ 0x8000) >> 4];
      }
      /* the match: while the bits so far agree with the byte it expects, its
         next bit, as sure as matches of its length have been */
      int mexp = -1;
      if (mlen > 0 && ((uint32_t)(expected | 256) >> (j + 1)) == partial) {
        mexp = (expected >> j) & 1;
        int sp = stretch[(a->mm[mbucket * 2 + mexp].q ^ 0x8000) >> 4];
        st[NCTX] = mexp ? sp : -sp;
      } else st[NCTX] = 0;
      st[NCTX + 1] = 256;
      {
        /* two weight sets, by channel and by the area's activity, averaged */
        v4 s1 = {0, 0, 0, 0}, s2 = {0, 0, 0, 0}, sv, wv, pr;
        for (int v = 0; v < NV; v++) {
          LOAD4(sv, st + 4 * v);
          LOAD4(wv, w + 4 * v); pr = wv * sv; s1 += DIV_POW2(pr, 13);
          LOAD4(wv, w2 + 4 * v); pr = wv * sv; s2 += DIV_POW2(pr, 13);
        }
        dot = HSUM4(s1);
        dot2 = HSUM4(s2);
      }
      dot = (dot + dot2) / 16;
      if (dot > smax) dot = smax;
      if (dot < -smax - 1) dot = -smax - 1;
      p = a->squash[dot + 2048];
      if (p < 1) p = 1;
      if (p > 65535) p = 65535;
      /* the APM: the mixer's output refined by the channel and the bits of
         the byte so far, interpolated between 33 points of its stretch */
      int sidx = dot + 2048, lo = sidx >> 7, wt = sidx & 127;
      uint16_t *ap = a->apm + (((k & 15) * 256 + partial) * 33);
      int pa = (ap[lo] * (128 - wt) + ap[lo + 1] * wt) >> 7;
      int pm = p;
      p = (p + 3 * pa) >> 2;
      if (p < 1) p = 1;
      if (p > 65535) p = 65535;
      {
        uint32_t xm = x1 + (uint32_t)(((uint64_t)(x2 - x1) * (uint32_t)p) >> 16);
        if (enc) {
          bit = (value >> j) & 1;
          if (bit) x2 = xm; else x1 = xm + 1;
          while (((x1 ^ x2) & 0xFF000000u) == 0) {
            buf[pos++] = (uint8_t)(x2 >> 24);
            x1 <<= 8;
            x2 = (x2 << 8) | 255;
          }
        } else {
          if (x <= xm) { bit = 1; x2 = xm; } else { bit = 0; x1 = xm + 1; }
          while (((x1 ^ x2) & 0xFF000000u) == 0) {
            uint8_t b = (pos >= 0 && pos < len) ? buf[pos] : 0;
            pos++;
            x1 <<= 8;
            x2 = (x2 << 8) | 255;
            x = (x << 8) | b;
          }
        }
      }
      {
        int ai = lo + (wt >> 6), g = bit ? 65535 : 0;
        ap[ai] = (uint16_t)(ap[ai] + (g - ap[ai]) / 64);
      }
      err = ((bit << 16) - pm) / 16;
      {
        const v4 er = {err * rate, err * rate, err * rate, err * rate};
        const v4 hi = {wMax, wMax, wMax, wMax}, lo = -hi;
        for (int v = 0; v < NV; v++) {
          v4 d, x, m;
          LOAD4(d, st + 4 * v); d = d * er; d = DIV_POW2(d, 16);
          LOAD4(x, w + 4 * v); x += d;
          m = x > hi; x = (x & ~m) | (hi & m);
          m = x < lo; x = (x & ~m) | (lo & m);
          STORE4(w + 4 * v, x);
          LOAD4(x, w2 + 4 * v); x += d;
          m = x > hi; x = (x & ~m) | (hi & m);
          m = x < lo; x = (x & ~m) | (lo & m);
          STORE4(w2 + 4 * v, x);
        }
      }
      for (int i = 0; i < NCTX; i++) {
        ctr_t *c = &t[i][idx[i]];
        ctr_update(c, bit ? 65535 : 1, recip, nmax);
      }
      if (mexp >= 0) {
        /* the counter learns whether the match was right */
        ctr_t *c = &a->mm[mbucket * 2 + mexp];
        ctr_update(c, (bit == mexp) ? 65535 : 1, recip, nmax);
      }
      partial = partial * 2 + (uint32_t)bit;
    }
    if (!enc) row[xx] = (uint8_t)(partial & 0xFF);
    {
      /* the match goes on or ends; then the last MINLEN bytes' hash, where
         they were last, and a new match from there when there is none */
      const int byte = (int)(partial & 0xFF);
      if (mlen > 0 && a->data[mptr] == byte) { mlen++; mptr++; } else mlen = 0;
      if (bpos + 1 - a->bandStart >= MINLEN) {
        uint32_t h = 0;
        for (int i = 1; i <= MINLEN; i++) h = (h + a->data[bpos + 1 - i] + 1) * 2654435761u;
        h >>= (32 - a->mbits);
        if (mlen == 0) {
          intptr_t cand = a->mtab[h];
          if (cand > 0) {
            intptr_t l = 0;
            while (l < 32 && cand - 1 - l >= a->bandStart && a->data[cand - 1 - l] == a->data[bpos - l]) l++;
            if (l >= MINLEN) { mlen = l; mptr = cand; }
          }
        }
        a->mtab[h] = (uint32_t)(bpos + 1);
      }
      if (mlen > 65535) mlen = 65535;
      *a->mptr = mptr; *a->mlen = mlen;
    }
  }
  *a->x1 = x1; *a->x2 = x2;
  if (!enc) *a->x = x;
  *a->pos = pos;
}

/* ---- ppamodel's byte model (TByteModel, CodeBytes), bit for bit what its
   Pascal reference does: the bytes kept as bytes (the structure, the
   streams that are not images, the static model's tables). Four hashed
   orders (0 to 3 bytes before) and a bias, mixed by the bit's position. */
typedef struct { uint16_t p; uint8_t n, pad; } abit_t;   /* ppaarith.TAdaptiveBit, p as p xor 0x8000 */

/* ppamodel.TBytesArgs */
typedef struct {
  abit_t *t[4];            /* TByteModel.t: 2^18 counters each */
  int32_t *w;              /* TByteModel.w: [8][5] */
  uint32_t *hist;          /* TByteModel.hist */
  uint8_t *data; intptr_t n;   /* the bytes: read when encoding, written when decoding */
  const int32_t *recip; const int16_t *stretch; const uint16_t *squash;
  uint32_t *x1, *x2, *x;   /* the coder's state (x: the decoder's only) */
  uint8_t *buf;            /* the encoder's output (room enough: the caller sees to it), or the decoder's input */
  intptr_t *pos;           /* where in buf */
  intptr_t len;            /* the decoder's input length */
  intptr_t encoding;
} bytesargs_t;

#define BT_BITS 18
#define BT_LIMIT 127
#define BT_WMAX (1 << 19)

static inline uint32_t byte_slot(int order, uint32_t hist, uint32_t partial) {
  uint32_t h = order == 0 ? 0 : order == 1 ? hist & 0xFF : order == 2 ? hist & 0xFFFF : hist & 0xFFFFFF;
  h = (h + ((uint32_t)order << 24)) * 2654435761u;
  return ((h >> (32 - BT_BITS)) ^ ((partial * 2246822519u) >> (32 - BT_BITS))) & ((1u << BT_BITS) - 1);
}

static inline __attribute__((always_inline)) void bytes_k(bytesargs_t *a, const int enc) {
  int32_t *const w = a->w;
  const int16_t *const st_tab = a->stretch;
  const uint16_t *const sq = a->squash;
  const int32_t *const recip = a->recip;
  uint32_t hist = *a->hist, x1 = *a->x1, x2 = *a->x2, x = enc ? 0 : *a->x;
  uint8_t *const buf = a->buf;
  intptr_t pos = *a->pos;
  const intptr_t len = a->len;
  for (intptr_t q = 0; q < a->n; q++) {
    const int value = enc ? a->data[q] : 0;
    uint32_t partial = 1;
    for (int j = 7; j >= 0; j--) {
      abit_t *c[4];
      int st[4], dot = 0;
      int32_t *const wj = w + j * 5;
      for (int i = 0; i < 4; i++) {
        c[i] = &a->t[i][byte_slot(i, hist, partial)];
        st[i] = st_tab[(c[i]->p ^ 0x8000) >> 4];
        dot += (wj[i] * st[i]) / 8192;
      }
      dot += (wj[4] * 256) / 8192;
      int d8 = dot / 8;
      d8 = d8 > 2047 ? 2047 : d8 < -2048 ? -2048 : d8;
      const int p = sq[d8 + 2048];
      const int pc = p < 1 ? 1 : p > 65535 ? 65535 : p;
      const uint32_t xm = x1 + (uint32_t)(((uint64_t)(x2 - x1) * (uint32_t)pc) >> 16);
      int bit;
      if (enc) {
        bit = (value >> j) & 1;
        if (bit) x2 = xm; else x1 = xm + 1;
        while (((x1 ^ x2) & 0xFF000000u) == 0) {
          buf[pos++] = (uint8_t)(x2 >> 24); x1 <<= 8; x2 = (x2 << 8) | 255;
        }
      } else {
        if (x <= xm) { bit = 1; x2 = xm; } else { bit = 0; x1 = xm + 1; }
        while (((x1 ^ x2) & 0xFF000000u) == 0) {
          const uint8_t b = (pos >= 0 && pos < len) ? buf[pos] : 0;
          pos++; x1 <<= 8; x2 = (x2 << 8) | 255; x = (x << 8) | b;
        }
      }
      const int err = ((bit << 16) - p) / 16;
      for (int i = 0; i < 4; i++) {
        int v = wj[i] + (st[i] * err * 12) / 65536;
        wj[i] = v > BT_WMAX ? BT_WMAX : v < -BT_WMAX ? -BT_WMAX : v;
      }
      {
        int v = wj[4] + (256 * err * 12) / 65536;
        wj[4] = v > BT_WMAX ? BT_WMAX : v < -BT_WMAX ? -BT_WMAX : v;
      }
      for (int i = 0; i < 4; i++) {
        /* TAdaptiveBit.Update on p xor 0x8000: toward the target by
           recip[n] / 65536 of the way, truncated toward zero */
        const int pp = c[i]->p ^ 0x8000;
        const int64_t prod = (int64_t)((bit ? 65535 : 1) - pp) * recip[c[i]->n];
        const int64_t dq = (prod + ((prod >> 63) & 0xFFFF)) >> 16;
        c[i]->p = (uint16_t)((pp + (int)dq) ^ 0x8000);
        if (c[i]->n < BT_LIMIT) c[i]->n++;
      }
      partial = partial * 2 + (uint32_t)bit;
    }
    const int v = (int)(partial & 0xFF);
    if (!enc) a->data[q] = (uint8_t)v;
    hist = ((hist << 8) | (uint32_t)v) & 0xFFFFFF;
  }
  *a->hist = hist; *a->x1 = x1; *a->x2 = x2;
  if (!enc) *a->x = x;
  *a->pos = pos;
}

void ppam_bytes(bytesargs_t *a) {
  if (a->encoding) bytes_k(a, 1); else bytes_k(a, 0);
}
