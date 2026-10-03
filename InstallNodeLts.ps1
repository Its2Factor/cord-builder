param(
    [string] $InstallRoot = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "CordBuilder\runtime"),
    [switch] $SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Get-WindowsNodeArchitecture {
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($architecture.ToUpperInvariant()) {
        "AMD64" { return "x64" }
        "ARM64" { return "arm64" }
        "X86" { return "x86" }
        default { throw "Unsupported Windows architecture: $architecture" }
    }
}

function Assert-PathInsideRoot {
    param([string] $Path, [string] $Root)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $candidatePath = [IO.Path]::GetFullPath($Path)
    if (-not $candidatePath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe runtime path: $candidatePath"
    }
}

function Assert-NodeRuntime {
    param([string] $Directory)
    $node = Join-Path $Directory "node.exe"
    $npmCli = Join-Path $Directory "node_modules\npm\bin\npm-cli.js"
    if (-not (Test-Path -LiteralPath $node -PathType Leaf) -or
        -not (Test-Path -LiteralPath $npmCli -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $Directory "npm.cmd") -PathType Leaf)) {
        throw "The private Node.js runtime is incomplete, including its bundled npm."
    }
    $ltsName = & $node -p "process.release.lts || ''"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$ltsName)) {
        throw "The installed Node.js runtime did not report an LTS codename."
    }
    $npmVersion = & $node $npmCli --version
    if ($LASTEXITCODE -ne 0 -or [string]$npmVersion -notmatch '^\d+\.\d+\.\d+') {
        throw "The bundled npm failed its version check."
    }
    return [string]$ltsName
}

function Assert-NodeZipPaths {
    param([string] $ArchivePath, [string] $Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        [long]$totalSize = 0
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ([IO.Path]::IsPathRooted($name) -or $name.Contains(':')) { throw "Unsafe Node.js archive entry: $name" }
            Assert-PathInsideRoot (Join-Path $Destination $name) $Destination
            $totalSize += $entry.Length
            if ($totalSize -gt 1GB) { throw "Node.js archive exceeded its extraction size limit." }
        }
    }
    finally { $archive.Dispose() }
}

$architecture = Get-WindowsNodeArchitecture
if ($SelfTest) {
    $testRoot = [IO.Path]::GetFullPath($InstallRoot)
    $testChild = Join-Path $testRoot ".download-self-test"
    Assert-PathInsideRoot $testChild $testRoot
    $rejected = $false
    try { Assert-PathInsideRoot (Join-Path $testRoot '..\escape') $testRoot } catch { $rejected = $true }
    if (-not $rejected) { throw "An unsafe runtime path was accepted." }
    $rejected = $false
    try { [void](Assert-NodeRuntime (Join-Path $testRoot 'missing-self-test-runtime')) } catch { $rejected = $true }
    if (-not $rejected) { throw "An incomplete runtime was accepted." }
    Write-Output "PASS: Node.js LTS installer supports Windows $architecture and validated its runtime path."
    exit 0
}

$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$releaseIndexUrl = "https://nodejs.org/dist/index.json"
Write-Output "Checking the official Node.js release index..."
$releases = Invoke-RestMethod -Uri $releaseIndexUrl -UseBasicParsing -TimeoutSec 60
$fileType = "win-$architecture-zip"
$release = $releases | Where-Object {
    $_.lts -and $_.lts -ne $false -and $_.files -contains $fileType
} | Select-Object -First 1
if ($null -eq $release) { throw "No supported Node.js LTS $fileType release was found." }

$version = [string]$release.version
if ($version -cnotmatch '^v\d+\.\d+\.\d+$') { throw "Invalid version in the official Node.js release index." }
$archiveName = "node-$version-win-$architecture.zip"
$directoryName = "node-$version-win-$architecture"
$targetDirectory = Join-Path $InstallRoot $directoryName
$nodePath = Join-Path $targetDirectory "node.exe"

if (Test-Path -LiteralPath $nodePath -PathType Leaf) {
    $ltsName = $null
    try { $ltsName = Assert-NodeRuntime $targetDirectory }
    catch { Write-Output "The cached Node.js/npm runtime needs repair. Downloading a fresh private copy." }
    if ($ltsName) {
        Set-Content -LiteralPath (Join-Path $InstallRoot "node-current.txt") -Value $directoryName -Encoding ASCII
        Write-Output "Node.js $version LTS ($ltsName) is already ready."
        exit 0
    }
}

$temporaryDirectory = Join-Path $InstallRoot (".download-" + [Guid]::NewGuid().ToString("N"))
Assert-PathInsideRoot $temporaryDirectory $InstallRoot
New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null

try {
    $archivePath = Join-Path $temporaryDirectory $archiveName
    $checksumsPath = Join-Path $temporaryDirectory "SHASUMS256.txt"
    $releaseBaseUrl = "https://nodejs.org/dist/$version"

    Write-Output "Downloading Node.js $version LTS for Windows $architecture..."
    Invoke-WebRequest -Uri "$releaseBaseUrl/$archiveName" -OutFile $archivePath -UseBasicParsing -TimeoutSec 600
    Invoke-WebRequest -Uri "$releaseBaseUrl/SHASUMS256.txt" -OutFile $checksumsPath -UseBasicParsing -TimeoutSec 60

    $expectedHash = $null
    $escapedArchiveName = [regex]::Escape($archiveName)
    foreach ($line in Get-Content -LiteralPath $checksumsPath) {
        if ($line -match "^([0-9a-fA-F]{64})\s+\*?$escapedArchiveName$") {
            $expectedHash = $matches[1]
            break
        }
    }
    if (-not $expectedHash) { throw "The official checksum list did not contain $archiveName." }

    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if (-not $actualHash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Node.js archive checksum verification failed."
    }
    Write-Output "Verified the official SHA-256 checksum."

    $extractDirectory = Join-Path $temporaryDirectory "extract"
    Assert-NodeZipPaths $archivePath $extractDirectory
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDirectory -Force
    $extractedDirectory = Join-Path $extractDirectory $directoryName
    [void](Assert-NodeRuntime $extractedDirectory)

    if (Test-Path -LiteralPath $targetDirectory) {
        $targetDirectory = Join-Path $InstallRoot ($directoryName + "-repair-" + [Guid]::NewGuid().ToString("N"))
        Assert-PathInsideRoot $targetDirectory $InstallRoot
    }
    Move-Item -LiteralPath $extractedDirectory -Destination $targetDirectory
    $activeDirectoryName = Split-Path -Leaf $targetDirectory
    $installedLtsName = Assert-NodeRuntime $targetDirectory
    # Activate only after both Node.js and npm run successfully from their final location.
    Set-Content -LiteralPath (Join-Path $InstallRoot "node-current.txt") -Value $activeDirectoryName -Encoding ASCII
    Write-Output "Installed and verified Node.js $version LTS ($installedLtsName) and bundled npm."
}
finally {
    if ((Test-Path -LiteralPath $temporaryDirectory) -and (Split-Path -Leaf $temporaryDirectory) -cmatch '^\.download-[a-f0-9]{32}$') {
        Assert-PathInsideRoot $temporaryDirectory $InstallRoot
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
