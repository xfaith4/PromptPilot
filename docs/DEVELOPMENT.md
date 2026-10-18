# Developing, testing and building Prompt Pilot

This page collects the source-checkout instructions that used to live in the
main README: running the test suites, the optional live acceptance tools, the
model discovery and comparison scripts, and the portable EXE build. The release
process and public acceptance gates are in [RELEASE.md](RELEASE.md).

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

The GitHub Actions workflow in `.github/workflows/windows.yml` runs the Windows
suite, builds the portable EXE with `-SkipTests`, and uploads the candidate ZIP,
checksums and smoke evidence as a reviewable artifact. It does not publish a release.

## Model discovery and comparison tools

These scripts ship in the portable package and the source checkout. They are
optional; the desktop app performs the same discovery and comparisons from
**Models** or **Settings > Model recommendations**. See
[MODEL-MANAGEMENT.md](MODEL-MANAGEMENT.md) for the decision policy.

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

## Build a portable release (source checkout)

```powershell
# Run from the project directory, in either Windows PowerShell or PowerShell 7.
# These commands install prerequisites into Windows PowerShell's user location.
powershell.exe -NoProfile -Command "Install-Module ps2exe -RequiredVersion 1.0.17 -Scope CurrentUser"
powershell.exe -NoProfile -Command "Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-PortableExe.ps1
```

The compiler remains pinned to **ps2exe 1.0.17** for reproducible builds; installing
1.0.18 does not replace that requirement. The build also finds compatible modules
already installed in either `Documents/WindowsPowerShell/Modules` or
`Documents/PowerShell/Modules`, using the actual redirected Documents location.
It does not change your persistent module path or automatically install modules.

The build runs Windows tests, compiles the EXE, copies only declared resources,
starts the EXE under a fresh data directory, validates its smoke report, and writes
a ZIP, a file manifest and SHA-256 checksums under `dist/`. Existing output folders
are preserved with a `.previous-...` suffix. The build does not publish a release.
A valid code-signing certificate can be supplied with `-CertificateThumbprint`.
Unsigned artifacts are labeled `NotSigned`, never presented as trusted-publisher signed.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Prompt_Pilot.Wpf.ps1`, `*.xaml` | Desktop UI and window definitions. |
| `PromptPilot.Core.ps1` | Provider engine, budgeting, sessions and logging. |
| `PromptPilot.Models.ps1`, `PromptPilot.ModelWindow.ps1` | Model discovery, comparison and the model-management window. |
| `data/` | Version source (`product.json`) and the dated pricing catalog. |
| `presets/`, `evaluations/` | Refinement profiles and the synthetic evaluation corpus. |
| `tests/` | Pester suites; `Invoke-Tests.ps1` is the entry point. |
| `tools/` | Build, live acceptance and model-management scripts. |
| `docs/` | User documentation and the GitHub Pages walkthrough. |
| `docs/dev/` | Historical planning and investigation notes, not current documentation. |
| `legacy/` | Earlier console scripts kept for reference only. |
| `build/`, `dist/`, `logs/` | Ignored local build, package and log output. |
