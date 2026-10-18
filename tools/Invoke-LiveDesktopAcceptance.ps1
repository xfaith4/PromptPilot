#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Prompt Pilot/settings.json'),
    [string]$OutputDirectory = '',
    [string[]]$Providers = @('Anthropic', 'OpenAI'),
    [ValidateRange(0.05, 2.0)][double]$BudgetUsd = 0.50
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'build/live-desktop' }
. (Join-Path $root 'PromptPilot.Core.ps1')
$preferences = Read-PilotPreferences $SettingsPath
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$report = @{ Version = (Read-PilotJson (Join-Path $root 'data/product.json')).version; StartedAtUtc = [DateTime]::UtcNow.ToString('o'); BudgetUsd = $BudgetUsd; EstimatedCostUsd = 0.0; SourceHash = (Get-FileHash (Join-Path $root 'Prompt_Pilot.Wpf.ps1') -Algorithm SHA256).Hash; CoreHash = (Get-FileHash (Join-Path $root 'PromptPilot.Core.ps1') -Algorithm SHA256).Hash; Providers = @() }
$remaining = $BudgetUsd
foreach ($providerName in $Providers) {
    $name = Resolve-PilotProvider $providerName
    $provider = (Get-PilotProviders)[$name]
    $model = $preferences.Providers[$name].Model
    $entry = @{ Provider = $name; Model = $model; AnswerModel = Get-PilotRoleModel $preferences $name Answer; Status = 'Pending'; Error = '' }
    $report.Providers += $entry
    try {
        if (-not (Get-PilotPricing $name $model $preferences.PricingOverrides).Known) { throw 'No verified/configured pricing for a bounded live desktop run.' }
        $credential = Get-PilotCredential $name $preferences
        if (-not $credential.Key) { throw 'No credential configured for this provider.' }
        $credential = $null
        $dataDir = Join-Path $OutputDirectory ($name + '-profile-' + [guid]::NewGuid().ToString('N'))
        $isolated = New-PilotPreferences
        $isolated.ActiveProvider = $name
        Set-PilotRoleModel $isolated $name Refine $model $false
        Set-PilotRoleModel $isolated $name Answer (Get-PilotRoleModel $preferences $name Answer) $false
        $isolated.ModelManagement.AutoCheck = $false
        $isolated.PricingOverrides = $preferences.PricingOverrides
        $ciphertext = Get-PilotValue $preferences.Keys $name
        if ($ciphertext) { $isolated.Keys[$name] = $ciphertext }
        Save-PilotPreferences (Join-Path $dataDir 'settings.json') $isolated
        $runBudget = [Math]::Min(0.15, ($remaining / 2))
        if ($runBudget -lt 0.01) { throw 'The live desktop validation budget is exhausted.' }
        $scenario = @'
$script:Controls.PromptTextBox.Text = 'Return exactly two numbered acceptance criteria for a CSV parser fix that supports quoted commas and preserves blank rows. Do not write implementation code or add dependencies.'
$script:Controls.IterationsTextBox.Text = '1'
$script:Controls.MaxOutputTextBox.Text = '2048'
$script:Controls.BudgetTextBox.Text = '__RUN_BUDGET__'
$watch = [Diagnostics.Stopwatch]::StartNew()
Invoke-PilotButton $script:Controls.RunButton
$startMilliseconds = $watch.ElapsedMilliseconds
$busy = [bool]$script:Operation
Wait-PilotDesktopIdle -TimeoutSeconds 120
if (-not $script:Session.Revisions.Count -or $script:Controls.FeedbackTextBlock.Text -notmatch 'Draft ready') { throw ('Live refinement failed: ' + $script:Controls.FeedbackTextBlock.Text) }
$refineUsage = $script:Session.Usage.Clone()
$refined = $script:Controls.FinalPromptTextBox.Text
Invoke-PilotButton $script:Controls.UsePromptButton
Wait-PilotDesktopIdle -TimeoutSeconds 120
if ($script:Controls.FeedbackTextBlock.Text -notmatch 'Answer ready') { throw ('Live answer failed: ' + $script:Controls.FeedbackTextBlock.Text) }
$answer = $script:Controls.TaskOutputTextBox.Text
$formatPassed = ($answer -match '(?m)^\s*1[.)]' -and $answer -match '(?m)^\s*2[.)]' -and $answer -notmatch '(?m)^\s*3[.)]')
Save-PilotAutosave
[pscustomobject]@{
    Status = $(if ($formatPassed) { 'Passed' } else { 'Failed' })
    NonblockingStart = $busy; StartMilliseconds = $startMilliseconds
    Original = $script:Controls.PromptTextBox.Text; Refined = $refined; Answer = $answer
    RefinementModel = $script:Session.RefinementModel; AnswerModel = $script:Session.AnswerModel; Revisions = $script:Session.Revisions.Count; RefineUsage = $refineUsage; AnswerUsage = $script:Session.Usage
    SessionPath = (Join-Path $script:SessionsDirectory ($script:Session.Id + '.json'))
}
'@ -replace '(?m)^\+', ''
        $scenario = $scenario.Replace('__RUN_BUDGET__', $runBudget.ToString('0.00######', [Globalization.CultureInfo]::InvariantCulture))
        $scenarioPath = Join-Path $OutputDirectory ($name + '-scenario.ps1')
        [IO.File]::WriteAllText($scenarioPath, $scenario, [Text.UTF8Encoding]::new($false))
        Write-Host ('Operating real desktop Refine and Use-prompt buttons with ' + $provider.DisplayName)
        $result = & (Join-Path $PSScriptRoot 'Invoke-DesktopScenario.ps1') -DataDirectory $dataDir -ScenarioPath $scenarioPath -SourceDirectory $root
        $entry.Workflow = ConvertTo-PilotMap $result
        $entry.Status = $result.Status
        foreach ($usage in @($result.RefineUsage, $result.AnswerUsage)) {
            $reservation = [double](Get-PilotValue $usage 'ReservedUsd' 0)
            $remaining = [Math]::Max([double]0, [double]($remaining - $reservation))
            if ($null -ne (Get-PilotValue $usage 'CostUsd')) { $report.EstimatedCostUsd += [double]$usage.CostUsd }
        }
        $smokeReport = Join-Path $OutputDirectory ($name + '-restored.json')
        & (Join-Path $root 'Prompt_Pilot.Wpf.ps1') -DataDirectory $dataDir -SmokeTest -SmokeReportPath $smokeReport
        $restored = Read-PilotJson $smokeReport
        $entry.Restart = $restored
        if (-not $restored.Restored -or $restored.Revisions -ne 1 -or $restored.AnswerCharacters -eq 0) { $entry.Status = 'Failed'; $entry.Error = 'Full-session restart recovery failed.' }
    }
    catch { $entry.Status = 'Failed'; $entry.Error = $_.Exception.Message }
    Write-PilotJson (Join-Path $OutputDirectory 'desktop-acceptance.json') $report
}
$report.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
$report.Status = if (@($report.Providers | Where-Object Status -ne Passed).Count -eq 0) { 'Passed' } else { 'Partial' }
Write-PilotJson (Join-Path $OutputDirectory 'desktop-acceptance.json') $report
$report.Providers | ForEach-Object { [pscustomobject]$_ } | Select-Object Provider, Model, Status, Error | Format-Table -Wrap
if ($report.Status -ne 'Passed') { exit 1 }
