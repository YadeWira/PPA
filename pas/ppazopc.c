/* zopfli's deflate (vendor/zopfli: zopfli 1.0.3's src/zopfli, unmodified)
   for PPA's deflate recipes of kind 2, encoder 3: one call,
   ppa_zop_deflate, and the same bits on every platform.

   - No C runtime, as the rest of PPA's C: malloc, realloc, calloc and free
     are the caller's memory, each block on a list kept for the call, so
     that a failure (zopfli's exit() where an allocation failed) jumps back
     to ppa_zop_deflate (__builtin_setjmp, no library), which frees what
     was left and returns 0: the process (a 7-Zip host) never exits.
     memcpy, memmove, memset are ppamemc.c's; fprintf (zopfli's verbose
     output) is nothing.
   - The same bits everywhere: zopfli's costs are doubles; IEEE +, -, *, /
     give the same results on every platform with -ffp-contract=off and SSE2
     doubles (build_c.sh: -msse2 -mfpmath=sse on 32-bit x86), and its only
     libm call, log() of symbol counts, is ppa_zop_log: double-double
     arithmetic, correctly rounded (glibc's log is not on 487 of the
     integers up to 20,000,000; a stream PPA's zopfli does not give back is
     simply not this recipe). */
#define NDEBUG
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

/* memcpy, memmove, memset: ppamemc.c's */

#if defined(__MINGW32__)
/* Windows: a frame of more than a page (zopfli's has a few) is probed a
   page at a time first, so that the stack's guard page grows it: gcc calls
   ___chkstk_ms with the frame's size in rax (eax), which libgcc would give
   and PPA does not link. It touches every page from the stack pointer down
   to that size and changes no register. */
#if defined(__x86_64__)
__asm__(".text\n.globl ___chkstk_ms\n___chkstk_ms:\n"
        "  pushq %rcx\n  pushq %rax\n  leaq 24(%rsp), %rcx\n"
        "1: cmpq $0x1000, %rax\n  jb 2f\n  subq $0x1000, %rcx\n  orq $0, (%rcx)\n  subq $0x1000, %rax\n  jmp 1b\n"
        "2: subq %rax, %rcx\n  orq $0, (%rcx)\n  popq %rax\n  popq %rcx\n  ret\n");
#elif defined(__i386__)
__asm__(".text\n.globl ___chkstk_ms\n___chkstk_ms:\n"
        "  pushl %ecx\n  pushl %eax\n  leal 12(%esp), %ecx\n"
        "1: cmpl $0x1000, %eax\n  jb 2f\n  subl $0x1000, %ecx\n  orl $0, (%ecx)\n  subl $0x1000, %eax\n  jmp 1b\n"
        "2: subl %eax, %ecx\n  orl $0, (%ecx)\n  popl %eax\n  popl %ecx\n  ret\n");
#endif
#endif

/* ppa_zop_log: the natural logarithm of a double >= 1, correctly rounded in
   practice: double-double arithmetic (Dekker's products by Veltkamp's
   split, no fused multiply-add), only IEEE +, -, * and /, so that every
   platform gets the same bits (with SSE2 doubles, never x87's, and
   -ffp-contract=off). zopfli takes logs of symbol counts only. */
typedef struct { double hi, lo; } ppa_dd;
static ppa_dd ppa_dd_two_sum(double a, double b) {
  double s = a + b, bb = s - a; ppa_dd r; r.hi = s; r.lo = (a - (s - bb)) + (b - bb); return r;
}
static ppa_dd ppa_dd_quick(double a, double b) { double s = a + b; ppa_dd r; r.hi = s; r.lo = b - (s - a); return r; }
static void ppa_dd_split(double a, double *h, double *l) {
  double t = 134217729.0 * a; *h = t - (t - a); *l = a - *h;     /* 2^27 + 1 */
}
static ppa_dd ppa_dd_two_prod(double a, double b) {
  double ah, al, bh, bl, p = a * b; ppa_dd r;
  ppa_dd_split(a, &ah, &al); ppa_dd_split(b, &bh, &bl);
  r.hi = p; r.lo = ((ah * bh - p) + ah * bl + al * bh) + al * bl; return r;
}
static ppa_dd ppa_dd_add(ppa_dd a, ppa_dd b) {
  ppa_dd s = ppa_dd_two_sum(a.hi, b.hi), t = ppa_dd_two_sum(a.lo, b.lo);
  s.lo += t.hi; s = ppa_dd_quick(s.hi, s.lo); s.lo += t.lo; return ppa_dd_quick(s.hi, s.lo);
}
static ppa_dd ppa_dd_mul(ppa_dd a, ppa_dd b) {
  ppa_dd p = ppa_dd_two_prod(a.hi, b.hi); p.lo += a.hi * b.lo + a.lo * b.hi; return ppa_dd_quick(p.hi, p.lo);
}
static ppa_dd ppa_dd_div(ppa_dd a, ppa_dd b) {
  double q1 = a.hi / b.hi; ppa_dd r = ppa_dd_add(a, ppa_dd_mul(b, (ppa_dd){-q1, 0}));
  double q2 = r.hi / b.hi; r = ppa_dd_add(r, ppa_dd_mul(b, (ppa_dd){-q2, 0}));
  double q3 = r.hi / b.hi; ppa_dd q = ppa_dd_quick(q1, q2); return ppa_dd_add(q, (ppa_dd){q3, 0});
}
static double ppa_zop_log(double x) {
  /* x = m * 2^e, m in [sqrt(1/2), sqrt(2)) */
  static const ppa_dd LN2 = {6.93147180559945286e-01, 2.31904681384629956e-17};
  int e = 0; double m = x;
  if (!(x > 0)) return x == 0 ? -1.0 / 0.0 : 0.0 / 0.0;
  while (m >= 1.4142135623730951) { m *= 0.5; e++; }
  while (m < 0.70710678118654757) { m *= 2.0; e--; }
  /* log(m) = 2 atanh(s), s = (m - 1) / (m + 1), |s| < 0.1716 */
  ppa_dd s = ppa_dd_div(ppa_dd_two_sum(m, -1.0), ppa_dd_two_sum(m, 1.0));
  ppa_dd s2 = ppa_dd_mul(s, s), term = s, sum = s;
  for (int k = 3; k < 80; k += 2) {
    term = ppa_dd_mul(term, s2);
    ppa_dd t = ppa_dd_div(term, (ppa_dd){(double)k, 0});
    sum = ppa_dd_add(sum, t);
    if (t.hi == 0 || (t.hi < 0 ? -t.hi : t.hi) < 1e-36) break;
  }
  ppa_dd r = ppa_dd_add(ppa_dd_mul((ppa_dd){2.0, 0}, sum), ppa_dd_mul(LN2, (ppa_dd){(double)e, 0}));
  return r.hi + r.lo;
}

/* the call's memory: a list of blocks, each after a header that keeps the
   list and the size (32 bytes: doubles stay aligned) */
typedef struct ppa_zop_blk { struct ppa_zop_blk *prev, *next; size_t size; size_t pad; } ppa_zop_blk;
typedef struct {
  void *(*alloc)(size_t);
  void (*release)(void *);
  ppa_zop_blk *list;
  void *jb[5];
} ppa_zop_ctx;
/* where the running call's context is: the caller's thread-local slot */
static ppa_zop_ctx **(*ppa_zop_slot)(void);

static void ppa_zop_fail(void) {
  ppa_zop_ctx *c = *ppa_zop_slot();
  __builtin_longjmp(c->jb, 1);
}
static void *ppa_zop_malloc(size_t n) {
  ppa_zop_ctx *c = *ppa_zop_slot();
  if (n > (size_t)-1 - sizeof(ppa_zop_blk)) ppa_zop_fail();
  ppa_zop_blk *b = c->alloc(sizeof(ppa_zop_blk) + n);
  if (!b) ppa_zop_fail();
  b->size = n; b->prev = 0; b->next = c->list;
  if (c->list) c->list->prev = b;
  c->list = b;
  return b + 1;
}
static void ppa_zop_free(void *p) {
  if (!p) return;
  ppa_zop_ctx *c = *ppa_zop_slot();
  ppa_zop_blk *b = (ppa_zop_blk *)p - 1;
  if (b->prev) b->prev->next = b->next; else c->list = b->next;
  if (b->next) b->next->prev = b->prev;
  c->release(b);
}
static void *ppa_zop_realloc(void *p, size_t n) {
  if (!p) return ppa_zop_malloc(n);
  ppa_zop_blk *b = (ppa_zop_blk *)p - 1;
  void *q = ppa_zop_malloc(n);
  memcpy(q, p, b->size < n ? b->size : n);
  ppa_zop_free(p);
  return q;
}
static void *ppa_zop_calloc(size_t k, size_t n) {
  if (n && k > (size_t)-1 / n) ppa_zop_fail();
  void *p = ppa_zop_malloc(k * n);
  memset(p, 0, k * n);
  return p;
}

/* katajainen.c's only qsort: at most 288 leaves whose weights hold their
   symbol in the low bits (no two equal), so any correct sort gives the
   same order: insertion sort */
static void ppa_zop_qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
  unsigned char *a = base, t[64];
  if (size > sizeof t) ppa_zop_fail();
  for (size_t i = 1; i < n; i++) {
    size_t j = i;
    memcpy(t, a + i * size, size);
    while (j > 0 && cmp(a + (j - 1) * size, t) > 0) { memcpy(a + j * size, a + (j - 1) * size, size); j--; }
    memcpy(a + j * size, t, size);
  }
}

#define qsort(b, n, s, f) ppa_zop_qsort(b, n, s, f)
#define malloc(n) ppa_zop_malloc(n)
#define realloc(p, n) ppa_zop_realloc(p, n)
#define calloc(k, n) ppa_zop_calloc(k, n)
#define free(p) ppa_zop_free(p)
#define exit(c) ppa_zop_fail()
#define fprintf(...) ((void)0)
#define log(x) ppa_zop_log(x)

#include "src/zopfli/util.c"
#include "src/zopfli/hash.c"
#include "src/zopfli/cache.c"
#include "src/zopfli/katajainen.c"
#include "src/zopfli/tree.c"
#include "src/zopfli/lz77.c"
#include "src/zopfli/squeeze.c"
#include "src/zopfli/blocksplitter.c"
#include "src/zopfli/deflate.c"

/* 32-bit x86: this object's doubles are SSE2's (build_c.sh), the same
   bits as x86-64's; a processor without SSE2 (before the Pentium 4 and
   the Athlon 64) runs none of it: every call fails cleanly. */
#if defined(__i386__)
#include <cpuid.h>
static int ppa_zop_cpu_ok(void) {
  unsigned a, b, c, d;
  if (!__get_cpuid(1, &a, &b, &c, &d)) return 0;
  return (d >> 26) & 1;
}
#else
static int ppa_zop_cpu_ok(void) { return 1; }
#endif

static ppa_zop_ctx *ppa_zop_none;
static ppa_zop_ctx **ppa_zop_no_slot(void) { return &ppa_zop_none; }

/* the caller's thread-local slot for the running call's context (once,
   before any call) */
void ppa_zop_init(ppa_zop_ctx **(*slot)(void)) { ppa_zop_slot = slot ? slot : ppa_zop_no_slot; }

/* n bytes at in -> raw deflate (ZopfliDeflate: btype 2, final, as
   zopflipng's and zopfli's own zlib and gzip containers write it) with
   the options given, at out (cap bytes): its length, or 0 when cap is
   short, an option is out of range or there was no memory. */
size_t ppa_zop_deflate(int iterations, int blocksplitting, int blocksplittinglast, int blocksplittingmax,
                       const unsigned char *in, size_t n, unsigned char *out, size_t cap,
                       void *(*alloc)(size_t), void (*release)(void *)) {
  ppa_zop_ctx c, **slot;
  ZopfliOptions o;
  unsigned char bp = 0, *res = 0;
  size_t len = 0, r = 0;
  if (!ppa_zop_cpu_ok() || !ppa_zop_slot || !alloc || !release || iterations < 1 || blocksplittingmax < 0) return 0;
  c.alloc = alloc; c.release = release; c.list = 0;
  slot = ppa_zop_slot();
  *slot = &c;
  if (__builtin_setjmp(c.jb) == 0) {
    ZopfliInitOptions(&o);
    o.numiterations = iterations;
    o.blocksplitting = blocksplitting;
    o.blocksplittinglast = blocksplittinglast;
    o.blocksplittingmax = blocksplittingmax;
    ZopfliDeflate(&o, 2, 1, in, n, &bp, &res, &len);
    if (len <= cap) { memcpy(out, res, len); r = len; }
  } else r = 0;
  while (c.list) ppa_zop_free(c.list + 1);
  *slot = 0;
  return r;
}

/* For the search (ppazopfli.FindZopParams), a fraction of a run: zopfli
   splits each master block (ZOPFLI_MASTER_BLOCK_SIZE bytes) before it
   iterates, optimises each piece on its own and writes their tokens in
   order (the blocks may be grouped again afterwards, the tokens not).

   ppa_zop_split: the first master block's split points (byte positions,
   ZopfliBlockSplit as ZopfliDeflatePart calls it) into pts (up to max):
   how many, or (size_t)-1 when there was no memory. */
size_t ppa_zop_split(int blocksplittingmax, const unsigned char *in, size_t n, size_t *pts, size_t max,
                     void *(*alloc)(size_t), void (*release)(void *)) {
  ppa_zop_ctx c, **slot;
  ZopfliOptions o;
  size_t *sp = 0, np = 0, r = (size_t)-1, end = n < ZOPFLI_MASTER_BLOCK_SIZE ? n : ZOPFLI_MASTER_BLOCK_SIZE;
  if (!ppa_zop_cpu_ok() || !ppa_zop_slot || !alloc || !release || blocksplittingmax < 0) return r;
  c.alloc = alloc; c.release = release; c.list = 0;
  slot = ppa_zop_slot();
  *slot = &c;
  if (__builtin_setjmp(c.jb) == 0) {
    ZopfliInitOptions(&o);
    o.blocksplittingmax = blocksplittingmax;
    ZopfliBlockSplit(&o, in, 0, end, blocksplittingmax, &sp, &np);
    for (size_t i = 0; i < np && i < max; i++) pts[i] = sp[i];
    r = np;
  }
  while (c.list) ppa_zop_free(c.list + 1);
  *slot = 0;
  return r;
}

/* The tokens ZopfliLZ77Optimal gives in[start..end) with that many
   iterations (litlen: a literal byte when dist is 0, else a length):
   how many (at most cap), or (size_t)-1 when there was no memory or more
   than cap. */
size_t ppa_zop_piece(int iterations, const unsigned char *in, size_t start, size_t end,
                     unsigned short *litlens, unsigned short *dists, size_t cap,
                     void *(*alloc)(size_t), void (*release)(void *)) {
  ppa_zop_ctx c, **slot;
  ZopfliOptions o;
  ZopfliBlockState bs;
  ZopfliLZ77Store st;
  size_t r = (size_t)-1;
  if (!ppa_zop_cpu_ok() || !ppa_zop_slot || !alloc || !release || iterations < 1 || start > end) return r;
  c.alloc = alloc; c.release = release; c.list = 0;
  slot = ppa_zop_slot();
  *slot = &c;
  if (__builtin_setjmp(c.jb) == 0) {
    ZopfliInitOptions(&o);
    ZopfliInitLZ77Store(in, &st);
    ZopfliInitBlockState(&o, start, end, 1, &bs);
    ZopfliLZ77Optimal(&bs, in, start, end, iterations, &st);
    if (st.size <= cap) {
      for (size_t i = 0; i < st.size; i++) { litlens[i] = st.litlens[i]; dists[i] = st.dists[i]; }
      r = st.size;
    }
  }
  while (c.list) ppa_zop_free(c.list + 1);
  *slot = 0;
  return r;
}

/* The code lengths zopfli gives a dynamic block of these tokens
   (GetDynamicLengths: its length-limited codes of the block's counts, the
   distance codes patched, and the smaller of those and the ones made for
   run-length coding), into ll_lengths[288] and d_lengths[32]: 1, or 0
   when there was no memory or a token is out of range. litlen: a literal
   byte when dist is 0, else a length (3..258). For the search's test of a
   stream's trees: exactly zopfli's, ties included. */
int ppa_zop_lengths(const unsigned short *litlens, const unsigned short *dists, size_t n,
                    unsigned *ll_lengths, unsigned *d_lengths,
                    void *(*alloc)(size_t), void (*release)(void *)) {
  ppa_zop_ctx c, **slot;
  ZopfliLZ77Store st;
  int r = 0;
  if (!ppa_zop_cpu_ok() || !ppa_zop_slot || !alloc || !release) return 0;
  for (size_t i = 0; i < n; i++)
    if (dists[i] ? litlens[i] < 3 || litlens[i] > 258 || dists[i] > 32768 : litlens[i] > 255) return 0;
  c.alloc = alloc; c.release = release; c.list = 0;
  slot = ppa_zop_slot();
  *slot = &c;
  if (__builtin_setjmp(c.jb) == 0) {
    ZopfliInitLZ77Store(0, &st);
    for (size_t i = 0; i < n; i++) ZopfliStoreLitLenDist(litlens[i], dists[i], 0, &st);
    GetDynamicLengths(&st, 0, n, ll_lengths, d_lengths);
    r = 1;
  }
  while (c.list) ppa_zop_free(c.list + 1);
  *slot = 0;
  return r;
}
