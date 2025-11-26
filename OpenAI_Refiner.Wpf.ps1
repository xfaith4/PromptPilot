### BEGIN FILE: OpenAI_Refiner.Wpf.ps1
[CmdletBinding()]
param()

# Ensure errors stop the script, not silently continue
$ErrorActionPreference = 'Stop'

# Load WPF assemblies (works in Windows PowerShell and pwsh on Windows)
Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName PresentationCore       | Out-Null
Add-Type -AssemblyName WindowsBase            | Out-Null
Add-Type -AssemblyName System.Windows.Forms   | Out-Null

function Show-Status {
    param(
        [string]$Message,
        [string]$Usage = $null
    )

    # These variables are populated after parsing the XAML
    if ($script:StatusTextBlock) {
        $script:StatusTextBlock.Text = $Message
    }
    if ($Usage -and $script:UsageTextBlock) {
        $script:UsageTextBlock.Text = $Usage
    }
}

function Append-Log {
    param(
        [string]$Message
    )

    if (-not $script:LogTextBox) { return }

    $timestamp = (Get-Date).ToString('HH:mm:ss')
    $line = "[{0}] {1}" -f $timestamp, $Message
    $script:LogTextBox.AppendText("$line`n")
    $script:LogTextBox.ScrollToEnd()
}

function Set-BusyState {
    param(
        [bool]$IsBusy,
        [string]$Message = $null
    )

    if ($script:BusyIndicatorTextBlock) {
        $script:BusyIndicatorTextBlock.Visibility = if ($IsBusy) { 'Visible' } else { 'Collapsed' }
    }

    $window.Cursor = if ($IsBusy) { [System.Windows.Input.Cursors]::Wait } else { [System.Windows.Input.Cursors]::Arrow }

    foreach ($btn in @(
        $script:RunButton,
        $script:BrowseButton,
        $script:CopyButton,
        $script:UsePromptButton,
        $script:CopyTaskOutputButton,
        $script:ModeRefineRadio,
        $script:ModeAnswerRadio,
        $script:ClearLogButton
    )) {
        if ($btn) { $btn.IsEnabled = -not $IsBusy }
    }

    if ($Message) {
        Append-Log -Message $Message
    }
}

function Invoke-OpenAIRefinement {
    <#
    .SYNOPSIS
        Iteratively refines a prompt using the OpenAI Responses API.

    .DESCRIPTION
        - Uses the model requested by the caller (default gpt-4.1-mini).
        - On each iteration, sends the current draft plus explicit refinement goals.
        - Transforms rough prompts into structured, production-grade task descriptions.
        - Returns the final prompt text and a list of iterations.

    .OUTPUTS
        [pscustomobject] with:
          - FinalPrompt
          - Iterations (array)
          - TotalTokens
          - TotalCostUsd (rough estimate)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BasePrompt,
        [Parameter()][string]$RefinementGoals,
        [Parameter()][string]$FilePath,
        [Parameter()][int]$Iterations = 3,
        [Parameter()][string]$Model = 'gpt-4.1-mini',
        [Parameter()][string]$ProjectContext = ''
    )

    $apiKey = $env:OPENAI_API_KEY
    if (-not $apiKey) {
        throw "OPENAI_API_KEY environment variable is not set. Please set it to your OpenAI API key."
    }

    if ($Iterations -lt 1) {
        $Iterations = 1
    }

    # Basic heuristic pricing for mini; adjust if you change model
    $pricePer1kInput  = 0.00015
    $pricePer1kOutput = 0.00060

    $currentDraft = $BasePrompt
    $iterationResults = @()
    $totalInputTokens  = 0
    $totalOutputTokens = 0

    # Fixed system message for the Prompt Refiner
    $systemInstructions = @"
You are a senior prompt architect for coding assistants (e.g., GitHub Copilot, Claude, ChatGPT Code).
Your job is to transform rough, underspecified user prompts into high-quality, production-grade task
descriptions that coding agents can execute reliably.

Always:
- Preserve the user's core intent.
- Clarify role, goals, inputs, outputs, and constraints.
- Add structure that makes it easy for the coding agent to follow (headings, bullet points, clear sections).
- Avoid adding fictional requirements; only infer what is strongly implied by the user's text.

Assume the user is a technically proficient engineer working on a home-lab / monitoring / automation project.
Prefer precise, direct language over marketing fluff.
"@

    # Default project context if not provided
    $defaultProjectContext = @"
Project context (for reference while refining the prompt):

- This project is a System Dashboard for a single home lab machine and its router.
- It collects Windows Event Logs, system metrics, router client data, and syslogs.
- The user is a senior cloud engineer comfortable with PowerShell, .NET, and basic web dev.
- The codebase should prioritize robustness, maintainability, and observability over clever tricks.

Use this context to make the refined prompts more concrete and useful, but do not restate it verbatim unless it helps clarify the user's intent.
"@

    $effectiveProjectContext = if ($ProjectContext) { $ProjectContext } else { $defaultProjectContext }

    for ($i = 1; $i -le $Iterations; $i++) {
        # Build the user-side transformation template
        $userContent = @"
$effectiveProjectContext

You are refining a rough prompt that will be sent to a coding assistant like GitHub Copilot.

Original rough prompt:
---
$currentDraft
---

Transform this into a single, well-structured prompt with the following sections:

1. Role: Describe who the coding assistant should act as.
2. Goals: Bullet list of what the user is trying to achieve.
3. Context: Any relevant background that will help (assume a System Dashboard / home-lab monitoring project if not specified).
4. Deliverables: Exact formats or artifacts the coding assistant should produce.
5. Constraints and style: Technical constraints (language, stack, performance, safety) and writing/style preferences if present or implied.

Additional refinement goals (may be empty):
$RefinementGoals

If a file path is provided, assume the runtime system can handle uploads or references:
$FilePath

Output only the refined prompt, in Markdown, starting with a short one-line description and then the sections above.
Do not include your own commentary or analysis, only the final prompt the user should copy/paste into their coding assistant.
"@

        $messages = @(
            @{ role = 'system'; content = $systemInstructions },
            @{ role = 'user'; content = $userContent }
        )

        $body = @{
            model = $Model
            messages = $messages
        } | ConvertTo-Json -Depth 5

        $headers = @{
            'Authorization' = "Bearer $apiKey"
            'Content-Type'  = 'application/json'
        }

        Show-Status -Message ("Calling OpenAI (iteration {0}/{1})..." -f $i, $Iterations)

        $response = Invoke-RestMethod -Method Post `
            -Uri "https://api.openai.com/v1/chat/completions" `
            -Headers $headers `
            -Body $body

        # Extract the text result from the chat completions API structure
        $text = $null
        if ($response.choices -and $response.choices[0].message) {
            $text = $response.choices[0].message.content
        }

        if (-not $text) {
            throw "No text content returned from OpenAI in iteration $i."
        }

        $currentDraft = $text.Trim()

        # Token usage (if present)
        if ($response.usage) {
            $inTokens  = [int]$response.usage.prompt_tokens
            $outTokens = [int]$response.usage.completion_tokens
            $totalInputTokens  += $inTokens
            $totalOutputTokens += $outTokens
        }

        $iterationResults += [pscustomobject]@{
            Iteration = $i
            Prompt    = $currentDraft
        }
    }

    $totalTokens = $totalInputTokens + $totalOutputTokens
    $cost = 0.0
    if ($totalTokens -gt 0) {
        # Convert to 1k-token units
        $inputK  = $totalInputTokens  / 1000.0
        $outputK = $totalOutputTokens / 1000.0
        $cost = ($inputK * $pricePer1kInput) + ($outputK * $pricePer1kOutput)
    }

    return [pscustomobject]@{
        FinalPrompt     = $currentDraft
        Iterations      = $iterationResults
        TotalTokens     = $totalTokens
        TotalInputTokens  = $totalInputTokens
        TotalOutputTokens = $totalOutputTokens
        TotalCostUsd    = [Math]::Round($cost, 6)
    }
}

function Invoke-OpenAIAnswer {
    <#
    .SYNOPSIS
        Executes the refined prompt to produce the task result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$FilePath,
        [Parameter()][string]$Model = 'gpt-4.1-mini'
    )

    $apiKey = $env:OPENAI_API_KEY
    if (-not $apiKey) {
        throw "OPENAI_API_KEY environment variable is not set. Please set it to your OpenAI API key."
    }

    $pricePer1kInput  = 0.00015
    $pricePer1kOutput = 0.00060

    $promptWithContext = if ($FilePath) {
        "$Prompt`n`nFile reference: $FilePath"
    } else {
        $Prompt
    }

    $messages = @(
        @{ role = 'user'; content = $promptWithContext }
    )

    $body = @{
        model = $Model
        messages = $messages
    } | ConvertTo-Json -Depth 5

    $headers = @{
        'Authorization' = "Bearer $apiKey"
        'Content-Type'  = 'application/json'
    }

    $response = Invoke-RestMethod -Method Post `
        -Uri "https://api.openai.com/v1/chat/completions" `
        -Headers $headers `
        -Body $body

    $text = $null
    if ($response.choices -and $response.choices[0].message) {
        $text = $response.choices[0].message.content
    }

    if (-not $text) {
        throw "No text content returned from OpenAI for task execution."
    }

    $totalInputTokens  = 0
    $totalOutputTokens = 0
    if ($response.usage) {
        $totalInputTokens  = [int]$response.usage.prompt_tokens
        $totalOutputTokens = [int]$response.usage.completion_tokens
    }

    $totalTokens = $totalInputTokens + $totalOutputTokens
    $cost = 0.0
    if ($totalTokens -gt 0) {
        $inputK  = $totalInputTokens  / 1000.0
        $outputK = $totalOutputTokens / 1000.0
        $cost = ($inputK * $pricePer1kInput) + ($outputK * $pricePer1kOutput)
    }

    return [pscustomobject]@{
        OutputText        = $text.Trim()
        TotalTokens       = $totalTokens
        TotalInputTokens  = $totalInputTokens
        TotalOutputTokens = $totalOutputTokens
        TotalCostUsd      = [Math]::Round($cost, 6)
    }
}

# --- Load XAML and create window ---

$here = if ($PSCommandPath) {
    # Use .NET to avoid Split-Path parameter-set quirks with -LiteralPath/-Parent
    [System.IO.Path]::GetDirectoryName($PSCommandPath)
} else {
    (Get-Location).Path
}
$xamlPath = Join-Path -Path $here -ChildPath 'OpenAI_Refiner.MainWindow.xaml'
if (-not (Test-Path -LiteralPath $xamlPath)) {
    throw "XAML file not found at $xamlPath"
}

[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Cache controls we need to interact with
$script:PromptTextBox      = $window.FindName('PromptTextBox')
$script:GoalsTextBox       = $window.FindName('GoalsTextBox')
$script:ProjectContextTextBox = $window.FindName('ProjectContextTextBox')
$script:FilePathTextBox    = $window.FindName('FilePathTextBox')
$script:BrowseButton       = $window.FindName('BrowseButton')
$script:RunButton          = $window.FindName('RunButton')
$script:CopyButton         = $window.FindName('CopyButton')
$script:IterationsTextBox  = $window.FindName('IterationsTextBox')
$script:ModelTextBox       = $window.FindName('ModelTextBox')
$script:FinalPromptTextBox = $window.FindName('FinalPromptTextBox')
$script:HistoryTextBox     = $window.FindName('HistoryTextBox')
$script:StatusTextBlock    = $window.FindName('StatusTextBlock')
$script:UsageTextBlock     = $window.FindName('UsageTextBlock')
$script:ModeRefineRadio    = $window.FindName('ModeRefineRadio')
$script:ModeAnswerRadio    = $window.FindName('ModeAnswerRadio')
$script:UsePromptButton    = $window.FindName('UsePromptButton')
$script:CopyTaskOutputButton = $window.FindName('CopyTaskOutputButton')
$script:TaskOutputTextBox  = $window.FindName('TaskOutputTextBox')
$script:LogTextBox         = $window.FindName('LogTextBox')
$script:BusyIndicatorTextBlock = $window.FindName('BusyIndicatorTextBlock')
$script:ClearLogButton     = $window.FindName('ClearLogButton')

if (-not $script:PromptTextBox)      { throw "Failed to find PromptTextBox in XAML." }
if (-not $script:RunButton)          { throw "Failed to find RunButton in XAML." }
if (-not $script:StatusTextBlock)    { throw "Failed to find StatusTextBlock in XAML." }
if (-not $script:ModeRefineRadio -or -not $script:ModeAnswerRadio) { throw "Failed to find mode toggle radio buttons in XAML." }
if (-not $script:CopyTaskOutputButton) { throw "Failed to find CopyTaskOutputButton in XAML." }
if (-not $script:TaskOutputTextBox)  { throw "Failed to find TaskOutputTextBox in XAML." }
if (-not $script:LogTextBox)         { throw "Failed to find LogTextBox in XAML." }
if (-not $script:ClearLogButton)     { throw "Failed to find ClearLogButton in XAML." }

# Seed refinement goals with something sensible
if (-not $script:GoalsTextBox.Text) {
    $script:GoalsTextBox.Text = @"
- Preserve the user's core intent
- Clarify role, goals, inputs, outputs, and constraints
- Add structure that makes it easy for coding agents to follow
- Avoid adding fictional requirements; only infer what is strongly implied
- Prefer precise, direct language over marketing fluff
"@
}

$script:CurrentMode = 'Refine'
$script:UsageTextBlock.Text = "Tokens: 0 | Cost: $0.000000"

function Set-Mode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Refine','Answer')]
        [string]$Mode
    )

    $script:CurrentMode = $Mode
    $script:ModeRefineRadio.IsChecked = ($Mode -eq 'Refine')
    $script:ModeAnswerRadio.IsChecked = ($Mode -eq 'Answer')
    $script:RunButton.Content = if ($Mode -eq 'Refine') { 'Run Refinement' } else { 'Run Task' }
    $script:HistoryTextBox.IsEnabled = ($Mode -eq 'Refine')
    $script:HistoryTextBox.Opacity   = if ($Mode -eq 'Refine') { 1.0 } else { 0.65 }

    if ($Mode -eq 'Refine') {
        # Keep task output visible for copy/paste even while refining
        Show-Status -Message "Ready to refine."
    }
    else {
        # Clear history to reduce confusion when switching into execution mode
        $script:HistoryTextBox.Text = ''
        Show-Status -Message "Ready to answer the task."
    }
}

function Run-Refinement {
    $basePrompt = $script:PromptTextBox.Text
    if ([string]::IsNullOrWhiteSpace($basePrompt)) {
        [System.Windows.MessageBox]::Show(
            "Please enter a base prompt before running refinement.",
            "Missing prompt",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        return
    }

    $goals   = $script:GoalsTextBox.Text
    $projectContext = $script:ProjectContextTextBox.Text
    $file    = $script:FilePathTextBox.Text
    $model   = if ($script:ModelTextBox.Text) { $script:ModelTextBox.Text } else { 'gpt-4.1-mini' }

    $iterRaw = $script:IterationsTextBox.Text
    $iterations = 3
    if ([int]::TryParse($iterRaw, [ref]$iterations) -eq $false -or $iterations -lt 1) {
        $iterations = 3
    }

    $script:TaskOutputTextBox.Text = ''
    Show-Status -Message "Running refinement..." -Usage "Tokens: 0 | Cost: $0.000000"

    Set-BusyState -IsBusy $true -Message ("Refinement started (iterations: {0}, model: {1})" -f $iterations, $model)
    try {
        $result = Invoke-OpenAIRefinement -BasePrompt $basePrompt `
                                          -RefinementGoals $goals `
                                          -ProjectContext $projectContext `
                                          -FilePath $file `
                                          -Iterations $iterations `
                                          -Model $model
    }
    catch {
        Append-Log -Message ("Refinement failed: {0}" -f $_.Exception.Message)
        throw
    }
    finally {
        Set-BusyState -IsBusy $false
    }

    $script:FinalPromptTextBox.Text = $result.FinalPrompt

    # Build a readable history log
    $historyLines = @()
    foreach ($item in $result.Iterations) {
        $historyLines += ("===== Iteration {0} =====" -f $item.Iteration)
        $historyLines += $item.Prompt
        $historyLines += ""
    }
    $script:HistoryTextBox.Text = ($historyLines -join [Environment]::NewLine)

    $usageText = "Tokens: {0} (in {1} / out {2}) | Cost: ${3}" -f `
        $result.TotalTokens, $result.TotalInputTokens, $result.TotalOutputTokens, $result.TotalCostUsd
    Show-Status -Message "Refinement complete." -Usage $usageText
    Append-Log -Message ("Refinement complete. {0}" -f $usageText)
}

function Run-AnswerTask {
    $promptToRun = $script:PromptTextBox.Text
    if ([string]::IsNullOrWhiteSpace($promptToRun)) {
        [System.Windows.MessageBox]::Show(
            "Provide a prompt (or click 'Use this Prompt' after refining) before running the task.",
            "Missing prompt",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        return
    }

    $file  = $script:FilePathTextBox.Text
    $model = if ($script:ModelTextBox.Text) { $script:ModelTextBox.Text } else { 'gpt-4.1-mini' }

    Show-Status -Message "Running task..." -Usage "Tokens: 0 | Cost: $0.000000"

    Set-BusyState -IsBusy $true -Message ("Task started (model: {0})" -f $model)
    try {
        $result = Invoke-OpenAIAnswer -Prompt $promptToRun -FilePath $file -Model $model
    }
    catch {
        Append-Log -Message ("Task failed: {0}" -f $_.Exception.Message)
        throw
    }
    finally {
        Set-BusyState -IsBusy $false
    }

    $script:TaskOutputTextBox.Text = $result.OutputText
    $usageText = "Tokens: {0} (in {1} / out {2}) | Cost: ${3}" -f `
        $result.TotalTokens, $result.TotalInputTokens, $result.TotalOutputTokens, $result.TotalCostUsd
    Show-Status -Message "Task complete." -Usage $usageText
    Append-Log -Message ("Task complete. {0}" -f $usageText)
}

function Invoke-ModeAction {
    if ($script:CurrentMode -eq 'Answer') {
        Run-AnswerTask
    }
    else {
        Run-Refinement
    }
}

# --- Event handlers ---

# Mode toggles
$script:ModeRefineRadio.Add_Checked({ Set-Mode -Mode 'Refine' })
$script:ModeAnswerRadio.Add_Checked({ Set-Mode -Mode 'Answer' })

# File browse button
$script:BrowseButton.Add_Click({
    try {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title  = "Select a file for context (optional)"
        $ofd.Filter = "All files (*.*)|*.*"

        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:FilePathTextBox.Text = $ofd.FileName
        }
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Unable to open file dialog: $($_.Exception.Message)",
            "Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
})

# Run refinement button
$script:RunButton.Add_Click({
    try {
        Invoke-ModeAction
    }
    catch {
        $msg = "Action failed: $($_.Exception.Message)"
        Show-Status -Message $msg
        Append-Log -Message $msg
        [System.Windows.MessageBox]::Show(
            $msg,
            "Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
})

# Use this prompt button -> switch to Answer mode and execute
$script:UsePromptButton.Add_Click({
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:FinalPromptTextBox.Text)) {
            $script:PromptTextBox.Text = $script:FinalPromptTextBox.Text
            Append-Log -Message "Using refined prompt to run task."
            Set-Mode -Mode 'Answer'
            Run-AnswerTask
        }
        else {
            [System.Windows.MessageBox]::Show(
                "Refine first, then click 'Use this Prompt' to execute the final instruction.",
                "No refined prompt yet",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
        }
    }
    catch {
        $msg = "Failed to run task: $($_.Exception.Message)"
        Show-Status -Message $msg
        [System.Windows.MessageBox]::Show(
            $msg,
            "Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
})

# Clear log button
$script:ClearLogButton.Add_Click({
    try {
        $script:LogTextBox.Clear()
        Append-Log -Message "Log cleared."
    }
    catch {
        Append-Log -Message ("Failed to clear log: {0}" -f $_.Exception.Message)
    }
})

# Copy button
$script:CopyButton.Add_Click({
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:FinalPromptTextBox.Text)) {
            [System.Windows.Clipboard]::SetText($script:FinalPromptTextBox.Text)
            Show-Status -Message "Final prompt copied to clipboard."
            Append-Log -Message "Final prompt copied to clipboard."
        }
    }
    catch {
        Show-Status -Message "Failed to copy to clipboard: $($_.Exception.Message)"
        Append-Log -Message ("Copy failed: {0}" -f $_.Exception.Message)
    }
})

# Copy task output button
$script:CopyTaskOutputButton.Add_Click({
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:TaskOutputTextBox.Text)) {
            [System.Windows.Clipboard]::SetText($script:TaskOutputTextBox.Text)
            Show-Status -Message "Task output copied to clipboard."
            Append-Log -Message "Task output copied to clipboard."
        }
    }
    catch {
        Show-Status -Message "Failed to copy task output: $($_.Exception.Message)"
        Append-Log -Message ("Copy task output failed: {0}" -f $_.Exception.Message)
    }
})

# Show window
Set-Mode -Mode 'Refine'
Append-Log -Message "Ready."
$null = $window.ShowDialog()
### END FILE: OpenAI_Refiner.Wpf.ps1
