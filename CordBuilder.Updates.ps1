# App updates: compares this copy's version with the latest GitHub release and shows a notice in the title bar.
# Dot-sourced by VencordEquicordBuilder.ps1; functions use the app's script-scope controls and state.

function Get-NewerRelease {
    # Returns the release's version and page when it is newer than CurrentVersion, otherwise $null.
    param([object] $Release, [string] $CurrentVersion)
    if ($null -eq $Release -or (Get-OptionalProperty $Release "draft") -or (Get-OptionalProperty $Release "prerelease")) { return $null }
    $tag = [string](Get-OptionalProperty $Release "tag_name")
    $url = [string](Get-OptionalProperty $Release "html_url")
    $latest = $null
    $current = $null
    if (-not [version]::TryParse(($tag -replace '^[vV]', ''), [ref]$latest) -or
        -not [version]::TryParse($CurrentVersion, [ref]$current)) { return $null }
    # Only ever link to a GitHub page, whatever the response contains.
    if ($latest -le $current -or $url -notmatch '^https://github\.com/') { return $null }
    return [pscustomobject]@{ Version = $latest.ToString(); Url = $url }
}

function Stop-UpdateCheck {
    if ($null -ne $script:UpdateClient) { try { $script:UpdateClient.Dispose() } catch { } }
    $script:UpdateClient = $null
    $script:UpdateTask = $null
}

function Start-UpdateCheck {
    $repository = Get-ScriptState "UpdateRepository"
    $script:NextUpdateCheck = [DateTime]::UtcNow.AddHours(12)
    if (-not $repository -or $null -ne $script:UpdateTask) { return }
    try {
        Add-Type -AssemblyName System.Net.Http
        # Windows PowerShell can default to TLS versions that GitHub no longer accepts.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("CordBuilder/$script:AppVersion")
        $client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json")
        $script:UpdateClient = $client
        # Runs in the background; Update-UpdateCheck collects the result on a later timer tick.
        $script:UpdateTask = $client.GetStringAsync("https://api.github.com/repos/$repository/releases/latest")
    }
    catch { Stop-UpdateCheck }
}

function Update-UpdateCheck {
    $task = $script:UpdateTask
    if ($null -eq $task) {
        if ([DateTime]::UtcNow -ge $script:NextUpdateCheck) { Start-UpdateCheck }
        return
    }
    if (-not $task.IsCompleted) { return }
    # No release yet, no network, or rate limiting all leave the notice hidden.
    if ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
        try { $script:AvailableUpdate = Get-NewerRelease ($task.Result | ConvertFrom-Json) $script:AppVersion } catch { }
    }
    Stop-UpdateCheck
    Update-UpdateButton
}

function Update-UpdateButton {
    $update = Get-ScriptState "AvailableUpdate"
    $UpdateButton.Visibility = if ($null -ne $update) { "Visible" } else { "Collapsed" }
    if ($null -ne $update) { $UpdateText.Text = "Cord Builder $($update.Version) available" }
}
