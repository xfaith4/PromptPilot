#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'PromptPilot.Core.ps1')
$report = Read-PilotJson $ReportPath
$corpus = Read-PilotJson (Join-Path $root 'evaluations/prompt-cases.json')
foreach ($entry in $report.Evaluations) {
    $case = @($corpus.cases | Where-Object id -eq $entry.CaseId | Select-Object -First 1)[0]
    if (-not $case) { throw ('Case not found: ' + $entry.CaseId) }
    $checks = @()
    foreach ($pattern in $case.required) { $checks += @{ Pattern = $pattern; Expectation = 'Required'; Passed = ($entry.Result.OutputText -match $pattern) } }
    foreach ($pattern in $case.forbidden) { $checks += @{ Pattern = $pattern; Expectation = 'Absent'; Passed = ($entry.Result.OutputText -notmatch $pattern) } }
    $entry.Checks = $checks
    $entry.Passed = ($entry.Result.Status -eq 'Completed' -and @($checks | Where-Object { -not $_.Passed }).Count -eq 0)
}
$report.ChecksRecomputedAtUtc = [DateTime]::UtcNow.ToString('o')
$report.Status = if (@($report.Providers | Where-Object GenerationStatus -ne 'Passed').Count -eq 0 -and @($report.Evaluations | Where-Object { -not $_.Passed }).Count -eq 0) { 'Passed' } else { 'Partial' }
Write-PilotJson $ReportPath $report
$report.Evaluations | ForEach-Object { [pscustomobject]$_ } | Select-Object CaseId, Passed | Format-Table
if (@($report.Evaluations | Where-Object { -not $_.Passed }).Count) { exit 1 }
