# Checking a Windows build in a real Windows

CI builds and tests the Windows binaries, but on the runners' Windows only,
and with a 64-bit 7-Zip only before 0.2.0. A release is also checked in the
VMs (Windows XP x86, Windows 7 x86 and x64, Windows 10 x86 and x64): 0.1.1's
found a fault only a 32-bit 7-Zip on Windows XP showed.

```sh
tools/vm/make_kit.sh <build dir> x86 kit-x86 [more samples]   # CI's bin-windows-x86 artifact, say
# copy kit-x86 to the VM and run kit-x86\test.bat (cmd.exe)
```

`test.bat` runs `ppa selftest`; `ppa a`, `t` and `x` of every sample (each
back byte for byte); `-th 1` giving the same `.ppa`; `test_lib` (libppa's C
test) on the small samples; and the 7-Zip plugin: `7z i` listing `37F11
PPA`, an archive written (`-m0=PPA -m1=LZMA2`), tested and extracted, every
file back. It prints PASS or FAIL lines and exits with the count of FAILs.
Compare the `.ppa` files it writes (`o\*.ppa`) with Linux's: the same bytes.

The ZPAQL decoder of the zpaq-std codec ppa1 is checked the same way with
zpaq 7.15 (`zpaq.exe`, `zpaq64.exe`): archives zpaq-std writes with
`-sa:ppa` extracted without the plugin, every file compared.
