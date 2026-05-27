-- passage-xref.lua
-- Quarto Lua filter for custom inline passage cross-references.
--
-- Target:    [text]{.passage #pas-xxx}
-- Reference: [Passage]{.pref pas="pas-xxx"}
--            [Passage]{.pref pas="pas-xxx" prefix="Stmt"}
--            [Passage]{.pref pas="pas-xxx" noprefix="true"}
--
-- Features:
--   - Auto-numbered inline passage targets
--   - Clickable numbered references (same as native xrefs)
--   - Tippy.js hover preview (reuses Quarto's built-in tippy)
--   - Forward references supported (two-pass design)
--   - HTML-only: CSS/JS injection skipped for PDF and other formats
--   - Tolerant of [text] and {#id .class} split across lines

local passage_counter = 0
local passages = {}
local has_passages = false

--- Parse attribute string like `{#pas-abc .passage key="val"}`
local function parse_attr_str(s)
  if not s:match("^{") or not s:match("}$") then return nil end
  local inner = s:sub(2, -2)
  local id = inner:match("#(%S+)")
  local classes = {}
  local attrs = {}
  for c in inner:gmatch("%.(%S+)") do
    table.insert(classes, c)
  end
  for k, v in inner:gmatch('(%a[%w%-]+)="([^"]*)"') do
    attrs[k] = v
  end
  return pandoc.Attr(id or "", classes, attrs)
end

--- Collect a run of Str/Space/SoftBreak/Quoted inlines starting at `idx`.
--- Returns the joined string and end index.
local function collect_text_run(inlines, idx)
  local parts = {}
  local end_idx = idx
  while end_idx <= #inlines do
    local il = inlines[end_idx]
    if il.t == "Str" then
      table.insert(parts, il.text)
    elseif il.t == "Space" or il.t == "SoftBreak" then
      table.insert(parts, " ")
    elseif il.t == "Quoted" then
      table.insert(parts, '"' .. pandoc.utils.stringify(il) .. '"')
    else
      break
    end
    end_idx = end_idx + 1
  end
  return table.concat(parts), end_idx - 1
end

--- Fix broken `[text]\n{#id .class}` in a flat inline list.
--- When a formatter or manual edit splits the bracket text from its
--- attributes, Pandoc leaves them as separate Str nodes.  This function
--- detects the pattern and merges them into a proper Span.
--- Only merges when attributes contain `.passage` or `.pref` to avoid
--- corrupting native Pandoc spans.
--- Returns the (possibly modified) inline list.
local function fix_broken_inlines(inlines)
  local i = 1
  local result = {}
  while i <= #inlines do
    local il = inlines[i]

    -- Only interested in Str nodes ending with ]
    if il.t ~= "Str" or not il.text:match("%]$") then
      table.insert(result, il)
      i = i + 1
      goto continue
    end

    -- Check if the remaining inlines form an attribute block
    local attr_raw, attr_end = collect_text_run(inlines, i + 1)
    if not attr_raw or not attr_raw:match("^%s*{") then
      table.insert(result, il)
      i = i + 1
      goto continue
    end

    -- Parse the attribute block
    local trimmed = attr_raw:match("^%s*(.*)")
    local parsed = parse_attr_str(trimmed)
    if not parsed then
      table.insert(result, il)
      i = i + 1
      goto continue
    end

    -- Only fix passage-xref related spans — leave native Pandoc spans alone
    local cls = table.concat(parsed.classes, " ")
    if not cls:match("passage") and not cls:match("pref") then
      table.insert(result, il)
      i = i + 1
      goto continue
    end

    -- Scan result backwards for opening [
    local bracket_start = nil
    for ri = #result, 1, -1 do
      local rt = result[ri]
      if rt.t == "Str" and rt.text:match("^%[") then
        bracket_start = ri
        break
      end
      if rt.t ~= "Str" and rt.t ~= "Space" and rt.t ~= "SoftBreak" then
        break
      end
    end
    if not bracket_start then
      table.insert(result, il)
      i = i + 1
      goto continue
    end

    -- Reconstruct [text] and verify bracket matching
    local pieces = {}
    for k = bracket_start, #result do
      table.insert(pieces, pandoc.utils.stringify(result[k]))
    end
    table.insert(pieces, il.text)
    local full = table.concat(pieces, " ")

    if not full:match("^%[.*%]$") then
      table.insert(result, il)
      i = i + 1
      goto continue
    end

    -- Merge into a proper Span
    local inner = full:sub(2, -2):gsub("%s+", " ")
    for _ = #result, bracket_start, -1 do
      table.remove(result)
    end
    table.insert(result, pandoc.Span(pandoc.Str(inner), parsed))
    i = attr_end + 1

    ::continue::
  end
  return result
end

--- Recursively fix broken spans in all blocks, descending into
--- Divs, BlockQuotes, lists, etc.
local function fix_doc(doc)
  local function walk_inlines(il_list)
    if type(il_list) ~= "table" or #il_list == 0 then return end
    if not il_list[1].t then return end
    local fixed = fix_broken_inlines(il_list)
    for idx = 1, #fixed do il_list[idx] = fixed[idx] end
    while #il_list > #fixed do table.remove(il_list) end
    for _, il in ipairs(il_list) do
      if il.content then walk_inlines(il.content) end
    end
  end

  local function walk_blocks(blocks)
    for _, block in ipairs(blocks) do
      if block.t == "Para" or block.t == "Plain" or block.t == "Header" then
        walk_inlines(block.content)
      elseif block.t == "Div" or block.t == "BlockQuote" then
        walk_blocks(block.content)
      elseif block.t == "BulletList" or block.t == "OrderedList" then
        for _, sublist in ipairs(block.content) do
          walk_blocks(sublist)
        end
      elseif block.t == "LineBlock" then
        for _, line in ipairs(block.content) do
          walk_inlines(line)
        end
      end
    end
  end

  walk_blocks(doc.blocks)
  return doc
end

function Pandoc(doc)
  passage_counter = 0
  passages = {}
  has_passages = false

  -- Pass 0: Fix broken [text]\n{#id .class} spans
  doc = fix_doc(doc)

  -- Pass 1: Collect, number, and annotate all .passage spans
  for i, block in ipairs(doc.blocks) do
    doc.blocks[i] = pandoc.walk_block(block, { Span = function(span)
      if span.classes:includes("passage") then
        local id = span.identifier
        if id and id:match("^pas%-") then
          if passages[id] then
            pcall(function() quarto.log.warning("Duplicate passage ID: " .. id .. "; using first occurrence") end)
          else
            passage_counter = passage_counter + 1
            passages[id] = passage_counter
          end
          has_passages = true
          local num = passages[id]
          local marker = pandoc.Span(
            pandoc.Str(string.format(" {%d}", num)),
            pandoc.Attr("", {"passage-marker"})
          )
          table.insert(span.content, marker)
          return span
        end
      end
    end })
  end

  -- Pass 2: Resolve all .pref references into links
  for i, block in ipairs(doc.blocks) do
    doc.blocks[i] = pandoc.walk_block(block, { Span = function(span)
      if span.classes:includes("pref") then
        local pas_id = span.attributes["pas"]
        if not pas_id then
          return pandoc.Strong(pandoc.Str("[?pref:missing-pas]"))
        elseif passages[pas_id] then
          has_passages = true
          local num = passages[pas_id]
          local prefix = span.attributes["prefix"] or "Passage"
          local noprefix = span.attributes["noprefix"] == "true"
          local label
          if noprefix then
            label = tostring(num)
          else
            label = string.format("%s %d", prefix, num)
          end
          return pandoc.Link(
            pandoc.Str(label),
            "#" .. pas_id,
            "",
            pandoc.Attr("", {"passage-xref"})
          )
        else
          return pandoc.Strong(pandoc.Str("[?pref:" .. pas_id .. "]"))
        end
      end
    end })
  end

  -- Inject CSS + JS into metadata (HTML only, only when passages exist)
  if has_passages then
    local format = FORMAT:match("[^%+]+")
    if format == "html" or format == "html4" or format == "html5" then
      local css = pandoc.RawInline("html", [[
<style>
.passage-marker {
  color: #6c757d;
  font-size: 0.75em;
  font-weight: 600;
  vertical-align: super;
  margin-left: 2px;
}
.passage-xref {
  color: var(--link-color, #2a6496);
  text-decoration: none;
  font-weight: 500;
}
.passage-xref:hover {
  text-decoration: underline;
}
.passage-preview {
  font-size: 0.95em;
  line-height: 1.5;
  max-height: 200px;
  overflow-y: auto;
  padding: 4px 0;
}
.passage-preview .passage-marker {
  display: none;
}
</style>
]])
      local js = pandoc.RawInline("html", [[
<script>
(function() {
  function setupPassageXrefs() {
    if (typeof window.tippy === "undefined") return;
    document.querySelectorAll("a.passage-xref").forEach(function(xref) {
      if (xref._tippy) return;
      var url = xref.getAttribute("href");
      var hash;
      if (url && url.indexOf("#") === 0) {
        hash = url;
      } else if (url) {
        try { hash = new URL(url).hash; } catch(e) { return; }
      }
      if (!hash) return;
      var id = hash.replace(/^#\/?/, "");
      var target = document.getElementById(id);
      if (!target) return;
      var clone = target.cloneNode(true);
      var marker = clone.querySelector(".passage-marker");
      if (marker) marker.remove();
      var wrapper = document.createElement("div");
      wrapper.className = "passage-preview";
      wrapper.appendChild(clone);
      window.tippy(xref, {
        maxWidth: 500,
        delay: 100,
        arrow: false,
        appendTo: function() { return document.body; },
        interactive: true,
        interactiveBorder: 10,
        theme: "quarto",
        placement: "bottom-start",
        content: wrapper
      });
    });
  }
  function deferSetup() {
    setTimeout(setupPassageXrefs, 0);
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", deferSetup);
  } else {
    deferSetup();
  }
})();
</script>
]])

      if not doc.meta["header-includes"] then
        doc.meta["header-includes"] = pandoc.MetaList({})
      end
      table.insert(doc.meta["header-includes"], css)
      table.insert(doc.meta["header-includes"], js)
    end
  end

  return doc
end

return { Pandoc = Pandoc }
