function Start-ConductorProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FileName,

        [Parameter(Mandatory = $true)]
        [string] $WorkingDirectory,

        [hashtable] $Environment = @{},

        [Parameter(Mandatory = $true)]
        [string] $LogPath,

        [string[]] $Arguments = @()
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    foreach ($key in $Environment.Keys) {
        $startInfo.Environment[$key] = [string] $Environment[$key]
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void] $process.Start()
    $stdout = [System.IO.FileStream]::new(
        $LogPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite,
        1,
        [System.IO.FileOptions]::Asynchronous
    )
    $stderr = [System.IO.FileStream]::new(
        $LogPath + ".err",
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite,
        1,
        [System.IO.FileOptions]::Asynchronous
    )
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
    return @{
        Process = $process
        Stdout = $stdout
        Stderr = $stderr
        StdoutTask = $stdoutTask
        StderrTask = $stderrTask
    }
}

function Stop-ConductorProcess($Handle) {
    if ($null -eq $Handle) {
        return
    }
    $process = $Handle["Process"]
    if ($null -ne $process -and !$process.HasExited) {
        Stop-Process -Id $process.Id -Force
        Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    }
    $process.WaitForExit()
    try {
        [void] ($Handle["StdoutTask"]).GetAwaiter().GetResult()
        [void] ($Handle["StderrTask"]).GetAwaiter().GetResult()
    } finally {
        $Handle["Stdout"].Close()
        $Handle["Stderr"].Close()
        $process.Dispose()
    }
}
