# WordMarkdown

Open and save Markdown (`.md`) files in Microsoft Word, using Pandoc.

A macro-enabled template (`WordMarkdown.dotm`) that Word loads at startup. It adds a **Markdown** tab to the ribbon.

| Button | What it does |
|---|---|
| Open Markdown... | Converts the `.md` with Pandoc and opens it in Word, tied to that file |
| Save | Writes the document back to its `.md` (the old `.md` goes to `BAK\`, 3 newest kept) |
| Save As Markdown... | Picks a new `.md` and ties the document to it |
| Export Copy as Markdown... | Writes a `.md` copy of any document without changing how it saves |
| Save as Word (.docx)... | Unties the document and saves a normal `.docx` |
| Settings... | Pandoc path, read/write Markdown flavour, line endings for new files |

While a document is tied to an `.md`, **Ctrl+S and File > Save As write Markdown** (a `BeforeSave` hook), and the window title shows the `.md` name.

## Install

1. Install Pandoc (found automatically on PATH, `%LOCALAPPDATA%\Pandoc`, or `Program Files\Pandoc`).
2. Close all Word windows.
3. Run `/home/chris/src/Claude/TO_BE_RUN/REUSABLE/install-wordmarkdown.sh --vbom`.
   `--vbom` turns on Word's "Trust access to the VBA project object model" just for the build and puts it back afterwards. Or tick that box yourself and run without the flag.
4. Start Word and look for the Markdown tab.

The build imports the VBA, runs `MarkdownIO.SelfTest` (so a compile error stops the build), adds the ribbon XML, and installs:

- `%APPDATA%\Microsoft\Word\STARTUP\WordMarkdown.dotm`
- `%APPDATA%\WordMarkdown\filters\*.lua` and `reference.docx` (existing `reference.docx` is kept; edit its styles to change how Markdown looks in Word)

Re-run the installer after changing anything in `src/` or `filters/`. Old installed copies go to a `BAK\` folder next to them.

## How it works

```
.md  --pandoc (gfm, md-to-word.lua, reference.docx)-->  .docx  --> Word
Word --copy--> .docx --pandoc (word-to-md.lua)--> .md   (cwd = the .md's folder)
```

- Read format: `gfm+footnotes+yaml_metadata_block+tex_math_dollars`. Write format: `gfm+yaml_metadata_block`. Change in Settings.
- Fenced code blocks keep their language through Word via a small "Code Language" label paragraph above the block (this also keeps adjacent blocks separate).
- YAML front matter becomes Word's Title/Author/Date and is restored on save.
- Images are embedded in Word and written on save to `<name>-media/media/` beside the `.md`.
- Line endings of an existing `.md` are kept (LF by default for new files).

## Fidelity: what survives and what does not

Round-trips cleanly: headings, paragraphs, emphasis/strong/strikethrough, inline code, links, bullet/numbered/nested lists (incl. start number), task lists, pipe tables with alignment, fenced code with language, block quotes, hard breaks, footnotes, horizontal rules, images (alt + title), YAML front matter, Unicode.

Changes on a round trip (inherent to Word vs Markdown, confirmed by `tests/roundtrip.sh`):

- **Link titles** (`[x](url "title")`) are dropped. Word has nowhere to keep them.
- **Nested block quotes** are flattened to one level.
- **Raw HTML** (`<div>`, `<u>`, etc.) is dropped.
- **Code blocks inside list items** are pulled out of the list, which breaks the list into pieces.
- **Image file names** become `rIdNN.png` in `<name>-media/`; the original `img/foo.png` link is rewritten and the old file is left alone.
- **Source style** is normalised: `*`/`_` emphasis, setext vs `#` headings, list marker spacing (`1.  x`), `$x^2$` to `$x^{2}$`, bare URLs to `<url>`. Hard-wrapped paragraphs become one long line.
- Word-only content (comments, text boxes, merged-cell tables, tracked changes beyond accept-all) is not representable.

Because of this, every save keeps the previous `.md` in `BAK\` (3 newest, rotated per Word session). Keep your `.md` files in git as well.

## Tests

`tests/roundtrip.sh [-v]` runs every file in `tests/corpus` through md to docx to md with the same Pandoc options the add-in uses, and compares the parsed documents. It tests the Pandoc half only (needs `pandoc` on PATH, or set `PANDOC=`). Add a file to `tests/corpus` for any Markdown you care about.

## Status

The Pandoc pipeline and filters are tested. The VBA, ribbon and `BeforeSave` behaviour have **not yet been run in Word** (the build script's `SelfTest` is the first check). Things most likely to need adjustment on first use: the Save As dialog's file-name handling, close-with-unsaved-changes behaviour, and footnotes/images surviving the temporary copy (`FormattedText`).

## Files

- `src/MarkdownIO.bas`, `src/AppEvents.cls` - VBA (ASCII + CRLF, required by VBA import)
- `src/customUI14.xml` - ribbon
- `filters/md-to-word.lua`, `filters/word-to-md.lua` - Pandoc Lua filters
- `ref/reference.docx` - Pandoc's default reference doc (styles used when opening Markdown)
- `build/Build-WordMarkdown.ps1` - build + install
- `tests/` - corpus and round-trip script

## Security bar on every start

Word shows "SECURITY WARNING - Some active content has been disabled" for an unsigned macro template, even in STARTUP (the Trusted Location approach did not help). The fix is to sign the VBA project with a code-signing certificate that is also in your Trusted Publishers store (see `trust-codesign-cert-windows.sh`).

The build script does this itself: after the self-test it opens the VBA editor's Tools > Digital Signature and `build/Sign-Helper.ps1` (a separate process) clicks through the dialogs: a mouse click on Choose..., UI Automation on the Windows Security certificate prompt (certificate matched by name, default `-CertMatch 'Chris Pollitt'`), a mouse click on OK. It then checks that the saved template contains `vbaProjectSignature*.bin`. The mouse moves by itself for a few seconds, so don't touch it. Leave the Word windows that pop up alone while it runs. What it did is logged to `%TEMP%\WordMarkdown-sign.log`. `-NoSign` (installer: `--nosign`) skips it.

If the automatic step fails the template is installed unsigned. Sign it by hand: `winword /a`, open the STARTUP `WordMarkdown.dotm`, Alt+F11, select the project, Tools > Digital Signature > Choose > the certificate > OK, Ctrl+S.

## Save As dialog

Markdown commands use the Windows Save dialog with a "Markdown (*.md)" filter and always write Markdown (a trailing `.docx` is dropped). To save a Word file use **Save as Word (.docx)**.
