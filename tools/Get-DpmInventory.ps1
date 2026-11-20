<#
    DPM-Bestandsaufnahme fuer die Backup-Ueberwachung (dpm-monitor)

    Ausfuehren auf dem DPM-Server:
      Rechtsklick auf die Datei -> "Mit PowerShell ausfuehren"
      (das Skript fordert bei Bedarf selbst Administratorrechte an)

    Das Skript liest nur. Es aendert nichts an DPM, an Zeitplaenen oder am System.
    Ergebnis: ein Ordner und eine ZIP-Datei auf dem Desktop. Die ZIP bitte zurueckschicken.

    Die Ausgabe enthaelt Server- und Datenquellennamen des Kunden, aber keine Kennwoerter.
#>
[CmdletBinding()]
param(
    # Wie viele der juengsten Recovery Points pro Datenquelle erfasst werden
    [int]$RecoveryPointsPerDatasource = 30,
    # Wie lange maximal auf das asynchrone Nachladen der Datasource-Eigenschaften gewartet wird
    [int]$AsyncTimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Administratorrechte sicherstellen (startet sich sonst erhoeht neu)
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Starte mit Administratorrechten neu ...'
    Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    return
}

# ---------------------------------------------------------------------------
# Ausgabeordner und Hilfsfunktionen
# ---------------------------------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$desktop = [Environment]::GetFolderPath('Desktop')
$outDir  = Join-Path $desktop "DPM-Bestandsaufnahme_$($env:COMPUTERNAME)_$stamp"
$zipPath = "$outDir.zip"
New-Item -ItemType Directory -Path $outDir | Out-Null

$transcriptPath = Join-Path $outDir '00_konsole.log'
Start-Transcript -Path $transcriptPath | Out-Null

$script:problems = New-Object System.Collections.Generic.List[string]

function Save-Text {
    param([string]$Name, $Content)
    $path = Join-Path $outDir $Name
    ($Content | Out-String -Width 4096) | Set-Content -Path $path -Encoding UTF8
}

# Pass arrays, not List[object]: in Windows PowerShell 5.1, @($list) on a
# List[object] throws "Argument types do not match".
function Save-Csv {
    param([string]$Name, [object[]]$Rows)
    $path = Join-Path $outDir $Name
    if (-not $Rows -or $Rows.Count -eq 0) {
        Set-Content -Path $path -Value '(keine Daten)' -Encoding UTF8
        return
    }
    $Rows | Export-Csv -Path $path -NoTypeInformation -Delimiter ';' -Encoding UTF8
}

# Unambiguous timestamps including UTC offset (DST!). Empty for null/0001-01-01.
function Format-Time {
    param($Value)
    if ($null -eq $Value) { return '' }
    try { $t = [datetime]$Value } catch { return "$Value" }
    if ($t -eq [datetime]::MinValue) { return '0001-01-01' }
    $t.ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
}

# Short class name of the DPM object type (language independent, unlike ObjectType).
function Get-TypeName {
    param($Value)
    if ($null -eq $Value) { return '' }
    ("$Value" -split '\.')[-1]
}

function Invoke-Step {
    param([string]$Title, [scriptblock]$Block)
    Write-Host "-> $Title" -ForegroundColor Cyan
    try {
        & $Block
    }
    catch {
        $msg = "${Title}: $($_.Exception.Message)"
        Write-Warning $msg
        $script:problems.Add($msg)
    }
}

# DPM laedt LatestRecoveryPoint & Co. asynchron nach. Bis das passiert ist,
# steht dort 0001-01-01. Wir loesen das Nachladen aus und warten auf die Events.
function Wait-DatasourceProperties {
    param($Datasources, [int]$TimeoutSeconds)

    $registered = 0
    $i = 0
    foreach ($ds in $Datasources) {
        try {
            Register-ObjectEvent -InputObject $ds -EventName DataSourceChangedEvent -SourceIdentifier "DpmInv$i" | Out-Null
            $registered++
        }
        catch { }
        $i++
    }

    $Datasources | Select-Object LatestRecoveryPoint, OldestRecoveryPoint, TotalRecoveryPoints > $null

    $received = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $received = @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like 'DpmInv*' }).Count
        if ($registered -gt 0 -and $received -ge $registered) { break }
        if ($registered -eq 0 -and $sw.Elapsed.TotalSeconds -ge 30) { break }
        Write-Progress -Activity 'Warte auf DPM-Daten' -Status "$received von $registered Datenquellen geladen" `
            -PercentComplete ([Math]::Min(100, 100 * $sw.Elapsed.TotalSeconds / $TimeoutSeconds))
        Start-Sleep -Milliseconds 500
    }
    Write-Progress -Activity 'Warte auf DPM-Daten' -Completed

    Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like 'DpmInv*' } | Unregister-Event -ErrorAction SilentlyContinue
    Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like 'DpmInv*' } | Remove-Event -ErrorAction SilentlyContinue

    [pscustomobject]@{
        EventsRegistered = $registered
        EventsReceived   = $received
        WaitedSeconds    = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

# ---------------------------------------------------------------------------
# Hauptteil
# ---------------------------------------------------------------------------
try {
    Write-Host ''
    Write-Host "DPM-Bestandsaufnahme auf $($env:COMPUTERNAME)" -ForegroundColor Green
    Write-Host "Ausgabe: $outDir"
    Write-Host ''

    # --- System- und Umgebungsinfos -------------------------------------
    Invoke-Step 'Systeminformationen' {
        $os = Get-CimInstance Win32_OperatingSystem
        $info = [ordered]@{
            Computer                = $env:COMPUTERNAME
            Zeitpunkt               = (Get-Date).ToString('o')
            Zeitzone                = (Get-TimeZone).Id
            Betriebssystem          = "$($os.Caption) $($os.Version)"
            PowerShell              = $PSVersionTable.PSVersion.ToString()
            CLR                     = "$($PSVersionTable.CLRVersion)"
            SecurityProtocolDefault = [Net.ServicePointManager]::SecurityProtocol.ToString()
            Benutzer                = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
        Save-Text '01_system.txt' ([pscustomobject]$info | Format-List)
    }

    Invoke-Step 'DPM-Version (Registry)' {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Microsoft Data Protection Manager\Setup',
            'HKLM:\SOFTWARE\Microsoft\Microsoft Data Protection Manager\DB'
        )
        $out = foreach ($k in $keys) {
            "===== $k ====="
            if (Test-Path $k) { Get-ItemProperty $k | Format-List | Out-String -Width 4096 } else { '(nicht vorhanden)' }
        }
        Save-Text '02_dpm_version.txt' $out
    }

    Invoke-Step 'Proxy-Einstellungen (WinHTTP, gilt fuer SYSTEM)' {
        Save-Text '03_proxy.txt' (& netsh.exe winhttp show proxy)
    }

    Invoke-Step 'Erreichbarkeit hc-ping.com' {
        $results = New-Object System.Collections.Generic.List[object]
        $test = {
            param($label)
            $r = [ordered]@{ Test = $label; Protokolle = [Net.ServicePointManager]::SecurityProtocol.ToString(); Ergebnis = $null }
            try {
                $resp = Invoke-WebRequest -Uri 'https://hc-ping.com/' -UseBasicParsing -TimeoutSec 15
                $r.Ergebnis = "HTTP $($resp.StatusCode)"
            }
            catch [System.Net.WebException] {
                if ($_.Exception.Response) { $r.Ergebnis = "HTTP $([int]$_.Exception.Response.StatusCode) (Verbindung ok)" }
                else { $r.Ergebnis = "Fehler: $($_.Exception.Message)" }
            }
            catch { $r.Ergebnis = "Fehler: $($_.Exception.Message)" }
            [pscustomobject]$r
        }
        $uri = [Uri]'https://hc-ping.com/'
        $proxy = [Net.WebRequest]::DefaultWebProxy
        $results.Add([pscustomobject]@{
            Test       = 'Proxy (.NET, aktueller Benutzer)'
            Protokolle = ''
            Ergebnis   = if ($proxy -and -not $proxy.IsBypassed($uri)) { "$($proxy.GetProxy($uri))" } else { 'direkt' }
        })
        $results.Add((& $test 'Standard-Protokolle'))
        $sp = [Net.ServicePointManager]::SecurityProtocol
        if ($sp -ne [Net.SecurityProtocolType]::SystemDefault -and -not ($sp -band [Net.SecurityProtocolType]::Tls12)) {
            [Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12
            $results.Add((& $test 'mit TLS 1.2 ergaenzt'))
        }
        Save-Text '04_netzwerk.txt' ($results | Format-List)
    }

    # --- DPM-Modul -------------------------------------------------------
    if (-not (Get-Command Get-DPMProtectionGroup -ErrorAction SilentlyContinue)) {
        try { Import-Module DataProtectionManager -ErrorAction Stop } catch { }
    }
    if (-not (Get-Command Get-DPMProtectionGroup -ErrorAction SilentlyContinue)) {
        $msg = 'DPM-PowerShell-Modul nicht gefunden. Ist das wirklich ein DPM-Server?'
        Write-Host $msg -ForegroundColor Red
        $script:problems.Add($msg)
        return
    }
    Invoke-Step 'DPM-Modul' {
        Save-Text '05_dpm_modul.txt' (Get-Command Get-DPMProtectionGroup).Module
    }

    # --- Protection Groups ----------------------------------------------
    $pgs = @()
    Invoke-Step 'Protection Groups lesen' {
        $script:pgs = @(Get-DPMProtectionGroup -DPMServerName $env:COMPUTERNAME)
        Write-Host "   $($script:pgs.Count) Protection Group(s)"
        Save-Text '10_protectiongroups.txt' ($script:pgs | Format-List *)
    }

    # --- Datenquellen ---------------------------------------------------
    $dsEntries = New-Object System.Collections.Generic.List[object]
    Invoke-Step 'Datenquellen lesen' {
        foreach ($pg in $script:pgs) {
            foreach ($ds in @(Get-DPMDatasource -ProtectionGroup $pg)) {
                if ($ds) { $dsEntries.Add([pscustomobject]@{ PG = $pg.FriendlyName; DS = $ds }) }
            }
        }
        Write-Host "   $($dsEntries.Count) Datenquelle(n)"
    }

    if ($dsEntries.Count -gt 0) {
        Invoke-Step 'Auf asynchrone DPM-Daten warten' {
            $w = Wait-DatasourceProperties -Datasources @($dsEntries | ForEach-Object { $_.DS }) -TimeoutSeconds $AsyncTimeoutSeconds
            Write-Host "   Events registriert: $($w.EventsRegistered), empfangen: $($w.EventsReceived), gewartet: $($w.WaitedSeconds) s"
        }

        Invoke-Step 'Datenquellen speichern' {
            $rows = foreach ($e in $dsEntries) {
                $ds = $e.DS
                [pscustomobject][ordered]@{
                    ProtectionGroup         = $e.PG
                    ProductionServerName    = $ds.ProductionServerName
                    Name                    = $ds.Name
                    LogicalPath             = $ds.LogicalPath
                    DatasourceId            = $ds.DatasourceId
                    Type                    = Get-TypeName $ds.Type
                    ObjectType              = $ds.ObjectType
                    State                   = $ds.State
                    CurrentProtectionState  = $ds.CurrentProtectionState
                    CurrentlyProtected      = $ds.CurrentlyProtected
                    LatestRecoveryPoint     = Format-Time $ds.LatestRecoveryPoint
                    LatestDiskRecoveryPoint = Format-Time $ds.LatestDiskRecoveryPoint
                    OldestRecoveryPoint     = Format-Time $ds.OldestRecoveryPoint
                    TotalRecoveryPoints     = $ds.TotalRecoveryPoints
                    TotalDiskRecoveryPoints = $ds.TotalDiskRecoveryPoints
                }
            }
            Save-Csv '20_datenquellen.csv' @($rows)
            Save-Text '21_datenquellen_alle_eigenschaften.txt' ($dsEntries | ForEach-Object {
                "===== [$($_.PG)] $($_.DS.ProductionServerName) | $($_.DS.LogicalPath) ====="
                $_.DS | Format-List * | Out-String -Width 4096
            })
            Save-Text '22_datenquelle_member.txt' ($dsEntries[0].DS | Get-Member)
        }
    }

    # --- Zeitplaene -----------------------------------------------------
    Invoke-Step 'Zeitplaene lesen' {
        $export = New-Object System.Collections.Generic.List[object]
        $text   = New-Object System.Collections.Generic.List[string]
        $variants = @(
            @{ Name = 'ShortTerm';      Block = { param($pg) Get-DPMPolicySchedule -ProtectionGroup $pg -ShortTerm } },
            @{ Name = 'OffsetSchedule'; Block = { param($pg) Get-DPMPolicySchedule -ProtectionGroup $pg -OffsetSchedule } },
            @{ Name = 'LongTerm Online'; Block = { param($pg) Get-DPMPolicySchedule -ProtectionGroup $pg -LongTerm Online } },
            @{ Name = 'LongTerm Tape';   Block = { param($pg) Get-DPMPolicySchedule -ProtectionGroup $pg -LongTerm Tape } }
        )
        foreach ($pg in $script:pgs) {
            $text.Add("################ $($pg.FriendlyName) ################")
            foreach ($v in $variants) {
                $text.Add("===== $($v.Name) =====")
                try {
                    $sched = @(& $v.Block $pg)
                    $export.Add([pscustomobject]@{ PG = $pg.FriendlyName; Variante = $v.Name; Schedule = $sched })
                    if ($sched.Count -eq 0) { $text.Add('(leer)') }
                    else { $text.Add(($sched | Format-List * | Out-String -Width 4096)) }
                }
                catch {
                    $text.Add("(nicht verfuegbar: $($_.Exception.Message))")
                }
            }
        }
        Save-Text '30_zeitplaene.txt' $text
        $export | Export-Clixml -Path (Join-Path $outDir '31_zeitplaene.xml') -Depth 4

        $first = $export | ForEach-Object { $_.Schedule } | Where-Object { $_ } | Select-Object -First 1
        if ($first) { Save-Text '32_zeitplan_member.txt' ($first | Get-Member) }
    }

    # --- Recovery Points ------------------------------------------------
    if ($dsEntries.Count -gt 0) {
        Invoke-Step "Recovery Points lesen (je Datenquelle die letzten $RecoveryPointsPerDatasource)" {
            $rows = New-Object System.Collections.Generic.List[object]
            $columns = New-Object System.Collections.Generic.List[string]
            $samples = @{}   # one sample recovery point per data source type
            $n = 0
            foreach ($e in $dsEntries) {
                $n++
                Write-Progress -Activity 'Recovery Points lesen' -Status "$n / $($dsEntries.Count): $($e.DS.LogicalPath)" `
                    -PercentComplete ([int](100 * $n / $dsEntries.Count))
                $typeName = Get-TypeName $e.DS.Type
                try {
                    $rps = @(Get-DPMRecoveryPoint -Datasource $e.DS |
                        Sort-Object RepresentedPointInTime -Descending |
                        Select-Object -First $RecoveryPointsPerDatasource)
                    if (-not $samples.ContainsKey($typeName) -and $rps.Count -gt 0) { $samples[$typeName] = $rps[0] }
                    foreach ($rp in $rps) {
                        $time = $null
                        if ($rp.RepresentedPointInTime) { $time = [datetime]$rp.RepresentedPointInTime }
                        $dayOfWeek = $null
                        if ($time) { $dayOfWeek = $time.DayOfWeek.ToString() }
                        $row = [ordered]@{
                            ProtectionGroup      = $e.PG
                            ProductionServerName = $e.DS.ProductionServerName
                            LogicalPath          = $e.DS.LogicalPath
                            Type                 = $typeName
                            Zeitpunkt            = Format-Time $time
                            Wochentag            = $dayOfWeek
                        }
                        # All simple-valued recovery point properties (names are undocumented).
                        foreach ($p in $rp.PSObject.Properties) {
                            $v = $p.Value
                            if ($null -eq $v -or $v -is [string] -or $v -is [ValueType]) {
                                if ($v -is [datetime]) { $v = Format-Time $v }
                                $row["RP_$($p.Name)"] = $v
                            }
                        }
                        foreach ($k in $row.Keys) { if (-not $columns.Contains($k)) { $columns.Add($k) } }
                        $rows.Add([pscustomobject]$row)
                    }
                }
                catch {
                    $msg = "Recovery Points fuer $($e.DS.LogicalPath): $($_.Exception.Message)"
                    Write-Warning $msg
                    $script:problems.Add($msg)
                }
            }
            Write-Progress -Activity 'Recovery Points lesen' -Completed
            # Same columns for every row, otherwise Export-Csv takes them from the first row only.
            Save-Csv '40_recoverypoints.csv' @($rows.ToArray() | Select-Object -Property $columns.ToArray())
            if ($samples.Count -gt 0) {
                Save-Text '41_recoverypoint_beispiele.txt' ($samples.Keys | Sort-Object | ForEach-Object {
                    "===== $_ ====="
                    $samples[$_] | Format-List * | Out-String -Width 4096
                    $samples[$_] | Get-Member | Out-String -Width 4096
                })
            }
        }
    }

    # --- Aktuelle Alerts ------------------------------------------------
    Invoke-Step 'Aktuelle DPM-Alerts lesen' {
        Save-Text '50_alerts.txt' (Get-DPMAlert -DPMServerName $env:COMPUTERNAME | Format-List *)
    }
}
catch {
    $msg = "Unerwarteter Fehler: $($_.Exception.Message)"
    Write-Host $msg -ForegroundColor Red
    $script:problems.Add($msg)
}
finally {
    if ($script:problems.Count -gt 0) {
        Save-Text '99_probleme.txt' $script:problems
    }

    try { Stop-Transcript | Out-Null } catch { }

    $zipOk = $false
    try {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath
        $zipOk = $true
    }
    catch {
        Write-Warning "ZIP konnte nicht erstellt werden: $($_.Exception.Message)"
    }

    Write-Host ''
    Write-Host 'Geschriebene Dateien:' -ForegroundColor Green
    Get-ChildItem -Path $outDir -File | Sort-Object Name | ForEach-Object {
        Write-Host ('  {0}  ({1:N0} KB)' -f $_.FullName, [Math]::Ceiling($_.Length / 1KB))
    }
    if ($zipOk) {
        Write-Host ''
        Write-Host 'Bitte diese Datei zurueckschicken:' -ForegroundColor Green
        Write-Host "  $zipPath" -ForegroundColor Yellow
        Start-Process -FilePath explorer.exe -ArgumentList "/select,`"$zipPath`""
    }
    else {
        Start-Process -FilePath explorer.exe -ArgumentList "`"$outDir`""
    }

    if ($script:problems.Count -gt 0) {
        Write-Host ''
        Write-Host "$($script:problems.Count) Schritt(e) mit Problemen, Details in 99_probleme.txt" -ForegroundColor Yellow
    }

    Write-Host ''
    Read-Host 'Fertig. Enter druecken zum Schliessen'
}
