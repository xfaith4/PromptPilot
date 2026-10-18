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

## 5. Model discovery and independent defaults (active)

- [x] Coding plan and documented schemas/decision policy.
- [x] Independent refinement/answer defaults, migration and explicit pins; preserve restored sessions.
- [x] Cached provider discovery, weekly open-app checks and actionable compatibility/pricing status.
- [x] Optional discovery-only CLI/scheduled-task tooling for closed-app checks.
- [x] Expanded synthetic cases, repeated baseline/candidate comparisons and fixed downstream evaluation.
- [x] Explicit paid-evaluation opt-in, per-run/monthly ceilings and persistent reservations before dispatch.
- [x] Explainable recommendations with coverage, cost/latency, freshness and provenance gates.
- [x] Explicit acceptance and rollback affecting future sessions, with an audit trail.
- [x] Native model-management UI with progress, cancellation and evidence inspection.
- [x] Automated/native/live validation, release documentation and rebuilt portable candidate.


## 6. Current-product presentation and saved-key correction

- [x] Replace the old Pages concept with a responsive, accessible offline workflow illustration and current product overview.
- [x] Curated synthetic scenarios, revision comparison, answer-source choice and dated recorded model decisions; actual desktop capture and release limits.
- [x] Integrate a self-contained portfolio demo, project/intake/artifact records and explicit Release candidate status.
- [x] Validate browser workflows/mobile layout, portfolio content/lint/types/static build.
- [x] Remove security-module autoload dependency from saved-key protection; preserve existing DPAPI format.
- [x] 66 native tests and rebuilt packaged startup; both real EXE discovery buttons passed with an existing encrypted Anthropic key, metadata only.
- [ ] Publish and verify the updated Pages demo.

## External release acceptance

- [ ] Resolve GitHub Models live catalog response and verify generation with account-appropriate pricing.
- [ ] Run the new Windows CI workflow on GitHub after the reviewed changes are pushed.
- [ ] Clean Windows machine installation/launch and upgrade acceptance.
- [ ] Small beta cohort completes the workflow and confirms the revisions are useful.
- [ ] Trusted publisher signing and distribution channel chosen before broad public distribution.
- [ ] Publish a stable release only after reviewing the evidence and remaining limitations.

## Later, when justified by user feedback

More templates, collaboration, account roles and additional platforms.
