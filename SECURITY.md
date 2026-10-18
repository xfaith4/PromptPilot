# Security policy

Prompt Pilot stores provider API keys and sends your prompts to the provider you
choose. Reports about credential handling, log redaction, request construction,
session storage or the portable build are taken seriously.

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0.0-rc.2 (current release candidate) | Yes |
| Earlier release candidates | No, please upgrade |

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private vulnerability reporting: open the repository's **Security**
tab and choose **Report a vulnerability**. The report is visible only to the
maintainer until a fix is published.

Include, where you can:

- The app version from **Settings** or `data/product.json`, and whether you ran
  the portable EXE or the source.
- Steps to reproduce, with synthetic prompts rather than real work.
- Sanitised log lines from `logs/`. Known API keys are redacted automatically,
  but review the lines before sending them.
- The impact you observed or expect.

Never include an API key, an encrypted `settings.json`, or a session export that
contains private material.

You should receive an acknowledgement within a week. Confirmed issues are fixed
in the next release candidate and noted in [CHANGELOG.md](CHANGELOG.md).

## What the app does to protect you

- Saved keys are encrypted with Windows DPAPI for the current Windows user and
  stored in `settings.json`. Session-only keys are never written to disk.
- Sessions exclude credential fields and are written atomically with a backup.
- Diagnostic logs redact known API keys and do not deliberately record request
  bodies, model output or file contents.
- Spend is reserved on disk before each request so a crash cannot silently
  exceed the configured budget.
- There is no telemetry. The only network calls are to the provider you selected.
- Release candidates are currently unsigned. Verify the SHA-256 checksum published
  with each release before running the EXE.

See [docs/PRIVACY.md](docs/PRIVACY.md) for the full description of local data.
