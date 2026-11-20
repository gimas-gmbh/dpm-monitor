BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DpmMonitor.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $srcDir = Join-Path $PSScriptRoot '..\src'
    $productFiles = 'DpmMonitor.psm1', 'Check.ps1', 'Configure.ps1', 'Konfigurieren.cmd'

    function New-Package {
        $dir = Join-Path $TestDrive "package-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        foreach ($f in $productFiles) { Copy-Item -LiteralPath (Join-Path $srcDir $f) -Destination $dir }
        $dir
    }
}

Describe 'Install-DpmMonitor' {
    BeforeEach {
        Mock -ModuleName DpmMonitor Register-ScheduledTask { }
        Mock -ModuleName DpmMonitor Get-ScheduledTask { }
        Mock -ModuleName DpmMonitor Set-DpmMonitorShortcut { }
        Mock -ModuleName DpmMonitor Protect-DpmMonitorConfigFile { }
        $package = New-Package
        $target = Join-Path $TestDrive "install-$([guid]::NewGuid().ToString('N'))"
    }

    It 'copies the scripts, saves the config and registers the task' {
        $r = Install-DpmMonitor -SourcePath $package -InstallPath $target -Config (New-TestConfig) -Confirm:$false
        foreach ($f in $productFiles) { Join-Path $target $f | Should -Exist }
        (Read-DpmMonitorConfig -Path (Join-Path $target 'config.json')).PingUrl | Should -Be (New-TestConfig).PingUrl
        $r.Installed | Should -BeTrue
        $r.Version | Should -Be (Get-DpmMonitorVersion)
        Should -Invoke -ModuleName DpmMonitor Protect-DpmMonitorConfigFile -Times 1 -Exactly
        Should -Invoke -ModuleName DpmMonitor Set-DpmMonitorShortcut -Times 1 -Exactly -ParameterFilter { $InstallPath -eq $target }
    }
    It 'registers a task that runs Check.ps1 as SYSTEM every 4 hours' {
        Install-DpmMonitor -SourcePath $package -InstallPath $target -Config (New-TestConfig) -Confirm:$false | Out-Null
        $check = Join-Path $target 'Check.ps1'
        Should -Invoke -ModuleName DpmMonitor Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'DpmMonitor' -and
            $Action.Execute -like '*\WindowsPowerShell\v1.0\powershell.exe' -and
            $Action.Arguments -eq "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$check`"" -and
            $Principal.UserId -eq 'SYSTEM' -and $Principal.RunLevel -eq 'Highest' -and
            $Trigger.Repetition.Interval -eq 'PT4H' -and
            $Settings.MultipleInstances -eq 'IgnoreNew'
        }
    }
    It 'keeps the existing config on update' {
        Install-DpmMonitor -SourcePath $package -InstallPath $target -Config (New-TestConfig @{ JobBufferHours = 5 }) -Confirm:$false | Out-Null
        Install-DpmMonitor -SourcePath $package -InstallPath $target -Confirm:$false | Out-Null
        (Read-DpmMonitorConfig -Path (Join-Path $target 'config.json')).JobBufferHours | Should -Be 5
        Should -Invoke -ModuleName DpmMonitor Protect-DpmMonitorConfigFile -Times 1 -Exactly
    }
    It 'replaces old scripts on update' {
        Install-DpmMonitor -SourcePath $package -InstallPath $target -Config (New-TestConfig) -Confirm:$false | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'Check.ps1') -Value '# alt'
        Install-DpmMonitor -SourcePath $package -InstallPath $target -Confirm:$false | Out-Null
        Get-Content -LiteralPath (Join-Path $target 'Check.ps1') -Raw | Should -Not -Be "# alt`r`n"
    }
    It 'needs a config for a new installation' {
        { Install-DpmMonitor -SourcePath $package -InstallPath $target -Confirm:$false } | Should -Throw '*Konfiguration*'
        $target | Should -Not -Exist
    }
    It 'rejects an invalid config before changing anything' {
        { Install-DpmMonitor -SourcePath $package -InstallPath $target -Config (New-TestConfig @{ PingUrl = 'nope' }) -Confirm:$false } | Should -Throw 'Konfiguration ungültig*'
        $target | Should -Not -Exist
        Should -Invoke -ModuleName DpmMonitor Register-ScheduledTask -Times 0 -Exactly
    }
    It 'rejects an incomplete package' {
        Remove-Item -LiteralPath (Join-Path $package 'Check.ps1')
        { Install-DpmMonitor -SourcePath $package -InstallPath $target -Config (New-TestConfig) -Confirm:$false } | Should -Throw '*es fehlt: Check.ps1'
    }
    It 'can re-register from the installed copy itself' {
        Install-DpmMonitor -SourcePath $package -InstallPath $target -Config (New-TestConfig) -Confirm:$false | Out-Null
        { Install-DpmMonitor -SourcePath $target -InstallPath $target -Confirm:$false } | Should -Not -Throw
        Should -Invoke -ModuleName DpmMonitor Register-ScheduledTask -Times 2 -Exactly
    }
    It 'does nothing with -WhatIf' {
        Install-DpmMonitor -SourcePath $package -InstallPath $target -Config (New-TestConfig) -WhatIf | Out-Null
        $target | Should -Not -Exist
        Should -Invoke -ModuleName DpmMonitor Register-ScheduledTask -Times 0 -Exactly
    }
}

Describe 'Get-DpmMonitorInstallation' {
    It 'reports a missing installation' {
        Mock -ModuleName DpmMonitor Get-ScheduledTask { }
        $r = Get-DpmMonitorInstallation -InstallPath (Join-Path $TestDrive 'nothing')
        $r.Installed | Should -BeFalse
        $r.TaskExists | Should -BeFalse
    }
    It 'reads version and task details' {
        Mock -ModuleName DpmMonitor Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        Mock -ModuleName DpmMonitor Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = (Get-Date '2026-11-20 08:00'); LastTaskResult = 0; NextRunTime = (Get-Date '2026-11-20 12:00') } }
        $dir = Join-Path $TestDrive 'installed'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'DpmMonitor.psm1') -Value "`$script:ModuleVersion = '1.2.3'"
        $r = Get-DpmMonitorInstallation -InstallPath $dir
        $r.Installed | Should -BeTrue
        $r.Version | Should -Be '1.2.3'
        $r.TaskState | Should -Be 'Ready'
        $r.NextRunTime | Should -Be (Get-Date '2026-11-20 12:00')
    }
}

Describe 'Compare-DpmMonitorVersion' {
    It 'compares numerically' {
        Compare-DpmMonitorVersion '0.10.0' '0.9.1' | Should -Be 1
        Compare-DpmMonitorVersion '1.0.0' '1.0.0' | Should -Be 0
        Compare-DpmMonitorVersion '0.1.0' '0.2.0' | Should -Be -1
        Compare-DpmMonitorVersion '0.1.0' $null | Should -Be 1
    }
}

Describe 'Get-DpmMonitorExecutionPolicyWarning' {
    It 'warns about AllSigned from Group Policy' {
        Mock -ModuleName DpmMonitor Get-ExecutionPolicy { 'AllSigned' } -ParameterFilter { $Scope -eq 'MachinePolicy' }
        Get-DpmMonitorExecutionPolicyWarning | Should -BeLike '*AllSigned*'
    }
    It 'is quiet otherwise' {
        Mock -ModuleName DpmMonitor Get-ExecutionPolicy { 'RemoteSigned' } -ParameterFilter { $Scope -eq 'MachinePolicy' }
        Get-DpmMonitorExecutionPolicyWarning | Should -BeNullOrEmpty
    }
}

Describe 'Uninstall-DpmMonitor' {
    BeforeEach {
        Mock -ModuleName DpmMonitor Register-ScheduledTask { }
        Mock -ModuleName DpmMonitor Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        Mock -ModuleName DpmMonitor Unregister-ScheduledTask { }
        Mock -ModuleName DpmMonitor Set-DpmMonitorShortcut { }
        Mock -ModuleName DpmMonitor Protect-DpmMonitorConfigFile { }
        Mock -ModuleName DpmMonitor Get-ScheduledTaskInfo { }
        $target = Join-Path $TestDrive "install-$([guid]::NewGuid().ToString('N'))"
        Install-DpmMonitor -SourcePath (New-Package) -InstallPath $target -Config (New-TestConfig) -Confirm:$false | Out-Null
        Write-DpmMonitorLog -Path (Join-Path $target 'logs\dpm-monitor.log') -Message 'x'
        Set-Content -LiteralPath (Join-Path $target 'last-result.json') -Value '{}'
    }
    It 'removes task, scripts, config, log and folder' {
        Uninstall-DpmMonitor -InstallPath $target -Confirm:$false
        Should -Invoke -ModuleName DpmMonitor Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'DpmMonitor' }
        $target | Should -Not -Exist
    }
    It 'can keep the config' {
        Uninstall-DpmMonitor -InstallPath $target -KeepConfig -Confirm:$false
        Join-Path $target 'config.json' | Should -Exist
        Join-Path $target 'DpmMonitor.psm1' | Should -Not -Exist
    }
    It 'leaves foreign files alone' {
        Set-Content -LiteralPath (Join-Path $target 'notiz.txt') -Value 'bleibt'
        Uninstall-DpmMonitor -InstallPath $target -Confirm:$false
        Join-Path $target 'notiz.txt' | Should -Exist
        Join-Path $target 'Check.ps1' | Should -Not -Exist
    }
}

Describe 'Start-DpmMonitorTask' {
    BeforeAll {
        Mock -ModuleName DpmMonitor Start-Sleep { }
        Mock -ModuleName DpmMonitor Start-ScheduledTask { }
        Mock -ModuleName DpmMonitor Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
    }
    BeforeEach {
        $dir = Join-Path $TestDrive "run-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $script:calls = 0
        # First call: before the start; later calls: the run has happened.
        Mock -ModuleName DpmMonitor Get-ScheduledTaskInfo {
            $script:calls++
            if ($script:calls -eq 1) { [pscustomobject]@{ LastRunTime = (Get-Date '2026-11-20 08:00'); LastTaskResult = 0 } }
            else { [pscustomobject]@{ LastRunTime = (Get-Date); LastTaskResult = 1 } }
        }
    }
    It 'starts the task and returns the fresh result' {
        $result = [pscustomobject]@{ Status = 'Failed'; ExitCode = 1; Report = 'FEHLER'; Ping = [pscustomobject]@{ Success = $true; Error = $null } }
        Save-DpmMonitorLastResult -Path (Join-Path $dir 'last-result.json') -Result $result
        $r = Start-DpmMonitorTask -InstallPath $dir -Confirm:$false
        Should -Invoke -ModuleName DpmMonitor Start-ScheduledTask -ParameterFilter { $TaskName -eq 'DpmMonitor' }
        $r.Completed | Should -BeTrue
        $r.LastTaskResult | Should -Be 1
        $r.Result.Report | Should -Be 'FEHLER'
        $r.Result.PingSuccess | Should -BeTrue
    }
    It 'ignores a result from an earlier run' {
        $result = [pscustomobject]@{ Status = 'Ok'; ExitCode = 0; Report = 'alt'; Ping = $null }
        Save-DpmMonitorLastResult -Path (Join-Path $dir 'last-result.json') -Result $result -Now ([datetime]::UtcNow.AddHours(-4))
        (Start-DpmMonitorTask -InstallPath $dir -Confirm:$false).Result | Should -BeNullOrEmpty
    }
    It 'gives up after the timeout' {
        Mock -ModuleName DpmMonitor Get-ScheduledTask { [pscustomobject]@{ State = 'Running' } }
        $r = Start-DpmMonitorTask -InstallPath $dir -TimeoutSeconds 0 -Confirm:$false
        $r.Completed | Should -BeFalse
    }
}

Describe 'Last result' {
    It 'round-trips through JSON with a UTC time' {
        $path = Join-Path $TestDrive 'r.json'
        $result = [pscustomobject]@{ Status = 'Ok'; ExitCode = 0; Report = "Prüfung`nok"; Ping = [pscustomobject]@{ Success = $false; Error = 'weg' } }
        Save-DpmMonitorLastResult -Path $path -Result $result -Now (Z '2026-11-20 09:00')
        $r = Read-DpmMonitorLastResult -Path $path
        $r.Time | Should -Be (Z '2026-11-20 09:00')
        $r.Time.Kind | Should -Be 'Utc'
        $r.Report | Should -Be "Prüfung`nok"
        $r.PingSuccess | Should -BeFalse
        $r.PingError | Should -Be 'weg'
    }
    It 'is written by Invoke-DpmMonitorCheck, also for an unusable config' {
        $path = Join-Path $TestDrive 'r2.json'
        Invoke-DpmMonitorCheck -ConfigPath (Join-Path $TestDrive 'none.json') -LogPath (Join-Path $TestDrive 'r2.log') -ResultPath $path -NoPing | Out-Null
        $r = Read-DpmMonitorLastResult -Path $path
        $r.ExitCode | Should -Be 2
        $r.PingSuccess | Should -BeNullOrEmpty
    }
}
