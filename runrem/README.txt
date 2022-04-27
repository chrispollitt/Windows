
c:\users\chris\dropbox\chris\zatira\pics\automate\runrem

---build

1 make clean build
2 copy RunRemServer.exe c:\Users\client\bin

---local

a .\RunRemServer -i
b pslist -nobanner RunRemServer
  b1 C:\Users\client\AppData\Local\RunRem\RunRemServer.exe
  b2 SCHTASKS /run /tn RunRem
c .\RunRemClient localhost whoami
d pskill -nobanner RunRemServer

----remote

-rem
a .\RunRemServer -i
-loc
b .\RunRemClient cmvmwin7 whoami

-----------------

Ways to hide "conhost" window:
 * NO: run as "SYSTEM" user
 * NO: compile as WinExe
 * NO: change subsys bit: change_exe_subsys.py RunRemServer.exe RunRemServerW.exe to_windows
 * ??: launch via wscript: WScript.CreateObject("WScript.Shell").Run('C:\Users\client\AppData\Local\RunRem\RunRemServer.exe', 0,true);
 * ??: use "No Password" flag
 * ??: select "Run whether user is logged on or not"

---------------

https://docs.microsoft.com/en-us/windows/desktop/taskschd/taskschedulerschema-boottrigger-triggergroup-element

