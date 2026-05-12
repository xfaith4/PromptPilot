[CmdletBinding()]
param(
    [string]$SourceScript = '',
    [string]$XamlPath = '',
    [string]$OutputRoot = '',
    [string]$OutputBaseName = 'Prompt_Pilot',
    [string]$ProductName = 'Prompt Pilot',
    [string]$Description = 'Portable desktop tool for refining prompts and running tasks against configurable AI providers.',
    [string]$Version = '0.2.0',
    [string]$Company = 'Prompt Pilot Project',
    [string]$IconPath = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
}
else {
    Split-Path -Parent $PSCommandPath
}

if ([string]::IsNullOrWhiteSpace($SourceScript)) {
    $SourceScript = Join-Path $scriptRoot '..\Prompt_Pilot.Wpf.ps1'
}

if ([string]::IsNullOrWhiteSpace($XamlPath)) {
    $XamlPath = Join-Path $scriptRoot '..\Prompt_Pilot.MainWindow.xaml'
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $scriptRoot '..\dist'
}

if ([string]::IsNullOrWhiteSpace($IconPath)) {
    $IconPath = Join-Path $scriptRoot '..\assets\prompt-pilot.ico'
}

function Resolve-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-FileExists {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }
}

$sourceScriptPath = Resolve-NormalizedPath -Path $SourceScript
$xamlSourcePath = Resolve-NormalizedPath -Path $XamlPath
$outputRootPath = Resolve-NormalizedPath -Path $OutputRoot

Assert-FileExists -Path $sourceScriptPath -Label 'Source script'
Assert-FileExists -Path $xamlSourcePath -Label 'XAML file'

if ($IconPath) {
    $iconSourcePath = Resolve-NormalizedPath -Path $IconPath
    Assert-FileExists -Path $iconSourcePath -Label 'Icon file'
}
else {
    $iconSourcePath = $null
}

try {
    Import-Module ps2exe -ErrorAction Stop | Out-Null
}
catch {
    throw 'The ps2exe module is not available in this PowerShell host. Install it for the current host with: Install-Module ps2exe -Scope CurrentUser'
}

if (-not (Get-Command -Name Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
    throw 'Invoke-PS2EXE is not available after importing ps2exe. Try running this build script in pwsh and confirm the module is installed there.'
}

$outputDirectory = Join-Path $outputRootPath $OutputBaseName
$outputExePath = Join-Path $outputDirectory ($OutputBaseName + '.exe')
$outputXamlPath = Join-Path $outputDirectory 'Prompt_Pilot.MainWindow.xaml'

if (Test-Path -LiteralPath $outputDirectory) {
    Remove-Item -LiteralPath $outputDirectory -Recurse -Force
}

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$ps2exeParams = @{
    inputFile   = $sourceScriptPath
    outputFile  = $outputExePath
    title       = $ProductName
    description = $Description
    company     = $Company
    product     = $ProductName
    version     = $Version
    STA         = $true
    noConsole   = $true
    noOutput    = $true
    noError     = $false
    DPIAware    = $true
    supportOS   = $true
    x64         = $true
}

if ($iconSourcePath) {
    $ps2exeParams.iconFile = $iconSourcePath
}

Write-Host "Compiling $sourceScriptPath" -ForegroundColor Cyan
Invoke-PS2EXE @ps2exeParams

Copy-Item -LiteralPath $xamlSourcePath -Destination $outputXamlPath -Force

$packageManifest = [ordered]@{
    ProductName = $ProductName
    Version     = $Version
    BuiltAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    EntryExe    = [System.IO.Path]::GetFileName($outputExePath)
    XamlFile    = [System.IO.Path]::GetFileName($outputXamlPath)
    SourceScript = [System.IO.Path]::GetFileName($sourceScriptPath)
}

$packageManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputDirectory 'package.json') -Encoding UTF8

Write-Host ''
Write-Host 'Portable package created:' -ForegroundColor Green
Write-Host "  $outputDirectory"
Write-Host ''
Write-Host 'Contents:' -ForegroundColor Green
Write-Host "  - $([System.IO.Path]::GetFileName($outputExePath))"
Write-Host "  - $([System.IO.Path]::GetFileName($outputXamlPath))"
Write-Host '  - package.json'
