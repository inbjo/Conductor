param(
    [string] $EvidenceDir = ".\artifacts\windows-client-smoke"
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

if (!(Test-Path $SummaryPath)) {
    Write-Error "Missing Windows smoke evidence summary: $SummaryPath"
}
if (!(Test-Path $LogPath)) {
    Write-Error "Missing Windows smoke transcript: $LogPath"
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

$Result = $Summary["result"]
if ($Result -ne "passed") {
    Write-Error "Windows smoke evidence result is not passed: $Result"
}

$ArchiveSha256 = $Summary["archive_sha256"]
if ($ArchiveSha256 -notmatch "^[a-f0-9]{64}$") {
    Write-Error "Windows smoke evidence archive_sha256 is invalid: $ArchiveSha256"
}

$LogText = Get-Content $LogPath -Raw
if ($LogText -notmatch "Windows client flow smoke passed") {
    Write-Error "Windows smoke transcript does not contain the success marker."
}

Write-Host "Windows smoke evidence verified: $EvidenceFullPath"
