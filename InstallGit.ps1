param(
    [string] $InstallRoot = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "CordBuilder\runtime"),
    [switch] $SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Get-GitArchiveArchitecture {
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($architecture.ToUpperInvariant()) {
        "AMD64" { return "64-bit" }
        "ARM64" { return "arm64" }
        "X86" { return "32-bit" }
        default { throw "Unsupported Windows architecture: $architecture" }
    }
}

function Assert-GitChildPath {
    param([string] $Path, [string] $Root)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not ([IO.Path]::GetFullPath($Path)).StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing a path outside the private Git runtime: $Path"
    }
}

function Get-VerifiedGitAsset {
    param([object] $Release, [string] $Architecture)
    $namePattern = '^MinGit-(\d+\.\d+\.\d+(?:\.\d+)?)-' + [regex]::Escape($Architecture) + '\.zip$'
    $assets = @($Release.assets | Where-Object { $_.name -cmatch $namePattern })
    if ($assets.Count -ne 1) { throw "The official release did not contain one standard MinGit archive for $Architecture." }
    $asset = $assets[0]
    $uri = [Uri]$asset.browser_download_url
    if ($uri.Scheme -ne "https" -or $uri.Host -ne "github.com" -or
        $uri.UserInfo -or -not $uri.IsDefaultPort -or
        -not $uri.AbsolutePath.StartsWith("/git-for-windows/git/releases/download/", [StringComparison]::Ordinal) -or
        $uri.Query -or $uri.Fragment) {
        throw "The Git release download URL was not from the official repository."
    }
    $digestProperty = $asset.PSObject.Properties["digest"]
    if ($null -eq $digestProperty -or [string]$digestProperty.Value -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "The official Git release has no usable SHA-256 checksum. Nothing will be installed."
    }
    return [pscustomobject]@{
        Name = [string]$asset.name
        Url = $uri.AbsoluteUri
        Hash = ([string]$digestProperty.Value).Substring(7)
    }
}

function Assert-GitZipPaths {
    param([string] $ArchivePath, [string] $Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        [long]$totalSize = 0
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ([IO.Path]::IsPathRooted($name) -or $name.Contains(':')) { throw "Unsafe Git archive entry: $name" }
            Assert-GitChildPath (Join-Path $Destination $name) $Destination
            $totalSize += $entry.Length
            if ($totalSize -gt 1GB) { throw "Git archive exceeded its extraction size limit." }
        }
    }
    finally { $archive.Dispose() }
}

function Assert-PrivateGit {
    param([string] $Directory)
    $git = Join-Path $Directory "cmd\git.exe"
    if (-not (Test-Path -LiteralPath $git -PathType Leaf)) { throw "The Git archive did not contain cmd\git.exe." }
    $version = & $git --version
    if ($LASTEXITCODE -ne 0 -or [string]$version -notmatch '^git version \d+\.\d+') { throw "The installed Git executable failed verification." }
    $execPath = & $git --exec-path
    if ($LASTEXITCODE -ne 0 -or -not $execPath) { throw "Git did not report its helper directory." }
    Assert-GitChildPath $execPath $Directory
    # MinGit can place remote helpers in mingw*/bin rather than libexec/git-core.
    $helperPaths = @(
        (Join-Path $execPath "git-remote-https.exe"),
        (Join-Path (Split-Path -Parent (Split-Path -Parent $execPath)) "bin\git-remote-https.exe")
    )
    $httpsHelper = @($helperPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($httpsHelper.Count -eq 0) {
        throw "Git's HTTPS support is missing; repository downloads would not work."
    }
    Write-Output "Verified $version, including HTTPS repository support."
}

if ($SelfTest) {
    $testAsset = [pscustomobject]@{
        name = "MinGit-2.55.0.5-64-bit.zip"
        browser_download_url = "https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/MinGit-2.55.0.5-64-bit.zip"
        digest = "sha256:" + ("a" * 64)
    }
    $release = [pscustomobject]@{ assets = @($testAsset) }
    [void](Get-VerifiedGitAsset $release "64-bit")
    $testAsset.digest = $null
    $rejected = $false
    try { [void](Get-VerifiedGitAsset $release "64-bit") } catch { $rejected = $true }
    if (-not $rejected) { throw "An archive without a checksum was accepted." }
    $testAsset.digest = "sha256:" + ("a" * 64)
    $testAsset.browser_download_url = "https://example.com/git.zip"
    $rejected = $false
    try { [void](Get-VerifiedGitAsset $release "64-bit") } catch { $rejected = $true }
    if (-not $rejected) { throw "An unofficial download URL was accepted." }
    $rejected = $false
    try { Assert-GitChildPath (Join-Path $InstallRoot '..\escape') $InstallRoot } catch { $rejected = $true }
    if (-not $rejected) { throw "An unsafe extraction path was accepted." }
    Write-Output "PASS: Git installer checks the official source, checksum, architecture and safe paths."
    exit 0
}

$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$architecture = Get-GitArchiveArchitecture
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Output "Looking up the official Git for Windows application package..."
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -Headers @{
    "User-Agent" = "CordBuilder"
    "Accept" = "application/vnd.github+json"
} -UseBasicParsing -TimeoutSec 60
$asset = Get-VerifiedGitAsset $release $architecture

$temporaryDirectory = Join-Path $InstallRoot (".git-download-" + [Guid]::NewGuid().ToString("N"))
Assert-GitChildPath $temporaryDirectory $InstallRoot
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
try {
    $archivePath = Join-Path $temporaryDirectory $asset.Name
    Write-Output "Downloading $($asset.Name)..."
    Invoke-WebRequest -Uri $asset.Url -OutFile $archivePath -UseBasicParsing -TimeoutSec 600
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if (-not $actualHash.Equals($asset.Hash, [StringComparison]::OrdinalIgnoreCase)) { throw "Git download checksum did not match. Nothing was activated." }
    Write-Output "Verified the Git release SHA-256 checksum."
    $extracted = Join-Path $temporaryDirectory "extracted"
    Assert-GitZipPaths $archivePath $extracted
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extracted
    Assert-PrivateGit $extracted
    $directoryName = "git-" + [IO.Path]::GetFileNameWithoutExtension($asset.Name) + "-" + [Guid]::NewGuid().ToString("N")
    $installedDirectory = Join-Path $InstallRoot $directoryName
    Assert-GitChildPath $installedDirectory $InstallRoot
    Move-Item -LiteralPath $extracted -Destination $installedDirectory
    Assert-PrivateGit $installedDirectory
    # Never switch the active copy until its executable and HTTPS helper pass.
    Set-Content -LiteralPath (Join-Path $InstallRoot "git-current.txt") -Value $directoryName -Encoding ASCII
    Write-Output "Private Git is ready. No system installation or administrator access was needed."
}
finally {
    Assert-GitChildPath $temporaryDirectory $InstallRoot
    if ((Split-Path -Leaf $temporaryDirectory) -cmatch '^\.git-download-[0-9a-f]{32}$' -and
        (Test-Path -LiteralPath $temporaryDirectory -PathType Container)) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
