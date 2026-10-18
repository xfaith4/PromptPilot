#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Prompt Pilot/settings.json'),
    [string]$OutputDirectory = '',
    [ValidateRange(0.05, 5.0)][double]$BudgetUsd = 1.0,
    [string[]]$Providers = @('Anthropic', 'OpenAI', 'GitHubModels'),
    [ValidateRange(0, 12)][int]$EvaluationCases = 3,
    [string[]]$ReevaluateCaseIds = @(),
    [switch]$EvaluateOnly
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'build/live-acceptance' }
. (Join-Path $root 'PromptPilot.Core.ps1')
$preferences = Read-PilotPreferences $SettingsPath
$definitions = Get-PilotProviders
$corpus = Read-PilotJson (Join-Path $root 'evaluations/prompt-cases.json')
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$reportPath = Join-Path $OutputDirectory 'acceptance.json'
$logPath = Join-Path $OutputDirectory 'requests.log'
$report = @{ StartedAtUtc = [DateTime]::UtcNow.ToString('o'); Version = (Read-PilotJson (Join-Path $root 'data/product.json')).version; BudgetUsd = $BudgetUsd; ReservedUsd = 0.0; EstimatedCostUsd = 0.0; Providers = @(); Evaluations = @(); Notes = @('Uses synthetic public prompts. Credentials are kept only in memory. Missing/unknown billing is not represented as zero.'); Status = 'Running' }
$remaining = $BudgetUsd
if ($EvaluateOnly) {
    $report = Read-PilotJson $reportPath
    $remaining = [Math]::Max([double]0, [double]($report.BudgetUsd - $report.ReservedUsd))
    $report.Notes += 'Additional evaluation cases run on existing provider-generation evidence; earlier cases are reused.'
}
$secrets = @()

function Save-AcceptanceProgress {
    Write-PilotJson $reportPath $report
}
function Save-AcceptanceEvents {
    param($Queue)
    $item = $null
    while ($Queue.TryDequeue([ref]$item)) {
        if ($item.Kind -ne 'Revision') { Add-Content -LiteralPath $logPath -Value ('[{0}] {1}' -f $item.AtUtc, (Protect-PilotText $item.Message $secrets)) -Encoding UTF8 }
    }
}
function Register-AcceptanceUsage {
    param($Usage)
    $reserved = [double](Get-PilotValue $Usage 'ReservedUsd' 0)
    $script:remaining = [Math]::Max([double]0, [double]($script:remaining - $reserved))
    $script:report.ReservedUsd += $reserved
    if ($null -ne (Get-PilotValue $Usage 'CostUsd')) { $script:report.EstimatedCostUsd += [double]$Usage.CostUsd }
    else { $script:report.Notes += 'At least one request has incomplete usage; the recorded reservation is retained.' }
}

Save-AcceptanceProgress
foreach ($name in $(if ($EvaluateOnly) { @() } else { $Providers })) {
    $provider = $definitions[(Resolve-PilotProvider $name)]
    $model = $preferences.Providers[$provider.Name].Model
    $entry = @{ Provider = $provider.Name; Model = $model; MetadataStatus = 'Pending'; GenerationStatus = 'NotAttempted'; GenerationAttempted = $false; Error = ''; Refine = $null; Answer = $null }
    $report.Providers += $entry
    $events = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    try {
        $credential = Get-PilotCredential $provider.Name $preferences
        if (-not $credential.Key) { $entry.GenerationStatus = 'Unavailable'; $entry.Error = 'No credential configured.'; continue }
        $key = $credential.Key; $secrets += $key
        Write-Host ('Checking {0} model access...' -f $provider.DisplayName)
        $models = @(Get-PilotModels -Provider $provider -ApiKey $key -Events $events)
        $entry.MetadataStatus = 'Passed'
        $entry.ModelCount = $models.Count
        $entry.SelectedModelListed = ($model -in @($models.Id))
        $pricing = Get-PilotPricing $provider.Name $model $preferences.PricingOverrides
        if (-not $pricing.Known) { $entry.GenerationStatus = 'PricingRequired'; $entry.Error = 'Set explicit account-appropriate token rates before running a budgeted generation.'; continue }
        $options = @{ Prompt = $corpus.cases[0].prompt; Goals = 'Preserve every explicit constraint. Keep the prompt concise.'; Context = ''; Profile = 'Coding task'; Model = $model; Iterations = 1; MaxOutputTokens = 2048; BudgetUsd = [Math]::Min(0.20, $remaining); Pricing = $pricing; IncludeFile = $false }
        $entry.GenerationAttempted = $true
        Write-Host ('Running real refinement and answer with {0}...' -f $provider.DisplayName)
        $refined = Invoke-PilotWorkflow Refine $options $provider $key $events
        Register-AcceptanceUsage $refined.Usage
        $entry.Refine = $refined
        Save-AcceptanceProgress
        if ($refined.Status -ne 'Completed') { $entry.GenerationStatus = 'Failed'; $entry.Error = $refined.Error; continue }
        $options.Prompt = $refined.OutputText
        $options.BudgetUsd = [Math]::Min(0.20, $remaining)
        $answer = Invoke-PilotWorkflow Answer $options $provider $key $events
        Register-AcceptanceUsage $answer.Usage
        $entry.Answer = $answer
        $twoCriteria = ($answer.OutputText -match '(?m)^\s*1[.)]' -and $answer.OutputText -match '(?m)^\s*2[.)]' -and $answer.OutputText -notmatch '(?m)^\s*3[.)]')
        $entry.AcceptanceFormatPassed = $twoCriteria
        $entry.GenerationStatus = if ($answer.Status -eq 'Completed' -and $twoCriteria) { 'Passed' } else { 'Failed' }
        if ($entry.GenerationStatus -eq 'Failed') { $entry.Error = if ($answer.Error) { $answer.Error } else { 'The live answer did not preserve the exactly-two numbered criteria constraint.' } }
    }
    catch { if ($entry.MetadataStatus -ne 'Passed') { $entry.MetadataStatus = 'Failed' }; $entry.GenerationStatus = if ($entry.GenerationAttempted) { 'Failed' } else { 'NotAttempted' }; $entry.Error = Protect-PilotText $_.Exception.Message $secrets }
    finally { Save-AcceptanceEvents $events; Save-AcceptanceProgress; $key = $null }
}

$evaluationProvider = @($report.Providers | Where-Object GenerationStatus -eq 'Passed' | Select-Object -First 1)
if ($EvaluationCases -gt 0 -and $evaluationProvider.Count) {
    $provider = $definitions[$evaluationProvider[0].Provider]
    $model = $evaluationProvider[0].Model
    $key = (Get-PilotCredential $provider.Name $preferences).Key
    $pricing = Get-PilotPricing $provider.Name $model $preferences.PricingOverrides
    try {
        foreach ($case in @($corpus.cases | Select-Object -First $EvaluationCases)) {
            if ($EvaluateOnly -and $case.id -in @($report.Evaluations.CaseId)) {
                if ($case.id -notin $ReevaluateCaseIds) { continue }
                if (-not $report.ContainsKey('PriorEvaluations')) { $report.PriorEvaluations = @() }
                $report.PriorEvaluations += @($report.Evaluations | Where-Object CaseId -eq $case.id)
                $report.Evaluations = @($report.Evaluations | Where-Object CaseId -ne $case.id)
            }
            Write-Host ('Evaluating constraint preservation: ' + $case.id)
            $events = [Collections.Concurrent.ConcurrentQueue[object]]::new()
            $options = @{ Prompt = $case.prompt; Goals = 'Preserve all hard constraints and exclusions.'; Context = ''; Profile = $case.profile; Model = $model; Iterations = 1; MaxOutputTokens = 2048; BudgetUsd = [Math]::Min(0.20, $remaining); Pricing = $pricing; IncludeFile = $false }
            $result = Invoke-PilotWorkflow Refine $options $provider $key $events
            Register-AcceptanceUsage $result.Usage
            $checks = @()
            foreach ($pattern in $case.required) { $checks += @{ Pattern = $pattern; Expectation = 'Required'; Passed = ($result.OutputText -match $pattern) } }
            foreach ($pattern in $case.forbidden) { $checks += @{ Pattern = $pattern; Expectation = 'Absent'; Passed = ($result.OutputText -notmatch $pattern) } }
            $report.Evaluations += @{ CaseId = $case.id; Provider = $provider.Name; Model = $model; Prompt = $case.prompt; Result = $result; Checks = $checks; Passed = ($result.Status -eq 'Completed' -and @($checks | Where-Object { -not $_.Passed }).Count -eq 0) }
            Save-AcceptanceEvents $events
            Save-AcceptanceProgress
        }
    }
    finally { $key = $null }
}
$report.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
$report.Status = if (@($report.Providers | Where-Object GenerationStatus -ne 'Passed').Count -eq 0 -and @($report.Evaluations | Where-Object { -not $_.Passed }).Count -eq 0) { 'Passed' } else { 'Partial' }
Save-AcceptanceProgress
$report.Providers | ForEach-Object { [pscustomobject]$_ } | Select-Object Provider, Model, MetadataStatus, GenerationStatus, Error | Format-Table -Wrap
Write-Host ('Constraint cases passed: {0}/{1}; estimated recorded cost: ${2:F5}; report: {3}' -f @($report.Evaluations | Where-Object Passed).Count, $report.Evaluations.Count, $report.EstimatedCostUsd, $reportPath)
if ($EvaluateOnly) { if (@($report.Evaluations | Where-Object { -not $_.Passed }).Count) { exit 1 } }
elseif ($report.Status -ne 'Passed') { exit 1 }
