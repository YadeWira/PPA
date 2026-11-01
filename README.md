# PPA

Lossless recompression of the **PNG family** (PNG, APNG, MNG, JNG), in
FreePascal, with the hot loops in C and some x86-64 assembly; no libraries.
The successor of [packPNG](https://github.com/YadeWira/packPNG), with a
format of its own, the way [PJA](https://github.com/YadeWira/PJA) followed
packJPG.

```sh
ppa a image.png          # -> image.ppa
ppa x image.ppa          # -> image.png, the same file byte for byte
```

**Work in progress.** Layer 1 of the codec (the file ↔ its chunks and image
streams) is done and tested; there is no command yet. The plan and the
status of each layer are in [`doc/CODEC.md`](doc/CODEC.md).

The original will come back **byte for byte**, and nothing will be written
under an output's name unless it verified: compressing decompresses the
result and compares it with the input before writing.

## Tests

```sh
pas/run_tests.sh                                  # needs fpc 3.2.2 and python3
PNG_CORPUS=dir1:dir2 pas/run_tests.sh             # plus the round trip over those directories
```

## License

MIT, see [LICENSE](LICENSE).
