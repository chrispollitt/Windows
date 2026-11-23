# Build under Cygwin. Produces a native (no cygwin1.dll) GUI-subsystem exe.
CC     = x86_64-w64-mingw32-gcc
CFLAGS = -O2 -Wall -Wextra

# Where `make install` / `make uninstall` work:
#   DEST=...   given explicitly: used as is, no questions asked.
#   otherwise  per-user %LOCALAPPDATA%\Microsoft\WindowsApps (on every user's PATH, no
#              admin needed) -- unless this shell is elevated (`net session` succeeds),
#              in which case you are asked whether to use %WINDIR% (system-wide) instead.
#              Without a terminal to ask on, an elevated shell still gets per-user.
USER_DEST = $(shell cygpath -u "$$LOCALAPPDATA")/Microsoft/WindowsApps
SYS_DEST  = $(shell cygpath -u "$$WINDIR")

# Shell snippet that sets $$dest according to the rules above.
PICK_DEST = dest="$(DEST)"; \
  if [ -z "$$dest" ]; then \
    dest="$(USER_DEST)"; \
    if net session >/dev/null 2>&1; then \
      if [ -t 0 ]; then \
        printf "Elevated shell detected. Install system-wide into %s? [y/N] " "$(SYS_DEST)"; \
        read ans; case "$$ans" in [yY]*) dest="$(SYS_DEST)";; esac; \
      else \
        echo "Elevated but not interactive: using per-user $$dest (give DEST=... for system-wide)"; \
      fi; \
    fi; \
  fi

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
	@$(PICK_DEST); \
	[ -n "$$dest" ] && [ -d "$$dest" ] || { echo "install folder '$$dest' does not exist"; exit 1; }; \
	cp -f ptyw.exe "$$dest/ptyw.exe" || exit 1; \
	for p in $(PROGS); do \
	    rm -f "$$dest/$${p}w.exe"; \
	    ln "$$dest/ptyw.exe" "$$dest/$${p}w.exe" 2>/dev/null \
	      || cp -f "$$dest/ptyw.exe" "$$dest/$${p}w.exe"; \
	    echo "  $$dest/$${p}w.exe"; \
	done; \
	echo "Installed ptyw + aliases to $$dest"

uninstall:
	@$(PICK_DEST); \
	[ -n "$$dest" ] && [ -d "$$dest" ] || { echo "install folder '$$dest' does not exist"; exit 1; }; \
	rm -f "$$dest/ptyw.exe"; \
	for p in $(PROGS); do rm -f "$$dest/$${p}w.exe"; done; \
	echo "Removed ptyw + aliases from $$dest"

# Print where install/uninstall would go (to check the prompt logic).
which-dest:
	@$(PICK_DEST); echo "$$dest"

clean:
	rm -f ptyw.exe

.PHONY: all test install uninstall which-dest clean
