#Requires -Version 7.4
#Requires -Modules PSParquet
<#
.SYNOPSIS
    First smoke test for PSParquet: write a small typed dataset to a Parquet
    file, then read it back and show what actually ended up in the file.

.DESCRIPTION
    PSParquet 0.2.x is built on .NET 8, so it needs PowerShell 7.4 or later
    (it does not load in Windows PowerShell 5.1).

    Two datasets are written:
      * typed.parquet - objects with real .NET types (int, decimal, datetime,
        guid, bool, nullable columns), the way a database reader or a REST
        client that parses JSON would give them to us.
      * csv.parquet   - the same data as it would arrive from a CSV file, where
        everything is a string and types and nullability are lost.

    The point is to see, with your own eyes, which types and which nullability
    survive the round trip, before building the real sources on top of this.

.PARAMETER OutputDirectory
    Where the Parquet files are written. Created if missing.
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'out')
)

$ErrorActionPreference = 'Stop'
Import-Module PSParquet

$null = New-Item -ItemType Directory -Force -Path $OutputDirectory

# --- 1. Typed data ---------------------------------------------------------
# Every property gets an explicit .NET type. Note that the last two rows have
# nulls: how PSParquet treats those (optional column or not) is one of the
# things this test reveals.
$typed = @(
    [pscustomobject]@{
        Id        = [int]1
        Name      = 'Alpha'
        Price     = [decimal]12.50
        Created   = [datetime]'2026-01-15T10:30:00'
        Guid      = [guid]'11111111-1111-1111-1111-111111111111'
        Active    = $true
        Quantity  = [Nullable[int]]5
    }
    [pscustomobject]@{
        Id        = [int]2
        Name      = 'Beta'
        Price     = [decimal]0.99
        Created   = [datetime]'2026-02-20T08:00:00'
        Guid      = [guid]'22222222-2222-2222-2222-222222222222'
        Active    = $false
        Quantity  = $null
    }
    [pscustomobject]@{
        Id        = [int]3
        Name      = $null
        Price     = [decimal]1234.56789012   # more digits than the others: does the scale survive?
        Created   = [datetime]'2026-03-01T00:00:00'
        Guid      = [guid]'33333333-3333-3333-3333-333333333333'
        Active    = $true
        Quantity  = [Nullable[int]]7
    }
)

$typedFile = Join-Path $OutputDirectory 'typed.parquet'
$typed | Export-Parquet -FilePath $typedFile -Force

# --- 2. The same data as CSV would deliver it: strings only ----------------
$csvFile = Join-Path $OutputDirectory 'csv.parquet'
$typed | ConvertTo-Csv -NoTypeInformation | ConvertFrom-Csv |
    Export-Parquet -FilePath $csvFile -Force

# --- 3. Read back and inspect ---------------------------------------------
foreach ($file in $typedFile, $csvFile) {
    Write-Host ''
    Write-Host "=== $(Split-Path $file -Leaf) ===" -ForegroundColor Cyan

    Write-Host '-- File info (schema as stored in the file) --'
    Get-ParquetFileInfo -FilePath $file | Format-List *

    Write-Host '-- Parquet schema as stored (via Parquet.Net, which PSParquet ships) --'
    try {
        $stream = [IO.File]::OpenRead($file)
        try {
            $reader = [Parquet.ParquetReader]::CreateAsync($stream).GetAwaiter().GetResult()
            foreach ($f in $reader.Schema.DataFields) {
                $extra = if ($f -is [Parquet.Schema.DecimalDataField]) {
                    "precision=$($f.Precision) scale=$($f.Scale)"
                } else { '' }
                '{0,-10} {1,-16} nullable={2,-5} {3}' -f $f.Name, $f.ClrType.Name, $f.IsNullable, $extra
            }
            $reader.Dispose()
        } finally { $stream.Dispose() }
    } catch {
        Write-Warning "Could not read the schema through Parquet.Net: $($_.Exception.Message)"
    }

    Write-Host '-- Rows read back --'
    $rows = Import-Parquet -FilePath $file
    $rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host

    Write-Host '-- .NET types of the first row after read-back --'
    $rows | Select-Object -First 1 | ForEach-Object {
        foreach ($p in $_.PSObject.Properties) {
            $t = if ($null -eq $p.Value) { '(null)' } else { $p.Value.GetType().Name }
            '{0,-10} {1}' -f $p.Name, $t
        }
    }

    Write-Host '-- Null vs empty string per column, across all rows --'
    foreach ($name in $rows[0].PSObject.Properties.Name) {
        $values = $rows | ForEach-Object { $_.$name }
        $nulls  = @($values | Where-Object { $null -eq $_ }).Count
        $empty  = @($values | Where-Object { $_ -is [string] -and $_ -eq '' }).Count
        '{0,-10} nulls={1} emptyStrings={2}' -f $name, $nulls, $empty
    }

    Write-Host '-- Price values read back --'
    $rows | ForEach-Object { $_.Price }
}
