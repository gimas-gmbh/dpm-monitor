BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DpmMonitor.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $validUrl = 'https://hc-ping.com/00000000-0000-0000-0000-000000000000'
}

Describe 'Test-DpmMonitorConfig' {
    It 'accepts a complete config' {
        @(Test-DpmMonitorConfig (New-TestConfig)) | Should -HaveCount 0
    }
    It 'requires an https ping URL' {
        @(Test-DpmMonitorConfig (New-TestConfig @{ PingUrl = '' })) | Should -Be 'Ping-URL fehlt.'
        @(Test-DpmMonitorConfig (New-TestConfig @{ PingUrl = 'http://hc-ping.com/x' })) | Should -BeLike '*keine gültige https-Adresse*'
    }
    It 'rejects configs from a newer version' {
        @(Test-DpmMonitorConfig (New-TestConfig @{ SchemaVersion = 99 })) | Should -BeLike '*neueren Version*'
    }
    It 'requires a reason and a valid date for exclusions' {
        $ex = [pscustomobject]@{ ProtectionGroup = 'PG SQL'; Reason = ''; Until = '31.12.2026' }
        $errors = @(Test-DpmMonitorConfig (New-TestConfig @{ Exclusions = @($ex) }))
        $errors | Should -Contain 'Ausnahme 1: Grund fehlt.'
        $errors | Should -Contain "Ausnahme 1: Ablaufdatum '31.12.2026' ist kein Datum (JJJJ-MM-TT)."
    }
    It 'requires a target for rules' {
        $ex = [pscustomobject]@{ LogicalPath = 'SRV-SQL01\db01'; Reason = 'x' }
        @(Test-DpmMonitorConfig (New-TestConfig @{ Exclusions = @($ex) })) | Should -BeLike '*braucht eine Schutzgruppe oder Server und Pfad*'
    }
    It 'requires either a maximum age or a schedule for overrides' {
        $ov = [pscustomobject]@{ ProtectionGroup = 'PG SQL' }
        @(Test-DpmMonitorConfig (New-TestConfig @{ Overrides = @($ov) })) | Should -BeLike '*MaxAgeHours oder Wochentage*'
        $ov = [pscustomobject]@{ ProtectionGroup = 'PG SQL'; WeekDays = @('Funday'); TimesOfDay = @('20:00') }
        @(Test-DpmMonitorConfig (New-TestConfig @{ Overrides = @($ov) })) | Should -BeLike '*Unbekannter Wochentag*'
    }
}

Describe 'Read-DpmMonitorConfig and Save-DpmMonitorConfig' {
    It 'round-trips a config with umlauts as UTF-8 with BOM' {
        $path = Join-Path $TestDrive 'config.json'
        $ex = [pscustomobject]@{ ProductionServerName = 'srv-sql01.example.local'; LogicalPath = 'SRV-SQL01\db01'; Reason = 'Wird abgelöst'; Until = '2026-12-31' }
        Save-DpmMonitorConfig -Config (New-TestConfig @{ Exclusions = @($ex) }) -Path $path
        [IO.File]::ReadAllBytes($path)[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $c = Read-DpmMonitorConfig -Path $path
        $c.Exclusions[0].Reason | Should -Be 'Wird abgelöst'
        $c.PingUrl | Should -Be $validUrl
    }
    It 'keeps a single exclusion as a list' {
        $path = Join-Path $TestDrive 'single.json'
        $ex = [pscustomobject]@{ ProtectionGroup = 'PG SQL'; Reason = 'Test' }
        Save-DpmMonitorConfig -Config (New-TestConfig @{ Exclusions = @($ex) }) -Path $path
        @((Read-DpmMonitorConfig -Path $path).Exclusions) | Should -HaveCount 1
    }
    It 'fills in missing optional settings' {
        $path = Join-Path $TestDrive 'minimal.json'
        Set-Content -LiteralPath $path -Value "{ `"SchemaVersion`": 1, `"PingUrl`": `"$validUrl`" }" -Encoding UTF8
        $c = Read-DpmMonitorConfig -Path $path
        $c.MissedRunsThreshold | Should -Be 2
        $c.JobBufferHours | Should -Be 3
        @($c.Exclusions) | Should -HaveCount 0
    }
    It 'reports a missing file' {
        { Read-DpmMonitorConfig -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw 'Konfiguration nicht gefunden*'
    }
    It 'reports invalid JSON' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $path -Value '{ "SchemaVersion": ' -Encoding UTF8
        { Read-DpmMonitorConfig -Path $path } | Should -Throw 'Konfiguration ist kein gültiges JSON*'
    }
    It 'refuses to save an invalid config' {
        { Save-DpmMonitorConfig -Config (New-TestConfig @{ PingUrl = '' }) -Path (Join-Path $TestDrive 'x.json') } | Should -Throw 'Konfiguration ungültig*'
    }
}

Describe 'Write-DpmMonitorLog' {
    It 'writes one line per message line with level' {
        $path = Join-Path $TestDrive 'log\a.log'
        Write-DpmMonitorLog -Path $path -Message "Zeile eins`nZeile zwei" -Level WARN
        $lines = Get-Content -LiteralPath $path -Encoding UTF8
        $lines | Should -HaveCount 2
        $lines[1] | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[WARN\] Zeile zwei$'
    }
    It 'rotates and keeps a limited number of files' {
        $path = Join-Path $TestDrive 'rot\b.log'
        1..12 | ForEach-Object { Write-DpmMonitorLog -Path $path -Message ('x' * 100) -MaxBytes 250 -Keep 2 }
        Test-Path "$path.1" | Should -BeTrue
        Test-Path "$path.2" | Should -BeTrue
        Test-Path "$path.3" | Should -BeFalse
        (Get-Item $path).Length | Should -BeLessThan 500
    }
}

Describe 'Send-DpmMonitorPing' {
    BeforeAll {
        Mock -ModuleName DpmMonitor Start-Sleep { }
    }
    It 'posts the report to the ping URL on success' {
        Mock -ModuleName DpmMonitor Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        $r = Send-DpmMonitorPing -PingUrl $validUrl -Status Ok -Body 'Alles gut: Prüfung ok'
        $r.Success | Should -BeTrue
        $r.Url | Should -Be $validUrl
        Should -Invoke -ModuleName DpmMonitor Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq $validUrl -and $Method -eq 'Post' -and [Text.Encoding]::UTF8.GetString($Body) -eq 'Alles gut: Prüfung ok'
        }
    }
    It 'uses /fail for failures' {
        Mock -ModuleName DpmMonitor Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        (Send-DpmMonitorPing -PingUrl "$validUrl/" -Status Failed -Body 'kaputt').Url | Should -Be "$validUrl/fail"
    }
    It 'passes the proxy' {
        Mock -ModuleName DpmMonitor Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        Send-DpmMonitorPing -PingUrl $validUrl -Status Ok -Proxy 'http://proxy.example.local:8080' | Out-Null
        Should -Invoke -ModuleName DpmMonitor Invoke-WebRequest -ParameterFilter { $Proxy -eq 'http://proxy.example.local:8080' }
    }
    It 'retries and reports the error without throwing' {
        Mock -ModuleName DpmMonitor Invoke-WebRequest { throw 'Die Verbindung wurde getrennt' }
        $r = Send-DpmMonitorPing -PingUrl $validUrl -Status Ok -RetryCount 3
        $r.Success | Should -BeFalse
        $r.Attempts | Should -Be 3
        $r.Error | Should -Be 'Die Verbindung wurde getrennt'
        Should -Invoke -ModuleName DpmMonitor Invoke-WebRequest -Times 3 -Exactly
        Should -Invoke -ModuleName DpmMonitor Start-Sleep -Times 2 -Exactly
    }
    It 'truncates very long bodies' {
        Mock -ModuleName DpmMonitor Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        Send-DpmMonitorPing -PingUrl $validUrl -Status Failed -Body ('x' * 200000) | Out-Null
        Should -Invoke -ModuleName DpmMonitor Invoke-WebRequest -ParameterFilter { $Body.Length -lt 100000 }
    }
}

Describe 'Enable-DpmMonitorTls12' {
    BeforeEach { $saved = [Net.ServicePointManager]::SecurityProtocol }
    AfterEach { [Net.ServicePointManager]::SecurityProtocol = $saved }

    It 'adds TLS 1.2 when only older protocols are offered' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls
        InModuleScope DpmMonitor { Enable-DpmMonitorTls12 }
        [int][Net.ServicePointManager]::SecurityProtocol -band 3072 | Should -Be 3072
        [int][Net.ServicePointManager]::SecurityProtocol -band 192 | Should -Be 192
    }
    It 'leaves SystemDefault alone' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]0
        InModuleScope DpmMonitor { Enable-DpmMonitorTls12 }
        [int][Net.ServicePointManager]::SecurityProtocol | Should -Be 0
    }
}

Describe 'Invoke-DpmMonitorCheck' {
    BeforeAll {
        $configPath = Join-Path $TestDrive 'config.json'
        $logPath = Join-Path $TestDrive 'logs\dpm-monitor.log'
        Save-DpmMonitorConfig -Config (New-TestConfig) -Path $configPath
        $now = U '2026-11-20 10:00'
        function New-CheckState {
            param([string]$Latest)
            $ds = New-TestDatasource -Latest (L $Latest)
            New-TestState -Groups @(New-TestGroup -Schedules @(New-TestSchedule -Times '20:00') -Datasources @($ds))
        }
    }
    BeforeEach {
        Mock -ModuleName DpmMonitor Send-DpmMonitorPing { [pscustomobject]@{ Success = $true; Url = $PingUrl; StatusCode = 200; Attempts = 1; Error = $null } }
    }

    It 'pings success when all backups are current' {
        Mock -ModuleName DpmMonitor Get-DpmMonitorState { New-CheckState '2026-11-19 20:05' }
        $r = Invoke-DpmMonitorCheck -ConfigPath $configPath -LogPath $logPath -Now $now -TimeZone $Tz
        $r.Status | Should -Be 'Ok'
        $r.ExitCode | Should -Be 0
        Should -Invoke -ModuleName DpmMonitor Send-DpmMonitorPing -Times 1 -Exactly -ParameterFilter { $Status -eq 'Ok' -and $PingUrl -eq $validUrl -and $Body -like '*OK*' }
        Get-Content -LiteralPath $logPath -Encoding UTF8 -Raw | Should -BeLike '*Healthchecks.io benachrichtigt (HTTP 200)*'
    }
    It 'pings failure with the report when backups are missing' {
        Mock -ModuleName DpmMonitor Get-DpmMonitorState { New-CheckState '2026-11-15 20:05' }
        $r = Invoke-DpmMonitorCheck -ConfigPath $configPath -LogPath $logPath -Now $now -TimeZone $Tz
        $r.ExitCode | Should -Be 1
        Should -Invoke -ModuleName DpmMonitor Send-DpmMonitorPing -Times 1 -Exactly -ParameterFilter { $Status -eq 'Failed' -and $Body -like '*SRV-SQL01\db01*geplante Termine verpasst*' }
    }
    It 'pings failure when DPM cannot be read' {
        Mock -ModuleName DpmMonitor Get-DpmMonitorState { throw 'DPM-Dienst antwortet nicht' }
        $r = Invoke-DpmMonitorCheck -ConfigPath $configPath -LogPath $logPath -Now $now -TimeZone $Tz
        $r.Status | Should -Be 'Failed'
        $r.ExitCode | Should -Be 1
        Should -Invoke -ModuleName DpmMonitor Send-DpmMonitorPing -Times 1 -Exactly -ParameterFilter { $Status -eq 'Failed' -and $Body -like '*Prüfung selbst ist fehlgeschlagen: DPM-Dienst antwortet nicht*' }
    }
    It 'cannot ping without a usable config' {
        Mock -ModuleName DpmMonitor Get-DpmMonitorState { New-CheckState '2026-11-19 20:05' }
        $r = Invoke-DpmMonitorCheck -ConfigPath (Join-Path $TestDrive 'missing.json') -LogPath $logPath -Now $now -TimeZone $Tz
        $r.ExitCode | Should -Be 2
        Should -Invoke -ModuleName DpmMonitor Send-DpmMonitorPing -Times 0 -Exactly
        Get-Content -LiteralPath $logPath -Encoding UTF8 -Raw | Should -BeLike '*[[]ERROR] Konfiguration nicht gefunden*'
    }
    It 'reports an undelivered ping' {
        Mock -ModuleName DpmMonitor Get-DpmMonitorState { New-CheckState '2026-11-19 20:05' }
        Mock -ModuleName DpmMonitor Send-DpmMonitorPing { [pscustomobject]@{ Success = $false; Url = $PingUrl; StatusCode = $null; Attempts = 3; Error = 'Zeitüberschreitung' } }
        $r = Invoke-DpmMonitorCheck -ConfigPath $configPath -LogPath $logPath -Now $now -TimeZone $Tz
        $r.ExitCode | Should -Be 3
        Get-Content -LiteralPath $logPath -Encoding UTF8 -Raw | Should -BeLike '*Healthchecks.io nicht erreichbar nach 3 Versuch(en): Zeitüberschreitung*'
    }
    It 'can check without pinging' {
        Mock -ModuleName DpmMonitor Get-DpmMonitorState { New-CheckState '2026-11-19 20:05' }
        $r = Invoke-DpmMonitorCheck -ConfigPath $configPath -LogPath $logPath -NoPing -Now $now -TimeZone $Tz
        $r.ExitCode | Should -Be 0
        $r.Ping | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DpmMonitor Send-DpmMonitorPing -Times 0 -Exactly
    }
}

Describe 'Check.ps1' {
    BeforeAll {
        $script = Join-Path $PSScriptRoot '..\src\Check.ps1'
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    It 'fails with exit code 1 when DPM is not available' {
        $configPath = Join-Path $TestDrive 'cfg.json'
        Save-DpmMonitorConfig -Config (New-TestConfig) -Path $configPath
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $script -ConfigPath $configPath -LogPath (Join-Path $TestDrive 'c.log') -NoPing
        $LASTEXITCODE | Should -Be 1
        ($out -join "`n") | Should -BeLike '*Prüfung selbst ist fehlgeschlagen*DPM-PowerShell-Modul nicht gefunden*'
    }
    It 'fails with exit code 2 without config' {
        & $exe -NoProfile -ExecutionPolicy Bypass -File $script -ConfigPath (Join-Path $TestDrive 'none.json') -LogPath (Join-Path $TestDrive 'd.log') -NoPing | Out-Null
        $LASTEXITCODE | Should -Be 2
    }
}
