param(
    [string] $ArchivePath = ".\release\conductor-client-windows-x64.zip",

    [switch] $SkipClientBuild,

    [switch] $SkipServerBuild
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([System.IO.Path]::IsPathRooted($ArchivePath)) {
    $ArchiveFullPath = $ArchivePath
} else {
    $ArchiveFullPath = Join-Path $RootDir $ArchivePath
}

function Invoke-Step($Name, [scriptblock] $Command) {
    Write-Host ""
    Write-Host "==> $Name"
    & $Command
}

Push-Location $RootDir
try {
    Write-Host "Windows client flow smoke"
    Write-Host "Repository: $RootDir"
    Write-Host "Archive: $ArchiveFullPath"
    Write-Host "SkipClientBuild: $SkipClientBuild"
    Write-Host "SkipServerBuild: $SkipServerBuild"

    if (!$SkipClientBuild) {
        Invoke-Step "Build Windows client package" {
            & .\scripts\build-client.ps1
        }
    }

    if (!$SkipServerBuild) {
        Invoke-Step "Build web assets" {
            npm --prefix web ci
            npm --prefix web run build
        }
        Invoke-Step "Build smoke server" {
            cargo build -p conductor-server
        }
    }

    if (!(Test-Path $ArchiveFullPath)) {
        Write-Error "Windows client archive not found: $ArchiveFullPath. Run without -SkipClientBuild or build the package first."
    }
    if (!(Test-Path ".\target\debug\conductor-server.exe")) {
        Write-Error "Smoke server not found: .\target\debug\conductor-server.exe. Run without -SkipServerBuild or build the server first."
    }

    Invoke-Step "Verify Windows client archive" {
        & .\scripts\verify-client-archive.ps1 -ArchivePath $ArchiveFullPath
    }
    Invoke-Step "Smoke launch bundled Windows agent" {
        & .\scripts\smoke-agent-launch.ps1 -ArchivePath $ArchiveFullPath
    }
    Invoke-Step "Smoke register bundled Windows agent" {
        & .\scripts\smoke-windows-agent-e2e.ps1 -ArchivePath $ArchiveFullPath
    }
    Invoke-Step "Smoke register through Windows client" {
        & .\scripts\smoke-windows-client-e2e.ps1 -ArchivePath $ArchiveFullPath
    }
    Invoke-Step "Smoke launch Windows client" {
        & .\scripts\smoke-client-launch.ps1 -ArchivePath $ArchiveFullPath
    }

    Write-Host ""
    Write-Host "Windows client flow smoke passed: $ArchiveFullPath"
} finally {
    Pop-Location
}
