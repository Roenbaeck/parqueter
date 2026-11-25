using System.Text;
using System.Text.Json;
using Parqueter;

Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

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
