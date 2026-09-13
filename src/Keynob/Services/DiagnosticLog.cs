using System.IO;

namespace Keynob.Services;

public sealed class DiagnosticLog
{
    private readonly string _path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CodexKeyboardStudio",
        "diagnostic.log");
    private readonly object _gate = new();

    public string LogPath => _path;

    public void Write(string eventName, string detail)
    {
        try
        {
            lock (_gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                File.AppendAllText(_path, $"{DateTimeOffset.UtcNow:O}\t{eventName}\t{detail}{Environment.NewLine}");
            }
        }
        catch
        {
            // Diagnostics must never interrupt keyboard input handling.
        }
    }

    public bool Clear()
    {
        try
        {
            lock (_gate)
            {
                if (File.Exists(_path))
                {
                    File.Delete(_path);
                }
            }
            return true;
        }
        catch
        {
            return false;
        }
    }
}
