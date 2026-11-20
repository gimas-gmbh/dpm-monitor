#Requires -Version 5.1
<#
    .SYNOPSIS
    Renders the configuration UI with synthetic data into PNG files.
    Development only: lets you check the layout without a DPM server.
    Windows appear briefly on screen while they are captured.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutDir)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\Configure.ps1')
. (Join-Path $root 'tests\TestHelpers.ps1')
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

function Save-FormImage {
    param($Form, [string]$Name)
    $bmp = New-Object Drawing.Bitmap($Form.Width, $Form.Height)
    $Form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $Form.Width, $Form.Height)))
    $bmp.Save((Join-Path $OutDir "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# Captures the next modal dialog shortly after it opens, then closes it.
function Save-DialogImage {
    param([string]$Name, [scriptblock]$Open)
    $script:PreviewName = $Name
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
            $this.Stop()
            $dialog = [Windows.Forms.Application]::OpenForms[[Windows.Forms.Application]::OpenForms.Count - 1]
            Save-FormImage $dialog $script:PreviewName
            $dialog.DialogResult = 'Cancel'
        })
    $timer.Start()
    & $Open | Out-Null
    $timer.Dispose()
}

# Synthetic state from the test fixture.
$fixture = Import-FixtureServer
$groups = foreach ($g in $fixture.Groups) {
    $ds = foreach ($d in $g.Datasources) {
        New-TestDatasource -Path $d.LogicalPath -Server $d.ProductionServerName -Type (($d.Type -split '\.')[-1]) -Latest $d.LatestRecoveryPoint -State $d.State
    }
    New-TestGroup -Name $g.Group.FriendlyName -Schedules @($g.Schedules | ConvertTo-DpmMonitorSchedule) -Datasources @($ds)
}

$ctx = New-Context -InstallPath (Join-Path $env:TEMP 'DpmMonitorPreview')
$ctx.Config = New-TestConfig @{
    Exclusions = @([pscustomobject]@{ ProductionServerName = 'srv-sql01.example.local'; LogicalPath = 'SRV-SQL01\ArchiveDb'; Reason = 'Archiv, nur noch lesend'; Until = '2026-12-31' })
    Overrides  = @([pscustomobject]@{ ProtectionGroup = 'PG Hyper-V'; WeekDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'); TimesOfDay = @('22:00') })
}
$form = Show-MainForm -Ctx $ctx -PassThru
$form.StartPosition = 'Manual'
$form.Location = New-Object Drawing.Point(40, 40)
$form.Show()
$ctx.StatusLabel.Text = 'Version 0.1.0  ·  Aufgabe: Ready  ·  letzte Prüfung 20.11.2026 12:00: OK  ·  nächste 20.11.2026 16:00'
$ctx.State = New-TestState -Groups @($groups)
Update-Evaluation $ctx
$ctx.DatasourceList.Items[0].Selected = $true
[Windows.Forms.Application]::DoEvents()

$tabs = $form.Controls | Where-Object { $_ -is [Windows.Forms.TabControl] }
for ($i = 0; $i -lt $tabs.TabPages.Count; $i++) {
    $tabs.SelectedIndex = $i
    [Windows.Forms.Application]::DoEvents()
    Save-FormImage $form ("main-{0}" -f ($i + 1))
}

$item = $ctx.DatasourceList.Items[0].Tag
Save-DialogImage 'dialog-exclusion' { Show-ExclusionDialog -Item $item }
Save-DialogImage 'dialog-rule' { Show-RuleDialog -Item $item }
Save-DialogImage 'dialog-connection' { Show-ConnectionDialog -Config (Get-DpmMonitorDefaultConfig) -Heading 'dpm-monitor 0.1.0 installieren' -OkText 'Installieren' }

$ctx.Dirty = $false
$form.Close()
Get-ChildItem -LiteralPath $OutDir -Filter *.png | ForEach-Object { $_.FullName }
