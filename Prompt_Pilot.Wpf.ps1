[CmdletBinding()]
param(
    [string]$DataDirectory = '',
    [switch]$SmokeTest,
    [string]$SmokeReportPath = ''
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Prompt Pilot requires Windows with WPF and PowerShell 5.1 or later.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'Launch Prompt Pilot using Start Prompt Pilot.cmd, or run PowerShell with -STA.' }
$script:AppDirectory = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { [IO.Path]::GetDirectoryName([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
. (Join-Path $script:AppDirectory 'PromptPilot.Core.ps1')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:Product = Read-PilotJson (Join-Path $script:AppDirectory 'data/product.json')
if ($SmokeTest -and (-not $DataDirectory -or -not $SmokeReportPath)) { throw 'Smoke testing requires an isolated data directory and a report path.' }
if (-not $DataDirectory) { $DataDirectory = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Prompt Pilot' }
$script:DataDirectory = [IO.Path]::GetFullPath($DataDirectory)
$script:SettingsPath = Join-Path $script:DataDirectory 'settings.json'
$script:SessionsDirectory = Join-Path $script:DataDirectory 'sessions'
$null = [IO.Directory]::CreateDirectory($script:DataDirectory)
$script:SessionKeys = @{}
$script:KnownSecrets = @()
$script:Controls = @{}
$script:Operation = $null
$script:Dirty = $false
$script:LoadingSession = $false
$script:Closing = $false
$script:SettingsReadError = ''
$script:LogFilePath = ''
$script:LogFailure = ''
$script:LastEditUtc = [DateTime]::UtcNow
$script:SettingsContext = $null
$script:ModelContext = $null
$script:NextModelPollUtc = [DateTime]::UtcNow.AddSeconds(15)
$script:PendingRunAfterDiscovery = $false
$script:InstancePath = Join-Path $script:DataDirectory 'instance.json'
$script:Mutex = $null
$script:OwnsMutex = $false

function Write-PilotLog {
    param([string]$Message)
    $safe = Protect-PilotText $Message $script:KnownSecrets
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffzzz'), $safe
    if ($script:Controls.ContainsKey('LogTextBox')) {
        $box = $script:Controls.LogTextBox
        if ($box.LineCount -gt 1500) { $box.Text = ($box.Text -split "`n" | Select-Object -Last 750) -join "`n" }
        $box.AppendText($line + "`n"); $box.ScrollToEnd()
    }
    if ($script:LogFilePath) {
        try {
            if ((Get-Item -LiteralPath $script:LogFilePath).Length -gt 5242880) { Initialize-PilotLogging }
            Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch { $script:LogFailure = 'The log file could not be written. Check folder permissions and disk space.' }
    }
}

function Initialize-PilotLogging {
    foreach ($directory in @((Join-Path $script:AppDirectory 'logs'), (Join-Path $script:DataDirectory 'logs'))) {
        try {
            $null = [IO.Directory]::CreateDirectory($directory)
            $name = 'Prompt_Pilot_{0}_{1}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $script:LogFilePath = Join-Path $directory $name
            [IO.File]::WriteAllText($script:LogFilePath, '', [Text.UTF8Encoding]::new($false))
            $managedLogs = @(Get-ChildItem -LiteralPath $directory -Filter 'Prompt_Pilot_*.log' -File | Sort-Object LastWriteTimeUtc -Descending)
            for ($index = 0; $index -lt $managedLogs.Count; $index++) {
                if ($managedLogs[$index].FullName -ne $script:LogFilePath -and ($index -ge 100 -or $managedLogs[$index].LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-30))) {
                    Remove-Item -LiteralPath $managedLogs[$index].FullName -ErrorAction SilentlyContinue
                }
            }
            Write-PilotLog ('Session started. Version={0}; PowerShell={1}; logs={2}' -f $script:Product.version, $PSVersionTable.PSVersion, $script:LogFilePath)
            return
        }
        catch { $script:LogFilePath = '' }
    }
    $script:LogFailure = 'Disk logging is unavailable. Check the app and user-data folder permissions.'
}

function Set-PilotFeedback {
    param([string]$Message, [switch]$ErrorState)
    $script:Controls.FeedbackTextBlock.Text = Protect-PilotText $Message $script:KnownSecrets
    $script:Controls.FeedbackTextBlock.Foreground = if ($ErrorState) { [Windows.Media.Brushes]::Firebrick } else { [Windows.Media.Brushes]::SlateGray }
    if ($ErrorState) { $script:Controls.ActivityExpander.IsExpanded = $true; Write-PilotLog $Message }
}

function Save-PilotUiPreferences {
    if ($script:SettingsReadError) { throw $script:SettingsReadError }
    Save-PilotPreferences $script:SettingsPath $script:Preferences
}

function Get-PilotUiCredential {
    param([string]$ProviderName, [string]$TypedKey = '')
    if ($TypedKey) { $key = $TypedKey }
    else { $key = (Get-PilotCredential $ProviderName $script:Preferences $script:SessionKeys).Key }
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'Configure an API key in Providers and API keys before running.' }
    if ($key -notin $script:KnownSecrets) { $script:KnownSecrets += $key }
    return $key
}

function Update-PilotProviderUi {
    $provider = (Get-PilotProviders)[$script:Session.ProviderName]
    try { $source = (Get-PilotCredential $provider.Name $script:Preferences $script:SessionKeys).Source }
    catch { $source = 'saved key unavailable for this Windows user' }
    $script:Controls.ProviderButton.Content = '{0} | {1}' -f $provider.DisplayName, $source
    $pricing = Get-PilotPricing $provider.Name $script:Session.Model $script:Preferences.PricingOverrides
    if ($pricing.Known) {
        $script:Controls.PricingTextBlock.Text = '{0} | Est. rates: ${1:g} input / ${2:g} output per 1M tokens' -f $script:Session.Model, $pricing.InputPerMillion, $pricing.OutputPerMillion
    }
    else { $script:Controls.PricingTextBlock.Text = $script:Session.Model + ' | Set token prices in provider settings before running.' }
    $script:Controls.PricingTextBlock.ToolTip = $pricing.Source + ' | Checked: ' + $pricing.CheckedOn
}

function Set-PilotUiMode {
    param([ValidateSet('Refine', 'Answer')][string]$Mode)
    $script:Session.Mode = $Mode
    $script:Session.Model = if ($Mode -eq 'Refine') { $script:Session.RefinementModel } else { $script:Session.AnswerModel }
    $script:Controls.ModeRefineRadio.IsChecked = ($Mode -eq 'Refine')
    $script:Controls.ModeAnswerRadio.IsChecked = ($Mode -eq 'Answer')
    $script:Controls.RunButton.Content = if ($Mode -eq 'Refine') { 'Refine prompt' } else { 'Get answer' }
    $script:Controls.IterationsTextBox.IsEnabled = ($Mode -eq 'Refine' -and -not $script:Operation)
    $script:Controls.AnswerSourcePanel.Visibility = if ($Mode -eq 'Answer') { 'Visible' } else { 'Collapsed' }
    Update-PilotProviderUi
}

function Set-PilotBusy {
    param([bool]$Busy)
    foreach ($name in @('ModelsButton', 'MenuModelManagement', 'RunButton', 'NewSessionButton', 'OpenSessionButton', 'SaveSessionButton', 'BrowseButton', 'IncludeFileCheckBox', 'ModeRefineRadio', 'ModeAnswerRadio', 'ProfileComboBox', 'ExampleComboBox', 'IterationsTextBox', 'MaxOutputTextBox', 'BudgetTextBox', 'PromptTextBox', 'GoalsTextBox', 'ProjectContextTextBox', 'FinalPromptTextBox', 'UsePromptButton', 'ProviderButton', 'AutosaveCheckBox', 'AnswerSourceComboBox', 'MenuNewSession', 'MenuOpenSession', 'MenuSaveSession', 'MenuSettingsApiKey')) {
        $script:Controls[$name].IsEnabled = -not $Busy
    }
    $script:Controls.CancelButton.IsEnabled = $Busy
    $script:Controls.AcceptIterationButton.IsEnabled = ($Busy -and $script:Operation -and $script:Operation.Mode -eq 'Refine' -and $script:Session.Revisions.Count -gt 0)
    $script:Controls.BusyProgressBar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    if (-not $Busy) { $script:Controls.IterationsTextBox.IsEnabled = ($script:Session.Mode -eq 'Refine') }
    Update-PilotActionState
}

function Update-PilotActionState {
    if (-not $script:Controls.ContainsKey('CopyButton')) { return }
    $hasDraft = -not [string]::IsNullOrWhiteSpace($script:Controls.FinalPromptTextBox.Text)
    $script:Controls.CopyButton.IsEnabled = $hasDraft
    $script:Controls.UsePromptButton.IsEnabled = ($hasDraft -and -not $script:Operation)
    $script:Controls.CopyTaskOutputButton.IsEnabled = -not [string]::IsNullOrWhiteSpace($script:Controls.TaskOutputTextBox.Text)
}

function Mark-PilotDirty {
    Update-PilotActionState
    if (-not $script:LoadingSession) { $script:Dirty = $true; $script:LastEditUtc = [DateTime]::UtcNow; $script:Controls.SaveStateTextBlock.Text = 'Unsaved changes - stored locally when autosave is enabled.' }
}

function Sync-PilotSessionFromUi {
    param([switch]$ValidateRunLimits)
    $c = $script:Controls
    $script:Session.BasePrompt = $c.PromptTextBox.Text
    $script:Session.Goals = $c.GoalsTextBox.Text
    $script:Session.ProjectContext = $c.ProjectContextTextBox.Text
    $script:Session.FilePath = $c.FilePathTextBox.Text
    $script:Session.IncludeFile = ($c.IncludeFileCheckBox.IsChecked -eq $true)
    $script:Session.FinalPrompt = $c.FinalPromptTextBox.Text
    $script:Session.Answer = $c.TaskOutputTextBox.Text
    $script:Session.Profile = [string]$c.ProfileComboBox.SelectedItem
    $script:Session.AnswerSource = if ($c.AnswerSourceComboBox.SelectedIndex -eq 0) { 'Draft' } else { 'Original' }
    $iterations = 0; $output = 0; $budget = 0.0
    if ([int]::TryParse($c.IterationsTextBox.Text, [ref]$iterations) -and $iterations -in 1..5) { $script:Session.Iterations = $iterations }
    elseif ($ValidateRunLimits) { throw 'Iterations must be a whole number from 1 to 5.' }
    if ([int]::TryParse($c.MaxOutputTextBox.Text, [ref]$output) -and $output -ge 256 -and $output -le 8192) { $script:Session.MaxOutputTokens = $output }
    elseif ($ValidateRunLimits) { throw 'Output token limit must be a whole number from 256 to 8,192.' }
    if ([double]::TryParse($c.BudgetTextBox.Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$budget) -and $budget -gt 0 -and $budget -le 50 -and -not [double]::IsNaN($budget)) { $script:Session.BudgetUsd = $budget }
    elseif ($ValidateRunLimits) { throw 'Run budget must be a USD amount greater than zero and at most 50, using a decimal point.' }

}

function Save-PilotAutosave {
    param([switch]$Force)
    if (-not $script:Preferences.Autosave -and -not $Force) { return }
    if ($script:LoadingSession -or -not $script:Session) { return }
    Sync-PilotSessionFromUi
    if (-not $script:Session.BasePrompt -and -not $script:Session.FinalPrompt -and -not $script:Session.Answer) { return }
    $path = Join-Path $script:SessionsDirectory ($script:Session.Id + '.json')
    Save-PilotSession $path $script:Session
    $script:Preferences.LastSessionId = $script:Session.Id
    if (-not $script:SettingsReadError) { Save-PilotUiPreferences }
    $script:Dirty = $false
    $script:Controls.SessionTitleTextBlock.Text = $script:Session.Title
    $script:Controls.SaveStateTextBlock.Text = 'Saved locally at ' + (Get-Date -Format 'HH:mm:ss')
}

function Update-PilotComparison {
    if (-not $script:Controls.FinalPromptTextBox.Text) { return }
    $original = $script:Controls.PromptTextBox.Text
    if ($script:Controls.RevisionListBox.SelectedItem) { $original = $script:Controls.RevisionListBox.SelectedItem.OriginalPrompt }
    $document = [Windows.Documents.FlowDocument]::new()
    $document.FontFamily = [Windows.Media.FontFamily]::new('Consolas')
    $document.FontSize = 12
    $document.PagePadding = [Windows.Thickness]::new(8)
    foreach ($line in @(Compare-PilotText $original $script:Controls.FinalPromptTextBox.Text)) {
        $prefix = switch ($line.Kind) { 'Added' { '+ ' } 'Removed' { '- ' } default { '  ' } }
        $paragraph = [Windows.Documents.Paragraph]::new([Windows.Documents.Run]::new($prefix + $line.Text))
        $paragraph.Margin = [Windows.Thickness]::new(0)
        if ($line.Kind -eq 'Added') { $paragraph.Background = [Windows.Media.Brushes]::Honeydew; $paragraph.Foreground = [Windows.Media.Brushes]::DarkGreen }
        if ($line.Kind -eq 'Removed') { $paragraph.Background = [Windows.Media.Brushes]::MistyRose; $paragraph.Foreground = [Windows.Media.Brushes]::DarkRed }
        $null = $document.Blocks.Add($paragraph)
    }
    $script:Controls.DiffTextBox.Document = $document
}

function Update-PilotHistory {
    $script:Controls.RevisionListBox.Items.Clear()
    foreach ($revision in @($script:Session.Revisions)) {
        $null = $script:Controls.RevisionListBox.Items.Add([pscustomobject]@{ Label = ('Revision {0} | {1} | {2}' -f $revision.Number, $revision.Model, $revision.AtUtc); Text = $revision.Text; OriginalPrompt = (Get-PilotValue $revision 'OriginalPrompt' $script:Session.BasePrompt) })
    }
}

function Update-PilotAttachmentPreview {
    $c = $script:Controls
    if (-not $c.IncludeFileCheckBox.IsChecked) {
        $c.FilePreviewTextBox.Visibility = 'Collapsed'
        $c.FileSummaryTextBlock.Text = if ($c.FilePathTextBox.Text) { 'File selected. Its contents will not be sent until inclusion is checked.' } else { 'Choose a supported text file up to 256 KB, then check inclusion to preview its contents.' }
        return
    }
    try {
        $file = Read-PilotAttachment $c.FilePathTextBox.Text
        $c.FilePreviewTextBox.Text = $file.Text
        $c.FilePreviewTextBox.Visibility = 'Visible'
        $c.FileSummaryTextBlock.Text = '{0}: including {1:N0} of {2:N0} characters{3}.' -f $file.Name, $file.IncludedCharacters, $file.OriginalCharacters, $(if ($file.Truncated) { ' (excerpt truncated to 20,000 characters)' } else { '' })
    }
    catch { $c.IncludeFileCheckBox.IsChecked = $false; Set-PilotFeedback $_.Exception.Message -ErrorState }
}

function Load-PilotUiSession {
    param([hashtable]$Session)
    $script:LoadingSession = $true
    try {
        $script:Session = ConvertTo-PilotSession $Session
        $c = $script:Controls
        $c.PromptTextBox.Text = $script:Session.BasePrompt
        $c.GoalsTextBox.Text = $script:Session.Goals
        $c.ProjectContextTextBox.Text = $script:Session.ProjectContext
        $c.FilePathTextBox.Text = $script:Session.FilePath
        $c.IncludeFileCheckBox.IsChecked = $script:Session.IncludeFile
        $c.FinalPromptTextBox.Text = $script:Session.FinalPrompt
        $c.TaskOutputTextBox.Text = $script:Session.Answer
        $c.ProfileComboBox.SelectedItem = $script:Session.Profile
        $c.IterationsTextBox.Text = [string]$script:Session.Iterations
        $c.MaxOutputTextBox.Text = [string]$script:Session.MaxOutputTokens
        $c.BudgetTextBox.Text = $script:Session.BudgetUsd.ToString('0.00######', [Globalization.CultureInfo]::InvariantCulture)
        $c.AnswerSourceComboBox.SelectedIndex = if ($script:Session.AnswerSource -eq 'Draft') { 0 } else { 1 }
        $c.SessionTitleTextBlock.Text = $script:Session.Title
        Set-PilotUiMode $script:Session.Mode
        Update-PilotProviderUi
        Update-PilotHistory
        Update-PilotComparison
        Update-PilotAttachmentPreview
        $c.OutputTabs.SelectedItem = if ($script:Session.Mode -eq 'Answer' -and $script:Session.Answer) { $c.AnswerTab } else { $c.DraftTab }
        $c.UsageTextBlock.Text = if ((Get-PilotValue $script:Session.Usage 'Requests' 0) -gt 0) { Format-PilotUsage $script:Session.Usage } else { 'No requests yet' }
        $script:Dirty = $false
    }
    finally { $script:LoadingSession = $false }
}

function Start-PilotBackground {
    param([string]$Mode, [hashtable]$Options, $Provider, [string]$ApiKey, [string]$Target = 'Main')
    if ($script:Operation) { throw 'A request is already running. Cancel it or wait for completion.' }
    $events = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    $cancellation = [Threading.CancellationTokenSource]::new()
    $worker = [Management.Automation.PowerShell]::Create()
    $null = $worker.AddScript({
        param($CorePath, $Mode, $Options, $Provider, $Key, $Events, $Token)
        . $CorePath
        if ($Mode -eq 'Discover') { Update-PilotCatalog $Provider $Key $Options.DataDirectory $Events $Token }
        elseif ($Mode -eq 'Evaluate') { Invoke-PilotModelEvaluation $Provider $Key $Options $Events $Token }
        else { Invoke-PilotWorkflow -Mode $Mode -Options $Options -Provider $Provider -ApiKey $Key -Events $Events -CancellationToken $Token }
    }).AddArgument((Join-Path $script:AppDirectory 'PromptPilot.Core.ps1')).AddArgument($Mode).AddArgument($Options).AddArgument($Provider).AddArgument($ApiKey).AddArgument($events).AddArgument($cancellation.Token)
    try {
        $handle = $worker.BeginInvoke()
        $script:Operation = @{ Worker = $worker; Handle = $handle; Events = $events; Cancellation = $cancellation; Mode = $Mode; Target = $Target; KeepDraft = $false; Options = $Options }
        if ($Target -eq 'Catalog') { $script:Controls.CancelButton.IsEnabled = $true } else { Set-PilotBusy $true }
        if ($Target -eq 'Settings') { Set-PilotSettingsBusy $true }
        if ($Target -in @('Models','Catalog')) { Set-PilotModelBusy $true }
    }
    catch { $worker.Dispose(); $cancellation.Dispose(); throw }
}

function Receive-PilotEvents {
    if (-not $script:Operation) { return }
    $eventItem = $null
    while ($script:Operation.Events.TryDequeue([ref]$eventItem)) {
        if ($eventItem.Kind -eq 'Log') { Write-PilotLog $eventItem.Message }
        elseif ($eventItem.Kind -eq 'Progress') {
            if ($script:Operation.Target -in @('Models','Catalog') -and $script:ModelContext) { $script:ModelContext.Status.Text = $eventItem.Message }
            elseif ($script:Operation.Target -eq 'Settings' -and $script:SettingsContext) { $script:SettingsContext.Status.Text = $eventItem.Message }
            else { Set-PilotFeedback $eventItem.Message }
        }
        elseif ($eventItem.Kind -eq 'Revision' -and $script:Operation.Target -eq 'Main') {
            $revision = ConvertTo-PilotMap $eventItem.Data
            $revision.Number = $script:Session.Revisions.Count + 1
            $script:Session.Revisions += $revision
            $script:Controls.FinalPromptTextBox.Text = $revision.Text
            $script:Controls.AcceptIterationButton.IsEnabled = $true
            Update-PilotHistory
            Update-PilotComparison
            Mark-PilotDirty
            try { Save-PilotAutosave } catch { Set-PilotFeedback ('Revision ready, but autosave failed: ' + $_.Exception.Message) -ErrorState }
        }
    }
}

function Format-PilotUsage {
    param($Usage)
    $cost = if ($null -ne (Get-PilotValue $Usage 'CostUsd')) { '${0:F5} estimated cost' -f $Usage.CostUsd } else { 'Cost unknown (usage unavailable)' }
    $inputCount = Get-PilotValue $Usage 'InputTokens'
    $outputCount = Get-PilotValue $Usage 'OutputTokens'
    if ($null -eq $inputCount -or $null -eq $outputCount) { return 'Token usage incomplete | ' + $cost }
    return '{0:N0} input / {1:N0} output tokens | {2}' -f $inputCount, $outputCount, $cost
}

function Complete-PilotBackground {
    if (-not $script:Operation -or -not $script:Operation.Handle.IsCompleted) { return }
    $operation = $script:Operation
    try {
        Receive-PilotEvents
        $results = @($operation.Worker.EndInvoke($operation.Handle))
        if (-not $results.Count) { throw 'The provider worker ended without a result.' }
        $result = ConvertTo-PilotMap $results[-1]
        if ($operation.Target -in @('Models','Catalog')) { Complete-PilotModelOperation $operation $result }
        elseif ($operation.Target -eq 'Settings') { Complete-PilotSettingsOperation $operation $result }
        else {
            $script:Session.Usage = $result.Usage
            $script:Controls.UsageTextBlock.Text = Format-PilotUsage $result.Usage
            if ($operation.Mode -eq 'Answer' -and $result.OutputText) { $script:Controls.TaskOutputTextBox.Text = $result.OutputText; $script:Controls.OutputTabs.SelectedItem = $script:Controls.AnswerTab }
            if ($operation.Mode -eq 'Refine' -and $result.OutputText) { $script:Controls.FinalPromptTextBox.Text = $result.OutputText; $script:Controls.OutputTabs.SelectedItem = $script:Controls.DraftTab }
            Mark-PilotDirty
            try { Save-PilotAutosave } catch { Write-PilotLog ('Autosave failed: ' + $_.Exception.Message) }
            if ($result.Status -eq 'Completed') { Set-PilotFeedback $(if ($operation.Mode -eq 'Refine') { 'Draft ready. Compare the changes, edit if needed, then copy it or use it to get an answer.' } else { 'Answer ready. Copy it or export this session.' }) }
            elseif ($result.Status -eq 'Cancelled') { Set-PilotFeedback $(if ($operation.KeepDraft) { 'Latest completed draft kept. Review it before continuing.' } else { 'Cancelled. Completed drafts and previous answers were kept.' }) }
            else { Set-PilotFeedback $result.Error -ErrorState }
            Write-PilotLog ('{0} ended: {1}. {2}' -f $operation.Mode, $result.Status, (Format-PilotUsage $result.Usage))
        }
    }
    catch { Set-PilotFeedback ('Request failed: ' + $_.Exception.Message) -ErrorState }
    finally {
        $operation.Worker.Dispose(); $operation.Cancellation.Dispose()
        $script:Operation = $null
        Set-PilotBusy $false
        if ($script:SettingsContext) { Set-PilotSettingsBusy $false }
        Set-PilotModelBusy $false
        if ($script:PendingRunAfterDiscovery) { $script:PendingRunAfterDiscovery = $false; if (-not $script:Closing) { Invoke-PilotUiAction { Start-PilotUiRun } } }
    }
}

function Stop-PilotBackground {
    param([switch]$KeepDraft)
    if (-not $script:Operation) { return }
    $script:Operation.KeepDraft = $KeepDraft.IsPresent
    $script:Operation.Cancellation.Cancel()
    Set-PilotFeedback 'Cancelling the active request...'
    Write-PilotLog 'Cancellation requested by user.'
}

function Start-PilotUiRun {
    if ($script:Operation -and $script:Operation.Target -eq 'Catalog') { $script:PendingRunAfterDiscovery = $true; $script:Operation.Cancellation.Cancel(); Set-PilotFeedback 'Preparing your request; stopping the background model check...'; return }
    Sync-PilotSessionFromUi -ValidateRunLimits
    if ($script:Session.Mode -eq 'Refine' -and ($script:Session.Revisions.Count + $script:Session.Iterations) -gt 100) { throw 'This session would exceed 100 revisions. Export it and start a new session before refining again.' }
    $provider = (Get-PilotProviders)[$script:Session.ProviderName]
    $key = Get-PilotUiCredential $provider.Name
    $pricing = Get-PilotPricing $provider.Name $script:Session.Model $script:Preferences.PricingOverrides
    if (-not $pricing.Known) { throw 'Set model-specific prices in provider settings before running. Unknown prices cannot enforce a run budget.' }
    $prompt = $script:Session.BasePrompt
    if ($script:Session.Mode -eq 'Answer' -and $script:Session.AnswerSource -eq 'Draft') {
        $prompt = $script:Session.FinalPrompt
        if (-not $prompt) { throw 'Refine a prompt first, or choose Original request as the answer input.' }
    }
    if ([string]::IsNullOrWhiteSpace($prompt)) { throw 'Write a request before running.' }
    if ($script:Session.IncludeFile) { Update-PilotAttachmentPreview; if (-not $script:Controls.IncludeFileCheckBox.IsChecked) { throw 'Review the selected reference file before continuing.' } }
    $options = @{ Prompt = $prompt; Context = $script:Session.ProjectContext; Goals = $script:Session.Goals; Model = $script:Session.Model; Iterations = $script:Session.Iterations; MaxOutputTokens = $script:Session.MaxOutputTokens; BudgetUsd = $script:Session.BudgetUsd; Profile = $script:Session.Profile; FilePath = $script:Session.FilePath; IncludeFile = $script:Session.IncludeFile; Pricing = $pricing }
    Save-PilotAutosave
    Start-PilotBackground $script:Session.Mode $options $provider $key
    Set-PilotFeedback ('Running {0} with {1}. You can cancel the active request.' -f $script:Session.Mode.ToLowerInvariant(), $provider.DisplayName)
}

function Save-PilotSessionAs {
    Sync-PilotSessionFromUi
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Title = 'Save Prompt Pilot session'
    $dialog.Filter = 'Prompt Pilot session (*.json)|*.json'
    $dialog.FileName = 'prompt-pilot-session.json'
    if ($dialog.ShowDialog($script:Window)) { Save-PilotSession $dialog.FileName $script:Session; $script:Dirty = $false; Set-PilotFeedback 'Session saved. It includes your prompts and results, without API keys.'; return $true }
    return $false
}

function Confirm-PilotSessionChange {
    if ($script:Preferences.Autosave) { Save-PilotAutosave; return $true }
    if (-not $script:Dirty) { return $true }
    $choice = [Windows.MessageBox]::Show($script:Window, 'Save this session before starting or opening another?', 'Unsaved session', [Windows.MessageBoxButton]::YesNoCancel, [Windows.MessageBoxImage]::Question)
    if ($choice -eq 'Cancel') { return $false }
    if ($choice -eq 'Yes') { return Save-PilotSessionAs }
    return $true
}

function New-PilotUiSession {
    if (-not (Confirm-PilotSessionChange)) { return }
    $provider = $script:Session.ProviderName
    Load-PilotUiSession (New-PilotSessionFromDefaults $script:Preferences $provider)
    $script:Controls.UsageTextBlock.Text = 'No requests yet'
    Set-PilotFeedback 'Write a request or choose an example to get started.'
}

function Open-PilotUiSession {
    if (-not (Confirm-PilotSessionChange)) { return }
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = 'Open saved session'
    $dialog.Filter = 'Prompt Pilot sessions and legacy presets (*.json)|*.json'
    if (Test-Path -LiteralPath $script:SessionsDirectory) { $dialog.InitialDirectory = $script:SessionsDirectory }
    if ($dialog.ShowDialog($script:Window)) {
        $raw = Read-PilotJson $dialog.FileName
        if (Get-PilotValue $raw 'SchemaVersion') { $session = Read-PilotSession $dialog.FileName }
        else {
            $session = New-PilotSession $script:Session.ProviderName $script:Session.Model
            $session.Model = Resolve-PilotModel $session.ProviderName ([string](Get-PilotValue $raw 'Model' $session.Model))
            $session.RefinementModel = $session.Model; $session.AnswerModel = $session.Model
            $session.Goals = [string](Get-PilotValue $raw 'Goals' (Get-PilotValue $raw 'RefinementGoals' $session.Goals))
            $session.ProjectContext = [string](Get-PilotValue $raw 'ProjectContext' '')
            $session.Iterations = [int](Get-PilotValue $raw 'Iterations' 2)
            if (-not (Get-PilotValue $raw 'Model') -and -not (Get-PilotValue $raw 'Goals')) { throw 'This is not a Prompt Pilot session or supported legacy preset.' }
        }
        Load-PilotUiSession $session
        Mark-PilotDirty
        Save-PilotAutosave
        Set-PilotFeedback 'Session opened. Review the provider and reference file before running.'
    }
}

function Export-PilotUiSession {
    Sync-PilotSessionFromUi
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Title = 'Export session as Markdown'
    $dialog.Filter = 'Markdown (*.md)|*.md'
    $dialog.FileName = 'prompt-pilot-session.md'
    if ($dialog.ShowDialog($script:Window)) { [IO.File]::WriteAllText($dialog.FileName, (Export-PilotMarkdown $script:Session), [Text.UTF8Encoding]::new($false)); Set-PilotFeedback 'Markdown exported with the original request, revisions and answer.' }
}

function Set-PilotSettingsBusy {
    param([bool]$Busy)
    if (-not $script:SettingsContext) { return }
    $s = $script:SettingsContext
    foreach ($control in @($s.Role, $s.Pinned, $s.Provider, $s.Model, $s.Key, $s.Remember, $s.Custom, $s.Save, $s.Refresh, $s.Test, $s.Forget)) { $control.IsEnabled = -not $Busy }
    $s.Input.IsEnabled = (-not $Busy -and $s.Custom.IsChecked)
    $s.Output.IsEnabled = (-not $Busy -and $s.Custom.IsChecked)
    $s.Cancel.IsEnabled = $Busy
}

function Update-PilotSettingsPricing {
    if (-not $script:SettingsContext) { return }
    $s = $script:SettingsContext
    try {
        $pricing = Get-PilotPricing ([string]$s.Provider.SelectedItem.Key) $s.Model.Text $script:Preferences.PricingOverrides
        $s.Custom.IsChecked = $pricing.IsCustom
        $s.Input.Text = if ($pricing.Known) { $pricing.InputPerMillion.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture) } else { '' }
        $s.Output.Text = if ($pricing.Known) { $pricing.OutputPerMillion.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture) } else { '' }
        $s.PriceInfo.Text = $pricing.Source + ' | Checked: ' + $pricing.CheckedOn
        Set-PilotSettingsBusy ([bool]$script:Operation)
    }
    catch { $s.PriceInfo.Text = $_.Exception.Message }
}

function Get-PilotSettingsRates {
    $s = $script:SettingsContext
    $name = [string]$s.Provider.SelectedItem.Key
    $model = Resolve-PilotModel $name $s.Model.Text
    $overrides = $script:Preferences.PricingOverrides.Clone()
    if ($s.Custom.IsChecked) {
        $inputRate = 0.0; $outputRate = 0.0
        if (-not [double]::TryParse($s.Input.Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$inputRate) -or -not [double]::TryParse($s.Output.Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$outputRate)) { throw 'Enter custom input and output prices in USD per one million tokens.' }
        $overrides["$name/$model"] = @{ InputPerMillion = $inputRate; OutputPerMillion = $outputRate; CheckedOn = (Get-Date -Format 'yyyy-MM-dd') }
    }
    else { $overrides.Remove("$name/$model") }
    return @{ Pricing = Get-PilotPricing $name $model $overrides; Overrides = $overrides; Model = $model; ProviderName = $name }
}

function Complete-PilotSettingsOperation {
    param($Operation, $Result)
    if (-not $script:SettingsContext) { return }
    $s = $script:SettingsContext
    if ($Result.Status -eq 'Completed') {
        if ($Operation.Mode -eq 'Models') {
            $selected = $s.Model.Text
            $s.Model.Items.Clear()
            foreach ($model in @($Result.Models)) { $null = $s.Model.Items.Add([string]$model.Id) }
            $s.Model.Text = $selected
            $s.Status.Text = '{0} model IDs loaded. Choose a text-chat model; listing alone does not test generation.' -f @($Result.Models).Count
        }
        else { $s.Status.Text = 'Test passed: the selected model returned PROMPT_PILOT_OK. ' + (Format-PilotUsage $Result.Usage) }
        $s.Status.Foreground = [Windows.Media.Brushes]::DarkGreen
    }
    else {
        $s.Status.Text = $Result.Error
        $s.Status.Foreground = [Windows.Media.Brushes]::Firebrick
    }
}

function Show-PilotSettings {
    if ($script:Operation) { Set-PilotFeedback 'Finish or cancel the running request before changing providers.'; return }
    [xml]$markup = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Prompt Pilot - Providers and API keys" Width="610" Height="700" MinHeight="650" WindowStartupLocation="CenterOwner" ResizeMode="CanResize" Background="#F4F6FB" FontFamily="Segoe UI" FontSize="13">
 <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="22">
  <TextBlock Text="Connect your model provider" FontSize="21" FontWeight="SemiBold" Foreground="#172554" Margin="0,0,0,5" />
  <TextBlock Text="Your keys stay on this PC. A provider API account is separate from a chat subscription." TextWrapping="Wrap" Foreground="#64748B" Margin="0,0,0,16" />
  <TextBlock Text="Model choice for" /><ComboBox Name="RoleComboBox" Padding="6" Margin="0,5,0,8" /><CheckBox Name="PinModelCheckBox" Content="Pin this default until I change it" IsChecked="True" Margin="0,0,0,12" />
  <TextBlock Text="Provider" /><ComboBox Name="ProviderComboBox" DisplayMemberPath="Title" Padding="6" Margin="0,5,0,12" />
  <TextBlock Text="Model ID" /><Grid Margin="0,5,0,5"><Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
   <ComboBox Name="ModelComboBox" IsEditable="True" Padding="6" /><Button Name="RefreshModelsButton" Grid.Column="1" Content="Load models" Padding="12,6" Margin="8,0,0,0" />
  </Grid>
  <TextBlock Name="CredentialStatusTextBlock" TextWrapping="Wrap" Foreground="#64748B" Margin="0,0,0,12" />
  <TextBlock Text="API key / GitHub Models token (blank keeps the current key)" /><PasswordBox Name="KeyBox" Padding="7" Margin="0,5,0,6" />
  <CheckBox Name="RememberKeyCheckBox" Content="Save a new key for this Windows user (encrypted)" IsChecked="True" Margin="0,0,0,10" />
  <Button Name="ForgetKeyButton" Content="Forget this provider's stored/session key" HorizontalAlignment="Left" Padding="10,5" Margin="0,0,0,16" />
  <CheckBox Name="CustomPricingCheckBox" Content="Use custom token prices (USD per 1 million tokens)" Margin="0,0,0,7" />
  <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
   <StackPanel Margin="0,0,10,0"><TextBlock Text="Input price" /><TextBox Name="InputPriceBox" Padding="7" Margin="0,4,0,0" /></StackPanel>
   <StackPanel Grid.Column="1"><TextBlock Text="Output price" /><TextBox Name="OutputPriceBox" Padding="7" Margin="0,4,0,0" /></StackPanel>
  </Grid>
  <TextBlock Name="PricingInfoTextBlock" TextWrapping="Wrap" Foreground="#64748B" FontSize="11" Margin="0,6,0,16" />
  <StackPanel Orientation="Horizontal"><Button Name="TestRequestButton" Content="Test a short request" Padding="12,7" /><Button Name="CancelRequestButton" Content="Cancel test" Padding="12,7" Margin="8,0,0,0" IsEnabled="False" /></StackPanel>
  <TextBlock Text="The test sends a short generation request using API credits, capped at 1,024 output tokens and a $0.10 run budget. Model listing sends no prompt." TextWrapping="Wrap" Foreground="#64748B" FontSize="11" Margin="0,6,0,8" />
  <TextBlock Name="StatusTextBlock" TextWrapping="Wrap" MinHeight="52" Margin="0,0,0,12" />
  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button Name="SaveButton" Content="Save and use provider" Padding="14,8" Margin="0,0,8,0" /><Button Name="CloseButton" Content="Close" Padding="14,8" /></StackPanel>
 </StackPanel></ScrollViewer>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
    $dialog.Owner = $script:Window
    $script:SettingsContext = @{ Dialog = $dialog; Provider = $dialog.FindName('ProviderComboBox'); Role = $dialog.FindName('RoleComboBox'); Pinned = $dialog.FindName('PinModelCheckBox'); Model = $dialog.FindName('ModelComboBox'); Key = $dialog.FindName('KeyBox'); Remember = $dialog.FindName('RememberKeyCheckBox'); Forget = $dialog.FindName('ForgetKeyButton'); Custom = $dialog.FindName('CustomPricingCheckBox'); Input = $dialog.FindName('InputPriceBox'); Output = $dialog.FindName('OutputPriceBox'); PriceInfo = $dialog.FindName('PricingInfoTextBlock'); Status = $dialog.FindName('StatusTextBlock'); CredentialStatus = $dialog.FindName('CredentialStatusTextBlock'); Refresh = $dialog.FindName('RefreshModelsButton'); Test = $dialog.FindName('TestRequestButton'); Cancel = $dialog.FindName('CancelRequestButton'); Save = $dialog.FindName('SaveButton'); Close = $dialog.FindName('CloseButton') }
    $s = $script:SettingsContext
    foreach ($role in @('Refine','Answer')) { $null = $s.Role.Items.Add($role) }; $s.Role.SelectedItem = $script:Session.Mode
    $s.Role.Add_SelectionChanged({ if ($script:SettingsContext -and $script:SettingsContext.Provider.SelectedItem) { $s = $script:SettingsContext; $name = [string]$s.Provider.SelectedItem.Key; $s.Model.Text = Get-PilotRoleModel $script:Preferences $name ([string]$s.Role.SelectedItem); $s.Pinned.IsChecked = $script:Preferences.Providers[$name].Pins[[string]$s.Role.SelectedItem]; Update-PilotSettingsPricing } })
    foreach ($provider in (Get-PilotProviders).Values) { $null = $s.Provider.Items.Add([pscustomobject]@{ Key = $provider.Name; Title = $provider.DisplayName }) }
    $s.Provider.Add_SelectionChanged({
        $s = $script:SettingsContext
        if (-not $s -or -not $s.Provider.SelectedItem) { return }
        $name = [string]$s.Provider.SelectedItem.Key
        $s.Model.Items.Clear(); $s.Model.Text = Get-PilotRoleModel $script:Preferences $name ([string]$s.Role.SelectedItem); $s.Pinned.IsChecked = $script:Preferences.Providers[$name].Pins[[string]$s.Role.SelectedItem]; $s.Key.Clear()
        try { $source = (Get-PilotCredential $name $script:Preferences $script:SessionKeys).Source } catch { $source = 'saved key unavailable; enter a replacement' }
        $s.CredentialStatus.Text = 'Credential: ' + $source + $(if ($name -eq 'GitHubModels') { '. Use a GitHub Models token with Models access; Copilot subscriptions do not supply this API.' } else { '' })
        Update-PilotSettingsPricing
    })
    foreach ($item in $s.Provider.Items) { if ($item.Key -eq $script:Session.ProviderName) { $s.Provider.SelectedItem = $item; break } }
    $s.Model.Add_SelectionChanged({ if ($script:SettingsContext -and $script:SettingsContext.Model.SelectedItem) { $script:SettingsContext.Model.Text = [string]$script:SettingsContext.Model.SelectedItem; Update-PilotSettingsPricing } })
    $s.Model.Add_LostKeyboardFocus({ Update-PilotSettingsPricing })
    $s.Custom.Add_Checked({ if ($script:SettingsContext) { $script:SettingsContext.Input.IsEnabled = $true; $script:SettingsContext.Output.IsEnabled = $true } })
    $s.Custom.Add_Unchecked({ if ($script:SettingsContext) { $script:SettingsContext.Input.IsEnabled = $false; $script:SettingsContext.Output.IsEnabled = $false } })
    $s.Refresh.Add_Click({
        try {
            $s = $script:SettingsContext; $name = [string]$s.Provider.SelectedItem.Key
            $key = Get-PilotUiCredential $name $s.Key.Password
            Start-PilotBackground Models @{} (Get-PilotProviders)[$name] $key Settings
            $s.Status.Text = 'Loading available model IDs...'
        }
        catch { $script:SettingsContext.Status.Text = $_.Exception.Message }
    })
    $s.Test.Add_Click({
        try {
            $s = $script:SettingsContext; $rates = Get-PilotSettingsRates
            if (-not $rates.Pricing.Known) { throw 'Set explicit custom prices before running a test with this model.' }
            $key = Get-PilotUiCredential $rates.ProviderName $s.Key.Password
            $options = @{ Model = $rates.Model; Pricing = $rates.Pricing; BudgetUsd = 0.10; MaxOutputTokens = 1024; Iterations = 1 }
            Start-PilotBackground Test $options (Get-PilotProviders)[$rates.ProviderName] $key Settings
            $s.Status.Text = 'Testing a real generation request...'
        }
        catch { $script:SettingsContext.Status.Text = $_.Exception.Message }
    })
    $s.Cancel.Add_Click({ Stop-PilotBackground })
    $s.Forget.Add_Click({
        try {
            $s = $script:SettingsContext; $name = [string]$s.Provider.SelectedItem.Key
            $script:Preferences.Keys.Remove($name); $script:SessionKeys.Remove($name); $s.Key.Clear()
            Save-PilotUiPreferences
            $s.Status.Text = 'Stored and session keys removed. Any provider environment variable remains available.'
            Update-PilotProviderUi
        }
        catch { $script:SettingsContext.Status.Text = $_.Exception.Message }
    })
    $s.Save.Add_Click({
        try {
            $s = $script:SettingsContext; $rates = Get-PilotSettingsRates
            $script:Preferences.PricingOverrides = $rates.Overrides
            Set-PilotRoleModel $script:Preferences $rates.ProviderName ([string]$s.Role.SelectedItem) $rates.Model ($s.Pinned.IsChecked -eq $true)
            $script:Preferences.ActiveProvider = $rates.ProviderName
            if ($s.Key.Password) {
                if ($s.Remember.IsChecked) { $script:Preferences.Keys[$rates.ProviderName] = Protect-PilotSecret $s.Key.Password; $script:SessionKeys.Remove($rates.ProviderName) }
                else { $script:SessionKeys[$rates.ProviderName] = $s.Key.Password }
                if ($s.Key.Password -notin $script:KnownSecrets) { $script:KnownSecrets += $s.Key.Password }
            }
            Save-PilotUiPreferences
            $script:Session.ProviderName = $rates.ProviderName
            $script:Session.RefinementModel = Get-PilotRoleModel $script:Preferences $rates.ProviderName Refine
            $script:Session.AnswerModel = Get-PilotRoleModel $script:Preferences $rates.ProviderName Answer
            $script:Session.Model = if ($script:Session.Mode -eq 'Refine') { $script:Session.RefinementModel } else { $script:Session.AnswerModel }
            Update-PilotProviderUi; Mark-PilotDirty
            $s.Dialog.Close()
            Set-PilotFeedback 'Provider saved. Write your request, then refine or get an answer.'
        }
        catch { $script:SettingsContext.Status.Text = $_.Exception.Message }
    })
    $s.Close.Add_Click({ $script:SettingsContext.Dialog.Close() })
    $dialog.Add_Closing({ if ($script:Operation -and $script:Operation.Target -eq 'Settings') { Stop-PilotBackground } })
    $null = $dialog.ShowDialog()
    $script:SettingsContext = $null
}

function Confirm-PilotDiscardAfterSaveFailure {
    param([string]$Message)
    $detail = Protect-PilotText $Message $script:KnownSecrets
    return ([Windows.MessageBox]::Show($script:Window, ($detail + "`n`nClose without saving the latest changes? Choose No to keep the window open and save or export to another location."), 'Unsaved changes', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning, [Windows.MessageBoxResult]::No) -eq 'Yes')
}

function Invoke-PilotUiAction {
    param([scriptblock]$Action)
    try { & $Action } catch { Set-PilotFeedback $_.Exception.Message -ErrorState }
}

. (Join-Path $script:AppDirectory 'PromptPilot.ModelWindow.ps1')

Initialize-PilotLogging
try {
    if (-not $SmokeTest) {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $instanceId = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:DataDirectory.ToLowerInvariant())))).Replace('-', '').Substring(0, 24) } finally { $hash.Dispose() }
        $created = $false
        $script:Mutex = [Threading.Mutex]::new($true, ('Local\PromptPilot-' + $instanceId), [ref]$created)
        $script:OwnsMutex = $created
        if (-not $created) {
            [IO.File]::WriteAllText((Join-Path $script:DataDirectory 'activate.request'), '')
            Write-PilotLog 'Another instance is active; activation requested.'
            return
        }
        Write-PilotJson $script:InstancePath @{ ProcessId = $PID; StartedAtUtc = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o'); AppDirectory = $script:AppDirectory }
    }
    try { $script:Preferences = Read-PilotPreferences $script:SettingsPath }
    catch { $script:SettingsReadError = $_.Exception.Message; $script:Preferences = New-PilotPreferences; Write-PilotLog $script:SettingsReadError }
    foreach ($providerName in (Get-PilotProviders).Keys) {
        try { $keyInfo = Get-PilotCredential $providerName $script:Preferences $script:SessionKeys; if ($keyInfo.Key) { $script:KnownSecrets += $keyInfo.Key } } catch { Write-PilotLog ('A saved credential could not be opened for ' + $providerName) }
    }
    [xml]$markup = Get-Content -LiteralPath (Join-Path $script:AppDirectory 'Prompt_Pilot.MainWindow.xaml') -Raw -Encoding UTF8
    $script:Window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
    foreach ($node in $markup.SelectNodes('//*[@Name and not(ancestor::*[local-name()="ControlTemplate"])]')) { $script:Controls[$node.Name] = $script:Window.FindName([string]$node.Name); if (-not $script:Controls[$node.Name]) { throw ('Missing UI control: ' + $node.Name) } }
    $script:Controls.VersionTextBlock.Text = 'Version ' + $script:Product.version
    $iconPath = Join-Path $script:AppDirectory 'assets/prompt-pilot.ico'
    if (Test-Path -LiteralPath $iconPath) { $script:Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) }
    foreach ($profile in @('Coding task', 'Investigation', 'General task')) { $null = $script:Controls.ProfileComboBox.Items.Add($profile) }
    foreach ($source in @('Selected refined prompt', 'Original request')) { $null = $script:Controls.AnswerSourceComboBox.Items.Add($source) }
    $script:Examples = @(
        @{ Title = 'Fix a bug'; Profile = 'Coding task'; Prompt = 'Fix the CSV parser so quoted commas work. Preserve blank rows. Do not add dependencies. Add focused regression tests.' },
        @{ Title = 'Investigate a failure'; Profile = 'Investigation'; Prompt = 'Investigate why the nightly import stopped yesterday. Start with recent changes and logs. Separate confirmed facts from hypotheses. Do not modify production data.' },
        @{ Title = 'Plan a focused change'; Profile = 'Coding task'; Prompt = 'Review the current repository and implement the next dependency-ready roadmap task. Preserve unrelated edits. Validate the change and report any remaining acceptance gaps.' },
        @{ Title = 'Write a clear brief'; Profile = 'General task'; Prompt = 'Turn my meeting notes into a concise project brief. Keep the stated scope, owners and dates. Flag missing decisions without inventing answers.' }
    )
    $script:Controls.ExampleComboBox.DisplayMemberPath = 'Title'
    foreach ($example in $script:Examples) { $null = $script:Controls.ExampleComboBox.Items.Add([pscustomobject]$example) }
    $active = $script:Preferences.ActiveProvider
    $session = New-PilotSessionFromDefaults $script:Preferences $active
    $restored = $false
    if ($script:Preferences.Autosave -and $script:Preferences.LastSessionId -cmatch '^[a-f0-9]{32}$') {
        $sessionPath = Join-Path $script:SessionsDirectory ($script:Preferences.LastSessionId + '.json')
        if (Test-Path -LiteralPath $sessionPath) { try { $session = Read-PilotSession $sessionPath; $restored = $true } catch { Write-PilotLog ('Saved session could not be restored: ' + $_.Exception.Message) } }
    }
    Load-PilotUiSession $session
    $script:Controls.AutosaveCheckBox.IsChecked = $script:Preferences.Autosave
    foreach ($name in @('PromptTextBox', 'GoalsTextBox', 'ProjectContextTextBox', 'FinalPromptTextBox', 'IterationsTextBox', 'MaxOutputTextBox', 'BudgetTextBox')) { $script:Controls[$name].Add_TextChanged({ Mark-PilotDirty }) }
    $script:Controls.ProfileComboBox.Add_SelectionChanged({ Mark-PilotDirty })
    $script:Controls.AnswerSourceComboBox.Add_SelectionChanged({ Mark-PilotDirty })
    $script:Controls.ModeRefineRadio.Add_Click({ Set-PilotUiMode Refine; Mark-PilotDirty })
    $script:Controls.ModeAnswerRadio.Add_Click({ Set-PilotUiMode Answer; Mark-PilotDirty })
    $script:Controls.RunButton.Add_Click({ Invoke-PilotUiAction { Start-PilotUiRun } })
    $script:Controls.CancelButton.Add_Click({ Stop-PilotBackground })
    $script:Controls.AcceptIterationButton.Add_Click({ Stop-PilotBackground -KeepDraft })
    $script:Controls.UsePromptButton.Add_Click({ Invoke-PilotUiAction { if (-not $script:Controls.FinalPromptTextBox.Text) { throw 'Create or write a draft first.' }; $script:Controls.AnswerSourceComboBox.SelectedIndex = 0; Set-PilotUiMode Answer; Start-PilotUiRun } })
    $script:Controls.CopyButton.Add_Click({ Invoke-PilotUiAction { if ($script:Controls.FinalPromptTextBox.Text) { [Windows.Clipboard]::SetText($script:Controls.FinalPromptTextBox.Text); Set-PilotFeedback 'Prompt copied.' } } })
    $script:Controls.CopyTaskOutputButton.Add_Click({ Invoke-PilotUiAction { if ($script:Controls.TaskOutputTextBox.Text) { [Windows.Clipboard]::SetText($script:Controls.TaskOutputTextBox.Text); Set-PilotFeedback 'Answer copied.' } } })
    $script:Controls.OutputTabs.Add_SelectionChanged({ if ($script:Controls.OutputTabs.SelectedItem -eq $script:Controls.CompareTab) { Update-PilotComparison } })
    $script:Controls.RevisionListBox.Add_SelectionChanged({ if ($script:Controls.RevisionListBox.SelectedItem -and -not $script:LoadingSession) { $script:Controls.FinalPromptTextBox.Text = $script:Controls.RevisionListBox.SelectedItem.Text; Update-PilotComparison; Mark-PilotDirty; $script:Controls.OutputTabs.SelectedItem = $script:Controls.DraftTab } })
    $script:Controls.ExampleComboBox.Add_SelectionChanged({ if ($script:Controls.ExampleComboBox.SelectedItem) { if ($script:Controls.PromptTextBox.Text) { Set-PilotFeedback 'Start a new session to load an example without replacing your request.' } else { $script:Controls.PromptTextBox.Text = $script:Controls.ExampleComboBox.SelectedItem.Prompt; $script:Controls.ProfileComboBox.SelectedItem = $script:Controls.ExampleComboBox.SelectedItem.Profile; Mark-PilotDirty } } })
    $script:Controls.BrowseButton.Add_Click({ Invoke-PilotUiAction { $dialog = [Microsoft.Win32.OpenFileDialog]::new(); $dialog.Filter = 'Text and source files|*.txt;*.md;*.ps1;*.psm1;*.json;*.csv;*.yaml;*.yml;*.xml;*.cs;*.py;*.js;*.ts;*.sql;*.html;*.css;*.log;*.toml;*.go;*.rs|All files|*.*'; if ($dialog.ShowDialog($script:Window)) { $null = Read-PilotAttachment $dialog.FileName; $script:Controls.FilePathTextBox.Text = $dialog.FileName; $script:Controls.IncludeFileCheckBox.IsChecked = $false; Update-PilotAttachmentPreview; Mark-PilotDirty } } })
    $script:Controls.IncludeFileCheckBox.Add_Checked({ Update-PilotAttachmentPreview; Mark-PilotDirty })
    $script:Controls.IncludeFileCheckBox.Add_Unchecked({ Update-PilotAttachmentPreview; Mark-PilotDirty })
    $script:Controls.AutosaveCheckBox.Add_Click({ Invoke-PilotUiAction { $script:Preferences.Autosave = ($script:Controls.AutosaveCheckBox.IsChecked -eq $true); Save-PilotUiPreferences; if ($script:Preferences.Autosave) { Save-PilotAutosave } else { $script:Controls.SaveStateTextBlock.Text = 'Autosave off. Use Save as to keep this session.' } } })
    foreach ($name in @('NewSessionButton', 'MenuNewSession')) { $script:Controls[$name].Add_Click({ Invoke-PilotUiAction { New-PilotUiSession } }) }
    foreach ($name in @('OpenSessionButton', 'MenuOpenSession')) { $script:Controls[$name].Add_Click({ Invoke-PilotUiAction { Open-PilotUiSession } }) }
    foreach ($name in @('SaveSessionButton', 'MenuSaveSession')) { $script:Controls[$name].Add_Click({ Invoke-PilotUiAction { $null = Save-PilotSessionAs } }) }
    foreach ($name in @('ExportButton', 'MenuExportSession')) { $script:Controls[$name].Add_Click({ Invoke-PilotUiAction { Export-PilotUiSession } }) }
    foreach ($name in @('ModelsButton', 'MenuModelManagement')) { $script:Controls[$name].Add_Click({ Invoke-PilotUiAction { Show-PilotModelManagement } }) }
    foreach ($name in @('ProviderButton', 'MenuSettingsApiKey')) { $script:Controls[$name].Add_Click({ Invoke-PilotUiAction { Show-PilotSettings } }) }
    foreach ($name in @('OpenLogsButton', 'MenuOpenLogs')) { $script:Controls[$name].Add_Click({ Invoke-PilotUiAction { $directory = if ($script:LogFilePath) { Split-Path -Parent $script:LogFilePath } else { $script:DataDirectory }; Start-Process explorer.exe -ArgumentList ('"' + $directory + '"') } }) }
    $script:Controls.ClearLogButton.Add_Click({ $script:Controls.LogTextBox.Clear(); Write-PilotLog 'Activity view cleared. Disk log retained.' })
    $script:Controls.MenuHelpAbout.Add_Click({ [Windows.MessageBox]::Show($script:Window, ("Prompt Pilot " + $script:Product.version + "`n`nRefine coding-agent instructions while preserving your intent.`n`nPrompts and answers are sent only to the provider you select. Included file text is shown in the preview. Sessions are stored locally when autosave is enabled. API keys saved on Windows use protection for your user account. There is no telemetry.`n`nCosts are estimates using the selected model's rates. Output limits include reasoning tokens. Set account spending limits with your provider as well.`n`nData: " + $script:DataDirectory + "`nLogs: " + $script:LogFilePath), 'About Prompt Pilot') | Out-Null })
    $script:Window.Add_PreviewKeyDown({ param($sender, $eventArgs) if (($eventArgs.KeyboardDevice.Modifiers -band [Windows.Input.ModifierKeys]::Control) -and -not $script:Operation) { switch ($eventArgs.Key) { N { Invoke-PilotUiAction { New-PilotUiSession }; $eventArgs.Handled = $true } O { Invoke-PilotUiAction { Open-PilotUiSession }; $eventArgs.Handled = $true } S { Invoke-PilotUiAction { $null = Save-PilotSessionAs }; $eventArgs.Handled = $true } } } })
    $script:Timer = [Windows.Threading.DispatcherTimer]::new()
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:Timer.Add_Tick({
        try {
            Receive-PilotEvents
            Complete-PilotBackground
            Invoke-PilotAutomaticModelCheck
            if ($script:Dirty -and $script:Preferences.Autosave -and ([DateTime]::UtcNow - $script:LastEditUtc).TotalSeconds -gt 1) { try { Save-PilotAutosave } catch { $script:LastEditUtc = [DateTime]::UtcNow.AddSeconds(10); Set-PilotFeedback ('Autosave needs attention: ' + $_.Exception.Message) -ErrorState } }
            if (-not $SmokeTest) {
                $activation = Join-Path $script:DataDirectory 'activate.request'
                if (Test-Path -LiteralPath $activation) { Remove-Item -LiteralPath $activation; $script:Window.WindowState = 'Normal'; $null = $script:Window.Activate() }
                $restartPath = Join-Path $script:DataDirectory 'restart.request'
                if (Test-Path -LiteralPath $restartPath) { $request = Read-PilotJson $restartPath; Remove-Item -LiteralPath $restartPath; if ([int]$request.ProcessId -eq $PID) { $script:Window.Close() } }
            }
        }
        catch { Set-PilotFeedback $_.Exception.Message -ErrorState }
    })
    $script:Timer.Start()
    $script:Window.Add_Closing({
        param($sender, $eventArgs)
        if ($script:Closing) { return }
        if (-not $SmokeTest -and -not $script:Preferences.Autosave -and $script:Dirty -and -not (Confirm-PilotSessionChange)) { $eventArgs.Cancel = $true; return }
        $script:Closing = $true
        if ($script:Operation) {
            $script:Operation.Cancellation.Cancel()
            if ($script:Operation.Handle.AsyncWaitHandle.WaitOne(1500)) { Complete-PilotBackground }
            else { Receive-PilotEvents; $script:Operation.Worker.Stop(); $script:Operation.Worker.Dispose(); $script:Operation.Cancellation.Dispose(); $script:Operation = $null }
        }
        try { Save-PilotAutosave }
        catch {
            $message = 'Final autosave failed: ' + $_.Exception.Message
            Write-PilotLog $message
            if ($SmokeTest) { throw }
            if (-not (Confirm-PilotDiscardAfterSaveFailure $message)) {
                $eventArgs.Cancel = $true
                $script:Closing = $false
                Set-PilotFeedback 'The window was kept open because the latest changes could not be saved. Save or export to another location before closing.' -ErrorState
                return
            }
        }
        $script:Timer.Stop()
        Write-PilotLog 'Session closing.'
    })
    Set-PilotBusy $false
    Write-PilotLog ('Ready. Provider={0}; model={1}' -f $script:Session.ProviderName, $script:Session.Model)
    foreach ($note in @($script:Preferences.MigrationNotes)) { Write-PilotLog $note }
    if ($script:SettingsReadError) { Set-PilotFeedback $script:SettingsReadError -ErrorState }
    elseif ($script:LogFailure) { Set-PilotFeedback $script:LogFailure -ErrorState }
    elseif ($restored) { Set-PilotFeedback 'Your last session was restored. Review the selected draft or continue refining.'; $script:Controls.SaveStateTextBlock.Text = 'Restored from local autosave.' }
    else { Set-PilotFeedback 'Write your request, choose a provider, then refine it or get an answer.' }
    if ($script:Session.IncludeFile -and -not $script:Controls.IncludeFileCheckBox.IsChecked) { Set-PilotFeedback 'The saved reference file could not be loaded. File inclusion is off. Choose the file again before using it.' -ErrorState }
    if ($SmokeTest) {
        $script:Window.Show()
        $script:Window.UpdateLayout()
        $script:Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
        $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$script:Window.Content.ActualWidth, [int]$script:Window.Content.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $visual = [Windows.Media.DrawingVisual]::new()
        $drawing = $visual.RenderOpen()
        $rectangle = [Windows.Rect]::new(0, 0, $script:Window.Content.ActualWidth, $script:Window.Content.ActualHeight)
        $drawing.DrawRectangle($script:Window.Background, $null, $rectangle)
        $drawing.DrawRectangle([Windows.Media.VisualBrush]::new($script:Window.Content), $null, $rectangle)
        $drawing.Close()
        $bitmap.Render($visual)
        $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
        $null = $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $imagePath = [IO.Path]::ChangeExtension([IO.Path]::GetFullPath($SmokeReportPath), '.png')
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($imagePath))
        $stream = [IO.File]::Create($imagePath)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        $report = @{ Version = $script:Product.version; Controls = $script:Controls.Count; Provider = $script:Session.ProviderName; Model = $script:Session.Model; Restored = $restored; PromptCharacters = $script:Session.BasePrompt.Length; Revisions = $script:Session.Revisions.Count; AnswerCharacters = $script:Session.Answer.Length; Logging = [bool]$script:LogFilePath; LogPath = $script:LogFilePath; Autosave = $script:Preferences.Autosave; Screenshot = $imagePath; Width = $script:Window.ActualWidth; Height = $script:Window.ActualHeight; Error = $script:SettingsReadError }
        Write-PilotJson $SmokeReportPath $report
        $script:Window.Close()
        return
    }
    $null = $script:Window.ShowDialog()
}
catch {
    Write-PilotLog ('Startup failed: ' + $_.Exception.Message)
    if ($SmokeTest -and $SmokeReportPath) { Write-PilotJson $SmokeReportPath @{ Error = Protect-PilotText $_.Exception.Message $script:KnownSecrets; Version = $script:Product.version } }
    if (-not $SmokeTest) { [Windows.MessageBox]::Show(('Prompt Pilot could not start: ' + (Protect-PilotText $_.Exception.Message $script:KnownSecrets) + "`n`nLog: " + $script:LogFilePath), 'Prompt Pilot startup error') | Out-Null }
    throw
}
finally {
    if ($script:OwnsMutex) { if (Test-Path -LiteralPath $script:InstancePath) { Remove-Item -LiteralPath $script:InstancePath -ErrorAction SilentlyContinue }; $script:Mutex.ReleaseMutex() }
    if ($script:Mutex) { $script:Mutex.Dispose() }
}
