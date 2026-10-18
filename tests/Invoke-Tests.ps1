#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the Prompt Pilot Pester suite in an STA host with WPF loaded.
.DESCRIPTION
    The XAML tests need XamlReader, which needs STA and the WPF assemblies.
    Invoke as:  pwsh -STA -File tests/Invoke-Tests.ps1
    Add -Headless to run logging/API tests without Windows WPF.
    Exits 0 only when every selected test passes.
#>
[CmdletBinding()]
param([switch]$Headless)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Headless -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Run this under an STA host: pwsh -STA -File tests/Invoke-Tests.ps1'
}

if (-not $Headless) {
    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore     | Out-Null
    Add-Type -AssemblyName WindowsBase          | Out-Null
}

Import-Module Pester -MinimumVersion 5.0

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Output.Verbosity = 'Detailed'
if ($Headless) { $config.Filter.ExcludeTag = @('WindowsUI') }
$config.Run.Exit = $false
$config.Run.PassThru = $true

$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0 -or $result.PassedCount -lt 1) { exit 1 }
