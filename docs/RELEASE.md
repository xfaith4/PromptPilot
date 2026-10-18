# Release process

Current target: **1.0.0-rc.1**. `data/product.json` is the version source.
A release candidate is not a claim that clean-machine, beta or trusted-publisher
acceptance has already occurred. See ROADMAP.md and the latest local evidence.

## Local verification

1. Run `powershell.exe -NoProfile -STA -File tests/Invoke-Tests.ps1` on Windows.
2. Run `tools/Invoke-LiveAcceptance.ps1 -BudgetUsd 1.00 -EvaluationCases 3` with
   provider accounts you intend to support. Preserve failures and account-policy
   limitations. Live metadata access and live generation are distinct checks.
3. Review representative outputs in `build/live-acceptance/acceptance.json`.
   Check preservation of every hard constraint, unnecessary additions, clarity,
   and whether downstream answers actually follow the refined prompt.
4. Build with `tools/Build-PortableExe.ps1`. It pins ps2exe 1.0.17, runs tests,
   assembles declared resources and starts the actual EXE from a different working
   directory using a fresh data directory. `-SkipTests` is intended for CI after
   the same source has already passed the Windows suite.
5. Inspect `dist/Prompt_Pilot/package.json`, `SHA256SUMS.txt`, the ZIP and its hash.
   Smoke evidence and screenshots stay under `build/package-smoke-*`.

The Windows CI workflow performs the automated tests, build and packaged smoke.
Its artifact is a reviewable candidate, not an automatically published release.

## Public release acceptance

- Test the extracted ZIP on a clean Windows 10/11 machine without developer modules.
- Verify first launch, key setup, text-file preview, Refine -> Compare -> Answer,
  cancellation, session restore and upgrading an earlier data directory.
- Run with at least one non-admin Windows user and from a path containing spaces.
- Confirm readable layout at the minimum supported window size and common display scaling.
- Have a small beta group complete representative tasks and report both failures
  and whether refined prompts improve their downstream work.
- Resolve the GitHub Models preview/live-access gate before advertising verified
  GitHub generation. Unknown account pricing requires explicit custom rates.
- Use a trusted code-signing certificate for broad distribution. Supply its
  thumbprint with `-CertificateThumbprint` when building. No certificate or private
  key belongs in the repository; unsigned candidates are labeled as such.
- Review current pricing/model availability, update the dated catalog if needed,
  and close only gates supported by evidence before publishing a stable version.

## Failure recovery and support

The launcher requests an orderly restart and waits up to ten seconds. It does
not force-kill another session. Close a modal dialog if restart waits.

Report the app version, provider/model, action taken, timestamp and sanitized log
lines including the provider request ID. Include session documents or screenshots
only after reviewing their contents. Existing corrupt settings/session files are
preserved; a valid `.bak` can be restored. Do not share API keys or encrypted
credential files.
