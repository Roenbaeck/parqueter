using System.Reflection;

// Hello World, plus proof that Parquet.Net is bundled inside the single exe.
var parquet = typeof(Parquet.ParquetWriter).Assembly;
var version = parquet.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
              ?? parquet.GetName().Version?.ToString();

Console.WriteLine("Hello from parqueter!");
Console.WriteLine($"Runtime:     {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}");
Console.WriteLine($"Parquet.Net: {version}");
Console.WriteLine($"Executable:  {Environment.ProcessPath}");
