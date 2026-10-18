#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DataDirectory = '', [string]$ProviderName = '',
    [Parameter(Mandatory)][ValidateSet('Refine','Answer')][string]$Role,
    [Parameter(Mandatory)][string]$CandidateModel,
    [switch]$AllowPaidEvaluation
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'PromptPilot.Core.ps1')
if (-not $DataDirectory) { $DataDirectory = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Prompt Pilot' }
$preferences = Read-PilotPreferences (Join-Path $DataDirectory 'settings.json')
if (-not $ProviderName) { $ProviderName = $preferences.ActiveProvider }
$name = Resolve-PilotProvider $ProviderName
if (-not $AllowPaidEvaluation -or -not $preferences.ModelManagement.EvaluationEnabled) { throw 'Enable paid evaluations in the app and pass -AllowPaidEvaluation explicitly.' }
$key = (Get-PilotCredential $name $preferences).Key
if (-not $key) { throw 'No saved or environment credential is available.' }
$options = @{ Enabled = $true; DataDirectory = $DataDirectory; Role = $Role; BaselineModel = Get-PilotRoleModel $preferences $name $Role; CandidateModel = Resolve-PilotModel $name $CandidateModel; AnswerModel = Get-PilotRoleModel $preferences $name Answer; PricingOverrides = $preferences.PricingOverrides; RunBudgetUsd = $preferences.ModelManagement.RunBudgetUsd; MonthlyBudgetUsd = $preferences.ModelManagement.MonthlyBudgetUsd }
$result = Invoke-PilotModelEvaluation (Get-PilotProviders)[$name] $key $options
[pscustomobject]@{ Status = $result.Status; Decision = $result.Report.Decision; UsedOrReservedUsd = $result.Report.UsedUsd; EvidencePath = $result.ReportPath; Error = $result.Error } | ConvertTo-Json -Depth 5
if ($result.Status -ne 'Completed') { exit 1 }
