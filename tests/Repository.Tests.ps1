Describe 'Repository conventions' {
    It 'stores PowerShell sources as UTF-8 with BOM and CRLF, cmd files as ASCII with CRLF' {
        $script = Join-Path $PSScriptRoot '..\tools\Format-SourceFiles.ps1'
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $script -Check
        $out | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }

    # Catches e.g. German quotation marks („“), which PowerShell treats as
    # double quotes inside double-quoted strings.
    It 'parses every script without errors: <Name>' -ForEach @(
        Get-ChildItem -Path (Join-Path $PSScriptRoot '..\src'), (Join-Path $PSScriptRoot '..\tools'), $PSScriptRoot -Recurse -File -Include *.ps1, *.psm1 |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        @($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) | Should -BeNullOrEmpty
    }
}
