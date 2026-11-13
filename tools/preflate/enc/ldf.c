/* ldf IN LEVEL > OUT: libdeflate's raw deflate of IN at LEVEL (0-12). */
#include <libdeflate.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: ldf IN LEVEL\n"); return 2; }
  FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
  fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
  unsigned char *in = malloc(n ? n : 1);
  if (n && fread(in, 1, n, f) != (size_t)n) return 1;
  struct libdeflate_compressor *c = libdeflate_alloc_compressor(atoi(argv[2]));
  if (!c) { fprintf(stderr, "ldf: bad level\n"); return 2; }
  size_t cap = libdeflate_deflate_compress_bound(c, n);
  unsigned char *o = malloc(cap);
  size_t on = libdeflate_deflate_compress(c, in, n, o, cap);
  if (!on) return 1;
  fwrite(o, 1, on, stdout);
  return 0;
}
