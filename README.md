# Prompt Pilot

A Windows desktop workspace for turning rough requests into clear coding-agent
instructions, reviewing what changed, and optionally getting an answer from the
same provider. Your original request remains available throughout the session.

**Version 1.0.0-rc.2.** This is a release candidate. See [ROADMAP.md](ROADMAP.md)
for verified work and the remaining external release gates.

See [the validation record](docs/VALIDATION.md) for exact live and local proof.

![Prompt Pilot desktop session](docs/example-session.png)

## Start

Double-click **Start Prompt Pilot.cmd**. The launcher opens the portable EXE when
present, otherwise runs the source with Windows PowerShell 5.1 in STA mode.
Running it again asks the existing instance to save and close before restarting;
it does not force-kill your session. Close an open modal dialog if restart waits.

Requirements: Windows 10/11, Windows PowerShell 5.1 or PowerShell 7 with WPF,
and a provider API key. A provider API account is separate from a chat subscription.
Building an EXE additionally requires the pinned `ps2exe` version below.

Manual source launch:

```powershell
powershell.exe -NoProfile -STA -File .\Prompt_Pilot.Wpf.ps1
```

## A complete session

1. Open the provider button or **Settings > Providers and API keys**.
2. Select a provider and whether the choice is for Refine or Answer. Load model IDs
   or enter a direct API model ID. Pin a choice to keep recommendations from replacing it.
3. Enter a key, choosing encrypted storage for this Windows user or session-only
   use. Existing provider environment variables are also supported.
4. Review token prices. Known models use the dated, sourced catalog; other models
   need explicit custom rates. **Test a short request** verifies actual generation
   by asking for `PROMPT_PILOT_OK`; it uses API credits. Loading models sends no prompt.
5. Write your request, choose a refinement profile, and supply any relevant goals
   or project context. No language, stack or personal background is assumed.
6. Select 1-5 iterations, an output cap of 256-8,192 tokens, and a run budget.
   Click **Refine prompt**. The window remains responsive and Cancel stops an
   active request. **Keep draft** retains the latest completed revision.
7. Read or edit the draft, select earlier revisions, and use **Compare** to review
   additions and removals against the original request.
8. Copy the prompt or choose **Use prompt to answer**. Answer mode lets you choose
   the selected draft or the original request explicitly.
9. Reopen a saved session or export the original, revisions and answer as Markdown.

Autosave is on by default and restores the last session after restart. Turn it
off to use explicit **Save as** instead. Shortcuts: **Ctrl+N**, **Ctrl+O**, **Ctrl+S**.
If autosave fails on close, you can keep the window open and save elsewhere.
Saved sessions contain your prompts and results, so treat exports as your own documents.

## Providers

| Provider | API and configuration |
| --- | --- |
| OpenAI | Direct Chat Completions API. `OPENAI_API_KEY`. New-profile default: `gpt-5.4-mini`; saved models are preserved. Output limits use `max_completion_tokens`, including reasoning. |
| Anthropic | Direct Claude Messages API. `ANTHROPIC_API_KEY`. New-profile default: `claude-sonnet-5-5`. The simple `anthropic.claude-...` Bedrock prefix is corrected; regional/dated Bedrock IDs need the matching direct API ID. |
| GitHub Models (preview) | GitHub Models inference API, using a GitHub token with Models access. `GITHUB_TOKEN` or the legacy `GITHUB_COPILOT_API_KEY`. This is not a Copilot subscription API. Legacy provider names migrate automatically. Account-specific pricing must be configured explicitly. |

Model availability and token permissions depend on your account. Use the in-app
short-request test to verify the selected provider/model pair. GitHub Models
remains a compatibility preview until live discovery/generation is accepted.
The default models are suggestions, not an assurance of account access.

Credential priority: session key, saved encrypted key, provider environment variable.
Settings migrate the old shared price defaults to the model-specific catalog;
deliberate old custom rates are retained with an explicit legacy provenance label.

## Future models and default recommendations

Open **Models** or **Settings > Model recommendations**. Refinement and answers
have independent defaults for each provider. Existing saved selections migrate to
both roles as pinned; unpin a role explicitly to accept a recommendation.

- Available models are checked weekly for the selected provider while the app is
  open. This is metadata discovery, with no generation prompt. Cached IDs survive
  failed checks; a failed attempt backs off for a day. Automatic discovery can be disabled.
- Choose a role and candidate. Unknown prices require explicit custom rates or a
  sourced pricing-catalog update. Listing a model does not establish compatibility;
  the paid comparison begins with a real short-generation probe.
- Paid evaluations are off initially. Enable them and set both ceilings before
  running: initially **$1 per comparison** and **$5 per UTC calendar month**.
  Every probe, baseline, candidate and downstream/control request counts. Spending
  is reserved on disk before dispatch; uncertain spending is retained after interruption.
- Comparisons run twelve synthetic tasks three times. Refinement comparisons also
  test answers under a fixed answer model and compare with the original request.
  Failed, truncated, incomplete or uncertain comparisons cannot recommend an update.
- Results show task checks, costs, latency and the reason to adopt or keep a model.
  Adoption requires your explicit acceptance, fresh matching evidence and an unpinned
  role. It changes future sessions only; current/restored sessions keep their models.
  A matching accepted default can be rolled back. There is no automatic adoption.

An API or parameter change can require an application update. New model names do
not establish compatibility, prices or quality. The twelve controlled tasks measure
specific behavior; broader usefulness still needs real-user feedback.

Optional tools in the portable package/source checkout:

```powershell
# Discovery only; -Force bypasses the local schedule/disabled preference explicitly.
.\tools\Check-ModelUpdates.ps1 -Force
# Optional weekly discovery while the app is closed (logged-in Windows user).
.\tools\Install-ModelCheckTask.ps1 -WhatIf
.\tools\Install-ModelCheckTask.ps1
# Remove only the task with this name.
.\tools\Install-ModelCheckTask.ps1 -Remove
# Also requires paid evaluation to be enabled in the app.
.\tools\Compare-Models.ps1 -Role Answer -CandidateModel YOUR_MODEL_ID -AllowPaidEvaluation
```

The app does not install a scheduled task itself. Keep its folder in a stable
location if you register one. Session-only keys are unavailable to a closed-app check.
See [the implementation and decision policy](docs/MODEL-MANAGEMENT.md).

![Model comparison results in the actual desktop app](docs/model-recommendations.png)

## Reference files

Choose a supported text/source file, then check **Include the selected file's text**.
The visible preview contains the excerpt sent to the provider. The path alone is
not sent. Files must be at most 256 KB and valid UTF-8 or BOM-marked Unicode;
up to 20,000 characters are included with an explicit truncation notice.
Images, PDFs and binary files are not supported. The combined prompt, goals,
context and excerpt are limited to 64,000 characters.

## Costs and limits

Prices are estimates in **USD per one million tokens**. The catalog records its
source and check date in [data/pricing.json](data/pricing.json); custom pricing
can reflect your account. Unknown rates remain unknown and block a budgeted run.
Cached input is conservatively priced as regular input.

Before dispatching each request, the app reserves an input allowance based on
UTF-8 bytes plus framing, and the configured maximum output. Returned usage
reconciles the reservation. Timeout retries retain the earlier reservation because
an interrupted request might still be billed. Missing usage remains unknown.
The app stops dispatching when the next reservation would exceed the run budget.
Output limits include reasoning tokens; a model may use the cap before returning
visible text. Partial output is preserved and clearly labeled.

These local estimates use the configured rates. Provider-side spending limits
remain the authority for your account's total bill, taxes and account-specific charges.

## Local data, privacy and logs

- Settings and sessions: `%AppData%\Prompt Pilot\`.
- Saved keys: Windows user-protected ciphertext in `settings.json`.
- Sessions: local JSON documents with atomic replacement and a previous-file backup.
  They include prompts/results and exclude credential fields. There is no telemetry.
- Logs: `logs/` beside the source or EXE, falling back to the data directory if the
  app directory cannot be written. Known API keys are redacted. Request bodies,
  model output and file contents are not deliberately written to diagnostic logs.
- Managed logs rotate at 5 MB; startup retains at most 100 managed logs and removes
  managed logs older than 30 days. Other files in `logs/` are left alone.

See [privacy details](docs/PRIVACY.md). Legacy console scripts in `legacy/` are
historical references and are outside the current product workflow.

## Validate (source checkout)

```powershell
powershell.exe -NoProfile -STA -File .\tests\Invoke-Tests.ps1
```

Headless core/contract checks: `pwsh -File ./tests/Invoke-Tests.ps1 -Headless`.
The Windows suite also operates the actual Refine, Use-prompt and Cancel buttons,
verifies restart recovery, and checks the complete XAML. Mock tests make no paid calls.

Opt-in live acceptance uses configured credentials and synthetic public prompts:

```powershell
.\tools\Invoke-LiveAcceptance.ps1 -BudgetUsd 1.00 -EvaluationCases 3
```

The tool records provider outcomes, exact prompts/results, constraint checks and
estimated usage in `build/live-acceptance/`. A partial result exits nonzero and
keeps the evidence. Automated constraint checks are followed by human review of
usefulness; they do not establish universal prompt-quality improvement.

`tools/Invoke-LiveDesktopAcceptance.ps1` additionally operates the actual desktop
buttons with synthetic prompts and verifies restart recovery under isolated data.

## Build a portable release (source checkout)

```powershell
Install-Module ps2exe -RequiredVersion 1.0.17 -Scope CurrentUser
.\tools\Build-PortableExe.ps1
```

The build runs Windows tests, compiles the EXE, copies only declared resources,
starts the EXE under a fresh data directory, validates its smoke report, and writes
a ZIP, a file manifest and SHA-256 checksums under `dist/`. Existing output folders
are preserved with a `.previous-...` suffix. The build does not publish a release.
A valid code-signing certificate can be supplied with `-CertificateThumbprint`.
Unsigned artifacts are labeled `NotSigned`, never presented as trusted-publisher signed.

See [release instructions and acceptance gates](docs/RELEASE.md) and
[CHANGELOG.md](CHANGELOG.md). Licensed under the [MIT License](LICENSE).
