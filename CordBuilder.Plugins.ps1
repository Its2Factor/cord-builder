# User plugins: listing, layout checks, name clashes, turning plugins on and off, and the Plugins page.
# Dot-sourced by VencordEquicordBuilder.ps1; functions use the app's script-scope controls and state.

function Get-UserPluginsPath {
    return Join-Path (Get-ProjectPath) "src\userplugins"
}

function Get-PluginItemProblem {
    # Returns $null for a valid plugin, otherwise a short reason the user can act on.
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "Not found." }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        if ($script:CurrentClient -ne "Vencord") { return "Equicord needs each plugin in its own folder with an index.ts or index.tsx." }
        if ($item.Extension -notin @(".ts", ".tsx")) { return "Only .ts and .tsx files can be plugins." }
        if ($item.Length -eq 0) { return "The file is empty." }
        return $null
    }

    if ($script:CurrentClient -eq "Equicord" -and $item.Name -cnotmatch '^[a-z][A-Za-z0-9]*$') {
        return "Equicord folder names must be camelCase, for example myPlugin."
    }

    foreach ($entryName in @("index.ts", "index.tsx")) {
        $entryPath = Join-Path $item.FullName $entryName
        if ((Test-Path -LiteralPath $entryPath -PathType Leaf) -and (Get-Item -LiteralPath $entryPath).Length -gt 0) {
            return $null
        }
    }
    return "Missing a non-empty index.ts or index.tsx directly inside the folder."
}

function Test-PluginItemStructure {
    param([string] $Path)
    return $null -eq (Get-PluginItemProblem $Path)
}

function Get-PluginDeclaredName {
    # Reads the name given to definePlugin, which is how the client tells plugins apart.
    param([string] $Path)
    $entry = $Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $entry = @("index.ts", "index.tsx") | ForEach-Object { Join-Path $Path $_ } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
    if (-not $entry) { return $null }
    try { $text = [IO.File]::ReadAllText($entry) } catch { return $null }
    $match = [regex]::Match($text, 'definePlugin\s*\(\s*\{[\s\S]*?\bname\s*:\s*(["''`])(.+?)\1')
    if ($match.Success) { return $match.Groups[2].Value }
    return $null
}

function Get-BuiltInPluginNames {
    # Names of the plugins that ship with the client. Read once per checkout; Prepare clears the cache after updating.
    $path = Get-ProjectPath
    $key = "$path|$script:CurrentClient"
    $cached = Get-ScriptState "BuiltInPluginNames"
    if ($null -ne $cached -and (Get-ScriptState "BuiltInPluginNamesKey") -eq $key) { return ,$cached }
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($folder in @("plugins", "plugins\_api", "plugins\_core", "equicordplugins", "equicordplugins\_api", "equicordplugins\_core")) {
        $fullPath = Join-Path $path "src\$folder"
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) { continue }
        foreach ($entry in @(Get-ChildItem -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue)) {
            # The same entries the client's build skips.
            if ($entry.Name.StartsWith('_') -or $entry.Name.StartsWith('.') -or $entry.Name -eq "index.ts") { continue }
            if (-not $entry.PSIsContainer -and $entry.Extension -notin @(".ts", ".tsx")) { continue }
            $name = Get-PluginDeclaredName $entry.FullName
            if ($name) { [void]$names.Add($name) }
        }
    }
    $script:BuiltInPluginNames = $names
    $script:BuiltInPluginNamesKey = $key
    return ,$names
}

function Get-PluginModifiedTime {
    # A folder's own timestamp doesn't change when a file inside it is edited, so use the newest file.
    param([object] $Item)
    $latest = $Item.LastWriteTime
    if ($Item -is [IO.DirectoryInfo]) {
        foreach ($file in @(Get-ChildItem -LiteralPath $Item.FullName -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -gt $latest) { $latest = $file.LastWriteTime }
        }
    }
    return $latest
}

function Format-PluginTime {
    param([DateTime] $Time)
    $days = ([DateTime]::Today - $Time.Date).Days
    if ($days -le 0) { return "Today" }
    if ($days -eq 1) { return "Yesterday" }
    if ($days -lt 7) { return "$days days ago" }
    if ($Time.Year -eq [DateTime]::Today.Year) { return $Time.ToString("d MMM") }
    return $Time.ToString("d MMM yyyy")
}

function Add-PluginWarnings {
    # Two plugins with the same name don't fail the build: the later one silently replaces the earlier.
    param([object[]] $Items)
    $enabled = @($Items | Where-Object { $_.Enabled -and $_.DeclaredName })
    foreach ($group in @($enabled | Group-Object DeclaredName -CaseSensitive | Where-Object Count -gt 1)) {
        foreach ($item in $group.Group) {
            $others = @($group.Group | Where-Object { $_ -ne $item } | ForEach-Object { $_.DisplayName }) -join ", "
            $item.Warning = "Uses the plugin name `"$($item.DeclaredName)`", same as $others. Only one of them loads, so turn one off."
        }
    }
    $builtIns = Get-BuiltInPluginNames
    foreach ($item in @($enabled | Where-Object { -not $_.Warning -and $builtIns.Contains($_.DeclaredName) })) {
        $item.Warning = "Replaces $script:CurrentClient's built-in `"$($item.DeclaredName)`" plugin, because both use that name."
    }
}

function Get-PluginItems {
    # -Details adds last-changed dates, declared names and name-clash warnings for the Plugins page.
    param([switch] $Details)
    $pluginRoot = Get-UserPluginsPath
    if (-not (Test-Path -LiteralPath $pluginRoot -PathType Container)) { return @() }
    $hidden = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
    # Dot-folders such as .vscode and hidden system files are not plugins.
    $entries = @(Get-ChildItem -LiteralPath $pluginRoot -Force -ErrorAction Stop | Where-Object {
        -not $_.Name.StartsWith('.') -and -not ($_.Attributes -band $hidden) -and
        ($_.PSIsContainer -or $_.Extension -in @(".ts", ".tsx"))
    } | Sort-Object Name)
    $items = @($entries | ForEach-Object {
        # The client's build skips names starting with "_", which is how a plugin is turned off.
        $enabled = -not $_.Name.StartsWith('_')
        $problem = if ($enabled) { Get-PluginItemProblem $_.FullName } else { $null }
        [pscustomobject]@{
            Name = $_.Name
            DisplayName = $_.Name.TrimStart('_')
            Path = $_.FullName
            Kind = if ($_.PSIsContainer) { "Folder" } else { "File" }
            Enabled = $enabled
            Valid = $null -eq $problem
            Problem = if ($problem) { $problem } else { "" }
            Warning = ""
            DeclaredName = if ($Details) { Get-PluginDeclaredName $_.FullName } else { $null }
            Modified = if ($Details) { Format-PluginTime (Get-PluginModifiedTime $_) } else { "" }
            Note = ""
            State = ""
        }
    })
    if ($Details) { Add-PluginWarnings $items }
    foreach ($item in $items) {
        $item.State = if (-not $item.Enabled) { "Disabled" } elseif (-not $item.Valid) { "Invalid" } elseif ($item.Warning) { "Warning" } else { "Ok" }
        $item.Note = if ($item.Problem) { $item.Problem } else { $item.Warning }
    }
    return $items
}

function Get-InvalidPluginNames {
    return @(Get-PluginItems | Where-Object { -not $_.Valid } | ForEach-Object { $_.Name })
}

function Test-PluginsValidForBuild {
    return @(Get-InvalidPluginNames).Count -eq 0
}

function Set-PluginEnabled {
    # Turning a plugin off renames it with a leading "_" inside userplugins; nothing is moved or deleted.
    param([object] $Item, [bool] $Enabled)
    if ($script:IsBusy -or $script:ToolSetupActive) {
        Add-LogLine "Wait for the current task to finish before turning plugins on or off."
        Set-AppStatus "A task is running" "Error"
        return $false
    }
    $baseName = ([string]$Item.Name).TrimStart('_')
    $targetName = if ($Enabled) { $baseName } else { "_" + $baseName }
    if (-not $baseName -or $targetName -eq $Item.Name) { return $true }
    $root = Get-UserPluginsPath
    $target = Join-Path $root $targetName
    $verb = if ($Enabled) { "on" } else { "off" }
    if (Test-Path -LiteralPath $target) {
        Add-LogLine "Can't turn $baseName $verb because userplugins already contains $targetName. Rename or remove one of them."
        Set-AppStatus "Plugin name already in use" "Error"
        return $false
    }
    try { Rename-Item -LiteralPath (Join-Path $root $Item.Name) -NewName $targetName -ErrorAction Stop }
    catch {
        Add-LogLine "Couldn't turn $baseName ${verb}: $($_.Exception.Message) Close any editor or terminal using that folder, then try again."
        Set-AppStatus "Plugin change failed" "Error"
        return $false
    }
    Add-LogLine "Turned $baseName $verb. Build again to apply it."
    Add-HistoryEntry "Turned plugin $baseName $verb"
    Set-AppStatus "Turned $baseName $verb" "Success"
    return $true
}

function Open-PluginItem {
    # Opens a plugin in VS Code when it's installed, otherwise shows it in File Explorer.
    param([object] $Item, [switch] $Reveal)
    $path = Join-Path (Get-UserPluginsPath) $Item.Name
    if (-not (Test-Path -LiteralPath $path)) {
        Add-LogLine "$($Item.DisplayName) is no longer in userplugins."
        Request-PluginsRefresh
        return
    }
    $editor = if ($Reveal) { $null } else { Resolve-CommandPath @("code.cmd", "code") }
    try {
        if ($editor) { Start-Process -FilePath $editor -ArgumentList "`"$path`"" -WindowStyle Hidden }
        elseif ($Item.Kind -eq "Folder" -and -not $Reveal) { Start-Process -FilePath $path }
        else { Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$path`"" }
    }
    catch { Add-LogLine "Could not open $path : $($_.Exception.Message)" }
}

function Request-PluginsRefresh {
    $script:PluginItemsKey = $null
    Clear-ReadinessCache
    Update-WorkflowState
}

function Show-PluginList {
    # Applies the search box to both lists; turned-off plugins are listed separately.
    $filter = [string](Get-ScriptState "PluginFilter" "")
    $all = @($script:PluginItems)
    $visible = @($all | Where-Object {
        -not $filter -or $_.DisplayName.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ($_.DeclaredName -and $_.DeclaredName.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
    $PluginList.ItemsSource = @($visible | Where-Object { $_.Enabled })
    $disabled = @($visible | Where-Object { -not $_.Enabled })
    $DisabledPluginList.ItemsSource = $disabled
    $DisabledPluginsPanel.Visibility = if ($disabled.Count -gt 0) { "Visible" } else { "Collapsed" }
    $PluginsEmptyText.Visibility = if ($visible.Count -eq 0) { "Visible" } else { "Collapsed" }
    if ($all.Count -gt 0 -and $visible.Count -eq 0) { $PluginsEmptyText.Text = "No plugins match `"$filter`"." }
}

function Update-PluginsSummary {
    param([object] $State)
    $PluginsSummary.Inlines.Clear()
    if (-not $State.DependenciesReady) { $PluginsSummary.Inlines.Add([System.Windows.Documents.Run]::new("Prepare the source first.")); return }
    $all = @($script:PluginItems)
    $total = $all.Count
    $invalid = @($all | Where-Object State -eq "Invalid").Count
    $warned = @($all | Where-Object State -eq "Warning").Count
    $off = @($all | Where-Object State -eq "Disabled").Count
    $ready = $total - $invalid - $warned - $off
    $add = {
        param([string] $Text, [string] $Color, [bool] $Strong = $false)
        $run = [System.Windows.Documents.Run]::new($Text)
        if ($Color) { $run.Foreground = Get-Brush $Color }
        if ($Strong) { $run.FontWeight = "SemiBold" }
        $PluginsSummary.Inlines.Add($run)
    }
    & $add $(if ($total -eq 1) { "1 plugin" } else { "$total plugins" }) "#D1D1D6" $true
    if ($total -eq 0) { return }
    & $add " · $ready ready" ""
    if ($invalid -gt 0) { & $add " · $invalid need$(if ($invalid -eq 1) { 's' }) a fix" "#FF6961" }
    if ($warned -gt 0) { & $add " · $warned need$(if ($warned -eq 1) { 's' }) a look" "#FFB340" }
    if ($off -gt 0) { & $add " · $off off" "" }
}

function Update-PluginsView {
    param([object] $State)
    $key = "$(Get-ProjectPath)|$script:CurrentClient|$script:SourceHash|$($State.DependenciesReady)"
    if ($key -ne $script:PluginItemsKey) {
        $script:PluginItemsKey = $key
        try { $script:PluginItems = if ($State.DependenciesReady) { @(Get-PluginItems -Details) } else { @() } }
        catch { $script:PluginItems = @() }
        $PluginsEmptyText.Text = if (-not $State.DependenciesReady) { "Plugins appear here once the source is prepared." }
            else { "No user plugins yet. Open the folder and add one plugin per folder, each with an index.ts or index.tsx." }
        Show-PluginList
    }
    Update-PluginsSummary $State
    $PluginsSubtitle.Text = if ($State.DependenciesReady) { Get-UserPluginsPath } else { "" }
}

function Ensure-UserPluginsFolder {
    $folder = Get-UserPluginsPath
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Add-LogLine "Created $folder"
    }
}

function Open-UserPlugins {
    if ($script:IsBusy -or -not (Test-NotElevated)) { return }
    if (-not (Test-RequiredTools)) { return }
    if (-not (Test-ProjectRoot)) { return }
    if (-not (Test-DependenciesReady)) { return }
    if (-not (Test-SafeProjectPath (Get-ProjectPath))) { return }
    Ensure-UserPluginsFolder
    Start-Process -FilePath (Get-UserPluginsPath)
}
