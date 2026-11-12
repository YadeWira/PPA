/* libFuzzer target over ppastaticc.c's decoder (mode 2: rANS) alone, C
   under ASan + UBSan, with buffers of exactly the size ppastatic.pas's Walk
   gives it and tables that pass DecodeImageStatic's checks (each context's
   frequencies sum to 4096, cum and slot built from them), so that any
   rANS bytes, width, channel count and stream version are tried.

   input: nc-1 (3 bits) | ctxv-1 (1 bit) | table seed (4 bits), width-1
   (10 bits of 2 bytes: up to 1024), rows-1 (5 bits: up to 32), then the rANS bytes (the first 4 the state,
   as DecodeImageStatic reads it). */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "../../ppastaticc.c"

#define N_CTX 320
#define SM_TOT 4096

static uint16_t freq[N_CTX * 256], cum[N_CTX * 257];
static uint8_t slot[N_CTX * 256], ebin[4096], rq[511];
static int ready;

static uint32_t rng;
static uint32_t next(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

static void tables(unsigned seed) {
  static const int TH[15] = {1, 2, 3, 5, 7, 10, 14, 20, 28, 40, 56, 80, 112, 160, 224};
  for (int e = 0; e < 4096; e++) { int b = 0; while (b < 15 && e >= TH[b]) b++; ebin[e] = (uint8_t)b; }
  for (int e = -255; e <= 255; e++) rq[e + 255] = e < -2 ? 0 : e < 0 ? 1 : e == 0 ? 2 : e <= 2 ? 3 : 4;
  rng = 0x9E3779B9u ^ (seed * 0x85EBCA6Bu);
  memset(freq, 0, sizeof freq);
  for (int c = 0; c < N_CTX; c++) {
    uint16_t *f = freq + c * 256;
    int used = (int)(next() % 257);          /* 0: never used, all on symbol 0 */
    if (seed & 8) used = used ? 256 : 0;     /* every symbol */
    if (!used) f[0] = SM_TOT;
    else {
      /* `used` symbols, each at least 1, the rest of 4096 spread at random */
      uint8_t perm[256];
      for (int s = 0; s < 256; s++) perm[s] = (uint8_t)s;
      for (int s = 255; s > 0; s--) { int r = (int)(next() % (unsigned)(s + 1)); uint8_t t = perm[s]; perm[s] = perm[r]; perm[r] = t; }
      for (int k = 0; k < used; k++) f[perm[k]] = 1;
      int left = SM_TOT - used;
      while (left > 0) {
        int give = 1 + (int)(next() % (unsigned)left);
        if (next() & 1) give = 1 + give / 16;
        f[perm[next() % (unsigned)used]] += (uint16_t)give;
        left -= give;
      }
    }
    uint16_t *cu = cum + c * 257;
    cu[0] = 0;
    for (int s = 0; s < 256; s++) {
      cu[s + 1] = (uint16_t)(cu[s] + f[s]);
      for (int j = cu[s]; j < cu[s + 1]; j++) if ((j & 15) == 0) slot[c * 256 + (j >> 4)] = (uint8_t)s;
    }
    if (cu[256] != SM_TOT) abort();          /* the harness's own check */
  }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 8) return 0;
  const int nc = 1 + (data[0] & 7), ctxv = 1 + ((data[0] >> 3) & 1);
  const unsigned seed = data[0] >> 4;
  const intptr_t w = 1 + (data[1] | (data[2] & 0x03) << 8), rows = 1 + (data[3] & 0x1F);
  if (!ready || (unsigned)ready - 1 != seed) { tables(seed); ready = (int)seed + 1; }
  const uint8_t *buf = data + 4; const intptr_t len = (intptr_t)size - 4;
  uint32_t x = (uint32_t)buf[0] << 24 | (uint32_t)buf[1] << 16 | (uint32_t)buf[2] << 8 | buf[3];
  if (x < SM_L || x >= SM_L << 8) return 0;
  intptr_t pos = 4;
  const intptr_t rs = (w + 2 * SM_PAD) * nc;
  uint8_t *px = calloc((size_t)(2 * rs), 1);
  int16_t *fe = calloc((size_t)(2 * rs), sizeof(int16_t));
  uint8_t *img = malloc((size_t)(w * nc * rows));
  uint8_t *rans = malloc((size_t)len);
  memcpy(rans, buf, (size_t)len);
  sm_args_t a = {0};
  a.mode = 2; a.px = px; a.fe = fe; a.w = w; a.nc = nc;
  a.ebin = ebin; a.rq = rq; a.freq = freq; a.cum = cum; a.slot = slot;
  a.x = &x; a.buf = rans; a.pos = &pos; a.len = len; a.ctxv = ctxv;
  for (intptr_t y = 0; y < rows; y++) {
    a.y = y;
    a.src = img + y * w * nc;
    ppas_row(&a);
  }
  free(px); free(fe); free(img); free(rans);
  return 0;
}
