' Run Console App with Hidden ConHost Window (VBScript)
' Usage:
'   cscript //nologo .\runremserver.vbs
'

Option Explicit
On Error Resume Next

Function Main()
  Dim Prog         : Prog         = "c:\\users\\client\\appdata\\local\\runrem\\runremserver.exe"
  Dim Hide         : Hide         = 0
  Dim Show         : Show         = 1
  Dim WindowStyle  : WindowStyle  = Show 'Hide
  Dim WaitOnReturn : WaitOnReturn = True 'False
  Dim WSobj        : Set WSobj    = WScript.CreateObject("WScript.Shell")
  WSobj.Run Prog, WindowStyle, WaitOnReturn
  If Err.Number <> 0 Then
    WScript.Echo "Error (Run):" & CStr(Err.Number) & " " & Err.Source
    Err.Clear
  End If
End Function

Main()
