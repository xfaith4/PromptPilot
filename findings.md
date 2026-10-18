# Findings

- The screenshot shows Anthropic selected and the configured model `anthropic.claude-opus-5-5` in the activity log, followed by HTTP 404 during refinement. An initial visual reading of the model version was corrected by inspecting saved settings.
- The working tree has many modified files, but ignoring end-of-line whitespace leaves only README content changes. The application and XAML local changes are line-ending conversions.
- Existing logging is optional, requires a save-file dialog, and returns before writing to disk when the UI log control is absent. HTTP errors currently omit provider response details.
- No applicable AGENTS.md was found in the project or its ancestor directories.
- The memory quick pass found no Prompt Pilot context.
- Read only the active provider and model fields from `/mnt/c/Users/benfu/AppData/Roaming/Prompt Pilot/settings.json`: active provider Anthropic; saved model `anthropic.claude-opus-5-5`. No keys were displayed or modified.
- Anthropic's official Opus 5.5 reference lists `claude-opus-5-5` for the direct Claude API and `anthropic.claude-opus-5-5` for Amazon Bedrock: https://platform.claude.com/docs/en/models/opus-5-5/overview . The app sends the saved model unchanged to `https://api.anthropic.com/v1/messages`, so its provider/model pairing is incompatible.
- Commit `020b816` (August 14, 2026) changes background cancellation/completion only. `d96f908` added Answer background execution on May 14; `994f21c` added persisted model/pricing settings on May 13. None introduces the configured Bedrock model ID. The refinement endpoint and payload model behavior were untouched by the latest application commit.
- Anthropic documents the existing POST `/v1/messages` endpoint, JSON error fields and `request-id`: https://platform.claude.com/docs/en/api/messages/create and https://platform.claude.com/docs/en/api/errors . The original failing response body is unavailable; subsequent live model-metadata verification confirms the configuration mismatch below.
- Windows PowerShell 5.1 also could not parse the existing UTF-8 source without a BOM (63 errors reproduced against both HEAD and edited source). Adding the BOM resolves this independent startup compatibility issue. It does not explain an HTTP 404 from an already-running app.
- Disk logs use a unique per-session file under the source/executable `logs` directory. Logging works before UI controls exist; known saved/session/environment keys are redacted, and HTTP diagnostics retain only error fields rather than raw payloads.
- Prefix correction is narrow: `anthropic.claude-opus-5-5` becomes `claude-opus-5-5`, preserving the model version. Regional/dated Bedrock InvokeModel IDs are rejected with actionable guidance. The external saved settings file is not rewritten by loading.

## Confirmed live cause

Using the saved Anthropic credential, made two read-only GET requests to `https://api.anthropic.com/v1/models/{model_id}`:

| Model ID | HTTP result | Returned model |
| --- | --- | --- |
| `anthropic.claude-opus-5-5` (saved configuration) | 404 | unavailable |
| `claude-opus-5-5` (corrected direct API ID) | 200 | `claude-opus-5-5` |

Evidence: [model verification log](logs/Anthropic_model_verification_20261017_013718.log).
The credential was decrypted only in process memory and was not printed or persisted.
No prompts were sent and no generation was requested. Model metadata access is verified;
a full live Refine/Answer response remains untested.

## Validation

- Native Windows PowerShell 5.1: all 29 tests passed, including actual WPF startup with temporary settings and creation of logs in this project, model correction, log toggling, 404 diagnostics, key redaction, 503 retry and existing cancellation/UI checks.
- Linux PowerShell 7.6: 20 headless tests passed (Windows UI checks excluded explicitly).
- App/XAML CRLF line endings preserved; UTF-8 BOM added to the application script for Windows PowerShell 5.1 compatibility. Unrelated local changes preserved.

## Product completion baseline
- User authorized closing the assessed product gaps, including implementation, validation and packaging.
- Existing app is one WPF/PowerShell entrypoint with duplicate synchronous/background provider paths. Refinement blocks the UI while a request runs; Answer uses a background runspace.
- Presets omit the base prompt, provider and results. File input passes only a path. Provider/model/pricing are manually entered. No tracked CI workflow, license file, release acceptance checklist or prompt-quality corpus exists.
- Packaging defaults to version 0.2.0; ROADMAP.md declares 1.0.0 complete using placeholder badges and prioritizes collaboration/roles over the current desktop workflow. It will be replaced with grounded release gates.

- Native Windows has saved Anthropic credentials and OpenAI/GitHub environment credentials (availability only, values never displayed), Pester 5.7.1 and ps2exe 1.0.17. Live tests and a local EXE build are feasible.
- Existing saved pricing is the same legacy default for all providers. Migration must not treat those defaults as trustworthy model pricing.
- Official references checked: OpenAI model/Chat Completions documentation, Anthropic Opus/Sonnet 5.5 references, GitHub Models documentation and source. Model pricing provenance will be stored with the catalog.
- Architecture: UI-independent shared core for HTTP, budgets, prompt construction, sessions and comparisons; cancellable background workflows and a WPF interface. Portable packaging must include the core/catalog.
- Saved existing source/tests/docs under ignored build/product-baseline before product changes. Replaced placeholder ROADMAP.md with implementation and external acceptance gates.
- The initial roadmap patch used incompatible delete/add operations on the same path and was rejected without changes; corrected by writing one replacement.

## Product validation progress
- All 34 initial product tests passed under native Windows PowerShell 5.1, including actual Refine/Use-prompt/Cancel buttons, nonblocking worker startup and full-session restart recovery.
- Live synthetic Refine -> Answer generation passed for saved Anthropic `claude-opus-5-5` and OpenAI `gpt-5-mini`, including exactly two numbered acceptance criteria. This is generation evidence, beyond model metadata.
- Three synthetic live prompt cases (CSV criteria, Python contract, read-only investigation) passed constraint checks after correcting a PS5 scalar-array import bug in the test corpus loader. Recomputed checks on recorded outputs without buying duplicate generations. Actual outputs were reviewed for scope and intent preservation.
- The first bounded live run recorded about $0.05923 estimated generation cost. No real user prompt was sent.
- GitHub Models discovery returned HTTP 200 with `text/plain` body `OK` from the documented catalog endpoint, including with JSON/version headers. Generation was not attempted with unverified rates. GitHub remains labeled preview; external live acceptance is open.
- Added a fresh-profile source startup screenshot, reviewed visually. The packaged artifact is being built and will require its own smoke.
- Nested invocation of powershell.exe returned without output or an exit code in this host. The build now invokes Pester in an explicit STA runspace and validates its counts/errors directly.

## Final release-candidate findings
- Native Windows 5.1 suite passed all 41 tests. Linux 7.6 passed 33 headless tests with eight WPF tests excluded.
- Actual desktop generation and full-session restart passed against the final source/core hashes for Anthropic Opus and the saved OpenAI model. Both new default models also passed live core Refine/Answer acceptance.
- Seven recorded constraint cases passed; manual review improved preservation of permissions and conciseness. This remains bounded evidence, not a claim that every refinement improves downstream work.
- A final review found that close-time autosave errors could allow loss of unsaved changes. Added a default-No discard prompt and a real WPF regression that keeps the window and prompt intact after a simulated save failure.
- The final unsigned portable candidate passed compiled startup and packaged activation/restart. Verified 17 manifest file hashes and 19 ZIP entries against their packaged contents, with no runtime/private files included.
- Current verification and artifact hashes are recorded in `build/product-verification.json`; external acceptance gates remain unchecked in ROADMAP.md.
