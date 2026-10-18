# Progress

- Started investigation with Git history and semantic diffs, preserving existing edits.
- Found PowerShell available on Linux and Windows; the existing test runner requires WPF/STA on Windows.
- Next: inspect provider/model settings, recent request changes, and test seams; verify Anthropic model naming against official documentation.
- Confirmed the saved model uses the Bedrock ID against the direct Anthropic endpoint. Verified the correct direct API ID in official documentation.
- Implementing automatic per-session logs, safe diagnostic errors in both execution modes, and narrow model-prefix correction. Saved user settings outside this checkout will remain untouched; the app will correct the selected model when loading/running.
- Automatic logging, prefix correction, error diagnostics and documentation are implemented. Preserved original CRLF application/XAML edits; added a UTF-8 BOM for Windows PowerShell 5.1 parsing.
- Linux PowerShell 7.6: 20 headless tests passed; 8 Windows UI tests excluded explicitly.
- Native Windows PowerShell 5.1: all 28 tests passed, including XAML, mock provider traffic, retry/cancellation and UI completion behavior.
- Added a final startup integration check with temporary settings to verify automatic logging, model correction, displayed path and checkbox events against the real application startup. No external provider request is made.
- Final native Windows PowerShell 5.1 run: all 29 tests passed. The startup check created real session logs under this project's `logs` directory and verified automatic enablement, displayed path, disable/re-enable behavior and shutdown logging.
- Live read-only Anthropic model-metadata verification confirmed the exact cause with the same saved credential: `anthropic.claude-opus-5-5` returned 404 and `claude-opus-5-5` returned 200. Evidence saved in `logs/Anthropic_model_verification_20261017_013718.log`; no key values or prompt content were recorded.
- Final whitespace check passed with `core.whitespace=cr-at-eol`, preserving pre-existing Windows line endings. Removed temporary baseline/verification scripts; retained diagnostic logs.
- Both requested tasks are complete. Restart updated source (or rebuild the packaged EXE); no live prompt-generation acceptance claim is made.

## Product completion
- Started the newly authorized product work. Restored current plans, assessed the dirty tree and retained the earlier logging/model fix.
- First step: verify current provider contracts and design a shared engine plus durable desktop workflow before editing execution/UI paths.
- Implemented the shared core with provider identity migration, model discovery, cancellable HTTP, transient retries, output caps, pricing provenance and conservative per-request budgets.
- Implemented atomic settings/session storage and backups, credential-free session/export schemas, explicit text-file ingestion and bounded line comparison.
- First core test run caught a case-insensitive variable-shadowing bug in session import and a Markdown format-expression error. Fixed both; all 28 new core tests pass under PowerShell 7.6 against local HTTP mocks.
- Rebuilt the WPF workflow around one background worker path, original/draft answer selection, autosave/recovery, revisions/diff, export, provider model loading and a real generation test in settings. Native startup/layout validation is in progress.
- Native startup smoke now passes, binds 56 controls and renders a screenshot. Visual inspection confirmed the main workflow is legible and primary actions stay visible.
- Windows checks found two compatibility details: PS5 requires simpler multidimensional-array expressions, and PS5 treats JSON arrays as PSCustomObject as well as Array. Corrected parser expressions and checked arrays before custom objects. Strengthened session round-trip assertions to verify actual revision text.
- Native Windows product suite passed 34 tests, including actual button interactions and restart recovery. Added additional scalar-array and invalid-numeric-field autosave regressions after review.
- Live Anthropic and OpenAI Refine -> Answer passed with synthetic criteria prompts. Three live constraint-preservation cases passed after fixing the corpus loader's PS5 wrapped-scalar handling and rechecking recorded outputs without extra API calls. Recorded estimated cost: $0.05923.
- GitHub catalog returns non-JSON `OK`; kept provider in preview and its live acceptance gate open rather than inferring support.
- Implemented one-click orderly restart/single-instance startup, pinned portable build, version/manifest/checksums, Windows CI, license/changelog and product/privacy/release documentation. Compiled-artifact smoke and final review are in progress.
- Compiled the actual EXE and produced a candidate ZIP; fresh-profile packaged startup from a different working directory passed. Source launcher activation and orderly restart passed using test-owned instances.
- Desktop-driven live Refine -> Use-prompt -> Answer -> restart recovery passed for Anthropic and OpenAI (recorded estimated cost $0.02319). Their new-profile defaults also passed live core acceptance (about $0.01001).
- Review caught fractional-dollar rounding in Math.Max overload selection. Fixed it with explicit double operands and added a regression that prevents a second request from exceeding the cumulative remaining budget.
- Final native suite passed 40 tests. Added/corrected Retry-After handling, unknown token usage, boolean session validation, numeric-field autosave and restored answer/usage display.
- Manual review of the initially passing constraint corpus found an investigation refinement that unnecessarily forbade recommendations. Updated the prompt to preserve permissions as well as prohibitions and discourage expansion of already-clear requests. Revalidating that case plus a deliberately messy coding request.

## Final product handoff
- Seven recorded constraint cases passed after review and targeted revalidation. The earlier over-restrictive output remains in prior evidence.
- Added the final data-loss safeguard: a failed close-time autosave leaves the window open when discard is declined. Final native suite: **41 passed, 0 failed**; headless: **33 passed**, eight Windows UI tests excluded.
- Repeated actual desktop Refine -> Answer -> reopen against the final source/core hashes: Anthropic `claude-opus-5-5` and OpenAI `gpt-5-mini` both passed.
- Built **1.0.0-rc.1** and verified compiled startup, packaged activation and orderly restart. Audited all 17 manifest hashes and 19 ZIP entries; runtime/private directories are excluded. Artifact is unsigned.
- Updated current workflow documentation and visibly labeled the earlier simulated demos as historical concepts.
- Removed encrypted credential copies from owned isolated test settings after use; original owner settings were left untouched.
- Final report: `build/product-verification.md` and `.json`; portable ZIP under `dist/`. Hosted CI, GitHub preview, clean-machine/upgrade, beta and signing gates remain explicitly open. No commit or public release was made.
