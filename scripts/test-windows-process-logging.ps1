$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "windows-process-logging.ps1")

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("conductor-process-log-test-" + [System.Guid]::NewGuid().ToString("N"))
$LogPath = Join-Path $TempDir "process.log"
$ProcessHandle = $null

try {
    New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
    $PowerShellExe = (Get-Process -Id $PID).Path
    $ProcessHandle = Start-ConductorProcess `
        -FileName $PowerShellExe `
        -WorkingDirectory $TempDir `
        -LogPath $LogPath `
        -Arguments @(
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "[Console]::Out.WriteLine('live-output'); [Console]::Error.WriteLine('live-error'); Start-Sleep -Seconds 5"
        )

    $Deadline = (Get-Date).AddSeconds(3)
    $StdoutObserved = $false
    $StderrObserved = $false
    do {
        $StdoutObserved = (Get-Content $LogPath -Raw -ErrorAction SilentlyContinue) -like "*live-output*"
        $StderrObserved = (Get-Content "$LogPath.err" -Raw -ErrorAction SilentlyContinue) -like "*live-error*"
        if ($StdoutObserved -and $StderrObserved) {
            break
        }
        if ($ProcessHandle["Process"].HasExited) {
            throw "Test process exited before its redirected logs became visible."
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $Deadline)

    if (!$StdoutObserved -or !$StderrObserved) {
        throw "Redirected process logs were not visible while the process was running."
    }
    Write-Host "Windows process live logging test passed."
} finally {
    Stop-ConductorProcess $ProcessHandle
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
