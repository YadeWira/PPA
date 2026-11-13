/* zfl: zlib's deflate driven by a script of flushes and parameter changes,
   to build streams PPA's zlib search cannot tell today (doc: README.md).

     zfl IN LEVEL MEMLEVEL WBITS STRATEGY [EVENT...] > OUT

   WBITS < 0 gives raw deflate (as zlib's deflateInit2), > 0 a zlib stream.
   STRATEGY: 0 default, 1 filtered, 2 huffman, 3 rle, 4 fixed.
   Each EVENT is POS:WHAT, POS a byte offset of IN (increasing), WHAT one of
     sync, full, partial, block      deflate(Z_SYNC_FLUSH ...) after IN[0..POS)
     params=L,S                      deflateParams(L, S) after IN[0..POS)
   The rest of IN goes with Z_FINISH. Built against zlib 1.3.1 (the system's,
   or any: zlibVersion() goes to stderr). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static z_stream z;
static unsigned char obuf[1 << 16];

static void pump(int flush) {
  do {
    z.next_out = obuf; z.avail_out = sizeof obuf;
    int r = deflate(&z, flush);
    if (r == Z_STREAM_ERROR) { fprintf(stderr, "zfl: deflate error\n"); exit(1); }
    fwrite(obuf, 1, sizeof obuf - z.avail_out, stdout);
  } while (z.avail_out == 0 || z.avail_in > 0);
}

int main(int argc, char **argv) {
  if (argc < 6) { fprintf(stderr, "usage: zfl IN LEVEL MEMLEVEL WBITS STRATEGY [POS:EVENT...]\n"); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 1; }
  fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
  unsigned char *in = malloc(n ? n : 1);
  if (n && fread(in, 1, n, f) != (size_t)n) { perror("read"); return 1; }
  fclose(f);
  if (deflateInit2(&z, atoi(argv[2]), Z_DEFLATED, atoi(argv[4]), atoi(argv[3]), atoi(argv[5])) != Z_OK) {
    fprintf(stderr, "zfl: bad parameters\n"); return 2;
  }
  fprintf(stderr, "zfl: zlib %s\n", zlibVersion());
  long at = 0;
  for (int i = 6; i < argc; i++) {
    char *c = strchr(argv[i], ':');
    if (!c) { fprintf(stderr, "zfl: bad event %s\n", argv[i]); return 2; }
    long pos = atol(argv[i]);
    if (pos < at || pos > n) { fprintf(stderr, "zfl: event %s out of order\n", argv[i]); return 2; }
    z.next_in = in + at; z.avail_in = (uInt)(pos - at); at = pos;
    pump(Z_NO_FLUSH);
    c++;
    if (!strcmp(c, "sync")) pump(Z_SYNC_FLUSH);
    else if (!strcmp(c, "full")) pump(Z_FULL_FLUSH);
    else if (!strcmp(c, "partial")) pump(Z_PARTIAL_FLUSH);
    else if (!strcmp(c, "block")) pump(Z_BLOCK);
    else if (!strncmp(c, "params=", 7)) {
      int l, s;
      if (sscanf(c + 7, "%d,%d", &l, &s) != 2) { fprintf(stderr, "zfl: bad %s\n", c); return 2; }
      /* deflateParams may need room to flush what it holds */
      int r;
      do {
        z.next_out = obuf; z.avail_out = sizeof obuf;
        r = deflateParams(&z, l, s);
        fwrite(obuf, 1, sizeof obuf - z.avail_out, stdout);
      } while (r == Z_BUF_ERROR && z.avail_out == 0);
      if (r != Z_OK) { fprintf(stderr, "zfl: deflateParams %d\n", r); return 1; }
    } else { fprintf(stderr, "zfl: bad event %s\n", c); return 2; }
  }
  z.next_in = in + at; z.avail_in = (uInt)(n - at);
  int r;
  do {
    z.next_out = obuf; z.avail_out = sizeof obuf;
    r = deflate(&z, Z_FINISH);
    fwrite(obuf, 1, sizeof obuf - z.avail_out, stdout);
  } while (r == Z_OK);
  if (r != Z_STREAM_END) { fprintf(stderr, "zfl: finish %d\n", r); return 1; }
  deflateEnd(&z);
  return 0;
}
