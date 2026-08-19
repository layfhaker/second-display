using System;
using System.Collections.Concurrent;
using System.IO;
using System.Text;
using System.Threading;

namespace SecondDisplay.Host;

/// <summary>
/// A TextWriter that duplicates all writes to both an inner writer (e.g. console) and a log file.
/// Writes are handed off to a dedicated background thread via a queue, so callers — including
/// latency-critical threads like the input pump — never block on console redraw or disk I/O.
/// The file is flushed on a timer/idle basis rather than after every single write.
/// </summary>
public sealed class TeeTextWriter : TextWriter
{
    private const int FlushIntervalMs = 250;

    private readonly TextWriter? _inner;
    private readonly StreamWriter _file;
    private readonly BlockingCollection<LogItem> _queue = new();
    private readonly Thread _writerThread;
    private readonly SemaphoreSlim _flushed = new(0);
    private volatile bool _stopping;

    private readonly record struct LogItem(string Text, bool IsLine, bool IsFlushSignal = false);

    public TeeTextWriter(TextWriter? inner, string logPath)
    {
        _inner = inner;
        // FileShare.ReadWrite so multiple writers (Console.Out + Console.Error, or a stray
        // second process) can hold the file without a sharing violation.
        var stream = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        _file = new StreamWriter(stream, Encoding.UTF8) { AutoFlush = false };

        _writerThread = new Thread(WriterLoop) { IsBackground = true, Name = "LogWriter" };
        _writerThread.Start();
    }

    public override Encoding Encoding => _inner?.Encoding ?? Encoding.UTF8;

    public override void Write(char value) => Enqueue(value.ToString(), isLine: false);

    public override void Write(string? value)
    {
        if (value != null) Enqueue(value, isLine: false);
    }

    public override void WriteLine(string? value) => Enqueue(value ?? string.Empty, isLine: true);

    private void Enqueue(string text, bool isLine)
    {
        if (_stopping) return;
        try { _queue.Add(new LogItem(text, isLine)); }
        catch (InvalidOperationException) { /* queue completed during shutdown */ }
    }

    /// <summary>Blocks until every write enqueued so far has been flushed to disk.</summary>
    public override void Flush()
    {
        _inner?.Flush();
        if (_stopping) return;
        try
        {
            _queue.Add(new LogItem(string.Empty, false, IsFlushSignal: true));
            _flushed.Wait(2000);
        }
        catch (InvalidOperationException) { /* queue completed during shutdown */ }
    }

    private void WriterLoop()
    {
        long lastFlush = Environment.TickCount64;
        foreach (LogItem item in _queue.GetConsumingEnumerable())
        {
            if (item.IsFlushSignal)
            {
                _file.Flush();
                lastFlush = Environment.TickCount64;
                _flushed.Release();
                continue;
            }

            if (item.IsLine)
            {
                _inner?.WriteLine(item.Text);
                string timestamp = DateTime.Now.ToString("HH:mm:ss.fff");
                _file.WriteLine($"[{timestamp}] {item.Text}");
            }
            else
            {
                _inner?.Write(item.Text);
                _file.Write(item.Text);
            }

            long now = Environment.TickCount64;
            // Flush on a timer, or immediately once the burst that produced this item has
            // drained — keeps the file reasonably fresh for tailing without a flush per line.
            if (now - lastFlush >= FlushIntervalMs || _queue.Count == 0)
            {
                _file.Flush();
                lastFlush = now;
            }
        }
        _file.Flush();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && !_stopping)
        {
            _stopping = true;
            _queue.CompleteAdding();
            _writerThread.Join(2000);
            _file.Flush();
            _file.Dispose();
        }
        base.Dispose(disposing);
    }

    /// <summary>
    /// Setup: ensure the parent directory of logPath exists, truncate the log file,
    /// redirect Console.Out and Console.Error through TeeTextWriter instances,
    /// and write a startup banner.
    /// </summary>
    public static void Setup(string logPath)
    {
        string? dir = Path.GetDirectoryName(logPath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        // Truncate the file (create fresh), tolerating another handle being open.
        using (new FileStream(logPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite)) { }

        // Capture current console output. One shared writer backs both Out and Error so there is
        // a single file handle (avoids the two-writers sharing violation).
        TextWriter originalOut = Console.Out;
        var tee = new TeeTextWriter(originalOut, logPath);
        Console.SetOut(tee);
        Console.SetError(tee);

        // Write startup banner
        string banner = $"=== SecondDisplay host log {DateTime.Now:yyyy-MM-dd HH:mm:ss} ===";
        Console.WriteLine(banner);
    }
}
