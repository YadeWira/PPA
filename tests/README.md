# Test samples

Every file here is synthetic: a fractal plasma from ImageMagick 7.1.1 with a
fixed seed, or chunks rewritten from one by `tests/mkpng.py`, which makes
them all again, the same bytes (`python3 tests/mkpng.py tests/png`). None
comes from a photo or from another project. They are small on purpose: the
suites flip every bit of them.

## `png/`

| file | what it has |
|---|---|
| `rgb8.png`, `rgba8.png`, `gray8.png`, `gray1.png`, `palette.png`, `rgb16.png` | the colour types and depths as libpng writes them: RGB 8, RGBA 8, gray 8, gray 1 bit, a 16-colour palette, RGB 16 |
| `interlaced.png` | Adam7 |
| `idat_split.png` | `rgb8.png`'s stream cut into IDATs of 100 bytes, with an empty IDAT in the middle |
| `bad_crc_trailer.png` | a tEXt with a wrong CRC, and bytes after IEND |
| `cut_short.png` | `rgb8.png` cut at two thirds, in the middle of its IDAT |
| `apng3.png` | an APNG of 3 frames: IDAT for the first, the other two in two fdAT each |
| `color.jng`, `alpha.jng` | JNG as ImageMagick writes it: colour only (JDAT), and with an alpha channel (IDAT) |
| `anim.mng` | an MNG of 3 frames as ImageMagick writes it, each an embedded PNG |
