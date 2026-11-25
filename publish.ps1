<#
.SYNOPSIS
    Builds the single-file, framework-dependent parqueter.exe for Windows into ./publish.
    Needs the .NET 8 SDK (run it in the codespace); the resulting exe needs only the .NET 8 runtime.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

dotnet publish (Join-Path $root 'src/Parqueter') -c Release -r win-x64 --self-contained false `
    -p:PublishSingleFile=true -p:DebugType=none -o (Join-Path $root 'publish')
if ($LASTEXITCODE -ne 0) { throw 'publish failed' }

Get-Item (Join-Path $root 'publish/parqueter.exe') | Select-Object Name, Length
