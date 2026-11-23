# ptyw

`ptyw.exe` is to console programs what `pythonw.exe` is to `python.exe`: a
**Windows GUI-subsystem** launcher (no console window, ever) that runs a command
on a **hidden pseudo console (ConPTY)**. The child still sees a real interactive
console — `isatty()` is true, console size queries work, VT sequences are
processed — but nothing is displayed.

    ptyw [-s COLSxROWS] [-o FILE] [--] command [args...]

- `-s` console size (default 120x30); `-o FILE` also saves the child's output.
- Redirected stdout/stderr-of-the-child (merged, as on a terminal, with VT escapes)
  go to ptyw's redirected stdout; otherwise they are discarded.
- Redirected stdin is fed to the child's console input (LF/CRLF become CR).
- Exit code is the child's; ptyw's own errors exit 125 (stderr if redirected,
  else a message box).
- Replies to cursor-position (`ESC[6n`) and device-attributes (`ESC[c`) queries
  so children that probe the terminal don't hang.

Needs Windows 10 1809+. Build under Cygwin with `make` (uses
`x86_64-w64-mingw32-gcc`, so the result is native — no cygwin1.dll). Because it
is native, the command must be a Windows program (e.g. Windows python, not
Cygwin's). `make test` runs smoke tests (`PY=` overrides the python used).

## Invocation name

Run as `ptyw.exe` it takes the options above. Run under any other name `<prog>w.exe`
(copy or hard link), it runs `<prog>` with all its arguments passed through untouched —
`cmdw /c dir` runs `cmd /c dir`, `phpw script.php` runs `php script.php`. Any other name
is an error. Options aren't parsed in this mode; use the environment instead:
`PTYW_SIZE=COLSxROWS`, `PTYW_OUT=FILE` (also honoured by plain `ptyw`).

## Install

    make install              # to %LOCALAPPDATA%\Microsoft\WindowsApps (on PATH, no admin)
    make install DEST=/cygdrive/c/Windows            # system-wide (elevated shell)
    make install PROGS="bash cmd php"                # choose aliases
    make uninstall

Installs `ptyw.exe` plus `bashw sh zsh cmd powershell pwsh php perl ruby node lua wsl`
aliases (`bashw.exe`, `cmdw.exe`, …) as hard links to it (a junction can only target a
directory; symlinks need elevation; copies are the fallback across volumes). No `pythonw`
alias: that already exists.
