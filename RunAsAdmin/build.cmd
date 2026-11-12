@echo off
rem Build RunAsAdminServer.exe and RunAsAdminClient.exe into .\bin (Release).
rem Needs MSBuild: Visual Studio 2019 if present, else the .NET Framework 4 one (and the .NET 4.5.2 reference assemblies).
setlocal
set "MSB=%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe"
if not exist "%MSB%" set "MSB=%windir%\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe"
if not exist "%MSB%" (
  echo MSBuild not found
  exit /b 1
)
"%MSB%" "%~dp0RunAsAdmin.sln" /p:Configuration=Release /verbosity:minimal /nologo
if errorlevel 1 exit /b 1
echo.
echo Built: %~dp0bin
dir /b "%~dp0bin\*.exe"
endlocal
