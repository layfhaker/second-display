using System;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace SecondDisplay.Host;

/// <summary>
/// Direct ADB-server socket fast path (adb-link), mirroring host-rs/src/adblink.rs.
///
/// Talks to the adb server on 127.0.0.1:5037 with the same framing `adb.exe` itself uses
/// (4 hex chars length + payload, OKAY/FAIL status), so the hot poll (`host:devices`) costs
/// one ~2ms TCP round-trip instead of spawning `adb.exe`. Every socket op degrades gracefully:
/// callers fall back to the `adb.exe` subprocess path on any error.
/// Protocol reference: platform/system/adb SERVICES.TXT.
/// </summary>
public sealed class AdbLink : IDisposable
{
    private const string AdbHost = "127.0.0.1";
    private const int AdbPort = 5037;
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromMilliseconds(1500);

    private readonly object _trackLock = new();
    private List<(string Serial, string State)> _tracked = new();
    private bool _trackHaveData;
    private bool _trackAlive;
    private Thread? _trackThread;
    private volatile bool _disposed;

    public void StartTracker()
    {
        lock (_trackLock)
        {
            if (_trackThread != null) return;
            _trackThread = new Thread(TrackLoop) { IsBackground = true, Name = "AdbTrack" };
            _trackThread.Start();
        }
    }

    /// <summary>
    /// Cached device list if the track feed is live (any age — the server pushes every change,
    /// so a live feed is never stale). Null while (re)connecting.
    /// </summary>
    public List<(string Serial, string State)>? Snapshot()
    {
        lock (_trackLock)
        {
            if (_trackAlive && _trackHaveData)
                return new List<(string, string)>(_tracked);
            return null;
        }
    }

    private void TrackLoop()
    {
        while (!_disposed)
        {
            TrackSession();
            lock (_trackLock) { _trackAlive = false; }
            Thread.Sleep(1000);
        }
    }

    private void TrackSession()
    {
        try
        {
            using var client = new TcpClient();
            if (!client.ConnectAsync(AdbHost, AdbPort).Wait(ConnectTimeout))
                return;
            var stream = client.GetStream();
            stream.WriteTimeout = 5000;
            SendService(stream, "host:track-devices");
            if (ReadStatus(stream) != "OKAY")
                return;
            lock (_trackLock) { _trackAlive = true; }
            while (!_disposed)
            {
                int len = ReadHexLen(stream);
                byte[] payload = ReadN(stream, len);
                var pairs = ParseDevicePairs(payload);
                lock (_trackLock)
                {
                    _tracked = pairs;
                    _trackHaveData = true;
                    _trackAlive = true;
                }
            }
        }
        catch
        {
            // Reconnect quietly via the outer loop.
        }
    }

    /// <summary>Single-shot host service (host:devices, host:version, ...). Payload on OKAY.</summary>
    public static byte[] Query(string service, int timeoutMs)
    {
        using var client = new TcpClient();
        if (!client.ConnectAsync(AdbHost, AdbPort).Wait(ConnectTimeout))
            throw new InvalidOperationException("connect 5037 failed");
        var stream = client.GetStream();
        stream.ReadTimeout = timeoutMs;
        stream.WriteTimeout = timeoutMs;
        SendService(stream, service);
        string status = ReadStatus(stream);
        if (status == "OKAY")
        {
            int len = Math.Min(ReadHexLen(stream), 1 << 20);
            return ReadN(stream, len);
        }
        if (status == "FAIL")
        {
            int len = Math.Min(ReadHexLen(stream), 4096);
            string msg = Encoding.UTF8.GetString(ReadN(stream, len));
            throw new InvalidOperationException(msg);
        }
        throw new InvalidOperationException($"bad status '{status}'");
    }

    /// <summary>
    /// Two-step device service: host:transport:&lt;serial&gt; then a local service
    /// (shell:&lt;cmd&gt;, reverse:forward:&lt;local&gt;;&lt;remote&gt;, reverse:killforward:&lt;local&gt;).
    /// Returns the streamed output (shell stdout, or OKAY... for reverse ops).
    /// </summary>
    public static byte[] TransportExec(string serial, string local, int timeoutMs, int maxBytes = 65536)
    {
        using var client = new TcpClient();
        if (!client.ConnectAsync(AdbHost, AdbPort).Wait(ConnectTimeout))
            throw new InvalidOperationException("connect 5037 failed");
        var stream = client.GetStream();
        stream.ReadTimeout = timeoutMs;
        stream.WriteTimeout = timeoutMs;
        SendService(stream, $"host:transport:{serial}");
        if (ReadStatus(stream) != "OKAY")
            throw new InvalidOperationException("transport rejected");
        SendService(stream, local);
        string status = ReadStatus(stream);
        if (status == "FAIL")
        {
            int len = Math.Min(ReadHexLen(stream), 4096);
            string msg = Encoding.UTF8.GetString(ReadN(stream, len));
            throw new InvalidOperationException(msg);
        }
        if (status != "OKAY")
            throw new InvalidOperationException($"bad local status '{status}'");
        // Stream until the server closes (command done). A read timeout just ends the
        // stream with what we have — the command already completed server-side.
        var outBytes = new List<byte>();
        var buf = new byte[4096];
        try
        {
            while (outBytes.Count < maxBytes)
            {
                int n = stream.Read(buf, 0, Math.Min(buf.Length, maxBytes - outBytes.Count));
                if (n <= 0) break;
                for (int i = 0; i < n; i++) outBytes.Add(buf[i]);
            }
        }
        catch (IOException) { /* timeout = end of stream */ }
        return outBytes.ToArray();
    }

    public static List<(string Serial, string State)> ParseDevicePairs(byte[] payload)
    {
        var pairs = new List<(string, string)>();
        string text = Encoding.UTF8.GetString(payload);
        foreach (string line in text.Split('\n'))
        {
            string t = line.TrimEnd();
            if (string.IsNullOrEmpty(t)) continue;
            string[] parts = t.Split('\t');
            if (parts.Length < 2) continue;
            string serial = parts[0].Trim();
            string state = parts[1].Trim();
            if (serial.Length == 0 || state.Length == 0) continue;
            pairs.Add((serial, state));
        }
        return pairs;
    }

    private static void SendService(NetworkStream stream, string service)
    {
        byte[] body = Encoding.ASCII.GetBytes(service);
        byte[] head = Encoding.ASCII.GetBytes(body.Length.ToString("x4"));
        stream.Write(head, 0, head.Length);
        stream.Write(body, 0, body.Length);
    }

    private static string ReadStatus(NetworkStream stream)
    {
        byte[] st = ReadN(stream, 4);
        return Encoding.ASCII.GetString(st);
    }

    private static int ReadHexLen(NetworkStream stream)
    {
        byte[] lb = ReadN(stream, 4);
        string text = Encoding.ASCII.GetString(lb).Trim();
        return Convert.ToInt32(text, 16);
    }

    private static byte[] ReadN(NetworkStream stream, int n)
    {
        if (n < 0 || n > (1 << 20)) throw new InvalidOperationException($"bad length {n}");
        var buf = new byte[n];
        int got = 0;
        while (got < n)
        {
            int r = stream.Read(buf, got, n - got);
            if (r <= 0) throw new IOException("unexpected EOF");
            got += r;
        }
        return buf;
    }

    public void Dispose()
    {
        _disposed = true;
    }
}
