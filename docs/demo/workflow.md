# Prompt Pilot — Workflow Walkthrough

This document describes the five-step refinement workflow shown in the animated
demo. Every step maps directly to a UI element in the app.

---

## Step 1 — Enter a rough prompt

Open the app and type your unpolished idea into the **Base Prompt** box.
No special format is required. Write it the same way you would describe
the task to a colleague.

**Example:**

```
Write a PowerShell script to monitor Windows services.
If any service in a defined list is stopped, restart it
automatically and email me an alert. Log all restarts.
```

> **Tip:** The rougher the starting prompt, the more the refinement adds value.
> A single sentence is enough to begin.

---

## Step 2 — Set goals and project context

Use the supporting fields to shape the refinement pass:

| Field | Purpose |
|---|---|
| **Refinement Goals** | What makes a good result? Style, structure, tone, constraints. |
| **Project Context** | Runtime environment, language version, platform, team conventions. |
| **File (optional)** | Reference a local file path to include its name in the prompt. |

**Example goals:**

```
- Production-ready, with structured error handling
- Comment blocks for each logical section
- Built-in cmdlets only; no external modules
```

**Example context:**

```
Windows Server 2019, PowerShell 5.1
```

> **Tip:** Save a filled-in set of goals and context as a **preset** so you can
> reload them for the next project without retyping.

---

## Step 3 — Configure and run

Adjust the run settings in the control row directly below the input fields:

- **Iterations** — how many refinement passes the AI makes (default: 3).
  More iterations produce a more polished result at a higher token cost.
- **Model** — the model name sent to the provider. You can override the default
  stored in Settings without reopening the dialog.
- **Mode selector** — choose **Refine Prompt** (default) to improve the wording,
  or **Answer Task** to send the current prompt directly for execution.

Click **Run Refinement**. The status bar immediately shows:

```
Running... [Cancel]   Provider: OpenAI | gpt-5-mini   Tokens: … | Cost: …
```

> **Tip:** Click **Cancel** in the status bar to stop after the current API call
> completes, or click **Accept Current Draft** to promote the latest iteration
> result without waiting for all passes to finish.

---

## Step 4 — Review the structured output

When the run completes the three output areas populate:

### Refined Prompt (final)

The final structured prompt, formatted with clear sections:

```
Role: You are a senior Windows systems engineer.

Task: Write a production-ready PowerShell 5.1 script that monitors
and auto-heals Windows services on Windows Server 2019.

Requirements:
• Check each service against a configurable list variable
• Restart stopped services; log each event to the Windows Event Log
• Send an email alert via Send-MailMessage on each auto-restart
• Include structured comment blocks per section; no external modules

Constraints:
• Target PowerShell 5.1 on Windows Server 2019 only
• Exit with code 1 if any service restart fails; code 0 on clean run
```

### Iteration History

A compact log of what each pass changed or added:

```
[1/3]  Clarified role; expanded scope and primary deliverable
[2/3]  Structured requirements with bullet-point constraints
[3/3]  Added exit-code contract; tightened PS 5.1 constraint
```

### Activity Log

Timestamped trace of the run, useful for cost tracking and debugging:

```
[12:04:01] Starting refinement run (3 iterations, gpt-5-mini, OpenAI)…
[12:04:05] Iteration 1/3 complete.
[12:04:09] Iteration 2/3 complete.
[12:04:13] Iteration 3/3 — refinement complete.
```

### Status bar

After the run the status bar reports the total token usage and estimated cost
for the session:

```
Ready.  |  Provider: OpenAI | gpt-5-mini  |  Tokens: 1,842 | Cost: $0.0003
```

---

## Step 5 — Use the result

You have four options once the structured prompt is ready:

| Action | How |
|---|---|
| **Copy to clipboard** | Click **Copy Final Prompt** — paste into any AI chat, IDE extension, or API call. |
| **Save as preset** | Click **Save Preset** to write the current goals, context, model, and iteration count to a JSON file for reuse. |
| **Run it directly** | Click **Use this Prompt** (next to the mode selector) to promote the refined prompt, switch to **Answer Task** mode, and execute in the same session. |
| **Start a new run** | Edit the Base Prompt and click **Run Refinement** again — the output areas update in place. |

---

## Provider configuration

Open **Settings → Configure API Key...** to:

- Switch the active provider (OpenAI / Anthropic / GitHub Copilot)
- Update the model name and per-token pricing for cost estimates
- Save an encrypted key for the current Windows user profile,
  or enter a session-only key that lives only in memory

Prompt Pilot resolves credentials in this priority order:

1. Session key entered via Settings this run
2. Key saved in `%AppData%\Prompt Pilot\settings.json`
3. Provider environment variable (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.)
4. Runtime prompt for a session-only key (if none of the above are set)

---

## File logging

Check **Log to file** in the status bar to append every activity log entry to a
`.log` file of your choice. Useful for tracking token costs across sessions or
auditing which prompts were refined and when.

---

## Key limits to be aware of

| Limit | Detail |
|---|---|
| Platform | Windows only — WPF is required. |
| File input | References a local path by name; does **not** upload or read file contents. |
| Portable build | Requires `ps2exe` on Windows — see `tools/Build-PortableExe.ps1`. |
