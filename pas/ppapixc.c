/* Layer 3's hot spot in C: a line filtered with Paeth (the filter that
   costs, and the one photographs use most), bit for bit what ppapixels'
   Pascal FilterLine does (PPA_NOC=1 picks the Pascal one; the suite filters
   every sample both ways). Filtering, every input is known: 16 bytes at a
   time with SSE2, without a branch otherwise. Takes no memory and calls no
   library. */
#include <stdint.h>
#if defined(__SSE2__) && !defined(PPA_NO_SIMD)
#include <emmintrin.h>
#define PX_SSE2 1
#endif

static inline int px_paeth(int a, int b, int c) {
  const int p = a + b - c;
  int pa = p - a, pb = p - b, pc = p - c;
  pa = pa < 0 ? -pa : pa; pb = pb < 0 ? -pb : pb; pc = pc < 0 ? -pc : pc;
  return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
}

#ifdef PX_SSE2
/* eight 16-bit lanes: a, b, c -> the Paeth predictor */
static inline __m128i paeth8(__m128i a, __m128i b, __m128i c) {
  const __m128i z = _mm_setzero_si128();
  const __m128i pa0 = _mm_sub_epi16(b, c), pb0 = _mm_sub_epi16(a, c);   /* p - a = b - c, p - b = a - c */
  const __m128i pc0 = _mm_add_epi16(pa0, pb0);                          /* p - c */
  const __m128i pa = _mm_max_epi16(pa0, _mm_sub_epi16(z, pa0));
  const __m128i pb = _mm_max_epi16(pb0, _mm_sub_epi16(z, pb0));
  const __m128i pc = _mm_max_epi16(pc0, _mm_sub_epi16(z, pc0));
  /* a where pa <= pb and pa <= pc; else b where pb <= pc; else c */
  const __m128i useA = _mm_andnot_si128(_mm_or_si128(_mm_cmpgt_epi16(pa, pb), _mm_cmpgt_epi16(pa, pc)), _mm_set1_epi16(-1));
  const __m128i useB = _mm_andnot_si128(_mm_cmpgt_epi16(pb, pc), _mm_set1_epi16(-1));
  const __m128i bc = _mm_or_si128(_mm_and_si128(useB, b), _mm_andnot_si128(useB, c));
  return _mm_or_si128(_mm_and_si128(useA, a), _mm_andnot_si128(useA, bc));
}
#endif

/* dst[x] = cur[x] - Paeth(cur[x - bpp], prior[x], prior[x - bpp]), the first
   bpp bytes with a = c = 0 */
void ppap_paeth_filter(const uint8_t *cur, const uint8_t *prior, uint8_t *dst, intptr_t rb, intptr_t bpp) {
  intptr_t x = 0;
  for (; x < bpp && x < rb; x++) dst[x] = (uint8_t)(cur[x] - prior[x]);
#ifdef PX_SSE2
  const __m128i z = _mm_setzero_si128();
  for (; x + 16 <= rb; x += 16) {
    const __m128i va = _mm_loadu_si128((const __m128i *)(const void *)(cur + x - bpp));
    const __m128i vb = _mm_loadu_si128((const __m128i *)(const void *)(prior + x));
    const __m128i vc = _mm_loadu_si128((const __m128i *)(const void *)(prior + x - bpp));
    const __m128i vx = _mm_loadu_si128((const __m128i *)(const void *)(cur + x));
    const __m128i lo = paeth8(_mm_unpacklo_epi8(va, z), _mm_unpacklo_epi8(vb, z), _mm_unpacklo_epi8(vc, z));
    const __m128i hi = paeth8(_mm_unpackhi_epi8(va, z), _mm_unpackhi_epi8(vb, z), _mm_unpackhi_epi8(vc, z));
    _mm_storeu_si128((__m128i *)(void *)(dst + x), _mm_sub_epi8(vx, _mm_packus_epi16(lo, hi)));
  }
#endif
  for (; x < rb; x++) dst[x] = (uint8_t)(cur[x] - px_paeth(cur[x - bpp], prior[x], prior[x - bpp]));
}
