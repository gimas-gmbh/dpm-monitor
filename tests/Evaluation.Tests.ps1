BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DpmMonitor.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function Get-Status {
        param([string]$Latest, [string]$Now, [object[]]$Schedule = @(), $MaxAgeHours = $null, [int]$Threshold = 2, [double]$Buffer = 3)
        $l = if ($Latest) { L $Latest } else { $null }
        Get-DpmMonitorBackupStatus -LatestRecoveryPoint $l -Schedule $Schedule -MaxAgeHours $MaxAgeHours `
            -MissedRunsThreshold $Threshold -JobBufferHours $Buffer -Now (U $Now) -TimeZone $Tz
    }
}

Describe 'Get-DpmMonitorBackupStatus' {
    Context 'daily schedule 20:00' {
        BeforeAll { $daily = New-TestSchedule -Times '20:00' }

        It 'is ok while the next occurrence is still within the job buffer' {
            $r = Get-Status -Latest '2026-11-19 20:05' -Now '2026-11-20 22:59' -Schedule $daily
            $r.Status | Should -Be 'Ok'
            $r.MissedCount | Should -Be 0
        }
        It 'tolerates one missed occurrence' {
            $r = Get-Status -Latest '2026-11-19 20:05' -Now '2026-11-20 23:00' -Schedule $daily
            $r.Status | Should -Be 'Warning'
            $r.MissedCount | Should -Be 1
            $r.Reason | Should -BeLike '*20.11.2026 20:00*'
        }
        It 'fails after two missed occurrences' {
            $r = Get-Status -Latest '2026-11-19 20:05' -Now '2026-11-21 23:00' -Schedule $daily
            $r.Status | Should -Be 'Failed'
            $r.MissedCount | Should -Be 2
            $r.FirstMissed | Should -Be (U '2026-11-20 20:00')
            $r.Reason | Should -BeLike '2 geplante Termine verpasst seit 20.11.2026 20:00*19.11.2026 20:05*'
        }
        It 'counts the weekend for a daily schedule' {
            $r = Get-Status -Latest '2026-11-20 20:05' -Now '2026-11-23 10:00' -Schedule $daily
            $r.Status | Should -Be 'Failed'
            $r.MissedCount | Should -Be 2
        }
        It 'respects a configurable threshold' {
            (Get-Status -Latest '2026-11-19 20:05' -Now '2026-11-21 23:00' -Schedule $daily -Threshold 3).Status | Should -Be 'Warning'
            (Get-Status -Latest '2026-11-19 20:05' -Now '2026-11-20 23:00' -Schedule $daily -Threshold 1).Status | Should -Be 'Failed'
        }
        It 'respects a configurable job buffer' {
            (Get-Status -Latest '2026-11-19 20:05' -Now '2026-11-20 21:30' -Schedule $daily -Buffer 1).Status | Should -Be 'Warning'
        }
        It 'accepts a recovery point stamped late because of the job queue' {
            (Get-Status -Latest '2026-11-20 21:10' -Now '2026-11-21 10:00' -Schedule $daily).Status | Should -Be 'Ok'
        }
    }

    Context 'work day schedule Mo-Fr 20:00' {
        BeforeAll { $workdays = New-TestSchedule -WeekDays $WorkDays -Times '20:00' }

        It 'does not count the weekend' {
            (Get-Status -Latest '2026-11-20 20:05' -Now '2026-11-23 10:00' -Schedule $workdays).Status | Should -Be 'Ok'
        }
        It 'tolerates a missed Monday' {
            $r = Get-Status -Latest '2026-11-20 20:05' -Now '2026-11-23 23:30' -Schedule $workdays
            $r.Status | Should -Be 'Warning'
            $r.MissedCount | Should -Be 1
        }
        It 'fails after Monday and Tuesday are missed' {
            (Get-Status -Latest '2026-11-20 20:05' -Now '2026-11-24 23:30' -Schedule $workdays).Status | Should -Be 'Failed'
        }
        It 'fails over a weekend if Thursday and Friday are missed' {
            $r = Get-Status -Latest '2026-11-18 20:05' -Now '2026-11-22 12:00' -Schedule $workdays
            $r.Status | Should -Be 'Failed'
            $r.MissedCount | Should -Be 2
        }
    }

    Context 'weekly schedule Friday 21:00' {
        BeforeAll { $weekly = New-TestSchedule -WeekDays 'Fr' -Times '21:00' }

        It 'is ok during the week' {
            (Get-Status -Latest '2026-11-13 21:20' -Now '2026-11-20 12:00' -Schedule $weekly).Status | Should -Be 'Ok'
        }
        It 'fails after two missed weeks' {
            (Get-Status -Latest '2026-11-06 21:20' -Now '2026-11-21 08:00' -Schedule $weekly).Status | Should -Be 'Failed'
        }
    }

    Context 'several recovery points per day (shadow copies 07:00, 12:00, 18:04)' {
        BeforeAll { $shadow = New-TestSchedule -Kind ShadowCopy -WeekDays $WorkDays -Times '07:00', '12:00', '18:04' }

        It 'fails after two missed slots on the same day' {
            (Get-Status -Latest '2026-11-20 07:01' -Now '2026-11-20 21:10' -Schedule $shadow).Status | Should -Be 'Failed'
        }
        It 'accepts a recovery point stamped a few minutes before the scheduled time' {
            # schedule says 18:04 (offset included), recovery point reads 18:00
            (Get-Status -Latest '2026-11-20 18:00' -Now '2026-11-23 09:00' -Schedule $shadow).Status | Should -Be 'Ok'
        }
    }

    Context 'daylight saving time' {
        BeforeAll { $daily = New-TestSchedule -Times '20:00' }

        It 'counts by local time in spring (one missed, not two)' {
            # 23 h day: an hour-based check would see more than 24 h + buffer
            $r = Get-Status -Latest '2026-03-28 20:01' -Now '2026-03-29 23:30' -Schedule $daily
            $r.Status | Should -Be 'Warning'
            $r.MissedCount | Should -Be 1
        }
        It 'counts by local time in autumn' {
            $r = Get-Status -Latest '2026-10-24 20:01' -Now '2026-10-25 22:59' -Schedule $daily
            $r.Status | Should -Be 'Ok'
            $r = Get-Status -Latest '2026-10-24 20:01' -Now '2026-10-26 23:30' -Schedule $daily
            $r.MissedCount | Should -Be 2
        }
    }

    Context 'without schedule' {
        It 'uses the maximum age if given' {
            (Get-Status -Latest '2026-11-19 20:00' -Now '2026-11-20 19:00' -MaxAgeHours 26).Status | Should -Be 'Ok'
            $r = Get-Status -Latest '2026-11-19 20:00' -Now '2026-11-20 23:00' -MaxAgeHours 26
            $r.Status | Should -Be 'Failed'
            $r.Basis | Should -Be 'MaxAge'
        }
        It 'fails if neither schedule nor maximum age is known' {
            $r = Get-Status -Latest '2026-11-19 20:00' -Now '2026-11-20 10:00'
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -BeLike '*Kein Zeitplan*'
        }
        It 'ignores schedules without days or times' {
            $empty = New-TestSchedule -WeekDays @() -Times '20:00'
            (Get-Status -Latest '2026-11-19 20:00' -Now '2026-11-20 10:00' -Schedule $empty).Status | Should -Be 'Failed'
        }
    }

    Context 'missing recovery point' {
        It 'fails without a recovery point' {
            $r = Get-Status -Latest $null -Now '2026-11-20 10:00' -Schedule (New-TestSchedule)
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -BeLike 'Kein Wiederherstellungspunkt*'
        }
        It 'treats 0001-01-01 as missing' {
            $r = Get-DpmMonitorBackupStatus -LatestRecoveryPoint ([datetime]::MinValue) -Schedule (New-TestSchedule) -Now (U '2026-11-20 10:00') -TimeZone $Tz
            $r.Status | Should -Be 'Failed'
        }
        It 'caps very old recovery points and says so' {
            $r = Get-Status -Latest '2020-01-01 20:00' -Now '2026-11-20 10:00' -Schedule (New-TestSchedule)
            $r.Status | Should -Be 'Failed'
            $r.Reason | Should -BeLike 'mehr als *'
        }
    }
}

Describe 'Invoke-DpmMonitorEvaluation' {
    BeforeAll {
        $daily = New-TestSchedule -Times '20:00'
        $now = U '2026-11-20 10:00'
        function New-SqlState {
            param([string[]]$Latest)
            $i = 0
            $ds = foreach ($l in $Latest) { $i++; New-TestDatasource -Path "SRV-SQL01\db0$i" -Latest (L $l) }
            New-TestState -Groups @(New-TestGroup -Name 'PG SQL' -Schedules @($daily) -Datasources @($ds))
        }
    }

    It 'is ok when all data sources are current' {
        $e = Invoke-DpmMonitorEvaluation -State (New-SqlState '2026-11-19 20:01', '2026-11-19 20:30') -Config (New-TestConfig) -Now $now -TimeZone $Tz
        $e.Status | Should -Be 'Ok'
        $e.Items | Should -HaveCount 2
        $e.Report | Should -BeLike 'DPM-Überwachung SRV-DPM01: OK*2 Datenquellen geprüft, alle aktuell.*'
    }
    It 'fails if one data source is behind and lists it' {
        $e = Invoke-DpmMonitorEvaluation -State (New-SqlState '2026-11-19 20:01', '2026-11-17 20:30') -Config (New-TestConfig) -Now $now -TimeZone $Tz
        $e.Status | Should -Be 'Failed'
        @($e.Items | Where-Object Status -eq 'Failed').LogicalPath | Should -Be 'SRV-SQL01\db02'
        $e.Report | Should -Match ([regex]::Escape("FEHLER`n1 von 2 Datenquellen ohne aktuelle Sicherung."))
        $e.Report | Should -Match ([regex]::Escape("Fehler:`n- [PG SQL] srv-sql01.example.local | SRV-SQL01\db02: 2 geplante Termine verpasst"))
    }
    It 'reports a single missed occurrence without failing' {
        $e = Invoke-DpmMonitorEvaluation -State (New-SqlState '2026-11-18 20:01') -Config (New-TestConfig) -Now $now -TimeZone $Tz
        $e.Status | Should -Be 'Ok'
        $e.Report | Should -BeLike '*Einzelner verpasster Termin*SRV-SQL01\db01*'
    }
    It 'fails if there is nothing to monitor' {
        $e = Invoke-DpmMonitorEvaluation -State (New-TestState -Groups @()) -Config (New-TestConfig) -Now $now -TimeZone $Tz
        $e.Status | Should -Be 'Failed'
        $e.Report | Should -BeLike '*Keine überwachten Datenquellen*'
    }
    It 'mentions an inconsistent replica' {
        $ds = New-TestDatasource -Latest (L '2026-11-10 20:00') -State 'Invalid'
        $state = New-TestState -Groups @(New-TestGroup -Schedules @($daily) -Datasources @($ds))
        $e = Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig) -Now $now -TimeZone $Tz
        $e.Items[0].Reason | Should -BeLike '*inkonsistent*'
    }
    It 'monitors new data sources without configuration' {
        $state = New-SqlState '2026-11-19 20:01', '2026-11-19 20:02', '2026-11-19 20:03'
        $e = Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig) -Now $now -TimeZone $Tz
        @($e.Items | Where-Object Status -eq 'Ok') | Should -HaveCount 3
    }

    Context 'exclusions' {
        BeforeAll {
            $state = New-SqlState '2026-11-19 20:01', '2026-11-01 20:30'
            function New-Exclusion {
                param($Until = '', $Path = 'SRV-SQL01\db02', $Group = '')
                $ex = [pscustomobject]@{ ProtectionGroup = $Group; ProductionServerName = ''; LogicalPath = ''; Reason = 'Datenbank wird abgelöst'; Until = $Until }
                if ($Path) { $ex.ProductionServerName = 'srv-sql01.example.local'; $ex.LogicalPath = $Path }
                $ex
            }
        }
        It 'excludes a data source with reason' {
            $e = Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig @{ Exclusions = @(New-Exclusion) }) -Now $now -TimeZone $Tz
            $e.Status | Should -Be 'Ok'
            $x = @($e.Items | Where-Object Status -eq 'Excluded')
            $x.LogicalPath | Should -Be 'SRV-SQL01\db02'
            $x.Reason | Should -Be 'Ausgenommen: Datenbank wird abgelöst'
            $x.LatestRecoveryPoint | Should -Be (U '2026-11-01 20:30')
            $e.Report | Should -BeLike '*Ausgenommen: 1 Datenquelle(n).*'
        }
        It 'matches names case-insensitively' {
            $ex = New-Exclusion -Path 'srv-sql01\DB02'
            $ex.ProductionServerName = 'SRV-SQL01.EXAMPLE.LOCAL'
            (Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig @{ Exclusions = @($ex) }) -Now $now -TimeZone $Tz).Status | Should -Be 'Ok'
        }
        It 'keeps an exclusion active through its last day' {
            $cfg = New-TestConfig @{ Exclusions = @(New-Exclusion -Until '2026-11-30') }
            $e = Invoke-DpmMonitorEvaluation -State $state -Config $cfg -Now (U '2026-11-30 23:59') -TimeZone $Tz
            ($e.Items | Where-Object LogicalPath -eq 'SRV-SQL01\db02').Status | Should -Be 'Excluded'
            $e = Invoke-DpmMonitorEvaluation -State $state -Config $cfg -Now (U '2026-12-01 00:00') -TimeZone $Tz
            ($e.Items | Where-Object LogicalPath -eq 'SRV-SQL01\db02').Status | Should -Be 'Failed'
        }
        It 'monitors again after expiry and says so' {
            $cfg = New-TestConfig @{ Exclusions = @(New-Exclusion -Until '2026-11-19') }
            $e = Invoke-DpmMonitorEvaluation -State $state -Config $cfg -Now (U '2026-11-20 00:01') -TimeZone $Tz
            $e.Status | Should -Be 'Failed'
            $e.Notices | Should -Be @('Ausnahme abgelaufen am 2026-11-19, wird wieder überwacht: srv-sql01.example.local | SRV-SQL01\db02')
            $e.Report | Should -BeLike '*Hinweise:*Ausnahme abgelaufen*'
        }
        It 'excludes a whole protection group' {
            $cfg = New-TestConfig @{ Exclusions = @(New-Exclusion -Path '' -Group 'PG SQL') }
            $e = Invoke-DpmMonitorEvaluation -State $state -Config $cfg -Now $now -TimeZone $Tz
            @($e.Items | Where-Object Status -eq 'Excluded') | Should -HaveCount 2
            $e.Status | Should -Be 'Failed'   # nothing left to monitor
        }
        It 'excludes all data sources of one server within a protection group' {
            $ds = @(
                New-TestDatasource -Path 'SRV-SQL01\db01' -Latest (L '2026-11-01 20:00')
                New-TestDatasource -Path 'SRV-SQL01\db02' -Latest (L '2026-11-01 20:00')
                New-TestDatasource -Path 'SRV-SQL02\db01' -Server 'srv-sql02.example.local' -Latest (L '2026-11-19 20:01')
            )
            $other = New-TestDatasource -Path 'SRV-SQL01\db03' -Latest (L '2026-11-19 20:01')
            $twoServers = New-TestState -Groups @(
                New-TestGroup -Name 'PG SQL' -Schedules @($daily) -Datasources $ds
                New-TestGroup -Name 'PG Andere' -Schedules @($daily) -Datasources @($other)
            )
            $ex = [pscustomobject]@{ ProtectionGroup = 'PG SQL'; ProductionServerName = 'SRV-SQL01.example.local'; Reason = 'Server wird abgelöst' }
            $e = Invoke-DpmMonitorEvaluation -State $twoServers -Config (New-TestConfig @{ Exclusions = @($ex) }) -Now $now -TimeZone $Tz
            $e.Status | Should -Be 'Ok'
            @($e.Items | Where-Object Status -eq 'Excluded').LogicalPath | Should -Be @('SRV-SQL01\db01', 'SRV-SQL01\db02')
            ($e.Items | Where-Object LogicalPath -eq 'SRV-SQL01\db03').Status | Should -Be 'Ok'
            $e.Notices.Count | Should -Be 0
        }
        It 'does not report an expired exclusion while a wider one is active' {
            $expired = New-Exclusion -Until '2026-11-01'
            $server = [pscustomobject]@{ ProtectionGroup = 'PG SQL'; ProductionServerName = 'srv-sql01.example.local'; Reason = 'Server wird abgelöst' }
            $e = Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig @{ Exclusions = @($expired, $server) }) -Now $now -TimeZone $Tz
            ($e.Items | Where-Object LogicalPath -eq 'SRV-SQL01\db02').Status | Should -Be 'Excluded'
            $e.Notices.Count | Should -Be 0
        }
        It 'reports exclusions that match nothing' {
            $cfg = New-TestConfig @{ Exclusions = @((New-Exclusion -Path 'SRV-SQL01\gone')) }
            $e = Invoke-DpmMonitorEvaluation -State $state -Config $cfg -Now $now -TimeZone $Tz
            $e.Notices | Should -Contain 'Ausnahme passt zu keiner Datenquelle: srv-sql01.example.local | SRV-SQL01\gone'
        }
    }

    Context 'overrides' {
        BeforeAll {
            # Friday 10:00, latest on Monday: daily schedule would fail
            $state = New-SqlState '2026-11-16 20:01', '2026-11-16 20:30'
            $friday = U '2026-11-20 10:00'
        }
        It 'uses a maximum age for a protection group' {
            $ov = [pscustomobject]@{ ProtectionGroup = 'PG SQL'; MaxAgeHours = 168 }
            (Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig @{ Overrides = @($ov) }) -Now $friday -TimeZone $Tz).Status | Should -Be 'Ok'
        }
        It 'uses a custom schedule instead of the DPM schedule' {
            $ov = [pscustomobject]@{ ProtectionGroup = 'PG SQL'; WeekDays = @('Monday'); TimesOfDay = @('20:00') }
            $e = Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig @{ Overrides = @($ov) }) -Now $friday -TimeZone $Tz
            $e.Status | Should -Be 'Ok'
            $e.Items[0].Basis | Should -Be 'Schedule'
        }
        It 'prefers the data source rule over the protection group rule' {
            $pgRule = [pscustomobject]@{ ProtectionGroup = 'PG SQL'; MaxAgeHours = 168 }
            $dsRule = [pscustomobject]@{ ProductionServerName = 'srv-sql01.example.local'; LogicalPath = 'SRV-SQL01\db02'; MaxAgeHours = 24 }
            $e = Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig @{ Overrides = @($dsRule, $pgRule) }) -Now $friday -TimeZone $Tz
            ($e.Items | Where-Object LogicalPath -eq 'SRV-SQL01\db01').Status | Should -Be 'Ok'
            ($e.Items | Where-Object LogicalPath -eq 'SRV-SQL01\db02').Status | Should -Be 'Failed'
        }
        It 'ranks the server rule between data source and protection group rule' {
            $pgRule = [pscustomobject]@{ ProtectionGroup = 'PG SQL'; MaxAgeHours = 24 }
            $serverRule = [pscustomobject]@{ ProtectionGroup = 'PG SQL'; ProductionServerName = 'srv-sql01.example.local'; MaxAgeHours = 168 }
            $dsRule = [pscustomobject]@{ ProductionServerName = 'srv-sql01.example.local'; LogicalPath = 'SRV-SQL01\db02'; MaxAgeHours = 24 }
            foreach ($order in @(@($pgRule, $serverRule, $dsRule), @($dsRule, $serverRule, $pgRule))) {
                $e = Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig @{ Overrides = $order }) -Now $friday -TimeZone $Tz
                ($e.Items | Where-Object LogicalPath -eq 'SRV-SQL01\db01').Status | Should -Be 'Ok'
                ($e.Items | Where-Object LogicalPath -eq 'SRV-SQL01\db02').Status | Should -Be 'Failed'
            }
        }
        It 'uses the global fallback only when no schedule is known' {
            $ds = New-TestDatasource -Latest (L '2026-11-19 08:00')
            $noSchedule = New-TestState -Groups @(New-TestGroup -Schedules @() -Datasources @($ds))
            (Invoke-DpmMonitorEvaluation -State $noSchedule -Config (New-TestConfig @{ FallbackMaxAgeHours = 48 }) -Now $friday -TimeZone $Tz).Status | Should -Be 'Ok'
            (Invoke-DpmMonitorEvaluation -State $noSchedule -Config (New-TestConfig) -Now $friday -TimeZone $Tz).Status | Should -Be 'Failed'
            (Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig @{ FallbackMaxAgeHours = 500 }) -Now $friday -TimeZone $Tz).Status | Should -Be 'Failed'
        }
    }

    Context 'rule targets for a selection' {
        BeforeAll {
            $items = @(
                [pscustomobject]@{ ProtectionGroup = 'PG SQL'; ProductionServerName = 'srv-sql01.example.local'; LogicalPath = 'SRV-SQL01\db01' }
                [pscustomobject]@{ ProtectionGroup = 'PG SQL'; ProductionServerName = 'SRV-SQL01.example.local'; LogicalPath = 'SRV-SQL01\db02' }
                [pscustomobject]@{ ProtectionGroup = 'PG SQL'; ProductionServerName = 'srv-sql02.example.local'; LogicalPath = 'SRV-SQL02\db01' }
                [pscustomobject]@{ ProtectionGroup = 'PG Fileserver'; ProductionServerName = 'srv-sql01.example.local'; LogicalPath = 'D:\' }
            )
        }
        It 'returns one target per data source' {
            $t = @(Get-DpmMonitorRuleTarget -Item $items -Scope Datasource)
            $t | Should -HaveCount 4
            $t[0].Keys | Should -Be @('ProductionServerName', 'LogicalPath')
        }
        It 'returns one target per server and protection group' {
            $t = @(Get-DpmMonitorRuleTarget -Item $items -Scope Server)
            $t | Should -HaveCount 3
            $t[0].ProtectionGroup | Should -Be 'PG SQL'
            $t[0].ProductionServerName | Should -Be 'srv-sql01.example.local'
            $t[2].ProtectionGroup | Should -Be 'PG Fileserver'
        }
        It 'returns one target per protection group' {
            $t = @(Get-DpmMonitorRuleTarget -Item $items -Scope ProtectionGroup)
            @($t | ForEach-Object { $_.ProtectionGroup }) | Should -Be @('PG SQL', 'PG Fileserver')
        }
    }

    Context 'synthetic example server' {
        BeforeAll {
            $fixture = Import-FixtureServer
            $groups = foreach ($g in $fixture.Groups) {
                $ds = foreach ($d in $g.Datasources) {
                    New-TestDatasource -Path $d.LogicalPath -Server $d.ProductionServerName -Type (($d.Type -split '\.')[-1]) -Latest $d.LatestRecoveryPoint -State $d.State
                }
                New-TestGroup -Name $g.Group.FriendlyName -Schedules @($g.Schedules | ConvertTo-DpmMonitorSchedule) -Datasources @($ds)
            }
            $state = New-TestState -Groups @($groups)
        }
        It 'finds exactly the stale archive database' {
            $e = Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig) -Now (U '2026-11-20 14:00') -TimeZone $Tz
            $e.Status | Should -Be 'Failed'
            @($e.Items | Where-Object Status -ne 'Ok').LogicalPath | Should -Be 'SRV-SQL01\ArchiveDb'
        }
        It 'is ok once the archive database is excluded' {
            $ex = [pscustomobject]@{ ProductionServerName = 'srv-sql01.example.local'; LogicalPath = 'SRV-SQL01\ArchiveDb'; Reason = 'Archiv, nur noch lesend' }
            $e = Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig @{ Exclusions = @($ex) }) -Now (U '2026-11-20 14:00') -TimeZone $Tz
            $e.Status | Should -Be 'Ok'
        }
        It 'counts only the Friday run on Saturday for work day groups' {
            $ex = [pscustomobject]@{ ProductionServerName = 'srv-sql01.example.local'; LogicalPath = 'SRV-SQL01\ArchiveDb'; Reason = 'Archiv' }
            $cfg = New-TestConfig @{ Exclusions = @($ex) }
            # Saturday noon: file shadow copies (Mo-Fr) and Hyper-V (Mo-Fr 22:00) had Friday runs after the fixture time
            $e = Invoke-DpmMonitorEvaluation -State $state -Config $cfg -Now (U '2026-11-21 12:00') -TimeZone $Tz
            ($e.Items | Where-Object LogicalPath -eq 'RCT\SRV-APP01').Status | Should -Be 'Warning'
            ($e.Items | Where-Object LogicalPath -eq 'D:\').Status | Should -Be 'Warning'
        }
    }
}
