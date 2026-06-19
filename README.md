# quarto-passage-xref

A [Quarto](https://quarto.org) extension that adds cross-references for arbitrary inline text passages — something Quarto's native cross-reference system doesn't support.

## Overview

Quarto provides built-in cross-references for figures, tables, equations, theorems, and other floating environments. However, you can't cross-reference an arbitrary span of inline text. This extension fills that gap.

## Installation

```bash
quarto add jiangyangzx/quarto-passage-xref
```

## Usage

### Define a passage target

Wrap any inline text with `.passage` and give it an ID starting with `pas-`:

```markdown
The [decalcification step uses 0.5M HCl at 4°C for 72 hours]{.passage #pas-decalcification}.
```

A superscript number is automatically appended: `decalcification step...¹`

### Reference a passage

Use `.pref` with the `pas` attribute to create a cross-reference:

```markdown
As described in [Passage]{.pref pas="pas-decalcification"}.
```

This renders as a clickable link: `Passage 1`

### Options

| Attribute | Example | Description |
|-----------|---------|-------------|
| `pas` | `pas="pas-foo"` | ID of the target passage (required) |
| `prefix` | `prefix="Stmt"` | Custom label prefix (default: `"Passage"`) |
| `noprefix` | `noprefix="true"` | Show only the number, no prefix |

```markdown
[Passage]{.pref pas="pas-decalcification"}          → Passage 1
[Passage]{.pref pas="pas-decalcification" prefix="Step"} → Step 1
[Passage]{.pref pas="pas-decalcification" noprefix="true"}  → 1
```

### Forward references

References can appear before their targets in the document. The two-pass filter design resolves forward references correctly.

### Hover previews (HTML only)

On hover, passage references show a tooltip preview of the target text using the same tippy.js library Quarto uses for native cross-references.

### Cross-file references with `{{< include >}}`

Passages defined in different files work seamlessly when using Quarto's `{{< include >}}` pattern, since all included content merges into a single Pandoc document before filters run.

### Tolerant syntax

The filter is tolerant of how the bracket text and its attribute block are written. They may sit on a single line, or be split across separate lines — the filter detects the split and merges them into a proper span before numbering. Both forms below produce the same result:

```markdown
[the square of the hypotenuse equals the sum of the squares of the other two sides]{.passage #pas-pythagoras}

[the square of the hypotenuse equals the sum of the squares of the other two sides]
{.passage #pas-pythagoras}
```

This is convenient for long passages that wrap onto their own line, and it also repairs spans that some Markdown formatters break apart. Only spans carrying `.passage` or `.pref` are touched; native Pandoc spans are left alone.

### Broken references

Unresolved references display a warning: **[?pref:pas-missing-id]**

Duplicate passage IDs emit a warning during rendering.

## Configuration

Add the extension to your `_quarto.yml`:

```yaml
filters:
  - passage-xref
```

No additional configuration needed.

## Format support

| Format | Support |
|--------|---------|
| HTML | Full (numbering, links, hover previews) |
| PDF | Partial (numbering and links; no hover previews) |
| Word / EPUB | Partial (numbering; link behavior depends on reader) |

## License

MIT
