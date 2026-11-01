# The `ppa` command

```
ppa a [options] FILE...     compress:  image.png -> image.ppa
ppa x [options] FILE...     extract:   image.ppa -> image.png (the original's extension)
ppa list FILE...            what each .ppa holds: original size, stored size, extension, hash
```

| switch | what it does |
|---|---|
| `-o PATH` | output name with one input; a directory if it exists or ends in `/` |
| `--output-dir=DIR` | output directory |
| `-f`, `--force` | replace an existing output, only with one that verified |
| `-th N`, `--threads=N` | threads; by default the processors, up to 8. They go to files first, several at once, and what is left to each file's image streams (zlib's parameters when compressing, the deflate streams rebuilt when extracting). Each file's lines still come out in the order of the inputs; the `.ppa` is the same bytes whatever the threads |
| `--no-verify` | `a`: do not decompress the stream to check it before writing. The hash still catches a codec bug when extracting |
| `--max-output=SIZE` | `x`: refuse a declared original above SIZE (`256M` by default, `K`/`M`/`G`, `0` = no limit) |
| `-n`, `--dry-run` | do everything but write |
| `-q`, `--quiet` | only errors |
| `--version` | the command's version, and the stream and format versions |
| `--` | everything after it is a file |

Exit status: 0 when every file went through, 1 when any failed (each with
its line on stderr), 2 for a usage error.

## Nothing written that did not verify

- `a` writes the `.ppa` only after the codec has decompressed its own stream
  and compared it with the input (unless `--no-verify`). A file the codec
  does not take, or does not make smaller, is stored in the `.ppa` as it is.
- `x` writes the original only after its size and BLAKE3 hash match the
  descriptor.
- Every output goes to a temporary name next to it first, and is renamed
  into place when complete.
- An existing output is not replaced without `-f`.

Version 0.1.0 is a first one, and slow: the model codes an image's pixels
in one thread, and a stream zlib wrote at level 8 or 9 takes, to rebuild,
about what zlib took to write it.
