#Requires -Version 5.1
<#
    .SYNOPSIS
    Builds the release package dpm-monitor-<version>.zip plus its SHA-256 file.

    The version comes from $script:ModuleVersion in src\DpmMonitor.psm1.
    With -Tag (e.g. from CI) the tag must be "v<version>".
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'src'
$module = Import-Module (Join-Path $src 'DpmMonitor.psm1') -Force -PassThru
$version = Get-DpmMonitorVersion
if ($Tag -and $Tag -ne "v$version") {
    throw "Tag '$Tag' passt nicht zur Version im Modul ($version). Erwartet: v$version"
}
$files = & $module { $script:ProductFiles }

$OutDir = [IO.Path]::GetFullPath($OutDir)
$name = "dpm-monitor-$version"
$staging = Join-Path $OutDir $name
$zip = Join-Path $OutDir "$name.zip"
foreach ($p in $staging, $zip, "$zip.sha256") {
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}
New-Item -ItemType Directory -Path $staging -Force | Out-Null

foreach ($f in $files) {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination $staging
}

$readme = @"
dpm-monitor $version
====================

Überwachung der DPM-Sicherungen mit Meldung an Healthchecks.io.

Installation und Update
1. In Healthchecks.io einen Check für diesen Server anlegen:
   Periode 4 Stunden, Grace Time 2 Stunden. Die Ping-URL kopieren.
2. Diesen Ordner auf den DPM-Server kopieren.
3. Konfigurieren.cmd doppelklicken und die Rechteerhöhung bestätigen.
4. Ping-URL eintragen und "Installieren" wählen. Die erste Prüfung
   läuft sofort, das Ergebnis wird angezeigt.

Bei einem Update dasselbe tun: die Konfiguration bleibt erhalten.

Danach ist die Oberfläche über das Startmenü erreichbar
("DPM-Überwachung"). Installiert wird nach C:\Program Files\DpmMonitor\.

Weitere Informationen: https://github.com/gimas-gmbh/dpm-monitor
"@
[IO.File]::WriteAllText((Join-Path $staging 'README.txt'), ($readme -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($true)))

# Entries are written one by one: ZipFile.CreateFromDirectory in .NET Framework
# may store backslashes, which the ZIP format does not allow.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem -LiteralPath $staging -File | Sort-Object Name) {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, "$name/$($file.Name)", [IO.Compression.CompressionLevel]::Optimal)
    }
}
finally { $archive.Dispose() }
Remove-Item -LiteralPath $staging -Recurse -Force

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zip.sha256", "$hash  $name.zip`n", (New-Object Text.UTF8Encoding($false)))

Get-Item -LiteralPath $zip, "$zip.sha256"
