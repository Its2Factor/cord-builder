# Build readiness: completion markers, source tracking and cached checks for each workflow step.
# Dot-sourced by VencordEquicordBuilder.ps1; functions use the app's script-scope controls and state.

function Get-DependenciesMarkerPath {
    return Join-Path (Get-ProjectPath) "node_modules\.cord-builder-ready"
}

function Get-BuildMarkerPath {
    return Join-Path (Get-ProjectPath) "dist\.cord-builder-ready"
}

function Clear-ReadinessCache {
    $script:ReadinessCache = @{}
}

function Set-DependenciesReady {
    $marker = Get-DependenciesMarkerPath
    if (Test-Path -LiteralPath (Split-Path -Parent $marker) -PathType Container) {
        Set-Content -LiteralPath $marker -Value "Dependencies completed by Cord Builder at $(Get-Date -Format o)" -Encoding UTF8
    }
    Clear-ReadinessCache
}

function Set-BuildReady {
    $snapshot = Read-VerifiedBuildSnapshot (Get-ProjectPath)
    if ($null -eq $snapshot) { throw "The build did not save a verified source snapshot." }
    Reset-SourceTracking
    $script:SourceHash = $snapshot.InputHash
    $script:BuildInvalidated = $false
    Clear-ReadinessCache
}

function Reset-SourceTracking {
    if ($null -ne $script:SourceScanCancellation) {
        $script:SourceScanCancellation.Cancel()
        $script:SourceScanCancellation.Dispose()
    }
    $script:SourceScanCancellation = $null
    $script:SourceSnapshotTask = $null
    $script:SourcePath = Get-ProjectPath
    $script:SourceHash = $null
    $script:SourceError = $null
    $script:NextSourceScan = [DateTime]::MinValue
    Clear-ReadinessCache
}

function Update-SourceTracking {
    $path = Get-ProjectPath
    if ($path -ne $script:SourcePath) { Reset-SourceTracking }
    if ($null -ne $script:SourceSnapshotTask -and $script:SourceSnapshotTask.IsCompleted) {
        $oldHash = $script:SourceHash
        $oldError = $script:SourceError
        try {
            $script:SourceHash = $script:SourceSnapshotTask.GetAwaiter().GetResult()
            $script:SourceError = $null
        }
        catch {
            $script:SourceHash = $null
            $script:SourceError = $_.Exception.GetBaseException().Message
        }
        $script:SourceSnapshotTask = $null
        $script:SourceScanCancellation.Dispose()
        $script:SourceScanCancellation = $null
        $script:NextSourceScan = [DateTime]::UtcNow.AddSeconds(2)
        if ($oldError -ne $script:SourceError -and $script:SourceError) {
            Add-LogLine "Source check needs attention: $script:SourceError"
        }
        if ($oldHash -ne $script:SourceHash -or $oldError -ne $script:SourceError) { Update-WorkflowState }
    }
    if (-not $script:IsBusy -and -not $script:ToolSetupActive -and
        $null -eq $script:SourceSnapshotTask -and [DateTime]::UtcNow -ge $script:NextSourceScan -and
        (Test-DependenciesReady)) {
        $script:SourceScanCancellation = [Threading.CancellationTokenSource]::new()
        $script:SourceSnapshotTask = [CordSourceSnapshot]::ComputeAsync($path, $script:SourceScanCancellation.Token)
    }
}

function New-SourceCheckCommand {
    param([string] $Action, [string] $Label)
    return New-Command $Label "powershell.exe" @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "SourceTracking.ps1"),
        "-Action", $Action, "-ProjectPath", (Get-ProjectPath), "-Client", $script:CurrentClient,
        "-DevelopmentMode", ([bool]$DevModeCheck.IsChecked).ToString().ToLowerInvariant()
    ) $PSScriptRoot
}

function Invalidate-Dependencies {
    $marker = Get-DependenciesMarkerPath
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }
    Invalidate-Build
}

function Invalidate-Build {
    $script:BuildInvalidated = $true
    $marker = Get-BuildMarkerPath
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }
    Clear-ReadinessCache
}

function Assert-PreparedProject {
    $path = Get-ProjectPath
    $packagePath = Join-Path $path "package.json"
    $lockPath = Join-Path $path "pnpm-lock.yaml"
    $modulesPath = Join-Path $path "node_modules"
    $pnpmStorePath = Join-Path $modulesPath ".pnpm"

    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { throw "package.json was not found." }
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw "pnpm-lock.yaml was not found." }
    if (-not (Test-Path -LiteralPath $modulesPath -PathType Container)) { throw "node_modules was not created." }
    if (-not (Test-Path -LiteralPath $pnpmStorePath -PathType Container)) { throw "node_modules/.pnpm was not created, so dependency installation is incomplete." }

    try { $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json }
    catch { throw "package.json could not be parsed: $($_.Exception.Message)" }
    $scriptsProperty = $package.PSObject.Properties["scripts"]
    if ($null -eq $scriptsProperty) { throw "package.json has no scripts section." }
    if ($null -eq $scriptsProperty.Value.PSObject.Properties["build"]) { throw "package.json has no build script." }
    if ($null -eq $scriptsProperty.Value.PSObject.Properties["inject"]) { throw "package.json has no inject script." }

    Add-LogLine "Verified source, pnpm lockfile, project scripts, and installed dependency store."
}

function Test-PackageScript {
    param([string] $Name)
    try {
        $package = Get-Content -LiteralPath (Join-Path (Get-ProjectPath) "package.json") -Raw -ErrorAction Stop | ConvertFrom-Json
        $scripts = $package.PSObject.Properties["scripts"]
        return $null -ne $scripts -and $null -ne $scripts.Value.PSObject.Properties[$Name]
    }
    catch { return $false }
}

function Assert-BuildOutput {
    $distPath = Join-Path (Get-ProjectPath) "dist"
    if (-not (Test-Path -LiteralPath $distPath -PathType Container)) { throw "The dist folder was not created." }
    $javascriptOutput = Get-ChildItem -LiteralPath $distPath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".js", ".cjs", ".mjs") -and $_.Length -gt 0 } |
        Select-Object -First 1
    if ($null -eq $javascriptOutput) { throw "No non-empty JavaScript build output was found in dist." }
    Add-LogLine "Verified build output: $($javascriptOutput.FullName)"
}

function Test-DependenciesReady {
    $path = Get-ProjectPath
    if (-not $path) { return $false }
    return (Test-Path -LiteralPath (Join-Path $path "package.json") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $path "node_modules") -PathType Container) -and
        (Test-Path -LiteralPath (Get-DependenciesMarkerPath) -PathType Leaf)
}

function Get-CachedReadiness {
    # Readiness checks walk dist and read Discord's files, so reuse a result briefly while nothing changed.
    param([string] $Kind, [scriptblock] $Compute)
    $target = Get-SelectedDiscordChannel
    $key = @($Kind, (Get-ProjectPath), $script:CurrentClient, [bool]$DevModeCheck.IsChecked, $script:SourceHash,
        $script:SourcePath, $script:BuildInvalidated, (Get-OptionalProperty $target "Branch"), (Get-OptionalProperty $target "AppPath")) -join '|'
    $cache = Get-ScriptState "ReadinessCache"
    if ($null -eq $cache) { $cache = @{}; $script:ReadinessCache = $cache }
    $entry = $cache[$Kind]
    if ($null -ne $entry -and $entry.Key -eq $key -and $entry.Expires -gt [DateTime]::UtcNow) { return $entry.Value }
    $value = [bool](& $Compute)
    $cache[$Kind] = @{ Key = $key; Value = $value; Expires = [DateTime]::UtcNow.AddSeconds(3) }
    return $value
}

function Test-BuildReady {
    return Get-CachedReadiness "Build" {
        if ($script:BuildInvalidated -or -not (Test-DependenciesReady) -or -not $script:SourceHash -or
            $script:SourcePath -ne (Get-ProjectPath)) { return $false }
        $snapshot = Read-VerifiedBuildSnapshot (Get-ProjectPath)
        if ($null -eq $snapshot -or $snapshot.InputHash -ne $script:SourceHash -or
            $snapshot.Client -ne $script:CurrentClient -or $snapshot.DevelopmentMode -ne [bool]$DevModeCheck.IsChecked) { return $false }
        $distPath = Join-Path (Get-ProjectPath) "dist"
        return (Test-Path -LiteralPath $distPath -PathType Container) -and
            (Test-Path -LiteralPath (Get-BuildMarkerPath) -PathType Leaf) -and
            ($null -ne (Get-ChildItem -LiteralPath $distPath -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @(".js", ".cjs", ".mjs") -and $_.Length -gt 0 } | Select-Object -First 1))
    }
}

function Test-InjectionReady {
    if (-not (Test-BuildReady)) { return $false }
    return Get-CachedReadiness "Injection" { $null -ne (Find-DiscordInjectionEvidence) }
}
