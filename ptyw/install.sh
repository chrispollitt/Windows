#!/bin/bash
# install.sh install|uninstall   (called by `make install` / `make uninstall`)
#
#   DEST   folder that gets the one central ptyw.exe (+ the manifest), e.g. /cygdrive/c/Windows
#   PROGS  programs that get a <prog>w.exe alias
#
# Each alias is placed *beside the program it wraps* (first match on PATH, e.g.
# /usr/bin/bashw.exe next to /usr/bin/bash.exe), so bashw can only ever run that very
# bash.  Where that isn't possible -- the program lives under %WINDIR% (System32...),
# the folder isn't writable, or it is not a plain <prog>.exe -- the alias goes next to
# the central ptyw.exe in DEST instead (and then finds <prog> by the usual search).
# Aliases are hard links to DEST/ptyw.exe where the volume allows, else copies.
# Everything placed is recorded in DEST/ptyw-installed.txt, which uninstall (and the
# next install) use to clean up.  Only files that really are ptyw copies are ever removed.

set -u
mode=${1:-}
dest=${DEST:-}
progs=${PROGS:-}
[ -n "$dest" ] && [ -d "$dest" ] || { echo "install.sh: DEST '$dest' is not a folder" >&2; exit 1; }
manifest="$dest/ptyw-installed.txt"
winroot=$(cygpath -u "${WINDIR:-C:\\Windows}")

# Files are given explicit rwxr-xr-x: a copy made across volumes from an elevated shell can
# otherwise end up with an ACL that denies even its owner read access (then it cannot be
# started, nor recognised below).
fixperm() { chmod 755 -- "$1" 2>/dev/null; }

# a file this install placed earlier (listed in the manifest) -- safe to repair permissions on
in_manifest() { [ -f "$manifest" ] && grep -qxF -- "$1" "$manifest"; }

is_ptyw() {                                                      # marker string built into ptyw.exe
    [ -f "$1" ] || return 1
    if ! head -c1 -- "$1" >/dev/null 2>&1 && in_manifest "$1"; then fixperm "$1"; fi
    grep -qa 'PTYW-MARKER-v1' "$1"
}

remove_if_ptyw() {
    if [ ! -e "$1" ]; then return 0; fi
    if is_ptyw "$1"; then rm -f -- "$1" && echo "  removed $1"; else echo "  kept $1 (not a ptyw copy)"; fi
}

under_windir() {
    local d=${1,,} w=${winroot,,}
    [[ "$d/" == "$w/"* ]]
}

case $mode in
install)
    [ -f ./ptyw.exe ] || { echo "install.sh: build ptyw.exe first (make)" >&2; exit 1; }
    cp -f ./ptyw.exe "$dest/ptyw.exe" || exit 1
    fixperm "$dest/ptyw.exe"
    echo "  $dest/ptyw.exe"
    placed=()
    for p in $progs; do
        cmdpath=$(command -v "$p" 2>/dev/null) || { echo "  $p: not found on PATH, skipped"; continue; }
        dir=$(dirname "$cmdpath")
        if [ ! -f "$dir/$p.exe" ]; then
            echo "  $p: no real $p.exe beside $cmdpath, skipped"; continue
        fi
        if under_windir "$dir" || [ ! -w "$dir" ]; then
            target="$dest/${p}w.exe"; where="central (program is in a protected folder)"
        else
            target="$dir/${p}w.exe"; where="beside $p.exe"
        fi
        if [ -e "$target" ] && ! is_ptyw "$target"; then
            echo "  $target exists and is not ptyw; skipped"; continue
        fi
        rm -f -- "$target"
        ln "$dest/ptyw.exe" "$target" 2>/dev/null || cp -f "$dest/ptyw.exe" "$target" || { echo "  $target: failed"; continue; }
        fixperm "$target"
        if ! head -c1 -- "$target" >/dev/null 2>&1; then echo "  $target: not readable after install (check its permissions)"; continue; fi
        placed+=("$target")
        echo "  $target   [$where]"
    done
    # clean up what an earlier install put elsewhere (manifest) or centrally (before aliases moved)
    stale=()
    [ -f "$manifest" ] && while IFS= read -r f; do stale+=("$f"); done < "$manifest"
    for p in $progs; do stale+=("$dest/${p}w.exe"); done
    for f in "${stale[@]}"; do
        keep=0; for q in "${placed[@]}"; do [ "$f" = "$q" ] && keep=1; done
        [ $keep = 1 ] || remove_if_ptyw "$f"
    done
    printf '%s\n' "${placed[@]}" > "$manifest"
    echo "Installed ptyw.exe to $dest and ${#placed[@]} alias(es); manifest: $manifest"
    ;;
uninstall)
    old=()
    [ -f "$manifest" ] && while IFS= read -r f; do old+=("$f"); done < "$manifest"
    for p in $progs; do old+=("$dest/${p}w.exe"); done
    for f in "${old[@]}"; do remove_if_ptyw "$f"; done
    remove_if_ptyw "$dest/ptyw.exe"
    rm -f -- "$manifest"
    echo "Uninstalled ptyw from $dest"
    ;;
*)
    echo "usage: DEST=... PROGS=... $0 install|uninstall" >&2; exit 2 ;;
esac
