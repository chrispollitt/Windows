// Run Console App with Hidden ConHost Window (JScript)
// Usage:
//   cscript //nologo .\RunRemServer.js
//

"use strict";

function main() {
  var Prog         = 'c:\\Users\\client\\AppData\\Local\\RunRem\\RunRemServer.exe';
  var Hide         = 0;
  var Show         = 1;
  var WindowStyle  = Show; // Hide 
  var WaitOnReturn = true; // false
  var WSobj        = WScript.CreateObject("WScript.Shell");
  try {
    WSobj.Run(Prog, WindowStyle, WaitOnReturn);
  } catch(Err) {
    WScript.Echo("Error (Run):" + (Err.number & 0xFFFF) + " " + Err.name);
  }
}

main();