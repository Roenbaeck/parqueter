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
| JSON Lines on stdin, for PowerShell 5.1 to pipe into | planned |

## Usage

```
parqueter csv <input.csv> <output.parquet> [options]
parqueter inspect <file.parquet> [--rows N]
parqueter --version
```

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

### What CSV inference does

* An empty field, or any `--null` text, is a null. In a string column an empty field is null too, unless `--keep-empty-strings`.
* Integers become `int32` or `int64`, other numbers `decimal(38, s)` where `s` is the most decimals seen.
* Values with leading zeros (`01234`) or a leading `+` are kept as strings: they are identifiers, not numbers.
* Dates are ISO 8601 only (`2026-01-15`, `2026-01-15T10:30:00`, with or without `Z` or an offset). A timestamp with an offset is converted to UTC; one without is kept as written. Timestamps are stored with microsecond precision and without time zone.
* A value that does not fit the schema stops the run with the line and column. Nothing is silently rounded or nulled, and no half-written file is left behind.

## Build and test

There is no .NET SDK on the laptop; the project is built in a GitHub codespace (see `.devcontainer`).

```powershell
./publish.ps1                                  # in the codespace: builds publish/parqueter.exe (framework-dependent, single file)
./tests/Test-Csv.ps1                           # builds and tests with the dotnet CLI
./tests/Test-Csv.ps1 -Exe .\publish\parqueter.exe   # tests the exe, also in Windows PowerShell 5.1
```

`Test-Parquet.ps1` is the earlier smoke test of the PSParquet module, kept for reference.

## License

MIT, see [LICENSE](LICENSE).
