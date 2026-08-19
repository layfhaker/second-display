using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;

namespace SecondDisplay.Host;

public sealed class Server : IDisposable
{
    private readonly TcpListener _listener;
    private readonly CancellationTokenSource _cts = new();
    private readonly List<ClientSession> _clients = new();
    private readonly object _clientsLock = new();

    public int Port { get; }

    public Server(int port = 27315)
    {
        Port = port;
        _listener = new TcpListener(IPAddress.Loopback, port);
    }

    public void Start(int captureWidth, int captureHeight)
    {
        _listener.Start();
        Console.WriteLine($"Server listening on 127.0.0.1:{Port}");
        Console.WriteLine("Run: adb reverse tcp:27315 tcp:27315");

        Task.Run(() => AcceptLoop(captureWidth, captureHeight));
    }

    private async Task AcceptLoop(int captureWidth, int captureHeight)
    {
        while (!_cts.IsCancellationRequested)
        {
            try
            {
                var tcp = await _listener.AcceptTcpClientAsync(_cts.Token);
                tcp.NoDelay = true;
                var session = new ClientSession(tcp, captureWidth, captureHeight);
                if (session.Handshake())
                {
                    lock (_clientsLock) _clients.Add(session);
                    Console.WriteLine($"Client connected: {tcp.Client.RemoteEndPoint}");
                }
                else
                {
                    tcp.Dispose();
                }
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                Console.WriteLine($"Accept error: {ex.Message}");
            }
        }
    }

    public void BroadcastFrame(long ptsMicros, byte[] jpegData, bool keyframe)
    {
        lock (_clientsLock)
        {
            for (int i = _clients.Count - 1; i >= 0; i--)
            {
                try
                {
                    _clients[i].SendFrame(ptsMicros, keyframe, jpegData);
                }
                catch
                {
                    Console.WriteLine("Client disconnected");
                    _clients[i].Dispose();
                    _clients.RemoveAt(i);
                }
            }
        }
    }

    public void BroadcastCursor(bool visible, int x, int y, int w, int h, byte[]? bgra)
    {
        lock (_clientsLock)
        {
            for (int i = _clients.Count - 1; i >= 0; i--)
            {
                try
                {
                    _clients[i].SendCursor(visible, x, y, w, h, bgra);
                }
                catch
                {
                    Console.WriteLine("Client disconnected");
                    _clients[i].Dispose();
                    _clients.RemoveAt(i);
                }
            }
        }
    }

    public TouchPacket? PollTouch()
    {
        lock (_clientsLock)
        {
            foreach (var client in _clients)
            {
                if (client.TryGetTouch(out var touch))
                    return touch;
            }
        }
        return null;
    }

    public KeyPacket? PollKey()
    {
        lock (_clientsLock)
        {
            foreach (var client in _clients)
            {
                if (client.TryGetKey(out var key))
                    return key;
            }
        }
        return null;
    }

    public bool HasClients
    {
        get { lock (_clientsLock) return _clients.Count > 0; }
    }

    public int ClientCount
    {
        get { lock (_clientsLock) return _clients.Count; }
    }

    public int PreferredRefreshRate
    {
        get
        {
            lock (_clientsLock)
            {
                int refresh = 0;
                foreach (var client in _clients)
                    refresh = Math.Max(refresh, client.RefreshRate);
                return refresh;
            }
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener.Stop();
        lock (_clientsLock)
        {
            foreach (var c in _clients) c.Dispose();
            _clients.Clear();
        }
    }
}

internal sealed class ClientSession : IDisposable
{
    private readonly TcpClient _tcp;
    private readonly NetworkStream _stream;
    private readonly ConcurrentQueue<TouchPacket> _touchQueue = new();
    private readonly ConcurrentQueue<KeyPacket> _keyQueue = new();
    private readonly BlockingCollection<VideoPacket> _sendQueue = new(2);
    private readonly object _cursorLock = new();
    private CursorState? _latestCursor;
    private long _cursorSeq;
    private readonly int _captureWidth;
    private readonly int _captureHeight;
    private HelloPacket? _hello;
    private CancellationTokenSource _cts = new();

    public int RefreshRate => (int)(_hello?.RefreshRate ?? 0);

    public ClientSession(TcpClient tcp, int captureWidth, int captureHeight)
    {
        _tcp = tcp;
        _stream = tcp.GetStream();
        _captureWidth = captureWidth;
        _captureHeight = captureHeight;
    }

    public bool Handshake()
    {
        try
        {
            var (type, payload) = Protocol.ReadPacket(_stream);
            if (type != PacketType.Hello) return false;

            _hello = Protocol.ParseHello(payload);
            Console.WriteLine($"Client: {_hello.Width}x{_hello.Height} @ {_hello.RefreshRate}Hz, {_hello.Density}dpi");

            Protocol.WriteReady(_stream, new ReadyPacket(
                (uint)_captureWidth,
                (uint)_captureHeight,
                _hello.RefreshRate,
                Codec.H265
            ));

            Task.Run(ReceiveLoop);
            Task.Run(SendLoop);
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Handshake failed: {ex.Message}");
            return false;
        }
    }

    public void SendFrame(long ptsMicros, bool keyframe, byte[] jpegData)
    {
        if (_cts.IsCancellationRequested)
            throw new IOException("Client disconnected");

        var frame = VideoPacket.Video(ptsMicros, keyframe, jpegData);
        if (_sendQueue.TryAdd(frame, 0)) return;

        _sendQueue.TryTake(out _, 0);
        _sendQueue.TryAdd(frame, 0);
    }

    public void SendCursor(bool visible, int x, int y, int w, int h, byte[]? bgra)
    {
        if (_cts.IsCancellationRequested)
            throw new IOException("Client disconnected");

        lock (_cursorLock)
        {
            _latestCursor = new CursorState(visible, x, y, w, h, bgra ?? Array.Empty<byte>());
            _cursorSeq++;
        }
    }

    public bool TryGetTouch(out TouchPacket? touch)
    {
        if (_touchQueue.TryDequeue(out touch))
            return true;
        touch = null;
        return false;
    }

    public bool TryGetKey(out KeyPacket? key)
    {
        if (_keyQueue.TryDequeue(out key))
            return true;
        key = null;
        return false;
    }

    private void ReceiveLoop()
    {
        try
        {
            while (!_cts.IsCancellationRequested)
            {
                var (type, payload) = Protocol.ReadPacket(_stream);
                if (type == PacketType.Touch)
                    _touchQueue.Enqueue(Protocol.ParseTouch(payload));
                else if (type == PacketType.Key)
                    _keyQueue.Enqueue(Protocol.ParseKey(payload));
            }
        }
        catch { _cts.Cancel(); }
    }

    private void SendLoop()
    {
        try
        {
            long sentCursorSeq = -1;
            foreach (var frame in _sendQueue.GetConsumingEnumerable(_cts.Token))
            {
                CursorState? cursor = null;
                long cursorSeq;
                lock (_cursorLock)
                {
                    cursorSeq = _cursorSeq;
                    if (cursorSeq != sentCursorSeq)
                        cursor = _latestCursor;
                }

                if (cursor != null)
                {
                    var c = cursor.Value;
                    Protocol.WriteCursor(_stream, c.Visible, c.X, c.Y, c.W, c.H, c.Bgra);
                    sentCursorSeq = cursorSeq;
                }

                Protocol.WriteVideoFrame(_stream, frame.PtsMicros, frame.Keyframe, frame.Data);
            }
        }
        catch { _cts.Cancel(); }
    }

    public void Dispose()
    {
        _cts.Cancel();
        _sendQueue.CompleteAdding();
        _stream.Dispose();
        _tcp.Dispose();
    }

    private readonly record struct VideoPacket(long PtsMicros, bool Keyframe, byte[] Data)
    {
        public static VideoPacket Video(long ptsMicros, bool keyframe, byte[] data) =>
            new(ptsMicros, keyframe, data);
    }

    private readonly record struct CursorState(bool Visible, int X, int Y, int W, int H, byte[] Bgra);
}
