#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Restart, [string]$DataDirectory = '')
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Prompt Pilot requires Windows.' }
if (-not $DataDirectory) { $DataDirectory = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Prompt Pilot' }
$appDirectory = $PSScriptRoot
$instancePath = Join-Path $DataDirectory 'instance.json'
if (Test-Path -LiteralPath $instancePath) {
    $instance = $null
    try { $instance = Get-Content -LiteralPath $instancePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if ($instance) {
        $process = Get-Process -Id ([int]$instance.ProcessId) -ErrorAction SilentlyContinue
        $matches = $process -and ($process.StartTime.ToUniversalTime().ToString('o') -eq [string]$instance.StartedAtUtc)
        if ($matches -and -not $Restart) {
            [IO.File]::WriteAllText((Join-Path $DataDirectory 'activate.request'), '')
            return
        }
        if ($matches) {
            $request = @{ ProcessId = [int]$instance.ProcessId } | ConvertTo-Json
            [IO.File]::WriteAllText((Join-Path $DataDirectory 'restart.request'), $request, [Text.UTF8Encoding]::new($false))
            if (-not $process.WaitForExit(10000)) { throw 'Prompt Pilot is still closing. Save or close any open dialog, then run the launcher again. Your existing process was kept.' }
        }
    }
}
$exe = Join-Path $appDirectory 'Prompt_Pilot.exe'
if (Test-Path -LiteralPath $exe) {
    Start-Process -FilePath $exe -ArgumentList @('-DataDirectory', ('"' + $DataDirectory + '"')) -WorkingDirectory $appDirectory
}
else {
    $source = Join-Path $appDirectory 'Prompt_Pilot.Wpf.ps1'
    if (-not (Test-Path -LiteralPath $source)) { throw 'Prompt Pilot source or executable was not found beside the launcher.' }
    Start-Process -FilePath powershell.exe -ArgumentList @('-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $source + '"'), '-DataDirectory', ('"' + $DataDirectory + '"')) -WorkingDirectory $appDirectory -WindowStyle Hidden
}
