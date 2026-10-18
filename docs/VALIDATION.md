# 1.0.0-rc.2 validation record

## Final local verification

- Native Windows PowerShell 5.1: **63 passed, 0 failed**.
- Linux PowerShell 7.6: **51 passed, 0 failed**; twelve Windows UI tests excluded.
- Tests cover existing provider/workflow/persistence behavior plus separate role
  routing, old settings/session migration, catalog metadata/cache/backoff, explicit
  paid opt-in, repeated comparisons, per-run/monthly ceilings and pre-dispatch
  persistent reservations. Unknown/interrupted/server-error liability is retained.
- Real WPF controls execute HTTP-backed comparisons, refuse a failing candidate,
  accept a qualifying controlled result for one role and roll back. Active-session
  model choices survive adoption. Pins, expired evidence, changed prices/capabilities
  and changed baselines block acceptance. Test discovery/container errors fail the runner.

Evidence: `build/model-windows-final-tests.txt` and `build/model-headless-final-tests.txt`.
The portable build reruns the native suite and records its count in package.json.

## Live discovery and independent role routing

Live metadata returned 14 Anthropic model IDs and 139 OpenAI IDs for the tested
accounts. These counts describe availability at the recorded check, not universal
access or generation support for every listed model.

Actual final-source desktop Refine -> Answer -> reopen passed with independent models:

| Provider | Refinement | Answer | Result |
| --- | --- | --- | --- |
| Anthropic | claude-sonnet-5-5 | claude-opus-5-5 | Passed |
| OpenAI | gpt-5-mini | gpt-5.4-mini | Passed |

The final desktop check used about $0.01705 in estimated generation cost. Synthetic
public prompts were used, original requests survived and saved answers were restored.
Evidence: `build/model-live/desktop-final/desktop-acceptance.json`.

## Live comparative evaluation

Each role completed twelve synthetic tasks with three repetitions:

- Answer: 36 paired tasks, 73 requests including the probe; about $0.05225.
- Refinement: 36 paired tasks, 181 requests including fixed-model downstream
  answers, original-request controls and the probe; about $0.33233.
- Both returned **Keep current**. The answer candidate was cheaper/faster but
  failed strict output checks more often. Failed tasks/actual outputs are retained.
  Exact checks include capitalization and punctuation; these results do not establish
  that a model is generally superior or inferior for real work.

These full comparisons preceded the final correction that retains uncertain HTTP
server-error spending and the addition of per-call request IDs/token counts. Their exact tested core/engine/corpus is archived in
`build/model-live/source`, with reports under `build/model-live/data/models/evaluations`.
Their acceptance fingerprints are intentionally stale against the final core. The
successful request path is unchanged. The final source passed the complete local
suite (including this failure path) and the live desktop check above. A final live
comparison preflight captured usage and request ID, then stopped after one request
at its $0.005 ceiling with no recommendation. Evidence: `build/model-live/final-preflight.json`.

Owner settings hashes matched before/after isolated verification. Encrypted key
copies were removed from owned fixtures after use. No real user session prompt was
sent, no default was promoted in owner settings and no scheduled task was installed.

## Distribution and remaining acceptance

The optional discovery-only scheduled task passed **WhatIf** validation, which is
not proof of a registered task executing later. Native artifacts are unsigned unless
built with a supplied signing certificate. Fresh-profile compiled startup and final
ZIP/checksum/launcher evidence are retained under build/ and the package manifest.
Windows UI Automation also opened the Models dialog in the actual compiled EXE,
verified paid evaluations were initially off and closed its isolated test process.

Hosted CI execution, clean Windows installation/upgrade, broader beta usefulness,
trusted signing/public distribution and GitHub Models live acceptance remain open
in ROADMAP.md. No commit, push or stable public release is claimed.
