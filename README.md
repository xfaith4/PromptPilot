# OpenAI Refiner

[![PowerShell](https://img.shields.io/badge/PowerShell-7+-blue.svg)](https://learn.microsoft.com/en-us/powershell/)
[![OpenAI](https://img.shields.io/badge/OpenAI-API-green.svg)](https://platform.openai.com/)
[![Excel Tracking](https://img.shields.io/badge/Excel-Session%20Tracking-yellowgreen.svg)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](LICENSE)
[![Contributions welcome](https://img.shields.io/badge/Contributions-Welcome-blue.svg)](#)

**AI-powered prompt refinement tool with token & cost tracking**

---

OpenAI Refiner is a **PowerShell-based interactive refinement tool** for OpenAI prompts.

- Iteratively improves prompts with multiple refinement passes
- Prevents truncation with **dynamic max_token scaling**
- Saves each iteration in **AI-generated session folders**
- Tracks **token usage & estimated costs**
- Logs all sessions into an **Excel summary for long-term cost tracking**
- Detects when further refinements are **not meaningful** and stops early
- Includes a **WPF desktop UI** for click-to-run refinement and execution

It’s designed for **script developers, documentation writers, and anyone refining complex prompts** while keeping costs transparent.

---

## WPF Desktop App (OpenAI_Refiner.Wpf.ps1)

- **Mode toggle**: Refine Prompt vs Answer Task, plus “Use this Prompt” to flow from refinement into execution.
- **Iterations + model controls**: choose pass count and model; optional file path for context.
- **Outputs**: refined prompt, iteration history (with scrollbars), task output pane (Answer mode).
- **Activity log + busy indicator**: shows when work is running; buttons disable during calls; “Clear Log” to reset.
- **Clipboard + file picker**: copy final prompt; browse for files.

Run (Windows, STA required):

```powershell

powershell.exe -NoProfile -sta -File .\OpenAI_Refiner.Wpf.ps1
# or
pwsh -NoProfile -sta -File .\OpenAI_Refiner.Wpf.ps1
```

> Screenshots not included in this repository update; capture the window after launch to document your environment.

## Screenshot / Example Run

Here’s what a typical refinement session looks like:

![OpenAI Refiner Example Screenshot](docs/example-session.png)

- AI-generated folder name
- Iterations saved as `Iteration_X.txt`
- Token + cost tracked automatically
- Session summary logged in Excel

---

## Output Structure

Each session creates:
/Sessions/
20250727_153045_ShortName_GUI/
Iteration_0.txt
Iteration_1.txt
Iteration_2.txt
...
/Logs/
OpenAI_Refiner.log
OpenAI_SessionSummary.xlsx

- **`Iteration_X.txt`** → Prompt + refined response
- **`OpenAI_Refiner.log`** → Timestamped log of all operations
- **`OpenAI_SessionSummary.xlsx`** → Running historical cost + token summary

---

- **`Iteration_X.txt`** → Prompt + refined response
- **`OpenAI_Refiner.log`** → Timestamped log of all operations
- **`OpenAI_SessionSummary.xlsx`** → Running historical cost + token summary

---

## Installation

1. **Install PowerShell 7+ (recommended)**
   Works with Windows PowerShell 5.1, but Core 7+ is preferred.

2. **Install the ImportExcel module (required for Excel tracking)**
   Install-Module ImportExcel -Scope CurrentUser

3. **Set your OpenAI API key**
  $env:OpenAIKey = "your-openai-api-key"

4. **Optional: Set a custom base directory for outputs**
  $env:OpenAI_Refiner_Dir = "C:\AI_Refiner"

5. **Run the script**
  .\OpenAI_Refiner.ps1

***Configuration***

| Setting                   | Description                                      |
| ------------------------- | ------------------------------------------------ |
| `DefaultModel`            | OpenAI model (default: `gpt-4.1-mini`)           |
| `DefaultMaxTokens`        | Base token limit (auto-scales dynamically)       |
| `DefaultTemperature`      | Controls creativity vs. precision                |
| `RefinementIterations`    | Number of refinement passes                      |
| `FolderNameModel`         | Cheap model for AI folder naming (`gpt-4o-mini`) |
| `SessionSummaryFile`      | Excel file for cost tracking                     |
| `RetryCount`              | API retry attempts                               |
| `RetryDelaySeconds`       | Delay between retries                            |
| `RefinementGoalsTemplate` | Default refinement goals if user skips           |

***Example Run***
How can I assist you today? (type 'exit' to quit)
> Generate a PowerShell script that executes an Example Run in a GUI

AI folder name: ExampleRun_GUI
Session outputs will be saved under:
C:\AI_Refiner\Sessions\20250727_153045_ExampleRun_GUI

Enter refinement goals (or press Enter to skip):
> [Press Enter to use defaults]

[2025-07-27 15:30:47] [INFO] Invoking OpenAI API with prompt length: 350 tokens
[2025-07-27 15:30:48] [SUCCESS] Initial GPT Response saved as Iteration_0.txt
[2025-07-27 15:30:55] [INFO] Refinement #1 complete.
...
[2025-07-27 15:31:30] [SUCCESS] Refinement process complete!
[2025-07-27 15:31:30] [SUCCESS] ✅ Total tokens: 4500 (Prompt: 1200 | Completion: 3300)
[2025-07-27 15:31:30] [SUCCESS] ✅ Estimated session cost: $0.024 USD

**Cost Tracking**
Each session logs:
Prompt tokens
Completion tokens
Total tokens
Estimated session cost

It automatically appends a record into:

OpenAI_SessionSummary.xlsx
Example Excel Output:

Date SessionFolder Model IterationsRun PromptTokens CompletionTokens TotalTokens CostUSD
2025-07-27 15:30 20250727_153045_GenesysLogin_GUI gpt-4.1-mini 5 1200 3300 4500 0.024
2025-07-27 16:10 20250727_161012_PythonHello gpt-4.1-mini 1 300 200 500 0.003

**Roadmap**
 Auto-detect truncation → ask GPT to continue from where it left off

 GUI version (WinForms or WPF) for easier usage

 Batch prompt refinement mode

 Multi-model cost comparisons

 Pull live OpenAI billing usage via API

**Security Notes**
Your OpenAI API key is only read from the environment (env:OpenAIKey) and never written to disk.
Session folders only store your prompts & responses, no API keys or secrets.

**Contributing**
Pull requests welcome!
Improve AI folder naming
Add new output formats
Enhance cost tracking

---

## Testing

- `OpenAI_Refiner.Wpf.ps1`: parsed with `PSParser` (syntax OK). Full UI run not performed here; run on Windows with `-sta` to validate end-to-end.

---

## Ops Telemetry Web Dashboard Prototype

To support the EventLog → PostgreSQL → IIS dashboard initiative, the repository now includes a static web interface that can be hosted on IIS (or any static web server) to visualize operational telemetry sourced from PostgreSQL materialized views.

### Highlights

- **Realtime KPIs** for IIS 5xx spikes, authentication failures, Windows critical events, and router/syslog bursts.
- **Actionable alert drill-down** panel with top offenders, recent timelines, and suggested runbook steps.
- **Chart.js visualizations** (no build system required) rendering 24h trends, burst analysis, and severity heat.
- **Ingest & scheduled task health** table wired for PowerShell-based pipeline monitoring.
- **Auto refresh controls** (manual/interval) ready to be bound to live API endpoints.

### File Layout

```
web/
  index.html              # Dashboard shell to host on IIS (http://localhost:8088/)
  assets/
    css/styles.css        # Glassmorphism-inspired theme and layout rules
    js/app.js             # Fetches dashboard JSON, renders KPIs/charts/tables
    data/mock-metrics.json# Sample payload mirroring expected PostgreSQL API response
```

### Preview Locally

1. Start a lightweight static server from the repository root:

   ```bash
   python -m http.server 8088
   ```

2. Browse to [http://localhost:8088/web/](http://localhost:8088/web/) to view the dashboard against the bundled mock data.

When deploying to IIS via `Provision.ps1`, copy the `web/` directory to the IIS site root (e.g., `C:\inetpub\wwwroot\ops-telemetry`). Configure `/api/metrics` (or similar) endpoints to return the JSON schema used by `assets/data/mock-metrics.json` and adjust `app.js` to point at the live endpoint.

### Wiring to PostgreSQL

- Replace the `fetch('assets/data/mock-metrics.json')` call in `app.js` with your IIS-hosted API endpoint (PHP, PowerShell REST, etc.).
- Each KPI maps to dedicated materialized views (e.g., `rpt.iis_errors_5m`, `rpt.iis_authfailures_15m`). Ensure indexes and partitions align with the JSON payload shape.
- Scheduled PowerShell ingest tasks should write health/status rows into an `ops.ingest_health` table exposed via the same API for the "Ingest & Task Health" grid.

### Next Steps

- Extend `Provision.ps1` to deploy the dashboard assets, configure MIME types, and bind the IIS site to `http://localhost:8088/`.
- Replace the mock JSON with a live API that queries PostgreSQL partitions and materialized views.
- Add CSV export endpoints (`/api/export?metric=iis-5xx`) that stream server-side filtered results for investigations.
- Layer in lightweight authentication (Windows Integrated or OpenID Connect) before exposing the dashboard broadly.

---

## Backend Telemetry Service

The repository now includes an **Express-based backend (`server/app.js`)** that binds the dashboard to live telemetry sources:

- Polls **Windows Event Logs** (via PowerShell) for Critical/Error/Warning activity.
- Tails **IIS W3C logs** for 5xx spikes and authentication failures.
- Listens for **router/syslog** events on UDP port `514` (with automatic fall back to `5514` when elevation is unavailable).
- Emits **Server-Sent Events (SSE)** to keep `web/index.html` updated in real time, and exposes `GET /api/dashboard` + `GET /api/health` for REST access.

### Quick Start

```bash
npm install
MOCK_MODE=1 node server/app.js
```

Visit <http://localhost:3001> to load the dashboard against synthetic mock data. Remove `MOCK_MODE=1` to run against live inputs.

### Environment Variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `PORT` | HTTP port for Express | `3001` |
| `WINDOWS_EVENT_LOGS` | Comma list of Event Logs to poll | `System,Application` |
| `WINDOWS_EVENT_LEVELS` | Event levels (1–5) | `1,2,3` |
| `WINDOWS_EVENT_INTERVAL_MS` | Poll cadence | `45000` |
| `IIS_LOG_ROOT` | Semi-colon delimited IIS log roots | `C:\\inetpub\\logs\\LogFiles` |
| `IIS_POLL_INTERVAL_MS` | IIS tail cadence | `30000` |
| `SYSLOG_PORT` | UDP port for router/syslog intake | `514` |
| `SYSLOG_FALLBACK_PORT` | Non-privileged UDP backup port | `5514` |
| `MOCK_MODE` | Set `1` to enable synthetic telemetry | `0` |

> **Note:** Running on UDP 514 or accessing protected Event Logs may require **elevated privileges**. Execute the service in an elevated PowerShell/Command prompt when binding system ports or accessing restricted logs.

### Production Wiring Checklist

1. **Windows Event Logs** – Ensure PowerShell 7+ is available and the executing identity can run `Get-WinEvent` across the selected logs.
2. **IIS Logs** – Confirm the account has read access to the IIS W3C log directories and that logs are rotated with standard `#Fields` headers.
3. **Router Syslog** – Point routers/firewalls to the host running this service on UDP 514 (or the configured fallback). Firewall rules must allow inbound UDP.
4. **Dashboard Deployment** – Host `web/` behind IIS (or another web server) and reverse-proxy `/api/*` to the Node service, or serve the static assets directly from Express.

With those hooks in place, the dashboard will automatically surface live metrics, realtime alerts, and ingestion health without manual JSON refreshes.
