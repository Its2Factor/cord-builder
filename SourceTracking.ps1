[CmdletBinding()]
param(
    [ValidateSet("Library", "Capture", "Verify", "Check")]
    [string] $Action = "Library",
    [string] $ProjectPath,
    [ValidateSet("Vencord", "Equicord")]
    [string] $Client = "Vencord",
    [ValidateSet("true", "false")]
    [string] $DevelopmentMode = "false"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if (-not ("CordSourceSnapshot" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class CordSourceSnapshot
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint size, uint flags);

    private static string PhysicalDirectory(string path)
    {
        // Resolve folder links for cycle detection; cloud/OneDrive folders remain supported.
        // https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew
        using (var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))
        {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot inspect source folder: " + path);
            var result = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, result, (uint)result.Capacity, 0);
            if (length == 0 || length >= result.Capacity)
                throw new IOException("Cannot resolve source folder: " + path);
            return result.ToString().TrimEnd('\\');
        }
    }

    // Generated output and tool stores are not source inputs.
    private static readonly HashSet<string> IgnoredDirectories =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            ".git", "node_modules", "dist", ".cache", ".pnpm-store", "coverage"
        };

    public static Task<string> ComputeAsync(string root, CancellationToken token)
    {
        return Task.Run(() => Compute(root, token), token);
    }

    public static string Compute(string root, CancellationToken token)
    {
        root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!Directory.Exists(root)) throw new DirectoryNotFoundException("The selected source folder does not exist.");
        var paths = new List<string>();
        Collect(root, paths, token, new HashSet<string>(StringComparer.OrdinalIgnoreCase), true);
        paths.Sort(StringComparer.Ordinal);
        using (var aggregate = SHA256.Create())
        {
            foreach (var path in paths)
            {
                token.ThrowIfCancellationRequested();
                byte[] name = Encoding.UTF8.GetBytes(path.Substring(root.Length).Replace('\\', '/'));
                aggregate.TransformBlock(name, 0, name.Length, null, 0);
                byte[] separator = new byte[] { 0 };
                aggregate.TransformBlock(separator, 0, 1, null, 0);
                using (var contentHash = SHA256.Create())
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    byte[] buffer = new byte[65536];
                    int count;
                    while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        token.ThrowIfCancellationRequested();
                        contentHash.TransformBlock(buffer, 0, count, null, 0);
                    }
                    contentHash.TransformFinalBlock(new byte[0], 0, 0);
                    aggregate.TransformBlock(contentHash.Hash, 0, contentHash.Hash.Length, null, 0);
                }
            }
            aggregate.TransformFinalBlock(new byte[0], 0, 0);
            return BitConverter.ToString(aggregate.Hash).Replace("-", "").ToLowerInvariant();
        }
    }

    private static void Collect(string folder, List<string> paths, CancellationToken token, HashSet<string> ancestors, bool isRoot)
    {
        token.ThrowIfCancellationRequested();
        string physical = PhysicalDirectory(folder);
        if (!ancestors.Add(physical)) throw new IOException("A source folder link forms a loop: " + folder);
        try
        {
        foreach (string path in Directory.GetFileSystemEntries(folder))
        {
            token.ThrowIfCancellationRequested();
            var attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.Directory) != 0)
            {
                string name = Path.GetFileName(path);
                if (IgnoredDirectories.Contains(name) &&
                    (!name.Equals("dist", StringComparison.OrdinalIgnoreCase) || isRoot)) continue;
                Collect(path, paths, token, ancestors, false);
            }
            else { paths.Add(path); }
        }
        }
        finally { ancestors.Remove(physical); }
    }
}
'@
}

function Read-VerifiedBuildSnapshot {
    param([string] $Path)
    try {
        $snapshot = Get-Content -LiteralPath (Join-Path $Path "dist\.cord-builder-ready") -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($snapshot.Version -ne 1 -or $snapshot.InputHash -notmatch '^[a-f0-9]{64}$' -or
            $snapshot.Client -notin @("Vencord", "Equicord") -or $snapshot.DevelopmentMode -isnot [bool] -or
            -not ([IO.Path]::GetFullPath($snapshot.ProjectPath)).TrimEnd('\').Equals([IO.Path]::GetFullPath($Path).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        return $snapshot
    }
    catch { return $null }
}

function Assert-TrackedBuildOutput {
    param([string] $Path, [DateTime] $WrittenSince = [DateTime]::MinValue)
    $dist = Join-Path $Path "dist"
    $output = Get-ChildItem -LiteralPath $dist -File -Recurse -ErrorAction Stop |
        Where-Object { $_.Extension -in @(".js", ".cjs", ".mjs") -and $_.Length -gt 0 -and $_.LastWriteTimeUtc -ge $WrittenSince } | Select-Object -First 1
    if ($null -eq $output) { throw "No non-empty JavaScript output written by this build was found." }
}

function Invoke-SourceSnapshotAction {
    param([string] $Operation, [string] $Path, [string] $SelectedClient, [bool] $DevMode)
    $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $Path "package.json") -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $Path "src") -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $Path "node_modules") -PathType Container)) {
        throw "Prepare the selected source project before capturing a build."
    }
    $marker = Join-Path $Path "dist\.cord-builder-ready"
    $capture = Join-Path $Path "node_modules\.cord-builder-inputs.json"
    if ($Operation -eq "Capture") {
        # A failed or cancelled build cannot leave an old success marker behind.
        if (Test-Path -LiteralPath $marker -PathType Leaf) { Remove-Item -LiteralPath $marker -Force }
        $hash = [CordSourceSnapshot]::Compute($Path, [Threading.CancellationToken]::None)
        [pscustomobject]@{
            Version = 1; ProjectPath = $Path; Client = $SelectedClient
            DevelopmentMode = $DevMode; InputHash = $hash; CapturedAt = [DateTime]::UtcNow.ToString("o")
        } | ConvertTo-Json | Set-Content -LiteralPath $capture -Encoding UTF8
        Write-Output "Captured source file contents, including custom plugins."
        return
    }
    if ($Operation -eq "Verify") {
        $snapshot = Get-Content -LiteralPath $capture -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    else { $snapshot = Read-VerifiedBuildSnapshot $Path }
    if ($null -eq $snapshot -or $snapshot.Version -ne 1 -or
        $snapshot.ProjectPath -ne $Path -or $snapshot.Client -ne $SelectedClient -or
        $snapshot.DevelopmentMode -ne $DevMode) { throw "A matching source snapshot is missing. Build again." }
    $hash = [CordSourceSnapshot]::Compute($Path, [Threading.CancellationToken]::None)
    if ($snapshot.InputHash -ne $hash) {
        throw "Source files changed during or after the build. Build again; Discord was not restarted."
    }
    if ($Operation -eq "Verify") {
        Assert-TrackedBuildOutput $Path ([DateTime]::Parse($snapshot.CapturedAt).ToUniversalTime())
        $snapshot | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
        Write-Output "Verified build output and unchanged source contents; saved the successful build snapshot."
    }
    else {
        Assert-TrackedBuildOutput $Path
        Write-Output "Verified the current files still match the successful build."
    }
}

if ($Action -ne "Library") {
    Invoke-SourceSnapshotAction $Action $ProjectPath $Client ($DevelopmentMode -eq "true")
}
