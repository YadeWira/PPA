/* libppa's test, in C against ppa.h, the way an archiver uses it (from
   PJA's pas/lib/test_lib.c):

     test_lib FILE...

   Each file through ppa_compress and ppa_decompress (a file PPA does not
   take, or does not make smaller, must say so, and nothing else may fail),
   the same bytes on 1 and 2 threads; a damaged .ppa refused. What a newer
   PPA would write (a .ppa, a codec stream, a filter version or record)
   must give PPA_E_VERSION. Several threads compressing at once must give
   the same bytes, and many short-lived threads must not run out of memory
   (the codec's per-thread models handed back). Then every file put
   together into one stream with bytes around them (and false signatures),
   through the filter in read sizes of 1 byte to 1 MiB, and back: the same
   bytes, every time. A damaged filter stream must give an error or other
   bytes, never a crash. Prints a line per check that fails and "N checks,
   M failures" at the end.

     test_lib --deflate [-1|-2|-3] FILE...

   Each file a deflate stream (.raw: bare; .zlib: zlib; else either),
   through ppa_deflate_analyze and ppa_deflate_rebuild: the same stream
   back, with one context for all (the hint) and with a fresh one each;
   bytes after the stream left out of it; a newer recipe PPA_E_VERSION;
   damaged streams and recipes an error or other bytes, never a crash; 4
   threads, a context each, the same recipes; -1 to -3, the level. Prints
   the time a stream takes, by size. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "ppa.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <time.h>
#endif

static int checks, failures;
static void check(int ok, const char *what, const char *name) {
  checks++;
  if (!ok) { failures++; printf("  FAIL  %s %s\n", what, name); }
}

typedef struct { const unsigned char *d; size_t n, p, step; } src_t;
typedef struct { unsigned char *d; size_t n, cap; } dst_t;

static ptrdiff_t rd(void *ctx, void *buf, size_t size) {
  src_t *s = ctx;
  size_t k = s->n - s->p;
  if (k > size) k = size;
  if (k > s->step) k = s->step;
  memcpy(buf, s->d + s->p, k);
  s->p += k;
  return (ptrdiff_t)k;
}
static int wr(void *ctx, const void *buf, size_t size) {
  dst_t *d = ctx;
  if (d->n + size > d->cap) {
    d->cap = (d->n + size) * 2 + 4096;
    d->d = realloc(d->d, d->cap);
    if (!d->d) return -1;
  }
  memcpy(d->d + d->n, buf, size);
  d->n += size;
  return 0;
}

static unsigned char *slurp(const char *name, size_t *n) {
  FILE *f = fopen(name, "rb");
  if (!f) return 0;
  fseek(f, 0, SEEK_END);
  long k = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *d = malloc(k > 0 ? (size_t)k : 1);
  *n = fread(d, 1, (size_t)k, f);
  fclose(f);
  return d;
}

/* a filter stream through the decoder: its result */
static int filter_result(const unsigned char *a, size_t an) {
  src_t ia = {a, an, 0, 4096};
  dst_t o = {0};
  int r = ppa_filter_decode(rd, &ia, wr, &o, 1);
  free(o.d);
  return r;
}

/* what a newer PPA wrote: PPA_E_VERSION, never PPA_E_DATA nor a crash. ppa
   is a .ppa of a PNG, not stored, with no extension (ppa_compress's): its
   codec stream from byte 37 */
static void versions(const unsigned char *ppa, size_t pn) {
  unsigned char *p = malloc(pn);
  void *back = 0;
  size_t bn = 0;
  int bad = 0;
  memcpy(p, ppa, pn);
  p[4] = 2;
  check(ppa_decompress(p, pn, &back, &bn, 0, 1) == PPA_E_VERSION, "a .ppa of format version 2: PPA_E_VERSION", "");
  ppa_free(back); back = 0;
  memcpy(p, ppa, pn);
  for (int v = 7; v < 256; v++) {
    p[37] = (unsigned char)v;
    bad += ppa_decompress(p, pn, &back, &bn, 0, 1) != PPA_E_VERSION;
    ppa_free(back); back = 0;
  }
  check(bad == 0, "codec stream versions 7 to 255 in a .ppa: PPA_E_VERSION", "");
  p[37] = 0;
  check(ppa_decompress(p, pn, &back, &bn, 0, 1) == PPA_E_DATA, "codec stream version 0: PPA_E_DATA", "");
  ppa_free(back);
  free(p);
  static const unsigned char f2[] = {'P', 'P', 'A', 'F', 2, 0xFF}, f1end[] = {'P', 'P', 'A', 'F', 1, 0xFF},
    f1cut[] = {'P', 'P', 'A', 'F', 1};
  check(filter_result(f2, sizeof f2) == PPA_E_VERSION, "filter version 2: PPA_E_VERSION", "");
  check(filter_result(f1end, sizeof f1end) == PPA_OK, "filter version 1, empty", "");
  check(filter_result(f1cut, sizeof f1cut) == PPA_E_DATA, "filter version 1 cut short: PPA_E_DATA", "");
  bad = 0;
  for (int t = 0x02; t < 0xFF; t++) {
    /* a raw record first, then the unknown one */
    unsigned char s1[] = {'P', 'P', 'A', 'F', 1, 0x00, 0x01, 'x', (unsigned char)t, 0x01, 0x01, 0xFF};
    bad += filter_result(s1, sizeof s1) != PPA_E_VERSION;
  }
  check(bad == 0, "filter records 02 to FE: PPA_E_VERSION", "");
  bad = 0;
  for (int v = 7; v < 256; v++) {
    /* a file of 100 bytes whose codec stream (10 bytes) is version v */
    unsigned char s1[] = {'P', 'P', 'A', 'F', 1, 0x01, 100, 10, (unsigned char)v, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF};
    bad += filter_result(s1, sizeof s1) != PPA_E_VERSION;
  }
  check(bad == 0, "a filter record whose codec stream is version 7 to 255: PPA_E_VERSION", "");
  printf("what a newer PPA wrote: PPA_E_VERSION (.ppa, codec stream, filter version and records)\n");
}

/* ---------- threads ---------- */

typedef struct { const unsigned char *d; size_t n; void *out; size_t on; int r; } work_t;

#ifdef _WIN32
static DWORD WINAPI worker(LPVOID arg) {
  work_t *w = arg;
  w->r = ppa_compress(w->d, w->n, &w->out, &w->on, 1);
  return 0;
}
static void run_threads(work_t *w, int n) {
  HANDLE h[16];
  for (int k = 0; k < n; k++) h[k] = CreateThread(NULL, 0, worker, &w[k], 0, NULL);
  for (int k = 0; k < n; k++) { WaitForSingleObject(h[k], INFINITE); CloseHandle(h[k]); }
}
#else
static void *worker(void *arg) {
  work_t *w = arg;
  w->r = ppa_compress(w->d, w->n, &w->out, &w->on, 1);
  return 0;
}
static void run_threads(work_t *w, int n) {
  pthread_t t[16];
  for (int k = 0; k < n; k++) pthread_create(&t[k], NULL, worker, &w[k]);
  for (int k = 0; k < n; k++) pthread_join(t[k], NULL);
}
#endif

/* the same file from 4 threads at once, 3 rounds, then 40 threads one after
   another (each its own models, given back when it returns): the same
   bytes as on the main thread, every time */
static void threads_test(const unsigned char *d, size_t n, const void *want, size_t wn, const char *name) {
  work_t w[16];
  int bad = 0;
  for (int round = 0; round < 3; round++) {
    for (int k = 0; k < 4; k++) { w[k].d = d; w[k].n = n; w[k].out = 0; w[k].on = 0; w[k].r = -1; }
    run_threads(w, 4);
    for (int k = 0; k < 4; k++) {
      bad += w[k].r != PPA_OK || w[k].on != wn || memcmp(w[k].out, want, wn) != 0;
      ppa_free(w[k].out);
    }
  }
  check(bad == 0, "4 threads at once: the same bytes", name);
  bad = 0;
  for (int k = 0; k < 40; k++) {
    w[0].d = d; w[0].n = n; w[0].out = 0; w[0].on = 0; w[0].r = -1;
    run_threads(w, 1);
    bad += w[0].r != PPA_OK || w[0].on != wn || memcmp(w[0].out, want, wn) != 0;
    ppa_free(w[0].out);
  }
  check(bad == 0, "40 short-lived threads: the same bytes", name);
  printf("threads (%s): 4 at once, 3 rounds, and 40 one after another: %s\n", name, bad ? "FAILED" : "the same bytes");
}

/* ---------- one deflate stream at a time (ppa_deflate_*) ---------- */

static double now_us(void) {
#ifdef _WIN32
  LARGE_INTEGER f, c;
  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&c);
  return (double)c.QuadPart * 1e6 / (double)f.QuadPart;
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
#endif
}

static int framing_of(const char *name) {
  size_t l = strlen(name);
  if (l > 4 && strcmp(name + l - 4, ".raw") == 0) return PPA_DEFLATE_RAW;
  if (l > 5 && strcmp(name + l - 5, ".zlib") == 0) return PPA_DEFLATE_ZLIB;
  return PPA_DEFLATE_AUTO;
}

typedef struct { const unsigned char *d; size_t n; int flags; void *rc; size_t rn; int r; } dstream_t;

/* every stream, in order, through one context: the result and recipe of each */
static void analyze_all(dstream_t *s, int ns) {
  ppa_deflate_ctx *c = ppa_deflate_ctx_new(0);
  for (int k = 0; k < ns; k++) {
    void *pl = 0;
    size_t pn = 0;
    s[k].rc = 0; s[k].rn = 0;
    s[k].r = ppa_deflate_analyze(c, s[k].d, s[k].n, s[k].flags, &pl, &pn, &s[k].rc, &s[k].rn, NULL, NULL);
    ppa_free(pl);
  }
  ppa_deflate_ctx_free(c);
}

typedef struct { dstream_t *s; int ns; } dwork_t;
#ifdef _WIN32
static DWORD WINAPI dworker(LPVOID arg) { dwork_t *w = arg; analyze_all(w->s, w->ns); return 0; }
#else
static void *dworker(void *arg) { dwork_t *w = arg; analyze_all(w->s, w->ns); return 0; }
#endif

static int cmp_double(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}

static int deflate_main(int argc, char **argv) {
  /* -1, -2, -3: the level (the default's none) */
  int level = 0;
  if (argc > 2 && argv[2][0] == '-' && argv[2][1] >= '1' && argv[2][1] <= '3' && !argv[2][2]) {
    level = (argv[2][1] - '0') << 4;
    argv++; argc--;
  }
  int ns = argc - 2, ok = 0, notTaken = 0, data = 0, hinted = 0;
  dstream_t *s = calloc(ns > 0 ? ns : 1, sizeof *s);
  double *ta = calloc(ns > 0 ? ns : 1, sizeof *ta), *tr = calloc(ns > 0 ? ns : 1, sizeof *tr);
  size_t *sz = calloc(ns > 0 ? ns : 1, sizeof *sz);
  size_t in = 0, plainSum = 0, recipeSum = 0;
  double tA = 0, tR = 0;
  uint64_t fnv = 0;                              /* the recipes (the one context's), for CI's platforms */
  ppa_deflate_ctx *batch = ppa_deflate_ctx_new(0);
  check(batch != NULL, "a context", "");
  for (int k = 0; k < ns; k++) {
    const char *name = argv[k + 2];
    size_t n;
    unsigned char *d = slurp(name, &n);
    if (!d) { check(0, "read", name); s[k].d = (unsigned char *)""; continue; }
    s[k].d = d; s[k].n = n; s[k].flags = framing_of(name) | level;
    void *pl = 0, *rc = 0, *back = 0;
    size_t pn = 0, rn = 0, bn = 0, cons = 0, ep = 0;
    double t0 = now_us();
    int r = ppa_deflate_analyze(batch, d, n, s[k].flags, &pl, &pn, &rc, &rn, &cons, &ep);
    double t1 = now_us();
    sz[k] = n; ta[k] = t1 - t0;
    tA += t1 - t0;
    in += n;
    if (r == PPA_E_NOT_TAKEN) { notTaken++; printf("  not taken: %s\n", name); continue; }
    if (strstr(name, "bad/") || strstr(name, "bad\\")) {  /* a stream inflate refuses: PPA_E_DATA, where it showed */
      check(r == PPA_E_DATA && ep <= n && pl == NULL && rc == NULL, "a damaged stream: PPA_E_DATA within it", name);
      if (r == PPA_E_DATA) { data++; printf("  refused at %zu of %zu: %s\n", ep, n, name); }
      ppa_free(pl); ppa_free(rc);
      continue;
    }
    if (r != PPA_OK) { data++; check(0, "analyze", name); continue; }
    check(cons > 0 && cons <= n, "consumed within the stream", name);
    t0 = now_us();
    r = ppa_deflate_rebuild(NULL, pl, pn, rc, rn, 0, &back, &bn, &ep);
    t1 = now_us();
    tr[k] = t1 - t0;
    tR += t1 - t0;
    check(r == PPA_OK && bn == cons && memcmp(back, d, cons) == 0, "rebuilt the same", name);
    ok += r == PPA_OK && bn == cons && memcmp(back, d, cons) == 0;
    plainSum += pn; recipeSum += rn;
    {                                            /* each recipe's hash, summed: the order of the files does not count */
      uint64_t h = 14695981039346656037u;
      for (size_t j = 0; j < rn; j++) h = (h ^ ((unsigned char *)rc)[j]) * 1099511628211u;
      fnv += h;
      const char *base = strrchr(name, '/');
      printf("  recipe %016llx %s\n", (unsigned long long)h, base ? base + 1 : name);
    }
    ppa_free(back); back = 0;
    /* a fresh context (no hint): a recipe that gives the same stream */
    {
      ppa_deflate_ctx *c = ppa_deflate_ctx_new(0);
      void *pl2 = 0, *rc2 = 0;
      size_t pn2 = 0, rn2 = 0;
      r = ppa_deflate_analyze(c, d, n, s[k].flags, &pl2, &pn2, &rc2, &rn2, NULL, NULL);
      check(r == PPA_OK && pn2 == pn && memcmp(pl2, pl, pn) == 0, "a fresh context: taken, the same bytes", name);
      hinted += r == PPA_OK && (rn2 != rn || memcmp(rc2, rc, rn) != 0);
      if (r == PPA_OK) {
        r = ppa_deflate_rebuild(c, pl2, pn2, rc2, rn2, 0, &back, &bn, NULL);
        check(r == PPA_OK && bn == cons && memcmp(back, d, cons) == 0, "a fresh context: rebuilt the same", name);
        ppa_free(back); back = 0;
      }
      /* the stream with bytes after it: left out, the same recipe */
      if (k < 40) {
        unsigned char *d2 = malloc(n + 9);
        memcpy(d2, d, n);
        memcpy(d2 + n, "TRAILING!", 9);
        void *pl3 = 0, *rc3 = 0;
        size_t pn3 = 0, rn3 = 0, cons3 = 0;
        ppa_deflate_ctx *c3 = ppa_deflate_ctx_new(0);
        r = ppa_deflate_analyze(c3, d2, n + 9, s[k].flags, &pl3, &pn3, &rc3, &rn3, &cons3, NULL);
        check(r == PPA_OK && cons3 == cons && rn3 == rn2 && memcmp(rc3, rc2, rn2) == 0,
              "bytes after the stream: left out", name);
        ppa_deflate_ctx_free(c3);
        ppa_free(pl3); ppa_free(rc3); free(d2);
      }
      ppa_deflate_ctx_free(c);
      ppa_free(pl2); ppa_free(rc2);
    }
    /* max_out below the stream: PPA_E_MEMORY */
    if (k < 40) {
      check(ppa_deflate_rebuild(NULL, pl, pn, rc, rn, cons - 1, &back, &bn, NULL) == PPA_E_MEMORY && back == NULL,
            "rebuild, max_out below the stream: PPA_E_MEMORY", name);
      /* a newer recipe: PPA_E_VERSION; version 0 to 2: PPA_E_DATA */
      unsigned char *rv = malloc(rn);
      memcpy(rv, rc, rn);
      int bad = 0;
      for (int v = 0; v < 256; v++) {
        rv[0] = (unsigned char)v;
        r = ppa_deflate_rebuild(NULL, pl, pn, rv, rn, 0, &back, &bn, NULL);
        ppa_free(back); back = 0;
        if (v > 6) bad += r != PPA_E_VERSION;
        else if (v < 3) bad += r != PPA_E_DATA;
      }
      check(bad == 0, "recipe versions: 7 to 255 PPA_E_VERSION, 0 to 2 PPA_E_DATA", name);
      /* damaged recipes and bytes: an error or a stream, no crash */
      memcpy(rv, rc, rn);
      for (size_t j = 1; j < rn; j++) {
        rv[j] ^= 0x5A;
        r = ppa_deflate_rebuild(NULL, pl, pn, rv, rn, 0, &back, &bn, NULL);
        ppa_free(back); back = 0;
        rv[j] ^= 0x5A;
        check(r == PPA_OK || r == PPA_E_DATA || r == PPA_E_VERSION, "a damaged recipe: an error or a stream", name);
      }
      r = ppa_deflate_rebuild(NULL, pl, pn, rc, rn - 1, 0, &back, &bn, NULL);
      ppa_free(back); back = 0;
      check(r == PPA_E_DATA, "a recipe cut short: PPA_E_DATA", name);
      if (pn > 0) {
        r = ppa_deflate_rebuild(NULL, pl, pn - 1, rc, rn, 0, &back, &bn, NULL);
        ppa_free(back); back = 0;
        check(r == PPA_OK || r == PPA_E_DATA, "a byte short: an error or a stream", name);
      }
      free(rv);
      /* the stream cut short or damaged: an error or not taken, no crash */
      for (size_t cut = 0; cut < n; cut += n / 5 + 1) {
        void *p4 = 0, *r4 = 0;
        size_t p4n = 0, r4n = 0;
        ppa_deflate_ctx *c4 = ppa_deflate_ctx_new(0);
        r = ppa_deflate_analyze(c4, d, cut, s[k].flags, &p4, &p4n, &r4, &r4n, NULL, NULL);
        check(r == PPA_E_DATA || r == PPA_E_NOT_TAKEN || r == PPA_OK, "a stream cut short", name);
        ppa_deflate_ctx_free(c4);
        ppa_free(p4); ppa_free(r4);
      }
    }
    ppa_free(pl); ppa_free(rc);
  }
  /* 4 threads, a context each, the streams in the same order: the same
     recipes as one context on this thread */
  if (ns > 0) {
    dstream_t *one = malloc(ns * sizeof *one), *w4[4];
    memcpy(one, s, ns * sizeof *one);
    analyze_all(one, ns);
    dwork_t dw[4];
    for (int t = 0; t < 4; t++) {
      w4[t] = malloc(ns * sizeof *w4[t]);
      memcpy(w4[t], s, ns * sizeof *w4[t]);
      dw[t].s = w4[t]; dw[t].ns = ns;
    }
#ifdef _WIN32
    HANDLE h[4];
    for (int t = 0; t < 4; t++) h[t] = CreateThread(NULL, 0, dworker, &dw[t], 0, NULL);
    for (int t = 0; t < 4; t++) { WaitForSingleObject(h[t], INFINITE); CloseHandle(h[t]); }
#else
    pthread_t h[4];
    for (int t = 0; t < 4; t++) pthread_create(&h[t], NULL, dworker, &dw[t]);
    for (int t = 0; t < 4; t++) pthread_join(h[t], NULL);
#endif
    int bad = 0;
    for (int t = 0; t < 4; t++) {
      for (int k = 0; k < ns; k++) {
        bad += w4[t][k].r != one[k].r || w4[t][k].rn != one[k].rn ||
               (one[k].rn && memcmp(w4[t][k].rc, one[k].rc, one[k].rn) != 0);
        ppa_free(w4[t][k].rc);
      }
      free(w4[t]);
    }
    for (int k = 0; k < ns; k++) ppa_free(one[k].rc);
    free(one);
    check(bad == 0, "4 threads, a context each: the same recipes", "");
    printf("deflate, 4 threads with a context each: %s\n", bad ? "OTHER recipes" : "the same recipes");
  }
  {                                                /* bad arguments, and nothing */
    void *p = 0, *q = 0;
    size_t pn = 0, qn = 0, ep = 0;
    static const unsigned char z[2] = {0x78, 0x9C}, fd[2] = {0x78, 0xBB};
    check(ppa_deflate_analyze(NULL, z, 2, PPA_DEFLATE_ZLIB, &p, &pn, &q, &qn, NULL, NULL) == PPA_E_ARG, "analyze, no context", "");
    check(ppa_deflate_analyze(batch, z, 2, 0, &p, &pn, &q, &qn, NULL, NULL) == PPA_E_ARG, "analyze, no framing", "");
    check(ppa_deflate_analyze(batch, z, 2, PPA_DEFLATE_ZLIB | 0x100, &p, &pn, &q, &qn, NULL, NULL) == PPA_E_ARG,
          "analyze, unknown flags", "");
    check(ppa_deflate_analyze(batch, z, 2, PPA_DEFLATE_ZLIB, NULL, &pn, &q, &qn, NULL, NULL) == PPA_E_ARG, "analyze, null plain", "");
    check(ppa_deflate_analyze(batch, NULL, 0, PPA_DEFLATE_ZLIB, &p, &pn, &q, &qn, NULL, &ep) == PPA_E_DATA, "analyze, nothing", "");
    check(ppa_deflate_analyze(batch, z, 2, PPA_DEFLATE_ZLIB, &p, &pn, &q, &qn, NULL, &ep) == PPA_E_DATA,
          "analyze, a header alone", "");
    check(ppa_deflate_analyze(batch, fd, 2, PPA_DEFLATE_AUTO, &p, &pn, &q, &qn, NULL, NULL) == PPA_E_NOT_TAKEN,
          "analyze, a preset dictionary: not taken", "");
    check(ppa_deflate_rebuild(NULL, z, 2, NULL, 0, 0, &p, &pn, NULL) == PPA_E_DATA, "rebuild, no recipe", "");
    check(ppa_deflate_rebuild(NULL, z, 2, z, 2, 0, NULL, &pn, NULL) == PPA_E_ARG, "rebuild, null out", "");
    ppa_deflate_ctx *small = ppa_deflate_ctx_new(16);
    for (int k = 0; k < ns; k++)
      if (s[k].n > 64) {
        size_t cons = 0;
        int r = ppa_deflate_analyze(small, s[k].d, s[k].n, s[k].flags, &p, &pn, &q, &qn, &cons, NULL);
        check(r == PPA_E_MEMORY || (r == PPA_OK && pn <= 16) || r == PPA_E_DATA, "over max_plain: PPA_E_MEMORY", argv[k + 2]);
        ppa_free(p); ppa_free(q); p = q = 0;
        break;
      }
    ppa_deflate_ctx_free(small);
    ppa_deflate_ctx_free(NULL);
  }
  ppa_deflate_ctx_free(batch);
  printf("deflate: %d streams, %d rebuilt the same, %d not taken, %d refused; %zu bytes -> %zu bytes "
         "and %zu of recipes; %d recipes other with a fresh context\n",
         ns, ok, notTaken, data, in, plainSum, recipeSum, hinted);
  /* the time a stream takes: the median of each size class */
  static const size_t lim[] = {256, 1024, 4096, 65536, (size_t)-1};
  size_t lo = 0;
  double *a = malloc((ns > 0 ? ns : 1) * sizeof *a), *b = malloc((ns > 0 ? ns : 1) * sizeof *b);
  for (unsigned c = 0; c < sizeof lim / sizeof lim[0]; c++) {
    int m = 0;
    for (int k = 0; k < ns; k++)
      if (sz[k] >= lo && sz[k] < lim[c] && tr[k] > 0) { a[m] = ta[k]; b[m] = tr[k]; m++; }
    if (m > 0) {
      qsort(a, m, sizeof *a, cmp_double);
      qsort(b, m, sizeof *b, cmp_double);
      printf("deflate, streams of %zu to %zu bytes: %d, median %.0f us to analyze, %.0f us to rebuild\n",
             lo, lim[c] == (size_t)-1 ? (size_t)0 : lim[c] - 1, m, a[m / 2], b[m / 2]);
    }
    lo = lim[c];
  }
  printf("deflate: %.2f s to analyze, %.2f s to rebuild\n", tA / 1e6, tR / 1e6);
  printf("deflate: recipes %016llx\n", (unsigned long long)fnv);
  free(a); free(b);
  for (int k = 0; k < ns; k++) if (s[k].n) free((void *)s[k].d);
  free(s); free(ta); free(tr); free(sz);
  printf("%d checks, %d failures\n", checks, failures);
  return failures != 0;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);   /* every line out at once, even if a check hangs */
  printf("%s\n", ppa_version());
  if (argc > 1 && strcmp(argv[1], "--deflate") == 0) return deflate_main(argc, argv);
  unsigned char *all = 0;
  size_t alln = 0, taken = 0, insum = 0, outsum = 0;
  unsigned seed = 1;
  int versioned = 0, threaded = 0;
  for (int a = 1; a < argc; a++) {
    size_t n;
    unsigned char *d = slurp(argv[a], &n);
    if (!d) { check(0, "read", argv[a]); continue; }
    void *p = 0, *back = 0;
    size_t pn = 0, bn = 0;
    int r = ppa_compress(d, n, &p, &pn, 2);
    check(r == PPA_OK || r == PPA_E_NOT_TAKEN, "compress", argv[a]);
    if (r == PPA_OK && !versioned && pn > 40 && n > 8 && d[0] == 0x89 && !(((unsigned char *)p)[5] & 1)) {
      versions(p, pn);
      versioned = 1;
    }
    if (r == PPA_OK) {
      void *p2 = 0;                                /* again, on one thread */
      size_t pn2 = 0;
      check(ppa_compress(d, n, &p2, &pn2, 1) == PPA_OK && pn2 == pn && memcmp(p2, p, pn) == 0,
            "the same bytes on 1 thread", argv[a]);
      ppa_free(p2);
      if (!threaded) { threads_test(d, n, p, pn, argv[a]); threaded = 1; }
      /* the levels: level 2 is ppa_compress; 1 and 3 come back too */
      for (int lv = 1; lv <= 3; lv++) {
        void *pl = 0, *bl = 0;
        size_t pln = 0, bln = 0;
        int rl = ppa_compress_level(d, n, &pl, &pln, 1, lv);
        if (lv == 2) check(rl == PPA_OK && pln == pn && memcmp(pl, p, pn) == 0, "level 2: ppa_compress's bytes", argv[a]);
        else if (rl == PPA_OK) {
          check(ppa_decompress(pl, pln, &bl, &bln, 0, 1) == PPA_OK && bln == n && memcmp(bl, d, n) == 0,
                lv == 1 ? "level 1 back" : "level 3 back", argv[a]);
        } else check(rl == PPA_E_NOT_TAKEN, "level 1 or 3: taken or not", argv[a]);
        ppa_free(pl); ppa_free(bl);
      }
      taken++; insum += n; outsum += pn;
      r = ppa_decompress(p, pn, &back, &bn, 0, 2);
      check(r == PPA_OK && bn == n && memcmp(back, d, n) == 0, "decompress", argv[a]);
      ppa_free(back); back = 0;
      r = ppa_decompress(p, pn, &back, &bn, n - 1, 1);
      check(r == PPA_E_MEMORY, "decompress, max_size below the original: PPA_E_MEMORY", argv[a]);
      ppa_free(back);
      if (pn > 40) {                               /* one flipped byte: caught */
        ((unsigned char *)p)[pn / 2] ^= 0x55;
        back = 0;
        r = ppa_decompress(p, pn, &back, &bn, 0, 1);
        check(r != PPA_OK, "damaged .ppa refused", argv[a]);
        ppa_free(back);
      }
    }
    ppa_free(p);
    /* the stream: some bytes, a false signature, the file */
    size_t junk = (seed = seed * 1103515245u + 12345u) % 3000;
    all = realloc(all, alln + junk + n + 12);
    for (size_t k = 0; k < junk; k++) all[alln++] = (unsigned char)((seed >> (k % 24)) ^ k);
    static const unsigned char fake[12] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13};
    memcpy(all + alln, fake, sizeof fake); alln += sizeof fake;
    memcpy(all + alln, d, n); alln += n;
    free(d);
  }
  printf("%zu of %d files taken: %zu -> %zu bytes as .ppa\n", taken, argc - 1, insum, outsum);
  check(versioned, "a PNG for the version checks", "");
  check(threaded, "a PNG for the thread checks", "");
  {                                                /* null pointers: an error, not a crash */
    static const unsigned char some[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    void *p = 0;
    size_t pn = 0;
    check(ppa_compress(some, 8, NULL, &pn, 1) == PPA_E_ARG, "compress, null out", "");
    check(ppa_compress(some, 8, &p, NULL, 1) == PPA_E_ARG, "compress, null out_size", "");
    check(ppa_decompress(some, 8, NULL, &pn, 0, 1) == PPA_E_ARG, "decompress, null out", "");
    check(ppa_decompress(some, 8, &p, NULL, 0, 1) == PPA_E_ARG, "decompress, null out_size", "");
    check(ppa_compress(NULL, 0, &p, &pn, 1) == PPA_E_NOT_TAKEN, "compress, nothing: not taken", "");
    check(ppa_compress(some, 8, &p, &pn, 1) == PPA_E_NOT_TAKEN, "compress, a signature alone: not taken", "");
    check(ppa_filter_encode(NULL, NULL, NULL, NULL, 1) == PPA_E_ARG, "filter, null functions", "");
    check(ppa_filter_decode(NULL, NULL, NULL, NULL, 1) == PPA_E_ARG, "filter decode, null functions", "");
    check(ppa_compress_level(some, 8, &p, &pn, 1, 0) == PPA_E_ARG, "compress, level 0", "");
    check(ppa_compress_level(some, 8, &p, &pn, 1, 4) == PPA_E_ARG, "compress, level 4", "");
    check(ppa_filter_encode_level(rd, NULL, wr, NULL, 1, 0) == PPA_E_ARG, "filter, level 0", "");
    check(ppa_filter_encode_level(rd, NULL, wr, NULL, 1, 4) == PPA_E_ARG, "filter, level 4", "");
  }
  static const size_t steps[] = {1 << 20, 4096, 1000, 7, 1};
  dst_t enc = {0};
  for (unsigned s = 0; s < sizeof steps / sizeof steps[0]; s++) {
    if (steps[s] < 1000 && alln > (8u << 20)) continue;   /* byte by byte only on small sets */
    src_t in = {all, alln, 0, steps[s]};
    dst_t e = {0}, b = {0};
    int r = ppa_filter_encode(rd, &in, wr, &e, 4);
    check(r == PPA_OK, "filter encode", "");
    src_t in2 = {e.d, e.n, 0, steps[s]};
    r = ppa_filter_decode(rd, &in2, wr, &b, 4);
    check(r == PPA_OK && b.n == alln && memcmp(b.d, all, alln) == 0, "filter round trip", "");
    if (s > 0) check(e.n == enc.n && memcmp(e.d, enc.d, e.n) == 0, "filter: the same stream whatever the reads", "");
    printf("filter, reads of %zu: %zu -> %zu bytes, %s\n", steps[s], alln, e.n,
           r == PPA_OK && b.n == alln ? "back" : "NOT back");
    if (s == 0) enc = e; else free(e.d);
    free(b.d);
  }
  check(enc.n < alln, "filter: smaller", "");
  /* the same stream on one thread: the same bytes */
  {
    src_t in = {all, alln, 0, 1 << 20};
    dst_t e = {0};
    check(ppa_filter_encode(rd, &in, wr, &e, 1) == PPA_OK && e.n == enc.n && memcmp(e.d, enc.d, e.n) == 0,
          "filter: the same stream on 1 thread", "");
    free(e.d);
  }
  /* the levels: the default is level 2; levels 1 and 3 come back */
  for (int lv = 1; lv <= 3; lv++) {
    src_t in = {all, alln, 0, 1 << 20};
    dst_t e = {0}, b = {0};
    check(ppa_filter_encode_level(rd, &in, wr, &e, 4, lv) == PPA_OK, "filter encode at a level", "");
    if (lv == 2) check(e.n == enc.n && memcmp(e.d, enc.d, e.n) == 0, "filter: level 2 is the default", "");
    src_t in2 = {e.d, e.n, 0, 1 << 20};
    check(ppa_filter_decode(rd, &in2, wr, &b, 4) == PPA_OK && b.n == alln && memcmp(b.d, all, alln) == 0,
          "filter round trip at a level", "");
    free(e.d); free(b.d);
  }
  /* damaged filter streams: about 300 bytes spread over the stream
     flipped, one at a time, and cut short at a few places */
  int bad = 0, same = 0;
  for (size_t k = 0; k < enc.n; k += enc.n / 300 + 1) {
    enc.d[k] ^= 0x41;
    src_t in = {enc.d, enc.n, 0, 1 << 20};
    dst_t b = {0};
    int r = ppa_filter_decode(rd, &in, wr, &b, 1);
    if (r != PPA_OK) bad++;
    else same += b.n == alln && memcmp(b.d, all, alln) == 0;
    free(b.d);
    enc.d[k] ^= 0x41;
  }
  for (size_t cut = 0; cut < enc.n; cut += enc.n / 7 + 1) {
    src_t in = {enc.d, cut, 0, 1 << 20};
    dst_t b = {0};
    check(ppa_filter_decode(rd, &in, wr, &b, 1) != PPA_OK, "cut filter stream refused", "");
    free(b.d);
  }
  printf("damaged filter streams: %d refused, %d decoded the same, the rest other bytes, no crash\n",
         bad, same);
  free(enc.d);
  free(all);
  printf("%d checks, %d failures\n", checks, failures);
  return failures != 0;
}
