# Discord: installed channels, patch detection, injection, restore and restart.
# Dot-sourced by VencordEquicordBuilder.ps1; functions use the app's script-scope controls and state.

function Get-DiscordChannelDefinitions {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    return @(
        [pscustomobject]@{ Branch = "stable"; Label = "Discord Stable"; ProcessName = "Discord"; ProductRoot = Join-Path $localAppData "Discord" },
        [pscustomobject]@{ Branch = "ptb"; Label = "Discord PTB"; ProcessName = "DiscordPTB"; ProductRoot = Join-Path $localAppData "DiscordPTB" },
        [pscustomobject]@{ Branch = "canary"; Label = "Discord Canary"; ProcessName = "DiscordCanary"; ProductRoot = Join-Path $localAppData "DiscordCanary" },
        [pscustomobject]@{ Branch = "development"; Label = "Discord Development"; ProcessName = "DiscordDevelopment"; ProductRoot = Join-Path $localAppData "DiscordDevelopment" }
    )
}

function Get-DiscordAppFolders {
    param([object] $Channel)
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        Get-ChildItem -LiteralPath $Channel.ProductRoot -Directory -Filter "app-*" -ErrorAction Stop | ForEach-Object {
            [void]$paths.Add($_.FullName)
        }
    }
    catch { }

    foreach ($process in @(Get-Process -Name $Channel.ProcessName -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path) { [void]$paths.Add((Split-Path -Parent $process.Path)) }
        }
        catch { }
    }

    $folders = foreach ($path in $paths) {
        try { Get-Item -LiteralPath $path -Force -ErrorAction Stop }
        catch { }
    }
    return @($folders)
}

function Get-InstalledDiscordChannels {
    $installed = [System.Collections.Generic.List[object]]::new()
    foreach ($channel in Get-DiscordChannelDefinitions) {
        if (-not (Test-Path -LiteralPath $channel.ProductRoot -PathType Container) -and
            -not (Get-Process -Name $channel.ProcessName -ErrorAction SilentlyContinue)) { continue }

        $versions = [System.Collections.Generic.List[object]]::new()
        foreach ($appFolder in @(Get-DiscordAppFolders $channel)) {
            $executable = Join-Path $appFolder.FullName "$($channel.ProcessName).exe"
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { continue }
            $versionText = $appFolder.Name -replace '^app-', ''
            $versionObject = [version]::new(0, 0)
            [void][version]::TryParse($versionText, [ref]$versionObject)
            $versions.Add([pscustomobject]@{ Text = $versionText; Value = $versionObject; AppPath = $appFolder.FullName })
        }
        $latest = $versions | Sort-Object Value -Descending | Select-Object -First 1
        $versionLabel = if ($latest) { $latest.Text } else { "version unknown" }
        $installed.Add([pscustomobject]@{
            Branch = $channel.Branch
            Label = $channel.Label
            ProcessName = $channel.ProcessName
            ProductRoot = $channel.ProductRoot
            Version = if ($latest) { $latest.Text } else { $null }
            AppPath = if ($latest) { $latest.AppPath } else { $null }
            DisplayName = "$($channel.Label)  -  $versionLabel"
        })
    }
    return $installed.ToArray()
}

function Get-SelectedDiscordChannel {
    return $DiscordChannelCombo.SelectedItem
}

function Update-DiscordChannelHint {
    $target = Get-SelectedDiscordChannel
    if ($null -eq $target) {
        $DiscordChannelHint.Text = "No Discord Desktop installation was found. Install Discord, then click Rescan."
        return
    }
    $DiscordChannelHint.Text = "Injection, verification and restarts affect only $($target.Label). Source and builds are shared."
}

function Initialize-DiscordChannels {
    $DiscordChannelCombo.Items.Clear()
    $channels = @(Get-InstalledDiscordChannels)
    foreach ($channel in $channels) { [void]$DiscordChannelCombo.Items.Add($channel) }

    $preferredBranch = if ($script:Settings.TargetBranch) { $script:Settings.TargetBranch } else { "stable" }
    $selected = $channels | Where-Object Branch -eq $preferredBranch | Select-Object -First 1
    if ($null -eq $selected) { $selected = $channels | Where-Object Branch -eq "stable" | Select-Object -First 1 }
    if ($null -eq $selected) { $selected = $channels | Select-Object -First 1 }
    $DiscordChannelCombo.SelectedItem = $selected
    Update-DiscordChannelHint
}

function Find-DiscordInjectionEvidence {
    $target = Get-SelectedDiscordChannel
    if ($null -eq $target) { return $null }
    $projectPath = Get-ProjectPath
    if (-not $projectPath) { return $null }
    try { $expectedDistPath = [IO.Path]::GetFullPath((Join-Path $projectPath "dist")).TrimEnd('\') }
    catch { return $null }

    foreach ($appFolder in @(Get-DiscordAppFolders $target)) {
        foreach ($relativePath in @("resources\app\index.js", "resources\app.asar\index.js", "resources\app.asar")) {
            $candidate = Join-Path $appFolder.FullName $relativePath
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            if ($relativePath -eq "resources\app.asar" -and (Get-Item -LiteralPath $candidate).Length -gt 1MB) { continue }
            try { $content = Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop }
            catch { continue }
            $normalizedContent = $content.Replace('\\', '\').Replace('/', '\')
            if ($normalizedContent.IndexOf($expectedDistPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $candidate
            }
        }
    }
    return $null
}

function Test-DiscordPatched {
    # True when the selected channel carries any Vencord/Equicord patch, from this checkout or another.
    $appPath = Get-OptionalProperty (Get-SelectedDiscordChannel) "AppPath"
    if (-not $appPath) { return $false }
    return Test-Path -LiteralPath (Join-Path $appPath "resources\_app.asar") -PathType Leaf
}

function Test-DiscordPatchedHere {
    # True when the selected channel loads this checkout's build output, whether or not that build is current.
    if ($null -eq (Get-SelectedDiscordChannel)) { return $false }
    return Get-CachedReadiness "PatchedHere" { $null -ne (Find-DiscordInjectionEvidence) }
}

function New-DiscordRestartCommand {
    param([object] $Target)
    $helperPath = Join-Path $PSScriptRoot "RestartDiscord.ps1"
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "Discord restart helper is missing: $helperPath"
    }
    return New-Command "Restart $($Target.ProcessName)" "powershell.exe" @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $helperPath,
        "-ProductRoot", $Target.ProductRoot,
        "-ProcessName", $Target.ProcessName
    ) $PSScriptRoot
}

function Queue-VerifiedDiscordRestart {
    if (-not (Test-BuildReady)) { throw "The build no longer matches the source. Build again before restarting Discord." }
    $target = Get-SelectedDiscordChannel
    if ($null -eq $target) {
        Add-LogLine "Build verified. No installed Discord target is selected, so there is nothing to restart."
        return
    }

    $script:DeferredCommands = @(
        (New-SourceCheckCommand "Check" "Verify source before restarting Discord"),
        (New-DiscordRestartCommand $target)
    )
    $script:DeferredOnSuccess = {
        Clear-ReadinessCache
        if (Find-DiscordInjectionEvidence) { Add-LogLine "Discord restarted successfully with the verified build." }
        else { Add-LogLine "Discord restarted. Inject once to load this source build, then the app will restart it again." }
        Set-AppStatus "Discord restarted" "Success"
    }
    Add-LogLine "Verified work is complete; Discord restart has been queued."
}

function Assert-InjectionCompletion {
    Clear-ReadinessCache
    if (-not (Test-BuildReady)) { throw "The verified build output is no longer available." }
    $target = Get-SelectedDiscordChannel
    if ($null -eq $target) { throw "No Discord target is selected." }
    $evidencePath = Find-DiscordInjectionEvidence
    if (-not $evidencePath) {
        throw "The injector exited, but $($target.DisplayName) is not loading this source build from $(Join-Path (Get-ProjectPath) 'dist'). An older packaged injection does not count as verified."
    }
    Add-LogLine "Verified $($target.DisplayName) patch: $evidencePath"
}

function Get-InstallerArguments {
    param([string] $Script)
    $target = Get-SelectedDiscordChannel
    if ($null -eq $target) { return @($Script) }

    # The installers expose named branches for the public release channels.
    # Discord Development is a separate local product, so target its root directly.
    if ($target.Branch -eq "development") {
        return @($Script, "-location", $target.ProductRoot)
    }
    return @($Script, "-branch", $target.Branch)
}

function Get-InjectArguments {
    return Get-InstallerArguments "inject"
}

function Get-InjectionTarget {
    # Shared checks for inject and restore; returns the selected channel or $null after explaining why not.
    if ($script:IsBusy) { return $null }
    if (-not (Test-RequiredTools)) { return $null }
    if (-not (Test-ProjectRoot)) { return $null }
    if (-not (Test-NotElevated)) { return $null }
    if (-not (Test-SafeProjectPath (Get-ProjectPath))) { return $null }
    $target = Get-SelectedDiscordChannel
    if ($null -eq $target) {
        Add-LogLine "Select an installed Discord channel first."
        Set-AppStatus "No Discord target" "Error"
        return $null
    }
    if (-not $target.AppPath) {
        Add-LogLine "The selected Discord version folder could not be identified. Restart or repair that Discord installation, then rescan."
        Set-AppStatus "Discord version not found" "Error"
        return $null
    }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "RepairDiscordInjection.ps1") -PathType Leaf)) {
        Add-LogLine "Discord repair helper is missing: $(Join-Path $PSScriptRoot 'RepairDiscordInjection.ps1')"
        Set-AppStatus "Repair helper missing" "Error"
        return $null
    }
    return $target
}

function New-DiscordRepairCommand {
    param([object] $Target, [string] $Label)
    return New-Command $Label "powershell.exe" @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "RepairDiscordInjection.ps1"),
        "-ProductRoot", $Target.ProductRoot,
        "-AppPath", $Target.AppPath,
        "-ProcessName", $Target.ProcessName
    ) $PSScriptRoot
}

function Start-Injection {
    $target = Get-InjectionTarget
    if ($null -eq $target) { return }
    $tools = Get-ToolPaths
    $onSuccess = {
        Assert-InjectionCompletion
        Update-WorkflowState
        Add-LogLine "Injection step verified. Fully restart Discord to load the build."
        Add-HistoryEntry "Installed $script:CurrentClient into $((Get-SelectedDiscordChannel).Label)"
        Queue-VerifiedDiscordRestart
    }
    Start-CommandSequence @(
        (New-SourceCheckCommand "Check" "Verify source before injection"),
        (New-Command "Diagnose and repair $($target.DisplayName)" "powershell.exe" @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $PSScriptRoot "RepairDiscordInjection.ps1"),
            "-ProductRoot", $target.ProductRoot,
            "-AppPath", $target.AppPath,
            "-ProcessName", $target.ProcessName
        ) $PSScriptRoot),
        (New-Command "Inject $($target.DisplayName)" $tools.Pnpm (Get-InjectArguments) (Get-ProjectPath))
    ) $onSuccess
}

function Start-RestoreDiscord {
    $target = Get-InjectionTarget
    if ($null -eq $target) { return }
    if (-not (Test-PackageScript "uninject")) {
        Add-LogLine "This $script:CurrentClient checkout has no uninject script, so Cord Builder can't restore Discord with it."
        Set-AppStatus "Restore unavailable" "Error"
        return
    }
    $answer = [System.Windows.MessageBox]::Show($window,
        "Restore $($target.Label) to its original files?`n`n$script:CurrentClient stops loading until you install it again. Discord closes and restarts.",
        "Restore stock Discord", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $tools = Get-ToolPaths
    $onSuccess = {
        Clear-ReadinessCache
        if (Test-DiscordPatched) { throw "The uninstaller exited, but the selected Discord channel still has a patch in place." }
        $target = Get-SelectedDiscordChannel
        Add-LogLine "Verified $($target.Label) is back to its original files."
        Add-HistoryEntry "Restored $($target.Label) to stock"
        $script:DeferredCommands = @((New-DiscordRestartCommand $target))
        $script:DeferredOnSuccess = { Set-AppStatus "Discord restored" "Success" }
    }
    Start-CommandSequence @(
        (New-DiscordRepairCommand $target "Check $($target.DisplayName) before restoring"),
        (New-Command "Restore stock $($target.DisplayName)" $tools.Pnpm (Get-InstallerArguments "uninject") (Get-ProjectPath))
    ) $onSuccess
}

function Rescan-Discord {
    if ($script:IsBusy) { return }
    Save-Settings
    Initialize-DiscordChannels
    Clear-ReadinessCache
    $count = $DiscordChannelCombo.Items.Count
    Add-LogLine $(if ($count -eq 1) { "Found 1 Discord installation." } else { "Found $count Discord installations." })
    Update-WorkflowState
}
