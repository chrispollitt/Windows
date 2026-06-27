@echo off
REM ******************************
REM * Toggle Mono Audio
REM ******************************
if .%1.=.mono. (
REG ADD "HKCU\Software\Microsoft\Multimedia\Audio" /V AccessibilityMonoMixState /T REG_DWORD /D 1 /F
net stop "Audiosrv"
net start "Audiosrv"
) else (
REG ADD "HKCU\Software\Microsoft\Multimedia\Audio" /V AccessibilityMonoMixState /T REG_DWORD /D 0 /F
net stop "Audiosrv"
net start "Audiosrv"
)

REM 
REM Settings -> Ease Of Access -> "Hearing" -> Audio
REM   "Audio" -> "Make your device easier to hear"
REM   Turn on mono audio
REM 
