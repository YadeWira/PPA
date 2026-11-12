/* libFuzzer target over ppafilter.c alone (C, ASan + UBSan), with a host of
   its own instead of PPA's codec, so that the filter's parsing and queues
   run at C speed:

   first byte even: the rest is a PPAF stream, decoded. A file record's
     "stream" decodes (its first byte even) to `expected` bytes, or fails
     (odd), the cause from its second byte.
   first byte odd: the rest is any bytes, encoded and decoded back, which
     must give them again. The "codec" keeps each file it is given in a
     table and hands back its index as the stream (8 bytes, so every file
     of 21 bytes or more is taken), or refuses one (its 9th byte odd).

   Threads: the pool runs a job when it is submitted. */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "../../lib/ppafilter.c"

#define MAX_FAKE_OUT ((size_t)1 << 20)

static uint8_t **kept; static size_t *keptLen; static size_t nKept, capKept;

static void *h_alloc(size_t n) { return malloc(n ? n : 1); }
static void h_release(void *p) { free(p); }
static void *h_open(int threads, int encode) { (void)threads; return (void *)(intptr_t)(encode + 1); }
static void h_wait(void *pool, job_t *j) { (void)pool; (void)j; }
static void h_close(void *pool) { (void)pool; }

static void h_submit(void *pool, job_t *j) {
  j->out = 0; j->out_size = 0; j->ok = 0; j->cause = 0;
  if ((intptr_t)pool == 2) {          /* encoding */
    if (j->size >= 9 && (j->in[8] & 1)) { j->done = 1; return; }
    if (nKept == capKept) {
      capKept = capKept ? 2 * capKept : 16;
      kept = realloc(kept, capKept * sizeof *kept);
      keptLen = realloc(keptLen, capKept * sizeof *keptLen);
    }
    kept[nKept] = malloc(j->size ? j->size : 1);
    memcpy(kept[nKept], j->in, j->size);
    keptLen[nKept] = j->size;
    j->out = h_alloc(8);
    uint64_t id = nKept++;
    memcpy(j->out, &id, 8);
    j->out_size = 8;
    j->ok = 1;
  } else if (capKept && j->size == 8) {   /* decoding what the encoder wrote */
    uint64_t id; memcpy(&id, j->in, 8);
    if (id < nKept && keptLen[id] == j->expected) {
      j->out = h_alloc(j->expected);
      memcpy(j->out, kept[id], j->expected);
      j->out_size = j->expected;
      j->ok = 1;
    }
  } else {                              /* decoding fuzzed records */
    if (j->size && !(j->in[0] & 1) && j->expected <= MAX_FAKE_OUT) {
      j->out = h_alloc(j->expected);
      memset(j->out, j->in[0], j->expected);
      j->out_size = j->expected;
      j->ok = 1;
    } else if (j->size > 1) j->cause = j->in[1] % 3;
  }
  j->done = 1;
}

typedef struct { const uint8_t *p; size_t n, at; uint8_t *o; size_t on, ocap; int cut; } io_t;

static ptrdiff_t fz_rd(void *ctx, void *buf, size_t size) {
  io_t *s = ctx;
  size_t k = s->n - s->at;
  if (k > size) k = size;
  if (s->cut && k > 3) k = k / 3 + 1;  /* short reads */
  memcpy(buf, s->p + s->at, k);
  s->at += k;
  return (ptrdiff_t)k;
}
static int fz_wr(void *ctx, const void *buf, size_t size) {
  io_t *s = ctx;
  if (s->on + size > s->ocap) {
    size_t c = s->ocap ? s->ocap : 4096;
    while (c < s->on + size) c *= 2;
    if (c > ((size_t)64 << 20)) return 1;
    s->o = realloc(s->o, c); s->ocap = c;
  }
  memcpy(s->o + s->on, buf, size);
  s->on += size;
  return 0;
}

static void forget(void) {
  for (size_t i = 0; i < nKept; i++) free(kept[i]);
  free(kept); free(keptLen);
  kept = 0; keptLen = 0; nKept = capKept = 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static const host_t host = {h_alloc, h_release, h_open, h_submit, h_wait, h_close};
  if (size < 1) return 0;
  ppafilter_host(&host);
  if (!(data[0] & 1)) {
    io_t s = {data + 1, size - 1, 0, 0, 0, 0, data[0] & 2};
    ppafilter_decode(fz_rd, &s, fz_wr, &s, 1 + (data[0] >> 4));
    free(s.o);
    return 0;
  }
  io_t e = {data + 1, size - 1, 0, 0, 0, 0, data[0] & 2};
  capKept = 0;
  int r = ppafilter_encode(fz_rd, &e, fz_wr, &e, 1 + (data[0] >> 4));
  if (r != PPA_OK) { fprintf(stderr, "encode: %d\n", r); abort(); }
  if (!capKept) { capKept = 1; kept = malloc(sizeof *kept); keptLen = malloc(sizeof *keptLen); }
  io_t d = {e.o, e.on, 0, 0, 0, 0, data[0] & 4};
  r = ppafilter_decode(fz_rd, &d, fz_wr, &d, 1 + (data[0] >> 4));
  if (r != PPA_OK || d.on != size - 1 || (d.on && memcmp(d.o, data + 1, d.on))) {
    fprintf(stderr, "round trip: %d, %zu bytes back of %zu\n", r, d.on, size - 1);
    abort();
  }
  free(e.o); free(d.o);
  forget();
  return 0;
}
