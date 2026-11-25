using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

namespace Parqueter;

sealed class CliException(string message, int exitCode = 1) : Exception(message)
{
    public int ExitCode { get; } = exitCode;
}

/// <summary>--name value options (repeatable), --flag switches and positional arguments.</summary>
sealed class Args
{
    static readonly HashSet<string> Flags = new() { "no-header", "keep-empty-strings", "force", "help", "stats", "ascii-names" };

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
          parqueter jsonl <input.jsonl | -> <output.parquet> [options]
          parqueter inspect <file.parquet> [--rows N] [--stats]
          parqueter --version

        inspect shows the schema (with required/optional), the first N rows (default 10, 0 for none) and,
        with --stats, the null count, minimum, maximum and sum of every column, read one row group at a time.

        csv options:
          --schema <file>          Use this schema (JSON) instead of inferring one.
          --write-schema <file>    Save the schema that is used, so it can be reviewed and edited.
          --delimiter <text>       What separates fields. Default ,  Can be a character, a word (tab, comma,
                                   semicolon, pipe), a character code (0x1F, \x1F, U+001F) or several
                                   characters such as ^;
          --quote <c|none>         The quote character (default "), or none if fields are never quoted.
          --row-delimiter <text>   What ends a row: crlf, lf, cr or any text. By default any line break does.
                                   Give it when text fields contain line breaks: only this exact text ends a row.
          --no-header              The first row is data; columns are named column1, column2, ...
          --ascii-names            Make column names plain ASCII (letters, digits, _): A-ring and A-diaeresis
                                   become A, O-diaeresis O, spaces and dashes _. Snowflake and most databases
                                   then need no quoting. The original name is kept as "source" in the schema.
          --encoding <name>        Text encoding, e.g. utf-8 (default), windows-1252, iso-8859-1.
          --culture <name>         Culture for numbers, e.g. sv-SE where 12,5 is a decimal. Default invariant.
          --null <text>            Text that means null (besides an empty field). Can be repeated.
          --keep-empty-strings     An empty field in a string column is "" instead of null.
          --row-group-size <n>     Rows per Parquet row group. Default 100000.
          --force                  Overwrite the output file if it exists.

        jsonl options (input "-" is stdin, so a script can pipe rows in):
          The first line is the schema, the same JSON as a schema file, unless --schema is given.
          Every other line is a row: a JSON array in column order, or an object keyed by column name.
          --schema <file>, --write-schema <file>, --encoding <name>, --row-group-size <n>, --force

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
            case "jsonl": return await JsonlAsync(args);
            case "inspect": return await InspectAsync(args);
            default: throw new CliException($"Unknown command '{first}'. Try: parqueter --help", 2);
        }
    }

    static string Version() =>
        typeof(Cli).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "unknown";

    static async Task<int> InspectAsync(Args a)
    {
        a.AllowOnly("rows", "stats");
        if (a.Positional.Count != 1) throw new CliException("Usage: parqueter inspect <file.parquet> [--rows N] [--stats]", 2);
        var rows = a.Get("rows") is { } r ? ParseInt(r, "--rows") : 10;
        await ParquetInspect.RunAsync(a.Positional[0], rows, a.Has("stats"), Console.Out);
        return 0;
    }

    static async Task<int> CsvAsync(Args a)
    {
        a.AllowOnly("schema", "write-schema", "delimiter", "quote", "row-delimiter", "no-header", "ascii-names", "encoding", "culture", "null",
                    "keep-empty-strings", "row-group-size", "force");
        if (a.Positional.Count != 2) throw new CliException("Usage: parqueter csv <input.csv> <output.parquet> [options]", 2);
        var input = a.Positional[0];
        var output = a.Positional[1];

        if (!File.Exists(input)) throw new CliException($"The input file {input} does not exist.");
        CheckOutput(output, a);

        var options = new CsvOptions
        {
            Delimiter = ParseDelimiter(a.Get("delimiter")),
            Quote = ParseQuote(a.Get("quote")),
            RowDelimiter = ParseRowDelimiter(a.Get("row-delimiter")),
            HasHeader = !a.Has("no-header"),
            AsciiNames = a.Has("ascii-names"),
            Encoding = ParseEncoding(a.Get("encoding")),
            Parse = new ParseOptions
            {
                Culture = ParseCulture(a.Get("culture")),
                NullTokens = new HashSet<string>(a.GetAll("null"), StringComparer.Ordinal),
                KeepEmptyStrings = a.Has("keep-empty-strings"),
            },
        };
        var groupSize = RowGroupSize(a);

        var inferred = a.Get("schema") is null;
        var schema = inferred ? CsvTable.Infer(input, options) : TableSchema.Load(a.Get("schema")!);
        if (a.Get("write-schema") is { } schemaPath) schema.Save(schemaPath);

        var rows = await ParquetOut.WriteAsync(output, schema, CsvTable.ReadRows(input, schema, options), groupSize);
        Report(schema, inferred ? "inferred" : "used", rows, output);
        return 0;
    }

    static async Task<int> JsonlAsync(Args a)
    {
        a.AllowOnly("schema", "write-schema", "encoding", "row-group-size", "force");
        if (a.Positional.Count != 2) throw new CliException("Usage: parqueter jsonl <input.jsonl | -> <output.parquet> [options]", 2);
        var input = a.Positional[0];
        var output = a.Positional[1];

        if (input != "-" && !File.Exists(input)) throw new CliException($"The input file {input} does not exist.");
        CheckOutput(output, a);
        var groupSize = RowGroupSize(a);

        using var reader = new JsonLinesReader(input, ParseEncoding(a.Get("encoding")));
        var fromStream = a.Get("schema") is null;
        var schema = fromStream ? reader.ReadSchema() : TableSchema.Load(a.Get("schema")!);
        if (a.Get("write-schema") is { } schemaPath) schema.Save(schemaPath);

        var rows = await ParquetOut.WriteAsync(output, schema, reader.ReadRows(schema), groupSize);
        Report(schema, fromStream ? "schema from the input" : "schema from file", rows, output);
        return 0;
    }

    static void CheckOutput(string output, Args a)
    {
        if (File.Exists(output) && !a.Has("force")) throw new CliException($"The output file {output} exists. Use --force to overwrite it.");
    }

    static int RowGroupSize(Args a)
    {
        var size = a.Get("row-group-size") is { } g ? ParseInt(g, "--row-group-size") : 100_000;
        if (size < 1) throw new CliException("--row-group-size must be at least 1.", 2);
        return size;
    }

    static void Report(TableSchema schema, string how, long rows, string output)
    {
        Console.WriteLine($"{how}:");
        foreach (var c in schema.Columns)
            Console.WriteLine($"  {c.Name,-16} {TypeName(c),-18} {(c.Nullable ? "nullable" : "not null")}");
        Console.WriteLine($"wrote {rows} rows to {output}");
    }

    static string TypeName(Column c) => c.Type == ColumnType.Decimal ? $"decimal({c.Precision ?? 38},{c.Scale ?? 0})" : c.Type.ToString().ToLowerInvariant();

    static int ParseInt(string text, string option) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : throw new CliException($"{option} needs a number, not '{text}'.", 2);

    static readonly Regex CharCode = new(@"^(?:0x|\\x|U\+)([0-9A-Fa-f]{1,4})$", RegexOptions.Compiled);

    static string ParseDelimiter(string? text)
    {
        if (string.IsNullOrEmpty(text)) return text is null ? "," : throw new CliException("--delimiter cannot be empty.", 2);
        switch (text.ToLowerInvariant())
        {
            case "tab": case "\\t": return "\t";
            case "comma": return ",";
            case "semicolon": return ";";
            case "pipe": return "|";
        }
        var code = CharCode.Match(text);
        if (code.Success) return ((char)Convert.ToInt32(code.Groups[1].Value, 16)).ToString();
        return text; // one or more literal characters
    }

    static string? ParseRowDelimiter(string? text)
    {
        if (text is null) return null;
        return text.ToLowerInvariant() switch
        {
            "crlf" or "\\r\\n" => "\r\n",
            "lf" or "\\n" => "\n",
            "cr" or "\\r" => "\r",
            _ => ParseDelimiter(text),
        };
    }

    static char? ParseQuote(string? text) => text switch
    {
        null => '"',
        "none" => null,
        { Length: 1 } => text[0],
        _ => throw new CliException($"--quote must be one character or 'none', not '{text}'.", 2),
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
