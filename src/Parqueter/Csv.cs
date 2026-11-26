using System.Globalization;
using System.Text;

namespace Parqueter;

public sealed class CsvOptions
{
    /// <summary>The text between fields: usually one character, but may be several (such as "^;").</summary>
    public string Delimiter { get; init; } = ",";

    /// <summary>The quote character, or null if fields are never quoted (what SSIS writes without a text qualifier).</summary>
    public char? Quote { get; init; } = '"';

    /// <summary>
    /// What ends a row. Null means any of LF, CRLF or CR. If given (for example "\r\n"), a record ends only at exactly
    /// that text, and any other line break is part of the data: this is how SSIS reads a flat file whose text fields
    /// contain line breaks.
    /// </summary>
    public string? RowDelimiter { get; init; }

    public bool HasHeader { get; init; } = true;

    /// <summary>Turn header names into plain ASCII identifiers (see <see cref="CsvTable.ToAsciiName"/>).</summary>
    public bool AsciiNames { get; init; }
    public Encoding Encoding { get; init; } = new UTF8Encoding(false);
    public required ParseOptions Parse { get; init; }
}

/// <summary>Minimal RFC 4180 reader: quoted fields, "" as an escaped quote, line breaks inside quotes, CRLF or LF.</summary>
sealed class CsvParser
{
    readonly TextReader _reader;
    readonly string _delimiter;
    readonly string? _rowDelimiter; // null: LF, CRLF or CR
    readonly int _quote; // -1: no quoting
    readonly char[] _buffer = new char[64 * 1024];
    int _pos, _len;
    long _line = 1;

    public CsvParser(TextReader reader, string delimiter, char? quote, string? rowDelimiter = null)
    {
        _reader = reader;
        _delimiter = delimiter;
        _quote = quote ?? -1;
        _rowDelimiter = rowDelimiter;
    }

    /// <summary>The first character of <paramref name="text"/> has just been read: does the rest of it follow?</summary>
    bool MatchRestOf(string text)
    {
        var need = text.Length - 1;
        if (need == 0) return true;
        if (_len - _pos < need)
        {
            // Move what is left to the front of the buffer and read more, so the look-ahead never loses characters.
            var remaining = _len - _pos;
            Array.Copy(_buffer, _pos, _buffer, 0, remaining);
            _pos = 0;
            _len = remaining;
            while (_len < need)
            {
                var n = _reader.Read(_buffer, _len, _buffer.Length - _len);
                if (n <= 0) break;
                _len += n;
            }
            if (_len < need) return false;
        }
        for (var i = 0; i < need; i++)
            if (_buffer[_pos + i] != text[i + 1]) return false;
        _pos += need;
        return true;
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
                if (c == _quote)
                {
                    if (Peek() == _quote) { Next(); field.Append((char)_quote); }
                    else inQuotes = false;
                }
                else
                {
                    if (c == '\n') _line++;
                    field.Append((char)c);
                }
                continue;
            }

            if (c == _quote && atFieldStart) { inQuotes = true; atFieldStart = false; continue; }
            if (c == _delimiter[0] && MatchRestOf(_delimiter)) { fields.Add(field.ToString()); field.Clear(); atFieldStart = true; continue; }

            if (_rowDelimiter is null)
            {
                if (c == '\r') { if (Peek() == '\n') Next(); c = '\n'; }
                if (c == '\n') { _line++; fields.Add(field.ToString()); return true; }
            }
            else if (c == _rowDelimiter[0] && MatchRestOf(_rowDelimiter))
            {
                _line += _rowDelimiter.Count(ch => ch == '\n');
                fields.Add(field.ToString());
                return true;
            }
            else if (c == '\n')
            {
                _line++; // a line break that is data, not a row delimiter
            }

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
        var parser = new CsvParser(reader, o.Delimiter, o.Quote, o.RowDelimiter);
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
        var used = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < names.Length; i++)
        {
            var name = o.AsciiNames ? ToAsciiName(names[i]) : names[i];
            if (used.TryGetValue(name, out var other))
                throw new FormatException($"{path}: the columns '{other}' and '{names[i]}' both become '{name}' with --ascii-names. Rename one of them in a schema file.");
            used[name] = names[i];
            columns.Add(probes![i].ToColumn(name, names[i] == name ? null : names[i], o.Parse));
        }
        return new TableSchema { Columns = columns };
    }

    /// <summary>
    /// A name made of letters, digits and underscores only, so it needs no quoting in Snowflake or most other databases:
    /// accents are removed (Å, Ä become A; Ö becomes O; é becomes e), ß becomes ss, and any other character,
    /// such as a space or a dash, becomes an underscore. A name that would start with a digit gets a leading underscore.
    /// </summary>
    public static string ToAsciiName(string name)
    {
        var result = new StringBuilder();
        foreach (var ch in name.Normalize(NormalizationForm.FormD))
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.NonSpacingMark) continue; // the ring or dots of Å, Ä, Ö
            switch (ch)
            {
                case 'ß': result.Append("ss"); continue;
                case 'Æ': result.Append("AE"); continue;
                case 'æ': result.Append("ae"); continue;
                case 'Ø': result.Append('O'); continue;
                case 'ø': result.Append('o'); continue;
            }
            if (ch < 128 && (char.IsLetterOrDigit(ch) || ch == '_')) result.Append(ch);
            else if (result.Length == 0 || result[^1] != '_') result.Append('_');
        }
        var ascii = result.ToString();
        if (ascii.Length == 0) ascii = "_";
        return char.IsDigit(ascii[0]) ? "_" + ascii : ascii;
    }

    /// <summary>Streams the rows of the file, converted to the schema. Fails with a line and column on the first bad value.</summary>
    public static IEnumerable<object?[]> ReadRows(string path, TableSchema schema, CsvOptions o)
    {
        using var reader = Open(path, o);
        var parser = new CsvParser(reader, o.Delimiter, o.Quote, o.RowDelimiter);
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
        var expected = schema.Columns.Select(c => c.Source ?? c.Name).ToArray();
        if (header.SequenceEqual(expected, StringComparer.Ordinal)) return;
        throw new FormatException(
            $"{path}: the header does not match the schema.\n  header: {string.Join(", ", header)}\n  schema: {string.Join(", ", expected)}");
    }

    /// <summary>What a column looks like so far while scanning the file.</summary>
    sealed class Probe
    {
        bool _any, _sawEmpty, _sawToken;
        bool _bool = true, _int32 = true, _int64 = true, _decimal = true, _date = true, _dateTime = true, _time = true, _guid = true;
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
                    if (_int32 && !int.TryParse(text, integer, o.Numbers, out _)) _int32 = false;
                    if (_int64 && !long.TryParse(text, integer, o.Numbers, out _)) _int64 = false;
                    if (_decimal)
                    {
                        if (decimal.TryParse(text, number, o.Numbers, out var d))
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
            if (_time && !Values.TryParseIsoTime(text, out _)) _time = false;
            if (_guid && !Values.TryParseGuid(text, out _)) _guid = false;
        }

        // Values like 01234 (zip codes), +46701234567 (phone numbers) are identifiers, not numbers.
        static bool LooksLikeText(string s) =>
            s[0] == '+'
            || (s.Length > 1 && s[0] == '0' && char.IsDigit(s[1]))
            || (s.Length > 2 && s[0] == '-' && s[1] == '0' && char.IsDigit(s[2]));

        public Column ToColumn(string name, string? source, ParseOptions o)
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
            else if (_time) type = ColumnType.Time;
            else if (_guid) type = ColumnType.Guid;
            else type = ColumnType.String;

            var emptyIsNull = !(type == ColumnType.String && o.KeepEmptyStrings);
            return new Column
            {
                Name = name,
                Source = source,
                Type = type,
                Nullable = _sawToken || (_sawEmpty && emptyIsNull),
                Precision = precision,
                Scale = scale,
            };
        }
    }
}
