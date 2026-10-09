# Runs app jobs without a window, for scheduled tasks:
#   -Action AutoUpdate   install updates when nobody is playing (rolls back automatically on problems)
#   -Action Events       switch timed events (double XP weekend, ...) on/off and tell the players
param([Parameter(Mandatory)][string]$Root, [ValidateSet('AutoUpdate', 'Events')][string]$Action = 'Events')

$ErrorActionPreference = 'Stop'
$ToolDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Manage.ps1')
. (Join-Path $PSScriptRoot 'Steps.ps1')
. (Join-Path $PSScriptRoot 'Update.ps1')
$global:ToolDir = $ToolDir
$Root = $Root.TrimEnd('\')
if (-not (Test-ServerRoot $Root)) { throw "No server in $Root" }
New-Item -ItemType Directory -Force (Join-Path $Root '.creationtool') | Out-Null

switch ($Action) {
    'AutoUpdate' {
        $Global:ToolLogFile = Join-Path $Root '.creationtool\auto-update.log'
        $s = Get-ServerSettings $Root
        $notice = Join-Path $Root 'tools\update-notice.json'
        $save = { param($ok, $msg) [pscustomobject]@{ Date = (Get-Date -Format 's'); Ok = $ok; Message = $msg } | ConvertTo-Json | Set-Content $notice -Encoding utf8 }
        if ($s.UpdatePinned) { Write-ToolLog 'Pinned to its current version - not updating.'; return }
        $st = Get-ServerStatus $Root
        if ($st.World -and $st.PlayersOnline -gt 0) { Write-ToolLog "Skipped: $($st.PlayersOnline) player(s) online. Trying again next time."; return }
        try {
            $plan = @(Get-UpdateStatus $Root | Where-Object { $_.NewCommits -gt 0 })
            if (-not $plan) { Write-ToolLog 'Everything is up to date.'; return }
            $r = Invoke-SafeUpdate -Root $Root -ToolDirectory $ToolDir -Components @($plan | ForEach-Object Id) -WarnMinutes 5 -Unattended
            if ($r.Ok) { & $save $true "Automatic update installed: $($r.Message)" }
            elseif ($r.Message -eq 'COMPILE_FAILED') {
                $why = if ($r.Failing) { "$($r.Failing -join ', ') does not work with the newest version yet" } else { 'the new version did not compile' }
                & $save $false "The automatic update was skipped because $why. Nothing was changed; it is tried again next time."
                Send-ServerNotice $Root "Automatic update of **$($s.RealmName)** skipped: $why. Nothing was changed." 'OnUpdate'
            } else { & $save $false "The automatic update was rolled back: $($r.Message)" }
        } catch {
            Write-ToolLog "Automatic update failed: $($_.Exception.Message)" 'ERROR'
            & $save $false "The automatic update could not run: $($_.Exception.Message)"
        }
    }
    'Events' {
        $s = Get-ServerSettings $Root
        $file = Join-Path $Root 'tools\events-active.txt'
        $before = @(if (Test-Path $file) { Get-Content $file | Where-Object { $_.Trim() } })
        $now = @(Get-ActiveEventNames $s (Get-Date))
        if ((@($before) -join '|') -eq (@($now) -join '|')) { return }
        Invoke-ApplyServerConfig $Root | Out-Null
        if (Get-ServerProcessInfo $Root 'worldserver') {
            try {
                Invoke-ServerSoap $Root 'reload config' | Out-Null
                foreach ($e in $now | Where-Object { $before -notcontains $_ }) { Invoke-ServerSoap $Root "announce $e has started! Enjoy." | Out-Null }
                foreach ($e in $before | Where-Object { $now -notcontains $_ }) { Invoke-ServerSoap $Root "announce $e is over. Thanks for playing!" | Out-Null }
            } catch {}
        }
    }
}
