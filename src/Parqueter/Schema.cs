using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parqueter;

/// <summary>The data types parqueter understands, independent of any source or of Parquet.</summary>
public enum ColumnType { String, Bool, Int32, Int64, Decimal, Double, DateTime, Date, Guid }

public sealed class Column
{
    public required string Name { get; init; }
    public required ColumnType Type { get; init; }

    /// <summary>Whether the column may contain nulls. Defaults to true, the safe choice.</summary>
    public bool Nullable { get; init; } = true;

    /// <summary>Decimal only: total number of digits (default 38).</summary>
    public int? Precision { get; init; }

    /// <summary>Decimal only: digits after the decimal point (default 0).</summary>
    public int? Scale { get; init; }

    /// <summary>Date and DateTime only: an exact .NET format string such as "dd/MM/yyyy". Default is ISO 8601.</summary>
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

    public static TableSchema Load(string path)
    {
        TableSchema? schema;
        try
        {
            schema = JsonSerializer.Deserialize<TableSchema>(File.ReadAllText(path), JsonOptions);
        }
        catch (JsonException e)
        {
            throw new FormatException($"Schema file {path} is not valid: {e.Message}");
        }
        if (schema is null) throw new FormatException($"Schema file {path} is empty.");
        schema.Validate(path);
        return schema;
    }

    public void Save(string path) => File.WriteAllText(path, JsonSerializer.Serialize(this, JsonOptions) + Environment.NewLine);

    void Validate(string source)
    {
        if (Columns.Count == 0) throw new FormatException($"Schema {source} has no columns.");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var c in Columns)
        {
            if (string.IsNullOrWhiteSpace(c.Name)) throw new FormatException($"Schema {source} has a column without a name.");
            if (!seen.Add(c.Name)) throw new FormatException($"Schema {source} has the column '{c.Name}' twice.");
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
