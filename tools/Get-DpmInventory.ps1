<#
    DPM-Bestandsaufnahme fuer die Backup-Ueberwachung (dpm-monitor)

    Ausfuehren auf dem DPM-Server:
      Rechtsklick auf die Datei -> "Mit PowerShell ausfuehren"
      (das Skript fordert bei Bedarf selbst Administratorrechte an)

    Das Skript liest nur. Es aendert nichts an DPM, an Zeitplaenen oder am System.
    Ergebnis: ein Ordner und eine ZIP-Datei auf dem Desktop. Die ZIP bitte zurueckschicken.

    Die Ausgabe enthaelt Server- und Datenquellennamen des Kunden, aber keine Kennwoerter.

    Die Recovery Points kommen zuletzt und koennen bei vielen Datenquellen lange dauern.
    Schneller Lauf ohne sie (in einer PowerShell):
      powershell.exe -ExecutionPolicy Bypass -File Get-DpmInventory.ps1 -SkipRecoveryPoints
#>
# AsyncTimeoutSeconds is used inside an Invoke-Step script block.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AsyncTimeoutSeconds')]
[CmdletBinding()]
param(
    # Wie viele der juengsten Recovery Points pro Datenquelle erfasst werden
    [int]$RecoveryPointsPerDatasource = 30,
    # Recovery Points ganz auslassen (schneller Lauf; dauert bei vielen Datenquellen sonst lange)
    [switch]$SkipRecoveryPoints,
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
    $elevatedArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    # Pass on the parameters given, otherwise e.g. -SkipRecoveryPoints is lost.
    foreach ($p in $PSBoundParameters.GetEnumerator()) {
        if ($p.Value -is [switch]) { if ($p.Value) { $elevatedArgs += "-$($p.Key)" } }
        else { $elevatedArgs += "-$($p.Key)"; $elevatedArgs += "$($p.Value)" }
    }
    Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList $elevatedArgs
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
function Wait-DatasourceProperty {
    param($Datasources, [int]$TimeoutSeconds)

    $registered = 0
    $i = 0
    foreach ($ds in $Datasources) {
        try {
            Register-ObjectEvent -InputObject $ds -EventName DataSourceChangedEvent -SourceIdentifier "DpmInv$i" | Out-Null
            $registered++
        }
        catch { Write-Verbose "Event-Registrierung fehlgeschlagen: $($_.Exception.Message)" }
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
        try { Import-Module DataProtectionManager -ErrorAction Stop } catch { Write-Verbose $_.Exception.Message }
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
            $w = Wait-DatasourceProperty -Datasources @($dsEntries | ForEach-Object { $_.DS }) -TimeoutSeconds $AsyncTimeoutSeconds
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
    # Protection group name -> has an online (Azure) schedule. Missing key = unknown.
    $script:onlineByPg = @{}
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
                    $sched = @(& $v.Block $pg | Where-Object { $null -ne $_ })
                    $export.Add([pscustomobject]@{ PG = $pg.FriendlyName; Variante = $v.Name; Schedule = $sched })
                    if ($sched.Count -eq 0) { $text.Add('(leer)') }
                    else { $text.Add(($sched | Format-List * | Out-String -Width 4096)) }
                    if ($v.Name -eq 'LongTerm Online') { $script:onlineByPg[$pg.FriendlyName] = $sched.Count -gt 0 }
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

    # --- Speicher -------------------------------------------------------
    Invoke-Step 'Speicher lesen' {
        $text = New-Object System.Collections.Generic.List[string]
        $export = New-Object System.Collections.Generic.List[object]
        $variants = @(
            @{ Name = 'Volumes (Modern Backup Storage)'; Block = { Get-DPMDiskStorage -DPMServerName $env:COMPUTERNAME -Volumes } },
            @{ Name = 'Datentraeger'; Block = { Get-DPMDiskStorage -DPMServerName $env:COMPUTERNAME } }
        )
        foreach ($v in $variants) {
            $text.Add("===== $($v.Name) =====")
            try {
                $items = @(& $v.Block | Where-Object { $null -ne $_ })
                $export.Add([pscustomobject]@{ Variante = $v.Name; Items = $items })
                if ($items.Count -eq 0) { $text.Add('(leer)') }
                else { $text.Add(($items | Format-List * | Out-String -Width 4096)) }
            }
            catch {
                $text.Add("(nicht verfuegbar: $($_.Exception.Message))")
            }
        }
        Save-Text '60_speicher.txt' $text.ToArray()
        $export.ToArray() | Export-Clixml -Path (Join-Path $outDir '61_speicher.xml') -Depth 3
        $first = $export.ToArray() | ForEach-Object { $_.Items } | Select-Object -First 1
        if ($first) { Save-Text '62_speicher_member.txt' ($first | Get-Member) }
    }

    # --- Aktuelle Alerts ------------------------------------------------
    Invoke-Step 'Aktuelle DPM-Alerts lesen' {
        $alerts = @(Get-DPMAlert -DPMServerName $env:COMPUTERNAME | Where-Object { $null -ne $_ })
        Save-Text '50_alerts.txt' ($alerts | Format-List *)
        $alerts | Export-Clixml -Path (Join-Path $outDir '51_alerts.xml') -Depth 2
        if ($alerts.Count -gt 0) { Save-Text '52_alert_member.txt' ($alerts[0] | Get-Member) }
        # How long alerts stay open, per type and severity (relevant for alarm rules).
        $now = Get-Date
        Save-Csv '53_alerts_uebersicht.csv' @($alerts | ForEach-Object {
                $since = $null
                if ($_.OccurredSince) { $since = [datetime]$_.OccurredSince }
                [pscustomobject][ordered]@{
                    Type             = "$($_.Type)"
                    Severity         = "$($_.Severity)"
                    IsResolved       = $_.IsResolved
                    TargetObjectType = "$($_.TargetObjectType)"
                    AffectedArea     = "$($_.AffectedArea)"
                    OccurredSince    = Format-Time $since
                    OffenStunden     = if ($since) { [Math]::Round(($now - $since).TotalHours, 1) } else { $null }
                }
            })
    }

    # --- Recovery Points ------------------------------------------------
    if ($SkipRecoveryPoints) {
        Write-Host '-> Recovery Points ausgelassen (-SkipRecoveryPoints)' -ForegroundColor Cyan
    }
    elseif ($dsEntries.Count -gt 0) {
        Invoke-Step "Recovery Points lesen (je Datenquelle und Speicherort die letzten $RecoveryPointsPerDatasource)" {
            $rows = New-Object System.Collections.Generic.List[object]
            $summary = New-Object System.Collections.Generic.List[object]
            $columns = New-Object System.Collections.Generic.List[string]
            $timings = New-Object System.Collections.Generic.List[object]
            $samples = @{}   # one sample recovery point per type, source and storage location
            $hasOnline = (Get-Command Get-DPMRecoveryPoint).Parameters.ContainsKey('Online')
            if ($hasOnline) {
                # Which groups get the slow -Online query, so the decision can be checked afterwards.
                Write-Host '   Online-Abfrage je Schutzgruppe:'
                foreach ($pg in $script:pgs) {
                    $name = $pg.FriendlyName
                    $decision = if (-not $script:onlineByPg.ContainsKey($name)) { 'ja (Zeitplan unbekannt)' }
                    elseif ($script:onlineByPg[$name]) { 'ja (Online-Zeitplan vorhanden)' }
                    else { 'nein (kein Online-Zeitplan)' }
                    Write-Host "     $($name): $decision"
                }
            }
            Write-Host '   Kann bei vielen Datenquellen lange dauern. Bei Strg+C werden die bis dahin gelesenen'
            Write-Host '   Recovery Points gespeichert und die ZIP trotzdem erstellt.'
            $total = [Diagnostics.Stopwatch]::StartNew()
            $n = 0
            $completed = $false
            try {
                foreach ($e in $dsEntries) {
                    $n++
                    $remaining = ''
                    if ($n -gt 1) {
                        $perItem = $total.Elapsed.TotalSeconds / ($n - 1)
                        $minutes = $perItem * ($dsEntries.Count - $n + 1) / 60
                        $remaining = if ($minutes -lt 1) { ', noch unter 1 min' } else { ', noch ca. {0:N0} min' -f $minutes }
                    }
                    Write-Progress -Activity 'Recovery Points lesen' -Status "$n / $($dsEntries.Count)$($remaining): $($e.DS.LogicalPath)" `
                        -PercentComplete ([int](100 * ($n - 1) / $dsEntries.Count))
                    $typeName = Get-TypeName $e.DS.Type
                    # Disk and tape points come from the default call; online (Azure) points need -Online,
                    # which is slow, so only ask where the protection group has an online schedule (or it is unknown).
                    $sources = @(@{ Name = 'Standard'; Block = { param($ds) Get-DPMRecoveryPoint -Datasource $ds } })
                    $wantOnline = $hasOnline -and (-not $script:onlineByPg.ContainsKey($e.PG) -or $script:onlineByPg[$e.PG])
                    if ($wantOnline) { $sources += @{ Name = 'Online'; Block = { param($ds) Get-DPMRecoveryPoint -Datasource $ds -Online } } }
                    $seconds = @{}
                    foreach ($source in $sources) {
                        $watch = [Diagnostics.Stopwatch]::StartNew()
                        try {
                            $all = @(& $source.Block $e.DS | Where-Object { $null -ne $_ })
                            $seconds[$source.Name] = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
                        }
                        catch {
                            $seconds[$source.Name] = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
                            if ($source.Name -eq 'Standard') {
                                $msg = "Recovery Points fuer $($e.DS.LogicalPath): $($_.Exception.Message)"
                                Write-Warning $msg
                                $script:problems.Add($msg)
                            }
                            continue
                        }
                        # Group by all simple properties that look like a storage location, so that
                        # rare tape or online points are not pushed out by frequent disk points.
                        $groups = $all | Group-Object {
                            $rp = $_
                            @($rp.PSObject.Properties | Where-Object {
                                    $_.Name -match 'Location|Tape|Online|Cloud|Disk|Media|Vault' -and
                                    ($null -eq $_.Value -or $_.Value -is [string] -or $_.Value -is [ValueType])
                                } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
                        }
                        foreach ($g in $groups) {
                            $sorted = @($g.Group | Sort-Object RepresentedPointInTime -Descending)
                            $summary.Add([pscustomobject][ordered]@{
                                    ProtectionGroup      = $e.PG
                                    ProductionServerName = $e.DS.ProductionServerName
                                    LogicalPath          = $e.DS.LogicalPath
                                    Type                 = $typeName
                                    Quelle               = $source.Name
                                    Speicherort          = $g.Name
                                    Anzahl               = $sorted.Count
                                    Neuester             = Format-Time $sorted[0].RepresentedPointInTime
                                    Aeltester            = Format-Time $sorted[-1].RepresentedPointInTime
                                })
                            $sampleKey = "$typeName | $($source.Name) | $($g.Name)"
                            if (-not $samples.ContainsKey($sampleKey)) { $samples[$sampleKey] = $sorted[0] }
                            foreach ($rp in ($sorted | Select-Object -First $RecoveryPointsPerDatasource)) {
                                $time = $null
                                if ($rp.RepresentedPointInTime) { $time = [datetime]$rp.RepresentedPointInTime }
                                $dayOfWeek = $null
                                if ($time) { $dayOfWeek = $time.DayOfWeek.ToString() }
                                $row = [ordered]@{
                                    ProtectionGroup      = $e.PG
                                    ProductionServerName = $e.DS.ProductionServerName
                                    LogicalPath          = $e.DS.LogicalPath
                                    Type                 = $typeName
                                    Quelle               = $source.Name
                                    Speicherort          = $g.Name
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
                    }
                    $timings.Add([pscustomobject][ordered]@{
                            ProtectionGroup      = $e.PG
                            ProductionServerName = $e.DS.ProductionServerName
                            LogicalPath          = $e.DS.LogicalPath
                            Type                 = $typeName
                            StandardSekunden     = $seconds['Standard']
                            OnlineSekunden       = $seconds['Online']
                        })
                    $line = '   {0,4}/{1}  {2,6:N1} s  [{3}] {4} | {5}' -f $n, $dsEntries.Count,
                        (($seconds.Values | Measure-Object -Sum).Sum), $e.PG, $e.DS.ProductionServerName, $e.DS.LogicalPath
                    Write-Host $line
                }
                $completed = $true
            }
            finally {
                Write-Progress -Activity 'Recovery Points lesen' -Completed
                Write-Host ('   Dauer insgesamt: {0:N1} min' -f $total.Elapsed.TotalMinutes)
                Save-Csv '43_recoverypoints_abrufdauer.csv' $timings.ToArray()
                # Same columns for every row, otherwise Export-Csv takes them from the first row only.
                Save-Csv '40_recoverypoints.csv' @($rows.ToArray() | Select-Object -Property $columns.ToArray())
                Save-Csv '42_recoverypoints_uebersicht.csv' $summary.ToArray()
                if ($samples.Count -gt 0) {
                    Save-Text '41_recoverypoint_beispiele.txt' ($samples.Keys | Sort-Object | ForEach-Object {
                        "===== $_ ====="
                        $samples[$_] | Format-List * | Out-String -Width 4096
                        $samples[$_] | Get-Member | Out-String -Width 4096
                    })
                }
                if (-not $completed) {
                    $script:problems.Add("Recovery Points abgebrochen bei Datenquelle $n von $($dsEntries.Count), Teilergebnis gespeichert")
                }
            }
        }
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

    try { Stop-Transcript | Out-Null } catch { Write-Verbose $_.Exception.Message }

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
