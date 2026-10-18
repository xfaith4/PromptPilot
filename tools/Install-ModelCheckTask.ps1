#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param([string]$DataDirectory = '', [string]$TaskName = 'PromptPilotModelDiscovery', [switch]$Remove)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Windows Task Scheduler is required.' }
if (-not $DataDirectory) { $DataDirectory = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Prompt Pilot' }
if ($TaskName -notmatch '^PromptPilot[A-Za-z0-9_-]*$') { throw 'Choose a simple task name starting with PromptPilot.' }
if ($Remove) {
    if ($PSCmdlet.ShouldProcess($TaskName, 'Remove model-discovery scheduled task')) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
    return
}
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { throw 'A task with this name already exists. Inspect or remove it explicitly before installing a replacement.' }
$checker = Join-Path $PSScriptRoot 'Check-ModelUpdates.ps1'
if ($DataDirectory.Contains('"') -or $checker.Contains('"')) { throw 'Paths cannot contain quote characters.' }
$arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -DataDirectory "{1}"' -f $checker, ([IO.Path]::GetFullPath($DataDirectory))
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '10:00AM'
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5)) -MultipleInstances IgnoreNew
if ($PSCmdlet.ShouldProcess($TaskName, 'Register weekly discovery-only task; no paid generation')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Prompt Pilot metadata discovery only. No paid benchmarks or default changes.'
}
