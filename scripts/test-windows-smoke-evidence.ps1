<#
.SYNOPSIS
Tests the Windows smoke evidence verifier with synthetic evidence.

.DESCRIPTION
Creates minimal Windows smoke evidence, verifies the success path, and checks
that a missing evidence archive checksum sidecar is rejected.
#>

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("conductor-windows-evidence-test-" + [System.Guid]::NewGuid().ToString("N"))
$EvidenceDir = Join-Path $TempDir "windows-client-smoke"
$ArchivePath = Join-Path $TempDir "conductor-client-windows-x64.zip"
$FailureLog = Join-Path $TempDir "failure.log"
$Commit = "test-windows-smoke-evidence-commit"

function Write-TextFile($Path, $Value) {
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    Set-Content -Path $Path -Value $Value -Encoding ascii
}

function Write-ArchiveChecksum($Path) {
    $Hash = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
    $Name = Split-Path -Leaf $Path
    Set-Content -Path "$Path.sha256" -Value "$Hash  $Name" -Encoding ascii
    return $Hash
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
    New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
    Write-TextFile $ArchivePath "synthetic windows client archive"
    $ArchiveSha256 = Write-ArchiveChecksum $ArchivePath
    Copy-Item -Force -Path "$ArchivePath.sha256" -Destination (Join-Path $EvidenceDir ((Split-Path -Leaf $ArchivePath) + ".sha256"))

    Write-TextFile (Join-Path $EvidenceDir "validation-summary.txt") @"
timestamp=2026-06-28T00:00:00Z
repository=$RootDir
archive=$ArchivePath
commit=$Commit
runner_os=Windows
runner_arch=X64
powershell=PowerShell 7
rustc=rustc 1
cargo=cargo 1
flutter=Flutter 3
archive_sha256=$ArchiveSha256
result=passed
"@
    Write-TextFile (Join-Path $EvidenceDir "smoke-windows-client-flow.log") @"
Windows client flow smoke passed
Agent config log observed
Agent diagnostics observed
"@
    Write-TextFile (Join-Path $EvidenceDir "logs\agent-e2e\server.log") "server"
    Write-TextFile (Join-Path $EvidenceDir "logs\agent-e2e\agent.log") "agent config root=$TempDir\agent-root agent_name=windows-client-e2e-test audio_input=smoke-audio-input"
    Write-TextFile (Join-Path $EvidenceDir "logs\client-e2e\server.log") "server"
    Write-TextFile (Join-Path $EvidenceDir "logs\client-e2e\client.log") @"
agent config root=$TempDir\agent-root agent_name=windows-client-e2e-test audio_input=smoke-audio-input
[diagnostics] conductor-agent
"@
    @{
        serverUrl = "ws://127.0.0.1:18081/ws/agent"
        agentName = "windows-client-e2e-test"
        agentRoot = (Join-Path $TempDir "agent-root")
        audioInput = "smoke-audio-input"
        interactiveApproval = $false
    } | ConvertTo-Json | Set-Content -Path (Join-Path $EvidenceDir "logs\client-e2e\client-settings.json") -Encoding ascii

    & (Join-Path $RootDir "scripts\verify-windows-smoke-evidence.ps1") `
        -EvidenceDir $EvidenceDir `
        -RequireCiFields `
        -ExpectedCommit $Commit

    $EvidenceSidecar = Join-Path $EvidenceDir ((Split-Path -Leaf $ArchivePath) + ".sha256")
    Rename-Item -Path $EvidenceSidecar -NewName ((Split-Path -Leaf $EvidenceSidecar) + ".bak")
    Invoke-ExpectedFailure "Windows smoke evidence archive checksum sidecar is missing" {
        & (Join-Path $RootDir "scripts\verify-windows-smoke-evidence.ps1") `
            -EvidenceDir $EvidenceDir `
            -RequireCiFields `
            -ExpectedCommit $Commit
    }

    Write-Host "Windows smoke evidence verifier test passed."
} finally {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
