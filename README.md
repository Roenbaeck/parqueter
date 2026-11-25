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

`csv` options: `--schema`, `--write-schema`, `--delimiter` (`;`, `tab`), `--no-header`, `--encoding`
(`windows-1252`), `--culture` (`sv-SE`), `--null <text>` (repeatable), `--keep-empty-strings`,
`--row-group-size`, `--force`. Run `parqueter --help` for details.

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
