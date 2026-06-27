param(
    [Parameter(Mandatory = $true)]
    [string] $ArchivePath,

    [int] $Seconds = 8
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $ArchivePath)) {
    Write-Error "Archive not found: $ArchivePath"
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("conductor-agent-launch-" + [System.Guid]::NewGuid().ToString("N"))
$AgentRoot = Join-Path $TempDir "agent-root"
$StdoutPath = Join-Path $TempDir "agent.stdout.log"
$StderrPath = Join-Path $TempDir "agent.stderr.log"
$Process = $null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
New-Item -ItemType Directory -Force -Path $AgentRoot | Out-Null

try {
    Expand-Archive -Force -Path $ArchivePath -DestinationPath $TempDir

    $AgentExe = Join-Path $TempDir "conductor-agent.exe"
    if (!(Test-Path $AgentExe)) {
        Write-Error "Missing bundled agent executable: conductor-agent.exe"
    }

    $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $AgentExe
    $StartInfo.WorkingDirectory = $TempDir
    $StartInfo.UseShellExecute = $false
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.Environment["CONDUCTOR_SERVER_URL"] = "ws://127.0.0.1:9/ws/agent"
    $StartInfo.Environment["CONDUCTOR_AGENT_TOKEN"] = "smoke-agent-token"
    $StartInfo.Environment["CONDUCTOR_AGENT_NAME"] = "windows-agent-smoke"
    $StartInfo.Environment["CONDUCTOR_AGENT_ROOT"] = $AgentRoot
    $StartInfo.Environment["CONDUCTOR_INTERACTIVE_APPROVAL"] = "0"

    Write-Host "Launching bundled agent smoke process: $AgentExe"
    $Process = [System.Diagnostics.Process]::Start($StartInfo)
    Start-Sleep -Seconds $Seconds

    if ($Process.HasExited) {
        $stdout = $Process.StandardOutput.ReadToEnd()
        $stderr = $Process.StandardError.ReadToEnd()
        Set-Content -Path $StdoutPath -Value $stdout
        Set-Content -Path $StderrPath -Value $stderr
        Write-Host "Agent stdout:"
        Write-Host $stdout
        Write-Host "Agent stderr:"
        Write-Host $stderr
        Write-Error "Bundled agent exited during launch smoke. Exit code: $($Process.ExitCode)"
    }

    Write-Host "Bundled agent launch smoke passed after $Seconds seconds. PID: $($Process.Id)"
} finally {
    if ($null -ne $Process -and !$Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
        Wait-Process -Id $Process.Id -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $TempDir
}
