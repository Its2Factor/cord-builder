param([string] $AppPath = (Join-Path $PSScriptRoot "VencordEquicordBuilder.ps1"))

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "SourceTracking.ps1")
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($AppPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join "; ") }
$appDirectoryLiteral = "'" + (Split-Path -Parent ([IO.Path]::GetFullPath($AppPath))).Replace("'", "''") + "'"
# The app's functions live in the main script and its dot-sourced CordBuilder.*.ps1 parts.
$appAsts = @($ast) + @(Get-ChildItem -LiteralPath (Split-Path -Parent $AppPath) -Filter "CordBuilder.*.ps1" | ForEach-Object {
    $partAst = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors.Message -join "; ") }
    $partAst
})
foreach ($definition in @($appAsts | ForEach-Object { $_.FindAll({
    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true) })) {
    . ([scriptblock]::Create($definition.Extent.Text.Replace('$PSScriptRoot', $appDirectoryLiteral)))
}
function Assert-Equal { param($Actual, $Expected, $Message) if ($Actual -ne $Expected) { throw "$Message (expected $Expected, got $Actual)" } }
function Assert-Rejected {
    param([scriptblock] $Operation, [string] $Message)
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $true }
    Assert-Equal $rejected $true $Message
}
function Get-ProjectPath { return $script:TestProject }
function Get-ToolPaths { return [pscustomobject]@{ Pnpm = "test-pnpm.cmd" } }
function Test-RequiredTools { return $true }
function Test-NotElevated { return $true }
function Test-SafeProjectPath { param($Path) return $true }
function Test-ProjectRoot { return $true }
function Add-LogLine { param($Message) }
function Set-AppStatus { param($Text, $Kind) }
function Set-PanelAvailability { param($Panel, $Enabled) $Panel.IsEnabled = $Enabled }
function Set-StepCompletion { param($Badge, $Number, $Check, $Completed, $Active) }
function Get-SelectedDiscordChannel { return $script:SelectedTarget }
function Find-DiscordInjectionEvidence { if ($script:Patched) { return "test-patch" } return $null }
function Start-CommandSequence { param($Commands, $OnSuccess) $script:CapturedCommands = @($Commands); $script:CapturedSuccess = $OnSuccess }
function Sync-TestSnapshot {
    $script:SourcePath = $script:TestProject
    $script:SourceHash = [CordSourceSnapshot]::Compute($script:TestProject, [Threading.CancellationToken]::None)
}
function Verify-TestBuild {
    Invoke-SourceSnapshotAction "Capture" $script:TestProject "Equicord" $false | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:TestProject "dist\desktop.js"), "fresh build output")
    Invoke-SourceSnapshotAction "Verify" $script:TestProject "Equicord" $false | Out-Null
    Set-BuildReady
}
$controlAssignment = $ast.Find({
    param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$controlNames'
}, $true)
foreach ($name in $controlAssignment.Right.Expression.SafeGetValue()) {
    Set-Variable -Scope Script -Name $name -Value ([pscustomobject]@{ IsEnabled = $true; Content = ""; Text = ""; IsChecked = $false; Items = @("installed") })
}
$script:IsBusy = $false
$script:ToolSetupActive = $false
$script:BuildInvalidated = $false
$script:SourceSnapshotTask = $null
$script:SourceScanCancellation = $null
$script:SourceError = $null
$script:SourceHash = $null
$script:SourcePath = $null
$script:NextSourceScan = [DateTime]::MinValue
$script:PrerequisiteState = [pscustomobject]@{ Ready = $true }
$script:CurrentClient = "Equicord"
$script:Patched = $false
$script:DeferredCommands = @()
$script:CapturedCommands = @()
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempRoot ("CordBuilder-BuildTest-" + [Guid]::NewGuid().ToString("N"))
$script:TestProject = Join-Path $testRoot "Equicord"
New-Item -ItemType Directory -Path $script:TestProject | Out-Null
try {
    foreach ($folder in @("src\userplugins\myPlugin", "node_modules", "dist", ".git")) {
        New-Item -ItemType Directory -Path (Join-Path $script:TestProject $folder) -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $script:TestProject "package.json"), '{"name":"equicord"}')
    [IO.File]::WriteAllText((Get-DependenciesMarkerPath), "ready")
    $output = Join-Path $script:TestProject "dist\desktop.js"
    [IO.File]::WriteAllText($output, "build output")
    $input = Join-Path $script:TestProject "src\userplugins\myPlugin\index.ts"
    [IO.File]::WriteAllText($input, "original")
    $script:SelectedTarget = [pscustomobject]@{ ProductRoot = (Join-Path $testRoot "DiscordPTB"); ProcessName = "DiscordPTB"; DisplayName = "Discord PTB" }

    Sync-TestSnapshot
    Update-WorkflowState
    Assert-Equal $BuildButton.IsEnabled $true "First build must be available"
    Verify-TestBuild
    $baseline = $script:SourceHash
    Update-WorkflowState
    Assert-Equal $BuildButton.IsEnabled $false "Unchanged source must show Build up to date"
    Assert-Equal (Test-BuildReady) $true "Verified source and output must be ready"
    $time = [IO.File]::GetLastWriteTimeUtc($input)
    [IO.File]::WriteAllText($input, "modified")
    [IO.File]::SetLastWriteTimeUtc($input, $time)
    Sync-TestSnapshot
    Update-WorkflowState
    Assert-Equal $BuildButton.IsEnabled $true "Same-size edits with preserved timestamps must unlock Build"
    Assert-Equal $InjectButton.IsEnabled $false "Changed source must lock injection"
    [IO.File]::WriteAllText($input, "original")
    Sync-TestSnapshot
    Assert-Equal $script:SourceHash $baseline "Restoring identical contents must restore the baseline"
    $added = Join-Path $script:TestProject "src\extra.ts"
    [IO.File]::WriteAllText($added, "new")
    Sync-TestSnapshot
    Assert-Equal ($script:SourceHash -ne $baseline) $true "Added files must change the snapshot"
    Remove-Item -LiteralPath $added
    Sync-TestSnapshot
    Assert-Equal $script:SourceHash $baseline "Deleted added files must be reflected"
    $renamed = Join-Path (Split-Path -Parent $input) "renamed.ts"
    Move-Item -LiteralPath $input -Destination $renamed
    Sync-TestSnapshot
    Assert-Equal ($script:SourceHash -ne $baseline) $true "Renames must change the snapshot"
    Move-Item -LiteralPath $renamed -Destination $input
    [IO.File]::WriteAllText($output, "new generated output")
    [IO.File]::WriteAllText((Join-Path $script:TestProject "node_modules\generated.txt"), "generated")
    [IO.File]::WriteAllText((Join-Path $script:TestProject ".git\HEAD"), "metadata")
    Sync-TestSnapshot
    Assert-Equal $script:SourceHash $baseline "Generated output, dependencies and Git metadata must not cause a rebuild loop"
    $nestedDist = Join-Path (Split-Path -Parent $input) "dist"
    New-Item -ItemType Directory -Path $nestedDist | Out-Null
    $nestedSource = Join-Path $nestedDist "helper.js"
    [IO.File]::WriteAllText($nestedSource, "plugin build input")
    Sync-TestSnapshot
    Assert-Equal ($script:SourceHash -ne $baseline) $true "Nested plugin dist files remain source inputs"
    Remove-Item -LiteralPath $nestedSource
    [IO.Directory]::Delete($nestedDist)
    $linkedFolder = Join-Path $script:TestProject "src\linkedPlugin"
    New-Item -ItemType Junction -Path $linkedFolder -Target (Split-Path -Parent $input) | Out-Null
    try {
        Sync-TestSnapshot
        $linkedHash = $script:SourceHash
        [IO.File]::WriteAllText($input, "linked-edit")
        Sync-TestSnapshot
        Assert-Equal ($script:SourceHash -ne $linkedHash) $true "Linked plugin contents must be tracked"
        [IO.File]::WriteAllText($input, "original")
    }
    finally { [IO.Directory]::Delete($linkedFolder) } # Delete the link itself, not its target.
    New-Item -ItemType Junction -Path $linkedFolder -Target $script:TestProject | Out-Null
    try { Assert-Rejected { Sync-TestSnapshot } "Cyclic folder links must fail safely" }
    finally { [IO.Directory]::Delete($linkedFolder) }
    Sync-TestSnapshot
    Assert-Equal ($null -ne (Read-VerifiedBuildSnapshot ($script:TestProject + '\'))) $true "Trailing path separators must not invalidate a verified snapshot"
    $DevModeCheck.IsChecked = $true
    Assert-Equal (Test-BuildReady) $false "Build mode must be part of the saved snapshot"
    $DevModeCheck.IsChecked = $false
    $script:SourceHash = $null
    Update-WorkflowState
    Assert-Equal $BuildButton.IsEnabled $false "Build must wait for the initial source check"
    Sync-TestSnapshot

    Invoke-SourceSnapshotAction "Capture" $script:TestProject "Equicord" $false | Out-Null
    Assert-Equal (Test-Path -LiteralPath (Get-BuildMarkerPath)) $false "Starting another build must clear old verified completion"
    [IO.File]::SetLastWriteTimeUtc($output, [DateTime]::UtcNow.AddMinutes(-1))
    Assert-Rejected { Invoke-SourceSnapshotAction "Verify" $script:TestProject "Equicord" $false } "Old output cannot pass as a fresh successful build"
    [IO.File]::WriteAllText($input, "during-build")
    Assert-Rejected { Invoke-SourceSnapshotAction "Verify" $script:TestProject "Equicord" $false } "Edits during a build must fail verification"
    Assert-Equal (Test-Path -LiteralPath (Get-BuildMarkerPath)) $false "A changed or failed build must not gain a success marker"
    [IO.File]::WriteAllText($input, "original")
    Verify-TestBuild
    [IO.File]::WriteAllText($input, "before-restart")
    Assert-Rejected { Invoke-SourceSnapshotAction "Check" $script:TestProject "Equicord" $false } "Changes before restart must stop the restart sequence"
    [IO.File]::WriteAllText($input, "original")
    [IO.File]::WriteAllText((Get-BuildMarkerPath), "old timestamp marker")
    Assert-Equal ($null -eq (Read-VerifiedBuildSnapshot $script:TestProject)) $true "Old markers must require one verified rebuild"

    # Exercise the real build success callback, but never run pnpm or restart Discord.
    Sync-TestSnapshot
    Start-ProjectBuild
    Assert-Equal $script:CapturedCommands.Count 3 "Build must capture source, run pnpm, then verify"
    Assert-Equal $script:CapturedCommands[0].Label "Capture source before building" "Snapshot capture must come first"
    Assert-Equal $script:CapturedCommands[2].Label "Verify build matches source files" "Verification must come after the compiler"
    Invoke-SourceSnapshotAction "Capture" $script:TestProject "Equicord" $false | Out-Null
    [IO.File]::WriteAllText($output, "newly compiled output")
    Invoke-SourceSnapshotAction "Verify" $script:TestProject "Equicord" $false | Out-Null
    $script:Settings = [pscustomobject]@{ AutoRestart = $false }
    & $script:CapturedSuccess
    Assert-Equal $script:DeferredCommands.Count 2 "Every successful build must queue a fresh source check then restart"
    Assert-Equal $script:DeferredCommands[1].Label "Restart DiscordPTB" "Only the selected Discord channel may restart"
    Assert-Equal ($script:DeferredCommands[1].Arguments -contains $script:SelectedTarget.ProductRoot) $true "Restart must target the selected product directory"
    $script:DeferredCommands = @()
    $script:BuildInvalidated = $true
    Assert-Rejected { Queue-VerifiedDiscordRestart } "Unverified builds must never queue a restart"
    Assert-Equal $script:DeferredCommands.Count 0 "Failed verification must leave the restart queue empty"
    $script:BuildInvalidated = $false

    # Editor folders are not plugins; badly named folders are reported with a reason.
    $pluginRoot = Join-Path $script:TestProject "src\userplugins"
    $editorFolder = Join-Path $pluginRoot ".vscode"
    $badFolder = Join-Path $pluginRoot "Bad-Name"
    New-Item -ItemType Directory -Path $editorFolder, $badFolder | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $badFolder "index.ts"), "export default {};")
        $items = @(Get-PluginItems)
        Assert-Equal (@($items | Where-Object Name -eq ".vscode").Count) 0 "Dot-folders must not be listed as plugins"
        $bad = @($items | Where-Object Name -eq "Bad-Name")
        Assert-Equal ($bad.Count -eq 1 -and -not $bad[0].Valid -and $bad[0].Problem -match "camelCase") $true "Invalid Equicord names must explain the fix"
        Assert-Equal (Test-PluginsValidForBuild) $false "Invalid plugins must block the build"
        Assert-Equal ((Get-InvalidPluginNames) -join ",") "Bad-Name" "Only the invalid plugin is named"
    }
    finally { Remove-Item -LiteralPath $editorFolder, $badFolder -Recurse -Force }
    Assert-Equal (Test-PluginsValidForBuild) $true "Valid plugins must allow the build"

    # A leading "_" turns a plugin off, as the client's build skips it; shared plugin names warn without blocking.
    $offFolder = Join-Path $pluginRoot "_Old-Name"
    $twinA = Join-Path $pluginRoot "twinA"
    $twinB = Join-Path $pluginRoot "twinB"
    New-Item -ItemType Directory -Path $offFolder, $twinA, $twinB | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $offFolder "index.ts"), "export default {};")
        foreach ($twin in @($twinA, $twinB)) {
            [IO.File]::WriteAllText((Join-Path $twin "index.ts"), 'export default definePlugin({ name: "Twin", authors: [{ name: "x" }] });')
        }
        Assert-Equal (Test-PluginsValidForBuild) $true "Turned-off plugins must not block the build"
        $detailed = @(Get-PluginItems -Details)
        $off = @($detailed | Where-Object Name -eq "_Old-Name")
        Assert-Equal ($off.Count -eq 1 -and $off[0].State -eq "Disabled" -and $off[0].DisplayName -eq "Old-Name") $true "A leading underscore marks a plugin as off"
        $twins = @($detailed | Where-Object { $_.Name -like "twin*" })
        Assert-Equal (@($twins | Where-Object State -eq "Warning").Count) 2 "Plugins sharing a name must both be flagged"
        Assert-Equal $twins[0].DeclaredName "Twin" "The plugin name comes from definePlugin"
        Assert-Equal $twins[0].Valid $true "A name clash warns without blocking the build"
        Assert-Equal (Set-PluginEnabled $twins[1] $false) $true "Turning a plugin off must succeed"
        Assert-Equal (Test-Path -LiteralPath (Join-Path $pluginRoot "_twinB")) $true "Turning off renames with a leading underscore"
        Assert-Equal (@(Get-PluginItems -Details | Where-Object State -eq "Warning").Count) 0 "A turned-off twin no longer clashes"
        $offTwin = @(Get-PluginItems | Where-Object Name -eq "_twinB")[0]
        Assert-Equal (Set-PluginEnabled $offTwin $true) $true "Turning a plugin back on must succeed"
        Assert-Equal (Test-Path -LiteralPath $twinB) $true "Turning on restores the original name"
        New-Item -ItemType Directory -Path (Join-Path $pluginRoot "_twinA") | Out-Null
        Assert-Equal (Set-PluginEnabled $twins[0] $false) $false "Renaming onto an existing name must be refused"
        Assert-Equal (Test-Path -LiteralPath $twinA) $true "A refused rename leaves the plugin in place"
    }
    finally {
        foreach ($leftover in @($offFolder, $twinA, $twinB, (Join-Path $pluginRoot "_twinA"), (Join-Path $pluginRoot "_twinB"))) {
            if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Recurse -Force }
        }
    }

    # Test the background scanner rather than only direct hash calls.
    Reset-SourceTracking
    Update-SourceTracking
    if (-not $script:SourceSnapshotTask.Wait(5000)) { throw "Background source check timed out" }
    Update-SourceTracking
    Assert-Equal (Test-BuildReady) $true "Reopening must recognize the saved content snapshot"
    [IO.File]::WriteAllText($input, "external-edit")
    $script:NextSourceScan = [DateTime]::MinValue
    Update-SourceTracking
    if (-not $script:SourceSnapshotTask.Wait(5000)) { throw "Background source check timed out" }
    Update-SourceTracking
    Assert-Equal $BuildButton.IsEnabled $true "Background changes must unlock Build without Refresh or reopening"
    Write-Output "PASS: content tracking, file edits/additions/deletions/renames, saved snapshots, build verification and automatic targeted restart."
}
finally {
    Reset-SourceTracking
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Path]::GetDirectoryName($resolved).Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -cmatch '^CordBuilder-BuildTest-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
