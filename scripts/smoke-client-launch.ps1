param(
    [Parameter(Mandatory = $true)]
    [string] $ArchivePath,

    [int] $Seconds = 8
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $ArchivePath)) {
    Write-Error "Archive not found: $ArchivePath"
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("conductor-client-launch-" + [System.Guid]::NewGuid().ToString("N"))
$ClientSettings = Join-Path $TempDir "client-settings.json"
$Process = $null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

function Remove-TempDirectoryWithRetry($Path) {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        if (!(Test-Path -LiteralPath $Path)) {
            return
        }
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq 10) {
                Write-Warning "Unable to remove temporary client directory after $attempt attempts: $Path. $($_.Exception.Message)"
                return
            }
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
}

try {
    Expand-Archive -Force -Path $ArchivePath -DestinationPath $TempDir

    $ClientExe = Join-Path $TempDir "conductor_client.exe"
    $AgentExe = Join-Path $TempDir "conductor-agent.exe"

    if (!(Test-Path $ClientExe)) {
        Write-Error "Missing client executable: conductor_client.exe"
    }
    if (!(Test-Path $AgentExe)) {
        Write-Error "Missing bundled agent executable: conductor-agent.exe"
    }

    Write-Host "Launching client smoke process: $ClientExe"
    $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $ClientExe
    $StartInfo.WorkingDirectory = $TempDir
    $StartInfo.UseShellExecute = $false
    $StartInfo.Environment["CONDUCTOR_CLIENT_SETTINGS_FILE"] = $ClientSettings
    $Process = [System.Diagnostics.Process]::Start($StartInfo)
    Start-Sleep -Seconds $Seconds

    if ($Process.HasExited) {
        Write-Error "Client exited during launch smoke. Exit code: $($Process.ExitCode)"
    }

    Write-Host "Client launch smoke passed after $Seconds seconds. PID: $($Process.Id)"
} finally {
    if ($null -ne $Process -and !$Process.HasExited) {
        try {
            $Process.Kill($true)
            $Process.WaitForExit()
        } catch {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $Process.Id -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $Process) {
        $Process.Dispose()
    }
    Remove-TempDirectoryWithRetry $TempDir
}
