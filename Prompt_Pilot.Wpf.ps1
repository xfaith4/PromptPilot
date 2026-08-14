[cmdletBinding()]
param()

# =============================================================================
# [10] PowerShell and OS version guard — must run before loading any assemblies
# =============================================================================
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "This script requires PowerShell 5.1 or later. Detected: $($PSVersionTable.PSVersion)"
}
# $IsWindows is only defined in PS 6+; on PS 5.1 it is $null (falsy), so the
# second condition safely short-circuits via the -ge 6 test.
if ((-not $IsWindows) -and ($PSVersionTable.PSVersion.Major -ge 6)) {
    throw "This script requires Windows. WPF is not available on non-Windows platforms."
}

$ErrorActionPreference = 'Stop'

# Load WPF assemblies (works in Windows PowerShell 5.1 and pwsh on Windows)
Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName PresentationCore       | Out-Null
Add-Type -AssemblyName WindowsBase            | Out-Null
Add-Type -AssemblyName System.Windows.Forms   | Out-Null

# =============================================================================
# [1] Centralised defaults — edit here, not scattered throughout the file
# =============================================================================
$script:DefaultModel           = 'gpt-5-mini'
$script:DefaultIterations      = 3
$script:PricePer1kInputTokens  = 0.00015
$script:PricePer1kOutputTokens = 0.00060
$script:DefaultProvider        = 'OpenAI'
$script:ProviderDefinitions    = [ordered]@{
    OpenAI = [ordered]@{
        DisplayName      = 'OpenAI'
        ApiBase          = 'https://api.openai.com/v1'
        ChatEndpointPath = 'chat/completions'
        EnvVars          = @('OPENAI_API_KEY')
        DefaultModel     = 'gpt-5-mini'
        DefaultPricePer1kInputTokens  = $script:PricePer1kInputTokens
        DefaultPricePer1kOutputTokens = $script:PricePer1kOutputTokens
        Protocol         = 'OpenAI'
    }
    Anthropic = [ordered]@{
        DisplayName      = 'Anthropic'
        ApiBase          = 'https://api.anthropic.com'
        ChatEndpointPath = 'v1/messages'
        EnvVars          = @('ANTHROPIC_API_KEY')
        DefaultModel     = 'claude-sonnet-4-20250514'
        DefaultPricePer1kInputTokens  = $script:PricePer1kInputTokens
        DefaultPricePer1kOutputTokens = $script:PricePer1kOutputTokens
        Protocol         = 'Anthropic'
    }
    GitHubCopilot = [ordered]@{
        DisplayName      = 'GitHub Copilot'
        ApiBase          = 'https://models.inference.ai.azure.com'
        ChatEndpointPath = 'chat/completions'
        EnvVars          = @('GITHUB_COPILOT_API_KEY', 'GITHUB_TOKEN')
        DefaultModel     = 'gpt-4.1'
        DefaultPricePer1kInputTokens  = $script:PricePer1kInputTokens
        DefaultPricePer1kOutputTokens = $script:PricePer1kOutputTokens
        Protocol         = 'OpenAI'
    }
}
$script:ActiveProvider         = $script:DefaultProvider
$script:SavedApiKeys           = @{}
$script:ProviderSettings       = @{}
$script:SettingsDir            = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Prompt Pilot'
$script:SettingsPath           = Join-Path $script:SettingsDir 'settings.json'

# [3] Cancellation flag — set by Cancel button or AcceptIterationButton
$script:CancelRequested = $false

# [9] Session API keys — stored in memory only, never written to disk or env vars
$script:SessionApiKeys = @{}

# [7] Active log file path — $null means file logging is disabled
$script:LogFilePath = $null

# [11] Answer-mode background execution state
$script:AnswerTaskState = $null
$script:AnswerTaskTimer = $null

# =============================================================================
# Utility functions
# =============================================================================

function Show-Status {
    <#
    .SYNOPSIS
        Updates the status bar message and, optionally, the token-usage/cost line.
    #>
    param(
        [string]$Message,
        [string]$Usage = $null
    )

    if ($script:StatusTextBlock) {
        $script:StatusTextBlock.Text = $Message
    }
    if ($Usage -and $script:UsageTextBlock) {
        $script:UsageTextBlock.Text = $Usage
    }
}

function Append-Log {
    <#
    .SYNOPSIS
        Appends a timestamped line to the activity log TextBox and, when enabled,
        to the log file on disk. Never logs API key values.
    #>
    param(
        [string]$Message
    )

    if (-not $script:LogTextBox) { return }

    $timestamp = (Get-Date).ToString('HH:mm:ss')
    $line = "[{0}] {1}" -f $timestamp, $Message
    $script:LogTextBox.AppendText("$line`n")
    $script:LogTextBox.ScrollToEnd()

    # [7] Append to log file if one is configured
    if ($script:LogFilePath) {
        try {
            Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8
        }
        catch {
            # Silently ignore file-write failures to prevent recursive log loops
        }
    }
}

function Get-ProviderDefinition {
    param(
        [string]$ProviderName = $script:ActiveProvider
    )

    if (-not $script:ProviderDefinitions.Contains($ProviderName)) {
        throw "Unsupported provider: $ProviderName"
    }

    return $script:ProviderDefinitions[$ProviderName]
}

function New-ProviderRuntimeSettings {
    param(
        [string]$ProviderName = $script:ActiveProvider
    )

    $provider = Get-ProviderDefinition -ProviderName $ProviderName

    return [ordered]@{
        Model                   = [string]$provider.DefaultModel
        PricePer1kInputTokens   = [double]$provider.DefaultPricePer1kInputTokens
        PricePer1kOutputTokens  = [double]$provider.DefaultPricePer1kOutputTokens
    }
}

function Get-ProviderRuntimeSettings {
    param(
        [string]$ProviderName = $script:ActiveProvider
    )

    if (-not $script:ProviderSettings.ContainsKey($ProviderName) -or -not $script:ProviderSettings[$ProviderName]) {
        $script:ProviderSettings[$ProviderName] = New-ProviderRuntimeSettings -ProviderName $ProviderName
    }

    return $script:ProviderSettings[$ProviderName]
}

function Protect-Secret {
    param([string]$PlainText)

    if ([string]::IsNullOrWhiteSpace($PlainText)) {
        return $null
    }

    $secureValue = ConvertTo-SecureString -String $PlainText -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secureValue
}

function Unprotect-Secret {
    param([string]$ProtectedText)

    if ([string]::IsNullOrWhiteSpace($ProtectedText)) {
        return $null
    }

    $secureValue = ConvertTo-SecureString -String $ProtectedText
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Load-ProviderSettings {
    $settings = @{
        ActiveProvider = $script:DefaultProvider
        Keys           = @{}
        Providers      = @{}
    }

    foreach ($providerName in $script:ProviderDefinitions.Keys) {
        $settings.Keys[$providerName] = $null
        $settings.Providers[$providerName] = New-ProviderRuntimeSettings -ProviderName $providerName
    }

    if (-not (Test-Path -LiteralPath $script:SettingsPath)) {
        return $settings
    }

    try {
        $rawSettings = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($rawSettings.ActiveProvider -and $script:ProviderDefinitions.Contains([string]$rawSettings.ActiveProvider)) {
            $settings.ActiveProvider = [string]$rawSettings.ActiveProvider
        }

        if ($rawSettings.Keys) {
            foreach ($providerName in $script:ProviderDefinitions.Keys) {
                $property = $rawSettings.Keys.PSObject.Properties[$providerName]
                if ($property -and -not [string]::IsNullOrWhiteSpace($property.Value)) {
                    $protectedValue = [string]$property.Value
                    $settings.Keys[$providerName] = Unprotect-Secret -ProtectedText $protectedValue
                }
            }
        }

        if ($rawSettings.Providers) {
            foreach ($providerName in $script:ProviderDefinitions.Keys) {
                $property = $rawSettings.Providers.PSObject.Properties[$providerName]
                if (-not $property -or -not $property.Value) {
                    continue
                }

                $providerSettings = New-ProviderRuntimeSettings -ProviderName $providerName
                $rawProvider = $property.Value

                if ($rawProvider.Model -and -not [string]::IsNullOrWhiteSpace([string]$rawProvider.Model)) {
                    $providerSettings.Model = [string]$rawProvider.Model
                }

                $inputPrice = $providerSettings.PricePer1kInputTokens
                if ($rawProvider.PricePer1kInputTokens -ne $null -and [double]::TryParse([string]$rawProvider.PricePer1kInputTokens, [ref]$inputPrice)) {
                    $providerSettings.PricePer1kInputTokens = $inputPrice
                }

                $outputPrice = $providerSettings.PricePer1kOutputTokens
                if ($rawProvider.PricePer1kOutputTokens -ne $null -and [double]::TryParse([string]$rawProvider.PricePer1kOutputTokens, [ref]$outputPrice)) {
                    $providerSettings.PricePer1kOutputTokens = $outputPrice
                }

                $settings.Providers[$providerName] = $providerSettings
            }
        }
    }
    catch {
        if ($script:LogTextBox) {
            Append-Log -Message ("WARNING: Failed to load saved settings: {0}" -f $_.Exception.Message)
        }
    }

    return $settings
}

function Save-ProviderSettings {
    try {
        if (-not (Test-Path -LiteralPath $script:SettingsDir)) {
            New-Item -ItemType Directory -Path $script:SettingsDir -Force | Out-Null
        }

        $keysPayload = [ordered]@{}
        foreach ($providerName in $script:ProviderDefinitions.Keys) {
            $plainText = $script:SavedApiKeys[$providerName]
            $keysPayload[$providerName] = if ([string]::IsNullOrWhiteSpace($plainText)) {
                $null
            }
            else {
                Protect-Secret -PlainText $plainText
            }
        }

        $providersPayload = [ordered]@{}
        foreach ($providerName in $script:ProviderDefinitions.Keys) {
            $providerSettings = Get-ProviderRuntimeSettings -ProviderName $providerName
            $providersPayload[$providerName] = [ordered]@{
                Model                  = [string]$providerSettings.Model
                PricePer1kInputTokens  = [double]$providerSettings.PricePer1kInputTokens
                PricePer1kOutputTokens = [double]$providerSettings.PricePer1kOutputTokens
            }
        }

        $settingsPayload = [ordered]@{
            ActiveProvider = $script:ActiveProvider
            Keys           = $keysPayload
            Providers      = $providersPayload
        }

        $settingsPayload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    }
    catch {
        throw "Unable to save provider settings: $($_.Exception.Message)"
    }
}

function Get-EnvironmentProviderKey {
    param([string]$ProviderName = $script:ActiveProvider)

    $provider = Get-ProviderDefinition -ProviderName $ProviderName
    foreach ($envVar in $provider.EnvVars) {
        $candidate = [Environment]::GetEnvironmentVariable($envVar)
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-ProviderCredentialState {
    param([string]$ProviderName = $script:ActiveProvider)

    if ($script:SessionApiKeys.ContainsKey($ProviderName) -and -not [string]::IsNullOrWhiteSpace($script:SessionApiKeys[$ProviderName])) {
        return [pscustomobject]@{ Source = 'session'; Summary = 'session key'; IsConfigured = $true }
    }

    if ($script:SavedApiKeys.ContainsKey($ProviderName) -and -not [string]::IsNullOrWhiteSpace($script:SavedApiKeys[$ProviderName])) {
        return [pscustomobject]@{ Source = 'saved'; Summary = 'saved key'; IsConfigured = $true }
    }

    if (Get-EnvironmentProviderKey -ProviderName $ProviderName) {
        return [pscustomobject]@{ Source = 'environment'; Summary = 'env key'; IsConfigured = $true }
    }

    return [pscustomobject]@{ Source = 'none'; Summary = 'no key configured'; IsConfigured = $false }
}

function Update-ProviderIndicator {
    if (-not $script:ProviderStatusTextBlock) {
        return
    }

    $provider = Get-ProviderDefinition
    $credentialState = Get-ProviderCredentialState
    $script:ProviderStatusTextBlock.Text = "Provider: {0} | {1}" -f $provider.DisplayName, $credentialState.Summary
}

function Set-ActiveProvider {
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        [switch]$SkipSave
    )

    $previousProviderName = if ($script:ProviderDefinitions.Contains($script:ActiveProvider)) {
        [string]$script:ActiveProvider
    }
    else {
        $null
    }
    $previousProviderSettings = if ($previousProviderName) {
        Get-ProviderRuntimeSettings -ProviderName $previousProviderName
    }
    else {
        $null
    }
    $nextProviderSettings = Get-ProviderRuntimeSettings -ProviderName $ProviderName

    $script:ActiveProvider = $ProviderName

    if ($script:ModelTextBox) {
        $shouldUpdateModel = [string]::IsNullOrWhiteSpace($script:ModelTextBox.Text)
        if (-not $shouldUpdateModel -and $previousProviderSettings) {
            $shouldUpdateModel = ($script:ModelTextBox.Text -eq [string]$previousProviderSettings.Model)
        }

        if ($shouldUpdateModel) {
            $script:ModelTextBox.Text = [string]$nextProviderSettings.Model
        }
    }

    Update-ProviderIndicator

    if (-not $SkipSave) {
        Save-ProviderSettings
    }
}

function Set-BusyState {
    <#
    .SYNOPSIS
        Toggles the busy/idle UI state: wait cursor, busy indicator visibility,
        button enable states, and the cancellation flag reset.
    #>
    param(
        [bool]$IsBusy,
        [string]$Message = $null
    )

    if ($script:BusyIndicatorTextBlock) {
        $script:BusyIndicatorTextBlock.Visibility = if ($IsBusy) { 'Visible' } else { 'Collapsed' }
    }

    $window.Cursor = if ($IsBusy) { [System.Windows.Input.Cursors]::Wait } else { [System.Windows.Input.Cursors]::Arrow }

    # These buttons are DISABLED while a run is in progress
    foreach ($btn in @(
        $script:RunButton,
        $script:BrowseButton,
        $script:CopyButton,
        $script:UsePromptButton,
        $script:CopyTaskOutputButton,
        $script:ModeRefineRadio,
        $script:ModeAnswerRadio,
        $script:ClearLogButton,
        $script:SavePresetButton,
        $script:LoadPresetButton,
        $script:ClearSessionKeyButton
    )) {
        if ($btn) { $btn.IsEnabled = -not $IsBusy }
    }

    # [3][4] Cancel and AcceptIteration are ENABLED during a run, disabled when idle
    if ($script:CancelButton)          { $script:CancelButton.IsEnabled          = $IsBusy }
    if ($script:AcceptIterationButton) { $script:AcceptIterationButton.IsEnabled = $IsBusy }

    # [3] Reset the flag when returning to idle so the next run starts clean
    if (-not $IsBusy) {
        $script:CancelRequested = $false
    }

    if ($Message) {
        Append-Log -Message $Message
    }
}

# =============================================================================
# [9] API key resolution — never exposes key values in logs or UI
# =============================================================================

function Get-ApiKey {
    <#
    .SYNOPSIS
        Returns the active provider API key using the following priority:
          1. Session key           (set interactively this session)
          2. Saved settings key    (stored securely for the current Windows user)
          3. Provider environment variable(s)
          4. A WPF PasswordBox modal prompt (stored as a session key, never persisted)
    #>
    param(
        [string]$ProviderName = $script:ActiveProvider
    )

    $provider = Get-ProviderDefinition -ProviderName $ProviderName

    if ($script:SessionApiKeys.ContainsKey($ProviderName) -and -not [string]::IsNullOrWhiteSpace($script:SessionApiKeys[$ProviderName])) {
        return $script:SessionApiKeys[$ProviderName]
    }

    if ($script:SavedApiKeys.ContainsKey($ProviderName) -and -not [string]::IsNullOrWhiteSpace($script:SavedApiKeys[$ProviderName])) {
        return $script:SavedApiKeys[$ProviderName]
    }

    $environmentKey = Get-EnvironmentProviderKey -ProviderName $ProviderName
    if ($environmentKey) {
        return $environmentKey
    }

    # Neither source is available — show a modal WPF PasswordBox dialog
    $inputXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="API Key Required" Width="440" Height="170"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False">
    <StackPanel Margin="14">
        <TextBlock TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="Enter the API key for this provider. It will be kept in memory for this session only and will not be written to disk or to any environment variable." />
        <PasswordBox Name="KeyBox" Margin="0,0,0,10" />
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="OkBtn"     Content="OK"     Padding="24,4" Margin="0,0,8,0" IsDefault="True" />
            <Button Name="CancelBtn" Content="Cancel" Padding="24,4" IsCancel="True" />
        </StackPanel>
    </StackPanel>
</Window>
'@

    $inputReader = New-Object System.Xml.XmlNodeReader ([xml]$inputXaml)
    $inputDialog = [Windows.Markup.XamlReader]::Load($inputReader)
    $keyBox      = $inputDialog.FindName('KeyBox')
    $okBtn       = $inputDialog.FindName('OkBtn')
    $cancelBtn   = $inputDialog.FindName('CancelBtn')

    $okBtn.Add_Click({
        $inputDialog.DialogResult = $true
        $inputDialog.Close()
    })
    $cancelBtn.Add_Click({
        $inputDialog.DialogResult = $false
        $inputDialog.Close()
    })

    $inputDialog.Title = "API Key Required - $($provider.DisplayName)"
    $inputDialog.Owner = $window
    $dialogResult = $inputDialog.ShowDialog()

    if ($dialogResult -ne $true -or [string]::IsNullOrWhiteSpace($keyBox.Password)) {
        throw "No API key provided. Operation cancelled."
    }

    $script:SessionApiKeys[$ProviderName] = $keyBox.Password
    Append-Log -Message ("Session API key accepted for {0} (stored in memory only — not persisted)." -f $provider.DisplayName)
    Update-ProviderIndicator
    return $script:SessionApiKeys[$ProviderName]
}

function Invoke-ProviderChatRequest {
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$Model,
        [Parameter()][string]$SystemMessage = '',
        [Parameter(Mandatory)][array]$Messages,
        [int]$MaxTokens = 4096
    )

    $provider = Get-ProviderDefinition -ProviderName $ProviderName
    $endpoint = "{0}/{1}" -f $provider.ApiBase.TrimEnd('/'), $provider.ChatEndpointPath.TrimStart('/')

    switch ($provider.Protocol) {
        'Anthropic' {
            $headers = @{
                'x-api-key'         = $ApiKey
                'anthropic-version' = '2023-06-01'
                'content-type'      = 'application/json'
            }

            $body = @{
                model      = $Model
                max_tokens = $MaxTokens
                messages   = @(
                    foreach ($message in $Messages) {
                        @{
                            role    = $message.role
                            content = @(
                                @{
                                    type = 'text'
                                    text = [string]$message.content
                                }
                            )
                        }
                    }
                )
            }

            if (-not [string]::IsNullOrWhiteSpace($SystemMessage)) {
                $body.system = $SystemMessage
            }

            $response = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -Body ($body | ConvertTo-Json -Depth 10) -TimeoutSec 120

            $responseText = @(
                foreach ($part in $response.content) {
                    if ($part.type -eq 'text') {
                        $part.text
                    }
                }
            ) -join "`n"

            return [pscustomobject]@{
                Text             = $responseText
                PromptTokens     = [int]($response.usage.input_tokens)
                CompletionTokens = [int]($response.usage.output_tokens)
            }
        }
        default {
            $headers = @{
                'Authorization' = "Bearer $ApiKey"
                'Content-Type'  = 'application/json'
            }

            $allMessages = @()
            if (-not [string]::IsNullOrWhiteSpace($SystemMessage)) {
                $allMessages += @{ role = 'system'; content = $SystemMessage }
            }
            $allMessages += $Messages

            $body = @{
                model    = $Model
                messages = $allMessages
            } | ConvertTo-Json -Depth 10

            $response = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -Body $body -TimeoutSec 120

            return [pscustomobject]@{
                Text             = $response.choices[0].message.content
                PromptTokens     = [int]($response.usage.prompt_tokens)
                CompletionTokens = [int]($response.usage.completion_tokens)
            }
        }
    }
}

# =============================================================================
# [5] Token estimation helper
# =============================================================================

function Get-TokenEstimate {
    <#
    .SYNOPSIS
        Returns a rough token count using the heuristic: ceiling(characters / 4).
    #>
    param([string]$Text)
    return [int]([Math]::Ceiling($Text.Length / 4))
}

# =============================================================================
# [2] Retry helper with exponential backoff
# =============================================================================

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Executes a ScriptBlock and retries on transient HTTP errors (429, 502, 503, 504)
        and network timeouts, using exponential backoff capped at 30 seconds.
        All other errors are re-thrown immediately.
    #>
    param(
        [Parameter(Mandatory)][ScriptBlock]$Action,
        [int]$MaxRetries  = 3,
        [int]$BaseDelayMs = 500
    )

    $retryableStatusCodes = @(429, 502, 503, 504)
    $attempt = 0

    while ($true) {
        try {
            return & $Action
        }
        catch {
            $statusCode = $null
            $isTimeout  = $false

            # PS 5.1 — System.Net.WebException
            if ($_.Exception -is [System.Net.WebException]) {
                if ($_.Exception.Response) {
                    try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
                }
                if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
                    $isTimeout = $true
                }
            }
            # PS 6+ — HttpResponseException carries the status code differently
            elseif ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            }

            # PS 6+ timeout surfaces as OperationCanceledException
            if ($_.Exception -is [System.OperationCanceledException])                        { $isTimeout = $true }
            if ($_.Exception.InnerException -is [System.OperationCanceledException])          { $isTimeout = $true }

            $isRetryable = $isTimeout -or ($statusCode -and ($retryableStatusCodes -contains $statusCode))

            if (-not $isRetryable -or $attempt -ge $MaxRetries) {
                throw
            }

            $attempt++
            $rawDelay = [int]([Math]::Pow(2, $attempt) * $BaseDelayMs)
            $delayMs  = if ($rawDelay -gt 30000) { 30000 } else { $rawDelay }

            $statusMsg = if ($statusCode) { "HTTP $statusCode" } elseif ($isTimeout) { "network timeout" } else { "transient error" }
            Append-Log -Message ("Retry {0}/{1} after {2} — waiting {3} ms..." -f $attempt, $MaxRetries, $statusMsg, $delayMs)
            Start-Sleep -Milliseconds $delayMs
        }
    }
}

# =============================================================================
# Core API functions
# =============================================================================

function Invoke-OpenAIRefinement {
    <#
    .SYNOPSIS
        Iteratively refines a prompt using the OpenAI Chat Completions API.

    .DESCRIPTION
        Sends the current draft through multiple refinement iterations, each time
        transforming it into a more structured, production-grade task description.
        Supports pre-run cost confirmation, per-iteration UI updates, and cancellation.
        Returns $null if the user declines the cost confirmation prompt.

    .OUTPUTS
        [pscustomobject] with FinalPrompt, Iterations, TotalTokens, TotalInputTokens,
        TotalOutputTokens, TotalCostUsd — or $null when cancelled before the loop starts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BasePrompt,
        [Parameter()][string]$RefinementGoals = '',
        [Parameter()][string]$FilePath        = '',
        [Parameter()][int]$Iterations         = $script:DefaultIterations,
        [Parameter()][string]$Model           = $script:DefaultModel,
        [Parameter()][string]$ProjectContext  = ''
    )

    $provider = Get-ProviderDefinition
    $providerSettings = Get-ProviderRuntimeSettings

    # [9] Resolve API key (may show interactive prompt)
    $apiKey = Get-ApiKey -ProviderName $script:ActiveProvider

    # [8] Input length validation
    if ($BasePrompt.Length -gt 32000) {
        throw ("BasePrompt is too long ({0} characters). Maximum is 32,000 characters." -f $BasePrompt.Length)
    }

    if ($Iterations -lt 1) { $Iterations = 1 }

    # [8] File path validation — validate existence and size before use
    $effectiveFilePath = ''
    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        if (-not (Test-Path -LiteralPath $FilePath)) {
            Append-Log -Message "WARNING: File not found — omitting file reference: $FilePath"
        }
        else {
            $fileSize = (Get-Item -LiteralPath $FilePath).Length
            if ($fileSize -gt (512 * 1024)) {
                Append-Log -Message ("WARNING: File exceeds 512 KB ({0} bytes) — omitting file reference." -f $fileSize)
            }
            else {
                $effectiveFilePath = $FilePath
            }
        }
    }

    $currentDraft      = $BasePrompt
    $iterationResults  = @()
    $totalInputTokens  = 0
    $totalOutputTokens = 0

    # Fixed system prompt for the Prompt Pilot role
    $systemInstructions = @"
You are a senior prompt architect for coding assistants (e.g., GitHub Copilot, Claude, ChatGPT Code).
Your job is to transform rough, underspecified user prompts into high-quality, production-grade task
descriptions that coding agents can execute reliably.

Always:
- Preserve the user's core intent.
- Clarify role, goals, inputs, outputs, and constraints.
- Add structure that makes it easy for the coding agent to follow (headings, bullet points, clear sections).
- Avoid adding fictional requirements; only infer what is strongly implied by the user's text.

Assume the user is a technically proficient engineer working on PowerShell-first automation projects of a variety of types.
Prefer precise, direct language over marketing fluff.
"@

    $defaultProjectContext = @"
Project context (for reference while refining the prompt):

- The user is a senior cloud engineer comfortable with PowerShell, .NET, and basic web dev.
- The codebase should prioritize robustness, maintainability, and observability over clever tricks.
- Inline comments and clear structure are more important than terseness.
- Write-Host is available for console output, and the user can run scripts in a home-lab environment with typical permissions.

Use this context to make the refined prompts more concrete and useful, but do not restate it verbatim unless it helps clarify the user's intent.
"@

    $effectiveProjectContext = if ($ProjectContext) { $ProjectContext } else { $defaultProjectContext }

    # [5] Pre-run token estimate and cost confirmation
    $sampleUserContent     = $effectiveProjectContext + $currentDraft + $RefinementGoals + $effectiveFilePath
    $estimatedInputPerIter = (Get-TokenEstimate -Text $systemInstructions) + (Get-TokenEstimate -Text $sampleUserContent)
    $estimatedTotalTokens  = $estimatedInputPerIter * $Iterations * 2   # x2 approximates output volume
    $estimatedCost         = (($estimatedInputPerIter * $Iterations / 1000.0) * [double]$providerSettings.PricePer1kInputTokens) +
                             (($estimatedInputPerIter * $Iterations / 1000.0) * [double]$providerSettings.PricePer1kOutputTokens)

    if ($estimatedCost -gt 0.05) {
        $confirmMsg = (
            "The estimated cost for this refinement run exceeds `$0.05.`n`n" +
            "  Iterations  : {0}`n" +
            "  Est. tokens : {1}`n" +
            "  Est. cost   : `${2:F6}`n`n" +
            "Proceed?"
        ) -f $Iterations, $estimatedTotalTokens, $estimatedCost

        $choice = [System.Windows.MessageBox]::Show(
            $confirmMsg,
            "Cost Confirmation",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )

        if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
            Append-Log -Message ("Refinement cancelled — estimated cost `${0:F6} exceeded `$0.05 threshold." -f $estimatedCost)
            return $null
        }
    }

    for ($i = 1; $i -le $Iterations; $i++) {

        # [3] Check for cancellation before starting each iteration
        if ($script:CancelRequested) {
            Append-Log -Message ("Refinement cancelled by user before iteration {0}." -f $i)
            break
        }

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
3. Context: Any relevant background that will help (assume a PowerShell-first automation project if not specified).
4. Deliverables: Exact formats or artifacts the coding assistant should produce.
5. Constraints and style: Technical constraints (language, stack, performance, safety) and writing/style preferences if present or implied.

Additional refinement goals (may be empty):
$RefinementGoals

If a file path is provided, assume the runtime system can handle uploads or references:
$effectiveFilePath

Output only the refined prompt, in well-formed Markdown, starting with a short one-line description and then the sections above.
Do not include your own commentary or analysis, only the final prompt the user should copy/paste into their coding assistant.
"@

        $messages = @(
            @{ role = 'user'; content = $userContent }
        )

        Show-Status -Message ("Calling {0} (iteration {1}/{2})..." -f $provider.DisplayName, $i, $Iterations)

        # [2] Retry wrapper; [2] explicit timeout
        $response = Invoke-WithRetry -Action {
            Invoke-ProviderChatRequest `
                -ProviderName  $script:ActiveProvider `
                -ApiKey        $apiKey `
                -Model         $Model `
                -SystemMessage $systemInstructions `
                -Messages      $messages `
                -MaxTokens     4096
        }

        $text = $response.Text

        if (-not $text) {
            throw "No text content returned from $($provider.DisplayName) in iteration $i."
        }

        $currentDraft = $text.Trim()

        # [4] Update FinalPromptTextBox after every iteration so AcceptIterationButton is useful
        if ($script:FinalPromptTextBox) {
            $script:FinalPromptTextBox.Text = $currentDraft
        }

        $totalInputTokens  += [int]$response.PromptTokens
        $totalOutputTokens += [int]$response.CompletionTokens

        $iterationResults += [pscustomobject]@{
            Iteration = $i
            Prompt    = $currentDraft
        }

        # [4] Per-iteration progress message
        Show-Status -Message ("Iteration {0}/{1} complete." -f $i, $Iterations)

        # Yield to the WPF dispatcher so Cancel/AcceptIteration clicks can register
        # between API calls without requiring a background thread.
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [Action]{},
            [System.Windows.Threading.DispatcherPriority]::Background
        )
    }

    $totalTokens = $totalInputTokens + $totalOutputTokens
    $cost = 0.0
    if ($totalTokens -gt 0) {
        $cost = (($totalInputTokens  / 1000.0) * [double]$providerSettings.PricePer1kInputTokens) +
            (($totalOutputTokens / 1000.0) * [double]$providerSettings.PricePer1kOutputTokens)
    }

    return [pscustomobject]@{
        FinalPrompt       = $currentDraft
        Iterations        = $iterationResults
        TotalTokens       = $totalTokens
        TotalInputTokens  = $totalInputTokens
        TotalOutputTokens = $totalOutputTokens
        TotalCostUsd      = [Math]::Round($cost, 6)
    }
}

function Invoke-OpenAIAnswer {
    <#
    .SYNOPSIS
        Executes a prompt (refined or raw) against the active provider API
        and returns the response text with token usage and estimated cost.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$FilePath = '',
        [Parameter()][string]$Model    = $script:DefaultModel
    )

    $provider = Get-ProviderDefinition
    $providerSettings = Get-ProviderRuntimeSettings

    # [9] Resolve API key
    $apiKey = Get-ApiKey -ProviderName $script:ActiveProvider

    # [8] Input length validation
    if ($Prompt.Length -gt 32000) {
        throw ("Prompt is too long ({0} characters). Maximum is 32,000 characters." -f $Prompt.Length)
    }

    # [8] File path validation
    $promptWithContext = $Prompt
    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        if (-not (Test-Path -LiteralPath $FilePath)) {
            Append-Log -Message "WARNING: File not found — omitting file reference: $FilePath"
        }
        else {
            $fileSize = (Get-Item -LiteralPath $FilePath).Length
            if ($fileSize -gt (512 * 1024)) {
                Append-Log -Message ("WARNING: File exceeds 512 KB ({0} bytes) — omitting file reference." -f $fileSize)
            }
            else {
                $promptWithContext = "$Prompt`n`nFile reference: $FilePath"
            }
        }
    }

    $messages = @(
        @{ role = 'user'; content = $promptWithContext }
    )

    # [2] Retry wrapper with timeout
    $response = Invoke-WithRetry -Action {
        Invoke-ProviderChatRequest `
            -ProviderName $script:ActiveProvider `
            -ApiKey       $apiKey `
            -Model        $Model `
            -Messages     $messages `
            -MaxTokens    4096
    }

    $text = $response.Text

    if (-not $text) {
        throw "No text content returned from $($provider.DisplayName) for task execution."
    }

    $totalInputTokens  = [int]$response.PromptTokens
    $totalOutputTokens = [int]$response.CompletionTokens

    $totalTokens = $totalInputTokens + $totalOutputTokens
    $cost = 0.0
    if ($totalTokens -gt 0) {
        $cost = (($totalInputTokens  / 1000.0) * [double]$providerSettings.PricePer1kInputTokens) +
            (($totalOutputTokens / 1000.0) * [double]$providerSettings.PricePer1kOutputTokens)
    }

    return [pscustomobject]@{
        OutputText        = $text.Trim()
        TotalTokens       = $totalTokens
        TotalInputTokens  = $totalInputTokens
        TotalOutputTokens = $totalOutputTokens
        TotalCostUsd      = [Math]::Round($cost, 6)
    }
}

function Show-TaskErrorDialog {
    <#
    .SYNOPSIS
        Modal error dialog for a failed background task. Kept as its own
        function so headless tests can override it instead of blocking on a
        real MessageBox.
    #>
    param([string]$Message)

    [System.Windows.MessageBox]::Show(
        "Failed to run task: $Message",
        "Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
}

function Complete-AnswerTask {
    param(
        [Parameter(Mandatory)][System.IAsyncResult]$Handle,
        [Parameter(Mandatory)][System.Management.Automation.PowerShell]$PowerShellInstance
    )

    try {
        $result = $PowerShellInstance.EndInvoke($Handle)
        if ($result.Count -lt 1) {
            throw "No response object returned for task execution."
        }

        $taskResult = $result[$result.Count - 1]
        $script:TaskOutputTextBox.Text = [string]$taskResult.OutputText

        if ($taskResult.Warnings) {
            foreach ($warning in $taskResult.Warnings) {
                Append-Log -Message ([string]$warning)
            }
        }

        $usageText = "Tokens: {0} (in {1} / out {2}) | Cost: `${3}" -f `
            $taskResult.TotalTokens, $taskResult.TotalInputTokens, $taskResult.TotalOutputTokens, $taskResult.TotalCostUsd
        Show-Status -Message "Task complete." -Usage $usageText
        Append-Log -Message ("Task complete. {0}" -f $usageText)
    }
    catch {
        # [12] A stopped pipeline is the operator's Cancel, not an application
        # error — report it as such and skip the error dialog.
        if ($PowerShellInstance.InvocationStateInfo.State -eq 'Stopped') {
            Show-Status -Message "Task cancelled."
            Append-Log  -Message "Task cancelled by operator."
        }
        else {
            $message = $_.Exception.Message
            if ($PowerShellInstance.Streams.Error.Count -gt 0) {
                $message = [string]$PowerShellInstance.Streams.Error[0]
            }

            Append-Log -Message ("Task failed: {0}" -f $message)
            Show-Status -Message ("Task failed: {0}" -f $message)
            Show-TaskErrorDialog -Message $message
        }
    }
    finally {
        Set-BusyState -IsBusy $false
        $PowerShellInstance.Dispose()
        $script:AnswerTaskState = $null
    }
}

function Stop-AnswerTask {
    <#
    .SYNOPSIS
        Requests cancellation of the running background answer task. Safe to
        call when no task is running. UI cleanup happens in Complete-AnswerTask
        when the poll timer observes the stopped pipeline.
    #>
    if (-not $script:AnswerTaskState) { return }

    try {
        $null = $script:AnswerTaskState.PowerShell.BeginStop($null, $null)
        Show-Status -Message "Cancelling task..."
        Append-Log  -Message "Cancel requested — stopping the background task."
    }
    catch {
        Append-Log -Message ("Cancel request failed: {0}" -f $_.Exception.Message)
    }
}

function Start-AnswerTask {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$FilePath = '',
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)][string]$ApiKey
    )

    if ($script:AnswerTaskState) {
        throw "A task is already running."
    }

    $provider = Get-ProviderDefinition -ProviderName $ProviderName
    $providerSettings = Get-ProviderRuntimeSettings -ProviderName $ProviderName

    $backgroundScript = {
        param($Prompt, $FilePath, $Model, $ProviderName, $Provider, $ProviderSettings, $ApiKey)

        if ($Prompt.Length -gt 32000) {
            throw ("Prompt is too long ({0} characters). Maximum is 32,000 characters." -f $Prompt.Length)
        }

        $promptWithContext = $Prompt
        $warnings = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
            if (-not (Test-Path -LiteralPath $FilePath)) {
                $warnings.Add("WARNING: File not found — omitting file reference: $FilePath")
            }
            else {
                $fileSize = (Get-Item -LiteralPath $FilePath).Length
                if ($fileSize -gt (512 * 1024)) {
                    $warnings.Add(("WARNING: File exceeds 512 KB ({0} bytes) — omitting file reference." -f $fileSize))
                }
                else {
                    $promptWithContext = "$Prompt`n`nFile reference: $FilePath"
                }
            }
        }

        $messages = @(
            @{ role = 'user'; content = $promptWithContext }
        )

        $endpoint = "{0}/{1}" -f $Provider.ApiBase.TrimEnd('/'), $Provider.ChatEndpointPath.TrimStart('/')
        switch ($Provider.Protocol) {
            'Anthropic' {
                $headers = @{
                    'x-api-key'         = $ApiKey
                    'anthropic-version' = '2023-06-01'
                    'content-type'      = 'application/json'
                }

                $body = @{
                    model      = $Model
                    max_tokens = 4096
                    messages   = @(
                        foreach ($message in $messages) {
                            @{
                                role    = $message.role
                                content = @(
                                    @{
                                        type = 'text'
                                        text = [string]$message.content
                                    }
                                )
                            }
                        }
                    )
                }

                $response = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -Body ($body | ConvertTo-Json -Depth 10) -TimeoutSec 120
                $responseText = @(
                    foreach ($part in $response.content) {
                        if ($part.type -eq 'text') {
                            $part.text
                        }
                    }
                ) -join "`n"

                $promptTokens = [int]$response.usage.input_tokens
                $completionTokens = [int]$response.usage.output_tokens
                $text = $responseText
            }
            default {
                $headers = @{
                    'Authorization' = "Bearer $ApiKey"
                    'Content-Type'  = 'application/json'
                }

                $body = @{
                    model    = $Model
                    messages = $messages
                } | ConvertTo-Json -Depth 10

                $response = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -Body $body -TimeoutSec 120
                $promptTokens = [int]$response.usage.prompt_tokens
                $completionTokens = [int]$response.usage.completion_tokens
                $text = $response.choices[0].message.content
            }
        }

        if (-not $text) {
            throw "No text content returned from $($Provider.DisplayName) for task execution."
        }

        $totalTokens = $promptTokens + $completionTokens
        $cost = 0.0
        if ($totalTokens -gt 0) {
            $cost = (($promptTokens / 1000.0) * [double]$ProviderSettings.PricePer1kInputTokens) +
                (($completionTokens / 1000.0) * [double]$ProviderSettings.PricePer1kOutputTokens)
        }

        return [pscustomobject]@{
            OutputText        = $text.Trim()
            TotalTokens       = $totalTokens
            TotalInputTokens  = $promptTokens
            TotalOutputTokens = $completionTokens
            TotalCostUsd      = [Math]::Round($cost, 6)
            Warnings          = @($warnings)
        }
    }

    $powerShellInstance = [System.Management.Automation.PowerShell]::Create()
    $null = $powerShellInstance.AddScript($backgroundScript.ToString())
    $null = $powerShellInstance.AddArgument($Prompt)
    $null = $powerShellInstance.AddArgument($FilePath)
    $null = $powerShellInstance.AddArgument($Model)
    $null = $powerShellInstance.AddArgument($ProviderName)
    $null = $powerShellInstance.AddArgument($provider)
    $null = $powerShellInstance.AddArgument($providerSettings)
    $null = $powerShellInstance.AddArgument($ApiKey)

    $handle = $powerShellInstance.BeginInvoke()
    $script:AnswerTaskState = [pscustomobject]@{
        PowerShell = $powerShellInstance
        Handle     = $handle
    }

    if (-not $script:AnswerTaskTimer) {
        $script:AnswerTaskTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:AnswerTaskTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:AnswerTaskTimer.Add_Tick({
            if (-not $script:AnswerTaskState) {
                $script:AnswerTaskTimer.Stop()
                return
            }

            if (-not $script:AnswerTaskState.Handle.IsCompleted) {
                return
            }

            $script:AnswerTaskTimer.Stop()
            Complete-AnswerTask -Handle $script:AnswerTaskState.Handle -PowerShellInstance $script:AnswerTaskState.PowerShell
        })
    }

    $script:AnswerTaskTimer.Start()
}

# =============================================================================
# Load XAML and create window
# =============================================================================

$script:ScriptDir  = if ($PSCommandPath) {
    [System.IO.Path]::GetDirectoryName($PSCommandPath)
} else {
    (Get-Location).Path
}
$script:PresetsDir = Join-Path $script:ScriptDir 'presets'

$xamlPath = Join-Path -Path $script:ScriptDir -ChildPath 'Prompt_Pilot.MainWindow.xaml'
if (-not (Test-Path -LiteralPath $xamlPath)) {
    throw "XAML file not found at $xamlPath"
}

[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
$reader    = New-Object System.Xml.XmlNodeReader $xaml
$window    = [Windows.Markup.XamlReader]::Load($reader)

# Cache every control we reference from PowerShell
$script:PromptTextBox          = $window.FindName('PromptTextBox')
$script:GoalsTextBox           = $window.FindName('GoalsTextBox')
$script:ProjectContextTextBox  = $window.FindName('ProjectContextTextBox')
$script:FilePathTextBox        = $window.FindName('FilePathTextBox')
$script:BrowseButton           = $window.FindName('BrowseButton')
$script:RunButton              = $window.FindName('RunButton')
$script:CopyButton             = $window.FindName('CopyButton')
$script:AcceptIterationButton  = $window.FindName('AcceptIterationButton')
$script:SavePresetButton       = $window.FindName('SavePresetButton')
$script:LoadPresetButton       = $window.FindName('LoadPresetButton')
$script:ClearSessionKeyButton  = $window.FindName('ClearSessionKeyButton')
$script:IterationsTextBox      = $window.FindName('IterationsTextBox')
$script:ModelTextBox           = $window.FindName('ModelTextBox')
$script:FinalPromptTextBox     = $window.FindName('FinalPromptTextBox')
$script:HistoryTextBox         = $window.FindName('HistoryTextBox')
$script:StatusTextBlock        = $window.FindName('StatusTextBlock')
$script:ProviderStatusTextBlock = $window.FindName('ProviderStatusTextBlock')
$script:UsageTextBlock         = $window.FindName('UsageTextBlock')
$script:ModeRefineRadio        = $window.FindName('ModeRefineRadio')
$script:ModeAnswerRadio        = $window.FindName('ModeAnswerRadio')
$script:UsePromptButton        = $window.FindName('UsePromptButton')
$script:CopyTaskOutputButton   = $window.FindName('CopyTaskOutputButton')
$script:TaskOutputTextBox      = $window.FindName('TaskOutputTextBox')
$script:LogTextBox             = $window.FindName('LogTextBox')
$script:BusyIndicatorTextBlock = $window.FindName('BusyIndicatorTextBlock')
$script:ClearLogButton         = $window.FindName('ClearLogButton')
$script:CancelButton           = $window.FindName('CancelButton')
$script:LogToFileCheckBox      = $window.FindName('LogToFileCheckBox')
$script:LogFilePathTextBox     = $window.FindName('LogFilePathTextBox')
$script:MenuSettingsApiKey      = $window.FindName('MenuSettingsApiKey')
$script:MenuHelpBasePrompt      = $window.FindName('MenuHelpBasePrompt')
$script:MenuHelpRefinementGoals = $window.FindName('MenuHelpRefinementGoals')
$script:MenuHelpProjectContext  = $window.FindName('MenuHelpProjectContext')
$script:MenuHelpFile            = $window.FindName('MenuHelpFile')
$script:MenuHelpAbout           = $window.FindName('MenuHelpAbout')

# Required control validation — fail fast with a clear message
if (-not $script:PromptTextBox)         { throw "Failed to find PromptTextBox in XAML." }
if (-not $script:RunButton)             { throw "Failed to find RunButton in XAML." }
if (-not $script:StatusTextBlock)       { throw "Failed to find StatusTextBlock in XAML." }
if (-not $script:ModeRefineRadio -or
    -not $script:ModeAnswerRadio)       { throw "Failed to find mode toggle radio buttons in XAML." }
if (-not $script:CopyTaskOutputButton)  { throw "Failed to find CopyTaskOutputButton in XAML." }
if (-not $script:TaskOutputTextBox)     { throw "Failed to find TaskOutputTextBox in XAML." }
if (-not $script:LogTextBox)            { throw "Failed to find LogTextBox in XAML." }
if (-not $script:ClearLogButton)        { throw "Failed to find ClearLogButton in XAML." }
if (-not $script:CancelButton)          { throw "Failed to find CancelButton in XAML." }
if (-not $script:LogToFileCheckBox)     { throw "Failed to find LogToFileCheckBox in XAML." }
if (-not $script:LogFilePathTextBox)    { throw "Failed to find LogFilePathTextBox in XAML." }
if (-not $script:ProviderStatusTextBlock) { throw "Failed to find ProviderStatusTextBlock in XAML." }

# Seed refinement goals with a sensible default
if (-not $script:GoalsTextBox.Text) {
    $script:GoalsTextBox.Text = @"
- Preserve the user's core intent
- Clarify role, goals, inputs, outputs, and constraints
- Add structure that makes it easy for coding agents to follow
- Avoid adding fictional requirements; only infer what is strongly implied
- Prefer precise, direct language over marketing fluff
"@
}

$loadedProviderSettings = Load-ProviderSettings
$script:SavedApiKeys = $loadedProviderSettings.Keys
$script:ProviderSettings = $loadedProviderSettings.Providers
$script:CurrentMode = 'Refine'
$script:UsageTextBlock.Text = "Tokens: 0 | Cost: `$0.000000"
Set-ActiveProvider -ProviderName $loadedProviderSettings.ActiveProvider -SkipSave

# =============================================================================
# Mode management
# =============================================================================

function Set-Mode {
    <#
    .SYNOPSIS
        Switches the UI between Refine and Answer modes, updating button labels
        and control states to match.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Refine','Answer')]
        [string]$Mode
    )

    $script:CurrentMode = $Mode
    $script:ModeRefineRadio.IsChecked = ($Mode -eq 'Refine')
    $script:ModeAnswerRadio.IsChecked = ($Mode -eq 'Answer')
    $script:RunButton.Content         = if ($Mode -eq 'Refine') { 'Run Refinement' } else { 'Run Task' }
    $script:HistoryTextBox.IsEnabled  = ($Mode -eq 'Refine')
    $script:HistoryTextBox.Opacity    = if ($Mode -eq 'Refine') { 1.0 } else { 0.65 }

    if ($Mode -eq 'Refine') {
        Show-Status -Message "Ready to refine."
    }
    else {
        $script:HistoryTextBox.Text = ''
        Show-Status -Message "Ready to answer the task."
    }
}

# =============================================================================
# Run functions
# =============================================================================

function Run-Refinement {
    <#
    .SYNOPSIS
        Reads UI inputs, invokes the iterative refinement API call, and populates
        the output controls. Guards against a $null result (user cancelled at cost prompt).
    #>
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

    $goals          = $script:GoalsTextBox.Text
    $projectContext = $script:ProjectContextTextBox.Text
    $file           = $script:FilePathTextBox.Text
    # [1] Fall back to the centralised default model
    $providerSettings = Get-ProviderRuntimeSettings
    $model          = if ($script:ModelTextBox.Text) { $script:ModelTextBox.Text } else { [string]$providerSettings.Model }

    $iterRaw    = $script:IterationsTextBox.Text
    $iterations = $script:DefaultIterations
    if ([int]::TryParse($iterRaw, [ref]$iterations) -eq $false -or $iterations -lt 1) {
        $iterations = $script:DefaultIterations
    }

    $script:TaskOutputTextBox.Text = ''
    Show-Status -Message "Running refinement..." -Usage "Tokens: 0 | Cost: `$0.000000"

    Set-BusyState -IsBusy $true -Message ("Refinement started (iterations: {0}, model: {1})" -f $iterations, $model)
    try {
        $result = Invoke-OpenAIRefinement `
            -BasePrompt      $basePrompt `
            -RefinementGoals $goals `
            -ProjectContext  $projectContext `
            -FilePath        $file `
            -Iterations      $iterations `
            -Model           $model
    }
    catch {
        Append-Log -Message ("Refinement failed: {0}" -f $_.Exception.Message)
        throw
    }
    finally {
        Set-BusyState -IsBusy $false
    }

    # [5] Guard: user declined the cost confirmation
    if ($null -eq $result) {
        Show-Status -Message "Refinement cancelled."
        return
    }

    $script:FinalPromptTextBox.Text = $result.FinalPrompt

    $historyLines = @()
    foreach ($item in $result.Iterations) {
        $historyLines += ("===== Iteration {0} =====" -f $item.Iteration)
        $historyLines += $item.Prompt
        $historyLines += ""
    }
    $script:HistoryTextBox.Text = ($historyLines -join [Environment]::NewLine)

    $usageText = "Tokens: {0} (in {1} / out {2}) | Cost: `${3}" -f `
        $result.TotalTokens, $result.TotalInputTokens, $result.TotalOutputTokens, $result.TotalCostUsd
    Show-Status -Message "Refinement complete." -Usage $usageText
    Append-Log -Message ("Refinement complete. {0}" -f $usageText)
}

function Run-AnswerTask {
    <#
    .SYNOPSIS
        Reads UI inputs, starts a background task request, and updates the UI
        when the model's response is ready.
    #>
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
    # [1] Fall back to the centralised default model
    $providerSettings = Get-ProviderRuntimeSettings
    $model = if ($script:ModelTextBox.Text) { $script:ModelTextBox.Text } else { [string]$providerSettings.Model }

    Show-Status -Message "Running task..." -Usage "Tokens: 0 | Cost: `$0.000000"
    $script:TaskOutputTextBox.Text = ''

    Set-BusyState -IsBusy $true -Message ("Task started (model: {0})" -f $model)
    try {
        $apiKey = Get-ApiKey -ProviderName $script:ActiveProvider
        Start-AnswerTask -Prompt $promptToRun -FilePath $file -Model $model -ProviderName $script:ActiveProvider -ApiKey $apiKey
        # [12] Cancel stays ENABLED: it is the only recovery from a slow or hung
        # request short of killing the app. Accept-draft is refine-only, so it
        # stays off while a background task runs.
        if ($script:AcceptIterationButton) { $script:AcceptIterationButton.IsEnabled = $false }
        Append-Log -Message "Task request is running in the background."
    }
    catch {
        Set-BusyState -IsBusy $false
        Append-Log -Message ("Task failed: {0}" -f $_.Exception.Message)
        throw
    }
}

function Invoke-ModeAction {
    <#
    .SYNOPSIS
        Dispatches to Run-Refinement or Run-AnswerTask based on the current mode.
    #>
    if ($script:CurrentMode -eq 'Answer') {
        Run-AnswerTask
    }
    else {
        Run-Refinement
    }
}

# =============================================================================
# Event handlers
# =============================================================================

# Mode toggles
$script:ModeRefineRadio.Add_Checked({ Set-Mode -Mode 'Refine' })
$script:ModeAnswerRadio.Add_Checked({ Set-Mode -Mode 'Answer' })

# File browse
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

# Primary run button
$script:RunButton.Add_Click({
    try {
        Invoke-ModeAction
    }
    catch {
        $msg = "Action failed: $($_.Exception.Message)"
        Show-Status -Message $msg
        Append-Log  -Message $msg
        [System.Windows.MessageBox]::Show(
            $msg,
            "Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
})

# [3] Cancel — refine mode: signals the loop to stop after the current call.
# [12] Answer mode: stops the background pipeline; the poll timer then reports
# the cancellation and restores the UI through Complete-AnswerTask.
$script:CancelButton.Add_Click({
    if ($script:AnswerTaskState) {
        Stop-AnswerTask
        return
    }

    $script:CancelRequested = $true
    Append-Log -Message "Cancel requested — will stop after the current iteration completes."
})

# [4] Accept Current Draft — promotes the in-progress draft and cancels remaining iterations
$script:AcceptIterationButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:FinalPromptTextBox.Text)) {
        $script:PromptTextBox.Text = $script:FinalPromptTextBox.Text
        $script:CancelRequested   = $true
        Append-Log -Message "Current draft accepted — remaining iterations will be skipped."
    }
})

# Use this Prompt — switches to Answer mode and runs immediately
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

# Clear log
$script:ClearLogButton.Add_Click({
    try {
        $script:LogTextBox.Clear()
        Append-Log -Message "Log cleared."
    }
    catch {
        Append-Log -Message ("Failed to clear log: {0}" -f $_.Exception.Message)
    }
})

# Copy final prompt to clipboard
$script:CopyButton.Add_Click({
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:FinalPromptTextBox.Text)) {
            [System.Windows.Clipboard]::SetText($script:FinalPromptTextBox.Text)
            Show-Status -Message "Final prompt copied to clipboard."
            Append-Log  -Message "Final prompt copied to clipboard."
        }
    }
    catch {
        Show-Status -Message "Failed to copy to clipboard: $($_.Exception.Message)"
        Append-Log  -Message ("Copy failed: {0}" -f $_.Exception.Message)
    }
})

# Copy task output to clipboard
$script:CopyTaskOutputButton.Add_Click({
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:TaskOutputTextBox.Text)) {
            [System.Windows.Clipboard]::SetText($script:TaskOutputTextBox.Text)
            Show-Status -Message "Task output copied to clipboard."
            Append-Log  -Message "Task output copied to clipboard."
        }
    }
    catch {
        Show-Status -Message "Failed to copy task output: $($_.Exception.Message)"
        Append-Log  -Message ("Copy task output failed: {0}" -f $_.Exception.Message)
    }
})

# [6] Save Preset
$script:SavePresetButton.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $script:PresetsDir)) {
            New-Item -ItemType Directory -Path $script:PresetsDir | Out-Null
        }

        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Title            = "Save Preset"
        $sfd.Filter           = "JSON preset (*.json)|*.json"
        $sfd.InitialDirectory = $script:PresetsDir
        $sfd.FileName         = "preset_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"

        if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            @{
                Model          = $script:ModelTextBox.Text
                Iterations     = $script:IterationsTextBox.Text
                Goals          = $script:GoalsTextBox.Text
                ProjectContext = $script:ProjectContextTextBox.Text
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sfd.FileName -Encoding UTF8

            Append-Log -Message ("Preset saved: {0}" -f $sfd.FileName)
        }
    }
    catch {
        Append-Log -Message ("Save preset failed: {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show(
            "Failed to save preset: $($_.Exception.Message)",
            "Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
})

# [6] Load Preset
$script:LoadPresetButton.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $script:PresetsDir)) {
            New-Item -ItemType Directory -Path $script:PresetsDir | Out-Null
        }

        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title            = "Load Preset"
        $ofd.Filter           = "JSON preset (*.json)|*.json"
        $ofd.InitialDirectory = $script:PresetsDir

        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $preset      = Get-Content -LiteralPath $ofd.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
            $presentKeys = $preset.PSObject.Properties.Name
            $requiredKeys = @('Model', 'Iterations', 'Goals', 'ProjectContext')
            $missingKeys  = $requiredKeys | Where-Object { $presentKeys -notcontains $_ }

            if ($missingKeys) {
                Append-Log -Message ("Preset missing keys (skipped): {0}" -f ($missingKeys -join ', '))
            }

            if ($presentKeys -contains 'Model')          { $script:ModelTextBox.Text          = $preset.Model }
            if ($presentKeys -contains 'Iterations')     { $script:IterationsTextBox.Text     = $preset.Iterations }
            if ($presentKeys -contains 'Goals')          { $script:GoalsTextBox.Text          = $preset.Goals }
            if ($presentKeys -contains 'ProjectContext') { $script:ProjectContextTextBox.Text = $preset.ProjectContext }

            Append-Log -Message ("Preset loaded: {0}" -f $ofd.FileName)
        }
    }
    catch {
        Append-Log -Message ("Load preset failed: {0}" -f $_.Exception.Message)
        [System.Windows.MessageBox]::Show(
            "Failed to load preset: $($_.Exception.Message)",
            "Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
})

# [9] Clear Session Key
$script:ClearSessionKeyButton.Add_Click({
    $provider = Get-ProviderDefinition
    $script:SessionApiKeys.Remove($script:ActiveProvider) | Out-Null
    Append-Log  -Message ("Session API key cleared for {0}." -f $provider.DisplayName)
    Show-Status -Message ("Session API key cleared for {0}." -f $provider.DisplayName)
    Update-ProviderIndicator
})

# [7] Log-to-file checkbox: Checked — prompt for a save path
$script:LogToFileCheckBox.Add_Checked({
    try {
        $sfd          = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Title    = "Choose log file location"
        $sfd.Filter   = "Log files (*.log)|*.log|All files (*.*)|*.*"
        $sfd.FileName = "Prompt_Pilot_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

        if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:LogFilePath = $sfd.FileName
            $script:LogFilePathTextBox.Text = $sfd.FileName
            Append-Log -Message ("File logging enabled: {0}" -f $sfd.FileName)
        }
        else {
            # User cancelled the dialog — revert without re-triggering Unchecked handler
            $script:LogToFileCheckBox.IsChecked = $false
        }
    }
    catch {
        $script:LogToFileCheckBox.IsChecked = $false
        Append-Log -Message ("Failed to configure log file: {0}" -f $_.Exception.Message)
    }
})

# [7] Log-to-file checkbox: Unchecked — disable file logging
$script:LogToFileCheckBox.Add_Unchecked({
    $script:LogFilePath = $null
    $script:LogFilePathTextBox.Text = ''
    Append-Log -Message "File logging disabled."
})

# =============================================================================
# Menu — Settings
# =============================================================================

# Settings → Configure API Key
$script:MenuSettingsApiKey.Add_Click({
    $settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Settings — Provider Settings" Width="500" Height="470"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False">
    <StackPanel Margin="14">
        <TextBlock Text="Active provider:" Margin="0,0,0,4" />
        <ComboBox Name="ProviderComboBox" Margin="0,0,0,10" />
        <TextBlock Name="StatusLabel" TextWrapping="Wrap" Margin="0,0,0,10" />
        <TextBlock Text="Model for selected provider:" Margin="0,0,0,4" />
        <TextBox Name="ModelBox" Margin="0,0,0,10" />
        <TextBlock Text="Input price per 1K tokens (USD):" Margin="0,0,0,4" />
        <TextBox Name="InputPriceBox" Margin="0,0,0,10" />
        <TextBlock Text="Output price per 1K tokens (USD):" Margin="0,0,0,4" />
        <TextBox Name="OutputPriceBox" Margin="0,0,0,10" />
        <CheckBox Name="RemoveSavedKeyCheckBox"
                  Content="Remove saved key for selected provider"
                  Margin="0,0,0,10" />
        <TextBlock Text="New API key (leave blank to keep current):" Margin="0,0,0,4" />
        <PasswordBox Name="KeyBox" Margin="0,0,0,10" />
        <TextBlock Text="Models and token prices are stored per provider. Keys entered here are saved securely for the current Windows user. Run-time prompts still remain session-only."
                   TextWrapping="Wrap"
                   Foreground="Gray"
                   FontSize="11"
                   Margin="0,0,0,10" />
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="OkBtn"     Content="OK"     Padding="24,4" Margin="0,0,8,0" IsDefault="True" />
            <Button Name="CancelBtn" Content="Cancel" Padding="24,4" IsCancel="True" />
        </StackPanel>
    </StackPanel>
</Window>
'@

    $settingsReader = New-Object System.Xml.XmlNodeReader ([xml]$settingsXaml)
    $settingsDialog = [Windows.Markup.XamlReader]::Load($settingsReader)
    $providerCombo   = $settingsDialog.FindName('ProviderComboBox')
    $statusLabel    = $settingsDialog.FindName('StatusLabel')
    $modelBox       = $settingsDialog.FindName('ModelBox')
    $inputPriceBox  = $settingsDialog.FindName('InputPriceBox')
    $outputPriceBox = $settingsDialog.FindName('OutputPriceBox')
    $removeCheckBox = $settingsDialog.FindName('RemoveSavedKeyCheckBox')
    $keyBox         = $settingsDialog.FindName('KeyBox')
    $okBtn          = $settingsDialog.FindName('OkBtn')
    $cancelBtn      = $settingsDialog.FindName('CancelBtn')

    foreach ($providerName in $script:ProviderDefinitions.Keys) {
        [void]$providerCombo.Items.Add($providerName)
    }
    $providerCombo.SelectedItem = $script:ActiveProvider

    $updateStatus = {
        $selectedProvider = [string]$providerCombo.SelectedItem
        if ([string]::IsNullOrWhiteSpace($selectedProvider)) {
            return
        }

        $provider = Get-ProviderDefinition -ProviderName $selectedProvider
        $state = Get-ProviderCredentialState -ProviderName $selectedProvider
        $providerSettings = Get-ProviderRuntimeSettings -ProviderName $selectedProvider
        $statusLabel.Text = "{0} is currently using {1}. Update the model and pricing if needed, and leave the key box blank to keep the current saved value." -f $provider.DisplayName, $state.Summary
        $modelBox.Text = [string]$providerSettings.Model
        $inputPriceBox.Text = ([double]$providerSettings.PricePer1kInputTokens).ToString('0.######')
        $outputPriceBox.Text = ([double]$providerSettings.PricePer1kOutputTokens).ToString('0.######')
    }

    $providerCombo.Add_SelectionChanged($updateStatus)
    & $updateStatus

    $okBtn.Add_Click({
        $settingsDialog.DialogResult = $true
        $settingsDialog.Close()
    })
    $cancelBtn.Add_Click({
        $settingsDialog.DialogResult = $false
        $settingsDialog.Close()
    })

    $settingsDialog.Owner = $window
    $dlgResult = $settingsDialog.ShowDialog()

    if ($dlgResult -eq $true) {
        $selectedProvider = [string]$providerCombo.SelectedItem
        if ([string]::IsNullOrWhiteSpace($selectedProvider)) {
            $selectedProvider = $script:DefaultProvider
        }

        $providerSettings = Get-ProviderRuntimeSettings -ProviderName $selectedProvider
        $modelValue = if ([string]::IsNullOrWhiteSpace($modelBox.Text)) {
            [string]$providerSettings.Model
        }
        else {
            $modelBox.Text.Trim()
        }

        $inputPrice = [double]$providerSettings.PricePer1kInputTokens
        if (-not [string]::IsNullOrWhiteSpace($inputPriceBox.Text) -and -not [double]::TryParse($inputPriceBox.Text.Trim(), [ref]$inputPrice)) {
            [System.Windows.MessageBox]::Show(
                "Enter a valid input price per 1K tokens.",
                "Invalid setting",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
            return
        }

        $outputPrice = [double]$providerSettings.PricePer1kOutputTokens
        if (-not [string]::IsNullOrWhiteSpace($outputPriceBox.Text) -and -not [double]::TryParse($outputPriceBox.Text.Trim(), [ref]$outputPrice)) {
            [System.Windows.MessageBox]::Show(
                "Enter a valid output price per 1K tokens.",
                "Invalid setting",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
            return
        }

        $script:ProviderSettings[$selectedProvider] = [ordered]@{
            Model                  = $modelValue
            PricePer1kInputTokens  = [double]$inputPrice
            PricePer1kOutputTokens = [double]$outputPrice
        }

        Set-ActiveProvider -ProviderName $selectedProvider -SkipSave

        if ($removeCheckBox.IsChecked -eq $true) {
            $script:SavedApiKeys[$selectedProvider] = $null
            $script:SessionApiKeys.Remove($selectedProvider) | Out-Null
            Append-Log -Message ("Saved API key removed for {0}." -f (Get-ProviderDefinition -ProviderName $selectedProvider).DisplayName)
        }

        if (-not [string]::IsNullOrWhiteSpace($keyBox.Password)) {
            $script:SavedApiKeys[$selectedProvider] = $keyBox.Password
            Append-Log -Message ("Saved API key updated for {0}." -f (Get-ProviderDefinition -ProviderName $selectedProvider).DisplayName)
        }

        Save-ProviderSettings
        Append-Log -Message ("Provider settings updated for {0}." -f (Get-ProviderDefinition -ProviderName $selectedProvider).DisplayName)

        Update-ProviderIndicator
        Show-Status -Message ("Active provider set to {0}." -f (Get-ProviderDefinition -ProviderName $selectedProvider).DisplayName)
    }
})

# =============================================================================
# Menu — Help
# =============================================================================

$script:MenuHelpBasePrompt.Add_Click({
    [System.Windows.MessageBox]::Show(
        "Base Prompt`n`n" +
        "The raw, rough-draft instruction that is the starting point for refinement.`n`n" +
        "Enter the task or question you want a coding assistant to answer. It can be a " +
        "single sentence or several paragraphs. In Refine mode the text is iteratively " +
        "transformed into a structured prompt with Role, Goals, Context, Deliverables, " +
        "and Constraints sections.`n`n" +
        "In Answer mode this field is sent directly to OpenAI and the model's response " +
        "appears in the Task Output panel.",
        "Help — Base Prompt",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
})

$script:MenuHelpRefinementGoals.Add_Click({
    [System.Windows.MessageBox]::Show(
        "Refinement Goals`n`n" +
        "Optional bullet points that guide how the refiner reshapes your Base Prompt.`n`n" +
        "Use this field to steer the style or emphasis of the output. Examples:`n" +
        "  - Focus on Python 3.12 compatibility`n" +
        "  - Avoid adding test requirements`n" +
        "  - Keep the result under 300 words`n`n" +
        "The default goals produce a general-purpose, well-structured prompt. " +
        "Clear or replace them to change the refiner's behaviour. " +
        "This field is only used in Refine mode.",
        "Help — Refinement Goals",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
})

$script:MenuHelpProjectContext.Add_Click({
    [System.Windows.MessageBox]::Show(
        "Project Context`n`n" +
        "Optional background about your project that helps the refiner produce more " +
        "relevant, concrete prompts.`n`n" +
        "Useful things to include:`n" +
        "  - Language / framework  (e.g. 'C# ASP.NET Core 8 API')`n" +
        "  - Team conventions      (e.g. 'prefer async/await over callbacks')`n" +
        "  - Runtime environment   (e.g. 'Windows Server 2022, PS 7.4')`n`n" +
        "Leave blank to use the built-in default (PowerShell-first automation project). " +
        "This field is not sent to OpenAI in Answer mode.",
        "Help — Project Context",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
})

$script:MenuHelpFile.Add_Click({
    [System.Windows.MessageBox]::Show(
        "File (optional)`n`n" +
        "Attach a local file whose path will be referenced in the prompt sent to OpenAI.`n`n" +
        "Constraints:`n" +
        "  - The file must exist on disk when you click Run.`n" +
        "  - Maximum size: 512 KB (larger files are silently omitted).`n`n" +
        "The file path — not its contents — is appended to the prompt text. " +
        "Use it to give the model a reference point such as a config file, " +
        "schema, or script you are actively working with.`n`n" +
        "Click Browse... to choose a file, or type the full path directly.",
        "Help — File",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
})

$script:MenuHelpAbout.Add_Click({
    [System.Windows.MessageBox]::Show(
        "Prompt Pilot`n`n" +
        "A WPF tool for iteratively refining rough prompts into production-grade task " +
        "descriptions suitable for coding assistants such as GitHub Copilot, Claude, " +
        "or ChatGPT.`n`n" +
        "Typical workflow:`n" +
        "  1. Enter a rough Base Prompt.`n" +
        "  2. Adjust Refinement Goals and Project Context as needed.`n" +
        "  3. Click Run Refinement — the model improves the prompt over N iterations.`n" +
        "  4. Copy the final prompt, or click Use this Prompt to execute it directly.`n`n" +
        "API key priority per provider: session key > saved settings key > provider env var > " +
        "interactive prompt at run time.",
        "About — Prompt Pilot",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
})

# =============================================================================
# Startup
# =============================================================================

Set-Mode -Mode 'Refine'
Update-ProviderIndicator
Append-Log -Message "Ready."
$window.Add_Closing({
    if ($script:AnswerTaskTimer) {
        $script:AnswerTaskTimer.Stop()
    }

    if ($script:AnswerTaskState -and $script:AnswerTaskState.PowerShell) {
        try {
            $script:AnswerTaskState.PowerShell.Stop()
        }
        catch {
        }
        finally {
            $script:AnswerTaskState.PowerShell.Dispose()
            $script:AnswerTaskState = $null
        }
    }
})
$null = $window.ShowDialog()

<#
===============================================================================
WHAT CHANGED
===============================================================================
- [1]  Added $script:Default* / $script:Price* / $script:OpenAIApiBase /
       $script:ChatEndpointPath constants. All hardcoded model names, pricing
       figures, and the API endpoint URL now reference these variables.
- [2]  Added Invoke-WithRetry (exponential backoff, cap 30 s) wrapping every
       Invoke-RestMethod call. Retries on HTTP 429/502/503/504 and timeouts.
       All Invoke-RestMethod calls now include -TimeoutSec 120.
- [3]  Added $script:CancelRequested flag. CancelButton enables during a run
       and sets the flag; Invoke-OpenAIRefinement checks it before each
       iteration and breaks early, returning whatever was collected.
- [4]  Invoke-OpenAIRefinement updates FinalPromptTextBox and calls Show-Status
       after every completed iteration. AcceptIterationButton copies the current
       draft to PromptTextBox and sets the cancel flag to skip remaining iters.
       A WPF dispatcher yield between iterations lets both buttons register.
- [5]  Added Get-TokenEstimate helper. Invoke-OpenAIRefinement estimates tokens
       and cost before the loop; if cost > $0.05 it shows a Yes/No confirmation.
       Run-Refinement guards against a $null result from a cancelled run.
- [6]  Added SavePresetButton / LoadPresetButton. Presets (Model, Iterations,
       Goals, ProjectContext) are saved as JSON under a /presets subfolder.
       Load validates that all expected keys exist before applying them.
- [7]  Added $script:LogFilePath. LogToFileCheckBox prompts for a .log path
       when checked; Append-Log writes every line there via Add-Content.
       Unchecking clears the path and disables file logging.
- [8]  ConvertTo-Json changed from -Depth 5 to -Depth 10. Prompts longer than
       32,000 characters throw a descriptive error. File references are validated
       (must exist and be < 512 KB) before being included in the API payload.
- [9]  Added Get-ApiKey: prefers $script:SessionApiKey, falls back to
       $env:OPENAI_API_KEY, then shows a WPF PasswordBox modal. The key is
       held in $script:SessionApiKey only. ClearSessionKeyButton nulls it.
       Key values are never written to logs, clipboard, or UI text fields.
- [10] PS version guard (>= 5.1) and Windows platform guard added at the very
       top of the script, before any assembly loads.
- [11] Answer mode runs in a background PowerShell pipeline polled by a
       DispatcherTimer, so the window stays responsive during the API call.
- [12] Background tasks are cancellable: Cancel stays enabled during a run and
       stops the background pipeline (Stop-AnswerTask); a stopped pipeline is
       reported as "Task cancelled.", not as an error. The failure MessageBox
       moved behind Show-TaskErrorDialog so headless tests can intercept it.
       Tests live in tests/ (pwsh -STA -File tests/Invoke-Tests.ps1).
===============================================================================
#>
