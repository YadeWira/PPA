/* What the command says about its C part (ppasysinfo.pas: --version,
   report, bench): the compiler that built it, and the vector code the
   C loops were built with. Takes no memory and calls no library. */
#include <stdint.h>

/* "clang 18.1.3" or "gcc 14.2.0": the compiler's own version string */
const char *ppasys_cc(void) {
#if defined(__clang__)
  return "clang " __clang_version__;
#elif defined(__GNUC__)
  return "gcc " __VERSION__;
#else
  return "unknown";
#endif
}

/* the vector code of ppafastc.c and ppapixc.c (SSE2, built in or not) and
   ppamodelc.c's vector types (SSE2 on x86, NEON on arm64, plain code
   otherwise): every one gives the Pascal reference's bits */
const char *ppasys_simd(void) {
#if defined(__SSE2__) && !defined(PPA_NO_SIMD)
  return "sse2";
#elif defined(__ARM_NEON) || defined(__aarch64__)
  return "neon (ppamodelc.c's vector types)";
#else
  return "none (plain C)";
#endif
}
