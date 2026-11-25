using System.Globalization;
using Parquet;
using Parquet.Schema;

namespace Parqueter;

/// <summary>Prints what is really stored in a Parquet file: the schema with nullability, and the first rows.</summary>
public static class ParquetInspect
{
    /// <summary>Per column: how many nulls, and for numbers and dates the minimum, maximum and (numbers) the sum.</summary>
    sealed class Stat
    {
        public long Nulls, Values;
        public object? Min, Max;
        public decimal Sum;
        public double DoubleSum;
        public bool IsDouble;

        public void Add(object? v)
        {
            if (v is null) { Nulls++; return; }
            Values++;
            switch (v)
            {
                case int i: Sum += i; break;
                case long l: Sum += l; break;
                case decimal d: Sum += d; break;
                case double x: DoubleSum += x; IsDouble = true; break;
                case DateTime or DateOnly: break;
                default: return; // strings, booleans, guids: only the null count is interesting
            }
            var c = (IComparable)v;
            if (Min is null || c.CompareTo(Min) < 0) Min = v;
            if (Max is null || c.CompareTo(Max) > 0) Max = v;
        }
    }

    public static async Task RunAsync(string path, int maxRows, bool stats, TextWriter output)
    {
        await using var stream = File.OpenRead(path);
        await using var reader = await ParquetReader.CreateAsync(stream, new ParquetOptions { UseDateOnlyTypeForDates = true });
        var fields = reader.Schema.DataFields;

        long totalRows = 0;
        for (var g = 0; g < reader.RowGroupCount; g++)
        {
            using var rg = reader.OpenRowGroupReader(g);
            totalRows += rg.RowCount;
        }

        output.WriteLine($"file: {path}");
        output.WriteLine($"row groups: {reader.RowGroupCount}");
        output.WriteLine($"rows: {totalRows}");
        output.WriteLine("columns:");
        foreach (var f in fields)
            output.WriteLine($"  {f.Name,-16} {Describe(f),-18} {(f.IsNullable ? "optional" : "required")}");

        if (stats)
        {
            // One row group at a time, so this works on files far larger than memory.
            var all = fields.Select(_ => new Stat()).ToArray();
            for (var g = 0; g < reader.RowGroupCount; g++)
            {
                using var rg = reader.OpenRowGroupReader(g);
                var count = (int)rg.RowCount;
                for (var i = 0; i < fields.Length; i++)
                    foreach (var v in await ReadColumnAsync(rg, fields[i], count)) all[i].Add(v);
            }
            output.WriteLine("statistics:");
            for (var i = 0; i < fields.Length; i++)
            {
                var s = all[i];
                var line = $"  {fields[i].Name,-16} nulls={s.Nulls}";
                if (s.Min is not null)
                {
                    line += $" min={Format(s.Min)} max={Format(s.Max)}";
                    if (s.IsDouble) line += $" sum={s.DoubleSum.ToString("R", CultureInfo.InvariantCulture)}";
                    else if (s.Min is not DateTime and not DateOnly) line += $" sum={s.Sum.ToString(CultureInfo.InvariantCulture)}";
                }
                output.WriteLine(line);
            }
        }

        if (maxRows <= 0) return;
        output.WriteLine($"first {Math.Min(totalRows, maxRows)} rows:");
        var printed = 0;
        for (var g = 0; g < reader.RowGroupCount && printed < maxRows; g++)
        {
            using var rg = reader.OpenRowGroupReader(g);
            var count = (int)rg.RowCount;
            var columns = new object?[fields.Length][];
            for (var i = 0; i < fields.Length; i++)
                columns[i] = await ReadColumnAsync(rg, fields[i], count);

            for (var r = 0; r < count && printed < maxRows; r++, printed++)
                output.WriteLine("  " + string.Join(" | ", columns.Select(c => Format(c[r]))));
        }
    }

    static async Task<object?[]> ReadColumnAsync(ParquetRowGroupReader rg, DataField f, int count)
    {
        var t = f.ClrType;
        if (IsString(t))
        {
            var values = new string?[count];
            await rg.ReadAsync(f, new Memory<string?>(values));
            return values.Select(v => (object?)v).ToArray();
        }
        if (t == typeof(int)) return await ReadStructAsync<int>(rg, f, count);
        if (t == typeof(long)) return await ReadStructAsync<long>(rg, f, count);
        if (t == typeof(bool)) return await ReadStructAsync<bool>(rg, f, count);
        if (t == typeof(double)) return await ReadStructAsync<double>(rg, f, count);
        if (t == typeof(decimal)) return await ReadStructAsync<decimal>(rg, f, count);
        if (t == typeof(Guid)) return await ReadStructAsync<Guid>(rg, f, count);
        if (t == typeof(DateTime)) return await ReadStructAsync<DateTime>(rg, f, count);
        if (t == typeof(DateOnly)) return await ReadStructAsync<DateOnly>(rg, f, count);
        throw new NotSupportedException($"inspect cannot print the column '{f.Name}' of type {t.Name}");
    }

    static async Task<object?[]> ReadStructAsync<T>(ParquetRowGroupReader rg, DataField f, int count) where T : struct
    {
        if (f.IsNullable)
        {
            var values = new T?[count];
            await rg.ReadAsync<T>(f, new Memory<T?>(values));
            return values.Select(v => (object?)v).ToArray();
        }
        else
        {
            var values = new T[count];
            await rg.ReadAsync<T>(f, new Memory<T>(values));
            return values.Select(v => (object?)v).ToArray();
        }
    }

    // Parquet.Net reports a string column read from a file as ReadOnlyMemory<char>.
    static bool IsString(Type t) => t == typeof(string) || t == typeof(ReadOnlyMemory<char>);

    static string Describe(DataField f)
    {
        if (f is DecimalDataField d) return $"decimal({d.Precision},{d.Scale})";
        if (f is DateTimeDataField dt)
            return dt.DateTimeFormat == DateTimeFormat.Date ? "date" : $"datetime({dt.Unit.ToString().ToLowerInvariant()})";
        var t = f.ClrType;
        if (t == typeof(int)) return "int32";
        if (t == typeof(long)) return "int64";
        if (IsString(t)) return "string";
        if (t == typeof(bool)) return "bool";
        if (t == typeof(double)) return "double";
        if (t == typeof(Guid)) return "guid";
        if (t == typeof(DateOnly)) return "date";
        if (t == typeof(DateTime)) return "datetime";
        return t.Name.ToLowerInvariant();
    }

    static string Format(object? v) => v switch
    {
        null => "NULL",
        decimal d => d.ToString(CultureInfo.InvariantCulture),
        DateTime dt => dt.ToString("yyyy-MM-dd HH:mm:ss.FFFFFF", CultureInfo.InvariantCulture),
        DateOnly d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        bool b => b ? "true" : "false",
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => v.ToString() ?? "NULL",
    };
}
