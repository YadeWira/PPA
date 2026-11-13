@echo off
rem PPA on a real Windows: the command, libppa (test_lib) and the 7-Zip plugin.
rem Folder layout (tools/vm/make_kit.sh makes it): ppa.exe ppa.dll test_lib.exe 7z\ s\ (every sample) lib\ (the small ones,
rem for test_lib) README.md. Prints PASS or FAIL lines; the exit status is the count of FAILs.
setlocal enabledelayedexpansion
cd /d %~dp0
set L=
for %%f in (s\*) do set L=!L! %%f
set LL=
for %%f in (lib\*) do set LL=!LL! %%f
set FAILS=0

ppa.exe --version
if errorlevel 1 (echo FAIL: --version & set /a FAILS+=1)

ppa.exe selftest > selftest.txt 2>&1
if errorlevel 1 (type selftest.txt & echo FAIL: selftest & set /a FAILS+=1) else (echo PASS: selftest)

if exist o rmdir /s /q o
mkdir o
mkdir o\x
mkdir o\z
ppa.exe a -q --output-dir=o %L%
if errorlevel 1 (echo FAIL: ppa a & set /a FAILS+=1)
ppa.exe t -q o\*.ppa
if errorlevel 1 (echo FAIL: ppa t & set /a FAILS+=1)
set P=
for %%f in (o\*.ppa) do set P=!P! %%f
ppa.exe x -q --output-dir=o\x !P!
if errorlevel 1 (echo FAIL: ppa x & set /a FAILS+=1)
set BAD=0
for %%f in (s\*) do (
  fc /b "%%f" "o\x\%%~nxf" > nul 2>&1
  if errorlevel 1 (echo DIFF: %%~nxf & set /a BAD+=1)
)
if !BAD!==0 (echo PASS: ppa a/t/x, every file back) else (echo FAIL: !BAD! files differ & set /a FAILS+=1)

for %%f in (lib\*) do set ONE=%%~nf& set ONEF=%%f
ppa.exe a -q -th 1 --output-dir=o\z !ONEF!
fc /b o\!ONE!.ppa o\z\!ONE!.ppa > nul 2>&1
if errorlevel 1 (echo FAIL: -th 1 writes other bytes & set /a FAILS+=1) else (echo PASS: -th 1 the same .ppa)

test_lib.exe %LL% README.md > test_lib.txt 2>&1
if errorlevel 1 (type test_lib.txt & echo FAIL: test_lib & set /a FAILS+=1) else (echo PASS: test_lib & more +0 test_lib.txt | findstr /i "checks failures")

if not exist 7z\Codecs mkdir 7z\Codecs
copy /y ppa.dll 7z\Codecs\ppa.dll > nul
7z\7z.exe i | findstr 37F11
7z\7z.exe i | findstr 37F11 > nul
if errorlevel 1 (echo FAIL: 7-Zip does not list PPA & set /a FAILS+=1)
7z\7z.exe a -bso0 -bsp0 -m0=PPA -m1=LZMA2 -mmt=4 o\t.7z %L%
if errorlevel 1 (echo FAIL: 7z a & set /a FAILS+=1)
7z\7z.exe t -bso0 -bsp0 o\t.7z
if errorlevel 1 (echo FAIL: 7z t & set /a FAILS+=1)
7z\7z.exe x -bso0 -bsp0 -oo\7 o\t.7z
if errorlevel 1 (echo FAIL: 7z x & set /a FAILS+=1)
set BAD=0
for %%f in (s\*) do (
  fc /b "%%f" "o\7\s\%%~nxf" > nul 2>&1
  if errorlevel 1 (echo DIFF7: %%~nxf & set /a BAD+=1)
)
if !BAD!==0 (echo PASS: 7-Zip with PPA, every file back) else (echo FAIL: !BAD! files differ after 7-Zip & set /a FAILS+=1)
for %%a in (o\t.7z) do echo 7z archive: %%~za bytes
7z\7z.exe x -bso0 -bsp0 -mmt=1 -oo\71 o\t.7z
if errorlevel 1 (echo FAIL: 7z x -mmt=1 & set /a FAILS+=1)
set BAD=0
for %%f in (s\*) do (
  fc /b "%%f" "o\71\s\%%~nxf" > nul 2>&1
  if errorlevel 1 (echo DIFF71: %%~nxf & set /a BAD+=1)
)
if !BAD!==0 (echo PASS: 7-Zip -mmt=1, every file back) else (echo FAIL: !BAD! files differ after 7-Zip -mmt=1 & set /a FAILS+=1)

echo FAILS=!FAILS!
exit /b !FAILS!
