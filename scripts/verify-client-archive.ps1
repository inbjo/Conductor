param(
    [Parameter(Mandatory = $true)]
    [string] $ArchivePath
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $ArchivePath)) {
    Write-Error "Archive not found: $ArchivePath"
}
$ChecksumPath = "$ArchivePath.sha256"
if (!(Test-Path $ChecksumPath)) {
    Write-Error "Archive checksum not found: $ChecksumPath"
}
$ExpectedLine = (Get-Content $ChecksumPath -ErrorAction Stop | Select-Object -First 1).Trim()
$ExpectedHash = ($ExpectedLine -split "\s+")[0].ToLowerInvariant()
if ($ExpectedHash -notmatch "^[a-f0-9]{64}$") {
    Write-Error "Archive checksum file is invalid: $ChecksumPath"
}
$ActualHash = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLowerInvariant()
if ($ActualHash -ne $ExpectedHash) {
    Write-Error "Archive checksum mismatch. Expected: $ExpectedHash Actual: $ActualHash"
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
        "data\flutter_assets",
        "data\flutter_assets\AssetManifest.bin",
        "data\flutter_assets\FontManifest.json",
        "data\flutter_assets\NativeAssetsManifest.json",
        "data\flutter_assets\version.json"
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
