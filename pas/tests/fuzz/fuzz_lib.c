/* libFuzzer target over libppa (pas/lib/ppalib.pas) built for fuzzing by
   pas/tests/fuzz/run.sh: the C part (pas/ppa*c.c, ppafilter.c, PJA's C) under
   clang's ASan + UBSan + coverage, the Pascal part with cmem (so its heap is
   malloc's and ASan checks every C access to it) and ppafuzzhook (an
   exception that is a bug aborts instead of being called damage).

     -DFUZZ_FILTER   the input is a PPAF stream: ppa_filter_decode
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
#ifdef FUZZ_FILTER
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
