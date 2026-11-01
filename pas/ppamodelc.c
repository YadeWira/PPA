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

#define NCTX 6
#define NIN (NCTX + 1)

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
} rowargs_t;

static inline uint32_t hash3(uint32_t a, uint32_t b, uint32_t c) {
  uint32_t r = (a * 2654435761u) ^ (b * 2246822519u) ^ (c * 3266489917u);
  return r ^ (r >> 15);
}

static inline uint32_t bucket_hash(uint32_t ctx, uint32_t nib) {
  uint32_t r = ctx ^ (nib * 2654435761u);
  return r ^ ((r >> 13) * 2246822519u);
}

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

  for (intptr_t xx = 0; xx < rb; xx++) {
    int W, N, NW, NE, grad, avg, res;
    uint32_t base[NCTX], bkt[NCTX], idx[NCTX];
    int st[NIN];
    if (++k == bpp) k = 0;
    W = xx >= bpp ? row[xx - bpp] : 0;
    N = hasPrior ? prior[xx] : W;
    NW = (hasPrior && xx >= bpp) ? prior[xx - bpp] : N;
    NE = (hasPrior && xx + bpp < rb) ? prior[xx + bpp] : N;
    grad = clamp255(W + N - NW);
    avg = (W + N + 1) >> 1;
    if (k > 0) {
      intptr_t i = xx - 1;
      int j, nd, b;
      res = row[i];
      j = i >= bpp ? row[i - bpp] : 0;
      nd = hasPrior ? prior[i] : j;
      b = (hasPrior && i >= bpp) ? prior[i - bpp] : nd;
      res -= clamp255(j + nd - b);
    } else res = 0;
    base[0] = hash3((uint32_t)k, (uint32_t)W, 1);
    base[1] = hash3((uint32_t)k, (uint32_t)N, 2);
    base[2] = hash3((uint32_t)k, (uint32_t)grad, 3);
    base[3] = hash3((uint32_t)k, (uint32_t)avg + ((uint32_t)clamp255(NE) << 8), 4);
    base[4] = hash3((uint32_t)k, (uint32_t)((W >> 2) | ((N >> 2) << 6) | ((NE >> 2) << 12)), 5);
    base[5] = hash3((uint32_t)k, (uint32_t)clamp255(grad + res) | ((uint32_t)(res + 256) << 8), 6);

    int value = enc ? row[xx] : 0;
    uint32_t partial = 1;
    for (int i = 0; i < NCTX; i++) bkt[i] = ((bucket_hash(base[i], 0) >> bshift) & bmask) << 4;
    for (int j = 7; j >= 0; j--) {
      int node, dot = 0, p, bit, err;
      int32_t *w;
      if (j == 3)
        for (int i = 0; i < NCTX; i++) bkt[i] = ((bucket_hash(base[i], partial) >> bshift) & bmask) << 4;
      if (j >= 4) node = (int)partial;
      else node = (1 << (3 - j)) | (int)(partial & ((1u << (3 - j)) - 1));
      w = a->w + ((k & 15) * 8 + j) * NIN;
      for (int i = 0; i < NCTX; i++) {
        idx[i] = bkt[i] + (uint32_t)node;
        st[i] = a->stretch[(a->t[i][idx[i]].q ^ 0x8000) >> 4];
        dot += (w[i] * st[i]) / 8192;
      }
      st[NCTX] = 256;
      dot += (w[NCTX] * st[NCTX]) / 8192;
      dot /= 8;
      if (dot > smax) dot = smax;
      if (dot < -smax - 1) dot = -smax - 1;
      p = a->squash[dot + 2048];
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
      err = ((bit << 16) - p) / 16;
      for (int i = 0; i < NIN; i++) {
        int v = w[i] + (st[i] * err * rate) / 65536;
        if (v > wMax) v = wMax;
        if (v < -wMax) v = -wMax;
        w[i] = v;
      }
      for (int i = 0; i < NCTX; i++) {
        ctr_t *c = &a->t[i][idx[i]];
        int pp = c->q ^ 0x8000, target = bit ? 65535 : 1;
        int64_t q = (int64_t)(target - pp) * a->recip[c->n];
        q = (q + ((q >> 63) & 0xFFFF)) >> 16;
        c->q = (uint16_t)((uint16_t)(pp + q) ^ 0x8000);
        if (c->n < limit && c->n < 255) c->n++;
      }
      partial = partial * 2 + (uint32_t)bit;
    }
    if (!enc) row[xx] = (uint8_t)(partial & 0xFF);
  }
  *a->x1 = x1; *a->x2 = x2;
  if (!enc) *a->x = x;
  *a->pos = pos;
}
