/* mz IN LEVEL [GREEDY] > OUT: miniz's raw deflate of IN, tdefl_compress_mem_to_heap
   with the flags tdefl_create_comp_flags_from_zip_params gives for LEVEL (0-10).
   Built with -DMZ114 against miniz.c 1.14 (single file), else against miniz 3.x. */
#include <stdio.h>
#include <stdlib.h>
#ifdef MZ114
#include "miniz.c"
#else
#include "miniz.h"
#endif
int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: mz IN LEVEL [GREEDY]\n"); return 2; }
  FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
  fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
  unsigned char *in = malloc(n ? n : 1);
  if (n && fread(in, 1, n, f) != (size_t)n) return 1;
  mz_uint fl = tdefl_create_comp_flags_from_zip_params(atoi(argv[2]), -15, MZ_DEFAULT_STRATEGY);
  if (argc > 3 && atoi(argv[3])) fl |= TDEFL_GREEDY_PARSING_FLAG;
  size_t on = 0;
  void *o = tdefl_compress_mem_to_heap(in, n, &on, fl);
  if (!o) return 1;
  fwrite(o, 1, on, stdout);
  return 0;
}
