#Requires -Version 5.1
[CmdletBinding()]
param([string]$ApplicationDirectory = '', [string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $ApplicationDirectory) { $ApplicationDirectory = $root }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root ('build/launcher-check-' + [guid]::NewGuid().ToString('N')) }
. (Join-Path $root 'PromptPilot.Core.ps1')
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$dataDir = Join-Path $OutputDirectory 'data'
$instancePath = Join-Path $dataDir 'instance.json'
$launcher = Join-Path $ApplicationDirectory 'Start-PromptPilot.ps1'

function Wait-LauncherInstance {
    param([int]$PreviousId = 0)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (Test-Path -LiteralPath $instancePath) {
            try {
                $instance = Read-PilotJson $instancePath
                if ([int]$instance.ProcessId -ne $PreviousId -and (Get-Process -Id ([int]$instance.ProcessId) -ErrorAction SilentlyContinue)) { return $instance }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The launcher did not create a new application instance.'
}

$latest = $null
try {
    & $launcher -DataDirectory $dataDir -Restart
    $first = Wait-LauncherInstance
    $latest = $first
    & $launcher -DataDirectory $dataDir
    Start-Sleep -Milliseconds 400
    $activated = Read-PilotJson $instancePath
    if ($activated.ProcessId -ne $first.ProcessId) { throw 'Activation started a duplicate instance.' }
    & $launcher -DataDirectory $dataDir -Restart
    $second = Wait-LauncherInstance -PreviousId ([int]$first.ProcessId)
    $latest = $second
    if (Get-Process -Id ([int]$first.ProcessId) -ErrorAction SilentlyContinue) { throw 'The old instance did not exit during restart.' }
    $report = @{ Status = 'Passed'; ApplicationDirectory = $ApplicationDirectory; FirstProcessId = $first.ProcessId; RestartedProcessId = $second.ProcessId; SingleInstanceActivation = 'Passed'; OrderlyRestart = 'Passed'; CheckedAtUtc = [DateTime]::UtcNow.ToString('o') }
    Write-PilotJson (Join-Path $OutputDirectory 'launcher.json') $report
    $report | ConvertTo-Json
}
finally {
    if ($latest) {
        Write-PilotJson (Join-Path $dataDir 'restart.request') @{ ProcessId = [int]$latest.ProcessId }
        $process = Get-Process -Id ([int]$latest.ProcessId) -ErrorAction SilentlyContinue
        if ($process -and -not $process.WaitForExit(10000)) { throw 'The isolated launcher test instance did not close; its data directory is recorded in the test output.' }
    }
}
