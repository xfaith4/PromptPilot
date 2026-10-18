BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Pilot.BuildTools.ps1')
    function New-BuildToolFixture {
        param([string]$Root, [string]$Name, [string]$Version)
        $directory = Join-Path $Root (Join-Path $Name $Version)
        $null = [IO.Directory]::CreateDirectory($directory)
        $manifest = Join-Path $directory ($Name + '.psd1')
        [IO.File]::WriteAllText($manifest, ("@{{ ModuleVersion = '{0}'; GUID = '{1}'; PowerShellVersion = '5.1'; FunctionsToExport = @() }}" -f $Version, [guid]::NewGuid()))
        return $manifest
    }
}
Describe 'Build tools installed for a different PowerShell host' {
    It 'finds the pinned compiler in a redirected PowerShell user folder despite a newer version' {
        $directory = Join-Path $TestDrive 'OneDrive/Documents/PowerShell/Modules'
        $expected = New-BuildToolFixture $directory ps2exe '1.0.17'
        $null = New-BuildToolFixture $directory ps2exe '1.0.18'
        $oldPath = $env:PSModulePath
        $module = Resolve-PilotBuildModule ps2exe -RequiredVersion '1.0.17' -SearchRoots @((Join-Path $TestDrive 'Documents/WindowsPowerShell/Modules'), $directory)
        $module.Path | Should -Be $expected
        $module.Version | Should -Be ([version]'1.0.17')
        $env:PSModulePath | Should -Be $oldPath
    }
    It 'does not silently substitute a newer compiler and names the correct installation host' {
        $directory = Join-Path $TestDrive 'newer-only'
        $null = New-BuildToolFixture $directory ps2exe '1.0.18'
        { Resolve-PilotBuildModule ps2exe -RequiredVersion '1.0.17' -SearchRoots @($directory) } | Should -Throw '*powershell.exe -NoProfile -Command "Install-Module ps2exe -RequiredVersion 1.0.17 -Scope CurrentUser"*'
    }
    It 'resolves a compatible Pester manifest for explicit import into the test runspace' {
        $directory = Join-Path $TestDrive 'Pester-folder'
        $null = New-BuildToolFixture $directory Pester '4.10.1'
        $expected = New-BuildToolFixture $directory Pester '5.7.1'
        $module = Resolve-PilotBuildModule Pester -MinimumVersion '5.0' -SearchRoots @($directory)
        $module.Path | Should -Be $expected
    }
}
