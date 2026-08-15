# Prompt Pilot — Demo Assets

This folder contains a self-contained demo package that communicates the Prompt
Pilot workflow without requiring a Windows environment or a live API key.

## Assets

| File | Description |
|---|---|
| [`index.html`](index.html) | **GitHub Pages landing page** — product-style presentation that combines the screen recording slot, interactive walkthrough, and animated preview. |
| [`demo.svg`](demo.svg) | **Animated SVG** — 30-second looping animation of the 5-step workflow. Embeds directly in the README and renders in all modern browsers and the GitHub file viewer. |
| [`demo.html`](demo.html) | **Interactive HTML walkthrough** — step-by-step demo with live UI simulation, auto-advance, and manual navigation. Open locally in any browser; no server required. |
| [`workflow.md`](workflow.md) | **Text walkthrough** — detailed step-by-step guide covering every UI field, the status bar, provider configuration, and file logging. |

## GitHub Pages showcase

`docs/index.html` is intended to be the GitHub Pages entrypoint for demo presentation.
It prioritizes a screen recording at `docs/demo.mp4` (or `docs/demo.webm`) and combines
it with the existing interactive and animated demo assets.

## What the demo shows

The demo walks through the five core workflow steps:

1. **Enter a rough prompt** — type an unpolished idea into the Base Prompt box.
2. **Set goals and project context** — guide the AI with constraints, style, and environment.
3. **Click Run Refinement** — the app iterates N times and streams iteration history live.
4. **Structured prompt ready** — output arrives as Role · Task · Requirements · Constraints sections.
5. **Copy · preset · Answer mode** — paste the result, save as a JSON preset, or execute directly.

## Using the SVG in your own documentation

The animated SVG can be embedded anywhere Markdown renders images:

```markdown
![Prompt Pilot demo](docs/demo.svg)
```

It loops automatically and requires no JavaScript or network access.

## Viewing the HTML demo locally

```powershell
# Windows — open directly in the default browser
Start-Process docs\demo.html

# macOS / Linux
open docs/demo.html
```

The HTML file is fully self-contained (no CDN dependencies) and works offline.
