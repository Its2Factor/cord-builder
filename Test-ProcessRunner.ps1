param([string] $AppPath = (Join-Path $PSScriptRoot "VencordEquicordBuilder.ps1"))

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($AppPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join "; ") }
$runner = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$runnerSource'
}, $true)
Add-Type -TypeDefinition $runner.Right.Expression.Value
$queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$cancel = [System.Threading.CancellationTokenSource]::new()
$powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$childCommand = '$child = Start-Process -FilePath (Join-Path $PSHOME "powershell.exe") -ArgumentList "-NoProfile -Command Start-Sleep -Seconds 30" -WindowStyle Hidden -PassThru; Write-Output ("test-child:" + $child.Id); Wait-Process -Id $child.Id'
$childProcess = $null
try {
    $task = [BuilderProcessRunner]::RunAsync($powershell, @("-NoProfile", "-Command", $childCommand), $PSScriptRoot, $queue, $cancel.Token)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline -and -not $task.IsCompleted -and $null -eq $childProcess) {
        $line = $null
        while ($queue.TryDequeue([ref]$line)) {
            if ($line -match '^test-child:(\d+)$') {
                $childProcess = [Diagnostics.Process]::GetProcessById([int]$matches[1])
                break
            }
        }
        Start-Sleep -Milliseconds 50
    }
    if ($null -eq $childProcess) { throw "The test worker did not start its child process." }
    $cancel.Cancel()
    if (-not $task.Wait(10000)) { throw "Cancelling the task did not finish promptly." }
    if ($task.Result -ne -999) { throw "A cancelled task was not marked cancelled." }
    $line = $null
    while ($queue.TryDequeue([ref]$line)) { Write-Output $line }
    if (-not $childProcess.WaitForExit(3000)) { throw "The task's child process remained running after Stop." }
    Write-Output "PASS: Stop cancels the task and its child process without touching unrelated processes."
}
finally {
    $cancel.Cancel()
    if ($null -ne $childProcess) {
        # This Process object belongs only to the child created above.
        try { if (-not $childProcess.HasExited) { $childProcess.Kill() } } catch { }
        $childProcess.Dispose()
    }
    $cancel.Dispose()
}
