# Small dialogs: a multiple-choice question, the item search for "Mail item", "Copy to another server" and "Check & repair".
# Dot-sourced by App.ps1 at global scope after Windows.ps1 (uses New-ThemedWindow and Show-AppDialog).

class UpdRow {
    [bool]$Include
    [bool]$HasChanges
    [string]$Id
    [string]$Name
    [string]$Current
    [int]$NewCommits
    [string]$Notes
    [string]$Latest
    [string[]]$Changes
}

class RepairRow {
    [bool]$Include
    [bool]$CanFix
    [int]$Order
    [string]$Id
    [string]$Icon
    [string]$Status
    [string]$Area
    [string]$Check
    [string]$Detail
    [string]$Fix
}

function Show-Choice([string]$Title, [string]$Text, [string[]]$Buttons) {
    <# A message with a few answers; returns the index of the clicked one (-1 when closed). The first is highlighted. #>
    $x = New-ThemedWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        Background="{StaticResource BgBrush}" Foreground="{StaticResource TextBrush}" FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Display">
  <StackPanel Margin="24,20,24,18">
    <TextBlock x:Name="Head" Style="{StaticResource H2}" FontSize="18"/>
    <TextBlock x:Name="Body" TextWrapping="Wrap" LineHeight="21" Margin="0,4,0,16"/>
    <StackPanel x:Name="Btns"/>
  </StackPanel>
</Window>
'@
    $x.Window.Title = $Title; $x.Head.Text = $Title; $x.Body.Text = $Text
    $x.Choice = -1
    for ($i = 0; $i -lt $Buttons.Count; $i++) {
        $b = New-Object Windows.Controls.Button; $b.Content = $Buttons[$i]; $b.Tag = $i; $b.Margin = '0,0,0,8'; $b.HorizontalContentAlignment = 'Left'; $b.Padding = '14,9'
        if ($i -eq 0) { $b.Style = $App.Resources['Primary'] }
        $b.Add_Click({ $x.Choice = [int]$this.Tag; $x.Window.Close() }.GetNewClosure())
        [void]$x.Btns.Children.Add($b)
    }
    Show-AppDialog $x
    $x.Choice
}

function Show-ItemPicker([string]$CharName) {
    <# Search the game's items by name; returns @{ Id; Name; Count } or $null. #>
    $root = $script:Root
    $x = New-ThemedWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Mail an item" Width="860" Height="620" MinWidth="640" MinHeight="420" WindowStartupLocation="CenterOwner"
        Background="{StaticResource BgBrush}" Foreground="{StaticResource TextBrush}" FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Display">
  <DockPanel Margin="22,18,22,16">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <TextBlock x:Name="Head" Style="{StaticResource H2}" FontSize="18"/>
      <DockPanel>
        <Button x:Name="BtnFind" DockPanel.Dock="Right" Content="Search" Style="{StaticResource Primary}" Margin="8,0,0,0"/>
        <TextBox x:Name="Query" ToolTip="Part of the item name (or its ID number)"/>
      </DockPanel>
    </StackPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="How many" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBox x:Name="Count" Width="60" Text="1"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnCancel" Content="Cancel"/>
        <Button x:Name="BtnSend" Style="{StaticResource Primary}" Content="Mail it" Margin="0"/>
      </StackPanel>
    </DockPanel>
    <TextBlock x:Name="Info" DockPanel.Dock="Bottom" Style="{StaticResource Muted}" FontSize="12" Margin="0,6,0,0"/>
    <DataGrid x:Name="Grid">
      <DataGrid.RowStyle>
        <Style TargetType="DataGridRow">
          <Style.Triggers>
            <DataTrigger Binding="{Binding Quality}" Value="0"><Setter Property="Foreground" Value="#9D9D9D"/></DataTrigger>
            <DataTrigger Binding="{Binding Quality}" Value="2"><Setter Property="Foreground" Value="#1EFF00"/></DataTrigger>
            <DataTrigger Binding="{Binding Quality}" Value="3"><Setter Property="Foreground" Value="#3FA3FF"/></DataTrigger>
            <DataTrigger Binding="{Binding Quality}" Value="4"><Setter Property="Foreground" Value="#C774FF"/></DataTrigger>
            <DataTrigger Binding="{Binding Quality}" Value="5"><Setter Property="Foreground" Value="#FF8000"/></DataTrigger>
            <DataTrigger Binding="{Binding Quality}" Value="7"><Setter Property="Foreground" Value="#E6CC80"/></DataTrigger>
          </Style.Triggers>
        </Style>
      </DataGrid.RowStyle>
      <DataGrid.Columns>
        <DataGridTextColumn Header="Item" Binding="{Binding Name}" Width="4*"/>
        <DataGridTextColumn Header="Quality" Binding="{Binding QualityName}" Width="*"/>
        <DataGridTextColumn Header="Item level" Binding="{Binding ItemLevel}" Width="90"/>
        <DataGridTextColumn Header="Needs level" Binding="{Binding ReqLevel}" Width="100"/>
        <DataGridTextColumn Header="ID" Binding="{Binding Id}" Width="80"/>
      </DataGrid.Columns>
    </DataGrid>
  </DockPanel>
</Window>
'@
    $x.Head.Text = "Mail an item to $CharName"
    $x.Info.Text = 'Type part of a name, e.g. "Thunderfury", "linen" or "mount", and press Enter.'
    $x.Result = $null
    $find = {
        $x = $x   # make it local so the nested closure below captures it
        $q = $x.Query.Text.Trim(); if ($q.Length -lt 2) { $x.Info.Text = 'Type at least 2 letters.'; return }
        $x.Info.Text = 'Searching...'
        Start-BgTask -Script { param($r, $t) @(Find-GameItems $r $t) } -Arguments @($root, $q) -OnDone {
            param($res, $err)
            if ($err) { $x.Info.Text = "Search failed: $($err.Message)"; return }
            $items = @($res | Where-Object { $_.Id })
            $x.Grid.ItemsSource = $items
            $x.Info.Text = if ($items.Count -ge 200) { 'First 200 matches shown - type more of the name to narrow it down.' } elseif ($items.Count) { "$($items.Count) item(s) found. Double-click one, or select it and click 'Mail it'." } else { 'Nothing found.' }
        }.GetNewClosure() | Out-Null
    }.GetNewClosure()
    $send = {
        $it = $x.Grid.SelectedItem; if (-not $it) { $x.Info.Text = 'Select an item first.'; return }
        if ($x.Count.Text -notmatch '^\d{1,3}$' -or [int]$x.Count.Text -lt 1) { $x.Info.Text = 'How many: 1-999.'; return }
        $x.Result = @{ Id = $it.Id; Name = $it.Name; Count = [int]$x.Count.Text }
        $x.Window.Close()
    }.GetNewClosure()
    $x.Find = $find
    $x.BtnFind.Add_Click($find)
    $x.Query.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { & $find } }.GetNewClosure())
    $x.Grid.Add_MouseDoubleClick($send)
    $x.BtnSend.Add_Click($send)
    $x.BtnCancel.Add_Click({ $x.Window.Close() }.GetNewClosure())
    $x.Window.Add_ContentRendered({ [void]$x.Query.Focus() }.GetNewClosure())
    Show-AppDialog $x
    $x.Result
}

function Show-CopyCharacterDialog([string]$CharName, [string]$FromRoot) {
    <# Pick the target server, account and (optionally) a new name. Returns a hashtable or $null. #>
    $others = @(Get-ServerRegistry | Where-Object { $_.RootDir -ne $FromRoot -and (Test-ServerRoot $_.RootDir) })
    if (-not $others.Count) { Show-Message 'You have only one server. Create or import another server first.' 'Copy character'; return $null }
    $x = New-ThemedWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Copy a character" Width="620" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        Background="{StaticResource BgBrush}" Foreground="{StaticResource TextBrush}" FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Display">
  <StackPanel Margin="24,20,24,18">
    <TextBlock x:Name="Head" Style="{StaticResource H2}" FontSize="18"/>
    <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,14"
               Text="The character is copied with its gear, bags, bank, quests, spells and reputation. The original stays where it is. Only one server can run at a time, so each server is started briefly (a few minutes) and things are put back the way they were afterwards."/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
      <TextBlock Text="Copy to server" VerticalAlignment="Center"/>
      <ComboBox x:Name="Target" Grid.Column="1"/>
      <TextBlock Grid.Row="1" Text="Into account" VerticalAlignment="Center" Margin="0,10,0,0"/>
      <TextBox x:Name="Account" Grid.Row="1" Grid.Column="1" Margin="0,10,0,0" MaxLength="17" ToolTip="An existing account on the other server (Accounts page)"/>
      <TextBlock Grid.Row="2" Text="New name (optional)" VerticalAlignment="Center" Margin="0,10,0,0"/>
      <TextBox x:Name="NewName" Grid.Row="2" Grid.Column="1" Margin="0,10,0,0" MaxLength="12" ToolTip="Leave empty to keep the name (it must be free on the other server)"/>
    </Grid>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="BtnCancel" Content="Cancel"/>
      <Button x:Name="BtnGo" Style="{StaticResource Primary}" Content="Copy" Margin="0"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $x.Head.Text = "Copy $CharName to another server"
    foreach ($o in $others) { $i = New-Object Windows.Controls.ComboBoxItem; $i.Content = $o.Name; $i.Tag = $o.RootDir; [void]$x.Target.Items.Add($i) }
    $x.Target.SelectedIndex = 0
    $x.Account.Text = "$($script:Settings.PlayerUser)"
    $x.Result = $null
    $x.BtnGo.Add_Click({
        $acc = $x.Account.Text.Trim(); $nn = $x.NewName.Text.Trim()
        if ($acc -notmatch '^[A-Za-z0-9]{3,17}$') { Show-Message 'Account: 3-17 letters or numbers.' 'Copy character'; return }
        if ($nn -and $nn -notmatch '^[A-Za-z]{2,12}$') { Show-Message 'New name: 2-12 letters, no spaces or numbers.' 'Copy character'; return }
        $x.Result = @{ To = $x.Target.SelectedItem.Tag; ToName = "$($x.Target.SelectedItem.Content)"; Account = $acc.ToUpper(); NewName = $nn }
        $x.Window.Close()
    }.GetNewClosure())
    $x.BtnCancel.Add_Click({ $x.Window.Close() }.GetNewClosure())
    Show-AppDialog $x
    $x.Result
}

function Show-RepairWindow([string]$Root) {
    <# Check & repair: runs every check in the background, lists what was found and repairs the ticked problems. #>
    if (-not $Root) { $Root = $script:Root }
    $x = New-ThemedWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Check &amp; repair" Width="1060" Height="700" MinWidth="760" MinHeight="460" WindowStartupLocation="CenterOwner"
        Background="{StaticResource BgBrush}" Foreground="{StaticResource TextBrush}" FontFamily="Segoe UI" FontSize="14" TextOptions.TextFormattingMode="Display">
  <DockPanel Margin="22,18,22,16">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <TextBlock x:Name="Head" Style="{StaticResource H2}" FontSize="18"/>
      <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,2,0,8"
                 Text="Looks for the usual ways a server breaks: a moved folder, missing files or libraries, a database that won't start or can't log in, outdated helper scripts, scheduled tasks or shortcuts pointing to old places, ports used by another program, and more. Nothing is changed until you click Repair."/>
      <DockPanel>
        <CheckBox x:Name="ChkAll" DockPanel.Dock="Right" Content="Show passed checks" VerticalAlignment="Center"/>
        <TextBlock x:Name="Summary" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
      </DockPanel>
    </StackPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" DockPanel.Dock="Right">
        <Button x:Name="BtnCopy" Content="Copy report" ToolTip="Copies the results as text, e.g. to paste into a GitHub issue (no passwords are included)"/>
        <Button x:Name="BtnScan" Content="Check again"/>
        <Button x:Name="BtnFix" Style="{StaticResource Primary}" Content="Repair selected"/>
        <Button x:Name="BtnClose" Content="Close" Margin="0"/>
      </StackPanel>
      <TextBlock x:Name="Info" Style="{StaticResource Muted}" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
    </DockPanel>
    <DataGrid x:Name="Grid" IsReadOnly="False">
      <DataGrid.RowStyle>
        <Style TargetType="DataGridRow">
          <Style.Triggers>
            <DataTrigger Binding="{Binding Status}" Value="Problem"><Setter Property="Foreground" Value="#F08A84"/></DataTrigger>
            <DataTrigger Binding="{Binding Status}" Value="Warning"><Setter Property="Foreground" Value="#E7B65A"/></DataTrigger>
            <DataTrigger Binding="{Binding Status}" Value="OK"><Setter Property="Foreground" Value="#8FCFAA"/></DataTrigger>
            <DataTrigger Binding="{Binding Status}" Value="Skipped"><Setter Property="Foreground" Value="#7D8392"/></DataTrigger>
          </Style.Triggers>
        </Style>
      </DataGrid.RowStyle>
      <DataGrid.Columns>
        <DataGridTemplateColumn Header="Repair" Width="64">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate><CheckBox IsChecked="{Binding Include, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanFix}" HorizontalAlignment="Center"/></DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
        <DataGridTextColumn Header="" Binding="{Binding Icon}" Width="30" IsReadOnly="True"/>
        <DataGridTextColumn Header="Area" Binding="{Binding Area}" Width="110" IsReadOnly="True"/>
        <DataGridTextColumn Header="Check" Binding="{Binding Check}" Width="2*" IsReadOnly="True"/>
        <DataGridTemplateColumn Header="What was found" Width="4*" IsReadOnly="True">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate><TextBlock Text="{Binding Detail}" TextWrapping="Wrap" Margin="4,3"/></DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
        <DataGridTemplateColumn Header="Repair does" Width="3*" IsReadOnly="True">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate><TextBlock Text="{Binding Fix}" TextWrapping="Wrap" Margin="4,3"/></DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
      </DataGrid.Columns>
    </DataGrid>
  </DockPanel>
</Window>
'@
    $x.Head.Text = "Check & repair: $((Get-ServerSettings $Root).RealmName)"
    $x.Root = $Root; $x.Task = $null; $x.Rows = @(); $x.Repaired = $false
    $x.Show = {
        $x = $x   # local, so nested closures capture it
        $x.Grid.ItemsSource = @($x.Rows | Where-Object { $x.ChkAll.IsChecked -or $_.Status -ne 'OK' })
    }.GetNewClosure()
    $x.Busy = { param($on) $x.BtnScan.IsEnabled = -not $on; $x.BtnFix.IsEnabled = -not $on; if ($on) { $x.Window.Cursor = 'AppStarting' } else { $x.Window.Cursor = $null } }.GetNewClosure()
    $x.OnScan = {
        param($res, $err)
        $x = $x
        & $x.Busy $false; $x.Task = $null
        if ($err) { $x.Info.Text = "The check failed: $($err.Message)"; return }
        $rank = @{ Problem = 0; Warning = 1; Skipped = 2; OK = 3 }
        $i = 0
        $rows = foreach ($r in @($res | Where-Object { $_ -and $_.Id })) {
            $row = [RepairRow]::new()
            $row.Id = $r.Id; $row.Status = $r.Status; $row.Area = $r.Area; $row.Check = $r.Check; $row.Detail = $r.Detail; $row.Fix = $r.Fix
            $row.CanFix = [bool]$r.CanFix; $row.Include = [bool]$r.CanFix; $row.Order = $rank["$($r.Status)"] * 1000 + $i++
            $row.Icon = switch ($r.Status) { 'Problem' { '✖' } 'Warning' { '⚠' } 'OK' { '✔' } default { '–' } }
            $row
        }
        $x.Rows = @($rows | Sort-Object Order)
        $p = @($x.Rows | Where-Object Status -eq 'Problem').Count; $w = @($x.Rows | Where-Object Status -eq 'Warning').Count
        $ok = @($x.Rows | Where-Object Status -eq 'OK').Count; $fixable = @($x.Rows | Where-Object CanFix).Count
        $x.Summary.Text = if ($p + $w -eq 0) { "✔ Everything looks fine ($ok checks passed)." } else { "$p problem(s), $w warning(s), $ok checks passed." }
        $x.Summary.Foreground = Get-Brush $(if ($p) { 'BadBrush' } elseif ($w) { 'WarnBrush' } else { 'GoodBrush' })
        if ($p + $w -eq 0) { $x.ChkAll.IsChecked = $true }   # all good: show what was checked instead of an empty list
        $x.Info.Text = if ($fixable) { "$fixable can be repaired automatically - they are ticked. Click 'Repair selected'." } elseif ($p + $w) { 'Nothing here can be repaired automatically - the text says what to do.' } else { '' }
        & $x.Show
    }.GetNewClosure()
    $x.Scan = {
        $x = $x
        & $x.Busy $true; $x.Info.Text = 'Checking...'; $x.Summary.Text = 'Checking...'; $x.Summary.Foreground = Get-Brush 'TextBrush'
        $x.Task = Start-BgTask -Script { param($r) @(Get-ServerRepairReport $r) } -Arguments @($x.Root) -OnDone $x.OnScan
    }.GetNewClosure()
    $x.OnFix = {
        param($res, $err)
        $x = $x
        & $x.Busy $false; $x.Task = $null; $x.Repaired = $true
        Show-Message $(if ($err) { "The repair stopped: $($err.Message)" } else { (@($res | Where-Object { $_ }) -join "`n") + "`n`nThe checks run again now." }) 'Check & repair'
        & $x.Scan
    }.GetNewClosure()
    $x.Fix = {
        $x = $x
        $sel = @($x.Rows | Where-Object { $_.Include -and $_.CanFix })
        if (-not $sel.Count) { $x.Info.Text = 'Tick at least one problem that has a repair.'; return }
        $list = ($sel | ForEach-Object { "$($_.Check): $($_.Fix)" }) -join "`n  • "
        if (-not (Confirm-Action "Repair these?`n`n  • $list`n`nA log is saved in the server's .creationtool folder." 'Check & repair')) { return }
        & $x.Busy $true; $x.Info.Text = 'Repairing...'
        $x.Task = Start-BgTask -Script { param($r, $ids) @(Invoke-ServerRepair $r $ids) } -Arguments @($x.Root, @($sel | ForEach-Object Id)) -OnDone $x.OnFix
    }.GetNewClosure()
    # Live progress of the running check/repair.
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $timer.Add_Tick({ if ($x.Task -and $x.Task.Sync.Detail) { $x.Info.Text = $x.Task.Sync.Detail } }.GetNewClosure())
    $timer.Start()
    $x.Window.Add_Closed({ $timer.Stop() }.GetNewClosure())
    $x.ChkAll.Add_Click({ & $x.Show }.GetNewClosure())
    $x.BtnScan.Add_Click({ & $x.Scan }.GetNewClosure())
    $x.BtnCopy.Add_Click({
        $s = Get-ServerSettings $x.Root
        $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        $lines = @("AzerothCore Control Center $((Get-AppInfo).version) - Check & repair report", "Server: $($s.RealmName) | expansion $($s.Expansion) | $($s.Bots) bots | modules: $(@($s.Modules) -join ', ')", "Windows: $os | PowerShell $($PSVersionTable.PSVersion)", '')
        $lines += @($x.Rows | ForEach-Object { "[$($_.Status)] $($_.Area) / $($_.Check): $($_.Detail)$(if ($_.Fix) { "  -> repair: $($_.Fix)" })" })
        [Windows.Clipboard]::SetText(($lines -join "`r`n"))
        $x.Info.Text = 'Report copied to the clipboard.'
    }.GetNewClosure())
    $x.BtnFix.Add_Click({ & $x.Fix }.GetNewClosure())
    $x.BtnClose.Add_Click({ $x.Window.Close() }.GetNewClosure())
    $x.Window.Add_Closing({ param($s, $e) if ($x.Task) { $e.Cancel = $true; $x.Info.Text = 'Please wait until the current step has finished.' } }.GetNewClosure())
    & $x.Scan
    Show-AppDialog $x
    $x.Repaired
}
