@echo off
REM ********************************************
REM * local script
REM ********************************************

setlocal

set mypc=%1
set mydir=c:\temp

if not exist %mydir% mkdir %mydir%
pushd %mydir%

echo pc=%computername% > pgate.out

copy pgate.out \\pics08-dt253\public\pgate-%mypc%.out

popd

endlocal
