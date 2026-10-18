# Prompt Pilot workflow

Double-click **Start Prompt Pilot.cmd** on Windows. The launcher selects the
packaged app when available and requests an orderly restart of an existing
instance. Your original request remains separate from the editable draft.

1. Open **Settings > Providers and API keys**. Choose OpenAI, Anthropic or the
   GitHub Models preview. Load model IDs or enter a direct API ID, provide a key,
   and review the selected model's token rates. Unknown prices require explicit
   custom rates. **Test a short request** verifies generation and uses API credits.
2. Write the task and choose Coding task, Investigation or General task. Add
   goals and context that matter to your request. Profiles preserve your scope,
   permissions and constraints; a particular language or output structure is
   not assumed.
3. Optionally choose a supported text file and check inclusion. Review its
   visible excerpt. Files are limited to 256 KB; at most 20,000 characters are
   included, with a truncation notice when needed. Unchecked files are not sent.
4. Set 1-5 iterations (default 2), output tokens and the USD run budget. Click
   **Refine prompt**. The UI stays responsive. **Cancel** stops an active request;
   **Keep draft** retains the latest completed revision. Completed revisions
   survive a later request failure or cancellation.
5. Review the draft, **Compare** changes with the original, or select a revision.
   Edit or copy the draft. Refinement does not authorize additional work or
   guarantee that more iterations improve an already-clear request.
6. Choose **Use prompt to answer**, or select Answer mode and explicitly choose
   Original or Draft. Inspect the answer and any output-limit notice.
7. Autosave restores the latest session after restart. **Save as** creates a
   portable session JSON; **Export Markdown** creates a readable document with
   the original, revisions and answer. If saving fails on close, keep the window
   open and save or export elsewhere. Ctrl+N, Ctrl+O and Ctrl+S are available.

Settings and sessions live under `%AppData%\Prompt Pilot`. Saved keys use
Windows user protection and are excluded from session documents. Prompts and
answers in sessions/exports are ordinary local document text. Diagnostic logs
are written to `logs/` beside the app, with a user-data fallback, credential
redaction and managed retention. Use the activity log's request ID when reporting
a provider error; review all shared documents for private content.

See [the main guide](../README.md) for exact limits and commands,
[the validation record](VALIDATION.md) for live provider evidence, and
[the roadmap](../ROADMAP.md) for the remaining release gates.
