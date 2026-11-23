#!/bin/bash
# Smoke tests for ptyw.exe (run under Cygwin). Needs a *native Windows* python
# (not Cygwin's): ptyw.exe is a native program. Override with PY='C:\path\python.exe'.
cd "$(dirname "$0")" || exit 1
PTYW=./ptyw.exe
PY=${PY:-$(cygpath -w "$(cygpath -u "$LOCALAPPDATA")/Programs/Python/Python311/python.exe")}
fail=0
check() { # name, ok(0/1)
    if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

# 1. child sees a tty with the requested size
out=$($PTYW -s 100x40 $PY -c "import sys,os; print(sys.stdout.isatty(), sys.stdin.isatty(), tuple(os.get_terminal_size()))" | tr -d '\r\033' )
echo "$out" | grep -q "True True (100, 40)"; check "isatty + size" $?

# 2. exit code is propagated
$PTYW $PY -c "import sys; sys.exit(7)" >/dev/null; [ $? = 7 ]; check "exit code" $?

# 3. redirected stdin reaches the child (LF -> CR)
out=$(printf 'hello\n' | $PTYW $PY -c "print('got:' + input())" | tr -d '\r')
echo "$out" | grep -q "got:hello"; check "stdin forwarding" $?

# 4. -o file captures output
rm -f pty.out; $PTYW -o pty.out $PY -c "print('captured')" >/dev/null; grep -q captured pty.out; check "-o file" $?; rm -f pty.out

# 5. unknown program -> 125 and message on redirected stderr
$PTYW no-such-prog-xyz 2>err.txt >/dev/null; rc=$?; [ $rc = 125 ] && grep -q "cannot run" err.txt; check "bad command" $?; rm -f err.txt

# 6. invoked as <prog>w runs <prog>: cmdw -> cmd (args, exit code, PTYW_SIZE)
T=$(mktemp -d); cp ptyw.exe "$T/cmdw.exe"; cp ptyw.exe "$T/foo.exe"
"$T/cmdw.exe" /c "exit 3" >/dev/null; [ $? = 3 ]; check "alias cmdw exit code" $?
out=$(PTYW_SIZE=90x20 "$T/cmdw.exe" /c "mode con" | tr -d '\r')
echo "$out" | grep -Eq "Columns:[[:space:]]+90" ; check "alias PTYW_SIZE" $?
"$T/foo.exe" /c "exit 0" 2>"$T/err.txt" >/dev/null; [ $? = 125 ] && grep -q "must be ptyw" "$T/err.txt"; check "bad alias name" $?
rm -rf "$T"

# 7. make install: alias beside the first <prog>.exe on PATH; central one for protected folders
T=$(mktemp -d); mkdir "$T/dest" "$T/bin"; cp "$(command -v cmd)" "$T/bin/fakeprog.exe"
PATH="$T/bin:$PATH" make -s install DEST="$T/dest" PROGS="fakeprog cmd" </dev/null >/dev/null
[ -f "$T/bin/fakeprogw.exe" ] && [ -f "$T/dest/cmdw.exe" ] && [ ! -e "$T/dest/fakeprogw.exe" ]; check "install: alias beside program" $?
"$T/bin/fakeprogw.exe" /c "exit 4" >/dev/null; [ $? = 4 ]; check "installed alias runs its sibling" $?
PATH="$T/bin:$PATH" make -s uninstall DEST="$T/dest" PROGS="fakeprog cmd" </dev/null >/dev/null
[ ! -e "$T/bin/fakeprogw.exe" ] && [ ! -e "$T/dest/ptyw.exe" ] && [ -e "$T/bin/fakeprog.exe" ]; check "uninstall removes only ptyw copies" $?
rm -rf "$T"

exit $fail
