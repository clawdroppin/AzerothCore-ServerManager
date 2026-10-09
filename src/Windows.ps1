# Extra windows opened from the World settings page: Extra settings, Presets and All options (advanced).
# Dot-sourced by App.ps1 at global scope (uses its $ui, $Window, $App, $ToolDir and helper functions).
# All three store their changes as option overrides in server-settings.json (see Manage.ps1, apply-config.ps1).

class ConfRow {
    [string]$Key
    [string]$Value
    [string]$Default
    [string]$Source
    [string]$Description
    [string]$Original
    [bool]$Reset
}

function New-ThemedWindow([string]$xaml) {
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    if ($Window.IsVisible) { $w.Owner = $Window }
    if ($Window.Icon) { $w.Icon = $Window.Icon }
    $names = @{}
    foreach ($m in [regex]::Matches($xaml, 'x:Name="([^"]+)"')) { $names[$m.Groups[1].Value] = $w.FindName($m.Groups[1].Value) }
    $names['Window'] = $w
    $names
}

# Self-test hook: lets App.ps1 -SelfTest render and exercise a window instead of showing it modally.
function Show-AppDialog($x) { if ($global:AccDialogHook) { & $global:AccDialogHook $x } else { [void]$x.Window.ShowDialog() } }

function Read-JsonFile([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json }

# Saves settings, regenerates the .conf files and optionally restarts the server (used by all three windows).
function Save-ServerOptions($Settings, [switch]$Restart) {
    $root = $script:Root
    Save-ServerSettings $root $Settings
    Invoke-ApplyServerConfig $root | Out-Null
    $script:Settings = Get-ServerSettings $root
    if ($script:CurrentPage -eq 'Settings') { Enter-Settings }
    if ($Restart) {
        if (Get-ServerProcessInfo $root 'worldserver') { Invoke-StopServer { Start-GameServer $root; Show-Toast 'Saved. The server is restarting with the new options.' 6 }.GetNewClosure() }
        else { Start-GameServer $root; Show-Toast 'Saved. The server is starting.' 5 }
    } else {
        $running = [bool](Get-ServerProcessInfo $root 'worldserver')
        Show-Toast $(if ($running) { 'Saved. Restart the server for the changes to take effect.' } else { 'Saved. The changes apply the next time the server starts.' }) 6
    }
}

# ================================================================== Extra settings
function Show-ExtrasWindow {
    if (-not (Assert-Server)) { return }
    $root = $script:Root
    $settings = Get-ServerSettings $root
    $cat = Read-JsonFile (Join-Path $ToolDir 'config\extras.json')
    $files = @{}; foreach ($f in Get-ConfFiles $root) { $files[$f.Rel] = $f }
    $dists = @{}; $confs = @{}
    $ov = Get-ConfOverrideTable $settings
    $exp = [int]$settings.Expansion

    $x = New-ThemedWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Extra settings" Width="1060" Height="760" MinWidth="820" MinHeight="520" WindowStartupLocation="CenterOwner"
        Background="{StaticResource BgBrush}" Foreground="{StaticResource TextBrush}" FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Display">
  <DockPanel Margin="24,20,24,16">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,14">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="🔍" VerticalAlignment="Center" Margin="0,0,6,0" Foreground="{StaticResource MutedBrush}"/>
        <TextBox x:Name="Search" Width="240" ToolTip="Find a setting"/>
      </StackPanel>
      <StackPanel>
        <TextBlock Style="{StaticResource H1}" Text="Extra settings"/>
        <TextBlock x:Name="Sub" Style="{StaticResource Muted}"/>
      </StackPanel>
    </DockPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <Button x:Name="BtnResetAll" Style="{StaticResource Danger}" Content="Reset all extra settings..." DockPanel.Dock="Left"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <TextBlock x:Name="Pending" VerticalAlignment="Center" Margin="0,0,14,0" Foreground="{StaticResource AccentBrush}"/>
        <Button x:Name="BtnClose" Content="Close"/>
        <Button x:Name="BtnSave" Style="{StaticResource Primary}" Content="Save"/>
        <Button x:Name="BtnSaveRestart" Content="Save and restart server" Margin="0"/>
      </StackPanel>
    </DockPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="230"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <ListBox x:Name="Groups" Background="Transparent" BorderThickness="0" Foreground="{StaticResource TextBrush}" Margin="0,0,14,0" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
      <ScrollViewer x:Name="Scroll" Grid.Column="1" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="Body"/>
      </ScrollViewer>
    </Grid>
  </DockPanel>
</Window>
'@
    $x.Sub.Text = "More ways to tailor '$($settings.RealmName)'. Changes apply when the server (re)starts. Your main World settings stay as they are."
    $rows = New-Object System.Collections.ArrayList
    $cards = New-Object System.Collections.ArrayList
    $markPending = {
        $n = @($rows | Where-Object { (& $_.Dirty) }).Count
        $x.Pending.Text = if ($n) { "$n unsaved change(s)" } else { '' }
    }.GetNewClosure()

    foreach ($g in $cat.groups) {
        $items = @()
        foreach ($it in $g.items) {
            $f = $files[$it.file.ToLower()]
            if (-not $f) { continue }
            if ($it.minExpansion -and $exp -lt [int]$it.minExpansion) { continue }
            if (-not $dists[$f.Rel]) { $dists[$f.Rel] = Read-ConfValues $f.Dist; $confs[$f.Rel] = Read-ConfValues $f.Conf }
            $keys = @(if ($it.keys) { $it.keys } else { $it.key })
            if (@($keys | Where-Object { -not $dists[$f.Rel].ContainsKey($_) }).Count) { continue }   # option not in this server version
            $items += , @($it, $f, $keys)
        }
        if (-not $items.Count) { continue }

        $card = New-Object Windows.Controls.Border; $card.Style = $App.Resources['Card']
        $sp = New-Object Windows.Controls.StackPanel
        $h = New-Object Windows.Controls.TextBlock; $h.Text = "$($g.icon)  $($g.title)"; $h.Style = $App.Resources['H2']
        [void]$sp.Children.Add($h)
        if ($g.note) { $n = New-Object Windows.Controls.TextBlock; $n.Text = $g.note; $n.Style = $App.Resources['Muted']; $n.FontSize = 12; $n.Margin = '0,-4,0,8'; [void]$sp.Children.Add($n) }
        $card.Child = $sp
        [void]$x.Body.Children.Add($card)
        $cardRows = New-Object System.Collections.ArrayList

        foreach ($triple in $items) {
            $it, $f, $keys = $triple
            $rel = $f.Rel
            $cur = @{}; $def = @{}
            foreach ($k in $keys) {
                $def[$k] = $dists[$rel][$k]
                $cur[$k] = if ($ov[$rel] -and $ov[$rel].ContainsKey($k)) { $ov[$rel][$k] } elseif ($confs[$rel].ContainsKey($k)) { $confs[$rel][$k] } else { $def[$k] }
            }
            $isOv = [bool]($ov[$rel] -and @($keys | Where-Object { $ov[$rel].ContainsKey($_) }).Count)
            $row = New-ExtraRow $it $keys $cur $def $markPending
            $row | Add-Member -NotePropertyName Rel -NotePropertyValue $rel
            $row | Add-Member -NotePropertyName Overridden -NotePropertyValue $isOv
            $row | Add-Member -NotePropertyName Card -NotePropertyValue $card
            # header line: label + (changed) + reset button
            $panel = New-Object Windows.Controls.DockPanel; $panel.Margin = '0,7'
            $right = New-Object Windows.Controls.StackPanel; $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Center'
            [Windows.Controls.DockPanel]::SetDock($right, 'Right')
            [void]$right.Children.Add($row.Control)
            $rb = New-Object Windows.Controls.Button; $rb.Content = '↺'; $rb.ToolTip = 'Back to the default'; $rb.Padding = '8,3'; $rb.Margin = '8,0,0,0'
            $rb.Visibility = if ($isOv) { 'Visible' } else { 'Hidden' }
            $rb.Tag = $row
            $rb.Add_Click({ $r = $this.Tag; & $r.SetValues $r.Defaults; $r.Reset = $true; $this.Visibility = 'Hidden'; & $r.Mark })
            [void]$right.Children.Add($rb)
            $row | Add-Member -NotePropertyName ResetButton -NotePropertyValue $rb
            [void]$panel.Children.Add($right)
            $left = New-Object Windows.Controls.StackPanel; $left.Margin = '0,0,16,0'
            $lt = New-Object Windows.Controls.TextBlock; $lt.TextWrapping = 'Wrap'
            [void]$lt.Inlines.Add((New-Object Windows.Documents.Run $it.label))
            if ($isOv) { $chg = New-Object Windows.Documents.Run '   • changed'; $chg.Foreground = Get-Brush 'AccentBrush'; $chg.FontSize = 11; [void]$lt.Inlines.Add($chg) }
            [void]$left.Children.Add($lt)
            $defText = & $row.Describe $row.Defaults
            $hint = (@($it.help, "Default: $defText") | Where-Object { $_ }) -join '   ·   '
            $ht = New-Object Windows.Controls.TextBlock; $ht.Text = $hint; $ht.Style = $App.Resources['Muted']; $ht.FontSize = 12; $ht.TextWrapping = 'Wrap'
            [void]$left.Children.Add($ht)
            $left.ToolTip = "$rel`n" + ($keys -join "`n")
            [void]$panel.Children.Add($left)
            [void]$sp.Children.Add($panel)
            $row | Add-Member -NotePropertyName Panel -NotePropertyValue $panel
            $row | Add-Member -NotePropertyName Search -NotePropertyValue ("$($it.label) $($it.help) $($keys -join ' ') $($g.title)".ToLower())
            [void]$rows.Add($row); [void]$cardRows.Add($row)
        }
        $li = New-Object Windows.Controls.ListBoxItem; $li.Content = "$($g.icon)  $($g.title)"; $li.Tag = $card; $li.Padding = '10,7'
        [void]$x.Groups.Items.Add($li)
        [void]$cards.Add(@{ Card = $card; Rows = $cardRows; Item = $li })
    }

    $x.Groups.Add_SelectionChanged({ $i = $x.Groups.SelectedItem; if ($i) { $i.Tag.BringIntoView() } }.GetNewClosure())
    $x.Search.Add_TextChanged({
        $q = $x.Search.Text.Trim().ToLower()
        foreach ($c in $cards) {
            $any = $false
            foreach ($r in $c.Rows) { $show = (-not $q) -or $r.Search.Contains($q); $r.Panel.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }; if ($show) { $any = $true } }
            $c.Card.Visibility = if ($any) { 'Visible' } else { 'Collapsed' }
            $c.Item.Visibility = $c.Card.Visibility
        }
    }.GetNewClosure())

    $save = {
        param([bool]$restart)
        $table = Get-ConfOverrideTable $settings
        $changed = 0
        foreach ($r in $rows) {
            if (-not (& $r.Dirty)) { continue }
            try { $vals = & $r.GetValues } catch { Show-Message $_.Exception.Message 'Please check' 'Warning'; return }
            if (-not $table[$r.Rel]) { $table[$r.Rel] = @{} }
            $isDefault = -not @($r.Keys | Where-Object { "$($vals[$_])".Trim('"') -ne "$($r.Defaults[$_])".Trim('"') }).Count
            foreach ($k in $r.Keys) {
                if ($r.Reset -and $isDefault) { $table[$r.Rel].Remove($k) } else { $table[$r.Rel][$k] = Format-ConfValue $vals[$k] $r.Defaults[$k] }
            }
            $changed++
        }
        if (-not $changed) { $x.Window.Tag = 'saved'; $x.Window.Close(); return }
        Set-ConfOverrideTable $settings $table
        try { Save-ServerOptions $settings -Restart:$restart; $x.Window.Tag = 'saved'; $x.Window.Close() }
        catch { Show-Message "Saving failed: $($_.Exception.Message)" 'Error' 'Error' }
    }.GetNewClosure()
    $x.BtnSave.Add_Click({ & $save $false }.GetNewClosure())
    $x.BtnSaveRestart.Add_Click({ & $save $true }.GetNewClosure())
    $x.BtnClose.Add_Click({ $x.Window.Close() }.GetNewClosure())
    $x.Window.Add_Closing({
        param($s, $e)
        if ($x.Pending.Text -and -not $x.Window.Tag) {
            if (-not (Confirm-Action 'You have unsaved changes. Close without saving?' 'Extra settings')) { $e.Cancel = $true }
        }
    }.GetNewClosure())
    $x.BtnResetAll.Add_Click({
        $catalogKeys = @{}
        foreach ($r in $rows) { foreach ($k in $r.Keys) { $catalogKeys["$($r.Rel)|$k"] = $true } }
        if (-not (Confirm-Action "Put every setting in this window back to its default?`n`nYour main World settings (speed, bots, game version...) are not changed. Options changed under 'All options' outside this window are kept." 'Reset extra settings')) { return }
        $table = Get-ConfOverrideTable $settings
        foreach ($f in @($table.Keys)) { foreach ($k in @($table[$f].Keys)) { if ($catalogKeys["$f|$k"]) { $table[$f].Remove($k) } } }
        Set-ConfOverrideTable $settings $table
        try { $x.Window.Tag = 'saved'; Save-ServerOptions $settings; $x.Window.Close() } catch { Show-Message $_.Exception.Message 'Error' 'Error' }
    }.GetNewClosure())
    & $markPending
    $x.Rows = $rows; $x.Save = $save
    if ($x.Groups.Items.Count) { $x.Groups.SelectedIndex = 0 }
    Show-AppDialog $x
}

function New-ExtraRow($it, [string[]]$keys, [hashtable]$cur, [hashtable]$def, [scriptblock]$mark) {
    <# Builds the input control for one catalog item. Returns an object with:
       Control, Keys, Defaults, GetValues (key -> value), SetValues, Describe, Dirty, Reset, Mark. #>
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $num = { param($v) $d = 0.0; if ([double]::TryParse("$v".Trim('"'), [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $d } else { $null } }
    $first = $keys[0]
    $on = if ($it.on) { "$($it.on)" } else { '1' }
    $off = if ($it.off) { "$($it.off)" } else { '0' }
    switch ($it.type) {
        'bool' {
            $c = New-Object Windows.Controls.CheckBox; $c.VerticalAlignment = 'Center'
            $get = { $v = if ($c.IsChecked) { $on } else { $off }; $h = @{}; foreach ($k in $keys) { $h[$k] = $v }; $h }.GetNewClosure()
            $set = { param($vals) $c.IsChecked = ("$($vals[$first])".Trim('"') -eq $on) -or ("$($vals[$first])" -eq 'true' -and $on -eq '1') }.GetNewClosure()
            $describe = { param($vals) if ("$($vals[$first])".Trim('"') -eq $on) { 'on' } else { 'off' } }.GetNewClosure()
            $c.Add_Click($mark)
        }
        'choice' {
            $c = New-Object Windows.Controls.ComboBox; $c.Width = 330
            foreach ($o in $it.options) { $i = New-Object Windows.Controls.ComboBoxItem; $i.Content = $o[1]; $i.Tag = "$($o[0])"; [void]$c.Items.Add($i) }
            $get = { $v = if ($c.SelectedItem) { $c.SelectedItem.Tag } else { '' }; $h = @{}; foreach ($k in $keys) { $h[$k] = $v }; $h }.GetNewClosure()
            $set = {
                param($vals)
                $v = "$($vals[$first])".Trim('"')
                $match = $c.Items | Where-Object { $_.Tag -eq $v } | Select-Object -First 1
                if (-not $match) { $match = New-Object Windows.Controls.ComboBoxItem; $match.Content = "Custom ($v)"; $match.Tag = $v; [void]$c.Items.Add($match) }
                $c.SelectedItem = $match
            }.GetNewClosure()
            $describe = { param($vals) $v = "$($vals[$first])".Trim('"'); $o = $it.options | Where-Object { "$($_[0])" -eq $v } | Select-Object -First 1; if ($o) { $o[1] } else { $v } }.GetNewClosure()
            $c.Add_SelectionChanged($mark)
        }
        'ratio' {
            $c = New-Object Windows.Controls.StackPanel; $c.Width = 330
            $sl = New-Object Windows.Controls.Slider; $sl.Minimum = 0; $sl.Maximum = 100; $sl.TickFrequency = 5; $sl.IsSnapToTickEnabled = $true
            $lbl = New-Object Windows.Controls.TextBlock; $lbl.FontSize = 12; $lbl.Foreground = Get-Brush 'MutedBrush'
            [void]$c.Children.Add($sl); [void]$c.Children.Add($lbl)
            $sl.Add_ValueChanged({ $lbl.Text = "$([int]$sl.Value)% Alliance  ·  $(100 - [int]$sl.Value)% Horde" }.GetNewClosure())
            $get = { $a = [int]$sl.Value; @{ $keys[0] = "$a"; $keys[1] = "$(100 - $a)" } }.GetNewClosure()
            $set = { param($vals) $a = & $num $vals[$keys[0]]; $b = & $num $vals[$keys[1]]; if ($null -eq $a -or $null -eq $b -or ($a + $b) -le 0) { $a = 50; $b = 50 }; $sl.Value = [math]::Round(100 * $a / ($a + $b)); $lbl.Text = "$([int]$sl.Value)% Alliance  ·  $(100 - [int]$sl.Value)% Horde" }.GetNewClosure()
            $describe = { param($vals) "$($vals[$keys[0]]) / $($vals[$keys[1]])" }.GetNewClosure()
            $sl.Add_ValueChanged($mark)
        }
        'flags' {
            $c = New-Object Windows.Controls.WrapPanel; $c.Width = 420
            $boxes = @{}
            foreach ($o in $it.options) { $cb = New-Object Windows.Controls.CheckBox; $cb.Content = $o[1]; $cb.Margin = '0,2,14,2'; $cb.Add_Click($mark); [void]$c.Children.Add($cb); $boxes["$($o[0])"] = $cb }
            $get = { $sel = @(foreach ($o in $it.options) { if ($boxes["$($o[0])"].IsChecked) { "$($o[0])" } }); $h = @{}; foreach ($k in $keys) { $h[$k] = '"' + ($sel -join ',') + '"' }; $h }.GetNewClosure()
            $set = { param($vals) $parts = @("$($vals[$first])".Trim('"') -split '\s*,\s*'); foreach ($k in $boxes.Keys) { $boxes[$k].IsChecked = $parts -contains $k } }.GetNewClosure()
            $describe = { param($vals) $v = "$($vals[$first])".Trim('"'); if ($v) { $v } else { 'none' } }.GetNewClosure()
        }
        default {
            # number / gold
            $c = New-Object Windows.Controls.StackPanel; $c.Orientation = 'Horizontal'
            $tb = New-Object Windows.Controls.TextBox; $tb.Width = 110
            [void]$c.Children.Add($tb)
            $isGold = $it.type -eq 'gold'
            if ($isGold) { $g = New-Object Windows.Controls.TextBlock; $g.Text = ' gold'; $g.VerticalAlignment = 'Center'; $g.Foreground = Get-Brush 'MutedBrush'; [void]$c.Children.Add($g) }
            $get = {
                $d = & $num $tb.Text
                if ($null -eq $d -or $d -lt [double]$it.min -or $d -gt [double]$it.max) { throw "'$($it.label)' must be a number from $($it.min) to $($it.max)." }
                $v = if ($isGold) { "$([long][math]::Round($d * 10000))" } else { $d.ToString('0.####', $inv) }
                $h = @{}; foreach ($k in $keys) { $h[$k] = $v }; $h
            }.GetNewClosure()
            $set = { param($vals) $d = & $num $vals[$first]; $tb.Text = if ($null -eq $d) { "$($vals[$first])" } elseif ($isGold) { ($d / 10000).ToString('0.##', $inv) } else { $d.ToString('0.####', $inv) } }.GetNewClosure()
            $describe = { param($vals) $d = & $num $vals[$first]; if ($null -ne $d -and $isGold) { "$(($d / 10000).ToString('0.##', $inv)) gold" } else { "$($vals[$first])".Trim('"') } }.GetNewClosure()
            $tb.Add_TextChanged($mark)
        }
    }
    $row = [pscustomobject]@{ Control = $c; Keys = $keys; Defaults = $def; GetValues = $get; SetValues = $set; Describe = $describe; Reset = $false; Mark = $mark; Initial = $null; Dirty = $null }
    & $set $cur
    # "Dirty" = the shown value differs from what was loaded (or a reset was clicked).
    $row.Initial = (& $describe $cur)
    $snapshot = $null
    try { $snapshot = ((& $get).GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';' } catch {}
    $row.Dirty = {
        if ($row.Reset) { return $true }
        try { $now = ((& $get).GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';' } catch { return $true }
        $now -ne $snapshot
    }.GetNewClosure()
    $row
}

# ================================================================== Presets
function Get-UserPresetDir { $d = Join-Path $env:LOCALAPPDATA 'AzerothCoreCreationTool\presets'; New-Item -ItemType Directory -Force $d | Out-Null; $d }

function Get-AllPresets {
    $list = New-Object System.Collections.ArrayList
    foreach ($p in (Read-JsonFile (Join-Path $ToolDir 'config\presets.json')).presets) { $p | Add-Member -NotePropertyName Builtin -NotePropertyValue $true -Force; [void]$list.Add($p) }
    foreach ($f in Get-ChildItem (Get-UserPresetDir) -Filter *.json -ErrorAction SilentlyContinue) {
        try { $p = Read-JsonFile $f.FullName; if ($p.name) { $p | Add-Member -NotePropertyName Builtin -NotePropertyValue $false -Force; $p | Add-Member -NotePropertyName File -NotePropertyValue $f.FullName -Force; [void]$list.Add($p) } } catch {}
    }
    $list
}

function Get-PresetChanges($p, $s) {
    # Plain-language list of what applying preset $p to settings $s would change.
    $out = @()
    $rateNames = @{ XPKill = 'XP from kills'; XPQuest = 'XP from quests'; XPExplore = 'XP from exploring'; Money = 'Money'; Crafting = 'Crafting'; Gathering = 'Gathering'; Weapon = 'Weapon skill'; Reputation = 'Reputation'; Honor = 'Honor' }
    if ($p.settings.Rates) { foreach ($r in $p.settings.Rates.PSObject.Properties) { if ("$($s.Rates.($r.Name))" -ne "$($r.Value)") { $out += "$($rateNames[$r.Name]): $($s.Rates.($r.Name))x → $($r.Value)x" } } }
    if ($p.settings.botsFactor) { $out += "Bots: $($s.Bots) → $([math]::Max(50, [int]([int]$s.Bots * [double]$p.settings.botsFactor)))" }
    if ($null -ne $p.settings.Bots -and "$($p.settings.Bots)" -ne "$($s.Bots)") { $out += "Bots: $($s.Bots) → $($p.settings.Bots)" }
    if ($null -ne $p.settings.BotsStartAtLevel1 -and [bool]$p.settings.BotsStartAtLevel1 -ne [bool]$s.BotsStartAtLevel1) { $out += $(if ($p.settings.BotsStartAtLevel1) { 'Bots start at level 1' } else { 'Bots start at random levels' }) }
    if ($null -ne $p.settings.BotsAutoBattlegrounds -and [bool]$p.settings.BotsAutoBattlegrounds -ne [bool]$s.BotsAutoBattlegrounds) { $out += $(if ($p.settings.BotsAutoBattlegrounds) { 'Bots start battlegrounds on their own' } else { 'Bots do not start battlegrounds' }) }
    if ($p.clearOverrides) { $n = 0; foreach ($t in (Get-ConfOverrideTable $s).Values) { $n += $t.Count }; if ($n) { $out += "All $n extra settings go back to default" } }
    $count = 0; if ($p.overrides) { foreach ($f in $p.overrides.PSObject.Properties) { $count += @($f.Value.PSObject.Properties).Count } }
    if ($count) { $out += "$count extra option(s) set (see the description)" }
    if (-not $out.Count) { $out += 'Nothing changes - this server already matches.' }
    $out
}

function Invoke-ApplyPreset($p, $s) {
    if ($p.settings.Rates) { foreach ($r in $p.settings.Rates.PSObject.Properties) { $s.Rates.($r.Name) = [double]$r.Value } }
    if ($p.settings.botsFactor) { $s.Bots = [math]::Max(50, [int]([int]$s.Bots * [double]$p.settings.botsFactor)) }
    if ($null -ne $p.settings.Bots) { $s.Bots = [int]$p.settings.Bots }
    if ($null -ne $p.settings.BotsStartAtLevel1) { $s.BotsStartAtLevel1 = [bool]$p.settings.BotsStartAtLevel1 }
    if ($null -ne $p.settings.BotsAutoBattlegrounds) { $s.BotsAutoBattlegrounds = [bool]$p.settings.BotsAutoBattlegrounds }
    $table = if ($p.clearOverrides) { @{} } else { Get-ConfOverrideTable $s }
    $max = "$(Get-MaxLevel $s)"
    if ($p.overrides) {
        foreach ($f in $p.overrides.PSObject.Properties) {
            $rel = $f.Name.ToLower()
            if (-not $table[$rel]) { $table[$rel] = @{} }
            foreach ($k in $f.Value.PSObject.Properties) { $table[$rel][$k.Name] = "$($k.Value)".Replace('{MaxLevel}', $max) }
        }
    }
    Set-ConfOverrideTable $s $table
    # Options that installed modules need are never removed by a preset.
    Update-ModuleConfigOverrides $s $V.modules
    $s
}

function Show-PresetsWindow {
    if (-not (Assert-Server)) { return }
    $x = New-ThemedWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Presets" Width="1060" Height="780" MinWidth="820" MinHeight="520" WindowStartupLocation="CenterOwner"
        Background="{StaticResource BgBrush}" Foreground="{StaticResource TextBrush}" FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Display">
  <DockPanel Margin="24,20,24,16">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
      <TextBlock Style="{StaticResource H1}" Text="Presets"/>
      <TextBlock x:Name="Sub" Style="{StaticResource Muted}" TextWrapping="Wrap"/>
    </StackPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnSaveMine" Content="＋ Save my current setup as a preset..."/>
        <Button x:Name="BtnImport" Content="Import a preset file..."/>
        <Button x:Name="BtnFolder" Content="Open my presets folder"/>
      </StackPanel>
      <Button x:Name="BtnClose" Content="Close" HorizontalAlignment="Right" Margin="0"/>
    </DockPanel>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <WrapPanel x:Name="BuiltIn" Margin="-7,0,-7,0"/>
        <TextBlock x:Name="MineTitle" Style="{StaticResource H2}" Text="My presets" Margin="0,8,0,8"/>
        <WrapPanel x:Name="Mine" Margin="-7,0,-7,0"/>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@
    $x.Sub.Text = "One click sets a whole style of play for '$($script:Settings.RealmName)'. Each preset only changes what it lists; you can fine-tune afterwards in World settings and Extra settings. Applies at the next server start."
    $fill = {
        $x = $x   # make it local so the button closures below capture it
        $x.BuiltIn.Children.Clear(); $x.Mine.Children.Clear()
        $all = Get-AllPresets
        foreach ($p in $all) {
            $card = New-Object Windows.Controls.Border; $card.Style = $App.Resources['Card']; $card.Width = 470; $card.Margin = '7,0,7,14'
            $card.Add_MouseEnter({ $this.BorderBrush = Get-Brush 'AccentDarkBrush' }); $card.Add_MouseLeave({ $this.BorderBrush = Get-Brush 'BorderBrush' })
            $sp = New-Object Windows.Controls.StackPanel
            $head = New-Object Windows.Controls.DockPanel
            $ic = New-Object Windows.Controls.TextBlock; $ic.Text = if ($p.icon) { $p.icon } else { '★' }; $ic.FontSize = 28; $ic.Margin = '0,0,12,0'; $ic.VerticalAlignment = 'Center'
            [void]$head.Children.Add($ic)
            $tt = New-Object Windows.Controls.StackPanel
            $nm = New-Object Windows.Controls.TextBlock; $nm.Text = $p.name; $nm.FontSize = 17; $nm.FontWeight = 'SemiBold'
            $tg = New-Object Windows.Controls.TextBlock; $tg.Text = $p.tagline; $tg.Foreground = Get-Brush 'AccentBrush'; $tg.FontSize = 13
            [void]$tt.Children.Add($nm); [void]$tt.Children.Add($tg); [void]$head.Children.Add($tt)
            [void]$sp.Children.Add($head)
            $d = New-Object Windows.Controls.TextBlock; $d.Text = $p.description; $d.TextWrapping = 'Wrap'; $d.Style = $App.Resources['Muted']; $d.Margin = '0,8,0,0'
            [void]$sp.Children.Add($d)
            $btns = New-Object Windows.Controls.WrapPanel; $btns.Margin = '0,12,0,0'
            $ap = New-Object Windows.Controls.Button; $ap.Content = 'Apply...'; $ap.Style = $App.Resources['Primary']; $ap.Tag = $p
            $ap.Add_Click({
                $p = $this.Tag
                $s = Get-ServerSettings $script:Root
                $changes = Get-PresetChanges $p $s
                if (-not (Confirm-Action "Apply '$($p.name)' to '$($s.RealmName)'?`n`n  • $($changes -join "`n  • ")`n`nTip: 'Save my current setup as a preset' first if you want to be able to come back to how it is now." 'Apply preset')) { return }
                try { $s = Invoke-ApplyPreset $p $s; Save-ServerOptions $s; Show-Toast "'$($p.name)' applied. It takes effect at the next server start." 6; $x.Window.Close() }
                catch { Show-Message "Could not apply the preset: $($_.Exception.Message)" 'Presets' 'Error' }
            }.GetNewClosure())
            [void]$btns.Children.Add($ap)
            if (-not $p.Builtin) {
                $ex = New-Object Windows.Controls.Button; $ex.Content = 'Share (export)...'; $ex.Tag = $p
                $ex.Add_Click({
                    $dlg = New-Object Microsoft.Win32.SaveFileDialog; $dlg.Filter = 'Preset (*.json)|*.json'; $dlg.FileName = (($this.Tag.name -replace '[^A-Za-z0-9 _-]', '') + '.json')
                    if ($dlg.ShowDialog($x.Window)) { Copy-Item $this.Tag.File $dlg.FileName -Force; Show-Toast 'Preset saved - send the file to a friend; they use "Import a preset file".' 6 }
                }.GetNewClosure())
                [void]$btns.Children.Add($ex)
                $del = New-Object Windows.Controls.Button; $del.Content = 'Delete'; $del.Style = $App.Resources['Danger']; $del.Tag = $p
                $del.Add_Click({ if (Confirm-Action "Delete the preset '$($this.Tag.name)'?") { Remove-Item $this.Tag.File -Force; & $x.Fill } }.GetNewClosure())
                [void]$btns.Children.Add($del)
            }
            [void]$sp.Children.Add($btns)
            $card.Child = $sp
            if ($p.Builtin) { [void]$x.BuiltIn.Children.Add($card) } else { [void]$x.Mine.Children.Add($card) }
        }
        if (-not $x.Mine.Children.Count) {
            $t = New-Object Windows.Controls.TextBlock; $t.Text = 'None yet. Set up a server the way you like it, then "Save my current setup as a preset" to reuse it on other servers or share it.'
            $t.Style = $App.Resources['Muted']; $t.Margin = '7,0,7,10'; $t.TextWrapping = 'Wrap'
            [void]$x.Mine.Children.Add($t)
        }
    }.GetNewClosure()
    $x.Fill = $fill   # the cards' own buttons refill the window through this
    & $fill
    $x.BtnSaveMine.Add_Click({
        $name = Read-Input 'Name for this preset:' 'Save preset' "$($script:Settings.RealmName) style"
        if (-not $name.Trim()) { return }
        $tag = Read-Input 'Short description (optional):' 'Save preset' 'My own setup'
        $s = Get-ServerSettings $script:Root
        $ov = [ordered]@{}; foreach ($f in $s.ConfOverrides.PSObject.Properties) { $ov[$f.Name] = $f.Value }
        $p = [ordered]@{
            icon = '★'; name = $name.Trim(); tagline = $tag; clearOverrides = $true
            description = "Saved from '$($s.RealmName)' on $(Get-Date -Format 'yyyy-MM-dd'): $($s.Rates.XPKill)x speed, $($s.Bots) bots, plus all its extra settings."
            settings = [ordered]@{ Rates = $s.Rates; Bots = [int]$s.Bots; BotsStartAtLevel1 = [bool]$s.BotsStartAtLevel1; BotsAutoBattlegrounds = [bool]$s.BotsAutoBattlegrounds }
            overrides = [pscustomobject]$ov
        }
        $file = Join-Path (Get-UserPresetDir) ((($name.Trim()) -replace '[^A-Za-z0-9 _-]', '') + '.json')
        [IO.File]::WriteAllText($file, ([pscustomobject]$p | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Show-Toast "Preset '$($name.Trim())' saved."
        & $fill
    }.GetNewClosure())
    $x.BtnImport.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog; $dlg.Filter = 'Preset (*.json)|*.json'
        if (-not $dlg.ShowDialog($x.Window)) { return }
        try { $p = Read-JsonFile $dlg.FileName; if (-not $p.name -or (-not $p.settings -and -not $p.overrides)) { throw 'not a preset' } }
        catch { Show-Message 'That file is not a preset made by AzerothCore Control Center.' 'Presets' 'Warning'; return }
        Copy-Item $dlg.FileName (Join-Path (Get-UserPresetDir) (Split-Path $dlg.FileName -Leaf)) -Force
        Show-Toast "Preset '$($p.name)' added."
        & $fill
    }.GetNewClosure())
    $x.BtnFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$(Get-UserPresetDir)`"" })
    $x.BtnClose.Add_Click({ $x.Window.Close() }.GetNewClosure())
    Show-AppDialog $x
}

# ================================================================== All options (advanced)
function Show-AllOptionsWindow {
    if (-not (Assert-Server)) { return }
    $root = $script:Root
    $settings = Get-ServerSettings $root
    $x = New-ThemedWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="All options (advanced)" Width="1180" Height="800" MinWidth="860" MinHeight="540" WindowStartupLocation="CenterOwner"
        Background="{StaticResource BgBrush}" Foreground="{StaticResource TextBrush}" FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Display">
  <DockPanel Margin="24,20,24,16">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <TextBlock Style="{StaticResource H1}" Text="All options"/>
      <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap"
                 Text="Every option of every server file, read straight from the server's own files - so options added by future AzerothCore and module versions show up here automatically. Double-click a value to change it. Your changes survive updates and are kept when you save World settings."/>
      <WrapPanel Margin="0,12,0,0">
        <ComboBox x:Name="File" Width="260" Margin="0,0,10,0"/>
        <TextBox x:Name="Search" Width="280" Margin="0,0,10,0" ToolTip="Search names and descriptions"/>
        <CheckBox x:Name="OnlyChanged" Content="Only options that differ from the default" VerticalAlignment="Center"/>
      </WrapPanel>
    </StackPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnReset" Content="↺ Back to default (selected)"/>
        <Button x:Name="BtnOpen" Content="Open this file"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <TextBlock x:Name="Pending" VerticalAlignment="Center" Margin="0,0,14,0" Foreground="{StaticResource AccentBrush}"/>
        <Button x:Name="BtnClose" Content="Close"/>
        <Button x:Name="BtnSave" Style="{StaticResource Primary}" Content="Save"/>
        <Button x:Name="BtnSaveRestart" Content="Save and restart server" Margin="0"/>
      </StackPanel>
    </DockPanel>
    <Border DockPanel.Dock="Bottom" Style="{StaticResource Card}" Margin="0,10,0,0" Padding="14,10" MaxHeight="190">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <TextBlock x:Name="Desc" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}"/>
      </ScrollViewer>
    </Border>
    <TextBlock x:Name="Count" DockPanel.Dock="Bottom" Style="{StaticResource Muted}" FontSize="12" Margin="0,6,0,0"/>
    <DataGrid x:Name="Grid" IsReadOnly="False" EnableRowVirtualization="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
      <DataGrid.RowStyle>
        <Style TargetType="DataGridRow">
          <Style.Triggers>
            <DataTrigger Binding="{Binding Source}" Value="you"><Setter Property="Foreground" Value="{StaticResource AccentBrush}"/></DataTrigger>
            <DataTrigger Binding="{Binding Source}" Value="app"><Setter Property="Foreground" Value="#9FC3E8"/></DataTrigger>
          </Style.Triggers>
        </Style>
      </DataGrid.RowStyle>
      <DataGrid.Columns>
        <DataGridTextColumn Header="Option" Binding="{Binding Key}" Width="3*" IsReadOnly="True"/>
        <DataGridTextColumn Header="Value" Binding="{Binding Value, UpdateSourceTrigger=PropertyChanged}" Width="2*"/>
        <DataGridTextColumn Header="Default" Binding="{Binding Default}" Width="2*" IsReadOnly="True"/>
        <DataGridTextColumn Header="Changed by" Binding="{Binding Source}" Width="100" IsReadOnly="True"/>
      </DataGrid.Columns>
    </DataGrid>
  </DockPanel>
</Window>
'@
    $ov = Get-ConfOverrideTable $settings
    $files = @(Get-ConfFiles $root)
    $rowsByFile = @{}
    foreach ($f in $files) { $i = New-Object Windows.Controls.ComboBoxItem; $i.Content = "$($f.Title)  ($($f.Rel))"; $i.Tag = $f; [void]$x.File.Items.Add($i) }

    $load = {
        param($f)
        if ($rowsByFile[$f.Rel]) { return $rowsByFile[$f.Rel] }
        $conf = Read-ConfValues $f.Conf
        $mine = $ov[$f.Rel]
        $list = New-Object System.Collections.Generic.List[ConfRow]
        foreach ($o in Get-ConfOptions $f.Dist) {
            $r = [ConfRow]::new()
            $r.Key = $o.Key; $r.Default = $o.Default; $r.Description = $o.Description
            if ($mine -and $mine.ContainsKey($o.Key)) { $r.Value = $mine[$o.Key]; $r.Source = 'you' }
            elseif ($conf.ContainsKey($o.Key)) { $r.Value = $conf[$o.Key]; $r.Source = if ($conf[$o.Key].Trim('"') -ne $o.Default.Trim('"')) { 'app' } else { '' } }
            else { $r.Value = $o.Default; $r.Source = '' }
            $r.Original = $r.Value
            $list.Add($r)
        }
        $rowsByFile[$f.Rel] = $list
        $list
    }.GetNewClosure()

    $refresh = {
        $f = $x.File.SelectedItem.Tag
        $all = & $load $f
        $q = $x.Search.Text.Trim().ToLower()
        $only = [bool]$x.OnlyChanged.IsChecked
        $shown = @($all | Where-Object {
            ((-not $q) -or $_.Key.ToLower().Contains($q) -or $_.Description.ToLower().Contains($q)) -and
            ((-not $only) -or $_.Source -or $_.Value -ne $_.Original)
        })
        $x.Grid.ItemsSource = $shown
        if ($shown.Count) { $x.Grid.SelectedIndex = 0 }
        $mineCount = @($all | Where-Object Source -eq 'you').Count
        $x.Count.Text = "$($shown.Count) of $($all.Count) options shown  ·  $mineCount changed by you (gold)  ·  blue = set by the app from your World settings"
    }.GetNewClosure()

    $pending = {
        $n = 0; foreach ($l in $rowsByFile.Values) { foreach ($r in $l) { if ($r.Value -ne $r.Original -or $r.Reset) { $n++ } } }
        $x.Pending.Text = if ($n) { "$n unsaved change(s)" } else { '' }
    }.GetNewClosure()

    $x.File.Add_SelectionChanged({ & $refresh }.GetNewClosure())
    $x.Search.Add_TextChanged({ & $refresh }.GetNewClosure())
    $x.OnlyChanged.Add_Click({ & $refresh }.GetNewClosure())
    $x.Grid.Add_SelectionChanged({
        $r = $x.Grid.SelectedItem
        $x.Desc.Text = if ($r -is [ConfRow]) { "$($r.Key)`n`n$(if ($r.Description) { $r.Description } else { '(no description in the file)' })" } else { '' }
    }.GetNewClosure())
    $x.Grid.Add_CellEditEnding({ $x.Window.Dispatcher.BeginInvoke([Action] { & $pending }) | Out-Null }.GetNewClosure())
    $x.BtnReset.Add_Click({
        $r = $x.Grid.SelectedItem; if (-not ($r -is [ConfRow])) { return }
        [void]$x.Grid.CommitEdit('Row', $true)
        $r.Value = $r.Default; $r.Reset = $true
        $x.Grid.Items.Refresh(); & $pending
    }.GetNewClosure())
    $x.BtnOpen.Add_Click({ $f = $x.File.SelectedItem.Tag; if (Test-Path $f.Conf) { Start-Process notepad.exe -ArgumentList "`"$($f.Conf)`"" } }.GetNewClosure())

    $save = {
        param([bool]$restart)
        [void]$x.Grid.CommitEdit('Row', $true)
        $appKeys = @(foreach ($l in $rowsByFile.Values) { foreach ($r in $l) { if ($r.Source -eq 'app' -and $r.Value -ne $r.Original -and -not $r.Reset) { $r.Key } } })
        if ($appKeys.Count -and -not (Confirm-Action ("These options are normally set by the app from your World settings (or are needed for the server to find its files and database):`n`n  $($appKeys -join "`n  ")`n`n" +
            "Your value will replace the app's from now on, until you set it back to default here. Continue?") 'All options')) { return }
        $table = Get-ConfOverrideTable $settings
        $n = 0
        foreach ($rel in $rowsByFile.Keys) {
            foreach ($r in $rowsByFile[$rel]) {
                if ($r.Value -eq $r.Original -and -not $r.Reset) { continue }
                if (-not $table[$rel]) { $table[$rel] = @{} }
                if ($r.Reset -and $r.Value -eq $r.Default) { $table[$rel].Remove($r.Key) }
                else { $table[$rel][$r.Key] = Format-ConfValue $r.Value $r.Default }
                $n++
            }
        }
        if ($n) {
            Set-ConfOverrideTable $settings $table
            try { Save-ServerOptions $settings -Restart:$restart } catch { Show-Message "Saving failed: $($_.Exception.Message)" 'Error' 'Error'; return }
        }
        $x.Window.Tag = 'saved'; $x.Window.Close()
    }.GetNewClosure()
    $x.BtnSave.Add_Click({ & $save $false }.GetNewClosure())
    $x.BtnSaveRestart.Add_Click({ & $save $true }.GetNewClosure())
    $x.BtnClose.Add_Click({ $x.Window.Close() }.GetNewClosure())
    $x.Window.Add_Closing({
        param($s, $e)
        if ($x.Pending.Text -and -not $x.Window.Tag -and -not (Confirm-Action 'You have unsaved changes. Close without saving?' 'All options')) { $e.Cancel = $true }
    }.GetNewClosure())
    $x.Rows = $rowsByFile; $x.Save = $save; $x.Load = $load
    $x.File.SelectedIndex = [math]::Max(0, [array]::IndexOf(@($files | ForEach-Object Rel), 'worldserver.conf'))
    Show-AppDialog $x
}
