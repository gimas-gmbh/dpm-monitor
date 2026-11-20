BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DpmMonitor.psm1') -Force
    $script = Join-Path $PSScriptRoot '..\tools\Build-Release.ps1'
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $version = Get-DpmMonitorVersion
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

Describe 'Build-Release.ps1' {
    BeforeAll {
        $out = Join-Path $TestDrive 'dist'
        & $exe -NoProfile -ExecutionPolicy Bypass -File $script -OutDir $out -Tag "v$version" | Out-Null
        $buildExit = $LASTEXITCODE
        $zip = Join-Path $out "dpm-monitor-$version.zip"
    }

    It 'succeeds for the matching tag' {
        $buildExit | Should -Be 0
        $zip | Should -Exist
    }
    It 'packs the product files and the readme in one folder' {
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($archive.Entries | ForEach-Object { $_.FullName }) }
        finally { $archive.Dispose() }
        $prefix = "dpm-monitor-$version/"
        ($names | Sort-Object) | Should -Be (@('Check.ps1', 'Configure.ps1', 'DpmMonitor.psm1', 'Konfigurieren.cmd', 'README.txt') | ForEach-Object { "$prefix$_" })
    }
    It 'writes a matching SHA-256 file' {
        $line = Get-Content -LiteralPath "$zip.sha256" -Raw
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        $line | Should -Be "$hash  dpm-monitor-$version.zip`n"
    }
    It 'keeps the sources byte for byte (BOM, CRLF)' {
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $entry = $archive.GetEntry("dpm-monitor-$version/Configure.ps1")
            $ms = New-Object IO.MemoryStream
            $s = $entry.Open(); $s.CopyTo($ms); $s.Dispose()
            $ms.ToArray() | Should -Be ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\src\Configure.ps1')))
        }
        finally { $archive.Dispose() }
    }
    It 'refuses a tag that does not match the module version' {
        # Windows PowerShell 5.1 turns stderr of native programs into errors; with
        # ErrorActionPreference Stop (as in Invoke-Tests.ps1) these would throw.
        $ErrorActionPreference = 'Continue'
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $script -OutDir (Join-Path $TestDrive 'x') -Tag 'v99.0.0' 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out | Out-String) | Should -BeLike '*passt nicht zur Version*'
    }
}
