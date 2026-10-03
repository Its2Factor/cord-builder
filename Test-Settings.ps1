param([string] $AppPath = (Join-Path $PSScriptRoot "VencordEquicordBuilder.ps1"))

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($AppPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join "; ") }
$needed = @(
    "Get-UserSettingsPath", "Test-SourceCheckout", "Get-DefaultSourcePath",
    "Test-AbsoluteSettingsPath", "Test-LegacySourceOwnership",
    "Get-DefaultSettings", "Load-Settings", "Save-Settings"
)
# The app's functions live in the main script and its dot-sourced CordBuilder.*.ps1 parts.
$appAsts = @($ast) + @(Get-ChildItem -LiteralPath (Split-Path -Parent $AppPath) -Filter "CordBuilder.*.ps1" | ForEach-Object {
    $partAst = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors.Message -join "; ") }
    $partAst
})
foreach ($definition in @($appAsts | ForEach-Object { $_.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) })) {
    if ($definition.Name -in $needed) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    if ($Actual -ne $Expected) { throw "$Message (expected $Expected, got $Actual)" }
}
function Get-CurrentUserContext { return $script:TestUser }
function New-TestCheckout {
    param([string] $Path, [string] $Client)
    New-Item -ItemType Directory -Path (Join-Path $Path ".git"), (Join-Path $Path "src") -Force | Out-Null
    @{ name = $Client.ToLowerInvariant(); scripts = @{ build = "test"; inject = "test" } } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Path "package.json") -Encoding UTF8
}
function Set-TestUser {
    param([string] $Name, [switch] $OneDrive)
    $profile = Join-Path $testRoot $Name
    $cloudRoot = Join-Path $profile "OneDrive"
    $script:TestUser = [pscustomobject]@{
        Sid = "test-sid-$Name"
        Profile = $profile
        Documents = if ($OneDrive) { Join-Path $cloudRoot "Documents" } else { Join-Path $profile "Documents" }
        Desktop = Join-Path $profile "Desktop"
        LocalAppData = Join-Path $profile "AppData\Local"
        OneDrive = if ($OneDrive) { @($cloudRoot) } else { @() }
    }
    $script:SettingsPath = Get-UserSettingsPath
}
function Save-TestSettings {
    param([object] $Value)
    $script:Settings = $Value
    $script:CurrentClient = $Value.LastClient
    $script:ProjectPathBox = [pscustomobject]@{ Text = $Value.($Value.LastClient + "Path") }
    $script:DevModeCheck = [pscustomobject]@{ IsChecked = $Value.DevMode }
    $script:DiscordChannelCombo = [pscustomobject]@{ SelectedItem = [pscustomobject]@{ Branch = $Value.TargetBranch } }
    Save-Settings
    Assert-Equal (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) $true "Settings must be written into this user's app-data folder"
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempRoot ("CordBuilder-SettingsTest-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $script:LegacySettingsPath = Join-Path $testRoot "builder.settings.json"
    Set-TestUser "Original"
    $originalProfile = $script:TestUser.Profile
    $originalVencord = Join-Path $script:TestUser.Documents "Vencord"
    $originalEquicord = Join-Path $script:TestUser.Documents "Equicord"
    New-TestCheckout $originalVencord "Vencord"
    New-TestCheckout $originalEquicord "Equicord"
    @{
        VencordPath = $originalVencord; EquicordPath = $originalEquicord
        LastClient = "Equicord"; TargetBranch = "ptb"; AutoRestart = $false; DevMode = $true
    } | ConvertTo-Json | Set-Content -LiteralPath $script:LegacySettingsPath -Encoding UTF8
    $legacyHash = (Get-FileHash -LiteralPath $script:LegacySettingsPath).Hash

    # Copying the app to another account must not inherit the original paths or preferences,
    # even if the old user's source folders are accessible on the same computer.
    Set-TestUser "Other" -OneDrive
    $loaded = Load-Settings
    Assert-Equal ($null -eq $loaded.PSObject.Properties["AutoRestart"]) $true "The removed restart preference must not be loaded"
    Assert-Equal $loaded.EquicordPath (Join-Path $script:TestUser.Documents "Equicord") "Use the current user's redirected Documents"
    Assert-Equal $loaded.VencordPath (Join-Path $script:TestUser.Documents "Vencord") "Both clients must belong to the current user"
    Assert-Equal $loaded.TargetBranch "stable" "Do not inherit another user's PTB selection"
    Assert-Equal $loaded.DevMode $false "Do not inherit another user's development mode"
    Assert-Equal (Test-Path -LiteralPath $script:TestUser.Documents) $false "Detection must not create a source folder"

    # Find existing checkouts in current-user locations instead of choosing an empty default.
    $existing = Join-Path $script:TestUser.Profile "source\repos\Equicord"
    New-TestCheckout $existing "Equicord"
    Assert-Equal (Get-DefaultSettings).EquicordPath $existing "Detect an existing checkout in source/repos"
    $wrongClient = Join-Path $script:TestUser.Documents "Equicord"
    New-TestCheckout $wrongClient "Vencord"
    Assert-Equal (Get-DefaultSettings).EquicordPath $existing "A folder with the wrong project must not win detection"
    New-TestCheckout $wrongClient "Equicord"
    Assert-Equal (Get-DefaultSettings).EquicordPath $wrongClient "A valid checkout in redirected Documents has priority"

    # A Browse selection on another drive/shared location remains a deliberate personal choice.
    $custom = Join-Path $testRoot "shared-development\custom-equicord"
    $loaded = Get-DefaultSettings
    $loaded.EquicordPath = $custom
    $loaded.LastClient = "Equicord"
    Save-TestSettings $loaded
    $otherSettingsPath = $script:SettingsPath
    Assert-Equal (Load-Settings).EquicordPath $custom "Keep personal custom paths even before cloning or while a drive is unavailable"
    Assert-Equal (Get-FileHash -LiteralPath $script:LegacySettingsPath).Hash $legacyHash "Saving must not change shared legacy settings"

    # The original owner can migrate their existing checkouts without affecting other users.
    Set-TestUser "Original"
    $loaded = Load-Settings
    Assert-Equal $loaded.EquicordPath $originalEquicord "Preserve the original user's own checkout"
    Assert-Equal $loaded.LastClient "Equicord" "Migrate preferences only with owned source paths"
    Save-TestSettings $loaded
    $originalSettingsPath = $script:SettingsPath
    Assert-Equal ($originalSettingsPath -eq $otherSettingsPath) $false "Each Windows user must have a separate settings file"

    # Even manually copying the new settings file across users cannot transfer their paths.
    Copy-Item -LiteralPath $otherSettingsPath -Destination $originalSettingsPath -Force
    Assert-Equal (Load-Settings).EquicordPath $originalEquicord "Reject another account's tagged settings"
    [IO.File]::WriteAllText($originalSettingsPath, "{broken")
    Assert-Equal (Load-Settings).EquicordPath $originalEquicord "Malformed settings must fall back to current-user discovery"
    [IO.File]::WriteAllText($originalSettingsPath, "{}")
    Assert-Equal (Load-Settings).VencordPath $originalVencord "Incomplete settings must not prevent launch"

    # Prefix matching must use a path boundary, not just the spelling of a username.
    $lookalike = Join-Path ($originalProfile + "Extra") "Documents\Equicord"
    New-TestCheckout $lookalike "Equicord"
    Assert-Equal (Test-LegacySourceOwnership $lookalike "Equicord" $script:TestUser) $false "Similar profile names must not count as the same user"
    Assert-Equal (Test-AbsoluteSettingsPath "C:Equicord") $false "Drive-relative paths must not be used as saved defaults"
    Write-Output "PASS: user isolation, OneDrive, source discovery, safe migration, personal custom paths and malformed settings."
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Path]::GetDirectoryName($resolved).Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -cmatch '^CordBuilder-SettingsTest-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
