# Contributing to Prompt Pilot

Thanks for your interest. Prompt Pilot is a Windows desktop app written in
PowerShell and WPF. Bug reports, documentation fixes and focused pull requests
are welcome.

## Before you start

- Check [ROADMAP.md](ROADMAP.md) and open issues so work is not duplicated.
- For anything larger than a small fix, open an issue first and describe the
  change and why it helps. Features that would weaken the cost guardrails,
  local-only data handling or explicit model adoption are unlikely to be accepted.
- Never commit API keys, encrypted credential files, session exports or logs.
  The `logs/`, `build/` and `dist/` folders are ignored for that reason.

## Development setup

You need Windows 10 or 11 with Windows PowerShell 5.1. PowerShell 7 works for
headless checks. The full suite drives the real WPF window, so it needs an
interactive desktop session.

```powershell
powershell.exe -NoProfile -Command "Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser"
powershell.exe -NoProfile -STA -File .\tests\Invoke-Tests.ps1
```

Headless core and contract checks only:

```powershell
pwsh -File ./tests/Invoke-Tests.ps1 -Headless
```

Mock tests make no paid provider calls. The live acceptance tools under `tools/`
are opt-in, use your own credentials and spend real credits. See
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the build and tooling details.

## Making changes

- Keep PowerShell 5.1 compatibility unless a change is explicitly PowerShell 7 only.
- Preserve existing settings and session schemas. If a schema must change, add a
  migration and bump the schema number in `data/product.json`.
- Add or update a Pester test for new behaviour. UI changes should be covered by
  the Windows suite, not only by headless checks.
- Update [CHANGELOG.md](CHANGELOG.md) under the current unreleased version and
  the relevant page under `docs/` when behaviour or documentation changes.
- Keep Markdown lint-clean: fenced code blocks declare a language, headings are
  surrounded by blank lines, and table delimiter rows use spaced pipes.

## Pull requests

1. Branch from `main` and keep the change focused on one topic.
2. Run the test suite locally and note the result in the PR description.
3. Fill in the pull request template. The CI workflow runs the Windows suite and
   builds the portable EXE on every push and pull request.
4. Expect review questions about budgeting, credential handling and privacy for
   any change that touches provider requests, settings or logs.

## Reporting problems

Use the issue templates. For security problems, including anything involving
stored keys or log redaction, follow [SECURITY.md](SECURITY.md) instead of
opening a public issue.
