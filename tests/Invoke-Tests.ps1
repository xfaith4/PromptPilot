#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the Prompt Pilot Pester suite in an STA host with WPF loaded.
.DESCRIPTION
    The XAML tests need XamlReader, which needs STA and the WPF assemblies.
    Invoke as:  pwsh -STA -File tests/Invoke-Tests.ps1
    Exits 0 only when every test passes.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Run this under an STA host: pwsh -STA -File tests/Invoke-Tests.ps1'
}

Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName PresentationCore     | Out-Null
Add-Type -AssemblyName WindowsBase          | Out-Null

Import-Module Pester -MinimumVersion 5.0

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'PromptPilot.Tests.ps1'
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit = $true

Invoke-Pester -Configuration $config
