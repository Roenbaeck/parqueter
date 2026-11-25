<#
.SYNOPSIS
    End-to-end test of "parqueter jsonl": rows piped in on stdin, as a PowerShell script or module would do.

.PARAMETER Exe
    Path to parqueter.exe. If omitted, the project is built and run with the dotnet CLI (works on Linux too).
#>
[CmdletBinding()]
param([string] $Exe)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/TestHelpers.ps1"
Initialize-Runner $Exe
$work = New-WorkDirectory 'test-jsonl'

$schemaLine = '{"columns":[' + (@(
    '{"name":"Id","type":"int64","nullable":false}'
    '{"name":"Name","type":"string"}'
    '{"name":"Price","type":"decimal","precision":18,"scale":4}'
    '{"name":"Created","type":"dateTime"}'
    '{"name":"Day","type":"date"}'
    '{"name":"Active","type":"bool"}'
    '{"name":"Ref","type":"guid"}'
) -join ',') + ']}'

# --- 1. Schema on the first line, rows as arrays, piped to stdin -------------
Write-Host 'Schema line and array rows on stdin'
$lines = @(
    $schemaLine
    ('[1,"{0}ke",12.5,"2026-01-15T10:30:00.123456","2026-01-15",true,"11111111-1111-1111-1111-111111111111"]' -f $Aring)
    '[2,null,0.0001,"2026-02-20 08:00:00","2026-02-20",false,null]'
    ''
    '[9007199254740993,"say \"hi\"",1234567890123.4567,null,null,null,null]'
)
$out = Join-Path $work 'out.parquet'
$r = Invoke-ParqueterWithInput $lines @('jsonl', '-', $out, '--write-schema', (Join-Path $work 'schema.json'))
Assert-True ($r.ExitCode -eq 0) 'jsonl exits with 0'
if ($r.ExitCode -ne 0) { Write-Host $r.Text }

$i = Invoke-Parqueter inspect $out
Assert-Match $i.Text 'rows: 3' 'three rows (the blank line is skipped)'
Assert-Match $i.Text '(?m)^\s+Id\s+int64\s+required' 'Id is a required int64'
Assert-Match $i.Text '(?m)^\s+Name\s+string\s+optional' 'Name is an optional string'
Assert-Match $i.Text '(?m)^\s+Price\s+decimal\(18,4\)\s+optional' 'Price is decimal(18,4)'
Assert-Match $i.Text '(?m)^\s+Created\s+datetime\(micros\)\s+optional' 'Created is a datetime with microseconds'
Assert-Match $i.Text '(?m)^\s+Day\s+date\s+optional' 'Day is a date'
Assert-Match $i.Text '(?m)^\s+Ref\s+guid\s+optional' 'Ref is a guid'
Assert-Match $i.Text ('(?m)^\s+1 \| {0}ke \| 12\.5(0*) \| 2026-01-15 10:30:00\.123456 \| 2026-01-15 \| true \| 11111111-' -f $Aring) 'a non-ASCII letter survives the pipe and microseconds are kept'
Assert-Match $i.Text '(?m)^\s+2 \| NULL \| 0\.0001 \| .* \| false \| NULL$' 'null string and null guid are NULL'
Assert-Match $i.Text '9007199254740993 \| say "hi" \| 1234567890123\.4567 \| NULL \| NULL \| NULL \| NULL' 'a large int64 and a decimal are exact; nulls stay null'
Assert-True (Test-Path (Join-Path $work 'schema.json')) '--write-schema saves the schema that came in'

# --- 2. Objects keyed by column name, schema from a file ---------------------
Write-Host 'Object rows and --schema'
$schemaFile = Join-Path $work 'schema.json'
$objects = @(
    '{"Id":1,"Name":"a","Price":"1.5"}'
    '{"Price":2,"Id":2}'
)
$out2 = Join-Path $work 'out2.parquet'
$r = Invoke-ParqueterWithInput $objects @('jsonl', '-', $out2, '--schema', $schemaFile)
Assert-True ($r.ExitCode -eq 0) 'object rows with --schema exit with 0'
if ($r.ExitCode -ne 0) { Write-Host $r.Text }
$i = Invoke-Parqueter inspect $out2
Assert-Match $i.Text '(?m)^\s+1 \| a \| 1\.5(0*) \| NULL' 'a number written as a string is accepted'
Assert-Match $i.Text '(?m)^\s+2 \| NULL \| 2(\.0*)? \| NULL' 'a missing key is null'

# --- 3. A file instead of stdin ---------------------------------------------
Write-Host 'Input from a file'
$file = Join-Path $work 'in.jsonl'
[IO.File]::WriteAllText($file, ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding $false))
$out3 = Join-Path $work 'out3.parquet'
$r = Invoke-Parqueter jsonl $file $out3
Assert-True ($r.ExitCode -eq 0) 'jsonl from a file exits with 0'
Assert-Match (Invoke-Parqueter inspect $out3).Text 'rows: 3' 'same three rows'

# --- 4. Errors are loud ------------------------------------------------------
Write-Host 'Bad input'
$bad = Join-Path $work 'bad.parquet'

$r = Invoke-ParqueterWithInput @($schemaLine, '[null,"x",1,null,null,null,null]') @('jsonl', '-', $bad)
Assert-True ($r.ExitCode -ne 0) 'null in a not-nullable column fails'
Assert-Match $r.Text "line 2, column 'Id'" 'the error names the line and the column'

$r = Invoke-ParqueterWithInput @($schemaLine, '[1,"x",1,null,null,null]') @('jsonl', '-', $bad)
Assert-True ($r.ExitCode -ne 0) 'a row with too few values fails'
Assert-Match $r.Text 'expected 7 values but found 6' 'the error says how many values were expected'

$r = Invoke-ParqueterWithInput @($schemaLine, '[1,"x",1.23456,null,null,null,null]') @('jsonl', '-', $bad)
Assert-True ($r.ExitCode -ne 0) 'a decimal with more digits than the scale fails'
Assert-Match $r.Text "column 'Price'.*more than 4 decimals" 'the error names the column and the scale'

$r = Invoke-ParqueterWithInput @($schemaLine, '[1,"x",1,"not a date",null,null,null]') @('jsonl', '-', $bad)
Assert-True ($r.ExitCode -ne 0) 'a bad timestamp fails'

$r = Invoke-ParqueterWithInput @($schemaLine, '{"Id":1,"Nope":2}') @('jsonl', '-', $bad)
Assert-True ($r.ExitCode -ne 0) 'an unknown key fails'

$r = Invoke-ParqueterWithInput @($schemaLine, '[1,"x"') @('jsonl', '-', $bad)
Assert-True ($r.ExitCode -ne 0) 'broken JSON fails'
Assert-Match $r.Text 'line 2: not valid JSON' 'the error names the line'

$r = Invoke-ParqueterWithInput @('{"columns":[]}') @('jsonl', '-', $bad)
Assert-True ($r.ExitCode -ne 0) 'a schema without columns fails'
Assert-True (-not (Test-Path $bad)) 'no output file is left behind after any failure'

Complete-Tests
