#Requires -Version 5.1
[CmdletBinding()]
param([string]$DataDirectory = '', [string]$ProviderName = '', [switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'PromptPilot.Core.ps1')
if (-not $DataDirectory) { $DataDirectory = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Prompt Pilot' }
$preferences = Read-PilotPreferences (Join-Path $DataDirectory 'settings.json')
if (-not $ProviderName) { $ProviderName = $preferences.ActiveProvider }
$provider = (Get-PilotProviders)[(Resolve-PilotProvider $ProviderName)]
$catalog = Read-PilotCatalog $DataDirectory $provider.Name
if (-not $Force -and (-not $preferences.ModelManagement.AutoCheck -or -not (Test-PilotCatalogDue $catalog))) {
    [pscustomobject]@{ Status = 'NotDueOrDisabled'; Provider = $provider.Name; NextCheckUtc = $catalog.NextCheckUtc }
    return
}
$credential = Get-PilotCredential $provider.Name $preferences
if (-not $credential.Key) { throw 'No saved/environment credential is available. Session-only keys require the open application.' }
$result = Update-PilotCatalog $provider $credential.Key $DataDirectory
[pscustomobject]@{ Status = $result.Status; Provider = $provider.Name; LastSuccessUtc = $result.Catalog.LastSuccessUtc; NewModels = $result.Catalog.NewIds; Error = $result.Error } | ConvertTo-Json -Depth 5
if ($result.Status -ne 'Completed') { exit 1 }
