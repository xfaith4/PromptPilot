#Requires -Version 5.1
# Loaded by PromptPilot.Core.ps1. No UI, scheduler registration or startup network I/O.

function New-PilotChatJson {
    param($Provider, [string]$Model, [string]$System, [array]$Messages, [int]$MaxOutputTokens)
    $body = @{ model = $Model; messages = @($Messages) }
    if ($Provider.Protocol -eq 'Anthropic') {
        $body.max_tokens = $MaxOutputTokens
        if ($System) { $body.system = $System }
    }
    else {
        if ($System) { $body.messages = @(@{ role = 'system'; content = $System }) + $body.messages }
        if ($Provider.Protocol -eq 'OpenAI') { $body.max_completion_tokens = $MaxOutputTokens }
        else { $body.max_tokens = $MaxOutputTokens }
    }
    return $body | ConvertTo-Json -Depth 12 -Compress
}

function New-PilotModelPolicy {
    return @{ AutoCheck = $true; EvaluationEnabled = $false; RunBudgetUsd = 1.0; MonthlyBudgetUsd = 5.0; History = @() }
}

function Get-PilotRoleModel {
    param($Preferences, [string]$ProviderName, [ValidateSet('Refine','Answer')][string]$Role)
    $provider = Resolve-PilotProvider $ProviderName
    $item = $Preferences.Providers[$provider]
    # Model remains the refinement compatibility field for older scripts.
    $field = if ($Role -eq 'Refine') { 'Model' } else { 'AnswerModel' }
    return Resolve-PilotModel $provider ([string](Get-PilotValue $item $field $item.Model))
}

function Set-PilotRoleModel {
    param($Preferences, [string]$ProviderName, [ValidateSet('Refine','Answer')][string]$Role, [string]$Model, [bool]$Pinned)
    $provider = Resolve-PilotProvider $ProviderName
    $modelId = Resolve-PilotModel $provider $Model
    if ($Role -eq 'Refine') { $Preferences.Providers[$provider].Model = $modelId }
    else { $Preferences.Providers[$provider].AnswerModel = $modelId }
    $Preferences.Providers[$provider].Pins[$Role] = $Pinned
}

function New-PilotSessionFromDefaults {
    param($Preferences, [string]$ProviderName = '')
    if (-not $ProviderName) { $ProviderName = $Preferences.ActiveProvider }
    $session = New-PilotSession $ProviderName (Get-PilotRoleModel $Preferences $ProviderName Refine)
    $session.AnswerModel = Get-PilotRoleModel $Preferences $ProviderName Answer
    return $session
}

function Get-PilotCatalogPath {
    param([string]$DataDirectory, [string]$ProviderName)
    return Join-Path $DataDirectory ('models/catalog-' + (Resolve-PilotProvider $ProviderName) + '.json')
}

function Read-PilotCatalog {
    param([string]$DataDirectory, [string]$ProviderName)
    $path = Get-PilotCatalogPath $DataDirectory $ProviderName
    if (Test-Path -LiteralPath $path) {
        try { return Read-PilotJson $path } catch {
            if (Test-Path -LiteralPath ($path + '.bak')) { return Read-PilotJson ($path + '.bak') }
            throw 'The model catalog is damaged. Preserve it and restore its backup before checking again.'
        }
    }
    return @{ SchemaVersion = 1; Provider = (Resolve-PilotProvider $ProviderName); LastSuccessUtc = ''; LastAttemptUtc = ''; NextCheckUtc = ''; LastError = ''; Models = @(); NewIds = @() }
}

function Test-PilotCatalogDue {
    param($Catalog, [DateTime]$Now = [DateTime]::UtcNow)
    if (-not $Catalog.NextCheckUtc) { return $true }
    return $Now -ge [DateTime]::Parse($Catalog.NextCheckUtc).ToUniversalTime()
}

function Update-PilotCatalog {
    param($Provider, [string]$ApiKey, [string]$DataDirectory, $Events = $null,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $catalog = Read-PilotCatalog $DataDirectory $Provider.Name
    $path = Get-PilotCatalogPath $DataDirectory $Provider.Name
    $lock = $null
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    try {
        $lock = [IO.File]::Open(($path + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $catalog = Read-PilotCatalog $DataDirectory $Provider.Name
        $catalog.LastAttemptUtc = [DateTime]::UtcNow.ToString('o')
        try {
            $found = @(Get-PilotModels $Provider $ApiKey $Events $CancellationToken)
            if ($found.Count -eq 0 -or $found.Count -gt 20000) { throw 'The provider returned an empty or oversized model list.' }
            $previous = @{}
            foreach ($item in @($catalog.Models)) { $previous[$item.Id] = $item }
            $now = [DateTime]::UtcNow.ToString('o')
            $newIds = @(); $models = @()
            foreach ($item in $found) {
                $id = Resolve-PilotModel $Provider.Name $item.Id
                $firstSeen = $now
                if ($previous.ContainsKey($id)) { $firstSeen = ([DateTime]::Parse([string]$previous[$id].FirstSeenUtc)).ToUniversalTime().ToString('o') }
                else { $newIds += $id }
                $models += @{ Id = $id; Name = [string]$item.Name; FirstSeenUtc = $firstSeen; CreatedAt = Get-PilotValue $item 'CreatedAt'; MaxInputTokens = Get-PilotValue $item 'MaxInputTokens'; MaxOutputTokens = Get-PilotValue $item 'MaxOutputTokens'; Capabilities = Get-PilotValue $item 'Capabilities' @{} }
            }
            $catalog.Models = $models; $catalog.NewIds = $newIds
            $catalog.LastSuccessUtc = $now; $catalog.LastError = ''
            $catalog.NextCheckUtc = [DateTime]::UtcNow.AddDays(7).ToString('o')
            Write-PilotJson $path $catalog
            Send-PilotEvent $Events 'Log' ('Model discovery completed: provider={0}; models={1}; new={2}.' -f $Provider.Name, $models.Count, $newIds.Count)
            return @{ Status = 'Completed'; Catalog = $catalog; Error = '' }
        }
        catch {
            $catalog.LastError = Protect-PilotText $_.Exception.Message @($ApiKey)
            $catalog.NextCheckUtc = [DateTime]::UtcNow.AddDays(1).ToString('o')
            Write-PilotJson $path $catalog
            $status = if ($CancellationToken.IsCancellationRequested) { 'Cancelled' } else { 'Failed' }
            return @{ Status = $status; Catalog = $catalog; Error = $catalog.LastError }
        }
    }
    finally { if ($lock) { $lock.Dispose() } }
}

function Get-PilotFileSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-PilotCanonicalText {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [Collections.IDictionary]) {
        $items = @($Value.Keys | Sort-Object | ForEach-Object { ($_ | ConvertTo-Json -Compress) + ':' + (ConvertTo-PilotCanonicalText $Value[$_]) })
        return '{' + ($items -join ',') + '}'
    }
    if ($Value -is [array]) { return '[' + (@($Value | ForEach-Object { ConvertTo-PilotCanonicalText $_ }) -join ',') + ']' }
    return $Value | ConvertTo-Json -Compress
}

function Get-PilotCatalogFingerprint {
    param($Catalog, [string[]]$Models)
    $items = @()
    foreach ($id in $Models) {
        $found = @($Catalog.Models | Where-Object { $_.Id -eq $id } | Select-Object -First 1)
        $item = if ($found.Count) { $found[0] } else { @{} }
        $items += @{ Id = $id; CreatedAt = Get-PilotValue $item 'CreatedAt'; MaxInputTokens = Get-PilotValue $item 'MaxInputTokens'; MaxOutputTokens = Get-PilotValue $item 'MaxOutputTokens'; Capabilities = Get-PilotValue $item 'Capabilities' @{} }
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-PilotCanonicalText $items))))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-PilotEvaluationFingerprint {
    param([string]$ProviderName, [string]$Role, [string]$BaselineModel, [string]$CandidateModel, [string]$AnswerModel, $Overrides = @{})
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($text in @('model-policy-1', $ProviderName, $Role, $BaselineModel, $CandidateModel, $AnswerModel,
        (Get-PilotFileSha (Join-Path $script:PilotCoreDirectory 'PromptPilot.Core.ps1')),
        (Get-PilotFileSha (Join-Path $script:PilotCoreDirectory 'PromptPilot.Models.ps1')),
        (Get-PilotFileSha (Join-Path $script:PilotCoreDirectory 'evaluations/model-cases.json')))) { $parts.Add([string]$text) }
    foreach ($model in @($BaselineModel, $CandidateModel, $AnswerModel)) {
        $price = Get-PilotPricing $ProviderName $model $Overrides
        if (-not $price.Known) { throw ('Pricing required for ' + $model + '. Supply explicit rates before evaluating.') }
        $parts.Add(([double]$price.InputPerMillion).ToString('G17', [Globalization.CultureInfo]::InvariantCulture))
        $parts.Add(([double]$price.OutputPerMillion).ToString('G17', [Globalization.CultureInfo]::InvariantCulture))
        $parts.Add([string]$price.Source); $parts.Add([string]$price.CheckedOn)
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Test-PilotOutput {
    param([string]$Text, $Checks)
    $outcomes = @()
    foreach ($pattern in @(Get-PilotValue $Checks 'Required' @())) {
        $outcomes += @{ Check = 'Required'; Pattern = $pattern; Passed = [regex]::IsMatch($Text, $pattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(1)) }
    }
    foreach ($pattern in @(Get-PilotValue $Checks 'Forbidden' @())) {
        $outcomes += @{ Check = 'Forbidden'; Pattern = $pattern; Passed = -not [regex]::IsMatch($Text, $pattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(1)) }
    }
    $exact = Get-PilotValue $Checks 'Exact'
    if ($null -ne $exact) { $outcomes += @{ Check = 'Exact'; Passed = ($Text.Trim() -ceq [string]$exact) } }
    $maxWords = Get-PilotValue $Checks 'MaxWords'
    if ($maxWords) { $outcomes += @{ Check = 'MaxWords'; Passed = (@($Text -split '\s+' | Where-Object { $_ }).Count -le [int]$maxWords) } }
    $maxCharacters = Get-PilotValue $Checks 'MaxCharacters'
    if ($maxCharacters) { $outcomes += @{ Check = 'MaxCharacters'; Passed = ($Text.Length -le [int]$maxCharacters) } }
    if (-not $outcomes.Count) { throw 'Every evaluation case must declare at least one objective check.' }
    return @{ Passed = (@($outcomes | Where-Object { -not $_.Passed }).Count -eq 0); Checks = $outcomes; Score = (@($outcomes | Where-Object Passed).Count / [double]$outcomes.Count) }
}

function Get-PilotMedian {
    param([double[]]$Values)
    if (-not $Values.Count) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return $sorted[$index] }
    return ($sorted[$index - 1] + $sorted[$index]) / 2.0
}

function Get-PilotModelDecision {
    param($Report)
    if ($Report.Status -ne 'Completed' -or $Report.CaseCount -lt 12 -or $Report.Repetitions -lt 3 -or -not $Report.UsageComplete) {
        return @{ Status = 'InsufficientEvidence'; Reason = 'A recommendation requires twelve cases, three paired repetitions, complete results and known usage.' }
    }
    $expected = [int]$Report.CaseCount * [int]$Report.Repetitions
    if (@($Report.Pairs).Count -ne $expected) { return @{ Status = 'InsufficientEvidence'; Reason = 'The paired comparison is incomplete.' } }
    $baselinePass = 0; $candidatePass = 0
    foreach ($pair in @($Report.Pairs)) {
        if ($pair.Baseline.Passed) { $baselinePass++ }
        if ($pair.Candidate.Passed) { $candidatePass++ }
        if (-not $pair.Candidate.Passed -or [double]$pair.Candidate.Score -lt [double]$pair.Baseline.Score) {
            return @{ Status = 'KeepCurrent'; Reason = 'The candidate failed a critical check or regressed on a paired task.' }
        }
        if ($Report.Role -eq 'Refine' -and [double]$pair.Candidate.DownstreamScore -lt [double]$pair.Control.Score) {
            return @{ Status = 'KeepCurrent'; Reason = 'Candidate refinement reduced downstream task success compared with the original request.' }
        }
    }
    $baselineCost = [double]$Report.Metrics.BaselineCostUsd
    $candidateCost = [double]$Report.Metrics.CandidateCostUsd
    $baselineLatency = [double]$Report.Metrics.BaselineMedianMs
    $candidateLatency = [double]$Report.Metrics.CandidateMedianMs
    if ($candidatePass -gt $baselinePass -and $candidateCost -le ($baselineCost * 1.25)) {
        return @{ Status = 'Recommended'; Reason = 'All candidate critical checks passed with improved task success and a cost increase no greater than 25%.' }
    }
    if ($candidatePass -eq $baselinePass -and $baselineCost -gt 0 -and $candidateCost -le ($baselineCost * 0.85)) {
        return @{ Status = 'Recommended'; Reason = 'Equivalent measured task success with at least 15% lower generation cost.' }
    }
    if ($candidatePass -eq $baselinePass -and $baselineLatency -gt 0 -and $candidateLatency -le ($baselineLatency * 0.8) -and $candidateCost -le $baselineCost) {
        return @{ Status = 'Recommended'; Reason = 'Equivalent measured task success with at least 20% lower median latency and no cost increase.' }
    }
    return @{ Status = 'KeepCurrent'; Reason = 'No material improvement within the configured quality, cost and latency policy.' }
}

function Invoke-PilotModelEvaluation {
    param($Provider, [string]$ApiKey, [hashtable]$Options, $Events = $null,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $dataDir = [string]$Options.DataDirectory
    $folder = Join-Path $dataDir 'models'
    $null = [IO.Directory]::CreateDirectory($folder)
    $lock = $null; $ledger = $null; $context = $null
    $report = @{ SchemaVersion = 1; Id = [guid]::NewGuid().ToString('N'); Provider = $Provider.Name; Role = $Options.Role; BaselineModel = $Options.BaselineModel; CandidateModel = $Options.CandidateModel; AnswerModel = $Options.AnswerModel; StartedAtUtc = [DateTime]::UtcNow.ToString('o'); FinishedAtUtc = ''; Status = 'Running'; Error = ''; Pairs = @(); Calls = @(); UsageComplete = $true; Repetitions = 3; CaseCount = 0; UsedUsd = 0.0; RunBudgetUsd = $Options.RunBudgetUsd; MonthlyBudgetUsd = $Options.MonthlyBudgetUsd; Fingerprint = ''; Prices = @{}; Metrics = @{}; Decision = @{ Status = 'InsufficientEvidence'; Reason = 'Not evaluated yet.' } }
    $reportPath = Join-Path $folder ('evaluations/' + $report.Id + '.json')
    try {
        if ($Options.Enabled -isnot [bool] -or -not $Options.Enabled) { throw 'Enable paid evaluations explicitly before comparing models.' }
        if ($Options.Role -notin @('Refine','Answer')) { throw 'Choose Refine or Answer.' }
        foreach ($limit in @('RunBudgetUsd','MonthlyBudgetUsd')) {
            $value = [double]$Options[$limit]
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0 -or $value -gt 100) { throw 'Evaluation ceilings must be finite USD amounts greater than zero and at most 100.' }
        }
        foreach ($name in @('BaselineModel','CandidateModel','AnswerModel')) { $report[$name] = Resolve-PilotModel $Provider.Name ([string]$Options[$name]) }
        if ($report.CandidateModel -eq $report.BaselineModel) { throw 'Choose a candidate different from the current default.' }
        $report.Fingerprint = Get-PilotEvaluationFingerprint $Provider.Name $report.Role $report.BaselineModel $report.CandidateModel $report.AnswerModel $Options.PricingOverrides
        $catalog = Read-PilotCatalog $dataDir $Provider.Name
        if (-not $catalog.LastSuccessUtc -or $catalog.LastError -or [DateTime]::Parse($catalog.LastSuccessUtc).ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(-7)) { throw 'Check available models successfully before evaluating (catalog must be no older than seven days).' }
        if ($report.CandidateModel -notin @($catalog.Models | ForEach-Object { $_.Id })) { throw 'The candidate is not listed in the current provider catalog.' }
        $report.CatalogFingerprint = Get-PilotCatalogFingerprint $catalog @($report.BaselineModel, $report.CandidateModel, $report.AnswerModel)
        $lock = [IO.File]::Open((Join-Path $folder 'evaluation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $ledgerPath = Join-Path $folder 'evaluation-budget.json'
        $ledger = @{ SchemaVersion = 1; Months = @{} }
        if (Test-Path -LiteralPath $ledgerPath) { $ledger = Read-PilotJson $ledgerPath }
        $corpus = Read-PilotJson (Join-Path $script:PilotCoreDirectory 'evaluations/model-cases.json')
        $cases = @($corpus.Cases | Where-Object { $report.Role -in $_.Roles })
        if ($cases.Count -lt 12) { throw 'The evaluation corpus does not contain twelve cases for this role.' }
        $report.CaseCount = $cases.Count
        $context = @{ Report = $report; Path = $reportPath; Ledger = $ledger; LedgerPath = $ledgerPath; Provider = $Provider; Key = $ApiKey; Options = $Options; Events = $Events; Token = $CancellationToken }
        foreach ($model in @($report.BaselineModel, $report.CandidateModel, $report.AnswerModel)) { $report.Prices[$model] = Get-PilotPricing $Provider.Name $model $Options.PricingOverrides }
        Write-PilotJson $reportPath $report
        $probe = Invoke-PilotEvaluationCall $context $report.CandidateModel 'Reply with exactly PROMPT_PILOT_OK and no other text.' '' 'Compatibility' 256
        if ($probe.Text.Trim() -ne 'PROMPT_PILOT_OK') { throw 'The candidate did not pass the short generation compatibility test.' }
        for ($repetition = 1; $repetition -le 3; $repetition++) {
            foreach ($case in $cases) {
                $CancellationToken.ThrowIfCancellationRequested()
                Send-PilotEvent $Events 'Progress' ('Comparing {0}: case {1}, repetition {2}/3. Reserved/used ${3:F4}.' -f $report.Role, $case.Id, $repetition, $report.UsedUsd)
                $pair = @{ CaseId = $case.Id; Repetition = $repetition; Baseline = $null; Candidate = $null; Control = $null }
                if ($report.Role -eq 'Refine') {
                    $control = Invoke-PilotEvaluationCall $context $report.AnswerModel $case.Prompt 'Answer the request exactly as specified.' 'Control'
                    $pair.Control = Test-PilotOutput $control.Text $case.AnswerChecks
                }
                # Alternate ordering so latency is not always measured in the same order.
                $order = if ($repetition % 2) { @('Baseline','Candidate') } else { @('Candidate','Baseline') }
                foreach ($side in $order) {
                    $model = $report[$side + 'Model']
                    $first = $report.Calls.Count
                    if ($report.Role -eq 'Refine') {
                        $response = Invoke-PilotEvaluationCall $context $model (New-PilotRefinementMessages $case.Prompt $case.Prompt 'Preserve every explicit constraint and permission.' '' '') (Get-PilotRefinementSystem $case.Profile) $side
                        $check = Test-PilotOutput $response.Text $case.RefinementChecks
                        $answer = Invoke-PilotEvaluationCall $context $report.AnswerModel $response.Text 'Answer the request exactly as specified.' ($side + ' downstream')
                        $answerCheck = Test-PilotOutput $answer.Text $case.AnswerChecks
                        $check.Passed = ($check.Passed -and $answerCheck.Passed)
                        $check.Score = ($check.Score + $answerCheck.Score) / 2.0
                        $check.DownstreamScore = $answerCheck.Score
                        $check.DownstreamChecks = $answerCheck.Checks
                    }
                    else {
                        $response = Invoke-PilotEvaluationCall $context $model $case.Prompt 'Answer the request exactly as specified.' $side
                        $check = Test-PilotOutput $response.Text $case.AnswerChecks
                    }
                    $calls = @($report.Calls | Select-Object -Skip $first)
                    $check.CostUsd = if (@($calls | Where-Object { $null -eq $_.CostUsd }).Count) { $null } else { ($calls | ForEach-Object { $_.CostUsd } | Measure-Object -Sum).Sum }
                    $check.LatencyMs = ($calls | ForEach-Object { $_.LatencyMs } | Measure-Object -Sum).Sum
                    $pair[$side] = $check
                }
                $report.Pairs += $pair
                Write-PilotJson $reportPath $report
            }
        }
        foreach ($model in @($report.BaselineModel, $report.CandidateModel, $report.AnswerModel) | Select-Object -Unique) {
            $snapshots = @($report.Calls | Where-Object { $_.Model -eq $model -and $_.ResolvedModel } | ForEach-Object { $_.ResolvedModel } | Select-Object -Unique)
            if ($snapshots.Count -gt 1) { throw 'A model resolved to different snapshots during evaluation. Run a fresh comparison.' }
        }
        $report.Status = 'Completed'
        $report.Metrics = @{ BaselineCostUsd = $(if ($report.UsageComplete) { ($report.Pairs | ForEach-Object { $_.Baseline.CostUsd } | Measure-Object -Sum).Sum } else { $null }); CandidateCostUsd = $(if ($report.UsageComplete) { ($report.Pairs | ForEach-Object { $_.Candidate.CostUsd } | Measure-Object -Sum).Sum } else { $null }); BaselineMedianMs = Get-PilotMedian @($report.Pairs | ForEach-Object { $_.Baseline.LatencyMs }); CandidateMedianMs = Get-PilotMedian @($report.Pairs | ForEach-Object { $_.Candidate.LatencyMs }); BaselinePassed = @($report.Pairs | Where-Object { $_.Baseline.Passed }).Count; CandidatePassed = @($report.Pairs | Where-Object { $_.Candidate.Passed }).Count }
    }
    catch {
        $report.Status = if ($CancellationToken.IsCancellationRequested) { 'Cancelled' } else { 'Incomplete' }
        $report.Error = Protect-PilotText $_.Exception.Message @($ApiKey)
        $report.ErrorLocation = $_.ScriptStackTrace
    }
    finally {
        $report.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
        $report.Decision = Get-PilotModelDecision $report
        try { Write-PilotJson $reportPath $report } finally { if ($lock) { $lock.Dispose() } }
    }
    return @{ Status = $(if ($report.Status -eq 'Completed') { 'Completed' } else { $report.Status }); Report = $report; ReportPath = $reportPath; Error = $report.Error }
}

function Invoke-PilotEvaluationCall {
    param($Context, [string]$Model, $Prompt, [string]$System, [string]$Purpose, [int]$MaxOutputTokens = 1024)
    $Context.Token.ThrowIfCancellationRequested()
    $messages = if ($Prompt -is [array]) { $Prompt } else { @(@{ role = 'user'; content = [string]$Prompt }) }
    $body = New-PilotChatJson $Context.Provider $Model $System $messages $MaxOutputTokens
    $price = $Context.Report.Prices[$Model]
    $ceiling = Get-PilotCallCeiling $body $MaxOutputTokens $price
    $month = [DateTime]::UtcNow.ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture)
    if (-not $Context.Ledger.Months.ContainsKey($month)) { $Context.Ledger.Months[$month] = @{ UsedUsd = 0.0; Requests = 0 } }
    $monthEntry = $Context.Ledger.Months[$month]
    if (($Context.Report.UsedUsd + $ceiling) -gt ([double]$Context.Options.RunBudgetUsd + 0.000000001) -or ($monthEntry.UsedUsd + $ceiling) -gt ([double]$Context.Options.MonthlyBudgetUsd + 0.000000001)) { throw 'Evaluation budget reached before dispatch. Completed evidence was saved; no default was changed.' }
    $monthEntry.UsedUsd += $ceiling; $monthEntry.Requests++
    $Context.Report.UsedUsd += $ceiling
    $call = @{ Model = $Model; Purpose = $Purpose; Prompt = $messages; System = $System; AtUtc = [DateTime]::UtcNow.ToString('o'); CostUsd = $null; ReservedUsd = $ceiling; Output = ''; LatencyMs = $null; Status = 'Reserved'; ResolvedModel = ''; RequestId = ''; InputTokens = $null; OutputTokens = $null; Error = '' }
    $Context.Report.Calls += $call
    # Persist the liability first. A crash after this point cannot erase the reservation.
    Write-PilotJson $Context.LedgerPath $Context.Ledger
    Write-PilotJson $Context.Path $Context.Report
    $budget = New-PilotBudget -LimitUsd ([Math]::Max([double]0.000000001, [double]$ceiling)) -Pricing $price
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-PilotChat -Provider $Context.Provider -ApiKey $Context.Key -Model $Model -System $System -Messages $messages -MaxOutputTokens $MaxOutputTokens -Budget $budget -Events $Context.Events -CancellationToken $Context.Token -MaxRetries 0
        $call.Output = $response.Text; $call.ResolvedModel = $response.ResolvedModel
        $call.RequestId = [string](Get-PilotValue $response 'RequestId' '')
        $call.InputTokens = Get-PilotValue $response 'InputTokens'
        $call.OutputTokens = Get-PilotValue $response 'OutputTokens'
        if ($null -eq $response.CostUsd) { $Context.Report.UsageComplete = $false }
        $call.CostUsd = $response.CostUsd; $call.Status = 'Completed'
        if ($response.Truncated) { throw 'An evaluation response reached its output limit; the comparison is incomplete.' }
        return $response
    }
    catch { $call.Error = Protect-PilotText $_.Exception.Message @($Context.Key); $call.Status = 'Failed'; throw }
    finally {
        $call.LatencyMs = $watch.Elapsed.TotalMilliseconds
        $retained = [double]$budget.UsedUsd
        $monthEntry.UsedUsd = [Math]::Max([double]0, [double]($monthEntry.UsedUsd - $ceiling + $retained))
        $Context.Report.UsedUsd = [Math]::Max([double]0, [double]($Context.Report.UsedUsd - $ceiling + $retained))
        $call.ReservedUsd = $retained
        if ($null -eq $call.CostUsd -and $retained -gt 0) { $Context.Report.UsageComplete = $false }
        Write-PilotJson $Context.LedgerPath $Context.Ledger
        Write-PilotJson $Context.Path $Context.Report
    }
}

function Assert-PilotRecommendation {
    param($Report, $Preferences, [string]$DataDirectory)
    if ((Get-PilotModelDecision $Report).Status -ne 'Recommended') { throw 'This comparison does not meet the recommendation policy.' }
    $provider = Resolve-PilotProvider $Report.Provider
    $role = [string]$Report.Role
    if ($role -notin @('Refine','Answer')) { throw 'Invalid recommendation role.' }
    if ($Preferences.Providers[$provider].Pins[$role]) { throw 'This default is pinned. Unpin it explicitly before accepting a recommendation.' }
    if ((Get-PilotRoleModel $Preferences $provider $role) -ne $Report.BaselineModel) { throw 'The baseline default changed. Run a new comparison.' }
    if ([DateTime]::Parse($Report.FinishedAtUtc).ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(-7) -or [DateTime]::Parse($Report.FinishedAtUtc).ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5)) { throw 'This recommendation expired or has an invalid timestamp. Run a fresh comparison.' }
    $answerModel = Get-PilotRoleModel $Preferences $provider Answer
    $fingerprint = Get-PilotEvaluationFingerprint $provider $role $Report.BaselineModel $Report.CandidateModel $answerModel $Preferences.PricingOverrides
    if ($fingerprint -ne $Report.Fingerprint) { throw 'Models, prices, prompts or evaluation code changed. Run a fresh comparison.' }
    $catalog = Read-PilotCatalog $DataDirectory $provider
    if (-not $catalog.LastSuccessUtc -or $catalog.LastError -or [DateTime]::Parse($catalog.LastSuccessUtc).ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(-7) -or $Report.CandidateModel -notin @($catalog.Models | ForEach-Object { $_.Id })) { throw 'Refresh the provider catalog successfully before accepting this recommendation.' }
    if ((Get-PilotCatalogFingerprint $catalog @($Report.BaselineModel, $Report.CandidateModel, $Report.AnswerModel)) -ne (Get-PilotValue $Report 'CatalogFingerprint')) { throw 'Provider model metadata changed. Run a fresh comparison.' }
}

function Accept-PilotRecommendation {
    param($Report, $Preferences, [string]$DataDirectory, [string]$SettingsPath)
    Assert-PilotRecommendation $Report $Preferences $DataDirectory
    $next = ConvertTo-PilotMap ($Preferences | ConvertTo-Json -Depth 25 | ConvertFrom-Json)
    Set-PilotRoleModel $next $Report.Provider $Report.Role $Report.CandidateModel $false
    $next.ModelManagement.History = @($next.ModelManagement.History | Select-Object -Last 49) + @(@{ Id = [guid]::NewGuid().ToString('N'); Action = 'Accept'; Provider = $Report.Provider; Role = $Report.Role; From = $Report.BaselineModel; To = $Report.CandidateModel; ReportId = $Report.Id; AtUtc = [DateTime]::UtcNow.ToString('o') })
    Save-PilotPreferences $SettingsPath $next
    return $next
}

function Undo-PilotModelDefault {
    param($Preferences, [string]$ProviderName, [ValidateSet('Refine','Answer')][string]$Role, [string]$SettingsPath)
    $provider = Resolve-PilotProvider $ProviderName
    if ($Preferences.Providers[$provider].Pins[$Role]) { throw 'Unpin this default explicitly before rolling it back.' }
    $current = Get-PilotRoleModel $Preferences $provider $Role
    $last = @($Preferences.ModelManagement.History | Where-Object { $_.Provider -eq $provider -and $_.Role -eq $Role } | Select-Object -Last 1)
    if (-not $last.Count -or $last[0].Action -ne 'Accept' -or $last[0].To -ne $current) { throw 'There is no matching accepted default to roll back.' }
    $next = ConvertTo-PilotMap ($Preferences | ConvertTo-Json -Depth 25 | ConvertFrom-Json)
    Set-PilotRoleModel $next $provider $Role $last[0].From $false
    $next.ModelManagement.History = @($next.ModelManagement.History | Select-Object -Last 49) + @(@{ Id = [guid]::NewGuid().ToString('N'); Action = 'Rollback'; Provider = $provider; Role = $Role; From = $current; To = $last[0].From; ReportId = $last[0].ReportId; AtUtc = [DateTime]::UtcNow.ToString('o') })
    Save-PilotPreferences $SettingsPath $next
    return $next
}
