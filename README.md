# parqueter

A small command line tool that writes Parquet files with **exact types and nullability**. It is one
framework-dependent `parqueter.exe` (needs the .NET 8 runtime), unsigned, with
[Parquet.Net](https://github.com/aloneguid/parquet-dotnet) built in.

## Design

parqueter does one thing: **typed rows in, Parquet out.** It does not know about databases or REST APIs.
Getting data out of SQL Server, Oracle, Snowflake, IFS, Jira and so on is done by the tools that are
already approved for that (PowerShell 5.1 with its drivers and modules), which hand the rows to parqueter.

Every input has a *schema*: for each column a type, whether it may be null, and for decimals the
precision and scale. The schema is what ends up in the Parquet file, so a null stays a null (PSParquet
cannot do that: it writes every column as required and turns a null integer into 0).

| Input | Status |
|---|---|
| CSV file | done: `parqueter csv` |
| JSON Lines, from a file or stdin, for PowerShell 5.1 to pipe into | done: `parqueter jsonl` |
| PowerShell 5.1 module that reads from any ADO.NET source or from objects and pipes to `jsonl` | done: `powershell/Parqueter.psm1` (tested with a DataTable reader; not yet against a real database server) |

## Usage

```
parqueter csv <input.csv> <output.parquet> [options]
parqueter jsonl <input.jsonl | -> <output.parquet> [options]
parqueter inspect <file.parquet> [--rows N] [--stats]
parqueter --version
```

`inspect` shows what is really in a Parquet file: the schema with `required`/`optional`, the first rows, and with
`--stats` the null count, minimum, maximum and sum of every column (read one row group at a time, so it works on
files far larger than memory). Compare those numbers with a `SELECT COUNT(*), SUM(...), MIN(...), MAX(...)` on the source.

`csv` options: `--schema`, `--write-schema`, `--delimiter`, `--quote`, `--row-delimiter`, `--no-header`, `--encoding`
(`windows-1252`), `--culture` (`sv-SE`), `--null <text>` (repeatable), `--keep-empty-strings`,
`--row-group-size`, `--force`. Run `parqueter --help` for details.

* `--delimiter` is a character, a word (`tab`, `comma`, `semicolon`, `pipe`), a character code (`0x1F`, `\x1F`, `U+001F`)
  or several characters (`^;`). A byte order mark is detected, so UTF-8 and UTF-16 files need no `--encoding`.
* `--quote none` for files that never quote their fields (SSIS without a text qualifier). Otherwise a field that
  starts with `"` is read as quoted and the quotes are dropped.
* `--row-delimiter crlf` when text fields contain line breaks. Only that exact text ends a row and any other
  line break is data, which is how SSIS reads a flat file. Without it, such a record is split and parqueter stops
  with `expected N fields but found M` and the line number.
* With a culture such as `sv-SE`, an ordinary `-` is still the minus sign.
* `--ascii-names` makes column names plain ASCII (`ÅR` becomes `AR`, `KOSTNADSSTÄLLE` `KOSTNADSSTALLE`, a space or dash `_`),
  so Snowflake and most databases need no double quotes. Quoting is SQL syntax, not part of Parquet, which accepts any
  UTF-8 name: without this option a name like `ÅR` is stored as is, and Snowflake's load dialog asks you to quote it
  (`"ÅR"`) and then every query has to as well. The original name is kept as `source` in the schema written by
  `--write-schema`. A column can be renamed by editing its `name` there while `source` stays the header text.

Example, an SSIS flat file (UTF-16, delimiter `0x1F`, rows end with CRLF, Swedish decimals):

```powershell
parqueter csv ledger.csv ledger.parquet --delimiter 0x1F --quote none --row-delimiter crlf --culture sv-SE
parqueter inspect ledger.parquet --rows 0 --stats
```

Without `--schema` the types are inferred from the whole file. Review what was decided with
`--write-schema schema.json`, edit it, and pass it back with `--schema schema.json`.

```powershell
parqueter csv orders.csv orders.parquet --delimiter ';' --culture sv-SE --encoding windows-1252 --null NULL
parqueter inspect orders.parquet
```

Schema file:

```json
{
  "columns": [
    { "name": "Id",       "type": "int32",    "nullable": false },
    { "name": "Price",    "type": "decimal",  "precision": 18, "scale": 2 },
    { "name": "Created",  "type": "dateTime" },
    { "name": "Shipped",  "type": "date", "format": "dd/MM/yyyy" }
  ]
}
```

Types: `string`, `bool`, `int32`, `int64`, `decimal`, `double`, `dateTime`, `date`, `guid`.
`nullable` defaults to true.

### JSON Lines

The input is one JSON value per line. Unless `--schema` is given, the **first line is the schema** (the same
JSON as a schema file, on one line). Every other line is a **row**: an array in column order, or an object keyed
by column name (a missing key is null). Use `-` as the input to read stdin.

```
{"columns":[{"name":"Id","type":"int64","nullable":false},{"name":"Name","type":"string"},{"name":"Price","type":"decimal","precision":18,"scale":4}]}
[1,"Alpha",12.5]
[2,null,0.0001]
```

Numbers are read as exact text, so a decimal never passes through a double. A number or boolean is accepted
for a string column and a string for a numeric column; dates and timestamps are ISO 8601 strings. Anything that
does not fit the schema stops the run with the line and the column.

```powershell
$lines | parqueter.exe jsonl - out.parquet
```

Pitfall when piping from **Windows PowerShell 5.1**: text sent to a program is encoded with `$OutputEncoding`, which
is ASCII by default, so non-ASCII letters turn into `?`. Set it to UTF-8, and set it in the *global* scope;
an assignment inside a function is silently ignored:

```powershell
$global:OutputEncoding = New-Object System.Text.UTF8Encoding $false
```

## PowerShell module (Windows PowerShell 5.1)

[powershell/Parqueter.psm1](powershell/Parqueter.psm1) is a single file next to `parqueter.exe`. It reads from any
ADO.NET reader and takes the **schema from the reader itself** (`GetSchemaTable()`): a `NOT NULL` column
becomes a required Parquet column, a decimal gets its precision and scale, and nulls stay nulls. Rows are
streamed to `parqueter.exe jsonl -` by a small compiled helper, so a large table never passes through the
PowerShell pipeline or sits in memory. If a row does not fit, or the reader fails half way, no file is left behind.

```powershell
Import-Module .\Parqueter.psm1

# SQL Server (System.Data.SqlClient comes with Windows PowerShell)
$connection = New-Object System.Data.SqlClient.SqlConnection 'Server=myserver;Database=mydb;Integrated Security=True'
$connection.Open()
$command = $connection.CreateCommand()
$command.CommandText = 'SELECT OrderId, Customer, Amount, Created FROM dbo.Orders'
$command.CommandTimeout = 0
$reader = $command.ExecuteReader()
Export-ParqueterFromReader -Reader $reader -Path orders.parquet -ParqueterPath .\parqueter.exe -Force
$reader.Dispose(); $connection.Dispose()
```

Oracle and Snowflake work the same way through any provider that gives a data reader, for example ODBC
(`System.Data.Odbc.OdbcConnection` with the Snowflake or Oracle ODBC driver). Use `Get-ParqueterSchema -Reader $reader`
to see what will be written. When a provider cannot say a decimal's precision and scale (typical for an Oracle
`NUMBER` without a declared size) the export stops and says so; give the answer with `-ColumnOverride`:

```powershell
Export-ParqueterFromReader -Reader $reader -Path out.parquet -ParqueterPath .\parqueter.exe `
    -ColumnOverride @{ Amount = @{ Type = 'decimal'; Precision = 18; Scale = 4 }; Note = @{ Nullable = $true } }
```

For **REST** (IFS, Netboss, Jira ...) the script does the calling, paging and authentication, and the module
writes the objects. Objects carry no reliable types or nullability, so the schema is declared:

```powershell
$schema = @(
    New-ParqueterColumn Key string -NotNull
    New-ParqueterColumn Created dateTime
    New-ParqueterColumn Estimate decimal -Precision 18 -Scale 2
)
$issues | Export-ParqueterObjects -Schema $schema -Path issues.parquet -ParqueterPath .\parqueter.exe
```

`parqueter.exe` is found through `-ParqueterPath`, then `$env:PARQUETER_EXE`, then next to the module, then on the PATH.
Provider type mapping: strings and characters (and `TimeSpan`) become `string`, `Byte`/`Int16`/`Int32` become `int32`,
`Int64`/`UInt32` `int64`, `UInt64` `decimal(20,0)`, `Single`/`Double` `double`, `DateTime` and `DateTimeOffset`
`dateTime` (an offset is converted to UTC; a SQL Server `date` column becomes `date`), `Guid` `guid`. Binary columns are
refused: convert them in the query.

**Scale and memory.** Nothing is collected in PowerShell: the reader is read one row at a time, written to
parqueter's stdin, and parqueter holds one row group (100,000 rows by default, `-RowGroupSize`) at a time.
Measured against a SQL Server test database: 11,855,549 rows (3 columns: int, `decimal(17,2)`, datetime) in
57 seconds, about 208,000 rows/s, to an 80 MB file. Peak memory was 94 MB for PowerShell and 73 MB for parqueter
(private bytes), and count, sum, minimum and maximum matched SQL exactly.

Test it with `tests/Test-Module.ps1 -Exe .\publish\parqueter.exe` (it uses a `DataTable` reader, no server needed).

### What CSV inference does

* An empty field, or any `--null` text, is a null. In a string column an empty field is null too, unless `--keep-empty-strings`.
* Integers become `int32` or `int64`, other numbers `decimal(38, s)` where `s` is the most decimals seen.
* Values with leading zeros (`01234`) or a leading `+` are kept as strings: they are identifiers, not numbers.
* Dates are ISO 8601 only (`2026-01-15`, `2026-01-15T10:30:00`, with or without `Z` or an offset). A timestamp with an offset is converted to UTC; one without is kept as written. Timestamps are stored as Parquet `TIMESTAMP` with microsecond precision and not adjusted to UTC (Snowflake reads that as `TIMESTAMP_NTZ`).
* A value that does not fit the schema stops the run with the line and column. Nothing is silently rounded or nulled, and no half-written file is left behind.

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

`USING TEMPLATE` worked in a Snowsight workspace but failed through the SQL REST API (cause unknown). There the column
list can be generated instead and pasted into `CREATE TABLE ledger ( ... )`:
`SELECT GENERATE_COLUMN_DESCRIPTION(ARRAY_AGG(OBJECT_CONSTRUCT(*)), 'table') FROM TABLE(INFER_SCHEMA(...))`.
Required columns in the Parquet file become `NOT NULL`. Check the load with `parqueter inspect --stats` against
`SELECT COUNT(*), SUM(...), MIN(...), MAX(...)` on the table.

**Column names.** Quoting is Snowflake SQL, not Parquet. A name such as `ÅR` is stored as is and loads fine, but it is
a quoted identifier in Snowflake and must be written `"ÅR"` in every query. The Snowsight *Load Data into Table*
dialog refuses such names unless you type them with quotes, makes every column nullable whatever the file says, and
does not know `USE_LOGICAL_TYPE` by default; the SQL above avoids all three. For plain names use `--ascii-names`.

## Build and test

There is no .NET SDK on the laptop; the project is built in a GitHub codespace (see `.devcontainer`).

```powershell
./publish.ps1                                  # in the codespace: builds publish/parqueter.exe (framework-dependent, single file)
./tests/Test-Csv.ps1                           # builds and tests with the dotnet CLI
./tests/Test-Jsonl.ps1
./tests/Test-Csv.ps1 -Exe .\publish\parqueter.exe   # tests the exe, also in Windows PowerShell 5.1
```

`Test-Parquet.ps1` is the earlier smoke test of the PSParquet module, kept for reference.

## License

MIT, see [LICENSE](LICENSE).
