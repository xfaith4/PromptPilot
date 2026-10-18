# Prompt Pilot release roadmap

Target: **1.0.0 release candidate** for a dependable Windows desktop prompt workflow.
Stable release status stays open until the acceptance evidence below exists.

## Completed foundation
- [x] Automatic local session logs with credential redaction.
- [x] Diagnose the Anthropic 404 with live metadata evidence and correct the Bedrock prefix.
- [x] Native Windows startup/XAML/mock-provider/cancellation regression baseline.

## 1. Provider reliability and spend controls
- [x] One shared request engine for Refine, Answer, model discovery and connection tests.
- [x] Correct GitHub Models identity/endpoints; migrate legacy provider settings.
- [x] Discover models and test a real short generation from provider settings.
- [x] Model-specific, sourced pricing; unknown prices stay unknown.
- [x] Bound iterations/output and enforce a conservative per-run request budget.
- [x] Consistent HTTP errors, transient retries, timeout handling and cancellation.

## 2. Complete desktop workflow
- [x] Refine and Answer run without blocking the UI; preserve completed revisions on cancel/failure.
- [x] Save/recover full sessions and export readable Markdown without credentials.
- [x] Original/revision comparison, selectable history, clear progress and next actions.
- [x] Explicit text-file inclusion with preview, size/encoding limits and accurate status.
- [x] Profiles/examples that preserve user intent without assuming a particular stack.
- [x] Bounded log retention and actionable startup/configuration errors.

## 3. Product validation
- [x] Representative prompt corpus with constraint-preservation checks and recorded live outputs.
- [x] Full Windows automated suite using real core/startup/UI workflow paths.
- [x] Live Anthropic/OpenAI Refine/Answer acceptance; native cancellation/error checks. GitHub live acceptance remains open below.
- [x] Session restart recovery and packaged-EXE smoke under a fresh data directory.
- [x] Explicitly record unavailable providers or account-policy failures; no blanket live-support claim.

## 4. Release engineering
- [x] One-click launcher with single-instance/restart behavior.
- [x] Reproducible portable build with pinned build dependency, manifest and checksums.
- [x] Windows CI workflow for tests/build/packaged smoke is implemented; hosted execution awaits a push.
- [x] Consistent version, changelog, MIT license, privacy/support and release instructions.

## External release acceptance
- [ ] Resolve GitHub Models live catalog response and verify generation with account-appropriate pricing.
- [ ] Run the new Windows CI workflow on GitHub after the reviewed changes are pushed.
- [ ] Clean Windows machine installation/launch and upgrade acceptance.
- [ ] Small beta cohort completes the workflow and confirms the revisions are useful.
- [ ] Trusted publisher signing and distribution channel chosen before broad public distribution.
- [ ] Publish a stable release only after reviewing the evidence and remaining limitations.

## Later, when justified by user feedback
More templates, collaboration, account roles and additional platforms.
