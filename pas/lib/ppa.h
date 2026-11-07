/* libppa: PPA as a library, for archivers and other programs.

   PPA recompresses files of the PNG family losslessly (PNG, APNG, MNG,
   JNG, Apple's CgBI PNG): the original comes back byte for byte. The
   library is one shared object (ppa.so, ppa.dll, ppa.dylib) with a C
   interface, shaped as PJA's libpja (pja.h); every function may be called
   from several threads at once.

   Two ways to use it:

   - One file in memory: ppa_compress() writes a .ppa (the same format as
     the `ppa` command, with the original's size and BLAKE3 hash), and
     ppa_decompress() gives the original back. A file PPA does not take,
     or does not make smaller, comes back as PPA_E_NOT_TAKEN, and the
     caller stores it its own way.

   - A filter over a stream of any bytes, for an archiver that puts many
     files in one stream (a solid block): ppa_filter_encode() finds the
     PNG, MNG and JNG files inside, recompresses each one that comes back
     byte for byte, and passes every other byte through untouched, so the
     archiver's own compressor (LZMA2, zstd...) still sees them.
     ppa_filter_decode() gives the stream back. The filter's format is in
     doc/LIBRARY.md.

   Every buffer the library returns is freed with ppa_free(), never with
   free().

   PPA's formats are not frozen before 1.0.0 (doc/FORMAT.md): a .ppa or a
   filter stream written by a 0.x release may not open in a later one; a
   later release says so with PPA_E_VERSION where it can. */
#ifndef PPA_H
#define PPA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && !defined(_WIN64)
#define PPA_CALL __cdecl
#else
#define PPA_CALL
#endif

enum {
  PPA_OK = 0,
  PPA_E_NOT_TAKEN = 1,  /* ppa_compress: not a file PPA takes or makes smaller (store it as is) */
  PPA_E_DATA = 2,       /* the input is damaged or not PPA's */
  PPA_E_MEMORY = 3,     /* out of memory, or over a size limit */
  PPA_E_READ = 4,       /* the filter's read callback failed */
  PPA_E_WRITE = 5,      /* the filter's write callback failed */
  PPA_E_ARG = 6,        /* a null pointer or a bad argument */
  PPA_E_VERSION = 7     /* written by a newer PPA: a .ppa version, a codec stream
                           version, a filter version or record this release
                           does not know; also damage that lands on one of
                           those bytes, which cannot be told apart */
};

/* Error codes may be added; a caller treats one it does not know as an
   error, as it treats PPA_E_DATA. */

/* "ppa 0.1.0" */
const char *PPA_CALL ppa_version(void);

/* A file of the PNG family -> a .ppa. threads: how many at once (1 to 64;
   outside that, the nearest). On PPA_OK, *out holds *out_size bytes, to
   free with ppa_free(). The .ppa keeps no extension (the command's keeps
   the original's). */
int PPA_CALL ppa_compress(const void *in, size_t in_size, void **out, size_t *out_size, int threads);

/* A .ppa -> the original, checked against its size and hash. max_size caps
   the original's size (0: no cap but the library's own, 2^31); it does not
   cap the memory a decode takes on the way (each image's pixels, up to
   1 GiB, and the models' tables). PPA_E_VERSION: a newer PPA wrote it. */
int PPA_CALL ppa_decompress(const void *in, size_t in_size, void **out, size_t *out_size,
                            size_t max_size, int threads);

void PPA_CALL ppa_free(void *p);

/* The filter's callbacks. read: up to size bytes into buf; returns how
   many (0 at the end), or -1 on an error. write: all size bytes; returns 0,
   or -1 on an error. */
typedef ptrdiff_t (PPA_CALL *ppa_read_fn)(void *ctx, void *buf, size_t size);
typedef int (PPA_CALL *ppa_write_fn)(void *ctx, const void *buf, size_t size);

/* Every byte read -> the filter's stream, written. */
int PPA_CALL ppa_filter_encode(ppa_read_fn read, void *read_ctx, ppa_write_fn write, void *write_ctx,
                               int threads);
/* The filter's stream, read -> the original bytes, written. PPA_E_VERSION:
   a newer PPA wrote it (a filter version or a record it does not know, or a
   file's codec stream of a later version); what came before it may have
   been written already. */
int PPA_CALL ppa_filter_decode(ppa_read_fn read, void *read_ctx, ppa_write_fn write, void *write_ctx,
                               int threads);

#ifdef __cplusplus
}
#endif
#endif
