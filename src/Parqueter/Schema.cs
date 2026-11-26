using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parqueter;

/// <summary>The data types parqueter understands, independent of any source or of Parquet.</summary>
public enum ColumnType { String, Bool, Int32, Int64, Decimal, Double, DateTime, Date, Time, Guid }

public sealed class Column
{
    public required string Name { get; init; }
    public required ColumnType Type { get; init; }

    /// <summary>
    /// CSV only: the name of the column in the file's header, when it differs from <see cref="Name"/>
    /// (for example after --ascii-names, or when the schema file was edited to rename a column).
    /// </summary>
    public string? Source { get; init; }

    /// <summary>Whether the column may contain nulls. Defaults to true, the safe choice.</summary>
    public bool Nullable { get; init; } = true;

    /// <summary>Decimal only: total number of digits (default 38).</summary>
    public int? Precision { get; init; }

    /// <summary>Decimal only: digits after the decimal point (default 0).</summary>
    public int? Scale { get; init; }

    /// <summary>Date, DateTime and Time only: an exact .NET format string such as "dd/MM/yyyy" (for a time: "hh\:mm"). Default is ISO 8601.</summary>
    public string? Format { get; init; }
}

public sealed class TableSchema
{
    public required List<Column> Columns { get; init; }

    static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static TableSchema Load(string path) => Parse(File.ReadAllText(path), $"Schema file {path}");

    /// <param name="source">Where the text came from, for error messages.</param>
    public static TableSchema Parse(string json, string source)
    {
        TableSchema? schema;
        try
        {
            schema = JsonSerializer.Deserialize<TableSchema>(json, JsonOptions);
        }
        catch (JsonException e)
        {
            throw new FormatException($"{source} is not a valid schema: {e.Message}");
        }
        if (schema is null) throw new FormatException($"{source} is empty.");
        schema.Validate(source);
        return schema;
    }

    public void Save(string path) => File.WriteAllText(path, JsonSerializer.Serialize(this, JsonOptions) + Environment.NewLine);

    void Validate(string source)
    {
        if (Columns.Count == 0) throw new FormatException($"{source} has no columns.");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var c in Columns)
        {
            if (string.IsNullOrWhiteSpace(c.Name)) throw new FormatException($"{source} has a column without a name.");
            if (!seen.Add(c.Name)) throw new FormatException($"{source} has the column '{c.Name}' twice.");
            if (c.Type == ColumnType.Decimal)
            {
                var p = c.Precision ?? 38;
                var s = c.Scale ?? 0;
                if (p < 1 || p > 38) throw new FormatException($"Column '{c.Name}': precision must be 1-38.");
                if (s < 0 || s > p) throw new FormatException($"Column '{c.Name}': scale must be 0-{p}.");
            }
        }
    }
}
