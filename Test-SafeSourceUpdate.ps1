[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$helper = Join-Path $PSScriptRoot "UpdateSourceSafely.ps1"
$git = (Get-Command git.exe -ErrorAction Stop).Source
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("CordBuilder-SourceUpdateTest-" + [Guid]::NewGuid().ToString("N"))
$oldGlobalConfig = $env:GIT_CONFIG_GLOBAL
$oldXdgConfig = $env:XDG_CONFIG_HOME
$env:GIT_CONFIG_GLOBAL = "NUL"
$env:XDG_CONFIG_HOME = Join-Path $testRoot "xdg"

function Invoke-TestGit {
    param([string] $WorkingDirectory, [string[]] $Arguments)
    & $git -C $WorkingDirectory @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Test Git command failed: git $($Arguments -join ' ')" }
}

try {
    $remote = Join-Path $testRoot "remote.git"
    $seed = Join-Path $testRoot "seed"
    $checkout = Join-Path $testRoot "checkout"
    New-Item -ItemType Directory -Path $testRoot,$seed -Force | Out-Null
    & $git init --bare $remote | Out-Null
    Invoke-TestGit $seed @("init")
    Invoke-TestGit $seed @("config", "user.name", "Cord Builder Test")
    Invoke-TestGit $seed @("config", "user.email", "cord-builder@example.invalid")
    Set-Content -LiteralPath (Join-Path $seed "tracked.txt") -Value "base" -Encoding UTF8
    Invoke-TestGit $seed @("add", "tracked.txt")
    Invoke-TestGit $seed @("commit", "-m", "initial")
    Invoke-TestGit $seed @("branch", "-M", "main")
    Invoke-TestGit $seed @("remote", "add", "origin", $remote)
    Invoke-TestGit $seed @("push", "-u", "origin", "main")
    & $git --git-dir=$remote symbolic-ref HEAD refs/heads/main
    if ($LASTEXITCODE -ne 0) { throw "Could not set the test remote's default branch." }
    & $git clone $remote $checkout | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create the test checkout." }

    Set-Content -LiteralPath (Join-Path $checkout "tracked.txt") -Value "local custom change" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $checkout "custom-plugin.ts") -Value "export default {};" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $seed "upstream.txt") -Value "remote update" -Encoding UTF8
    Invoke-TestGit $seed @("add", "upstream.txt")
    Invoke-TestGit $seed @("commit", "-m", "upstream")
    Invoke-TestGit $seed @("push")

    $output = @(& $helper -ProjectPath $checkout -GitPath $git) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw "Safe source update helper failed." }
    if ((Get-Content -LiteralPath (Join-Path $checkout "tracked.txt") -Raw).Trim() -ne "local custom change") { throw "Tracked custom changes were not restored." }
    if (-not (Test-Path -LiteralPath (Join-Path $checkout "custom-plugin.ts") -PathType Leaf)) { throw "Untracked custom file was not restored." }
    if (-not (Test-Path -LiteralPath (Join-Path $checkout "upstream.txt") -PathType Leaf)) { throw "Remote update was not applied." }
    $conflicts = @(& $git -C $checkout diff --name-only --diff-filter=U)
    if ($conflicts.Count -gt 0) { throw "Source update left unmerged files." }
    $stash = @(& $git -C $checkout stash list)
    if ($stash.Count -eq 0 -or $stash[0] -notmatch "Cord Builder safety backup") { throw "Recovery stash was not retained." }
    if ($output -notmatch "Verified local source changes were restored" -or $output -notmatch "Verified source commit") { throw "Source update did not report verification." }

    $conflictCheckout = Join-Path $testRoot "conflict-checkout"
    & $git clone $remote $conflictCheckout | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create the conflict test checkout." }
    Set-Content -LiteralPath (Join-Path $conflictCheckout "tracked.txt") -Value "local conflicting change" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $seed "tracked.txt") -Value "remote conflicting change" -Encoding UTF8
    Invoke-TestGit $seed @("add", "tracked.txt")
    Invoke-TestGit $seed @("commit", "-m", "conflict")
    Invoke-TestGit $seed @("push")
    $conflictStopped = $false
    try { & $helper -ProjectPath $conflictCheckout -GitPath $git | Out-Null }
    catch { $conflictStopped = $_.Exception.Message -match "did not choose either side" }
    if (-not $conflictStopped) { throw "Conflicting custom changes were not stopped for manual review." }
    $conflictStash = @(& $git -C $conflictCheckout stash list)
    if ($conflictStash.Count -eq 0 -or $conflictStash[0] -notmatch "Cord Builder safety backup") { throw "Conflict recovery stash was not retained." }

    # A lockfile rewritten by pnpm install is reset, not stashed, so it cannot conflict with upstream.
    Set-Content -LiteralPath (Join-Path $seed "pnpm-lock.yaml") -Value "lock v1" -Encoding UTF8
    Invoke-TestGit $seed @("add", "pnpm-lock.yaml")
    Invoke-TestGit $seed @("commit", "-m", "lockfile")
    Invoke-TestGit $seed @("push")
    $lockCheckout = Join-Path $testRoot "lock-checkout"
    & $git clone $remote $lockCheckout | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create the lockfile test checkout." }
    Set-Content -LiteralPath (Join-Path $lockCheckout "pnpm-lock.yaml") -Value "lock regenerated locally" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $seed "pnpm-lock.yaml") -Value "lock v2" -Encoding UTF8
    Invoke-TestGit $seed @("add", "pnpm-lock.yaml")
    Invoke-TestGit $seed @("commit", "-m", "lockfile update")
    Invoke-TestGit $seed @("push")
    $lockOutput = @(& $helper -ProjectPath $lockCheckout -GitPath $git) -join [Environment]::NewLine
    if ((Get-Content -LiteralPath (Join-Path $lockCheckout "pnpm-lock.yaml") -Raw).Trim() -ne "lock v2") { throw "Upstream lockfile was not applied." }
    if (@(& $git -C $lockCheckout stash list).Count -ne 0) { throw "A generated lockfile change was stashed." }
    if ($lockOutput -notmatch "Reset pnpm-lock.yaml") { throw "Lockfile reset was not reported." }

    # Only the newest Cord Builder backups are kept; the user's own stashes are never dropped.
    $pruneCheckout = Join-Path $testRoot "prune-checkout"
    & $git clone $remote $pruneCheckout | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create the pruning test checkout." }
    Invoke-TestGit $pruneCheckout @("config", "user.name", "Cord Builder Test")
    Invoke-TestGit $pruneCheckout @("config", "user.email", "cord-builder@example.invalid")
    Set-Content -LiteralPath (Join-Path $pruneCheckout "tracked.txt") -Value "user stash" -Encoding UTF8
    Invoke-TestGit $pruneCheckout @("stash", "push", "--message", "my own work")
    for ($i = 1; $i -le 12; $i++) {
        Set-Content -LiteralPath (Join-Path $pruneCheckout "tracked.txt") -Value "backup $i" -Encoding UTF8
        Invoke-TestGit $pruneCheckout @("stash", "push", "--message", "Cord Builder safety backup test $i")
    }
    & $helper -ProjectPath $pruneCheckout -GitPath $git | Out-Null
    $remaining = @(& $git -C $pruneCheckout stash list)
    $backupCount = @($remaining | Where-Object { $_ -match "Cord Builder safety backup" }).Count
    if ($backupCount -ne 10) { throw "Expected 10 retained backups, found $backupCount." }
    if (@($remaining | Where-Object { $_ -match "my own work" }).Count -ne 1) { throw "A user stash was dropped." }
    if (@($remaining | Where-Object { $_ -match "backup test 12" }).Count -ne 1) { throw "The newest backup was dropped." }

    $builder = Get-Content -LiteralPath (Join-Path $PSScriptRoot "VencordEquicordBuilder.ps1") -Raw
    if ($builder -notmatch "Back up changes and update source" -or $builder -notmatch "UpdateSourceSafely.ps1") {
        throw "Cord Builder does not use the safe source updater."
    }

    Write-Output "PASS: tracked and untracked custom changes survive source updates"
    Write-Output "PASS: remote fast-forward updates are applied"
    Write-Output "PASS: unmerged files are checked and recovery stash is retained"
    Write-Output "PASS: conflicts stop without choosing either side"
    Write-Output "PASS: generated lockfile changes are reset instead of conflicting"
    Write-Output "PASS: old safety backups are pruned and user stashes are kept"
    Write-Output "PASS: Prepare project uses the safe source updater"
}
finally {
    $env:GIT_CONFIG_GLOBAL = $oldGlobalConfig
    $env:XDG_CONFIG_HOME = $oldXdgConfig
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
