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

## Model management (2026-10-18)
- Began the newly authorized coding plan/roadmap work. Existing application/core/XAML diffs are line endings only; roadmap has formatting-only edits. Preserved a source baseline under ignored build/.
- Planning catch-up script reports Codex session parsing unsupported; restored context from checked-in planning files, current diffs and evidence instead.
- Settings/schema migration, cached discovery, evaluation policy/runner, native dialog and routing are implemented. First focused test discovery caught an unquoted regex literal in the test mock; corrected before executing assertions.
- Full initial runs: Windows 51 passed/5 failed; headless 45 passed/1 failed. Fixed PS5 hashtable measurement incompatibility and assertions for JSON date conversion/floating-point precision. Investigating the native dialog catalog completion path.
- Native second pass improved to 55 passed/1 failed. The remaining catalog test built a loopback URL without the separator slash; corrected the fixture. Added source/catalog fingerprints and snapshot-consistency checks, and made user requests preempt automatic discovery.
- Native Windows regression now passes 60/60; headless passes 50/50 with ten UI tests excluded. Added one further native full-comparison check for failing candidates and disabled adoption. Live discovery succeeded for Anthropic (14 IDs) and OpenAI (139 IDs); independent-role desktop and bounded comparisons are running.
- Live answer comparison completed all 36 paired tasks/73 requests; live refinement completed all 36 paired tasks/181 requests. Both conservatively kept the current defaults. Costs were about $0.05225 and $0.33233 respectively. Original owner settings were not changed.
- Final budget review found inherited HTTP handling refunded all server errors. Tightened it to retain possible spending for server/time-out failures; explicit pre-generation rejections still release reservations. Archived the exact pre-fix live core/engine/corpus under build/model-live/source; final regression will cover this additional failure-path fix.
- Final pre-package checks passed: native 63/63 and headless 51/51 (twelve UI cases excluded). Actual positive/negative dialog adoption and rollback, live independent routing and restart all passed. Optional task definition passed WhatIf only. Updating documentation/screenshots and building rc.2.
- Completed the evidence fields in comparison calls (request IDs and input/output token counts) and ensured missing usage remains unknown even for a zero-price configuration. Final native HTTP-backed adoption test checks the recorded fields. Rebuilding with these final audit additions.
- Final package passed its full 63-test build and startup smoke; packaged activation/restart passed. Compiled-dialog UI Automation initially searched desktop children only and missed owned dialogs; extending the test harness to search within the owned main window before drawing a product conclusion.
- Final compiled Models dialog passed UI Automation after correcting the owned-window search in the test harness. Paid evaluation was off; test process closed. Packaged activation/restart passed.
- Documentation-only handoff refresh retained the tested EXE/code/data, then regenerated manifest/checksums/ZIP. Audited 27 manifest files and 29 ZIP entries against source and checked owner settings/credential hygiene.
- All coding/roadmap phases complete. Final evidence: build/model-management-verification.md and .json. Stable/public release acceptance remains separate and open.

## Current-product web demos (2026-10-18)
- Audited the live demo, current validation record, model policy and portfolio integration/asset rules.
- Recorded design and coding phases before implementation. Building one shared offline demonstration with full-page and compact portfolio presentations.
- Saved-key correction: direct Windows CurrentUser DPAPI preserves legacy ciphertext. Bidirectional compatibility, malformed input and a fresh host without security cmdlets pass. The full rebuilt candidate passes 66 native tests and packaged startup. Both discovery-dialog regressions now load saved encrypted keys.
- Portfolio integration passes all four content validators with zero errors (existing warnings retained). ESLint and TypeScript pass; Next.js static export generates all 19 pages including the new project page.
- Chromium verifies all scenarios, revisions, original comparison, answer-source selection, reset, both model roles and blocked adoption. Mobile views have no horizontal overflow and honor reduced motion. Real screenshots inspected; corrected missing whitespace around responsive line breaks.

- Published two scoped commits through the authenticated GitHub connector: saved-key correction d491777, current-product Pages demo 0e9b3f1. Pages build/deploy succeeded; live overview/demo/CSS/JS exactly match local hashes. Synced local HEAD/index only after proving all published paths matched and no staged work existed; all working files preserved.
- Actual rebuilt EXE UI Automation passed Load models (14 Anthropic IDs) and Check available models now using an existing encrypted credential. Zero prompts sent; owner settings unchanged; encrypted fixture copies removed.
- Final portfolio static export and validators pass. Actual project page, evidence image and embedded comparison passed Chromium checks; the compact desktop action controls fit inside 640px. Portfolio changes are local and have not been deployed.
- Final public Chromium checks passed the deployed refinement/review/answer/model workflow, reset and mobile layout with no script errors or provider requests. Hosted Pages deployment succeeded; Windows CI was still running at handoff (local native 66/66 and packaged startup already passed).

## Build-tool discovery correction
- Added explicit compatible-module resolution across the current host and both redirected Documents module folders. Kept ps2exe 1.0.17 pinned; Pester is passed by resolved manifest path into the test runspace.
- Updated prerequisite/error instructions to invoke Install-Module under powershell.exe, so PowerShell 7 users install into the intended host location. No automatic installations or persistent environment changes.
- Build-tool fix verified: three focused discovery tests passed; complete native build under a clean Windows PowerShell module path passed 69/69 tests and packaged startup. Existing ps2exe 1.0.17 and Pester 5.7.1 were used from the PowerShell 7 user directory. Regenerated EXE/ZIP; process module path unchanged. Evidence: build/build-tool-discovery-verification.json/.txt. Changes remain local; no commit/push performed for this correction.
