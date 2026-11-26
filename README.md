# parqueter

Writes Parquet files with **exact types and nullability**, from a CSV file, from a database, or from a REST API.
One small `parqueter.exe` does the writing, and a PowerShell 5.1 module feeds it from anything that PowerShell can read.

* **Standalone:** `parqueter csv` converts a CSV file, with delimiter, encoding and format options for the awkward
  files that SSIS and Excel produce. `parqueter inspect` shows what is really inside a Parquet file.
* **From PowerShell:** `Parqueter.psm1` reads any ADO.NET source (SQL Server, Oracle, Snowflake over ODBC, ...) or
  objects from a REST call, takes the schema from the source, and streams the rows to Parquet. A `NOT NULL`
  column becomes a required Parquet column and a null stays a null.

## Contents

[Quick start](#quick-start) · [Install](#install) · [Standalone: CSV](#standalone-csv-files) ·
[Schema files](#schema-files) · [JSON Lines](#json-lines) · [Inspect](#inspect-a-parquet-file) ·
[PowerShell module](#powershell-module-windows-powershell-51) · [Snowflake](#loading-the-files-into-snowflake) ·
[Troubleshooting](#troubleshooting) · [Limits](#limits) · [Build and test](#build-and-test)

## Quick start

A CSV file to Parquet, then look at the result:

```powershell
.\parqueter.exe csv orders.csv orders.parquet
.\parqueter.exe inspect orders.parquet
```

```
file: orders.parquet
row groups: 1
rows: 3
columns:
  Id               int32              required
  Name             string             optional
  Price            decimal(38,2)      required
first 3 rows:
  1 | Alpha | 12.5
  2 | NULL | 0.99
  3 | Gamma | 7
```

(`Name` has an empty field in the second row, so it is `optional`; `Id` and `Price` have no empty fields in this file, so they are `required`.)

A SQL Server query to Parquet, from Windows PowerShell 5.1 (the schema, including `NOT NULL`, comes from the query):

```powershell
Import-Module .\Parqueter.psm1

$connection = New-Object System.Data.SqlClient.SqlConnection 'Server=myserver;Database=mydb;Integrated Security=True'
$connection.Open()
$command = $connection.CreateCommand()
$command.CommandText = 'SELECT OrderId, Customer, Amount, Created FROM dbo.Orders'
$command.CommandTimeout = 0
$reader = $command.ExecuteReader()
Export-ParqueterFromReader -Reader $reader -Path orders.parquet -ParqueterPath .\parqueter.exe -Force
$reader.Dispose(); $connection.Dispose()
```

## Install

There is nothing to install: download **`parqueter.exe`** (and, for PowerShell use, **`Parqueter.psm1`**) from the
[latest release](https://github.com/Roenbaeck/parqueter/releases/latest) and put them in a folder. A release has:

| File | What it is |
|---|---|
| `parqueter-<version>-win-x64.zip` | the exe, the module, the README, the license and the [third-party notices](THIRD-PARTY-NOTICES.md), together |
| `THIRD-PARTY-NOTICES.md` | the licenses of the libraries that are built into the exe |
| `parqueter.exe` | the exe alone |
| `Parqueter.psm1` | the PowerShell module alone |
| `SHA256SUMS.txt` | checksums of the files above |

```powershell
$base = 'https://github.com/Roenbaeck/parqueter/releases/latest/download'
Invoke-WebRequest "$base/parqueter.exe" -OutFile parqueter.exe
Invoke-WebRequest "$base/Parqueter.psm1" -OutFile Parqueter.psm1
Invoke-WebRequest "$base/SHA256SUMS.txt" -OutFile SHA256SUMS.txt
(Get-FileHash .\parqueter.exe).Hash.ToLower()     # compare with the parqueter.exe line in SHA256SUMS.txt
```

* Needs the **.NET 8 runtime** (Windows, x64). Windows PowerShell **5.1** is enough for the module.
* `parqueter.exe` is a single file with its libraries built in. It is not code signed. If Windows blocks a copy
  that came from a download, run `Unblock-File .\parqueter.exe`.
* The module finds the exe through `-ParqueterPath`, then `$env:PARQUETER_EXE`, then next to the module, then on the PATH.
  Keep the two files in the same folder and no path is needed.
* To build the exe yourself, see [Build and test](#build-and-test).

```
parqueter --version
parqueter --help
```

Exit codes: `0` success, `1` the run failed (the message starts with `error:` on stderr and names the line and column
for bad data), `2` wrong command line. A failed run leaves no output file behind.

## Design

parqueter does one thing: **typed rows in, Parquet out.** It does not know about databases or REST APIs: getting data
out of SQL Server, Oracle, Snowflake, IFS, Jira and so on is left to the tools that already know how (PowerShell 5.1
with its drivers and modules), which hand the rows to parqueter. That keeps the exe small, with no database drivers of its own.

Every input has a *schema*: for each column a type, whether it may be null, and for decimals the precision and scale.
The schema is what ends up in the Parquet file, so a null stays a null. (The PowerShell module PSParquet 0.2.x, for comparison,
takes the types from the first object, writes every column as required and turns a null integer into 0; `Test-Parquet.ps1`
shows this.)

| Input | Command |
|---|---|
| CSV file | `parqueter csv` |
| JSON Lines, from a file or from stdin | `parqueter jsonl` |
| A database or a REST API, from PowerShell | `Export-ParqueterFromReader`, `Export-ParqueterObjects` in `Parqueter.psm1` |

## Standalone: CSV files

```
parqueter csv <input.csv> <output.parquet> [options]
```

Without a schema the types are inferred from the **whole file**. Review the decision with `--write-schema`, edit it,
and pass it back with `--schema` (see [Schema files](#schema-files)).

```powershell
# comma separated, UTF-8, header row: no options needed
parqueter csv orders.csv orders.parquet

# a Swedish Excel export: semicolons, comma decimals, Windows-1252, NULL for missing values
parqueter csv orders.csv orders.parquet --delimiter ';' --culture sv-SE --encoding windows-1252 --null NULL

# an SSIS flat file: UTF-16, delimiter 0x1F, no quoting, CRLF row ends, line breaks inside text
parqueter csv ledger.csv ledger.parquet --delimiter 0x1F --quote none --row-delimiter crlf --culture sv-SE

# no header row, so the columns are called column1, column2, ... (name them in a schema file)
parqueter csv headcount.csv headcount.parquet --delimiter ';' --no-header --write-schema headcount.schema.json

# plain ASCII column names, so Snowflake needs no double quotes
parqueter csv ledger.csv ledger.parquet --ascii-names --write-schema ledger.schema.json
```

| Option | Meaning |
|---|---|
| `--schema <file>` | use this schema instead of inferring one |
| `--write-schema <file>` | save the schema that was used, to review and edit |
| `--delimiter <text>` | what separates fields (default `,`): a character, a word (`tab`, `comma`, `semicolon`, `pipe`), a character code (`0x1F`, `\x1F`, `U+001F`), or several characters (`^;`) |
| `--quote <c\|none>` | the quote character (default `"`), or `none` if fields are never quoted |
| `--row-delimiter <text>` | what ends a row: `crlf`, `lf`, `cr` or any text. Default: any line break. Give it when text fields contain line breaks |
| `--no-header` | the first row is data |
| `--ascii-names` | make column names plain ASCII: `ÅR` becomes `AR`, `KOSTNADSSTÄLLE` `KOSTNADSSTALLE`, a space or dash `_` |
| `--encoding <name>` | `utf-8` (default), `windows-1252`, `iso-8859-1`, `utf-16`, ... A byte order mark is detected, so UTF-8 and UTF-16 files that have one need no option |
| `--culture <name>` | culture for numbers, for example `sv-SE` where `12,5` is a decimal (default invariant). An ordinary `-` is always the minus sign |
| `--null <text>` | text that means null besides an empty field (repeatable) |
| `--keep-empty-strings` | an empty field in a string column is `""` instead of null |
| `--row-group-size <n>` | rows per Parquet row group (default 100000) |
| `--force` | overwrite the output file |

**What inference does**

* An empty field, or any `--null` text, is a null. In a string column an empty field is null too, unless `--keep-empty-strings`.
* `true`/`false` columns become `bool`, GUIDs `guid`, whole numbers `int32` or `int64`, other numbers `decimal(38, s)` where `s` is the most decimals seen.
* Values with leading zeros (`01234`) or a leading `+` stay strings: they are identifiers, not numbers.
* Dates are ISO 8601 only (`2026-01-15` becomes `date`, `2026-01-15T10:30:00` or `2026-01-15 10:30:00` `dateTime`, with or without `Z` or an offset).
  A timestamp with an offset is converted to UTC; one without is kept as written. For other formats use a schema file with `"format"`.
* Whatever else is found is `string`. Nullability is what *this file* shows, which is why you review the schema before reusing it.
* A value that does not fit the schema stops the run with the line and column. Nothing is silently rounded or nulled.

**Quotes and national letters.** With the default `--quote "` a field that starts with `"` is read as a quoted field and the
quotes are dropped, which is right for normal CSV and wrong for SSIS files without a text qualifier: use `--quote none` there.
Quoting of *column names* is a different matter: it is Snowflake SQL, not Parquet. A name such as `ÅR` is stored as is;
`--ascii-names` is for when you want plain names. The original name is kept as `source` in the schema written by `--write-schema`.

## Schema files

```json
{
  "columns": [
    { "name": "Id",       "type": "int32",    "nullable": false },
    { "name": "Price",    "type": "decimal",  "precision": 18, "scale": 2 },
    { "name": "Created",  "type": "dateTime" },
    { "name": "Shipped",  "type": "date", "format": "dd/MM/yyyy" },
    { "name": "YEAR",     "type": "int32", "source": "ÅR" }
  ]
}
```

* Types: `string`, `bool`, `int32`, `int64`, `decimal`, `double`, `dateTime`, `date`, `guid`. `nullable` defaults to true.
* `precision` (default 38) and `scale` (default 0) are for decimals; a value with more decimals than `scale` is an error.
* `format` (dates and timestamps only) is an exact .NET format such as `dd/MM/yyyy` or `yyyyMMdd HH:mm`.
* `source` is the column's name in the CSV header, when it differs from `name`. Edit `name` to rename a column.
* Timestamps are written as Parquet `TIMESTAMP` with microsecond precision, **not adjusted to UTC** (Snowflake reads that as `TIMESTAMP_NTZ`, see [Snowflake](#loading-the-files-into-snowflake)).

## JSON Lines

```
parqueter jsonl <input.jsonl | -> <output.parquet> [--schema <file>] [--write-schema <file>] [--encoding <name>] [--row-group-size <n>] [--force]
```

One JSON value per line. Unless `--schema` is given, the **first line is the schema** (the same JSON as a schema file, on one
line). Every other line is a **row**: an array in column order, or an object keyed by column name (a missing key is null).
Use `-` as the input to read stdin, which is how a script pipes rows in.

```
{"columns":[{"name":"Id","type":"int64","nullable":false},{"name":"Name","type":"string"},{"name":"Price","type":"decimal","precision":18,"scale":4}]}
[1,"Alpha",12.5]
[2,null,0.0001]
```

Numbers are read as exact text, so a decimal never passes through a double. A number or boolean is accepted for a string
column and a string for a numeric column; dates and timestamps are ISO 8601 strings. Anything that does not fit the schema
stops the run with the line and the column.

```powershell
$global:OutputEncoding = New-Object System.Text.UTF8Encoding $false     # see the pitfall below
$lines | .\parqueter.exe jsonl - out.parquet
if ($LASTEXITCODE -ne 0) { throw 'parqueter failed' }
```

Pitfall when piping from **Windows PowerShell 5.1**: text sent to a program is encoded with `$OutputEncoding`, which is ASCII by
default, so non-ASCII letters turn into `?`. Set it to UTF-8, and set it in the *global* scope: an assignment inside a function
is silently ignored. (The PowerShell module does this for you.)

## Inspect a Parquet file

```
parqueter inspect <file.parquet> [--rows N] [--stats]
```

Shows the schema with `required`/`optional` (the nullability that is really stored), the first N rows (default 10, `0` for none)
and, with `--stats`, the null count, minimum, maximum and sum of every column. Statistics are read one row group at a time, so
they work on files far larger than memory. Use them to check a conversion against the source:

```powershell
parqueter inspect orders.parquet --rows 0 --stats
```
```
  Amount           nulls=0 min=0.99 max=1234.5 sum=1248.49
```
```sql
SELECT COUNT(*), SUM(Amount), MIN(Amount), MAX(Amount) FROM dbo.Orders;
```

## PowerShell module (Windows PowerShell 5.1)

[powershell/Parqueter.psm1](powershell/Parqueter.psm1) is a single file that is used together with `parqueter.exe`.
It reads from any ADO.NET reader and takes the **schema from the reader itself** (`GetSchemaTable()`): a `NOT NULL` column becomes
a required Parquet column, a decimal gets its precision and scale, and nulls stay nulls. Rows are streamed to `parqueter.exe jsonl -`
by a small compiled helper, so a large table never passes through the PowerShell pipeline or sits in memory. If a row does not fit,
or the reader fails half way, no file is left behind.

| Command | Use |
|---|---|
| `Export-ParqueterFromReader` | any open `IDataReader` to a Parquet file. Parameters: `-Reader`, `-Path`, `-ParqueterPath`, `-ColumnOverride`, `-Force`, `-RowGroupSize`, `-WriteSchema` |
| `Export-ParqueterObjects` | objects from the pipeline (for instance from a REST call) with a declared schema. Parameters: `-InputObject`, `-Schema`, `-Path`, `-ParqueterPath`, `-Force`, `-RowGroupSize` |
| `Get-ParqueterSchema` | show what `Export-ParqueterFromReader` will write for a reader (and which columns need an override) |
| `New-ParqueterColumn` | declare one column: `-Name`, `-Type`, `-NotNull`, `-Precision`, `-Scale` |

Both export commands return an object with `Path`, `Rows` and `Columns`.

### SQL Server

```powershell
Import-Module .\Parqueter.psm1

$connection = New-Object System.Data.SqlClient.SqlConnection 'Server=myserver;Database=mydb;Integrated Security=True'
$connection.Open()
$command = $connection.CreateCommand()
$command.CommandText = 'SELECT OrderId, Customer, Amount, Created FROM dbo.Orders'
$command.CommandTimeout = 0
$reader = $command.ExecuteReader()
Export-ParqueterFromReader -Reader $reader -Path orders.parquet -ParqueterPath .\parqueter.exe -Force
$reader.Dispose(); $connection.Dispose()
```

Several tables over one connection:

```powershell
Import-Module .\Parqueter.psm1
$connection = New-Object System.Data.SqlClient.SqlConnection 'Server=myserver;Database=mydb;Integrated Security=True'
$connection.Open()
foreach ($table in 'dbo.Orders', 'dbo.Customers') {
    $command = $connection.CreateCommand()
    $command.CommandText = "SELECT * FROM $table"
    $command.CommandTimeout = 0
    $reader = $command.ExecuteReader()
    try { Export-ParqueterFromReader -Reader $reader -Path "$table.parquet" -ParqueterPath .\parqueter.exe -Force }
    finally { $reader.Dispose() }
}
$connection.Dispose()
```

See what will be written before writing it:

```powershell
Get-ParqueterSchema -Reader $reader | Format-Table Name, SourceType, Type, Nullable, Precision, Scale
```

### Oracle, Snowflake and other databases

Any provider that gives a data reader works the same way, for example ODBC with the vendor's driver
(`System.Data.Odbc.OdbcConnection`). Only the SQL Server ODBC driver has been verified (same schema and same numbers as
SqlClient); the Oracle and Snowflake drivers have not, so look at `Get-ParqueterSchema` first:

```powershell
$connection = New-Object System.Data.Odbc.OdbcConnection 'DSN=mydsn'     # or a full Driver=...;Server=... string
$connection.Open()
$command = $connection.CreateCommand()
$command.CommandText = 'SELECT * FROM SALES.ORDERS'
$reader = $command.ExecuteReader()
Get-ParqueterSchema -Reader $reader | Format-Table Name, SourceType, Type, Nullable, Precision, Scale
```

When a provider cannot say a decimal's precision and scale (typical for an Oracle `NUMBER` without a declared size) the export
stops with an error that names the column; give the answer with `-ColumnOverride`:

```powershell
Export-ParqueterFromReader -Reader $reader -Path out.parquet -ParqueterPath .\parqueter.exe `
    -ColumnOverride @{ Amount = @{ Type = 'decimal'; Precision = 18; Scale = 4 }; Note = @{ Nullable = $true } }
```

An override can set `Type`, `Nullable`, `Precision` and `Scale` of a column. Plain ASCII names are easiest to get from the query itself (`SELECT "ÅR" AS AR ...`).

### REST APIs (IFS, Netboss, Jira, ...)

The script does the calling, paging and authentication; the module writes the objects. Objects carry no reliable types or
nullability, so the schema is declared. A property that is missing on an object is null.

```powershell
$schema = @(
    New-ParqueterColumn Key string -NotNull
    New-ParqueterColumn Created dateTime
    New-ParqueterColumn Estimate decimal -Precision 18 -Scale 2
)
$issues | Export-ParqueterObjects -Schema $schema -Path issues.parquet -ParqueterPath .\parqueter.exe
```

Dates should be `[datetime]` or ISO 8601 strings. Collecting all pages into `$issues` first needs memory for all of them;
to avoid that, call `Export-ParqueterObjects` on a pipeline that produces the objects page by page.

### Type mapping and limits

Strings, characters and `TimeSpan` become `string`; `Byte`, `Int16`, `Int32` become `int32`; `Int64`, `UInt32` `int64`; `UInt64` `decimal(20,0)`;
`Single`, `Double` `double`; `DateTime` and `DateTimeOffset` `dateTime` (an offset is converted to UTC; a SQL Server `date` column becomes `date`);
`Guid` `guid`; `Decimal` `decimal(precision, scale)` from the reader. Binary columns are refused: convert them in the query.

**Scale and memory.** Nothing is collected in PowerShell: the reader is read one row at a time, written to parqueter's stdin,
and parqueter holds one row group (100,000 rows by default, `-RowGroupSize`) at a time. Example measurement with SQL Server
as the source: 11,855,549 rows (3 columns: int, `decimal(17,2)`, datetime) in 57 seconds, about 208,000 rows/s, to an 80 MB file.
Peak memory was 94 MB for PowerShell and 73 MB for parqueter (private bytes), and count, sum, minimum and maximum matched SQL
exactly. Speed depends on the machine and the network; memory does not grow with the number of rows.

**Tested with** a `DataTable` reader (`tests/Test-Module.ps1`, no server needed) and with SQL Server 2014 through both
`System.Data.SqlClient` and ODBC (schema, nullability, national letters, decimals, timestamps, and the 11.9 million rows above).

## Loading the files into Snowflake

Tested with a file of 458,862 rows and 28 columns (national letters in some column names, decimals, a timestamp).

1. **Upload** the file to a stage (Snowsight: Data, Add Data, Load files into a stage; or `PUT`).
2. **Use a file format with `USE_LOGICAL_TYPE = TRUE`.** Without it Snowflake reads a Parquet timestamp as a plain
   `NUMBER` (microseconds since 1970) instead of `TIMESTAMP_NTZ`. Decimals (`NUMBER(p,s)`), integers, text, dates
   and booleans need no option.
3. **Create the table from the file** and load it, matching columns by name:

```sql
CREATE FILE FORMAT IF NOT EXISTS pq_logical TYPE = PARQUET USE_LOGICAL_TYPE = TRUE;

CREATE TABLE ledger USING TEMPLATE (
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
  FROM TABLE(INFER_SCHEMA(LOCATION => '@mystage/ledger.parquet', FILE_FORMAT => 'pq_logical')));

COPY INTO ledger FROM @mystage/ledger.parquet
  FILE_FORMAT = (FORMAT_NAME = 'pq_logical') MATCH_BY_COLUMN_NAME = CASE_SENSITIVE;
```

`USING TEMPLATE` works in a Snowsight workspace. Sent through the Snowflake SQL REST API it failed with "result from
sub-query must be a single scalar value" (cause unknown); there the column list can be generated instead and pasted
into `CREATE TABLE ledger ( ... )`:
`SELECT GENERATE_COLUMN_DESCRIPTION(ARRAY_AGG(OBJECT_CONSTRUCT(*)), 'table') FROM TABLE(INFER_SCHEMA(...))`.
Required columns in the Parquet file become `NOT NULL`. Check the load with `parqueter inspect --stats` against
`SELECT COUNT(*), SUM(...), MIN(...), MAX(...)` on the table.

**Column names.** A name such as `ÅR` is stored as is and loads fine, but it is a quoted identifier in Snowflake and must be
written `"ÅR"` in every query. The Snowsight *Load Data into Table* dialog refuses such names unless you type them with
quotes, makes every column nullable whatever the file says, and does not know `USE_LOGICAL_TYPE` by default; the SQL above
avoids all three. For plain names use `--ascii-names` (or an alias in the query).

## Troubleshooting

| You see | Cause and fix |
|---|---|
| `expected 28 fields but found 20` at some line | Text fields contain line breaks: add `--row-delimiter crlf` (or whatever really ends a row). Or the `--delimiter` is wrong, or a stray `"` starts a quoted field: try `--quote none` |
| a numeric column became `string` | A value that is not a number, such as `01234`, `+4670...`, `1 234` or a different decimal separator. Use `--culture sv-SE` for comma decimals, or set the type in a schema file |
| decimals have more scale than expected | Inference uses the most decimals seen, with precision 38. Narrow it in a schema file |
| `Å` shows as `Ã…` or `?` | Wrong `--encoding` for a CSV file; for text piped from PowerShell 5.1 set `$global:OutputEncoding` (see [JSON Lines](#json-lines)) |
| `the output file ... exists` | Add `--force` / `-Force` |
| `... is not a boolean / integer / date ...` with a line and column | The value does not fit the schema (inferred or given). Fix the data or the schema; nothing is written |
| module: `Column 'X': the reader does not give a usable decimal precision and scale` | Give `-ColumnOverride @{ X = @{ Type = 'decimal'; Precision = 18; Scale = 2 } }` |
| module: `cannot store` a binary column | Convert it in the query (for example to a hex string) |
| module: `parqueter.exe was not found` | Pass `-ParqueterPath`, set `$env:PARQUETER_EXE`, or put the exe next to the module |
| Snowflake shows a timestamp as a number | Use a file format with `USE_LOGICAL_TYPE = TRUE` |
| Snowflake load dialog: "Contains invalid characters. Consider enclosing in double quotes" | National letters in a column name: type the name in quotes, load with SQL as above, or use `--ascii-names` |

## Limits

* Parquet only, one table (one flat set of columns) per file. No nested types and no binary columns.
* No time-of-day type yet: a value such as `07:30:00` is a `string`.
* Timestamps have no time zone (an input offset is converted to UTC and the zone dropped).
* CSV dates are ISO 8601 unless the schema gives a `format`.
* Windows x64 and the .NET 8 runtime for the exe; Windows PowerShell 5.1 for the module (not tested in PowerShell 7).
* The Oracle and Snowflake ODBC drivers have not been tried (SQL Server through SqlClient and ODBC has).

## Dependencies

parqueter uses [Parquet.Net](https://www.nuget.org/packages/Parquet.Net) 6.1.0 (MIT) to write and read Parquet files.
**Parquet.Net was retired by its author on 10 November 2026**: the GitHub repository is gone, no new versions are planned,
and the author says the NuGet package will stay available. The library is stable and parqueter only uses its basics (flat
tables, standard types), so this is not an immediate problem, but there will be no fixes and no support for future Parquet
or .NET versions.

* The version is **pinned exactly** (`Parquet.Net 6.1.0` in `src/Parqueter/Parqueter.csproj`) and the exe has it built in,
  so exes that have been released are not affected.
* The six packages that go into the exe (Parquet.Net and the five libraries it needs) are kept in
  [`third-party/nuget/`](third-party/nuget), with the hashes NuGet recorded, so that a build never depends on nuget.org or on
  the package staying there: `dotnet restore src/Parqueter --source third-party/nuget` restores, builds and runs the
  tool from these copies alone (verified with an empty package cache). Publishing the Windows exe with `-r win-x64` also needs
  Microsoft's own host and runtime packs, which come from nuget.org as usual and are not part of this risk.
* The licenses of all built-in libraries are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), which is also in the release zip.
* Only `ParquetOut.cs` and `ParquetInspect.cs` use the library; the CSV reading, the schemas and the PowerShell module do
  not. Replacing it later with another Parquet library would therefore be a contained change.
* **Decision: stay on Parquet.Net 6.1.0.** [ParquetSharp](https://github.com/G-Research/ParquetSharp) was tried as a replacement and
  passed all the tests, but it needs a 15 MB native library (built on Apache Arrow), which makes the exe about 16 MB instead of
  1.7 MB and unpacks a DLL on first run. It was not adopted.
* **Why a fork of the source is kept:** the author retired Parquet.Net, made its GitHub repository private and took the source
  download offline, so the source can no longer be fetched from its original home. Every file parqueter writes goes through this
  library, so we keep a copy of the exact source that can be verified, built and, if necessary, fixed by us. It costs nothing while
  the library works. It matters only if a real bug turns up (or a future .NET version breaks the library): the fix can then be made
  and built from this fork instead of waiting for an upstream that no longer exists.
* **The fork:** [Roenbaeck/parquet-dotnet](https://github.com/Roenbaeck/parquet-dotnet). Its tag `6.1.0` is the commit the 6.1.0
  package was built from (`c179d97bd2549b5f44a9241e729f869d4947ee59`, recorded in the package metadata), and its branch
  `upstream-final` is the original author's last code commit (`6cdd7de0ff93d1af6819b16d7a7f3c61063df28e`, 2026-08-25, nine commits
  newer; the same hash is found in independent public forks, so the source can be verified). A fix would be built from that source
  and used in parqueter through a project reference, without publishing a package under the Parquet.Net name.

## Build and test

Building needs the .NET 8 SDK. The repository has a devcontainer (`.devcontainer`) with the SDK, PowerShell 7 and the PSParquet
module, which works in GitHub Codespaces or any other devcontainer host, so nothing has to be installed locally.
The tests are PowerShell scripts: `Test-Csv.ps1` and `Test-Jsonl.ps1` run in Windows PowerShell 5.1 and PowerShell 7,
`Test-Module.ps1` in Windows PowerShell 5.1 only.

```powershell
./publish.ps1                                       # builds publish/parqueter.exe (framework-dependent, single file, win-x64)
./tests/Test-Csv.ps1                                # builds and tests with the dotnet CLI (also on Linux)
./tests/Test-Jsonl.ps1
./tests/Test-Csv.ps1 -Exe .\publish\parqueter.exe   # tests the exe, also in Windows PowerShell 5.1
./tests/Test-Jsonl.ps1 -Exe .\publish\parqueter.exe
./tests/Test-Module.ps1 -Exe .\publish\parqueter.exe    # the PowerShell module (Windows PowerShell 5.1)
```

**Continuous build and releases.** The GitHub Actions workflow `.github/workflows/build.yml` runs on every push and pull
request: it builds the exe on a Windows runner and runs `Test-Csv.ps1`, `Test-Jsonl.ps1` and `Test-Module.ps1` in Windows
PowerShell 5.1. The files of every run can be downloaded as a workflow artifact. To make a release, push a version tag; the
version is taken from the tag, the tests run first, and the release gets the files listed under [Install](#install):

```powershell
git tag v0.2.0
git push origin v0.2.0
```

A tag with a hyphen (`v0.2.0-rc1`) is published as a pre-release. `./publish.ps1 -Version 0.2.0` builds the same exe locally.

`Test-Parquet.ps1` is a small experiment, separate from parqueter, that writes typed and CSV-style data with the PSParquet
module and prints what ended up in the file (it needs PowerShell 7.4 or later and `Install-Module PSParquet`).

## License

MIT, see [LICENSE](LICENSE).
