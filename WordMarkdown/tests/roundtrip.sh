#!/bin/bash
# Round-trip fidelity check for the WordMarkdown Pandoc pipeline.
#
# For every tests/corpus/*.md:  md --> docx --> md, using the same Pandoc
# options as the Word add-in, then compare the *parsed* documents (Pandoc's
# native AST), so harmless differences (list spacing, soft line breaks) do not
# count but lost structure does.
#
#   tests/roundtrip.sh            # summary
#   tests/roundtrip.sh -v         # also show each diff
#
# PANDOC=/path/to/pandoc overrides the pandoc found on PATH.

cd "$(dirname "$0")" || exit 2
PANDOC=${PANDOC:-pandoc}
READ='gfm+footnotes+yaml_metadata_block+tex_math_dollars'
WRITE='gfm+yaml_metadata_block'
REF=../ref/reference.docx
FILT=../filters
VERBOSE=0; [ "$1" = "-v" ] && VERBOSE=1

rm -rf out; mkdir -p out
pass=0; fail=0

for md in corpus/*.md; do
  b=$(basename "$md" .md)
  mkdir -p "out/$b"
  # Pandoc runs from the folder holding the .md (as the add-in does), so that
  # relative image paths resolve.
  (cd corpus &&
   "$PANDOC" "$b.md" -f "$READ" -t docx -o "../out/$b/$b.docx" \
       --resource-path=. --reference-doc="../$REF" --lua-filter="../$FILT/md-to-word.lua") \
     || { echo "FAIL  $b (md -> docx)"; fail=$((fail+1)); continue; }
  # Write the round-tripped .md next to a copy of the corpus so image links work.
  (cd corpus &&
   "$PANDOC" "../out/$b/$b.docx" -f docx+styles -t "$WRITE" -s --wrap=none --eol=lf \
       --extract-media="../out/$b/$b-media" --lua-filter="../$FILT/word-to-md.lua" \
       -o "../out/$b/$b.md") \
     || { echo "FAIL  $b (docx -> md)"; fail=$((fail+1)); continue; }

  # Compare ASTs.  Image paths are normalised away (they are rewritten on save).
  norm() {
    "$PANDOC" "$1" -f "$READ" -t native --wrap=none \
      | sed -E 's#"[^"]*media/[^"]*"#"<img>"#; s#"img/[^"]*"#"<img>"#; s#SoftBreak#Space#g' \
      | tr -s ' \n' ' ' \
      | sed 's/ , /\n, /g'
  }
  norm "$md"            > "out/$b/before.native"
  norm "out/$b/$b.md"   > "out/$b/after.native"
  if diff -q "out/$b/before.native" "out/$b/after.native" >/dev/null; then
    echo "SAME  $b"; pass=$((pass+1))
  else
    n=$(diff "out/$b/before.native" "out/$b/after.native" | grep -c '^[<>]')
    echo "DIFF  $b  ($n AST lines differ)"; fail=$((fail+1))
    [ $VERBOSE = 1 ] && diff "out/$b/before.native" "out/$b/after.native" | head -40
  fi
done

echo; echo "identical: $pass   different: $fail"
