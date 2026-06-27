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
$Process = $null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

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
    $Process = Start-Process -FilePath $ClientExe -WorkingDirectory $TempDir -PassThru
    Start-Sleep -Seconds $Seconds

    if ($Process.HasExited) {
        Write-Error "Client exited during launch smoke. Exit code: $($Process.ExitCode)"
    }

    Write-Host "Client launch smoke passed after $Seconds seconds. PID: $($Process.Id)"
} finally {
    if ($null -ne $Process -and !$Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
        Wait-Process -Id $Process.Id -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $TempDir
}
