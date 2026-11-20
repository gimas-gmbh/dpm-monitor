Describe 'Repository conventions' {
    It 'stores all PowerShell and cmd sources as UTF-8 with BOM and CRLF' {
        $script = Join-Path $PSScriptRoot '..\tools\Format-SourceFiles.ps1'
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $script -Check
        $out | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }
}
