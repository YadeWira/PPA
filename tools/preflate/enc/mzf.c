/* mzf IN FLAGS > OUT: miniz's tdefl_compress_mem_to_heap of IN with tdefl's
   own FLAGS (decimal or 0x hex: the probes and TDEFL_*; with
   TDEFL_WRITE_ZLIB_HEADER, zlib-framed). Built with -DMZ114 against miniz.c
   1.14 (single file), else against miniz 3.x; -DMINIZ_USE_UNALIGNED_LOADS_AND_STORES=1
   for its level-1 loop (as 1.14 on x86). */
#include <stdio.h>
#include <stdlib.h>
#ifdef MZ114
#include "miniz.c"
#else
#include "miniz.h"
#endif
int main(int argc, char **argv) {
  if (argc < 3) return 2;
  FILE *f = fopen(argv[1], "rb"); if (!f) return 1;
  fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
  unsigned char *in = malloc(n ? n : 1);
  if (n && fread(in, 1, n, f) != (size_t)n) return 1;
  size_t on = 0;
  void *o = tdefl_compress_mem_to_heap(in, n, &on, (int)strtol(argv[2], 0, 0));
  if (!o) return 1;
  fwrite(o, 1, on, stdout);
  return 0;
}
