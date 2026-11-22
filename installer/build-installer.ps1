[CmdletBinding()]
param(
    # Which build to package; 'auto' lets stage-payload.ps1 pick the one this
    # machine just produced. The name of the installer follows, because the
    # x64 and Arm64 setups sit side by side on a release.
    [ValidateSet('auto', 'x64', 'arm64')]
    [string]$Architecture = 'auto'
)

$ErrorActionPreference = 'Stop'

$installerDir = $PSScriptRoot
$issPath = Join-Path $installerDir 'setup.iss'
if ($Architecture -eq 'auto') {
    # Resolve the same way stage-payload.ps1 does, so the installer's
    # ArchitecturesAllowed describes the payload it actually stages; the two
    # disagreeing would produce an Arm64 payload behind an x64compatible
    # header, which installs and then cannot start.
    $repoRootPath = Split-Path -Parent $installerDir
    $hostArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $preferred = if ($hostArch -eq 'ARM64') { @('arm64', 'x64') } else { @('x64', 'arm64') }
    $targetArch = $preferred |
        Where-Object { Test-Path (Join-Path $repoRootPath "build\windows\$_\runner\Release") } |
        Select-Object -First 1
    # The legacy flat build directory predates the per-architecture ones and is
    # always an x64 build.
    if (-not $targetArch) { $targetArch = 'x64' }
} else {
    $targetArch = $Architecture
}
$outputName = if ($targetArch -eq 'arm64') { 'wsl2-distro-manager-setup-arm64.exe' } else { 'wsl2-distro-manager-setup.exe' }
$outputPath = Join-Path $installerDir $outputName
$pubspecPath = Join-Path (Split-Path -Parent $installerDir) 'pubspec.yaml'
$codeDependenciesPath = Join-Path $installerDir 'CodeDependencies.iss'
$codeDependenciesUrl = 'https://raw.githubusercontent.com/DomGries/InnoDependencyInstaller/master/CodeDependencies.iss'
$codeDependenciesSha256 = 'D57E218B36CB77D7A83F0558B3C13C391585AEA92F560CF9FDFEDBC87FAE5D10'

if (-not (Test-Path $issPath)) {
    throw "Inno Setup script not found: $issPath"
}

if (-not (Test-Path $pubspecPath)) {
    throw "pubspec.yaml not found: $pubspecPath"
}

if (-not (Test-Path $codeDependenciesPath)) {
    Write-Host 'Downloading CodeDependencies.iss for InnoDependencyInstaller...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $codeDependenciesUrl -OutFile $codeDependenciesPath
}

$actualCodeDependenciesSha256 = (Get-FileHash $codeDependenciesPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actualCodeDependenciesSha256 -ne $codeDependenciesSha256) {
    throw "CodeDependencies.iss checksum mismatch. Expected $codeDependenciesSha256 but got $actualCodeDependenciesSha256"
}

$pubspec = Get-Content $pubspecPath -Raw
$versionMatch = [regex]::Match($pubspec, 'version:\s*([^\s#]+)')
if (-not $versionMatch.Success) {
    throw 'Could not parse version from pubspec.yaml.'
}
$appVersion = $versionMatch.Groups[1].Value

$iscc = (Get-Command iscc -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
if (-not $iscc) {
    $regInstallLocation = $null
    $regPaths = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1'
    )
    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            $regInstallLocation = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).InstallLocation
            if ($regInstallLocation) { break }
        }
    }

    $isccCandidates = @(
        ($(if ($regInstallLocation) { Join-Path $regInstallLocation 'ISCC.exe' })),
        ($(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe' })),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    $iscc = $isccCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

if (-not $iscc) {
    throw 'Inno Setup compiler (ISCC.exe) was not found. Install Inno Setup 6 and retry.'
}

& (Join-Path $installerDir 'stage-payload.ps1') -Architecture $Architecture

if (Test-Path $outputPath) {
    Remove-Item $outputPath -Force
}

$isccOutput = & $iscc "/DAppVersion=$appVersion" "/DTargetArch=$targetArch" $issPath 2>&1
$isccExitCode = $LASTEXITCODE
if ($isccExitCode -ne 0) {
    if ($isccOutput) {
        $isccOutput | Out-Host
    }
    throw "Inno Setup compilation failed with exit code $isccExitCode."
}

if (-not (Test-Path $outputPath)) {
    throw "Installer build did not produce: $outputPath"
}

Write-Host "Installer created: $outputPath"