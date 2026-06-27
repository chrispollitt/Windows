#!/usr/bin/env python3
"""
fix_qfx.py
==========

A general repair tool for malformed Quicken Web Connect (.qfx / OFX 1.0.x SGML)
downloads. Supersedes the earlier Vancity-only script: it applies an array of
automatic fixes to bridge the gap between sloppy bank exports and Quicken's
strict, legacy SGML parser.

Fixes it can apply
------------------
  0. Leading BOM removal (ALWAYS)
  1. Header blank line (ALWAYS)
  2. Line-ending normalisation (ALWAYS)
  3. FITID sanitisation (ALWAYS)
  4. <FI> block injection (OPT-IN, --add-fi)
  5. Text Tag Sanitization (ALWAYS): Unescapes HTML entities and safely 
     re-escapes SGML special characters (<, >, &) inside <NAME>, <MEMO>, 
     and <PAYEE> tags where banks frequently put unescaped garbage.
  6. Date Format Normalisation (ALWAYS): Quicken expects YYYYMMDDHHMMSS. 
     Converts common bank date formats (e.g., 2023-10-25, 10/25/2023) safely.
  7. Account ID cleaning (ALWAYS): Strips spaces from <ACCTID> to prevent 
     Quicken treating spaced account numbers as new accounts.
  8. Bare Ampersand Escaping (ALWAYS): Escapes stray & to &amp; outside text tags.
  9. Missing </OFX> closure (ALWAYS): Appends </OFX> if truncated downloads
     omit the root closing tag.

All fixes are idempotent: re-running on an already-fixed file changes nothing.

Examples
--------
  # Vancity Chequing/Savings (header + fitids + eol):
  python3 fix_qfx.py "BadVancity-Account_Statement_xxxx.qfx"

  # RBC MasterCard (also inject the FI block so it links to the same account):
  python3 fix_qfx.py "BadMC-download-transactions.qfx" --add-fi --fi-org RBC
"""

import argparse
import datetime
import html
import os
import re
import sys


# ---------------------------------------------------------------------------
# Header / body
# ---------------------------------------------------------------------------
# Byte Order Marks that may be wrongly prepended to an OFX file.
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
    Returns (text, bom_name_or_None). Falls back to cp1252.
    """
    with open(path, "rb") as f:
        raw = f.read()
    for name, sig, codec in _BOMS:
        if raw.startswith(sig):
            stripped = raw[len(sig):]
            text = stripped.decode(codec, errors="replace")
            if "OFX" not in text:
                text = stripped.decode("cp1252", errors="replace")
            return text, name
    return raw.decode("cp1252", errors="replace"), None


def split_header_and_body(text):
    """
    Return (header_lines, body_str).
    """
    lines = text.splitlines()
    body_start = next((i for i, ln in enumerate(lines)
                       if ln.lstrip().startswith("<")), None)
    if body_start is None:
        raise ValueError("Could not locate the <OFX> body (no '<' line found).")
    header_lines = [ln.rstrip() for ln in lines[:body_start] if ln.strip() != ""]
    body_str = "\n".join(lines[body_start:])
    return header_lines, body_str


# ---------------------------------------------------------------------------
# Fix 3: FITID sanitisation
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
    if re.search(r"<FI>", body, re.IGNORECASE):
        return body, False, None
    if fid is None:
        m = re.search(r"<INTU\.BID>\s*([^<\r\n\s]+)", body)
        if not m:
            return body, False, None
        fid = m.group(1)
    block = f"<FI><ORG>{org}<FID>{fid}</FI>"
    new_body, n = re.subn(r"(<INTU\.BID>)", block + r"\1", body, count=1)
    if n == 0:
        return body, False, None
    return new_body, True, fid


# ---------------------------------------------------------------------------
# Fix 5: Text Tag Sanitization (HTML entities & SGML escaping)
# ---------------------------------------------------------------------------
_TEXT_TAG_RE = re.compile(r"(<(?:NAME|MEMO|PAYEE)>)(.*?)(</(?:NAME|MEMO|PAYEE)>)", re.IGNORECASE)

def clean_text_tags(body):
    changed = 0
    def repl(m):
        nonlocal changed
        tag_open, content, tag_close = m.groups()
        original = content
        # Unescape HTML like &#39; &nbsp; etc into plain text
        content = html.unescape(content)
        # Re-escape SGML specials to prevent parser crashes
        content = content.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        if content != original:
            changed += 1
        return f"{tag_open}{content}{tag_close}"
    return _TEXT_TAG_RE.sub(repl, body), changed


# ---------------------------------------------------------------------------
# Fix 6: Date Format Normalisation
# ---------------------------------------------------------------------------
_DT_RE = re.compile(r"(<DT(?:POSTED|AVAIL|START|END|PROFUP|USER|ASOF)>)([^<\r\n]+)", re.IGNORECASE)

def _clean_dt(val):
    val = val.strip()
    # Already in YYYYMMDDHHMMSS or YYYYMMDD format? Leave it.
    m = re.search(r"(\d{4})(\d{2})(\d{2})(\d{2})?(\d{2})?(\d{2})?", val)
    if m and m.group(1) and m.group(2) and m.group(3):
        y, mo, d = m.group(1), m.group(2), m.group(3)
        hh = m.group(4) or "00"
        mm = m.group(5) or "00"
        ss = m.group(6) or "00"
        try:
            datetime.datetime(int(y), int(mo), int(d), int(hh), int(mm), int(ss))
            return f"{y}{mo}{d}{hh}{mm}{ss}"
        except ValueError:
            pass
    # Try parsing common delimited formats
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d", "%m/%d/%Y", "%d/%m/%Y", "%Y/%m/%d"):
        try:
            dt = datetime.datetime.strptime(val, fmt)
            return dt.strftime("%Y%m%d%H%M%S")
        except ValueError:
            continue
    return val # Fallback to original if unparseable

def clean_dates(body):
    changed = 0
    def repl(m):
        nonlocal changed
        original = m.group(2)
        cleaned = _clean_dt(original)
        if cleaned != original:
            changed += 1
        return m.group(1) + cleaned
    return _DT_RE.sub(repl, body), changed


# ---------------------------------------------------------------------------
# Fix 7: Account ID space removal
# ---------------------------------------------------------------------------
_ACCTID_RE = re.compile(r"(<ACCTID>)([^<\r\n]*)", re.IGNORECASE)

def clean_acctid(body):
    changed = 0
    def repl(m):
        nonlocal changed
        original = m.group(2)
        cleaned = re.sub(r"\s+", "", original)
        if cleaned != original:
            changed += 1
        return m.group(1) + cleaned
    return _ACCTID_RE.sub(repl, body), changed


# ---------------------------------------------------------------------------
# Fix 8: Bare Ampersand Escaping
# ---------------------------------------------------------------------------
_BARE_AMP_RE = re.compile(r"&(?!amp;|lt;|gt;|apos;|quot;|#?\d+;)")

def clean_bare_ampersands(body):
    changed = len(_BARE_AMP_RE.findall(body))
    return _BARE_AMP_RE.sub("&amp;", body), changed


# ---------------------------------------------------------------------------
# Fix 9: Missing </OFX> closure
# ---------------------------------------------------------------------------
def ensure_ofx_closed(body):
    stripped = body.rstrip()
    if not stripped.upper().endswith("</OFX>"):
        return stripped + "\n</OFX>", True
    return body, False


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def repair(text, line_ending="crlf", add_fi=False, fi_org="RBC", fi_fid=None):
    header_lines, body = split_header_and_body(text)

    # Apply all body fixes
    body, fitids_changed = clean_fitids(body)
    body, text_changed = clean_text_tags(body)
    body, dates_changed = clean_dates(body)
    body, acctid_changed = clean_acctid(body)
    body, amp_changed = clean_bare_ampersands(body)
    body, ofx_closed = ensure_ofx_closed(body)

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
        "text_tags_cleaned": text_changed,
        "dates_normalized": dates_changed,
        "acctids_cleaned": acctid_changed,
        "ampersands_escaped": amp_changed,
        "ofx_closure_added": ofx_closed,
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

    try:
        text, bom = read_text(args.input)
        fixed, rpt = repair(text,
                            line_ending=args.line_ending,
                            add_fi=args.add_fi,
                            fi_org=args.fi_org,
                            fi_fid=args.fi_fid)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    with open(out_path, "wb") as f:
        f.write(fixed.encode("cp1252", errors="replace"))

    print(f"Fixed file written to: {out_path}")
    print(f"  - leading BOM removed         : {bom if bom else 'none found'}")
    print("  - blank line after OFX header : ensured")
    print(f"  - line endings normalised to  : {rpt['line_ending']}")
    print(f"  - FITIDs sanitised            : {rpt['fitids_cleaned']}")
    print(f"  - Text tags parsed/escaped    : {rpt['text_tags_cleaned']}")
    print(f"  - Dates normalised to YYYYMMDD: {rpt['dates_normalized']}")
    print(f"  - Account IDs spaced stripped : {rpt['acctids_cleaned']}")
    print(f"  - Bare ampersands escaped     : {rpt['ampersands_escaped']}")
    print(f"  - Missing </OFX> closure added: {rpt['ofx_closure_added']}")
    
    if args.add_fi:
        if rpt["fi_injected"]:
            print(f"  - <FI> block injected         : <ORG>{rpt['fi_org']} <FID>{rpt['fi_fid']}")
        else:
            print("  - <FI> block                  : already present or no INTU.BID; left unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())