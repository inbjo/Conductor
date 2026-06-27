<#
.SYNOPSIS
Verifies Windows client smoke evidence.

.DESCRIPTION
Checks validation-summary.txt and smoke-windows-client-flow.log for required
fields, successful result, expected commit, toolchain records, success marker,
and archive SHA256 when the archive is still present.

.PARAMETER EvidenceDir
Directory containing validation-summary.txt and smoke-windows-client-flow.log.

.PARAMETER RequireCiFields
Require CI-only evidence fields such as runner_os and runner_arch.

.PARAMETER ExpectedCommit
Require the evidence commit field to match this SHA.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\verify-windows-smoke-evidence.ps1 -EvidenceDir .\artifacts\windows-client-smoke
#>
param(
    [string] $EvidenceDir = ".\artifacts\windows-client-smoke",

    [switch] $RequireCiFields,

    [string] $ExpectedCommit = ""
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([System.IO.Path]::IsPathRooted($EvidenceDir)) {
    $EvidenceFullPath = $EvidenceDir
} else {
    $EvidenceFullPath = Join-Path $RootDir $EvidenceDir
}

$SummaryPath = Join-Path $EvidenceFullPath "validation-summary.txt"
$LogPath = Join-Path $EvidenceFullPath "smoke-windows-client-flow.log"
$AgentE2eServerLog = Join-Path $EvidenceFullPath "logs\agent-e2e\server.log"
$AgentE2eAgentLog = Join-Path $EvidenceFullPath "logs\agent-e2e\agent.log"
$ClientE2eServerLog = Join-Path $EvidenceFullPath "logs\client-e2e\server.log"
$ClientE2eClientLog = Join-Path $EvidenceFullPath "logs\client-e2e\client.log"
$ClientE2eSettingsFile = Join-Path $EvidenceFullPath "logs\client-e2e\client-settings.json"

if (!(Test-Path $SummaryPath)) {
    Write-Error "Missing Windows smoke evidence summary: $SummaryPath"
}
if (!(Test-Path $LogPath)) {
    Write-Error "Missing Windows smoke transcript: $LogPath"
}
foreach ($path in @($AgentE2eServerLog, $AgentE2eAgentLog, $ClientE2eServerLog, $ClientE2eClientLog, $ClientE2eSettingsFile)) {
    if (!(Test-Path $path)) {
        Write-Error "Missing Windows e2e raw log: $path"
    }
}

$SummaryLines = Get-Content $SummaryPath
$Summary = @{}
foreach ($line in $SummaryLines) {
    $separator = $line.IndexOf("=")
    if ($separator -le 0) {
        continue
    }
    $key = $line.Substring(0, $separator)
    $value = $line.Substring($separator + 1)
    $Summary[$key] = $value
}

$RequiredKeys = @(
    "timestamp",
    "repository",
    "archive",
    "commit",
    "powershell",
    "rustc",
    "cargo",
    "flutter",
    "archive_sha256",
    "result"
)

foreach ($key in $RequiredKeys) {
    if (!$Summary.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($Summary[$key])) {
        Write-Error "Missing Windows smoke evidence field: $key"
    }
}

if ($RequireCiFields) {
    foreach ($key in @("runner_os", "runner_arch")) {
        if (!$Summary.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($Summary[$key])) {
            Write-Error "Missing Windows CI smoke evidence field: $key"
        }
    }
}

if (![string]::IsNullOrWhiteSpace($ExpectedCommit)) {
    $ActualCommit = $Summary["commit"]
    if ($ActualCommit -ne $ExpectedCommit) {
        Write-Error "Windows smoke evidence commit mismatch. Expected: $ExpectedCommit Actual: $ActualCommit"
    }
}

foreach ($key in @("rustc", "cargo", "flutter")) {
    if ($Summary[$key] -eq "not found") {
        Write-Error "Windows smoke evidence reports missing tool: $key"
    }
}

$Result = $Summary["result"]
if ($Result -ne "passed") {
    Write-Error "Windows smoke evidence result is not passed: $Result"
}

$ArchiveSha256 = $Summary["archive_sha256"]
if ($ArchiveSha256 -notmatch "^[a-f0-9]{64}$") {
    Write-Error "Windows smoke evidence archive_sha256 is invalid: $ArchiveSha256"
}

$ArchivePath = $Summary["archive"]
if (Test-Path $ArchivePath) {
    $ActualArchiveSha256 = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLowerInvariant()
    if ($ActualArchiveSha256 -ne $ArchiveSha256) {
        Write-Error "Windows smoke evidence archive hash mismatch. Summary: $ArchiveSha256 Actual: $ActualArchiveSha256"
    }
    $ArchiveChecksumPath = "$ArchivePath.sha256"
    if (!(Test-Path $ArchiveChecksumPath)) {
        Write-Error "Windows smoke evidence archive checksum sidecar is missing: $ArchiveChecksumPath"
    }
    $SidecarSha256 = ((Get-Content $ArchiveChecksumPath -ErrorAction Stop | Select-Object -First 1) -split "\s+")[0].ToLowerInvariant()
    if ($SidecarSha256 -ne $ArchiveSha256) {
        Write-Error "Windows smoke evidence archive sidecar hash mismatch. Summary: $ArchiveSha256 Sidecar: $SidecarSha256"
    }
} else {
    Write-Host "Windows smoke archive is not present for hash recheck: $ArchivePath"
}

$LogText = Get-Content $LogPath -Raw
if ($LogText -notmatch "Windows client flow smoke passed") {
    Write-Error "Windows smoke transcript does not contain the success marker."
}
if ($LogText -notmatch "Agent config log observed") {
    Write-Error "Windows smoke transcript does not prove client-to-agent runtime config propagation."
}
if ($LogText -notmatch "Agent diagnostics observed") {
    Write-Error "Windows smoke transcript does not prove diagnostics command execution."
}

$AgentLogText = Get-Content $AgentE2eAgentLog -Raw
if ($AgentLogText -notmatch "agent config ") {
    Write-Error "Windows bundled agent e2e log does not contain the agent config line."
}
$ClientLogText = Get-Content $ClientE2eClientLog -Raw
if ($ClientLogText -notmatch "agent config ") {
    Write-Error "Windows client e2e log does not contain the agent config line."
}
if ($ClientLogText -notmatch "agent config .*root=.*agent-root .*audio_input=smoke-audio-input") {
    Write-Error "Windows client e2e log does not prove file root and audio input propagation."
}
if ($ClientLogText -notmatch "\[diagnostics\] conductor-agent") {
    Write-Error "Windows client e2e log does not contain diagnostics output."
}

$ClientSettings = Get-Content $ClientE2eSettingsFile -Raw | ConvertFrom-Json
if ($ClientSettings.serverUrl -notmatch "^ws://127\.0\.0\.1:\d+/ws/agent$") {
    Write-Error "Windows client e2e settings file does not contain the normalized serverUrl: $($ClientSettings.serverUrl)"
}
if ($ClientSettings.agentName -notmatch "^windows-client-e2e-") {
    Write-Error "Windows client e2e settings file does not contain the expected agentName: $($ClientSettings.agentName)"
}
if ($ClientSettings.agentRoot -notmatch "[/\\]agent-root$") {
    Write-Error "Windows client e2e settings file does not contain the expected agentRoot: $($ClientSettings.agentRoot)"
}
if ($ClientSettings.audioInput -ne "smoke-audio-input") {
    Write-Error "Windows client e2e settings file does not contain the expected audioInput: $($ClientSettings.audioInput)"
}
if ($ClientSettings.interactiveApproval -ne $false) {
    Write-Error "Windows client e2e settings file does not contain interactiveApproval=false."
}

Write-Host "Windows smoke evidence verified: $EvidenceFullPath"
