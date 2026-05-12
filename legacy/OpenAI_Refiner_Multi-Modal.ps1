function OpenAI_Refiner {
    <#
.SYNOPSIS
    OpenAI Interactive Refinement Script with Iteration Export, AI-named Folders, Cost Tracking, and Excel Session Summary

.DESCRIPTION
    Iteratively refines a prompt with OpenAI API.
    - Saves each iteration in a timestamped + AI-named session folder.
    - Tracks token usage and estimated cost.
    - Logs all session metadata into an Excel file for long-term cost tracking.
    - Early stopping detection based on response content
    - Fallback to truncation if AI folder naming fails
    - Configurable refinement goals
    - Retry logic for API calls
    - Logging of all operations
    - Uses a cheaper model for folder naming to save costs.

.PARAMETER OpenAIKey
    The OpenAI API key must be set in the environment variable `OpenAIKey`.

.REQUIRES
    - ImportExcel module (`Install-Module ImportExcel -Scope CurrentUser`)

.AUTHOR
    XFaith / ChatGPT Refined Test
#>

    # ===========================
    # CONFIGURATION SECTION
    # ===========================
    $Config = @{
        OpenAIEndpoint          = "https://api.openai.com/v1/chat/completions"
        ApiKey                  = $env:OPENAI_API_KEY
        BaseExportPath          = $env:OpenAI_Refiner_Dir
        DefaultModel            = "gpt-4.1-mini"
        DefaultMaxTokens        = 4096
        DefaultTemperature      = 0.6
        RefinementIterations    = 5
        RetryCount              = 3
        RetryDelaySeconds       = 5
        SessionSummaryFile      = "OpenAI_SessionSummary.xlsx"  # Excel summary file
        FolderNameModel         = "gpt-4o-mini"                # Cheaper model for folder naming
        RefinementGoalsTemplate = @"
Refine this response further by:
1. Expanding with more useful details or context.
2. Improving clarity and readability.
3. Suggesting potential next steps or related insights.
4. If it's code, add comments or best practices.
5. If it's a simple response, provide deeper explanation or alternative approaches.
"@
    }

    # ===========================
    # PRE-FLIGHT CHECKS
    # ===========================
    if (-not $Config.ApiKey) {
        Write-Error "API key is required. Set `$env:OpenAIKey` before running."
        exit 1
    }

    # Ensure ImportExcel is installed
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Warning "ImportExcel module not found. Run: Install-Module ImportExcel -Scope CurrentUser"
        return
    }

    # Ensure export base path exists
    if (-not (Test-Path $Config.BaseExportPath)) {
        New-Item -ItemType Directory -Path $Config.BaseExportPath -Force | Out-Null
    }
    # Ensure logs directory exists
    $LogsPath = Join-Path $Config.BaseExportPath "\Logs"
    if (-not (Test-Path $LogsPath)) {
        New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null
    }

    # Ensure sessions directory exists
    $SessionsPath = Join-Path $Config.BaseExportPath "\Sessions"
    if (-not (Test-Path $SessionsPath)) {
        New-Item -ItemType Directory -Path $SessionsPath -Force | Out-Null
    }

    # ===========================
    # LOGGING FUNCTION
    # ===========================
    function Write-Log {
        param(
            [string]$Message,
            [string]$Level = "INFO",
            [string]$AdditionalData = $null
        )
        $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        switch ($Level.ToUpper()) {
            "INFO" { $color = "Cyan" }
            "SUCCESS" { $color = "Green" }
            "WARN" { $color = "Yellow" }
            "ERROR" { $color = "Red" }
            default { $color = "White" }
        }
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
        Write-Output -InputObject "[$timestamp] [$Level] $Message $AdditionalData" | Out-File -Append -FilePath (Join-Path $Config.BaseExportPath "Logs\OpenAI_Refiner.log") -Encoding UTF8
    }

    # ===========================
    # AI-GENERATED SHORT FOLDER NAME
    # ===========================
    function Get-AIShortFolderName {
        param(
            [string]$OriginalPrompt
        )

        $FolderNamePrompt = @"
You are an AI that creates concise, filesystem-safe folder names from user prompts.
RULES:
- Max 25 characters
- Use only letters, numbers, and underscores
- No spaces or special characters
- No explanation, just return the folder name.
Original request: $OriginalPrompt
"@

        $Messages = @(
            @{role = "system"; content = "You generate concise folder names." },
            @{role = "user"; content = $FolderNamePrompt }
        )

        $Body = @{
            model       = $Config.FolderNameModel
            messages    = $Messages
            max_tokens  = 30
            temperature = 0.2
        } | ConvertTo-Json -Depth 5 -Compress

        $Headers = @{
            "Authorization" = "Bearer $($Config.ApiKey)"
            "Content-Type"  = "application/json"
        }

        try {
            $Response = Invoke-RestMethod -Uri $Config.OpenAIEndpoint -Method Post -Headers $Headers -Body $Body -ErrorAction Stop
            $ShortName = $Response.choices[0].message.content.Trim()

            # Sanitize output
            $ShortName = ($ShortName -replace '\s+', '_') -replace '[^A-Za-z0-9_]', ''

            if (-not $ShortName -or $ShortName.Length -lt 3 -or $ShortName.Length -gt 30) {
                Write-Warning "GPT folder name invalid, falling back to truncation."
                $ShortName = ($OriginalPrompt.Substring(0, [Math]::Min(25, $OriginalPrompt.Length)) -replace '\s+', '_') -replace '[^A-Za-z0-9_]', ''
            }

            return $ShortName
        }
        catch {
            Write-Warning "AI folder name generation failed, falling back to truncation."
            return ($OriginalPrompt.Substring(0, [Math]::Min(25, $OriginalPrompt.Length)) -replace '\s+', '_') -replace '[^A-Za-z0-9_]', ''
        }
    }

    # ===========================
    # SESSION FOLDER CREATION
    # ===========================
    function New-SessionFolder {
        param([string]$OriginalPrompt)

        $AIShortName = Get-AIShortFolderName -OriginalPrompt $OriginalPrompt
        $SessionTimestamp = (Get-Date -Format "yyyyMMdd_HHmmss")
        $FolderName = "${SessionTimestamp}_${AIShortName}"

        $SessionFolder = Join-Path $Config.BaseExportPath "Sessions\$FolderName"
        New-Item -Path $SessionFolder -ItemType Directory -Force | Out-Null

        return $SessionFolder
    }

    # ===========================
    # OPENAI CALL FUNCTION
    # ===========================
    function Invoke-OpenAIRequest {
        param(
            [string]$Prompt,
            [System.Collections.ArrayList]$ConversationHistory
        )

        $Headers = @{
            "Authorization" = "Bearer $($Config.ApiKey)"
            "Content-Type"  = "application/json"
        }

        $retry = 0
        do {
            try {
                $Messages = @()
                foreach ($m in $ConversationHistory) {
                    $Messages += @{ role = $m.Role; content = $m.Content }
                }
                $Messages += @{ role = "user"; content = $Prompt }

                # Estimate prompt size
                $PromptLength = ($Prompt.Length / 4) # rough tokens = chars/4
                $DynamicMaxTokens = [Math]::Min(8192, [Math]::Max($Config.DefaultMaxTokens, $PromptLength * 2))

                $Body = @{
                    model       = $Config.DefaultModel
                    messages    = $Messages
                    max_tokens  = $DynamicMaxTokens
                    temperature = $Config.DefaultTemperature
                } | ConvertTo-Json -Depth 10 -Compress
                Write-Log -Message "Invoking OpenAI API with prompt length: $($PromptLength) tokens" -Level 'INFO'

                $Response = Invoke-RestMethod -Uri $Config.OpenAIEndpoint -Method Post -Headers $Headers -Body $Body -ErrorAction Stop

                $UsageJson = [PSCustomObject]@{
                    PromptTokens     = $Response.usage.prompt_tokens
                    CompletionTokens = $Response.usage.completion_tokens
                    TotalTokens      = $Response.usage.total_tokens
                } | ConvertTo-Json -Depth 5
                Write-Log -Message "OpenAI API call successful" -Level 'INFO' -AdditionalData $UsageJson

                return [PSCustomObject]@{
                    Content          = $Response.choices[0].message.content
                    TotalTokens      = $Response.usage.total_tokens
                    PromptTokens     = $Response.usage.prompt_tokens
                    CompletionTokens = $Response.usage.completion_tokens
                }
            }
            catch {
                $retry++
                Write-Log "OpenAI API call failed (attempt $retry/$($Config.RetryCount)): $_" "WARN"
                if ($retry -lt $Config.RetryCount) {
                    Write-Log "Retrying in $($Config.RetryDelaySeconds) seconds..." "INFO"
                    Start-Sleep -Seconds $Config.RetryDelaySeconds
                }
                else {
                    Write-Log "Max retries reached. Returning null response." "ERROR"
                    return $null
                }
            }
        } while ($retry -lt $Config.RetryCount)
    }

    # ===========================
    # SAVE ITERATION OUTPUT
    # ===========================
    function Save-IterationOutput {
        param (
            [int]$IterationNumber,
            [string]$Prompt,
            [string]$Response,
            [string]$SessionFolder
        )
        $OutputFile = Join-Path $SessionFolder "Iteration_$IterationNumber.txt"
        @"
Iteration: $IterationNumber
===========================
Prompt:
-------
$Prompt

Response:
---------
$Response
"@ | Out-File -FilePath $OutputFile -Encoding UTF8

        Write-Log "Saved Iteration #$IterationNumber output to: $OutputFile" "SUCCESS"
    }

    # ===========================
    # APPEND SESSION SUMMARY TO EXCEL
    # ===========================
    function Append-SessionSummaryToExcel {
        param(
            [string]$SessionFolder,
            [string]$Model,
            [int]$IterationsRun,
            [int]$PromptTokens,
            [int]$CompletionTokens,
            [int]$TotalTokens,
            [decimal]$CostUSD
        )

        $SummaryPath = Join-Path $Config.BaseExportPath $Config.SessionSummaryFile

        $SummaryData = [PSCustomObject]@{
            Date             = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            SessionFolder    = $SessionFolder
            Model            = $Model
            IterationsRun    = $IterationsRun
            PromptTokens     = $PromptTokens
            CompletionTokens = $CompletionTokens
            TotalTokens      = $TotalTokens
            CostUSD          = $CostUSD
        }

        if (-not (Test-Path $SummaryPath)) {
            $SummaryData | Export-Excel -Path $SummaryPath -WorksheetName "SessionSummary" -AutoSize
            Write-Log "Created new session summary Excel: $SummaryPath" "SUCCESS"
        }
        else {
            $SummaryData | Export-Excel -Path $SummaryPath -WorksheetName "SessionSummary" -Append -AutoSize
            Write-Log "Appended session summary to Excel: $SummaryPath" "SUCCESS"
        }
    }

    # ===========================
    # MAIN EXECUTION
    # ===========================
    Write-Log "Welcome to the OpenAI GPT interactive refinement tool!" "INFO"

    if (-not $global:ConversationHistory) {
        $global:ConversationHistory = [System.Collections.ArrayList]::new()
    }
    $ConversationHistory = $global:ConversationHistory

    [int]$TotalTokenUsage = 0
    [int]$TotalPromptTokens = 0
    [int]$TotalCompletionTokens = 0
    ### BEGIN: Refiner_MultiModal_Helpers

    function Select-RefinerInputFile {
        <#
    .SYNOPSIS
        Lets the user pick a file using a GUI dialog when possible,
        and falls back to manual path entry otherwise.
    #>
        param()

        try {
            # Try to load WinForms for a GUI file picker (works on Windows PowerShell / pwsh on Windows)
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Title = "Select a file for Prompt Pilot"
            $dialog.Filter = "All files (*.*)|*.*"

            $null = $dialog.ShowDialog()
            if ($dialog.FileName) {
                # User picked a file
                return $dialog.FileName
            }
            else {
                # User cancelled
                Write-Log "File selection was cancelled by the user." "INFO"
                return $null
            }
        }
        catch {
            # No WinForms (e.g. non-Windows or constrained host) – fall back to manual path entry
            Write-Log "GUI file picker unavailable, falling back to manual path entry. $($_.Exception.Message)" "WARN"
            $manualPath = Read-Host "Enter full path to the file you want to work with"
            return $manualPath
        }
    }

    function Get-RefinerFileCategory {
        <#
    .SYNOPSIS
        Maps a file extension to a coarse “category” so we can ask smarter questions.
    #>
        param(
            [Parameter(Mandatory)][string]$Path
        )

        $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

        switch ($ext) {
            '.txt' { 'Text' }
            '.md' { 'Text' }
            '.rtf' { 'Text' }

            '.ps1' { 'Code' }
            '.psm1' { 'Code' }
            '.psd1' { 'Code' }
            '.py' { 'Code' }
            '.js' { 'Code' }
            '.ts' { 'Code' }
            '.cs' { 'Code' }
            '.java' { 'Code' }
            '.sh' { 'Code' }

            '.doc' { 'Document' }
            '.docx' { 'Document' }
            '.pdf' { 'Document' }
            '.ppt' { 'Document' }
            '.pptx' { 'Document' }

            '.xls' { 'Spreadsheet' }
            '.xlsx' { 'Spreadsheet' }
            '.csv' { 'Spreadsheet' }

            '.png' { 'Image' }
            '.jpg' { 'Image' }
            '.jpeg' { 'Image' }
            '.gif' { 'Image' }
            '.bmp' { 'Image' }
            '.webp' { 'Image' }

            '.mp3' { 'Audio' }
            '.wav' { 'Audio' }
            '.m4a' { 'Audio' }

            '.mp4' { 'Video' }
            '.mkv' { 'Video' }
            '.mov' { 'Video' }
            '.avi' { 'Video' }

            default { 'Other' }
        }
    }

    function Get-RefinementQuestionsForFileCategory {
        <#
    .SYNOPSIS
        Returns a list of follow-up questions appropriate for the file category.
    #>
        param(
            [Parameter(Mandatory)][string]$Category
        )

        switch ($Category) {
            'Text' {
                @(
                    "Who is the target audience for this text (e.g. engineers, executives, general users)?"
                    "What is the main goal: clarity, brevity, persuasion, technical accuracy, or something else?"
                    "Do you want the tone to be formal, casual, playful, or neutral?"
                    "Are there any sections that are off-limits for editing (e.g. legal clauses, exact quotes)?"
                )
            }
            'Code' {
                @(
                    "What is the primary language or stack in this file?"
                    "Is your goal bug fixing, performance optimization, style/readability, or feature changes?"
                    "Are there constraints like 'must stay compatible with PowerShell 5.1' or 'public APIs cannot change'?"
                    "What environment does this code run in (OS, runtime version, cloud provider, etc.)?"
                )
            }
            'Document' {
                @(
                    "Do you want a summary, rewrite, or critique of this document?"
                    "What should the reader be able to do after reading the refined output (decide, learn, implement)?"
                    "Are there specific sections that matter most (e.g. methodology, conclusions, executive summary)?"
                    "Should we keep original formatting structure (headings, bullet lists), or is free-form OK?"
                )
            }
            'Spreadsheet' {
                @(
                    "What are the key metrics or columns you actually care about?"
                    "Do you want formulas reviewed, dashboards suggested, or data quality issues surfaced?"
                    "Over what time period or subset of rows should the analysis focus?"
                    "Are there any privacy constraints (columns that must not be exposed in examples)?"
                )
            }
            'Image' {
                @(
                    "Is your goal description/captioning, alt-text, design critique, or transformation ideas?"
                    "Should the AI focus on visual details, emotional impact, or practical information?"
                    "Are there branding or style constraints (colors, fonts, logo usage) the AI should respect?"
                )
            }
            'Audio' {
                @(
                    "Do you primarily want transcription, summary, or key-insights extraction?"
                    "Is the audio conversational, a lecture, music, or something else?"
                    "Should timestamps or speaker labels be preserved in the refined output?"
                )
            }
            'Video' {
                @(
                    "Is your main goal a summary, shot-by-shot breakdown, or script refinement?"
                    "Should the AI focus on dialogue, visuals, pacing, or all of the above?"
                    "Do you need content suitable for social clips (short hooks, titles, descriptions)?"
                )
            }
            default {
                @(
                    "What kind of content is inside this file (text, binary config, mixed, proprietary)?"
                    "In plain language, what do you wish an expert AI could help you accomplish with it?"
                    "Are there any safety, privacy, or compliance constraints the AI must keep in mind?"
                )
            }
        }
    }

    function Get-RefinerUserPrompt {
        <#
    .SYNOPSIS
        Central entry point for Prompt Pilot's input mode.
        Lets the user:
          - enter a free-form text prompt, OR
          - pick a file and answer file-specific questions,
        then returns a composed prompt string for the existing refinement loop.

    .OUTPUTS
        [string]  – the composed user prompt, or 'exit' to signal termination,
                    or $null if there was no usable input.
    #>
        [CmdletBinding()]
        param()

        Write-Host ""
        Write-Host "=== Prompt Pilot Input Mode ===" -ForegroundColor Cyan
        Write-Host "  1) Free-form text prompt"
        Write-Host "  2) Work with a file (multi-modal helper)"
        Write-Host "  X) Exit"
        $choice = Read-Host "Select an option (1/2/X)"

        switch ($choice) {
            '1' {
                # Plain text mode – equivalent to your old Read-Host call
                $prompt = Read-Host "How can I assist you today? (type your prompt text)"
                if ([string]::IsNullOrWhiteSpace($prompt)) {
                    Write-Log "User selected text mode but provided an empty prompt." "WARN"
                    return $null
                }
                return $prompt
            }

            '2' {
                # File-driven mode
                $filePath = Select-RefinerInputFile
                if (-not $filePath) {
                    # User cancelled or something failed
                    return $null
                }

                if (-not (Test-Path -LiteralPath $filePath)) {
                    Write-Log "Selected file path does not exist: $filePath" "ERROR"
                    return $null
                }

                $category = Get-RefinerFileCategory -Path $filePath
                $fileName = [System.IO.Path]::GetFileName($filePath)
                $extension = [System.IO.Path]::GetExtension($filePath)

                Write-Log "Selected file '$fileName' detected as category '$category'." "INFO"

                # High-level goal first
                $goal = Read-Host "Briefly describe what you want the AI to do with this $category file"
                if ([string]::IsNullOrWhiteSpace($goal)) {
                    $goal = "Help me work with this $category file in the most useful way."
                }

                # Category-specific refiners
                $questions = Get-RefinementQuestionsForFileCategory -Category $category
                $answers = @()

                foreach ($q in $questions) {
                    $answer = Read-Host $q
                    if (-not [string]::IsNullOrWhiteSpace($answer)) {
                        # Keep Q/A pairs so the model has structured context
                        $answers += "- $q`n  -> $answer"
                    }
                }

                $answersText = if ($answers.Count -gt 0) {
                    $answers -join "`n"
                }
                else {
                    "No additional preferences were specified."
                }

                # Final composed prompt that your existing refinement loop can treat as normal text
                $composedPrompt = @"
You are a prompt-engineering assistant helping a user work with a local file.

File details:
- File name: $fileName
- Full path (local to the user): $filePath
- Extension / detected category: $extension ($category)

User goal for this file:
$goal

Additional preferences and constraints (Q & A):
$answersText

Using this information, refine this into a high-quality prompt that the user can send to an AI model that is able to access or upload the file as needed. Make the prompt explicit about:
- what to do with the file,
- any constraints or priorities,
- what a "good" answer would look like,
- and any follow-up outputs (summaries, code, diagrams, etc.) that would be useful.
"@

                return $composedPrompt
            }

            'X' { return 'exit' }
            'x' { return 'exit' }

            default {
                Write-Log "Unrecognized input mode '$choice'. Falling back to text mode." "WARN"
                $prompt = Read-Host "How can I assist you today? (type your prompt text)"
                if ([string]::IsNullOrWhiteSpace($prompt)) {
                    Write-Log "Fallback text prompt was also empty." "WARN"
                    return $null
                }
                return $prompt
            }
        }
    }

    ### END: Refiner_MultiModal_Helpers

    # ===========================
    # MAIN LOOP
    # ===========================

    do {
        # Centralized intake – either free-form text or file-driven prompt
        $UserPrompt = Get-RefinerUserPrompt

        if (-not $UserPrompt) {
            # Nothing usable – safest move is to bail out rather than hammer the API with garbage
            Write-Log "No valid prompt was provided. Ending session." "INFO"
            break
        }

        if ($UserPrompt -eq "exit") {
            Write-Log "User requested exit from Prompt Pilot." "INFO"
            break
        }

        # Create folder with AI-generated short name based on the composed prompt
        $SessionFolder = New-SessionFolder -OriginalPrompt $UserPrompt
        Write-Log "Session outputs will be saved under: $SessionFolder" "INFO"

        $RefinmentGoals = Read-Host "Enter refinement goals (or press Enter to use default goals)"
        if (-not $RefinmentGoals) { $RefinmentGoals = $Config.RefinementGoalsTemplate }

        $BaselineScript = $UserPrompt

        # Initial GPT call
        $InitialCall = Invoke-OpenAIRequest -Prompt $UserPrompt -ConversationHistory $ConversationHistory
        if ($null -eq $InitialCall) {
            Write-Log "Initial response was null. Try again." "WARN"
            continue
        }

        $InitialResponse = $InitialCall.Content
        $TotalTokenUsage += $InitialCall.TotalTokens
        $TotalPromptTokens += $InitialCall.PromptTokens
        $TotalCompletionTokens += $InitialCall.CompletionTokens

        $EffectiveIterations = ($InitialResponse.Length -lt 100) ? 1 : $Config.RefinementIterations

        Write-Log "Initial GPT Response: $InitialResponse" "SUCCESS"
        Save-IterationOutput -IterationNumber 0 -Prompt $UserPrompt -Response $InitialResponse -SessionFolder $SessionFolder

        # Track conversation only for the initial prompt
        $null = $ConversationHistory.Add([PSCustomObject]@{ Role = "user"; Content = $UserPrompt })
        $null = $ConversationHistory.Add([PSCustomObject]@{ Role = "assistant"; Content = $InitialResponse })

        $LastImprovedScript = $InitialResponse
        $IterationsRun = 0

        for ($i = 1; $i -le $EffectiveIterations; $i++) {
            $IterationsRun++
            $ImprovementPrompt = @"
Here is the ORIGINAL baseline input:
$BaselineScript

Here is the LAST improved version:
$LastImprovedScript

Refinement Goals:
$RefinmentGoals
"@

            Write-Log "Starting refinement iteration #$i" "INFO"

            $MinimalHistory = [System.Collections.ArrayList]::new()
            $null = $MinimalHistory.Add([PSCustomObject]@{ role = "user"; content = $ImprovementPrompt })

            $ImprovementCall = Invoke-OpenAIRequest -Prompt $ImprovementPrompt -ConversationHistory $MinimalHistory
            if ($null -eq $ImprovementCall) {
                Write-Log "Improvement call returned null. Stopping iterations." "ERROR"
                break
            }

            $ImprovementResponse = $ImprovementCall.Content
            $TotalTokenUsage += $ImprovementCall.TotalTokens
            $TotalPromptTokens += $ImprovementCall.PromptTokens
            $TotalCompletionTokens += $ImprovementCall.CompletionTokens

            # ✅ EARLY STOP DETECTION
            if ($ImprovementResponse -match "already optimal|cannot improve|no further|nothing more to improve|no additional") {
                Write-Log "GPT indicated no further refinements are meaningful. Stopping early." "WARN"
                Save-IterationOutput -IterationNumber $i -Prompt $ImprovementPrompt -Response $ImprovementResponse -SessionFolder $SessionFolder
                break
            }

            Write-Log "Refinement #$i complete." "INFO"
            Save-IterationOutput -IterationNumber $i -Prompt $ImprovementPrompt -Response $ImprovementResponse -SessionFolder $SessionFolder
            $LastImprovedScript = $ImprovementResponse

            if ($i -eq $EffectiveIterations) {
                Write-Log "Final refinement reached. Ending iterations." "SUCCESS"
            }
        }

        # ===========================
        # COST CALCULATION
        # ===========================
        $CostPromptRate = 0.003
        $CostCompletionRate = 0.006
        $SessionPromptCost = ($TotalPromptTokens / 1000) * $CostPromptRate
        $SessionCompletionCost = ($TotalCompletionTokens / 1000) * $CostCompletionRate
        $TotalCost = [Math]::Round(($SessionPromptCost + $SessionCompletionCost), 4)

        Write-Host ""
        Write-Log "Refinement process complete! Iterations saved in: $SessionFolder" "SUCCESS"
        Write-Log "✅ Total tokens: $TotalTokenUsage (Prompt: $TotalPromptTokens | Completion: $TotalCompletionTokens)" "SUCCESS"
        Write-Log "✅ Estimated session cost: $TotalCost USD" "SUCCESS"

        # Append session summary to Excel
        Append-SessionSummaryToExcel `
            -SessionFolder $SessionFolder `
            -Model $Config.DefaultModel `
            -IterationsRun $IterationsRun `
            -PromptTokens $TotalPromptTokens `
            -CompletionTokens $TotalCompletionTokens `
            -TotalTokens $TotalTokenUsage `
            -CostUSD $TotalCost

        break
    } while ($true)

    Write-Log "Goodbye!" "INFO"
}

OpenAI_Refiner
