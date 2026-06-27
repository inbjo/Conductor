<#
.SYNOPSIS
Builds the Windows controlled desktop client package.

.DESCRIPTION
Builds the Rust conductor-agent.exe and Flutter Windows client, copies the agent
into the Flutter bundle, and creates release\conductor-client-windows-x64.zip.
Default client settings can be baked in through parameters or
CONDUCTOR_DEFAULT_* environment variables.

.PARAMETER ServerUrl
Default Server URL baked into the client.

.PARAMETER AgentToken
Default Agent Token baked into the client.

.PARAMETER AgentName
Default Agent Name baked into the client.

.PARAMETER AgentRoot
Default file root baked into the client.

.PARAMETER AudioInput
Default audio input baked into the client.

.PARAMETER InteractiveApproval
Default local approval setting baked into the client. Accepted values:
1, 0, true, false, yes, no, on, off.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -ServerUrl "ws://server:8080/ws/agent" -AgentToken "token" -AgentName "windows-client-01"
#>
param(
    [string] $ServerUrl = $env:CONDUCTOR_DEFAULT_SERVER_URL,

    [string] $AgentToken = $env:CONDUCTOR_DEFAULT_AGENT_TOKEN,

    [string] $AgentName = $env:CONDUCTOR_DEFAULT_AGENT_NAME,

    [string] $AgentRoot = $env:CONDUCTOR_DEFAULT_AGENT_ROOT,

    [string] $AudioInput = $env:CONDUCTOR_DEFAULT_AUDIO_INPUT,

    [string] $InteractiveApproval = $env:CONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$ReleaseDir = Join-Path $RootDir "release"
$FlutterBin = $env:FLUTTER_BIN
if ([string]::IsNullOrWhiteSpace($FlutterBin)) {
    $FlutterBin = Join-Path $env:USERPROFILE "Code\flutter\bin\flutter.bat"
}

function Require-Command($Name, $InstallHint) {
    if (!(Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Error "$Name not found. $InstallHint"
    }
}

function Test-BoolText($Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $true
    }
    return $Value.Trim().ToLowerInvariant() -in @("1", "0", "true", "false", "yes", "no", "on", "off")
}

if (!(Test-BoolText $InteractiveApproval)) {
    Write-Error "Invalid InteractiveApproval value: $InteractiveApproval. Use one of: 1, 0, true, false, yes, no, on, off."
}

if (!(Test-Path $FlutterBin)) {
    Write-Error "Flutter executable not found: $FlutterBin. Set FLUTTER_BIN and retry."
}

$AgentBin = Join-Path $RootDir "target\release\conductor-agent.exe"
$BundleDir = Join-Path $RootDir "client\build\windows\x64\runner\Release"
$BundleAgent = Join-Path $BundleDir "conductor-agent.exe"
$ArchivePath = Join-Path $ReleaseDir "conductor-client-windows-x64.zip"

Write-Host "[1/5] Checking Windows client build environment"
Require-Command "cargo" "Install Rust stable MSVC from https://rustup.rs/"
Require-Command "git" "Install Git for Windows."
& $FlutterBin config --enable-windows-desktop
& $FlutterBin doctor -v

Write-Host "[2/5] Building Rust agent"
cargo build --manifest-path (Join-Path $RootDir "Cargo.toml") --release -p conductor-agent

Write-Host "[3/5] Building Flutter client for windows"
$FlutterDefines = @()
if (![string]::IsNullOrWhiteSpace($ServerUrl)) {
    $FlutterDefines += @("--dart-define", "CONDUCTOR_DEFAULT_SERVER_URL=$ServerUrl")
}
if (![string]::IsNullOrWhiteSpace($AgentToken)) {
    $FlutterDefines += @("--dart-define", "CONDUCTOR_DEFAULT_AGENT_TOKEN=$AgentToken")
}
if (![string]::IsNullOrWhiteSpace($AgentName)) {
    $FlutterDefines += @("--dart-define", "CONDUCTOR_DEFAULT_AGENT_NAME=$AgentName")
}
if (![string]::IsNullOrWhiteSpace($AgentRoot)) {
    $FlutterDefines += @("--dart-define", "CONDUCTOR_DEFAULT_AGENT_ROOT=$AgentRoot")
}
if (![string]::IsNullOrWhiteSpace($AudioInput)) {
    $FlutterDefines += @("--dart-define", "CONDUCTOR_DEFAULT_AUDIO_INPUT=$AudioInput")
}
if (![string]::IsNullOrWhiteSpace($InteractiveApproval)) {
    $FlutterDefines += @(
        "--dart-define",
        "CONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL=$InteractiveApproval"
    )
}
Push-Location (Join-Path $RootDir "client")
try {
    & $FlutterBin build windows --release @FlutterDefines
} finally {
    Pop-Location
}

Write-Host "[4/5] Copying agent into client bundle"
New-Item -ItemType Directory -Force -Path $BundleDir | Out-Null
Copy-Item -Force $AgentBin $BundleAgent

Write-Host "[5/5] Creating distributable archive"
New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null
if (Test-Path $ArchivePath) {
    Remove-Item -Force $ArchivePath
}
Compress-Archive -Path (Join-Path $BundleDir "*") -DestinationPath $ArchivePath

Write-Host "Client bundle ready: $BundleDir"
Write-Host "Agent binary copied to: $BundleAgent"
Write-Host "Archive ready: $ArchivePath"
