#Requires -Version 5.1
<#
    .SYNOPSIS
    Builds the release package dpm-monitor-<version>.zip plus its SHA-256 file.

    The version comes from Nerdbank.GitVersioning (version.json plus git
    height, via the local dotnet tool "nbgv") and is stamped, together with
    the commit, into the packaged DpmMonitor.psm1. The sources keep the
    placeholder. -Version/-Commit override nbgv (tests, offline builds).
    With -Tag (e.g. from CI) the tag must be "v<version>".
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Tag,
    [string]$Version,
    [string]$Commit = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'src'

if (-not $Version) {
    # Native tools may write to stderr; with 'Stop' Windows PowerShell 5.1 would throw.
    $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $root
    try { $json = & dotnet tool run nbgv get-version --format json 2>$null }
    finally { Pop-Location }
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw 'nbgv lieferte keine Version. Vorher "dotnet tool restore" ausführen.' }
    $info = ($json -join "`n") | ConvertFrom-Json
    $Version = $info.SimpleVersion
    $Commit = $info.GitCommitIdShort
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Ungültige Version: '$Version'" }
if ($Commit -notmatch '^[0-9a-f]*$') { throw "Ungültiger Commit: '$Commit'" }
if ($Tag -and $Tag -ne "v$Version") {
    throw "Tag '$Tag' passt nicht zur berechneten Version ($Version). Erwartet: v$Version"
}
$version = $Version

$module = Import-Module (Join-Path $src 'DpmMonitor.psm1') -Force -PassThru
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

# Stamp version and commit into the packaged module (UTF-8 with BOM, CRLF kept).
$modulePath = Join-Path $staging 'DpmMonitor.psm1'
$text = [IO.File]::ReadAllText($modulePath)
foreach ($pair in @(@('ModuleVersion', $version), @('ModuleCommit', $Commit))) {
    $pattern = "(?m)^\`$script:$($pair[0]) = '[^']*'"
    if ([regex]::Matches($text, $pattern).Count -ne 1) { throw "Platzhalter `$script:$($pair[0]) nicht genau einmal gefunden." }
    # "$$" is a literal "$" in a .NET regex replacement.
    $text = [regex]::Replace($text, $pattern, "`$`$script:$($pair[0]) = '$($pair[1])'")
}
[IO.File]::WriteAllText($modulePath, $text, (New-Object Text.UTF8Encoding($true)))

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
