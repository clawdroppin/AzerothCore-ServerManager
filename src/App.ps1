# AzerothCore Control Center - create and manage AzerothCore servers.
# Launch with AzerothCoreCreationTool.bat, which dot-sources this file at global scope (required: WPF event
# handlers and closures only see global functions). -SelfTest loads every page without showing the window.
# -StartPage opens a specific page (e.g. Prereqs, used by tools\PrereqInstaller\PrereqInstaller.bat).
# -TestScript <file> loads everything, then runs that script instead of showing the window (development).
param([switch]$SelfTest, [string]$StartPage, [string]$TestScript)

$ErrorActionPreference = 'Stop'
$ToolDir = Split-Path -Parent $PSScriptRoot

# ================================================================== elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $SelfTest -and -not $TestScript) {
    $pageArg = if ($StartPage -match '^[A-Za-z]+$') { " -StartPage $StartPage" } else { '' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -Command `". '$PSCommandPath'$pageArg`""
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Manage.ps1')
. (Join-Path $PSScriptRoot 'Steps.ps1')
. (Join-Path $PSScriptRoot 'Update.ps1')
. (Join-Path $PSScriptRoot 'Repair.ps1')
. (Join-Path $PSScriptRoot 'Windows.ps1')
. (Join-Path $PSScriptRoot 'Dialogs.ps1')

$V = Get-Content (Join-Path $ToolDir 'config\versions.json') -Raw | ConvertFrom-Json
$Machine = Get-MachineProfile
$LastFile = Join-Path $env:LOCALAPPDATA 'AzerothCoreCreationTool\last-install.json'

# ================================================================== window
if (-not [Windows.Application]::Current) { $null = New-Object Windows.Application }
$App = [Windows.Application]::Current
# Safety net: an unexpected error in a button handler shows a message (and is logged) instead of closing the app.
$App.Add_DispatcherUnhandledException({
    param($sender, $e)
    $e.Handled = $true
    $ex = $e.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
    try {
        $log = Join-Path $env:LOCALAPPDATA 'AzerothCoreCreationTool\app-errors.log'
        New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
        Add-Content $log ("{0}  {1}`r`n{2}`r`n" -f (Get-Date -Format 's'), $ex.Message, $e.Exception.ToString())
    } catch {}
    [Windows.MessageBox]::Show("Something went wrong, but the app keeps running:`n`n$($ex.Message)`n`nIf it keeps happening, please report it (Help & about > Project page) and attach:`n$env:LOCALAPPDATA\AzerothCoreCreationTool\app-errors.log", 'AzerothCore Control Center', 'OK', 'Warning') | Out-Null
})
$App.ShutdownMode = 'OnExplicitShutdown'
$themeXml = [IO.File]::ReadAllText((Join-Path $ToolDir 'ui\Theme.xaml'))
$App.Resources = [Windows.Markup.XamlReader]::Parse($themeXml)
$appXml = [IO.File]::ReadAllText((Join-Path $ToolDir 'ui\App.xaml'))
$Window = [Windows.Markup.XamlReader]::Parse($appXml)
$iconPath = Join-Path $ToolDir 'ui\icon.png'
if (Test-Path $iconPath) { $Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) }

$ui = @{}
foreach ($m in [regex]::Matches($appXml, 'x:Name="([^"]+)"')) { $ui[$m.Groups[1].Value] = $Window.FindName($m.Groups[1].Value) }

function Get-Brush([string]$key) { $App.Resources[$key] }

# Closures made with .GetNewClosure() (button handlers, -OnDone callbacks) run in their own little module, where
# $script:Name does NOT reach the app's variables. Inside closures use these instead (functions keep the app's scope).
function Get-AppVar([string]$Name) { Get-Variable -Name $Name -Scope Script -ValueOnly -ErrorAction SilentlyContinue }
function Set-AppVar([string]$Name, $Value) { Set-Variable -Name $Name -Value $Value -Scope Script }

function Show-Toast([string]$text, [int]$seconds = 4) {
    $ui.ToastText.Text = $text
    $ui.Toast.Visibility = 'Visible'
    $script:ToastUntil = (Get-Date).AddSeconds($seconds)
}

function Show-Message([string]$text, [string]$title = 'AzerothCore Control Center', [string]$icon = 'Information') {
    [Windows.MessageBox]::Show($Window, $text, $title, 'OK', $icon) | Out-Null
}

function Confirm-Action([string]$text, [string]$title = 'Please confirm') {
    [Windows.MessageBox]::Show($Window, $text, $title, 'YesNo', 'Question') -eq 'Yes'
}

function Read-Input([string]$prompt, [string]$title, [string]$default = '') {
    [Microsoft.VisualBasic.Interaction]::InputBox($prompt, $title, $default)
}

# ================================================================== background tasks
# Every slow operation runs in its own runspace so the window never freezes.
$Tasks = New-Object System.Collections.ArrayList

$script:WorkerPool = $null
function Get-WorkerPool {
    # Background workers with the app's scripts pre-loaded once (~2 ms per task instead of ~60 ms).
    if (-not $script:WorkerPool) {
        $iss = [initialsessionstate]::CreateDefault()
        foreach ($f in 'Common', 'Manage', 'Steps', 'Update', 'Repair') { [void]$iss.StartupScripts.Add((Join-Path $ToolDir "src\$f.ps1")) }
        $script:WorkerPool = [runspacefactory]::CreateRunspacePool(1, 8, $iss, $Host)
        $script:WorkerPool.ApartmentState = 'STA'
        $script:WorkerPool.Open()
    }
    $script:WorkerPool
}

function Start-BgTask {
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$Arguments = @(),
        [scriptblock]$OnDone,
        [string]$Overlay,         # title => show the busy overlay with live log
        [string]$Tag,
        [switch]$Hideable,        # long jobs: the overlay can be hidden while the job keeps running
        [switch]$Cancellable      # shows Cancel (the job stops at the next safe point; it can set Sync.NoCancel)
    )
    if ($Tag -and ($Tasks | Where-Object { $_.Tag -eq $Tag })) { return }   # already running
    $sync = [hashtable]::Synchronized(@{
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Steps = [hashtable]::Synchronized(@{}); Detail = ''; Current = ''; Cancel = $false
    })
    $ps = [powershell]::Create(); $ps.RunspacePool = Get-WorkerPool
    $wrapper = {
        param($SyncObj, $ToolDir, $Body, $ArgList)
        # Workers are reused: reset everything a previous task may have left behind.
        $global:Sync = $SyncObj
        $global:ToolDir = $ToolDir
        $global:ToolLogFile = $null
        $global:S = $null
        $global:ErrorActionPreference = 'Stop'
        $global:V = Get-Content (Join-Path $ToolDir 'config\versions.json') -Raw | ConvertFrom-Json
        Update-SessionPath
        $sb = [scriptblock]::Create($Body)
        & $sb @ArgList
    }
    $ps.AddScript($wrapper.ToString()).AddArgument($sync).AddArgument($ToolDir).AddArgument($Script.ToString()).AddArgument($Arguments) | Out-Null
    $task = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; OnDone = $OnDone; Overlay = $Overlay; Tag = $Tag }
    [void]$Tasks.Add($task)
    if ($Overlay) {
        $script:OverlayTask = $task
        $ui.BusyTitle.Text = $Overlay
        $ui.BusyDetail.Text = ''
        $ui.BusyDetail.Foreground = Get-Brush 'MutedBrush'
        $ui.BusyBar.IsIndeterminate = $true
        $ui.BusyLog.Text = ''
        $ui.BtnBusyClose.Visibility = 'Collapsed'
        $ui.BtnBusyHide.Visibility = if ($Hideable) { 'Visible' } else { 'Collapsed' }
        $ui.BtnBusyCancel.Visibility = if ($Cancellable) { 'Visible' } else { 'Collapsed' }
        $ui.BtnBusyCancel.IsEnabled = $true
        $ui.Busy.Visibility = 'Visible'
    }
    $task
}

function Complete-BgTask($task) {
    $result = $null; $err = $null
    try { $result = $task.PS.EndInvoke($task.Handle) }
    catch { $err = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception } }
    if (-not $err -and $task.PS.Streams.Error.Count -gt 0 -and -not $result) { $err = $task.PS.Streams.Error[-1].Exception }
    $task.PS.Dispose()
    if ($task.Overlay) {
        $line = $null
        while ($task.Sync.Log.TryDequeue([ref]$line)) { $ui.BusyLog.AppendText($line + "`r`n") }
        $ui.BtnBgTask.Visibility = 'Collapsed'
        $ui.BtnBusyHide.Visibility = 'Collapsed'; $ui.BtnBusyCancel.Visibility = 'Collapsed'
        if ($err) {
            $ui.BusyTitle.Text = "$($task.Overlay) - $(if ($err -is [OperationCanceledException]) { 'cancelled' } else { 'failed' })"
            $ui.BusyDetail.Text = $err.Message
            $ui.BusyDetail.Foreground = Get-Brush 'BadBrush'
            $ui.BusyBar.IsIndeterminate = $false; $ui.BusyBar.Value = 0
            $ui.BtnBusyClose.Visibility = 'Visible'
            $ui.Busy.Visibility = 'Visible'
        } else {
            $ui.Busy.Visibility = 'Collapsed'
        }
        if ($script:OverlayTask -eq $task) { $script:OverlayTask = $null }
    }
    if ($task.OnDone) {
        try { & $task.OnDone $result $err } catch { Show-Toast "Error: $($_.Exception.Message)" 6 }
    } elseif ($err -and -not $task.Overlay) {
        Show-Toast "Error: $($err.Message)" 6
    }
}

$ui.BtnBusyClose.Add_Click({
    $ui.Busy.Visibility = 'Collapsed'
    $ui.BusyDetail.Foreground = Get-Brush 'MutedBrush'
    $ui.BusyBar.IsIndeterminate = $true
})
# Long jobs (updates, copying characters) can run in the background while the rest of the app is used.
$ui.BtnBusyHide.Add_Click({
    $ui.Busy.Visibility = 'Collapsed'
    if ($script:OverlayTask) { $ui.BtnBgTask.Content = "⏳ $($script:OverlayTask.Overlay)"; $ui.BtnBgTask.Visibility = 'Visible' }
    Show-Toast 'It keeps running. Click the progress button in the sidebar to see it again.' 6
})
$ui.BtnBgTask.Add_Click({ if ($script:OverlayTask) { $ui.Busy.Visibility = 'Visible'; $ui.BtnBgTask.Visibility = 'Collapsed' } })
$ui.BtnBusyCancel.Add_Click({
    $t = $script:OverlayTask
    if ($t -and (Confirm-Action 'Cancel this job? It stops at the next safe point and leaves everything as it was.' 'Cancel')) {
        $t.Sync.Cancel = $true; $ui.BtnBusyCancel.IsEnabled = $false; $ui.BusyDetail.Text = 'Cancelling...'
    }
})

# ================================================================== server selection
$script:Root = $null
$script:Settings = $null

function Update-ServerList([string]$select) {
    try { $list = @(Get-ServerRegistry | Where-Object { Test-ServerRoot $_.RootDir }) }
    catch { Show-Message "$($_.Exception.Message)`n`nAdd your servers again with My servers > Add existing folder (nothing inside them is lost)." 'Server list' 'Warning'; $list = @() }
    $ui.CmbServer.Items.Clear()
    foreach ($s in $list) {
        $item = New-Object Windows.Controls.ComboBoxItem
        $item.Content = $s.Name; $item.Tag = $s.RootDir; $item.ToolTip = $s.RootDir
        [void]$ui.CmbServer.Items.Add($item)
    }
    $hasServers = $list.Count -gt 0
    $ui.NavPanel.IsEnabled = $hasServers
    $ui.CmbServer.IsEnabled = $hasServers
    if (-not $hasServers) { $script:Root = $null; Show-Page 'Welcome'; return }
    $idx = 0
    if ($select) { for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].RootDir -eq $select) { $idx = $i } } }
    $ui.CmbServer.SelectedIndex = $idx
}

$ui.CmbServer.Add_SelectionChanged({
    $item = $ui.CmbServer.SelectedItem
    if (-not $item) { return }
    $script:Root = $item.Tag
    try { $script:Settings = Get-ServerSettings $script:Root } catch { Show-Toast "Could not read settings: $($_.Exception.Message)" 6; return }
    $script:LastStatus = $null
    $script:TickHistory.Clear()
    Show-UpdateBadgeFor $script:Root
    if (-not $script:CurrentPage -or $script:CurrentPage -eq 'Welcome') {
        # With several servers start on the overview, with one go straight to its dashboard.
        if ($ui.CmbServer.Items.Count -gt 1) { $ui.NavServers.IsChecked = $true } else { $ui.NavDashboard.IsChecked = $true }
    }
    elseif ($script:CurrentPage -ne 'Wizard') { Enter-Page $script:CurrentPage }
})

function Show-UpdateBadgeFor([string]$Root) {
    # "Updates •" in the sidebar when the last check found something; checks again in the background every 3 days.
    $f = Join-Path $Root 'tools\update-check.json'
    $c = $null; if (Test-Path $f) { try { $c = Get-Content $f -Raw | ConvertFrom-Json } catch {} }
    $ui.NavUpdates.Content = if ($c -and $c.Available) { '⟳  Updates  •' } else { '⟳  Updates' }
    $stale = -not $c -or ([datetime]$c.Date) -lt (Get-Date).AddDays(-3)
    if ($stale -and (Test-Path (Join-Path $Root 'azerothcore-wotlk\.git')) -and -not $SelfTest -and -not $TestScript) {
        Start-BgTask -Tag "bgcheck:$Root" -Script { param($r) @(Get-UpdateStatus $r) } -Arguments @($Root) -OnDone {
            param($res, $err) if (-not $err) { Set-UpdateBadge $Root ([bool](@($res) | Where-Object { $_.NewCommits -gt 0 })) }
        }.GetNewClosure() | Out-Null
    }
    $n = Join-Path $Root 'tools\update-notice.json'
    if (Test-Path $n) { try { $m = Get-Content $n -Raw | ConvertFrom-Json; Show-Toast "Updates: $($m.Message)" 10 } catch {} }
}

# ================================================================== navigation
$Pages = 'Welcome', 'Servers', 'Dashboard', 'Console', 'Accounts', 'Characters', 'Friends', 'Ai', 'Settings', 'Addons', 'Backups', 'Export', 'Updates', 'Performance', 'Logs', 'About', 'Wizard', 'Import', 'Prereqs'
$script:CurrentPage = $null

function Show-Page([string]$name) {
    foreach ($p in $Pages) { $ui["Page$p"].Visibility = if ($p -eq $name) { 'Visible' } else { 'Collapsed' } }
    if ($script:CurrentPage -ne $name) {
        # Soft fade + slide-in when switching pages.
        $el = $ui["Page$name"]
        $fade = New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(180))
        $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        $shift = New-Object Windows.Media.TranslateTransform
        $el.RenderTransform = $shift
        $slide = New-Object Windows.Media.Animation.DoubleAnimation(10, 0, [TimeSpan]::FromMilliseconds(220))
        $slide.EasingFunction = New-Object Windows.Media.Animation.CubicEase
        $shift.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slide)
    }
    $script:CurrentPage = $name
}

function Enter-Page([string]$name) {
    Show-Page $name
    switch ($name) {
        'Dashboard'  { Update-Dashboard -Full }
        'Accounts'   { Update-Accounts }
        'Characters' { Update-Characters }
        'Friends'    { Enter-Friends }
        'Ai'         { Enter-Ai }
        'Settings'   { Enter-Settings }
        'Addons'     { Enter-Addons }
        'Backups'    { Enter-Backups }
        'Updates'    { Enter-Updates }
        'Performance' { Enter-Performance }
        'Logs'       { Enter-Logs }
        'About'      { Enter-About }
        'Wizard'     { Enter-Wizard }
        'Servers'    { Enter-Servers }
        'Export'     { Enter-Export }
        'Import'     { Enter-Import }
        'Prereqs'    { Enter-Prereqs }
    }
}

foreach ($n in 'Servers', 'Dashboard', 'Console', 'Accounts', 'Characters', 'Friends', 'Ai', 'Settings', 'Addons', 'Backups', 'Export', 'Updates', 'Performance', 'Logs', 'About', 'Import', 'Prereqs') {
    $page = $n
    $ui["Nav$n"].Add_Checked({ Enter-Page $this.Tag }.GetNewClosure())
    $ui["Nav$n"].Tag = $page
}
$ui.NavNew.Add_Checked({ Enter-Page 'Wizard' })
$ui.BtnWelcomeCreate.Add_Click({ $ui.NavNew.IsChecked = $true })
$ui.BtnWelcomeAdd.Add_Click({ Add-ExistingServer })

function Assert-Server {
    if (-not $script:Root) { Show-Toast 'Select or create a server first.'; return $false }
    $true
}

# ================================================================== dashboard
function Set-StatusIndicator($st) {
    if (-not $st) { $ui.StatusDot.Fill = Get-Brush 'MutedBrush'; $ui.StatusText.Text = 'Unknown'; return }
    if ($st.World -and $st.Starting) { $ui.StatusDot.Fill = Get-Brush 'WarnBrush'; $ui.StatusText.Text = 'Starting...' }
    elseif ($st.World) { $ui.StatusDot.Fill = Get-Brush 'GoodBrush'; $ui.StatusText.Text = "Online · $($st.PlayersOnline) players · $($st.BotsOnline) bots" }
    else { $ui.StatusDot.Fill = Get-Brush 'BadBrush'; $ui.StatusText.Text = 'Offline' }
}

function New-ServiceRow([string]$name, [string]$state, [string]$kind) {
    $row = New-Object Windows.Controls.DockPanel; $row.Margin = '0,4'
    $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 9; $dot.Height = 9; $dot.Margin = '0,0,10,0'
    $dot.Fill = Get-Brush $(switch ($kind) { 'good' { 'GoodBrush' } 'warn' { 'WarnBrush' } 'bad' { 'BadBrush' } default { 'MutedBrush' } })
    $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = $name; $t1.Width = 170
    $t2 = New-Object Windows.Controls.TextBlock; $t2.Text = $state; $t2.Foreground = Get-Brush 'MutedBrush'
    [void]$row.Children.Add($dot); [void]$row.Children.Add($t1); [void]$row.Children.Add($t2)
    $row
}

$script:TickHistory = New-Object System.Collections.ArrayList
function Update-Sparkline {
    $pts = New-Object Windows.Media.PointCollection
    $h = @($script:TickHistory)
    $w = $ui.SparkCanvas.ActualWidth; if ($w -lt 50) { $w = 900 }
    $height = 86
    if ($h.Count -ge 2) {
        $max = [math]::Max(50, ($h | Measure-Object -Maximum).Maximum)
        for ($i = 0; $i -lt $h.Count; $i++) {
            $x = $w * $i / 119
            $y = $height - ($height - 6) * $h[$i] / $max - 2
            $pts.Add((New-Object Windows.Point($x, $y)))
        }
        $ui.SparkLabel.Text = "now $($h[-1]) ms  ·  peak $([int]$max) ms  ·  last $([math]::Round($h.Count * 5 / 60, 1)) min"
    } else { $ui.SparkLabel.Text = 'collecting...' }
    $ui.SparkLine.Points = $pts
}

function Show-Status($st) {
    $script:LastStatus = $st
    Set-StatusIndicator $st
    if ($st -and $st.TickMean -ne $null) {
        [void]$script:TickHistory.Add([int]$st.TickMean)
        while ($script:TickHistory.Count -gt 120) { $script:TickHistory.RemoveAt(0) }
    }
    if ($script:CurrentPage -ne 'Dashboard' -or -not $st) { return }
    Update-Sparkline
    $ui.DashTitle.Text = $st.Name
    $ui.DashSubtitle.Text = $script:Root
    $ui.StatPlayers.Text = if ($st.World) { "$($st.PlayersOnline)" } else { '–' }
    $ui.StatBots.Text = if ($st.World) { "$($st.BotsOnline)" } else { '–' }
    if ($st.TickMedian -ne $null) {
        $ui.StatTick.Text = "$($st.TickMedian) ms"
        $ui.StatTickHint.Text = "average $($st.TickMean) ms · worst 1%: $($st.TickP99) ms" + $(if ($st.TickMean -gt 100) { '  (busy!)' } else { '  (smooth)' })
    } else { $ui.StatTick.Text = '–'; $ui.StatTickHint.Text = '' }
    if ($st.Uptime) {
        $u = $st.Uptime
        $ui.StatUptime.Text = if ($u.TotalHours -ge 1) { '{0}h {1}m' -f [int][math]::Floor($u.TotalHours), $u.Minutes } else { '{0}m' -f $u.Minutes }
        $ui.StatRam.Text = "world server uses $($st.WorldRamGB) GB RAM"
    } else { $ui.StatUptime.Text = '–'; $ui.StatRam.Text = '' }

    $ui.ServiceList.Items.Clear()
    $mk = if ($st.MySql -eq 'Running') { 'good' } else { 'bad' }
    [void]$ui.ServiceList.Items.Add((New-ServiceRow 'Database (MySQL)' $st.MySql $mk))
    [void]$ui.ServiceList.Items.Add((New-ServiceRow 'Login server' $(if ($st.Auth) { 'Running' } else { 'Stopped' }) $(if ($st.Auth) { 'good' } else { 'bad' })))
    $ws = if ($st.World -and $st.Starting) { 'Starting (loading the world)...' } elseif ($st.World) { "Running (PID $($st.WorldPid))" } else { 'Stopped' }
    [void]$ui.ServiceList.Items.Add((New-ServiceRow 'World server' $ws $(if ($st.World -and -not $st.Starting) { 'good' } elseif ($st.World) { 'warn' } else { 'bad' })))
    if ($st.LlmEnabled) {
        [void]$ui.ServiceList.Items.Add((New-ServiceRow 'AI chatter bridge' $(if ($st.Bridge) { 'Running' } else { 'Stopped' }) $(if ($st.Bridge) { 'good' } else { 'idle' })))
        [void]$ui.ServiceList.Items.Add((New-ServiceRow 'Ollama (AI model)' $(if ($st.Ollama) { 'Running' } else { 'Stopped' }) $(if ($st.Ollama) { 'good' } else { 'idle' })))
    }
    $ui.BtnStart.IsEnabled = -not $st.World
    $ui.BtnStop.IsEnabled = [bool]$st.World
    $ui.BtnRestart.IsEnabled = [bool]$st.World -and -not $st.Starting
}

function Show-Health($items) {
    $ui.HealthList.Items.Clear()
    foreach ($h in @($items)) {
        $row = New-Object Windows.Controls.DockPanel; $row.Margin = '0,3'
        $icon = New-Object Windows.Controls.TextBlock; $icon.Width = 24; $icon.FontWeight = 'Bold'
        $icon.Text = switch ($h.Level) { 'ok' { '✔' } 'warn' { '!' } default { '✖' } }
        $icon.Foreground = Get-Brush $(switch ($h.Level) { 'ok' { 'GoodBrush' } 'warn' { 'WarnBrush' } default { 'BadBrush' } })
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $h.Text; $t.TextWrapping = 'Wrap'
        [void]$row.Children.Add($icon); [void]$row.Children.Add($t)
        [void]$ui.HealthList.Items.Add($row)
    }
}

function Show-LevelChart($dist) {
    $ui.LevelChart.Items.Clear()
    $dist = @($dist)
    if (-not $dist -or $dist.Count -eq 0) { $ui.LevelChartHint.Text = 'No bots yet. They are created the first time the server starts.'; return }
    $max = ($dist | Measure-Object Count -Maximum).Maximum
    $total = ($dist | Measure-Object Count -Sum).Sum
    foreach ($d in $dist) {
        $row = New-Object Windows.Controls.DockPanel; $row.Margin = '0,3'
        $lbl = New-Object Windows.Controls.TextBlock; $lbl.Text = "Lv $($d.Range)"; $lbl.Width = 70; $lbl.Foreground = Get-Brush 'MutedBrush'
        $cnt = New-Object Windows.Controls.TextBlock; $cnt.Text = "$($d.Count)"; $cnt.Width = 50; $cnt.TextAlignment = 'Right'
        [Windows.Controls.DockPanel]::SetDock($cnt, 'Right')
        $bar = New-Object Windows.Controls.Border; $bar.Height = 14; $bar.CornerRadius = 3; $bar.HorizontalAlignment = 'Left'
        $bar.Background = Get-Brush 'AccentBrush'
        $bar.Width = [math]::Max(3, 520 * $d.Count / [math]::Max(1, $max))
        [void]$row.Children.Add($lbl); [void]$row.Children.Add($cnt); [void]$row.Children.Add($bar)
        [void]$ui.LevelChart.Items.Add($row)
    }
    $ui.LevelChartHint.Text = "$total bots in total."
}

function Update-Dashboard([switch]$Full) {
    if (-not $script:Root) { return }
    $root = $script:Root
    $withHealth = $script:CurrentPage -eq 'Dashboard'
    Start-BgTask -Tag 'status' -Script {
        param($r, $h)
        $st = Get-ServerStatus $r
        [pscustomobject]@{ Status = $st; Health = $(if ($h) { @(Get-ServerHealth $r $st) } else { $null }) }
    } -Arguments @($root, $withHealth) -OnDone {
        param($res, $err)
        if ($err -or (Get-AppVar Root) -ne $root) { return }
        $r = $res | Select-Object -Last 1
        Show-Status $r.Status
        if ($r.Health) { Show-Health $r.Health }
    }.GetNewClosure() | Out-Null
    if ($Full) {
        $ui.ChkAutostart.IsChecked = Get-ServerAutostart $root
        Start-BgTask -Tag 'levels' -Script { param($r) Get-BotLevelDistribution $r } -Arguments @($root) -OnDone {
            param($res, $err) if (-not $err) { Show-LevelChart $res } else { Show-LevelChart @() }
        } | Out-Null
    }
}

$ui.BtnStart.Add_Click({
    if (-not (Assert-Server)) { return }
    Start-ServerSmart $script:Root
})
function Invoke-StopServer([scriptblock]$Then) {
    $root = $script:Root
    Start-BgTask -Overlay 'Stopping the server (saving all characters)...' -Script { param($r) Stop-GameServer $r } -Arguments @($root) -OnDone {
        param($res, $err)
        if (-not $err) { Show-Toast 'Server stopped safely.' }
        Update-Dashboard
        if ($Then -and -not $err) { & $Then }
    }.GetNewClosure() | Out-Null
}
$ui.BtnStop.Add_Click({ if ((Assert-Server) -and (Confirm-Action 'Stop the server? Everyone will be disconnected (characters are saved first).')) { Invoke-StopServer } })
$ui.BtnRestart.Add_Click({
    if ((Assert-Server) -and (Confirm-Action 'Restart the server? Everyone will be disconnected for a minute.')) {
        $root = $script:Root
        Invoke-StopServer { Start-GameServer $root; Show-Toast 'Server restarting...' }.GetNewClosure()
    }
})
$ui.QaSave.Add_Click({ Invoke-Console 'saveall' })
$ui.QaAnnounce.Add_Click({
    $msg = Read-Input 'Message shown to everyone in the game:' 'Announce'
    if ($msg) { Invoke-Console "announce $msg" }
})
function Get-WowExe([switch]$Ask) {
    $exe = $script:Settings.WowExe
    if ($exe -and (Test-Path $exe) -and -not $Ask) { return $exe }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog; $dlg.Filter = 'World of Warcraft (Wow.exe)|Wow.exe'; $dlg.Title = 'Where is your WoW 3.3.5a Wow.exe?'
    if (-not $dlg.ShowDialog($Window)) { return $null }
    $problem = Test-WowClient $dlg.FileName
    if ($problem) { Show-Message $problem 'Game client' 'Warning'; return $null }
    $script:Settings.WowExe = $dlg.FileName; Save-ServerSettings $script:Root $script:Settings
    $dlg.FileName
}
$ui.QaGame.Add_Click({
    $exe = Get-WowExe; if (-not $exe) { return }
    try { Set-ClientRealmlist $exe '127.0.0.1' } catch {}
    Start-Process $exe -WorkingDirectory (Split-Path $exe)
})
$ui.QaMotd.Add_Click({
    $msg = Read-Input 'Message players see when they log in:' 'Message of the day'
    if ($msg) { Invoke-Console "server set motd enUS $msg" }
})
$ui.QaFolder.Add_Click({ if (Assert-Server) { Start-Process explorer.exe -ArgumentList "`"$($script:Root)`"" } })
$ui.QaBackup.Add_Click({ Invoke-Backup })
$ui.ChkAutostart.Add_Click({
    try { Set-ServerAutostart $script:Root ([bool]$ui.ChkAutostart.IsChecked); Show-Toast $(if ($ui.ChkAutostart.IsChecked) { 'The server will start when you sign in.' } else { 'Auto-start turned off.' }) }
    catch { Show-Toast "Could not change auto-start: $($_.Exception.Message)" 6 }
})

# ================================================================== console
$script:CmdHistory = New-Object System.Collections.ArrayList
$script:CmdIndex = 0
function Invoke-Console([string]$cmd) {
    if (-not (Assert-Server) -or -not $cmd.Trim()) { return }
    $cmd = $cmd.Trim().TrimStart('.')
    [void]$script:CmdHistory.Add($cmd); $script:CmdIndex = $script:CmdHistory.Count
    $ui.ConsoleOut.AppendText("> $cmd`r`n")
    $root = $script:Root
    Start-BgTask -Script { param($r, $c) Invoke-ServerSoap $r $c } -Arguments @($root, $cmd) -OnDone {
        param($res, $err)
        $text = if ($err) { "[error] $($err.Message)" } else { (@($res) -join "`r`n") }
        if (-not $text) { $text = '(done)' }
        $ui.ConsoleOut.AppendText($text + "`r`n`r`n"); $ui.ConsoleOut.ScrollToEnd()
        if ($script:CurrentPage -ne 'Console') { Show-Toast $text.Split("`n")[0] }
    } | Out-Null
}
$quick = [ordered]@{
    'Server info' = 'server info'; 'Who is online' = 'account onlinelist'; 'Save all' = 'saveall'
    'Message of the day' = 'server motd'; 'Bot statistics' = 'playerbots rndbot stats'; 'Reload config' = 'reload config'
}
foreach ($k in $quick.Keys) {
    $b = New-Object Windows.Controls.Button; $b.Content = $k; $b.Tag = $quick[$k]; $b.Margin = '0,0,8,8'
    $b.Add_Click({ Invoke-Console $this.Tag })
    [void]$ui.QuickCommands.Children.Add($b)
}
$ui.BtnRunCmd.Add_Click({ Invoke-Console $ui.TxtCmd.Text; $ui.TxtCmd.Clear() })
$ui.TxtCmd.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return') { Invoke-Console $ui.TxtCmd.Text; $ui.TxtCmd.Clear() }
    elseif ($e.Key -eq 'Up' -and $script:CmdIndex -gt 0) { $script:CmdIndex--; $ui.TxtCmd.Text = $script:CmdHistory[$script:CmdIndex]; $ui.TxtCmd.CaretIndex = $ui.TxtCmd.Text.Length }
    elseif ($e.Key -eq 'Down' -and $script:CmdIndex -lt $script:CmdHistory.Count - 1) { $script:CmdIndex++; $ui.TxtCmd.Text = $script:CmdHistory[$script:CmdIndex] }
})

# ================================================================== accounts
function Update-Accounts {
    if (-not $script:Root) { return }
    $root = $script:Root
    Start-BgTask -Tag 'accounts' -Script { param($r) @(Get-GameAccounts $r) } -Arguments @($root) -OnDone {
        param($res, $err)
        if ($err) { Show-Toast "Could not load accounts: $($err.Message)" 6; return }
        $ui.AccGrid.ItemsSource = @($res)
    } | Out-Null
}
$ui.BtnAccRefresh.Add_Click({ Update-Accounts })
$ui.BtnAccCreate.Add_Click({
    $u = $ui.AccUser.Text.Trim(); $p = $ui.AccPass.Password
    if ($u -notmatch '^[A-Za-z0-9]{3,17}$') { Show-Toast 'Username: 3-17 letters or numbers.'; return }
    if ($p.Length -lt 4 -or $p -match '["''\s]') { Show-Toast 'Password: 4-16 characters, no spaces or quotes.'; return }
    $lvl = $ui.AccLevel.SelectedIndex
    $root = $script:Root
    Start-BgTask -Script { param($r, $u, $p, $l) New-ServerAccount $r $u $p $l } -Arguments @($root, $u, $p, $lvl) -OnDone {
        param($res, $err)
        if ($err) { Show-Toast "Failed: $($err.Message)" 6 } else { Show-Toast "$res"; $ui.AccPass.Clear(); Update-Accounts }
    } | Out-Null
})
function Get-SelectedAccount { $a = $ui.AccGrid.SelectedItem; if (-not $a) { Show-Toast 'Select an account in the list first.' }; $a }
$ui.BtnAccGm.Add_Click({
    $a = Get-SelectedAccount; if (-not $a) { return }
    try { Set-AccountGmLevel $script:Root $a.Username $ui.AccLevel.SelectedIndex; Show-Toast "$($a.Username) is now GM level $($ui.AccLevel.SelectedIndex) (applies at next login)."; Update-Accounts }
    catch { Show-Toast $_.Exception.Message 6 }
})
$ui.BtnAccBan.Add_Click({
    $a = Get-SelectedAccount; if (-not $a) { return }
    $ban = -not $a.Banned
    if ($ban -and -not (Confirm-Action "Ban $($a.Username)? They will not be able to log in.")) { return }
    $root = $script:Root
    Start-BgTask -Script { param($r, $u, $b) Set-AccountBan $r $u $b } -Arguments @($root, $a.Username, $ban) -OnDone {
        param($res, $err) if ($err) { Show-Toast $err.Message 6 } else { Show-Toast "$res"; Update-Accounts }
    } | Out-Null
})
$ui.BtnAccDelete.Add_Click({
    $a = Get-SelectedAccount; if (-not $a) { return }
    if ($a.Username -in 'SERVERADMIN', 'AHBOT') { Show-Toast "$($a.Username) is used by the server itself and cannot be deleted here." 6; return }
    if (-not (Confirm-Action "Permanently delete account $($a.Username) and ALL its characters? This cannot be undone.`n`n(Tip: make a backup first.)" 'Delete account')) { return }
    $root = $script:Root
    Start-BgTask -Script { param($r, $u) Remove-ServerAccount $r $u } -Arguments @($root, $a.Username) -OnDone {
        param($res, $err) if ($err) { Show-Toast $err.Message 8 } else { Show-Toast "$res"; Update-Accounts }
    } | Out-Null
})

# ================================================================== characters
function Update-Characters {
    if (-not $script:Root) { return }
    $kind = @('Players', 'Bots', 'All')[$ui.CharKind.SelectedIndex]
    $online = [bool]$ui.CharOnline.IsChecked
    $root = $script:Root
    Start-BgTask -Tag 'chars' -Script { param($r, $k, $o) @(Get-ServerCharacters -Root $r -Kind $k -OnlineOnly:$o) } -Arguments @($root, $kind, $online) -OnDone {
        param($res, $err)
        if ($err) { Show-Toast "Could not load characters: $($err.Message)" 6; return }
        $ui.CharGrid.ItemsSource = @($res)
        $ui.CharCount.Text = "$(@($res).Count) characters shown (max 500)."
    } | Out-Null
}
$ui.BtnCharRefresh.Add_Click({ Update-Characters })
$ui.CharKind.Add_SelectionChanged({ if ($script:CurrentPage -eq 'Characters') { Update-Characters } })
$ui.CharOnline.Add_Click({ Update-Characters })
$ui.BtnCharKick.Add_Click({
    $c = $ui.CharGrid.SelectedItem; if (-not $c) { Show-Toast 'Select a character first.'; return }
    Invoke-Console "kick $($c.Name)"
})
$teleMenu = New-Object Windows.Controls.ContextMenu
foreach ($city in 'Stormwind', 'Ironforge', 'Darnassus', 'Orgrimmar', 'Undercity', 'ThunderBluff', 'Shattrath', 'Dalaran') {
    $mi = New-Object Windows.Controls.MenuItem; $mi.Header = $city
    $mi.Add_Click({
        $c = $ui.CharGrid.SelectedItem; if (-not $c) { Show-Toast 'Select a character first.'; return }
        Invoke-Console "tele name $($c.Name) $($this.Header)"
    })
    [void]$teleMenu.Items.Add($mi)
}
$ui.BtnCharSummon.ContextMenu = $teleMenu
$ui.BtnCharSummon.Add_Click({ $teleMenu.PlacementTarget = $ui.BtnCharSummon; $teleMenu.IsOpen = $true })

function Get-SelectedCharacter { $c = $ui.CharGrid.SelectedItem; if (-not $c) { Show-Toast 'Select a character first.' }; $c }
$ui.BtnCharLevel.Add_Click({
    $c = Get-SelectedCharacter; if (-not $c) { return }
    $lvl = Read-Input "New level for $($c.Name) (1-$(@(60, 70, 80)[[int]$script:Settings.Expansion])):" 'Set level' $c.Level
    if ($lvl -match '^\d{1,2}$') { Invoke-Console "character level $($c.Name) $lvl" }
})
$ui.BtnCharGold.Add_Click({
    $c = Get-SelectedCharacter; if (-not $c) { return }
    $g = Read-Input "How much gold to mail to $($c.Name)?" 'Mail gold' '100'
    if ($g -match '^\d{1,6}$') { Invoke-Console "send money $($c.Name) `"A gift`" `"From the server owner.`" $([int]$g * 10000)" }
})
$ui.BtnCharItem.Add_Click({
    $c = Get-SelectedCharacter; if (-not $c) { return }
    $pick = Show-ItemPicker $c.Name
    if ($pick) { Invoke-Console "send items $($c.Name) `"A gift`" `"From the server owner: $($pick.Name)`" $($pick.Id):$($pick.Count)" }
})
$ui.BtnCharCopy.Add_Click({
    $c = Get-SelectedCharacter; if (-not $c) { return }
    if ($c.Account -like 'RNDBOT*') { Show-Message 'That is a bot. Copy one of your own characters instead.'; return }
    $from = $script:Root
    $t = Show-CopyCharacterDialog $c.Name $from
    if (-not $t) { return }
    Start-BgTask -Overlay "Copying $($c.Name) to $($t.ToName)" -Hideable -Script {
        param($f, $n, $to, $acc, $nn) Copy-CharacterToServer -FromRoot $f -Character $n -ToRoot $to -ToAccount $acc -NewName $nn
    } -Arguments @($from, $c.Name, $t.To, $t.Account, $t.NewName) -OnDone {
        param($res, $err) if (-not $err) { Show-Message "$($res | Select-Object -Last 1)" 'Copy character' }
    } | Out-Null
})

# ================================================================== play with friends
$script:Net = $null
$ui.PortGuide.Text = @"
Only needed for "Over the internet with port forwarding". Every router is different, but the steps are the same:

1.  Open your router's page in a browser. It is usually http://192.168.0.1 or http://192.168.1.1 (shown above as "router").
     The login is often printed on a sticker on the router.
2.  Find "Port Forwarding" (sometimes under Advanced, NAT, Virtual Server, or Gaming).
3.  Add TWO rules, both TCP, both pointing at this PC's home-network IP (shown above):
        • External port 3724  ->  internal port 3724   (login server)
        • External port 8085  ->  internal port 8085   (game world)
4.  Save. Give this PC a fixed IP in the router ("DHCP reservation") so the rule keeps working after a reboot.
5.  Click "Allow friends through the firewall" below, and "Apply connection mode" above with the internet option.
6.  Your friend uses your public IP in their realmlist. It can change when your internet provider reconnects
     you; if friends suddenly can't connect, come back here and click Apply again.

Easier and safer alternative: Tailscale (free, https://tailscale.com). Install it on both PCs, sign in with the
same account (or share your PC with your friend from the Tailscale admin page), then pick the VPN option.
Nothing on the router needs to change and the server is not exposed to the whole internet.
"@

function Enter-Friends {
    if (-not $script:Root) { return }
    Update-FirewallStatus
    $ui.TxtDiscord.Text = Get-DiscordWebhook $script:Root
    $n = $script:Settings.Notify
    $ui.ChkNotifyStart.IsChecked = $n.OnStartStop -ne $false; $ui.ChkNotifyLogin.IsChecked = $n.OnLogin -ne $false
    $ui.ChkNotifyCrash.IsChecked = $n.OnCrash -ne $false; $ui.ChkNotifyUpdate.IsChecked = $n.OnUpdate -ne $false
    $ui.NetInfo.Text = 'Detecting your network...'
    $root = $script:Root
    Start-BgTask -Tag 'net' -Script { param($r) [pscustomobject]@{ Net = Get-NetworkInfo; Realm = Get-RealmAddress $r; Profile = "$(Get-NetworkProfileName)" } } -Arguments @($root) -OnDone {
        param($res, $err)
        if ($err) { $ui.NetInfo.Text = "Could not detect the network: $($err.Message)"; return }
        $r = $res | Select-Object -Last 1
        $script:Net = $r.Net
        $n = $r.Net
        $ui.NetInfo.Text = (@(
            "This PC on your home network:  $(if ($n.LanIp) { $n.LanIp } else { 'not found' })",
            "Your public internet address:  $(if ($n.PublicIp) { $n.PublicIp } else { 'not found (offline?)' })",
            "VPN (Tailscale etc.):  $(if ($n.VpnIp) { "$($n.VpnIp)  ($($n.VpnName))" } else { 'not installed' })",
            "Router:  $(if ($n.Gateway) { $n.Gateway } else { '?' })    ·    Windows network type: $($r.Profile)",
            "Players are currently sent to:  $($r.Realm.Address)  (home network: $($r.Realm.LocalAddress))"
        ) -join "`n")
        $a = $r.Realm.Address
        if ($a -eq '127.0.0.1') { $ui.RbNetLocal.IsChecked = $true }
        elseif ($n.VpnIp -and $a -eq $n.VpnIp) { $ui.RbNetVpn.IsChecked = $true }
        elseif ($n.PublicIp -and $a -eq $n.PublicIp) { $ui.RbNetInternet.IsChecked = $true }
        else { $ui.RbNetLan.IsChecked = $true }
    } | Out-Null
}
$ui.BtnNetRefresh.Add_Click({ Enter-Friends })

$netHelp = @{
    RbNetLocal    = 'Only this PC can connect. Safest.'
    RbNetLan      = 'Anyone on your Wi-Fi / home network can join. Your friend sets their realmlist to this PC''s home-network IP. Also click "Allow friends through the firewall".'
    RbNetVpn      = 'Install Tailscale (free) on both PCs and sign in. Your friend connects to your Tailscale address. No router changes, nothing exposed to the internet. Also allow the firewall below.'
    RbNetInternet = 'Anyone with your public IP can reach the login screen. Needs the two port forwards described at the bottom of this page, plus the firewall rules. Use strong passwords.'
}
foreach ($rb in $netHelp.Keys) {
    $name = $rb
    $ui[$rb].Add_Checked({ $ui.NetModeHelp.Text = $netHelp[$this.Name] })
}

$ui.BtnNetApply.Add_Click({
    $n = $script:Net
    if (-not $n) { Show-Toast 'Still detecting your network, try again in a moment.'; return }
    $lan = if ($n.LanIp) { $n.LanIp } else { '127.0.0.1' }
    if ($ui.RbNetLocal.IsChecked) { $addr = '127.0.0.1'; $local = '127.0.0.1' }
    elseif ($ui.RbNetLan.IsChecked) { $addr = $lan; $local = $lan }
    elseif ($ui.RbNetVpn.IsChecked) {
        if (-not $n.VpnIp) { Show-Message "No VPN address found.`n`nInstall Tailscale from https://tailscale.com, sign in, then click 'Detect again'."; return }
        $addr = $n.VpnIp; $local = $lan
    } else {
        if (-not $n.PublicIp) { Show-Message 'Your public IP could not be detected. Check your internet connection and click Detect again.'; return }
        $addr = $n.PublicIp; $local = $lan
    }
    try {
        Set-RealmAddress $script:Root $addr $local '255.255.255.0'
        $script:Settings.PublicAddress = $addr; $script:Settings.LocalAddress = $local
        Save-ServerSettings $script:Root $script:Settings
        Show-Toast "Done. Friends connect to $addr. You on this PC keep working as before." 7
        Enter-Friends
    } catch { Show-Toast $_.Exception.Message 6 }
})

function Update-FirewallStatus {
    $on = Get-FirewallRulesEnabled
    $ui.FwStatus.Text = if ($on) { '✔ Firewall rules are in place (ports 3724 and 8085 allowed).' } else { 'No firewall rules yet: other computers will be blocked.' }
    $ui.FwStatus.Foreground = Get-Brush $(if ($on) { 'GoodBrush' } else { 'WarnBrush' })
}
$ui.BtnFwOn.Add_Click({
    $profileName = "$(Get-NetworkProfileName)"
    if ($profileName -eq 'Public') {
        # Many home PCs are classed "Public" by Windows; Private-only rules would silently not apply.
        $public = Confirm-Action ("Windows currently treats your network as PUBLIC, so rules for private networks would not work.`n`n" +
            "Allow the server's two ports on this network anyway? (Fine at home. On café/hotel Wi-Fi, strangers on the same network could then reach your login screen.)`n`n" +
            "Tip: you can instead mark your home network as Private in Windows Settings > Network & internet > (your connection) > Private network.") 'Firewall'
        if (-not $public) { return }
    } else { $public = $false }
    try { Set-FirewallRules $script:Root $true -AllowPublicNetworks:$public; Update-FirewallStatus; Show-Toast 'Firewall rules added.' }
    catch { Show-Toast "Could not change the firewall: $($_.Exception.Message)" 6 }
})
$ui.BtnFwOff.Add_Click({ try { Set-FirewallRules $script:Root $false; Update-FirewallStatus; Show-Toast 'Firewall rules removed.' } catch { Show-Toast $_.Exception.Message 6 } })

function Save-DiscordSettings {
    $url = $ui.TxtDiscord.Text.Trim()
    if ($url -and $url -notmatch '^https://(discord|discordapp|canary\.discord|ptb\.discord)\.com/api/webhooks/\d+/[\w-]+$') {
        Show-Message 'That does not look like a Discord webhook link. It starts with https://discord.com/api/webhooks/ - copy it from Server Settings > Integrations > Webhooks in Discord.' 'Discord' 'Warning'; return $false
    }
    $f = Join-Path $script:Root 'secrets\discord-webhook.txt'
    New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
    if ($url) { Set-Content $f $url -Encoding ascii } else { Remove-Item $f -ErrorAction SilentlyContinue }
    $script:Settings.Notify = [pscustomobject]@{ OnStartStop = [bool]$ui.ChkNotifyStart.IsChecked; OnLogin = [bool]$ui.ChkNotifyLogin.IsChecked; OnCrash = [bool]$ui.ChkNotifyCrash.IsChecked; OnUpdate = [bool]$ui.ChkNotifyUpdate.IsChecked }
    Save-ServerSettings $script:Root $script:Settings
    $true
}
$ui.BtnDiscordSave.Add_Click({
    if (Save-DiscordSettings) { Show-Toast $(if ($ui.TxtDiscord.Text.Trim()) { 'Saved. Notices start with the next server start (online/offline right away).' } else { 'Discord notifications turned off.' }) 6 }
})
$ui.BtnDiscordTest.Add_Click({
    if (-not $ui.TxtDiscord.Text.Trim()) { Show-Toast 'Paste the webhook link first.'; return }
    if (-not (Save-DiscordSettings)) { return }
    $root = $script:Root
    Start-BgTask -Script {
        param($r)
        $url = Get-DiscordWebhook $r
        Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -TimeoutSec 15 -Body ([Text.Encoding]::UTF8.GetBytes((@{ username = 'AzerothCore Control Center'; content = "✅ Test from **$((Get-ServerSettings $r).RealmName)** - notifications work!" } | ConvertTo-Json))) | Out-Null
        'ok'
    } -Arguments @($root) -OnDone { param($a, $b) if ($b) { Show-Toast "Discord did not accept it: $($b.Message)" 8 } else { Show-Toast 'Test message sent - check your Discord channel.' 6 } } | Out-Null
})
$ui.BtnFriendKit.Add_Click({
    $u = $ui.FriendUser.Text.Trim(); $p = $ui.FriendPass.Text
    if ($u -notmatch '^[A-Za-z0-9]{3,17}$') { Show-Toast 'Username: 3-17 letters or numbers.'; return }
    if ($p.Length -lt 4 -or $p -match '["''\s]') { Show-Toast 'Password: 4-16 characters, no spaces or quotes.'; return }
    $root = $script:Root
    Start-BgTask -Script {
        param($r, $u, $p)
        New-ServerAccount $r $u $p 0 | Out-Null
        $realm = Get-RealmAddress $r
        $dir = New-FriendKit $r $realm.Address $u $p (Join-Path $r "friend-kits\$u")
        [pscustomobject]@{ Dir = $dir; Address = $realm.Address }
    } -Arguments @($root, $u, $p) -OnDone {
        param($res, $err)
        if ($err) { Show-Toast "Failed: $($err.Message)" 6; return }
        $k = $res | Select-Object -Last 1
        $warn = if ($k.Address -eq '127.0.0.1') { '  ⚠ The server is still set to "Only me" - choose a connection mode above first, then make the kit again.' } else { '' }
        $ui.FriendResult.Text = "Account created. Send your friend the files in $($k.Dir) (realm address: $($k.Address)).$warn"
        Start-Process explorer.exe -ArgumentList "`"$($k.Dir)`""
    } | Out-Null
})

# ================================================================== AI chatter
function Enter-Ai {
    if (-not $script:Root) { return }
    $s = $script:Settings
    $hasModule = Test-Path (Join-Path $script:Root 'azerothcore-wotlk\modules\mod-llm-chatter')
    $ui.ChkAiEnabled.IsChecked = [bool]$s.Llm.Enabled
    $ui.ChkAiEnabled.IsEnabled = $hasModule
    $ui.AiPreset.SelectedIndex = if ($s.Llm.Preset -eq 'quieter') { 1 } else { 0 }
    $ui.AiStatus.Text = if (-not $hasModule) { 'The AI Chatter feature is not installed on this server. Add it under Updates > Modules.' }
                        elseif (-not (Find-Ollama)) { 'Ollama is not installed. It is installed automatically when you add the AI Chatter module.' }
                        else { "Current model: $($s.Llm.Model).  GPU: $($Machine.GpuName) ($($Machine.VramGB) GB)." }
    $ui.AiCatalog.Items.Clear()
    foreach ($m in $V.llmModels) { $i = New-Object Windows.Controls.ComboBoxItem; $i.Content = $m.label; $i.Tag = $m.name; [void]$ui.AiCatalog.Items.Add($i) }
    $ui.AiCatalog.SelectedIndex = 0
    Start-BgTask -Tag 'models' -Script { @(Get-OllamaModels) } -OnDone {
        param($res, $err)
        $ui.AiModel.Items.Clear()
        foreach ($m in @($res)) {
            if (-not $m) { continue }
            $i = New-Object Windows.Controls.ComboBoxItem; $i.Content = "$($m.Name)   ($($m.Size))"; $i.Tag = $m.Name
            [void]$ui.AiModel.Items.Add($i)
            if ($m.Name -eq $script:Settings.Llm.Model) { $ui.AiModel.SelectedItem = $i }
        }
    } | Out-Null
}
$ui.BtnAiTest.Add_Click({
    $m = $ui.AiModel.SelectedItem; if (-not $m) { Show-Toast 'Pick a model first.'; return }
    $ui.AiTestResult.Text = "Asking $($m.Tag) for an in-character line... (the first answer can take a while while the model loads)"
    Start-BgTask -Script { param($mod) Test-LlmModel $mod } -Arguments @($m.Tag) -OnDone {
        param($res, $err)
        $r = $res | Select-Object -Last 1
        $ui.AiTestResult.Text = if ($err) { "Test failed: $($err.Message) (is Ollama running?)" } else { '"' + $r.Reply + '"   - answered in ' + $r.Seconds + ' s' }
    } | Out-Null
})
$ui.BtnAiSave.Add_Click({
    $s = $script:Settings
    $s.Llm.Enabled = [bool]$ui.ChkAiEnabled.IsChecked
    if ($ui.AiModel.SelectedItem) { $s.Llm.Model = $ui.AiModel.SelectedItem.Tag }
    $s.Llm.Preset = $ui.AiPreset.SelectedItem.Tag
    try { Save-ServerSettings $script:Root $s; Invoke-ApplyServerConfig $script:Root | Out-Null; Show-Toast 'Saved. Restart the server to use the new AI settings.' }
    catch { Show-Toast $_.Exception.Message 6 }
})
$ui.BtnAiPull.Add_Click({
    $m = $ui.AiCatalog.SelectedItem; if (-not $m) { return }
    Start-BgTask -Overlay "Downloading AI model $($m.Tag)" -Script {
        param($model)
        $o = Find-Ollama; if (-not $o) { throw 'Ollama is not installed.' }
        Invoke-Native $o "pull $model" -Quiet -OnLine { param($l) if ($l -match '(\d+)%') { Set-Detail "Downloading: $($Matches[1])%" } } | Out-Null
        "Downloaded $model."
    } -Arguments @($m.Tag) -OnDone { param($res, $err) if (-not $err) { Show-Toast "$res Select it above and click Save."; Enter-Ai } } | Out-Null
})

# ================================================================== settings form (shared by wizard and World settings)
$RatePresets = @(
    @{ Label = '1x - original Blizzard speed'; XP = 1; Money = 1; Skill = 1; Rep = 1 },
    @{ Label = '2x - a little faster'; XP = 2; Money = 2; Skill = 2; Rep = 1.5 },
    @{ Label = '3x - faster'; XP = 3; Money = 3; Skill = 3; Rep = 2 },
    @{ Label = '5x - fast (recommended)'; XP = 5; Money = 5; Skill = 5; Rep = 3 },
    @{ Label = '10x - very fast'; XP = 10; Money = 10; Skill = 10; Rep = 5 },
    @{ Label = 'Custom (set below)'; XP = $null })

function New-Card([string]$title, [Windows.Controls.Panel]$parent) {
    $card = New-Object Windows.Controls.Border; $card.Style = $App.Resources['Card']
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Object Windows.Controls.TextBlock; $h.Text = $title; $h.Style = $App.Resources['H2']
    [void]$sp.Children.Add($h); $card.Child = $sp
    [void]$parent.Children.Add($card)
    $sp
}

function Add-Row([Windows.Controls.Panel]$card, [string]$label, [Windows.UIElement]$control, [string]$hint) {
    $g = New-Object Windows.Controls.Grid; $g.Margin = '0,5'
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '220'
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $label; $t.VerticalAlignment = 'Center'; $t.TextWrapping = 'Wrap'
    [void]$g.Children.Add($t)
    $right = New-Object Windows.Controls.StackPanel
    [void]$right.Children.Add($control)
    if ($hint) { $h = New-Object Windows.Controls.TextBlock; $h.Text = $hint; $h.Style = $App.Resources['Muted']; $h.Margin = '0,3,0,0'; [void]$right.Children.Add($h) }
    [Windows.Controls.Grid]::SetColumn($right, 1)
    [void]$g.Children.Add($right)
    [void]$card.Children.Add($g)
    $right
}

function New-Combo([string[]]$items, [int]$selected, [int]$width = 420) {
    $c = New-Object Windows.Controls.ComboBox; $c.MaxWidth = $width; $c.HorizontalAlignment = 'Left'; $c.MinWidth = 260
    foreach ($i in $items) { [void]$c.Items.Add($i) }
    $c.SelectedIndex = $selected; $c
}
function New-Text([string]$value, [int]$width = 120) { $t = New-Object Windows.Controls.TextBox; $t.Text = "$value"; $t.Width = $width; $t.HorizontalAlignment = 'Left'; $t }
function New-Check([string]$text, [bool]$checked) { $c = New-Object Windows.Controls.CheckBox; $c.Content = $text; $c.IsChecked = $checked; $c }

function Build-SettingsForm([Windows.Controls.Panel]$container, $s, [switch]$Wizard) {
    $container.Children.Clear()
    $f = @{}
    # ---- world
    $w = New-Card 'Your world' $container
    $f.Realm = New-Text $s.RealmName 320; $f.Realm.MaxLength = 30
    Add-Row $w 'Server name' $f.Realm 'Shown on the realm list.' | Out-Null
    $f.Expansion = New-Combo @('Classic / Vanilla (level 60, no Outland or Northrend)', 'Up to The Burning Crusade (level 70, Outland)', 'Full Wrath of the Lich King (level 80)') ([int]$s.Expansion)
    Add-Row $w 'Game version' $f.Expansion 'Caps the level and which continents exist. You can raise it later for a progression feel.' | Out-Null
    $f.GameType = New-Combo @('Normal (PvE) - fight the other faction only when you choose', 'PvP - open-world PvP in contested zones') $(if ([int]$s.GameType -eq 1) { 1 } else { 0 })
    Add-Row $w 'World type' $f.GameType '' | Out-Null

    # ---- speed
    $sp = New-Card 'Speed' $container
    $presetIdx = 5
    for ($i = 0; $i -lt 5; $i++) {
        $p = $RatePresets[$i]
        if ([double]$s.Rates.XPKill -eq $p.XP -and [double]$s.Rates.Money -eq $p.Money -and [double]$s.Rates.Crafting -eq $p.Skill -and [double]$s.Rates.Reputation -eq $p.Rep) { $presetIdx = $i }
    }
    $f.Preset = New-Combo ($RatePresets | ForEach-Object { $_.Label }) $presetIdx
    Add-Row $sp 'Leveling speed' $f.Preset 'Sets all the multipliers below at once.' | Out-Null
    $rateDefs = [ordered]@{ XPKill = 'XP from kills'; XPQuest = 'XP from quests'; XPExplore = 'XP from exploring'; Money = 'Money dropped'; Crafting = 'Crafting skill-ups'; Gathering = 'Gathering skill-ups'; Weapon = 'Weapon / defense skill-ups'; Reputation = 'Reputation'; Honor = 'Honor' }
    $f.Rates = @{}
    $grid = New-Object Windows.Controls.WrapPanel; $grid.Margin = '0,6,0,0'
    foreach ($k in $rateDefs.Keys) {
        $cell = New-Object Windows.Controls.StackPanel; $cell.Width = 190; $cell.Margin = '0,4,12,4'
        $l = New-Object Windows.Controls.TextBlock; $l.Text = $rateDefs[$k]; $l.Style = $App.Resources['StatLabel']; $l.Margin = '0,0,0,3'
        $f.Rates[$k] = New-Text $s.Rates.$k 90
        [void]$cell.Children.Add($l); [void]$cell.Children.Add($f.Rates[$k]); [void]$grid.Children.Add($cell)
    }
    [void]$sp.Children.Add($grid)
    $f.Preset.Add_SelectionChanged({
        $p = $RatePresets[$f.Preset.SelectedIndex]
        if ($null -eq $p.XP) { return }
        foreach ($k in 'XPKill', 'XPQuest', 'XPExplore') { $f.Rates[$k].Text = "$($p.XP)" }
        $f.Rates.Money.Text = "$($p.Money)"
        foreach ($k in 'Crafting', 'Gathering', 'Weapon') { $f.Rates[$k].Text = "$($p.Skill)" }
        $f.Rates.Reputation.Text = "$($p.Rep)"; $f.Rates.Honor.Text = "$($p.Rep)"
    }.GetNewClosure())

    # ---- bots
    $b = New-Card 'AI players (bots)' $container
    $slider = New-Object Windows.Controls.Slider; $slider.Minimum = 0; $slider.Maximum = 2000; $slider.TickFrequency = 50; $slider.IsSnapToTickEnabled = $true
    $slider.Width = 420; $slider.HorizontalAlignment = 'Left'; $slider.Value = [int]$s.Bots
    $lbl = New-Object Windows.Controls.TextBlock; $lbl.FontWeight = 'SemiBold'; $lbl.Margin = '0,4,0,0'
    $rec = Get-RecommendedBotCount $Machine.RamGB
    $updateLbl = { $n = [int]$slider.Value; $lbl.Text = "$n bots" + $(if ($n -gt $rec * 1.5) { "   ⚠ a lot for $($Machine.RamGB) GB RAM (recommended: $rec)" } else { "   (recommended for this PC: $rec)" }) }.GetNewClosure()
    $slider.Add_ValueChanged($updateLbl); & $updateLbl
    $holder = New-Object Windows.Controls.StackPanel; [void]$holder.Children.Add($slider); [void]$holder.Children.Add($lbl)
    Add-Row $b 'Number of bots' $holder 'More bots = livelier world, more CPU and RAM.' | Out-Null
    $f.Bots = $slider
    $f.Lvl1 = New-Check 'All bots start at level 1 and level up alongside you' ([bool]$s.BotsStartAtLevel1)
    Add-Row $b 'Starting levels' $f.Lvl1 'Otherwise bots start at random levels across the whole range.' | Out-Null
    $f.Bg = New-Check 'Bots start battlegrounds on their own' ([bool]$s.BotsAutoBattlegrounds)
    Add-Row $b 'Battlegrounds' $f.Bg '' | Out-Null

    if ($Wizard) {
        # ---- modules + AI (wizard only; later managed on the Updates / AI pages)
        $m = New-Card 'Extra features' $container
        $holder = New-Object Windows.Controls.StackPanel
        [void]$m.Children.Add($holder)
        $f.Modules = Show-ModuleList $holder @($s.Modules)
        $f.Model = New-Object Windows.Controls.ComboBox; $f.Model.Width = 420; $f.Model.HorizontalAlignment = 'Left'
        foreach ($mod in $V.llmModels) { $i = New-Object Windows.Controls.ComboBoxItem; $i.Content = $mod.label; $i.Tag = $mod.name; [void]$f.Model.Items.Add($i); if ($mod.name -eq $s.Llm.Model) { $f.Model.SelectedItem = $i } }
        if (-not $f.Model.SelectedItem) { $f.Model.SelectedIndex = 0 }
        $aiHint = if ($Machine.VramGB -lt 8) { "Your graphics card has $(if ($Machine.VramGB) { "$($Machine.VramGB) GB" } else { 'an unknown amount of' }) memory; AI chatter needs an NVIDIA card with 8 GB or more." } else { "Detected $($Machine.GpuName) ($($Machine.VramGB) GB)." }
        Add-Row $m 'AI chatter model' $f.Model $aiHint | Out-Null

        # ---- performance
        $pf = New-Card 'Performance (set automatically for this PC)' $container
        $shared = Get-SharedDbPort
        $f.DbMode = New-Object Windows.Controls.ComboBox; $f.DbMode.Width = 560; $f.DbMode.HorizontalAlignment = 'Left'
        foreach ($o in @(@('shared', "Shared port $shared (recommended) - all your servers use it; starting a server swaps its database in"),
                         @('own', 'Its own port - this database can stay available while another server runs'))) {
            $i = New-Object Windows.Controls.ComboBoxItem; $i.Tag = $o[0]; $i.Content = $o[1]; [void]$f.DbMode.Items.Add($i)
        }
        $f.DbMode.SelectedIndex = if ($s.DbPortMode -eq 'own') { 1 } else { 0 }
        $f.DbPort = New-Text $(if ($s.DbPortMode -eq 'own') { $s.DbPort } else { Get-FreeDbPort }) 90; $f.DbPort.Margin = '0,6,0,0'
        $dbBox = New-Object Windows.Controls.StackPanel; [void]$dbBox.Children.Add($f.DbMode); [void]$dbBox.Children.Add($f.DbPort)
        $syncDb = { $f.DbPort.Visibility = if ($f.DbMode.SelectedItem.Tag -eq 'own') { 'Visible' } else { 'Collapsed' } }.GetNewClosure()
        $f.DbMode.Add_SelectionChanged($syncDb); & $syncDb
        Add-Row $pf 'Database port' $dbBox ('Only used inside this PC - it never needs port forwarding. Friends only ever need the game ports 3724 and 8085, ' +
            'which are the same for every server. Only one server runs at a time either way.') | Out-Null
        $f.Buffer = New-Text $s.BufferPoolGB 90; Add-Row $pf 'Database memory (GB)' $f.Buffer 'About a quarter of your RAM, max 16.' | Out-Null
    }
    $adv = New-Card 'Advanced' $container
    $f.MapThreads = New-Text $s.MapThreads 90; Add-Row $adv 'World update threads' $f.MapThreads 'How many CPU threads update the world in parallel.' | Out-Null
    if (-not $Wizard) {
        $f.Keep = New-Text $s.BackupKeep 90; Add-Row $adv 'Backups to keep' $f.Keep '' | Out-Null
    }
    $f
}

function Read-Number($tb, [string]$label, [double]$min, [double]$max) {
    $v = 0.0
    if (-not [double]::TryParse($tb.Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -or $v -lt $min -or $v -gt $max) {
        throw "'$label' must be a number between $min and $max."
    }
    $v
}

function Read-SettingsForm($f, $s) {
    $realm = $f.Realm.Text.Trim()
    if (-not $realm -or $realm -match "[`"'\\]") { throw 'Server name cannot be empty or contain quotes.' }
    $s.RealmName = $realm
    $s.Expansion = $f.Expansion.SelectedIndex
    $s.GameType = $(if ($f.GameType.SelectedIndex -eq 1) { 1 } else { 0 })
    foreach ($k in @($f.Rates.Keys)) { $s.Rates.$k = Read-Number $f.Rates[$k] $k 0.1 100 }
    $s.Bots = [int]$f.Bots.Value
    $s.BotsStartAtLevel1 = [bool]$f.Lvl1.IsChecked
    $s.BotsAutoBattlegrounds = [bool]$f.Bg.IsChecked
    $s.MapThreads = [int](Read-Number $f.MapThreads 'World update threads' 1 64)
    if ($f.Keep) { $s.BackupKeep = [int](Read-Number $f.Keep 'Backups to keep' 1 1000) }
    if ($f.Modules) {
        $s.Modules = @($f.Modules.Keys | Where-Object { $f.Modules[$_].IsChecked })
        $s.Llm.Enabled = $s.Modules -contains 'mod-llm-chatter'
        if (-not $s.PSObject.Properties['ConfOverrides']) { $s | Add-Member -NotePropertyName ConfOverrides -NotePropertyValue ([pscustomobject]@{}) -Force }
        Update-ModuleConfigOverrides $s $V.modules
        $s.Llm.Model = $f.Model.SelectedItem.Tag
        $s | Add-Member -NotePropertyName DbPortMode -NotePropertyValue $f.DbMode.SelectedItem.Tag -Force
        $s.DbPort = if ($s.DbPortMode -eq 'shared') { Get-SharedDbPort } else { [int](Read-Number $f.DbPort 'Database port' 1024 65000) }
        $s.BufferPoolGB = [int](Read-Number $f.Buffer 'Database memory' 1 64)
    }
    $s
}

# ================================================================== world settings page
function Enter-Settings {
    if (-not $script:Root) { return }
    $script:Settings = Get-ServerSettings $script:Root
    $script:SettingsFields = Build-SettingsForm $ui.SettingsForm $script:Settings
    $n = 0; foreach ($t in (Get-ConfOverrideTable $script:Settings).Values) { $n += $t.Count }
    $evFile = Join-Path $script:Root 'tools\events-active.txt'
    $active = @(if (Test-Path $evFile) { Get-Content $evFile | Where-Object { $_.Trim() } })
    $ui.SetSubtitle.Text = "Changes are applied to the server's config files and take effect after a restart." +
        $(if ($n) { "   ·   $n extra option(s) active" } else { '' }) + $(if ($active.Count) { "   ·   event running: $($active -join ', ')" } else { '' })
}
function Save-SettingsPage([switch]$Restart) {
    try { $s = Read-SettingsForm $script:SettingsFields ($script:Settings | ConvertTo-Json -Depth 6 | ConvertFrom-Json) }
    catch { Show-Message $_.Exception.Message 'Please check the settings' 'Warning'; return }
    try {
        Save-ServerSettings $script:Root $s
        Invoke-ApplyServerConfig $script:Root | Out-Null
        Invoke-ServerSql $script:Root "UPDATE realmlist SET name=$(ConvertTo-SqlString $s.RealmName), icon=$(if ($s.GameType -eq 1) { 1 } else { 0 }) WHERE id=1;" | Out-Null
        # Accounts carry their own expansion level; keep them in step with the game version (progression).
        if ([int]$s.Expansion -ne [int]$script:Settings.Expansion) {
            Invoke-ServerSql $script:Root "UPDATE account SET expansion=$([int]$s.Expansion);" | Out-Null
        }
        $script:Settings = $s
        Register-Server $script:Root $s.RealmName
        Update-ServerList $script:Root
    } catch { Show-Message "Saving failed: $($_.Exception.Message)" 'Error' 'Error'; return }
    if ($Restart) {
        $root = $script:Root
        if ((Get-ServerProcessInfo $root 'worldserver')) { Invoke-StopServer { Start-GameServer $root; Show-Toast 'Settings saved, server restarting.' }.GetNewClosure() }
        else { Start-GameServer $root; Show-Toast 'Settings saved, server starting.' }
    } else { Show-Toast 'Settings saved. They take effect the next time the server starts.' 5 }
}
$ui.BtnSetSave.Add_Click({ Save-SettingsPage })
$ui.BtnSetSaveRestart.Add_Click({ Save-SettingsPage -Restart })
$ui.BtnSetOpenConf.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$(Join-Path $script:Root 'server\configs')`"" })
$ui.BtnSetExtras.Add_Click({ Show-ExtrasWindow })
$ui.BtnSetPresets.Add_Click({ Show-PresetsWindow })
$ui.BtnSetAllOptions.Add_Click({ Show-AllOptionsWindow })

# ================================================================== backups
function Enter-Backups {
    if (-not $script:Root) { return }
    $ui.BackupGrid.ItemsSource = @(Get-ServerBackups $script:Root)
    $ui.TxtBackupKeep.Text = "$($script:Settings.BackupKeep)"
    $t = Get-BackupSchedule $script:Root
    $ui.ChkBackupDaily.IsChecked = [bool]$t
    if ($t) { $ui.TxtBackupTime.Text = $t }
    $r = Get-DailyRestart $script:Root
    $ui.ChkRestartDaily.IsChecked = [bool]$r
    if ($r) { $ui.TxtRestartTime.Text = $r }
    $ui.TxtBackupCopy.Text = "$($script:Settings.BackupCopyDir)"
    Show-EventList
}
$ui.BtnRestartSchedule.Add_Click({
    if ($ui.TxtRestartTime.Text -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Show-Toast 'Time must look like 06:00 (24-hour clock).'; return }
    if ($ui.TxtRestartWarn.Text -notmatch '^\d{1,2}$') { Show-Toast 'Warning must be 0-99 minutes.'; return }
    try {
        Set-DailyRestart $script:Root ([bool]$ui.ChkRestartDaily.IsChecked) $ui.TxtRestartTime.Text ([int]$ui.TxtRestartWarn.Text)
        Show-Toast $(if ($ui.ChkRestartDaily.IsChecked) { "The server will restart daily at $($ui.TxtRestartTime.Text)." } else { 'Daily restart turned off.' })
    } catch { Show-Toast $_.Exception.Message 6 }
})

# ================================================================== game addons
function Enter-Addons {
    if (-not $script:Root) { return }
    $exe = $script:Settings.WowExe
    $ui.TxtAddonGame.Text = if ($exe) { Split-Path $exe -Parent } else { '(not set - click Change...)' }
    $ui.AddonList.Children.Clear()
    $installedModules = @(Get-ChildItem (Join-Path $script:Root 'azerothcore-wotlk\modules') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    $state = @{}
    if ($exe -and (Test-Path $exe)) { foreach ($a in Get-ClientAddonState $exe $V.addons) { $state[$a.Name] = $a.Installed } }
    foreach ($a in $V.addons) {
        $card = New-Object Windows.Controls.Border; $card.Style = $App.Resources['Card']
        $dp = New-Object Windows.Controls.DockPanel
        $btns = New-Object Windows.Controls.StackPanel; $btns.Orientation = 'Horizontal'; $btns.VerticalAlignment = 'Center'
        [Windows.Controls.DockPanel]::SetDock($btns, 'Right')
        $installed = [bool]$state[$a.name]
        $b1 = New-Object Windows.Controls.Button; $b1.Content = if ($installed) { 'Update' } else { 'Install' }; $b1.Tag = $a.name
        if (-not $installed) { $b1.Style = $App.Resources['Primary'] }
        $b1.Add_Click({
            $exe = Get-WowExe; if (-not $exe) { return }
            $addon = $V.addons | Where-Object name -eq $this.Tag
            Start-BgTask -Overlay "Installing $($addon.title)" -Script { param($e, $a) Install-ClientAddon $e $a } -Arguments @($exe, $addon) -OnDone {
                param($res, $err) if (-not $err) { Show-Toast "$res Restart WoW to load it."; Enter-Addons }
            } | Out-Null
        })
        [void]$btns.Children.Add($b1)
        if ($installed) {
            $b2 = New-Object Windows.Controls.Button; $b2.Content = 'Remove'; $b2.Tag = $a.name; $b2.Style = $App.Resources['Danger']
            $b2.Add_Click({
                $addon = $V.addons | Where-Object name -eq $this.Tag
                try { Uninstall-ClientAddon $script:Settings.WowExe $addon; Show-Toast "$($addon.title) removed."; Enter-Addons } catch { Show-Toast $_.Exception.Message 6 }
            })
            [void]$btns.Children.Add($b2)
        }
        [void]$dp.Children.Add($btns)
        $sp = New-Object Windows.Controls.StackPanel
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $a.title + $(if ($installed) { '   ✔ installed' } else { '' }); $t.FontSize = 15; $t.FontWeight = 'SemiBold'
        $d = New-Object Windows.Controls.TextBlock; $d.Text = $a.description; $d.Style = $App.Resources['Muted']; $d.Margin = '0,4,0,0'
        [void]$sp.Children.Add($t); [void]$sp.Children.Add($d)
        if ($a.module -and $installedModules -notcontains $a.module) {
            $n = New-Object Windows.Controls.TextBlock; $n.Text = "Needs the $($a.module) server module (Updates > Modules)."; $n.Foreground = Get-Brush 'WarnBrush'; $n.FontSize = 12; $n.Margin = '0,4,0,0'
            [void]$sp.Children.Add($n)
        }
        $src = New-Object Windows.Controls.TextBlock; $src.Text = "github.com/$($a.repo)"; $src.Style = $App.Resources['StatLabel']; $src.Margin = '0,4,0,0'
        [void]$sp.Children.Add($src)
        [void]$dp.Children.Add($sp)
        $card.Child = $dp
        [void]$ui.AddonList.Children.Add($card)
    }
}
$ui.BtnAddonGame.Add_Click({ if (Get-WowExe -Ask) { Enter-Addons } })
function Invoke-Backup {
    if (-not (Assert-Server)) { return }
    $root = $script:Root
    Start-BgTask -Overlay 'Backing up accounts and characters...' -Script { param($r) New-ServerBackup $r 'manual' } -Arguments @($root) -OnDone {
        param($res, $err) if (-not $err) { Show-Toast "Backup saved: $(Split-Path ($res | Select-Object -Last 1) -Leaf)" 6; if ($script:CurrentPage -eq 'Backups') { Enter-Backups } }
    } | Out-Null
}
$ui.BtnBackupNow.Add_Click({ Invoke-Backup })
$ui.BtnBackupRefresh.Add_Click({ Enter-Backups })
$ui.BtnBackupOpen.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$(Get-BackupDir $script:Root)`"" })
$ui.BtnBackupSchedule.Add_Click({
    if ($ui.TxtBackupTime.Text -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Show-Toast 'Time must look like 05:00 (24-hour clock).'; return }
    try {
        $script:Settings.BackupKeep = [int](Read-Number $ui.TxtBackupKeep 'Backups to keep' 1 1000)
        Save-ServerSettings $script:Root $script:Settings
        Set-BackupSchedule $script:Root ([bool]$ui.ChkBackupDaily.IsChecked) $ui.TxtBackupTime.Text
        Show-Toast $(if ($ui.ChkBackupDaily.IsChecked) { "Daily backup scheduled at $($ui.TxtBackupTime.Text)." } else { 'Daily backup turned off.' })
    } catch { Show-Toast $_.Exception.Message 6 }
})
$ui.BtnBackupRestore.Add_Click({
    $b = $ui.BackupGrid.SelectedItem; if (-not $b) { Show-Toast 'Select a backup first.'; return }
    if (Get-ServerProcessInfo $script:Root 'worldserver') { Show-Message 'Stop the server first (Dashboard > Stop), then restore.'; return }
    if (-not (Confirm-Action "Restore '$($b.Name)'?`n`nAll accounts, characters and bot data will go back to how they were at $($b.Date)$(if ($b.Kind -match 'Save point|Safety') { ', and so will the world' }). A safety backup of the current state is made first." 'Restore backup')) { return }
    $withSettings = $false
    if ($b.Kind -match 'Save point') { $withSettings = Confirm-Action "Also put the settings back to how they were at $($b.Date)?`n`n(speed, bots, extra settings, events... - Yes is what you want to fully undo an experiment)" 'Restore save point' }
    $root = $script:Root
    Start-BgTask -Overlay "Restoring $($b.Name)..." -Script { param($r, $z, $set) Restore-ServerBackup $r $z -RestoreSettings:$set; 'ok' } -Arguments @($root, $b.File, $withSettings) -OnDone {
        param($res, $err) if (-not $err) { Show-Toast 'Backup restored.'; $script:Settings = Get-ServerSettings $script:Root; Enter-Backups }
    } | Out-Null
})
$ui.BtnSavePoint.Add_Click({
    if (-not (Assert-Server)) { return }
    $root = $script:Root
    Start-BgTask -Overlay 'Creating a save point (everything)...' -Script { param($r) New-ServerBackup $r 'savepoint' -IncludeWorld } -Arguments @($root) -OnDone {
        param($res, $err) if (-not $err) { Show-Toast 'Save point created. Restore it any time from the list below.' 6; if ($script:CurrentPage -eq 'Backups') { Enter-Backups } }
    } | Out-Null
})
$ui.BtnBackupDelete.Add_Click({
    $b = $ui.BackupGrid.SelectedItem; if (-not $b) { Show-Toast 'Select a backup first.'; return }
    if (-not (Confirm-Action "Delete the backup '$($b.Name)' ($($b.SizeMB) MB)? This cannot be undone." 'Delete backup')) { return }
    try { Remove-ServerBackup $script:Root $b.File; Show-Toast 'Backup deleted.'; Enter-Backups } catch { Show-Toast $_.Exception.Message 6 }
})
$ui.BtnBackupCopyDir.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Where should copies of the backups go? (another drive, a USB disk, or a OneDrive / Google Drive / Dropbox folder)'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    if ($dlg.SelectedPath.StartsWith($script:Root, [StringComparison]::OrdinalIgnoreCase)) { Show-Message 'Choose a folder outside the server folder - the point is to have a copy somewhere else.'; return }
    $script:Settings.BackupCopyDir = $dlg.SelectedPath; Save-ServerSettings $script:Root $script:Settings
    $ui.TxtBackupCopy.Text = $dlg.SelectedPath
    Show-Toast 'Every new backup is now also copied there.'
})
$ui.BtnBackupCopyClear.Add_Click({ $script:Settings.BackupCopyDir = ''; Save-ServerSettings $script:Root $script:Settings; $ui.TxtBackupCopy.Text = ''; Show-Toast 'Backups are no longer copied elsewhere.' })

# ---- events (double XP weekend, ...)
$DayNames = 'Every day', 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'   # index 0 = -1 (every day)
$EventTemplates = [ordered]@{
    'Double XP weekend'   = @{ Kind = 'xp'; Multiplier = 2; StartDay = 5; StartTime = '18:00'; EndDay = 1; EndTime = '06:00' }
    'Double loot weekend' = @{ Kind = 'loot'; Multiplier = 2; StartDay = 5; StartTime = '18:00'; EndDay = 1; EndTime = '06:00' }
    'Honor week'          = @{ Kind = 'honor'; Multiplier = 2; StartDay = 1; StartTime = '00:00'; EndDay = 0; EndTime = '23:59' }
    'Happy hour'          = @{ Kind = 'xp'; Multiplier = 3; StartDay = -1; StartTime = '20:00'; EndDay = -1; EndTime = '22:00' }
    'Gold rush'           = @{ Kind = 'gold'; Multiplier = 2; StartDay = 6; StartTime = '00:00'; EndDay = 0; EndTime = '23:59' }
    'Crafting festival'   = @{ Kind = 'skill'; Multiplier = 3; StartDay = 0; StartTime = '00:00'; EndDay = 1; EndTime = '00:00' }
}

function New-EventRow($e) {
    $row = New-Object Windows.Controls.Border; $row.Background = '#191C25'; $row.CornerRadius = 8; $row.Padding = '12,8'; $row.Margin = '0,0,0,8'
    $wp = New-Object Windows.Controls.WrapPanel
    $on = New-Object Windows.Controls.CheckBox; $on.IsChecked = [bool]$e.Enabled; $on.VerticalAlignment = 'Center'; $on.Margin = '0,0,10,0'; $on.ToolTip = 'On / off'
    $name = New-Object Windows.Controls.TextBox; $name.Text = $e.Name; $name.Width = 170; $name.Margin = '0,0,10,0'; $name.MaxLength = 40
    $kind = New-Object Windows.Controls.ComboBox; $kind.Width = 165; $kind.Margin = '0,0,6,0'
    foreach ($k in $EventKinds.Keys) { $i = New-Object Windows.Controls.ComboBoxItem; $i.Content = $EventKinds[$k]; $i.Tag = $k; [void]$kind.Items.Add($i); if ($k -eq $e.Kind) { $kind.SelectedItem = $i } }
    $mult = New-Object Windows.Controls.TextBox; $mult.Text = "$($e.Multiplier)"; $mult.Width = 46; $mult.Margin = '0,0,4,0'; $mult.ToolTip = 'Multiplier, e.g. 2 = double'
    $x = New-Object Windows.Controls.TextBlock; $x.Text = '×   from'; $x.VerticalAlignment = 'Center'; $x.Margin = '0,0,8,0'
    $sd = New-Object Windows.Controls.ComboBox; $sd.Width = 115; $sd.Margin = '0,0,6,0'; foreach ($d in $DayNames) { [void]$sd.Items.Add($d) }; $sd.SelectedIndex = [int]$e.StartDay + 1
    $st = New-Object Windows.Controls.TextBox; $st.Text = $e.StartTime; $st.Width = 58; $st.Margin = '0,0,8,0'
    $to = New-Object Windows.Controls.TextBlock; $to.Text = 'until'; $to.VerticalAlignment = 'Center'; $to.Margin = '0,0,8,0'
    $ed = New-Object Windows.Controls.ComboBox; $ed.Width = 115; $ed.Margin = '0,0,6,0'; foreach ($d in $DayNames) { [void]$ed.Items.Add($d) }; $ed.SelectedIndex = [int]$e.EndDay + 1
    $et = New-Object Windows.Controls.TextBox; $et.Text = $e.EndTime; $et.Width = 58; $et.Margin = '0,0,10,0'
    $state = New-Object Windows.Controls.TextBlock; $state.VerticalAlignment = 'Center'; $state.Margin = '0,0,10,0'; $state.FontSize = 12
    $del = New-Object Windows.Controls.Button; $del.Content = '✕'; $del.Padding = '8,3'; $del.ToolTip = 'Remove this event'
    $del.Add_Click({ [void]$ui.EventList.Children.Remove($row) }.GetNewClosure())
    # Keep "every day" consistent on both ends.
    $sd.Add_SelectionChanged({ if ($sd.SelectedIndex -eq 0) { $ed.SelectedIndex = 0 } elseif ($ed.SelectedIndex -eq 0) { $ed.SelectedIndex = $sd.SelectedIndex } }.GetNewClosure())
    $ed.Add_SelectionChanged({ if ($ed.SelectedIndex -eq 0) { $sd.SelectedIndex = 0 } elseif ($sd.SelectedIndex -eq 0) { $sd.SelectedIndex = $ed.SelectedIndex } }.GetNewClosure())
    foreach ($c in $on, $name, $kind, $mult, $x, $sd, $st, $to, $ed, $et, $state, $del) { [void]$wp.Children.Add($c) }
    $row.Child = $wp
    $row.Tag = @{ On = $on; Name = $name; Kind = $kind; Mult = $mult; StartDay = $sd; StartTime = $st; EndDay = $ed; EndTime = $et; State = $state }
    if ($e.Enabled -and (Test-EventActive $e (Get-Date))) { $state.Text = '● running now'; $state.Foreground = Get-Brush 'GoodBrush' }
    $row
}

function Read-EventRows {
    $list = @()
    foreach ($row in $ui.EventList.Children) {
        $t = $row.Tag
        $name = $t.Name.Text.Trim()
        if (-not $name -or $name -match '["\\]') { throw 'Every event needs a name (no quotes).' }
        $m = 0.0
        if (-not [double]::TryParse($t.Mult.Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$m) -or $m -lt 0.1 -or $m -gt 20) { throw "'$name': the multiplier must be a number from 0.1 to 20." }
        foreach ($tm in $t.StartTime.Text, $t.EndTime.Text) { if ($tm -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw "'$name': times must look like 18:00." } }
        $list += [pscustomobject]@{
            Name = $name; Kind = $t.Kind.SelectedItem.Tag; Multiplier = $m; Enabled = [bool]$t.On.IsChecked
            StartDay = $t.StartDay.SelectedIndex - 1; StartTime = $t.StartTime.Text; EndDay = $t.EndDay.SelectedIndex - 1; EndTime = $t.EndTime.Text
        }
    }
    $list
}

function Show-EventList {
    $ui.EventList.Children.Clear()
    foreach ($e in @($script:Settings.Events)) { [void]$ui.EventList.Children.Add((New-EventRow $e)) }
    $active = @(Get-ActiveEventNames $script:Settings)
    $sched = Get-EventSchedule $script:Root
    $ui.EventStatus.Text = if (-not $ui.EventList.Children.Count) { 'No events yet. Click "Add event" and pick one to start with.' }
                           elseif (-not $sched -and @($script:Settings.Events | Where-Object Enabled).Count) { 'Click "Save events" to switch the automatic timing on.' }
                           elseif ($active.Count) { "Running now: $($active -join ', '). Events switch on and off by themselves (checked every 15 minutes)." }
                           else { 'Events switch on and off by themselves (checked every 15 minutes).' }
}

$eventMenu = New-Object Windows.Controls.ContextMenu
foreach ($k in @($EventTemplates.Keys) + 'Custom event') {
    $mi = New-Object Windows.Controls.MenuItem; $mi.Header = $k
    $mi.Add_Click({
        $t = $EventTemplates[$this.Header]
        if (-not $t) { $t = @{ Kind = 'xp'; Multiplier = 2; StartDay = 5; StartTime = '18:00'; EndDay = 0; EndTime = '23:59' } }
        $name = if ($EventTemplates.Contains($this.Header)) { $this.Header } else { 'My event' }
        $e = [pscustomobject]@{ Name = $name; Kind = $t.Kind; Multiplier = $t.Multiplier; StartDay = $t.StartDay; StartTime = $t.StartTime; EndDay = $t.EndDay; EndTime = $t.EndTime; Enabled = $true }
        [void]$ui.EventList.Children.Add((New-EventRow $e))
        $ui.EventStatus.Text = 'Adjust it if you like, then click "Save events".'
    })
    [void]$eventMenu.Items.Add($mi)
}
$ui.BtnEventAdd.ContextMenu = $eventMenu
$ui.BtnEventAdd.Add_Click({ $eventMenu.PlacementTarget = $ui.BtnEventAdd; $eventMenu.IsOpen = $true })
$ui.BtnEventSave.Add_Click({
    try { $events = @(Read-EventRows) } catch { Show-Message $_.Exception.Message 'Events' 'Warning'; return }
    $root = $script:Root
    try {
        $before = @(Get-ActiveEventNames $script:Settings)
        $script:Settings | Add-Member -NotePropertyName Events -NotePropertyValue $events -Force
        Save-ServerSettings $root $script:Settings
        Invoke-ApplyServerConfig $root | Out-Null
        Set-EventSchedule $root $ToolDir ([bool]@($events | Where-Object Enabled).Count)
        $now = @(Get-ActiveEventNames $script:Settings)
        if ((Get-ServerProcessInfo $root 'worldserver') -and (($before -join '|') -ne ($now -join '|'))) {
            Start-BgTask -Script {
                param($r, $b, $n)
                Invoke-ServerSoap $r 'reload config' | Out-Null
                foreach ($e in $n | Where-Object { $b -notcontains $_ }) { Invoke-ServerSoap $r "announce $e has started! Enjoy." | Out-Null }
                foreach ($e in $b | Where-Object { $n -notcontains $_ }) { Invoke-ServerSoap $r "announce $e is over. Thanks for playing!" | Out-Null }
            } -Arguments @($root, $before, $now) | Out-Null
        }
        Show-Toast 'Events saved.' ; Show-EventList
    } catch { Show-Message "Saving the events failed: $($_.Exception.Message)" 'Events' 'Error' }
})

# ================================================================== updates & modules
function Enter-Updates {
    if (-not $script:Root) { return }
    $root = $script:Root
    $installed = @(Get-ChildItem (Join-Path $root 'azerothcore-wotlk\modules') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    if (-not $installed.Count) { $installed = @($script:Settings.Modules) }
    $script:ModuleBoxes = Show-ModuleList $ui.ModuleToggles $installed
    $hasSource = Test-Path (Join-Path $root 'azerothcore-wotlk\.git')
    $ui.UpdNoSource.Visibility = if ($hasSource) { 'Collapsed' } else { 'Visible' }
    $ui.UpdGrid.Visibility = if ($hasSource) { 'Visible' } else { 'Collapsed' }
    $ui.BtnUpdCheck.IsEnabled = $hasSource
    $ui.BtnModulesApply.IsEnabled = $hasSource
    $ui.BtnRecompile.IsEnabled = $hasSource; $ui.BtnRecompileClean.IsEnabled = $hasSource
    $ui.ChkUpdPinned.IsChecked = [bool]$script:Settings.UpdatePinned
    # automatic updates
    if (-not $ui.CmbAutoUpdateDay.Items.Count) { foreach ($d in 'Daily', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') { [void]$ui.CmbAutoUpdateDay.Items.Add($d) } }
    $au = Get-AutoUpdate $root
    $ui.ChkAutoUpdate.IsChecked = [bool]$au
    $ui.CmbAutoUpdateDay.SelectedItem = if ($au) { $au.Day } else { 'Sunday' }
    if ($au) { $ui.TxtAutoUpdateTime.Text = $au.Time }
    # notice from the last automatic update
    $notice = Join-Path $root 'tools\update-notice.json'
    if (Test-Path $notice) {
        try { $n = Get-Content $notice -Raw | ConvertFrom-Json; $ui.UpdNoticeText.Text = "$(([datetime]$n.Date).ToString('yyyy-MM-dd HH:mm')): $($n.Message)"; $ui.UpdNotice.Visibility = 'Visible' } catch {}
    } else { $ui.UpdNotice.Visibility = 'Collapsed' }
    Update-SafetyCopies
    # Check automatically the first time the page is opened for a server.
    if ($hasSource -and $script:UpdCheckedFor -ne $root) { $script:UpdCheckedFor = $root; Invoke-UpdateCheck }
    elseif (-not $hasSource) { $ui.UpdSummary.Text = '' }
}

function New-ModuleCheckBox($m, [bool]$checked) {
    $cb = New-Object Windows.Controls.CheckBox; $cb.Margin = '0,5'; $cb.VerticalContentAlignment = 'Top'
    $tb = New-Object Windows.Controls.TextBlock; $tb.TextWrapping = 'Wrap'
    $tb.Inlines.Add((New-Object Windows.Documents.Bold (New-Object Windows.Documents.Run $m.title)))
    $tb.Inlines.Add((New-Object Windows.Documents.Run (' - ' + $m.description)))
    if ($m.note) { $n = New-Object Windows.Documents.Run ("  " + $m.note); $n.Foreground = Get-Brush 'WarnBrush'; $n.FontSize = 12; $tb.Inlines.Add($n) }
    $cb.Content = $tb; $cb.ToolTip = $m.repo
    $cb.IsChecked = $checked -or $m.required; $cb.IsEnabled = -not $m.required
    $cb
}

function Show-ModuleList([Windows.Controls.Panel]$Panel, [string[]]$Checked) {
    # Built-in modules first, then the optional community modules under their own heading. Returns name -> CheckBox.
    $Panel.Children.Clear()
    $boxes = @{}
    $shownHeader = $false
    foreach ($m in $V.modules) {
        if ($m.community -and -not $shownHeader) {
            $h = New-Object Windows.Controls.TextBlock; $h.Text = 'MORE MODULES (made by the AzerothCore community, compiled and tested with this app)'
            $h.Style = $App.Resources['StatLabel']; $h.Margin = '0,14,0,4'
            [void]$Panel.Children.Add($h); $shownHeader = $true
        }
        $cb = New-ModuleCheckBox $m (@($Checked) -contains $m.name)
        [void]$Panel.Children.Add($cb); $boxes[$m.name] = $cb
    }
    $boxes
}

function Update-SafetyCopies {
    $root = $script:Root
    $ui.SafetyGrid.ItemsSource = @(Get-SafetyCopies $root)
    $h = @(Get-UpdateHistory $root | Select-Object -Last 5)
    $ui.UpdHistory.Text = if ($h.Count) { 'Recent: ' + (($h | ForEach-Object { "$(([datetime]$_.Date).ToString('MM-dd HH:mm')) $($_.Result)$(if ($_.Detail) { " ($($_.Detail))" })" }) -join '   ·   ') } else { 'No updates installed with the app yet.' }
}

$ui.BtnUpdCheck.Add_Click({ Invoke-UpdateCheck })
function Invoke-UpdateCheck {
    $root = $script:Root
    $ui.UpdGrid.ItemsSource = $null; $ui.UpdChanges.Text = ''
    $ui.UpdSummary.Text = 'Checking for updates...'
    Start-BgTask -Tag 'updcheck' -Script { param($r) @(Get-UpdateStatus $r) } -Arguments @($root) -OnDone {
        param($res, $err)
        if ($err) { $ui.UpdSummary.Text = "Could not check: $($err.Message)"; return }
        $rows = foreach ($x in @($res | Where-Object { $_.Name })) {
            $u = [UpdRow]::new()
            $u.Id = $x.Id; $u.Name = $x.Name; $u.Current = $x.Current; $u.NewCommits = $x.NewCommits; $u.Notes = $x.Notes; $u.Latest = $x.Latest
            $u.Changes = @($x.Changes); $u.HasChanges = $x.NewCommits -gt 0; $u.Include = $u.HasChanges
            $u
        }
        # Components with new changes first (core stays first among equals).
        $rows = @($rows | Sort-Object @{ e = { -not $_.HasChanges } }, @{ e = { $_.Id -ne 'core' } }, Name)
        $ui.UpdGrid.ItemsSource = $rows
        $n = ($rows | Measure-Object NewCommits -Sum).Sum
        $comp = @($rows | Where-Object HasChanges).Count
        $ui.UpdSummary.Text = if ((Get-AppVar Settings).UpdatePinned) { 'This server is pinned to its current version (see Automatic updates below).' }
                              elseif ($n -gt 0) { "$n new change(s) in $comp component(s). Untick anything you don't want, then click 'Update selected'." }
                              else { '✔ Everything is up to date.' }
        Set-UpdateBadge $root ($n -gt 0)
        $first = $rows | Where-Object HasChanges | Select-Object -First 1
        if ($rows.Count) { $ui.UpdGrid.SelectedIndex = if ($first) { [array]::IndexOf($rows, $first) } else { 0 } }
    }.GetNewClosure() | Out-Null
}
$ui.UpdGrid.Add_SelectionChanged({
    $r = $ui.UpdGrid.SelectedItem
    $ui.UpdChanges.Text = if ($r -is [UpdRow]) {
        if ($r.Changes.Count) { ($r.Changes -join "`r`n") + $(if ($r.NewCommits -gt $r.Changes.Count) { "`r`n... and $($r.NewCommits - $r.Changes.Count) more" } else { '' }) } else { 'No new changes.' }
    } else { '' }
})

function Set-UpdateBadge([string]$Root, [bool]$Available) {
    # Remembers the result so the sidebar and the server cards can show "update available" without checking again.
    try { [pscustomobject]@{ Date = (Get-Date -Format 's'); Available = $Available } | ConvertTo-Json | Set-Content (Join-Path $Root 'tools\update-check.json') -Encoding utf8 } catch {}
    if ($Root -eq $script:Root) { $ui.NavUpdates.Content = if ($Available) { '⟳  Updates  •' } else { '⟳  Updates' } }
}

function Start-SafeUpdate([string[]]$Components) {
    $root = $script:Root
    $warn = if ($ui.TxtUpdWarn.Text -match '^\d{1,2}$') { [int]$ui.TxtUpdWarn.Text } else { 5 }
    Start-BgTask -Overlay "Updating $($script:Settings.RealmName)" -Hideable -Cancellable -Script {
        param($r, $tool, $comp, $w)
        Invoke-SafeUpdate -Root $r -ToolDirectory $tool -Components $comp -WarnMinutes $w
    } -Arguments @($root, $ToolDir, $Components, $warn) -OnDone {
        param($res, $err)
        Set-AppVar UpdCheckedFor $null
        if ($err) { if ((Get-AppVar CurrentPage) -eq 'Updates') { Enter-Updates }; return }
        $r = $res | Select-Object -Last 1
        if ($r.Ok) { Show-Toast "✔ $($r.Message)" 8; Show-Message "$($r.Message)`n`nThe new version is running fine. A safety copy of the previous version is kept on the Updates page - once you've played and everything is good, you can delete it there." 'Update finished' }
        elseif ($r.RolledBack) { Show-Message "The update did not work: $($r.Message)`n`nEverything was put back exactly as it was before (programs, settings and characters). Nothing is lost. The full log is in:`n$($r.Log)" 'Update rolled back' 'Warning' }
        elseif ($r.Message -eq 'COMPILE_FAILED') { Resolve-UpdateCompileFailure $Components @($r.Failing) $r.Log }
        if ((Get-AppVar CurrentPage) -eq 'Updates') { Enter-Updates }
    }.GetNewClosure() | Out-Null
}

function Start-Recompile([switch]$Clean) {
    $root = $script:Root
    $running = [bool](Get-ServerProcessInfo $root 'worldserver')
    $warn = if ($ui.TxtUpdWarn.Text -match '^\d{1,2}$') { [int]$ui.TxtUpdWarn.Text } else { 5 }
    $msg = $(if ($Clean) { "Recompile '$($script:Settings.RealmName)' from scratch?`n`nA fresh build folder is used and everything is compiled again (30-90 minutes). The old build folder is kept until the new one works.`n`n" }
             else { "Recompile '$($script:Settings.RealmName)'?`n`nOnly what is needed is compiled again (usually a few minutes).`n`n" }) +
        '1.  It compiles while the server ' + $(if ($running) { 'keeps running' } else { 'stays off' }) + ".`n" +
        '2.  ' + $(if ($running) { "Players get a $warn-minute warning, then the server stops." } else { 'The server is started once to check the result.' }) + "`n" +
        "3.  A complete safety copy is saved, the new programs are put in place and checked - with automatic rollback if anything is wrong.`n`nStart now?"
    if (-not (Confirm-Action $msg 'Recompile')) { return }
    $title = if ($Clean) { "Clean recompile of $($script:Settings.RealmName)" } else { "Recompiling $($script:Settings.RealmName)" }
    Start-BgTask -Overlay $title -Hideable -Cancellable -Script {
        param($r, $tool, $w, $cl)
        Invoke-SafeUpdate -Root $r -ToolDirectory $tool -Rebuild -Clean:$cl -WarnMinutes $w
    } -Arguments @($root, $ToolDir, $warn, [bool]$Clean) -OnDone {
        param($res, $err)
        if ($err) { if ((Get-AppVar CurrentPage) -eq 'Updates') { Enter-Updates }; return }
        $r = $res | Select-Object -Last 1
        if ($r.Ok) { Show-Toast "✔ $($r.Message)" 8 }
        elseif ($r.RolledBack) { Show-Message "The recompiled server did not work: $($r.Message)`n`nEverything was put back as it was before. Nothing is lost. Log:`n$($r.Log)" 'Recompile rolled back' 'Warning' }
        elseif ($r.Message -eq 'COMPILE_FAILED') {
            $parts = @($r.Failing | ForEach-Object { if ($ModuleTitles[$_]) { "$($ModuleTitles[$_]) ($_)" } elseif ($_ -eq 'core') { 'AzerothCore itself' } else { $_ } })
            Show-Message ("The server does not compile$(if ($parts) { " - the problem is in: $($parts -join ', ')" }).`n`nNothing was changed; your server runs exactly as before.`n`n" +
                "Try 'Check & repair' on the Dashboard, a clean recompile, or switch the named module off under Modules.`n`nLog: $($r.Log)") 'Recompile failed' 'Warning'
        }
        if ((Get-AppVar CurrentPage) -eq 'Updates') { Enter-Updates }
    }.GetNewClosure() | Out-Null
}

function Resolve-UpdateCompileFailure([string[]]$Components, [string[]]$Failing, [string]$Log) {
    $mods = @($Failing | Where-Object { $_ -ne 'core' })
    if (-not $mods.Count) {
        Show-Message "The new AzerothCore version doesn't compile right now. This happens now and then while its developers are in the middle of a change, and is usually fixed within a day or two.`n`nNothing was changed - your server is exactly as before. Try again later.`n`nLog: $Log" 'Update not possible yet' 'Warning'
        return
    }
    $names = ($mods | ForEach-Object { if ($ModuleTitles[$_]) { "$($ModuleTitles[$_]) ($_)" } else { $_ } }) -join ', '
    $buttons = @("Update without $($mods -join ', ') (switched off until it is fixed)")
    $coreOnlyPossible = $Components -contains 'core'
    if ($coreOnlyPossible) { $buttons += 'Keep AzerothCore as it is, only update the modules' }
    $buttons += 'Cancel - keep everything as it is'
    $c = Show-Choice 'A module is not ready for this update' ("$names does not work with the newest AzerothCore yet (it doesn't compile). Its author usually catches up within days.`n`nNothing was changed so far - your server runs exactly as before. What would you like to do?") $buttons
    if ($c -eq 0) {
        if (-not (Confirm-Action "Switch off $names and update the rest?`n`nYou can switch it back on later under Updates > Modules once it has been fixed." 'Update')) { return }
        foreach ($m in $mods) { Disable-ServerModule $script:Root $m }
        $script:Settings = Get-ServerSettings $script:Root
        Start-SafeUpdate @($Components | Where-Object { $mods -notcontains $_ })
    } elseif ($coreOnlyPossible -and $c -eq 1) {
        $rest = @($Components | Where-Object { $_ -ne 'core' })
        if (-not $rest.Count) { Show-Toast 'Only AzerothCore itself had changes - nothing else to update.'; return }
        Start-SafeUpdate $rest
    }
}

$ui.BtnRecompile.Add_Click({ if (Assert-Server) { Start-Recompile } })
$ui.BtnRecompileClean.Add_Click({ if (Assert-Server) { Start-Recompile -Clean } })
$ui.BtnRepair.Add_Click({
    if (-not (Assert-Server)) { return }
    if (Show-RepairWindow $script:Root) { $script:Settings = Get-ServerSettings $script:Root }
})

$ui.BtnUpdApply.Add_Click({
    if ($script:Settings.UpdatePinned) { Show-Message 'This server is pinned to its current version. Untick "Pin this server" below to update it.'; return }
    $rows = @($ui.UpdGrid.ItemsSource | Where-Object { $_ -is [UpdRow] -and $_.Include -and $_.HasChanges })
    if (-not $rows.Count) { Show-Toast 'Nothing selected - check for updates first, or tick a component.'; return }
    $running = [bool](Get-ServerProcessInfo $script:Root 'worldserver')
    $warn = if ($ui.TxtUpdWarn.Text -match '^\d{1,2}$') { [int]$ui.TxtUpdWarn.Text } else { 5 }
    $sql = @($rows | Where-Object { $_.Notes -match 'database' }).Count
    $msg = "Update $(($rows | ForEach-Object Name) -join ', ')?`n`n" +
        '1.  The new version compiles while the server ' + $(if ($running) { 'keeps running' } else { 'stays off' }) + " (about 10-60 minutes).`n" +
        '2.  ' + $(if ($running) { "Players get a $warn-minute warning, then the server stops." } else { 'The server is started once to check the new version.' }) + "`n" +
        "3.  A complete safety copy is saved (characters, world and the current programs).`n" +
        "4.  The new version starts and is checked. If anything is wrong, everything is put back automatically.`n`n" +
        $(if ($sql) { "Includes database changes - they are covered by the safety copy.`n`n" } else { '' }) +
        'You can keep using the app meanwhile. Start now?'
    if (-not (Confirm-Action $msg 'Safe update')) { return }
    Start-SafeUpdate @($rows | ForEach-Object Id)
})

$ui.BtnRollback.Add_Click({
    $c = $ui.SafetyGrid.SelectedItem; if (-not $c) { Show-Toast 'Select a safety copy first.'; return }
    if ($c.Result -eq 'rolled back') { Show-Message 'That update was already rolled back.'; return }
    $newest = @(Get-SafetyCopies $script:Root)[0]
    $extra = if ($newest.Path -ne $c.Path) { "`n`nThis is not the newest update: later updates are undone too." } else { '' }
    if (-not (Confirm-Action "Go back to the version from before the update of $($c.Date) ($($c.From))?`n`nPrograms, settings and ALL databases return to how they were just before that update - characters lose any progress made since then.$extra" 'Go back')) { return }
    $root = $script:Root; $running = [bool](Get-ServerProcessInfo $root 'worldserver')
    Start-BgTask -Overlay 'Going back to the previous version' -Script {
        param($r, $copy, $start) Invoke-UpdateRollback -Root $r -SafetyCopy $copy -StartAfter:$start; 'ok'
    } -Arguments @($root, $c.Path, $running) -OnDone { param($a, $b) if (-not $b) { Show-Toast 'Back on the previous version.' 6 }; $script:UpdCheckedFor = $null; Enter-Updates } | Out-Null
})
$ui.BtnSafetyDelete.Add_Click({
    $c = $ui.SafetyGrid.SelectedItem; if (-not $c) { Show-Toast 'Select a safety copy first.'; return }
    if (-not (Confirm-Action "Delete the safety copy from $($c.Date) ($($c.SizeMB) MB)?`n`nYou won't be able to go back to the version before that update." 'Delete safety copy')) { return }
    try { Remove-SafetyCopy $script:Root $c.Path; Show-Toast 'Safety copy deleted.'; Update-SafetyCopies } catch { Show-Toast $_.Exception.Message 6 }
})
$ui.BtnSafetyDeleteAll.Add_Click({
    $all = @(Get-SafetyCopies $script:Root); if (-not $all.Count) { Show-Toast 'There are no safety copies.'; return }
    $mb = ($all | Measure-Object SizeMB -Sum).Sum
    if (-not (Confirm-Action "Delete all $($all.Count) safety copies ($mb MB)?`n`nDo this once you're happy with the update - you won't be able to go back afterwards." 'Delete safety copies')) { return }
    foreach ($c in $all) { try { Remove-SafetyCopy $script:Root $c.Path } catch {} }
    Show-Toast "Freed $mb MB."; Update-SafetyCopies
})
$ui.BtnUpdNotice.Add_Click({ Remove-Item (Join-Path $script:Root 'tools\update-notice.json') -ErrorAction SilentlyContinue; $ui.UpdNotice.Visibility = 'Collapsed' })
$ui.ChkUpdPinned.Add_Click({
    $script:Settings.UpdatePinned = [bool]$ui.ChkUpdPinned.IsChecked
    Save-ServerSettings $script:Root $script:Settings
    Show-Toast $(if ($script:Settings.UpdatePinned) { 'Pinned: this server stays on its current version.' } else { 'Unpinned: this server can be updated again.' })
})
$ui.BtnAutoUpdateSave.Add_Click({
    if ($ui.TxtAutoUpdateTime.Text -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Show-Toast 'Time must look like 05:00 (24-hour clock).'; return }
    try {
        Set-AutoUpdate $script:Root $ToolDir ([bool]$ui.ChkAutoUpdate.IsChecked) $ui.CmbAutoUpdateDay.SelectedItem $ui.TxtAutoUpdateTime.Text
        Show-Toast $(if ($ui.ChkAutoUpdate.IsChecked) { "Updates install automatically ($($ui.CmbAutoUpdateDay.SelectedItem) at $($ui.TxtAutoUpdateTime.Text)) when nobody is playing." } else { 'Automatic updates turned off.' }) 7
    } catch { Show-Toast $_.Exception.Message 6 }
})
$ui.BtnMakeUpdatable.Add_Click({
    $missing = @(Get-PrereqStatus | Where-Object { -not $_.Installed -and $_.Need -eq 'build' })
    $extra = if ($missing.Count) { "`n`nThese build tools are installed first: $(($missing | ForEach-Object Name) -join ', ')." } else { '' }
    if (-not (Confirm-Action "Make '$($script:Settings.RealmName)' updatable?`n`nThis downloads the source code of exactly the version this server runs and compiles it once (30-90 minutes). Your characters and settings are not touched; the server can keep running meanwhile, but restart it afterwards.$extra" 'Make updatable')) { return }
    $root = $script:Root
    Start-BgTask -Overlay 'Making the server updatable' -Hideable -Cancellable -Script { param($r, $t) Invoke-MakeUpdatable $r $t; 'ok' } -Arguments @($root, $ToolDir) -OnDone {
        param($a, $b) if (-not $b) { Show-Message 'Done! This server can now be updated like any other. Restart it once to run the freshly compiled version.' 'Make updatable' }; $script:Settings = Get-ServerSettings $script:Root; Enter-Updates
    } | Out-Null
})

$ui.BtnModulesApply.Add_Click({
    if ($script:Settings.UpdatePinned) { Show-Message 'This server is pinned to its current version. Untick "Pin this server" first.'; return }
    $installed = @(Get-ChildItem (Join-Path $script:Root 'azerothcore-wotlk\modules') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    $add = @($script:ModuleBoxes.Keys | Where-Object { $script:ModuleBoxes[$_].IsChecked -and $installed -notcontains $_ })
    $remove = @($script:ModuleBoxes.Keys | Where-Object { -not $script:ModuleBoxes[$_].IsChecked -and $installed -contains $_ -and -not ($V.modules | Where-Object name -eq $_).required })
    if (-not $add.Count -and -not $remove.Count) { Show-Toast 'Nothing changed - tick or untick a module first.'; return }
    $t = { param($n) $m = $V.modules | Where-Object name -eq $n; if ($m) { $m.title } else { $n } }
    $msg = (@($add | ForEach-Object { "  + $(& $t $_)" }) + @($remove | ForEach-Object { "  - $(& $t $_) (kept aside, can be switched on again)" })) -join "`n"
    $running = [bool](Get-ServerProcessInfo $script:Root 'worldserver')
    if (-not (Confirm-Action "Apply these module changes?`n`n$msg`n`nThe server is recompiled while it " + $(if ($running) { 'keeps running' } else { 'stays off' }) + ", then restarted once with a complete safety copy. If it doesn't work, everything is put back automatically." 'Modules')) { return }
    $root = $script:Root
    $warn = if ($ui.TxtUpdWarn.Text -match '^\d{1,2}$') { [int]$ui.TxtUpdWarn.Text } else { 5 }
    Start-BgTask -Overlay "Changing modules on $($script:Settings.RealmName)" -Hideable -Cancellable -Script {
        param($r, $tool, $a, $rm, $w) Invoke-SafeUpdate -Root $r -ToolDirectory $tool -AddModules $a -RemoveModules $rm -WarnMinutes $w
    } -Arguments @($root, $ToolDir, $add, $remove, $warn) -OnDone {
        param($res, $err)
        $script:Settings = Get-ServerSettings $script:Root; $script:UpdCheckedFor = $null
        if (-not $err) {
            $r = $res | Select-Object -Last 1
            if ($r.Ok) { Show-Message "Done: the server now runs with the new set of modules.`n`nTheir options are in World settings > All options." 'Modules' }
            elseif ($r.RolledBack) { Show-Message "The new set of modules did not start properly: $($r.Message)`n`nEverything was put back as it was. Log: $($r.Log)" 'Modules' 'Warning' }
            elseif ($r.Message -eq 'COMPILE_FAILED') { Show-Message "$(if ($r.Failing) { ($r.Failing -join ', ') } else { 'A module' }) does not compile with this server's AzerothCore version, so nothing was changed.`n`nLog: $($r.Log)" 'Modules' 'Warning' }
        }
        if ($script:CurrentPage -eq 'Updates') { Enter-Updates }
    } | Out-Null
})

# ================================================================== performance
function New-UsageRow([string]$label, [double]$ramGB, [double]$cpu, [double]$maxGB) {
    $row = New-Object Windows.Controls.DockPanel; $row.Margin = '0,4'
    $l = New-Object Windows.Controls.TextBlock; $l.Text = $label; $l.Width = 210; $l.TextTrimming = 'CharacterEllipsis'
    $v = New-Object Windows.Controls.TextBlock; $v.Text = ('{0:0.0} GB   ·   CPU {1:0}%' -f $ramGB, $cpu); $v.Width = 170; $v.TextAlignment = 'Right'; $v.Foreground = Get-Brush 'MutedBrush'
    [Windows.Controls.DockPanel]::SetDock($v, 'Right')
    $bar = New-Object Windows.Controls.Border; $bar.Height = 12; $bar.CornerRadius = 3; $bar.HorizontalAlignment = 'Left'; $bar.Margin = '0,0,12,0'
    $bar.Background = Get-Brush 'AccentBrush'; $bar.Width = [math]::Max(3, 420 * $ramGB / [math]::Max(0.5, $maxGB))
    [void]$row.Children.Add($l); [void]$row.Children.Add($v); [void]$row.Children.Add($bar)
    $row
}
function Enter-Performance {
    if (-not $script:Root) { return }
    $root = $script:Root
    Start-BgTask -Tag 'perf' -Script { param($r) $snap = Get-PerformanceSnapshot $r; [pscustomobject]@{ Snap = $snap; Advice = Get-BotAdvice $snap } } -Arguments @($root) -OnDone {
        param($res, $err)
        if ($err -or (Get-AppVar Root) -ne $root -or (Get-AppVar CurrentPage) -ne 'Performance') { return }
        $p = ($res | Select-Object -Last 1); $s = $p.Snap; $a = $p.Advice
        $ui.PerfCpu.Text = "$($s.CpuPct)%"; $ui.PerfCpuHint.Text = "$($s.Cores) threads"
        $used = [math]::Round($s.RamTotalGB - $s.RamFreeGB, 1)
        $ui.PerfRam.Text = "$used / $($s.RamTotalGB) GB"; $ui.PerfRamHint.Text = "$($s.RamFreeGB) GB free" + $(if ($s.RamFreeGB -lt 4) { '  ⚠ low' } else { '' })
        if ($s.Gpu) { $ui.PerfGpu.Text = "$($s.Gpu.UsedGB) / $($s.Gpu.TotalGB) GB"; $ui.PerfGpuHint.Text = "$($s.Gpu.Name) · busy $($s.Gpu.Util)%" }
        else { $ui.PerfGpu.Text = '–'; $ui.PerfGpuHint.Text = 'No NVIDIA card found (only needed for AI chatter)' }
        $ui.PerfDisk.Text = "$($s.DiskFreeGB) GB free"; $ui.PerfDiskHint.Text = $(if ($s.DiskFreeGB -lt 15) { '⚠ getting full' } else { 'plenty of room' })
        $max = [math]::Max(1, (@($s.Server) + @($s.Others) | Measure-Object RamGB -Maximum).Maximum)
        $ui.PerfServer.Items.Clear()
        if (-not @($s.Server).Count) { $t = New-Object Windows.Controls.TextBlock; $t.Text = 'The server is not running.'; $t.Foreground = Get-Brush 'MutedBrush'; [void]$ui.PerfServer.Items.Add($t) }
        foreach ($x in @($s.Server) | Sort-Object RamGB -Descending) { [void]$ui.PerfServer.Items.Add((New-UsageRow $x.Label $x.RamGB $x.Cpu $max)) }
        $ui.PerfOthers.Items.Clear()
        foreach ($x in @($s.Others)) { [void]$ui.PerfOthers.Items.Add((New-UsageRow ($x.Label + $(if ($x.Count -gt 1) { " ($($x.Count))" } else { '' })) $x.RamGB $x.Cpu $max)) }
        $st = $s.Status
        $lines = @()
        if ($st -and $st.World -and -not $st.Starting) {
            $lines += "Right now: $($st.BotsOnline) bots online, the world updates every $($st.TickMean) ms on average (" + $(if ($st.TickMean -lt 50) { 'very smooth' } elseif ($st.TickMean -lt 100) { 'fine' } elseif ($st.TickMean -lt 150) { 'busy' } else { 'struggling' }) + ').'
            $lines += "Each bot uses about $($a.PerBotMB) MB of memory here."
        } else { $lines += 'Start the server to measure how it runs; until then this is an estimate from free memory.' }
        $lines += "Suggested for this PC right now: about $($a.Suggest) bots (you have $($s.Bots) set)."
        if ($a.Suggest -lt $s.Bots) { $lines += 'Fewer bots would make the world smoother and leave more memory for the game and other programs.' }
        $ui.PerfAdvice.Text = $lines -join "`n"
        Set-AppVar PerfSuggest $a.Suggest
        $ui.BtnPerfApply.Visibility = if ([math]::Abs($a.Suggest - $s.Bots) -ge 100) { 'Visible' } else { 'Collapsed' }
        $ui.BtnPerfApply.Content = "Use $($a.Suggest) bots (applies at the next start)"
    }.GetNewClosure() | Out-Null
}
$ui.BtnPerfApply.Add_Click({
    if (-not $script:PerfSuggest) { return }
    if (-not (Confirm-Action "Set the number of bots to $($script:PerfSuggest)? It takes effect the next time the server starts.")) { return }
    $script:Settings.Bots = [int]$script:PerfSuggest
    try { Save-ServerSettings $script:Root $script:Settings; Invoke-ApplyServerConfig $script:Root | Out-Null; Show-Toast "Bots set to $($script:PerfSuggest)." } catch { Show-Toast $_.Exception.Message 6 }
})

# ================================================================== logs
function Enter-Logs {
    if (-not $script:Root) { return }
    $sel = $ui.LogFile.SelectedItem
    $ui.LogFile.Items.Clear()
    foreach ($f in Get-ServerLogFiles $script:Root) { [void]$ui.LogFile.Items.Add($f) }
    if ($sel -and $ui.LogFile.Items.Contains($sel)) { $ui.LogFile.SelectedItem = $sel }
    elseif ($ui.LogFile.Items.Contains('Server.log')) { $ui.LogFile.SelectedItem = 'Server.log' }
    elseif ($ui.LogFile.Items.Count) { $ui.LogFile.SelectedIndex = 0 }
    Update-LogView
}
function Update-LogView {
    if (-not $ui.LogFile.SelectedItem) { $ui.LogText.Text = 'No logs yet - start the server once.'; return }
    $atEnd = $ui.LogText.VerticalOffset -ge ($ui.LogText.ExtentHeight - $ui.LogText.ViewportHeight - 30)
    $ui.LogText.Text = Get-ServerLogTail $script:Root $ui.LogFile.SelectedItem 600 $ui.LogFilter.Text
    if ($atEnd) { $ui.LogText.ScrollToEnd() }
}
$ui.LogFile.Add_SelectionChanged({ if ($script:CurrentPage -eq 'Logs') { Update-LogView; $ui.LogText.ScrollToEnd() } })
$ui.BtnLogRefresh.Add_Click({ Update-LogView })
$ui.LogFilter.Add_KeyUp({ param($s, $e) if ($e.Key -eq 'Return') { Update-LogView } })

# ================================================================== about / add existing
function Show-AppUpdateResult($info) {
    $script:AppUpdate = $info
    if (-not $info) { return }
    $ui.TxtAppUpdate.Visibility = 'Visible'
    if ($info.Newer) {
        $notes = ("$($info.Notes)" -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 8) -join "`n"
        $ui.TxtAppUpdate.Text = "Version $($info.Latest) is available (you have $($info.Current)).`n$notes`n`nTo update: download it, close this app, and unpack it over this folder (your servers live elsewhere and are not touched)."
        $ui.TxtAppUpdate.Foreground = Get-Brush 'AccentBrush'
        $ui.BtnAppDownload.Visibility = 'Visible'
        $ui.NavAbout.Content = 'ⓘ  Help & about  •'
    } else {
        $ui.TxtAppUpdate.Text = "You have the newest version ($($info.Current))."
        $ui.TxtAppUpdate.Foreground = Get-Brush 'GoodBrush'
        $ui.BtnAppDownload.Visibility = 'Collapsed'
    }
}

function Start-AppUpdateCheck([switch]$Quiet) {
    Start-BgTask -Tag 'appupdate' -Script { Get-AppUpdateInfo } -OnDone {
        param($res, $err)
        if ($err) { if (-not $Quiet) { $ui.TxtAppUpdate.Visibility = 'Visible'; $ui.TxtAppUpdate.Foreground = Get-Brush 'MutedBrush'; $ui.TxtAppUpdate.Text = "Could not check: $($err.Message)" }; return }
        $info = $res | Select-Object -Last 1
        Show-AppUpdateResult $info
        if ($Quiet -and $info.Newer) { Show-Toast "A new version of this app ($($info.Latest)) is available - see Help & about." 10 }
    }.GetNewClosure() | Out-Null
}

$ui.BtnAppUpdate.Add_Click({ $ui.TxtAppUpdate.Visibility = 'Visible'; $ui.TxtAppUpdate.Foreground = Get-Brush 'MutedBrush'; $ui.TxtAppUpdate.Text = 'Checking...'; Start-AppUpdateCheck })
$ui.BtnAppSite.Add_Click({ $r = (Get-AppInfo).repository; if ($r) { Start-Process "https://github.com/$r" } })
$ui.BtnAppDownload.Add_Click({ if ($script:AppUpdate) { Start-Process $(if ($script:AppUpdate.Url) { $script:AppUpdate.Url } else { $script:AppUpdate.Download }) } })

function Enter-About {
    $ui.TxtAppVersion.Text = "AzerothCore Control Center $((Get-AppInfo).version)  ·  github.com/$((Get-AppInfo).repository)"
    $servers = @(Get-ServerRegistry)
    $ui.AboutText.Text = @"
AzerothCore Control Center creates and manages World of Warcraft 3.3.5a (Wrath of the Lich King) servers
built on AzerothCore with the Playerbots module.

Servers known to this app: $($servers.Count)
$(($servers | ForEach-Object { "   • $($_.Name)  -  $($_.RootDir)" }) -join "`n")

EVERYDAY USE
• Dashboard: start, stop and restart; see players, bots and how smoothly the server runs.
• Always stop the server with the Stop button (or the desktop shortcut) so characters are saved.
• Console: any GM command, e.g.  tele name Bob Stormwind,  character level Bob 20,  announce Hello!

IN-GAME CHEAT SHEET (type in the chat box)
Bots
   .playerbots bot add NAME         bring one of your own alts (same account) online as a bot
   .playerbots bot addclass warrior create a bot of a class to group with (also mage, priest, ...)
   .playerbots bot remove NAME      log that bot out
   Invite any random bot you meet to your group, then say in party chat:
      follow  ·  stay  ·  attack  ·  flee  ·  summon (bring them to you)  ·  leave
   The MultiBot addon (Game addons page) gives you buttons for all of this.
Dungeon Clear (your tank must be a bot)
   .dc on  ·  .dc off  ·  .dc pause  ·  .dc skip  ·  .dc status  ·  .dc bosses  ·  .dc pull (cycle pull style)
Dungeon Master
   Talk to the Dungeon Master NPC in any capital for random dungeons and the roguelike mode.
GM basics (Game Master accounts)
   .gm on / .gm off  ·  .tele Stormwind  ·  .appear NAME  ·  .summon NAME  ·  .revive  ·  .help
Full lists: github.com/mod-playerbots/mod-playerbots/wiki  ·  azerothcore.org/wiki/gm-commands

FILES
• Settings for each server: <server>\tools\server-settings.json (edit them on the World settings page).
• Passwords created by the installer: <server>\secrets\
• Backups: <server>\backups\    Logs: <server>\server\logs\

This computer: $($Machine.CpuName), $($Machine.RamGB) GB RAM, $($Machine.GpuName).
"@
}

function Add-ExistingServer {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the server folder (the one containing START_SERVER.bat)'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $root = $dlg.SelectedPath.TrimEnd('\')
    if (Test-ServerRoot $root) {
        $name = (Get-ServerSettings $root).RealmName
        Register-Server $root $name
        Update-ServerList $root
        Show-Toast "Added $name."
        return
    }
    if (-not (Test-Path (Join-Path $root 'server\worldserver.exe'))) {
        Show-Message "No server found in that folder.`n`nChoose the folder that contains the 'server' folder (with worldserver.exe inside)." 'Add server' 'Warning'
        return
    }
    # An AzerothCore server this app did not create: detect its settings and offer to import it.
    try { $d = Import-ExistingServer -Root $root -ToolDirectory $ToolDir -DryRun }
    catch { Show-Message "This server can't be imported automatically:`n`n$($_.Exception.Message)" 'Add server' 'Warning'; return }
    $summary = @"
Found an AzerothCore server that wasn't made by this app:

   Realm: $($d.RealmName)   ($(@('Vanilla','Burning Crusade','Wrath')[$d.Expansion]), $(if ($d.GameType -eq 1) { 'PvP' } else { 'PvE' }))
   Bots: $($d.Bots)   ·   XP rate: $($d.Rates.XPKill)x
   Database: Windows service '$($d.MySqlService)' on port $($d.DbPort)
   Modules: $(@($d.Modules) -join ', ')

Import it? The app will save these settings in tools\server-settings.json and install its helper scripts
(start/stop/backup/accounts). Your current scripts are copied to tools\pre-import-backup-... first.
Config files and databases are NOT changed until you save something in World settings.
"@
    if (-not (Confirm-Action $summary 'Import server')) { return }
    try {
        Import-ExistingServer -Root $root -ToolDirectory $ToolDir | Out-Null
        Register-Server $root $d.RealmName
        Update-ServerList $root
        Show-Toast "Imported $($d.RealmName)."
    } catch { Show-Message "Import failed: $($_.Exception.Message)" 'Add server' 'Error' }
}
$ui.BtnAddExisting.Add_Click({ Add-ExistingServer })
$ui.BtnForget.Add_Click({
    if (-not $script:Root) { return }
    if (Confirm-Action "Remove '$($script:Settings.RealmName)' from this app's list?`n`nNothing is deleted from disk; you can add it back any time.") {
        Unregister-Server $script:Root; Update-ServerList
    }
})

# ================================================================== one server at a time
function Start-ServerSmart([string]$Root) {
    # Only one WoW server can own the login/game ports: offer to stop the running one first.
    $running = Get-RunningServerRoot
    if ($running -and $running -ne $Root) {
        $name = try { (Get-ServerSettings $running).RealmName } catch { $running }
        if (-not (Confirm-Action "'$name' is running right now, and only one server can run at a time.`n`nStop '$name' (saving everyone) and start this one?" 'Switch server')) { return }
        Start-BgTask -Overlay "Stopping '$name'..." -Script { param($r) Stop-GameServer $r } -Arguments @($running) -OnDone {
            param($res, $err)
            if ($err) { return }
            Start-GameServer $Root
            Show-Toast 'Switched servers - the new one is starting.' 5
            if ((Get-AppVar CurrentPage) -eq 'Servers') { Enter-Servers }
        }.GetNewClosure() | Out-Null
        return
    }
    Start-GameServer $Root
    Show-Toast 'Server starting... a console window opens. The first start can take a few minutes.' 6
}

# ================================================================== my servers (cards)
$ModuleTitles = @{}; foreach ($m in $V.modules) { $ModuleTitles[$m.name] = $m.title }
$script:SizeCache = @{}

function New-Chip([string]$text) {
    $b = New-Object Windows.Controls.Border; $b.Background = '#262B38'; $b.CornerRadius = 9; $b.Padding = '8,2'; $b.Margin = '0,4,6,0'
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $text; $t.FontSize = 11; $t.Foreground = Get-Brush 'MutedBrush'
    $b.Child = $t; $b
}

function New-ServerCard($sum) {
    $card = New-Object Windows.Controls.Border; $card.Style = $App.Resources['Card']; $card.Width = 372; $card.Margin = '7,0,7,14'
    $card.Add_MouseEnter({ $this.BorderBrush = Get-Brush 'AccentDarkBrush' })
    $card.Add_MouseLeave({ $this.BorderBrush = Get-Brush 'BorderBrush' })
    $sp = New-Object Windows.Controls.StackPanel

    $head = New-Object Windows.Controls.DockPanel
    $pill = New-Object Windows.Controls.Border; $pill.CornerRadius = 9; $pill.Padding = '9,2'; $pill.VerticalAlignment = 'Center'
    $pill.Background = if ($sum.Running) { '#1F3A2C' } else { '#2A2F3C' }
    $pt = New-Object Windows.Controls.TextBlock; $pt.FontSize = 11; $pt.Text = if ($sum.Running) { '● Online' } else { 'Offline' }
    $pt.Foreground = Get-Brush $(if ($sum.Running) { 'GoodBrush' } else { 'MutedBrush' }); $pill.Child = $pt
    [Windows.Controls.DockPanel]::SetDock($pill, 'Right'); [void]$head.Children.Add($pill)
    $name = New-Object Windows.Controls.TextBlock; $name.Text = $sum.Name; $name.FontSize = 18; $name.FontWeight = 'SemiBold'; $name.TextTrimming = 'CharacterEllipsis'
    [void]$head.Children.Add($name); [void]$sp.Children.Add($head)

    $line = New-Object Windows.Controls.TextBlock; $line.Margin = '0,6,0,0'; $line.Foreground = Get-Brush 'AccentBrush'; $line.FontSize = 13
    $line.Text = "$($sum.Version)  ·  $($sum.Type)  ·  $($sum.Bots) bots  ·  $($sum.Rate)" + $(if ($sum.Ai) { '  ·  AI chat' } else { '' })
    [void]$sp.Children.Add($line)

    $chips = New-Object Windows.Controls.WrapPanel; $chips.Margin = '0,4,0,0'
    foreach ($m in $sum.Modules) { [void]$chips.Children.Add((New-Chip $(if ($ModuleTitles[$m]) { $ModuleTitles[$m] } else { $m }))) }
    if (-not $sum.Modules.Count) { [void]$chips.Children.Add((New-Chip 'Playerbots only')) }
    $uc = Join-Path $sum.Root 'tools\update-check.json'
    if (Test-Path $uc) { try { if ((Get-Content $uc -Raw | ConvertFrom-Json).Available) { $chip = New-Chip '⟳ update available'; $chip.Child.Foreground = Get-Brush 'AccentBrush'; [void]$chips.Children.Add($chip) } } catch {} }
    $ev = Join-Path $sum.Root 'tools\events-active.txt'
    if (Test-Path $ev) { foreach ($e in Get-Content $ev | Where-Object { $_.Trim() }) { $chip = New-Chip "★ $e"; $chip.Child.Foreground = Get-Brush 'GoodBrush'; [void]$chips.Children.Add($chip) } }
    [void]$sp.Children.Add($chips)

    $meta = New-Object Windows.Controls.TextBlock; $meta.Style = $App.Resources['Muted']; $meta.Margin = '0,8,0,0'; $meta.FontSize = 12
    $size = $script:SizeCache[$sum.Root]
    $meta.Text = "$($sum.Root)   ·   $(if ($size -ne $null) { "$size GB" } else { 'measuring size...' })"
    $meta.Tag = "size:$($sum.Root)"
    [void]$sp.Children.Add($meta)

    $btns = New-Object Windows.Controls.WrapPanel; $btns.Margin = '0,12,0,0'
    $go = New-Object Windows.Controls.Button; $go.Margin = '0,0,8,0'; $go.Tag = $sum.Root
    if ($sum.Running) {
        $go.Content = '■ Stop'; $go.Style = $App.Resources['Danger']
        $go.Add_Click({
            $r = $this.Tag
            if (-not (Confirm-Action 'Stop this server? Everyone is disconnected (characters are saved first).')) { return }
            Start-BgTask -Overlay 'Stopping the server (saving all characters)...' -Script { param($x) Stop-GameServer $x } -Arguments @($r) -OnDone { param($a, $b) Enter-Servers } | Out-Null
        })
    } else {
        $go.Content = '▶ Start'; $go.Style = $App.Resources['Primary']
        $go.Add_Click({ Start-ServerSmart $this.Tag; Enter-Servers })
    }
    [void]$btns.Children.Add($go)
    $manage = New-Object Windows.Controls.Button; $manage.Content = 'Manage'; $manage.Tag = $sum.Root; $manage.Margin = '0,0,8,0'
    $manage.Add_Click({ Select-Server $this.Tag; $ui.NavDashboard.IsChecked = $true })
    [void]$btns.Children.Add($manage)

    $more = New-Object Windows.Controls.Button; $more.Content = '⋯  More'; $more.Margin = '0'
    $menu = New-Object Windows.Controls.ContextMenu
    $items = [ordered]@{
        'Duplicate (copy settings)...' = 'dup'; 'Export / move to another PC...' = 'export'; 'Open folder' = 'open'
    }
    $items['Check & repair...'] = 'repair'
    if ($sum.CanUpdate) { $items['Recompile...'] = 'recompile' }
    if ($sum.HasBuildLeftovers) { $items['Free up space (delete compile leftovers, ~5 GB)'] = 'slim' }
    $items['Remove from this list'] = 'forget'; $items['Delete this server...'] = 'delete'
    foreach ($k in $items.Keys) {
        $mi = New-Object Windows.Controls.MenuItem; $mi.Header = $k; $mi.Tag = @($items[$k], $sum.Root)
        $mi.Add_Click({ Invoke-ServerCardAction $this.Tag[0] $this.Tag[1] })
        [void]$menu.Items.Add($mi)
    }
    $more.ContextMenu = $menu
    $more.Add_Click({ $this.ContextMenu.PlacementTarget = $this; $this.ContextMenu.IsOpen = $true })
    [void]$btns.Children.Add($more)
    [void]$sp.Children.Add($btns)
    $card.Child = $sp
    $card
}

function Select-Server([string]$Root) {
    for ($i = 0; $i -lt $ui.CmbServer.Items.Count; $i++) { if ($ui.CmbServer.Items[$i].Tag -eq $Root) { $ui.CmbServer.SelectedIndex = $i } }
}

function Enter-Servers {
    $ui.ServerCards.Children.Clear()
    $list = @(Get-ServerRegistry | Where-Object { Test-ServerRoot $_.RootDir })
    $running = 0
    foreach ($r in $list) {
        try { $sum = Get-ServerSummary $r.RootDir; if ($sum.Running) { $running++ }; [void]$ui.ServerCards.Children.Add((New-ServerCard $sum)) }
        catch { Show-Toast "Could not read $($r.RootDir): $($_.Exception.Message)" 6 }
    }
    if (-not $list.Count) {
        $t = New-Object Windows.Controls.TextBlock; $t.Text = 'No servers yet. Create a new one or import one from another PC.'; $t.Style = $App.Resources['Muted']; $t.Margin = '7,0,0,14'
        [void]$ui.ServerCards.Children.Add($t)
    }
    $ui.SrvSummary.Text = "$($list.Count) server(s)" + $(if ($running) { "  ·  1 running" } else { '  ·  none running' }) + '  ·  only one runs at a time'
    $prefs = Get-AppPrefs
    $ui.TxtPrefFolder.Text = $prefs.ServersFolder
    $ui.ChkPrefShare.IsChecked = [bool]$prefs.ShareMapData
    $roots = @($list | ForEach-Object RootDir)
    Start-BgTask -Tag 'sizes' -Script {
        param($rs)
        $out = @{}; foreach ($r in $rs) { $out[$r] = Get-FolderSizeGB $r }
        $cache = Join-Path (Get-AppPrefs).ServersFolder '_shared'
        $out['__shared'] = Get-FolderSizeGB $cache
        $out
    } -Arguments @(, $roots) -OnDone {
        param($res, $err)
        if ($err) { return }
        $sizes = $res | Select-Object -Last 1
        foreach ($k in $sizes.Keys) { if ($k -ne '__shared') { $script:SizeCache[$k] = $sizes[$k] } }
        $ui.TxtCacheSize.Text = "Shared map data and downloads use $($sizes['__shared']) GB."
        foreach ($card in $ui.ServerCards.Children) {
            if (-not ($card -is [Windows.Controls.Border])) { continue }
            foreach ($el in $card.Child.Children) {
                if ($el.Tag -is [string] -and $el.Tag.StartsWith('size:')) {
                    $r = $el.Tag.Substring(5); $el.Text = "$r   ·   $($sizes[$r]) GB"
                }
            }
        }
    } | Out-Null
}

function Invoke-ServerCardAction([string]$action, [string]$Root) {
    $s = Get-ServerSettings $Root
    switch ($action) {
        'open' { Start-Process explorer.exe -ArgumentList "`"$Root`"" }
        'export' { Select-Server $Root; $ui.NavExport.IsChecked = $true }
        'repair' { if (Show-RepairWindow $Root) { if ($Root -eq $script:Root) { $script:Settings = Get-ServerSettings $Root }; Update-ServerList; Enter-Servers } }
        'recompile' { Select-Server $Root; $ui.NavUpdates.IsChecked = $true; $ui.BtnRecompile.BringIntoView() }
        'forget' {
            if (Confirm-Action "Remove '$($s.RealmName)' from this list? Nothing is deleted; add it back any time with 'Add existing folder'.") {
                Unregister-Server $Root; Update-ServerList; Enter-Servers
            }
        }
        'slim' {
            if (-not (Confirm-Action "Delete the compile leftovers of '$($s.RealmName)' (about 5 GB)?`n`nThe server keeps working. The next update will recompile everything (30-60 min instead of a few minutes).")) { return }
            Start-BgTask -Overlay 'Freeing up space...' -Script { param($r) Remove-BuildLeftovers $r } -Arguments @($Root) -OnDone {
                param($a, $b) if (-not $b) { (Get-AppVar SizeCache).Remove($Root); Show-Toast 'Space freed.'; Enter-Servers }
            }.GetNewClosure() | Out-Null
        }
        'dup' {
            $copyChars = Confirm-Action "Duplicate '$($s.RealmName)'.`n`nA new server is built with the same settings and modules (30-90 min).`n`nAlso copy its accounts and characters? (No = start the copy fresh)" 'Duplicate'
            $script:DuplicateRequest = @{ From = $Root; CopyChars = $copyChars }
            $ui.NavNew.IsChecked = $false; $ui.NavNew.IsChecked = $true
        }
        'delete' {
            if (Get-ServerProcessInfo $Root 'worldserver') { Show-Message 'Stop this server first.'; return }
            $typed = Read-Input "This permanently deletes '$($s.RealmName)': its folder ($Root), database, characters, backups and scheduled tasks.`n`nType the server name to confirm:" 'Delete server'
            if ($typed -ne $s.RealmName) { if ($typed) { Show-Toast 'The name did not match - nothing was deleted.' }; return }
            $keep = Confirm-Action "Save a small 'characters & settings' package first, so you could bring it back later? (Recommended)" 'Delete server'
            $exports = (Get-AppPrefs).ExportsFolder
            Start-BgTask -Overlay "Deleting '$($s.RealmName)'..." -Script {
                param($r, $keep, $exp)
                if ($keep) {
                    $n = (Get-ServerSettings $r).RealmName -replace '[^A-Za-z0-9]', ''
                    $f = Export-Server -Root $r -OutFile (Join-Path $exp "$n-before-delete-$(Get-Date -Format 'yyyy-MM-dd_HHmm').wowserver") -Kind data -IncludeSecrets
                    Write-ToolLog "Saved $($f.FullName)" 'OK'
                }
                Remove-ServerInstall $r
                'ok'
            } -Arguments @($Root, $keep, $exports) -OnDone {
                param($a, $b) if (-not $b) { Show-Toast 'Server deleted.'; Update-ServerList; if ($ui.CmbServer.Items.Count) { $ui.NavServers.IsChecked = $false; $ui.NavServers.IsChecked = $true } }
            } | Out-Null
        }
    }
}

$ui.BtnSrvNew.Add_Click({ $ui.NavNew.IsChecked = $true })
$ui.BtnSrvImport.Add_Click({ $ui.NavImport.IsChecked = $true })
$ui.BtnSrvAdd.Add_Click({ Add-ExistingServer; Enter-Servers })
$ui.BtnPrefFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Where should new servers be created? (no spaces in the path)'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    if ($dlg.SelectedPath -match '\s') { Show-Message 'Please choose a folder path without spaces.'; return }
    $p = Get-AppPrefs; $p.ServersFolder = $dlg.SelectedPath; $p.ExportsFolder = Join-Path $dlg.SelectedPath '_exports'
    Save-AppPrefs $p; Enter-Servers
    Show-Toast 'New servers will go there. Existing servers stay where they are.'
})
$ui.ChkPrefShare.Add_Click({ $p = Get-AppPrefs; $p.ShareMapData = [bool]$ui.ChkPrefShare.IsChecked; Save-AppPrefs $p })
$ui.BtnClearCache.Add_Click({
    $dl = Join-Path (Get-AppPrefs).ServersFolder '_shared\downloads'
    if (-not (Confirm-Action "Delete the downloaded installers in $dl ?`n`nThey are downloaded again when needed. (Shared map data is kept.)")) { return }
    Get-ChildItem $dl -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Show-Toast 'Download cache cleared.'; Enter-Servers
})

# ================================================================== export
function Enter-Export {
    if (-not $script:Root) { return }
    $ui.TxtExpFolder.Text = (Get-AppPrefs).ExportsFolder
    $ui.ExpResult.Text = ''
    $ui.ChkExpMap.IsEnabled = [bool]$ui.RbExpFull.IsChecked
}
$ui.RbExpFull.Add_Checked({ $ui.ChkExpMap.IsEnabled = $true })
$ui.RbExpData.Add_Checked({ $ui.ChkExpMap.IsEnabled = $false })
$ui.BtnExpFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description = 'Where should the export file be saved?'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $p = Get-AppPrefs; $p.ExportsFolder = $dlg.SelectedPath; Save-AppPrefs $p; $ui.TxtExpFolder.Text = $dlg.SelectedPath
})
$ui.BtnExpOpen.Add_Click({ $d = $ui.TxtExpFolder.Text; New-Item -ItemType Directory -Force $d | Out-Null; Start-Process explorer.exe -ArgumentList "`"$d`"" })
$ui.BtnExport.Add_Click({
    if (-not (Assert-Server)) { return }
    $kind = if ($ui.RbExpData.IsChecked) { 'data' } else { 'full' }
    $leaf = $script:Settings.RealmName -replace '[^A-Za-z0-9]', ''
    $file = Join-Path $ui.TxtExpFolder.Text ("{0}-{1}{2}.wowserver" -f $leaf, (Get-Date -Format 'yyyy-MM-dd_HHmm'), $(if ($kind -eq 'data') { '-data' } else { '' }))
    $map = [bool]($ui.ChkExpMap.IsChecked -and $kind -eq 'full'); $sec = [bool]$ui.ChkExpSecrets.IsChecked
    $ui.ExpResult.Text = ''
    Start-BgTask -Overlay 'Exporting the server...' -Script {
        param($r, $f, $k, $m, $s)
        $item = Export-Server -Root $r -OutFile $f -Kind $k -IncludeMapData:$m -IncludeSecrets:$s
        [pscustomobject]@{ File = $item.FullName; MB = [math]::Round($item.Length / 1MB) }
    } -Arguments @($script:Root, $file, $kind, $map, $sec) -OnDone {
        param($res, $err)
        if ($err) { return }
        $r = $res | Select-Object -Last 1
        $ui.ExpResult.Text = "✔ Saved $($r.File)  ($($r.MB) MB).`nCopy it to the other PC (USB stick, network share, cloud drive) and choose 'Import a server' there."
    } | Out-Null
})

# ================================================================== import
$script:ImportManifest = $null
function Enter-Import { }
$ui.BtnImpBrowse.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog; $dlg.Filter = 'Server package (*.wowserver)|*.wowserver|All files|*.*'
    $dlg.InitialDirectory = (Get-AppPrefs).ExportsFolder
    if (-not $dlg.ShowDialog($Window)) { return }
    try { $m = Read-ServerPackage $dlg.FileName }
    catch { Show-Message $_.Exception.Message 'Import' 'Warning'; return }
    $script:ImportManifest = $m
    $ui.TxtImpFile.Text = $dlg.FileName
    $st = $m.Settings
    $ui.ImpInfo.Text = (@(
        "Server:  $($m.ServerName)   ($(@('Vanilla','Burning Crusade','Wrath')[[int]$st.Expansion]), $(if ([int]$st.GameType -eq 1) { 'PvP' } else { 'PvE' }), $($st.Bots) bots, $($st.Rates.XPKill)x)",
        "Exported:  $($m.Created -replace 'T', ' ') from $($m.FromComputer)   ·   $($m.SizeMB) MB",
        "Contains:  " + $(if ($m.Kind -eq 'full') { 'the finished server - no compiling needed' } else { 'characters and settings - the server is built on this PC (30-90 min)' }) +
            $(if ($m.IncludesMapData) { ', map data' } else { '' }) + $(if ($m.IncludesSecrets) { ', admin passwords' } else { '' }),
        "Modules:  $((@($m.Modules) | Where-Object { $_ -ne 'mod-playerbots' } | ForEach-Object { if ($ModuleTitles[$_]) { $ModuleTitles[$_] } else { $_ } }) -join ', ')"
    ) -join "`n")
    $ui.TxtImpRoot.Text = Get-DefaultRoot $m.ServerName
    $ui.ImpOptions.IsEnabled = $true
    $ui.BtnImport.Content = if ($m.Kind -eq 'full') { '⇩  Import' } else { 'Continue (set up the new server)' }
})
$ui.BtnImpRoot.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description = 'Choose where to put the imported server'
    if ($dlg.ShowDialog() -eq 'OK') { $ui.TxtImpRoot.Text = Join-Path $dlg.SelectedPath (($script:ImportManifest.ServerName -replace '[^A-Za-z0-9]', '')) }
})
$ui.BtnImpWow.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog; $dlg.Filter = 'World of Warcraft (Wow.exe)|Wow.exe'
    if (-not $dlg.ShowDialog($Window)) { return }
    $problem = Test-WowClient $dlg.FileName
    if ($problem) { $ui.ImpWowStatus.Text = $problem; $ui.ImpWowStatus.Foreground = Get-Brush 'BadBrush'; return }
    $ui.TxtImpWow.Text = $dlg.FileName; $ui.ImpWowStatus.Text = '✔ Found WoW 3.3.5a.'; $ui.ImpWowStatus.Foreground = Get-Brush 'GoodBrush'
})
$ui.BtnImport.Add_Click({
    $m = $script:ImportManifest; if (-not $m) { return }
    $root = $ui.TxtImpRoot.Text.Trim().TrimEnd('\')
    if (-not $root -or $root -match '\s' -or -not [IO.Path]::IsPathRooted($root)) { Show-Message 'Please choose a full folder path without spaces.'; return }
    if ((Test-Path $root) -and (Get-ChildItem $root -Force | Select-Object -First 1)) { Show-Message 'That folder is not empty. Choose a new folder.'; return }
    $need = if ($m.Kind -eq 'full') { 10 } else { 30 }
    if ((Get-FreeSpaceGB $root) -lt $need) { Show-Message "At least $need GB of free space is needed on that drive."; return }
    # Start from this PC's defaults, then take the world/gameplay settings from the package.
    $s = New-DefaultSettings
    foreach ($p in $m.Settings.PSObject.Properties) {
        if ($p.Name -in 'MapThreads', 'BufferPoolGB', 'CharDbWorkers') { continue }   # tuned for THIS PC instead
        $s | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
    }
    $s.RootDir = $root; $s.MySqlDir = Join-Path $root 'mysql'; $s.MySqlService = Get-UniqueMySqlServiceName $root
    $s | Add-Member -NotePropertyName DbPortMode -NotePropertyValue 'shared' -Force
    $s.DbPort = Get-SharedDbPort; $s.WowExe = $ui.TxtImpWow.Text; $s.PlayerPass = ''; $s.MySqlStopWithServer = $true
    $s.DataDir = if ((Get-AppPrefs).ShareMapData) { Get-SharedDataDir } else { '' }
    $s | Add-Member -NotePropertyName CoreRevision -NotePropertyValue $m.CoreRevision -Force
    $s | Add-Member -NotePropertyName ClientDataVersion -NotePropertyValue $m.ClientDataVersion -Force
    if ($m.Kind -eq 'full') {
        $s.InstallMode = 'import'; $s.ImportPackage = $ui.TxtImpFile.Text
        if (-not (Confirm-Action "Import '$($m.ServerName)' into $root ?`n`nThis takes a few minutes (no compiling)." 'Import')) { return }
        $script:WizSettings = $s
        Show-Page 'Wizard'
        Start-WizInstall
    } else {
        # Characters-only package: walk through the normal wizard with the package's settings, then load the data.
        $s.InstallMode = 'build'; $s.RestorePackage = $ui.TxtImpFile.Text
        $script:WizPreset = $s
        $ui.NavNew.IsChecked = $false; $ui.NavNew.IsChecked = $true
    }
})

# ================================================================== prerequisites
function Enter-Prereqs {
    $ui.PrereqList.Children.Clear()
    $loading = New-Object Windows.Controls.TextBlock; $loading.Text = 'Checking this PC...'; $loading.Style = $App.Resources['Muted']
    [void]$ui.PrereqList.Children.Add($loading)
    Start-BgTask -Tag 'prereqs' -Script { @(Get-PrereqStatus) } -OnDone {
        param($res, $err)
        $ui.PrereqList.Children.Clear()
        if ($err) { $ui.PreFooter.Text = "Could not check: $($err.Message)"; return }
        $items = @($res)
        $needText = @{ build = 'needed to build servers'; run = 'needed to run servers'; ai = 'needed for AI chatter'; extra = 'optional extra' }
        foreach ($group in ($items | ForEach-Object Group | Select-Object -Unique)) {
            $card = New-Object Windows.Controls.Border; $card.Style = $App.Resources['Card']
            $sp = New-Object Windows.Controls.StackPanel
            $h = New-Object Windows.Controls.TextBlock; $h.Text = $group; $h.Style = $App.Resources['H2']; [void]$sp.Children.Add($h)
            foreach ($it in $items | Where-Object Group -eq $group) {
                $row = New-Object Windows.Controls.DockPanel; $row.Margin = '0,6'
                $icon = New-Object Windows.Controls.TextBlock; $icon.Width = 26; $icon.FontSize = 15; $icon.FontWeight = 'Bold'
                $icon.Text = if ($it.Installed) { '✔' } else { '○' }
                $icon.Foreground = Get-Brush $(if ($it.Installed) { 'GoodBrush' } elseif ($it.Need -eq 'extra') { 'MutedBrush' } else { 'WarnBrush' })
                [void]$row.Children.Add($icon)
                $btn = New-Object Windows.Controls.Button; $btn.Tag = $it.Id; $btn.VerticalAlignment = 'Center'; $btn.Margin = '8,0,0,0'
                $btn.Content = if ($it.Installed) { 'Reinstall' } else { 'Install' }
                if (-not $it.Installed -and $it.Need -ne 'extra') { $btn.Style = $App.Resources['Primary'] }
                $btn.Add_Click({ Install-PrereqFromUi @($this.Tag) ($this.Content -eq 'Reinstall') })
                [Windows.Controls.DockPanel]::SetDock($btn, 'Right'); [void]$row.Children.Add($btn)
                $txt = New-Object Windows.Controls.StackPanel
                $n = New-Object Windows.Controls.TextBlock; $n.FontWeight = 'SemiBold'
                $n.Text = $it.Name + $(if ($it.Version) { "   $($it.Version)" } else { '' })
                $d = New-Object Windows.Controls.TextBlock; $d.Style = $App.Resources['Muted']
                $d.Text = "$($it.Purpose)  ($($needText[$it.Need]))" + $(if ($it.Note) { "  ·  $($it.Note)" } else { '' })
                [void]$txt.Children.Add($n); [void]$txt.Children.Add($d); [void]$row.Children.Add($txt)
                [void]$sp.Children.Add($row)
            }
            $card.Child = $sp; [void]$ui.PrereqList.Children.Add($card)
        }
        $missing = @($items | Where-Object { -not $_.Installed -and $_.Need -in 'build', 'run' })
        $ui.PreFooter.Text = if ($missing.Count) { "$($missing.Count) item(s) needed for building servers are missing. 'Install everything missing' installs them in one go." } else { '✔ This PC has everything needed to build and run servers.' }
    } | Out-Null
}

function Install-PrereqFromUi([string[]]$ids, [bool]$force) {
    $guided = [bool]$ui.ChkPreGuided.IsChecked
    Start-BgTask -Overlay $(if ($ids.Count -gt 1) { 'Installing prerequisites' } else { 'Installing ' + (Get-PrereqItem $ids[0]).Name }) -Script {
        param($list, $g, $f)
        foreach ($id in $list) { Install-Prereq -Id $id -Guided:$g -Force:$f }
        'ok'
    } -Arguments @(, $ids + @($guided, $force)) -OnDone { param($a, $b) Enter-Prereqs } | Out-Null
}
$ui.BtnPreRefresh.Add_Click({ Enter-Prereqs })
$ui.BtnPreAll.Add_Click({
    Start-BgTask -Tag 'prereqs-missing' -Script { @(Get-PrereqStatus | Where-Object { -not $_.Installed -and $_.Need -in 'build', 'run' } | ForEach-Object Id) } -OnDone {
        param($res, $err)
        $ids = @($res | Where-Object { $_ })
        if (-not $ids.Count) { Show-Toast 'Nothing is missing.'; return }
        if (Confirm-Action "Install these now?`n`n  • $(($ids | ForEach-Object { (Get-PrereqItem $_).Name }) -join "`n  • ")`n`nThe C++ compiler alone is several GB." 'Prerequisites') { Install-PrereqFromUi $ids $false }
    } | Out-Null
})
$ui.BtnPreLinks.Add_Click({
    Start-BgTask -Overlay 'Checking every download source...' -Script { @(Test-DownloadLinks) } -OnDone {
        param($res, $err)
        if ($err) { return }
        $rows = @($res)
        $bad = @($rows | Where-Object { -not $_.Ok })
        $text = ($rows | ForEach-Object { "$(if ($_.Ok) { '✔' } else { '✖' })  $($_.Source)  -  $($_.Detail)" }) -join "`n"
        Show-Message $(if ($bad.Count) { "$($bad.Count) source(s) did not answer:`n`n$text" } else { "All download sources are working.`n`n$text" }) 'Download links' $(if ($bad.Count) { 'Warning' } else { 'Information' })
    } | Out-Null
})

# ================================================================== new server wizard
$script:WizStep = 0
$script:WizRunning = $false
$WizCrumbs = 'Step 1 of 4 · Welcome', 'Step 2 of 4 · Game and folder', 'Step 3 of 4 · Settings', 'Step 4 of 4 · Installing', 'Finished'

function Get-DefaultRoot([string]$Name = 'Azeroth Reborn') {
    # <servers folder>\<server name without spaces>, numbered if that folder is taken.
    $leaf = ($Name -replace '[^A-Za-z0-9]', '')
    if (-not $leaf) { $leaf = 'Server' }
    $base = Join-Path (Get-AppPrefs).ServersFolder $leaf
    $p = $base; $i = 2
    while ((Test-Path $p) -and -not (Test-Path (Join-Path $p '.creationtool\state.json'))) { $p = "$base$i"; $i++ }
    $p
}

function Get-FreeDbPort {
    # Each server has its own database port; skip ports in use now AND ports owned by stopped servers.
    $taken = @(foreach ($r in Get-ServerRegistry) { try { [int](Get-ServerSettings $r.RootDir).DbPort } catch {} })
    $taken += Get-SharedDbPort
    foreach ($p in 3307..3399) {
        if ($taken -notcontains $p -and -not (Test-PortListening $p)) { return $p }
    }
    3400
}

function Get-MySqlServiceName([string]$Root) { 'AzerothCoreMySQL_' + ((Split-Path $Root -Leaf) -replace '[^A-Za-z0-9]', '') }

function Get-UniqueMySqlServiceName([string]$Root) {
    # One database service per server folder; never reuse a service that belongs to another folder.
    $base = Get-MySqlServiceName $Root; $name = $base; $i = 2
    while ($true) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.PathName -like "*$Root*") { return $name }
        $name = "$base$i"; $i++
    }
}

function New-DefaultSettings {
    $root = Get-DefaultRoot
    $prefs = Get-AppPrefs
    $llmOk = $Machine.VramGB -ge 8
    $model = ($V.llmModels | Where-Object { $_.vramGB -le [math]::Max(8, $Machine.VramGB) } | Select-Object -First 1).name
    [pscustomobject]@{
        RootDir = $root; WowExe = ''; RealmName = 'Azeroth Reborn'; GameType = 1; Expansion = 0
        Bots = Get-RecommendedBotCount $Machine.RamGB; BotsStartAtLevel1 = $true; BotsAutoBattlegrounds = $true
        Rates = [pscustomobject]@{ XPKill = 5; XPQuest = 5; XPExplore = 5; Money = 5; Crafting = 5; Gathering = 5; Weapon = 5; Reputation = 3; Honor = 3 }
        Modules = @($V.modules | Where-Object { ($_.required -or $_.default) -and (-not $_.llm -or $llmOk) } | ForEach-Object name)
        Llm = [pscustomobject]@{ Enabled = $llmOk; Model = $model; Preset = 'default' }
        PlayerUser = ''; PlayerPass = ''; PlayerIsGm = $true
        DbPortMode = 'shared'; DbPort = Get-SharedDbPort; SoapPort = 7878; MySqlService = Get-MySqlServiceName $root; MySqlDir = (Join-Path $root 'mysql')
        BufferPoolGB = [math]::Max(2, [math]::Min(16, [math]::Floor($Machine.RamGB / 4)))
        MapThreads = [math]::Max(2, [math]::Min(8, [math]::Floor($Machine.Cores / 2)))
        CharDbWorkers = 2; AhBotGuids = ''; BackupKeep = 10; PublicAddress = ''; LocalAddress = ''
        MySqlStopWithServer = $true; InstallMode = 'build'; ImportPackage = ''; RestorePackage = ''; DuplicateFrom = ''
        DataDir = $(if ($prefs.ShareMapData) { Get-SharedDataDir } else { '' }); ClientDataVersion = ''
    }
}

function Show-WizStep([int]$n) {
    0..4 | ForEach-Object { $ui["Wiz$_"].Visibility = if ($_ -eq $n) { 'Visible' } else { 'Collapsed' } }
    $ui.WizCrumb.Text = $WizCrumbs[$n]
    $ui.WizBack.Visibility = if ($n -in 1, 2) { 'Visible' } else { 'Hidden' }
    $ui.WizNext.Visibility = if ($n -eq 4) { 'Collapsed' } else { 'Visible' }
    $ui.WizNext.Content = switch ($n) { 2 { 'Install' } 3 { if ($script:WizRunning) { 'Cancel' } else { 'Try again' } } default { 'Next' } }
    $script:WizStep = $n
}

function Enter-Wizard {
    if ($script:WizRunning -or ($script:WizStep -ge 3 -and -not $script:WizPreset -and -not $script:DuplicateRequest)) { Show-WizStep $script:WizStep; return }
    $script:WizSettings = New-DefaultSettings
    $ui.ResumeCard.Visibility = 'Collapsed'
    if (Test-Path $LastFile) {
        try {
            $prev = Get-Content $LastFile -Raw | ConvertFrom-Json
            $stateFile = Join-Path $prev.RootDir '.creationtool\state.json'
            if ((Test-Path $stateFile) -and @((Get-Content $stateFile -Raw | ConvertFrom-Json).Completed) -notcontains 'client') {
                foreach ($p in $prev.PSObject.Properties) { $script:WizSettings | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
                $script:WizSettings | Add-Member -NotePropertyName PlayerPass -NotePropertyValue '' -Force
                $ui.ResumeCard.Visibility = 'Visible'
                $ui.ResumeText.Text = "An unfinished install was found in $($prev.RootDir). Your earlier choices are filled in; continue and it picks up where it stopped. (Type your password again.)"
            }
        } catch {}
    }
    if ($script:WizPreset) {
        # Coming from "Import a server" with a characters-only package.
        $script:WizSettings = $script:WizPreset; $script:WizPreset = $null
        $ui.ResumeCard.Visibility = 'Visible'
        $ui.ResumeText.Text = "Settings were loaded from the package '$(Split-Path $script:WizSettings.RestorePackage -Leaf)'. After the server is built, its accounts and characters are loaded into it. Log in with the same account as before."
    } elseif ($script:DuplicateRequest) {
        $src = Get-ServerSettings $script:DuplicateRequest.From
        foreach ($p in $src.PSObject.Properties) {
            if ($p.Name -in 'RootDir', 'MySqlDir', 'MySqlService', 'DbPort', 'DbPortMode', 'DataDir', 'AhBotGuids', 'PublicAddress', 'LocalAddress', 'InstallMode', 'ImportPackage', 'RestorePackage', 'ClientDataVersion') { continue }
            $script:WizSettings | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
        $script:WizSettings.RealmName = "$($src.RealmName) Copy"
        $script:WizSettings.RootDir = Get-DefaultRoot $script:WizSettings.RealmName
        $script:WizSettings.MySqlDir = Join-Path $script:WizSettings.RootDir 'mysql'
        $script:WizSettings.MySqlService = Get-MySqlServiceName $script:WizSettings.RootDir
        $script:WizSettings.DuplicateFrom = if ($script:DuplicateRequest.CopyChars) { $script:DuplicateRequest.From } else { '' }
        $ui.ResumeCard.Visibility = 'Visible'
        $ui.ResumeText.Text = "Duplicating '$($src.RealmName)': its settings and modules are filled in" + $(if ($script:DuplicateRequest.CopyChars) { ', and its accounts and characters are copied over at the end.' } else { '. The copy starts with a fresh world.' })
        $script:DuplicateRequest = $null
    }
    $s = $script:WizSettings
    $ui.SysInfo.Text = (@(
        "Windows: $($Machine.OsName)",
        "Processor: $($Machine.CpuName) ($($Machine.Cores) cores)",
        "Memory: $($Machine.RamGB) GB$(if ($Machine.RamGB -lt 16) { '  - low; choose fewer bots' })",
        "Graphics: $($Machine.GpuName)$(if ($Machine.VramGB) { " ($($Machine.VramGB) GB)" })"
    ) -join "`n")
    $ui.TxtRoot.Text = $s.RootDir
    $ui.TxtWow.Text = $s.WowExe
    $ui.TxtUser.Text = $s.PlayerUser
    $script:WizFields = Build-SettingsForm $ui.WizSettingsForm $s -Wizard
    Show-WizStep 0
}

function Set-Status($tb, [string]$text, [string]$kind) {
    $tb.Text = $text
    $tb.Foreground = Get-Brush $(switch ($kind) { 'ok' { 'GoodBrush' } 'warn' { 'WarnBrush' } 'bad' { 'BadBrush' } default { 'MutedBrush' } })
}
function Test-WizWow {
    if (-not $ui.TxtWow.Text) { Set-Status $ui.WowStatus 'No game selected yet.' 'info'; return $false }
    $problem = Test-WowClient $ui.TxtWow.Text
    if ($problem) { Set-Status $ui.WowStatus $problem 'bad'; return $false }
    Set-Status $ui.WowStatus '✔ Found WoW 3.3.5a (build 12340).' 'ok'; $true
}
function Test-WizRoot {
    $p = $ui.TxtRoot.Text.Trim().TrimEnd('\')
    if (-not $p -or -not [IO.Path]::IsPathRooted($p)) { Set-Status $ui.RootStatus 'Please choose a full folder path, like D:\AzerothCoreServer.' 'bad'; return $false }
    if ($p -match '\s') { Set-Status $ui.RootStatus 'Please choose a path without spaces.' 'bad'; return $false }
    if (-not (Test-Path ([IO.Path]::GetPathRoot($p)))) { Set-Status $ui.RootStatus 'That drive does not exist.' 'bad'; return $false }
    if ((Test-Path $p) -and (Get-ChildItem $p -Force | Select-Object -First 1) -and -not (Test-Path (Join-Path $p '.creationtool'))) {
        Set-Status $ui.RootStatus 'That folder already has other files in it. Choose a new or empty folder.' 'bad'; return $false
    }
    $free = Get-FreeSpaceGB $p
    if ($free -lt 30) { Set-Status $ui.RootStatus "Only $free GB free on that drive - at least 30 GB is needed." 'bad'; return $false }
    Set-Status $ui.RootStatus "✔ $free GB free on this drive." 'ok'; $true
}
$ui.BtnBrowseWow.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'World of Warcraft (Wow.exe)|Wow.exe|Programs (*.exe)|*.exe'
    if ($dlg.ShowDialog($Window)) { $ui.TxtWow.Text = $dlg.FileName; Test-WizWow | Out-Null }
})
$ui.BtnBrowseRoot.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose where to create the server folder'
    if ($dlg.ShowDialog() -eq 'OK') {
        $ui.TxtRoot.Text = if ((Split-Path $dlg.SelectedPath -Leaf) -match 'AzerothCore') { $dlg.SelectedPath } else { Join-Path $dlg.SelectedPath 'AzerothCoreServer' }
        Test-WizRoot | Out-Null
    }
})
$ui.TxtRoot.Add_LostFocus({ Test-WizRoot | Out-Null })

$ui.WizBack.Add_Click({ if ($script:WizStep -in 1, 2) { Show-WizStep ($script:WizStep - 1) } })
$ui.WizNext.Add_Click({
    switch ($script:WizStep) {
        0 { Show-WizStep 1; Test-WizWow | Out-Null; Test-WizRoot | Out-Null }
        1 { if ((Test-WizWow) -and (Test-WizRoot)) { Show-WizStep 2 } }
        2 {
            try {
                $s = Read-SettingsForm $script:WizFields $script:WizSettings
                $u = $ui.TxtUser.Text.Trim()
                # Imports and character restores keep the existing accounts; a new login is optional there.
                $loginOptional = $s.InstallMode -eq 'import' -or $s.RestorePackage
                if (-not ($loginOptional -and -not $u)) {
                    if ($u -notmatch '^[A-Za-z0-9]{3,17}$') { throw 'Username must be 3-17 letters or numbers (no spaces).' }
                    if ($ui.TxtPass.Password.Length -lt 4) { throw 'Password must be at least 4 characters.' }
                    if ($ui.TxtPass.Password -ne $ui.TxtPass2.Password) { throw 'The two passwords do not match.' }
                    if ($ui.TxtPass.Password -match '["''\s]') { throw 'Password cannot contain spaces or quote marks.' }
                }
                $root = $ui.TxtRoot.Text.Trim().TrimEnd('\')
                $s.RootDir = $root; $s.MySqlDir = Join-Path $root 'mysql'; $s.WowExe = $ui.TxtWow.Text
                $s.PlayerUser = $u.ToUpper(); $s.PlayerPass = $ui.TxtPass.Password; $s.PlayerIsGm = [bool]$ui.ChkGm.IsChecked
                $s.MySqlService = Get-UniqueMySqlServiceName $root
                # "Own port" servers must not reuse a port another server (running or not) owns. Shared-port servers
                # share on purpose: their databases are swapped when a server starts.
                $owner = Get-ServerRegistry | Where-Object { $_.RootDir.TrimEnd('\') -ne $root } |
                    Where-Object { try { [int](Get-ServerSettings $_.RootDir).DbPort -eq [int]$s.DbPort } catch { $false } } | Select-Object -First 1
                $resuming = Test-Path (Join-Path $root '.creationtool\state.json')
                if ($s.DbPortMode -ne 'shared' -and ($owner -or (-not $resuming -and (Test-PortListening ([int]$s.DbPort))))) {
                    $old = $s.DbPort; $s.DbPort = Get-FreeDbPort
                    Show-Message "Database port $old is already used by $(if ($owner) { "'$($owner.Name)'" } else { 'another program' }), so this server uses port $($s.DbPort) instead." 'Database port' 'Information'
                }
            } catch { Show-Message $_.Exception.Message 'Please check your settings' 'Warning'; return }
            if (-not (Confirm-Action "Ready to build your server in:`n$($s.RootDir)`n`nThis takes about 1-2 hours. Windows may ask for permission a few times.`n`nStart now?" 'Start install')) { return }
            $script:WizSettings = $s
            Start-WizInstall
        }
        3 {
            if ($script:WizRunning) {
                if (Confirm-Action 'Stop the install? You can continue later from where it stopped.') { $script:WizTask.Sync.Cancel = $true; $ui.WizNext.IsEnabled = $false; $ui.InstallDetail.Text = 'Stopping after the current task...' }
            } else { Start-WizInstall }
        }
    }
})

$script:StepItems = @{}
function Start-WizInstall {
    $s = $script:WizSettings
    $s | Select-Object * -ExcludeProperty PlayerPass | ConvertTo-Json -Depth 6 | Set-Content (New-Item -ItemType File -Force $LastFile) -Encoding utf8
    $ui.StepList.Items.Clear(); $script:StepItems.Clear()
    $Global:S = $s
    foreach ($st in $InstallSteps) {
        if ($st.When -and -not (& $st.When)) { continue }
        $row = New-Object Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = '0,4'
        $icon = New-Object Windows.Controls.TextBlock; $icon.Width = 28; $icon.FontSize = 14; $icon.Text = '○'; $icon.Foreground = Get-Brush 'MutedBrush'
        $txt = New-Object Windows.Controls.TextBlock; $txt.Text = $st.Title; $txt.Foreground = Get-Brush 'MutedBrush'
        [void]$row.Children.Add($icon); [void]$row.Children.Add($txt)
        [void]$ui.StepList.Items.Add($row)
        $script:StepItems[$st.Id] = @{ Icon = $icon; Text = $txt }
    }
    $ui.InstallTitle.Text = 'Building your server'
    $ui.InstallCurrent.Foreground = Get-Brush 'AccentBrush'
    $ui.LogBox.Clear()
    $script:WizRunning = $true
    $script:WizStart = Get-Date
    $ui.WizNext.IsEnabled = $true
    Show-WizStep 3
    $ui.WizNote.Text = 'You can leave this running. Keep the PC awake. You can browse other pages meanwhile.'
    $ui.InstallTitle.Text = if ($s.InstallMode -eq 'import') { 'Importing your server' } elseif ($s.DuplicateFrom) { 'Building your copy' } else { 'Building your server' }
    $script:WizTask = Start-BgTask -Tag 'install' -Script {
        param($settings, $tool)
        if ($settings.DuplicateFrom -and -not $settings.RestorePackage) {
            # "Duplicate with characters": snapshot the original server's data first, then load it into the copy.
            $Sync.Current = 'Copying characters from the original server'
            New-Item -ItemType Directory -Force (Join-Path $settings.RootDir '.creationtool') | Out-Null
            $pkg = Export-Server -Root $settings.DuplicateFrom -OutFile (Join-Path $settings.RootDir '.creationtool\duplicate-source.wowserver') -Kind data
            $settings.RestorePackage = $pkg.FullName
        }
        Invoke-Install -Settings $settings -ToolDirectory $tool
    } -Arguments @($s, $ToolDir) -OnDone {
        param($res, $err)
        $script:WizRunning = $false
        $ui.WizNext.IsEnabled = $true
        $ui.WizNote.Text = ''
        $sync = $script:WizTask.Sync
        Update-WizProgress
        if ($sync.Current -eq 'Finished') {
            Register-Server $script:WizSettings.RootDir $script:WizSettings.RealmName
            Update-ServerList $script:WizSettings.RootDir
            $ss = $script:WizSettings
            if ($ss.InstallMode -eq 'import') {
                $ui.DoneText.Text = @"
Your server "$($ss.RealmName)" was imported into $($ss.RootDir).

Everything came along: accounts, characters, bots and settings. Log in with the same username and password
as on the other PC. Click "Start the server now" below to play.

If friends connected to it before, set that up again on the "Play with friends" page (this PC has a
different network address).
"@
                Show-WizStep 4
                return
            }
            $ui.DoneText.Text = @"
Your server "$($ss.RealmName)" is installed in $($ss.RootDir).

HOW TO PLAY
1.  Click "Start the server now" below (or "Start $($ss.RealmName)" on your desktop). The first start takes a few
     extra minutes while $($ss.Bots) bots are created. The Dashboard shows when it is online.
2.  Start World of Warcraft as usual - it is already set to connect to your server.
3.  Log in with username $($ss.PlayerUser) and the password you chose (also saved in secrets\my-game-login.txt).

WHEN YOU ARE DONE
Stop the server from the Dashboard (or "Stop $($ss.RealmName)" on the desktop). It saves everything first.

NEXT STEPS
•  Play with friends: let your partner or friends join from another PC.
•  Backups: turn on a daily backup.
"@
            Show-WizStep 4
        } else {
            $msg = if ($sync.Cancel) { 'You cancelled the install.' } elseif ($err) { $err.Message } else { 'The install stopped.' }
            $ui.InstallTitle.Text = 'The install stopped'
            $ui.InstallCurrent.Text = $msg
            $ui.InstallCurrent.Foreground = Get-Brush 'BadBrush'
            $ui.InstallDetail.Text = 'Click "Try again" to continue from where it stopped. Finished steps are not redone.'
            $ui.LogExpander.IsExpanded = $true
            Show-WizStep 3
        }
    }
}

function Update-WizProgress {
    $t = $script:WizTask; if (-not $t) { return }
    $sync = $t.Sync
    $line = $null; $sb = New-Object Text.StringBuilder
    while ($sync.Log.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length) {
        $ui.LogBox.AppendText($sb.ToString())
        if ($ui.LogBox.Text.Length -gt 400000) { $ui.LogBox.Text = $ui.LogBox.Text.Substring($ui.LogBox.Text.Length - 200000) }
        $ui.LogBox.ScrollToEnd()
    }
    $done = 0; $total = $script:StepItems.Count
    foreach ($id in @($script:StepItems.Keys)) {
        $it = $script:StepItems[$id]
        switch ($sync.Steps[$id]) {
            'done'    { $it.Icon.Text = '✔'; $it.Icon.Foreground = Get-Brush 'GoodBrush'; $it.Text.Foreground = Get-Brush 'TextBrush'; $it.Text.FontWeight = 'Normal'; $done++ }
            'skipped' { $it.Icon.Text = '–'; $done++ }
            'running' { $it.Icon.Text = '►'; $it.Icon.Foreground = Get-Brush 'AccentBrush'; $it.Text.Foreground = Get-Brush 'AccentBrush'; $it.Text.FontWeight = 'SemiBold' }
            'failed'  { $it.Icon.Text = '✖'; $it.Icon.Foreground = Get-Brush 'BadBrush'; $it.Text.Foreground = Get-Brush 'BadBrush'; $it.Text.FontWeight = 'Normal' }
        }
    }
    $ui.InstallProgress.Value = if ($total) { 100 * $done / $total } else { 0 }
    if ($script:WizRunning) {
        $ui.InstallCurrent.Text = $sync.Current
        $ui.InstallDetail.Text = $sync.Detail
        $el = (Get-Date) - $script:WizStart
        $ui.InstallElapsed.Text = "Step $([math]::Min($done + 1, $total)) of $total  ·  running for $([int][math]::Floor($el.TotalHours))h $($el.Minutes)m"
    }
}

$ui.BtnDoneStart.Add_Click({
    Start-ServerSmart $script:WizSettings.RootDir
    $ui.BtnDoneStart.IsEnabled = $false; $ui.BtnDoneStart.Content = 'Server is starting...'
})
$ui.BtnDoneDash.Add_Click({ $script:WizStep = 0; $ui.NavDashboard.IsChecked = $true })

# ================================================================== heartbeat timer
$script:Tick = 0
$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(300)
$Timer.Add_Tick({
    $script:Tick++
    # finish background tasks
    foreach ($t in @($Tasks)) {
        if ($t.Overlay -and $ui.Busy.Visibility -eq 'Visible') {
            $line = $null; $sb = New-Object Text.StringBuilder
            while ($t.Sync.Log.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
            if ($sb.Length) {
                $ui.BusyLog.AppendText($sb.ToString())
                if ($ui.BusyLog.Text.Length -gt 300000) { $ui.BusyLog.Text = $ui.BusyLog.Text.Substring($ui.BusyLog.Text.Length - 150000) }
                $ui.BusyLog.ScrollToEnd()
            }
            $d = (@($t.Sync.Current, $t.Sync.Detail) | Where-Object { $_ }) -join '  ·  '
            if ($d -and -not $t.Sync.Cancel) { $ui.BusyDetail.Text = $d }
            if ($t.Sync.NoCancel) { $ui.BtnBusyCancel.IsEnabled = $false }
        } elseif ($t.Overlay -and $ui.BtnBgTask.Visibility -eq 'Visible' -and $t.Sync.Current -and $script:Tick % 5 -eq 0) {
            $ui.BtnBgTask.Content = "⏳ $($t.Sync.Current)"
        }
        if ($t.Handle.IsCompleted) { [void]$Tasks.Remove($t); Complete-BgTask $t }
    }
    if ($script:WizRunning) { Update-WizProgress }
    if ($script:ToastUntil -and (Get-Date) -gt $script:ToastUntil) { $ui.Toast.Visibility = 'Collapsed'; $script:ToastUntil = $null }
    # live refresh: status every ~5 s (dashboard) / ~15 s (sidebar), logs every ~3 s
    if ($script:Root) {
        if ($script:CurrentPage -eq 'Dashboard' -and $script:Tick % 17 -eq 0) { Update-Dashboard }
        elseif ($script:Tick % 50 -eq 0) { Update-Dashboard }
        if ($script:CurrentPage -eq 'Dashboard' -and $script:Tick % 200 -eq 0) { Update-Dashboard -Full }
        if ($script:CurrentPage -eq 'Logs' -and $ui.ChkLogFollow.IsChecked -and $script:Tick % 10 -eq 0) { Update-LogView }
        if ($script:CurrentPage -eq 'Performance' -and $script:Tick % 13 -eq 0) { Enter-Performance }
    }
})

$Window.Add_Closing({
    param($sender, $e)
    if ($script:WizRunning) {
        if (-not (Confirm-Action 'A server install is still running. Close anyway? You can resume it next time.' 'Close')) { $e.Cancel = $true; return }
        $script:WizTask.Sync.Cancel = $true
    } elseif (@($Tasks | Where-Object { $_.Overlay }).Count) {
        if (-not (Confirm-Action "'$($ui.BusyTitle.Text)' is still running. Closing now interrupts it (an update would leave the server stopped). Close anyway?" 'Close')) { $e.Cancel = $true; return }
    }
})
$Window.Add_Closed({
    $Timer.Stop()
    # Databases the app woke up (to show accounts etc.) go back to sleep if their server is not running.
    try { Stop-AppStartedDatabases } catch {}
    $App.Shutdown()
})

# ================================================================== start
Update-ServerList
if ($ui.CmbServer.Items.Count -eq 0) { Show-Page 'Welcome' }
# PrereqInstaller.bat (and other shortcuts) can open the app on a specific page.
if ($StartPage -and $ui["Nav$StartPage"]) { $ui["Nav$StartPage"].IsChecked = $true }

# Development: run a test script with the whole app loaded (window not shown).
if ($TestScript) { . $TestScript; return }

if ($SelfTest) {
    $report = @()
    foreach ($p in $Pages) { Show-Page $p; $report += "page $p OK" }
    $f = Build-SettingsForm $ui.WizSettingsForm (New-DefaultSettings) -Wizard
    $ui.TxtUser.Text = 'TestUser'
    $s = Read-SettingsForm $f (New-DefaultSettings)
    $report += "wizard form OK: $($s.Bots) bots, port $($s.DbPort), model $($s.Llm.Model), modules $(@($s.Modules).Count)"
    if ($ui.CmbServer.Items.Count) {
        Enter-Settings; $null = Read-SettingsForm $script:SettingsFields ($script:Settings | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
        $report += "settings form OK for $($script:Settings.RealmName)"
        Enter-Updates; Enter-About; Enter-Backups; $report += 'manage pages OK'
        # Interaction test: click every safe control and surface any handler errors.
        $Error.Clear()
        $click = [Windows.Controls.Primitives.ButtonBase]::ClickEvent
        $drain = { foreach ($i in 1..40) { $Window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Background); Start-Sleep -Milliseconds 100; foreach ($t in @($Tasks)) { if ($t.Handle.IsCompleted) { [void]$Tasks.Remove($t); Complete-BgTask $t } }; if (-not $Tasks.Count) { break } } }
        foreach ($n in 'NavDashboard', 'NavConsole', 'NavAccounts', 'NavCharacters', 'NavFriends', 'NavAi', 'NavSettings', 'NavAddons', 'NavBackups', 'NavExport', 'NavUpdates', 'NavPerformance', 'NavLogs', 'NavAbout', 'NavServers', 'NavImport', 'NavPrereqs') {
            $ui[$n].IsChecked = $true; & $drain
        }
        foreach ($b in 'BtnAccRefresh', 'BtnCharRefresh', 'BtnNetRefresh', 'BtnBackupRefresh', 'BtnUpdCheck', 'BtnLogRefresh') {
            $ui[$b].RaiseEvent((New-Object Windows.RoutedEventArgs($click))); & $drain
        }
        $ui.CharKind.SelectedIndex = 1; & $drain
        $ui.ChkLogFollow.IsChecked = $true; Update-LogView
        Invoke-Console 'server info'; & $drain
        # "No MSFT_..." = expected lookups of scheduled tasks/firewall rules that are not set up.
        $real = @($Error | Where-Object { $_.Exception.Message -notmatch '^No MSFT_|^Cannot find a process' -and $_.Exception.Message -notmatch 'world server is not running' })
        $Error.Clear(); $real | ForEach-Object { $Error.Add($_) | Out-Null }
        $report += "interaction test: $($real.Count) unexpected handler errors; accounts=$(@($ui.AccGrid.ItemsSource).Count) bots listed=$(@($ui.CharGrid.ItemsSource).Count) logs=$($ui.LogFile.Items.Count) updates=$(@($ui.UpdGrid.ItemsSource).Count)"
        $report += "console said: $(($ui.ConsoleOut.Text -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))"
        foreach ($er in $Error | Select-Object -First 8) { $report += "  ERR: $($er.Exception.Message) @ $($er.InvocationInfo.ScriptLineNumber)" }

        # Extra windows: open each one off-screen, poke it, (optionally) screenshot it, close without saving.
        $script:DialogReport = @()
        $global:AccDialogHook = {
            param($x)
            $w = $x.Window
            $w.Left = -20000; $w.ShowActivated = $false; $w.Show()
            $pumpW = { $w.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::ApplicationIdle) }
            & $pumpW
            $info = "$($w.Title):"
            if ($x.Body) { $info += " $($x.Body.Children.Count) groups, $($x.Groups.Items.Count) nav;"; $x.Search.Text = 'flight'; & $pumpW
                $info += " search 'flight' shows $(@($x.Body.Children | Where-Object { $_.Visibility -eq 'Visible' }).Count) group(s);"; $x.Search.Text = '' }
            if ($x.BuiltIn) { $info += " $($x.BuiltIn.Children.Count) built-in presets, $($x.Mine.Children.Count) mine;" }
            if ($x.ChkAll) {
                # Check & repair: let the background scan finish first.
                foreach ($i in 1..300) { & $pumpW; Start-Sleep -Milliseconds 200; foreach ($t in @($Tasks)) { if ($t.Handle.IsCompleted) { [void]$Tasks.Remove($t); Complete-BgTask $t } }; if (-not $x.Task) { break } }
                $info += " $($x.Summary.Text) ($(@($x.Rows).Count) checks)"
            }
            if ($x.Grid -and $x.File) { & $pumpW; $info += " $(@($x.Grid.ItemsSource).Count) options in $($x.File.SelectedItem.Content); $($x.Count.Text)"; $x.Search.Text = 'xp'; & $pumpW; $info += " / search 'xp': $(@($x.Grid.ItemsSource).Count)"; $x.Search.Text = '' }
            if ($env:ACC_SHOTS) {
                & $pumpW; $w.UpdateLayout(); $wc = [Windows.Media.VisualTreeHelper]::GetChild($w, 0)
                $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$wc.ActualWidth, [int]$wc.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                $bmp.Render($w); $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
                New-Item -ItemType Directory -Force $env:ACC_SHOTS | Out-Null
                $fs = [IO.File]::Create((Join-Path $env:ACC_SHOTS ("win-{0}.png" -f ($w.Title -replace '[^A-Za-z]', '')))); $enc.Save($fs); $fs.Close()
            }
            $w.Tag = 'saved'; $w.Close()
            $script:DialogReport += $info
        }
        $Error.Clear()
        Enter-Page 'Settings'
        Show-ExtrasWindow; Show-PresetsWindow; Show-AllOptionsWindow; [void](Show-RepairWindow $script:Root)
        $global:AccDialogHook = $null
        $report += $script:DialogReport
        $report += "window errors: $($Error.Count)"
        foreach ($er in $Error | Select-Object -First 8) { $report += "  ERR: $($er.Exception.Message) @ $($er.InvocationInfo.ScriptLineNumber)" }
        Stop-AppStartedDatabases   # same clean-up as closing the window
    }
    $report
    if ($env:ACC_SHOTS) {
        # Render every page to PNG (for visual checks during development).
        New-Item -ItemType Directory -Force $env:ACC_SHOTS | Out-Null
        $Window.Left = -20000; $Window.ShowActivated = $false; $Window.Show()
        $pump = { $Window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::ApplicationIdle) }
        $shots = @('Welcome', 'Wizard:0', 'Wizard:1', 'Wizard:2', 'Import', 'Prereqs')
        if ($ui.CmbServer.Items.Count) { $shots += 'Servers', 'Export', 'Dashboard', 'Console', 'Accounts', 'Characters', 'Friends', 'Ai', 'Settings', 'Backups', 'Updates', 'Performance', 'Logs', 'About' }
        foreach ($shot in $shots) {
            $name, $sub = $shot -split ':'
            if ($name -eq 'Wizard') { Show-Page 'Wizard'; if ($sub -eq '0') { Enter-Wizard }; Show-WizStep ([int]$sub) } else { Enter-Page $name }
            foreach ($i in 1..12) { & $pump; Start-Sleep -Milliseconds 150; foreach ($t in @($Tasks)) { if ($t.Handle.IsCompleted) { [void]$Tasks.Remove($t); Complete-BgTask $t } } }
            $ui.Toast.Visibility = 'Collapsed'
            $Window.UpdateLayout()
            # Size the picture to the client area (not the outer frame) so it has no empty strip at the edges.
            $client = [Windows.Media.VisualTreeHelper]::GetChild($Window, 0)
            $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$client.ActualWidth, [int]$client.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($Window)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create((Join-Path $env:ACC_SHOTS ("{0:00}-{1}.png" -f $shots.IndexOf($shot), ($shot -replace ':', '-'))))
            $enc.Save($fs); $fs.Close()
        }
        $Window.Close()
        "screenshots saved to $env:ACC_SHOTS"
    }
    return
}

$Timer.Start()
$Window.Show()
# Quietly look for a newer version of this app once a day.
try {
    $prefs = Get-AppPrefs
    if (-not $prefs.LastAppUpdateCheck -or ((Get-Date) - [datetime]$prefs.LastAppUpdateCheck).TotalHours -gt 24) {
        $prefs | Add-Member -NotePropertyName LastAppUpdateCheck -NotePropertyValue (Get-Date -Format 's') -Force
        Save-AppPrefs $prefs
        Start-AppUpdateCheck -Quiet
    }
} catch {}
$App.Run() | Out-Null
