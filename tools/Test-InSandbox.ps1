#Requires -Version 5.1
<#
    .SYNOPSIS
    End-to-end test in Windows Sandbox: installation, scheduled task as SYSTEM,
    update, UI start and removal. Development only.

    Builds the current package (nbgv) and a newer one for the update test,
    starts Windows Sandbox with tools\sandbox\Run-SandboxTest.ps1 and waits
    for its results (results.json, steps.log, screenshots) in -WorkDir.
    The sandbox has network access. Without -PingUrl the check pings
    hc-ping.com with an all-zero UUID, which Healthchecks.io rejects. With
    -PingUrl (a test check, never a customer's) it reports there for real;
    the URL is passed through the work folder only, never stored in the repo.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path $env:TEMP 'dpm-monitor-sandbox'),
    [int]$TimeoutMinutes = 20,
    [string]$PingUrl
)

$ErrorActionPreference = 'Stop'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (Get-Process -Name 'WindowsSandbox*' -ErrorAction SilentlyContinue) { throw 'Windows Sandbox läuft bereits. Bitte erst schließen.' }
if (-not (Test-Path (Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'))) { throw 'Windows Sandbox ist nicht installiert.' }

$inDir = Join-Path $WorkDir 'in'
$outDir = Join-Path $WorkDir 'out'
foreach ($d in $inDir, $outDir) {
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

$build = Join-Path $PSScriptRoot 'Build-Release.ps1'
& $powershell -NoProfile -ExecutionPolicy Bypass -File $build -OutDir $inDir | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Paket konnte nicht gebaut werden.' }
$current = (Get-ChildItem -LiteralPath $inDir -Filter '*.zip')[0].BaseName -replace '^dpm-monitor-', ''
$parts = $current.Split('.')
$newer = "$($parts[0]).$($parts[1]).$([int]$parts[2] + 1000)"
& $powershell -NoProfile -ExecutionPolicy Bypass -File $build -OutDir $inDir -Version $newer -Commit 'feed' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Update-Paket konnte nicht gebaut werden.' }
Get-ChildItem -LiteralPath $inDir -Filter '*.sha256' | Remove-Item

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sandbox\Run-SandboxTest.ps1') -Destination $inDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sandbox\DataProtectionManager') -Destination $inDir -Recurse
if ($PingUrl) { Set-Content -LiteralPath (Join-Path $inDir 'pingurl.txt') -Value $PingUrl -Encoding ASCII }

$wsb = Join-Path $WorkDir 'dpm-monitor-test.wsb'
$config = @"
<Configuration>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$([Security.SecurityElement]::Escape($inDir))</HostFolder>
      <SandboxFolder>C:\Test</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$([Security.SecurityElement]::Escape($outDir))</HostFolder>
      <SandboxFolder>C:\Results</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Test\Run-SandboxTest.ps1</Command>
  </LogonCommand>
</Configuration>
"@
[IO.File]::WriteAllText($wsb, $config, (New-Object Text.UTF8Encoding($false)))

Write-Output "Pakete: $current und $newer. Starte Windows Sandbox ..."
Start-Process -FilePath $wsb
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$done = Join-Path $outDir 'done.txt'
while (-not (Test-Path -LiteralPath $done) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
if (-not (Test-Path -LiteralPath $done)) { Write-Output "Zeitüberschreitung. Zwischenstand in $outDir"; exit 1 }

Get-Content -LiteralPath (Join-Path $outDir 'steps.log') -Encoding UTF8
Write-Output "Ergebnisse: $outDir"
$failed = Select-String -LiteralPath (Join-Path $outDir 'steps.log') -Pattern '^\S+ (FAIL|ABBRUCH)' -Quiet
if ($failed) { exit 1 }
exit 0
