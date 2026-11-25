<#
.SYNOPSIS
    Test of the PowerShell module (powershell/Parqueter.psm1) against parqueter.exe, in Windows PowerShell 5.1.
    Uses a DataTable reader, so no database server is needed; any ADO.NET reader behaves the same way.

.PARAMETER Exe
    Path to the Windows parqueter.exe.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Exe)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/TestHelpers.ps1"
Initialize-Runner $Exe
$work = New-WorkDirectory 'test-module'
Import-Module (Join-Path $root 'powershell/Parqueter.psm1') -Force

function Get-Failure {
    param([scriptblock] $Block)
    try { & $Block; $null } catch { $_.Exception.Message }
}

function New-TestTable {
    $t = New-Object System.Data.DataTable
    function Add-Col($name, $type, $allowNull) { $c = $t.Columns.Add($name, $type); $c.AllowDBNull = $allowNull }
    Add-Col 'Id'      ([int])      $false
    Add-Col 'Name'    ([string])   $true
    Add-Col 'Price'   ([decimal])  $true
    Add-Col 'Created' ([datetime]) $true
    Add-Col 'Big'     ([int64])    $true
    Add-Col 'Small'   ([int16])    $false
    Add-Col 'Flag'    ([bool])     $true
    Add-Col 'Ref'     ([guid])     $true
    Add-Col 'Ratio'   ([double])   $true
    $stamp = ([datetime]'2026-01-15T10:30:00').AddTicks(1234560)
    $null = $t.Rows.Add(1, "${Aring}ke", [decimal]12.5, $stamp, [int64]9007199254740993, [int16]5, $true,
                        [guid]'11111111-1111-1111-1111-111111111111', 0.1)
    $null = $t.Rows.Add(2, [DBNull]::Value, [DBNull]::Value, [DBNull]::Value, [DBNull]::Value, [int16]7, [DBNull]::Value,
                        [DBNull]::Value, [DBNull]::Value)
    $null = $t.Rows.Add(3, 'say "hi" back\slash', [decimal]0.0001, $stamp, [int64]-1, [int16]-3, $false,
                        [guid]'33333333-3333-3333-3333-333333333333', [double]1e20)
    , $t
}

# --- 1. A reader ------------------------------------------------------------
Write-Host 'Export-ParqueterFromReader'
$table = New-TestTable

$message = Get-Failure { Export-ParqueterFromReader -Reader $table.CreateDataReader() -Path (Join-Path $work 'x.parquet') -ParqueterPath $Exe }
Assert-Match $message "Column 'Price'.*-ColumnOverride" 'a decimal without precision gives an actionable error'

$out = Join-Path $work 'reader.parquet'
$override = @{ Price = @{ Type = 'decimal'; Precision = 18; Scale = 4 } }
$result = Export-ParqueterFromReader -Reader $table.CreateDataReader() -Path $out -ParqueterPath $Exe -ColumnOverride $override -WriteSchema (Join-Path $work 'schema.json')
Assert-True ($result.Rows -eq 3) 'three rows are reported'
Assert-True (Test-Path $out) 'the Parquet file exists'
Assert-True (-not (Test-Path ($out + '.tmp'))) 'no temporary file is left'

$i = Invoke-Parqueter inspect $out
Assert-Match $i.Text 'rows: 3' 'three rows are stored'
Assert-Match $i.Text '(?m)^\s+Id\s+int32\s+required' 'NOT NULL Id is a required int32'
Assert-Match $i.Text '(?m)^\s+Name\s+string\s+optional' 'Name is optional'
Assert-Match $i.Text '(?m)^\s+Price\s+decimal\(18,4\)\s+optional' 'the override sets the decimal precision and scale'
Assert-Match $i.Text '(?m)^\s+Created\s+datetime\(micros\)\s+optional' 'DateTime is a timestamp with microseconds'
Assert-Match $i.Text '(?m)^\s+Big\s+int64\s+optional' 'Int64 is an int64'
Assert-Match $i.Text '(?m)^\s+Small\s+int32\s+required' 'NOT NULL Int16 is a required int32'
Assert-Match $i.Text '(?m)^\s+Flag\s+bool\s+optional' 'Boolean is a bool'
Assert-Match $i.Text '(?m)^\s+Ref\s+guid\s+optional' 'Guid is a guid'
Assert-Match $i.Text '(?m)^\s+Ratio\s+double\s+optional' 'Double is a double'
Assert-Match $i.Text ('(?m)^\s+1 \| {0}ke \| 12\.5(0*) \| 2026-01-15 10:30:00\.123456 \| 9007199254740993 \| 5 \| true \| 11111111-1111-1111-1111-111111111111 \| 0\.1$' -f $Aring) 'row 1 is exact, including a non-ASCII letter, microseconds and a large int64'
Assert-Match $i.Text '(?m)^\s+2 \| NULL \| NULL \| NULL \| NULL \| 7 \| NULL \| NULL \| NULL$' 'row 2 has real nulls everywhere they were allowed'
Assert-Match $i.Text 'say "hi" back\\slash' 'quotes and backslashes survive the JSON'
Assert-Match $i.Text '\| 1E\+20$|\| 1E20$|\| 100000000000000000000$' 'a large double is kept'

# --- 2. Objects, as from a REST call ---------------------------------------
Write-Host 'Export-ParqueterObjects'
$schema = @(
    New-ParqueterColumn Key string -NotNull
    New-ParqueterColumn Amount decimal -Precision 18 -Scale 2
    New-ParqueterColumn Created dateTime
    New-ParqueterColumn Owner string
)
$objects = @(
    [pscustomobject]@{ Key = 'A-1'; Amount = [decimal]10.5; Created = [datetime]'2026-03-01T12:00:00'; Owner = "Bj${ouml}rn" }
    @{ Key = 'A-2'; Amount = 7; Created = '2026-03-02T08:15:00Z' }
    [pscustomobject]@{ Key = 'A-3' }
)
$out2 = Join-Path $work 'objects.parquet'
$result = $objects | Export-ParqueterObjects -Schema $schema -Path $out2 -ParqueterPath $Exe
Assert-True ($result.Rows -eq 3) 'three objects are reported'
$i = Invoke-Parqueter inspect $out2
Assert-Match $i.Text '(?m)^\s+Key\s+string\s+required' 'Key is required'
Assert-Match $i.Text '(?m)^\s+Amount\s+decimal\(18,2\)\s+optional' 'Amount is decimal(18,2)'
Assert-Match $i.Text ('(?m)^\s+A-1 \| 10\.5(0*) \| 2026-03-01 12:00:00 \| Bj{0}rn$' -f $ouml) 'object 1 is stored'
Assert-Match $i.Text '(?m)^\s+A-2 \| 7(\.0*)? \| 2026-03-02 08:15:00 \| NULL$' 'a hashtable works, a Z timestamp is read, a missing property is null'
Assert-Match $i.Text '(?m)^\s+A-3 \| NULL \| NULL \| NULL$' 'an object with only a key is mostly null'

# --- 3. Failures leave nothing behind ---------------------------------------
Write-Host 'Failures'
$bad = Join-Path $work 'bad.parquet'

$message = Get-Failure { @([pscustomobject]@{ Key = $null }) | Export-ParqueterObjects -Schema $schema -Path $bad -ParqueterPath $Exe }
Assert-Match $message "(?s)Key" 'a null in a NOT NULL column is reported with the column'
Assert-True (-not (Test-Path $bad) -and -not (Test-Path ($bad + '.tmp'))) 'no file after a null in a NOT NULL column'

$message = Get-Failure { @([pscustomobject]@{ Key = 'A'; Amount = [decimal]1.234 }) | Export-ParqueterObjects -Schema $schema -Path $bad -ParqueterPath $Exe }
Assert-Match $message 'more than 2 decimals' 'parqueter explains a value that does not fit the schema'
Assert-True (-not (Test-Path $bad) -and -not (Test-Path ($bad + '.tmp'))) 'no file after a value that does not fit'

# a column forced to int32 although it holds text: the reader side fails half way
$mixed = New-Object System.Data.DataTable
$null = $mixed.Columns.Add('N', [string])
$null = $mixed.Rows.Add('1'); $null = $mixed.Rows.Add('abc'); $null = $mixed.Rows.Add('3')
$message = Get-Failure { Export-ParqueterFromReader -Reader $mixed.CreateDataReader() -Path $bad -ParqueterPath $Exe -ColumnOverride @{ N = @{ Type = 'int32' } } }
Assert-Match $message "row 2, column 'N'" 'a conversion failure names the row and the column'
Assert-True (-not (Test-Path $bad) -and -not (Test-Path ($bad + '.tmp'))) 'no partial file after the reader fails half way'

$binary = New-Object System.Data.DataTable
$null = $binary.Columns.Add('Blob', [byte[]])
$message = Get-Failure { Export-ParqueterFromReader -Reader $binary.CreateDataReader() -Path $bad -ParqueterPath $Exe }
Assert-Match $message "Column 'Blob'.*cannot store" 'binary columns are refused with an explanation'

$message = Get-Failure { Export-ParqueterFromReader -Reader $table.CreateDataReader() -Path $out -ParqueterPath $Exe -ColumnOverride $override }
Assert-Match $message 'exists' 'an existing file is not overwritten without -Force'
$null = Export-ParqueterFromReader -Reader $table.CreateDataReader() -Path $out -ParqueterPath $Exe -ColumnOverride $override -Force
Assert-True ((Invoke-Parqueter inspect $out).ExitCode -eq 0) '-Force overwrites'

Complete-Tests
