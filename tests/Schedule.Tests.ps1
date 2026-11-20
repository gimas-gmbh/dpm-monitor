BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DpmMonitor.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'ConvertTo-DpmMonitorWeekDay' {
    It 'reads DPM enum names' {
        ConvertTo-DpmMonitorWeekDay @('Su', 'Mo', 'Fr') | Should -Be @([DayOfWeek]::Sunday, [DayOfWeek]::Monday, [DayOfWeek]::Friday)
    }
    It 'reads flag numbers as exported to CLIXML' {
        ConvertTo-DpmMonitorWeekDay @(2, 4, 8, 16, 32) | Should -Be @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
    }
    It 'decomposes combined flags' {
        ConvertTo-DpmMonitorWeekDay 127 | Should -HaveCount 7
        ConvertTo-DpmMonitorWeekDay 65 | Should -Be @([DayOfWeek]::Sunday, [DayOfWeek]::Saturday)
    }
    It 'accepts German and English day names and numeric strings' {
        ConvertTo-DpmMonitorWeekDay @('Montag', 'Di', 'wednesday', '16') | Should -Be @('Monday', 'Tuesday', 'Wednesday', 'Thursday')
    }
    It 'accepts DayOfWeek values' {
        ConvertTo-DpmMonitorWeekDay @([DayOfWeek]::Saturday) | Should -Be @([DayOfWeek]::Saturday)
    }
    It 'ignores None and null' {
        ConvertTo-DpmMonitorWeekDay @('None', $null) | Should -HaveCount 0
        ConvertTo-DpmMonitorWeekDay $null | Should -HaveCount 0
    }
    It 'returns days in week order and without duplicates' {
        ConvertTo-DpmMonitorWeekDay @('Fr', 'Mo', 'Mo') | Should -Be @('Monday', 'Friday')
    }
    It 'rejects unknown names' {
        { ConvertTo-DpmMonitorWeekDay 'Funday' } | Should -Throw '*Wochentag*'
    }
}

Describe 'ConvertTo-DpmMonitorTimeOfDay' {
    It 'takes the time of day from DateTime values' {
        $times = New-Object System.Collections.ArrayList
        [void]$times.Add((Get-Date '2026-11-17 18:04'))
        [void]$times.Add((Get-Date '2026-11-17 07:00'))
        ConvertTo-DpmMonitorTimeOfDay $times | Should -Be @([TimeSpan]'07:00', [TimeSpan]'18:04')
    }
    It 'parses strings' {
        ConvertTo-DpmMonitorTimeOfDay @('20:00', '06:30') | Should -Be @([TimeSpan]'06:30', [TimeSpan]'20:00')
    }
    It 'rejects invalid times' {
        { ConvertTo-DpmMonitorTimeOfDay '25:00' } | Should -Throw '*Uhrzeit*'
    }
}

Describe 'ConvertTo-DpmMonitorSchedule' {
    Context 'live objects (enum names)' {
        It 'recognises an express full schedule' {
            $s = New-RawSchedule -Kind Full -WeekDays $WorkDays -Times '20:00' | ConvertTo-DpmMonitorSchedule
            $s.Kind | Should -Be 'ExpressFull'
            $s.WeekDays | Should -Be @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
            $s.TimesOfDay | Should -Be @([TimeSpan]'20:00')
        }
        It 'recognises a shadow copy schedule with several times' {
            $s = New-RawSchedule -Kind ShadowCopy -Times '07:00', '12:00', '18:04' | ConvertTo-DpmMonitorSchedule
            $s.Kind | Should -Be 'ShadowCopy'
            $s.TimesOfDay | Should -HaveCount 3
        }
        It 'recognises a synchronisation schedule and its interval' {
            $s = New-RawSchedule -Kind Replication -Frequency 240 | ConvertTo-DpmMonitorSchedule
            $s.Kind | Should -Be 'Synchronization'
            $s.IntervalMinutes | Should -Be 240
            $s.WeekDays | Should -HaveCount 0
        }
    }
    Context 'deserialised objects (numbers)' {
        It 'gives the same result as the live object' {
            $live = New-RawSchedule -Kind Full -WeekDays $WorkDays -Times '22:00' | ConvertTo-DpmMonitorSchedule
            $des = New-RawSchedule -Kind Full -WeekDays $WorkDays -Times '22:00' -Deserialized | ConvertTo-DpmMonitorSchedule
            $des.Kind | Should -Be $live.Kind
            $des.WeekDays | Should -Be $live.WeekDays
            $des.TimesOfDay | Should -Be $live.TimesOfDay
        }
    }
    It 'falls back to the class name if JobType is missing' {
        $o = [pscustomobject]@{ TimesOfDay = @((Get-Date '2026-11-17 18:00')); WeekDays = @('Mo') }
        $o.PSObject.TypeNames.Insert(0, 'Deserialized.Microsoft.Internal.EnterpriseStorage.Dls.UI.ObjectModel.OMCommon.ShadowCopySchedule')
        ($o | ConvertTo-DpmMonitorSchedule).Kind | Should -Be 'ShadowCopy'
    }
    It 'marks unknown schedule types' {
        ([pscustomobject]@{ JobType = 'SomethingNew' } | ConvertTo-DpmMonitorSchedule).Kind | Should -Be 'Unknown'
    }
    It 'unrolls lists and skips plain values' {
        $list = New-Object System.Collections.ArrayList
        [void]$list.Add((New-RawSchedule -Kind Full))
        [void]$list.Add((New-RawSchedule -Kind Replication))
        @(ConvertTo-DpmMonitorSchedule -InputObject $list) | Should -HaveCount 2
        @(0 | ConvertTo-DpmMonitorSchedule) | Should -HaveCount 0
    }
}

Describe 'Select-DpmMonitorExpectedSchedule' {
    BeforeAll {
        $sync = New-RawSchedule -Kind Replication | ConvertTo-DpmMonitorSchedule
        $full = New-RawSchedule -Kind Full -Times '20:00' | ConvertTo-DpmMonitorSchedule
        $shadow = New-RawSchedule -Kind ShadowCopy -Times '18:04' | ConvertTo-DpmMonitorSchedule
    }
    It 'uses express full for SQL, Hyper-V and system protection' {
        foreach ($type in 'SQLObjectType', 'HyperVRctObjectType', 'HyperVObjectType', 'SystemProtectionObjectType') {
            $r = Select-DpmMonitorExpectedSchedule -DatasourceType $type -Schedule @($sync, $shadow, $full)
            $r | Should -HaveCount 1
            $r[0].Kind | Should -Be 'ExpressFull'
        }
    }
    It 'uses the shadow copy schedule for file data' {
        (Select-DpmMonitorExpectedSchedule -DatasourceType 'FsObjectType' -Schedule @($sync, $full, $shadow))[0].Kind | Should -Be 'ShadowCopy'
    }
    It 'falls back to the other recovery point schedule' {
        (Select-DpmMonitorExpectedSchedule -DatasourceType 'FsObjectType' -Schedule @($full))[0].Kind | Should -Be 'ExpressFull'
        (Select-DpmMonitorExpectedSchedule -DatasourceType 'SQLObjectType' -Schedule @($shadow))[0].Kind | Should -Be 'ShadowCopy'
    }
    It 'never uses synchronisation' {
        Select-DpmMonitorExpectedSchedule -DatasourceType 'SQLObjectType' -Schedule @($sync) | Should -HaveCount 0
    }
    It 'returns all schedules of the chosen kind' {
        $full2 = New-RawSchedule -Kind Full -Times '06:00' -WeekDays 'Sa' | ConvertTo-DpmMonitorSchedule
        Select-DpmMonitorExpectedSchedule -DatasourceType 'SQLObjectType' -Schedule @($full, $full2) | Should -HaveCount 2
    }
}

Describe 'Get-DpmMonitorOccurrence' {
    It 'lists daily occurrences in UTC' {
        $s = New-TestSchedule -Times '20:00'
        $r = Get-DpmMonitorOccurrence -Schedule $s -After (U '2026-11-16 00:00') -Before (U '2026-11-19 00:00') -TimeZone $Tz
        $r | Should -Be @((Z '2026-11-16 19:00'), (Z '2026-11-17 19:00'), (Z '2026-11-18 19:00'))
    }
    It 'excludes After and includes Before' {
        $s = New-TestSchedule -Times '20:00'
        $r = Get-DpmMonitorOccurrence -Schedule $s -After (U '2026-11-16 20:00') -Before (U '2026-11-17 20:00') -TimeZone $Tz
        $r | Should -Be @((Z '2026-11-17 19:00'))
    }
    It 'skips the weekend for a work day schedule' {
        $s = New-TestSchedule -WeekDays $WorkDays -Times '20:00'
        # Friday 2026-11-20 21:00 to Monday 2026-11-23 21:00
        $r = Get-DpmMonitorOccurrence -Schedule $s -After (U '2026-11-20 21:00') -Before (U '2026-11-23 21:00') -TimeZone $Tz
        $r | Should -Be @((U '2026-11-23 20:00'))
    }
    It 'handles a weekly schedule' {
        $s = New-TestSchedule -WeekDays 'Fr' -Times '21:00'
        $r = Get-DpmMonitorOccurrence -Schedule $s -After (U '2026-11-01 00:00') -Before (U '2026-11-30 00:00') -TimeZone $Tz
        $r | Should -HaveCount 4
        ($r | ForEach-Object { [TimeZoneInfo]::ConvertTimeFromUtc($_, $Tz).DayOfWeek } | Sort-Object -Unique) | Should -Be 'Friday'
    }
    It 'merges several schedules and times without duplicates' {
        $a = New-TestSchedule -WeekDays $WorkDays -Times '07:00', '12:00'
        $b = New-TestSchedule -WeekDays 'Mo' -Times '12:00'
        $r = Get-DpmMonitorOccurrence -Schedule @($a, $b) -After (U '2026-11-23 00:00') -Before (U '2026-11-24 00:00') -TimeZone $Tz
        $r | Should -Be @((U '2026-11-23 07:00'), (U '2026-11-23 12:00'))
    }
    It 'returns nothing for an empty or inverted range' {
        $s = New-TestSchedule
        Get-DpmMonitorOccurrence -Schedule $s -After (U '2026-11-20 00:00') -Before (U '2026-11-19 00:00') -TimeZone $Tz | Should -HaveCount 0
        Get-DpmMonitorOccurrence -Schedule @() -After (U '2026-11-01 00:00') -Before (U '2026-11-19 00:00') -TimeZone $Tz | Should -HaveCount 0
    }

    Context 'daylight saving time (Europe/Berlin)' {
        It 'keeps the local time across the spring change' {
            $s = New-TestSchedule -Times '20:00'
            $r = Get-DpmMonitorOccurrence -Schedule $s -After (U '2026-03-28 00:00') -Before (U '2026-03-30 00:00') -TimeZone $Tz
            # 20:00 CET = 19:00Z, 20:00 CEST = 18:00Z
            $r | Should -Be @((Z '2026-03-28 19:00'), (Z '2026-03-29 18:00'))
        }
        It 'keeps the local time across the autumn change' {
            $s = New-TestSchedule -Times '20:00'
            $r = Get-DpmMonitorOccurrence -Schedule $s -After (U '2026-10-24 00:00') -Before (U '2026-10-26 00:00') -TimeZone $Tz
            $r | Should -Be @((Z '2026-10-24 18:00'), (Z '2026-10-25 19:00'))
        }
        It 'moves a time in the spring gap one hour later' {
            $s = New-TestSchedule -Times '02:30'
            $r = Get-DpmMonitorOccurrence -Schedule $s -After (Z '2026-03-28 12:00') -Before (Z '2026-03-29 12:00') -TimeZone $Tz
            # 02:30 does not exist; runs at 03:30 CEST = 01:30Z
            $r | Should -Be @((Z '2026-03-29 01:30'))
        }
        It 'counts a time in the repeated autumn hour once' {
            $s = New-TestSchedule -Times '02:30'
            $r = Get-DpmMonitorOccurrence -Schedule $s -After (Z '2026-10-24 12:00') -Before (Z '2026-10-25 12:00') -TimeZone $Tz
            $r | Should -HaveCount 1
        }
    }
}
