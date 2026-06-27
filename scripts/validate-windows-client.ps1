<#
.SYNOPSIS
Runs the full Windows controlled client validation flow.

.DESCRIPTION
Builds or reuses the Windows client archive and smoke server, runs the Windows
client smoke flow, and verifies the generated smoke evidence. This is the
preferred one-command Windows validation entry point.

.PARAMETER ArchivePath
Path to the Windows client zip archive.

.PARAMETER EvidenceDir
Directory where validation-summary.txt and smoke-windows-client-flow.log are written.

.PARAMETER SkipClientBuild
Reuse an existing client archive instead of building it.

.PARAMETER SkipServerBuild
Reuse an existing target\debug\conductor-server.exe instead of building it.

.PARAMETER RequireCiFields
Require CI-only evidence fields such as runner_os and runner_arch.

.PARAMETER ExpectedCommit
Require the evidence commit field to match this SHA.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\validate-windows-client.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\validate-windows-client.ps1 -SkipClientBuild -SkipServerBuild -EvidenceDir .\artifacts\windows-client-smoke
#>
param(
    [string] $ArchivePath = ".\release\conductor-client-windows-x64.zip",

    [string] $EvidenceDir = ".\artifacts\windows-client-smoke",

    [switch] $SkipClientBuild,

    [switch] $SkipServerBuild,

    [switch] $RequireCiFields,

    [string] $ExpectedCommit = ""
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")

Push-Location $RootDir
try {
    Write-Host "Validating Windows controlled client"
    Write-Host "Archive: $ArchivePath"
    Write-Host "Evidence: $EvidenceDir"
    Write-Host "SkipClientBuild: $SkipClientBuild"
    Write-Host "SkipServerBuild: $SkipServerBuild"
    Write-Host "RequireCiFields: $RequireCiFields"
    if (![string]::IsNullOrWhiteSpace($ExpectedCommit)) {
        Write-Host "ExpectedCommit: $ExpectedCommit"
    }

    & .\scripts\smoke-windows-client-flow.ps1 `
        -ArchivePath $ArchivePath `
        -EvidenceDir $EvidenceDir `
        -SkipClientBuild:$SkipClientBuild `
        -SkipServerBuild:$SkipServerBuild

    & .\scripts\verify-windows-smoke-evidence.ps1 `
        -EvidenceDir $EvidenceDir `
        -RequireCiFields:$RequireCiFields `
        -ExpectedCommit $ExpectedCommit

    Write-Host "Windows controlled client validation passed."
} finally {
    Pop-Location
}
