[CmdletBinding()]
param(
    # Which build to package. 'auto' keeps the historical search order and, on
    # an Arm64 machine, looks for the native build first — a WoA developer who
    # just ran `flutter build windows` has no x64 directory to find.
    [ValidateSet('auto', 'x64', 'arm64')]
    [string]$Architecture = 'auto'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$payloadDir = Join-Path $PSScriptRoot 'payload'

function Get-BuildDirForArchitecture([string]$arch) {
    Join-Path $repoRoot "build\windows\$arch\runner\Release"
}

if ($Architecture -eq 'auto') {
    # PROCESSOR_ARCHITEW6432 is set only for a 32-bit-or-emulated process on a
    # 64-bit host, and it is the one that tells the truth there; PowerShell
    # itself may well be running under emulation on an Arm64 box.
    $hostArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $preferred = if ($hostArch -eq 'ARM64') { @('arm64', 'x64') } else { @('x64', 'arm64') }

    $candidateBuildDirs = @(
        ($preferred | ForEach-Object { Get-BuildDirForArchitecture $_ })
        (Join-Path $repoRoot 'build\windows\runner\Release')
    )

    $buildDir = $candidateBuildDirs | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $buildDir) {
        throw 'No Windows release build directory was found.'
    }
} else {
    # An explicit architecture never falls back: a release job that asked for
    # arm64 and quietly packaged the x64 build would ship an installer whose
    # name is the only Arm64 thing about it.
    $buildDir = Get-BuildDirForArchitecture $Architecture
    if (-not (Test-Path $buildDir)) {
        throw "No $Architecture Windows release build directory was found at $buildDir."
    }
}

New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
Get-ChildItem -Path $payloadDir -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('.gitkeep', '.gitignore') } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item -Path (Join-Path $buildDir '*') -Destination $payloadDir -Recurse -Force

Write-Host "Staged installer payload from $buildDir to $payloadDir"
