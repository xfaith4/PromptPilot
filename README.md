# Prompt Pilot

Prompt Pilot is a Windows WPF desktop tool for refining prompts and running task-oriented requests against configurable AI providers.

## Current App Surface

The active application is the WPF client:

- `Prompt_Pilot.Wpf.ps1`
- `Prompt_Pilot.MainWindow.xaml`

Legacy console scripts have been retired from the root and moved into `legacy/` so the packaged product now has a single primary entrypoint.

## Features

- Refine prompts over multiple iterations.
- Switch between prompt refinement and task execution modes.
- Use OpenAI, Anthropic, or GitHub Copilot from the same settings flow.
- Show provider/key status in the UI without exposing secret values.
- Keep session keys in memory only, with optional current-user saved keys.
- Package the app into a portable Windows folder with an `.exe`, XAML, and manifest.

## Provider Configuration

Provider keys are resolved in this order:

1. Session key entered in the app.
2. Saved key in `%AppData%\Prompt Pilot\settings.json`.
3. Provider environment variable.

Supported providers and environment variables:

- OpenAI: `OPENAI_API_KEY`
- Anthropic: `ANTHROPIC_API_KEY`
- GitHub Copilot: `GITHUB_COPILOT_API_KEY` or `GITHUB_TOKEN`

Saved keys are protected with `ConvertFrom-SecureString` and scoped to the current Windows user profile.

## Run From Source

Run the WPF app in STA mode on Windows:

```powershell
powershell.exe -NoProfile -Sta -File .\Prompt_Pilot.Wpf.ps1
```

```powershell
pwsh -NoProfile -Sta -File .\Prompt_Pilot.Wpf.ps1
```

## Build Portable Package

Build the portable Windows package with:

```powershell
.\tools\Build-PortableExe.ps1
```

Default output:

```text
dist\Prompt_Pilot\
  Prompt_Pilot.exe
  Prompt_Pilot.MainWindow.xaml
  package.json
```

Optional example:

```powershell
.\tools\Build-PortableExe.ps1 -OutputBaseName Prompt_Pilot_Beta -ProductName 'Prompt Pilot Beta'
```

Requirements:

- Windows PowerShell 5.1 or PowerShell 7 on Windows
- `ps2exe` installed in the PowerShell host used for packaging

If needed:

```powershell
Install-Module ps2exe -Scope CurrentUser
```

## Project Layout

- `Prompt_Pilot.Wpf.ps1`: WPF application entrypoint
- `Prompt_Pilot.MainWindow.xaml`: WPF window definition
- `tools/Build-PortableExe.ps1`: packaging script
- `tools/Build-AppIcon.ps1`: icon generation helper
- `assets/prompt-pilot.ico`: application icon used for builds
- `legacy/`: retired console scripts kept for reference only

## Security Notes

- No provider API keys are hardcoded in source.
- Saved keys are stored per-user, not in the repository.
- Session keys are never written to disk.
- Generated logs and packaged output are excluded from the main source flow.

## Validation

- `Prompt_Pilot.Wpf.ps1` parses cleanly.
- `Prompt_Pilot.MainWindow.xaml` has no current editor diagnostics.
- `tools/Build-PortableExe.ps1` builds the portable package from the renamed WPF files.
