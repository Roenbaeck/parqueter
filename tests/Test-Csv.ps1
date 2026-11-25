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

$s = Invoke-Parqueter inspect $out --rows 0 --stats
Assert-Match $s.Text '(?m)^\s+Id\s+nulls=0 min=1 max=3 sum=6$' 'inspect --stats: Id statistics'
Assert-Match $s.Text '(?m)^\s+Quantity\s+nulls=1 min=5 max=7 sum=12$' 'inspect --stats: Quantity has one null and sums to 12'
Assert-Match $s.Text '(?m)^\s+Name\s+nulls=1$' 'inspect --stats: Name has one null'
Assert-Match $s.Text '(?m)^\s+Price\s+nulls=0 min=0\.99\d* max=1234\.56789012\d* sum=1248\.05789012\d*$' 'inspect --stats: decimal sum is exact'

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

# --- 5. SSIS style files: UTF-16, control character delimiter, no quoting ----
Write-Host 'UTF-16, delimiter 0x1F, --quote none'
$us = [string][char]0x1F
$ssis = @(
    "AR${us}NAME${us}AMOUNT${us}CREATED"
    "2026${us}`"Quoted`" text${us}12,5${us}2026-01-02 10:00:00"
    "2026${us}Plain, with; punctuation${us},25${us}2026-01-03 11:30:00"
    "2025${us}${Aring}ke${us}${us}2026-01-04 00:00:00"
)
$utf16 = New-Object Text.UnicodeEncoding $false, $true   # little endian, with byte order mark
$ssisFile = Join-Path $work 'ssis.csv'
[IO.File]::WriteAllText($ssisFile, ($ssis -join "`n") + "`n", $utf16)
$ssisOut = Join-Path $work 'ssis.parquet'
$r = Invoke-Parqueter csv $ssisFile $ssisOut --delimiter 0x1F --quote none --culture sv-SE
Assert-True ($r.ExitCode -eq 0) 'a UTF-16 file with a 0x1F delimiter converts'
if ($r.ExitCode -ne 0) { Write-Host $r.Text }
$i = Invoke-Parqueter inspect $ssisOut
Assert-Match $i.Text '(?m)^\s+AR\s+int32\s+required' 'AR is an int32'
Assert-Match $i.Text '(?m)^\s+AMOUNT\s+decimal\(38,2\)\s+optional' 'AMOUNT is a nullable decimal(38,2)'
Assert-Match $i.Text '"Quoted" text \| 12\.50?' 'a quote at the start of a field is plain text with --quote none'
Assert-Match $i.Text 'Plain, with; punctuation \| 0\.25' 'commas and semicolons in text are kept; ,25 is 0.25'
Assert-Match $i.Text ('{0}ke \| NULL \| 2026-01-04' -f $Aring) 'an empty amount is NULL'
# Without --quote none the leading quote is taken as CSV quoting and silently dropped: the reason the option exists.
$quoted = Join-Path $work 'ssis-quoted.parquet'
$r = Invoke-Parqueter csv $ssisFile $quoted --delimiter 0x1F --culture sv-SE
Assert-True ($r.ExitCode -eq 0) 'the default quote handling still converts the file'
$i = Invoke-Parqueter inspect $quoted
Assert-Match $i.Text '\| Quoted text \|' 'by default the quotes are removed (CSV rules), which --quote none avoids'

Write-Host 'Two-character delimiter ^;'
$caret = Join-Path $work 'caret.csv'
$rows = @('Id^;Name^;Note')
$rows += 1..20000 | ForEach-Object { "$_^;name_$_ a^b^;note $_" }   # a^b: a caret that is not part of the delimiter
[IO.File]::WriteAllText($caret, ($rows -join "`n") + "`n", $utf16)
$caretOut = Join-Path $work 'caret.parquet'
$r = Invoke-Parqueter csv $caret $caretOut --delimiter '^;' --quote none
Assert-True ($r.ExitCode -eq 0) 'a file with the delimiter ^; converts (the delimiter crosses buffer boundaries)'
if ($r.ExitCode -ne 0) { Write-Host $r.Text }
$s = Invoke-Parqueter inspect $caretOut --rows 1 --stats
Assert-Match $s.Text 'rows: 20000' 'all 20000 rows are read'
Assert-Match $s.Text '(?m)^\s+Id\s+nulls=0 min=1 max=20000 sum=200010000$' 'no row was shifted or merged'
Assert-Match $s.Text '1 \| name_1 a\^b \| note 1' 'a caret that is not followed by ; stays in the text'

Write-Host 'Row delimiter CRLF with a bare LF inside a text field'
$rd = Join-Path $work 'rowdelim.csv'
$rdText = "Id${us}Note${us}Amount`r`n1${us}first line`nsecond line${us}1,5`r`n2${us}plain${us}2,5`r`n"
[IO.File]::WriteAllText($rd, $rdText, $utf16)
$rdOut = Join-Path $work 'rowdelim.parquet'
$r = Invoke-Parqueter csv $rd $rdOut --delimiter 0x1F --quote none --culture sv-SE
Assert-True ($r.ExitCode -ne 0) 'by default the embedded line break splits the record, and the field count mismatch is reported'
Assert-Match $r.Text 'expected 3 fields but found 2' 'the error says what is wrong'
$r = Invoke-Parqueter csv $rd $rdOut --delimiter 0x1F --quote none --culture sv-SE --row-delimiter crlf --force
Assert-True ($r.ExitCode -eq 0) '--row-delimiter crlf keeps the embedded line break as data'
$s = Invoke-Parqueter inspect $rdOut --rows 0 --stats
Assert-Match $s.Text 'rows: 2' 'two rows'
Assert-Match $s.Text '(?m)^\s+Amount\s+nulls=0 min=1\.5\d* max=2\.5\d* sum=4\.0\d*$' 'the amounts are read from the right fields'
$j = Invoke-Parqueter inspect $rdOut --rows 2
Assert-Match $j.Text 'first line' 'the text before the line break is in the field'
Assert-Match $j.Text 'second line' 'and the text after it too'

Write-Host 'Negative numbers with a Swedish culture'
$neg = Join-Path $work 'neg.csv'
[IO.File]::WriteAllText($neg, "Namn;Belopp;Antal`nA;-1,5;-3`nB;2,25;4`n", (New-Object Text.UTF8Encoding $false))
$negOut = Join-Path $work 'neg.parquet'
$r = Invoke-Parqueter csv $neg $negOut --delimiter ';' --culture sv-SE
Assert-True ($r.ExitCode -eq 0) 'negative numbers with sv-SE convert'
$s = Invoke-Parqueter inspect $negOut --rows 0 --stats
Assert-Match $s.Text '(?m)^\s+Belopp\s+nulls=0 min=-1\.5\d* max=2\.25\d* sum=0\.75\d*$' 'an ordinary minus sign is a negative decimal, not text'
Assert-Match $s.Text '(?m)^\s+Antal\s+nulls=0 min=-3 max=4 sum=1$' 'an ordinary minus sign is a negative integer'

Write-Host '--ascii-names'
$an = Join-Path $work 'ascii.csv'
$anHeader = "${Aring}R;KOSTNADSST${Auml}LLE;Timmar_N${Auml}rvarande;Plain name;Id"
[IO.File]::WriteAllText($an, "$anHeader`n2026;1;1,5;x;7`n2026;2;2,5;y;8`n", (New-Object Text.UTF8Encoding $false))
$anOut = Join-Path $work 'ascii.parquet'
$anSchema = Join-Path $work 'ascii.schema.json'
$r = Invoke-Parqueter csv $an $anOut --delimiter ';' --culture sv-SE --ascii-names --write-schema $anSchema
Assert-True ($r.ExitCode -eq 0) '--ascii-names converts'
if ($r.ExitCode -ne 0) { Write-Host $r.Text }
$i = Invoke-Parqueter inspect $anOut --rows 0
Assert-Match $i.Text '(?m)^\s+AR\s+int32\s+required' "the A-ring in the first column name becomes A"
Assert-Match $i.Text '(?m)^\s+KOSTNADSSTALLE\s+int32' 'a diaeresis is removed'
Assert-Match $i.Text '(?m)^\s+Timmar_Narvarande\s+decimal' 'case and underscores are kept'
Assert-Match $i.Text '(?m)^\s+Plain_name\s+string' 'a space becomes an underscore'
Assert-True (-not ($i.Text -match '[^\x00-\x7F]')) 'the file has only ASCII in its output'
$schemaText = [IO.File]::ReadAllText($anSchema, (New-Object Text.UTF8Encoding $false))
Assert-Match $schemaText '"source":\s*"' 'the schema file records the original header name as source'
Assert-True (-not ($schemaText -match '"source":\s*"Id"')) 'a name that did not change has no source'
$anOut2 = Join-Path $work 'ascii2.parquet'
$r = Invoke-Parqueter csv $an $anOut2 --delimiter ';' --culture sv-SE --schema $anSchema
Assert-True ($r.ExitCode -eq 0) 'the written schema can be used again with the original file'
$dup = Join-Path $work 'ascii-dup.csv'
[IO.File]::WriteAllText($dup, "${Aring}R;AR`n1;2`n", (New-Object Text.UTF8Encoding $false))
$r = Invoke-Parqueter csv $dup (Join-Path $work 'ascii-dup.parquet') --delimiter ';' --ascii-names
Assert-True ($r.ExitCode -ne 0) 'two columns that become the same name are an error'
Assert-Match $r.Text 'both become' 'the error says which names collide'

Write-Host 'No header'
$nh = Join-Path $work 'noheader.csv'
[IO.File]::WriteAllText($nh, "FC1;X1;2026;10;5.00000000`nFC1;X2;2026;11;6.50000000`n", (New-Object Text.UTF8Encoding $true))
$nhOut = Join-Path $work 'noheader.parquet'
$r = Invoke-Parqueter csv $nh $nhOut --delimiter ';' --no-header
Assert-True ($r.ExitCode -eq 0) 'a file without a header converts'
$i = Invoke-Parqueter inspect $nhOut
Assert-Match $i.Text 'rows: 2' 'both lines are data'
Assert-Match $i.Text '(?m)^\s+column1\s+string\s+required' 'columns are named column1, column2, ...'
Assert-Match $i.Text '(?m)^\s+column5\s+decimal\(38,8\)\s+required' 'a dot decimal is read with the invariant culture'

Complete-Tests
