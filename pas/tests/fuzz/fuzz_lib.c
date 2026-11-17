/* libFuzzer target over libppa (pas/lib/ppalib.pas) built for fuzzing by
   pas/tests/fuzz/run.sh: the C part (pas/ppa*c.c, ppafilter.c, PJA's C) under
   clang's ASan + UBSan + coverage, the Pascal part with cmem (so its heap is
   malloc's and ASan checks every C access to it) and ppafuzzhook (an
   exception that is a bug aborts instead of being called damage).

     -DFUZZ_FILTER   the input is a PPAF stream: ppa_filter_decode
     -DFUZZ_DEFLATE  ppa_deflate_* (since 0.7.0); the first byte, even: the
                     rest is a deflate stream to analyze (bits 1-2 its
                     framing: 1 raw, 2 zlib, else either; level 1, no
                     zopfli), and a recipe it gives must rebuild it; odd:
                     two bytes (little-endian) the length of the bytes that
                     follow (at most FUZZ_PLAIN), the rest a recipe to
                     rebuild them with
     otherwise       the input is a .ppa: ppa_decompress

   Coverage comes from the C only (FreePascal has no instrumentation): the
   AFL++ qemu target (fuzz_decode.pas) is the one guided by the Pascal. */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef ptrdiff_t (*ppa_read_fn)(void *ctx, void *buf, size_t size);
typedef int (*ppa_write_fn)(void *ctx, const void *buf, size_t size);
int ppa_decompress(const uint8_t *input, size_t size, uint8_t **output, size_t *out_size,
                   size_t max_size, int threads);
void ppa_free(void *p);
int ppa_filter_decode(ppa_read_fn read, void *read_ctx, ppa_write_fn write, void *write_ctx, int threads);
typedef struct ppa_deflate_ctx ppa_deflate_ctx;
ppa_deflate_ctx *ppa_deflate_ctx_new(size_t max_plain);
void ppa_deflate_ctx_free(ppa_deflate_ctx *ctx);
int ppa_deflate_analyze(ppa_deflate_ctx *ctx, const void *in, size_t n, int flags, void **plain, size_t *plain_size,
                        void **recipe, size_t *recipe_size, size_t *consumed, size_t *err_pos);
int ppa_deflate_rebuild(ppa_deflate_ctx *ctx, const void *plain, size_t plain_size, const void *recipe,
                        size_t recipe_size, size_t max_out, void **out, size_t *out_size, size_t *err_pos);

/* the deflate target's caps: the bytes a stream may hold, and the bytes a
   rebuild's recipe gets (a damaged zopfli recipe may ask 1000 iterations) */
#define FUZZ_MAX_PLAIN ((size_t)1 << 20)
#define FUZZ_PLAIN 2048

#define MAX_OUT ((size_t)64 << 20)

typedef struct { const uint8_t *p; size_t n, at; size_t out; } io_t;

static ptrdiff_t rd(void *ctx, void *buf, size_t size) {
  io_t *s = ctx;
  size_t k = s->n - s->at;
  if (k > size) k = size;
  /* a short read now and then, as a pipe gives */
  if (k > 7 && (s->at & 1)) k = k / 2 + 1;
  memcpy(buf, s->p + s->at, k);
  s->at += k;
  return (ptrdiff_t)k;
}

static int wr(void *ctx, const void *buf, size_t size) {
  io_t *s = ctx;
  volatile uint8_t sink = 0;
  /* touch the first and last byte: ASan sees a write past a buffer */
  if (size) sink ^= ((const uint8_t *)buf)[0] ^ ((const uint8_t *)buf)[size - 1];
  s->out += size;
  return s->out > 4 * MAX_OUT;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
#ifdef FUZZ_DEFLATE
  if (size < 1) return 0;
  void *out = NULL; size_t n = 0;
  if ((data[0] & 1) == 0) {
    static const int framing[4] = {3, 1, 2, 3};
    void *plain = NULL, *rc = NULL; size_t pn = 0, rn = 0, cons = 0;
    ppa_deflate_ctx *ctx = ppa_deflate_ctx_new(FUZZ_MAX_PLAIN);
    int r = ppa_deflate_analyze(ctx, data + 1, size - 1, framing[(data[0] >> 1) & 3] | (1 << 4),
                                &plain, &pn, &rc, &rn, &cons, NULL);
    if (r == 0) {
      /* what analyze gives must rebuild the stream: anything else is a bug */
      if (ppa_deflate_rebuild(NULL, plain, pn, rc, rn, 0, &out, &n, NULL) != 0 || n != cons ||
          cons > size - 1 || memcmp(out, data + 1, n) != 0)
        abort();
    }
    ppa_free(plain); ppa_free(rc);
    ppa_deflate_ctx_free(ctx);
  } else {
    if (size < 3) return 0;
    size_t pn = data[1] | ((size_t)data[2] << 8);
    if (pn > FUZZ_PLAIN) pn = FUZZ_PLAIN;
    if (pn > size - 3) pn = size - 3;
    if (ppa_deflate_rebuild(NULL, data + 3, pn, data + 3 + pn, size - 3 - pn, MAX_OUT, &out, &n, NULL) == 0 && n) {
      volatile uint8_t sink = ((uint8_t *)out)[0] ^ ((uint8_t *)out)[n - 1];
      (void)sink;
    }
  }
  if (out) ppa_free(out);
#elif defined(FUZZ_FILTER)
  io_t s = {data, size, 0, 0};
  ppa_filter_decode(rd, &s, wr, &s, 1);
#else
  uint8_t *out = NULL; size_t n = 0;
  if (ppa_decompress(data, size, &out, &n, MAX_OUT, 1) == 0 && n) {
    volatile uint8_t sink = out[0] ^ out[n - 1];
    (void)sink;
  }
  if (out) ppa_free(out);
#endif
  return 0;
}
