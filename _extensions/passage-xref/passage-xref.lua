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

local passage_counter = 0
local passages = {}
local has_passages = false

function Pandoc(doc)
  -- Reset state for each document (chapter in book projects)
  passage_counter = 0
  passages = {}
  has_passages = false

  -- Pass 1: Collect and number all .passage spans
  for i, block in ipairs(doc.blocks) do
    doc.blocks[i] = pandoc.walk_block(block, { Span = function(span)
      if span.classes:includes("passage") then
        local id = span.identifier
        if id and id:match("^pas%-") then
          if passages[id] then
            pcall(function() quarto.log.warning("Duplicate passage ID: " .. id) end)
          end
          passage_counter = passage_counter + 1
          passages[id] = passage_counter
          has_passages = true
          local marker = pandoc.Span(
            pandoc.Str(string.format(" {%d}", passage_counter)),
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

  return doc
end

-- Inject CSS + tippy.js hover preview JS (HTML output only)
function Meta(meta)
  -- Skip if no passage elements in this document
  if not has_passages then return meta end

  -- Only inject for HTML output formats
  local format = FORMAT:match("[^%+]+")
  if format ~= "html" and format ~= "html4" and format ~= "html5" then
    return meta
  end

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
      if (xref._tippy) return; // already initialized
      var url = xref.getAttribute("href");
      // Quarto's nav script rewrites hrefs to full URLs; extract hash fragment
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

  if not meta["header-includes"] then
    meta["header-includes"] = pandoc.MetaList({})
  end
  table.insert(meta["header-includes"], css)
  table.insert(meta["header-includes"], js)

  return meta
end

return {
  Pandoc = Pandoc,
  Meta = Meta,
}
