[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$helper = Join-Path $PSScriptRoot "RepairDiscordInjection.ps1"
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw "Repair helper is missing." }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("CordBuilder-RepairTest-" + [Guid]::NewGuid().ToString("N"))
$backupRoot = Join-Path $testRoot "backups"

function New-FakeDiscord {
    param([string] $Name)
    $product = Join-Path $testRoot $Name
    $app = Join-Path $product "app-1.2.3"
    $resources = Join-Path $app "resources"
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $app "$Name.exe") -Value "fake executable" -Encoding UTF8
    return [pscustomobject]@{ Product = $product; App = $app; Resources = $resources }
}

function Invoke-Repair {
    param([object] $Install)
    & $helper -ProductRoot $Install.Product -AppPath $Install.App -ProcessName (Split-Path -Leaf $Install.Product) -BackupRoot $backupRoot -SkipProcessStop
}

try {
    $clean = New-FakeDiscord "Discord"
    Set-Content -LiteralPath (Join-Path $clean.Resources "app.asar") -Value "original" -Encoding UTF8
    $cleanOutput = @(Invoke-Repair $clean) -join [Environment]::NewLine
    if ($cleanOutput -notmatch "No pre-injection repair") { throw "Clean state was not recognized." }
    if (Test-Path -LiteralPath $backupRoot) { throw "Clean state created an unnecessary backup." }

    $patched = New-FakeDiscord "DiscordPTB"
    Set-Content -LiteralPath (Join-Path $patched.Resources "app.asar") -Value "loader" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $patched.Resources "_app.asar") -Value "original" -Encoding UTF8
    $patchedOutput = @(Invoke-Repair $patched) -join [Environment]::NewLine
    if ($patchedOutput -notmatch "injection state is complete") { throw "Patched state was not recognized." }
    if (-not (Test-Path -LiteralPath (Join-Path $patched.Resources "_app.asar") -PathType Leaf)) { throw "Patched state was changed." }

    $broken = New-FakeDiscord "DiscordCanary"
    New-Item -ItemType Directory -Path (Join-Path $broken.Resources "bootstrap") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $broken.Resources "bootstrap\manifest.json") -Value '{"patched":true}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $broken.Resources "_app.asar") -Value "recoverable original content" -Encoding UTF8
    $beforeHash = (Get-FileHash -LiteralPath (Join-Path $broken.Resources "_app.asar") -Algorithm SHA256).Hash
    $brokenOutput = @(Invoke-Repair $broken) -join [Environment]::NewLine
    $restored = Join-Path $broken.Resources "app.asar"
    if (-not (Test-Path -LiteralPath $restored -PathType Leaf)) { throw "Broken state was not restored." }
    if (Test-Path -LiteralPath (Join-Path $broken.Resources "_app.asar")) { throw "Saved app.asar remained after restore." }
    if ((Get-FileHash -LiteralPath $restored -Algorithm SHA256).Hash -ne $beforeHash) { throw "Restored app.asar hash changed." }
    $manifest = Get-ChildItem -LiteralPath $backupRoot -Filter "repair-manifest.json" -File -Recurse | Select-Object -First 1
    if ($null -eq $manifest) { throw "Repair backup manifest was not created." }
    $backup = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
    $asarRecord = @($backup.Files | Where-Object { $_.Source -like '*_app.asar' }) | Select-Object -First 1
    if ($null -eq $asarRecord -or $asarRecord.Sha256 -ne $beforeHash -or -not (Test-Path -LiteralPath $asarRecord.Backup -PathType Leaf)) {
        throw "Repair backup was not hash-verified."
    }
    if ($brokenOutput -notmatch "Verified restored app.asar SHA-256") { throw "Repair did not report verification." }

    $missing = New-FakeDiscord "DiscordDevelopment"
    $failedSafely = $false
    try { Invoke-Repair $missing | Out-Null }
    catch { $failedSafely = $_.Exception.Message -match "missing both app.asar and _app.asar" }
    if (-not $failedSafely) { throw "Unrecoverable state did not stop safely." }

    $outside = Join-Path $testRoot "outside\app-9.9.9"
    New-Item -ItemType Directory -Path (Join-Path $outside "resources") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $outside "Discord.exe") -Value "fake" -Encoding UTF8
    $rejectedOutside = $false
    try { & $helper -ProductRoot $clean.Product -AppPath $outside -ProcessName Discord -BackupRoot $backupRoot -SkipProcessStop | Out-Null }
    catch { $rejectedOutside = $_.Exception.Message -match "not a direct child" }
    if (-not $rejectedOutside) { throw "Outside app path was not rejected." }

    $builder = Get-Content -LiteralPath (Join-Path $PSScriptRoot "CordBuilder.Discord.ps1") -Raw
    $repairIndex = $builder.IndexOf('(New-Command "Diagnose and repair')
    $injectIndex = $builder.IndexOf('(New-Command "Inject $($target.DisplayName)"')
    if ($repairIndex -lt 0 -or $injectIndex -le $repairIndex) { throw "Repair is not queued before injection." }

    Write-Output "PASS: clean Discord state is left unchanged"
    Write-Output "PASS: complete patched state is left for the official injector"
    Write-Output "PASS: missing app.asar is restored only from a hash-verified _app.asar backup"
    Write-Output "PASS: ambiguous missing files stop without mutation"
    Write-Output "PASS: app paths outside the selected Discord product are rejected"
    Write-Output "PASS: repair is queued before the official injector"
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
