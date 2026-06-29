<#
.SYNOPSIS
Tests Windows client build default define propagation.

.DESCRIPTION
Runs build-client.ps1 with fake Flutter and Cargo executables so the test can
verify --dart-define arguments, archive creation, and checksum generation
without compiling the real client.
#>

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("conductor-windows-build-defaults-" + [System.Guid]::NewGuid().ToString("N"))
$FakeBin = Join-Path $TempDir "bin"
$FlutterLog = Join-Path $TempDir "flutter.log"
$CargoLog = Join-Path $TempDir "cargo.log"
$OldPath = $env:PATH
$OldFlutterBin = $env:FLUTTER_BIN

function Write-TextFile($Path, $Value) {
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    Set-Content -Path $Path -Value $Value -Encoding ascii
}

function Require-LogLine($Path, $ExpectedText) {
    $Text = Get-Content $Path -Raw
    if ($Text -notmatch [regex]::Escape($ExpectedText)) {
        throw "Missing log line '$ExpectedText'. Actual: $Text"
    }
}

function Invoke-BuildClientWithExplicitDefaults {
    & (Join-Path $RootDir "scripts\build-client.ps1") `
        -ServerUrl "ws://example.test:8080/ws/agent" `
        -AgentToken "token with spaces" `
        -AgentName "windows build agent" `
        -AgentRoot "C:\Conductor Build Root" `
        -AudioInput "smoke audio input" `
        -InteractiveApproval "yes" `
        *> (Join-Path $TempDir "build-client.log")
}

function Invoke-BuildClientWithEnvironmentDefaults {
    & (Join-Path $RootDir "scripts\build-client.ps1") *> (Join-Path $TempDir "build-client-env.log")
}

try {
    New-Item -ItemType Directory -Force -Path $FakeBin | Out-Null

    $FakeFlutter = Join-Path $FakeBin "flutter.ps1"
    Set-Content -Path $FakeFlutter -Encoding ascii -Value @'
$ErrorActionPreference = "Stop"
("flutter`t" + ($args -join "`t")) | Add-Content -Path $env:FAKE_FLUTTER_LOG -Encoding ascii
'@

    $FakeCargo = Join-Path $FakeBin "cargo.cmd"
    Set-Content -Path $FakeCargo -Encoding ascii -Value @'
@echo off
setlocal enabledelayedexpansion
set "line=cargo"
:args
if "%~1"=="" goto done
set "line=!line!	%~1"
shift
goto args
:done
>>"%FAKE_CARGO_LOG%" echo !line!
exit /b 0
'@

    $env:PATH = "$FakeBin;$OldPath"
    $env:FLUTTER_BIN = $FakeFlutter
    $env:FAKE_FLUTTER_LOG = $FlutterLog
    $env:FAKE_CARGO_LOG = $CargoLog
    $FakeFfmpeg = Join-Path $FakeBin "ffmpeg.exe"
    $FakeFfplay = Join-Path $FakeBin "ffplay.exe"
    Write-TextFile $FakeFfmpeg "ffmpeg"
    Write-TextFile $FakeFfplay "ffplay"
    $env:FFMPEG_BIN = $FakeFfmpeg
    $env:FFPLAY_BIN = $FakeFfplay

    $AgentPath = Join-Path $RootDir "target\release\conductor-agent.exe"
    $BundleDir = Join-Path $RootDir "client\build\windows\x64\runner\Release"
    Write-TextFile $AgentPath "agent"
    Write-TextFile (Join-Path $BundleDir "conductor_client.exe") "client"
    Write-TextFile (Join-Path $BundleDir "flutter_windows.dll") "flutter"
    Write-TextFile (Join-Path $BundleDir "data\icudtl.dat") "icu"
    Write-TextFile (Join-Path $BundleDir "data\flutter_assets\AssetManifest.bin") "asset"

    Invoke-BuildClientWithExplicitDefaults

    Require-LogLine $FlutterLog "flutter`tconfig`t--enable-windows-desktop"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_SERVER_URL=ws://example.test:8080/ws/agent"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_AGENT_TOKEN=token with spaces"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_AGENT_NAME=windows build agent"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_AGENT_ROOT=C:\Conductor Build Root"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_AUDIO_INPUT=smoke audio input"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL=yes"

    Set-Content -Path $FlutterLog -Value "" -Encoding ascii
    $env:CONDUCTOR_DEFAULT_SERVER_URL = "wss://env.example.test/ws/agent"
    $env:CONDUCTOR_DEFAULT_AGENT_TOKEN = "env token"
    $env:CONDUCTOR_DEFAULT_AGENT_NAME = "env windows build agent"
    $env:CONDUCTOR_DEFAULT_AGENT_ROOT = "C:\Env Conductor Root"
    $env:CONDUCTOR_DEFAULT_AUDIO_INPUT = "env audio input"
    $env:CONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL = "off"

    Invoke-BuildClientWithEnvironmentDefaults

    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_SERVER_URL=wss://env.example.test/ws/agent"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_AGENT_TOKEN=env token"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_AGENT_NAME=env windows build agent"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_AGENT_ROOT=C:\Env Conductor Root"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_AUDIO_INPUT=env audio input"
    Require-LogLine $FlutterLog "--dart-define`tCONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL=off"

    $ArchivePath = Join-Path $RootDir "release\conductor-client-windows-x64.zip"
    $ArchiveChecksumPath = "$ArchivePath.sha256"
    if (!(Test-Path $ArchivePath)) {
        throw "Windows client archive was not created: $ArchivePath"
    }
    if (!(Test-Path $ArchiveChecksumPath)) {
        throw "Windows client archive checksum was not created: $ArchiveChecksumPath"
    }
    if (!(Test-Path (Join-Path $BundleDir "ffmpeg.exe"))) {
        throw "Bundled ffmpeg.exe was not created."
    }
    if (!(Test-Path (Join-Path $BundleDir "ffplay.exe"))) {
        throw "Bundled ffplay.exe was not created."
    }
    $ArchiveSha256 = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLowerInvariant()
    $SidecarSha256 = ((Get-Content $ArchiveChecksumPath -ErrorAction Stop | Select-Object -First 1) -split "\s+")[0].ToLowerInvariant()
    if ($ArchiveSha256 -ne $SidecarSha256) {
        throw "Windows client archive checksum mismatch. Archive: $ArchiveSha256 Sidecar: $SidecarSha256"
    }

    Write-Host "Windows build client defaults test passed."
} finally {
    $env:PATH = $OldPath
    if ([string]::IsNullOrEmpty($OldFlutterBin)) {
        Remove-Item Env:\FLUTTER_BIN -ErrorAction SilentlyContinue
    } else {
        $env:FLUTTER_BIN = $OldFlutterBin
    }
    Remove-Item Env:\CONDUCTOR_DEFAULT_SERVER_URL -ErrorAction SilentlyContinue
    Remove-Item Env:\CONDUCTOR_DEFAULT_AGENT_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\CONDUCTOR_DEFAULT_AGENT_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:\CONDUCTOR_DEFAULT_AGENT_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CONDUCTOR_DEFAULT_AUDIO_INPUT -ErrorAction SilentlyContinue
    Remove-Item Env:\CONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL -ErrorAction SilentlyContinue
    Remove-Item Env:\FFMPEG_BIN -ErrorAction SilentlyContinue
    Remove-Item Env:\FFPLAY_BIN -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
