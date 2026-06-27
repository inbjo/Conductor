<#
.SYNOPSIS
Runs the Windows client smoke flow and optionally writes evidence.

.DESCRIPTION
Builds or reuses the Windows client archive and smoke server, verifies the zip,
smoke-launches the bundled agent, checks bundled-agent registration, checks
Flutter-client-started agent registration, and smoke-launches the GUI entry.

.PARAMETER ArchivePath
Path to the Windows client zip archive.

.PARAMETER SkipClientBuild
Reuse an existing client archive instead of building it.

.PARAMETER SkipServerBuild
Reuse an existing target\debug\conductor-server.exe instead of building it.

.PARAMETER EvidenceDir
Optional directory where validation-summary.txt and smoke-windows-client-flow.log are written.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-windows-client-flow.ps1 -EvidenceDir .\artifacts\windows-client-smoke
#>
param(
    [string] $ArchivePath = ".\release\conductor-client-windows-x64.zip",

    [switch] $SkipClientBuild,

    [switch] $SkipServerBuild,

    [string] $EvidenceDir = ""
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([System.IO.Path]::IsPathRooted($ArchivePath)) {
    $ArchiveFullPath = $ArchivePath
} else {
    $ArchiveFullPath = Join-Path $RootDir $ArchivePath
}
$EvidenceFullPath = $null
if (![string]::IsNullOrWhiteSpace($EvidenceDir)) {
    if ([System.IO.Path]::IsPathRooted($EvidenceDir)) {
        $EvidenceFullPath = $EvidenceDir
    } else {
        $EvidenceFullPath = Join-Path $RootDir $EvidenceDir
    }
}
$TranscriptStarted = $false
$SummaryPath = $null
$EvidenceLogsPath = $null

function Invoke-Step($Name, [scriptblock] $Command) {
    Write-Host ""
    Write-Host "==> $Name"
    & $Command
}

function Add-SummaryLine($Path, $Line) {
    $Line | Out-File -Encoding utf8 -Append $Path
}

function Add-CommandSummary($Path, $Command, $Arguments) {
    $commandInfo = Get-Command $Command -ErrorAction SilentlyContinue
    if ($null -eq $commandInfo) {
        Add-SummaryLine $Path "$Command=not found"
        return
    }
    $output = & $Command @Arguments 2>&1
    foreach ($line in $output) {
        Add-SummaryLine $Path "$Command=$line"
    }
}

function Add-ExecutableSummary($Path, $Label, $Executable, $Arguments) {
    if ([string]::IsNullOrWhiteSpace($Executable) -or !(Test-Path $Executable)) {
        Add-SummaryLine $Path "$Label=not found"
        return
    }
    $output = & $Executable @Arguments 2>&1
    foreach ($line in $output) {
        Add-SummaryLine $Path "$Label=$line"
    }
}

function Get-CurrentCommit {
    if (![string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
        return $env:GITHUB_SHA
    }
    try {
        $commit = git -C $RootDir rev-parse HEAD 2>$null
        if (![string]::IsNullOrWhiteSpace($commit)) {
            return $commit.Trim()
        }
    } catch {
    }
    return ""
}

Push-Location $RootDir
try {
    if ($null -ne $EvidenceFullPath) {
        New-Item -ItemType Directory -Force -Path $EvidenceFullPath | Out-Null
        $SummaryPath = Join-Path $EvidenceFullPath "validation-summary.txt"
        "timestamp=$((Get-Date).ToString("o"))" | Out-File -Encoding utf8 $SummaryPath
        Add-SummaryLine $SummaryPath "repository=$RootDir"
        Add-SummaryLine $SummaryPath "archive=$ArchiveFullPath"
        Add-SummaryLine $SummaryPath "skip_client_build=$SkipClientBuild"
        Add-SummaryLine $SummaryPath "skip_server_build=$SkipServerBuild"
        Add-SummaryLine $SummaryPath "commit=$(Get-CurrentCommit)"
        Add-SummaryLine $SummaryPath "runner_os=$env:RUNNER_OS"
        Add-SummaryLine $SummaryPath "runner_arch=$env:RUNNER_ARCH"
        Add-SummaryLine $SummaryPath "powershell=$($PSVersionTable.PSVersion)"
        Add-CommandSummary $SummaryPath "rustc" @("--version")
        Add-CommandSummary $SummaryPath "cargo" @("--version")
        if (![string]::IsNullOrWhiteSpace($env:FLUTTER_BIN)) {
            Add-ExecutableSummary $SummaryPath "flutter" $env:FLUTTER_BIN @("--version")
        } else {
            Add-CommandSummary $SummaryPath "flutter" @("--version")
        }
        Start-Transcript -Path (Join-Path $EvidenceFullPath "smoke-windows-client-flow.log") -Force
        $TranscriptStarted = $true
        $EvidenceLogsPath = Join-Path $EvidenceFullPath "logs"
    }

    Write-Host "Windows client flow smoke"
    Write-Host "Repository: $RootDir"
    Write-Host "Archive: $ArchiveFullPath"
    Write-Host "SkipClientBuild: $SkipClientBuild"
    Write-Host "SkipServerBuild: $SkipServerBuild"
    if ($null -ne $EvidenceFullPath) {
        Write-Host "Evidence: $EvidenceFullPath"
    }

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
    if ($null -ne $SummaryPath) {
        $archiveHash = Get-FileHash -Algorithm SHA256 -Path $ArchiveFullPath
        Add-SummaryLine $SummaryPath "archive_sha256=$($archiveHash.Hash.ToLowerInvariant())"
    }

    Invoke-Step "Verify Windows client archive" {
        & .\scripts\verify-client-archive.ps1 -ArchivePath $ArchiveFullPath
    }
    Invoke-Step "Smoke launch bundled Windows agent" {
        & .\scripts\smoke-agent-launch.ps1 -ArchivePath $ArchiveFullPath
    }
    Invoke-Step "Smoke register bundled Windows agent" {
        $agentEvidenceDir = $null
        if ($null -ne $EvidenceLogsPath) {
            $agentEvidenceDir = Join-Path $EvidenceLogsPath "agent-e2e"
        }
        & .\scripts\smoke-windows-agent-e2e.ps1 -ArchivePath $ArchiveFullPath -EvidenceDir $agentEvidenceDir
    }
    Invoke-Step "Smoke register through Windows client" {
        $clientEvidenceDir = $null
        if ($null -ne $EvidenceLogsPath) {
            $clientEvidenceDir = Join-Path $EvidenceLogsPath "client-e2e"
        }
        & .\scripts\smoke-windows-client-e2e.ps1 -ArchivePath $ArchiveFullPath -EvidenceDir $clientEvidenceDir
    }
    Invoke-Step "Smoke launch Windows client" {
        & .\scripts\smoke-client-launch.ps1 -ArchivePath $ArchiveFullPath
    }

    Write-Host ""
    Write-Host "Windows client flow smoke passed: $ArchiveFullPath"
    if ($null -ne $SummaryPath) {
        Add-SummaryLine $SummaryPath "result=passed"
    }
} catch {
    if ($null -ne $SummaryPath) {
        Add-SummaryLine $SummaryPath "result=failed"
        Add-SummaryLine $SummaryPath "error=$($_.Exception.Message)"
    }
    throw
} finally {
    if ($TranscriptStarted) {
        Stop-Transcript
    }
    Pop-Location
}
