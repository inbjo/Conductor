param(
    [Parameter(Mandatory = $true)]
    [string] $ArchivePath
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $ArchivePath)) {
    Write-Error "Archive not found: $ArchivePath"
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("conductor-client-verify-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

try {
    Expand-Archive -Force -Path $ArchivePath -DestinationPath $TempDir

    $Required = @(
        "conductor_client.exe",
        "conductor-agent.exe",
        "flutter_windows.dll",
        "data\icudtl.dat",
        "data\flutter_assets"
    )

    foreach ($Item in $Required) {
        $Path = Join-Path $TempDir $Item
        if (!(Test-Path $Path)) {
            Write-Error "Missing archive entry: $Item"
        }
    }

    Write-Host "Client archive verified: $ArchivePath"
} finally {
    Remove-Item -Recurse -Force $TempDir
}
