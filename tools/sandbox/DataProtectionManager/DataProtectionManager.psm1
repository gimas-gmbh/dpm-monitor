# Fake DPM module for tests in Windows Sandbox. Synthetic data only.
# Provides the cmdlets dpm-monitor uses, so the scheduled task can run a
# complete check without a DPM server.

function Get-DPMProtectionGroup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    param($DPMServerName)
    $pg = [pscustomobject]@{ FriendlyName = 'PG SQL'; Name = 'PG SQL' }
    $pg.PSObject.TypeNames.Insert(0, 'Microsoft.Internal.EnterpriseStorage.Dls.UI.ObjectModel.OMCommon.ProtectionGroup')
    $pg
}

function Get-DPMDatasource {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    param($ProtectionGroup)
    $now = Get-Date
    foreach ($n in 1, 2) {
        [pscustomobject]@{
            Name                 = "db0$n"
            ProductionServerName = 'srv-sql01.example.local'
            LogicalPath          = "SRV-SQL01\db0$n"
            DatasourceId         = [guid]::NewGuid().ToString()
            Type                 = 'Microsoft.Internal.EnterpriseStorage.Dls.UI.ObjectModel.SQL.SQLObjectType'
            ObjectType           = 'SQL Server 2019-Datenbank'
            State                = 'Valid'
            LatestRecoveryPoint  = $now.AddMinutes(-30 * $n)
        }
    }
    # A stale one, so the UI shows a failure and an exclusion can be tested.
    [pscustomobject]@{
        Name                 = 'ArchiveDb'
        ProductionServerName = 'srv-sql01.example.local'
        LogicalPath          = 'SRV-SQL01\ArchiveDb'
        DatasourceId         = [guid]::NewGuid().ToString()
        Type                 = 'Microsoft.Internal.EnterpriseStorage.Dls.UI.ObjectModel.SQL.SQLObjectType'
        ObjectType           = 'SQL Server 2019-Datenbank'
        State                = 'Invalid'
        LatestRecoveryPoint  = $now.AddDays(-20)
    }
}

function Get-DPMPolicySchedule {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    param($ProtectionGroup, [switch]$ShortTerm, [switch]$OffsetSchedule, $LongTerm)
    if (-not $ShortTerm) { return }
    $sync = [pscustomobject]@{ Frequency = 60; JobType = 'Replication'; ScheduleDescription = 'Alle 60 Minuten' }
    $sync.PSObject.TypeNames.Insert(0, 'Microsoft.Internal.EnterpriseStorage.Dls.UI.ObjectModel.OMCommon.ReplicationSchedule')
    $full = [pscustomobject]@{
        TimesOfDay          = [Collections.ArrayList]@((Get-Date).Date.AddHours(20))
        WeekDays            = [Collections.ArrayList]@('Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa')
        JobType             = 'FullReplicationForApplication'
        ScheduleDescription = '20:00 taeglich'
    }
    $full.PSObject.TypeNames.Insert(0, 'Microsoft.Internal.EnterpriseStorage.Dls.UI.ObjectModel.OMCommon.FullSchedule')
    $sync
    $full
}

Export-ModuleMember -Function Get-DPMProtectionGroup, Get-DPMDatasource, Get-DPMPolicySchedule
