using Parquet;
using Parquet.Schema;

namespace Parqueter;

/// <summary>Writes rows to a Parquet file with an explicit schema, so types and nullability are exactly what the schema says.</summary>
public static class ParquetOut
{
    public static async Task<long> WriteAsync(string path, TableSchema schema, IEnumerable<object?[]> rows, int rowGroupSize)
    {
        var fields = schema.Columns.Select(ToField).ToArray();
        var parquetSchema = new ParquetSchema(fields);

        // Write to a temporary file so a failure half way never leaves a broken file under the real name.
        var temp = path + ".tmp";
        long total = 0;
        try
        {
            await using (var stream = File.Create(temp))
            await using (var writer = await ParquetWriter.CreateAsync(parquetSchema, stream))
            {
                var batch = new List<object?[]>(Math.Min(rowGroupSize, 100_000));

                async Task FlushAsync()
                {
                    if (batch.Count == 0) return;
                    using var group = writer.CreateRowGroup();
                    for (var i = 0; i < fields.Length; i++)
                        await WriteColumnAsync(group, schema.Columns[i], fields[i], batch, i);
                    total += batch.Count;
                    batch.Clear();
                }

                foreach (var row in rows)
                {
                    batch.Add(row);
                    if (batch.Count >= rowGroupSize) await FlushAsync();
                }
                await FlushAsync();
            }
            File.Move(temp, path, overwrite: true);
        }
        catch
        {
            try { File.Delete(temp); } catch (IOException) { }
            throw;
        }
        return total;
    }

    static DataField ToField(Column c) => c.Type switch
    {
        ColumnType.String   => new DataField(c.Name, typeof(string), c.Nullable),
        ColumnType.Bool     => new DataField(c.Name, typeof(bool), c.Nullable),
        ColumnType.Int32    => new DataField(c.Name, typeof(int), c.Nullable),
        ColumnType.Int64    => new DataField(c.Name, typeof(long), c.Nullable),
        ColumnType.Double   => new DataField(c.Name, typeof(double), c.Nullable),
        ColumnType.Guid     => new DataField(c.Name, typeof(Guid), c.Nullable),
        ColumnType.Date     => new DataField(c.Name, typeof(DateOnly), c.Nullable),
        ColumnType.DateTime => new DateTimeDataField(c.Name, DateTimeFormat.DateAndTime, isAdjustedToUTC: false, unit: DateTimeTimeUnit.Micros, isNullable: c.Nullable),
        ColumnType.Decimal  => new DecimalDataField(c.Name, c.Precision ?? 38, c.Scale ?? 0, isNullable: c.Nullable),
        _ => throw new InvalidOperationException($"Unhandled column type {c.Type}"),
    };

    static Task WriteColumnAsync(ParquetRowGroupWriter group, Column c, DataField field, List<object?[]> batch, int index) => c.Type switch
    {
        // Parquet.Net's string overload is annotated non-nullable but writes null for an optional field.
        ColumnType.String   => group.WriteAsync(field, (IReadOnlyCollection<string>)batch.Select(r => (string)r[index]!).ToArray()),
        ColumnType.Bool     => WriteStructAsync<bool>(group, field, batch, index, c.Nullable),
        ColumnType.Int32    => WriteStructAsync<int>(group, field, batch, index, c.Nullable),
        ColumnType.Int64    => WriteStructAsync<long>(group, field, batch, index, c.Nullable),
        ColumnType.Double   => WriteStructAsync<double>(group, field, batch, index, c.Nullable),
        ColumnType.Guid     => WriteStructAsync<Guid>(group, field, batch, index, c.Nullable),
        ColumnType.Date     => WriteStructAsync<DateOnly>(group, field, batch, index, c.Nullable),
        ColumnType.DateTime => WriteStructAsync<DateTime>(group, field, batch, index, c.Nullable),
        ColumnType.Decimal  => WriteStructAsync<decimal>(group, field, batch, index, c.Nullable),
        _ => throw new InvalidOperationException($"Unhandled column type {c.Type}"),
    };

    static Task WriteStructAsync<T>(ParquetRowGroupWriter group, DataField field, List<object?[]> batch, int index, bool nullable)
        where T : struct
    {
        if (nullable)
        {
            var values = batch.Select(r => (T?)r[index]).ToArray();
            return group.WriteAsync<T>(field, new ReadOnlyMemory<T?>(values));
        }
        else
        {
            var values = batch.Select(r => (T)r[index]!).ToArray();
            return group.WriteAsync<T>(field, new ReadOnlyMemory<T>(values));
        }
    }
}
