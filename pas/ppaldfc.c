/* libdeflate's compressor (vendor/libdeflate: lib/deflate_compress.c,
   unmodified) for PPA's deflate recipes of kind 2, encoder 2
   (ppalibdeflate.pas, doc/PREFLATE.md): one call, ppa_ldf_compress.

   No C runtime, as the rest of PPA's C: libdeflate's freestanding build
   (FREESTANDING: its memcpy, memmove and memset are the compiler's
   built-ins), the memory the caller's (libdeflate_alloc_compressor_ex),
   and memcpy, memmove and memset defined here for the copies the compiler
   still calls them for (a struct assigned whole, a length known only at
   run time). They are hidden where the object format allows it: nothing
   outside this object sees them. build_c.sh keeps the compiler from
   turning their loops into calls to themselves. */
#define FREESTANDING
#include "lib/lib_common.h"

#if defined(_WIN32) || defined(__CYGWIN__)
#define PPA_LDF_LOCAL
#else
#define PPA_LDF_LOCAL __attribute__((visibility("hidden")))
#endif

#undef memcpy
#undef memmove
#undef memset
#undef memcmp

PPA_LDF_LOCAL void *memcpy(void *d, const void *s, size_t n) {
  unsigned char *a = d;
  const unsigned char *b = s;
  while (n--) *a++ = *b++;
  return d;
}

PPA_LDF_LOCAL void *memmove(void *d, const void *s, size_t n) {
  unsigned char *a = d;
  const unsigned char *b = s;
  if (a <= b)
    while (n--) *a++ = *b++;
  else {
    a += n; b += n;
    while (n--) *--a = *--b;
  }
  return d;
}

PPA_LDF_LOCAL void *memset(void *d, int c, size_t n) {
  unsigned char *a = d;
  while (n--) *a++ = (unsigned char)c;
  return d;
}

PPA_LDF_LOCAL int memcmp(const void *x, const void *y, size_t n) {
  const unsigned char *a = x, *b = y;
  for (; n; n--, a++, b++)
    if (*a != *b) return *a < *b ? -1 : 1;
  return 0;
}

#define memcpy(d, s, n) __builtin_memcpy((d), (s), (n))
#define memmove(d, s, n) __builtin_memmove((d), (s), (n))
#define memset(s, c, n) __builtin_memset((s), (c), (n))
#define memcmp(x, y, n) __builtin_memcmp((x), (y), (n))

/* libdeflate's utils.c, the parts the compressor calls (its default
   allocator is never used: ppa_ldf_compress always gives one) */
malloc_func_t libdeflate_default_malloc_func;
free_func_t libdeflate_default_free_func;

void *libdeflate_aligned_malloc(malloc_func_t malloc_func, size_t alignment, size_t size) {
  void *ptr = (*malloc_func)(sizeof(void *) + alignment - 1 + size);
  if (ptr) {
    void *orig = ptr;
    ptr = (void *)ALIGN((uintptr_t)ptr + sizeof(void *), alignment);
    ((void **)ptr)[-1] = orig;
  }
  return ptr;
}

void libdeflate_aligned_free(free_func_t free_func, void *ptr) {
  if (ptr) (*free_func)(((void **)ptr)[-1]);
}

#include "lib/deflate_compress.c"

/* n bytes at in -> raw deflate at out (what libdeflate_deflate_compress
   writes at that level, 1 to 12): its length, or 0 when the level is not
   one, cap is too short, or alloc gave no memory. alloc and release: the
   caller's (cdecl). */
size_t ppa_ldf_compress(int level, const void *in, size_t n, void *out, size_t cap,
                        void *(*alloc)(size_t), void (*release)(void *)) {
  struct libdeflate_options o;
  struct libdeflate_compressor *c;
  size_t r;
  if (level < 1 || level > 12 || !alloc || !release) return 0;
  memset(&o, 0, sizeof o);
  o.sizeof_options = sizeof o;
  o.malloc_func = alloc;
  o.free_func = release;
  c = libdeflate_alloc_compressor_ex(level, &o);
  if (!c) return 0;
  r = libdeflate_deflate_compress(c, in, n, out, cap);
  libdeflate_free_compressor(c);
  return r;
}

/* the most ppa_ldf_compress writes for n bytes, at any level */
size_t ppa_ldf_bound(size_t n) { return libdeflate_deflate_compress_bound(NULL, n); }
