using System.Globalization;
using System.Reflection;
using System.Text;

namespace Parqueter;

sealed class CliException(string message, int exitCode = 1) : Exception(message)
{
    public int ExitCode { get; } = exitCode;
}

/// <summary>--name value options (repeatable), --flag switches and positional arguments.</summary>
sealed class Args
{
    static readonly HashSet<string> Flags = new() { "no-header", "keep-empty-strings", "force", "help" };

    readonly Dictionary<string, List<string>> _options = new();
    readonly HashSet<string> _flags = new();
    public List<string> Positional { get; } = new();

    public static Args Parse(IReadOnlyList<string> args)
    {
        var result = new Args();
        for (var i = 0; i < args.Count; i++)
        {
            var a = args[i];
            if (a == "-h") a = "--help";
            if (!a.StartsWith("--", StringComparison.Ordinal)) { result.Positional.Add(a); continue; }

            var name = a[2..];
            if (Flags.Contains(name)) { result._flags.Add(name); continue; }
            if (i + 1 >= args.Count) throw new CliException($"The option --{name} needs a value.", 2);
            if (!result._options.TryGetValue(name, out var list)) result._options[name] = list = new();
            list.Add(args[++i]);
        }
        return result;
    }

    public bool Has(string flag) => _flags.Contains(flag);
    public string? Get(string name) => _options.TryGetValue(name, out var l) ? l[^1] : null;
    public IReadOnlyList<string> GetAll(string name) => _options.TryGetValue(name, out var l) ? l : Array.Empty<string>();

    public void AllowOnly(params string[] names)
    {
        var allowed = new HashSet<string>(names);
        foreach (var n in _options.Keys.Concat(_flags))
            if (!allowed.Contains(n)) throw new CliException($"Unknown option --{n}. Try: parqueter --help", 2);
    }
}

static class Cli
{
    const string Usage = """
        parqueter - write Parquet files with exact types and nullability

        Usage:
          parqueter csv <input.csv> <output.parquet> [options]
          parqueter inspect <file.parquet> [--rows N]
          parqueter --version

        csv options:
          --schema <file>          Use this schema (JSON) instead of inferring one.
          --write-schema <file>    Save the schema that is used, so it can be reviewed and edited.
          --delimiter <c>          Field delimiter: a single character, or "tab". Default ,
          --no-header              The first row is data; columns are named column1, column2, ...
          --encoding <name>        Text encoding, e.g. utf-8 (default), windows-1252, iso-8859-1.
          --culture <name>         Culture for numbers, e.g. sv-SE where 12,5 is a decimal. Default invariant.
          --null <text>            Text that means null (besides an empty field). Can be repeated.
          --keep-empty-strings     An empty field in a string column is "" instead of null.
          --row-group-size <n>     Rows per Parquet row group. Default 100000.
          --force                  Overwrite the output file if it exists.

        Types in a schema file: string, bool, int32, int64, decimal, double, dateTime, date, guid.
        """;

    public static async Task<int> RunAsync(string[] argv)
    {
        if (argv.Length == 0) { Console.Error.WriteLine(Usage); return 2; }

        var first = argv[0];
        if (first is "--help" or "-h" or "help") { Console.WriteLine(Usage); return 0; }
        if (first is "--version") { Console.WriteLine(Version()); return 0; }

        var args = Args.Parse(argv.Skip(1).ToArray());
        if (args.Has("help")) { Console.WriteLine(Usage); return 0; }

        switch (first)
        {
            case "csv": return await CsvAsync(args);
            case "inspect": return await InspectAsync(args);
            default: throw new CliException($"Unknown command '{first}'. Try: parqueter --help", 2);
        }
    }

    static string Version() =>
        typeof(Cli).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "unknown";

    static async Task<int> InspectAsync(Args a)
    {
        a.AllowOnly("rows");
        if (a.Positional.Count != 1) throw new CliException("Usage: parqueter inspect <file.parquet> [--rows N]", 2);
        var rows = a.Get("rows") is { } r ? ParseInt(r, "--rows") : 10;
        await ParquetInspect.RunAsync(a.Positional[0], rows, Console.Out);
        return 0;
    }

    static async Task<int> CsvAsync(Args a)
    {
        a.AllowOnly("schema", "write-schema", "delimiter", "no-header", "encoding", "culture", "null",
                    "keep-empty-strings", "row-group-size", "force");
        if (a.Positional.Count != 2) throw new CliException("Usage: parqueter csv <input.csv> <output.parquet> [options]", 2);
        var input = a.Positional[0];
        var output = a.Positional[1];

        if (!File.Exists(input)) throw new CliException($"The input file {input} does not exist.");
        if (File.Exists(output) && !a.Has("force")) throw new CliException($"The output file {output} exists. Use --force to overwrite it.");

        var options = new CsvOptions
        {
            Delimiter = ParseDelimiter(a.Get("delimiter")),
            HasHeader = !a.Has("no-header"),
            Encoding = ParseEncoding(a.Get("encoding")),
            Parse = new ParseOptions
            {
                Culture = ParseCulture(a.Get("culture")),
                NullTokens = new HashSet<string>(a.GetAll("null"), StringComparer.Ordinal),
                KeepEmptyStrings = a.Has("keep-empty-strings"),
            },
        };
        var groupSize = a.Get("row-group-size") is { } g ? ParseInt(g, "--row-group-size") : 100_000;
        if (groupSize < 1) throw new CliException("--row-group-size must be at least 1.", 2);

        var inferred = a.Get("schema") is null;
        var schema = inferred ? CsvTable.Infer(input, options) : TableSchema.Load(a.Get("schema")!);
        if (a.Get("write-schema") is { } schemaPath) schema.Save(schemaPath);

        var rows = await ParquetOut.WriteAsync(output, schema, CsvTable.ReadRows(input, schema, options), groupSize);

        Console.WriteLine($"{(inferred ? "inferred" : "used")} schema:");
        foreach (var c in schema.Columns)
            Console.WriteLine($"  {c.Name,-16} {TypeName(c),-18} {(c.Nullable ? "nullable" : "not null")}");
        Console.WriteLine($"wrote {rows} rows to {output}");
        return 0;
    }

    static string TypeName(Column c) => c.Type == ColumnType.Decimal ? $"decimal({c.Precision ?? 38},{c.Scale ?? 0})" : c.Type.ToString().ToLowerInvariant();

    static int ParseInt(string text, string option) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : throw new CliException($"{option} needs a number, not '{text}'.", 2);

    static char ParseDelimiter(string? text) => text switch
    {
        null => ',',
        "tab" or "\\t" => '\t',
        { Length: 1 } => text[0],
        _ => throw new CliException($"--delimiter must be one character or 'tab', not '{text}'.", 2),
    };

    static Encoding ParseEncoding(string? name)
    {
        if (name is null) return new UTF8Encoding(false);
        try { return Encoding.GetEncoding(name); }
        catch (ArgumentException) { throw new CliException($"Unknown encoding '{name}'.", 2); }
    }

    static CultureInfo ParseCulture(string? name)
    {
        if (name is null) return CultureInfo.InvariantCulture;
        try { return CultureInfo.GetCultureInfo(name); }
        catch (CultureNotFoundException) { throw new CliException($"Unknown culture '{name}'.", 2); }
    }
}
