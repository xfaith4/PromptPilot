# Privacy and local data

Prompt Pilot sends the request and user-supplied context only to the selected
provider's API. A selected file is included only when the inclusion checkbox is
checked; the preview shows its exact excerpt. Prompts may contain confidential
information, so choose a provider/account appropriate for your data.

There is no telemetry, background analytics, remote session sync or automatic
upload of local documents. Available-model metadata is checked weekly for the selected provider while the
app is open, unless disabled; manual checks are also available. Discovery sends
no prompt. A connection test is a short paid generation, clearly labeled in the
provider dialog. Paid model comparisons require explicit opt-in and budgets.
They use bundled synthetic prompts, never session prompts, and include baseline,
candidate and downstream/control requests. No default is adopted automatically.

## Storage

Settings and sessions live in `%AppData%\Prompt Pilot` unless an explicit data
directory is passed on the command line. Saved API keys use Windows user
protection through `ConvertFrom-SecureString`; another Windows user cannot
normally decrypt them. Session-only keys stay in process memory. Environment
credentials are read from the provider's documented variables and never persisted
by the app. Forgetting a key does not remove a credential from your environment.

Session JSON and Markdown exports contain the original request, context,
selected file path, revisions and answer. They are ordinary local documents,
not encrypted. Credential fields are excluded from the persisted session schema.
If you paste a secret into a prompt or model output, that text is part of your
document; the app cannot infer which arbitrary document text is confidential.

Autosave is enabled by default and can be turned off. Settings and sessions are
written atomically and retain a `.bak` previous copy. Deleting a session also
requires deleting its `.bak` copy if you want to remove both. There is no silent
session deletion or retention policy.

## Diagnostics

Logs live in the app's `logs` folder, falling back to a logs folder in user data
when necessary. They contain timestamps, provider/model, request status, request
IDs and sanitized provider error fields. Known runtime API keys are redacted.
Provider error text may contain details supplied by the provider. Raw request
bodies, generated answers and included file contents are not logged deliberately.

Managed `Prompt_Pilot_*.log` files rotate at 5 MB and are retained for up to 30
days, with a maximum of 100 files. The app does not delete unrelated log files.

Acceptance tools write synthetic prompts and responses to an explicitly selected
local output directory. Those artifacts are separate from normal diagnostic logs.
Review any report before sharing it. No diagnostic or acceptance report is uploaded
automatically.

## Model catalogs and comparisons

The user-data `models` directory contains cached model metadata, synthetic
comparison reports and an evaluation-budget ledger. Reports contain actual synthetic
prompts/outputs, token usage, request IDs, latency, configured prices and model/code
fingerprints. They exclude API keys. Defaults and acceptance/rollback history are
stored in settings; saved sessions retain their own refinement and answer IDs.

Evaluation reservations persist before dispatch and after uncertain interruptions.
Do not delete/reset the budget ledger to reconcile a provider bill; the amounts are
local estimates. The app serialises evaluation runs but does not control spending
from other tools/accounts. An optional explicitly installed Windows task performs
metadata discovery only, never paid comparison or default adoption.
