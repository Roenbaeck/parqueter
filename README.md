# parqueter
Powershell tool to create Parquet files

Built on the [PSParquet](https://www.powershellgallery.com/packages/PSParquet) module. PSParquet 0.2.x targets .NET 8,
so it needs **PowerShell 7.4 or later** (it does not load in Windows PowerShell 5.1).

## Smoke test

```powershell
./Test-Parquet.ps1
```

Writes `out/typed.parquet` (real .NET types, with nulls) and `out/csv.parquet` (all strings, as from a CSV)
and prints the schema and rows read back, to show which types and nullability survive.

## License

MIT, see [LICENSE](LICENSE).
