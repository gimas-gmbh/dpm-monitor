#Requires -Version 5.1
<#
    dpm-monitor: checks that Microsoft DPM creates recovery points on schedule
    and reports the result to Healthchecks.io.

    Layout:
      - Schedules:   normalise DPM schedule objects, compute scheduled occurrences
      - Evaluation:  pure assessment of a collected state against the config
      - DPM access:  collect the state from the DPM cmdlets (impure)
      - Ping, config, log, check orchestration

    All internal times are UTC. Times coming from DPM are local times of the
    DPM server and are converted with an explicit time zone.
#>

$script:ModuleVersion = '0.1.0'

# Recovery points can be stamped a few minutes before the scheduled time
# (shadow copy schedule 18:04 vs. recovery point 18:00). An occurrence counts
# as missed only if it lies more than this after the latest recovery point.
$script:EarlyToleranceMinutes = 15

# Recovery points older than this are not expanded into single occurrences.
$script:MaxLookbackDays = 400

# DPM WeekDays flags (observed: Su = 1 ... Sa = 64).
$script:WeekDayFlags = [ordered]@{
    Sunday    = 1
    Monday    = 2
    Tuesday   = 4
    Wednesday = 8
    Thursday  = 16
    Friday    = 32
    Saturday  = 64
}

$script:WeekDayAliases = @{
    su = 'Sunday';    sun = 'Sunday';    sunday = 'Sunday';       so = 'Sunday';     sonntag = 'Sunday'
    mo = 'Monday';    mon = 'Monday';    monday = 'Monday';       montag = 'Monday'
    tu = 'Tuesday';   tue = 'Tuesday';   tuesday = 'Tuesday';     di = 'Tuesday';    dienstag = 'Tuesday'
    we = 'Wednesday'; wed = 'Wednesday'; wednesday = 'Wednesday'; mi = 'Wednesday';  mittwoch = 'Wednesday'
    th = 'Thursday';  thu = 'Thursday';  thursday = 'Thursday';   do = 'Thursday';   donnerstag = 'Thursday'
    fr = 'Friday';    fri = 'Friday';    friday = 'Friday';       freitag = 'Friday'
    sa = 'Saturday';  sat = 'Saturday';  saturday = 'Saturday';   samstag = 'Saturday'
}

# Which schedule kind produces the recovery points, by data source class name
# (the 'Type' property; ObjectType is localised). Preliminary, see DESIGN.md.
$script:ShadowCopyTypes = @('FsObjectType')

$script:Culture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Get-ObjectPropertyValue {
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    $p.Value
}

function Test-ObjectProperty {
    param([object]$InputObject, [string]$Name)
    ($null -ne $InputObject) -and ($null -ne $InputObject.PSObject.Properties[$Name])
}

# Local wall-clock time in $TimeZone -> UTC. Times in the spring-forward gap
# are interpreted with the standard offset (02:30 -> 03:30 summer time);
# ambiguous times in the fall-back hour resolve to standard time.
function ConvertTo-DpmMonitorUtc {
    param([datetime]$Time, [TimeZoneInfo]$TimeZone)
    if ($Time.Kind -eq [DateTimeKind]::Utc) { return $Time }
    $local = [datetime]::SpecifyKind($Time, [DateTimeKind]::Unspecified)
    if ($TimeZone.IsInvalidTime($local)) {
        return [datetime]::SpecifyKind($local - $TimeZone.BaseUtcOffset, [DateTimeKind]::Utc)
    }
    [TimeZoneInfo]::ConvertTimeToUtc($local, $TimeZone)
}

function ConvertTo-DpmMonitorLocal {
    param([datetime]$Time, [TimeZoneInfo]$TimeZone)
    $utc = if ($Time.Kind -eq [DateTimeKind]::Utc) { $Time } else { [datetime]::SpecifyKind($Time, [DateTimeKind]::Utc) }
    [TimeZoneInfo]::ConvertTimeFromUtc($utc, $TimeZone)
}

function Format-DpmMonitorTime {
    param([object]$Time, [TimeZoneInfo]$TimeZone)
    if ($null -eq $Time) { return '-' }
    (ConvertTo-DpmMonitorLocal -Time $Time -TimeZone $TimeZone).ToString('dd.MM.yyyy HH:mm', $script:Culture)
}

# ---------------------------------------------------------------------------
# Schedules
# ---------------------------------------------------------------------------

function ConvertTo-DpmMonitorWeekDay {
    <#
        .SYNOPSIS
        Converts DPM WeekDays values (enum names, flag numbers, German/English
        day names, DayOfWeek) into a sorted DayOfWeek array.
    #>
    [CmdletBinding()]
    [OutputType([DayOfWeek[]])]
    param([AllowNull()][object]$Value)

    $flags = 0
    foreach ($v in $Value) {
        if ($null -eq $v) { continue }
        if ($v -is [DayOfWeek]) {
            $flags = $flags -bor $script:WeekDayFlags[$v.ToString()]
        }
        elseif ($v -is [string]) {
            $text = $v.Trim()
            $number = 0
            if ([int]::TryParse($text, [ref]$number)) {
                $flags = $flags -bor $number
            }
            elseif ($text -eq '' -or $text -eq 'None') {
                continue
            }
            elseif ($script:WeekDayAliases.ContainsKey($text.ToLowerInvariant())) {
                $flags = $flags -bor $script:WeekDayFlags[$script:WeekDayAliases[$text.ToLowerInvariant()]]
            }
            else {
                throw "Unbekannter Wochentag: '$text'"
            }
        }
        else {
            # DPM enum value or number
            $flags = $flags -bor [int]$v
        }
    }

    $days = foreach ($name in $script:WeekDayFlags.Keys) {
        if ($flags -band $script:WeekDayFlags[$name]) { [DayOfWeek]$name }
    }
    $days
}

function ConvertTo-DpmMonitorTimeOfDay {
    [CmdletBinding()]
    [OutputType([TimeSpan[]])]
    param([AllowNull()][object]$Value)

    $times = foreach ($v in $Value) {
        if ($null -eq $v) { continue }
        if ($v -is [datetime]) { $v.TimeOfDay }
        elseif ($v -is [TimeSpan]) { $v }
        else {
            $t = [TimeSpan]::Zero
            if ([TimeSpan]::TryParse("$v", [ref]$t) -and $t -ge [TimeSpan]::Zero -and $t -lt [TimeSpan]::FromDays(1)) { $t }
            else { throw "Ungültige Uhrzeit: '$v'" }
        }
    }
    $times | Sort-Object -Unique
}

function Get-DpmMonitorScheduleKind {
    param([object]$InputObject)

    $jobType = Get-ObjectPropertyValue $InputObject 'JobType'
    if ($null -ne $jobType) {
        switch -Regex ("$jobType") {
            '^(Replication|1)$' { return 'Synchronization' }
            '^(FullReplicationForApplication|2)$' { return 'ExpressFull' }
            '^(ShadowCopy|3)$' { return 'ShadowCopy' }
        }
    }
    foreach ($typeName in $InputObject.PSObject.TypeNames) {
        switch -Regex ($typeName) {
            'ReplicationSchedule$' { return 'Synchronization' }
            '(^|\.)FullSchedule$' { return 'ExpressFull' }
            'ShadowCopySchedule$' { return 'ShadowCopy' }
        }
    }
    'Unknown'
}

function ConvertTo-DpmMonitorSchedule {
    <#
        .SYNOPSIS
        Normalises a schedule object from Get-DPMPolicySchedule -ShortTerm
        (live or deserialised) into a DpmMonitor.Schedule.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowNull()][object]$InputObject)

    process {
        if ($null -eq $InputObject -or $InputObject -is [ValueType] -or $InputObject -is [string]) { return }
        if ($InputObject -is [Collections.IEnumerable]) {
            foreach ($o in $InputObject) { ConvertTo-DpmMonitorSchedule -InputObject $o }
            return
        }
        $kind = Get-DpmMonitorScheduleKind $InputObject
        $interval = $null
        if ($kind -eq 'Synchronization') {
            $f = Get-ObjectPropertyValue $InputObject 'Frequency'
            $n = 0
            if ($null -ne $f -and [int]::TryParse("$f", [ref]$n)) { $interval = $n }
        }
        [pscustomobject]@{
            PSTypeName      = 'DpmMonitor.Schedule'
            Kind            = $kind
            WeekDays        = [DayOfWeek[]]@(ConvertTo-DpmMonitorWeekDay (Get-ObjectPropertyValue $InputObject 'WeekDays'))
            TimesOfDay      = [TimeSpan[]]@(ConvertTo-DpmMonitorTimeOfDay (Get-ObjectPropertyValue $InputObject 'TimesOfDay'))
            IntervalMinutes = $interval
            Description     = [string](Get-ObjectPropertyValue $InputObject 'ScheduleDescription')
        }
    }
}

function New-DpmMonitorSchedule {
    <#
        .SYNOPSIS
        Creates a schedule from day names and times, e.g. for config overrides.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object]$WeekDays,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object]$TimesOfDay,
        [string]$Kind = 'Custom'
    )
    [pscustomobject]@{
        PSTypeName      = 'DpmMonitor.Schedule'
        Kind            = $Kind
        WeekDays        = [DayOfWeek[]]@(ConvertTo-DpmMonitorWeekDay $WeekDays)
        TimesOfDay      = [TimeSpan[]]@(ConvertTo-DpmMonitorTimeOfDay $TimesOfDay)
        IntervalMinutes = $null
        Description     = ''
    }
}

function Test-DpmMonitorScheduleUsable {
    param([object]$Schedule)
    ($null -ne $Schedule) -and (@($Schedule.WeekDays).Count -gt 0) -and (@($Schedule.TimesOfDay).Count -gt 0)
}

function Get-DpmMonitorOccurrence {
    <#
        .SYNOPSIS
        Returns the UTC times of all scheduled occurrences in (After, Before].
        Schedule times are local wall-clock times in $TimeZone, so daylight
        saving changes shift them in UTC as DPM does.
    #>
    [CmdletBinding()]
    [OutputType([datetime[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Schedule,
        [Parameter(Mandatory)][datetime]$After,
        [Parameter(Mandatory)][datetime]$Before,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $afterUtc = ConvertTo-DpmMonitorUtc -Time $After -TimeZone $TimeZone
    $beforeUtc = ConvertTo-DpmMonitorUtc -Time $Before -TimeZone $TimeZone
    $set = New-Object 'System.Collections.Generic.SortedSet[datetime]'
    if ($beforeUtc -le $afterUtc) { return }

    $first = (ConvertTo-DpmMonitorLocal -Time $afterUtc -TimeZone $TimeZone).Date.AddDays(-1)
    $last = (ConvertTo-DpmMonitorLocal -Time $beforeUtc -TimeZone $TimeZone).Date.AddDays(1)
    for ($day = $first; $day -le $last; $day = $day.AddDays(1)) {
        foreach ($s in $Schedule) {
            if (-not (Test-DpmMonitorScheduleUsable $s)) { continue }
            if (@($s.WeekDays) -notcontains $day.DayOfWeek) { continue }
            foreach ($t in $s.TimesOfDay) {
                $utc = ConvertTo-DpmMonitorUtc -Time ($day + $t) -TimeZone $TimeZone
                if ($utc -gt $afterUtc -and $utc -le $beforeUtc) { [void]$set.Add($utc) }
            }
        }
    }
    foreach ($o in $set) { $o }
}

function Select-DpmMonitorExpectedSchedule {
    <#
        .SYNOPSIS
        Picks the schedules that create recovery points for a data source type:
        shadow copy for file data, express full for everything else, each
        falling back to the other kind. Synchronisation never counts.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$DatasourceType,
        [AllowEmptyCollection()][object[]]$Schedule
    )

    $usable = @($Schedule | Where-Object { Test-DpmMonitorScheduleUsable $_ })
    $order = if ($script:ShadowCopyTypes -contains $DatasourceType) { 'ShadowCopy', 'ExpressFull' } else { 'ExpressFull', 'ShadowCopy' }
    foreach ($kind in $order) {
        $match = @($usable | Where-Object { $_.Kind -eq $kind })
        if ($match.Count -gt 0) { return $match }
    }
}

# ---------------------------------------------------------------------------
# Evaluation (pure)
# ---------------------------------------------------------------------------

function Get-DpmMonitorBackupStatus {
    <#
        .SYNOPSIS
        Assesses one data source: missed scheduled occurrences since the latest
        recovery point, or the age of the latest recovery point.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$LatestRecoveryPoint,
        [AllowEmptyCollection()][object[]]$Schedule = @(),
        [AllowNull()][object]$MaxAgeHours,
        [int]$MissedRunsThreshold = 2,
        [double]$JobBufferHours = 3,
        [Parameter(Mandatory)][datetime]$Now,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $nowUtc = ConvertTo-DpmMonitorUtc -Time $Now -TimeZone $TimeZone
    $result = [ordered]@{
        Status              = 'Failed'
        Reason              = ''
        Basis               = $null
        LatestRecoveryPoint = $null
        MissedCount         = 0
        FirstMissed         = $null
    }

    $hasLatest = ($null -ne $LatestRecoveryPoint) -and ([datetime]$LatestRecoveryPoint -ne [datetime]::MinValue)
    if (-not $hasLatest) {
        $result.Reason = 'Kein Wiederherstellungspunkt vorhanden oder nicht ermittelbar.'
        return [pscustomobject]$result
    }
    $latest = ConvertTo-DpmMonitorUtc -Time ([datetime]$LatestRecoveryPoint) -TimeZone $TimeZone
    $result.LatestRecoveryPoint = $latest
    $latestText = Format-DpmMonitorTime $latest $TimeZone

    $usable = @($Schedule | Where-Object { Test-DpmMonitorScheduleUsable $_ })
    if ($usable.Count -gt 0) {
        $result.Basis = 'Schedule'
        $after = $latest.AddMinutes($script:EarlyToleranceMinutes)
        $limit = $nowUtc.AddDays(-$script:MaxLookbackDays)
        $capped = $false
        if ($after -lt $limit) { $after = $limit; $capped = $true }
        $missed = @(Get-DpmMonitorOccurrence -Schedule $usable -After $after -Before ($nowUtc.AddHours(-$JobBufferHours)) -TimeZone $TimeZone)
        $result.MissedCount = $missed.Count
        if ($missed.Count -gt 0) { $result.FirstMissed = $missed[0] }
        $countText = if ($capped) { "mehr als $($missed.Count)" } else { "$($missed.Count)" }

        if ($missed.Count -ge [Math]::Max(1, $MissedRunsThreshold)) {
            $result.Status = 'Failed'
            $result.Reason = "$countText geplante Termine verpasst seit $(Format-DpmMonitorTime $missed[0] $TimeZone), letzter Wiederherstellungspunkt $latestText."
        }
        elseif ($missed.Count -gt 0) {
            $result.Status = 'Warning'
            $result.Reason = "1 geplanter Termin verpasst ($(Format-DpmMonitorTime $missed[0] $TimeZone)), letzter Wiederherstellungspunkt $latestText."
        }
        else {
            $result.Status = 'Ok'
            $result.Reason = "Letzter Wiederherstellungspunkt $latestText."
        }
        return [pscustomobject]$result
    }

    if ($null -ne $MaxAgeHours -and "$MaxAgeHours" -ne '') {
        $result.Basis = 'MaxAge'
        $ageHours = ($nowUtc - $latest).TotalHours
        if ($ageHours -gt [double]$MaxAgeHours) {
            $result.Status = 'Failed'
            $result.Reason = "Letzter Wiederherstellungspunkt $latestText ist älter als $MaxAgeHours Stunden."
        }
        else {
            $result.Status = 'Ok'
            $result.Reason = "Letzter Wiederherstellungspunkt $latestText."
        }
        return [pscustomobject]$result
    }

    $result.Reason = "Kein Zeitplan für diese Datenquelle ermittelbar, letzter Wiederherstellungspunkt $latestText."
    [pscustomobject]$result
}

function Test-DpmMonitorRuleMatch {
    param([object]$Rule, [object]$ProtectionGroup, [object]$Datasource)
    $pg = [string](Get-ObjectPropertyValue $Rule 'ProtectionGroup')
    $server = [string](Get-ObjectPropertyValue $Rule 'ProductionServerName')
    $path = [string](Get-ObjectPropertyValue $Rule 'LogicalPath')
    if ($pg -ne '' -and $pg -ne $ProtectionGroup.Name) { return $false }
    if ($server -ne '' -and $server -ne $Datasource.ProductionServerName) { return $false }
    if ($path -ne '' -and $path -ne $Datasource.LogicalPath) { return $false }
    $true
}

function Get-DpmMonitorRuleSpecificity {
    param([object]$Rule)
    if ([string](Get-ObjectPropertyValue $Rule 'LogicalPath') -ne '') { 2 } else { 1 }
}

function Get-DpmMonitorRuleLabel {
    param([object]$Rule)
    $parts = foreach ($n in 'ProtectionGroup', 'ProductionServerName', 'LogicalPath') {
        $v = [string](Get-ObjectPropertyValue $Rule $n)
        if ($v -ne '') { $v }
    }
    $parts -join ' | '
}

# Exclusions are valid through the end of their 'Until' day (local time).
function Test-DpmMonitorExclusionActive {
    param([object]$Exclusion, [datetime]$LocalToday)
    $until = [string](Get-ObjectPropertyValue $Exclusion 'Until')
    if ($until -eq '') { return $true }
    $date = [datetime]::ParseExact($until, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $LocalToday -le $date
}

function Invoke-DpmMonitorEvaluation {
    <#
        .SYNOPSIS
        Evaluates a collected DPM state against the configuration. Pure function:
        no DPM or network access.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][datetime]$Now,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $nowUtc = ConvertTo-DpmMonitorUtc -Time $Now -TimeZone $TimeZone
    $localToday = (ConvertTo-DpmMonitorLocal -Time $nowUtc -TimeZone $TimeZone).Date
    $defaults = Get-DpmMonitorDefaultConfig
    $setting = @{}
    foreach ($name in 'MissedRunsThreshold', 'JobBufferHours', 'FallbackMaxAgeHours') {
        $setting[$name] = if (Test-ObjectProperty $Config $name) { $Config.$name } else { $defaults.$name }
    }
    $exclusions = @(Get-ObjectPropertyValue $Config 'Exclusions' | Where-Object { $null -ne $_ })
    $overrides = @(Get-ObjectPropertyValue $Config 'Overrides' | Where-Object { $null -ne $_ })
    $usedExclusions = @{}
    $usedOverrides = @{}
    $notices = New-Object System.Collections.Generic.List[string]
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($pg in @($State.ProtectionGroups)) {
        foreach ($ds in @($pg.Datasources)) {
            $item = [ordered]@{
                ProtectionGroup      = $pg.Name
                ProductionServerName = $ds.ProductionServerName
                LogicalPath          = $ds.LogicalPath
                Name                 = $ds.Name
                Type                 = $ds.Type
                Status               = $null
                Reason               = ''
                Basis                = $null
                LatestRecoveryPoint  = $null
                MissedCount          = 0
            }

            # Exclusions: active ones exclude, expired ones are reported once.
            $excluded = $null
            for ($i = 0; $i -lt $exclusions.Count; $i++) {
                $ex = $exclusions[$i]
                if (-not (Test-DpmMonitorRuleMatch $ex $pg $ds)) { continue }
                $usedExclusions[$i] = $true
                if (Test-DpmMonitorExclusionActive $ex $localToday) {
                    if ($null -eq $excluded) { $excluded = $ex }
                }
                else {
                    $msg = "Ausnahme abgelaufen am $($ex.Until), wird wieder überwacht: $(Get-DpmMonitorRuleLabel $ex)"
                    if (-not $notices.Contains($msg)) { $notices.Add($msg) }
                }
            }
            if ($null -ne $excluded) {
                $item.Status = 'Excluded'
                $until = [string](Get-ObjectPropertyValue $excluded 'Until')
                $item.Reason = "Ausgenommen: $($excluded.Reason)" + $(if ($until) { " (bis $until)" } else { '' })
                $items.Add([pscustomobject]$item)
                continue
            }

            # Overrides: data source rule beats protection group rule.
            $override = $null
            for ($i = 0; $i -lt $overrides.Count; $i++) {
                $ov = $overrides[$i]
                if (-not (Test-DpmMonitorRuleMatch $ov $pg $ds)) { continue }
                $usedOverrides[$i] = $true
                if ($null -eq $override -or (Get-DpmMonitorRuleSpecificity $ov) -gt (Get-DpmMonitorRuleSpecificity $override)) {
                    $override = $ov
                }
            }

            $schedule = @()
            $maxAge = $setting.FallbackMaxAgeHours
            if ($null -ne $override) {
                $ovMaxAge = Get-ObjectPropertyValue $override 'MaxAgeHours'
                if ($null -ne $ovMaxAge -and "$ovMaxAge" -ne '') {
                    $maxAge = $ovMaxAge
                }
                else {
                    $schedule = @(New-DpmMonitorSchedule -WeekDays $override.WeekDays -TimesOfDay $override.TimesOfDay)
                }
            }
            else {
                $schedule = @(Select-DpmMonitorExpectedSchedule -DatasourceType $ds.Type -Schedule @($pg.Schedules))
            }

            $status = Get-DpmMonitorBackupStatus -LatestRecoveryPoint $ds.LatestRecoveryPoint -Schedule $schedule `
                -MaxAgeHours $maxAge -MissedRunsThreshold $setting.MissedRunsThreshold -JobBufferHours $setting.JobBufferHours `
                -Now $nowUtc -TimeZone $TimeZone
            $item.Status = $status.Status
            $item.Reason = $status.Reason
            $item.Basis = $status.Basis
            $item.LatestRecoveryPoint = $status.LatestRecoveryPoint
            $item.MissedCount = $status.MissedCount
            if ([string](Get-ObjectPropertyValue $ds 'State') -eq 'Invalid') {
                $item.Reason += ' DPM meldet das Replikat als inkonsistent.'
            }
            $items.Add([pscustomobject]$item)
        }
    }

    for ($i = 0; $i -lt $exclusions.Count; $i++) {
        if (-not $usedExclusions.ContainsKey($i)) {
            $notices.Add("Ausnahme passt zu keiner Datenquelle: $(Get-DpmMonitorRuleLabel $exclusions[$i])")
        }
    }
    for ($i = 0; $i -lt $overrides.Count; $i++) {
        if (-not $usedOverrides.ContainsKey($i)) {
            $notices.Add("Abweichende Regel passt zu keiner Datenquelle: $(Get-DpmMonitorRuleLabel $overrides[$i])")
        }
    }

    $itemArray = $items.ToArray()
    $failed = @($itemArray | Where-Object { $_.Status -eq 'Failed' })
    $monitored = @($itemArray | Where-Object { $_.Status -ne 'Excluded' })
    $overall = if ($failed.Count -gt 0 -or $monitored.Count -eq 0) { 'Failed' } else { 'Ok' }

    $evaluation = [pscustomobject]@{
        PSTypeName  = 'DpmMonitor.Evaluation'
        ServerName  = $State.ServerName
        Status      = $overall
        EvaluatedAt = $nowUtc
        Items       = $itemArray
        Notices     = $notices.ToArray()
        Report      = ''
    }
    $evaluation.Report = Format-DpmMonitorReport -Evaluation $evaluation -TimeZone $TimeZone
    $evaluation
}

function Format-DpmMonitorReport {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Evaluation,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $items = @($Evaluation.Items)
    $failed = @($items | Where-Object Status -eq 'Failed')
    $warning = @($items | Where-Object Status -eq 'Warning')
    $excluded = @($items | Where-Object Status -eq 'Excluded')
    $monitored = $items.Count - $excluded.Count
    $label = { param($i) "[$($i.ProtectionGroup)] $($i.ProductionServerName) | $($i.LogicalPath)" }

    $lines = New-Object System.Collections.Generic.List[string]
    $statusText = if ($Evaluation.Status -eq 'Ok') { 'OK' } else { 'FEHLER' }
    $lines.Add("DPM-Überwachung $($Evaluation.ServerName): $statusText")
    if ($monitored -eq 0) {
        $lines.Add('Keine überwachten Datenquellen gefunden.')
    }
    elseif ($failed.Count -gt 0) {
        $lines.Add("$($failed.Count) von $monitored Datenquellen ohne aktuelle Sicherung.")
    }
    else {
        $lines.Add("$monitored Datenquellen geprüft, alle aktuell.")
    }

    if ($failed.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Fehler:')
        foreach ($i in $failed) { $lines.Add("- $(& $label $i): $($i.Reason)") }
    }
    if ($warning.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Einzelner verpasster Termin (noch toleriert):')
        foreach ($i in $warning) { $lines.Add("- $(& $label $i): $($i.Reason)") }
    }
    if (@($Evaluation.Notices).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Hinweise:')
        foreach ($n in $Evaluation.Notices) { $lines.Add("- $n") }
    }
    if ($excluded.Count -gt 0) {
        $lines.Add('')
        $lines.Add("Ausgenommen: $($excluded.Count) Datenquelle(n).")
    }
    $lines.Add('')
    $lines.Add("Geprüft: $(Format-DpmMonitorTime $Evaluation.EvaluatedAt $TimeZone) (dpm-monitor $script:ModuleVersion)")
    $lines.ToArray() -join "`n"
}

# ---------------------------------------------------------------------------
# DPM access (impure)
# ---------------------------------------------------------------------------

function Import-DpmMonitorDpmModule {
    if (Get-Command Get-DPMProtectionGroup -ErrorAction SilentlyContinue) { return }
    try { Import-Module DataProtectionManager -ErrorAction Stop }
    catch { throw "DPM-PowerShell-Modul nicht gefunden. Läuft die Prüfung auf dem DPM-Server? ($($_.Exception.Message))" }
}

# DPM loads LatestRecoveryPoint & co. asynchronously; until then they read
# 0001-01-01. Reading the properties triggers loading; DataSourceChangedEvent
# signals completion.
function Wait-DpmMonitorDatasourceProperty {
    param([object[]]$Datasource, [int]$TimeoutSeconds = 120)

    $prefix = "DpmMonitor-$([guid]::NewGuid().ToString('N'))-"
    $registered = 0
    $i = 0
    foreach ($ds in $Datasource) {
        try {
            Register-ObjectEvent -InputObject $ds -EventName DataSourceChangedEvent -SourceIdentifier "$prefix$i" -ErrorAction Stop | Out-Null
            $registered++
        }
        catch { Write-Verbose "Event-Registrierung fehlgeschlagen: $($_.Exception.Message)" }
        $i++
    }
    try {
        $Datasource | Select-Object LatestRecoveryPoint, OldestRecoveryPoint, TotalRecoveryPoints | Out-Null
        $received = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($registered -gt 0 -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $received = @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$prefix*" }).Count
            if ($received -ge $registered) { break }
            Start-Sleep -Milliseconds 500
        }
        [pscustomobject]@{ Registered = $registered; Received = $received; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
    }
    finally {
        Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$prefix*" } | Unregister-Event -ErrorAction SilentlyContinue
        Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$prefix*" } | Remove-Event -ErrorAction SilentlyContinue
    }
}

function Get-DpmMonitorState {
    <#
        .SYNOPSIS
        Reads protection groups, data sources and short-term schedules from DPM.
        Errors are not swallowed: an unknown state must fail the check.
    #>
    [CmdletBinding()]
    param(
        [string]$ServerName = $env:COMPUTERNAME,
        [int]$TimeoutSeconds = 120
    )

    Import-DpmMonitorDpmModule
    $pgs = @(Get-DPMProtectionGroup -DPMServerName $ServerName -ErrorAction Stop | Where-Object { $null -ne $_ })

    $entries = foreach ($pg in $pgs) {
        $ds = @(Get-DPMDatasource -ProtectionGroup $pg -ErrorAction Stop | Where-Object { $null -ne $_ })
        $schedules = @(Get-DPMPolicySchedule -ProtectionGroup $pg -ShortTerm -ErrorAction Stop | ConvertTo-DpmMonitorSchedule)
        [pscustomobject]@{ Group = $pg; Datasources = $ds; Schedules = $schedules }
    }
    $entries = @($entries)

    $allDs = @($entries | ForEach-Object { $_.Datasources })
    $wait = $null
    if ($allDs.Count -gt 0) {
        $wait = Wait-DpmMonitorDatasourceProperty -Datasource $allDs -TimeoutSeconds $TimeoutSeconds
    }

    $groups = foreach ($e in $entries) {
        $dsList = foreach ($ds in $e.Datasources) {
            $latest = Get-ObjectPropertyValue $ds 'LatestRecoveryPoint'
            if ($null -ne $latest -and [datetime]$latest -eq [datetime]::MinValue) { $latest = $null }
            [pscustomobject]@{
                Name                 = [string]$ds.Name
                ProductionServerName = [string]$ds.ProductionServerName
                LogicalPath          = [string]$ds.LogicalPath
                DatasourceId         = [string](Get-ObjectPropertyValue $ds 'DatasourceId')
                Type                 = ("$(Get-ObjectPropertyValue $ds 'Type')" -split '\.')[-1]
                State                = [string](Get-ObjectPropertyValue $ds 'State')
                LatestRecoveryPoint  = $latest
            }
        }
        [pscustomobject]@{
            Name        = [string]$e.Group.FriendlyName
            Schedules   = $e.Schedules
            Datasources = @($dsList)
        }
    }

    [pscustomobject]@{
        PSTypeName       = 'DpmMonitor.State'
        ServerName       = $ServerName
        ProtectionGroups = @($groups)
        Wait             = $wait
    }
}

# ---------------------------------------------------------------------------
# Healthchecks.io ping
# ---------------------------------------------------------------------------

# Adds TLS 1.2 for this process only, and only if the process is neither on
# SystemDefault (0) nor already offering TLS 1.2 (3072). No system changes.
function Enable-DpmMonitorTls12 {
    $current = [int][Net.ServicePointManager]::SecurityProtocol
    if ($current -ne 0 -and -not ($current -band 3072)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]($current -bor 3072)
    }
}

function Send-DpmMonitorPing {
    <#
        .SYNOPSIS
        Reports success or failure to a Healthchecks.io ping URL, with the
        report as body. Retries a few times; never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PingUrl,
        [Parameter(Mandatory)][ValidateSet('Ok', 'Failed')][string]$Status,
        [AllowEmptyString()][string]$Body = '',
        [AllowEmptyString()][string]$Proxy = '',
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 10
    )

    Enable-DpmMonitorTls12
    $url = $PingUrl.TrimEnd('/')
    if ($Status -eq 'Failed') { $url = "$url/fail" }
    # Healthchecks.io keeps up to 100 kB of the body.
    if ($Body.Length -gt 90000) { $Body = $Body.Substring(0, 90000) + "`n[gekürzt]" }

    $request = @{
        Uri             = $url
        Method          = 'Post'
        Body            = [Text.Encoding]::UTF8.GetBytes($Body)
        ContentType     = 'text/plain; charset=utf-8'
        UseBasicParsing = $true
        TimeoutSec      = 30
    }
    if ($Proxy) { $request.Proxy = $Proxy }

    $lastError = $null
    for ($attempt = 1; $attempt -le [Math]::Max(1, $RetryCount); $attempt++) {
        try {
            $response = Invoke-WebRequest @request -ErrorAction Stop
            return [pscustomobject]@{ Success = $true; Url = $url; StatusCode = [int]$response.StatusCode; Attempts = $attempt; Error = $null }
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $RetryCount) { Start-Sleep -Seconds $RetryDelaySeconds }
        }
    }
    [pscustomobject]@{ Success = $false; Url = $url; StatusCode = $null; Attempts = [Math]::Max(1, $RetryCount); Error = $lastError }
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$script:ConfigSchemaVersion = 1

function Get-DpmMonitorDefaultConfig {
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        SchemaVersion       = $script:ConfigSchemaVersion
        PingUrl             = ''
        Proxy               = ''
        MissedRunsThreshold = 2
        JobBufferHours      = 3
        FallbackMaxAgeHours = $null
        Exclusions          = @()
        Overrides           = @()
    }
}

function Test-DpmMonitorRuleTarget {
    param([object]$Rule)
    $pg = [string](Get-ObjectPropertyValue $Rule 'ProtectionGroup')
    $server = [string](Get-ObjectPropertyValue $Rule 'ProductionServerName')
    $path = [string](Get-ObjectPropertyValue $Rule 'LogicalPath')
    ($pg -ne '' -and $server -eq '' -and $path -eq '') -or ($server -ne '' -and $path -ne '')
}

function Test-DpmMonitorConfig {
    <#
        .SYNOPSIS
        Returns a list of German error messages; empty if the config is valid.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][object]$Config)

    $errors = New-Object System.Collections.Generic.List[string]
    $version = Get-ObjectPropertyValue $Config 'SchemaVersion'
    if ($null -eq $version) { $errors.Add('SchemaVersion fehlt.') }
    elseif ([int]$version -gt $script:ConfigSchemaVersion) { $errors.Add("Konfiguration stammt von einer neueren Version (Schema $version).") }

    $url = [string](Get-ObjectPropertyValue $Config 'PingUrl')
    $uri = $null
    if ($url -eq '') { $errors.Add('Ping-URL fehlt.') }
    elseif (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { $errors.Add("Ping-URL ist keine gültige https-Adresse: $url") }

    $proxy = [string](Get-ObjectPropertyValue $Config 'Proxy')
    if ($proxy -ne '' -and -not [Uri]::TryCreate($proxy, [UriKind]::Absolute, [ref]$uri)) { $errors.Add("Proxy-Adresse ungültig: $proxy") }

    $threshold = Get-ObjectPropertyValue $Config 'MissedRunsThreshold'
    if ($null -ne $threshold -and [int]$threshold -lt 1) { $errors.Add('MissedRunsThreshold muss mindestens 1 sein.') }
    $buffer = Get-ObjectPropertyValue $Config 'JobBufferHours'
    if ($null -ne $buffer -and [double]$buffer -lt 0) { $errors.Add('JobBufferHours darf nicht negativ sein.') }
    $fallback = Get-ObjectPropertyValue $Config 'FallbackMaxAgeHours'
    if ($null -ne $fallback -and [double]$fallback -le 0) { $errors.Add('FallbackMaxAgeHours muss größer als 0 sein.') }

    $n = 0
    foreach ($ex in @(Get-ObjectPropertyValue $Config 'Exclusions')) {
        if ($null -eq $ex) { continue }
        $n++
        if (-not (Test-DpmMonitorRuleTarget $ex)) { $errors.Add("Ausnahme $($n): braucht eine Schutzgruppe oder Server und Pfad.") }
        if ([string](Get-ObjectPropertyValue $ex 'Reason') -eq '') { $errors.Add("Ausnahme $($n): Grund fehlt.") }
        $until = [string](Get-ObjectPropertyValue $ex 'Until')
        $d = [datetime]::MinValue
        if ($until -ne '' -and -not [datetime]::TryParseExact($until, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) {
            $errors.Add("Ausnahme $($n): Ablaufdatum '$until' ist kein Datum (JJJJ-MM-TT).")
        }
    }

    $n = 0
    foreach ($ov in @(Get-ObjectPropertyValue $Config 'Overrides')) {
        if ($null -eq $ov) { continue }
        $n++
        if (-not (Test-DpmMonitorRuleTarget $ov)) { $errors.Add("Regel $($n): braucht eine Schutzgruppe oder Server und Pfad.") }
        $maxAge = Get-ObjectPropertyValue $ov 'MaxAgeHours'
        if ($null -ne $maxAge -and "$maxAge" -ne '') {
            if ([double]$maxAge -le 0) { $errors.Add("Regel $($n): MaxAgeHours muss größer als 0 sein.") }
        }
        else {
            try {
                $s = New-DpmMonitorSchedule -WeekDays (Get-ObjectPropertyValue $ov 'WeekDays') -TimesOfDay (Get-ObjectPropertyValue $ov 'TimesOfDay')
                if (-not (Test-DpmMonitorScheduleUsable $s)) { $errors.Add("Regel $($n): braucht MaxAgeHours oder Wochentage und Uhrzeiten.") }
            }
            catch { $errors.Add("Regel $($n): $($_.Exception.Message)") }
        }
    }
    $errors.ToArray()
}

function Read-DpmMonitorConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Konfiguration nicht gefunden: $Path" }
    try { $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Konfiguration ist kein gültiges JSON: $Path ($($_.Exception.Message))" }

    $defaults = Get-DpmMonitorDefaultConfig
    foreach ($p in $defaults.PSObject.Properties) {
        if (-not (Test-ObjectProperty $config $p.Name)) { $config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    }
    $config.Exclusions = @($config.Exclusions | Where-Object { $null -ne $_ })
    $config.Overrides = @($config.Overrides | Where-Object { $null -ne $_ })

    $errors = @(Test-DpmMonitorConfig -Config $config)
    if ($errors.Count -gt 0) { throw "Konfiguration ungültig: $($errors -join ' ')" }
    $config
}

function Save-DpmMonitorConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Path
    )
    $errors = @(Test-DpmMonitorConfig -Config $Config)
    if ($errors.Count -gt 0) { throw "Konfiguration ungültig: $($errors -join ' ')" }
    $json = $Config | ConvertTo-Json -Depth 6
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---------------------------------------------------------------------------
# Log
# ---------------------------------------------------------------------------

function Write-DpmMonitorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [long]$MaxBytes = 1MB,
        [int]$Keep = 3
    )
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge $MaxBytes) {
            for ($i = $Keep; $i -ge 1; $i--) {
                $older = "$Path.$i"
                $newer = if ($i -eq 1) { $Path } else { "$Path.$($i - 1)" }
                if ($i -eq $Keep -and (Test-Path -LiteralPath $older)) { Remove-Item -LiteralPath $older -Force }
                if (Test-Path -LiteralPath $newer) { Move-Item -LiteralPath $newer -Destination $older -Force }
            }
        }
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        $text = ($Message -split "`r?`n" | ForEach-Object { "$stamp [$Level] $_" }) -join "`r`n"
        [IO.File]::AppendAllText($Path, $text + "`r`n", (New-Object Text.UTF8Encoding($true)))
    }
    catch {
        Write-Warning "Log konnte nicht geschrieben werden: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Check (used by the scheduled task and by "Jetzt prüfen")
# ---------------------------------------------------------------------------

function Invoke-DpmMonitorCheck {
    <#
        .SYNOPSIS
        Runs one complete check: read config, collect DPM state, evaluate,
        ping Healthchecks.io, log. Never throws.
        ExitCode: 0 ok, 1 backups failing or check failed, 2 config unusable,
        3 ping not delivered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$LogPath,
        [switch]$NoPing,
        [datetime]$Now = [datetime]::UtcNow,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    Write-DpmMonitorLog -Path $LogPath -Message "Prüfung gestartet (dpm-monitor $script:ModuleVersion)."
    try {
        $config = Read-DpmMonitorConfig -Path $ConfigPath
    }
    catch {
        $msg = $_.Exception.Message
        Write-DpmMonitorLog -Path $LogPath -Level ERROR -Message $msg
        return [pscustomobject]@{ Status = 'Failed'; ExitCode = 2; Report = $msg; Evaluation = $null; Ping = $null }
    }

    $evaluation = $null
    try {
        $state = Get-DpmMonitorState
        $evaluation = Invoke-DpmMonitorEvaluation -State $state -Config $config -Now $Now -TimeZone $TimeZone
        $status = $evaluation.Status
        $report = $evaluation.Report
    }
    catch {
        $status = 'Failed'
        $report = "DPM-Überwachung $($env:COMPUTERNAME): FEHLER`nDie Prüfung selbst ist fehlgeschlagen: $($_.Exception.Message)"
    }
    $level = if ($status -eq 'Ok') { 'INFO' } else { 'ERROR' }
    Write-DpmMonitorLog -Path $LogPath -Level $level -Message $report

    $exitCode = if ($status -eq 'Ok') { 0 } else { 1 }
    $ping = $null
    if (-not $NoPing) {
        $ping = Send-DpmMonitorPing -PingUrl $config.PingUrl -Status $status -Body $report -Proxy ([string]$config.Proxy)
        if ($ping.Success) {
            Write-DpmMonitorLog -Path $LogPath -Message "Healthchecks.io benachrichtigt (HTTP $($ping.StatusCode))."
        }
        else {
            Write-DpmMonitorLog -Path $LogPath -Level ERROR -Message "Healthchecks.io nicht erreichbar nach $($ping.Attempts) Versuch(en): $($ping.Error)"
            $exitCode = 3
        }
    }

    [pscustomobject]@{
        Status     = $status
        ExitCode   = $exitCode
        Report     = $report
        Evaluation = $evaluation
        Ping       = $ping
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-DpmMonitorWeekDay'
    'ConvertTo-DpmMonitorTimeOfDay'
    'ConvertTo-DpmMonitorSchedule'
    'New-DpmMonitorSchedule'
    'Get-DpmMonitorOccurrence'
    'Select-DpmMonitorExpectedSchedule'
    'Get-DpmMonitorBackupStatus'
    'Invoke-DpmMonitorEvaluation'
    'Format-DpmMonitorReport'
    'Get-DpmMonitorState'
    'Send-DpmMonitorPing'
    'Get-DpmMonitorDefaultConfig'
    'Test-DpmMonitorConfig'
    'Read-DpmMonitorConfig'
    'Save-DpmMonitorConfig'
    'Write-DpmMonitorLog'
    'Invoke-DpmMonitorCheck'
)
