-- WordMarkdown: run when converting Word -> Markdown.
--  * "Code Language" label paragraph + following code block -> fenced block
--    with that language.
--  * Code blocks are always written fenced (the gfm writer would otherwise
--    indent blocks that have no language).
--  * Drop Word-only paragraph/character style wrappers (custom-style) so they
--    do not leak into the Markdown as raw HTML.
--  * Drop image width/height so images stay plain ![alt](path).
--  * Write horizontal rules as a short "---".

local function is_label(b)
  return b.t == 'Div' and b.attributes['custom-style'] == 'Code Language'
end

local function fenced(text, lang)
  local longest = 0
  for run in text:gmatch('`+') do
    if #run > longest then longest = #run end
  end
  local fence = string.rep('`', math.max(3, longest + 1))
  return pandoc.RawBlock('markdown', fence .. (lang or '') .. '\n' .. text .. '\n' .. fence)
end

function Div(d)
  if d.attributes['custom-style'] and not is_label(d) then
    return d.content
  end
end

function Span(s)
  if s.attributes['custom-style'] then
    return s.content
  end
end

function Image(img)
  img.attributes['width'] = nil
  img.attributes['height'] = nil
  return img
end

function HorizontalRule()
  return pandoc.RawBlock('markdown', '---')
end

function Blocks(blocks)
  local out = pandoc.List()
  local i = 1
  while i <= #blocks do
    local b, nxt = blocks[i], blocks[i + 1]
    if is_label(b) then
      if nxt and nxt.t == 'CodeBlock' then
        local lang = pandoc.utils.stringify(b):gsub('%s+', '')
        if lang == 'plain' then lang = '' end
        out:insert(fenced(nxt.text, lang))
        i = i + 2
      else
        i = i + 1   -- orphan label: drop it
      end
    elseif b.t == 'CodeBlock' then
      out:insert(fenced(b.text, b.classes[1]))
      i = i + 1
    else
      out:insert(b)
      i = i + 1
    end
  end
  return out
end
