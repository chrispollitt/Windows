@echo on
REM ********************************************
REM * pgate - progagate cmd to list of pcs
REM ********************************************

REM runas /user:pics\client cmd

setlocal

set user=pics\client
set pass=xxx

PATH=C:\Chris\Utils\SysInternals;%PATH%

for %%I in (pics08-dt232) DO (
psexec \\%%I -nobanner -u %user% -p %pass% -c -f c:\Chris\Dropbox\Chris\zAtira\PICS\Automate\test.cmd %%I
type c:\Chris\Public\pgate-%%I.out
)

endlocal
