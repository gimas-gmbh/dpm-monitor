BeforeAll {
    $root = Join-Path $PSScriptRoot '..'
    $script = Join-Path $root 'tools\Build-Release.ps1'
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    function Read-ZipEntry {
        param([string]$Zip, [string]$Entry)
        $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            $ms = New-Object IO.MemoryStream
            $s = $archive.GetEntry($Entry).Open(); $s.CopyTo($ms); $s.Dispose()
            , $ms.ToArray()
        }
        finally { $archive.Dispose() }
    }

    # Windows PowerShell 5.1 turns stderr of native programs into errors; with
    # ErrorActionPreference Stop (as in Invoke-Tests.ps1) these would throw.
    function Invoke-Build {
        param([string[]]$Arguments)
        $ErrorActionPreference = 'Continue'
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $script @Arguments 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
    }
}

Describe 'Build-Release.ps1 with a given version' {
    BeforeAll {
        $out = Join-Path $TestDrive 'dist'
        $build = Invoke-Build @('-OutDir', $out, '-Version', '1.2.3', '-Commit', 'abc1234def', '-Tag', 'v1.2.3')
        $zip = Join-Path $out 'dpm-monitor-1.2.3.zip'
    }

    It 'succeeds for the matching tag' {
        $build.ExitCode | Should -Be 0
        $zip | Should -Exist
    }
    It 'packs the product files and the readme in one folder' {
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($archive.Entries | ForEach-Object { $_.FullName }) }
        finally { $archive.Dispose() }
        ($names | Sort-Object) | Should -Be (@('Check.ps1', 'Configure.ps1', 'DpmMonitor.psm1', 'Konfigurieren.cmd', 'README.txt') | ForEach-Object { "dpm-monitor-1.2.3/$_" })
    }
    It 'writes a matching SHA-256 file' {
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        Get-Content -LiteralPath "$zip.sha256" -Raw | Should -Be "$hash  dpm-monitor-1.2.3.zip`n"
    }
    It 'keeps the other sources byte for byte: <_>' -ForEach @('Check.ps1', 'Configure.ps1', 'Konfigurieren.cmd') {
        $packed = [Convert]::ToBase64String((Read-ZipEntry $zip "dpm-monitor-1.2.3/$_"))
        $packed | Should -Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root "src\$_"))))
    }
    It 'stamps version and commit into the module and changes nothing else' {
        $packed = [Text.Encoding]::UTF8.GetString((Read-ZipEntry $zip 'dpm-monitor-1.2.3/DpmMonitor.psm1')) -split "`r`n"
        $source = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $root 'src\DpmMonitor.psm1'))) -split "`r`n"
        $packed.Count | Should -Be $source.Count
        $diff = for ($i = 0; $i -lt $source.Count; $i++) { if ($packed[$i] -cne $source[$i]) { $packed[$i] } }
        $diff | Should -Be @("`$script:ModuleVersion = '1.2.3'", "`$script:ModuleCommit = 'abc1234def'")
    }
    It 'reports the stamped version at runtime' {
        $dir = Join-Path $TestDrive 'unpacked'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
        $module = Join-Path $dir 'dpm-monitor-1.2.3\DpmMonitor.psm1'
        & $exe -NoProfile -Command "Import-Module '$module'; Get-DpmMonitorVersion -WithCommit" | Should -Be '1.2.3 (abc1234def)'
    }
    It 'refuses a tag that does not match the version' {
        $r = Invoke-Build @('-OutDir', (Join-Path $TestDrive 'x'), '-Version', '1.2.3', '-Tag', 'v1.2.4')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*passt nicht zur berechneten Version*'
    }
    It 'refuses an invalid version' {
        $r = Invoke-Build @('-OutDir', (Join-Path $TestDrive 'y'), '-Version', '1.2')
        $r.ExitCode | Should -Not -Be 0
    }
}

Describe 'Build-Release.ps1 with nbgv' {
    BeforeAll {
        Push-Location $root
        try {
            $ErrorActionPreference = 'Continue'
            $json = & dotnet tool run nbgv get-version --format json 2>$null
            $nbgv = if ($LASTEXITCODE -eq 0 -and $json) { ($json -join "`n") | ConvertFrom-Json } else { $null }
        }
        finally { Pop-Location; $ErrorActionPreference = 'Stop' }
    }

    It 'takes version and commit from nbgv' {
        if (-not $nbgv) { Set-ItResult -Skipped -Because 'nbgv ist nicht verfügbar (dotnet tool restore)'; return }
        $out = Join-Path $TestDrive 'nbgv'
        (Invoke-Build @('-OutDir', $out)).ExitCode | Should -Be 0
        $zip = Join-Path $out "dpm-monitor-$($nbgv.SimpleVersion).zip"
        $zip | Should -Exist
        $text = [Text.Encoding]::UTF8.GetString((Read-ZipEntry $zip "dpm-monitor-$($nbgv.SimpleVersion)/DpmMonitor.psm1"))
        $text | Should -Match ([regex]::Escape("`$script:ModuleCommit = '$($nbgv.GitCommitIdShort)'"))
    }
}
