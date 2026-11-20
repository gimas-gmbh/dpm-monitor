# Shared helpers for the Pester tests. All data is synthetic.

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Tz = [TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
$script:OmPrefix = 'Microsoft.Internal.EnterpriseStorage.Dls.UI.ObjectModel.OMCommon.'

# Local wall-clock time (Europe/Berlin) as DPM delivers it (Kind Unspecified).
function L {
    param([string]$Text)
    [datetime]::ParseExact($Text, 'yyyy-MM-dd HH:mm', $script:Inv)
}

# UTC instant of a local wall-clock time (Europe/Berlin).
function U {
    param([string]$Text)
    [TimeZoneInfo]::ConvertTimeToUtc((L $Text), $script:Tz)
}

# UTC instant given directly in UTC.
function Z {
    param([string]$Text)
    [datetime]::SpecifyKind([datetime]::ParseExact($Text, 'yyyy-MM-dd HH:mm', $script:Inv), [DateTimeKind]::Utc)
}

$script:AllDays = @('Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa')
$script:WorkDays = @('Mo', 'Tu', 'We', 'Th', 'Fr')
$script:DayFlags = @{ Su = 1; Mo = 2; Tu = 4; We = 8; Th = 16; Fr = 32; Sa = 64 }

# Mimics an object from Get-DPMPolicySchedule -ShortTerm. -Deserialized mimics
# the same object after Export-Clixml/Import-Clixml (enums become numbers).
function New-RawSchedule {
    param(
        [ValidateSet('Full', 'ShadowCopy', 'Replication')][string]$Kind,
        [string[]]$WeekDays = $script:AllDays,
        [string[]]$Times = @('20:00'),
        [int]$Frequency = 60,
        [switch]$Deserialized
    )
    $class = @{ Full = 'FullSchedule'; ShadowCopy = 'ShadowCopySchedule'; Replication = 'ReplicationSchedule' }[$Kind]
    $jobName = @{ Full = 'FullReplicationForApplication'; ShadowCopy = 'ShadowCopy'; Replication = 'Replication' }[$Kind]
    $jobNumber = @{ Full = 2; ShadowCopy = 3; Replication = 1 }[$Kind]

    $props = [ordered]@{}
    if ($Kind -eq 'Replication') {
        $props.Frequency = $Frequency
    }
    else {
        # Note: PowerShell variable names are case-insensitive ($Times vs. $times).
        $dayList = New-Object System.Collections.ArrayList
        foreach ($d in $WeekDays) { [void]$dayList.Add($(if ($Deserialized) { $script:DayFlags[$d] } else { $d })) }
        $timeList = New-Object System.Collections.ArrayList
        foreach ($t in $Times) { [void]$timeList.Add((Get-Date '2026-11-17').Add([TimeSpan]::Parse($t))) }
        if ($Kind -eq 'ShadowCopy') { $props.SCOffset = 0 }
        $props.TimesOfDay = $timeList
        $props.WeekDays = $dayList
    }
    $props.JobType = if ($Deserialized) { $jobNumber } else { $jobName }
    $props.ScheduleDescription = 'synthetisch'
    $o = [pscustomobject]$props
    $o.PSObject.TypeNames.Insert(0, $(if ($Deserialized) { 'Deserialized.' } else { '' }) + $script:OmPrefix + $class)
    $o
}

function New-TestSchedule {
    param([string]$Kind = 'ExpressFull', [string[]]$WeekDays = $script:AllDays, [string[]]$Times = @('20:00'))
    New-DpmMonitorSchedule -WeekDays $WeekDays -TimesOfDay $Times -Kind $Kind
}

function New-TestDatasource {
    param(
        [string]$Path = 'SRV-SQL01\db01',
        [string]$Server = 'srv-sql01.example.local',
        [string]$Type = 'SQLObjectType',
        [object]$Latest = $null,
        [string]$State = 'Valid'
    )
    [pscustomobject]@{
        Name                 = ($Path -split '\\')[-1]
        ProductionServerName = $Server
        LogicalPath          = $Path
        DatasourceId         = [guid]::NewGuid().ToString()
        Type                 = $Type
        State                = $State
        LatestRecoveryPoint  = $Latest
    }
}

function New-TestGroup {
    param([string]$Name = 'PG SQL', [object[]]$Schedules = @(), [object[]]$Datasources = @())
    [pscustomobject]@{ Name = $Name; Schedules = $Schedules; Datasources = $Datasources }
}

function New-TestState {
    param([object[]]$Groups)
    [pscustomobject]@{ ServerName = 'SRV-DPM01'; ProtectionGroups = $Groups }
}

function New-TestConfig {
    param([hashtable]$Set = @{})
    $c = Get-DpmMonitorDefaultConfig
    $c.PingUrl = 'https://hc-ping.com/00000000-0000-0000-0000-000000000000'
    foreach ($k in $Set.Keys) { $c.$k = $Set[$k] }
    $c
}

# Raw DPM-like objects from tests/fixtures/example-server.json.
function Import-FixtureServer {
    param([string]$Name = 'example-server.json')
    $data = Get-Content -LiteralPath (Join-Path $PSScriptRoot "fixtures\$Name") -Raw -Encoding UTF8 | ConvertFrom-Json
    $groups = foreach ($g in $data.ProtectionGroups) {
        $pg = [pscustomobject]@{ FriendlyName = $g.FriendlyName; Name = $g.FriendlyName }
        $pg.PSObject.TypeNames.Insert(0, $script:OmPrefix + 'ProtectionGroup')
        $schedules = foreach ($s in $g.Schedules) {
            $kind = @{ FullSchedule = 'Full'; ShadowCopySchedule = 'ShadowCopy'; ReplicationSchedule = 'Replication' }[$s.Class]
            $params = @{ Kind = $kind }
            if ($s.PSObject.Properties['WeekDays']) { $params.WeekDays = @($s.WeekDays) }
            if ($s.PSObject.Properties['TimesOfDay']) { $params.Times = @($s.TimesOfDay) }
            if ($s.PSObject.Properties['Frequency']) { $params.Frequency = $s.Frequency }
            New-RawSchedule @params
        }
        $datasources = foreach ($d in $g.Datasources) {
            [pscustomobject]@{
                Name                 = $d.Name
                ProductionServerName = $d.ProductionServerName
                LogicalPath          = $d.LogicalPath
                DatasourceId         = $d.DatasourceId
                Type                 = $d.Type
                ObjectType           = $d.ObjectType
                State                = $d.State
                LatestRecoveryPoint  = if ($d.LatestRecoveryPoint) { L $d.LatestRecoveryPoint } else { [datetime]::MinValue }
            }
        }
        [pscustomobject]@{ Group = $pg; Schedules = @($schedules); Datasources = @($datasources) }
    }
    [pscustomobject]@{ ServerName = $data.ServerName; Groups = @($groups) }
}

# Stubs so the DPM cmdlets exist and can be mocked without a DPM server.
function Install-DpmCmdletStub {
    function global:Get-DPMProtectionGroup { param($DPMServerName) }
    function global:Get-DPMDatasource { param($ProtectionGroup) }
    function global:Get-DPMPolicySchedule { param($ProtectionGroup, [switch]$ShortTerm, [switch]$OffsetSchedule, $LongTerm) }
}

function Remove-DpmCmdletStub {
    foreach ($n in 'Get-DPMProtectionGroup', 'Get-DPMDatasource', 'Get-DPMPolicySchedule') {
        Remove-Item -Path "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}
