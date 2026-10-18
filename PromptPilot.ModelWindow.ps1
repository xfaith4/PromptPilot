function Get-PilotDecisionLabel {
    param([string]$Status)
    switch ($Status) { 'KeepCurrent' { return 'Keep current' } 'InsufficientEvidence' { return 'More evidence needed' } 'Recommended' { return 'Recommended' } default { return $Status } }
}

function Format-PilotComparisonNumber {
    param($Value, [string]$Format)
    if ($null -eq $Value) { return 'Unknown' }
    return $Format -f [double]$Value
}

# Native dialog, loaded after the main desktop helpers.
function Set-PilotModelBusy {
    param([bool]$Busy)
    if (-not $script:ModelContext) { return }
    foreach ($name in @('Discover','Evaluate','Accept','Rollback','SavePolicy','SavePrices','Role','Candidate','Auto','Enabled','RunBudget','MonthBudget','PinRefine','PinAnswer','InputPrice','OutputPrice','Reports')) { $script:ModelContext[$name].IsEnabled = -not $Busy }
    $script:ModelContext.Cancel.IsEnabled = $Busy
    if (-not $Busy) { Update-PilotRecommendationActions }
}

function Update-PilotRecommendationActions {
    if (-not $script:ModelContext) { return }
    $s = $script:ModelContext
    $s.Accept.IsEnabled = $false
    if ($s.Reports.SelectedItem) {
        try { Assert-PilotRecommendation $s.Reports.SelectedItem.Report $script:Preferences $script:DataDirectory; $s.Accept.IsEnabled = $true; $s.Accept.ToolTip = 'Apply this verified recommendation to future sessions.' }
        catch { $s.Accept.ToolTip = $_.Exception.Message }
    }
    $role = Get-PilotModelRole
    $last = @($script:Preferences.ModelManagement.History | Where-Object { $_.Provider -eq $s.Provider -and $_.Role -eq $role } | Select-Object -Last 1)
    $s.Rollback.IsEnabled = ($last.Count -gt 0 -and $last[0].Action -eq 'Accept' -and $last[0].To -eq (Get-PilotRoleModel $script:Preferences $s.Provider $role) -and -not $script:Preferences.Providers[$s.Provider].Pins[$role])
}

function Get-PilotModelRole {
    return $(if ($script:ModelContext.Role.SelectedIndex -eq 0) { 'Refine' } else { 'Answer' })
}

function Update-PilotModelPrices {
    if (-not $script:ModelContext) { return }
    $s = $script:ModelContext
    try {
        $price = Get-PilotPricing $s.Provider $s.Candidate.Text $script:Preferences.PricingOverrides
        $s.InputPrice.Text = $(if ($price.Known) { ([double]$price.InputPerMillion).ToString('G', [Globalization.CultureInfo]::InvariantCulture) } else { '' })
        $s.OutputPrice.Text = $(if ($price.Known) { ([double]$price.OutputPerMillion).ToString('G', [Globalization.CultureInfo]::InvariantCulture) } else { '' })
        $s.PriceInfo.Text = $price.Source + ' | ' + $price.CheckedOn
    }
    catch { $s.PriceInfo.Text = $_.Exception.Message }
}

function Update-PilotModelView {
    if (-not $script:ModelContext) { return }
    $s = $script:ModelContext
    $role = Get-PilotModelRole
    $s.Defaults.Text = 'Refinement: ' + (Get-PilotRoleModel $script:Preferences $s.Provider Refine) + "`nAnswers: " + (Get-PilotRoleModel $script:Preferences $s.Provider Answer)
    $s.Baseline.Text = 'Compare against: ' + (Get-PilotRoleModel $script:Preferences $s.Provider $role)
    $selected = $s.Candidate.Text
    $catalog = Read-PilotCatalog $script:DataDirectory $s.Provider
    $s.Candidate.Items.Clear()
    foreach ($model in @($catalog.Models)) { $null = $s.Candidate.Items.Add([string]$model.Id) }
    $s.Candidate.Text = $selected
    $s.Catalog.Text = $(if ($catalog.LastSuccessUtc) { 'Last successful discovery: ' + $catalog.LastSuccessUtc + ' | Models: ' + @($catalog.Models).Count + ' | Newly discovered: ' + @($catalog.NewIds).Count } else { 'No catalog yet. Check available models before comparing.' })
    if ($catalog.LastError) { $s.Catalog.Text += "`nLast check failed; cached IDs retained. " + $catalog.LastError }
    $s.PinRefine.IsChecked = $script:Preferences.Providers[$s.Provider].Pins.Refine
    $s.PinAnswer.IsChecked = $script:Preferences.Providers[$s.Provider].Pins.Answer
    $selectedPath = if ($s.Reports.SelectedItem) { $s.Reports.SelectedItem.Path } else { '' }
    $s.Reports.Items.Clear()
    $directory = Join-Path $script:DataDirectory 'models/evaluations'
    if (Test-Path -LiteralPath $directory) {
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 30)) {
            try {
                $report = Read-PilotJson $file.FullName
                if ($report.Provider -ne $s.Provider) { continue }
                $item = [pscustomobject]@{ Title = ('{0} | {1} | {2} | {3}' -f $report.Role, $report.CandidateModel, (Get-PilotDecisionLabel $report.Decision.Status), $report.StartedAtUtc); Path = $file.FullName; Report = $report }
                $null = $s.Reports.Items.Add($item)
                if ($file.FullName -eq $selectedPath) { $s.Reports.SelectedItem = $item }
            }
            catch { Write-PilotLog ('A model comparison report could not be read: ' + $_.Exception.Message) }
        }
    }
    Update-PilotModelPrices
    Update-PilotRecommendationActions
}

function Show-PilotModelReport {
    $s = $script:ModelContext
    if (-not $s -or -not $s.Reports.SelectedItem) { return }
    $r = $s.Reports.SelectedItem.Report
    $m = $r.Metrics
    $metrics = if ($r.Status -eq 'Completed') {
        'Tasks passed: current {0}/{2}; candidate {1}/{2}.' -f $m.BaselinePassed, $m.CandidatePassed, @($r.Pairs).Count
        'Comparison generation cost: current {0}; candidate {1}.' -f (Format-PilotComparisonNumber (Get-PilotValue $m 'BaselineCostUsd') '${0:F5}'), (Format-PilotComparisonNumber (Get-PilotValue $m 'CandidateCostUsd') '${0:F5}')
        'Median time per task: current {0}; candidate {1}.' -f (Format-PilotComparisonNumber (Get-PilotValue $m 'BaselineMedianMs') '{0:F0} ms'), (Format-PilotComparisonNumber (Get-PilotValue $m 'CandidateMedianMs') '{0:F0} ms')
    } else { 'Comparison metrics are incomplete.' }
    $failures = @($r.Pairs | Where-Object { -not $_.Candidate.Passed } | ForEach-Object { $_.CaseId + ' (repeat ' + $_.Repetition + ')' } | Select-Object -First 12)
    $s.Details.Text = @(
        ('Decision: ' + (Get-PilotDecisionLabel $r.Decision.Status) + ' | ' + $r.Decision.Reason),
        ('Provider: ' + $r.Provider + ' | Role: ' + $r.Role),
        ('Current comparison baseline: ' + $r.BaselineModel + ' | Candidate: ' + $r.CandidateModel),
        ('Fixed downstream answer model: ' + $r.AnswerModel),
        ('Status: ' + $r.Status + ' | Complete paired tasks: ' + @($r.Pairs).Count + ' | Cases: ' + $r.CaseCount + ' x ' + $r.Repetitions),
        ('Total used/reserved: ${0:F5} | Usage complete: {1}' -f $r.UsedUsd, $r.UsageComplete),
        ($metrics -join "`n"),
        ('Candidate checks needing review: ' + $(if ($failures.Count) { $failures -join ', ' } else { 'None recorded.' })),
        ('Error: ' + $r.Error),
        ('Evidence: ' + $s.Reports.SelectedItem.Path),
        'Reports contain synthetic prompts and outputs. These checks do not establish universal usefulness. Defaults require explicit acceptance; existing sessions keep their choices.'
    ) -join "`n`n"
    Update-PilotRecommendationActions
}

function Save-PilotModelPolicyFromUi {
    $s = $script:ModelContext
    $run = 0.0; $month = 0.0
    if (-not [double]::TryParse($s.RunBudget.Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$run) -or -not [double]::TryParse($s.MonthBudget.Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$month) -or $run -le 0 -or $month -le 0 -or $run -gt 100 -or $month -gt 100 -or [double]::IsNaN($run) -or [double]::IsNaN($month)) { throw 'Evaluation budgets must be USD amounts greater than zero and at most 100, using a decimal point.' }
    $script:Preferences.ModelManagement.AutoCheck = ($s.Auto.IsChecked -eq $true)
    $script:Preferences.ModelManagement.EvaluationEnabled = ($s.Enabled.IsChecked -eq $true)
    $script:Preferences.ModelManagement.RunBudgetUsd = $run
    $script:Preferences.ModelManagement.MonthlyBudgetUsd = $month
    $script:Preferences.Providers[$s.Provider].Pins.Refine = ($s.PinRefine.IsChecked -eq $true)
    $script:Preferences.Providers[$s.Provider].Pins.Answer = ($s.PinAnswer.IsChecked -eq $true)
    Save-PilotUiPreferences
}

function Complete-PilotModelOperation {
    param($Operation, $Result)
    if (-not $script:ModelContext) {
        if ($Result.Error) { Write-PilotLog ('Model check: ' + $Result.Error) }
        elseif ($Operation.Mode -eq 'Discover' -and @($Result.Catalog.NewIds).Count) {
            $count = @($Result.Catalog.NewIds).Count
            $script:Controls.ModelsButton.Content = 'Models (' + $(if ($count -gt 99) { '99+' } else { [string]$count }) + ')'
            $script:Controls.ModelsButton.ToolTip = '{0} model IDs newly seen for this account. Open model recommendations to review prices and run a comparison.' -f $count
        }
        return
    }
    $s = $script:ModelContext
    Update-PilotModelView
    $s.Status.Text = $(if ($Result.Status -eq 'Completed') { if ($Operation.Mode -eq 'Discover') { 'Available models updated. No generation was requested.' } else { (Get-PilotDecisionLabel $Result.Report.Decision.Status) + ': ' + $Result.Report.Decision.Reason } } else { $Result.Error })
    if (Get-PilotValue $Result 'ReportPath') {
        foreach ($item in $s.Reports.Items) { if ($item.Path -eq $Result.ReportPath) { $s.Reports.SelectedItem = $item; break } }
    }
}

function Invoke-PilotAutomaticModelCheck {
    if ($SmokeTest -or $script:Closing -or $script:Operation -or $script:SettingsContext -or $script:ModelContext -or [DateTime]::UtcNow -lt $script:NextModelPollUtc) { return }
    $script:NextModelPollUtc = [DateTime]::UtcNow.AddMinutes(10)
    if (-not $script:Preferences.ModelManagement.AutoCheck) { return }
    try {
        $provider = (Get-PilotProviders)[$script:Session.ProviderName]
        if (-not (Test-PilotCatalogDue (Read-PilotCatalog $script:DataDirectory $provider.Name))) { return }
        $credential = Get-PilotCredential $provider.Name $script:Preferences $script:SessionKeys
        if (-not $credential.Key) { return }
        $key = Get-PilotUiCredential $provider.Name
        Start-PilotBackground Discover @{ DataDirectory = $script:DataDirectory } $provider $key Catalog
    }
    catch { Write-PilotLog ('Automatic model discovery deferred: ' + $_.Exception.Message) }
}

function Show-PilotModelManagement {
    if ($script:Operation) { Set-PilotFeedback 'Finish or cancel the current request before managing models.'; return }
    [xml]$markup = Get-Content -LiteralPath (Join-Path $script:AppDirectory 'Prompt_Pilot.Models.xaml') -Raw -Encoding UTF8
    $dialog = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup)); $dialog.Owner = $script:Window
    $script:ModelContext = @{ Dialog = $dialog; Provider = $script:Session.ProviderName }
    foreach ($name in @('Defaults','Role','Baseline','Candidate','Catalog','Discover','Auto','Enabled','RunBudget','MonthBudget','PinRefine','PinAnswer','SavePolicy','InputPrice','OutputPrice','PriceInfo','SavePrices','Evaluate','Cancel','Status','Reports','Details','Accept','Rollback','OpenReport','Close')) { $script:ModelContext[$name] = $dialog.FindName($name) }
    $s = $script:ModelContext
    $dialog.Title = 'Prompt Pilot - Model recommendations | ' + $s.Provider
    foreach ($role in @('Prompt refinement','Answer generation')) { $null = $s.Role.Items.Add($role) }; $s.Role.SelectedIndex = 0
    $policy = $script:Preferences.ModelManagement
    $s.Auto.IsChecked = $policy.AutoCheck; $s.Enabled.IsChecked = $policy.EvaluationEnabled
    $s.RunBudget.Text = ([double]$policy.RunBudgetUsd).ToString('G', [Globalization.CultureInfo]::InvariantCulture)
    $s.MonthBudget.Text = ([double]$policy.MonthlyBudgetUsd).ToString('G', [Globalization.CultureInfo]::InvariantCulture)
    $s.Role.Add_SelectionChanged({ if ($script:ModelContext) { Update-PilotModelView } })
    $s.Candidate.Add_SelectionChanged({ if ($script:ModelContext -and $script:ModelContext.Candidate.SelectedItem) { $script:ModelContext.Candidate.Text = [string]$script:ModelContext.Candidate.SelectedItem; Update-PilotModelPrices } })
    $s.Candidate.Add_LostKeyboardFocus({ Update-PilotModelPrices })
    $s.SavePolicy.Add_Click({ try { Save-PilotModelPolicyFromUi; $script:ModelContext.Status.Text = 'Discovery, paid-evaluation budgets and pins saved.' } catch { $script:ModelContext.Status.Text = $_.Exception.Message } })
    $s.Discover.Add_Click({ try { $provider = (Get-PilotProviders)[$script:ModelContext.Provider]; Start-PilotBackground Discover @{ DataDirectory = $script:DataDirectory } $provider (Get-PilotUiCredential $provider.Name) Models } catch { $script:ModelContext.Status.Text = $_.Exception.Message } })
    $s.SavePrices.Add_Click({
        try {
            $s = $script:ModelContext; $model = Resolve-PilotModel $s.Provider $s.Candidate.Text
            $inputRate = 0.0; $outputRate = 0.0
            if (-not [double]::TryParse($s.InputPrice.Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$inputRate) -or -not [double]::TryParse($s.OutputPrice.Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$outputRate)) { throw 'Enter both token prices using a decimal point.' }
            $rates = @{ InputPerMillion = $inputRate; OutputPerMillion = $outputRate; CheckedOn = [DateTime]::UtcNow.ToString('yyyy-MM-dd') }
            $overrides = $script:Preferences.PricingOverrides.Clone(); $overrides[($s.Provider + '/' + $model)] = $rates
            $null = Get-PilotPricing $s.Provider $model $overrides
            $script:Preferences.PricingOverrides = $overrides; Save-PilotUiPreferences
            Update-PilotModelPrices; $s.Status.Text = 'Explicit custom rates saved. Check them against your provider account before evaluating.'
        }
        catch { $script:ModelContext.Status.Text = $_.Exception.Message }
    })
    $s.Evaluate.Add_Click({
        try {
            Save-PilotModelPolicyFromUi
            $s = $script:ModelContext; $policy = $script:Preferences.ModelManagement; $role = Get-PilotModelRole
            if (-not $policy.EvaluationEnabled) { throw 'Check Enable paid evaluations before running a comparison.' }
            $options = @{ Enabled = $policy.EvaluationEnabled; DataDirectory = $script:DataDirectory; Role = $role; BaselineModel = Get-PilotRoleModel $script:Preferences $s.Provider $role; CandidateModel = Resolve-PilotModel $s.Provider $s.Candidate.Text; AnswerModel = Get-PilotRoleModel $script:Preferences $s.Provider Answer; PricingOverrides = $script:Preferences.PricingOverrides.Clone(); RunBudgetUsd = $policy.RunBudgetUsd; MonthlyBudgetUsd = $policy.MonthlyBudgetUsd }
            Start-PilotBackground Evaluate $options (Get-PilotProviders)[$s.Provider] (Get-PilotUiCredential $s.Provider) Models
            $s.Status.Text = 'Paid comparison running on synthetic tasks. All probes, controls and baseline requests count toward both budgets.'
        }
        catch { $script:ModelContext.Status.Text = $_.Exception.Message }
    })
    $s.Cancel.Add_Click({ Stop-PilotBackground })
    $s.Reports.DisplayMemberPath = 'Title'; $s.Reports.Add_SelectionChanged({ Show-PilotModelReport })
    $s.Accept.Add_Click({
        try {
            $s = $script:ModelContext
            if (-not $s.Reports.SelectedItem) { throw 'Select a completed recommendation first.' }
            if ($script:SettingsReadError) { throw $script:SettingsReadError }
            $script:Preferences = Accept-PilotRecommendation $s.Reports.SelectedItem.Report $script:Preferences $script:DataDirectory $script:SettingsPath
            Update-PilotModelView
            $s.Status.Text = 'Default accepted for future sessions. Your current session keeps its own model choices.'
        }
        catch { $script:ModelContext.Status.Text = $_.Exception.Message }
    })
    $s.Rollback.Add_Click({
        try {
            $s = $script:ModelContext
            if ($script:SettingsReadError) { throw $script:SettingsReadError }
            $script:Preferences = Undo-PilotModelDefault $script:Preferences $s.Provider (Get-PilotModelRole) $script:SettingsPath
            Update-PilotModelView; $s.Status.Text = 'Previous default restored for future sessions. Current work was preserved.'
        }
        catch { $script:ModelContext.Status.Text = $_.Exception.Message }
    })
    $s.OpenReport.Add_Click({ try { if ($script:ModelContext.Reports.SelectedItem) { Start-Process notepad.exe -ArgumentList ('"' + $script:ModelContext.Reports.SelectedItem.Path + '"') } } catch { $script:ModelContext.Status.Text = $_.Exception.Message } })
    $s.Close.Add_Click({ $script:ModelContext.Dialog.Close() })
    $dialog.Add_Closing({ if ($script:Operation -and $script:Operation.Target -eq 'Models') { Stop-PilotBackground } })
    Update-PilotModelView; Set-PilotModelBusy $false
    try { $null = $dialog.ShowDialog() } finally { $script:ModelContext = $null }
}
