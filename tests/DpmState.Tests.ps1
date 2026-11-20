BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DpmMonitor.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Install-DpmCmdletStub
}

AfterAll {
    Remove-DpmCmdletStub
}

Describe 'Get-DpmMonitorState' {
    BeforeAll {
        $fixture = Import-FixtureServer
        Mock -ModuleName DpmMonitor Get-DPMProtectionGroup { $fixture.Groups | ForEach-Object { $_.Group } }
        Mock -ModuleName DpmMonitor Get-DPMDatasource {
            ($fixture.Groups | Where-Object { $_.Group.FriendlyName -eq $ProtectionGroup.FriendlyName }).Datasources
        }
        Mock -ModuleName DpmMonitor Get-DPMPolicySchedule {
            ($fixture.Groups | Where-Object { $_.Group.FriendlyName -eq $ProtectionGroup.FriendlyName }).Schedules
        }
        Mock -ModuleName DpmMonitor Wait-DpmMonitorDatasourceProperty { [pscustomobject]@{ Registered = 0; Received = 0; Seconds = 0 } }
    }

    It 'reads all protection groups and data sources' {
        $state = Get-DpmMonitorState -ServerName 'SRV-DPM01'
        $state.ServerName | Should -Be 'SRV-DPM01'
        $state.ProtectionGroups.Name | Should -Be @('PG Fileserver', 'PG SQL', 'PG Hyper-V')
        @($state.ProtectionGroups | ForEach-Object { $_.Datasources }) | Should -HaveCount 7
    }
    It 'asks for the short-term schedules and normalises them' {
        $state = Get-DpmMonitorState -ServerName 'SRV-DPM01'
        Should -Invoke -ModuleName DpmMonitor Get-DPMPolicySchedule -Times 3 -Exactly -ParameterFilter { $ShortTerm }
        $file = $state.ProtectionGroups | Where-Object Name -eq 'PG Fileserver'
        $file.Schedules.Kind | Should -Be @('Synchronization', 'ShadowCopy', 'ExpressFull')
    }
    It 'shortens the type name and keeps the local recovery point time' {
        $state = Get-DpmMonitorState -ServerName 'SRV-DPM01'
        $vm = $state.ProtectionGroups.Datasources | Where-Object LogicalPath -eq 'RCT\SRV-APP01'
        $vm.Type | Should -Be 'HyperVRctObjectType'
        $vm.LatestRecoveryPoint | Should -Be (L '2026-11-19 22:40')
    }
    It 'turns 0001-01-01 into no recovery point' {
        $fixture.Groups[1].Datasources[0].LatestRecoveryPoint = [datetime]::MinValue
        try {
            $state = Get-DpmMonitorState -ServerName 'SRV-DPM01'
            ($state.ProtectionGroups.Datasources | Where-Object LogicalPath -eq 'SRV-SQL01\master').LatestRecoveryPoint | Should -BeNullOrEmpty
        }
        finally { $fixture.Groups[1].Datasources[0].LatestRecoveryPoint = L '2026-11-19 20:01' }
    }
    It 'waits for the asynchronous properties of all data sources' {
        Get-DpmMonitorState -ServerName 'SRV-DPM01' | Out-Null
        Should -Invoke -ModuleName DpmMonitor Wait-DpmMonitorDatasourceProperty -Times 1 -Exactly -ParameterFilter { $Datasource.Count -eq 7 }
    }
    It 'does not swallow DPM errors' {
        Mock -ModuleName DpmMonitor Get-DPMDatasource { throw 'Verbindung zum DPM-Dienst fehlgeschlagen' }
        { Get-DpmMonitorState -ServerName 'SRV-DPM01' } | Should -Throw '*Verbindung zum DPM-Dienst*'
    }
    It 'feeds the evaluation end to end' {
        $state = Get-DpmMonitorState -ServerName 'SRV-DPM01'
        $e = Invoke-DpmMonitorEvaluation -State $state -Config (New-TestConfig) -Now (U '2026-11-20 14:00') -TimeZone $Tz
        @($e.Items | Where-Object Status -ne 'Ok').LogicalPath | Should -Be 'SRV-SQL01\ArchiveDb'
    }
}

Describe 'Wait-DpmMonitorDatasourceProperty' {
    BeforeAll {
        # Simulates DPM: reading LatestRecoveryPoint starts loading in the
        # background; DataSourceChangedEvent fires when the value is there.
        if (-not ('DpmMonitorTest.FakeDatasource' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Threading;
namespace DpmMonitorTest {
    public class FakeDatasource {
        public event EventHandler DataSourceChangedEvent;
        private readonly DateTime loadedValue;
        private readonly int delayMs;
        private DateTime latest = DateTime.MinValue;
        private Timer timer;
        public FakeDatasource(DateTime value, int delayMs) { loadedValue = value; this.delayMs = delayMs; }
        public DateTime LatestRecoveryPoint {
            get {
                if (timer == null) {
                    timer = new Timer(_ => {
                        latest = loadedValue;
                        var h = DataSourceChangedEvent;
                        if (h != null) h(this, EventArgs.Empty);
                    }, null, delayMs, Timeout.Infinite);
                }
                return latest;
            }
        }
        public DateTime OldestRecoveryPoint { get { return DateTime.MinValue; } }
        public int TotalRecoveryPoints { get { return 0; } }
    }
}
'@
        }
    }

    It 'waits until every data source has loaded' {
        $ds = @(
            (New-Object DpmMonitorTest.FakeDatasource ((Get-Date '2026-11-19 20:01'), 200)),
            (New-Object DpmMonitorTest.FakeDatasource ((Get-Date '2026-11-19 20:02'), 400))
        )
        $r = InModuleScope DpmMonitor -Parameters @{ Ds = $ds } { param($Ds) Wait-DpmMonitorDatasourceProperty -Datasource $Ds -TimeoutSeconds 10 }
        $r.Registered | Should -Be 2
        $r.Received | Should -Be 2
        $ds[1].LatestRecoveryPoint | Should -Be (Get-Date '2026-11-19 20:02')
        @(Get-EventSubscriber | Where-Object SourceIdentifier -like 'DpmMonitor-*') | Should -HaveCount 0
    }
    It 'gives up after the timeout' {
        $ds = @(New-Object DpmMonitorTest.FakeDatasource ((Get-Date '2026-11-19 20:01'), 5000))
        $r = InModuleScope DpmMonitor -Parameters @{ Ds = $ds } { param($Ds) Wait-DpmMonitorDatasourceProperty -Datasource $Ds -TimeoutSeconds 1 }
        $r.Received | Should -Be 0
        $r.Seconds | Should -BeLessThan 3
    }
    It 'returns at once for objects without the event' {
        $r = InModuleScope DpmMonitor { Wait-DpmMonitorDatasourceProperty -Datasource @([pscustomobject]@{ LatestRecoveryPoint = $null }) -TimeoutSeconds 30 }
        $r.Registered | Should -Be 0
        $r.Seconds | Should -BeLessThan 1
    }
}
