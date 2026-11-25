# Safety copy of the NuGet packages

The exact packages that `parqueter.exe` is built from, as downloaded from nuget.org by the build. They are kept here because
Parquet.Net, the library that does the Parquet writing, was retired by its author on 2026-11-10 and its repository removed
(see "Dependencies" in the main README).

| Package | Version |
|---|---|
| Parquet.Net | 6.1.0 |
| CommunityToolkit.HighPerformance | 8.4.2 |
| K4os.Compression.LZ4 | 1.3.8 |
| Microsoft.IO.RecyclableMemoryStream | 3.0.1 |
| Snappier | 1.3.1 |
| ZstdSharp.Port | 0.8.8 |

Each `.nupkg.sha512` file is the SHA-512 (base64) that NuGet recorded when it downloaded the package from nuget.org.

Restore, build and run from this folder instead of nuget.org (verified with an empty package cache and no other source):

```
dotnet restore src/Parqueter --source third-party/nuget
dotnet build src/Parqueter -c Release --no-restore -o out
dotnet out/parqueter.dll --version
```

Publishing the Windows exe (`-r win-x64`, see `publish.ps1`) additionally needs Microsoft's host and runtime packs
(`Microsoft.NETCore.App.Host.win-x64` and others). Those are not in this folder: they come from nuget.org as usual and
are not part of the Parquet.Net risk. To use both sources, add `--source https://api.nuget.org/v3/index.json` as a second `--source`.

The licenses of these packages are in [`THIRD-PARTY-NOTICES.md`](../../THIRD-PARTY-NOTICES.md) at the root of the repository.
