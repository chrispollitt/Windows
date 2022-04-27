@echo off
for /f "tokens=2 delims= " %%G in ('tasklist /FI "IMAGENAME eq tcc.exe" /NH') do SET pid=%%G
echo =====
echo pid=%pid%
echo =====
.\GetSetProcPri.exe %pid%
echo =====
.\GetSetPriCS.exe %pid%
echo =====
