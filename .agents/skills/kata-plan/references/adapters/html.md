# HTML Plan Adapter

Run this adapter only when the user requests HTML. The canonical Markdown plan
must already exist and pass its review. When Beadwork is also requested, run
Beadwork first so the HTML contains final issue IDs.

## Output contract

Create one self-contained `.html` file beside the Markdown plan with the same
basename. The HTML is a derived reading view. It must identify and link to the
canonical Markdown source. Do not delete, replace, or hide the Markdown file.
If that HTML path already exists, overwrite it only when it identifies the same
canonical Markdown source. Otherwise stop the adapter and report the collision.

On a later plan update, edit Markdown and regenerate HTML. Never treat a manual
HTML-only change as a plan change.

## Content parity

Represent every Markdown section, stable ID, decision, unit, dependency,
verification gate, blocker, source, and adapter result. Preserve the same
order and meaning. Presentation can add navigation and visual grouping, but it
must not add or remove a contract.

If Markdown contains Mermaid source, include the source in an accessible
`<pre>` block. Use a verified inline SVG only when the labels and edges can be
checked. Do not add a JavaScript runtime only to render a diagram.

## Document structure

Use semantic HTML:

```html
<!doctype html>
<html lang="en">
<head>...</head>
<body>
  <header>...</header>
  <nav aria-label="Plan sections">...</nav>
  <main>...</main>
  <footer>...</footer>
</body>
</html>
```

The header must show:

- plan title;
- readiness;
- last-reviewed date;
- software domain;
- canonical Markdown path or relative link; and
- Beadwork epic ID when available.

Use stable heading IDs derived from section names and plan IDs. Link the table
of contents to those IDs.

## Presentation rules

- Keep all CSS in one `<style>` element.
- Use no external fonts, scripts, stylesheets, images, or network assets.
- Use a readable line length and clear heading hierarchy.
- Make tables horizontally scrollable on narrow screens.
- Preserve code and command whitespace.
- Use color with sufficient contrast and never as the only status signal.
- Give readiness and blockers plain-text labels.
- Support keyboard navigation and visible focus.
- Add print styles that remove navigation clutter and preserve links.
- Escape source text before placing it in HTML.
- Use JavaScript only when the requested plan needs a small local interaction
  that cannot be expressed with HTML and CSS. The default is no JavaScript.

## Suggested visual mapping

- Goal Capsule: compact summary panel.
- Product Contract and Planning Contract: primary sections, not tabs that hide
  content.
- KTD entries: decision cards with reason and consequences.
- Implementation units: ordered cards with dependency badges and stable IDs.
- Work graph: text frontier plus optional static diagram.
- Verification Contract: responsive table.
- Blockers and risks: high-contrast callouts with text labels.
- Sources and adapter results: compact reference sections.

Do not turn every bullet into a card. Keep normal prose readable.

## Verify the view

When a browser or rendering tool is available, open the local HTML and inspect:

- desktop and narrow viewport layout;
- navigation and fragment links;
- table and code overflow;
- contrast and focus visibility;
- diagram labels and edges;
- print layout when practical; and
- content parity with the final Markdown.

When visual rendering is unavailable, check the HTML source, local links,
heading IDs, escaped content, and section parity. Report that visual inspection
did not run.

Update the Markdown Adapter Results only after these checks pass. If HTML fails,
keep the canonical Markdown plan and record the failure. Do not downgrade an
otherwise implementation-ready plan because an optional view failed.
