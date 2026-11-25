# Dot-sourced by the test scripts (. "$PSScriptRoot/TestHelpers.ps1"). Works in Windows PowerShell 5.1 and PowerShell 7.

$script:root = Split-Path $PSScriptRoot -Parent
$script:failures = 0

# Windows PowerShell 5.1 reads a .ps1 without a BOM as ANSI, which mangles literal non-ASCII text.
# Build such characters from their code points so the tests really test encodings.
$Aring = [string][char]0x00C5   # A with ring above
$ouml  = [string][char]0x00F6   # o with diaeresis

function Initialize-Runner {
    param([string] $Exe)
    if ($Exe) {
        $script:runner = @($Exe)
    } else {
        & dotnet build (Join-Path $script:root 'src/Parqueter') -c Release -o (Join-Path $script:root 'out/bin') --nologo -v quiet
        if ($LASTEXITCODE -ne 0) { throw 'build failed' }
        $script:runner = @('dotnet', (Join-Path $script:root 'out/bin/parqueter.dll'))
    }
}

function New-WorkDirectory {
    param([string] $Name)
    $dir = Join-Path $script:root "out/$Name"
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Force $dir
    $dir
}

function Invoke-Parqueter {
    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'; we want to read it.
    $ErrorActionPreference = 'Continue'
    $exe = $script:runner[0]
    $prefix = @($script:runner | Select-Object -Skip 1)
    $output = & $exe @prefix @args 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($output | ForEach-Object { "$_" }) -join "`n" }
}

# Pipes text lines to parqueter's stdin, the way the PowerShell module will.
function Invoke-ParqueterWithInput {
    param([string[]] $Lines, [string[]] $Arguments)
    $ErrorActionPreference = 'Continue'
    # $OutputEncoding decides how PowerShell encodes text piped to a native program (ASCII by default in 5.1).
    # It must be assigned in the global scope: a plain assignment inside a function is silently ignored.
    $previous = $global:OutputEncoding
    $global:OutputEncoding = New-Object System.Text.UTF8Encoding $false
    try {
        $exe = $script:runner[0]
        $prefix = @($script:runner | Select-Object -Skip 1)
        $output = $Lines | & $exe @prefix @Arguments 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($output | ForEach-Object { "$_" }) -join "`n" }
    } finally {
        $global:OutputEncoding = $previous
    }
}

function Assert-Match {
    param($Text, [string] $Pattern, [string] $What)
    if ($Text -match $Pattern) { Write-Host "  ok    $What" -ForegroundColor Green }
    else { Write-Host "  FAIL  $What  (expected /$Pattern/)" -ForegroundColor Red; $script:failures++ }
}

function Assert-True {
    param($Condition, [string] $What)
    if ($Condition) { Write-Host "  ok    $What" -ForegroundColor Green }
    else { Write-Host "  FAIL  $What" -ForegroundColor Red; $script:failures++ }
}

function Complete-Tests {
    if ($script:failures -gt 0) { Write-Host "`n$($script:failures) check(s) failed." -ForegroundColor Red; exit 1 }
    Write-Host "`nAll checks passed." -ForegroundColor Green
}
