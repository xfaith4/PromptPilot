#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for Prompt_Pilot.Wpf.ps1 — startup integrity and the
    background answer-task pipeline.

.DESCRIPTION
    The application script cannot be dot-sourced headlessly (it ends in
    ShowDialog), so these tests extract the pieces under test from the file
    via the PowerShell AST and exercise the REAL source text:

      * the background scriptblock inside Start-AnswerTask is run through the
        same PowerShell.Create()/AddScript/BeginInvoke mechanism production
        uses, against a local HttpListener mock — no network, no key.
      * UI-dependent functions (Set-BusyState, Complete-AnswerTask,
        Stop-AnswerTask) run against fake control objects.

    Run:  pwsh -STA -File tests/Invoke-Tests.ps1
    (STA matters: the XAML-load tests use XamlReader.)
#>

BeforeAll {
    $script:RepoRoot  = Split-Path -Parent $PSScriptRoot
    $script:AppScript = Join-Path $script:RepoRoot 'Prompt_Pilot.Wpf.ps1'
    $script:MainXaml  = Join-Path $script:RepoRoot 'Prompt_Pilot.MainWindow.xaml'

    $tokens = $null; $parseErrors = $null
    $script:AppAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:AppScript, [ref]$tokens, [ref]$parseErrors)
    $script:AppParseErrors = @($parseErrors)
    $script:AppText = Get-Content -LiteralPath $script:AppScript -Raw

    # -- helpers -------------------------------------------------------------

    function Get-AppFunctionText {
        param([Parameter(Mandatory)][string]$Name)
        $fn = $script:AppAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
            }, $true) | Select-Object -First 1
        if (-not $fn) { throw "Function '$Name' not found in the app script." }
        return $fn.Extent.Text
    }

    function Get-BackgroundScriptText {
        # The scriptblock assigned to $backgroundScript inside Start-AnswerTask,
        # exactly as production hands it to AddScript (ToString strips braces).
        $assignment = $script:AppAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq '$backgroundScript'
            }, $true) | Select-Object -First 1
        if (-not $assignment) { throw 'Assignment to $backgroundScript not found.' }
        $sbAst = $assignment.Right.Find({
                param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
            }, $true)
        if (-not $sbAst) { throw '$backgroundScript right-hand side is not a scriptblock.' }
        return $sbAst.ScriptBlock.GetScriptBlock().ToString()
    }

    # Start a one-shot mock API server on 127.0.0.1 (never 'localhost' on this
    # machine). Runs in its own runspace; answers every request with the given
    # status/body until disposed.
    function Start-MockApiServer {
        param(
            [Parameter(Mandatory)][string]$BodyJson,
            [int]$StatusCode = 200,
            [int]$DelayMs = 0
        )
        # A fresh listener per attempt: HttpListener is unusable after a failed
        # Start, so reusing one instance burns every retry on the first failure.
        $listener = $null
        $port = 0
        for ($try = 0; $try -lt 10; $try++) {
            $candidate = Get-Random -Minimum 20000 -Maximum 59000
            $attemptListener = [System.Net.HttpListener]::new()
            try {
                $attemptListener.Prefixes.Add("http://127.0.0.1:$candidate/")
                $attemptListener.Start()
                $listener = $attemptListener
                $port = $candidate
                break
            } catch {
                try { $attemptListener.Close() } catch { }
            }
        }
        if ($port -eq 0) { throw 'Could not bind a mock server port.' }

        $serverPs = [System.Management.Automation.PowerShell]::Create()
        $null = $serverPs.AddScript({
            param($Listener, $BodyJson, $StatusCode, $DelayMs)
            while ($Listener.IsListening) {
                try { $ctx = $Listener.GetContext() } catch { break }
                if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($BodyJson)
                $ctx.Response.StatusCode = $StatusCode
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.OutputStream.Close()
            }
        }).AddArgument($listener).AddArgument($BodyJson).AddArgument($StatusCode).AddArgument($DelayMs)
        $handle = $serverPs.BeginInvoke()

        return [pscustomobject]@{
            Port     = $port
            BaseUrl  = "http://127.0.0.1:$port"
            Listener = $listener
            Ps       = $serverPs
            Handle   = $handle
        }
    }

    function Stop-MockApiServer {
        param([Parameter(Mandatory)]$Server)
        try { $Server.Listener.Stop(); $Server.Listener.Close() } catch { }
        try { $Server.Ps.Stop() } catch { }
        try { $Server.Ps.Dispose() } catch { }
    }

    # Runs the extracted background script exactly as Start-AnswerTask does.
    function Invoke-BackgroundPipeline {
        param(
            [Parameter(Mandatory)][string]$ScriptText,
            [Parameter(Mandatory)][object[]]$Arguments,
            [int]$TimeoutSeconds = 15
        )
        $ps = [System.Management.Automation.PowerShell]::Create()
        $null = $ps.AddScript($ScriptText)
        foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }
        $handle = $ps.BeginInvoke()
        if (-not $handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            try { $ps.Stop() } catch { }
            $ps.Dispose()
            throw "Background pipeline did not complete within $TimeoutSeconds seconds."
        }
        try {
            $output = $ps.EndInvoke($handle)
            return [pscustomobject]@{ Output = $output; Errors = @($ps.Streams.Error); Failed = $false; Exception = $null }
        }
        catch {
            return [pscustomobject]@{ Output = $null; Errors = @($ps.Streams.Error); Failed = $true; Exception = $_.Exception }
        }
        finally {
            $ps.Dispose()
        }
    }

    function New-TestProvider {
        param([Parameter(Mandatory)][string]$BaseUrl, [string]$Protocol = 'OpenAI')
        $endpointPath = if ($Protocol -eq 'Anthropic') { 'v1/messages' } else { 'chat/completions' }
        return [ordered]@{
            DisplayName      = 'MockProvider'
            ApiBase          = $BaseUrl
            ChatEndpointPath = $endpointPath
            EnvVars          = @('MOCK_NONE')
            DefaultModel     = 'mock-model'
            DefaultPricePer1kInputTokens  = 0.001
            DefaultPricePer1kOutputTokens = 0.002
            Protocol         = $Protocol
        }
    }

    $script:TestProviderSettings = [ordered]@{
        Model                  = 'mock-model'
        PricePer1kInputTokens  = 0.001
        PricePer1kOutputTokens = 0.002
    }

    $script:OpenAiBody = @{
        choices = @(@{ message = @{ role = 'assistant'; content = 'mocked answer text' } })
        usage   = @{ prompt_tokens = 11; completion_tokens = 7 }
    } | ConvertTo-Json -Depth 6

    $script:AnthropicBody = @{
        content = @(@{ type = 'text'; text = 'mocked claude text' })
        usage   = @{ input_tokens = 13; output_tokens = 5 }
    } | ConvertTo-Json -Depth 6
}

Describe 'Startup integrity' {

    It 'app script parses with zero errors' {
        $script:AppParseErrors.Count | Should -Be 0
    }

    It 'main window XAML loads and every control the script requires resolves' {
        [xml]$xaml = Get-Content -LiteralPath $script:MainXaml -Raw
        $reader = [System.Xml.XmlNodeReader]::new($xaml)
        $window = [Windows.Markup.XamlReader]::Load($reader)

        # Every FindName target the script asks the main window for, taken from
        # the source so the test cannot drift from the app.
        $required = [regex]::Matches($script:AppText, '\$window\.FindName\(''(?<n>\w+)''\)') |
            ForEach-Object { $_.Groups['n'].Value } | Sort-Object -Unique
        $required.Count | Should -BeGreaterThan 30

        $missing = @($required | Where-Object { $null -eq $window.FindName($_) })
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'inline dialog XAMLs load and their controls resolve' {
        $hereStrings = [regex]::Matches($script:AppText, "@'\r?\n(?<x><Window[\s\S]*?</Window>)\r?\n'@")
        $hereStrings.Count | Should -Be 2
        foreach ($m in $hereStrings) {
            $reader = [System.Xml.XmlNodeReader]::new([xml]$m.Groups['x'].Value)
            $dialog = [Windows.Markup.XamlReader]::Load($reader)
            $names = [regex]::Matches($m.Groups['x'].Value, 'Name="(?<n>\w+)"') |
                ForEach-Object { $_.Groups['n'].Value }
            foreach ($n in $names) {
                $dialog.FindName($n) | Should -Not -BeNullOrEmpty -Because "dialog control '$n' must resolve"
            }
        }
    }
}

Describe 'Background answer-task pipeline' {

    BeforeAll {
        $script:BackgroundText = Get-BackgroundScriptText
    }

    It 'background scriptblock is self-contained (no app-scope function or $script: references)' {
        # It runs in a bare runspace: any reference to app functions or script
        # scope resolves to nothing there and fails at runtime, not at parse.
        $script:BackgroundText | Should -Not -Match '\$script:'
        foreach ($appFn in @('Get-ApiKey', 'Get-ProviderDefinition', 'Invoke-WithRetry', 'Append-Log', 'Show-Status')) {
            $script:BackgroundText | Should -Not -Match ([regex]::Escape($appFn))
        }
    }

    It 'completes an OpenAI-protocol task against a mock endpoint' {
        $server = Start-MockApiServer -BodyJson $script:OpenAiBody
        try {
            $provider = New-TestProvider -BaseUrl $server.BaseUrl -Protocol 'OpenAI'
            $result = Invoke-BackgroundPipeline -ScriptText $script:BackgroundText -Arguments @(
                'test prompt', '', 'mock-model', 'MockProvider', $provider, $script:TestProviderSettings, 'mock-key')

            $result.Failed | Should -BeFalse -Because ('{0} {1}' -f $result.Exception, (@($result.Errors) -join '; '))
            $result.Output.Count | Should -BeGreaterOrEqual 1
            $task = $result.Output[$result.Output.Count - 1]
            $task.OutputText        | Should -Be 'mocked answer text'
            $task.TotalInputTokens  | Should -Be 11
            $task.TotalOutputTokens | Should -Be 7
            $task.TotalTokens       | Should -Be 18
            [double]$task.TotalCostUsd | Should -BeGreaterThan 0
        }
        finally { Stop-MockApiServer -Server $server }
    }

    It 'completes an Anthropic-protocol task against a mock endpoint' {
        $server = Start-MockApiServer -BodyJson $script:AnthropicBody
        try {
            $provider = New-TestProvider -BaseUrl $server.BaseUrl -Protocol 'Anthropic'
            $result = Invoke-BackgroundPipeline -ScriptText $script:BackgroundText -Arguments @(
                'test prompt', '', 'mock-model', 'MockProvider', $provider, $script:TestProviderSettings, 'mock-key')

            $result.Failed | Should -BeFalse -Because ('{0} {1}' -f $result.Exception, (@($result.Errors) -join '; '))
            $task = $result.Output[$result.Output.Count - 1]
            $task.OutputText        | Should -Be 'mocked claude text'
            $task.TotalInputTokens  | Should -Be 13
            $task.TotalOutputTokens | Should -Be 5
        }
        finally { Stop-MockApiServer -Server $server }
    }

    It 'surfaces an HTTP failure as a pipeline error instead of hanging' {
        $server = Start-MockApiServer -BodyJson '{"error":{"message":"mock 500"}}' -StatusCode 500
        try {
            $provider = New-TestProvider -BaseUrl $server.BaseUrl
            $result = Invoke-BackgroundPipeline -ScriptText $script:BackgroundText -Arguments @(
                'test prompt', '', 'mock-model', 'MockProvider', $provider, $script:TestProviderSettings, 'mock-key')
            $result.Failed | Should -BeTrue
        }
        finally { Stop-MockApiServer -Server $server }
    }

    It 'records a warning and still completes when the file reference is missing' {
        $server = Start-MockApiServer -BodyJson $script:OpenAiBody
        try {
            $provider = New-TestProvider -BaseUrl $server.BaseUrl
            $missingFile = Join-Path $env:TEMP ("pp-no-such-file-{0}.txt" -f ([guid]::NewGuid().ToString('n')))
            $result = Invoke-BackgroundPipeline -ScriptText $script:BackgroundText -Arguments @(
                'test prompt', $missingFile, 'mock-model', 'MockProvider', $provider, $script:TestProviderSettings, 'mock-key')

            $result.Failed | Should -BeFalse
            $task = $result.Output[$result.Output.Count - 1]
            @($task.Warnings).Count | Should -Be 1
            @($task.Warnings)[0] | Should -Match 'File not found'
        }
        finally { Stop-MockApiServer -Server $server }
    }

    It 'a running task can be stopped, and stopping is not reported as completion' {
        # Server that stalls 30s; the task must be stoppable long before that.
        $server = Start-MockApiServer -BodyJson $script:OpenAiBody -DelayMs 30000
        try {
            $provider = New-TestProvider -BaseUrl $server.BaseUrl
            $ps = [System.Management.Automation.PowerShell]::Create()
            $null = $ps.AddScript($script:BackgroundText)
            foreach ($a in @('test prompt', '', 'mock-model', 'MockProvider', $provider, $script:TestProviderSettings, 'mock-key')) {
                $null = $ps.AddArgument($a)
            }
            $handle = $ps.BeginInvoke()
            Start-Sleep -Milliseconds 400

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $ps.Stop()
            $sw.Stop()

            $sw.Elapsed.TotalSeconds | Should -BeLessThan 10 -Because 'Stop must not wait out the HTTP call'
            $ps.InvocationStateInfo.State | Should -Be 'Stopped'
            $handle.IsCompleted | Should -BeTrue
            $ps.Dispose()
        }
        finally { Stop-MockApiServer -Server $server }
    }
}

Describe 'UI wiring for background tasks' {

    BeforeAll {
        # Fake WPF-ish controls: settable properties, no dispatcher.
        class FakeControl {
            [string]$Text = ''
            [bool]$IsEnabled = $true
            [object]$Visibility = 'Collapsed'
            [object]$Content = ''
            [double]$Opacity = 1.0
            [nullable[bool]]$IsChecked
            [void]AppendText([string]$t) { $this.Text += $t }
            [void]ScrollToEnd() { }
            [void]Clear() { $this.Text = '' }
        }
        class FakeWindow { [object]$Cursor }

        $script:NewFakeUi = {
            $ui = @{}
            foreach ($n in @('RunButton','BrowseButton','CopyButton','UsePromptButton','CopyTaskOutputButton',
                             'ModeRefineRadio','ModeAnswerRadio','ClearLogButton','SavePresetButton','LoadPresetButton',
                             'ClearSessionKeyButton','CancelButton','AcceptIterationButton','BusyIndicatorTextBlock',
                             'StatusTextBlock','UsageTextBlock','LogTextBox','TaskOutputTextBox')) {
                $ui[$n] = [FakeControl]::new()
            }
            $ui
        }

        # Session for the extracted UI functions: define fakes as $script: vars,
        # then dot-define the real function text into that session.
        function New-UiSession {
            $ui = & $script:NewFakeUi
            $sessionVars = @{}
            foreach ($k in $ui.Keys) { $sessionVars[$k] = $ui[$k] }

            $ss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($ss)
            $rs.Open()
            $psSession = [System.Management.Automation.PowerShell]::Create()
            $psSession.Runspace = $rs

            $setup = @'
$script:LogFilePath = $null
$script:CancelRequested = $false
$script:AnswerTaskState = $null
$script:AnswerTaskTimer = $null
function Show-TaskErrorDialog { param([string]$Message) $script:LastErrorDialog = $Message }
'@
            $null = $psSession.AddScript($setup).Invoke(); $psSession.Commands.Clear()
            foreach ($k in $sessionVars.Keys) {
                $null = $psSession.AddScript("`$script:$k = `$args[0]").AddArgument($sessionVars[$k]).Invoke()
                $psSession.Commands.Clear()
            }
            $null = $psSession.AddScript('$window = $args[0]; $script:window = $args[0]').AddArgument([FakeWindow]::new()).Invoke()
            $psSession.Commands.Clear()

            foreach ($fn in @('Show-Status','Append-Log','Set-BusyState','Complete-AnswerTask','Stop-AnswerTask')) {
                $text = Get-AppFunctionText -Name $fn
                $null = $psSession.AddScript($text).Invoke()
                $psSession.Commands.Clear()
            }

            return [pscustomobject]@{ Ps = $psSession; Ui = $ui; Runspace = $rs }
        }

        function Invoke-InUiSession {
            param($Session, [string]$Code)
            $Session.Ps.Commands.Clear()
            $out = $Session.Ps.AddScript($Code).Invoke()
            $Session.Ps.Commands.Clear()
            return $out
        }
    }

    It 'the app defines Stop-AnswerTask, and the Cancel button uses it for background tasks' {
        { Get-AppFunctionText -Name 'Stop-AnswerTask' } | Should -Not -Throw -Because 'a background task with no stop path locks the UI for the length of the HTTP timeout'
        $script:AppText | Should -Match 'CancelButton\.Add_Click\(\{[\s\S]*?Stop-AnswerTask'
    }

    It 'Run-AnswerTask leaves the Cancel button enabled while a background task runs' {
        $runText = Get-AppFunctionText -Name 'Run-AnswerTask'
        $runText | Should -Not -Match 'CancelButton\.IsEnabled\s*=\s*\$false' -Because 'Cancel is the only recovery from a slow request'
    }

    It 'Complete-AnswerTask on success writes output, clears busy state, and releases the task slot' {
        $s = New-UiSession
        try {
            $code = @'
$fake = [System.Management.Automation.PowerShell]::Create()
$null = $fake.AddScript('[pscustomobject]@{ OutputText = "done text"; TotalTokens = 5; TotalInputTokens = 3; TotalOutputTokens = 2; TotalCostUsd = 0.01; Warnings = @() }')
$h = $fake.BeginInvoke()
$null = $h.AsyncWaitHandle.WaitOne(5000)
$script:AnswerTaskState = [pscustomobject]@{ PowerShell = $fake; Handle = $h }
Complete-AnswerTask -Handle $h -PowerShellInstance $fake
'@
            $null = Invoke-InUiSession -Session $s -Code $code
            $s.Ui['TaskOutputTextBox'].Text | Should -Be 'done text'
            $s.Ui['RunButton'].IsEnabled | Should -BeTrue
            $s.Ui['CancelButton'].IsEnabled | Should -BeFalse
            (Invoke-InUiSession -Session $s -Code '$null -eq $script:AnswerTaskState')[0] | Should -BeTrue
        }
        finally { $s.Ps.Dispose(); $s.Runspace.Dispose() }
    }

    It 'Complete-AnswerTask on failure clears busy state, releases the slot, and routes the error through the dialog seam' {
        $s = New-UiSession
        try {
            $code = @'
$fake = [System.Management.Automation.PowerShell]::Create()
$null = $fake.AddScript('throw "mock task failure"')
$h = $fake.BeginInvoke()
$null = $h.AsyncWaitHandle.WaitOne(5000)
$script:AnswerTaskState = [pscustomobject]@{ PowerShell = $fake; Handle = $h }
Complete-AnswerTask -Handle $h -PowerShellInstance $fake
"DIALOG:$script:LastErrorDialog"
'@
            $out = @(Invoke-InUiSession -Session $s -Code $code)
            ($out -join "`n") | Should -Match 'DIALOG:.*mock task failure'
            $s.Ui['RunButton'].IsEnabled | Should -BeTrue
            (Invoke-InUiSession -Session $s -Code '$null -eq $script:AnswerTaskState')[0] | Should -BeTrue
        }
        finally { $s.Ps.Dispose(); $s.Runspace.Dispose() }
    }

    It 'a cancelled task reports cancellation, not an error dialog' {
        $s = New-UiSession
        try {
            $code = @'
$fake = [System.Management.Automation.PowerShell]::Create()
$null = $fake.AddScript('Start-Sleep -Seconds 60')
$h = $fake.BeginInvoke()
Start-Sleep -Milliseconds 300
$fake.Stop()
$script:AnswerTaskState = [pscustomobject]@{ PowerShell = $fake; Handle = $h }
Complete-AnswerTask -Handle $h -PowerShellInstance $fake
"DIALOG:[$script:LastErrorDialog]"
"STATUS:[" + $script:StatusTextBlock.Text + "]"
'@
            $out = @(Invoke-InUiSession -Session $s -Code $code) -join "`n"
            $out | Should -Match 'DIALOG:\[\]' -Because 'cancelling is an operator choice, not an application error'
            $out | Should -Match '(?i)STATUS:\[.*cancel'
            $s.Ui['RunButton'].IsEnabled | Should -BeTrue
        }
        finally { $s.Ps.Dispose(); $s.Runspace.Dispose() }
    }

    It 'Stop-AnswerTask stops a running background task and is safe to call when idle' {
        $s = New-UiSession
        try {
            $code = @'
$fake = [System.Management.Automation.PowerShell]::Create()
$null = $fake.AddScript('Start-Sleep -Seconds 60')
$h = $fake.BeginInvoke()
Start-Sleep -Milliseconds 300
$script:AnswerTaskState = [pscustomobject]@{ PowerShell = $fake; Handle = $h }
Stop-AnswerTask
Start-Sleep -Milliseconds 500
"STATE:" + $fake.InvocationStateInfo.State
'@
            $out = @(Invoke-InUiSession -Session $s -Code $code) -join "`n"
            $out | Should -Match 'STATE:(Stopped|Stopping)'
            { Invoke-InUiSession -Session $s -Code '$script:AnswerTaskState = $null; Stop-AnswerTask' } | Should -Not -Throw
        }
        finally { $s.Ps.Dispose(); $s.Runspace.Dispose() }
    }
}
