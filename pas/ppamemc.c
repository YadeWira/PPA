/* memcpy, memmove, memset and memcmp for PPA's C that is not its own
   (ppaldfc.c: libdeflate's compressor; ppazopc.c: zopfli's deflate), which
   the compiler still calls them for (a struct assigned whole, a length
   known only at run time): PPA's C needs no C runtime. Hidden where the
   object format allows it: nothing outside the program sees them.
   build_c.sh keeps the compiler from turning their loops into calls to
   themselves. Linked once (ppalibdeflate.pas). */
#include <stddef.h>

#if defined(_WIN32) || defined(__CYGWIN__)
#define PPA_MEM_LOCAL
#else
#define PPA_MEM_LOCAL __attribute__((visibility("hidden")))
#endif

PPA_MEM_LOCAL void *memcpy(void *d, const void *s, size_t n) {
  unsigned char *a = d;
  const unsigned char *b = s;
  while (n--) *a++ = *b++;
  return d;
}

PPA_MEM_LOCAL void *memmove(void *d, const void *s, size_t n) {
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

PPA_MEM_LOCAL void *memset(void *d, int c, size_t n) {
  unsigned char *a = d;
  while (n--) *a++ = (unsigned char)c;
  return d;
}

PPA_MEM_LOCAL int memcmp(const void *x, const void *y, size_t n) {
  const unsigned char *a = x, *b = y;
  for (; n; n--, a++, b++)
    if (*a != *b) return *a < *b ? -1 : 1;
  return 0;
}
