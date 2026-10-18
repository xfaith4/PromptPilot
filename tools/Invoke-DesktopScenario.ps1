#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DataDirectory,
    [Parameter(Mandatory)][string]$ScenarioPath,
    [string]$SourceDirectory = '',
    [string]$ReportPath = ''
)
$ErrorActionPreference = 'Stop'
if (-not $SourceDirectory) { $SourceDirectory = Split-Path -Parent $PSScriptRoot }
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Desktop scenarios require Windows WPF.' }
$sourcePath = Join-Path $SourceDirectory 'Prompt_Pilot.Wpf.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'The desktop source has parse errors.' }
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
$assignment = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:AppDirectory' }, $true)
$source = $source.Replace($assignment.Extent.Text, ('$script:AppDirectory = ' + "'" + ([IO.Path]::GetFullPath($SourceDirectory)).Replace("'", "''") + "'"))
$scenario = @'
function Wait-PilotDesktopIdle {
    param([int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $script:Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
        if (-not $script:Operation) { return }
        Start-Sleep -Milliseconds 15
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Desktop scenario timed out waiting for the request to complete.'
}
function Invoke-PilotButton {
    param($Button)
    if (-not $Button.IsEnabled) { throw 'The requested UI action is disabled.' }
    $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}
$script:Window.Show()
$script:Window.UpdateLayout()
try {
    . '__SCENARIO_PATH__'
}
finally { $script:Window.Close() }
'@
$scenario = $scenario.Replace('__SCENARIO_PATH__', ([IO.Path]::GetFullPath($ScenarioPath)).Replace("'", "''"))
$source = $source.Replace('$null = $script:Window.ShowDialog()', $scenario)
$runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$runspace.ApartmentState = 'STA'
$runspace.ThreadOptions = 'ReuseThread'
$runspace.Open()
$pipeline = [Management.Automation.PowerShell]::Create()
$pipeline.Runspace = $runspace
try {
    $results = @($pipeline.AddScript($source).AddParameter('DataDirectory', ([IO.Path]::GetFullPath($DataDirectory))).Invoke())
    if ($pipeline.HadErrors) { throw ('Desktop scenario failed: ' + (@($pipeline.Streams.Error) -join '; ')) }
    $result = $results[-1]
    if ($ReportPath) {
        . (Join-Path $SourceDirectory 'PromptPilot.Core.ps1')
        Write-PilotJson $ReportPath $result
    }
    return $result
}
finally { $pipeline.Dispose(); $runspace.Dispose() }
