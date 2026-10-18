BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'PromptPilot.Core.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:ScenarioRunner = Join-Path $script:RepoRoot 'tools/Invoke-DesktopScenario.ps1'
}

Describe 'Desktop source and artifact contract' {
    It 'parses the current application and shared core without errors' {
        foreach ($name in @('Prompt_Pilot.Wpf.ps1', 'PromptPilot.Core.ps1', 'tools/Invoke-DesktopScenario.ps1')) {
            $tokens = $null; $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $name), [ref]$tokens, [ref]$parseErrors)
            $parseErrors.Count | Should -Be 0 -Because $name
        }
    }
    It 'has one consistent release version and a documented pricing catalog' {
        $product = Read-PilotJson (Join-Path $script:RepoRoot 'data/product.json')
        $product.version | Should -Match '^\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$'
        $releaseVersion = [version]($product.version -split '-')[0]
        $fileVersion = [version]$product.fileVersion
        foreach ($component in @('Major','Minor','Build')) { $fileVersion.$component | Should -Be $releaseVersion.$component }
        $pricing = Read-PilotJson (Join-Path $script:RepoRoot 'data/pricing.json')
        $pricing.models.Count | Should -BeGreaterOrEqual 4
        foreach ($item in $pricing.models) { $item.source | Should -Match '^https://'; $item.input | Should -BeGreaterOrEqual 0; $item.output | Should -BeGreaterOrEqual 0 }
    }
}

Describe 'Native WPF product workflow' -Tag 'WindowsUI' {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    }
    It 'loads the entire window with unique control names and no template-local lookup collisions' {
        [xml]$markup = Get-Content (Join-Path $script:RepoRoot 'Prompt_Pilot.MainWindow.xaml') -Raw -Encoding UTF8
        $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
        try {
            $nodes = @($markup.SelectNodes('//*[@Name and not(ancestor::*[local-name()="ControlTemplate"])]'))
            $nodes.Count | Should -BeGreaterThan 50
            @($nodes.Name | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
            foreach ($node in $nodes) { $window.FindName($node.Name) | Should -Not -BeNullOrEmpty -Because $node.Name }
        }
        finally { $window.Close() }
    }
    It 'starts under a fresh profile with logs and can recover a full prior session on restart' {
        $dataDir = Join-Path $TestDrive 'restart-data'
        $null = [IO.Directory]::CreateDirectory($dataDir)
        $preferences = New-PilotPreferences
        $preferences.ActiveProvider = 'Anthropic'
        $preferences.Providers.Anthropic.Model = 'anthropic.claude-opus-5-5'
        $session = New-PilotSession Anthropic claude-opus-5-5
        $session.BasePrompt = 'Restore this original request'
        $session.FinalPrompt = 'Restore this refined prompt'
        $session.Answer = 'Restore this answer'
        $session.Revisions = @(@{ Number = 1; Text = 'Restore this refined prompt'; OriginalPrompt = $session.BasePrompt; Model = 'claude-opus-5-5'; AtUtc = [DateTime]::UtcNow.ToString('o') })
        Save-PilotSession (Join-Path $dataDir ('sessions/' + $session.Id + '.json')) $session
        $preferences.LastSessionId = $session.Id
        Save-PilotPreferences (Join-Path $dataDir 'settings.json') $preferences
        $report = Join-Path $TestDrive 'restart-smoke.json'
        & (Join-Path $script:RepoRoot 'Prompt_Pilot.Wpf.ps1') -DataDirectory $dataDir -SmokeTest -SmokeReportPath $report
        $result = Read-PilotJson $report
        $result.Error | Should -BeNullOrEmpty
        $result.Restored | Should -BeTrue
        $result.Model | Should -Be 'claude-opus-5-5'
        $result.PromptCharacters | Should -Be $session.BasePrompt.Length
        $result.AnswerCharacters | Should -Be $session.Answer.Length
        $result.Revisions | Should -Be 1
        $result.Logging | Should -BeTrue
        Test-Path $result.Screenshot | Should -BeTrue
    }
    It 'executes actual Refine and Use-prompt buttons without blocking, autosaves revisions and preserves the original' {
        $body = '{"content":[{"type":"text","text":"Refined request. Preserve blank rows. Do not add dependencies."}],"usage":{"input_tokens":30,"output_tokens":20},"stop_reason":"end_turn"}'
        $server = Start-PilotMockServer -Responses @(@{ Status = 200; Body = $body; DelayMs = 200 })
        $dataDir = Join-Path $TestDrive 'workflow-data'
        $null = [IO.Directory]::CreateDirectory($dataDir)
        $preferences = New-PilotPreferences; $preferences.ActiveProvider = 'Anthropic'; $preferences.Providers.Anthropic.Model = 'claude-opus-5-5'
        Save-PilotPreferences (Join-Path $dataDir 'settings.json') $preferences
        $scenario = @'
+$script:MockProviders = Get-PilotProviders
+$script:MockProviders.Anthropic.ApiBase = '__MOCK_BASE__'
+function Get-PilotProviders { return $script:MockProviders }
+$script:SessionKeys.Anthropic = 'test-key'
+$script:Controls.PromptTextBox.Text = 'Fix the CSV parser. Preserve blank rows. Do not add dependencies.'
+$script:Controls.IterationsTextBox.Text = '2'
+$before = [Diagnostics.Stopwatch]::StartNew()
+Invoke-PilotButton $script:Controls.RunButton
+$startMilliseconds = $before.ElapsedMilliseconds
+$busy = [bool]$script:Operation
+$cancelEnabled = $script:Controls.CancelButton.IsEnabled
+Wait-PilotDesktopIdle
+$revisions = $script:Session.Revisions.Count
+Update-PilotComparison
+$diffBlocks = $script:Controls.DiffTextBox.Document.Blocks.Count
+Invoke-PilotButton $script:Controls.UsePromptButton
+Wait-PilotDesktopIdle
+Save-PilotAutosave
+[pscustomobject]@{
+    StartMilliseconds = $startMilliseconds; BusyAfterClick = $busy; CancelEnabled = $cancelEnabled
+    Revisions = $revisions; DiffBlocks = $diffBlocks; FinalPrompt = $script:Controls.FinalPromptTextBox.Text
+    Answer = $script:Controls.TaskOutputTextBox.Text; Original = $script:Controls.PromptTextBox.Text
+    Idle = (-not $script:Operation); RunEnabled = $script:Controls.RunButton.IsEnabled
+    Path = (Join-Path $script:SessionsDirectory ($script:Session.Id + '.json'))
+    Feedback = $script:Controls.FeedbackTextBlock.Text
+}
'@ -replace '(?m)^\+', ''
        $scenario = $scenario.Replace('__MOCK_BASE__', $server.Base)
        $scenarioPath = Join-Path $TestDrive 'workflow.ps1'
        [IO.File]::WriteAllText($scenarioPath, $scenario)
        try {
            $result = & $script:ScenarioRunner -DataDirectory $dataDir -ScenarioPath $scenarioPath -SourceDirectory $script:RepoRoot
            $result.StartMilliseconds | Should -BeLessThan 2000
            $result.BusyAfterClick | Should -BeTrue
            $result.CancelEnabled | Should -BeTrue
            $result.Revisions | Should -Be 2
            $result.DiffBlocks | Should -BeGreaterThan 0
            $result.Answer | Should -Match 'Preserve blank rows'
            $result.Original | Should -Be 'Fix the CSV parser. Preserve blank rows. Do not add dependencies.'
            $result.Idle | Should -BeTrue
            $result.RunEnabled | Should -BeTrue
            $saved = Read-PilotSession $result.Path
            $saved.Revisions.Count | Should -Be 2
            $saved.Answer | Should -Be $result.Answer
            $server.Requests.Count | Should -Be 3
            $answerBody = $server.Requests.ToArray()[2].Body | ConvertFrom-Json
            $answerBody.messages[0].content | Should -Be $result.FinalPrompt
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'cancels through the actual UI button and retains completed work' {
        $body = '{"content":[{"type":"text","text":"First complete draft"}],"usage":{"input_tokens":10,"output_tokens":20},"stop_reason":"end_turn"}'
        $server = Start-PilotMockServer -Responses @(@{ Status = 200; Body = $body }, @{ Status = 200; Body = $body; DelayMs = 15000 })
        $dataDir = Join-Path $TestDrive 'cancel-data'
        $null = [IO.Directory]::CreateDirectory($dataDir)
        $preferences = New-PilotPreferences; $preferences.ActiveProvider = 'Anthropic'; $preferences.Providers.Anthropic.Model = 'claude-opus-5-5'
        Save-PilotPreferences (Join-Path $dataDir 'settings.json') $preferences
        $scenario = @'
+$script:MockProviders = Get-PilotProviders
+$script:MockProviders.Anthropic.ApiBase = '__MOCK_BASE__'
+function Get-PilotProviders { return $script:MockProviders }
+$script:SessionKeys.Anthropic = 'test-key'
+$script:Controls.PromptTextBox.Text = 'A task to refine'
+$script:Controls.IterationsTextBox.Text = '2'
+Invoke-PilotButton $script:Controls.RunButton
+$deadline = [DateTime]::UtcNow.AddSeconds(10)
+while ($script:Session.Revisions.Count -lt 1 -and [DateTime]::UtcNow -lt $deadline) {
+    $script:Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
+    Start-Sleep -Milliseconds 15
+}
+Invoke-PilotButton $script:Controls.CancelButton
+Wait-PilotDesktopIdle -TimeoutSeconds 3
+[pscustomobject]@{ FinalPrompt = $script:Controls.FinalPromptTextBox.Text; Revisions = $script:Session.Revisions.Count; Feedback = $script:Controls.FeedbackTextBlock.Text; RunEnabled = $script:Controls.RunButton.IsEnabled }
'@ -replace '(?m)^\+', ''
        $scenarioPath = Join-Path $TestDrive 'cancel.ps1'
        [IO.File]::WriteAllText($scenarioPath, $scenario.Replace('__MOCK_BASE__', $server.Base))
        try {
            $result = & $script:ScenarioRunner -DataDirectory $dataDir -ScenarioPath $scenarioPath -SourceDirectory $script:RepoRoot
            $result.FinalPrompt | Should -Be 'First complete draft'
            $result.Revisions | Should -Be 1
            $result.Feedback | Should -Match 'Cancelled'
            $result.RunEnabled | Should -BeTrue
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'autosaves the request while a run-limit field is temporarily invalid' {
        $dataDir = Join-Path $TestDrive 'invalid-limit-data'
        $scenarioPath = Join-Path $TestDrive 'invalid-limit.ps1'
        $scenario = @'
$script:Controls.PromptTextBox.Text = 'Do not lose this request while editing a numeric limit.'
$script:Controls.BudgetTextBox.Text = 'not-a-number'
Save-PilotAutosave
Invoke-PilotButton $script:Controls.RunButton
[pscustomobject]@{ Path = (Join-Path $script:SessionsDirectory ($script:Session.Id + '.json')); Feedback = $script:Controls.FeedbackTextBlock.Text; StartedRequest = [bool]$script:Operation }
'@ -replace '(?m)^\+', ''
        [IO.File]::WriteAllText($scenarioPath, $scenario)
        $result = & $script:ScenarioRunner -DataDirectory $dataDir -ScenarioPath $scenarioPath -SourceDirectory $script:RepoRoot
        $result.StartedRequest | Should -BeFalse
        $result.Feedback | Should -Match 'USD amount'
        (Read-PilotSession $result.Path).BasePrompt | Should -Be 'Do not lose this request while editing a numeric limit.'
    }
    It 'keeps the main actions inside the minimum supported window layout' {
        $dataDir = Join-Path $TestDrive 'minimum-layout-data'
        $scenarioPath = Join-Path $TestDrive 'minimum-layout.ps1'
        $scenario = @'
$script:Window.Width = 980; $script:Window.Height = 740
$script:Window.UpdateLayout()
$run = $script:Controls.RunButton.TranslatePoint([Windows.Point]::new(0,0), $script:Window.Content)
$cancel = $script:Controls.CancelButton.TranslatePoint([Windows.Point]::new(0,0), $script:Window.Content)
[pscustomobject]@{ RunBottom = $run.Y + $script:Controls.RunButton.ActualHeight; CancelRight = $cancel.X + $script:Controls.CancelButton.ActualWidth; Width = $script:Window.Content.ActualWidth; Height = $script:Window.Content.ActualHeight }
'@ -replace '(?m)^\+', ''
        [IO.File]::WriteAllText($scenarioPath, $scenario)
        $result = & $script:ScenarioRunner -DataDirectory $dataDir -ScenarioPath $scenarioPath -SourceDirectory $script:RepoRoot
        $result.RunBottom | Should -BeLessThan $result.Height
        $result.CancelRight | Should -BeLessThan $result.Width
    }
    It 'loads models and completes a real generation test through the provider dialog controls' {
        $server = Start-PilotMockServer -Responses @(
            @{ Status = 200; Body = '{"data":[{"id":"claude-opus-5-5"}],"has_more":false}' },
            @{ Status = 200; Body = '{"content":[{"type":"text","text":"PROMPT_PILOT_OK"}],"usage":{"input_tokens":10,"output_tokens":5}}' })
        $dataDir = Join-Path $TestDrive 'settings-dialog-data'
        $preferences = New-PilotPreferences; $preferences.ActiveProvider = 'Anthropic'; $preferences.Providers.Anthropic.Model = 'claude-opus-5-5'; $preferences.Keys.Anthropic = Protect-PilotSecret 'test-key'; $preferences.ModelManagement.AutoCheck = $false
        Save-PilotPreferences (Join-Path $dataDir 'settings.json') $preferences
        $scenarioPath = Join-Path $TestDrive 'settings-dialog.ps1'
        $scenario = @'
$script:MockProviders = Get-PilotProviders
$script:MockProviders.Anthropic.ApiBase = '__MOCK_BASE__'
$script:MockProviders.Anthropic.ModelsUri = '__MOCK_BASE__/models'
function Get-PilotProviders { return $script:MockProviders }
$script:SessionKeys.Clear()
$script:DialogStage = 0; $script:DialogError = ''; $script:LoadedModels = 0; $script:TestPassed = $false
$script:DialogDeadline = [DateTime]::UtcNow.AddSeconds(15)
$script:DialogTimer = [Windows.Threading.DispatcherTimer]::new()
$script:DialogTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$script:DialogTimer.Add_Tick({
    try {
        if ([DateTime]::UtcNow -gt $script:DialogDeadline) { throw 'Settings dialog test timed out.' }
        if (-not $script:SettingsContext) { return }
        $s = $script:SettingsContext
        if ($script:DialogStage -eq 0) { $script:DialogStage = 1; Invoke-PilotButton $s.Refresh }
        elseif ($script:DialogStage -eq 1 -and -not $script:Operation) { $script:LoadedModels = $s.Model.Items.Count; $script:DialogStage = 2; Invoke-PilotButton $s.Test }
        elseif ($script:DialogStage -eq 2 -and -not $script:Operation) { $script:TestPassed = ($s.Status.Text -match 'Test passed'); $script:DialogTimer.Stop(); Invoke-PilotButton $s.Save }
    }
    catch { $script:DialogError = $_.Exception.Message; $script:DialogTimer.Stop(); if ($script:SettingsContext) { $script:SettingsContext.Dialog.Close() } }
})
$script:DialogTimer.Start()
Show-PilotSettings
Wait-PilotDesktopIdle
[pscustomobject]@{ Error = $script:DialogError; Models = $script:LoadedModels; TestPassed = $script:TestPassed; Provider = $script:Session.ProviderName; Model = $script:Session.Model }
'@ -replace '(?m)^\+', ''
        [IO.File]::WriteAllText($scenarioPath, $scenario.Replace('__MOCK_BASE__', $server.Base))
        try {
            $result = & $script:ScenarioRunner -DataDirectory $dataDir -ScenarioPath $scenarioPath -SourceDirectory $script:RepoRoot
            $result.Error | Should -BeNullOrEmpty
            $result.Models | Should -Be 1
            $result.TestPassed | Should -BeTrue
            $result.Provider | Should -Be Anthropic
            $result.Model | Should -Be 'claude-opus-5-5'
            $server.Requests.Count | Should -Be 2
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'keeps unsaved work in the window when close-time persistence fails and discard is declined' {
        $scenarioPath = Join-Path $TestDrive 'close-save-failure.ps1'
        $scenario = @'
$script:Controls.PromptTextBox.Text = 'Unsaved request that must survive a failed close.'
$script:SaveMustFail = $true; $script:DiscardAsked = $false
function Save-PilotAutosave { if ($script:SaveMustFail) { throw 'Simulated disk failure' } }
function Confirm-PilotDiscardAfterSaveFailure { param($Message) $script:DiscardAsked = $true; return $false }
$script:Window.Close()
$result = [pscustomobject]@{ Visible = $script:Window.IsVisible; Closing = $script:Closing; Asked = $script:DiscardAsked; Prompt = $script:Controls.PromptTextBox.Text; Feedback = $script:Controls.FeedbackTextBlock.Text }
$script:SaveMustFail = $false
$result
'@ -replace '(?m)^\+', ''
        [IO.File]::WriteAllText($scenarioPath, $scenario)
        $result = & $script:ScenarioRunner -DataDirectory (Join-Path $TestDrive 'close-failure-data') -ScenarioPath $scenarioPath -SourceDirectory $script:RepoRoot
        $result.Visible | Should -BeTrue
        $result.Closing | Should -BeFalse
        $result.Asked | Should -BeTrue
        $result.Prompt | Should -Be 'Unsaved request that must survive a failed close.'
        $result.Feedback | Should -Match 'kept open'
    }
}
