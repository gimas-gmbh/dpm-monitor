#Requires -Version 5.1
<#
    .SYNOPSIS
    Renders the configuration UI with synthetic data into PNG files.
    Development only: lets you check the layout without a DPM server.
    Windows appear briefly on screen while they are captured.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutDir,
    # Shown in the status line; defaults to the version nbgv computes.
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\Configure.ps1')
. (Join-Path $root 'tests\TestHelpers.ps1')
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

if (-not $Version) {
    $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $root
    try { $json = & dotnet tool run nbgv get-version --format json 2>$null }
    finally { Pop-Location }
    $ErrorActionPreference = 'Stop'
    $Version = if ($LASTEXITCODE -eq 0 -and $json) { (($json -join "`n") | ConvertFrom-Json).SimpleVersion } else { '0.0.0-dev' }
}

if (-not ('PreviewTool.Dwm' -as [type])) {
    Add-Type -Namespace PreviewTool -Name Dwm -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);
'@
}

# Captures the window as it appears on screen. Form.DrawToBitmap would draw
# a legacy frame: on Windows 10/11 the desktop window manager draws title bar
# and border, not the window itself.
function Save-FormImage {
    param($Form, [string]$Name)
    $Form.TopMost = $true
    $Form.Activate()
    for ($i = 0; $i -lt 10; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    $r = New-Object PreviewTool.Dwm+RECT
    # 9 = DWMWA_EXTENDED_FRAME_BOUNDS: the visible frame without the invisible resize border
    [void][PreviewTool.Dwm]::DwmGetWindowAttribute($Form.Handle, 9, [ref]$r, [Runtime.InteropServices.Marshal]::SizeOf($r))
    $width = $r.Right - $r.Left
    $height = $r.Bottom - $r.Top
    $bmp = New-Object Drawing.Bitmap($width, $height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object Drawing.Size($width, $height)))
    $g.Dispose()
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
    Exclusions = @([pscustomobject]@{ ProductionServerName = 'srv-hv01.example.local'; LogicalPath = 'Host Component'; Reason = 'Wird separat gesichert'; Until = '2026-12-31' })
    Overrides  = @([pscustomobject]@{ ProtectionGroup = 'PG Hyper-V'; WeekDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'); TimesOfDay = @('22:00') })
}
$form = Show-MainForm -Ctx $ctx -PassThru
$form.StartPosition = 'Manual'
$form.Location = New-Object Drawing.Point(40, 40)
$form.Show()
# Fixed time, so the synthetic data always look the same.
$ctx.FixedNow = [TimeZoneInfo]::ConvertTimeToUtc((Get-Date '2026-11-20 14:00'))
$ctx.StatusLabel.Text = "Version $Version  ·  Aufgabe: Ready  ·  letzte Prüfung 20.11.2026 12:00: FEHLER  ·  nächste 20.11.2026 16:00"
$ctx.State = New-TestState -Groups @($groups)
Update-Evaluation $ctx
$form.Activate()
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
Save-DialogImage 'dialog-connection' { Show-ConnectionDialog -Config (Get-DpmMonitorDefaultConfig) -Heading "$script:Title $Version installieren" -OkText 'Installieren' }

$ctx.Dirty = $false
$form.Close()
Get-ChildItem -LiteralPath $OutDir -Filter *.png | ForEach-Object { $_.FullName }
