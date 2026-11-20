#Requires -Version 5.1
<#
    .SYNOPSIS
    dpm-monitor: one check run, as executed by the scheduled task.

    Reads config.json next to this script, checks DPM, reports to
    Healthchecks.io and writes logs\dpm-monitor.log.
    Exit code: 0 ok, 1 backups failing or check failed, 2 config unusable,
    3 Healthchecks.io not reachable.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$LogPath,
    [string]$ResultPath,
    [switch]$NoPing
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty in param defaults under Windows PowerShell 5.1.
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'logs\dpm-monitor.log' }
if (-not $ResultPath) { $ResultPath = Join-Path $PSScriptRoot 'last-result.json' }

try {
    Import-Module (Join-Path $PSScriptRoot 'DpmMonitor.psm1') -Force
    $result = Invoke-DpmMonitorCheck -ConfigPath $ConfigPath -LogPath $LogPath -ResultPath $ResultPath -NoPing:$NoPing
}
catch {
    # Last resort: the module itself could not be loaded.
    Write-Error "dpm-monitor konnte nicht ausgeführt werden: $($_.Exception.Message)" -ErrorAction Continue
    exit 2
}

Write-Output $result.Report
exit $result.ExitCode
