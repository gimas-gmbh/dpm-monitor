#Requires -Version 5.1
<#
    .SYNOPSIS
    dpm-monitor: Oberfläche zum Installieren, Konfigurieren, Aktualisieren und Entfernen.

    Start über Konfigurieren.cmd (Doppelklick). Das Skript fordert selbst
    Administratorrechte an. Alle Aktionen laufen über DpmMonitor.psm1.
#>
# UI helpers change controls, not system state; variables used only inside event handlers look unused.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:PackagePath = $PSScriptRoot
Import-Module (Join-Path $script:PackagePath 'DpmMonitor.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Crisp on high-DPI screens (e.g. 4K): without this, Windows stretches the
# DPI-unaware PowerShell window as a bitmap and the text gets blurry. Fonts
# are given in points and scale by themselves; pixel sizes use Get-Px.
if (-not ('DpmMonitorUi.Dpi' -as [type])) {
    Add-Type -Namespace DpmMonitorUi -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
}
[void][DpmMonitorUi.Dpi]::SetProcessDPIAware()
$graphics = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:Scale = $graphics.DpiX / 96
$graphics.Dispose()

function Get-Px {
    param([double]$Value)
    [int][Math]::Round($Value * $script:Scale)
}

function New-ScaledSize {
    param([double]$Width, [double]$Height)
    New-Object Drawing.Size((Get-Px $Width), (Get-Px $Height))
}

function New-ScaledPadding {
    param([Parameter(ValueFromRemainingArguments)][double[]]$Value)
    if ($Value.Count -eq 1) { return New-Object Windows.Forms.Padding((Get-Px $Value[0])) }
    New-Object Windows.Forms.Padding((Get-Px $Value[0]), (Get-Px $Value[1]), (Get-Px $Value[2]), (Get-Px $Value[3]))
}
[Windows.Forms.Application]::EnableVisualStyles()

$script:Font = New-Object Drawing.Font('Segoe UI', 9)
$script:Title = 'gimas DPM Monitor'
$script:IconFile = Join-Path $script:PackagePath 'DpmMonitor.ico'
$script:Icon = if (Test-Path -LiteralPath $script:IconFile) { New-Object Drawing.Icon($script:IconFile) } else { $null }
$script:StatusText = @{ Ok = 'OK'; Warning = 'Warnung'; Failed = 'Fehler'; Excluded = 'Ausgenommen' }
$script:StatusColor = @{
    Ok       = [Drawing.Color]::FromArgb(230, 245, 230)
    Warning  = [Drawing.Color]::FromArgb(255, 245, 210)
    Failed   = [Drawing.Color]::FromArgb(250, 220, 220)
    Excluded = [Drawing.Color]::FromArgb(235, 235, 235)
}
$script:Presets = @('Täglich', 'Werktags (Mo–Fr)', 'Wöchentlich', 'Eigene Wochentage', 'Höchstalter in Stunden')
$script:DayOrder = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$script:DayShort = @{ Monday = 'Mo'; Tuesday = 'Di'; Wednesday = 'Mi'; Thursday = 'Do'; Friday = 'Fr'; Saturday = 'Sa'; Sunday = 'So' }

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Show-Message {
    param([string]$Text, [ValidateSet('Info', 'Warning', 'Error')][string]$Kind = 'Info')
    $icon = @{ Info = 'Information'; Warning = 'Warning'; Error = 'Error' }[$Kind]
    [void][Windows.Forms.MessageBox]::Show($Text, $script:Title, 'OK', $icon)
}

function Confirm-Action {
    param([string]$Text)
    [Windows.Forms.MessageBox]::Show($Text, $script:Title, 'YesNo', 'Question') -eq 'Yes'
}

function New-Control {
    param([string]$Type, [hashtable]$Property = @{})
    $c = New-Object "System.Windows.Forms.$Type"
    $c.Font = $script:Font
    foreach ($k in $Property.Keys) { $c.$k = $Property[$k] }
    $c
}

function New-Dialog {
    param([string]$Text, [int]$Width = 520, [int]$Height = 360)
    $dialog = New-Control Form @{
        Text            = $Text
        ClientSize      = (New-ScaledSize $Width $Height)
        StartPosition   = 'CenterParent'
        FormBorderStyle = 'FixedDialog'
        MaximizeBox     = $false
        MinimizeBox     = $false
        ShowInTaskbar   = $false
    }
    if ($script:Icon) { $dialog.Icon = $script:Icon }
    $dialog
}

# Vertical stack of rows inside a dialog.
function New-Stack {
    New-Control FlowLayoutPanel @{ Dock = 'Fill'; FlowDirection = 'TopDown'; WrapContents = $false; Padding = (New-ScaledPadding 12); AutoScroll = $true }
}

function Add-DialogButton {
    param($Form, [string]$OkText = 'OK')
    $panel = New-Control FlowLayoutPanel @{ Dock = 'Bottom'; FlowDirection = 'RightToLeft'; Height = (Get-Px 44); Padding = (New-ScaledPadding 8) }
    $cancel = New-Control Button @{ Text = 'Abbrechen'; DialogResult = 'Cancel'; AutoSize = $true }
    $ok = New-Control Button @{ Text = $OkText; AutoSize = $true }
    $panel.Controls.AddRange(@($cancel, $ok))
    $Form.Controls.Add($panel)
    $Form.AcceptButton = $ok
    $Form.CancelButton = $cancel
    $ok
}

function Format-LocalTime {
    param($Time)
    if ($null -eq $Time) { return '-' }
    $t = [datetime]$Time
    if ($t.Kind -eq 'Utc') { $t = $t.ToLocalTime() }
    $t.ToString('dd.MM.yyyy HH:mm')
}

function Get-ItemLabel {
    param($Item)
    "[$($Item.ProtectionGroup)] $($Item.ProductionServerName) | $($Item.LogicalPath)"
}

function Get-RuleTargetText {
    param($Rule)
    $pg = [string]$Rule.ProtectionGroup
    $path = if ($Rule.PSObject.Properties['LogicalPath']) { [string]$Rule.LogicalPath } else { '' }
    if ($path) { "$($Rule.ProductionServerName) | $path" } else { ('Schutzgruppe „{0}“' -f $pg) }
}

function Get-RuleDetailText {
    param($Rule)
    if ($Rule.PSObject.Properties['MaxAgeHours'] -and "$($Rule.MaxAgeHours)" -ne '') { return "Höchstalter $($Rule.MaxAgeHours) Stunden" }
    $days = @($Rule.WeekDays | ForEach-Object { $script:DayShort["$_"] }) -join ', '
    "$days um $(@($Rule.TimesOfDay) -join ', ')"
}

function Test-SameTarget {
    param($A, $B)
    $get = { param($o, $n) if ($o.PSObject.Properties[$n]) { [string]$o.$n } else { '' } }
    (& $get $A 'ProtectionGroup') -eq (& $get $B 'ProtectionGroup') -and
    (& $get $A 'ProductionServerName') -eq (& $get $B 'ProductionServerName') -and
    (& $get $A 'LogicalPath') -eq (& $get $B 'LogicalPath')
}

# Target of a new rule: one data source, or its whole protection group.
function New-RuleTarget {
    param($Item, [bool]$WholeGroup)
    if ($WholeGroup) { [ordered]@{ ProtectionGroup = $Item.ProtectionGroup } }
    else { [ordered]@{ ProductionServerName = $Item.ProductionServerName; LogicalPath = $Item.LogicalPath } }
}

# ---------------------------------------------------------------------------
# Dialogs
# ---------------------------------------------------------------------------

function Show-ConnectionDialog {
    <# Ping URL and proxy. Returns $true if the values were changed. #>
    param($Config, [string]$Heading, [string]$OkText = 'OK')
    $form = New-Dialog -Text $script:Title -Height 330
    $stack = New-Stack
    $stack.Controls.Add((New-Control Label @{ Text = $Heading; AutoSize = $true; MaximumSize = (New-ScaledSize 480 0); Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold) }))
    $stack.Controls.Add((New-Control Label @{ AutoSize = $true; MaximumSize = (New-ScaledSize 480 0); Text = "In Healthchecks.io einen Check für diesen Server anlegen: Periode 4 Stunden, Grace Time 2 Stunden. Dessen Ping-URL hier eintragen." }))
    $stack.Controls.Add((New-Control Label @{ Text = 'Ping-URL'; AutoSize = $true; Margin = (New-ScaledPadding 3 12 3 0) }))
    $url = New-Control TextBox @{ Width = (Get-Px 480); Text = [string]$Config.PingUrl }
    $stack.Controls.Add($url)
    $stack.Controls.Add((New-Control Label @{ Text = 'Proxy (nur falls nötig, z. B. http://proxy:8080)'; AutoSize = $true; Margin = (New-ScaledPadding 3 12 3 0) }))
    $proxy = New-Control TextBox @{ Width = (Get-Px 480); Text = [string]$Config.Proxy }
    $stack.Controls.Add($proxy)
    $form.Controls.Add($stack)
    $ok = Add-DialogButton -Form $form -OkText $OkText
    $ok.Add_Click({
            $probe = $Config.PSObject.Copy()
            $probe.PingUrl = $url.Text.Trim()
            $probe.Proxy = $proxy.Text.Trim()
            $errors = @(Test-DpmMonitorConfig -Config $probe)
            if ($errors.Count -gt 0) { Show-Message ($errors -join "`n") 'Warning'; return }
            $form.DialogResult = 'OK'
        })
    if ($form.ShowDialog() -ne 'OK') { return $false }
    $Config.PingUrl = $url.Text.Trim()
    $Config.Proxy = $proxy.Text.Trim()
    $true
}

function Show-ExclusionDialog {
    <# Returns a new exclusion or $null. #>
    param($Item)
    $form = New-Dialog -Text 'Ausnahme festlegen' -Height 320
    $stack = New-Stack
    $stack.Controls.Add((New-Control Label @{ Text = (Get-ItemLabel $Item); AutoSize = $true; MaximumSize = (New-ScaledSize 480 0) }))
    $single = New-Control RadioButton @{ Text = 'Nur diese Datenquelle'; Checked = $true; AutoSize = $true; Margin = (New-ScaledPadding 3 10 3 0) }
    $group = New-Control RadioButton @{ Text = ('Ganze Schutzgruppe „{0}“' -f $Item.ProtectionGroup); AutoSize = $true }
    $stack.Controls.AddRange(@($single, $group))
    $stack.Controls.Add((New-Control Label @{ Text = 'Grund (Pflicht)'; AutoSize = $true; Margin = (New-ScaledPadding 3 10 3 0) }))
    $reason = New-Control TextBox @{ Width = (Get-Px 480) }
    $stack.Controls.Add($reason)
    $limited = New-Control CheckBox @{ Text = 'Befristet bis einschließlich'; Checked = $true; AutoSize = $true; Margin = (New-ScaledPadding 3 10 3 0) }
    $until = New-Control DateTimePicker @{ Format = 'Short'; Value = (Get-Date).Date.AddDays(30); Width = (Get-Px 140) }
    $limited.Add_CheckedChanged({ $until.Enabled = $limited.Checked })
    $stack.Controls.AddRange(@($limited, $until))
    $form.Controls.Add($stack)
    $ok = Add-DialogButton -Form $form
    $ok.Add_Click({
            if ($reason.Text.Trim() -eq '') { Show-Message 'Bitte einen Grund angeben.' 'Warning'; return }
            $form.DialogResult = 'OK'
        })
    if ($form.ShowDialog() -ne 'OK') { return $null }
    $ex = New-RuleTarget -Item $Item -WholeGroup $group.Checked
    $ex.Reason = $reason.Text.Trim()
    if ($limited.Checked) { $ex.Until = $until.Value.ToString('yyyy-MM-dd') }
    [pscustomobject]$ex
}

function Show-RuleDialog {
    <# Returns a new override (expected schedule or maximum age) or $null. #>
    param($Item)
    $form = New-Dialog -Text 'Erwarteten Rhythmus festlegen' -Height 390
    $stack = New-Stack
    $stack.Controls.Add((New-Control Label @{ Text = (Get-ItemLabel $Item); AutoSize = $true; MaximumSize = (New-ScaledSize 480 0) }))
    $stack.Controls.Add((New-Control Label @{ AutoSize = $true; MaximumSize = (New-ScaledSize 480 0); Text = 'Ersetzt den aus DPM gelesenen Zeitplan. Nur nötig, wenn der DPM-Zeitplan nicht passt.' }))
    $single = New-Control RadioButton @{ Text = 'Nur diese Datenquelle'; Checked = $true; AutoSize = $true; Margin = (New-ScaledPadding 3 10 3 0) }
    $group = New-Control RadioButton @{ Text = ('Ganze Schutzgruppe „{0}“' -f $Item.ProtectionGroup); AutoSize = $true }
    $stack.Controls.AddRange(@($single, $group))
    $preset = New-Control ComboBox @{ DropDownStyle = 'DropDownList'; Width = (Get-Px 220); Margin = (New-ScaledPadding 3 10 3 3) }
    [void]$preset.Items.AddRange($script:Presets)
    $preset.SelectedIndex = 0
    $stack.Controls.Add($preset)

    $dayPanel = New-Control FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false }
    $dayBoxes = @{}
    foreach ($d in $script:DayOrder) {
        $cb = New-Control CheckBox @{ Text = $script:DayShort[$d]; AutoSize = $true; Checked = ($d -eq 'Friday') }
        $dayBoxes[$d] = $cb
        $dayPanel.Controls.Add($cb)
    }
    $stack.Controls.Add($dayPanel)
    $timeRow = New-Control FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false }
    $timeRow.Controls.Add((New-Control Label @{ Text = 'Uhrzeit(en):'; AutoSize = $true; Margin = (New-ScaledPadding 3 6 3 3) }))
    $times = New-Control TextBox @{ Width = (Get-Px 160); Text = '20:00' }
    $timeRow.Controls.Add($times)
    $stack.Controls.Add($timeRow)
    $hoursRow = New-Control FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false }
    $hoursRow.Controls.Add((New-Control Label @{ Text = 'Höchstalter (Stunden):'; AutoSize = $true; Margin = (New-ScaledPadding 3 6 3 3) }))
    $hours = New-Control NumericUpDown @{ Minimum = 1; Maximum = 2000; Value = 26; Width = (Get-Px 80) }
    $hoursRow.Controls.Add($hours)
    $stack.Controls.Add($hoursRow)

    $update = {
        $i = $preset.SelectedIndex
        $dayPanel.Visible = $i -in 2, 3
        $timeRow.Visible = $i -ne 4
        $hoursRow.Visible = $i -eq 4
    }
    $preset.Add_SelectedIndexChanged($update)
    & $update
    $form.Controls.Add($stack)

    $ok = Add-DialogButton -Form $form
    $ok.Add_Click({
            $form.Tag = $null
            $rule = New-RuleTarget -Item $Item -WholeGroup $group.Checked
            switch ($preset.SelectedIndex) {
                0 { $rule.WeekDays = $script:DayOrder }
                1 { $rule.WeekDays = $script:DayOrder[0..4] }
                4 { $rule.MaxAgeHours = [int]$hours.Value }
                default { $rule.WeekDays = @($script:DayOrder | Where-Object { $dayBoxes[$_].Checked }) }
            }
            if ($preset.SelectedIndex -ne 4) {
                $rule.TimesOfDay = @($times.Text -split '[,; ]+' | Where-Object { $_ })
            }
            $probe = Get-DpmMonitorDefaultConfig
            $probe.PingUrl = 'https://example.invalid/'
            $probe.Overrides = @([pscustomobject]$rule)
            $errors = @(Test-DpmMonitorConfig -Config $probe | Where-Object { $_ -like 'Regel*' })
            if ($errors.Count -gt 0) { Show-Message (($errors -replace '^Regel 1: ', '') -join "`n") 'Warning'; return }
            $form.Tag = [pscustomobject]$rule
            $form.DialogResult = 'OK'
        })
    if ($form.ShowDialog() -ne 'OK') { return $null }
    $form.Tag
}

function Show-ReportDialog {
    param([string]$Heading, [string]$Text)
    $form = New-Dialog -Text $script:Title -Width 640 -Height 420
    $form.FormBorderStyle = 'Sizable'
    $label = New-Control Label @{ Text = $Heading; Dock = 'Top'; Height = (Get-Px 32); Padding = (New-ScaledPadding 8 8 8 0); Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold) }
    $box = New-Control TextBox @{ Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Dock = 'Fill'; Text = ($Text -replace "`r?`n", "`r`n"); Font = New-Object Drawing.Font('Consolas', 9) }
    $form.Controls.Add($box)
    $form.Controls.Add($label)
    $panel = New-Control FlowLayoutPanel @{ Dock = 'Bottom'; FlowDirection = 'RightToLeft'; Height = (Get-Px 44); Padding = (New-ScaledPadding 8) }
    $close = New-Control Button @{ Text = 'Schließen'; DialogResult = 'OK'; AutoSize = $true }
    $panel.Controls.Add($close)
    $form.Controls.Add($panel)
    $form.AcceptButton = $close
    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Invoke-WithWaitCursor {
    param($Form, [scriptblock]$Action)
    $old = $Form.Cursor
    $Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    $Form.Enabled = $false
    try { & $Action }
    finally {
        $Form.Enabled = $true
        $Form.Cursor = $old
    }
}

# Runs the scheduled task (as SYSTEM, including the ping) and shows the result.
function Invoke-TaskNow {
    param($Ctx, $Form, [string]$Heading = 'Ergebnis der Prüfung')
    $Ctx.StatusLabel.Text = 'Prüfung läuft als geplante Aufgabe (SYSTEM) ...'
    $run = Invoke-WithWaitCursor $Form {
        Start-DpmMonitorTask -InstallPath $Ctx.InstallPath -Confirm:$false -OnWait { [Windows.Forms.Application]::DoEvents() }
    }
    Update-StatusLine $Ctx
    if (-not $run.Completed) {
        Show-Message 'Die geplante Aufgabe ist nicht rechtzeitig fertig geworden. Details später im Protokoll.' 'Warning'
        return
    }
    if (-not $run.Result) {
        Show-Message "Die geplante Aufgabe lief, hat aber kein Ergebnis geschrieben (Rückgabewert $($run.LastTaskResult)). Möglicherweise verhindert eine Ausführungsrichtlinie den Start." 'Error'
        return
    }
    $r = $run.Result
    $ping = if ($null -eq $r.PingSuccess) { 'Keine Meldung an Healthchecks.io (Konfiguration unbrauchbar).' }
    elseif ($r.PingSuccess) { 'Healthchecks.io wurde benachrichtigt.' }
    else { "Healthchecks.io NICHT erreicht: $($r.PingError)" }
    Show-ReportDialog -Heading $Heading -Text "$($r.Report)`n`n$ping"
}

function Update-StatusLine {
    param($Ctx)
    $inst = Get-DpmMonitorInstallation -InstallPath $Ctx.InstallPath
    $parts = @("Version $($inst.Version)")
    if ($inst.TaskExists) {
        $parts += "Aufgabe: $($inst.TaskState)"
        $last = Read-DpmMonitorLastResult -Path $inst.ResultPath
        if ($last) {
            $txt = @{ Ok = 'OK'; Failed = 'FEHLER' }[[string]$last.Status]
            if ($last.ExitCode -eq 3) { $txt = 'Meldung an Healthchecks.io fehlgeschlagen' }
            $parts += "letzte Prüfung $(Format-LocalTime $last.Time): $txt"
        }
        if ($inst.NextRunTime) { $parts += "nächste $(Format-LocalTime $inst.NextRunTime)" }
    }
    else {
        $parts += 'Geplante Aufgabe fehlt!'
    }
    $Ctx.StatusLabel.Text = $parts -join '  ·  '
}

function Update-Evaluation {
    param($Ctx)
    $Ctx.DatasourceList.BeginUpdate()
    try {
        $Ctx.DatasourceList.Items.Clear()
        if ($null -eq $Ctx.State) { return }
        $Ctx.Evaluation = Invoke-DpmMonitorEvaluation -State $Ctx.State -Config $Ctx.Config -Now ([datetime]::UtcNow)
        $order = @{ Failed = 0; Warning = 1; Ok = 2; Excluded = 3 }
        foreach ($i in ($Ctx.Evaluation.Items | Sort-Object { $order[$_.Status] }, ProtectionGroup, LogicalPath)) {
            $row = New-Object Windows.Forms.ListViewItem($script:StatusText[$i.Status])
            [void]$row.SubItems.Add([string]$i.ProtectionGroup)
            [void]$row.SubItems.Add([string]$i.ProductionServerName)
            [void]$row.SubItems.Add([string]$i.LogicalPath)
            [void]$row.SubItems.Add((Format-LocalTime $i.LatestRecoveryPoint))
            [void]$row.SubItems.Add([string]$i.Reason)
            $row.BackColor = $script:StatusColor[$i.Status]
            $row.Tag = $i
            [void]$Ctx.DatasourceList.Items.Add($row)
        }
    }
    finally { $Ctx.DatasourceList.EndUpdate() }
    $failed = @($Ctx.Evaluation.Items | Where-Object Status -eq 'Failed').Count
    $Ctx.SummaryLabel.Text = "Bewertung mit der aktuellen (auch ungespeicherten) Konfiguration: $(@($Ctx.Evaluation.Items).Count) Datenquellen, $failed mit Fehler."
}

function Update-DatasourceState {
    param($Ctx, $Form)
    Invoke-WithWaitCursor $Form {
        try {
            $Ctx.SummaryLabel.Text = 'DPM wird gelesen ...'
            [Windows.Forms.Application]::DoEvents()
            $Ctx.State = Get-DpmMonitorState
        }
        catch {
            $Ctx.State = $null
            $Ctx.SummaryLabel.Text = "DPM konnte nicht gelesen werden: $($_.Exception.Message)"
        }
    }
    if ($Ctx.State) { Update-Evaluation $Ctx }
}

function Update-RuleList {
    param($Ctx)
    $list = $Ctx.RuleList
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($ex in @($Ctx.Config.Exclusions)) {
        $row = New-Object Windows.Forms.ListViewItem('Ausnahme')
        [void]$row.SubItems.Add((Get-RuleTargetText $ex))
        $until = if ($ex.PSObject.Properties['Until'] -and $ex.Until) { "bis $($ex.Until)" } else { 'unbefristet' }
        [void]$row.SubItems.Add("$($ex.Reason) ($until)")
        $row.Tag = $ex
        [void]$list.Items.Add($row)
    }
    foreach ($ov in @($Ctx.Config.Overrides)) {
        $row = New-Object Windows.Forms.ListViewItem('Eigener Rhythmus')
        [void]$row.SubItems.Add((Get-RuleTargetText $ov))
        [void]$row.SubItems.Add((Get-RuleDetailText $ov))
        $row.Tag = $ov
        [void]$list.Items.Add($row)
    }
    $list.EndUpdate()
}

function Set-Dirty {
    param($Ctx, [bool]$Value = $true)
    $Ctx.Dirty = $Value
    $Ctx.SaveButton.Enabled = $Value
    $Ctx.Form.Text = if ($Value) { "$script:Title – ungespeicherte Änderungen" } else { $script:Title }
}

function Save-Context {
    param($Ctx)
    $c = $Ctx.Config
    $c.MissedRunsThreshold = [int]$Ctx.ThresholdInput.Value
    $c.JobBufferHours = [int]$Ctx.BufferInput.Value
    $c.FallbackMaxAgeHours = if ($Ctx.FallbackCheck.Checked) { [int]$Ctx.FallbackInput.Value } else { $null }
    try {
        Save-DpmMonitorConfig -Config $c -Path $Ctx.ConfigPath
        Set-Dirty $Ctx $false
        $true
    }
    catch {
        Show-Message $_.Exception.Message 'Error'
        $false
    }
}

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

# Builds and shows the main window. The window is shown from inside this
# function on purpose: WinForms event handlers run in the scope that called
# ShowDialog, so they can only see the locals defined here.
function Show-MainForm {
    param($Ctx, [scriptblock]$OnShown, [switch]$PassThru)

    $form = New-Control Form @{ Text = $script:Title; ClientSize = (New-ScaledSize 1000 620); StartPosition = 'CenterScreen'; MinimumSize = (New-ScaledSize 800 480) }
    if ($script:Icon) { $form.Icon = $script:Icon }
    $Ctx.Form = $form

    $Ctx.StatusLabel = New-Control Label @{ Dock = 'Top'; Height = (Get-Px 30); Padding = (New-ScaledPadding 10 8 10 0) }
    $tabs = New-Control TabControl @{ Dock = 'Fill' }

    # --- Datenquellen ---
    $tabDs = New-Object Windows.Forms.TabPage('Datenquellen')
    $Ctx.SummaryLabel = New-Control Label @{ Dock = 'Top'; Height = (Get-Px 26); Padding = (New-ScaledPadding 4 6 4 0); Text = 'Noch nicht geladen.' }
    $list = New-Control ListView @{ View = 'Details'; FullRowSelect = $true; MultiSelect = $false; Dock = 'Fill'; HideSelection = $false }
    foreach ($col in @(@('Status', 90), @('Schutzgruppe', 150), @('Server', 190), @('Pfad', 200), @('Letzter Punkt', 110), @('Hinweis', 420))) {
        [void]$list.Columns.Add($col[0], (Get-Px $col[1]))
    }
    $Ctx.DatasourceList = $list
    $dsButtons = New-Control FlowLayoutPanel @{ Dock = 'Bottom'; Height = (Get-Px 40); Padding = (New-ScaledPadding 2) }
    $reload = New-Control Button @{ Text = 'Neu laden'; AutoSize = $true }
    $exclude = New-Control Button @{ Text = 'Ausnehmen …'; AutoSize = $true }
    $rule = New-Control Button @{ Text = 'Rhythmus festlegen …'; AutoSize = $true }
    $dsButtons.Controls.AddRange(@($reload, $exclude, $rule))
    $tabDs.Controls.AddRange(@($list, $Ctx.SummaryLabel, $dsButtons))

    # --- Ausnahmen und Regeln ---
    $tabRules = New-Object Windows.Forms.TabPage('Ausnahmen und Regeln')
    $rules = New-Control ListView @{ View = 'Details'; FullRowSelect = $true; MultiSelect = $false; Dock = 'Fill'; HideSelection = $false }
    foreach ($col in @(@('Art', 130), @('Gilt für', 330), @('Details', 480))) { [void]$rules.Columns.Add($col[0], (Get-Px $col[1])) }
    $Ctx.RuleList = $rules
    $ruleButtons = New-Control FlowLayoutPanel @{ Dock = 'Bottom'; Height = (Get-Px 40); Padding = (New-ScaledPadding 2) }
    $removeRule = New-Control Button @{ Text = 'Entfernen'; AutoSize = $true }
    $ruleButtons.Controls.Add($removeRule)
    $tabRules.Controls.AddRange(@($rules, $ruleButtons))

    # --- Einstellungen ---
    $tabSettings = New-Object Windows.Forms.TabPage('Einstellungen')
    $grid = New-Control TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 2; Padding = (New-ScaledPadding 12); AutoScroll = $true }
    [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    $addRow = {
        param([string]$Text, $Control)
        $grid.Controls.Add((New-Control Label @{ Text = $Text; AutoSize = $true; Margin = (New-ScaledPadding 3 7 12 3) }))
        $grid.Controls.Add($Control)
    }
    $urlRow = New-Control FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false }
    $Ctx.UrlLabel = New-Control Label @{ AutoSize = $true; Margin = (New-ScaledPadding 3 7 12 3) }
    $editUrl = New-Control Button @{ Text = 'Ändern …'; AutoSize = $true }
    $urlRow.Controls.AddRange(@($Ctx.UrlLabel, $editUrl))
    & $addRow 'Healthchecks.io' $urlRow
    $Ctx.ThresholdInput = New-Control NumericUpDown @{ Minimum = 1; Maximum = 10; Value = [int]$Ctx.Config.MissedRunsThreshold; Width = (Get-Px 70) }
    & $addRow 'Fehler ab verpassten Terminen' $Ctx.ThresholdInput
    $Ctx.BufferInput = New-Control NumericUpDown @{ Minimum = 0; Maximum = 24; Value = [int]$Ctx.Config.JobBufferHours; Width = (Get-Px 70) }
    & $addRow 'Puffer für Jobdauer (Stunden)' $Ctx.BufferInput
    $fallbackRow = New-Control FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false }
    $Ctx.FallbackCheck = New-Control CheckBox @{ Text = 'Höchstalter (Stunden), wenn kein Zeitplan ermittelbar ist:'; AutoSize = $true; Checked = ($null -ne $Ctx.Config.FallbackMaxAgeHours) }
    $Ctx.FallbackInput = New-Control NumericUpDown @{ Minimum = 1; Maximum = 2000; Width = (Get-Px 70); Value = $(if ($Ctx.Config.FallbackMaxAgeHours) { [int]$Ctx.Config.FallbackMaxAgeHours } else { 26 }) }
    $Ctx.FallbackInput.Enabled = $Ctx.FallbackCheck.Checked
    $fallbackRow.Controls.AddRange(@($Ctx.FallbackCheck, $Ctx.FallbackInput))
    & $addRow 'Rückfallebene' $fallbackRow
    $hint = New-Control Label @{ AutoSize = $true; MaximumSize = (New-ScaledSize 640 0); Margin = (New-ScaledPadding 3 16 3 3); Text = "Ein einzelner verpasster Termin wird toleriert und nur im Bericht erwähnt. Ohne Zeitplan und ohne Rückfallebene gilt eine Datenquelle als Fehler.`n`nIn Healthchecks.io: Periode 4 Stunden, Grace Time 2 Stunden." }
    $grid.Controls.Add((New-Control Label @{ Text = '' }))
    $grid.Controls.Add($hint)
    $tabSettings.Controls.Add($grid)

    # --- Protokoll ---
    $tabLog = New-Object Windows.Forms.TabPage('Protokoll')
    $logBox = New-Control TextBox @{ Multiline = $true; ReadOnly = $true; ScrollBars = 'Both'; WordWrap = $false; Dock = 'Fill'; Font = New-Object Drawing.Font('Consolas', 9) }
    $tabLog.Controls.Add($logBox)
    $loadLog = {
        $lines = if (Test-Path -LiteralPath $Ctx.LogPath) { Get-Content -LiteralPath $Ctx.LogPath -Tail 300 -Encoding UTF8 } else { @('(noch kein Protokoll)') }
        $logBox.Text = $lines -join "`r`n"
        $logBox.SelectionStart = $logBox.Text.Length
        $logBox.ScrollToCaret()
    }

    $tabs.TabPages.AddRange(@($tabDs, $tabRules, $tabSettings, $tabLog))

    # --- bottom buttons ---
    $bottom = New-Control FlowLayoutPanel @{ Dock = 'Bottom'; Height = (Get-Px 46); FlowDirection = 'RightToLeft'; Padding = (New-ScaledPadding 8) }
    $close = New-Control Button @{ Text = 'Schließen'; AutoSize = $true }
    $Ctx.SaveButton = New-Control Button @{ Text = 'Speichern'; AutoSize = $true; Enabled = $false }
    $runNow = New-Control Button @{ Text = 'Jetzt prüfen'; AutoSize = $true }
    $uninstall = New-Control Button @{ Text = 'Deinstallieren …'; AutoSize = $true }
    $bottom.Controls.AddRange(@($close, $Ctx.SaveButton, $runNow, $uninstall))

    $form.Controls.AddRange(@($tabs, $Ctx.StatusLabel, $bottom))

    # --- events ---
    $selected = { if ($list.SelectedItems.Count -eq 1) { $list.SelectedItems[0].Tag } else { $null } }
    $reload.Add_Click({ Update-DatasourceState $Ctx $form })
    $exclude.Add_Click({
            $item = & $selected
            if (-not $item) { Show-Message 'Bitte zuerst eine Datenquelle auswählen.'; return }
            $ex = Show-ExclusionDialog -Item $item
            if (-not $ex) { return }
            $Ctx.Config.Exclusions = @(@($Ctx.Config.Exclusions) | Where-Object { -not (Test-SameTarget $_ $ex) }) + $ex
            Set-Dirty $Ctx; Update-RuleList $Ctx; Update-Evaluation $Ctx
        })
    $rule.Add_Click({
            $item = & $selected
            if (-not $item) { Show-Message 'Bitte zuerst eine Datenquelle auswählen.'; return }
            $ov = Show-RuleDialog -Item $item
            if (-not $ov) { return }
            $Ctx.Config.Overrides = @(@($Ctx.Config.Overrides) | Where-Object { -not (Test-SameTarget $_ $ov) }) + $ov
            Set-Dirty $Ctx; Update-RuleList $Ctx; Update-Evaluation $Ctx
        })
    $list.Add_DoubleClick({ $exclude.PerformClick() })
    $removeRule.Add_Click({
            if ($rules.SelectedItems.Count -ne 1) { Show-Message 'Bitte zuerst einen Eintrag auswählen.'; return }
            $target = $rules.SelectedItems[0].Tag
            $Ctx.Config.Exclusions = @(@($Ctx.Config.Exclusions) | Where-Object { -not [object]::ReferenceEquals($_, $target) })
            $Ctx.Config.Overrides = @(@($Ctx.Config.Overrides) | Where-Object { -not [object]::ReferenceEquals($_, $target) })
            Set-Dirty $Ctx; Update-RuleList $Ctx; Update-Evaluation $Ctx
        })
    $editUrl.Add_Click({
            if (Show-ConnectionDialog -Config $Ctx.Config -Heading 'Verbindung zu Healthchecks.io') {
                $Ctx.UrlLabel.Text = $Ctx.Config.PingUrl
                Set-Dirty $Ctx
            }
        })
    foreach ($c in @($Ctx.ThresholdInput, $Ctx.BufferInput, $Ctx.FallbackInput)) {
        $c.Add_ValueChanged({
                Set-Dirty $Ctx
                $Ctx.Config.MissedRunsThreshold = [int]$Ctx.ThresholdInput.Value
                $Ctx.Config.JobBufferHours = [int]$Ctx.BufferInput.Value
                $Ctx.Config.FallbackMaxAgeHours = if ($Ctx.FallbackCheck.Checked) { [int]$Ctx.FallbackInput.Value } else { $null }
                if ($Ctx.State) { Update-Evaluation $Ctx }
            })
    }
    $Ctx.FallbackCheck.Add_CheckedChanged({
            $Ctx.FallbackInput.Enabled = $Ctx.FallbackCheck.Checked
            $Ctx.Config.FallbackMaxAgeHours = if ($Ctx.FallbackCheck.Checked) { [int]$Ctx.FallbackInput.Value } else { $null }
            Set-Dirty $Ctx
            if ($Ctx.State) { Update-Evaluation $Ctx }
        })
    $tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tabLog) { & $loadLog } })
    $Ctx.SaveButton.Add_Click({ [void](Save-Context $Ctx) })
    $runNow.Add_Click({
            if ($Ctx.Dirty) {
                if (-not (Confirm-Action 'Die geplante Aufgabe nutzt die gespeicherte Konfiguration. Jetzt speichern?')) { return }
                if (-not (Save-Context $Ctx)) { return }
            }
            Invoke-TaskNow -Ctx $Ctx -Form $form
        })
    $uninstall.Add_Click({
            $text = "dpm-monitor wirklich entfernen?`n`nGeplante Aufgabe, Skripte, Konfiguration und Protokoll werden gelöscht.`n`nWichtig: Den Check in Healthchecks.io vorher pausieren, sonst meldet er Alarm, sobald die Meldungen ausbleiben."
            if (-not (Confirm-Action $text)) { return }
            try {
                Uninstall-DpmMonitor -InstallPath $Ctx.InstallPath -Confirm:$false
                Show-Message 'dpm-monitor wurde entfernt. Bitte den Check in Healthchecks.io pausieren oder löschen.'
                $Ctx.Dirty = $false
                $form.Close()
            }
            catch { Show-Message "Entfernen fehlgeschlagen: $($_.Exception.Message)" 'Error' }
        })
    $close.Add_Click({ $form.Close() })
    $form.Add_FormClosing({
            if ($Ctx.Dirty -and -not (Confirm-Action 'Es gibt ungespeicherte Änderungen. Trotzdem schließen?')) { $_.Cancel = $true }
        })
    if ($OnShown) { $form.Add_Shown({ & $OnShown $Ctx $form }) }

    $Ctx.UrlLabel.Text = $Ctx.Config.PingUrl
    Update-RuleList $Ctx
    Set-Dirty $Ctx $false

    # Keep the window on screen when the scaled default size is too large
    # (e.g. 200 % scaling on a small display).
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $maxWidth = [int]($area.Width * 0.95)
    $maxHeight = [int]($area.Height * 0.95)
    if ($form.Width -gt $maxWidth -or $form.Height -gt $maxHeight) {
        $form.MinimumSize = New-Object Drawing.Size([Math]::Min($form.MinimumSize.Width, $maxWidth), [Math]::Min($form.MinimumSize.Height, $maxHeight))
        $form.Size = New-Object Drawing.Size([Math]::Min($form.Width, $maxWidth), [Math]::Min($form.Height, $maxHeight))
    }
    if ($PassThru) { return $form }
    [void]$form.ShowDialog()
}

function New-Context {
    param([string]$InstallPath)
    $paths = Get-DpmMonitorPath -InstallPath $InstallPath
    [pscustomobject]@{
        InstallPath    = $InstallPath
        ConfigPath     = $paths.ConfigPath
        LogPath        = $paths.LogPath
        Config         = $null
        State          = $null
        Evaluation     = $null
        Dirty          = $false
        Form           = $null
        StatusLabel    = $null
        SummaryLabel   = $null
        DatasourceList = $null
        RuleList       = $null
        SaveButton     = $null
        UrlLabel       = $null
        ThresholdInput = $null
        BufferInput    = $null
        FallbackCheck  = $null
        FallbackInput  = $null
    }
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-Configuration {
    $installPath = (Get-DpmMonitorPath).InstallPath
    $inst = Get-DpmMonitorInstallation -InstallPath $installPath
    $packageVersion = Get-DpmMonitorVersion
    $fromPackage = [IO.Path]::GetFullPath($script:PackagePath).TrimEnd('\') -ne [IO.Path]::GetFullPath($installPath).TrimEnd('\')

    $policyWarning = Get-DpmMonitorExecutionPolicyWarning
    if ($policyWarning) { Show-Message $policyWarning 'Warning' }

    if (-not $inst.Installed -or -not $inst.ConfigExists) {
        if (-not $fromPackage) { Show-Message 'Die Installation ist unvollständig. Bitte aus dem Installationspaket neu installieren.' 'Error'; return }
        $config = Get-DpmMonitorDefaultConfig
        $ok = Show-ConnectionDialog -Config $config -Heading "dpm-monitor $packageVersion installieren" -OkText 'Installieren'
        if (-not $ok) { return }
        try { Install-DpmMonitor -SourcePath $script:PackagePath -InstallPath $installPath -Config $config -Confirm:$false | Out-Null }
        catch { Show-Message "Installation fehlgeschlagen: $($_.Exception.Message)" 'Error'; return }
        $ctx = New-Context -InstallPath $installPath
        $ctx.Config = Read-DpmMonitorConfig -Path $ctx.ConfigPath
        Show-MainForm -Ctx $ctx -OnShown {
            param($Ctx, $Form)
            Update-StatusLine $Ctx
            Invoke-TaskNow -Ctx $Ctx -Form $Form -Heading 'Installiert. Ergebnis der ersten Prüfung:'
            Update-DatasourceState $Ctx $Form
        }
        return
    }

    if ($fromPackage) {
        $cmp = Compare-DpmMonitorVersion $packageVersion $inst.Version
        if ($cmp -gt 0 -or ($cmp -eq 0 -and (Confirm-Action "Version $packageVersion ist bereits installiert. Trotzdem neu einspielen?"))) {
            if ($cmp -le 0 -or (Confirm-Action "Installiert ist Version $($inst.Version). Auf Version $packageVersion aktualisieren? Die Konfiguration bleibt erhalten.")) {
                try { Install-DpmMonitor -SourcePath $script:PackagePath -InstallPath $installPath -Confirm:$false | Out-Null }
                catch { Show-Message "Aktualisierung fehlgeschlagen: $($_.Exception.Message)" 'Error'; return }
                Show-Message "dpm-monitor ist jetzt auf Version $packageVersion."
            }
        }
        elseif ($cmp -lt 0) {
            Show-Message "Installiert ist die neuere Version $($inst.Version). Dieses Paket ($packageVersion) wird nicht eingespielt."
        }
    }

    $ctx = New-Context -InstallPath $installPath
    try { $ctx.Config = Read-DpmMonitorConfig -Path $ctx.ConfigPath }
    catch {
        Show-Message "$($_.Exception.Message)`n`nBitte Ping-URL neu eingeben." 'Warning'
        $ctx.Config = Get-DpmMonitorDefaultConfig
        if (-not (Show-ConnectionDialog -Config $ctx.Config -Heading 'Verbindung zu Healthchecks.io')) { return }
        Save-DpmMonitorConfig -Config $ctx.Config -Path $ctx.ConfigPath
    }
    Show-MainForm -Ctx $ctx -OnShown {
        param($Ctx, $Form)
        Update-StatusLine $Ctx
        Update-DatasourceState $Ctx $Form
    }
}

# Dot-sourcing (development tools) only loads the functions.
if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-Administrator)) {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $powershell -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`""
        )
        return
    }
    try { Start-Configuration }
    catch { Show-Message "Unerwarteter Fehler: $($_.Exception.Message)" 'Error' }
}
