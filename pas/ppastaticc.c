/* Layer 5's static model, its line loop in C: bit for bit what
   ppastatic.pas's Pascal reference does (the suite codes the same images
   with both and demands identical streams; PPA_NOC=1 picks the Pascal one).

   A sample is predicted by LOCO-I's MED (gray, alpha, the first channel)
   or by the channel before plus MED of the differences to it (the colour
   channels); its residual, folded and zigzagged to 0..255, is a symbol of
   one of 64 contexts (an energy bin from the residuals around and the
   channel before's, by channel), coded with static frequencies by rANS.
   One line at a time: counted (mode 0), its (context, symbol) recorded for
   the encoder (mode 1), or decoded (mode 2).

   Called through ppastatic.pas, which owns every table and buffer: this
   file takes no memory and calls no library. Integer arithmetic only. */
#include <stdint.h>

#define SM_PAD 2
#define SM_PB 12                       /* frequencies: 12 bits */
#define SM_L (1u << 23)                /* rANS: the state's lower bound */

/* ppastatic.TStaticArgs */
typedef struct {
  intptr_t mode;                       /* 0 count, 1 record, 2 decode */
  uint8_t *px; int16_t *fe;            /* two padded lines of pixels, two of residuals */
  intptr_t w, nc, y;                   /* the line's width in pixels, bytes a pixel, its number in the pass or band */
  uint8_t *src;                        /* the line in the image (decoding: written) */
  const uint8_t *ebin;                 /* the energy's bin, 0..4095 -> 0..15 */
  uint32_t *cnt;                       /* mode 0: [64][256] */
  uint8_t *rctx, *rsym; intptr_t *rn;  /* mode 1: where the (context, symbol) go, and how many so far */
  const uint16_t *freq, *cum;          /* mode 2: [64][256], [64][257] */
  const uint8_t *slot;                 /* mode 2: [64][4096], the symbol of each slot */
  uint32_t *x; const uint8_t *buf; intptr_t *pos; intptr_t len;   /* mode 2: the rANS state and input */
} sm_args_t;

static inline int iabs(int v) { return v < 0 ? -v : v; }
static inline int imin(int a, int b) { return a < b ? a : b; }
static inline int imax(int a, int b) { return a > b ? a : b; }
static inline int med3(int a, int b, int c) { return imax(imin(a, b), imin(imax(a, b), c)); }

void ppas_row(sm_args_t *a) {
  const int w = (int)a->w, nc = (int)a->nc, y = (int)a->y, mode = (int)a->mode;
  const intptr_t rs = (intptr_t)(w + 2 * SM_PAD) * nc;
  uint8_t *const cur = a->px + (y & 1) * rs + SM_PAD * nc;
  uint8_t *up = a->px + ((y + 1) & 1) * rs + SM_PAD * nc;
  int16_t *const fc = a->fe + (y & 1) * rs + SM_PAD * nc, *const fu = a->fe + ((y + 1) & 1) * rs + SM_PAD * nc;
  uint8_t *const src = a->src;
  const uint8_t *const ebin = a->ebin;
  uint32_t *const cnt = a->cnt;
  uint8_t *const rctx = a->rctx, *const rsym = a->rsym;
  intptr_t rn = mode == 1 ? *a->rn : 0;
  const uint16_t *const freq = a->freq, *const cum = a->cum;
  const uint8_t *const slot = a->slot, *const buf = a->buf;
  uint32_t x = mode == 2 ? *a->x : 0;
  intptr_t pos = mode == 2 ? *a->pos : 0;
  const intptr_t len = a->len;

  /* the first line sees itself as the line above; the buffers start at
     zero (ppastatic's NewPass), the left padding stays so, the right one is
     the last pixel above, repeated */
  if (y == 0) up = cur;
  for (int k = 0; k < SM_PAD * nc; k++) up[w * nc + k] = up[(w - 1) * nc + k % nc];

  for (int xx = 0; xx < w; xx++) {
    int resPrev = 0, xPrev = 0;
    for (int ch = 0; ch < nc; ch++) {
      const int i = xx * nc + ch;
      const int W = cur[i - nc], N = up[i], NW = up[i - nc], NE = up[i + nc];
      int P;
      if (ch == 0 || ch == 3 || nc < 3) P = med3(W, N, W + N - NW);
      else {
        const int dW = W - cur[i - nc - 1], dN = N - up[i - 1], dNW = NW - up[i - nc - 1];
        P = xPrev + med3(dW, dN, dW + dN - dNW);
        P = P < 0 ? 0 : P > 255 ? 255 : P;
      }
      const int fW = fc[i - nc], fN = fu[i], fNW = fu[i - nc], fNE = fu[i + nc];
      int E = iabs(fW) + iabs(fN) + ((iabs(fNW) + iabs(fNE)) >> 1) + ((iabs(W - N) + iabs(N - NE)) >> 3);
      if (ch) E += 2 * iabs(resPrev);
      const int ctx = ebin[E > 4095 ? 4095 : E] * 4 + (ch & 3);
      int X;
      if (mode != 2) {
        X = src[i];
        int e = X - P;
        if (e < -128) e += 256;
        if (e > 127) e -= 256;
        const int sym = e >= 0 ? 2 * e : -2 * e - 1;
        if (mode == 0) cnt[ctx * 256 + sym]++;
        else { rctx[rn] = (uint8_t)ctx; rsym[rn] = (uint8_t)sym; rn++; }
      } else {
        const uint32_t s = x & ((1u << SM_PB) - 1);
        const int sym = slot[ctx * (1 << SM_PB) + s];
        x = freq[ctx * 256 + sym] * (x >> SM_PB) + s - cum[ctx * 257 + sym];
        while (x < SM_L) { x = (x << 8) | (pos >= 0 && pos < len ? buf[pos] : 0); pos++; }
        const int e = (sym & 1) ? -((sym + 1) >> 1) : sym >> 1;
        X = (P + e) & 255;
        src[i] = (uint8_t)X;
      }
      cur[i] = (uint8_t)X;
      const int er = X - P;
      fc[i] = (int16_t)er;
      resPrev = er; xPrev = X;
    }
  }
  if (mode == 1) *a->rn = rn;
  if (mode == 2) { *a->x = x; *a->pos = pos; }
}
