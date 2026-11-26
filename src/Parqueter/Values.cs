using System.Globalization;

namespace Parqueter;

public sealed class ParseOptions
{
    /// <summary>Culture for numbers (and for date formats given in the schema). ISO dates always use the invariant culture.</summary>
    public CultureInfo Culture { get; init; } = CultureInfo.InvariantCulture;

    /// <summary>
    /// Number formatting of <see cref="Culture"/>, except that the minus sign is always the ordinary '-'.
    /// Some cultures (sv-SE for one) use the Unicode minus U+2212, which no data file ever contains.
    /// </summary>
    public NumberFormatInfo Numbers => _numbers ??= MakeNumbers();
    NumberFormatInfo? _numbers;

    NumberFormatInfo MakeNumbers()
    {
        var n = (NumberFormatInfo)Culture.NumberFormat.Clone();
        n.NegativeSign = "-";
        return n;
    }

    /// <summary>Text values that mean null, in addition to the empty string.</summary>
    public IReadOnlySet<string> NullTokens { get; init; } = new HashSet<string>();

    /// <summary>If true, an empty field in a string column is an empty string instead of null.</summary>
    public bool KeepEmptyStrings { get; init; }
}

public static class Values
{
    const NumberStyles IntegerStyle = NumberStyles.AllowLeadingSign;
    const NumberStyles DecimalStyle = NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint;

    // K accepts "Z", an offset such as +02:00, or nothing at all.
    static readonly string[] IsoDateTimeFormats =
    {
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK", "yyyy-MM-dd'T'HH:mm:ssK", "yyyy-MM-dd'T'HH:mmK",
        "yyyy-MM-dd HH:mm:ss.FFFFFFFK",   "yyyy-MM-dd HH:mm:ssK",   "yyyy-MM-dd HH:mmK",
    };

    public static bool IsNull(string text, ColumnType type, ParseOptions o)
    {
        if (text.Length == 0) return !(type == ColumnType.String && o.KeepEmptyStrings);
        return o.NullTokens.Contains(text);
    }

    // A time of day: hours and minutes, optional seconds, optional fraction of a second.
    static readonly string[] IsoTimeFormats =
    {
        @"h\:mm", @"hh\:mm", @"h\:mm\:ss", @"hh\:mm\:ss", @"h\:mm\:ss\.FFFFFFF", @"hh\:mm\:ss\.FFFFFFF",
    };

    /// <summary>A time of day is at least 00:00:00 and less than 24:00:00 (a longer span is a duration, not a time).</summary>
    public static bool IsTimeOfDay(TimeSpan t) => t >= TimeSpan.Zero && t < TimeSpan.FromDays(1);

    public static bool TryParseIsoTime(string s, out TimeSpan value) =>
        TimeSpan.TryParseExact(s, IsoTimeFormats, CultureInfo.InvariantCulture, TimeSpanStyles.None, out value) && IsTimeOfDay(value);

    public static bool TryParseIsoDate(string s, out DateOnly value) =>
        DateOnly.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out value);

    /// <summary>
    /// Parses ISO 8601. A value with an offset or Z is converted to UTC; a value without is kept as written.
    /// The result has Kind Unspecified: parqueter writes timestamps that are not adjusted to UTC.
    /// </summary>
    public static bool TryParseIsoDateTime(string s, out DateTime value)
    {
        const DateTimeStyles styles = DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal;
        if (!DateTime.TryParseExact(s, IsoDateTimeFormats, CultureInfo.InvariantCulture, styles, out value)) return false;
        value = DateTime.SpecifyKind(value, DateTimeKind.Unspecified);
        return true;
    }

    public static bool TryParseGuid(string s, out Guid value) => Guid.TryParseExact(s, "D", out value);

    public static int ScaleOf(decimal d) => (decimal.GetBits(d)[3] >> 16) & 0xFF;

    public static int IntegerDigitsOf(decimal d) => d.ToString("F0", CultureInfo.InvariantCulture).TrimStart('-').Length;

    /// <summary>Converts a non-null text value to the CLR type of the column. Throws FormatException if it does not fit.</summary>
    public static object Parse(Column c, string s, ParseOptions o)
    {
        switch (c.Type)
        {
            case ColumnType.String:
                return s;

            case ColumnType.Bool:
                if (s.Equals("true", StringComparison.OrdinalIgnoreCase) || s == "1") return true;
                if (s.Equals("false", StringComparison.OrdinalIgnoreCase) || s == "0") return false;
                throw Bad(s, "a boolean (true/false/1/0)");

            case ColumnType.Int32:
                if (int.TryParse(s, IntegerStyle, o.Numbers, out var i32)) return i32;
                throw Bad(s, "a 32-bit integer");

            case ColumnType.Int64:
                if (long.TryParse(s, IntegerStyle, o.Numbers, out var i64)) return i64;
                throw Bad(s, "a 64-bit integer");

            case ColumnType.Decimal:
            {
                if (!decimal.TryParse(s, DecimalStyle, o.Numbers, out var d)) throw Bad(s, "a decimal number");
                var precision = c.Precision ?? 38;
                var scale = c.Scale ?? 0;
                if (decimal.Round(d, scale) != d) throw new FormatException($"'{s}' has more than {scale} decimals");
                if (IntegerDigitsOf(d) > precision - scale) throw new FormatException($"'{s}' has more than {precision - scale} digits before the decimal point");
                return d;
            }

            case ColumnType.Double:
                if (double.TryParse(s, NumberStyles.Float, o.Numbers, out var dbl)) return dbl;
                throw Bad(s, "a floating point number");

            case ColumnType.Date:
            {
                var ok = c.Format is null
                    ? TryParseIsoDate(s, out var date)
                    : DateOnly.TryParseExact(s, c.Format, o.Culture, DateTimeStyles.None, out date);
                if (ok) return date;
                throw Bad(s, c.Format is null ? "a date (yyyy-MM-dd)" : $"a date in the format {c.Format}");
            }

            case ColumnType.DateTime:
            {
                DateTime dt;
                var ok = c.Format is null
                    ? TryParseIsoDateTime(s, out dt)
                    : DateTime.TryParseExact(s, c.Format, o.Culture, DateTimeStyles.None, out dt);
                if (ok) return DateTime.SpecifyKind(dt, DateTimeKind.Unspecified);
                throw Bad(s, c.Format is null ? "an ISO 8601 date and time" : $"a date and time in the format {c.Format}");
            }

            case ColumnType.Time:
            {
                TimeSpan t;
                var ok = c.Format is null
                    ? TryParseIsoTime(s, out t)
                    : TimeSpan.TryParseExact(s, c.Format, o.Culture, TimeSpanStyles.None, out t) && IsTimeOfDay(t);
                if (ok) return t;
                throw Bad(s, c.Format is null ? "a time of day (HH:mm:ss or HH:mm:ss.ffffff, less than 24 hours)" : $"a time of day in the format {c.Format}");
            }

            case ColumnType.Guid:
                if (TryParseGuid(s, out var g)) return g;
                throw Bad(s, "a GUID");

            default:
                throw new InvalidOperationException($"Unhandled column type {c.Type}");
        }
    }

    static FormatException Bad(string s, string expected) => new($"'{Shorten(s)}' is not {expected}");

    static string Shorten(string s) => s.Length <= 40 ? s : s[..37] + "...";
}
