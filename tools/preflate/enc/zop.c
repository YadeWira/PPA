/* zop IN ITERATIONS > OUT: zopfli's raw deflate of IN (ZopfliDeflate, btype 2). */
#include <zopfli/zopfli.h>
#include <zopfli/deflate.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: zop IN ITERATIONS\n"); return 2; }
  FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
  fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
  unsigned char *in = malloc(n ? n : 1);
  if (n && fread(in, 1, n, f) != (size_t)n) return 1;
  ZopfliOptions o; ZopfliInitOptions(&o); o.numiterations = atoi(argv[2]);
  unsigned char *out = 0, bp = 0; size_t on = 0;
  ZopfliDeflate(&o, 2, 1, in, n, &bp, &out, &on);
  fwrite(out, 1, on, stdout);
  return 0;
}
