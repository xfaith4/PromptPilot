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
        ApiKey                  = $env:OpenAIKey
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

    do {
        $UserPrompt = Read-Host "How can I assist you today? (type 'exit' to quit)"
        if ($UserPrompt -eq "exit") { break }

        # Create folder with AI-generated short name
        $SessionFolder = New-SessionFolder -OriginalPrompt $UserPrompt
        Write-Log "Session outputs will be saved under: $SessionFolder" "INFO"

        $RefinmentGoals = Read-Host "Enter refinement goals (or press Enter to skip)"
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
