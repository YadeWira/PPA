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

   PPA's formats are not frozen before 0.9.0 (doc/STABILITY.md): what a
   published release wrote is read by every later one; a .ppa or a filter
   stream a later release wrote may not open in an earlier one, which says
   so with PPA_E_VERSION. */
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

/* "ppa 0.7.1" */
const char *PPA_CALL ppa_version(void);

/* A file of the PNG family -> a .ppa. threads: how many at once (1 to 64;
   outside that, the nearest). On PPA_OK, *out holds *out_size bytes, to
   free with ppa_free(). The .ppa keeps no extension (the command's keeps
   the original's). */
int PPA_CALL ppa_compress(const void *in, size_t in_size, void **out, size_t *out_size, int threads);

/* The levels (the command's -1, -2, -3): how each image's model is chosen.
   None is written in the .ppa or the filter's stream: every release since
   0.2.0 reads a file of any level. PPA_LEVEL_FAST never takes the slow
   model for an image the fast or the static one takes (about ten times as
   quick to extract it, a little larger on drawings); PPA_LEVEL_DEFAULT, as
   ppa_compress and ppa_filter_encode; PPA_LEVEL_MAX, the slow model for
   every image (smaller, ten to forty times slower to extract). Since
   0.4.0. */
enum { PPA_LEVEL_FAST = 1, PPA_LEVEL_DEFAULT = 2, PPA_LEVEL_MAX = 3 };

/* ppa_compress at a level; another level: PPA_E_ARG */
int PPA_CALL ppa_compress_level(const void *in, size_t in_size, void **out, size_t *out_size, int threads,
                                int level);

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
/* ppa_filter_encode at a level (above); another level: PPA_E_ARG */
int PPA_CALL ppa_filter_encode_level(ppa_read_fn read, void *read_ctx, ppa_write_fn write, void *write_ctx,
                                     int threads, int level);
/* The filter's stream, read -> the original bytes, written. PPA_E_VERSION:
   a newer PPA wrote it (a filter version or a record it does not know, or a
   file's codec stream of a later version); what came before it may have
   been written already. */
int PPA_CALL ppa_filter_decode(ppa_read_fn read, void *read_ctx, ppa_write_fn write, void *write_ctx,
                               int threads);

/* One deflate stream at a time, for a program that meets them loose (PDA:
   a PDF's or a ZIP's streams), since 0.7.0. ppa_deflate_analyze takes a
   stream, zlib-framed or bare, and gives the bytes it holds and a recipe:
   what the bytes alone do not say of how they were deflated, a few bytes
   for most streams (doc/PREFLATE.md). ppa_deflate_rebuild gives the same
   stream back, bit for bit, from the bytes and the recipe. A stream no
   recipe gives back comes out as PPA_E_NOT_TAKEN; the caller keeps it as
   it is. Whether the recipe and the bytes are worth more to the caller
   than the stream (the bytes compress better; a recipe of corrections may
   be long) is the caller's to weigh.

   A context is one thread's (several threads: one each). It holds the
   cap on a stream's bytes and the last stream's recipe, tried first on the
   next one: a file's streams are mostly made alike, and the search is then
   one encode. A recipe does not depend on the context that made it (any
   context, or none, rebuilds it), only which recipe is found when several
   give the same stream may.

   Not handled: gzip's framing (the caller takes it off), members or
   streams one after another (one stream a call: consumed says where it
   ended), a zlib stream with a preset dictionary (FDICT: PPA_E_NOT_TAKEN).
   A recipe begins with its version (a codec stream version, 3 to 6 in
   0.7.0): a recipe a newer PPA wrote with an encoder this one does not know
   is PPA_E_VERSION. */
enum {
  PPA_DEFLATE_RAW = 1,         /* bare deflate (RFC 1951) */
  PPA_DEFLATE_ZLIB = 2,        /* zlib (RFC 1950): the 2-byte header, the data, the Adler-32 */
  PPA_DEFLATE_AUTO = 3,        /* zlib when the first 2 bytes are a zlib header, bare otherwise */
  /* the level, or'ed in (none: PPA_LEVEL_DEFAULT): how hard the search
     tries zopfli's encoder, the slow one (fast: never; default: streams of
     up to 64 KiB; max: every stream) */
  PPA_DEFLATE_LEVEL_FAST = PPA_LEVEL_FAST << 4,
  PPA_DEFLATE_LEVEL_DEFAULT = PPA_LEVEL_DEFAULT << 4,
  PPA_DEFLATE_LEVEL_MAX = PPA_LEVEL_MAX << 4
};
typedef struct ppa_deflate_ctx ppa_deflate_ctx;

/* max_plain: the most bytes a stream may hold (0, or more than 1 GiB: 1
   GiB); a stream holding more is PPA_E_MEMORY. NULL: no memory. */
ppa_deflate_ctx *PPA_CALL ppa_deflate_ctx_new(size_t max_plain);
void PPA_CALL ppa_deflate_ctx_free(ppa_deflate_ctx *ctx);

/* in[0..n) -> *plain (*plain_size bytes) and *recipe (*recipe_size), both
   freed with ppa_free. flags: a framing and a level, above. *consumed (may
   be NULL): where the stream ended, the Adler-32 included when zlib-framed
   and it is the right one; the bytes after it are not in the recipe (the
   caller keeps them: a PDF's /Length may be long). PPA_E_DATA: not a
   deflate stream (cut short, a bad code...), *err_pos (may be NULL) the
   byte where that showed; PPA_E_NOT_TAKEN: a stream no recipe gives back
   (*consumed set); PPA_E_MEMORY: no memory, or over max_plain; PPA_E_ARG:
   a null pointer or unknown flags. */
int PPA_CALL ppa_deflate_analyze(ppa_deflate_ctx *ctx, const void *in, size_t n, int flags,
                                 void **plain, size_t *plain_size, void **recipe, size_t *recipe_size,
                                 size_t *consumed, size_t *err_pos);

/* The bytes and their recipe -> the stream, in[0..consumed) of the
   analysis, in *out (*out_size bytes; ppa_free). ctx may be NULL. max_out
   caps the stream (0: no cap): over it, PPA_E_MEMORY. PPA_E_VERSION: a
   newer PPA's recipe; PPA_E_DATA: a damaged recipe or one for other bytes
   (*err_pos, may be NULL: about where in the recipe). A recipe with the
   wrong bytes may also give a stream that is not the original: the caller
   checks what it keeps a hash of. */
int PPA_CALL ppa_deflate_rebuild(ppa_deflate_ctx *ctx, const void *plain, size_t plain_size,
                                 const void *recipe, size_t recipe_size, size_t max_out,
                                 void **out, size_t *out_size, size_t *err_pos);

#ifdef __cplusplus
}
#endif
#endif
