[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ProductRoot,
    [Parameter(Mandatory = $true)][string] $AppPath,
    [Parameter(Mandatory = $true)]
    [ValidateSet("Discord", "DiscordPTB", "DiscordCanary", "DiscordDevelopment")]
    [string] $ProcessName,
    [string] $BackupRoot = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "CordBuilder\backups\Discord"),
    [switch] $SkipProcessStop
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Assert-DirectChildPath {
    param([string] $Parent, [string] $Child)
    $resolvedParent = Get-NormalizedPath $Parent
    $resolvedChild = Get-NormalizedPath $Child
    if (-not $resolvedChild.StartsWith($resolvedParent + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Get-NormalizedPath (Split-Path -Parent $resolvedChild)) -ne $resolvedParent) {
        throw "Discord app folder is not a direct child of the selected product folder."
    }
    if ((Split-Path -Leaf $resolvedChild) -notlike 'app-*') {
        throw "Discord app folder name is invalid: $resolvedChild"
    }
}

function Stop-SelectedDiscord {
    $running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) {
        Write-Output "$ProcessName is already closed."
        return
    }
    Write-Output "Closing $ProcessName before checking its injection files..."
    foreach ($process in $running) {
        try { [void]$process.CloseMainWindow() } catch { }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(6)
    do {
        $remaining = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    $remaining = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($remaining.Count -gt 0) {
        $remaining | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }
    if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
        throw "$ProcessName could not be closed safely. Close it manually and try again."
    }
    Write-Output "Verified $ProcessName is closed."
}

function Copy-VerifiedBackupFile {
    param([string] $Source, [string] $Destination)
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $backupHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $backupHash) {
        throw "Backup verification failed for $Source. No repair was attempted."
    }
    return [pscustomobject]@{
        Source = $Source
        Backup = $Destination
        Sha256 = $sourceHash
        Length = (Get-Item -LiteralPath $Source).Length
    }
}

$resolvedRoot = Get-NormalizedPath $ProductRoot
$resolvedApp = Get-NormalizedPath $AppPath
if ((Split-Path -Leaf $resolvedRoot) -ne $ProcessName) {
    throw "Discord product folder does not match the requested process."
}
Assert-DirectChildPath -Parent $resolvedRoot -Child $resolvedApp

$discordExe = Join-Path $resolvedApp "$ProcessName.exe"
$resources = Join-Path $resolvedApp "resources"
if (-not (Test-Path -LiteralPath $discordExe -PathType Leaf)) {
    throw "The selected Discord executable is missing: $discordExe"
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
    throw "The selected Discord resources folder is missing: $resources"
}

$appAsar = Join-Path $resources "app.asar"
$savedAppAsar = Join-Path $resources "_app.asar"
$hasAppAsar = Test-Path -LiteralPath $appAsar -PathType Leaf
$hasSavedAppAsar = Test-Path -LiteralPath $savedAppAsar -PathType Leaf

if (-not $SkipProcessStop) { Stop-SelectedDiscord }
else { Write-Output "Process stop skipped for isolated testing." }

if ($hasAppAsar) {
    if ($hasSavedAppAsar) {
        Write-Output "Discord injection state is complete. The injector can safely unpatch and reapply it."
    } else {
        Write-Output "Discord has its original app.asar. No pre-injection repair is needed."
    }
    exit 0
}
if (-not $hasSavedAppAsar) {
    throw "Discord is missing both app.asar and _app.asar. Cord Builder will not guess or delete files. Repair or reinstall only this Discord channel, then try again. Your roaming Discord data was not touched."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupFolder = Join-Path (Get-NormalizedPath $BackupRoot) ("{0}-{1}-{2}" -f $ProcessName, (Split-Path -Leaf $resolvedApp), $stamp)
if (Test-Path -LiteralPath $backupFolder) {
    $backupFolder += "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
}
New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null

$records = [System.Collections.Generic.List[object]]::new()
$records.Add((Copy-VerifiedBackupFile -Source $savedAppAsar -Destination (Join-Path $backupFolder "resources\_app.asar")))
foreach ($relativePath in @("resources\build_info.json", "resources\bootstrap\manifest.json", "resources\app\package.json", "resources\app\index.js")) {
    $candidate = Join-Path $resolvedApp $relativePath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $records.Add((Copy-VerifiedBackupFile -Source $candidate -Destination (Join-Path $backupFolder $relativePath)))
    }
}

$manifestPath = Join-Path $backupFolder "repair-manifest.json"
[pscustomobject]@{
    CreatedUtc = [DateTime]::UtcNow.ToString("o")
    ProductRoot = $resolvedRoot
    AppPath = $resolvedApp
    ProcessName = $ProcessName
    Repair = "Restore missing app.asar from _app.asar"
    Files = $records.ToArray()
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "The repair manifest could not be created. No repair was attempted."
}

$savedHash = (Get-FileHash -LiteralPath $savedAppAsar -Algorithm SHA256).Hash
Move-Item -LiteralPath $savedAppAsar -Destination $appAsar
if (-not (Test-Path -LiteralPath $appAsar -PathType Leaf) -or
    (Test-Path -LiteralPath $savedAppAsar) -or
    (Get-FileHash -LiteralPath $appAsar -Algorithm SHA256).Hash -ne $savedHash) {
    throw "Discord's app.asar restore did not verify. The recovery copy is preserved at $backupFolder."
}
Write-Output "Repaired the incomplete Discord injection state."
Write-Output "Verified restored app.asar SHA-256: $savedHash"
Write-Output "Recovery backup: $backupFolder"
