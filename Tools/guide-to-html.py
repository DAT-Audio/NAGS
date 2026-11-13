#!/usr/bin/env python3
"""Turns docs/quick-start/QUICK-START.md into QUICK-START.html with every picture built in, so
it opens in any browser — some Markdown viewers (Quick Look among them) show no images.

    python3 Tools/guide-to-html.py

Handles only what the guide uses: headings (with GitHub's anchors, so in-page links work),
paragraphs, lists (with pictures inside them), tables, images, links, rules, **bold**, *italic*,
`code` and a fenced code block.
"""
import base64, html, os, re

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "quick-start")
src = open(os.path.join(here, "QUICK-START.md"), encoding="utf-8").read().splitlines()
# A blank line before a picture indented under a list item would end the list: drop it.
src = [l for i, l in enumerate(src)
       if not (not l.strip() and i + 1 < len(src) and src[i + 1].startswith("  ![") )]


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![*\w])\*([^*]+)\*(?!\w)", r"<em>\1</em>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    return text


def slug(text):
    """GitHub's heading anchor: lower case, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"[^\w\- ]", "", text.lower())
    return text.replace(" ", "-")


def li(text):
    # A picture written indented under an item belongs to that item.
    parts = re.split(r"\s*(!\[[^\]]*\]\([^)]+\))\s*", text)
    return "".join(image(*re.match(r"!\[([^\]]*)\]\(([^)]+)\)", p).groups()) if p.startswith("![") else inline(p)
                   for p in parts if p)


def image(alt, path):
    data = base64.b64encode(open(os.path.join(here, path), "rb").read()).decode()
    return f'<figure><img alt="{html.escape(alt)}" src="data:image/png;base64,{data}"></figure>'


out, para, items, kind, code, table = [], [], [], None, None, []


def flush():
    global para, items, kind, table
    if table:
        head, *rows = [[c.strip() for c in r.strip().strip("|").split("|")] for r in table if not re.match(r"\|[-| ]+\|$", r.strip())]
        out.append("<table><thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead><tbody>"
                   + "".join("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in rows)
                   + "</tbody></table>")
        table = []
    if para:
        out.append(f"<p>{inline(' '.join(para))}</p>")
        para = []
    if items:
        tag = "ol" if kind == "ol" else "ul"
        start = f' start="{items[0][0]}"' if kind == "ol" and items[0][0] != 1 else ""
        out.append(f"<{tag}{start}>" + "".join(f"<li>{li(t)}</li>" for _, t in items) + f"</{tag}>")
        items, kind = [], None


for line in src:
    if code is not None:
        if line.startswith("```"):
            out.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
            code = None
        else:
            code.append(line)
        continue
    if line.startswith("```"):
        flush(); code = []; continue
    m_img = re.match(r"!\[([^\]]*)\]\(([^)]+)\)\s*$", line)
    m_h = re.match(r"(#{1,3}) (.*)", line)
    m_ol = re.match(r"(\d+)\. (.*)", line)
    m_ul = re.match(r"- (.*)", line)
    if line.startswith("|"):
        if not table: flush()
        table.append(line); continue
    elif table:
        flush()
    if line.startswith("  ") and line.strip().startswith("![") and items:
        n, t = items[-1]; items[-1] = (n, t + " " + line.strip())
    elif m_img:
        flush(); out.append(image(*m_img.groups()))
    elif m_h:
        flush(); n = len(m_h.group(1)); t = m_h.group(2)
        out.append(f'<h{n} id="{slug(t)}">{inline(t)}</h{n}>')
    elif line.strip() == "---":
        flush(); out.append("<hr>")
    elif m_ol:
        if para or kind == "ul": flush()
        kind = "ol"; items.append((int(m_ol.group(1)), m_ol.group(2)))
    elif m_ul:
        if para or kind == "ol": flush()
        kind = "ul"; items.append((0, m_ul.group(1)))
    elif line.startswith("  ") and items:
        n, t = items[-1]; items[-1] = (n, t + " " + line.strip())
    elif not line.strip():
        flush()
    else:
        if items: flush()
        para.append(line.strip())
flush()

page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Network Audio quick start</title>
<style>
:root {{ --bg:#fff; --fg:#1d1d1f; --muted:#6e6e73; --rule:#d2d2d7; --code:#f2f2f4; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#1c1c1e; --fg:#f2f2f7; --muted:#a1a1a6; --rule:#3a3a3c; --code:#2c2c2e; }} }}
body {{ background:var(--bg); color:var(--fg); font:16px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
       max-width: 900px; margin: 0 auto; padding: 32px 16px 80px; }}
h1 {{ font-size: 2em; margin: 0 0 .4em; }}
h2 {{ font-size: 1.45em; margin: 1.6em 0 .4em; }}
h3 {{ font-size: 1.12em; margin: 1.6em 0 .3em; }}
hr {{ border: 0; border-top: 1px solid var(--rule); margin: 2.4em 0; }}
figure {{ margin: 12px 0 10px; }}
img {{ max-width: 100%; height: auto; border-radius: 10px; box-shadow: 0 2px 14px rgba(0,0,0,.25); }}
li {{ margin: .25em 0; }}
code {{ background: var(--code); padding: 1px 5px; border-radius: 4px; font-size: .9em; }}
pre {{ background: var(--code); padding: 12px; border-radius: 8px; overflow-x: auto; font-size: .85em; }}
pre code {{ background: none; padding: 0; }}
a {{ color: #e8892c; }}
table {{ border-collapse: collapse; width: 100%; margin: 10px 0 6px; font-size: .95em; }}
th, td {{ border: 1px solid var(--rule); padding: 7px 10px; text-align: left; vertical-align: top; }}
th {{ background: var(--code); }}
li figure {{ margin: 8px 0 14px; }}
em {{ color: var(--muted); }}
</style></head><body>
{chr(10).join(out)}
</body></html>
"""
open(os.path.join(here, "QUICK-START.html"), "w", encoding="utf-8").write(page)
print("wrote docs/quick-start/QUICK-START.html")
