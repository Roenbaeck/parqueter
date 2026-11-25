using System.Globalization;
using System.Text;

namespace Parqueter;

public sealed class CsvOptions
{
    public char Delimiter { get; init; } = ',';
    public bool HasHeader { get; init; } = true;
    public Encoding Encoding { get; init; } = new UTF8Encoding(false);
    public required ParseOptions Parse { get; init; }
}

/// <summary>Minimal RFC 4180 reader: quoted fields, "" as an escaped quote, line breaks inside quotes, CRLF or LF.</summary>
sealed class CsvParser
{
    readonly TextReader _reader;
    readonly char _delimiter;
    readonly char[] _buffer = new char[64 * 1024];
    int _pos, _len;
    long _line = 1;

    public CsvParser(TextReader reader, char delimiter)
    {
        _reader = reader;
        _delimiter = delimiter;
    }

    /// <summary>The line number (1-based) on which the most recently read record started.</summary>
    public long StartLine { get; private set; }

    int Peek()
    {
        if (_pos >= _len && !Fill()) return -1;
        return _buffer[_pos];
    }

    int Next()
    {
        if (_pos >= _len && !Fill()) return -1;
        return _buffer[_pos++];
    }

    bool Fill()
    {
        _len = _reader.Read(_buffer, 0, _buffer.Length);
        _pos = 0;
        return _len > 0;
    }

    public bool Read(List<string> fields)
    {
        fields.Clear();
        if (Peek() < 0) return false;
        StartLine = _line;

        var field = new StringBuilder();
        var inQuotes = false;
        var atFieldStart = true;

        while (true)
        {
            var c = Next();
            if (c < 0)
            {
                if (inQuotes) throw new FormatException($"line {StartLine}: a quoted field is never closed");
                fields.Add(field.ToString());
                return true;
            }

            if (inQuotes)
            {
                if (c == '"')
                {
                    if (Peek() == '"') { Next(); field.Append('"'); }
                    else inQuotes = false;
                }
                else
                {
                    if (c == '\n') _line++;
                    field.Append((char)c);
                }
                continue;
            }

            if (c == '"' && atFieldStart) { inQuotes = true; atFieldStart = false; continue; }
            if (c == _delimiter) { fields.Add(field.ToString()); field.Clear(); atFieldStart = true; continue; }
            if (c == '\r') { if (Peek() == '\n') Next(); c = '\n'; }
            if (c == '\n') { _line++; fields.Add(field.ToString()); return true; }

            atFieldStart = false;
            field.Append((char)c);
        }
    }
}

public static class CsvTable
{
    static StreamReader Open(string path, CsvOptions o) =>
        new(path, o.Encoding, detectEncodingFromByteOrderMarks: true, bufferSize: 64 * 1024);

    static bool IsBlank(List<string> fields) => fields.Count == 1 && fields[0].Length == 0;

    /// <summary>Reads the whole file once to decide a type and nullability for every column.</summary>
    public static TableSchema Infer(string path, CsvOptions o)
    {
        using var reader = Open(path, o);
        var parser = new CsvParser(reader, o.Delimiter);
        var fields = new List<string>();

        string[]? names = null;
        Probe[]? probes = null;

        while (parser.Read(fields))
        {
            if (IsBlank(fields)) continue;

            if (names is null)
            {
                names = o.HasHeader ? HeaderNames(fields, path) : Enumerable.Range(1, fields.Count).Select(i => $"column{i}").ToArray();
                probes = names.Select(_ => new Probe()).ToArray();
                if (o.HasHeader) continue;
            }

            if (fields.Count != names.Length)
                throw new FormatException($"{path} line {parser.StartLine}: expected {names.Length} fields but found {fields.Count}");

            for (var i = 0; i < fields.Count; i++) probes![i].Add(fields[i], o.Parse);
        }

        if (names is null) throw new FormatException($"{path} is empty.");

        var columns = new List<Column>();
        for (var i = 0; i < names.Length; i++) columns.Add(probes![i].ToColumn(names[i], o.Parse));
        return new TableSchema { Columns = columns };
    }

    /// <summary>Streams the rows of the file, converted to the schema. Fails with a line and column on the first bad value.</summary>
    public static IEnumerable<object?[]> ReadRows(string path, TableSchema schema, CsvOptions o)
    {
        using var reader = Open(path, o);
        var parser = new CsvParser(reader, o.Delimiter);
        var fields = new List<string>();
        var columns = schema.Columns;
        var first = true;

        while (parser.Read(fields))
        {
            if (IsBlank(fields)) continue;

            if (first)
            {
                first = false;
                if (o.HasHeader)
                {
                    CheckHeader(HeaderNames(fields, path), schema, path);
                    continue;
                }
            }

            if (fields.Count != columns.Count)
                throw new FormatException($"{path} line {parser.StartLine}: expected {columns.Count} fields but found {fields.Count}");

            var row = new object?[columns.Count];
            for (var i = 0; i < columns.Count; i++)
            {
                var column = columns[i];
                var text = fields[i];
                if (Values.IsNull(text, column.Type, o.Parse))
                {
                    if (!column.Nullable)
                        throw new FormatException($"{path} line {parser.StartLine}, column '{column.Name}': the value is empty or null but the column is not nullable");
                    continue;
                }
                try
                {
                    row[i] = Values.Parse(column, text, o.Parse);
                }
                catch (FormatException e)
                {
                    throw new FormatException($"{path} line {parser.StartLine}, column '{column.Name}': {e.Message}");
                }
            }
            yield return row;
        }
    }

    static string[] HeaderNames(List<string> fields, string path)
    {
        var names = fields.Select(f => f.Trim()).ToArray();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var n in names)
        {
            if (n.Length == 0) throw new FormatException($"{path}: the header has an empty column name");
            if (!seen.Add(n)) throw new FormatException($"{path}: the header has the column '{n}' twice");
        }
        return names;
    }

    static void CheckHeader(string[] header, TableSchema schema, string path)
    {
        var expected = schema.Columns.Select(c => c.Name).ToArray();
        if (header.SequenceEqual(expected, StringComparer.Ordinal)) return;
        throw new FormatException(
            $"{path}: the header does not match the schema.\n  header: {string.Join(", ", header)}\n  schema: {string.Join(", ", expected)}");
    }

    /// <summary>What a column looks like so far while scanning the file.</summary>
    sealed class Probe
    {
        bool _any, _sawEmpty, _sawToken;
        bool _bool = true, _int32 = true, _int64 = true, _decimal = true, _date = true, _dateTime = true, _guid = true;
        int _maxScale, _maxIntegerDigits;

        public void Add(string text, ParseOptions o)
        {
            if (text.Length == 0) { _sawEmpty = true; return; }
            if (o.NullTokens.Contains(text)) { _sawToken = true; return; }
            _any = true;

            if (_bool && !(text.Equals("true", StringComparison.OrdinalIgnoreCase) || text.Equals("false", StringComparison.OrdinalIgnoreCase)))
                _bool = false;

            if (_int32 || _int64 || _decimal)
            {
                if (LooksLikeText(text)) _int32 = _int64 = _decimal = false;
                else
                {
                    const NumberStyles integer = NumberStyles.AllowLeadingSign;
                    const NumberStyles number = NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint;
                    if (_int32 && !int.TryParse(text, integer, o.Culture, out _)) _int32 = false;
                    if (_int64 && !long.TryParse(text, integer, o.Culture, out _)) _int64 = false;
                    if (_decimal)
                    {
                        if (decimal.TryParse(text, number, o.Culture, out var d))
                        {
                            _maxScale = Math.Max(_maxScale, Values.ScaleOf(d));
                            _maxIntegerDigits = Math.Max(_maxIntegerDigits, Values.IntegerDigitsOf(d));
                        }
                        else _decimal = false;
                    }
                }
            }

            if (_date && !Values.TryParseIsoDate(text, out _)) _date = false;
            if (_dateTime && !Values.TryParseIsoDateTime(text, out _)) _dateTime = false;
            if (_guid && !Values.TryParseGuid(text, out _)) _guid = false;
        }

        // Values like 01234 (zip codes), +46701234567 (phone numbers) are identifiers, not numbers.
        static bool LooksLikeText(string s) =>
            s[0] == '+'
            || (s.Length > 1 && s[0] == '0' && char.IsDigit(s[1]))
            || (s.Length > 2 && s[0] == '-' && s[1] == '0' && char.IsDigit(s[2]));

        public Column ToColumn(string name, ParseOptions o)
        {
            ColumnType type;
            int? precision = null, scale = null;

            if (!_any) type = ColumnType.String;
            else if (_bool) type = ColumnType.Bool;
            else if (_int32) type = ColumnType.Int32;
            else if (_int64) type = ColumnType.Int64;
            else if (_decimal && _maxIntegerDigits + _maxScale <= 38) { type = ColumnType.Decimal; precision = 38; scale = _maxScale; }
            else if (_date) type = ColumnType.Date;
            else if (_dateTime) type = ColumnType.DateTime;
            else if (_guid) type = ColumnType.Guid;
            else type = ColumnType.String;

            var emptyIsNull = !(type == ColumnType.String && o.KeepEmptyStrings);
            return new Column
            {
                Name = name,
                Type = type,
                Nullable = _sawToken || (_sawEmpty && emptyIsNull),
                Precision = precision,
                Scale = scale,
            };
        }
    }
}
