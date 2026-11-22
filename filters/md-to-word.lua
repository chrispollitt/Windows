-- WordMarkdown: run when converting Markdown -> Word.
-- Put a small "Code Language" label paragraph before each fenced code block
-- that has a language (or that directly follows another code block).  The
-- label lets the language survive a trip through Word, and it stops Word from
-- merging two adjacent code blocks into one.

local function label(text)
  return pandoc.Div({ pandoc.Para({ pandoc.Str(text) }) },
                    pandoc.Attr('', {}, { { 'custom-style', 'Code Language' } }))
end

function Blocks(blocks)
  local out = pandoc.List()
  local prev_code = false
  for _, b in ipairs(blocks) do
    if b.t == 'CodeBlock' then
      local lang = b.classes[1]
      if lang or prev_code then
        out:insert(label(lang or 'plain'))
      end
      out:insert(b)
      prev_code = true
    else
      out:insert(b)
      prev_code = false
    end
  end
  return out
end
