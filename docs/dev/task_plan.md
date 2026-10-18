# Prompt Pilot product completion

## Objective
Deliver a dependable Windows desktop workflow for provider setup, prompt refinement,
revision review, answers, recovery and portable distribution. Preserve the original
request and user data, and state precisely what has been verified.

## Completed work
1. Investigate recent changes and diagnose the Anthropic HTTP 404. **Complete.**
2. Implement automatic project-local disk logs and safe provider diagnostics. **Complete.**
3. Validate logging/model correction and record the initial metadata-only boundary. **Complete.**
4. Assess product gaps and replace the placeholder roadmap with acceptance gates. **Complete.**
5. Implement shared HTTP/model discovery, generation tests, pricing and spend controls. **Complete.**
6. Make Refine and Answer asynchronous with progress, retries and cancellation. **Complete.**
7. Deliver full sessions/recovery/export, file preview, revisions/comparison and polished UI. **Complete.**
8. Run representative constraint evaluations and bounded live provider acceptance. **Complete for the recorded Anthropic/OpenAI scope.**
9. Deliver the launcher, portable EXE/ZIP, Windows CI configuration and product documentation. **Complete locally; hosted CI remains an external gate.**
10. Run final regression, actual desktop generation, packaged launch/restart and artifact review. **Complete.**

## Final evidence
- Windows PowerShell 5.1: **41 passed, 0 failed**. Linux PowerShell 7.6: **33 passed**, eight UI tests excluded.
- Actual final-source desktop Refine -> Answer -> reopen passed for Anthropic Opus and the saved OpenAI model; new default models passed live core acceptance.
- Seven recorded prompt cases passed constraint checks and manual review; usefulness across real users remains unverified.
- Compiled app startup, packaged activation/restart, ZIP contents, manifest and all checksums passed.
- Artifact: `dist/Prompt_Pilot-1.0.0-rc.1-win-x64.zip`, unsigned.
- Detailed evidence and exact hashes: `build/product-verification.json` and `build/product-verification.md`.

## Open external release gates
GitHub Models catalog and priced generation; hosted GitHub CI after a reviewed push;
clean Windows installation/upgrade; small beta cohort; trusted signing and stable publication.
These are tracked as incomplete in ROADMAP.md. A local release candidate is not stable-release acceptance.

## Constraints observed
Preserved unrelated dirty-worktree changes and Windows source line endings/BOM.
Used isolated data and synthetic live prompts within bounded budgets. Original owner
settings were not changed. Removed encrypted credential copies from owned test fixtures.
No commit, push, deployment or public release was performed.


# Model discovery and role-specific recommendations - active work (2026-10-18)

## Goal
Complete the agreed discover -> qualify -> compare -> recommend -> accept/rollback
workflow for separate refinement and answer defaults, preserving manual pins and saved sessions.

## Coding phases
11. Inspect current changes and document schemas, evaluation policy and acceptance gates. **Complete.**
12. Add settings/session migration and independent per-provider Refine/Answer choices. **Complete.**
13. Add persistent catalog discovery, weekly open-app checks, failure backoff and optional closed-app checker tooling. **Complete.**
14. Build a repeated, budgeted comparison runner with an expanded synthetic corpus, fixed downstream answer model and crash-safe monthly accounting. **Complete.**
15. Add explainable recommendation gates, provenance/freshness checks, explicit adoption, pinning and rollback. **Complete.**
16. Integrate a native model-management window, progress/cancellation and routing feedback. **Complete.**
17. Test migrations, discovery failures, spend/cancellation, role selection, stale recommendations and real WPF workflows; run bounded live acceptance where configured. **Complete within the documented proof boundaries.**
18. Update docs, rebuild the portable candidate and record current evidence and external limits. **Complete.**

## Design constraints
- One provider per session; switching provider remains explicit. Defaults apply to new sessions, not restored work.
- Automatic discovery enabled, paid benchmarking disabled initially; recommendations require acceptance.
- Unknown pricing or incompatible APIs block evaluation. No guess from model names or release order.
- At least 12 cases per role and three paired repetitions for recommendation eligibility. Use deterministic checks, preserve actual outputs and report limited coverage.
- Refinement comparisons include downstream answers under a fixed answer model and an original-prompt control.
- Reserve spend on disk before every evaluation request; serialise evaluations and retain uncertain reservations after interruption.
- Preserve all pre-existing changes, UTF-8 BOM/CRLF compatibility, credentials and owner settings. No commit/push/publication.

## Verification targets
Migration round trips; independent routing; pinned/active-session preservation; cached discovery/backoff;
unknown prices, partial/cancelled/crashed evaluation accounting; repeatable candidate selection;
stale evidence rejection; acceptance/rollback; real native dialog and packaged resource loading.

## Model-management execution notes
- First escalated headless test launch: automatic approval review timed out before its deadline; no test process was started. Will retry once after integrating the feature; no unsafe-action conclusion follows from a review timeout.

## Model-management final handoff
- All new coding phases complete. Version 1.0.0-rc.2 passes 63 native and 51 headless tests.
- Compiled model dialog, packaged activation/restart and final ZIP/hash audit passed.
- Detailed proof, exact current source hashes and the full-live-versus-final-preflight boundary are recorded in build/model-management-verification.md and .json.
- External public-release gates remain open in ROADMAP.md. No owner default, scheduled task, commit or public release was changed.

# Current-product web demos (2026-10-18)

19. Audit the live Pages demo, current product evidence and portfolio contracts. **Complete.**
20. Replace the historical demo with an accessible, responsive, self-contained workflow simulation and current product landing page. **Complete.**
21. Integrate a compact edition into the portfolio with dated evidence and intake records. **Complete locally.**
22. Verify browser interactions, responsive layouts, portfolio validation/build and publish the scoped Pages update where authenticated access permits. **Complete: Pages deployment succeeded; public HTML/CSS/JS/overview match the verified files. Portfolio integration remains local, not deployed.**

## Presentation design
- Visual thesis: a quiet navy editorial frame around a warm, legible working surface; precise blue accents, generous typography and actual desktop captures as proof.
- Content: short product proposition -> interactive Refine / Review / Answer workspace -> model decision explorer -> actual screenshots and dated release boundaries -> source/documentation CTA.
- Interaction thesis: short entrance reveal; state transitions for workflow steps; deliberate hover/focus feedback. Respect reduced motion. No pretend streaming, API calls, or paid actions.
- Browser examples are curated synthetic illustrations, labeled throughout. Model comparison figures come from recorded live synthetic tests with their exact-source limitation. Native Windows remains the actual product.
- Portfolio edition uses the same demo assets, relative local resources, no backend/auth/external resources, and a compact embed layout. Preserve existing work in both checkouts.

23. Fix the saved-key module-loading failure reported during demo work; reproduce in the packaged host, test both discovery entry points, rebuild and update current evidence. **Complete: 66 native tests, packaged startup and both actual EXE discovery buttons passed.**

24. Repair build-tool discovery across Windows PowerShell and PowerShell 7 module folders without upgrading the pinned compiler. Resolve Pester in the same clean host, clarify setup/error instructions, test isolated discovery and regenerate the EXE. **Complete: clean Windows PowerShell found zero modules via ordinary lookup, resolved the installed 1.0.17/Pester manifests, passed 69 native tests and packaged startup; module path unchanged.**
