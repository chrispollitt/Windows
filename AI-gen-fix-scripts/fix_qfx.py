#!/usr/bin/env python3
"""
fix_qfx.py
==========

A general repair tool for malformed Quicken Web Connect (.qfx / OFX 1.0.x SGML)
downloads. Supersedes the earlier Vancity-only script: it applies the same
header fix AND adds an opt-in fix for the Royal Bank "new account every time"
problem.

Fixes it can apply
------------------
  0. Leading BOM removal (ALWAYS): a byte-order mark wrongly prepended to the
     file (UTF-8 EF BB BF, or UTF-16/32 marks) makes the file start with
     something other than "OFXHEADER:", which Quicken's parser rejects. Any
     leading BOM is stripped. (No-op if none is present.)

  1. Header blank line (ALWAYS): OFX 1.0.x requires a single blank line between
     the plain-text header block and the <OFX> body. Vancity's Chequing/Savings
     export omits it, so Quicken can't find the body and the import fails. This
     inserts exactly one blank line. (No-op if already correct.)

  2. Line-ending normalisation (ALWAYS): collapses mixed CRLF/LF to one style
     (CRLF by default — the OFX/Windows convention).

  3. FITID sanitisation (ALWAYS): trims whitespace, removes backslashes, and
     removes embedded whitespace from each <FITID>, deterministically, so the
     ids stay stable across downloads (preserving duplicate detection). Cleans
     Vancity's malformed ids like '02.000002    FT26169KLYKQ\\B90'; a no-op on
     already-clean ids like RBC's.

  4. <FI> block injection (OPT-IN, --add-fi): Quicken links a downloaded file to
     an existing account using the financial-institution identity. RBC's
     MasterCard export omits the <FI><ORG>/<FID></FI> aggregate (it ships only
     <INTU.BID>), so Quicken treats every import as a new account. This injects
     a stable <FI> block. The <FID> defaults to the file's own <INTU.BID> value
     (so it always matches what RBC already sends and Quicken already accepts),
     and <ORG> is configurable (default "RBC").

All fixes are idempotent: re-running on an already-fixed file changes nothing.

Examples
--------
  # Vancity Chequing/Savings (header + fitids + eol):
  python3 fix_qfx.py "BadVancity-Account_Statement_xxxx.qfx"

  # RBC MasterCard (also inject the FI block so it links to the same account):
  python3 fix_qfx.py "BadMC-download-transactions.qfx" --add-fi --fi-org RBC

  # Override the FID instead of deriving it from INTU.BID:
  python3 fix_qfx.py infile.qfx --add-fi --fi-org RBC --fi-fid 12088
"""

import argparse
import os
import re
import sys


# ---------------------------------------------------------------------------
# Header / body
# ---------------------------------------------------------------------------
# Byte Order Marks that may be wrongly prepended to an OFX file. Quicken's
# OFX 1.0.x parser expects the very first bytes to be "OFXHEADER:..."; ANY
# leading BOM breaks parsing. UTF-8 is the realistic case for a .qfx, but the
# UTF-16/32 marks are handled too. Order matters: the UTF-32-LE signature
# starts with the UTF-16-LE one, so the longer marks must be tested first.
_BOMS = [
    ("UTF-32-LE", b"\xff\xfe\x00\x00", "utf-32-le"),
    ("UTF-32-BE", b"\x00\x00\xfe\xff", "utf-32-be"),
    ("UTF-8",     b"\xef\xbb\xbf",     "cp1252"),
    ("UTF-16-LE", b"\xff\xfe",         "utf-16-le"),
    ("UTF-16-BE", b"\xfe\xff",         "utf-16-be"),
]


def read_text(path):
    """
    Read the file, stripping a mistaken leading BOM if present.

    Returns (text, bom_name_or_None). After a BOM is removed the remaining
    bytes are decoded with the codec implied by that BOM; with no BOM (or a
    UTF-8 BOM) we use cp1252, the charset the file's header declares.
    """
    with open(path, "rb") as f:
        raw = f.read()
    for name, sig, codec in _BOMS:
        if raw.startswith(sig):
            stripped = raw[len(sig):]
            text = stripped.decode(codec, errors="replace")
            # Safety net: if a multibyte BOM was prepended to content that is
            # really single-byte (a mislabeled "sloppy bank" file), decoding
            # as UTF-16/32 yields garbage. Fall back to cp1252 so we never
            # choke on a BOM'd-but-ASCII file.
            if "OFX" not in text:
                text = stripped.decode("cp1252", errors="replace")
            return text, name
    return raw.decode("cp1252"), None


def split_header_and_body(text):
    """
    Return (header_lines, body_str).

    The OFX 1.x header is the run of leading 'KEY:VALUE' lines before the first
    line that starts the SGML body (first line beginning with '<'). Any existing
    blank separator is dropped here so we can re-insert exactly one (idempotent).
    The body is returned as a single string with '\\n' separators; its internal
    layout (single-line like RBC, or multi-line like Vancity) is preserved.
    """
    lines = text.splitlines()
    body_start = next((i for i, ln in enumerate(lines)
                       if ln.lstrip().startswith("<")), None)
    if body_start is None:
        raise ValueError("Could not locate the <OFX> body (no '<' line found).")
    header_lines = [ln for ln in lines[:body_start] if ln.strip() != ""]
    body_str = "\n".join(lines[body_start:])
    return header_lines, body_str


# ---------------------------------------------------------------------------
# Fix 3: FITID sanitisation (tag-based so it works on one-line or multi-line)
# ---------------------------------------------------------------------------
_FITID_RE = re.compile(r"(<FITID>)([^<\r\n]*)")


def _clean_fitid(val):
    val = val.strip().replace("\\", "")
    return re.sub(r"\s+", "", val)


def clean_fitids(body):
    changed = 0

    def repl(m):
        nonlocal changed
        cleaned = _clean_fitid(m.group(2))
        if cleaned != m.group(2):
            changed += 1
        return m.group(1) + cleaned

    return _FITID_RE.sub(repl, body), changed


# ---------------------------------------------------------------------------
# Fix 4: <FI> block injection
# ---------------------------------------------------------------------------
def inject_fi(body, org, fid):
    """
    Insert <FI><ORG>org<FID>fid</FI> immediately before the first <INTU.BID>,
    only if no <FI> block already exists. If fid is None, derive it from the
    file's own <INTU.BID>. Returns (body, injected_bool, used_fid).
    """
    if re.search(r"<FI>", body, re.IGNORECASE):
        return body, False, None  # already present; leave it alone

    if fid is None:
        m = re.search(r"<INTU\.BID>\s*([^<\r\n\s]+)", body)
        if not m:
            return body, False, None  # nothing to derive from; skip
        fid = m.group(1)

    block = f"<FI><ORG>{org}<FID>{fid}</FI>"
    new_body, n = re.subn(r"(<INTU\.BID>)", block + r"\1", body, count=1)
    if n == 0:
        return body, False, None
    return new_body, True, fid


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def repair(text, line_ending="crlf", add_fi=False, fi_org="RBC", fi_fid=None):
    header_lines, body = split_header_and_body(text)

    body, fitids_changed = clean_fitids(body)

    fi_injected, used_fid = False, None
    if add_fi:
        body, fi_injected, used_fid = inject_fi(body, fi_org, fi_fid)

    # Reassemble: header + one blank line + body, then normalise all newlines.
    logical = "\n".join(header_lines) + "\n\n" + body
    eol = "\r\n" if line_ending == "crlf" else "\n"
    out = logical.replace("\r\n", "\n").replace("\r", "\n").replace("\n", eol)
    if not out.endswith(eol):
        out += eol

    return out, {
        "line_ending": line_ending.upper(),
        "fitids_cleaned": fitids_changed,
        "fi_injected": fi_injected,
        "fi_org": fi_org if fi_injected else None,
        "fi_fid": used_fid,
    }


def main(argv=None):
    p = argparse.ArgumentParser(description="Repair malformed Quicken .qfx files.")
    p.add_argument("input", help="Path to the .qfx file")
    p.add_argument("-o", "--output", help="Output path (default: <input>_fixed.qfx)")
    p.add_argument("--line-ending", choices=["crlf", "lf"], default="crlf",
                   help="Output line endings (default: crlf).")
    p.add_argument("--add-fi", action="store_true",
                   help="Inject an <FI><ORG>/<FID></FI> block if absent (RBC fix).")
    p.add_argument("--fi-org", default="RBC",
                   help="ORG value for the injected <FI> block (default: RBC).")
    p.add_argument("--fi-fid", default=None,
                   help="FID for the injected <FI> block (default: derive from INTU.BID).")
    args = p.parse_args(argv)

    if not os.path.isfile(args.input):
        print(f"error: no such file: {args.input}", file=sys.stderr)
        return 2

    out_path = args.output
    if not out_path:
        base, ext = os.path.splitext(args.input)
        out_path = f"{base}_fixed{ext or '.qfx'}"

    text, bom = read_text(args.input)
    fixed, rpt = repair(text,
                        line_ending=args.line_ending,
                        add_fi=args.add_fi,
                        fi_org=args.fi_org,
                        fi_fid=args.fi_fid)

    with open(out_path, "wb") as f:
        f.write(fixed.encode("cp1252"))

    print(f"Fixed file written to: {out_path}")
    print(f"  - leading BOM removed         : {bom if bom else 'none found'}")
    print("  - blank line after OFX header : ensured")
    print(f"  - line endings normalised to  : {rpt['line_ending']}")
    print(f"  - FITIDs sanitised            : {rpt['fitids_cleaned']}")
    if args.add_fi:
        if rpt["fi_injected"]:
            print(f"  - <FI> block injected         : <ORG>{rpt['fi_org']} <FID>{rpt['fi_fid']}")
        else:
            print("  - <FI> block                  : already present or no INTU.BID; left unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
