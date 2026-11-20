#Requires -Version 5.1
<#
    Runs inside Windows Sandbox (started by tools\Test-InSandbox.ps1).
    Installs dpm-monitor from the package like an admin would, runs the
    scheduled task as SYSTEM against a fake DPM module, updates, captures
    screenshots of the UI and uninstalls. Results go to C:\Results.
    The sandbox shuts down at the end.
#>
$ErrorActionPreference = 'Stop'
$in = 'C:\Test'
$out = 'C:\Results'
$results = [ordered]@{}

function Write-Step {
    param([string]$Text)
    Add-Content -LiteralPath (Join-Path $out 'steps.log') -Value ("{0:HH:mm:ss} {1}" -f (Get-Date), $Text) -Encoding UTF8
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Block)
    try {
        $value = & $Block
        $results[$Name] = [ordered]@{ Ok = $true; Value = $value }
        Write-Step "OK   $Name"
    }
    catch {
        $results[$Name] = [ordered]@{ Ok = $false; Error = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)" }
        Write-Step "FAIL $Name : $($_.Exception.Message)"
    }
}

function Save-Screenshot {
    param([string]$Name)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    # DPI-aware, otherwise only the top left part of a scaled screen is captured.
    if (-not ('SandboxTest.Dpi' -as [type])) {
        Add-Type -Namespace SandboxTest -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    }
    [void][SandboxTest.Dpi]::SetProcessDPIAware()
    $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object Drawing.Bitmap($b.Width, $b.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size)
    $bmp.Save((Join-Path $out "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

function Close-ConfigureWindow {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*Configure.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# Expand-Archive (module Microsoft.PowerShell.Archive) does not load in the sandbox.
function Expand-Package {
    param([string]$Zip, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $target = Join-Path $Destination ([IO.Path]::GetFileNameWithoutExtension($Zip))
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Destination)
}

# Starts the UI via Konfigurieren.cmd and photographs it. Started through
# cmd.exe: the shell would block on the security warning for a downloaded file.
function Test-Ui {
    param([string]$Folder, [string]$Name, [int]$WaitSeconds = 15)
    Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', "`"$(Join-Path $Folder 'Konfigurieren.cmd')`""
    Start-Sleep -Seconds $WaitSeconds
    Save-Screenshot $Name
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*Configure.ps1*' }).Count
    Close-ConfigureWindow
    "Configure.ps1-Prozesse: $running"
}

try {
    Write-Step 'Start'
    $packages = Get-ChildItem -LiteralPath $in -Filter 'dpm-monitor-*.zip' |
        Sort-Object { [version]($_.BaseName -replace '^dpm-monitor-', '') }
    $current = $packages[0]
    $newer = $packages[-1]
    $downloads = Join-Path $env:USERPROFILE 'Downloads'

    Invoke-Step 'Umgebung' {
        [ordered]@{
            OS                = (Get-CimInstance Win32_OperatingSystem).Caption
            PowerShell        = $PSVersionTable.PSVersion.ToString()
            SecurityProtocol  = [Net.ServicePointManager]::SecurityProtocol.ToString()
            ExecutionPolicies = (Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ', '
            Pakete            = ($packages.Name -join ', ')
        }
    }

    # Like a download from the internet: extracted files carry the zone mark.
    $pkg = $null
    Invoke-Step 'Paket entpacken (mit Internet-Zonenmarkierung)' {
        Expand-Package -Zip $current.FullName -Destination $downloads
        $script:pkg = Join-Path $downloads $current.BaseName
        Get-ChildItem -LiteralPath $script:pkg -File | ForEach-Object {
            Set-Content -LiteralPath $_.FullName -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
        }
        $script:pkg
    }
    $pkg = $script:pkg

    Invoke-Step 'Fake-DPM-Modul einspielen' {
        $target = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\DataProtectionManager'
        Copy-Item -LiteralPath (Join-Path $in 'DataProtectionManager') -Destination (Split-Path $target) -Recurse -Force
        (Get-Command Get-DPMProtectionGroup).Source
    }

    Invoke-Step 'Oberfläche vor der Installation' { Test-Ui -Folder $pkg -Name '1-installdialog' }

    Invoke-Step 'Installieren' {
        Import-Module (Join-Path $pkg 'DpmMonitor.psm1') -Force
        $config = Get-DpmMonitorDefaultConfig
        $config.PingUrl = 'https://hc-ping.com/00000000-0000-0000-0000-000000000000'
        $inst = Install-DpmMonitor -SourcePath $pkg -Config $config -Confirm:$false
        "Version $($inst.Version), Aufgabe $($inst.TaskState)"
    }

    $installPath = Join-Path $env:ProgramFiles 'DpmMonitor'
    Invoke-Step 'Dateien und Zonenmarkierung' {
        $files = Get-ChildItem -LiteralPath $installPath -File
        $marked = @($files | Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue })
        if ($marked.Count) { throw "noch markiert: $($marked.Name -join ', ')" }
        ($files.Name | Sort-Object) -join ', '
    }

    Invoke-Step 'Rechte auf config.json' {
        $acl = Get-Acl -LiteralPath (Join-Path $installPath 'config.json')
        $ids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
        if (-not $acl.AreAccessRulesProtected) { throw 'Vererbung nicht abgeschaltet' }
        if (Compare-Object $ids @('S-1-5-18', 'S-1-5-32-544')) { throw "unerwartete Konten: $($ids -join ', ')" }
        $ids -join ', '
    }

    Invoke-Step 'Geplante Aufgabe' {
        $t = Get-ScheduledTask -TaskName 'DpmMonitor'
        [ordered]@{
            User      = $t.Principal.UserId
            RunLevel  = "$($t.Principal.RunLevel)"
            Execute   = $t.Actions[0].Execute
            Arguments = $t.Actions[0].Arguments
            Interval  = $t.Triggers[0].Repetition.Interval
            Start     = $t.Triggers[0].StartBoundary
        }
    }

    Invoke-Step 'Startmenü-Verknüpfung' {
        $lnk = Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') -Filter '*DPM Monitor.lnk'
        if (-not $lnk) { throw 'fehlt' }
        $lnk.Name
    }

    Invoke-Step 'Aufgabe als SYSTEM ausführen' {
        $run = Start-DpmMonitorTask -TimeoutSeconds 300 -Confirm:$false
        [ordered]@{
            Completed      = $run.Completed
            LastTaskResult = $run.LastTaskResult
            Status         = $run.Result.Status
            ExitCode       = $run.Result.ExitCode
            PingSuccess    = $run.Result.PingSuccess
            PingError      = $run.Result.PingError
            Report         = $run.Result.Report
        }
    }

    Invoke-Step 'Protokoll' { [IO.File]::ReadAllLines((Join-Path $installPath 'logs\dpm-monitor.log')) }

    Invoke-Step 'Oberfläche installiert (Startmenü-Pfad)' { Test-Ui -Folder $installPath -Name '2-hauptfenster' -WaitSeconds 20 }

    Invoke-Step 'Update auf neueres Paket' {
        Expand-Package -Zip $newer.FullName -Destination $downloads
        $pkg2 = Join-Path $downloads $newer.BaseName
        Import-Module (Join-Path $pkg2 'DpmMonitor.psm1') -Force
        $before = Get-Content -LiteralPath (Join-Path $installPath 'config.json') -Raw
        $inst = Install-DpmMonitor -SourcePath $pkg2 -Confirm:$false
        $after = Get-Content -LiteralPath (Join-Path $installPath 'config.json') -Raw
        if ($before -ne $after) { throw 'Konfiguration verändert' }
        "Version jetzt $($inst.Version)"
    }

    Invoke-Step 'Aufgabe nach Update' {
        $run = Start-DpmMonitorTask -TimeoutSeconds 300 -Confirm:$false
        ($run.Result.Report -split "`n")[-1]
    }

    Invoke-Step 'Deinstallieren' {
        Uninstall-DpmMonitor -Confirm:$false
        $left = @()
        if (Test-Path $installPath) { $left += $installPath }
        if (Get-ScheduledTask -TaskName 'DpmMonitor' -ErrorAction SilentlyContinue) { $left += 'Aufgabe' }
        if (Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') -Filter '*DPM Monitor.lnk') { $left += 'Verknüpfung' }
        if ($left) { throw "übrig: $($left -join ', ')" }
        'alles entfernt'
    }
}
catch {
    Write-Step "ABBRUCH: $($_.Exception.Message)"
}
finally {
    $json = [pscustomobject]$results | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $out 'results.json'), $json, (New-Object Text.UTF8Encoding($true)))
    Write-Step 'Fertig'
    Set-Content -LiteralPath (Join-Path $out 'done.txt') -Value 'done'
    Start-Sleep -Seconds 3
    Stop-Computer -Force
}
