# 1.0.0-rc.1 validation record

This record distinguishes local implementation, mocked execution, live generation
and acceptance that needs an independent environment or human feedback.

## Automated Windows verification

Native Windows PowerShell 5.1: **41 tests passed**. Coverage includes the shared
HTTP engine, per-provider payload/output caps, fractional-dollar budget accounting,
retry and Retry-After handling, active cancellation, missing usage, JSON migration,
atomic backups, document limits and credential-free session/export schemas.

WPF checks operate the actual Refine, Use-prompt and Cancel buttons, load model IDs
and run a generation test through the provider dialog against loopback servers,
verify nonblocking startup, preserve revisions after cancellation, restore sessions
and keep primary actions inside the minimum supported window. A failed close-time
autosave keeps the window open when the user declines to discard changes.

PowerShell 7.6 on Linux: **33 headless tests passed**; the eight Windows-only UI
tests are excluded explicitly. Linux is a test environment, not a supported GUI platform.

## Live provider evidence

All prompts were synthetic and public, not the owner's real project instructions.

| Provider/model | Live Refine -> Answer | Actual desktop buttons and restart |
| --- | --- | --- |
| Anthropic `claude-opus-5-5` | Passed | Passed |
| OpenAI `gpt-5-mini` (saved configuration) | Passed | Passed |
| Anthropic `claude-sonnet-5-5` (new-profile default) | Passed | Core acceptance |
| OpenAI `gpt-5.4-mini` (new-profile default) | Passed | Core acceptance |
| GitHub Models `openai/gpt-4.1` | Not attempted | Preview gate remains open |

GitHub's documented catalog endpoint returned HTTP 200 with a `text/plain` body
of `OK`, including with JSON/version headers. This is a failed metadata check,
not a successful model list and not a failed generation. No unpriced generation
was sent. Account-appropriate pricing and live GitHub generation remain open.

Local evidence:

- `build/live-acceptance-final/acceptance.json` and `requests.log`.
- `build/live-desktop-final/desktop-acceptance.json`, saved synthetic sessions and screenshots.
- `build/default-provider-check/evidence/acceptance.json`.

The desktop run verified the original request survived Refine -> Answer, completed
revisions were saved, and the answer was restored on reopening the session.
Live generation evidence is bound to the recorded models/accounts and does not
establish that every model returned by a provider supports this workflow.

## Prompt quality

Seven recorded cases passed explicit constraint checks: CSV acceptance criteria,
Python version/schema/package constraints, read-only investigation, file/path scope,
general-copy length/tone, preserving unknowns, and a deliberately messy coding request.

Manual review found one earlier output unnecessarily forbade recommendations when
the user only forbade making production changes. The refinement policy was corrected
to preserve permissions as well as prohibitions and avoid expanding already-clear
requests. The affected case was rerun; the older output remains in prior evidence.
A regex check was also corrected to recognize `don't` as equivalent to `do not`,
using the already-recorded output without paying for another generation.

These checks establish specific constraint preservation. A small beta cohort must
still assess usefulness on real work before a general prompt-quality claim is made.

## Distribution evidence and limits

The source launcher passed single-instance activation and orderly restart using
test-owned Windows processes and isolated data. The portable build compiles the
real EXE, starts it from another working directory with fresh data, verifies its
startup report and produces a manifest/checksums and ZIP. Build-local evidence is
under `build/package-smoke-*` and `build/launcher-check-*`.

The candidate is **unsigned** unless built with a supplied valid signing certificate.
Fresh-data checks were run on the development Windows host; they are not clean-machine
proof. Hosted GitHub CI has been configured but cannot be claimed passed before the
reviewed changes are pushed and the workflow actually runs.

See ROADMAP.md for clean-machine/upgrade, beta, signing and GitHub preview gates.
