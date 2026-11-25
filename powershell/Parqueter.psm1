<#
.SYNOPSIS
    Windows PowerShell 5.1 module that feeds parqueter.exe: reads rows from any ADO.NET data reader
    (SQL Server, Oracle, Snowflake over ODBC, ...) or from objects, and writes a Parquet file with exact
    types and nullability.

.DESCRIPTION
    The schema (type, nullable, decimal precision and scale) is taken from the reader's GetSchemaTable(),
    so a NOT NULL column is written as a required Parquet column and a null stays a null. Rows are
    streamed to "parqueter.exe jsonl -" on stdin by a small compiled helper, so large results do not
    pass through the PowerShell pipeline and never sit in memory.

    Import-Module .\Parqueter.psm1
    $reader = $command.ExecuteReader()
    Export-ParqueterFromReader -Reader $reader -Path orders.parquet -ParqueterPath .\parqueter.exe
#>
#Requires -Version 5.1
Set-StrictMode -Version 2.0

$script:ModuleRoot = $PSScriptRoot

# The row formatter is C# 5 (what Windows PowerShell 5.1 compiles) and runs once per value, so it is compiled.
$script:HelperSource = @'
using System;
using System.Data;
using System.Globalization;
using System.IO;
using System.Text;

namespace Parqueter
{
    public static class JsonLinesWriter
    {
        const int KString = 1, KBool = 2, KInt = 3, KDecimal = 4, KDouble = 5, KDateTime = 6, KDate = 7, KGuid = 8;

        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        public static int KindOf(string parqueterType)
        {
            switch (parqueterType)
            {
                case "string": return KString;
                case "bool": return KBool;
                case "int32": case "int64": return KInt;
                case "decimal": return KDecimal;
                case "double": return KDouble;
                case "dateTime": return KDateTime;
                case "date": return KDate;
                case "guid": return KGuid;
                default: throw new ArgumentException("Unknown parqueter type '" + parqueterType + "'");
            }
        }

        public static string Quote(string s)
        {
            StringWriter sw = new StringWriter(CultureInfo.InvariantCulture);
            WriteString(sw, s);
            return sw.ToString();
        }

        public static long WriteRows(IDataReader reader, int[] kinds, string[] names, TextWriter w)
        {
            object[] values = new object[reader.FieldCount];
            long row = 0;
            while (reader.Read())
            {
                row++;
                reader.GetValues(values);
                try
                {
                    WriteRow(w, values, kinds, names);
                }
                catch (IOException)
                {
                    throw;
                }
                catch (Exception e)
                {
                    throw new InvalidDataException("row " + row + ", " + e.Message, e);
                }
            }
            return row;
        }

        public static void WriteRow(TextWriter w, object[] values, int[] kinds, string[] names)
        {
            w.Write('[');
            for (int i = 0; i < kinds.Length; i++)
            {
                if (i > 0) w.Write(',');
                try
                {
                    WriteValue(w, values[i], kinds[i]);
                }
                catch (IOException)
                {
                    throw;
                }
                catch (Exception e)
                {
                    throw new InvalidDataException("column '" + names[i] + "': " + e.Message, e);
                }
            }
            w.Write("]\n");
        }

        static void WriteValue(TextWriter w, object v, int kind)
        {
            if (v == null || v is DBNull) { w.Write("null"); return; }

            switch (kind)
            {
                case KString:
                    WriteString(w, v as string ?? Convert.ToString(v, Inv));
                    break;

                case KBool:
                    w.Write(Convert.ToBoolean(v, Inv) ? "true" : "false");
                    break;

                case KInt:
                    w.Write(Convert.ToInt64(v, Inv).ToString(Inv));
                    break;

                case KDecimal:
                    w.Write((v is decimal ? (decimal)v : Convert.ToDecimal(v, Inv)).ToString(Inv));
                    break;

                case KDouble:
                    double d = Convert.ToDouble(v, Inv);
                    if (double.IsNaN(d) || double.IsInfinity(d)) throw new InvalidDataException("NaN and infinity cannot be stored");
                    w.Write(d.ToString("R", Inv));
                    break;

                case KDateTime:
                    if (v is DateTimeOffset)
                    {
                        w.Write('"');
                        w.Write(((DateTimeOffset)v).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'", Inv));
                        w.Write('"');
                    }
                    else if (v is DateTime)
                    {
                        w.Write('"');
                        w.Write(((DateTime)v).ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff", Inv));
                        w.Write('"');
                    }
                    else WriteString(w, Convert.ToString(v, Inv));
                    break;

                case KDate:
                    if (v is DateTime)
                    {
                        w.Write('"');
                        w.Write(((DateTime)v).ToString("yyyy-MM-dd", Inv));
                        w.Write('"');
                    }
                    else if (v is DateTimeOffset)
                    {
                        w.Write('"');
                        w.Write(((DateTimeOffset)v).ToString("yyyy-MM-dd", Inv));
                        w.Write('"');
                    }
                    else WriteString(w, Convert.ToString(v, Inv));
                    break;

                case KGuid:
                    w.Write('"');
                    w.Write(v is Guid ? ((Guid)v).ToString("D") : Convert.ToString(v, Inv));
                    w.Write('"');
                    break;

                default:
                    throw new InvalidOperationException("Unknown kind " + kind);
            }
        }

        static void WriteString(TextWriter w, string s)
        {
            w.Write('"');
            int start = 0;
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c != '"' && c != '\\' && c >= ' ') continue;

                if (i > start) w.Write(s.Substring(start, i - start));
                start = i + 1;
                switch (c)
                {
                    case '"': w.Write("\\\""); break;
                    case '\\': w.Write("\\\\"); break;
                    case '\n': w.Write("\\n"); break;
                    case '\r': w.Write("\\r"); break;
                    case '\t': w.Write("\\t"); break;
                    case '\b': w.Write("\\b"); break;
                    case '\f': w.Write("\\f"); break;
                    default: w.Write("\\u" + ((int)c).ToString("x4", Inv)); break;
                }
            }
            if (start == 0) w.Write(s);
            else if (start < s.Length) w.Write(s.Substring(start));
            w.Write('"');
        }
    }
}
'@

if (-not ('Parqueter.JsonLinesWriter' -as [type])) {
    Add-Type -TypeDefinition $script:HelperSource -ReferencedAssemblies 'System.Data' -Language CSharp
}

$script:ValidTypes = @('string', 'bool', 'int32', 'int64', 'decimal', 'double', 'dateTime', 'date', 'guid')

# --- schema ------------------------------------------------------------------

function New-ParqueterColumn {
    <#
    .SYNOPSIS
        Declares one column of a schema for Export-ParqueterObjects (or as an override for a reader).
    .EXAMPLE
        New-ParqueterColumn -Name Price -Type decimal -Precision 18 -Scale 2
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('string', 'bool', 'int32', 'int64', 'decimal', 'double', 'dateTime', 'date', 'guid')] [string] $Type,
        [switch] $NotNull,
        [int] $Precision = 38,
        [int] $Scale = 0
    )
    [pscustomobject]@{
        Name      = $Name
        Type      = $Type
        Nullable  = -not $NotNull
        Precision = $Precision
        Scale     = $Scale
    }
}

function Get-ParqueterColumnFromSchemaRow {
    param($Row, $Table, [int] $Position, $Override)

    $name = [string]$Row['ColumnName']
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Column $Position has no name. Give it an alias in the query (SELECT expr AS Name)."
    }

    $clr = $Row['DataType']
    $allow = $Row['AllowDBNull']
    $nullable = ($allow -is [DBNull]) -or [bool]$allow
    $precision = $null
    $scale = $null

    switch ($clr.FullName) {
        'System.String'         { $type = 'string' }
        'System.Char'           { $type = 'string' }
        'System.TimeSpan'       { $type = 'string' }
        'System.Boolean'        { $type = 'bool' }
        'System.Byte'           { $type = 'int32' }
        'System.SByte'          { $type = 'int32' }
        'System.Int16'          { $type = 'int32' }
        'System.UInt16'         { $type = 'int32' }
        'System.Int32'          { $type = 'int32' }
        'System.UInt32'         { $type = 'int64' }
        'System.Int64'          { $type = 'int64' }
        'System.UInt64'         { $type = 'decimal'; $precision = 20; $scale = 0 }
        'System.Single'         { $type = 'double' }
        'System.Double'         { $type = 'double' }
        'System.Guid'           { $type = 'guid' }
        'System.DateTimeOffset' { $type = 'dateTime' }
        'System.DateTime' {
            $type = 'dateTime'
            if ($Table.Columns.Contains('DataTypeName') -and ([string]$Row['DataTypeName']) -eq 'date') { $type = 'date' }
        }
        'System.Decimal' {
            $type = 'decimal'
            $p = $Row['NumericPrecision']
            $s = $Row['NumericScale']
            if (($p -isnot [DBNull]) -and ($s -isnot [DBNull])) { $precision = [int]$p; $scale = [int]$s }
        }
        default { $type = $null }
    }

    if ($Override) {
        if ($Override.ContainsKey('Type')) {
            $type = [string]$Override['Type']
            if ($script:ValidTypes -cnotcontains $type) { throw "Override for '$name': '$type' is not one of $($script:ValidTypes -join ', ')." }
        }
        if ($Override.ContainsKey('Nullable')) { $nullable = [bool]$Override['Nullable'] }
        if ($Override.ContainsKey('Precision')) { $precision = [int]$Override['Precision'] }
        if ($Override.ContainsKey('Scale')) { $scale = [int]$Override['Scale'] }
    }

    if (-not $type) {
        throw "Column '$name' has the type $($clr.FullName), which parqueter cannot store. Convert it in the query (for binary data, a hex string) or use -ColumnOverride."
    }

    if ($type -eq 'decimal') {
        $valid = ($null -ne $precision) -and ($null -ne $scale) -and ($precision -ge 1) -and ($precision -le 38) -and ($scale -ge 0) -and ($scale -le $precision)
        if (-not $valid) {
            $shown = if ($null -eq $precision) { 'unknown' } else { "precision $precision, scale $scale" }
            throw "Column '$name': the reader does not give a usable decimal precision and scale ($shown). Pass -ColumnOverride @{ $name = @{ Type = 'decimal'; Precision = 18; Scale = 4 } }."
        }
    } else {
        $precision = $null
        $scale = $null
    }

    [pscustomobject]@{
        Name       = $name
        Type       = $type
        Nullable   = $nullable
        Precision  = $precision
        Scale      = $scale
        SourceType = $clr.Name
    }
}

function Get-ParqueterSchema {
    <#
    .SYNOPSIS
        Derives a parqueter schema from an open data reader's column metadata.
    .DESCRIPTION
        Use it to see what Export-ParqueterFromReader will do, or to find the columns that need -ColumnOverride.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Data.IDataReader] $Reader,
        [hashtable] $ColumnOverride
    )
    $table = $Reader.GetSchemaTable()
    if ($null -eq $table) { throw 'The reader has no result set (no schema table).' }

    $columns = New-Object System.Collections.Generic.List[object]
    $position = 0
    foreach ($row in $table.Rows) {
        $position++
        $override = $null
        $name = [string]$row['ColumnName']
        if ($ColumnOverride -and $ColumnOverride.ContainsKey($name)) { $override = $ColumnOverride[$name] }
        $columns.Add((Get-ParqueterColumnFromSchemaRow -Row $row -Table $table -Position $position -Override $override))
    }
    if ($columns.Count -eq 0) { throw 'The reader has no columns.' }

    $seen = @{}
    foreach ($c in $columns) {
        if ($seen.ContainsKey($c.Name)) { throw "The result has the column name '$($c.Name)' twice. Give the columns unique aliases." }
        $seen[$c.Name] = $true
    }
    $columns.ToArray()
}

function ConvertTo-ParqueterSchemaLine {
    param([object[]] $Column)
    $parts = foreach ($c in $Column) {
        $json = '{"name":' + [Parqueter.JsonLinesWriter]::Quote($c.Name) + ',"type":"' + $c.Type + '","nullable":' + $(if ($c.Nullable) { 'true' } else { 'false' })
        if ($c.Type -eq 'decimal') { $json += ',"precision":' + $c.Precision + ',"scale":' + $c.Scale }
        $json + '}'
    }
    '{"columns":[' + ($parts -join ',') + ']}'
}

# --- the parqueter process ---------------------------------------------------

function Resolve-ParqueterExe {
    param([string] $Path)
    if (-not $Path -and $env:PARQUETER_EXE) { $Path = $env:PARQUETER_EXE }
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "parqueter.exe was not found at '$Path'." }
        return (Resolve-Path -LiteralPath $Path).ProviderPath
    }
    $beside = Join-Path $script:ModuleRoot 'parqueter.exe'
    if (Test-Path -LiteralPath $beside -PathType Leaf) { return $beside }
    $command = Get-Command parqueter -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw 'parqueter.exe was not found. Pass -ParqueterPath, set $env:PARQUETER_EXE, or put it next to the module or on the PATH.'
}

function ConvertTo-ArgumentString {
    param([string] $Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    '"' + $escaped + '"'
}

function Start-ParqueterProcess {
    param([string] $Exe, [string] $Path, [switch] $Force, [int] $RowGroupSize, [string] $SchemaFile)

    $arguments = @('jsonl', '-', $Path, '--row-group-size', $RowGroupSize)
    if ($Force) { $arguments += '--force' }
    if ($SchemaFile) { $arguments += @('--write-schema', $SchemaFile) }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Exe
    $startInfo.Arguments = ($arguments | ForEach-Object { ConvertTo-ArgumentString ([string]$_) }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    # Read both output streams in the background so a full pipe can never block parqueter.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()

    # Write the rows as UTF-8 without a byte order mark, whatever the console code page is.
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $writer = New-Object System.IO.StreamWriter($process.StandardInput.BaseStream, $utf8, 65536)

    [pscustomobject]@{ Process = $process; Writer = $writer; Stdout = $stdout; Stderr = $stderr; Path = $Path }
}

function Stop-ParqueterProcess {
    # Abort: kill parqueter so it never finishes a partial file, then remove its temporary file.
    param($Context)
    try { if (-not $Context.Process.HasExited) { $Context.Process.Kill() } } catch { }
    try { [void]$Context.Process.WaitForExit(5000) } catch { }
    Remove-Item -LiteralPath ($Context.Path + '.tmp') -Force -ErrorAction SilentlyContinue
}

function Complete-ParqueterProcess {
    param($Context)
    $Context.Writer.Flush()
    $Context.Writer.Close()
    $Context.Process.WaitForExit()
    $stdout = $Context.Stdout.Result
    $stderr = $Context.Stderr.Result
    if ($Context.Process.ExitCode -ne 0) {
        throw "parqueter failed (exit code $($Context.Process.ExitCode)): $($stderr.Trim())"
    }
    $stdout
}

function Get-InnerException {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($null -ne $e.InnerException -and ($e -is [System.Management.Automation.MethodInvocationException] -or $e -is [System.Reflection.TargetInvocationException])) {
        $e = $e.InnerException
    }
    $e
}

# When parqueter stops early (a row that does not fit), our write fails with a broken pipe; its stderr says why.
function Resolve-WriteFailure {
    param($Context, $ErrorRecord)
    $inner = Get-InnerException $ErrorRecord
    if ($inner -is [System.IO.IOException] -and $Context.Process.WaitForExit(5000)) {
        $reason = $Context.Stderr.Result.Trim()
        Remove-Item -LiteralPath ($Context.Path + '.tmp') -Force -ErrorAction SilentlyContinue
        if ($reason) { return "parqueter stopped: $reason" }
    }
    Stop-ParqueterProcess $Context
    $inner.Message
}

# --- public commands ---------------------------------------------------------

function Export-ParqueterFromReader {
    <#
    .SYNOPSIS
        Writes everything an open data reader returns to a Parquet file.
    .DESCRIPTION
        Works with any System.Data.IDataReader: SqlClient, OracleClient/ODP.NET, ODBC (Snowflake), OleDb, DataTableReader.
        Types, nullability and decimal precision/scale come from the reader's schema. If parqueter stops, or the
        reader fails half way, no output file is left behind.
    .PARAMETER ColumnOverride
        Per column changes: @{ Amount = @{ Type = 'decimal'; Precision = 18; Scale = 2 }; Note = @{ Nullable = $true } }.
        Needed when a provider cannot say a decimal's precision and scale (typically Oracle NUMBER without a declared size).
    .EXAMPLE
        $reader = $command.ExecuteReader()
        Export-ParqueterFromReader -Reader $reader -Path orders.parquet -ParqueterPath C:\tools\parqueter.exe
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Data.IDataReader] $Reader,
        [Parameter(Mandatory)] [string] $Path,
        [string] $ParqueterPath,
        [hashtable] $ColumnOverride,
        [switch] $Force,
        [int] $RowGroupSize = 100000,
        [string] $WriteSchema
    )

    $exe = Resolve-ParqueterExe $ParqueterPath
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $columns = Get-ParqueterSchema -Reader $Reader -ColumnOverride $ColumnOverride
    $kinds = [int[]]@($columns | ForEach-Object { [Parqueter.JsonLinesWriter]::KindOf($_.Type) })
    $names = [string[]]@($columns | ForEach-Object { $_.Name })

    $context = Start-ParqueterProcess -Exe $exe -Path $Path -Force:$Force -RowGroupSize $RowGroupSize -SchemaFile $WriteSchema
    $rows = 0
    try {
        $context.Writer.Write((ConvertTo-ParqueterSchemaLine $columns) + "`n")
        $rows = [Parqueter.JsonLinesWriter]::WriteRows($Reader, $kinds, $names, $context.Writer)
        $summary = Complete-ParqueterProcess $context
    } catch {
        throw (Resolve-WriteFailure $context $_)
    }
    Write-Verbose $summary

    [pscustomobject]@{ Path = $Path; Rows = $rows; Columns = $columns }
}

function Export-ParqueterObjects {
    <#
    .SYNOPSIS
        Writes objects from the pipeline (for example the result of a REST call) to a Parquet file.
    .DESCRIPTION
        The schema is declared with New-ParqueterColumn, because objects carry no reliable types or nullability.
        Each object is read by the column names; a missing property is null. Dates should be [datetime]
        or ISO 8601 strings; a value that does not fit stops the export and leaves no file.
    .EXAMPLE
        $schema = @(
            New-ParqueterColumn Key string -NotNull
            New-ParqueterColumn Created dateTime
        )
        $issues | Export-ParqueterObjects -Schema $schema -Path issues.parquet -ParqueterPath .\parqueter.exe
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [object[]] $Schema,
        [Parameter(Mandatory)] [string] $Path,
        [string] $ParqueterPath,
        [switch] $Force,
        [int] $RowGroupSize = 100000
    )

    begin {
        $exe = Resolve-ParqueterExe $ParqueterPath
        $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $columns = @($Schema | ForEach-Object {
            [pscustomobject]@{
                Name      = [string]$_.Name
                Type      = [string]$_.Type
                Nullable  = [bool]$_.Nullable
                Precision = $_.Precision
                Scale     = $_.Scale
            }
        })
        if ($columns.Count -eq 0) { throw 'The schema has no columns.' }
        $kinds = [int[]]@($columns | ForEach-Object { [Parqueter.JsonLinesWriter]::KindOf($_.Type) })
        $names = [string[]]@($columns | ForEach-Object { $_.Name })
        $values = New-Object object[] $columns.Count
        $count = 0

        $context = Start-ParqueterProcess -Exe $exe -Path $Path -Force:$Force -RowGroupSize $RowGroupSize
        try {
            $context.Writer.Write((ConvertTo-ParqueterSchemaLine $columns) + "`n")
        } catch {
            throw (Resolve-WriteFailure $context $_)
        }
    }

    process {
        try {
            for ($i = 0; $i -lt $names.Length; $i++) {
                $value = $null
                if ($InputObject -is [System.Collections.IDictionary]) {
                    if ($InputObject.Contains($names[$i])) { $value = $InputObject[$names[$i]] }
                } elseif ($null -ne $InputObject) {
                    $property = $InputObject.PSObject.Properties[$names[$i]]
                    if ($null -ne $property) { $value = $property.Value }
                }
                $values[$i] = $value
            }
            [Parqueter.JsonLinesWriter]::WriteRow($context.Writer, $values, $kinds, $names)
            $count++
        } catch {
            throw (Resolve-WriteFailure $context $_)
        }
    }

    end {
        try {
            $summary = Complete-ParqueterProcess $context
        } catch {
            throw (Resolve-WriteFailure $context $_)
        }
        Write-Verbose $summary
        [pscustomobject]@{ Path = $Path; Rows = $count; Columns = $columns }
    }
}

Export-ModuleMember -Function New-ParqueterColumn, Get-ParqueterSchema, Export-ParqueterFromReader, Export-ParqueterObjects
