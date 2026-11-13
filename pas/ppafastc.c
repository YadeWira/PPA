/* Layer 5's fast image model, its loop in C: one line of 8-bit samples
   (gray, gray and alpha, RGB, RGBA), coded or decoded, bit for bit what
   ppafast.pas's Pascal reference does (the suite codes the same images with
   both and demands identical streams; PPA_NOC=1 picks the Pascal one).

   Each sample is predicted by eight predictors blended by how wrong each
   was around it (the colour channels on their difference to the channel
   before), and its residual is coded with a few binary decisions: zero or
   not and the magnitude's first classes from two counters mixed (the zero
   with an APM too), a second guess (a value seen before) when that is far
   from the prediction from four, the sign and the rest from one each. A
   match model finds runs seen before.

   Called through ppafast.pas, which owns every table and buffer: this file
   takes no memory and calls no library. Integer arithmetic only. SSE2
   where the compiler has it, the same results without. Build with -O3
   -fwrapv -ffp-contract=off (pas/build_c.sh). */
#include <stdint.h>
#if defined(__SSE2__) && !defined(PPA_NO_SIMD)
#include <emmintrin.h>
#define FM_SSE2 1
/* a value the compiler must take as it is here: keeps it from merging a
   chain of inserts back into its own (longer) shuffle sequence */
#define FM_KEEP(v) __asm__("" : "+x"(v))
#endif

#define NP 8          /* predictors */
#define EB 16         /* energy bins */
#define QT 4          /* a second guess farther than this from the prediction */
#define Q_EB 1        /* and only where the energy bin is at most this, or a match runs */
#define FM_PAD 2      /* a padded line: FM_PAD pixels each side */
#define W_LIMIT 131071   /* a weight's bound: four inputs and the bias stay inside 32 bits */

typedef struct { uint16_t p; uint8_t n, pad; } ctr_t;
typedef struct { int32_t w[128][5]; uint16_t apm[128][33]; } mix_t;

/* ppafast.TFastTables */
typedef struct {
  ctr_t nzm[4][625][4];
  ctr_t qd[4][10][4], qs[4][625];
  ctr_t ns[4][625];
  ctr_t ncl[2][4][625];
  ctr_t cls[4][EB][8], mant[4][EB][8], low[4][8][8];
  mix_t mz, mq, mc[2];
} fm_tables_t;

/* ppafast.TFastArgs */
typedef struct {
  fm_tables_t *t;
  ctr_t *h; intptr_t hbits;            /* the hashed counters */
  uint16_t *ctab; intptr_t cbits;      /* each exact neighbourhood's last value + 1 */
  uint32_t *mtab; intptr_t mbits;      /* the match model's positions + 1 */
  uint8_t *px; int16_t *fe; uint8_t *pe;   /* three padded lines of pixels, two of residuals, three of the predictors' errors */
  intptr_t w, nc, y;                   /* the line's width in pixels, bytes a pixel, its number in the pass or band */
  uint8_t *data; intptr_t rowPos, bandStart;   /* the image's bytes, where this line starts, where the band starts */
  intptr_t *mptr, *mlen;
  const int32_t *recip; const int16_t *stretch; const uint16_t *squash;
  const int32_t *invsq; const uint8_t *ebin; const uint8_t *q3;
  uint32_t *x1, *x2, *x; uint8_t *buf; intptr_t *pos; intptr_t len, encoding;
} fm_args_t;

/* the tables, copied out of fm_args_t: a byte stored through a pointer may
   alias anything, and the compiler would load them again after each */
typedef struct { const int16_t *st; const uint16_t *sq; const int32_t *rc; } tabs_t;

static inline uint32_t hsh(uint32_t a) { a *= 2654435761u; return a ^ (a >> 15); }
static inline int clampi(int v, int a, int b) { return v < a ? a : v > b ? b : v; }
/* the same, for a value nearly always inside: one compare and a branch
   the processor predicts */
static inline int clamp_rare(int v, int lo, int hi) {
  if (__builtin_expect((unsigned)(v - lo) > (unsigned)(hi - lo), 0)) v = v < lo ? lo : hi;
  return v;
}
static inline int clamp255(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }
static inline int iabs(int v) { return v < 0 ? -v : v; }
static inline int imin(int a, int b) { return a < b ? a : b; }
static inline int imax(int a, int b) { return a > b ? a : b; }
/* LOCO-I's MED, W, N or W + N - NW: the median of the three, without a branch */
static inline int med3(int a, int b, int c) { return imax(imin(a, b), imin(imax(a, b), c)); }

/* ppaarith's counter update, as ppamodelc.c's ctr_update but on p itself */
/* p moves toward the target by recip[n] / 65536 of the way (the product's
   floor), n counts up to lim */
static inline void cupd(ctr_t *c, int bit, int lim, const int32_t *recip) {
  const int d = (bit ? 65535 : 1) - c->p;
  c->p = (uint16_t)(c->p + (int)(((int64_t)d * recip[c->n]) >> 16));
  c->n = (uint8_t)(c->n + (c->n < lim));
}

typedef struct { uint32_t x1, x2, x; uint8_t *buf; intptr_t pos, len; int enc; } coder_t;

static inline int code_bit(coder_t *c, int bit, int p) {
  const uint32_t xm = c->x1 + (uint32_t)(((uint64_t)(c->x2 - c->x1) * (uint32_t)p) >> 16);
  if (c->enc) {
    if (bit) c->x2 = xm; else c->x1 = xm + 1;
    while (((c->x1 ^ c->x2) & 0xFF000000u) == 0) {
      c->buf[c->pos++] = (uint8_t)(c->x2 >> 24); c->x1 <<= 8; c->x2 = (c->x2 << 8) | 255;
    }
  } else {
    if (c->x <= xm) { bit = 1; c->x2 = xm; } else { bit = 0; c->x1 = xm + 1; }
    while (((c->x1 ^ c->x2) & 0xFF000000u) == 0) {
      const uint8_t b = (c->pos >= 0 && c->pos < c->len) ? c->buf[c->pos] : 0;
      c->pos++; c->x1 <<= 8; c->x2 = (c->x2 << 8) | 255; c->x = (c->x << 8) | b;
    }
  }
  return bit;
}

/* a decision from four counters and a bias, mixed by the weights sel picks;
   the zero decision (apm) refines the mix with an APM as well */
static inline int mixbit(coder_t *c, const tabs_t a, mix_t *m, int apm, ctr_t *c0, ctr_t *c1, ctr_t *c2, ctr_t *c3,
                         int sel, int bit) {
  const int16_t *st = a.st;
  const int s0 = st[c0->p >> 4], s1 = st[c1->p >> 4], s2 = st[c2->p >> 4], s3 = st[c3->p >> 4];
  int32_t *w = m->w[sel];
  int dot = (w[0] * s0 + w[1] * s1 + w[2] * s2 + w[3] * s3 + w[4] * 256) >> 16;
  dot = clamp_rare(dot, -2047, 2047);
  const int p = a.sq[dot + 2048];
  int pf, lo = 0, wt = 0;
  uint16_t *ap = 0;
  if (apm) {
    const int sidx = dot + 2048;
    lo = sidx >> 7; wt = sidx & 127;
    ap = m->apm[sel];
    pf = (p + 3 * ((ap[lo] * (128 - wt) + ap[lo + 1] * wt) >> 7)) >> 2;
  } else pf = p;
  pf = clamp_rare(pf, 32, 65535 - 32);
  bit = code_bit(c, bit, pf);
  const int err = ((bit << 16) - p) >> 4;
  w[0] = clamp_rare(w[0] + ((s0 * err) >> 10), -W_LIMIT, W_LIMIT); w[1] = clamp_rare(w[1] + ((s1 * err) >> 10), -W_LIMIT, W_LIMIT);
  w[2] = clamp_rare(w[2] + ((s2 * err) >> 10), -W_LIMIT, W_LIMIT); w[3] = clamp_rare(w[3] + ((s3 * err) >> 10), -W_LIMIT, W_LIMIT);
  w[4] = clamp_rare(w[4] + ((256 * err) >> 10), -W_LIMIT, W_LIMIT);
  cupd(c0, bit, 255, a.rc); cupd(c1, bit, 255, a.rc); cupd(c2, bit, 255, a.rc); cupd(c3, bit, 255, a.rc);
  if (apm) {
    const int ai = lo + (wt >> 6);
    ap[ai] = (uint16_t)(ap[ai] + (((bit ? 65535 : 0) - ap[ai]) >> 6));
  }
  return bit;
}

/* the same from two counters (weights 0, 1 and the bias's, 4) */
static inline int mixbit2(coder_t *c, const tabs_t a, mix_t *m, int apm, ctr_t *c0, ctr_t *c1, int sel, int bit) {
  const int16_t *st = a.st;
  const int s0 = st[c0->p >> 4], s1 = st[c1->p >> 4];
  int32_t *w = m->w[sel];
  int dot = (w[0] * s0 + w[1] * s1 + w[4] * 256) >> 16;
  dot = clamp_rare(dot, -2047, 2047);
  const int p = a.sq[dot + 2048];
  int pf, lo = 0, wt = 0;
  uint16_t *ap = 0;
  if (apm) {
    const int sidx = dot + 2048;
    lo = sidx >> 7; wt = sidx & 127;
    ap = m->apm[sel];
    pf = (p + 3 * (ap[lo] + (((ap[lo + 1] - ap[lo]) * wt) >> 7))) >> 2;
  } else pf = p;
  pf = clamp_rare(pf, 32, 65535 - 32);
  bit = code_bit(c, bit, pf);
  const int err = ((bit << 16) - p) >> 4;
  w[0] = clamp_rare(w[0] + ((s0 * err) >> 10), -W_LIMIT, W_LIMIT); w[1] = clamp_rare(w[1] + ((s1 * err) >> 10), -W_LIMIT, W_LIMIT);
  w[4] = clamp_rare(w[4] + ((256 * err) >> 10), -W_LIMIT, W_LIMIT);
  cupd(c0, bit, 255, a.rc); cupd(c1, bit, 255, a.rc);
  if (apm) {
    const int ai = lo + (wt >> 6);
    ap[ai] = (uint16_t)(ap[ai] + (((bit ? 65535 : 0) - ap[ai]) >> 6));
  }
  return bit;
}

/* a class decision (two counters, no APM), out of the loop's body: the
   weights row picked by the caller, six arguments, all in registers */
static __attribute__((noinline)) int mixcls(coder_t *c, int32_t *w, ctr_t *c0, ctr_t *c1, int bit, const tabs_t *a) {
  const int16_t *st = a->st;
  const int s0 = st[c0->p >> 4], s1 = st[c1->p >> 4];
  int dot = (w[0] * s0 + w[1] * s1 + w[4] * 256) >> 16;
  dot = clamp_rare(dot, -2047, 2047);
  const int p = a->sq[dot + 2048];
  bit = code_bit(c, bit, clamp_rare(p, 32, 65535 - 32));
  const int err = ((bit << 16) - p) >> 4;
  w[0] = clamp_rare(w[0] + ((s0 * err) >> 10), -W_LIMIT, W_LIMIT); w[1] = clamp_rare(w[1] + ((s1 * err) >> 10), -W_LIMIT, W_LIMIT);
  w[4] = clamp_rare(w[4] + ((256 * err) >> 10), -W_LIMIT, W_LIMIT);
  cupd(c0, bit, 255, a->rc); cupd(c1, bit, 255, a->rc);
  return bit;
}

static inline int onebit(coder_t *c, const tabs_t a, ctr_t *k, int bit) {
  bit = code_bit(c, bit, clamp_rare(k->p, 32, 65535 - 32));
  cupd(k, bit, 60, a.rc);
  return bit;
}

#ifdef FM_SSE2
/* 16 bits from memory (x86: little-endian, unaligned allowed) */
static inline int ld16(const uint8_t *p) { uint16_t v; __builtin_memcpy(&v, p, 2); return v; }
/* lane k, one pextrw (the barrier keeps the compiler from doing the
   arithmetic on it in the vector first, then taking the lanes out with
   longer shuffles) */
#define ext16(v, k) __extension__({ uintptr_t j_ = (unsigned)_mm_extract_epi16(v, k); __asm__("" : "+r"(j_)); j_; })
#endif

static inline int fold(int e) { return e < -128 ? e + 256 : e > 127 ? e - 256 : e; }

static inline __attribute__((always_inline)) void row_nc(fm_args_t *a, const int nc, const int enc) {
  fm_tables_t *const T = a->t;
  ctr_t *const h = a->h;
  const int hs = 32 - (int)a->hbits, cs = 32 - (int)a->cbits;
  const int w = (int)a->w, y = (int)a->y;
  const intptr_t rs = (intptr_t)(w + 2 * FM_PAD) * nc;
  uint8_t *cur = a->px + (y % 3) * rs + FM_PAD * nc;
  uint8_t *up = a->px + ((y + 2) % 3) * rs + FM_PAD * nc;
  uint8_t *up2 = a->px + ((y + 1) % 3) * rs + FM_PAD * nc;
  int16_t *fc = a->fe + (y & 1) * rs + FM_PAD * nc, *fu = a->fe + ((y + 1) & 1) * rs + FM_PAD * nc;
  uint8_t *ec = a->pe + ((y % 3) * rs + FM_PAD * nc) * 8;
  uint8_t *eu = a->pe + (((y + 2) % 3) * rs + FM_PAD * nc) * 8;
  uint8_t *eu2 = a->pe + (((y + 1) % 3) * rs + FM_PAD * nc) * 8;
  uint8_t *const data = a->data, *const src = data + a->rowPos;
  const int mbits = (int)a->mbits;
  intptr_t mptr = *a->mptr, mlen = *a->mlen;
  const tabs_t tb = {a->stretch, a->squash, a->recip};
  const int32_t *const invsq = a->invsq;
  const uint8_t *const ebin = a->ebin, *const q3 = a->q3;
  uint16_t *const ctab = a->ctab;
  uint32_t *const mtab = a->mtab;
  const intptr_t bandStart = a->bandStart, rowPos = a->rowPos;
  coder_t c;
  c.x1 = *a->x1; c.x2 = *a->x2; c.x = enc ? 0 : *a->x; c.buf = a->buf; c.pos = *a->pos; c.len = a->len; c.enc = enc;

  /* the first line of a pass or band sees itself as the lines above. The
     buffers start at zero (ppafast's NewPass), and nothing writes the left
     padding, which stays so; the right one is the last pixel above,
     repeated */
  if (y == 0) { up = cur; up2 = cur; } else if (y == 1) up2 = up;
  for (int k = 0; k < FM_PAD * nc; k++) up[w * nc + k] = up[(w - 1) * nc + k % nc];

  for (intptr_t x = 0; x < w; x++) {
    int resPrev = 0, resPrev2 = 0, xPrev = 0;
    /* the channel before's neighbours, which a colour channel's differences need */
    int pW = 0, pN = 0, pNW = 0, pNE = 0, pWW = 0, pNN = 0;
    /* each channel its own copy (nc is a constant here): ch, chx and the
       colour test fold away */
#if defined(__clang__)
#pragma clang loop unroll(full)
#elif defined(__GNUC__)
#pragma GCC unroll 4
#endif
    for (int ch = 0; ch < nc; ch++) {
      const intptr_t i = x * nc + ch; const int chx = ch & 3;
      const int W = cur[i - nc], N = up[i], NW = up[i - nc], NE = up[i + nc], WW = cur[i - 2 * nc], NN = up2[i];
      int pr[NP];
      if (ch == 0 || ch == 3 || nc < 3) {
        pr[0] = W; pr[1] = N; pr[2] = NE; pr[3] = W + N - NW;
        pr[4] = med3(W, N, W + N - NW);
        pr[5] = (W + NE + 1) >> 1;
        pr[6] = 2 * W - WW; pr[7] = 2 * N - NN;
      } else {
        /* a colour channel: its difference to the channel before, predicted
           (cur[i - nc - 1] is the channel before's W, and so on) */
        const int dW = W - pW, dN = N - pN, dNW = NW - pNW, dNE = NE - pNE;
        const int dWW = WW - pWW, dNN = NN - pNN;
        pr[0] = xPrev + dW; pr[1] = xPrev + dN; pr[2] = xPrev + dNE; pr[3] = xPrev + dW + dN - dNW;
        pr[4] = xPrev + med3(dW, dN, dW + dN - dNW);
        pr[5] = xPrev + ((dW + dNE + 1) >> 1);
        pr[6] = xPrev + 2 * dW - dWW; pr[7] = xPrev + 2 * dN - dNN;
      }
      pW = W; pNW = NW; pNE = NE; pWW = WW;
      /* the blend: each predictor (clamped) weighed by its errors around */
      const uint8_t *eW = ec + (intptr_t)(i - nc) * 8, *eN = eu + (intptr_t)i * 8, *eNW = eu + (intptr_t)(i - nc) * 8;
      const uint8_t *eNE = eu + (intptr_t)(i + nc) * 8, *eWW = ec + (intptr_t)(i - 2 * nc) * 8, *eNN = eu2 + (intptr_t)i * 8;
      int sw, sp, pmx, pmn;
#ifdef FM_SSE2
      __m128i pv;
      {
        const __m128i z0 = _mm_setzero_si128();
#define LD8(p) _mm_unpacklo_epi8(_mm_loadl_epi64((const __m128i *)(const void *)(p)), z0)
        __m128i e = _mm_add_epi16(_mm_slli_epi16(_mm_add_epi16(LD8(eW), LD8(eN)), 1),
                    _mm_add_epi16(_mm_add_epi16(LD8(eNW), LD8(eNE)), _mm_add_epi16(LD8(eWW), LD8(eNN))));
#undef LD8
        e = _mm_min_epi16(e, _mm_set1_epi16(1023));
        /* each weight, INVSQ's entry's low 16 bits (all of it: at most
           32767), inserted straight from the table */
#define IV(k) ld16((const uint8_t *)(const void *)(invsq + ext16(e, k)))
        __m128i wv = _mm_cvtsi32_si128(IV(0));
        FM_KEEP(wv); wv = _mm_insert_epi16(wv, IV(1), 1); FM_KEEP(wv); wv = _mm_insert_epi16(wv, IV(2), 2);
        FM_KEEP(wv); wv = _mm_insert_epi16(wv, IV(3), 3); FM_KEEP(wv); wv = _mm_insert_epi16(wv, IV(4), 4);
        FM_KEEP(wv); wv = _mm_insert_epi16(wv, IV(5), 5); FM_KEEP(wv); wv = _mm_insert_epi16(wv, IV(6), 6);
        FM_KEEP(wv); wv = _mm_insert_epi16(wv, IV(7), 7);
#undef IV
        __m128i p16 = _mm_cvtsi32_si128(pr[0]);
        FM_KEEP(p16); p16 = _mm_insert_epi16(p16, pr[1], 1); FM_KEEP(p16); p16 = _mm_insert_epi16(p16, pr[2], 2);
        FM_KEEP(p16); p16 = _mm_insert_epi16(p16, pr[3], 3); FM_KEEP(p16); p16 = _mm_insert_epi16(p16, pr[4], 4);
        FM_KEEP(p16); p16 = _mm_insert_epi16(p16, pr[5], 5); FM_KEEP(p16); p16 = _mm_insert_epi16(p16, pr[6], 6);
        FM_KEEP(p16); p16 = _mm_insert_epi16(p16, pr[7], 7);
        pv = _mm_packus_epi16(p16, p16);
        const __m128i q16 = _mm_unpacklo_epi8(pv, z0);
        /* both sums at once: sp in lane 0, sw in lane 1 */
        const __m128i s1 = _mm_madd_epi16(wv, q16), s2 = _mm_madd_epi16(wv, _mm_set1_epi16(1));
        __m128i t = _mm_add_epi32(_mm_unpacklo_epi32(s1, s2), _mm_unpackhi_epi32(s1, s2));
        FM_KEEP(t);
        t = _mm_add_epi32(t, _mm_shuffle_epi32(t, 0xEE));
#ifdef __x86_64__
        {
          const uint64_t t2 = (uint64_t)_mm_cvtsi128_si64(t);
          sp = (int)(uint32_t)t2; sw = (int)(t2 >> 32);
        }
#else
        sp = _mm_cvtsi128_si32(t); sw = _mm_cvtsi128_si32(_mm_srli_epi64(t, 32));
#endif
        /* the largest and (as 255 minus the largest of 255 - p) the smallest
           at once: pv holds the predictions twice. Shifts, not shuffles: the
           shuffle port is the busy one */
        __m128i v = _mm_xor_si128(pv, _mm_set_epi32(-1, -1, 0, 0));
        v = _mm_max_epu8(v, _mm_srli_epi64(v, 32));
        v = _mm_max_epu8(v, _mm_srli_epi64(v, 16));
        v = _mm_max_epu8(v, _mm_srli_epi64(v, 8));
        pmx = _mm_cvtsi128_si32(v) & 255; pmn = 255 - (_mm_extract_epi16(v, 4) & 255);
      }
#else
      uint8_t cp[NP];
      sw = 0; sp = 0; pmx = 0; pmn = 255;
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
      /* the eight error sums at once in two 64-bit words, four 16-bit lanes
         each (the even predictors' and the odd ones'): at most 2040 */
      uint64_t es[2];
      {
        const uint64_t M = 0x00FF00FF00FF00FFull;
        uint64_t vW, vN, vNW, vNE, vWW, vNN;
        __builtin_memcpy(&vW, eW, 8); __builtin_memcpy(&vN, eN, 8); __builtin_memcpy(&vNW, eNW, 8);
        __builtin_memcpy(&vNE, eNE, 8); __builtin_memcpy(&vWW, eWW, 8); __builtin_memcpy(&vNN, eNN, 8);
        es[0] = 2 * ((vW & M) + (vN & M)) + (vNW & M) + (vNE & M) + (vWW & M) + (vNN & M);
        es[1] = 2 * (((vW >> 8) & M) + ((vN >> 8) & M)) + ((vNW >> 8) & M) + ((vNE >> 8) & M) + ((vWW >> 8) & M) + ((vNN >> 8) & M);
      }
#endif
      for (int k = 0; k < NP; k++) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
        const int e = (int)((es[k & 1] >> (16 * (k >> 1))) & 0xFFFF);
#else
        const int e = 2 * (eW[k] + eN[k]) + eNW[k] + eNE[k] + eWW[k] + eNN[k];
#endif
        const int wt = invsq[e > 1023 ? 1023 : e];
        const int q = clamp255(pr[k]);
        cp[k] = (uint8_t)q;
        sw += wt; sp += wt * q;
        pmx = q > pmx ? q : pmx; pmn = q < pmn ? q : pmn;
      }
#endif
      const int P = (sp + (sw >> 1)) / sw;
      /* the contexts */
      const int fW = fc[i - nc], fN = fu[i], fNW = fu[i - nc], fNE = fu[i + nc];
      const int E = iabs(fW) + iabs(fN) + ((iabs(fNW) + iabs(fNE)) >> 1) + (ch ? 2 * iabs(resPrev) : 0) + (pmx - pmn);
      const int eb = ebin[E > 2047 ? 2047 : E], eb4 = eb >> 2;
      const int sg = q3[fW & 511] + 5 * q3[fN & 511] + 25 * q3[resPrev & 511] + 125 * q3[resPrev2 & 511];
      const uint32_t hx = hsh((uint32_t)xPrev | (uint32_t)((P - xPrev) & 511) << 8 | (uint32_t)chx << 17 | (uint32_t)eb4 << 19);
      const uint32_t hn = ((uint32_t)W | (uint32_t)N << 8 | (uint32_t)NE << 16 | (uint32_t)NW << 24) * 0x9E3779B1u ^ (uint32_t)(chx + 1) * 0x85EBCA6Bu;
      const int sel = eb | (chx > 0) << 4;
      /* the hashed counters the decisions after the first may read, fetched
         while it is coded (a hint: nothing depends on it) */
      __builtin_prefetch(&ctab[hn >> cs]);
      for (int sn_ = 0; sn_ < 2; sn_++) {
        const uint32_t t_ = (uint32_t)(sn_ << 1) * 0x27D4EB2Fu + 3;
        __builtin_prefetch(&h[((hx + t_) * 0x165667B1u) >> hs]);
      }
      __builtin_prefetch(&h[((hx + 5) * 0x2545F491u) >> hs]);
      __builtin_prefetch(&h[((hn + 5) * 0x2545F491u) >> hs]);
      const intptr_t spos = rowPos + i;
      const int mexp = mlen > 0 ? data[mptr] : -1;
      const int mst = mlen == 0 ? 0 : mexp != P ? 3 : mlen < 16 ? 1 : 2;
      int X = enc ? src[i] : 0, e = 0;
      if (enc) e = fold(X - P);
      const int z = mixbit2(&c, tb, &T->mz, 1, &T->nzm[chx][sg][mst], &h[hx >> hs], sel, e == 0);
      uint16_t *cslot = &ctab[hn >> cs];
      if (!z) {
        int q = 0, c2 = -1, src2 = 0;
        const int cv = *cslot - 1;
        /* a second guess where values repeat: a match, or a flat area */
        if (mst == 3) { c2 = mexp; src2 = 4; }
        else if (eb > Q_EB) ;
        else if (*cslot && iabs(cv - P) > QT) { c2 = cv; src2 = 0; }
        else if (iabs(W - P) > QT) { c2 = W; src2 = 1; }
        else if (iabs(N - P) > QT) { c2 = N; src2 = 2; }
        else if (iabs(NE - P) > QT) { c2 = NE; src2 = 3; }
        if (c2 >= 0) {
          const int qi = src2 * 2 + (*cslot != 0);
          q = mixbit(&c, tb, &T->mq, 0, &T->qd[chx][qi][eb4], &T->qs[chx][sg], &h[((hx + 5) * 0x2545F491u) >> hs],
                     &h[((hn + 5) * 0x2545F491u) >> hs], qi | (chx > 0) << 4, enc ? X == c2 : 0);
          if (q) e = fold(c2 - P);
        }
        if (!q) {
          const int sn = onebit(&c, tb, &T->ns[chx][sg], e < 0);
          const int av0 = sn ? -e : e;
          const int k = enc ? 31 - __builtin_clz((unsigned)(av0 | 1)) : 0;
          int kk = 0;
          for (int j = 0; j < 7; j++) {
            int more;
            if (j < 2) {
              const uint32_t t = (uint32_t)(sn << 1 | j) * 0x27D4EB2Fu + 3;
              more = mixcls(&c, T->mc[j].w[sel], &T->ncl[j][chx][sg], &h[((hx + t) * 0x165667B1u) >> hs], k > j, &tb);
            } else more = onebit(&c, tb, &T->cls[chx][eb][j], k > j);
            if (!more) break;
            kk++;
          }
          int av = 1;
          for (int j = kk - 1; j >= 0; j--)
            av = av * 2 + onebit(&c, tb, j == kk - 1 ? &T->mant[chx][eb][kk] : &T->low[chx][kk][j], (av0 >> j) & 1);
          e = sn ? -av : av;
        }
      }
      if (!enc) { X = (P + e) & 255; src[i] = (uint8_t)X; }
      cur[i] = (uint8_t)X;
      *cslot = (uint16_t)(X + 1);
      const int er = X - P;
      fc[i] = (int16_t)er;
      uint8_t *eo = ec + (intptr_t)i * 8;
#ifdef FM_SSE2
      {
        const __m128i xv = _mm_set1_epi8((char)X);
        _mm_storel_epi64((__m128i *)(void *)eo, _mm_or_si128(_mm_subs_epu8(xv, pv), _mm_subs_epu8(pv, xv)));
      }
#else
      for (int k = 0; k < NP; k++) eo[k] = (uint8_t)iabs(X - cp[k]);
#endif
      /* the match goes on or ends; the last 6 bytes' hash, where they were
         last, a new match from there when there is none */
      if (mlen > 0 && mexp == X) { mlen++; mptr++; } else mlen = 0;
      if (spos + 1 - bandStart >= 6) {
        const uint64_t k6 = (uint64_t)data[spos - 5] | (uint64_t)data[spos - 4] << 8 | (uint64_t)data[spos - 3] << 16 |
                            (uint64_t)data[spos - 2] << 24 | (uint64_t)data[spos - 1] << 32 | (uint64_t)data[spos] << 40;
        const uint32_t hh = (uint32_t)((k6 * 0x9E3779B97F4A7C15ull) >> (64 - mbits));
        if (mlen == 0) {
          const intptr_t cand = mtab[hh];
          if (cand > 0 && cand <= spos) {
            intptr_t l = 0;
            while (l < 32 && cand - 1 - l >= bandStart && data[cand - 1 - l] == data[spos - l]) l++;
            if (l >= 6) { mlen = l; mptr = cand; }
          }
        }
        mtab[hh] = (uint32_t)(spos + 1);
      }
      if (mlen > 65535) mlen = 65535;
      resPrev2 = resPrev; resPrev = er; xPrev = X;
      /* N and NN read again, not kept: on a pass's first line the lines
         above are this one, and up[i], up2[i] are X now */
      pN = up[i]; pNN = up2[i];
    }
  }
  *a->mptr = mptr; *a->mlen = mlen;
  *a->x1 = c.x1; *a->x2 = c.x2;
  if (!enc) *a->x = c.x;
  *a->pos = c.pos;
}

/* the line's loop for each pixel size and each direction, constants in
   each copy: the neighbours' offsets fold into the addressing, and the
   coder's encode-or-decode tests go. nc is 1 to 4: ppafast.FastEligible
   (8-bit gray, gray and alpha, RGB, RGBA) is checked before any image is
   coded or decoded with this model (ppacodec) */
void ppaf_row(fm_args_t *a) {
  if ((int)a->encoding) switch (a->nc) {
    case 1: row_nc(a, 1, 1); break;
    case 2: row_nc(a, 2, 1); break;
    case 3: row_nc(a, 3, 1); break;
    default: row_nc(a, 4, 1); break;
  } else switch (a->nc) {
    case 1: row_nc(a, 1, 0); break;
    case 2: row_nc(a, 2, 0); break;
    case 3: row_nc(a, 3, 0); break;
    default: row_nc(a, 4, 0); break;
  }
}
