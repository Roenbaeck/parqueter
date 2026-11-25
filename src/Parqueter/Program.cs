using System.Text;
using System.Text.Json;
using Parqueter;

Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

// When output is captured by another program (a script, the PowerShell module) it is always UTF-8,
// not whatever the console code page happens to be. On a real console, .NET's default is kept.
if (Console.IsOutputRedirected)
    Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
if (Console.IsErrorRedirected)
    Console.SetError(new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true });

try
{
    return await Cli.RunAsync(args);
}
catch (CliException e)
{
    Console.Error.WriteLine($"error: {e.Message}");
    return e.ExitCode;
}
catch (Exception e) when (e is FormatException or IOException or UnauthorizedAccessException or JsonException)
{
    Console.Error.WriteLine($"error: {e.Message}");
    return 1;
}
