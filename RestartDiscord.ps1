[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ProductRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Discord", "DiscordPTB", "DiscordCanary", "DiscordDevelopment")]
    [string] $ProcessName
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$resolvedRoot = [IO.Path]::GetFullPath($ProductRoot).TrimEnd('\', '/')
if ((Split-Path -Leaf $resolvedRoot) -ne $ProcessName) {
    throw "Discord product folder does not match the requested process."
}

$running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
foreach ($process in $running) {
    try { [void]$process.CloseMainWindow() }
    catch { }
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

$updatePath = Join-Path $resolvedRoot "Update.exe"
if (Test-Path -LiteralPath $updatePath -PathType Leaf) {
    Start-Process -FilePath $updatePath -ArgumentList @("--processStart", "$ProcessName.exe") -WindowStyle Hidden
}
else {
    $latestApp = Get-ChildItem -LiteralPath $resolvedRoot -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latestApp) { throw "No Discord app directory was found in $resolvedRoot." }
    $executable = Join-Path $latestApp.FullName "$ProcessName.exe"
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Discord executable was not found: $executable"
    }
    Start-Process -FilePath $executable
}

$launchDeadline = [DateTime]::UtcNow.AddSeconds(20)
do {
    Start-Sleep -Milliseconds 300
    if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
        Write-Output "$ProcessName restarted successfully."
        exit 0
    }
} while ([DateTime]::UtcNow -lt $launchDeadline)

throw "$ProcessName did not start within 20 seconds."
