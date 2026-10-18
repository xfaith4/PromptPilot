# Model discovery, evaluation and defaults

## Coding plan

1. Extend settings to schema 3 and sessions to schema 2. Keep the legacy Model
   field as a compatibility view, add independent refinement/answer IDs and pins,
   and seed both from older saved selections. Explicit old selections migrate as
   pinned. Restored sessions keep their own models.
2. Add a UI-independent model-management module. Persist provider catalogs with
   first-seen times, capabilities when supplied, last success and retry times.
   Discovery checks the selected provider weekly while the app is open; failures
   retain the last successful catalog and back off for a day.
3. Add declarative synthetic checks for at least twelve tasks per role and run
   three paired repetitions. For refinement, compare downstream answers using a
   fixed answer model and include an original-request control. Keep actual outputs,
   checks, latency, token usage, configured prices and version fingerprints.
4. Reserve evaluation spending on disk before dispatching every request. A file
   lock serialises evaluations. Interrupted/unknown usage retains its reservation.
   Enforce both the run ceiling and UTC calendar-month ceiling. Never use customer
   session prompts as benchmark material.
5. Recommend only complete, repeated evidence with no candidate critical failures
   or regression against the baseline/control. Require better measured task success
   with no more than a 25% cost increase, or equivalent success with at least 15% lower cost or 20% lower median latency
   without a cost increase. These are product policy thresholds, not statistical
   confidence claims. Small differences leave the current default in place.
6. Add a native dialog for discovery, prices, paid evaluation opt-in, evidence,
   acceptance, pins and rollback. Adoption applies to future sessions only, stays
   within the selected provider and records an audit entry.
7. Test migrations, real routing, failed discovery, partial/unknown spending,
   cancellation, stale recommendations, pinning, adoption, rollback and native UI.
   Package all modules, corpus and optional discovery-only command-line tools.

## Initial policy

Automatic discovery is enabled. Paid evaluations are disabled until explicitly
enabled. The initial per-run evaluation ceiling is $1 and the initial monthly
ceiling is $5, both configurable. Discovery sends no generation prompts. There is
no automatic promotion. A compatibility probe and all baseline/control requests
count against the evaluation budget. Controlled requests use a 1,024 output-token
cap (256 for the probe); results apply to that recorded configuration.

Model IDs and release order do not establish quality. New IDs with unknown prices
need explicit custom rates or an updated sourced pricing catalog. A successful
model listing does not prove generation support. Unsupported API/parameter shapes
are reported as blocked, requiring a compatible application update.

## Decision evidence

Deterministic checks evaluate specified constraints and known synthetic answers.
They do not measure every aspect of usefulness. Exact-output cases include
capitalization and punctuation; inspect failures before drawing broad conclusions. Candidate models never grade
their own outputs. The initial implementation uses no model-based judge. Wider
real-work usefulness remains a beta acceptance gate.

Recommendations expire after seven days and become invalid when the baseline,
fixed answer model, pricing, evaluation corpus, refinement prompt or engine
changes. Acceptance also requires a successful current catalog containing the
candidate and a matching provider/role. Aliases can change server-side; resolved
model IDs are recorded when returned, and fresh evaluation is required after
expiry. A benchmark is evidence about the recorded account, configuration and
tasks, not every model or future version.

Catalogs, reports and monthly accounting are stored under the user-data `models`
directory. Reports contain synthetic prompts/outputs, not API keys. Original
settings and session documents retain the app's atomic replacement and backups.
Closed-app discovery is optional through the supplied CLI/scheduled-task installer;
the app does not register tasks or enable paid automation during installation.

## Use the completed workflow

1. In Providers and API keys, choose Refine or Answer and save a model for that
   role. Existing selections migrate as pinned. New sessions use these defaults;
   restored sessions keep their saved choices.
2. Open Models. Check available IDs, choose a role/candidate and review token rates.
   Save explicit custom rates for unknown prices. Pricing changes invalidate prior
   recommendations.
3. Enable paid evaluations, set the per-comparison and monthly ceilings, and save
   preferences. Click Run paid comparison. Baseline/control requests count too.
4. Review Results and defaults, including individual failed task IDs and full
   synthetic evidence. A comparison can finish successfully and still say Keep current.
5. Unpin the intended default explicitly, save preferences and accept a qualifying
   selected recommendation. Existing sessions remain unchanged. Roll back the
   chosen role to undo its latest matching acceptance.

CLI tools are described in the main README. Scheduled checks are optional and
metadata-only. No automatic paid comparison or default adoption is scheduled.
