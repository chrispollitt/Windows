# Build under Cygwin. Produces a native (no cygwin1.dll) GUI-subsystem exe.
CC     = x86_64-w64-mingw32-gcc
CFLAGS = -O2 -Wall -Wextra

# Where `make install` puts things. The default is on every user's PATH and
# needs no admin rights. For system-wide use: make install DEST=/cygdrive/c/Windows
DEST  ?= $(shell cygpath -u "$$LOCALAPPDATA")/Microsoft/WindowsApps

# Programs that get a <prog>w.exe alias (ptyw.exe run under another name runs
# that name minus the trailing "w"). Not python: pythonw already exists.
# Override/extend with: make install PROGS="bash cmd ..."
PROGS ?= bash sh zsh cmd powershell pwsh php perl ruby node lua wsl

all: ptyw.exe

# -mwindows => PE subsystem "Windows GUI" (no console allocated at startup)
ptyw.exe: ptyw.c
	$(CC) $(CFLAGS) -mwindows -static -s -o $@ $<

test: ptyw.exe
	./test.sh

# Aliases are hard links (a "junction" can only point at a directory, and
# symlinks need elevation or Developer Mode). Hard links need the same NTFS
# volume; otherwise we fall back to copies.
install: ptyw.exe
	@test -d "$(DEST)" || { echo "DEST $(DEST) does not exist"; exit 1; }
	cp -f ptyw.exe "$(DEST)/ptyw.exe"
	@for p in $(PROGS); do \
	    rm -f "$(DEST)/$${p}w.exe"; \
	    ln "$(DEST)/ptyw.exe" "$(DEST)/$${p}w.exe" 2>/dev/null \
	      || cp -f "$(DEST)/ptyw.exe" "$(DEST)/$${p}w.exe"; \
	    echo "  $(DEST)/$${p}w.exe"; \
	done
	@echo "Installed ptyw + aliases to $(DEST)"

uninstall:
	rm -f "$(DEST)/ptyw.exe"
	@for p in $(PROGS); do rm -f "$(DEST)/$${p}w.exe"; done

clean:
	rm -f ptyw.exe

.PHONY: all test install uninstall clean
