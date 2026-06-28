<#
.SYNOPSIS
Tests the Windows client archive verifier with synthetic archives.

.DESCRIPTION
Creates a minimal Windows client zip, verifies the checksum success path, and
checks that missing checksum, mismatched checksum, and missing archive entries
are rejected.
#>

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("conductor-windows-archive-test-" + [System.Guid]::NewGuid().ToString("N"))
$ArchivePath = Join-Path $TempDir "conductor-client-windows-x64.zip"
$StageDir = Join-Path $TempDir "stage"
$FailureLog = Join-Path $TempDir "failure.log"

function Write-TextFile($Path, $Value) {
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    Set-Content -Path $Path -Value $Value -Encoding ascii
}

function Write-ArchiveChecksum($Path) {
    $Hash = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
    $Name = Split-Path -Leaf $Path
    Set-Content -Path "$Path.sha256" -Value "$Hash  $Name" -Encoding ascii
}

function Invoke-ExpectedFailure($ExpectedText, [scriptblock] $Command) {
    try {
        & $Command *> $FailureLog
    } catch {
        $_ | Out-String | Add-Content -Path $FailureLog
        $Text = Get-Content $FailureLog -Raw
        if ($Text -notmatch [regex]::Escape($ExpectedText)) {
            throw "Failure did not contain expected text '$ExpectedText'. Actual: $Text"
        }
        return
    }
    throw "Expected command to fail: $ExpectedText"
}

try {
    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
    Write-TextFile (Join-Path $StageDir "conductor_client.exe") "client"
    Write-TextFile (Join-Path $StageDir "conductor-agent.exe") "agent"
    Write-TextFile (Join-Path $StageDir "flutter_windows.dll") "flutter"
    Write-TextFile (Join-Path $StageDir "data\icudtl.dat") "icu"
    Write-TextFile (Join-Path $StageDir "data\flutter_assets\AssetManifest.bin") "asset"
    Write-TextFile (Join-Path $StageDir "data\flutter_assets\FontManifest.json") "font"
    Write-TextFile (Join-Path $StageDir "data\flutter_assets\NativeAssetsManifest.json") "native"
    Write-TextFile (Join-Path $StageDir "data\flutter_assets\version.json") "version"

    Compress-Archive -Path (Join-Path $StageDir "*") -DestinationPath $ArchivePath
    Write-ArchiveChecksum $ArchivePath

    & (Join-Path $RootDir "scripts\verify-client-archive.ps1") -ArchivePath $ArchivePath

    Rename-Item -Path "$ArchivePath.sha256" -NewName "conductor-client-windows-x64.zip.sha256.bak"
    Invoke-ExpectedFailure "Archive checksum not found" {
        & (Join-Path $RootDir "scripts\verify-client-archive.ps1") -ArchivePath $ArchivePath
    }
    Rename-Item -Path "$ArchivePath.sha256.bak" -NewName "conductor-client-windows-x64.zip.sha256"

    Set-Content -Path "$ArchivePath.sha256" -Value ("0" * 64 + "  conductor-client-windows-x64.zip") -Encoding ascii
    Invoke-ExpectedFailure "Archive checksum mismatch" {
        & (Join-Path $RootDir "scripts\verify-client-archive.ps1") -ArchivePath $ArchivePath
    }

    Write-ArchiveChecksum $ArchivePath
    Remove-Item -Force (Join-Path $StageDir "data\flutter_assets\FontManifest.json")
    Remove-Item -Force $ArchivePath
    Remove-Item -Force "$ArchivePath.sha256"
    Compress-Archive -Path (Join-Path $StageDir "*") -DestinationPath $ArchivePath
    Write-ArchiveChecksum $ArchivePath
    Invoke-ExpectedFailure "Missing archive entry" {
        & (Join-Path $RootDir "scripts\verify-client-archive.ps1") -ArchivePath $ArchivePath
    }

    Write-Host "Windows client archive checksum test passed."
} finally {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
