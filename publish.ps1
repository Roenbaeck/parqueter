<#
.SYNOPSIS
    Builds the single-file, framework-dependent parqueter.exe for Windows into ./publish.
    Needs the .NET 8 SDK (the devcontainer has it); the resulting exe needs only the .NET 8 runtime.

.PARAMETER Version
    Version to stamp into the exe (shown by "parqueter --version"), for example 0.2.0.
    Default: the version in src/Parqueter/Parqueter.csproj.
#>
param([string] $Version)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$extra = @()
if ($Version) { $extra += "-p:Version=$Version" }

dotnet publish (Join-Path $root 'src/Parqueter') -c Release -r win-x64 --self-contained false `
    -p:PublishSingleFile=true -p:DebugType=none @extra -o (Join-Path $root 'publish')
if ($LASTEXITCODE -ne 0) { throw 'publish failed' }

Get-Item (Join-Path $root 'publish/parqueter.exe') | Select-Object Name, Length
