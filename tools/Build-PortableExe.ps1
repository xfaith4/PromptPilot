#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = '',
    [string]$OutputBaseName = 'Prompt_Pilot',
    [switch]$SkipTests,
    [string]$CertificateThumbprint = ''
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Build the portable app on Windows.' }
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'PromptPilot.Core.ps1')
$product = Read-PilotJson (Join-Path $root 'data/product.json')
if (-not $OutputRoot) { $OutputRoot = Join-Path $root 'dist' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$null = [IO.Directory]::CreateDirectory($OutputRoot)
if ($OutputBaseName -notmatch '^[A-Za-z0-9_-]+$') { throw 'OutputBaseName must be a simple file name.' }
. (Join-Path $PSScriptRoot 'Pilot.BuildTools.ps1')
$module = Resolve-PilotBuildModule -Name ps2exe -RequiredVersion ([version]$product.ps2exeVersion)
Write-Host ('Build compiler: ps2exe {0} | {1}' -f $module.Version, $module.Path)
Import-Module $module.Path -Force
$testEvidence = @{ Status = 'Skipped'; Note = 'Caller must supply matching Windows test evidence.' }
if (-not $SkipTests) {
    $pesterModule = Resolve-PilotBuildModule -Name Pester -MinimumVersion ([version]'5.0')
    Write-Host ('Build tests: Pester {0} | {1}' -f $pesterModule.Version, $pesterModule.Path)
    $testRunspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $testRunspace.ApartmentState = 'STA'
    $testRunspace.Open()
    $testPipeline = [Management.Automation.PowerShell]::Create()
    $testPipeline.Runspace = $testRunspace
    try {
        $null = $testPipeline.AddScript({
            param($Path, $PesterPath)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            Import-Module -Name $PesterPath -Force -ErrorAction Stop
            $result = Invoke-Pester -Path $Path -PassThru -Output Normal
            [pscustomobject]@{ Passed = $result.PassedCount; Failed = ($result.FailedCount + $result.FailedContainersCount + $result.FailedBlocksCount); FailedItems = @($result.Failed | ForEach-Object { $_.ExpandedName + ': ' + $_.ErrorRecord }) }
        }).AddArgument((Join-Path $root 'tests')).AddArgument($pesterModule.Path)
        $testResults = @($testPipeline.Invoke())
        if ($testPipeline.HadErrors -or -not $testResults.Count) { throw ('Windows test execution failed: ' + (@($testPipeline.Streams.Error) -join '; ')) }
        $testSummary = $testResults[-1]
        if ($testSummary.Failed -or $testSummary.Passed -lt 1) { throw ('The Windows regression suite failed: ' + ($testSummary.FailedItems -join '; ')) }
        $testEvidence = @{ Status = 'Passed'; Passed = $testSummary.Passed; Failed = $testSummary.Failed }
        Write-Host ('Windows regression suite: {0} passed, {1} failed.' -f $testSummary.Passed, $testSummary.Failed)
    }
    finally { $testPipeline.Dispose(); $testRunspace.Dispose() }
}

$stage = Join-Path $OutputRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($stage)
try {
    $exe = Join-Path $stage 'Prompt_Pilot.exe'
    Invoke-PS2EXE -inputFile (Join-Path $root 'Prompt_Pilot.Wpf.ps1') -outputFile $exe -title 'Prompt Pilot' -description 'Refine coding-agent prompts and preserve your work.' -product 'Prompt Pilot' -company 'Prompt Pilot contributors' -version $product.fileVersion -STA -noConsole -DPIAware -supportOS -x64 -iconFile (Join-Path $root 'assets/prompt-pilot.ico') | Out-Host
    foreach ($file in @('PromptPilot.Core.ps1', 'PromptPilot.Models.ps1', 'PromptPilot.ModelWindow.ps1', 'Prompt_Pilot.Models.xaml', 'Prompt_Pilot.MainWindow.xaml', 'Start Prompt Pilot.cmd', 'Start-PromptPilot.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md', 'ROADMAP.md')) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $stage $file) }
    foreach ($directory in @('data', 'assets', 'evaluations')) { Copy-Item -LiteralPath (Join-Path $root $directory) -Destination (Join-Path $stage $directory) -Recurse }
    $null = [IO.Directory]::CreateDirectory((Join-Path $stage 'docs'))
    foreach ($file in @('PRIVACY.md', 'RELEASE.md', 'VALIDATION.md', 'MODEL-MANAGEMENT.md', 'example-session.png', 'model-recommendations.png')) { Copy-Item -LiteralPath (Join-Path $root ('docs/' + $file)) -Destination (Join-Path $stage ('docs/' + $file)) }
    $null = [IO.Directory]::CreateDirectory((Join-Path $stage 'tools'))
    foreach ($file in @('Check-ModelUpdates.ps1','Compare-Models.ps1','Install-ModelCheckTask.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $stage ('tools/' + $file)) }
    $signature = 'NotSigned'
    if ($CertificateThumbprint) {
        $certificate = Get-Item -LiteralPath ('Cert:/CurrentUser/My/' + $CertificateThumbprint)
        if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -lt (Get-Date)) { throw 'The signing certificate is expired or has no private key.' }
        $signed = Set-AuthenticodeSignature -FilePath $exe -Certificate $certificate -TimestampServer 'http://timestamp.digicert.com'
        if ($signed.Status -ne 'Valid') { throw ('Code signing failed: ' + $signed.StatusMessage) }
        $signature = 'Valid'
    }
    $validationDir = Join-Path $root ('build/package-smoke-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($validationDir)
    $reportPath = Join-Path $validationDir 'smoke.json'
    $dataDir = Join-Path $validationDir 'data'
    $arguments = @('-SmokeTest', '-DataDirectory', ('"' + $dataDir + '"'), '-SmokeReportPath', ('"' + $reportPath + '"'))
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $validationDir -PassThru
    if (-not $process.WaitForExit(30000)) { Stop-Process -Id $process.Id -Force; throw 'The isolated packaged-app smoke timed out.' }
    if (-not (Test-Path -LiteralPath $reportPath)) { throw 'The packaged app did not create its startup report.' }
    $smoke = Read-PilotJson $reportPath
    if ($smoke.Error -or -not $smoke.Logging -or $smoke.Controls -lt 50 -or $smoke.Version -ne $product.version) { throw ('Packaged-app smoke failed: ' + $smoke.Error) }
    if (Test-Path -LiteralPath (Join-Path $stage 'logs')) { Remove-Item -LiteralPath (Join-Path $stage 'logs') -Recurse -Force }
    $manifest = @{ Product = $product.name; Version = $product.version; FileVersion = $product.fileVersion; BuiltAtUtc = [DateTime]::UtcNow.ToString('o'); PowerShell = $PSVersionTable.PSVersion.ToString(); BuildTool = ('ps2exe ' + $product.ps2exeVersion); EntryExe = 'Prompt_Pilot.exe'; SourceSha256 = (Get-FileHash -LiteralPath (Join-Path $root 'Prompt_Pilot.Wpf.ps1') -Algorithm SHA256).Hash.ToLowerInvariant(); WindowsTests = $testEvidence; SigningStatus = $signature; PackagedStartupSmoke = 'Passed'; SmokeEvidence = 'Build-local package-smoke report, retained in the source build directory and CI artifact'; Files = @() }
    foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName) { $manifest.Files += @{ Path = $file.FullName.Substring($stage.Length + 1).Replace([IO.Path]::DirectorySeparatorChar, [char]'/'); Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } }
    Write-PilotJson (Join-Path $stage 'package.json') $manifest
    $checksums = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.FullName.Substring($stage.Length + 1).Replace([IO.Path]::DirectorySeparatorChar, [char]'/') })
    [IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS.txt'), [string[]]$checksums, [Text.UTF8Encoding]::new($false))
    $destination = Join-Path $OutputRoot $OutputBaseName
    if (Test-Path -LiteralPath $destination) { Move-Item -LiteralPath $destination -Destination ($destination + '.previous-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')) }
    Move-Item -LiteralPath $stage -Destination $destination
    $zip = Join-Path $OutputRoot ($OutputBaseName + '-' + $product.version + '-win-x64.zip')
    Compress-Archive -Path (Join-Path $destination '*') -DestinationPath $zip -Force
    [IO.File]::WriteAllText(($zip + '.sha256'), ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($zip)), [Text.UTF8Encoding]::new($false))
    Write-Host ('Portable artifact verified: ' + $zip)
    Write-Host ('Signing: ' + $signature + '; packaged startup: Passed; clean-machine/beta acceptance remains in ROADMAP.md.')
}
finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
