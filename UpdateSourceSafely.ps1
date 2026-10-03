[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ProjectPath,
    [Parameter(Mandatory = $true)][string] $GitPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$resolvedProject = [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\', '/')
$resolvedGit = [IO.Path]::GetFullPath($GitPath)
if (-not (Test-Path -LiteralPath $resolvedProject -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $resolvedProject ".git") -PathType Container)) {
    throw "The selected source folder is not a Git checkout: $resolvedProject"
}
if (-not (Test-Path -LiteralPath $resolvedGit -PathType Leaf)) {
    throw "The verified Git executable is missing: $resolvedGit"
}

function Invoke-Git {
    param([string[]] $Arguments, [switch] $Capture, [switch] $AllowFailure)
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Capture) {
            $result = @(& $resolvedGit -C $resolvedProject @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0 -and -not $AllowFailure) {
                throw "Git command failed: git $($Arguments -join ' ') $([Environment]::NewLine)$($result -join [Environment]::NewLine)"
            }
            return [pscustomobject]@{ ExitCode = $exitCode; Text = ($result -join [Environment]::NewLine).Trim() }
        }

        & $resolvedGit -C $resolvedProject @Arguments
        if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
            throw "Git command failed: git $($Arguments -join ' ')"
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
}

# pnpm rewrites the lockfile during installs (Equicord installs without --frozen-lockfile).
# That generated change would otherwise be stashed and then conflict with upstream's new lockfile.
$lockfileDiff = Invoke-Git -Arguments @("diff", "--quiet", "--", "pnpm-lock.yaml") -Capture -AllowFailure
if ($lockfileDiff.ExitCode -eq 1) {
    Invoke-Git -Arguments @("checkout", "--", "pnpm-lock.yaml")
    Write-Output "Reset pnpm-lock.yaml to the committed version; installing dependencies regenerates it."
}

$status = (Invoke-Git -Arguments @("status", "--porcelain=v1", "--untracked-files=all") -Capture).Text
$stashOid = $null
if (-not [string]::IsNullOrWhiteSpace($status)) {
    $beforeStash = Invoke-Git -Arguments @("rev-parse", "--verify", "-q", "refs/stash") -Capture -AllowFailure
    $stashMessage = "Cord Builder safety backup " + [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Output "Local source changes found. Creating a recoverable safety stash..."
    Invoke-Git -Arguments @("stash", "push", "--include-untracked", "--message", $stashMessage)
    $afterStash = Invoke-Git -Arguments @("rev-parse", "--verify", "refs/stash") -Capture
    $stashOid = $afterStash.Text
    if ([string]::IsNullOrWhiteSpace($stashOid) -or
        ($beforeStash.ExitCode -eq 0 -and $stashOid -eq $beforeStash.Text)) {
        throw "Git did not create a new safety stash. The source update was not started."
    }
    $remaining = (Invoke-Git -Arguments @("status", "--porcelain=v1", "--untracked-files=all") -Capture).Text
    if (-not [string]::IsNullOrWhiteSpace($remaining)) {
        throw "The working tree was not clean after the safety stash. The source update was not started. Safety stash: $stashOid"
    }
    Write-Output "Verified safety stash: $stashOid"
}

$updateError = $null
try {
    Invoke-Git -Arguments @("fetch")
    Invoke-Git -Arguments @("pull", "--ff-only")
}
catch {
    $updateError = $_
}

if ($stashOid) {
    $applyError = $null
    try { Invoke-Git -Arguments @("stash", "apply", $stashOid) }
    catch { $applyError = $_ }

    $conflicts = (Invoke-Git -Arguments @("diff", "--name-only", "--diff-filter=U") -Capture -AllowFailure).Text
    if ($applyError -or -not [string]::IsNullOrWhiteSpace($conflicts)) {
        $detail = if ($conflicts) { " Conflicted files: $($conflicts -replace [Environment]::NewLine, ', ')." } else { "" }
        throw "Source changes need manual conflict resolution.$detail Cord Builder did not choose either side. The safety stash remains at $stashOid."
    }
    Write-Output "Verified local source changes were restored with no unmerged files."
    Write-Output "Recovery stash retained: $stashOid"
}

if ($updateError) {
    if ($stashOid) {
        throw "The source update failed, but local changes were restored and the recovery stash was retained. $($updateError.Exception.Message)"
    }
    throw "The source update failed. No local changes needed backup. $($updateError.Exception.Message)"
}

$head = (Invoke-Git -Arguments @("rev-parse", "--verify", "HEAD") -Capture).Text
if ([string]::IsNullOrWhiteSpace($head)) { throw "Git could not verify the updated source commit." }
Write-Output "Verified source commit: $head"

# Every update with local changes leaves a recovery stash. Keep the newest ones and drop older
# Cord Builder backups so they don't pile up forever. Stashes made by the user are never touched.
$keepBackups = 10
$stashList = (Invoke-Git -Arguments @("stash", "list", "--format=%gd%x09%s") -Capture -AllowFailure).Text
$backups = @($stashList -split "\r?\n" | Where-Object { $_ -match "^stash@\{\d+\}\t.*Cord Builder safety backup " })
if ($backups.Count -gt $keepBackups) {
    $old = @($backups[$keepBackups..($backups.Count - 1)] | ForEach-Object { ($_ -split "`t")[0] })
    # Drop from the highest index down so the remaining stash numbers stay valid.
    [array]::Reverse($old)
    foreach ($reference in $old) { Invoke-Git -Arguments @("stash", "drop", "--quiet", $reference) }
    Write-Output "Removed $($old.Count) older Cord Builder safety backups; kept the newest $keepBackups."
}
