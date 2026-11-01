# PPA

Lossless recompression of the **PNG family** (PNG, APNG, MNG, JNG), in
FreePascal, with the hot loops in C and some x86-64 assembly; no libraries.
The successor of [packPNG](https://github.com/YadeWira/packPNG), with a
format of its own, the way [PJA](https://github.com/YadeWira/PJA) followed
packJPG.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | none yet |

```sh
ppa a image.png          # -> image.ppa
ppa x image.ppa          # -> image.png, the same file byte for byte
```

**Work in progress: version 0.1.0, a first one.** Every layer of the codec
works and the command does too, but its model is a first prototype and it
is slow (one thread, the Pascal reference code). The status of each layer,
and everything measured, is in [`doc/CODEC.md`](doc/CODEC.md).

The original comes back **byte for byte**, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.ppa`. A file PPA cannot take, or does
not make smaller, is stored in the `.ppa` as it is.

The command is described in [`doc/CLI.md`](doc/CLI.md), the file in
[`doc/FORMAT.md`](doc/FORMAT.md).

## Building and tests

```sh
fpc -O3 -dPPA_FAST -Fupas -Fipas -FUbuild -obuild/ppa pas/ppacli.pas      # the command
```

```sh
pas/run_tests.sh                                  # needs fpc 3.2.2 and python3
PNG_CORPUS=dir1:dir2 pas/run_tests.sh             # plus the round trip over those directories
```

## License

MIT, see [LICENSE](LICENSE).

[ciBadge]: https://github.com/YadeWira/PPA/actions/workflows/ci.yml/badge.svg
[ciLink]: https://github.com/YadeWira/PPA/actions/workflows/ci.yml
