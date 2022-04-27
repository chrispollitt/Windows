@echo off
REM Current Config (Debug or Release)
REM  *Now both get installed to same folder

setlocal

REM change to parent dir

REM Paths
set INSTALLDIR=C:\DOS
set PROJECTDIR=%~dp0\..
set EXENAME1=RunAsAdminServer.exe
set EXENAME2=RunAsAdminClient.exe
echo Source = "%PROJECTDIR%"
echo Dest   = "%INSTALLDIR%"

REM Do the install
if not exist "%PROJECTDIR%\bin\%EXENAME1%" (
  echo Cannot find source 
  pause
  exit
)
if not exist %INSTALLDIR% (
  mkdir %INSTALLDIR%
)

schtasks /end /tn "\UserCreated\Elevate Service"
taskkill /f /im RunAsAdminServer.exe /t
echo Waiting for server task to end
sleep 5
cd/d "%PROJECTDIR%\bin"
for %%f in (%EXENAME1% *.dll %EXENAME2%) do copy /y  %%f %INSTALLDIR%

pause

endlocal
