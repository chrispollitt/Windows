@echo off
REM **********************
REM * Clean Classroom PC *
REM **********************

setlocal ENABLEEXTENSIONS
set BAK=Cleanup

echo **********************
echo * Clean Classroom PC *
echo **********************

pushd c:\users\client

if not exist %BAK% mkdir %BAK%
for /d %%I in (Desktop Documents Downloads Music Pictures Videos) DO (
  if not exist %BAK%\%%I mkdir %BAK%\%%I
  pushd %%I
  for    %%J in (*) DO move /y "%%J" "..\%BAK%\%%I\%%J"
  for /d %%J in (*) DO move /y "%%J" "..\%BAK%\%%I\%%J"
  popd
)

pause
popd
endlocal
