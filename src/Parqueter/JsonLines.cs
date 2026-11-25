using System.Text;
using System.Text.Json;

namespace Parqueter;

/// <summary>
/// JSON Lines input: one JSON value per line. Unless a schema file is given, the first line is the schema
/// (the same JSON as a schema file). Every other line is a row, either an array in column order or an object
/// keyed by column name. Meant to be piped in by a script that already knows the types, e.g. from a database reader.
/// </summary>
public sealed class JsonLinesReader : IDisposable
{
    static readonly ParseOptions Invariant = new();

    readonly TextReader _reader;
    readonly string _source;

    public JsonLinesReader(string path, Encoding encoding)
    {
        _source = path == "-" ? "stdin" : path;
        _reader = path == "-"
            ? new StreamReader(Console.OpenStandardInput(), encoding, detectEncodingFromByteOrderMarks: true, bufferSize: 64 * 1024)
            : new StreamReader(path, encoding, detectEncodingFromByteOrderMarks: true, bufferSize: 64 * 1024);
    }

    public long LineNumber { get; private set; }

    string? NextLine()
    {
        string? line;
        while ((line = _reader.ReadLine()) is not null)
        {
            LineNumber++;
            if (line.AsSpan().Trim().Length > 0) return line;
        }
        return null;
    }

    public TableSchema ReadSchema()
    {
        var line = NextLine() ?? throw new FormatException($"{_source} is empty: expected a schema on the first line.");
        return TableSchema.Parse(line, $"{_source} line {LineNumber}");
    }

    public IEnumerable<object?[]> ReadRows(TableSchema schema)
    {
        var columns = schema.Columns;
        var index = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < columns.Count; i++) index[columns[i].Name] = i;

        string? line;
        while ((line = NextLine()) is not null)
        {
            JsonDocument doc;
            try { doc = JsonDocument.Parse(line); }
            catch (JsonException e) { throw new FormatException($"{_source} line {LineNumber}: not valid JSON ({e.Message})"); }

            using (doc)
            {
                var root = doc.RootElement;
                var row = new object?[columns.Count];

                if (root.ValueKind == JsonValueKind.Array)
                {
                    if (root.GetArrayLength() != columns.Count)
                        throw new FormatException($"{_source} line {LineNumber}: expected {columns.Count} values but found {root.GetArrayLength()}");
                    var i = 0;
                    foreach (var element in root.EnumerateArray())
                    {
                        row[i] = Convert(columns[i], element);
                        i++;
                    }
                }
                else if (root.ValueKind == JsonValueKind.Object)
                {
                    var seen = new bool[columns.Count];
                    foreach (var property in root.EnumerateObject())
                    {
                        if (!index.TryGetValue(property.Name, out var i))
                            throw new FormatException($"{_source} line {LineNumber}: '{property.Name}' is not a column in the schema");
                        seen[i] = true;
                        row[i] = Convert(columns[i], property.Value);
                    }
                    for (var i = 0; i < columns.Count; i++)
                        if (!seen[i]) row[i] = Convert(columns[i], default); // a missing key is null
                }
                else
                {
                    throw new FormatException($"{_source} line {LineNumber}: a row must be a JSON array or object");
                }
                yield return row;
            }
        }
    }

    object? Convert(Column column, JsonElement element)
    {
        if (element.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            if (!column.Nullable)
                throw new FormatException($"{_source} line {LineNumber}, column '{column.Name}': the value is null but the column is not nullable");
            return null;
        }

        var text = element.ValueKind switch
        {
            JsonValueKind.String => element.GetString()!,
            JsonValueKind.Number => element.GetRawText(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => throw new FormatException($"{_source} line {LineNumber}, column '{column.Name}': expected a simple value, not {element.ValueKind}"),
        };

        try
        {
            // Numbers arrive as their exact text, so a decimal is never squeezed through a double.
            return Values.Parse(column, text, Invariant);
        }
        catch (FormatException e)
        {
            throw new FormatException($"{_source} line {LineNumber}, column '{column.Name}': {e.Message}");
        }
    }

    public void Dispose() => _reader.Dispose();
}
