param([string] $AppPath = (Join-Path $PSScriptRoot "VencordEquicordBuilder.ps1"))

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($AppPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join "; ") }

function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    if ($Actual -ne $Expected) { throw "$Message (expected $Expected, got $Actual)" }
}

$runnerAssignment = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$runnerSource'
}, $true)
Add-Type -TypeDefinition $runnerAssignment.Right.Expression.Value
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
    $appDirectoryLiteral = "'" + (Split-Path -Parent ([IO.Path]::GetFullPath($AppPath))).Replace("'", "''") + "'"
    . ([scriptblock]::Create($definition.Extent.Text.Replace('$PSScriptRoot', $appDirectoryLiteral)))
}

$powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$ok = Get-ToolProbe $powershell @("-NoProfile", "-Command", "'1.2.3'; exit 0")
Assert-Equal $ok "1.2.3" "A working command must pass"
$failed = Get-ToolProbe $powershell @("-NoProfile", "-Command", "'1.2.3'; exit 7")
Assert-Equal $failed $null "Version output with a failed exit code must not pass"
$unrelated = Get-ToolProbe $powershell @("-NoProfile", "-Command", "'not installed'")
Assert-Equal $unrelated $null "Unrelated output must not pass"
$timeout = Get-ToolProbe $powershell @("-NoProfile", "-Command", "Start-Sleep -Seconds 5") -TimeoutMilliseconds 50
Assert-Equal $timeout $null "A stalled command must not pass"
Write-Output "PASS: actual tool checks reject failed exits, invalid output and timeouts."
$gitRepair = (Get-Command Start-GitRepair).ScriptBlock
$nodeRepair = (Get-Command Start-NodeLtsRepair).ScriptBlock
$continueSetup = (Get-Command Continue-RequiredToolsInstallation).ScriptBlock

# All remaining tests simulate missing installations. They install nothing,
# launch no browser, and never change a user's project or environment.
function Get-ToolPaths {
    $result = @{}
    foreach ($name in @("Git", "Node", "Pnpm", "Npm")) {
        $result[$name] = if ($script:HideMissingPaths -and -not $script:MockReady[$name]) { $null } else { $name }
    }
    return [pscustomobject]$result
}
function Get-ToolProbe {
    param([string] $File, [string[]] $Arguments, [string] $Pattern)
    if (-not $File -or -not $script:MockReady[$File]) { return $null }
    switch ($File) {
        "Git" { return "git version 2.50.0.windows.1" }
        "Node" {
            if ($Pattern -like '*cord-builder-lts*') {
                if ($script:MockLts) { return "cord-builder-lts:TestLTS" }
                return $null
            }
            return "v24.0.0"
        }
        default { return "11.0.0" }
    }
}
function Start-PrerequisiteProbe {
    $tools = Get-ToolPaths
    $nodeLine = $null
    if ($tools.Node -and $script:MockReady[$tools.Node]) {
        $nodeLine = "cord-builder-node:v24.0.0:" + $(if ($script:MockLts) { "TestLTS" } else { "" })
    }
    return [pscustomobject]@{
        Tools = $tools
        Git = Get-ToolProbe $tools.Git
        Node = $nodeLine
        Pnpm = Get-ToolProbe $tools.Pnpm
    }
}
function Update-PrerequisiteStatus { $script:PrerequisiteState = Get-PrerequisiteState }
function Request-PrerequisiteRefresh { }
function Refresh-ToolSearchPath { }
function Get-ProjectPath { return "C:\cord-builder-test" }
function Test-DependenciesReady { return $true }
function Test-BuildReady { return $true }
function Test-InjectionReady { return $true }
function Test-DiscordPatchedHere { return $true }
function Get-SelectedDiscordChannel { return [pscustomobject]@{ Branch = "stable" } }
function Set-PanelAvailability { param($Panel, $Enabled) $Panel.IsEnabled = $Enabled }
function Set-StepCompletion { param($Badge, $Number, $Check, $Completed, $Active) }
function Add-LogLine { param($Message) }
function Set-AppStatus { param($Text, $Kind) }
function Test-NotElevated { return $true }
function Start-GitRepair { $script:InstallRoute = "Git" }
function Start-NodeLtsRepair { $script:InstallRoute = "Node" }
function Continue-RequiredToolsInstallation { $script:ContinuationCalls++ }
function Start-Process { param($FilePath) $script:OpenedUrl = $FilePath }
function New-Item { param($ItemType, $Path, [switch]$Force) $script:CreatedPath = $Path }
function Start-CommandSequence {
    param($Commands, $OnSuccess)
    $script:CapturedCommands = @($Commands)
    $script:CapturedSuccess = $OnSuccess
}

$controlAssignment = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$controlNames'
}, $true)
foreach ($name in $controlAssignment.Right.Expression.SafeGetValue()) {
    Set-Variable -Name $name -Scope Script -Value ([pscustomobject]@{
        IsEnabled = $true; Content = ""; Text = ""; Items = @("installed")
    })
}
$script:IsBusy = $false
$script:ToolSetupActive = $false
$script:ContinuationCalls = 0
$script:DeferredCommands = @()
$script:DeferredOnSuccess = $null
$script:BuildInvalidated = $false
$script:SourceHash = "test-hash"
$script:SourceError = $null
$script:CurrentClient = "Equicord"
$script:MockLts = $true
$cases = 0
foreach ($hidePaths in @($true, $false)) {
    $script:HideMissingPaths = $hidePaths
    for ($mask = 0; $mask -lt 8; $mask++) {
        $script:MockReady = @{
            Git = [bool]($mask -band 1)
            Node = [bool]($mask -band 2)
            Pnpm = [bool]($mask -band 4)
            Npm = $true
        }
        Update-PrerequisiteStatus
        Update-WorkflowState
        $ready = $mask -eq 7
        Assert-Equal $script:PrerequisiteState.Ready $ready "Readiness for mask $mask"
        foreach ($control in @($PrepareButton, $UpdateSourceButton, $OpenPluginsButton, $InjectButton, $ReinjectButton, $RunAllButton)) {
            Assert-Equal $control.IsEnabled $ready "Saved completion markers cannot bypass missing tools"
        }
        Assert-Equal $InstallPrerequisitesButton.IsEnabled (-not $ready) "Install button state"
        if (-not $ready) {
            $script:CapturedCommands = @()
            $script:CreatedPath = $null
            Start-PrepareProject
            Assert-Equal $script:CapturedCommands.Count 0 "Prepare must not run commands with missing tools"
            Assert-Equal $script:CreatedPath $null "Prepare must not create files with missing tools"
        }
        $cases++
    }
}
Write-Output "PASS: $cases missing/broken-tool combinations enforce the full workflow gate."

$script:HideMissingPaths = $false
$script:MockReady = @{ Git = $true; Node = $true; Pnpm = $true; Npm = $true }
$script:MockLts = $false
Assert-Equal (Get-PrerequisiteState).Ready $false "Equicord must reject non-LTS Node"
$script:CurrentClient = "Vencord"
Assert-Equal (Get-PrerequisiteState).Ready $true "Vencord keeps its existing non-LTS support"
$script:CurrentClient = "Equicord"
$script:MockLts = $true
$script:IsBusy = $true
Update-PrerequisiteStatus
Update-WorkflowState
foreach ($control in @($PrepareButton, $OpenPluginsButton, $InjectButton, $RunAllButton, $InstallPrerequisitesButton, $CheckPrerequisitesButton)) {
    Assert-Equal $control.IsEnabled $false "No action may unlock while work is running"
}
$script:IsBusy = $false

$script:MockReady = @{ Git = $false; Node = $false; Pnpm = $false; Npm = $false }
$script:OpenedUrl = $null
$script:InstallRoute = $null
$script:CapturedCommands = @()
Start-RequiredToolsInstallation
Assert-Equal $script:OpenedUrl $null "Git must install inside the app without opening a browser"
Assert-Equal $script:InstallRoute "Git" "Git installs before Node"
Assert-Equal $script:CapturedCommands.Count 0 "Git route must not start source operations"

$script:MockReady.Git = $true
Start-RequiredToolsInstallation
Assert-Equal $script:InstallRoute "Node" "Node installation follows Git"
$script:MockReady.Node = $true
$script:MockReady.Npm = $true
Start-RequiredToolsInstallation
Assert-Equal $script:CapturedCommands.Count 1 "pnpm installs separately, before source setup"
Assert-Equal $script:CapturedCommands[0].Label "Install and verify pnpm" "Expected prerequisite command"
$failedVerification = $false
try { & $script:CapturedSuccess } catch { $failedVerification = $true }
Assert-Equal $failedVerification $true "A zero installer exit cannot bypass missing pnpm"
$script:MockReady.Pnpm = $true
& $script:CapturedSuccess
Update-WorkflowState
Assert-Equal $PrepareButton.IsEnabled $true "Prepare unlocks after all three tools verify"
Write-Output "PASS: Git -> Node -> pnpm installation routing and post-install verification."

# Exercise the real Git and Node installer callbacks without downloading anything.
$script:MockReady.Git = $false
& $gitRepair
Assert-Equal $script:CapturedCommands[0].Label "Install and verify Git" "Git helper must be launched in the task runner"
$failedVerification = $false
try { & $script:CapturedSuccess } catch { $failedVerification = $true }
Assert-Equal $failedVerification $true "A successful installer exit cannot bypass broken Git"
Assert-Equal $script:ContinuationCalls 0 "Broken Git must stop automatic continuation"
$script:MockReady.Git = $true
& $script:CapturedSuccess
Assert-Equal $script:ContinuationCalls 1 "Verified Git must advance automatically"

& $nodeRepair
Assert-Equal $script:CapturedCommands[0].Label "Install and verify Node.js LTS" "Node helper must be launched in the task runner"
$script:MockReady.Npm = $false
$failedVerification = $false
try { & $script:CapturedSuccess } catch { $failedVerification = $true }
Assert-Equal $failedVerification $true "Node verification must reject broken bundled npm"
Assert-Equal $script:ContinuationCalls 1 "Broken npm must stop automatic continuation"
$script:MockReady.Npm = $true
& $script:CapturedSuccess
Assert-Equal $script:ContinuationCalls 2 "Verified Node and npm must advance automatically"

$script:ToolSetupActive = $true
$script:OnSequenceSuccess = { throw "Simulated verification failure" }
$script:OnSequenceFailure = $null
Complete-Sequence $true "Test completion"
Assert-Equal $script:ToolSetupActive $false "Verification failure must end automatic setup"
$script:ToolSetupActive = $true
$script:OnSequenceSuccess = $null
$script:OnSequenceFailure = $null
Complete-Sequence $false "Simulated cancelled or failed installer"
Assert-Equal $script:ToolSetupActive $false "Installer failure must end automatic setup"

$script:MockReady = @{ Git = $false; Node = $false; Pnpm = $false; Npm = $false }
$script:ToolSetupActive = $true
$script:InstallRoute = $null
$window = [System.Windows.Window]::new()
& $continueSetup
$script:ToolSetupActive = $false # Stop was clicked before the queued step started.
$frame = [System.Windows.Threading.DispatcherFrame]::new()
[void]$window.Dispatcher.BeginInvoke([Action]{ $frame.Continue = $false }, [System.Windows.Threading.DispatcherPriority]::ContextIdle)
[System.Windows.Threading.Dispatcher]::PushFrame($frame)
Assert-Equal $script:InstallRoute $null "A queued step must not restart setup after Stop"
Start-RequiredToolsInstallation -Continue
Assert-Equal $script:InstallRoute $null "Cancelled continuation must remain cancelled"
Start-RequiredToolsInstallation
Assert-Equal $script:InstallRoute "Git" "The same setup button must allow a deliberate retry"
Assert-Equal $script:OpenedUrl $null "No setup route may launch a browser"
Write-Output "PASS: installer callbacks, failure handling, queued-step cancellation and retry."
