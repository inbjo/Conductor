param(
    [Parameter(Mandatory = $true)]
    [string] $ArchivePath,

    [string] $ServerPath = ".\target\debug\conductor-server.exe",

    [int] $Port = 18081,

    [int] $TimeoutSeconds = 25
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $ArchivePath)) {
    Write-Error "Archive not found: $ArchivePath"
}
if (!(Test-Path $ServerPath)) {
    Write-Error "Server executable not found: $ServerPath"
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("conductor-windows-client-e2e-" + [System.Guid]::NewGuid().ToString("N"))
$AgentRoot = Join-Path $TempDir "agent-root"
$DbPath = Join-Path $TempDir "conductor.sqlite3"
$ServerLog = Join-Path $TempDir "server.log"
$ClientLog = Join-Path $TempDir "client.log"
$BaseUrl = "http://127.0.0.1:$Port"
$AgentName = "windows-client-e2e-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
$AdminPassword = "admin123"
$JwtSecret = "windows-client-e2e-secret"
$AgentToken = "windows-client-e2e-token"
$ServerProcess = $null
$ClientProcess = $null
$AgentExe = $null
$Failed = $true

function Start-ConductorProcess($FileName, $WorkingDirectory, $Environment, $LogPath) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($key in $Environment.Keys) {
        $startInfo.Environment[$key] = [string] $Environment[$key]
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $process.EnableRaisingEvents = $true
    $stdout = [System.IO.StreamWriter]::new($LogPath, $false)
    $stderr = [System.IO.StreamWriter]::new($LogPath + ".err", $false)
    $process.add_OutputDataReceived({
        if ($null -ne $_.Data) {
            $stdout.WriteLine($_.Data)
            $stdout.Flush()
        }
    })
    $process.add_ErrorDataReceived({
        if ($null -ne $_.Data) {
            $stderr.WriteLine($_.Data)
            $stderr.Flush()
        }
    })
    [void] $process.Start()
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    return @{
        Process = $process
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Stop-ConductorProcess($handle) {
    if ($null -eq $handle) {
        return
    }
    $process = $handle["Process"]
    if ($null -ne $process -and !$process.HasExited) {
        Stop-Process -Id $process.Id -Force
        Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    }
    $handle["Stdout"].Close()
    $handle["Stderr"].Close()
}

function Stop-ProcessByPath($Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    $children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $Path }
    foreach ($child in $children) {
        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

try {
    New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
    New-Item -ItemType Directory -Force -Path $AgentRoot | Out-Null
    Expand-Archive -Force -Path $ArchivePath -DestinationPath $TempDir

    $ClientExe = Join-Path $TempDir "conductor_client.exe"
    $AgentExe = Join-Path $TempDir "conductor-agent.exe"
    if (!(Test-Path $ClientExe)) {
        Write-Error "Missing client executable: conductor_client.exe"
    }
    if (!(Test-Path $AgentExe)) {
        Write-Error "Missing bundled agent executable: conductor-agent.exe"
    }

    $portInUse = $false
    try {
        Invoke-RestMethod -Method Get -Uri "$BaseUrl/health" -TimeoutSec 2 | Out-Null
        $portInUse = $true
    } catch {
        $portInUse = $false
    }
    if ($portInUse) {
        Write-Error "Port $Port already has a responding service at $BaseUrl."
    }

    Write-Host "[1/4] Starting smoke server: $ServerPath"
    $ServerProcess = Start-ConductorProcess `
        -FileName ([string] (Resolve-Path $ServerPath)) `
        -WorkingDirectory ([string] (Resolve-Path ".")) `
        -LogPath $ServerLog `
        -Environment @{
            CONDUCTOR_DB = $DbPath
            CONDUCTOR_BIND = "127.0.0.1:$Port"
            CONDUCTOR_ADMIN_PASSWORD = $AdminPassword
            CONDUCTOR_JWT_SECRET = $JwtSecret
            CONDUCTOR_AGENT_TOKEN = $AgentToken
        }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ($ServerProcess['Process'].HasExited) {
            Write-Error "Smoke server exited early. Exit code: $($ServerProcess['Process'].ExitCode)"
        }
        try {
            Invoke-RestMethod -Method Get -Uri "$BaseUrl/health" -TimeoutSec 2 | Out-Null
            break
        } catch {
            Start-Sleep -Milliseconds 250
        }
    } while ((Get-Date) -lt $deadline)
    Invoke-RestMethod -Method Get -Uri "$BaseUrl/health" -TimeoutSec 2 | Out-Null

    Write-Host "[2/4] Starting Windows client autostart smoke: $ClientExe"
    $ClientProcess = Start-ConductorProcess `
        -FileName $ClientExe `
        -WorkingDirectory $TempDir `
        -LogPath $ClientLog `
        -Environment @{
            CONDUCTOR_CLIENT_AUTOSTART = "1"
            CONDUCTOR_CLIENT_AGENT_BIN = $AgentExe
            CONDUCTOR_SERVER_URL = "ws://127.0.0.1:$Port/ws/agent"
            CONDUCTOR_AGENT_TOKEN = $AgentToken
            CONDUCTOR_AGENT_NAME = $AgentName
            CONDUCTOR_AGENT_ROOT = $AgentRoot
            CONDUCTOR_INTERACTIVE_APPROVAL = "0"
        }

    Write-Host "[3/4] Logging in"
    $loginBody = @{ username = "admin"; password = $AdminPassword } | ConvertTo-Json
    $login = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/auth/login" -ContentType "application/json" -Body $loginBody -TimeoutSec 5
    $headers = @{ Authorization = "Bearer $($login.token)" }

    Write-Host "[4/4] Waiting for client-started agent registration: $AgentName"
    $device = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ($ClientProcess['Process'].HasExited) {
            Write-Error "Windows client exited before agent registration. Exit code: $($ClientProcess['Process'].ExitCode)"
        }
        $devices = @(Invoke-RestMethod -Method Get -Uri "$BaseUrl/api/devices" -Headers $headers -TimeoutSec 5)
        $device = $devices | Where-Object { $_.hostname -eq $AgentName -and $_.online -eq 1 } | Select-Object -First 1
        if ($null -ne $device) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    if ($null -eq $device) {
        $devices = Invoke-RestMethod -Method Get -Uri "$BaseUrl/api/devices" -Headers $headers -TimeoutSec 5
        Write-Host "Current devices:"
        Write-Host ($devices | ConvertTo-Json -Depth 4)
        Write-Error "Windows client did not start and register bundled agent within $TimeoutSeconds seconds."
    }

    $Failed = $false
    Write-Host "Windows client e2e smoke passed. Device: $($device.device_id)"
} finally {
    Stop-ConductorProcess $ClientProcess
    Stop-ProcessByPath $AgentExe
    Stop-ConductorProcess $ServerProcess
    if ($Failed) {
        if (Test-Path $ServerLog) {
            Write-Host "Server log:"
            Get-Content $ServerLog -Tail 80
        }
        if (Test-Path "$ServerLog.err") {
            Write-Host "Server stderr:"
            Get-Content "$ServerLog.err" -Tail 80
        }
        if (Test-Path $ClientLog) {
            Write-Host "Client log:"
            Get-Content $ClientLog -Tail 80
        }
        if (Test-Path "$ClientLog.err") {
            Write-Host "Client stderr:"
            Get-Content "$ClientLog.err" -Tail 80
        }
    }
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
