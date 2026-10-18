# Current-product web demonstration

The public entry points are `index.html` (overview) and `demo.html` (interactive
illustration). The actual product is Windows WPF/PowerShell 1.0.0-rc.2, not a web app.

## What the visitor sees

- Three curated synthetic scenarios matching the desktop's three refinement profiles.
- Preserved originals, two selectable revisions, original/draft comparison and an
  illustrative answer. Changing answer source does not generate or benchmark anything.
- Recorded live synthetic comparison counts and Keep current decisions for each role,
  with exact-source and limited-corpus qualifications from VALIDATION.md.
- Actual desktop screenshot, dated local proof and open release gates.

Workflow sample text in demo.js is editorial illustration, not extracted provider
transcripts. Comparison figures are copied from docs/VALIDATION.md and the archived
live reports. Never describe these workflows as live AI or guaranteed improvements.
No keys, backend, analytics, external fonts, browser storage or provider requests.
The page resets on reload. No desktop file/persistence functionality is simulated.

## Shared portfolio edition

Run `python3 tools/Sync-PortfolioDemo.py`. It emits the same HTML/CSS/JS and the
synthetic desktop screenshot under ignored build/portfolio-demo, using compact
layout and local evidence links for embedding. The case-sensitive destination is
`public/demos/PromptPilot/index.html` in ben-fuhr-portfolio. The portfolio's app,
candidate and artifact records carry the evidence and provenance independently.

## Maintenance

Update the dated product state, examples and validation together. Keep all sample
scenarios public and synthetic. Preserve the no-network implementation and reduced
motion styles. Verify keyboard navigation, all workflow views, scenario/revision
selection, comparison, reset, model-role switching, mobile overflow and local links
in a real browser. Run portfolio validate, lint, TypeScript and static export checks
before shipping its integration.

The old demo.svg is historical. The current presentation does not link to it.
