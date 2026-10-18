BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'PromptPilot.Core.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    function New-ModelTestPreferences {
        $p = New-PilotPreferences
        Set-PilotRoleModel $p OpenAI Refine 'baseline-test' $false
        Set-PilotRoleModel $p OpenAI Answer 'baseline-test' $false
        $p.ModelManagement.EvaluationEnabled = $true
        $p.PricingOverrides = @{ 'OpenAI/baseline-test' = @{ InputPerMillion = 2; OutputPerMillion = 4; CheckedOn = '2026-10-18' }; 'OpenAI/candidate-test' = @{ InputPerMillion = 0.5; OutputPerMillion = 1; CheckedOn = '2026-10-18' } }
        return $p
    }
    function Save-ModelTestCatalog {
        param([string]$Directory)
        Write-PilotJson (Get-PilotCatalogPath $Directory OpenAI) @{ SchemaVersion = 1; Provider = 'OpenAI'; LastSuccessUtc = [DateTime]::UtcNow.ToString('o'); LastAttemptUtc = ''; LastError = ''; NextCheckUtc = [DateTime]::UtcNow.AddDays(7).ToString('o'); NewIds = @('candidate-test'); Models = @(@{ Id = 'candidate-test'; FirstSeenUtc = [DateTime]::UtcNow.ToString('o') }) }
    }
    function New-ModelTestOptions {
        param([string]$Directory, $Preferences, [string]$Role = 'Answer')
        return @{ Enabled = $true; DataDirectory = $Directory; Role = $Role; BaselineModel = 'baseline-test'; CandidateModel = 'candidate-test'; AnswerModel = 'baseline-test'; PricingOverrides = $Preferences.PricingOverrides; RunBudgetUsd = 1.0; MonthlyBudgetUsd = 5.0 }
    }
}

Describe 'Native model selection and recommendation workflow' -Tag 'WindowsUI' {
    BeforeAll { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase }
    It 'accepts a qualifying comparison and rolls back through the actual dialog buttons' {
        $answers = @('39','["a,b","c"]','[1,2,3]','src/parser.ts','unknown','inspect existing logs','APPROVED',"1. Preserve blank rows in the parsed CSV output.`n2. Keep each blank row in its original position.",'NO','404','NEED_INPUT','a1,b2,b2')
        $probe = '{"choices":[{"message":{"content":"PROMPT_PILOT_OK"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":10}}'
        $responses = @(@{ Status = 200; Body = $probe })
        for ($repeat = 0; $repeat -lt 3; $repeat++) {
            foreach ($answer in $answers) {
                $body = @{ choices = @(@{ message = @{ content = $answer }; finish_reason = 'stop' }); usage = @{ prompt_tokens = 10; completion_tokens = 10 } } | ConvertTo-Json -Depth 8 -Compress
                $responses += @(@{ Status = 200; Body = $body }, @{ Status = 200; Body = $body })
            }
        }
        $server = Start-PilotMockServer -Responses $responses
        $dir = Join-Path $TestDrive 'adoption-ui'; $p = New-ModelTestPreferences; $p.ModelManagement.AutoCheck = $false
        Save-PilotPreferences (Join-Path $dir 'settings.json') $p; Save-ModelTestCatalog $dir
        $scenario = @'
$script:MockProviders = Get-PilotProviders
$script:MockProviders.OpenAI.ApiBase = '__BASE__'
function Get-PilotProviders { return $script:MockProviders }
$script:SessionKeys.OpenAI = 'test-key'
$script:AdoptionUiResult = $null
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({
    $this.Stop()
    try {
        $s = $script:ModelContext; $s.Role.SelectedIndex = 1; $s.Candidate.Text = 'candidate-test'
        Invoke-PilotButton $s.Evaluate
        Wait-PilotDesktopIdle -TimeoutSeconds 60
        $decision = $s.Reports.SelectedItem.Report.Decision.Status
        Invoke-PilotButton $s.Accept
        $accepted = Get-PilotRoleModel $script:Preferences OpenAI Answer
        $activeAfterAccept = $script:Session.AnswerModel
        Invoke-PilotButton $s.Rollback
        $script:AdoptionUiResult = [pscustomobject]@{ RequestId = $s.Reports.SelectedItem.Report.Calls[0].RequestId; OutputTokens = $s.Reports.SelectedItem.Report.Calls[0].OutputTokens; Decision = $decision; Accepted = $accepted; ActiveAfterAccept = $activeAfterAccept; RolledBack = Get-PilotRoleModel $script:Preferences OpenAI Answer; History = $script:Preferences.ModelManagement.History.Count; Message = $s.Status.Text }
    }
    catch { $script:AdoptionUiResult = [pscustomobject]@{ Error = $_.Exception.Message } }
    finally { $script:ModelContext.Dialog.Close() }
})
$timer.Start()
Show-PilotModelManagement
$script:AdoptionUiResult
'@
        $path = Join-Path $TestDrive 'adoption.ps1'; [IO.File]::WriteAllText($path, $scenario.Replace('__BASE__',$server.Base))
        try {
            $result = & (Join-Path $script:RepoRoot 'tools/Invoke-DesktopScenario.ps1') -DataDirectory $dir -ScenarioPath $path
            $result.Decision | Should -Be Recommended -Because ([string](Get-PilotValue $result Error ''))
            $result.Accepted | Should -Be candidate-test
            $result.ActiveAfterAccept | Should -Be baseline-test
            $result.RolledBack | Should -Be baseline-test
            $result.History | Should -Be 2
            $result.RequestId | Should -Be req_mock
            $result.OutputTokens | Should -Be 10
        } finally { Stop-PilotMockServer $server }
    }
    It 'runs a real dialog comparison against local HTTP and refuses a failing candidate' {
        $probe = '{"choices":[{"message":{"content":"PROMPT_PILOT_OK"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":10}}'
        $body = '{"choices":[{"message":{"content":"39"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":10}}'
        $responses = @(@{ Status = 200; Body = $probe })
        for ($i = 0; $i -lt 72; $i++) { $responses += @{ Status = 200; Body = $body } }
        $server = Start-PilotMockServer -Responses $responses
        $dir = Join-Path $TestDrive 'paid-manager-ui'; $p = New-ModelTestPreferences; $p.ModelManagement.AutoCheck = $false
        Save-PilotPreferences (Join-Path $dir 'settings.json') $p; Save-ModelTestCatalog $dir
        $scenario = @'
$script:MockProviders = Get-PilotProviders
$script:MockProviders.OpenAI.ApiBase = '__BASE__'
function Get-PilotProviders { return $script:MockProviders }
$script:SessionKeys.OpenAI = 'test-key'
$script:ComparisonUiResult = $null
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({
    $this.Stop()
    try {
        $s = $script:ModelContext
        $s.Role.SelectedIndex = 1
        $s.Candidate.Text = 'candidate-test'
        Invoke-PilotButton $s.Evaluate
        Wait-PilotDesktopIdle -TimeoutSeconds 60
        $report = $s.Reports.SelectedItem.Report
        $script:ComparisonUiResult = [pscustomobject]@{ Message = $s.Status.Text; Status = $report.Status; Pairs = $report.Pairs.Count; Decision = $report.Decision.Status; AdoptEnabled = $s.Accept.IsEnabled; Baseline = $script:Session.AnswerModel; Idle = (-not $script:Operation) }
    }
    catch { $script:ComparisonUiResult = [pscustomobject]@{ Error = $_.Exception.Message } }
    finally { $script:ModelContext.Dialog.Close() }
})
$timer.Start()
Show-PilotModelManagement
$script:ComparisonUiResult
'@
        $path = Join-Path $TestDrive 'paid-manager.ps1'; [IO.File]::WriteAllText($path, $scenario.Replace('__BASE__',$server.Base))
        try {
            $result = & (Join-Path $script:RepoRoot 'tools/Invoke-DesktopScenario.ps1') -DataDirectory $dir -ScenarioPath $path
            $result.Status | Should -Be Completed -Because ([string](Get-PilotValue $result Error ''))
            $result.Pairs | Should -Be 36
            $result.Decision | Should -Be KeepCurrent
            $result.AdoptEnabled | Should -BeFalse
            $result.Baseline | Should -Be baseline-test
            $result.Idle | Should -BeTrue
        } finally { Stop-PilotMockServer $server }
    }
    It 'routes real refinement and answer buttons to their independent saved models' {
        $body = '{"choices":[{"message":{"content":"A useful result"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":10}}'
        $server = Start-PilotMockServer -Body $body
        $dir = Join-Path $TestDrive 'routing-ui'
        $p = New-PilotPreferences; $p.ModelManagement.AutoCheck = $false
        Set-PilotRoleModel $p OpenAI Refine gpt-5-mini $false
        Set-PilotRoleModel $p OpenAI Answer gpt-5.4-mini $false
        Save-PilotPreferences (Join-Path $dir 'settings.json') $p
        $scenario = @'
$script:MockProviders = Get-PilotProviders
$script:MockProviders.OpenAI.ApiBase = '__BASE__'
function Get-PilotProviders { return $script:MockProviders }
$script:SessionKeys.OpenAI = 'test-key'
$script:Controls.PromptTextBox.Text = 'A synthetic test request'
$script:Controls.IterationsTextBox.Text = '1'
Invoke-PilotButton $script:Controls.RunButton
Wait-PilotDesktopIdle
$refinement = $script:Session.Revisions[0].Model
Invoke-PilotButton $script:Controls.UsePromptButton
Wait-PilotDesktopIdle
[pscustomobject]@{ Refinement = $refinement; AnswerModel = $script:Session.Model; Answer = $script:Controls.TaskOutputTextBox.Text; Original = $script:Controls.PromptTextBox.Text; Idle = (-not $script:Operation) }
'@
        $path = Join-Path $TestDrive 'routing.ps1'; [IO.File]::WriteAllText($path, $scenario.Replace('__BASE__',$server.Base))
        try {
            $result = & (Join-Path $script:RepoRoot 'tools/Invoke-DesktopScenario.ps1') -DataDirectory $dir -ScenarioPath $path
            $result.Refinement | Should -Be gpt-5-mini
            $result.AnswerModel | Should -Be gpt-5.4-mini
            $result.Answer | Should -Be 'A useful result'
            $result.Original | Should -Be 'A synthetic test request'
            $result.Idle | Should -BeTrue
        } finally { Stop-PilotMockServer $server }
    }
    It 'opens the real manager, discovers models and requires opt-in before paid comparison' {
        $server = Start-PilotMockServer -Body '{"data":[{"id":"gpt-5.4-mini"},{"id":"candidate-test"}]}'
        $dir = Join-Path $TestDrive 'manager-ui'; $p = New-PilotPreferences; $p.ModelManagement.AutoCheck = $false
        Save-PilotPreferences (Join-Path $dir 'settings.json') $p
        $scenario = @'
$script:MockProviders = Get-PilotProviders
$script:MockProviders.OpenAI.ApiBase = '__BASE__'
$script:MockProviders.OpenAI.ModelsUri = '__BASE__/models'
function Get-PilotProviders { return $script:MockProviders }
$script:SessionKeys.OpenAI = 'test-key'
$script:ManagerResult = $null
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({
    $this.Stop()
    try {
        $s = $script:ModelContext
        Invoke-PilotButton $s.Discover
        Wait-PilotDesktopIdle
        $discoveryStatus = $s.Status.Text
        $s.Candidate.Text = 'candidate-test'
        Invoke-PilotButton $s.Evaluate
        $script:ManagerResult = [pscustomobject]@{ DiscoveryStatus = $discoveryStatus; Models = $s.Candidate.Items.Count; OptIn = $s.Enabled.IsChecked; Message = $s.Status.Text; Defaults = $s.Defaults.Text; Candidate = $s.Candidate.Text; Idle = (-not $script:Operation) }
    }
    catch { $script:ManagerResult = [pscustomobject]@{ Error = $_.Exception.Message } }
    finally { $script:ModelContext.Dialog.Close() }
})
$timer.Start()
Show-PilotModelManagement
$script:ManagerResult
'@
        $path = Join-Path $TestDrive 'manager.ps1'; [IO.File]::WriteAllText($path, $scenario.Replace('__BASE__',$server.Base))
        try {
            $result = & (Join-Path $script:RepoRoot 'tools/Invoke-DesktopScenario.ps1') -DataDirectory $dir -ScenarioPath $path
            $result.Models | Should -Be 2 -Because ([string]$result.DiscoveryStatus)
            $result.OptIn | Should -BeFalse
            $result.Message | Should -Match 'Enable paid evaluations'
            $result.Defaults | Should -Match Refinement
            $result.Idle | Should -BeTrue
            $server.Requests.Count | Should -Be 1
        } finally { Stop-PilotMockServer $server }
    }
}

Describe 'Model migration and cached discovery' {
    It 'migrates an older model to two pinned roles without rewriting the original' {
        $path = Join-Path $TestDrive 'old.json'
        Write-PilotJson $path @{ SchemaVersion = 2; ActiveProvider = 'Anthropic'; Providers = @{ Anthropic = @{ Model = 'anthropic.claude-opus-5-5' } }; Autosave = $true }
        $p = Read-PilotPreferences $path
        (Get-PilotRoleModel $p Anthropic Refine) | Should -Be 'claude-opus-5-5'
        (Get-PilotRoleModel $p Anthropic Answer) | Should -Be 'claude-opus-5-5'
        $p.Providers.Anthropic.Pins.Answer | Should -BeTrue
        (Read-PilotJson $path).SchemaVersion | Should -Be 2
    }
    It 'round trips independent defaults, pins and evaluation policy' {
        $p = New-ModelTestPreferences; Set-PilotRoleModel $p OpenAI Answer 'candidate-test' $true
        $path = Join-Path $TestDrive 'new.json'; Save-PilotPreferences $path $p
        $loaded = Read-PilotPreferences $path
        $loaded.SchemaVersion | Should -Be 3
        (Get-PilotRoleModel $loaded OpenAI Refine) | Should -Be baseline-test
        (Get-PilotRoleModel $loaded OpenAI Answer) | Should -Be candidate-test
        $loaded.Providers.OpenAI.Pins.Answer | Should -BeTrue
        $loaded.ModelManagement.EvaluationEnabled | Should -BeTrue
    }
    It 'keeps saved sessions stable when defaults change and migrates schema one' {
        $p = New-ModelTestPreferences; $session = New-PilotSessionFromDefaults $p
        Set-PilotRoleModel $p OpenAI Answer 'candidate-test' $false
        (ConvertTo-PilotSession $session).AnswerModel | Should -Be baseline-test
        (New-PilotSessionFromDefaults $p).AnswerModel | Should -Be candidate-test
        $session.Remove('RefinementModel'); $session.Remove('AnswerModel'); $session.SchemaVersion = 1
        (ConvertTo-PilotSession $session).RefinementModel | Should -Be baseline-test
        (ConvertTo-PilotSession $session).AnswerModel | Should -Be baseline-test
    }
    It 'rejects invalid switches and budgets instead of enabling paid work' {
        foreach ($policy in @(@{ EvaluationEnabled = 'false' }, @{ MonthlyBudgetUsd = -1 })) {
            $path = Join-Path $TestDrive 'bad.json'; Write-PilotJson $path @{ SchemaVersion = 3; ModelManagement = $policy }
            { Read-PilotPreferences $path } | Should -Throw
        }
    }
    It 'records new IDs and capabilities, retains first-seen timestamps and schedules a weekly check' {
        $server = Start-PilotMockServer -Body '{"data":[{"id":"candidate-test","max_input_tokens":64000,"capabilities":{"vision":{"supported":true}}}]}'
        try {
            $dir = Join-Path $TestDrive 'catalog'; $provider = New-PilotMockProvider $server OpenAI
            $one = Update-PilotCatalog $provider test-key $dir
            $one.Catalog.NewIds | Should -Contain candidate-test
            $two = Update-PilotCatalog $provider test-key $dir
            $two.Catalog.NewIds.Count | Should -Be 0
            ([DateTime]$two.Catalog.Models[0].FirstSeenUtc).ToUniversalTime().Ticks | Should -Be ([DateTime]$one.Catalog.Models[0].FirstSeenUtc).ToUniversalTime().Ticks
            $two.Catalog.Models[0].MaxInputTokens | Should -Be 64000
            (Test-PilotCatalogDue $two.Catalog) | Should -BeFalse
            (Test-PilotCatalogDue $two.Catalog ([DateTime]::UtcNow.AddDays(8))) | Should -BeTrue
        } finally { Stop-PilotMockServer $server }
    }
    It 'keeps cached IDs and backs off after an invalid provider response' {
        $dir = Join-Path $TestDrive 'failed-catalog'; Save-ModelTestCatalog $dir
        $server = Start-PilotMockServer -Body 'OK'
        try {
            $result = Update-PilotCatalog (New-PilotMockProvider $server OpenAI) test-key $dir
            $result.Status | Should -Be Failed
            $result.Catalog.Models[0].Id | Should -Be candidate-test
            $result.Catalog.LastError | Should -Match non-JSON
            (Test-PilotCatalogDue $result.Catalog) | Should -BeFalse
        } finally { Stop-PilotMockServer $server }
    }
}

Describe 'Repeated evaluation, spending and adoption' {
    BeforeAll {
        $script:Cases = (Read-PilotJson (Join-Path $script:RepoRoot 'evaluations/model-cases.json')).Cases
        $script:Answers = @('39','["a,b","c"]','[1,2,3]','src/parser.ts','unknown','inspect existing logs','APPROVED',"1. Preserve blank rows in the parsed CSV output.`n2. Keep each blank row in its original position.",'NO','404','NEED_INPUT','a1,b2,b2')
    }
    BeforeEach {
        $script:CallNumber = 0; $script:FailAt = 0; $script:UnknownUsage = $false
        Mock Invoke-PilotChat {
            param($Provider,$ApiKey,$Model,$System,$Messages,$MaxOutputTokens,$Budget,$Events,$CancellationToken,$MaxRetries)
            $script:CallNumber++
            $CancellationToken.ThrowIfCancellationRequested()
            if ($script:FailAt -eq $script:CallNumber) { $Budget.UsedUsd = 0.001; throw 'Simulated interrupted request' }
            $text = [string]$Messages[0].content; $output = 'PROMPT_PILOT_OK'
            if ($text -match '(?s)<original>\s*(.*?)\s*</original>') { $output = $Matches[1] }
            elseif ($text -notmatch 'PROMPT_PILOT_OK') {
                for ($i = 0; $i -lt $script:Cases.Count; $i++) { if ($text -eq $script:Cases[$i].Prompt) { $output = $script:Answers[$i]; break } }
            }
            $cost = ((10 * $Budget.Pricing.InputPerMillion) + (10 * $Budget.Pricing.OutputPerMillion)) / 1000000.0
            $Budget.UsedUsd = $cost
            if ($script:UnknownUsage) { $cost = $null; $Budget.UsedUsd = 0.001; $Budget.UsageComplete = $false }
            @{ Text = $output; CostUsd = $cost; Truncated = $false; ResolvedModel = $Model; InputTokens = 10; OutputTokens = 10 }
        }
    }
    It 'compares twelve answer cases three times, changes one default and rolls it back' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'answer'; Save-ModelTestCatalog $dir
        $result = Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-secret (New-ModelTestOptions $dir $p)
        $result.Error | Should -BeNullOrEmpty -Because ([string](Get-PilotValue $result.Report 'ErrorLocation' ''))
        $result.Report.Pairs.Count | Should -Be 36
        $result.Report.Calls.Count | Should -Be 73
        $result.Report.Decision.Status | Should -Be Recommended
        (Get-Content $result.ReportPath -Raw) | Should -Not -Match test-secret
        $path = Join-Path $dir 'settings.json'; $updated = Accept-PilotRecommendation $result.Report $p $dir $path
        (Get-PilotRoleModel $updated OpenAI Answer) | Should -Be candidate-test
        (Get-PilotRoleModel $updated OpenAI Refine) | Should -Be baseline-test
        $rolled = Undo-PilotModelDefault $updated OpenAI Answer $path
        (Get-PilotRoleModel $rolled OpenAI Answer) | Should -Be baseline-test
        $rolled.ModelManagement.History.Count | Should -Be 2
        { Undo-PilotModelDefault $rolled OpenAI Answer $path } | Should -Throw '*no matching*'
    }
    It 'uses the same downstream answer model and original-request controls for refinement' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'refine'; Save-ModelTestCatalog $dir
        $result = Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key (New-ModelTestOptions $dir $p Refine)
        $result.Error | Should -BeNullOrEmpty -Because ([string](Get-PilotValue $result.Report 'ErrorLocation' ''))
        $result.Report.Pairs.Count | Should -Be 36
        $result.Report.Calls.Count | Should -Be 181
        @($result.Report.Calls | Where-Object { $_.Purpose -match 'downstream|Control' -and $_.Model -ne 'baseline-test' }).Count | Should -Be 0
        $result.Report.Decision.Status | Should -Be Recommended
    }
    It 'requires explicit opt-in and known rates before making a generation request' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'optin'; Save-ModelTestCatalog $dir
        $options = New-ModelTestOptions $dir $p; $options.Enabled = $false
        (Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key $options).Report.Status | Should -Be Incomplete
        $options.Enabled = $true; $options.PricingOverrides.Remove('OpenAI/candidate-test')
        (Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key $options).Error | Should -Match 'Pricing required'
        $script:CallNumber | Should -Be 0
    }
    It 'stops before dispatch at the monthly ceiling and preserves existing reservations' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'ceiling'; Save-ModelTestCatalog $dir
        $month = [DateTime]::UtcNow.ToString('yyyy-MM'); $months = @{}; $months[$month] = @{ UsedUsd = 5.0; Requests = 1 }
        Write-PilotJson (Join-Path $dir 'models/evaluation-budget.json') @{ SchemaVersion = 1; Months = $months }
        $result = Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key (New-ModelTestOptions $dir $p)
        $result.Error | Should -Match 'budget reached'; $script:CallNumber | Should -Be 0
        (Read-PilotJson (Join-Path $dir 'models/evaluation-budget.json')).Months[$month].UsedUsd | Should -Be 5
    }
    It 'retains uncertain spending on an interrupted request and keeps the old default' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'interrupted'; Save-ModelTestCatalog $dir; $script:FailAt = 2
        $result = Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key (New-ModelTestOptions $dir $p)
        $result.Report.Status | Should -Be Incomplete
        $result.Report.Decision.Status | Should -Be InsufficientEvidence
        $result.Report.UsedUsd | Should -BeGreaterOrEqual 0.001
        $ledger = Read-PilotJson (Join-Path $dir 'models/evaluation-budget.json')
        [Math]::Abs($ledger.Months[[DateTime]::UtcNow.ToString('yyyy-MM')].UsedUsd - $result.Report.UsedUsd) | Should -BeLessThan 0.000000001
    }
    It 'rejects pins, changed baselines, expired evidence and changed prices' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'stale'; Save-ModelTestCatalog $dir
        $report = (Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key (New-ModelTestOptions $dir $p)).Report
        $p.Providers.OpenAI.Pins.Answer = $true; { Assert-PilotRecommendation $report $p $dir } | Should -Throw '*pinned*'
        $p.Providers.OpenAI.Pins.Answer = $false; $p.Providers.OpenAI.AnswerModel = 'changed-model'
        { Assert-PilotRecommendation $report $p $dir } | Should -Throw '*baseline*'
        $p.Providers.OpenAI.AnswerModel = 'baseline-test'; $report.FinishedAtUtc = [DateTime]::UtcNow.AddDays(-8).ToString('o')
        { Assert-PilotRecommendation $report $p $dir } | Should -Throw '*expired*'
        $report.FinishedAtUtc = [DateTime]::UtcNow.ToString('o'); $p.PricingOverrides['OpenAI/candidate-test'].InputPerMillion = 1
        { Assert-PilotRecommendation $report $p $dir } | Should -Throw '*changed*'
    }
    It 'keeps unknown usage and cancellation out of recommendations' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'unknown'; Save-ModelTestCatalog $dir; $script:UnknownUsage = $true
        $result = Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key (New-ModelTestOptions $dir $p)
        $result.Report.UsageComplete | Should -BeFalse
        $result.Report.Decision.Status | Should -Be InsufficientEvidence
        $cts = [Threading.CancellationTokenSource]::new(); $cts.Cancel()
        try {
            $result = Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key (New-ModelTestOptions $dir $p) -CancellationToken $cts.Token
            $result.Report.Status | Should -Be Cancelled
        } finally { $cts.Dispose() }
    }
    It 'persists the reservation before dispatch and stops when the next request exceeds the run ceiling' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'reservation'; Save-ModelTestCatalog $dir
        $script:DispatchLedgerPath = Join-Path $dir 'models/evaluation-budget.json'
        Mock Invoke-PilotChat {
            $ledger = Read-PilotJson $script:DispatchLedgerPath
            $month = [DateTime]::UtcNow.ToString('yyyy-MM')
            if ($ledger.Months[$month].Requests -lt 1 -or $ledger.Months[$month].UsedUsd -le 0) { throw 'Liability was not persisted before dispatch.' }
            $Budget.UsedUsd = 0.00001
            @{ Text = 'PROMPT_PILOT_OK'; CostUsd = 0.00001; Truncated = $false; ResolvedModel = $Model }
        }
        $options = New-ModelTestOptions $dir $p; $options.RunBudgetUsd = 0.001
        $result = Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key $options
        $result.Error | Should -Match 'budget reached'
        $result.Report.Calls.Count | Should -Be 1
        $result.Report.UsedUsd | Should -BeGreaterThan 0
        $result.Report.Decision.Status | Should -Be InsufficientEvidence
    }
    It 'refuses concurrent evaluation while another process owns the accounting lock' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'locked'; Save-ModelTestCatalog $dir
        $lock = [IO.File]::Open((Join-Path $dir 'models/evaluation.lock'), 'OpenOrCreate','ReadWrite','None')
        try {
            $result = Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key (New-ModelTestOptions $dir $p)
            $result.Report.Status | Should -Be Incomplete
            $script:CallNumber | Should -Be 0
        } finally { $lock.Dispose() }
    }
    It 'keeps the baseline when a cheap candidate fails a critical task' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'critical'; Save-ModelTestCatalog $dir
        $report = (Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key (New-ModelTestOptions $dir $p)).Report
        $report.Pairs[0].Candidate.Passed = $false
        (Get-PilotModelDecision $report).Status | Should -Be KeepCurrent
    }
    It 'invalidates a recommendation after provider capability metadata changes' {
        $p = New-ModelTestPreferences; $dir = Join-Path $TestDrive 'metadata'; Save-ModelTestCatalog $dir
        $report = (Invoke-PilotModelEvaluation (Get-PilotProviders).OpenAI test-key (New-ModelTestOptions $dir $p)).Report
        $catalog = Read-PilotCatalog $dir OpenAI; $catalog.Models[0].MaxOutputTokens = 128
        Write-PilotJson (Get-PilotCatalogPath $dir OpenAI) $catalog
        { Assert-PilotRecommendation $report $p $dir } | Should -Throw '*metadata changed*'
    }
}
