psexec \\computer -nobanner -u user -p psswd cmd arguments
psexec @file      -nobanner -u user -p psswd cmd arguments

 -c     = copy cmd before executing it
 -f     = force copy of cmd
 -h     = elevate permissions
 -n sec = timeout in seconds
 
cd C:\Chris\Utils\SysInternals
.\psexec \\pics08-dt253 -nobanner -u pics\chris.pollitt -p xxx! ipconfig


psexec \\pics08-dt232 -nobanner -u pics\client -p xxx -c -f c:\Chris\Dropbox\Chris\zAtira\PICS\Automate\test.cmd pics08-dt232

==============================

https://stackoverflow.com/questions/828432/psexec-access-denied-errors

xxx.cpl -> Folder Options -> View -> "Simple File Sharing" = Disable

secpol.msc -> Local Policies -> Security Options -> Network Access: Sharing > and security model for local accounts > Classic – local users authenticate as themselves

reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\system /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Lsa]  LimitBlankPasswordUse=dword:00000000

netsh advfirewall set allprofiles state off

net use \\pics08-dt253\Admin$ /user:pics\chris.pollitt xxx!
net use \\pics08-dt253\ipc$   /user:pics\chris.pollitt xxx!


cmdkey /add:target /user:user /pass:pass

=============================

NET USE
  [devicename | *] [\\computername\sharename[\volume] [password | *]]
        [/USER:[domainname\]username]
        [/USER:[dotted domain name\]username]
        [/USER:[username@dotted domain name]
        [/SAVECRED]
        [[/DELETE] [/PERSISTENT:{YES | NO}]]
		
