#!/usr/bin/env python3
"""make_site.py OUT_DIR  --  writes OUT_DIR/index.html (the dashboard page) from page.html and loader.js. Data lives in OUT_DIR/data."""
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
page = open(os.path.join(here, "page.html")).read()
loader = open(os.path.join(here, "loader.js")).read()
css = """<style>:root{--color-fg:#1b2130;--color-fg-muted:#5d6578;--color-bg:#f6f7fa;--color-panel:#fff;--color-border-line:#d5d9e2;--color-ok:#1e8a55;--color-warn:#c98a12;--color-bad:#c23a3a;--cds-radius:10px;--cds-pad-xs:4px;--cds-pad-sm:8px;--cds-pad-md:12px;--cds-pad-lg:18px;--cds-gap-sm:6px;--cds-gap-md:12px;--cds-gap-lg:20px;--cds-font-size-caption:12.5px;--cds-font-size-body:14.5px;--cds-font-size-heading:16px;--cds-font-weight-medium:500;--cds-chart-grid:#e3e6ee;--cds-chart-muted:#c3c9dc;--cds-chart-reference:#8a93a8;--cds-chart-status-critical:#d9433f;--cds-surface-popover:#fff;--cds-border:#d5d9e2;--cds-shadow-popover:0 4px 14px rgba(0,0,0,.15);--cds-text-secondary:#5d6578;--font-anthropic-sans:system-ui,-apple-system,Segoe UI,sans-serif;--font-anthropic-serif:Georgia,serif;--cds-dur-slow:.3s;--cds-ease-out:ease}
@media (prefers-color-scheme:dark){:root{--color-fg:#e8ebf3;--color-fg-muted:#9aa4b8;--color-bg:#12151d;--color-panel:#1a1e29;--color-border-line:#2b3142;--cds-chart-grid:#2b3142;--cds-chart-muted:#3b4358;--cds-chart-reference:#7b859b;--cds-surface-popover:#1a1e29;--cds-border:#2b3142;--cds-text-secondary:#9aa4b8}}
body{margin:0;background:var(--color-bg);color:var(--color-fg);font:14px system-ui,-apple-system,Segoe UI,sans-serif;padding:0 24px 40px}
select.dash-select{font:inherit;padding:6px 8px;border-radius:8px;border:1px solid var(--color-border-line);background:var(--color-panel);color:var(--color-fg)}
.dash-skeleton{background:#e4e7ee}@media (prefers-color-scheme:dark){.dash-skeleton{background:#262b3a}}</style>"""
html = ("<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1,viewport-fit=cover'>"
        "<meta name='robots' content='noindex,nofollow'><meta name='referrer' content='no-referrer'><title>Ranmaru stats</title>" + css +
        "<script src='https://cdnjs.cloudflare.com/ajax/libs/d3/7.8.5/d3.min.js'></script><script>" + loader + "</script></head>"
        "<body><div id='dash-root'>" + page + "</div></body></html>")
open(os.path.join(out, "index.html"), "w").write(html)
print("wrote", os.path.join(out, "index.html"), len(html))
