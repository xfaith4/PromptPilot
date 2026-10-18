#!/usr/bin/env python3
"""Generate the offline portfolio edition from the current Pages demo."""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'build' / 'portfolio-demo'
DEST.mkdir(parents=True, exist_ok=True)
html = (ROOT / 'docs' / 'demo.html').read_text(encoding='utf-8')
html = html.replace('<body>', '<body class="portfolio">')
html = html.replace('href="index.html" aria-label="Prompt Pilot home"', 'href="#workspace" aria-label="Prompt Pilot demo"')
html = html.replace('<a href="index.html">Product overview ↗</a>', '<a href="product-evidence.txt" target="_blank" rel="noreferrer">Product evidence ↗</a>')
(DEST / 'index.html').write_text(html, encoding='utf-8')
for name in ('demo.css', 'demo.js', 'example-session.png'):
    shutil.copy2(ROOT / 'docs' / name, DEST / name)
(DEST / 'product-evidence.txt').write_text(
    'PROMPT PILOT 1.0.0-rc.2 — EVIDENCE DATED 2026-10-18\n\n'
    'This is a curated offline illustration, not the Windows application.\n'
    'Workflow text is illustrative synthetic content. No provider requests or charges.\n\n'
    + (ROOT / 'docs' / 'VALIDATION.md').read_text(encoding='utf-8'), encoding='utf-8')
print(DEST)
