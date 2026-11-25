<#
.SYNOPSIS
    End-to-end test of "parqueter csv": converts a CSV with awkward data, then reads the Parquet file
    back with "parqueter inspect" and checks types, nullability and values.

.PARAMETER Exe
    Path to parqueter.exe. If omitted, the project is built and run with the dotnet CLI (works on Linux too).
#>
[CmdletBinding()]
param([string] $Exe)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/TestHelpers.ps1"
Initialize-Runner $Exe
$work = New-WorkDirectory 'test-csv'

# --- 1. Inference ----------------------------------------------------------
Write-Host 'Inferred schema'
$csv = Join-Path $work 'in.csv'
$lines = @(
    'Id,Name,Price,Created,Guid,Active,Quantity,Zip,Note'
    '1,Alpha,12.50,2026-01-15T10:30:00,11111111-1111-1111-1111-111111111111,true,5,01234,plain'
    '2,Beta,0.99,2026-02-20 08:00:00,22222222-2222-2222-2222-222222222222,false,,98765,"has, comma"'
    '3,,1234.56789012,2026-03-01T00:00:00Z,33333333-3333-3333-3333-333333333333,TRUE,7,00042,"say ""hi"""'
)
[IO.File]::WriteAllText($csv, ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding $false))

$out = Join-Path $work 'out.parquet'
$r = Invoke-Parqueter csv $csv $out --write-schema (Join-Path $work 'schema.json')
Assert-True ($r.ExitCode -eq 0) 'csv exits with 0'
if ($r.ExitCode -ne 0) { Write-Host $r.Text }

$i = Invoke-Parqueter inspect $out
Assert-True ($i.ExitCode -eq 0) 'inspect exits with 0'
Assert-Match $i.Text 'rows: 3' 'three rows'
Assert-Match $i.Text '(?m)^\s+Id\s+int32\s+required' 'Id is a required int32'
Assert-Match $i.Text '(?m)^\s+Name\s+string\s+optional' 'Name is an optional string'
Assert-Match $i.Text '(?m)^\s+Price\s+decimal\(38,8\)\s+required' 'Price is decimal(38,8)'
Assert-Match $i.Text '(?m)^\s+Created\s+datetime\(micros\)\s+required' 'Created is a datetime with microseconds'
Assert-Match $i.Text '(?m)^\s+Guid\s+guid\s+required' 'Guid is a guid'
Assert-Match $i.Text '(?m)^\s+Active\s+bool\s+required' 'Active is a bool'
Assert-Match $i.Text '(?m)^\s+Quantity\s+int32\s+optional' 'Quantity is an optional int32'
Assert-Match $i.Text '(?m)^\s+Zip\s+string\s+required' 'Zip with leading zeros stays a string'
Assert-Match $i.Text '(?m)^\s+2 \| Beta \| 0\.99 \| .* \| false \| NULL \|' 'a missing integer is NULL, not 0'
Assert-Match $i.Text '(?m)^\s+3 \| NULL \| 1234\.56789012 \|' 'a missing string is NULL and the decimal is exact'
Assert-Match $i.Text '00042' 'leading zeros are kept'
Assert-Match $i.Text 'has, comma' 'a quoted comma is kept'
Assert-Match $i.Text 'say "hi"' 'an escaped quote is kept'
Assert-Match $i.Text '2026-03-01 00:00:00 ' 'a Z timestamp is read'

# --- 2. Explicit schema ----------------------------------------------------
Write-Host 'Explicit schema'
$schema = Join-Path $work 'schema.json'
$json = Get-Content $schema -Raw | ConvertFrom-Json
$json.columns | Where-Object name -eq 'Price' | ForEach-Object { $_.scale = 8; $_.precision = 20 }
$json | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $work 'schema2.json') -Encoding utf8
$out2 = Join-Path $work 'out2.parquet'
$r = Invoke-Parqueter csv $csv $out2 --schema (Join-Path $work 'schema2.json')
Assert-True ($r.ExitCode -eq 0) 'csv with --schema exits with 0'
$i = Invoke-Parqueter inspect $out2
Assert-Match $i.Text '(?m)^\s+Price\s+decimal\(20,8\)' 'the schema file decides the decimal precision'

# --- 3. Errors are loud ----------------------------------------------------
Write-Host 'Bad data'
$r = Invoke-Parqueter csv $csv $out2 --schema (Join-Path $work 'schema2.json')
Assert-True ($r.ExitCode -ne 0) 'an existing output file is not overwritten without --force'

$bad = Join-Path $work 'bad.csv'
[IO.File]::WriteAllText($bad, "Id,Name`n1,a`nx,b`n", (New-Object Text.UTF8Encoding $false))
$badSchema = Join-Path $work 'bad-schema.json'
'{"columns":[{"name":"Id","type":"int32","nullable":false},{"name":"Name","type":"string"}]}' | Set-Content $badSchema -Encoding utf8
$r = Invoke-Parqueter csv $bad (Join-Path $work 'bad.parquet') --schema $badSchema
Assert-True ($r.ExitCode -ne 0) 'a value that does not fit the schema fails'
Assert-Match $r.Text "line 3, column 'Id'" 'the error names the line and the column'
Assert-True (-not (Test-Path (Join-Path $work 'bad.parquet'))) 'no half-written file is left behind'

# --- 4. Options ------------------------------------------------------------
Write-Host 'Swedish style: ; delimiter, comma decimals, NULL token, windows-1252'
$sv = Join-Path $work 'sv.csv'
$bytes = [Text.Encoding]::GetEncoding(1252).GetBytes("Namn;Belopp;Datum`n${Aring}ke;12,5;2026-01-02`nBj${ouml}rn;NULL;2026-01-03`n")
[IO.File]::WriteAllBytes($sv, $bytes)
$svOut = Join-Path $work 'sv.parquet'
$r = Invoke-Parqueter csv $sv $svOut --delimiter ';' --culture sv-SE --encoding windows-1252 --null NULL
Assert-True ($r.ExitCode -eq 0) 'csv with Swedish options exits with 0'
if ($r.ExitCode -ne 0) { Write-Host $r.Text }
$i = Invoke-Parqueter inspect $svOut
Assert-Match $i.Text '(?m)^\s+Belopp\s+decimal\(38,1\)\s+optional' 'Belopp is a nullable decimal'
Assert-Match $i.Text "${Aring}ke \| 12\.5 \| 2026-01-02" 'windows-1252 letters and the decimal comma are read'
Assert-Match $i.Text "Bj${ouml}rn \| NULL \| 2026-01-03" 'the NULL token is a null'

Complete-Tests
