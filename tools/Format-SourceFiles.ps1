#Requires -Version 5.1
<#
    .SYNOPSIS
    Normalises sources: PowerShell files to UTF-8 with BOM and CRLF,
    .cmd files to plain ASCII with CRLF.

    Windows PowerShell 5.1 reads .ps1 files without BOM as ANSI, which breaks
    umlauts. cmd.exe on the other hand chokes on a BOM in the first line.
    Run this after editing files with tools that write UTF-8 without BOM.
    Use -Check to only report files that need fixing (exit code 1 if any).
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Check
)

# $PSScriptRoot is empty in param defaults under Windows PowerShell 5.1.
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$extensions = '.ps1', '.psm1', '.psd1', '.cmd'
$folders = 'src', 'tools', 'tests'
$utf8Bom = New-Object Text.UTF8Encoding($true)
$utf8Strict = New-Object Text.UTF8Encoding($false, $true)
$bad = New-Object System.Collections.Generic.List[string]

$files = foreach ($f in $folders) {
    $dir = Join-Path $Root $f
    if (Test-Path -LiteralPath $dir) {
        Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() }
    }
}

foreach ($file in $files) {
    $isCmd = $file.Extension -ieq '.cmd'
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    try { $text = $utf8Strict.GetString($bytes, $offset, $bytes.Length - $offset) }
    catch { throw "Datei ist kein gültiges UTF-8: $($file.FullName)" }
    if ($isCmd -and $text -match '[^\x00-\x7F]') { throw "cmd-Datei darf nur ASCII enthalten: $($file.FullName)" }
    $normalized = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    $wantBom = -not $isCmd
    if ($hasBom -eq $wantBom -and $normalized -ceq $text) { continue }

    $bad.Add($file.FullName)
    if (-not $Check) {
        $encoding = if ($wantBom) { $utf8Bom } else { New-Object Text.UTF8Encoding($false) }
        [IO.File]::WriteAllText($file.FullName, $normalized, $encoding)
        Write-Output "korrigiert: $($file.FullName)"
    }
}

if ($Check -and $bad.Count -gt 0) {
    $bad | ForEach-Object { Write-Output "Kodierung/Zeilenenden falsch: $_" }
    exit 1
}
