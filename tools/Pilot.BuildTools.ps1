#Requires -Version 5.1
# Build-time modules only; never changes the user's persistent module search path.
function Resolve-PilotBuildModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ps2exe', 'Pester')][string]$Name,
        [version]$RequiredVersion,
        [version]$MinimumVersion,
        [string[]]$SearchRoots
    )
    $candidates = @()
    if (-not $PSBoundParameters.ContainsKey('SearchRoots')) {
        $candidates = @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $SearchRoots = @()
        if ($documents) {
            $SearchRoots += Join-Path $documents 'WindowsPowerShell/Modules'
            $SearchRoots += Join-Path $documents 'PowerShell/Modules'
        }
    }
    # PowerShell 7 removes its own module directories when launching powershell.exe.
    # Inspect these two known user locations explicitly, respecting OneDrive redirection.
    foreach ($searchRoot in @($SearchRoots | Select-Object -Unique)) {
        $moduleDirectory = Join-Path $searchRoot $Name
        if (-not (Test-Path -LiteralPath $moduleDirectory -PathType Container)) { continue }
        $manifests = @(Join-Path $moduleDirectory ($Name + '.psd1'))
        foreach ($directory in @(Get-ChildItem -LiteralPath $moduleDirectory -Directory)) {
            $versionNumber = $null
            if ([version]::TryParse($directory.Name, [ref]$versionNumber)) {
                $manifests += Join-Path $directory.FullName ($Name + '.psd1')
            }
        }
        foreach ($manifest in $manifests) {
            if (Test-Path -LiteralPath $manifest -PathType Leaf) {
                $candidates += @(Get-Module -ListAvailable -Name $manifest -ErrorAction SilentlyContinue)
            }
        }
    }
    $edition = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
    $module = $candidates | Where-Object {
        $_.Name -eq $Name -and
        (-not $RequiredVersion -or $_.Version -eq $RequiredVersion) -and
        (-not $MinimumVersion -or $_.Version -ge $MinimumVersion) -and
        (-not $_.PowerShellVersion -or $_.PowerShellVersion -le $PSVersionTable.PSVersion) -and
        (-not $_.CompatiblePSEditions -or $edition -in $_.CompatiblePSEditions)
    } | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) {
        $versionArgument = if ($RequiredVersion) { '-RequiredVersion ' + $RequiredVersion } elseif ($MinimumVersion) { '-MinimumVersion ' + $MinimumVersion } else { '' }
        throw ('The build cannot find a compatible {0} {1} in this host or either user module folder. Install it for Windows PowerShell with: powershell.exe -NoProfile -Command "Install-Module {0} {1} -Scope CurrentUser"' -f $Name, $versionArgument)
    }
    return $module
}
