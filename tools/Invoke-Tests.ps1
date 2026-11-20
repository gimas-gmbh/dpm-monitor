#Requires -Version 5.1
<#
    .SYNOPSIS
    Runs the Pester tests and PSScriptAnalyzer. Development only.

    Needs Pester 5 and PSScriptAnalyzer:
      Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
      Install-Module PSScriptAnalyzer -Scope CurrentUser
#>
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')][string]$Output = 'Normal'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

Import-Module Pester -MinimumVersion 5.5.0
$config = New-PesterConfiguration
$config.Run.Path = Join-Path $root 'tests'
$config.Run.PassThru = $true
$config.Output.Verbosity = $Output
$result = Invoke-Pester -Configuration $config
$failed = $result.FailedCount -gt 0 -or $result.Result -ne 'Passed'

if (-not $SkipAnalyzer) {
    Import-Module PSScriptAnalyzer
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    $findings = foreach ($dir in 'src', 'tools') {
        Invoke-ScriptAnalyzer -Path (Join-Path $root $dir) -Recurse -Settings $settings
    }
    if ($findings) {
        $findings | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 220 | Write-Output
        $failed = $true
    }
    else {
        Write-Output 'PSScriptAnalyzer: keine Befunde.'
    }
}

if ($failed) { exit 1 }
