[CmdletBinding()]
param(
    [switch] $SelfTest,
    [switch] $StartupSelfTest,
    [string] $PreviewPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "SourceTracking.ps1")
foreach ($part in @("Readiness", "Discord", "Plugins", "Updates")) { . (Join-Path $PSScriptRoot "CordBuilder.$part.ps1") }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$runnerSource = @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class BuilderProcessRunner
{
    private static void StopProcessTree(Process process, ConcurrentQueue<string> output)
    {
        // Only stop this task and its children, never other Git/Node processes.
        try
        {
            if (process.HasExited) return;
            var stopInfo = new ProcessStartInfo(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "taskkill.exe"),
                "/PID " + process.Id + " /T /F");
            stopInfo.UseShellExecute = false;
            stopInfo.CreateNoWindow = true;
            stopInfo.RedirectStandardOutput = true;
            stopInfo.RedirectStandardError = true;
            using (var stop = Process.Start(stopInfo))
            {
                stop.OutputDataReceived += (sender, args) => { if (args.Data != null) output.Enqueue("[stop] " + args.Data); };
                stop.ErrorDataReceived += (sender, args) => { if (args.Data != null) output.Enqueue("[stop] " + args.Data); };
                stop.BeginOutputReadLine();
                stop.BeginErrorReadLine();
                if (!stop.WaitForExit(5000)) { try { stop.Kill(); } catch { } }
            }
        }
        catch (Exception exception) { output.Enqueue("[stop] " + exception.Message); }
        try { if (!process.HasExited) process.Kill(); } catch { }
    }

    private static string Quote(string value)
    {
        if (value == null) return "\"\"";
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '\"' }) < 0) return value;

        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\')
            {
                slashes++;
                continue;
            }

            if (c == '\"')
            {
                result.Append('\\', slashes * 2 + 1);
                result.Append('\"');
                slashes = 0;
                continue;
            }

            result.Append('\\', slashes);
            slashes = 0;
            result.Append(c);
        }

        result.Append('\\', slashes * 2);
        result.Append('\"');
        return result.ToString();
    }

    private static string JoinArguments(string[] arguments)
    {
        var result = new StringBuilder();
        for (int i = 0; i < arguments.Length; i++)
        {
            if (i > 0) result.Append(' ');
            result.Append(Quote(arguments[i]));
        }
        return result.ToString();
    }

    public static Task<int> RunAsync(
        string fileName,
        string[] arguments,
        string workingDirectory,
        ConcurrentQueue<string> output,
        CancellationToken cancellationToken)
    {
        return Task.Run(() =>
        {
            var startInfo = new ProcessStartInfo();
            bool isBatch = fileName.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)
                || fileName.EndsWith(".bat", StringComparison.OrdinalIgnoreCase);

            if (isBatch)
            {
                startInfo.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
                startInfo.Arguments = "/d /s /c \"\"" + fileName + "\" " + JoinArguments(arguments) + "\"";
            }
            else
            {
                startInfo.FileName = fileName;
                startInfo.Arguments = JoinArguments(arguments);
            }

            startInfo.WorkingDirectory = workingDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;
            startInfo.StandardOutputEncoding = Encoding.UTF8;
            startInfo.StandardErrorEncoding = Encoding.UTF8;
            startInfo.EnvironmentVariables["NO_COLOR"] = "1";
            startInfo.EnvironmentVariables["FORCE_COLOR"] = "0";
            // Background tasks have no console, so a credential or update prompt would hang them.
            startInfo.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0";
            startInfo.EnvironmentVariables["npm_config_update_notifier"] = "false";

            using (var process = new Process())
            {
                process.StartInfo = startInfo;
                process.OutputDataReceived += (sender, eventArgs) =>
                {
                    if (eventArgs.Data != null) output.Enqueue(eventArgs.Data);
                };
                process.ErrorDataReceived += (sender, eventArgs) =>
                {
                    if (eventArgs.Data != null) output.Enqueue(eventArgs.Data);
                };

                try
                {
                    if (cancellationToken.IsCancellationRequested) return -999;
                    process.Start();
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();

                    while (!process.WaitForExit(100))
                    {
                        if (!cancellationToken.IsCancellationRequested) continue;
                        StopProcessTree(process, output);
                        process.WaitForExit();
                        output.Enqueue("[cancelled]");
                        return -999;
                    }

                    process.WaitForExit();
                    return cancellationToken.IsCancellationRequested ? -999 : process.ExitCode;
                }
                catch (Exception exception)
                {
                    output.Enqueue("[launcher error] " + exception.Message);
                    return -998;
                }
            }
        });
    }

    // Runs a short check command and returns its first output line matching the pattern,
    // or null on failure, unrelated output, or timeout. Several probes can run in parallel.
    public static Task<string> ProbeAsync(
        string fileName,
        string[] arguments,
        string workingDirectory,
        string pattern,
        int timeoutMilliseconds)
    {
        return Task.Run(() =>
        {
            if (string.IsNullOrEmpty(fileName)) return null;
            var output = new ConcurrentQueue<string>();
            using (var timeout = new CancellationTokenSource(timeoutMilliseconds))
            {
                int exitCode;
                try { exitCode = RunAsync(fileName, arguments, workingDirectory, output, timeout.Token).Result; }
                catch { return null; }
                if (exitCode != 0) return null;
            }
            var regex = new System.Text.RegularExpressions.Regex(pattern);
            string line;
            while (output.TryDequeue(out line))
            {
                if (regex.IsMatch(line)) return line;
            }
            return null;
        });
    }

    private static string FirstLine(string fileName, string[] arguments, string workingDirectory, CancellationToken token)
    {
        var output = new ConcurrentQueue<string>();
        int exitCode = RunAsync(fileName, arguments, workingDirectory, output, token).Result;
        if (exitCode != 0) return null;
        string line;
        while (output.TryDequeue(out line))
        {
            if (!string.IsNullOrWhiteSpace(line)) return line.Trim();
        }
        return null;
    }

    // Returns "branch<TAB>commit<TAB>commitsBehind" for a checkout. Empty fields mean unknown.
    // A fetch only updates remote-tracking refs; it never changes the user's files.
    public static Task<string> GitInfoAsync(string git, string repository, bool fetch, CancellationToken cancellationToken)
    {
        return Task.Run(() =>
        {
            using (var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                limit.CancelAfter(90000);
                var token = limit.Token;
                string branch = FirstLine(git, new[] { "-C", repository, "rev-parse", "--abbrev-ref", "HEAD" }, repository, token);
                string commit = FirstLine(git, new[] { "-C", repository, "rev-parse", "--short", "HEAD" }, repository, token);
                if (fetch && !token.IsCancellationRequested)
                {
                    FirstLine(git, new[] { "-C", repository, "fetch", "--quiet", "--no-tags" }, repository, token);
                }
                string behind = token.IsCancellationRequested ? null :
                    FirstLine(git, new[] { "-C", repository, "rev-list", "--count", "HEAD..@{upstream}" }, repository, token);
                token.ThrowIfCancellationRequested();
                return (branch ?? "") + "\t" + (commit ?? "") + "\t" + (behind ?? "");
            }
        }, cancellationToken);
    }
}

public static class BuilderWindowShell
{
    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    // Gives this PowerShell process its own taskbar identity, so Windows shows the
    // window's own icon instead of grouping it under (and borrowing) PowerShell's.
    public static void SetAppId(string appId)
    {
        try { SetCurrentProcessExplicitAppUserModelID(appId); } catch { }
    }

    // Asks Windows 10/11 to draw the window border and shadow for a dark window.
    public static void UseDarkFrame(IntPtr window)
    {
        int enabled = 1;
        try
        {
            if (DwmSetWindowAttribute(window, 20, ref enabled, sizeof(int)) != 0)
                DwmSetWindowAttribute(window, 19, ref enabled, sizeof(int));
        }
        catch { }
    }

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int ellipseWidth, int ellipseHeight);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int SetWindowRgn(IntPtr window, IntPtr region, bool redraw);

    // Asks Windows 11 to round the window corners; custom chrome otherwise opts out.
    // Returns false where Windows doesn't support it (Windows 10), so the caller can clip instead.
    public static bool UseRoundedCorners(IntPtr window)
    {
        int round = 2;
        try { return DwmSetWindowAttribute(window, 33, ref round, sizeof(int)) == 0; } catch { return false; }
    }

    // Windows 10 fallback: clips the window to a rounded rectangle in device pixels.
    // A size of zero removes the clip, for example while maximized.
    public static void ClipCorners(IntPtr window, int width, int height, int diameter)
    {
        try
        {
            if (width <= 0 || height <= 0) { SetWindowRgn(window, IntPtr.Zero, true); return; }
            // The window owns the region after SetWindowRgn succeeds, so it must not be deleted here.
            SetWindowRgn(window, CreateRoundRectRgn(0, 0, width + 1, height + 1, diameter, diameter), true);
        }
        catch { }
    }
}
'@

Add-Type -TypeDefinition $runnerSource -Language CSharp


if (-not $SelfTest -and -not $StartupSelfTest) {
    # Two copies building or injecting the same checkout at once would corrupt each other's work.
    $createdNew = $false
    $script:InstanceMutex = [System.Threading.Mutex]::new($true, "Local\CordBuilder.SingleInstance", [ref]$createdNew)
    if (-not $createdNew) {
        [void][System.Windows.MessageBox]::Show("Cord Builder is already open. Switch to the existing window.", "Cord Builder",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        exit 0
    }
    # Must run before any window exists for the taskbar to use Cord Builder's own icon.
    [BuilderWindowShell]::SetAppId("CordBuilder.App")
}

$xamlPath = Join-Path $PSScriptRoot "CordBuilder.xaml"
$xmlReader = [System.Xml.XmlReader]::Create($xamlPath)
try { $window = [System.Windows.Markup.XamlReader]::Load($xmlReader) }
finally { $xmlReader.Dispose() }

$controlNames = @(
    "RootGrid", "TitleLogoImage", "CloseButton", "MinimizeButton", "ZoomButton", "ZoomGlyph",
    "NavPanel", "NavHome", "NavPlugins", "NavActivity", "NavSettings", "SetupTag", "UpdateButton", "UpdateText",
    "AssistantPage", "AssistantIcon", "AssistantTitle", "AssistantBody",
    "ToolsStepPanel", "GitDot", "GitStatus", "NodeDot", "NodeStatus", "PnpmDot", "PnpmStatus",
    "InstallPrerequisitesButton", "ToolsReadyPanel", "AssistantCheckButton",
    "SourceStepPanel", "SourceHostAssistant", "SourceGroup", "VencordRadio", "EquicordRadio",
    "ProjectPathBox", "BrowseButton", "PathHint", "SourceInfoText", "PrepareButton",
    "BuildStepPanel", "AssistantPluginSummary", "AssistantPluginsButton", "BuildButton",
    "DiscordStepPanel", "DiscordHostAssistant", "DiscordGroup", "DiscordChannelCombo", "RescanDiscordButton", "DiscordChannelHint", "InjectButton",
    "AssistantProgressPanel", "AssistantStopButton", "AssistantElapsedText", "AssistantLogPanel", "AssistantLogText",
    "StepCounterText", "StepProgressFill", "ShowActivityButton", "BackButton", "ContinueButton",
    "HomePage", "HeroDot", "HeroSpinner", "HeroEyebrow", "HeroTitle", "HeroBody", "HeroProgressPanel", "HeroElapsedText",
    "HeroPrimaryButton", "StopButton", "RunAllButton", "DevHostHome", "DevModeGroup", "DevModeCheck",
    "ToolsTitle", "ToolsDetail", "CheckPrerequisitesButton", "SourceTitle", "SourceDetail", "UpdateSourceButton",
    "BuildTitle", "BuildDetail", "DiscordTitle", "DiscordDetail", "ReinjectButton", "RestoreDiscordButton",
    "PluginsTile", "PluginsTileValue", "PluginsTileDetail", "DiscordTile", "DiscordTileValue", "DiscordTileDetail",
    "BuildTile", "BuildTileValue", "BuildTileDetail", "RecentList", "RecentEmptyText",
    "PluginsPage", "PluginsSummary", "PluginsSubtitle", "PluginSearchBox", "PluginSearchHint", "OpenPluginsButton",
    "PluginList", "DisabledPluginsPanel", "DisabledPluginList", "PluginsEmptyText",
    "ActivityPage", "NextIssueButton", "CopyLogButton", "OpenLogFileButton", "ClearLogButton", "LogBox", "LogEmptyPanel",
    "SettingsPage", "SourceHostSettings", "DiscordHostSettings", "DevHostSettings",
    "OpenAssistantButton", "OpenLogsFolderButton", "OpenBackupsFolderButton", "AppVersionText",
    "ActivityBarButton", "StatusDot", "StatusText", "LastLogText", "ActivityBusyPanel", "ActivityElapsedText"
)

foreach ($controlName in $controlNames) {
    Set-Variable -Name $controlName -Value $window.FindName($controlName) -Scope Script
}

$logoPath = Join-Path $PSScriptRoot "assets\cord-builder-logo.png"
if (Test-Path -LiteralPath $logoPath -PathType Leaf) {
    $logoBitmap = [System.Windows.Media.Imaging.BitmapImage]::new()
    $logoBitmap.BeginInit()
    $logoBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $logoBitmap.UriSource = [Uri]::new($logoPath, [UriKind]::Absolute)
    $logoBitmap.EndInit()
    $logoBitmap.Freeze()
    $TitleLogoImage.Source = $logoBitmap
    $window.Icon = $logoBitmap
}

if ($SelfTest) {
    $missingControls = @($controlNames | Where-Object { $null -eq $window.FindName($_) })
    if ($missingControls.Count -gt 0) {
        throw "XAML controls missing: $($missingControls -join ', ')"
    }

    $testQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $testCancellation = [System.Threading.CancellationTokenSource]::new()
    $commandProcessor = $env:ComSpec
    if (-not $commandProcessor) { $commandProcessor = "cmd.exe" }
    $runnerTask = [BuilderProcessRunner]::RunAsync(
        $commandProcessor,
        [string[]]@("/d", "/c", "echo", "runner path with spaces works"),
        $PSScriptRoot,
        $testQueue,
        $testCancellation.Token
    )
    $runnerTask.Wait()
    if ($runnerTask.Result -ne 0) { throw "Process runner test failed with exit code $($runnerTask.Result)." }
    $runnerOutput = [System.Collections.Generic.List[string]]::new()
    $testLine = $null
    while ($testQueue.TryDequeue([ref]$testLine)) {
        $runnerOutput.Add($testLine)
        $testLine = $null
    }
    if (($runnerOutput -join "`n") -notmatch "runner path with spaces works") {
        throw "Process runner did not preserve a spaced argument."
    }

    $npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($npmCommand) {
        $batchQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $batchTask = [BuilderProcessRunner]::RunAsync(
            $npmCommand.Source,
            [string[]]@("--version"),
            $PSScriptRoot,
            $batchQueue,
            $testCancellation.Token
        )
        $batchTask.Wait()
        if ($batchTask.Result -ne 0) { throw "Batch-command runner test failed with exit code $($batchTask.Result)." }
    }

    $probe = [BuilderProcessRunner]::ProbeAsync($commandProcessor, [string[]]@("/d", "/c", "echo", "1.2.3"), $PSScriptRoot, '^\d+\.\d+\.\d+', 5000)
    if ($probe.Result -ne "1.2.3") { throw "Parallel tool probe did not return the version line." }

    $testCancellation.Dispose()

    # Exercise the Windows 10 corner clip on a real window handle, then remove it again.
    $testHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle()
    [BuilderWindowShell]::ClipCorners($testHandle, 200, 120, 16)
    [BuilderWindowShell]::ClipCorners($testHandle, 0, 0, 0)
    Write-Output "PASS: WPF loaded, $($controlNames.Count) named controls resolved, and command quoting worked."
    $window.Close()
    exit 0
}

$script:SettingsPath = $null
$script:LegacySettingsPath = Join-Path $PSScriptRoot "builder.settings.json"
$script:CurrentClient = "Vencord"
$script:IsBusy = $false
$script:ToolSetupActive = $false
$script:PrerequisiteState = $null
$script:PrerequisiteProbe = $null
$script:PendingCommands = [System.Collections.Generic.Queue[object]]::new()
$script:OutputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:CurrentTask = $null
$script:CurrentCommand = $null
$script:Cancellation = $null
$script:OnSequenceSuccess = $null
$script:OnSequenceFailure = $null
$script:Settings = $null
$script:BuildInvalidated = $false
$script:SourceSnapshotTask = $null
$script:SourceScanCancellation = $null
$script:SourcePath = $null
$script:SourceHash = $null
$script:SourceError = $null
$script:NextSourceScan = [DateTime]::MinValue
$script:DeferredCommands = @()
$script:DeferredOnSuccess = $null
$script:ReadinessCache = @{}
$script:RunAllStage = $null
$script:LastFailure = $null
$script:SequenceStartedAt = $null
$script:CommandStartedAt = $null
$script:LastBuildDuration = $null
$script:GitInfo = $null
$script:GitInfoTask = $null
$script:GitInfoCancellation = $null
$script:GitInfoPath = $null
$script:NextGitFetch = [DateTime]::MinValue
$script:LogWriter = $null
$script:LogFilePath = $null
$script:LogLineCount = 0
$script:LogScrollViewer = $null
$script:RecentLines = [System.Collections.Generic.Queue[string]]::new()
$script:ViewReady = $false
$script:CurrentPage = $null
$script:PreviousPage = "Home"
$script:AssistantStep = 1
$script:AdvanceAssistant = $false
$script:HeroAction = $null
$script:PluginItems = @()
$script:PluginItemsKey = $null
$script:PluginFilter = ""
$script:BuiltInPluginNames = $null
$script:BuiltInPluginNamesKey = $null
$script:HistoryPath = $null
$script:RegionCorners = $false
$script:AppVersion = "1.0.0"
# GitHub repository ("owner/name") whose latest release is compared with AppVersion. Empty turns the check off.
$script:UpdateRepository = "Its2Factor/cord-builder"
$script:UpdateTask = $null
$script:UpdateClient = $null
$script:NextUpdateCheck = [DateTime]::MinValue
$script:AvailableUpdate = $null
$script:PrepareKind = $null

function Get-ScriptState {
    # Reads optional script state; isolated tests load functions without the app's start-up variables.
    param([string] $Name, $Default = $null)
    $variable = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $variable) { return $Default }
    return $variable.Value
}

function Get-OptionalProperty {
    param([object] $Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-CurrentUserContext {
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    if (-not $profile -or -not $localAppData) { throw "Windows did not report this user's profile or local app-data folder." }
    if (-not $documents) { $documents = Join-Path $profile "Documents" }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $userSid = $identity.User.Value }
    finally { $identity.Dispose() }
    return [pscustomobject]@{
        Sid = $userSid
        Profile = $profile
        Documents = $documents
        Desktop = $desktop
        LocalAppData = $localAppData
        OneDrive = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Get-UserSettingsPath {
    return Join-Path (Get-CurrentUserContext).LocalAppData "CordBuilder\settings.json"
}

function Test-SourceCheckout {
    param([string] $Path, [string] $Client)
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $Path ".git")) -or
            -not (Test-Path -LiteralPath (Join-Path $Path "src") -PathType Container)) { return $false }
        $package = Get-Content -LiteralPath (Join-Path $Path "package.json") -Raw -ErrorAction Stop | ConvertFrom-Json
        return $package.name -eq $Client.ToLowerInvariant() -and
            [bool]$package.scripts.build -and [bool]$package.scripts.inject
    }
    catch { return $false }
}

function Get-DefaultSourcePath {
    param([string] $Client, [object] $Context = (Get-CurrentUserContext))
    # Check common locations for this user only. Never scan other users or entire drives.
    $parents = @($Context.Documents, (Join-Path $Context.Profile "Documents"))
    foreach ($oneDrive in $Context.OneDrive) { $parents += Join-Path $oneDrive "Documents" }
    $parents += @(
        (Join-Path $Context.Documents "GitHub"),
        (Join-Path $Context.Profile "source\repos"),
        $Context.Profile, $Context.Desktop
    )
    foreach ($parent in @($parents | Where-Object { $_ } | Select-Object -Unique)) {
        $candidate = Join-Path $parent $Client
        if (Test-SourceCheckout $candidate $Client) { return $candidate }
    }
    # A new checkout will be created here only when Prepare is clicked.
    return Join-Path $Context.Documents $Client
}

function Test-AbsoluteSettingsPath {
    param([string] $Path)
    if (-not $Path -or $Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)') { return $false }
    try { [void][IO.Path]::GetFullPath($Path); return $true }
    catch { return $false }
}

function Test-LegacySourceOwnership {
    param([string] $Path, [string] $Client, [object] $Context)
    if (-not (Test-AbsoluteSettingsPath $Path)) { return $false }
    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($root in @($Context.Profile, $Context.Documents, $Context.Desktop) + $Context.OneDrive) {
        if (-not $root) { continue }
        $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        if ($candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return Test-SourceCheckout $candidate $Client
        }
    }
    return $false
}

function Get-DefaultSettings {
    $context = Get-CurrentUserContext
    return [pscustomobject]@{
        SettingsVersion = 2
        OwnerSid = $context.Sid
        OwnerProfile = $context.Profile
        VencordPath = Get-DefaultSourcePath "Vencord" $context
        EquicordPath = Get-DefaultSourcePath "Equicord" $context
        LastClient = "Vencord"
        TargetBranch = "stable"
        DevMode = $false
        SetupCompleted = $false
    }
}

function Load-Settings {
    $defaults = Get-DefaultSettings
    $context = Get-CurrentUserContext
    $isLegacy = -not (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)
    $readPath = if ($isLegacy) { $script:LegacySettingsPath } else { $script:SettingsPath }
    if (-not (Test-Path -LiteralPath $readPath -PathType Leaf)) { return $defaults }
    try {
        $loaded = Get-Content -LiteralPath $readPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $sidProperty = $loaded.PSObject.Properties["OwnerSid"]
        $profileProperty = $loaded.PSObject.Properties["OwnerProfile"]
        $owned = $null -ne $sidProperty -and $sidProperty.Value -eq $context.Sid -and
            $null -ne $profileProperty -and $profileProperty.Value -eq $context.Profile
        # Account-tagged settings copied from another user must never supply defaults.
        if ($null -ne $sidProperty -and -not $owned) { return $defaults }
        if (-not $isLegacy -and -not $owned) { return $defaults }
        $usePreferences = $owned
        foreach ($client in @("Vencord", "Equicord")) {
            $property = $loaded.PSObject.Properties[$client + "Path"]
            if ($null -eq $property -or $property.Value -isnot [string]) { continue }
            $path = $property.Value.Trim()
            $canUse = if ($owned) { Test-AbsoluteSettingsPath $path }
                else { Test-LegacySourceOwnership $path $client $context }
            if ($canUse) {
                $defaults.($client + "Path") = $path
                $usePreferences = $true
            }
        }
        if (-not $usePreferences) { return $defaults }
        $clientProperty = $loaded.PSObject.Properties["LastClient"]
        if ($null -ne $clientProperty -and $clientProperty.Value -in @("Vencord", "Equicord")) {
            $defaults.LastClient = [string]$clientProperty.Value
        }
        $targetBranchProperty = $loaded.PSObject.Properties["TargetBranch"]
        if ($null -ne $targetBranchProperty -and $targetBranchProperty.Value -in @("stable", "ptb", "canary", "development")) {
            $defaults.TargetBranch = [string]$targetBranchProperty.Value
        }
        $devModeProperty = $loaded.PSObject.Properties["DevMode"]
        if ($null -ne $devModeProperty -and $devModeProperty.Value -is [bool]) { $defaults.DevMode = $devModeProperty.Value }
        $setupProperty = $loaded.PSObject.Properties["SetupCompleted"]
        if ($owned -and $null -ne $setupProperty -and $setupProperty.Value -is [bool]) { $defaults.SetupCompleted = $setupProperty.Value }
    }
    catch {
        # A malformed settings file should never prevent the builder from opening.
    }

    return $defaults
}

function Save-Settings {
    if ($null -eq $script:Settings) { return }
    $script:Settings.LastClient = $script:CurrentClient
    $script:Settings.DevMode = [bool]$DevModeCheck.IsChecked
    if ($null -ne $DiscordChannelCombo.SelectedItem) {
        $script:Settings.TargetBranch = [string]$DiscordChannelCombo.SelectedItem.Branch
    }
    if ($script:CurrentClient -eq "Vencord") {
        $script:Settings.VencordPath = $ProjectPathBox.Text.Trim()
    }
    else {
        $script:Settings.EquicordPath = $ProjectPathBox.Text.Trim()
    }

    try {
        $context = Get-CurrentUserContext
        $script:Settings.OwnerSid = $context.Sid
        $script:Settings.OwnerProfile = $context.Profile
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:SettingsPath) -Force | Out-Null
        # Write a temporary file first so a crash mid-write cannot leave a truncated settings file.
        $json = $script:Settings | ConvertTo-Json
        $temporaryPath = $script:SettingsPath + ".tmp"
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $script:SettingsPath, $null)
        }
        else {
            [IO.File]::Move($temporaryPath, $script:SettingsPath)
        }
    }
    catch {
        # Settings persistence is convenient but non-critical.
    }
}

function Get-LogsFolder {
    return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "CordBuilder\logs"
}

function Open-LogFile {
    try {
        $folder = Get-LogsFolder
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        # Keep the 20 most recent session logs.
        Get-ChildItem -LiteralPath $folder -Filter "cord-builder-*.log" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 19 |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        $script:LogFilePath = Join-Path $folder ("cord-builder-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
        $script:LogWriter = [IO.StreamWriter]::new($script:LogFilePath, $true, [Text.UTF8Encoding]::new($false))
        $script:LogWriter.AutoFlush = $true
    }
    catch {
        $script:LogWriter = $null
        $script:LogFilePath = $null
    }
}

function Get-LogScrollViewer {
    if ($null -eq $script:LogScrollViewer -and $null -ne $LogBox.Template) {
        $script:LogScrollViewer = $LogBox.Template.FindName("PART_ContentHost", $LogBox)
    }
    return $script:LogScrollViewer
}

function Write-LogText {
    param([string] $Text, [int] $LineCount)
    if (-not $Text) { return }
    $viewer = Get-LogScrollViewer
    # Follow new output only when the reader is already at the bottom.
    $atBottom = $null -eq $viewer -or $viewer.VerticalOffset -ge ($viewer.ScrollableHeight - 4)
    $LogBox.AppendText($Text)
    $script:LogLineCount += $LineCount
    if ($script:LogLineCount -eq $LineCount) { Update-LogControls }
    if ($null -ne $script:LogWriter) {
        try { $script:LogWriter.Write($Text) } catch { }
    }
    if ($script:LogLineCount -gt 8000) {
        # Keep the on-screen log responsive; the log file keeps everything.
        $content = $LogBox.Text
        $index = -1
        for ($i = 0; $i -lt ($script:LogLineCount - 6000); $i++) {
            $index = $content.IndexOf("`n", $index + 1)
            if ($index -lt 0) { break }
        }
        if ($index -ge 0) {
            $LogBox.Text = "[Earlier output trimmed. The full log is in the log file.]" + [Environment]::NewLine + $content.Substring($index + 1)
            $script:LogLineCount = 6001
            $atBottom = $true
        }
    }
    if ($atBottom) { $LogBox.ScrollToEnd() }
}

function Add-RecentLine {
    param([string] $Line)
    $script:RecentLines.Enqueue($Line)
    while ($script:RecentLines.Count -gt 8) { [void]$script:RecentLines.Dequeue() }
}

function Add-LogLine {
    param([string] $Message, [switch] $NoTimestamp)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $prefix = if ($NoTimestamp) { "" } else { "[$(Get-Date -Format 'HH:mm:ss')] " }
    Write-LogText ($prefix + $Message + [Environment]::NewLine) 1
    Add-RecentLine $Message
    Update-RecentOutput
}

function Update-RecentOutput {
    if ($script:RecentLines.Count -eq 0) { return }
    $lines = $script:RecentLines.ToArray()
    $LastLogText.Text = $lines[$lines.Count - 1]
    $AssistantLogText.Text = ($lines | Select-Object -Last 6) -join [Environment]::NewLine
}

function Flush-OutputQueue {
    # Append command output in one batch per tick instead of one UI update per line.
    $builder = [System.Text.StringBuilder]::new()
    $count = 0
    $line = $null
    while ($count -lt 4000 -and $script:OutputQueue.TryDequeue([ref]$line)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            [void]$builder.Append($line).Append([Environment]::NewLine)
            Add-RecentLine $line
            $count++
        }
        $line = $null
    }
    if ($count -gt 0) {
        Write-LogText $builder.ToString() $count
        Update-RecentOutput
    }
}

function Find-NextLogIssue {
    $text = $LogBox.Text
    if (-not $text) { return }
    $pattern = [regex]::new('(?im)^.*(\berror\b|\bERR!|\bfailed\b|\bfatal\b|\[launcher error\]|needs attention).*$')
    $start = [Math]::Min($text.Length, $LogBox.SelectionStart + [Math]::Max(1, $LogBox.SelectionLength))
    $match = $pattern.Match($text, $start)
    if (-not $match.Success) { $match = $pattern.Match($text, 0) }
    if (-not $match.Success) {
        Set-AppStatus "No errors in the output" "Success"
        return
    }
    [void]$LogBox.Focus()
    $LogBox.Select($match.Index, $match.Length)
    $LogBox.ScrollToLine($LogBox.GetLineIndexFromCharacterIndex($match.Index))
}

function Update-LogControls {
    # An empty log shows a short explanation, and actions that need output stay disabled.
    $hasText = [int](Get-ScriptState "LogLineCount" 0) -gt 0
    $LogEmptyPanel.Visibility = if ($hasText) { "Collapsed" } else { "Visible" }
    $NextIssueButton.IsEnabled = $hasText
    $CopyLogButton.IsEnabled = $hasText
    $ClearLogButton.IsEnabled = $hasText
    $OpenLogFileButton.IsEnabled = [bool](Get-ScriptState "LogFilePath")
}

function Read-History {
    $path = Get-ScriptState "HistoryPath"
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try {
        # Windows PowerShell returns a JSON array as one object, so unwrap it before filtering.
        $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        return @(@($data) | Where-Object { $null -ne $_ -and $_.PSObject.Properties["At"] -and $_.PSObject.Properties["Text"] })
    }
    catch { return @() }
}

function Add-HistoryEntry {
    # Records a verified step for Home's Recent list. Isolated tests have no history file and skip this.
    param([string] $Text)
    $path = Get-ScriptState "HistoryPath"
    if (-not $path) { return }
    $entries = @(@([pscustomobject]@{ At = [DateTime]::UtcNow.ToString("o"); Text = $Text }) + @(Read-History) | Select-Object -First 20)
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $temporaryPath = $path + ".tmp"
        [IO.File]::WriteAllText($temporaryPath, (ConvertTo-Json -InputObject $entries), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Replace($temporaryPath, $path, $null) }
        else { [IO.File]::Move($temporaryPath, $path) }
    }
    catch {
        # History is a convenience; a write failure must never fail the verified step itself.
    }
    if (Test-ViewReady) { Update-RecentList }
}

function Format-RecentTime {
    param([DateTime] $Time)
    $local = $Time.ToLocalTime()
    $clock = $local.ToString("t")
    if ($local.Date -eq [DateTime]::Today) { return "Today, $clock" }
    if ($local.Date -eq [DateTime]::Today.AddDays(-1)) { return "Yesterday, $clock" }
    if ($local.Year -eq [DateTime]::Today.Year) { return $local.ToString("d MMM") + ", $clock" }
    return $local.ToString("d MMM yyyy")
}

function Update-RecentList {
    $items = @(Read-History | Select-Object -First 4 | ForEach-Object {
        try {
            $time = [DateTime]::Parse($_.At, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            [pscustomobject]@{ Text = [string]$_.Text; When = Format-RecentTime $time }
        }
        catch { }
    })
    $RecentList.ItemsSource = $items
    $RecentEmptyText.Visibility = if ($items.Count -eq 0) { "Visible" } else { "Collapsed" }
}

function Get-Brush {
    param([string] $Color)
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Set-AppStatus {
    param(
        [string] $Text,
        [ValidateSet("Ready", "Busy", "Error", "Success")]
        [string] $Kind = "Ready"
    )

    $colors = @{
        Ready = "#8E8E93"
        Busy = "#0A84FF"
        Error = "#FF453A"
        Success = "#30D158"
    }
    $StatusText.Text = $Text
    $StatusDot.Fill = Get-Brush $colors[$Kind]
}

function Get-ProjectPath {
    return $ProjectPathBox.Text.Trim()
}

function Get-RepoUrl {
    if ($script:CurrentClient -eq "Vencord") { return "https://github.com/Vendicated/Vencord" }
    return "https://github.com/Equicord/Equicord"
}

function Get-InstallArguments {
    if ($script:CurrentClient -eq "Vencord") { return @("install", "--frozen-lockfile") }
    return @("install", "--no-frozen-lockfile")
}

function Get-BuildArguments {
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add("build")
    if ([bool]$DevModeCheck.IsChecked) { $arguments.Add("--dev") }
    return $arguments.ToArray()
}

function New-Command {
    param(
        [string] $Label,
        [string] $File,
        [string[]] $Arguments,
        [string] $WorkingDirectory
    )

    return [pscustomobject]@{
        Label = $Label
        File = $File
        Arguments = $Arguments
        WorkingDirectory = $WorkingDirectory
    }
}

function Resolve-CommandPath {
    param([string[]] $Names)
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { return $command.Source }
    }
    return $null
}

function Get-LocalRuntimeRoot {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    return Join-Path $localAppData "CordBuilder\runtime"
}

function Get-LocalNodeDirectory {
    $runtimeRoot = Get-LocalRuntimeRoot
    $pointerPath = Join-Path $runtimeRoot "node-current.txt"
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) { return $null }
    try { $directoryName = ([string](Get-Content -LiteralPath $pointerPath -First 1 -ErrorAction Stop)).Trim() }
    catch { return $null }
    if ($directoryName -notmatch '^node-v\d+\.\d+\.\d+-win-(x64|arm64|x86)(-repair-[a-f0-9]{32})?$') { return $null }

    $rootPath = [IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\') + '\'
    $candidatePath = [IO.Path]::GetFullPath((Join-Path $runtimeRoot $directoryName))
    if (-not $candidatePath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $candidatePath "node.exe") -PathType Leaf)) { return $null }
    return $candidatePath
}

function Get-LocalGitDirectory {
    $runtimeRoot = Get-LocalRuntimeRoot
    $pointer = Join-Path $runtimeRoot "git-current.txt"
    if (-not (Test-Path -LiteralPath $pointer -PathType Leaf)) { return $null }
    try { $name = ([string](Get-Content -LiteralPath $pointer -First 1 -ErrorAction Stop)).Trim() }
    catch { return $null }
    if ($name -cnotmatch '^git-MinGit-\d+\.\d+\.\d+(?:\.\d+)?-(64-bit|32-bit|arm64)-[a-f0-9]{32}$') { return $null }
    $directory = Join-Path $runtimeRoot $name
    if (-not (Test-Path -LiteralPath (Join-Path $directory "cmd\git.exe") -PathType Leaf)) { return $null }
    return $directory
}

function Get-LocalPnpmPath {
    $candidate = Join-Path (Get-LocalRuntimeRoot) "pnpm\pnpm.cmd"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Use-LocalNodeRuntime {
    $nodeDirectory = Get-LocalNodeDirectory
    if (-not $nodeDirectory) { return }
    $pathEntries = @($env:Path -split ';' | Where-Object { $_ -and $_ -ne $nodeDirectory })
    $env:Path = (@($nodeDirectory) + $pathEntries) -join ';'
}

function Refresh-ToolSearchPath {
    # Pick up installer PATH changes without discarding inherited custom paths.
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($scope in @("Machine", "User")) {
        $storedPath = [Environment]::GetEnvironmentVariable("Path", $scope)
        foreach ($entry in @($storedPath -split ';')) {
            if ($entry) { $paths.Add([Environment]::ExpandEnvironmentVariables($entry)) }
        }
    }
    foreach ($entry in @($env:Path -split ';')) {
        if ($entry) { $paths.Add($entry) }
    }
    $localPnpm = Get-LocalPnpmPath
    if ($localPnpm) { $paths.Insert(0, (Split-Path -Parent $localPnpm)) }
    $localGit = Get-LocalGitDirectory
    if ($localGit) { $paths.Insert(0, (Join-Path $localGit "cmd")) }
    $env:Path = ($paths | Select-Object -Unique) -join ';'
    Use-LocalNodeRuntime
}

function Get-ToolPaths {
    $localGitDirectory = Get-LocalGitDirectory
    $localNodeDirectory = Get-LocalNodeDirectory
    $localNode = if ($localNodeDirectory) { Join-Path $localNodeDirectory "node.exe" } else { $null }
    $localNpm = if ($localNodeDirectory) { Join-Path $localNodeDirectory "npm.cmd" } else { $null }
    $localPnpm = Get-LocalPnpmPath
    return [pscustomobject]@{
        Git = if ($localGitDirectory) { Join-Path $localGitDirectory "cmd\git.exe" } else { Resolve-CommandPath @("git.exe", "git") }
        Node = if ($localNode -and (Test-Path -LiteralPath $localNode -PathType Leaf)) { $localNode } else { Resolve-CommandPath @("node.exe", "node") }
        Pnpm = if ($localPnpm) { $localPnpm } else { Resolve-CommandPath @("pnpm.cmd", "pnpm.exe", "pnpm") }
        Npm = if ($localNpm -and (Test-Path -LiteralPath $localNpm -PathType Leaf)) { $localNpm } else { Resolve-CommandPath @("npm.cmd", "npm.exe", "npm") }
    }
}

function Get-ToolProbe {
    param(
        [string] $File,
        [string[]] $Arguments = @("--version"),
        [string] $Pattern = '^\d+\.\d+\.\d+',
        [int] $TimeoutMilliseconds = 6000
    )
    if (-not $File) { return $null }
    try { return [BuilderProcessRunner]::ProbeAsync($File, $Arguments, $PSScriptRoot, $Pattern, $TimeoutMilliseconds).Result }
    catch { return $null }
}

function Get-NodeLtsName {
    param([string] $NodePath)
    if (-not $NodePath) { return $null }
    $value = Get-ToolProbe $NodePath @("-p", "'cord-builder-lts:' + (process.release.lts || '')") '^cord-builder-lts:[A-Za-z0-9]+$'
    if ($value) { return $value.Substring("cord-builder-lts:".Length) }
    return $null
}

function Start-PrerequisiteProbe {
    # Starts every tool check at once; each one has its own timeout.
    $tools = Get-ToolPaths
    $start = {
        param([string] $File, [string[]] $Arguments, [string] $Pattern)
        if (-not $File) { return $null }
        return [BuilderProcessRunner]::ProbeAsync($File, $Arguments, $PSScriptRoot, $Pattern, 6000)
    }
    return [pscustomobject]@{
        Tools = $tools
        Git = & $start $tools.Git @("--version") '^git version \d+\.\d+'
        Node = & $start $tools.Node @("-p", "'cord-builder-node:' + process.version + ':' + (process.release.lts || '')") '^cord-builder-node:v\d+\.\d+\.\d+:[A-Za-z0-9]*$'
        Pnpm = & $start $tools.Pnpm @("--version") '^\d+\.\d+\.\d+'
    }
}

function Get-ProbeResult {
    param($Probe)
    if ($null -eq $Probe) { return $null }
    if ($Probe -is [System.Threading.Tasks.Task]) {
        try { return $Probe.Result } catch { return $null }
    }
    return [string]$Probe
}

function Test-PrerequisiteProbeComplete {
    param([object] $Probe)
    foreach ($name in @("Git", "Node", "Pnpm")) {
        $value = $Probe.$name
        if ($value -is [System.Threading.Tasks.Task] -and -not $value.IsCompleted) { return $false }
    }
    return $true
}

function Complete-PrerequisiteProbe {
    param([object] $Probe)
    $gitVersion = Get-ProbeResult $Probe.Git
    $nodeLine = Get-ProbeResult $Probe.Node
    $nodeVersion = $null
    $ltsName = $null
    if ($nodeLine -match '^cord-builder-node:(v\d+\.\d+\.\d+):([A-Za-z0-9]*)$') {
        $nodeVersion = $matches[1]
        if ($matches[2]) { $ltsName = $matches[2] }
    }
    $pnpmVersion = Get-ProbeResult $Probe.Pnpm
    $nodeReady = [bool]$nodeVersion -and ($script:CurrentClient -ne "Equicord" -or [bool]$ltsName)
    $missing = [System.Collections.Generic.List[string]]::new()
    if (-not $gitVersion) { $missing.Add("Git") }
    if (-not $nodeReady) {
        $missing.Add($(if ($script:CurrentClient -eq "Equicord") { "Node.js LTS" } else { "Node.js" }))
    }
    if (-not $pnpmVersion) { $missing.Add("pnpm") }
    return [pscustomobject]@{
        Tools = $Probe.Tools
        GitVersion = $gitVersion
        NodeVersion = $nodeVersion
        LtsName = $ltsName
        PnpmVersion = $pnpmVersion
        GitReady = [bool]$gitVersion
        NodeReady = $nodeReady
        PnpmReady = [bool]$pnpmVersion
        Missing = $missing.ToArray()
        Ready = $missing.Count -eq 0
    }
}

function Get-PrerequisiteState {
    $probe = Start-PrerequisiteProbe
    foreach ($name in @("Git", "Node", "Pnpm")) {
        $value = $probe.$name
        if ($value -is [System.Threading.Tasks.Task]) { try { [void]$value.Wait(8000) } catch { } }
    }
    return Complete-PrerequisiteProbe $probe
}

function Set-PrerequisiteState {
    param([object] $State)
    $script:PrerequisiteState = $State
    $good = "#30D158"; $warn = "#FF9F0A"; $bad = "#FF453A"

    $GitStatus.Text = if ($State.GitReady) { ($State.GitVersion -replace '^git version\s+', '') } else { "Missing or not working" }
    $NodeStatus.Text = if ($State.NodeVersion) { $State.NodeVersion } else { "Missing or not working" }
    if ($State.LtsName) { $NodeStatus.Text += "  (LTS $($State.LtsName))" }
    elseif ($State.NodeVersion) { $NodeStatus.Text += "  (not LTS)" }
    $PnpmStatus.Text = if ($State.PnpmReady) { $State.PnpmVersion } else { "Missing or not working" }
    $GitDot.Fill = Get-Brush $(if ($State.GitReady) { $good } else { $bad })
    $NodeDot.Fill = Get-Brush $(if (-not $State.NodeReady) { $bad } elseif ($State.LtsName) { $good } else { $warn })
    $PnpmDot.Fill = Get-Brush $(if ($State.PnpmReady) { $good } else { $bad })
}

function Update-PrerequisiteStatus {
    # A synchronous check discards any background check so an older result cannot overwrite it.
    $script:PrerequisiteProbe = $null
    Set-PrerequisiteState (Get-PrerequisiteState)
}

function Request-PrerequisiteRefresh {
    if ($null -ne $script:PrerequisiteProbe) { return }
    $script:PrerequisiteProbe = Start-PrerequisiteProbe
}

function Update-PrerequisiteRefresh {
    $probe = $script:PrerequisiteProbe
    if ($null -eq $probe -or -not (Test-PrerequisiteProbeComplete $probe)) { return }
    $script:PrerequisiteProbe = $null
    Set-PrerequisiteState (Complete-PrerequisiteProbe $probe)
    Update-WorkflowState
}

function Stop-GitInfo {
    if ($null -ne $script:GitInfoCancellation) {
        try { $script:GitInfoCancellation.Cancel() } catch { }
    }
    $script:GitInfoTask = $null
    $script:GitInfoCancellation = $null
}

function Request-GitInfo {
    param([switch] $Fetch)
    if ($script:IsBusy -or $script:ToolSetupActive) { return }
    $path = Get-ProjectPath
    $git = Get-OptionalProperty $script:PrerequisiteState "Tools"
    $git = Get-OptionalProperty $git "Git"
    $script:GitInfoPath = $path
    if ($Fetch) { $script:NextGitFetch = [DateTime]::UtcNow.AddMinutes(30) }
    if (-not $git -or -not $path -or -not (Test-Path -LiteralPath (Join-Path $path ".git"))) {
        $script:GitInfo = $null
        return
    }
    Stop-GitInfo
    $script:GitInfoCancellation = [Threading.CancellationTokenSource]::new()
    $script:GitInfoTask = [BuilderProcessRunner]::GitInfoAsync($git, $path, [bool]$Fetch, $script:GitInfoCancellation.Token)
}

function Update-GitInfo {
    if ($null -ne $script:GitInfoTask -and $script:GitInfoTask.IsCompleted) {
        $task = $script:GitInfoTask
        $script:GitInfoTask = $null
        $script:GitInfoCancellation = $null
        if ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $parts = $task.Result -split "`t"
            $behind = 0
            $hasBehind = $parts.Count -gt 2 -and [int]::TryParse($parts[2], [ref]$behind)
            $script:GitInfo = [pscustomobject]@{
                Branch = $parts[0]
                Commit = if ($parts.Count -gt 1) { $parts[1] } else { "" }
                Behind = if ($hasBehind) { $behind } else { $null }
            }
            Update-WorkflowState
        }
    }
    if ($script:IsBusy -or $script:ToolSetupActive -or $null -ne $script:GitInfoTask -or
        $null -eq $script:PrerequisiteState -or -not $script:PrerequisiteState.GitReady) { return }
    if ($script:GitInfoPath -ne (Get-ProjectPath)) { Request-GitInfo -Fetch }
    elseif ([DateTime]::UtcNow -ge $script:NextGitFetch) { Request-GitInfo -Fetch }
}

function Get-GitInfoText {
    $info = $script:GitInfo
    if ($null -eq $info -or -not $info.Commit) { return $null }
    $text = if ($info.Branch -and $info.Branch -ne "HEAD") { "$($info.Branch) · $($info.Commit)" } else { $info.Commit }
    if ($null -ne $info.Behind) {
        if ($info.Behind -eq 0) { $text += " · up to date with upstream" }
        elseif ($info.Behind -eq 1) { $text += " · 1 update available" }
        else { $text += " · $($info.Behind) updates available" }
    }
    return $text
}

function Format-Elapsed {
    param([TimeSpan] $Span)
    return "{0}:{1:00}" -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds
}

function Test-ViewReady {
    return [bool](Get-ScriptState "ViewReady" $false)
}

function Set-Indicator {
    # Timeline badges: Done (green check), Active (blue dot), Error (red !), Pending (empty ring).
    param([string] $Prefix, [ValidateSet("Done", "Active", "Error", "Pending")] [string] $State)
    $badge = $window.FindName("${Prefix}Badge")
    $check = $window.FindName("${Prefix}Check")
    $dot = $window.FindName("${Prefix}Dot")
    $bang = $window.FindName("${Prefix}Bang")
    $line = $window.FindName("${Prefix}Line")
    $colors = @{ Done = "#248A3D"; Active = "#0A84FF"; Error = "#FF453A"; Pending = "#444444" }
    $badge.BorderBrush = Get-Brush $colors[$State]
    $badge.Background = if ($State -in @("Done", "Error")) { Get-Brush $colors[$State] } else { [System.Windows.Media.Brushes]::Transparent }
    $check.Visibility = if ($State -eq "Done") { "Visible" } else { "Collapsed" }
    $dot.Visibility = if ($State -eq "Active") { "Visible" } else { "Collapsed" }
    $bang.Visibility = if ($State -eq "Error") { "Visible" } else { "Collapsed" }
    if ($null -ne $line) { $line.Fill = Get-Brush $(if ($State -eq "Done") { "#248A3D" } else { "#333333" }) }
}

function Set-StepIndicator {
    param([string] $Prefix, [ValidateSet("Done", "Active", "Pending")] [string] $State)
    $badge = $window.FindName("${Prefix}Badge")
    $check = $window.FindName("${Prefix}Check")
    $number = $window.FindName("${Prefix}Number")
    $label = $window.FindName("${Prefix}Label")
    switch ($State) {
        "Done" {
            $badge.Background = Get-Brush "#248A3D"; $badge.BorderBrush = Get-Brush "#248A3D"
            $check.Visibility = "Visible"; $number.Visibility = "Collapsed"
            $label.Foreground = Get-Brush "#98989D"; $label.FontWeight = "Normal"
        }
        "Active" {
            $badge.Background = Get-Brush "#0A84FF"; $badge.BorderBrush = Get-Brush "#0A84FF"
            $check.Visibility = "Collapsed"; $number.Visibility = "Visible"; $number.Foreground = [System.Windows.Media.Brushes]::White
            $label.Foreground = Get-Brush "#F5F5F7"; $label.FontWeight = "SemiBold"
        }
        default {
            $badge.Background = [System.Windows.Media.Brushes]::Transparent; $badge.BorderBrush = Get-Brush "#5E5E5E"
            $check.Visibility = "Collapsed"; $number.Visibility = "Visible"; $number.Foreground = Get-Brush "#98989D"
            $label.Foreground = Get-Brush "#98989D"; $label.FontWeight = "Normal"
        }
    }
}

function Move-Group {
    # Settings and the assistant share one set of inputs; move them to whichever page is showing.
    param([System.Windows.FrameworkElement] $Group, [System.Windows.Controls.ContentControl] $Destination)
    $current = [System.Windows.LogicalTreeHelper]::GetParent($Group)
    if ($current -eq $Destination) { return }
    if ($current -is [System.Windows.Controls.ContentControl]) { $current.Content = $null }
    $Destination.Content = $Group
}

function Get-WorkflowSnapshot {
    $path = Get-ProjectPath
    $toolsReady = $null -ne $script:PrerequisiteState -and $script:PrerequisiteState.Ready
    $available = -not $script:IsBusy -and -not $script:ToolSetupActive
    $dependenciesReady = $toolsReady -and (Test-DependenciesReady)
    $buildReady = $toolsReady -and (Test-BuildReady)
    $injectionReady = $toolsReady -and (Test-InjectionReady)
    $target = Get-SelectedDiscordChannel
    $pluginProblems = @()
    if ($dependenciesReady) {
        try { $pluginProblems = @(Get-InvalidPluginNames) } catch { $pluginProblems = @() }
    }
    return [pscustomobject]@{
        Available = $available
        Busy = $script:IsBusy -or $script:ToolSetupActive
        ToolsReady = $toolsReady
        ToolsChecked = $null -ne $script:PrerequisiteState
        SourceReady = [bool]$path -and (Test-Path -LiteralPath (Join-Path $path "package.json") -PathType Leaf)
        DependenciesReady = $dependenciesReady
        BuildReady = $buildReady
        InjectionReady = $injectionReady
        Target = $target
        TargetAvailable = $null -ne $target
        DiscordPatched = Test-DiscordPatched
        PatchedHere = Test-DiscordPatchedHere
        PluginProblems = $pluginProblems
        CanInstallTools = $available -and -not $toolsReady
        CanCheckTools = $available
        CanPrepare = $available -and $toolsReady
        CanOpenPlugins = $available -and $dependenciesReady
        CanBuild = $available -and $dependenciesReady -and [bool]$script:SourceHash -and -not $buildReady -and $pluginProblems.Count -eq 0
        CanInject = $available -and $buildReady -and $null -ne $target
        CanRestore = $available -and $toolsReady -and $dependenciesReady -and $null -ne $target -and (Test-DiscordPatched)
        CanRunAll = $available -and $toolsReady -and $null -ne $target
    }
}

function Get-FirstIncompleteStep {
    param([object] $State)
    if (-not $State.ToolsReady) { return 1 }
    if (-not $State.DependenciesReady) { return 2 }
    if (-not $State.BuildReady) { return 3 }
    if (-not $State.InjectionReady) { return 4 }
    return 5
}

function Update-WorkflowState {
    $state = Get-WorkflowSnapshot

    $PrepareButton.IsEnabled = $state.CanPrepare
    $UpdateSourceButton.IsEnabled = $state.CanPrepare
    $InstallPrerequisitesButton.IsEnabled = $state.CanInstallTools
    $CheckPrerequisitesButton.IsEnabled = $state.CanCheckTools
    $AssistantCheckButton.IsEnabled = $state.CanCheckTools
    $OpenPluginsButton.IsEnabled = $state.CanOpenPlugins
    $AssistantPluginsButton.IsEnabled = $state.CanOpenPlugins
    $BuildButton.IsEnabled = $state.CanBuild
    $InjectButton.IsEnabled = $state.CanInject
    $ReinjectButton.IsEnabled = $state.CanInject
    $RestoreDiscordButton.IsEnabled = $state.CanRestore
    $RunAllButton.IsEnabled = $state.CanRunAll
    $StopButton.IsEnabled = $state.Busy
    $AssistantStopButton.IsEnabled = $state.Busy

    $VencordRadio.IsEnabled = $state.Available
    $EquicordRadio.IsEnabled = $state.Available
    $ProjectPathBox.IsEnabled = $state.Available
    $BrowseButton.IsEnabled = $state.Available
    $RescanDiscordButton.IsEnabled = $state.Available
    $DevModeCheck.IsEnabled = $state.Available
    $DiscordChannelCombo.IsEnabled = $state.Available -and $DiscordChannelCombo.Items.Count -gt 0

    $InstallPrerequisitesButton.Content = if ($state.ToolsReady) { "All tools installed" }
        elseif ($script:ToolSetupActive) { "Installing tools..." } else { "Install missing tools" }
    $PrepareButton.Content = if ($state.DependenciesReady) { "Update source & reinstall dependencies" }
        elseif ($state.SourceReady) { "Install dependencies" } else { "Download source & dependencies" }
    $BuildButton.Content = if ($state.BuildReady) { "Build up to date" } else { "Build $script:CurrentClient" }
    $InjectButton.Content = if ($state.InjectionReady) { "Verify & re-inject" } else { "Install into Discord" }

    if (Test-ViewReady) {
        Update-AssistantView $state
        # Plugins first: Home's tile and headline use the plugin list it refreshes.
        Update-PluginsView $state
        Update-HomeView $state
    }
}

function Update-AssistantView {
    param([object] $State)
    $first = Get-FirstIncompleteStep $State
    if ($script:AdvanceAssistant -and $State.ToolsChecked) {
        $script:AdvanceAssistant = $false
        $script:AssistantStep = [Math]::Max($script:AssistantStep, [Math]::Min(4, $first))
    }
    $step = $script:AssistantStep

    $index = 1
    foreach ($prefix in @("StepTools", "StepSource", "StepBuild", "StepDiscord")) {
        $indicator = if ($index -lt $first) { "Done" } elseif ($index -eq $step) { "Active" } else { "Pending" }
        Set-StepIndicator $prefix $indicator
        $index++
    }

    $ToolsStepPanel.Visibility = if ($step -eq 1) { "Visible" } else { "Collapsed" }
    $SourceStepPanel.Visibility = if ($step -eq 2) { "Visible" } else { "Collapsed" }
    $BuildStepPanel.Visibility = if ($step -eq 3) { "Visible" } else { "Collapsed" }
    $DiscordStepPanel.Visibility = if ($step -eq 4) { "Visible" } else { "Collapsed" }

    $icons = @{
        1 = "M14.7,6.3 A4,4 0 0 0 9.3,11.7 L3,18 L6,21 L12.3,14.7 A4,4 0 0 0 17.7,9.3 L15.2,11.8 L12.7,11.3 L12.2,8.8 Z"
        2 = "M3,7 A2,2 0 0 1 5,5 L9,5 L11,7 L19,7 A2,2 0 0 1 21,9 L21,17 A2,2 0 0 1 19,19 L5,19 A2,2 0 0 1 3,17 Z M12,10.5 L12,15.5 M9.5,13 L14.5,13"
        3 = "M12,3 L20,7.5 L20,16.5 L12,21 L4,16.5 L4,7.5 Z M12,12 L20,7.5 M12,12 L12,21 M12,12 L4,7.5"
        4 = "M5,4 L19,4 A2,2 0 0 1 21,6 L21,15 A2,2 0 0 1 19,17 L5,17 A2,2 0 0 1 3,15 L3,6 A2,2 0 0 1 5,4 Z M8,21 L16,21 M12,17 L12,21"
    }
    $AssistantIcon.Data = [System.Windows.Media.Geometry]::Parse($icons[$step])
    $client = $script:CurrentClient
    switch ($step) {
        1 {
            $AssistantTitle.Text = if ($State.ToolsReady) { "Your build tools are ready" } else { "Install the build tools" }
            $AssistantBody.Text = if ($State.ToolsReady) { "Git, Node.js and pnpm are installed and verified." }
                elseif (-not $State.ToolsChecked) { "Checking Git, Node.js and pnpm..." }
                else { "Cord Builder needs Git, Node.js and pnpm. Missing tools are installed privately for your account; your system installs aren't changed." }
        }
        2 {
            $AssistantTitle.Text = "Choose a client and where it lives"
            $AssistantBody.Text = "Cord Builder downloads the source here, or updates an existing checkout. Your own changes are backed up before every update."
        }
        3 {
            $AssistantTitle.Text = if ($State.BuildReady) { "$client is built" } else { "Build $client" }
            $AssistantBody.Text = "Compiles the source together with your user plugins. This usually takes under a minute."
        }
        4 {
            $AssistantTitle.Text = if ($State.InjectionReady) { "$client is installed" } else { "Install into Discord" }
            $AssistantBody.Text = if ($State.InjectionReady) { "$client loads the next time Discord starts. You're ready to go." }
                else { "Patches the Discord channel you choose, then restarts it. Your Discord account data isn't touched." }
        }
    }

    $InstallPrerequisitesButton.Visibility = if ($State.ToolsReady) { "Collapsed" } else { "Visible" }
    $ToolsReadyPanel.Visibility = if ($State.ToolsReady) { "Visible" } else { "Collapsed" }

    $total = @($State.PluginProblems).Count
    $AssistantPluginSummary.Text = if ($total -gt 0) { "Fix these plugins before building: $($State.PluginProblems -join ', '). See the Plugins page for details." }
        else { "Add your own plugins to the userplugins folder at any time. Builds include everything in that folder." }

    $StepCounterText.Text = "Step $step of 4"
    $StepProgressFill.Width = 140 * $step / 4
    $BackButton.IsEnabled = $State.Available -and $step -gt 1
    $stepComplete = $step -lt $first
    $ContinueButton.Content = if ($step -eq 4) { "Finish" } else { "Continue" }
    $ContinueButton.IsEnabled = $State.Available -and $stepComplete

    $AssistantProgressPanel.Visibility = if ($State.Busy) { "Visible" } else { "Collapsed" }
    $AssistantLogPanel.Visibility = if ($State.Busy -or (Get-ScriptState "LastFailure")) { "Visible" } else { "Collapsed" }
}

function Update-HomeView {
    param([object] $State)
    $client = $script:CurrentClient
    $targetLabel = if ($State.TargetAvailable) { $State.Target.Label } else { "Discord" }
    $gitText = Get-GitInfoText
    $behind = if ($null -ne $script:GitInfo -and $null -ne $script:GitInfo.Behind) { $script:GitInfo.Behind } else { 0 }

    # Timeline
    if (-not $State.ToolsChecked) {
        Set-Indicator "Tools" "Active"; $ToolsTitle.Text = "Checking tools"; $ToolsDetail.Text = "Git, Node.js and pnpm"
    }
    elseif ($State.ToolsReady) {
        Set-Indicator "Tools" "Done"; $ToolsTitle.Text = "Tools verified"
        $p = $script:PrerequisiteState
        $node = $p.NodeVersion + $(if ($p.LtsName) { " LTS" } else { "" })
        $ToolsDetail.Text = "Git $($p.GitVersion -replace '^git version\s+', '' -replace '\.windows.*$', '') · Node.js $node · pnpm $($p.PnpmVersion)"
    }
    else {
        Set-Indicator "Tools" "Error"; $ToolsTitle.Text = "Tools need attention"; $ToolsDetail.Text = "Missing: $($script:PrerequisiteState.Missing -join ', ')"
    }

    if ($State.DependenciesReady) {
        Set-Indicator "Source" "Done"; $SourceTitle.Text = "Source prepared"
        $SourceDetail.Text = if ($gitText) { $gitText } else { Get-ProjectPath }
    }
    elseif ($State.ToolsReady) {
        Set-Indicator "Source" "Active"; $SourceTitle.Text = "Source not prepared"
        $SourceDetail.Text = if ($State.SourceReady) { "Dependencies need installing" } else { "Not downloaded yet" }
    }
    else { Set-Indicator "Source" "Pending"; $SourceTitle.Text = "Source"; $SourceDetail.Text = "Waiting for tools" }
    $UpdateSourceButton.Content = if ($State.DependenciesReady) { "Update" } else { "Prepare" }

    $snapshot = if ($State.DependenciesReady) { Read-VerifiedBuildSnapshot (Get-ProjectPath) } else { $null }
    $modeText = if ([bool]$DevModeCheck.IsChecked) { "development" } else { "production" }
    if ($State.BuildReady) {
        Set-Indicator "Build" "Done"; $BuildTitle.Text = "Build verified"; $BuildDetail.Text = "Matches your source and plugins · $modeText"
    }
    elseif (@($State.PluginProblems).Count -gt 0) {
        Set-Indicator "Build" "Error"; $BuildTitle.Text = "Build blocked"; $BuildDetail.Text = "Fix: $($State.PluginProblems -join ', ')"
    }
    elseif ($State.DependenciesReady -and -not $script:SourceHash -and -not $script:SourceError) {
        Set-Indicator "Build" "Active"; $BuildTitle.Text = "Checking build"; $BuildDetail.Text = "Comparing your files with the last build"
    }
    elseif ($State.DependenciesReady) {
        Set-Indicator "Build" "Active"; $BuildTitle.Text = "Build needed"
        $BuildDetail.Text = if ($script:SourceError) { "Can't read the source folder. Checking again..." }
            elseif ($snapshot) { "Source or settings changed since the last build" }
            else { "Not built yet" }
    }
    else { Set-Indicator "Build" "Pending"; $BuildTitle.Text = "Build"; $BuildDetail.Text = "Waiting for source" }

    if (-not $State.TargetAvailable) {
        Set-Indicator "Discord" "Error"; $DiscordTitle.Text = "Discord not found"; $DiscordDetail.Text = "Install Discord Desktop, then rescan in Settings"
    }
    elseif ($State.PatchedHere) {
        # Discord loads this folder's build output, so the next verified build reaches it with a restart.
        Set-Indicator "Discord" "Done"; $DiscordTitle.Text = $targetLabel
        $DiscordDetail.Text = if ($State.InjectionReady) { "Patched with this folder" } else { "Patched with this folder · restarts after the build" }
    }
    else {
        Set-Indicator "Discord" $(if ($State.BuildReady) { "Active" } else { "Pending" }); $DiscordTitle.Text = $targetLabel
        $DiscordDetail.Text = if ($State.DiscordPatched) { "Patched from a different folder · Install switches it to this one" } else { "Not patched yet" }
    }
    $ReinjectButton.Content = if ($State.PatchedHere) { "Re-inject" } else { "Install" }

    # Hero: one sentence about what matters now, and the single best next action.
    $eyebrowColor = "#30D158"
    $failure = Get-ScriptState "LastFailure"
    $HeroProgressPanel.Visibility = if ($State.Busy) { "Visible" } else { "Collapsed" }
    $StopButton.Visibility = if ($State.Busy) { "Visible" } else { "Collapsed" }
    $HeroPrimaryButton.Visibility = if ($State.Busy) { "Collapsed" } else { "Visible" }
    $RunAllButton.Visibility = if ($State.Busy -or -not $State.ToolsReady) { "Collapsed" } else { "Visible" }
    $script:HeroAction = $null
    $HeroPrimaryButton.IsEnabled = $true
    $checkingFiles = $false

    if ($State.Busy) {
        $eyebrowColor = "#0A84FF"
        $HeroEyebrow.Text = if (Get-ScriptState "RunAllStage") { "Running all steps" } else { "Working" }
        $label = if ($null -ne $script:CurrentCommand) { $script:CurrentCommand.Label } elseif ($script:ToolSetupActive) { "Installing tools" } else { "Working" }
        $HeroTitle.Text = "$label..."
        $HeroBody.Text = "You can keep using Discord. Output appears in Activity as it happens."
    }
    elseif (-not $State.ToolsChecked) {
        $eyebrowColor = "#8E8E93"; $HeroEyebrow.Text = "Starting up"
        $HeroTitle.Text = "One moment."; $HeroBody.Text = "Checking Git, Node.js and pnpm."
        $HeroPrimaryButton.Content = "Check tools"; $HeroPrimaryButton.IsEnabled = $false
    }
    elseif (-not $State.ToolsReady) {
        $eyebrowColor = "#FF453A"; $HeroEyebrow.Text = "Tools need attention"
        $HeroTitle.Text = "Install the build tools."
        $HeroBody.Text = "Missing: $($script:PrerequisiteState.Missing -join ', '). They're installed privately for your account, with no administrator access."
        $HeroPrimaryButton.Content = "Install missing tools"; $script:HeroAction = { Start-RequiredToolsInstallation }
    }
    elseif (-not $State.DependenciesReady) {
        $eyebrowColor = "#FF9F0A"; $HeroEyebrow.Text = "Source not prepared"
        $HeroTitle.Text = "Prepare $client."
        $HeroBody.Text = if ($State.SourceReady) { "The source is here, but its dependencies need installing." }
            else { "Downloads $client into $(Get-ProjectPath) and installs its dependencies." }
        $HeroPrimaryButton.Content = $PrepareButton.Content; $script:HeroAction = { Start-PrepareProject }
    }
    elseif (@($State.PluginProblems).Count -gt 0) {
        $eyebrowColor = "#FF453A"
        $count = @($State.PluginProblems).Count
        $HeroEyebrow.Text = if ($count -eq 1) { "1 plugin needs a fix" } else { "$count plugins need a fix" }
        $HeroTitle.Text = "Fix a plugin to build."
        $HeroBody.Text = "$($State.PluginProblems -join ', ') can't be built as laid out. The Plugins page shows what to change."
        $HeroPrimaryButton.Content = "Show plugins"; $script:HeroAction = { Show-Page "Plugins" }
    }
    elseif (-not $State.BuildReady) {
        $eyebrowColor = "#FF9F0A"
        $HeroEyebrow.Text = if ($snapshot -or (Test-Path -LiteralPath (Join-Path (Get-ProjectPath) "dist") -PathType Container)) { "Changes detected" } else { "Not built yet" }
        $HeroTitle.Text = "Ready to build."
        $pluginCount = @($script:PluginItems | Where-Object { $_.Enabled }).Count
        $warnedCount = @($script:PluginItems | Where-Object { $_.State -eq "Warning" }).Count
        $pluginText = if ($warnedCount -gt 0) { "$warnedCount plugin$(if ($warnedCount -ne 1) { 's' }) on the Plugins page need$(if ($warnedCount -eq 1) { 's' }) a look. " }
            elseif ($pluginCount -eq 1) { "Your plugin looks valid. " } elseif ($pluginCount -gt 1) { "All $pluginCount plugins look valid. " } else { "" }
        if ($script:SourceError) {
            $eyebrowColor = "#FF453A"; $HeroEyebrow.Text = "Source folder unreadable"
            $HeroTitle.Text = "Can't read your files."
            $HeroBody.Text = "$script:SourceError Cord Builder keeps checking."
            $HeroPrimaryButton.IsEnabled = $false
        }
        elseif (-not $script:SourceHash) {
            # Until the scan finishes it's unknown whether a build is needed, so say so rather than "Ready".
            $checkingFiles = $true
            $eyebrowColor = "#0A84FF"; $HeroEyebrow.Text = "Checking source and plugin files"
            $HeroTitle.Text = "Checking files…"
            $HeroBody.Text = "This takes a few seconds. Build unlocks when it's done."
            $HeroPrimaryButton.IsEnabled = $false
        }
        elseif (-not $State.TargetAvailable) { $HeroBody.Text = "${pluginText}Builds $client with your plugins." }
        else { $HeroBody.Text = "${pluginText}$targetLabel restarts when the build is verified." }
        $HeroPrimaryButton.Content = if ($State.TargetAvailable -and $State.DiscordPatched) { "Build & restart Discord" } else { "Build" }
        $script:HeroAction = { Start-ProjectBuild }
    }
    elseif (-not $State.TargetAvailable) {
        $eyebrowColor = "#FF453A"; $HeroEyebrow.Text = "Build verified"
        $HeroTitle.Text = "Discord wasn't found."
        $HeroBody.Text = "Install Discord Desktop for this Windows account, then rescan."
        $HeroPrimaryButton.Content = "Rescan for Discord"; $script:HeroAction = { Rescan-Discord }
    }
    elseif (-not $State.InjectionReady) {
        $eyebrowColor = "#0A84FF"; $HeroEyebrow.Text = "Build verified"
        $HeroTitle.Text = "Ready to install."
        $HeroBody.Text = "Install into $targetLabel to load this build. Discord closes and restarts automatically."
        $HeroPrimaryButton.Content = "Install into Discord"; $script:HeroAction = { Start-Injection }
    }
    else {
        $HeroEyebrow.Text = "Up to date"
        $HeroTitle.Text = "You're all set."
        $HeroBody.Text = "$client is running in $targetLabel."
        if ($behind -gt 0) {
            $eyebrowColor = "#FF9F0A"
            $HeroEyebrow.Text = if ($behind -eq 1) { "1 update available" } else { "$behind updates available" }
            $HeroBody.Text += " Upstream has new changes; updating rebuilds and reinstalls automatically."
            $HeroPrimaryButton.Content = "Update & rebuild"; $script:HeroAction = { Start-RunAll }
        }
        else {
            $HeroPrimaryButton.Content = "Check for updates"
            $script:HeroAction = { Add-LogLine "Checking upstream for updates..."; Request-GitInfo -Fetch; Update-WorkflowState }
            if ($null -ne $script:GitInfoTask) { $HeroPrimaryButton.Content = "Checking..."; $HeroPrimaryButton.IsEnabled = $false }
        }
    }
    if ($failure -and -not $State.Busy) {
        $eyebrowColor = "#FF453A"
        $HeroEyebrow.Text = "Last step needs attention"
        $HeroBody.Text = "$failure See Activity for the full output."
    }
    $HeroDot.Fill = Get-Brush $eyebrowColor
    $HeroDot.Visibility = if ($checkingFiles) { "Collapsed" } else { "Visible" }
    $HeroSpinner.Visibility = if ($checkingFiles) { "Visible" } else { "Collapsed" }

    # Tiles
    $plugins = @($script:PluginItems | Where-Object { $_.Enabled })
    $offCount = @($script:PluginItems).Count - $plugins.Count
    $PluginsTileValue.Text = [string]$plugins.Count
    $bad = @($plugins | Where-Object { -not $_.Valid })
    $warned = @($plugins | Where-Object { $_.State -eq "Warning" })
    $PluginsTileDetail.Text = if (-not $State.DependenciesReady) { "Available after setup" }
        elseif ($bad.Count -gt 0) { "$($bad.Count) need a fix · $($bad[0].DisplayName)" }
        elseif ($warned.Count -gt 0) { "$($warned.Count) need a look · $($warned[0].DisplayName)" }
        elseif ($plugins.Count -eq 0) { "None yet · open the folder to add some" }
        elseif ($offCount -gt 0) { "All valid · $offCount off" } else { "All valid" }
    $PluginsTileDetail.Foreground = Get-Brush $(if ($bad.Count -gt 0) { "#FF6961" } elseif ($warned.Count -gt 0) { "#FFB340" } else { "#98989D" })

    if ($State.TargetAvailable) {
        $DiscordTileValue.Text = $State.Target.Label -replace '^Discord ', ''
        $patchText = if ($State.PatchedHere) { "Patched with this folder" } elseif ($State.DiscordPatched) { "Patched from another folder" } else { "Not patched" }
        $DiscordTileDetail.Text = "$(if ($State.Target.Version) { $State.Target.Version } else { 'Version unknown' }) · $patchText"
    }
    else { $DiscordTileValue.Text = "None"; $DiscordTileDetail.Text = "Install Discord Desktop" }

    if ($snapshot) {
        try { $built = [DateTime]::Parse($snapshot.CapturedAt).ToLocalTime() } catch { $built = $null }
        $BuildTileValue.Text = if ($built) { $built.ToString("t") } else { "Built" }
        $dayText = if ($built -and $built.Date -eq [DateTime]::Today) { "Today" } elseif ($built) { $built.ToString("d MMM") } else { "" }
        $durationText = if ($script:LastBuildDuration) { " · " + (Format-Elapsed $script:LastBuildDuration) } else { "" }
        $BuildTileDetail.Text = "$dayText · $(if ($snapshot.DevelopmentMode) { 'development' } else { 'production' })$durationText"
    }
    else { $BuildTileValue.Text = "Never"; $BuildTileDetail.Text = "No verified build yet" }
}

function Show-Page {
    param([ValidateSet("Home", "Plugins", "Activity", "Settings", "Assistant")] [string] $Page)
    if ($Page -eq "Home" -and -not $script:Settings.SetupCompleted) { $Page = "Assistant" }
    if ($script:CurrentPage -and $script:CurrentPage -ne "Activity") { $script:PreviousPage = $script:CurrentPage }
    $script:CurrentPage = $Page

    if ($Page -eq "Settings") {
        Move-Group $SourceGroup $SourceHostSettings
        Move-Group $DiscordGroup $DiscordHostSettings
        Move-Group $DevModeGroup $DevHostSettings
    }
    else {
        Move-Group $SourceGroup $SourceHostAssistant
        Move-Group $DiscordGroup $DiscordHostAssistant
        Move-Group $DevModeGroup $DevHostHome
    }

    $AssistantPage.Visibility = if ($Page -eq "Assistant") { "Visible" } else { "Collapsed" }
    $HomePage.Visibility = if ($Page -eq "Home") { "Visible" } else { "Collapsed" }
    $PluginsPage.Visibility = if ($Page -eq "Plugins") { "Visible" } else { "Collapsed" }
    $ActivityPage.Visibility = if ($Page -eq "Activity") { "Visible" } else { "Collapsed" }
    $SettingsPage.Visibility = if ($Page -eq "Settings") { "Visible" } else { "Collapsed" }

    # The setup assistant is its own flow, so the tabs give way to a label instead of highlighting Home.
    $NavPanel.Visibility = if ($Page -eq "Assistant") { "Collapsed" } else { "Visible" }
    $SetupTag.Visibility = if ($Page -eq "Assistant") { "Visible" } else { "Collapsed" }
    $navTarget = switch ($Page) { "Plugins" { $NavPlugins } "Activity" { $NavActivity } "Settings" { $NavSettings } default { $NavHome } }
    if (-not $navTarget.IsChecked) { $navTarget.IsChecked = $true }
    if ($Page -eq "Activity") { $LogBox.ScrollToEnd() }
    Update-WorkflowState
}

function Set-BusyState {
    param([bool] $Busy)
    $script:IsBusy = $Busy
    Update-WorkflowState
}

function Complete-Sequence {
    param([bool] $Succeeded, [string] $Message)
    $script:CurrentTask = $null
    $script:CurrentCommand = $null
    $script:Cancellation = $null

    $successCallback = $script:OnSequenceSuccess
    $failureCallback = $script:OnSequenceFailure
    $script:OnSequenceSuccess = $null
    $script:OnSequenceFailure = $null

    if ($Succeeded -and $null -ne $successCallback) {
        try {
            & $successCallback | Out-Null
        }
        catch {
            $Succeeded = $false
            $Message = "Post-step verification failed: $($_.Exception.Message)"
        }
    }

    Set-BusyState $false

    if ($Succeeded) {
        Add-LogLine $Message
        Set-AppStatus "Verified" "Success"
        $script:LastFailure = $null
        $script:AdvanceAssistant = $true
    }
    else {
        $script:ToolSetupActive = $false
        $script:RunAllStage = $null
        $script:LastFailure = $Message
        Add-LogLine $Message
        Set-AppStatus "Needs attention" "Error"
        if ($null -ne $failureCallback) { & $failureCallback }
    }

    Clear-ReadinessCache
    Request-PrerequisiteRefresh
    Update-WorkflowState

    if ($Succeeded -and $script:DeferredCommands.Count -gt 0) {
        $commands = @($script:DeferredCommands)
        $onSuccess = $script:DeferredOnSuccess
        $script:DeferredCommands = @()
        $script:DeferredOnSuccess = $null
        Start-CommandSequence $commands $onSuccess
    }
    elseif (-not $Succeeded) {
        $script:DeferredCommands = @()
        $script:DeferredOnSuccess = $null
    }

    if ($Succeeded -and -not $script:IsBusy -and (Get-ScriptState "RunAllStage")) {
        [void]$window.Dispatcher.BeginInvoke([Action]{ Continue-RunAll }, [System.Windows.Threading.DispatcherPriority]::Background)
    }
}

function Invoke-NextCommand {
    if ($script:PendingCommands.Count -eq 0) {
        Complete-Sequence $true "All requested steps finished successfully."
        return
    }

    $command = $script:PendingCommands.Dequeue()
    $script:CurrentCommand = $command
    $script:CommandStartedAt = [DateTime]::UtcNow
    Add-LogLine ""
    Add-LogLine "> $($command.Label)" -NoTimestamp
    Add-LogLine "Working directory: $($command.WorkingDirectory)" -NoTimestamp
    Set-AppStatus $command.Label "Busy"
    Update-WorkflowState

    if (-not (Test-Path -LiteralPath $command.WorkingDirectory -PathType Container)) {
        Complete-Sequence $false "Working directory does not exist: $($command.WorkingDirectory)"
        return
    }

    $script:CurrentTask = [BuilderProcessRunner]::RunAsync(
        $command.File,
        [string[]]$command.Arguments,
        $command.WorkingDirectory,
        $script:OutputQueue,
        $script:Cancellation.Token
    )
}

function Start-CommandSequence {
    param(
        [object[]] $Commands,
        [scriptblock] $OnSuccess = $null,
        [scriptblock] $OnFailure = $null
    )

    if ($script:IsBusy) {
        Add-LogLine "A task is already running. Stop it before starting another."
        return
    }
    if ($Commands.Count -eq 0) { return }

    # A background fetch must not hold Git's lock while a real update runs.
    Stop-GitInfo
    $script:PendingCommands.Clear()
    foreach ($command in $Commands) { $script:PendingCommands.Enqueue($command) }
    $script:OnSequenceSuccess = $OnSuccess
    $script:OnSequenceFailure = $OnFailure
    $script:Cancellation = [System.Threading.CancellationTokenSource]::new()
    $script:SequenceStartedAt = [DateTime]::UtcNow
    $script:LastFailure = $null
    Set-BusyState $true
    Invoke-NextCommand
}

function Test-RequiredTools {
    Update-PrerequisiteStatus
    Update-WorkflowState
    if (-not $script:PrerequisiteState.Ready) {
        Add-LogLine "Required tools are missing or not working: $($script:PrerequisiteState.Missing -join ', '). Install them before continuing."
        Set-AppStatus "Missing prerequisites" "Error"
        return $false
    }
    return $true
}

function Continue-RequiredToolsInstallation {
    [void]$window.Dispatcher.BeginInvoke(
        [Action]{ if ($script:ToolSetupActive) { Start-RequiredToolsInstallation -Continue } },
        [System.Windows.Threading.DispatcherPriority]::Background
    )
}

function Start-RequiredToolsInstallation {
    param([switch] $Continue)
    if ($Continue -and -not $script:ToolSetupActive) { return }
    if ($script:IsBusy -or -not (Test-NotElevated)) { return }
    $script:ToolSetupActive = $true
    try {
    Refresh-ToolSearchPath
    Update-PrerequisiteStatus
    Update-WorkflowState
    $state = $script:PrerequisiteState
    if (-not $state.GitReady) {
        Start-GitRepair
        return
    }
    if (-not $state.NodeReady) {
        Start-NodeLtsRepair
        return
    }
    if (-not $state.PnpmReady) {
        if (-not (Get-ToolProbe $state.Tools.Npm)) {
            Add-LogLine "npm is missing or not working. Repairing the private Node.js LTS runtime first."
            Start-NodeLtsRepair
            return
        }
        $pnpmInstallRoot = Join-Path (Get-LocalRuntimeRoot) "pnpm"
        New-Item -ItemType Directory -Path (Get-LocalRuntimeRoot) -Force | Out-Null
        $onSuccess = {
            Refresh-ToolSearchPath
            Update-PrerequisiteStatus
            if (-not $script:PrerequisiteState.Ready) {
                throw "Required-tool verification failed: $($script:PrerequisiteState.Missing -join ', '). Project setup remains locked."
            }
            $script:ToolSetupActive = $false
            Add-LogLine "Git, Node.js and pnpm are verified. You can now prepare the project."
            Add-HistoryEntry "Installed and verified the build tools"
        }
        Start-CommandSequence @((New-Command "Install and verify pnpm" $state.Tools.Npm @(
            "install", "--global", "--prefix", $pnpmInstallRoot,
            "--registry", "https://registry.npmjs.org", "--ignore-scripts", "--no-fund", "--no-audit", "pnpm"
        ) $PSScriptRoot)) $onSuccess
        return
    }
    $script:ToolSetupActive = $false
    Update-WorkflowState
    Add-LogLine "All three required tools are verified. You can now prepare the project."
    if ($Continue) { Add-HistoryEntry "Installed and verified the build tools" }
    Set-AppStatus "Required tools ready" "Success"
    }
    catch {
        $script:ToolSetupActive = $false
        Add-LogLine "Tool setup stopped: $($_.Exception.Message) Click Install missing tools to retry."
        Set-AppStatus "Tool setup needs attention" "Error"
        Update-WorkflowState
    }
}

function Start-GitRepair {
    $helperPath = Join-Path $PSScriptRoot "InstallGit.ps1"
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "The private Git installer is missing: $helperPath"
    }
    Add-LogLine "Installing private Git from the official Git for Windows release. Existing system Git will not be changed."
    $onSuccess = {
        Refresh-ToolSearchPath
        Update-PrerequisiteStatus
        if (-not $script:PrerequisiteState.GitReady) {
            throw "Git finished installing but did not pass its version check. Tool setup stopped."
        }
        Add-LogLine "Git verified. Checking the next required tool..."
        Continue-RequiredToolsInstallation
    }
    Start-CommandSequence @((New-Command "Install and verify Git" "powershell.exe" @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $helperPath,
        "-InstallRoot", (Get-LocalRuntimeRoot)
    ) $PSScriptRoot)) $onSuccess
}

function Start-NodeLtsRepair {
    $helperPath = Join-Path $PSScriptRoot "InstallNodeLts.ps1"
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "The managed Node.js LTS installer is missing: $helperPath"
    }

    $runtimeRoot = Get-LocalRuntimeRoot
    Add-LogLine "Cord Builder will install a private Node.js LTS runtime. Your existing system Node.js will not be changed."
    $onSuccess = {
        Refresh-ToolSearchPath
        $repairedTools = Get-ToolPaths
        $ltsName = Get-NodeLtsName $repairedTools.Node
        if (-not $repairedTools.Node -or -not $ltsName) {
            throw "The managed Node.js installation finished but LTS verification failed."
        }
        if (-not (Get-ToolProbe $repairedTools.Npm)) {
            throw "Node.js is ready, but its bundled npm is not working. Tool installation stopped."
        }
        Add-LogLine "Verified managed Node.js LTS ($ltsName): $($repairedTools.Node)"
        Update-PrerequisiteStatus
        Continue-RequiredToolsInstallation
    }
    Start-CommandSequence @((New-Command "Install and verify Node.js LTS" "powershell.exe" @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $helperPath,
        "-InstallRoot", $runtimeRoot
    ) $PSScriptRoot)) $onSuccess
}

function Test-NotElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdministrator) { return $true }

        Add-LogLine "This workflow was stopped because Cord Builder is running as Administrator. Close it and launch it normally; Equicord warns that elevated injection can break Discord."
        Set-AppStatus "Do not run as Administrator" "Error"
        return $false
    }
    catch {
        return $true
    }
}

function Test-SafeProjectPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-LogLine "Choose a source folder first."
        Set-AppStatus "Choose a folder" "Error"
        return $false
    }
    try { $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
    catch {
        Add-LogLine "The selected source path is invalid."
        Set-AppStatus "Invalid source path" "Error"
        return $false
    }

    $driveRoot = [IO.Path]::GetPathRoot($fullPath).TrimEnd('\', '/')
    if ($fullPath -eq $driveRoot) {
        Add-LogLine "Choose a folder inside Documents or another user-owned location, not the root of a drive."
        Set-AppStatus "Unsafe source path" "Error"
        return $false
    }

    $protectedRoots = @(
        $env:WINDIR,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData
    ) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') }

    foreach ($protectedRoot in $protectedRoots) {
        if ($fullPath.Equals($protectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($protectedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            Add-LogLine "The selected folder is inside a protected Windows location: $protectedRoot"
            Add-LogLine "Choose a user-owned location such as Documents\$script:CurrentClient."
            Set-AppStatus "Unsafe source path" "Error"
            return $false
        }
    }
    return $true
}

function Test-ProjectRoot {
    $path = Get-ProjectPath
    if (-not $path) {
        Add-LogLine "Choose a source folder first."
        Set-AppStatus "Choose a folder" "Error"
        return $false
    }
    if (-not (Test-Path -LiteralPath (Join-Path $path "package.json") -PathType Leaf)) {
        Add-LogLine "No package.json was found in: $path"
        Set-AppStatus "Source not set up" "Error"
        return $false
    }
    return $true
}

function Update-PathHint {
    $client = $script:CurrentClient
    $PathHint.Text = if (Test-SourceCheckout (Get-ProjectPath) $client) { "Found an existing $client checkout here. It will be updated, keeping your changes." }
        else { "$client will be downloaded here if the folder doesn't contain a checkout yet." }
}

function Switch-Client {
    param([string] $Client)
    if ($script:IsBusy -or $Client -eq $script:CurrentClient) { return }

    if ($script:CurrentClient -eq "Vencord") {
        $script:Settings.VencordPath = $ProjectPathBox.Text.Trim()
    }
    else {
        $script:Settings.EquicordPath = $ProjectPathBox.Text.Trim()
    }

    $script:CurrentClient = $Client
    $VencordRadio.IsChecked = $Client -eq "Vencord"
    $EquicordRadio.IsChecked = $Client -eq "Equicord"
    $ProjectPathBox.Text = if ($Client -eq "Vencord") { $script:Settings.VencordPath } else { $script:Settings.EquicordPath }
    Update-PathHint
    Save-Settings
    Reset-SourceTracking
    $script:BuildInvalidated = $false
    $script:GitInfo = $null
    $script:LastFailure = $null
    # Each client has its own checkout, so the assistant restarts at that client's first unfinished step.
    $script:AssistantStep = 1
    $script:AdvanceAssistant = $true
    # Node LTS rules differ between clients, so re-check tools in the background.
    Request-PrerequisiteRefresh
    Update-WorkflowState
    Set-AppStatus "$Client selected" "Ready"
}

function Start-PrepareProject {
    if ($script:IsBusy) { return }
    if (-not (Test-RequiredTools)) { return }
    $path = Get-ProjectPath
    if (-not $path) {
        Add-LogLine "Choose a source folder first."
        return
    }

    if (-not (Test-NotElevated)) { return }
    if (-not (Test-SafeProjectPath $path)) { return }
    Use-LocalNodeRuntime
    $tools = Get-ToolPaths
    $safeUpdateHelper = Join-Path $PSScriptRoot "UpdateSourceSafely.ps1"

    $parent = Split-Path -Parent $path
    if (-not $parent) {
        Add-LogLine "Choose a normal source path, such as Documents\$script:CurrentClient."
        return
    }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $commands = [System.Collections.Generic.List[object]]::new()
    $projectExists = Test-Path -LiteralPath (Join-Path $path "package.json") -PathType Leaf
    if (-not $projectExists) {
        if ((Test-Path -LiteralPath $path) -and (Get-ChildItem -LiteralPath $path -Force | Select-Object -First 1)) {
            Add-LogLine "The selected source folder is not empty and is not a valid checkout: $path"
            Set-AppStatus "Folder is not empty" "Error"
            return
        }
        $commands.Add((New-Command "Clone $script:CurrentClient" $tools.Git @("clone", (Get-RepoUrl), $path) $parent))
    }
    elseif (Test-Path -LiteralPath (Join-Path $path ".git") -PathType Container) {
        if (-not (Test-Path -LiteralPath $safeUpdateHelper -PathType Leaf)) {
            Add-LogLine "Safe source update helper is missing: $safeUpdateHelper"
            Set-AppStatus "Update helper missing" "Error"
            return
        }
        $commands.Add((New-Command "Back up changes and update source" "powershell.exe" @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $safeUpdateHelper,
            "-ProjectPath", $path,
            "-GitPath", $tools.Git
        ) $PSScriptRoot))
    }

    $commands.Add((New-Command "Install dependencies" $tools.Pnpm (Get-InstallArguments) $path))
    $script:PrepareKind = if ($projectExists) { "Updated" } else { "Downloaded" }
    Invalidate-Dependencies
    Update-WorkflowState

    $onSuccess = {
        Assert-PreparedProject
        Ensure-UserPluginsFolder
        Reset-SourceTracking
        Set-DependenciesReady
        Invalidate-Build
        Save-Settings
        # Re-read branch and commit; the update just fetched, so no new fetch is needed.
        $script:GitInfoPath = $null
        $script:NextGitFetch = [DateTime]::UtcNow.AddMinutes(30)
        # A source update can add or rename built-in plugins, so re-read their names for clash warnings.
        $script:BuiltInPluginNames = $null
        $script:PluginItemsKey = $null
        Update-WorkflowState
        Add-LogLine "Dependencies are ready. You may add plugins or continue to Build."
        $commit = Get-ToolProbe (Get-ToolPaths).Git @("-C", (Get-ProjectPath), "rev-parse", "--short", "HEAD") '^[0-9a-f]{7,40}$'
        Add-HistoryEntry "$(Get-ScriptState 'PrepareKind' 'Prepared') $script:CurrentClient source$(if ($commit) { " to $commit" })"
    }
    Start-CommandSequence $commands.ToArray() $onSuccess
}

function Start-ProjectBuild {
    if ($script:IsBusy -or $script:ToolSetupActive) { return }
    if (-not (Test-NotElevated)) { return }
    if (-not (Test-SafeProjectPath (Get-ProjectPath))) { return }
    if (-not (Test-RequiredTools)) { return }
    if (-not (Test-ProjectRoot)) { return }
    if (-not (Test-DependenciesReady)) {
        Add-LogLine "Install dependencies before building."
        Update-WorkflowState
        return
    }
    if (Test-BuildReady) {
        Add-LogLine "The build is up to date. Edit source or plugin files to build again."
        return
    }
    $invalidNames = @(Get-InvalidPluginNames)
    if ($invalidNames.Count -gt 0) {
        Add-LogLine "Invalid plugin layout: $($invalidNames -join ', '). See the Plugins page. Equicord needs a camelCase folder with index.ts or index.tsx; Vencord also accepts standalone .ts/.tsx files."
        Set-AppStatus "Invalid plugin layout" "Error"
        Update-WorkflowState
        return
    }
    Ensure-UserPluginsFolder
    Invalidate-Build
    Update-WorkflowState
    $tools = Get-ToolPaths
    $onSuccess = {
        Assert-BuildOutput
        Set-BuildReady
        $script:BuildInvalidated = $false
        $started = Get-ScriptState "SequenceStartedAt"
        if ($started) { $script:LastBuildDuration = [DateTime]::UtcNow - $started }
        $buildMode = if ([bool]$DevModeCheck.IsChecked) { "development" } else { "production" }
        $buildTime = if ($started) { " · " + (Format-Elapsed $script:LastBuildDuration) } else { "" }
        Add-HistoryEntry "Built $script:CurrentClient · $buildMode$buildTime"
        Update-WorkflowState
        if ((Get-ScriptState "RunAllStage") -eq "inject" -and -not (Find-DiscordInjectionEvidence)) {
            Add-LogLine "Build and source contents verified. Injection runs next and restarts Discord."
        }
        else {
            Add-LogLine "Build and source contents verified. Restarting the selected Discord channel automatically."
            Queue-VerifiedDiscordRestart
        }
    }
    Start-CommandSequence @(
        (New-SourceCheckCommand "Capture" "Capture source before building"),
        (New-Command "Build $script:CurrentClient" $tools.Pnpm (Get-BuildArguments) (Get-ProjectPath)),
        (New-SourceCheckCommand "Verify" "Verify build matches source files")
    ) $onSuccess
}

function Start-RunAll {
    if ($script:IsBusy -or $script:ToolSetupActive) { return }
    $script:RunAllStage = "prepare"
    Add-LogLine "Running all steps: update the source, build, then install into Discord."
    Continue-RunAll
}

function Continue-RunAll {
    $stage = Get-ScriptState "RunAllStage"
    if (-not $stage -or $script:IsBusy) { return }
    switch ($stage) {
        "prepare" {
            $script:RunAllStage = "build"
            Start-PrepareProject
        }
        "build" {
            $script:RunAllStage = "inject"
            if (Test-BuildReady) { Continue-RunAll; return }
            Start-ProjectBuild
        }
        "inject" {
            $script:RunAllStage = "done"
            if (Test-InjectionReady) { Continue-RunAll; return }
            Start-Injection
        }
        default {
            $script:RunAllStage = $null
            Add-LogLine "All steps finished."
            Set-AppStatus "All steps complete" "Success"
            Update-WorkflowState
            return
        }
    }
    # A step that refused to start (for example invalid plugins) ends the run.
    if (-not $script:IsBusy) {
        $script:RunAllStage = $null
        Update-WorkflowState
    }
}

function Stop-CurrentTask {
    $script:ToolSetupActive = $false
    $script:RunAllStage = $null
    if ($null -ne $script:Cancellation) {
        Add-LogLine "Stopping the current task..."
        $script:PendingCommands.Clear()
        $script:Cancellation.Cancel()
    }
    Update-WorkflowState
}

function Select-SourceFolder {
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = "Choose an existing $script:CurrentClient folder, or where to download it"
    $dialog.ShowNewFolderButton = $true
    $current = Get-ProjectPath
    if ($current -and (Test-Path -LiteralPath $current -PathType Container)) { $dialog.SelectedPath = $current }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ProjectPathBox.Text = $dialog.SelectedPath
        $script:BuildInvalidated = $false
        Update-PathHint
        Save-Settings
        Reset-SourceTracking
        Update-WorkflowState
    }
    $dialog.Dispose()
}

function Open-Folder {
    param([string] $Path)
    try {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Start-Process -FilePath $Path
    }
    catch { Add-LogLine "Could not open $Path : $($_.Exception.Message)" }
}

function Update-WindowCorners {
    # Windows 10 can't round corners itself, so clip the window; maximized windows keep square edges.
    if (-not (Get-ScriptState "RegionCorners" $false)) { return }
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
        [BuilderWindowShell]::ClipCorners($handle, 0, 0, 0)
        return
    }
    $source = [System.Windows.PresentationSource]::FromVisual($window)
    if ($null -eq $source) { return }
    $scale = $source.CompositionTarget.TransformToDevice
    [BuilderWindowShell]::ClipCorners($handle,
        [int][Math]::Round($window.ActualWidth * $scale.M11),
        [int][Math]::Round($window.ActualHeight * $scale.M22),
        [int][Math]::Round(16 * $scale.M11))
}

function Update-ElapsedDisplay {
    if (-not $script:IsBusy -or $null -eq $script:CommandStartedAt) { return }
    $now = [DateTime]::UtcNow
    $stepText = Format-Elapsed ($now - $script:CommandStartedAt)
    $label = if ($null -ne $script:CurrentCommand) { $script:CurrentCommand.Label } else { "Working" }
    $text = "$label · $stepText"
    if ($null -ne $script:SequenceStartedAt -and ($now - $script:SequenceStartedAt).TotalSeconds -ge 1 -and
        ($script:SequenceStartedAt -lt $script:CommandStartedAt.AddSeconds(-1))) {
        $text += "  ·  $(Format-Elapsed ($now - $script:SequenceStartedAt)) total"
    }
    if ($HeroElapsedText.Text -ne $text) {
        $HeroElapsedText.Text = $text
        $AssistantElapsedText.Text = $text
        $ActivityElapsedText.Text = $stepText
    }
}

# ---------------------------------------------------------------- start-up

Refresh-ToolSearchPath
$script:SettingsPath = Get-UserSettingsPath
$script:HistoryPath = Join-Path (Split-Path -Parent $script:SettingsPath) "history.json"
$AppVersionText.Text = "Cord Builder $script:AppVersion"
$script:Settings = Load-Settings
$script:CurrentClient = $script:Settings.LastClient
$VencordRadio.IsChecked = $script:CurrentClient -eq "Vencord"
$EquicordRadio.IsChecked = $script:CurrentClient -eq "Equicord"
$ProjectPathBox.Text = if ($script:CurrentClient -eq "Vencord") { $script:Settings.VencordPath } else { $script:Settings.EquicordPath }
$DevModeCheck.IsChecked = $script:Settings.DevMode
Update-PathHint
Initialize-DiscordChannels

$VencordRadio.Add_Checked({ Switch-Client "Vencord" })
$EquicordRadio.Add_Checked({ Switch-Client "Equicord" })
$DiscordChannelCombo.Add_SelectionChanged({
    Update-DiscordChannelHint
    Save-Settings
    Clear-ReadinessCache
    Update-WorkflowState
})

$CloseButton.Add_Click({ $window.Close() })
$MinimizeButton.Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
$ZoomButton.Add_Click({
    $window.WindowState = if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) { "Normal" } else { "Maximized" }
})
$window.Add_StateChanged({
    $maximized = $window.WindowState -eq [System.Windows.WindowState]::Maximized
    # A maximized custom-chrome window extends past the screen edge by its resize border.
    $RootGrid.Margin = if ($maximized) { [System.Windows.Thickness]::new(7) } else { [System.Windows.Thickness]::new(0) }
    $ZoomGlyph.Text = if ($maximized) { [string][char]0xE923 } else { [string][char]0xE922 }
    $ZoomButton.ToolTip = if ($maximized) { "Restore down" } else { "Maximize" }
    Update-WindowCorners
})
$window.Add_SizeChanged({ Update-WindowCorners })
$window.Add_SourceInitialized({
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    [BuilderWindowShell]::UseDarkFrame($handle)
    $script:RegionCorners = -not [BuilderWindowShell]::UseRoundedCorners($handle)
})

$NavHome.Add_Checked({ if ($script:CurrentPage -notin @("Home", "Assistant")) { Show-Page "Home" } })
$NavPlugins.Add_Checked({ if ($script:CurrentPage -ne "Plugins") { Show-Page "Plugins" } })
$NavActivity.Add_Checked({ if ($script:CurrentPage -ne "Activity") { Show-Page "Activity" } })
$NavSettings.Add_Checked({ if ($script:CurrentPage -ne "Settings") { Show-Page "Settings" } })
$ActivityBarButton.Add_Click({
    if ($script:CurrentPage -eq "Activity") { Show-Page $script:PreviousPage } else { Show-Page "Activity" }
})
$ShowActivityButton.Add_Click({ Show-Page "Activity" })
$PluginsTile.Add_Click({ Show-Page "Plugins" })
$DiscordTile.Add_Click({ Show-Page "Settings" })
$BuildTile.Add_Click({ Show-Page "Activity" })

$BrowseButton.Add_Click({ Select-SourceFolder })
$ProjectPathBox.Add_LostFocus({
    $script:BuildInvalidated = $false
    Update-PathHint
    Save-Settings
    if ($script:SourcePath -ne (Get-ProjectPath)) { Reset-SourceTracking }
    Update-WorkflowState
})
$DevModeCheck.Add_Checked({
    Invalidate-Build
    Save-Settings
    Update-WorkflowState
})
$DevModeCheck.Add_Unchecked({
    Invalidate-Build
    Save-Settings
    Update-WorkflowState
})
$RescanDiscordButton.Add_Click({ Rescan-Discord })

$InstallPrerequisitesButton.Add_Click({ Start-RequiredToolsInstallation })
$checkTools = {
    if ($script:IsBusy) { return }
    Refresh-ToolSearchPath
    if (Test-RequiredTools) {
        Set-AppStatus "Required tools ready" "Success"
        Add-LogLine "Git, Node.js and pnpm are installed and verified."
    }
}
$CheckPrerequisitesButton.Add_Click($checkTools)
$AssistantCheckButton.Add_Click($checkTools)
$PrepareButton.Add_Click({ Start-PrepareProject })
$UpdateSourceButton.Add_Click({ Start-PrepareProject })
$BuildButton.Add_Click({ Start-ProjectBuild })
$InjectButton.Add_Click({ Start-Injection })
$ReinjectButton.Add_Click({ Start-Injection })
$RestoreDiscordButton.Add_Click({ Start-RestoreDiscord })
$RunAllButton.Add_Click({ Start-RunAll })
$HeroPrimaryButton.Add_Click({ if ($null -ne $script:HeroAction) { & $script:HeroAction } })
$StopButton.Add_Click({ Stop-CurrentTask })
$AssistantStopButton.Add_Click({ Stop-CurrentTask })
$OpenPluginsButton.Add_Click({ Open-UserPlugins })
# Row buttons in both plugin lists carry a Tag naming their action.
$PluginsPage.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $eventArgs)
    $source = $eventArgs.OriginalSource
    if ($source -isnot [System.Windows.FrameworkElement] -or $source.Tag -notin @("open", "reveal", "toggle")) { return }
    $item = $source.DataContext
    switch ($source.Tag) {
        "open" { Open-PluginItem $item }
        "reveal" { Open-PluginItem $item -Reveal }
        "toggle" {
            [void](Set-PluginEnabled $item ([bool]$source.IsChecked))
            # Rebinding also puts the switch back if the rename was refused.
            Request-PluginsRefresh
        }
    }
})
$PluginSearchBox.Add_TextChanged({
    $script:PluginFilter = $PluginSearchBox.Text.Trim()
    $PluginSearchHint.Visibility = if ($PluginSearchBox.Text) { "Collapsed" } else { "Visible" }
    Show-PluginList
})
$AssistantPluginsButton.Add_Click({ Open-UserPlugins })

$BackButton.Add_Click({
    if ($script:AssistantStep -gt 1) { $script:AssistantStep-- }
    Update-WorkflowState
})
$ContinueButton.Add_Click({
    if ($script:AssistantStep -lt 4) {
        $script:AssistantStep++
        Update-WorkflowState
        return
    }
    $script:Settings.SetupCompleted = $true
    Save-Settings
    Show-Page "Home"
})
$OpenAssistantButton.Add_Click({
    $script:Settings.SetupCompleted = $false
    Save-Settings
    $script:AssistantStep = 1
    Show-Page "Assistant"
})

$UpdateButton.Add_Click({
    $update = $script:AvailableUpdate
    if ($null -ne $update) { Start-Process -FilePath $update.Url }
})

$NextIssueButton.Add_Click({ Find-NextLogIssue })
$CopyLogButton.Add_Click({
    try {
        if ($LogBox.Text) { [System.Windows.Clipboard]::SetText($LogBox.Text); Set-AppStatus "Copied output" "Success" }
    }
    catch { Set-AppStatus "Clipboard is busy; try again" "Error" }
})
$ClearLogButton.Add_Click({
    $LogBox.Clear()
    $script:LogLineCount = 0
    Update-LogControls
})
$OpenLogFileButton.Add_Click({ if ($script:LogFilePath) { Start-Process -FilePath $script:LogFilePath } })
$OpenLogsFolderButton.Add_Click({ Open-Folder (Get-LogsFolder) })
$OpenBackupsFolderButton.Add_Click({
    Open-Folder (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "CordBuilder\backups\Discord")
})

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({
    Update-SourceTracking
    Flush-OutputQueue
    Update-PrerequisiteRefresh
    Update-GitInfo
    Update-UpdateCheck
    Update-ElapsedDisplay
    $ActivityBusyPanel.Visibility = if ($script:IsBusy -or $script:ToolSetupActive) { "Visible" } else { "Collapsed" }

    if ($script:IsBusy -and $null -ne $script:CurrentTask -and $script:CurrentTask.IsCompleted) {
        Flush-OutputQueue
        $exitCode = $script:CurrentTask.Result
        if ($exitCode -eq 0) {
            Add-LogLine "Completed: $($script:CurrentCommand.Label)" -NoTimestamp
            $script:CurrentTask = $null
            Invoke-NextCommand
        }
        elseif ($exitCode -eq -999) {
            Complete-Sequence $false "Task stopped."
        }
        else {
            Complete-Sequence $false "$($script:CurrentCommand.Label) failed with exit code $exitCode."
        }
    }
})

$window.Add_Loaded({
    Open-LogFile
    $script:ViewReady = $true
    Update-RecentList
    Update-LogControls
    Reset-SourceTracking
    Request-PrerequisiteRefresh
    if (-not $script:Settings.SetupCompleted -and (Test-DependenciesReady) -and (Read-VerifiedBuildSnapshot (Get-ProjectPath))) {
        # Someone upgrading from the older layout has already been through setup once.
        $script:Settings.SetupCompleted = $true
    }
    $script:AssistantStep = 1
    $script:AdvanceAssistant = $true
    Show-Page "Home"
    Add-LogLine "Cord Builder is ready."
    Add-LogLine "Tip: don't run this app as Administrator; Equicord warns this can break Discord injection on Windows."
    $timer.Start()
})

$window.Add_Closing({
    $script:ToolSetupActive = $false
    Save-Settings
    $timer.Stop()
    Reset-SourceTracking
    Stop-GitInfo
    if ($null -ne $script:Cancellation) { $script:Cancellation.Cancel() }
    if ($null -ne $script:LogWriter) { try { $script:LogWriter.Dispose() } catch { } }
})

if ($StartupSelfTest) {
    $script:ViewReady = $true
    Update-PrerequisiteStatus
    Reset-SourceTracking
    $script:AssistantStep = 1
    Show-Page "Home"
    foreach ($page in @("Plugins", "Activity", "Settings", "Home")) { Show-Page $page }
    Update-RecentList
    Update-LogControls
    # The update notice only offers published GitHub releases that are strictly newer.
    $release = [pscustomobject]@{ tag_name = "v1.2.0"; html_url = "https://github.com/owner/cord-builder/releases/tag/v1.2.0"; draft = $false; prerelease = $false }
    if ((Get-NewerRelease $release "1.0.0").Version -ne "1.2.0") { throw "A newer release was not offered." }
    if ($null -ne (Get-NewerRelease $release "1.2.0")) { throw "The running version was offered as an update." }
    $release.prerelease = $true
    if ($null -ne (Get-NewerRelease $release "1.0.0")) { throw "A pre-release was offered as an update." }
    $release.prerelease = $false
    $release.html_url = "https://example.com/cord-builder"
    if ($null -ne (Get-NewerRelease $release "1.0.0")) { throw "A non-GitHub page was offered as an update." }
    if ($null -ne $window.FindName("AutoRestartCheck") -or $null -ne $window.FindName("PluginStepPanel") -or $null -ne $window.FindName("HeaderVencordRadio")) {
        throw "Removed controls are still present."
    }
    if ($PreviewPath) {
        foreach ($previewPage in @("Assistant", "Home", "Plugins", "Activity", "Settings")) {
            if ($previewPage -eq "Home") { $script:Settings.SetupCompleted = $true }
            Show-Page $previewPage
            $previewRoot = $window.Content
            $previewRoot.Measure([System.Windows.Size]::new($window.Width, $window.Height))
            $previewRoot.Arrange([System.Windows.Rect]::new(0, 0, $window.Width, $window.Height))
            $previewRoot.UpdateLayout()
            $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.Width, [int]$window.Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($previewRoot)
            $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
            $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $target = [IO.Path]::ChangeExtension($PreviewPath, $null).TrimEnd('.') + "-" + $previewPage.ToLowerInvariant() + ".png"
            $stream = [IO.File]::Create($target)
            try { $encoder.Save($stream) } finally { $stream.Dispose() }
        }
    }
    Write-Output "PASS: startup, every page and the setup assistant loaded; removed controls are absent."
    exit 0
}
[void]$window.ShowDialog()
