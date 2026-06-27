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
