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

    // UDP transport (primary): video/touch go over UDP to avoid TCP backpressure on the
    // adb/USB link, which was the root cause of the "freezes". Fragmented via UdpPacketizer.
    private UdpClient? _udp;
    private readonly object _udpLock = new();
    private IPEndPoint? _udpClientEp; // remote endpoint of the current UDP client
    private bool _udpHasClient;
    private readonly ConcurrentQueue<TouchPacket> _udpTouchQueue = new();
    private readonly ConcurrentQueue<KeyPacket> _udpKeyQueue = new();
    private readonly object _udpCursorLock = new();
    private CursorState? _udpLatestCursor;
    private long _udpCursorSeq;
    private readonly BlockingCollection<VideoPacket> _udpSendQueue = new(2);
    private int _udpCaptureWidth;
    private int _udpCaptureHeight;
    private int _udpRefreshRate;
    private CancellationTokenSource _udpCts = new();

    public int Port { get; }

    public Server(int port = 27315)
    {
        Port = port;
        // Listen on all interfaces, not just loopback: video/touch now travel over the
        // RNDIS USB-Ethernet link (tablet 10.87.87.73 <-> PC 10.87.87.182), NOT through
        // the adb reverse loopback tunnel. Binding to 0.0.0.0 lets the tablet connect to
        // the PC's RNDIS IP directly; legacy adb reverse (127.0.0.1) still works too.
        _listener = new TcpListener(IPAddress.Any, port);
    }

    public void Start(int captureWidth, int captureHeight)
    {
        _listener.Start();
        Console.WriteLine($"Server listening on 0.0.0.0:{Port} (TCP; UDP via RNDIS optional)");

        Task.Run(() => AcceptLoop(captureWidth, captureHeight));
    }

    /// <summary>Handles incoming UDP datagrams from the tablet (HELLO / TOUCH / KEY).</summary>
    private void UdpReceiveLoop(CancellationToken ct)
    {
        var udp = _udp;
        if (udp == null) return;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                IPEndPoint remote = new(IPAddress.Any, 0);
                byte[] datagram;
                try { datagram = udp.Receive(ref remote); }
                catch (SocketException) { continue; }
                catch (ObjectDisposedException) { break; }

                if (datagram.Length < UdpPacketizer.HeaderSize) continue;

                byte type = datagram[0];
                // A single non-fragmented HELLO/TOUCH/KEY datagram: type in [1..2] / [0x20..0x22]
                if (type == PacketType.Hello)
                {
                    var hello = Protocol.ParseHello(datagram.AsSpan(UdpPacketizer.HeaderSize));
                    lock (_udpLock)
                    {
                        _udpClientEp = remote;
                        _udpHasClient = true;
                        _udpRefreshRate = (int)hello.RefreshRate;
                        _udpCursorSeq = 0;
                    }
                    Console.WriteLine($"UDP client HELLO from {remote}: {hello.Width}x{hello.Height} @ {hello.RefreshRate}Hz");

                    // Send READY (fragmented as a normal packet).
                    var readyPayload = BuildReadyPayload((uint)_udpCaptureWidth, (uint)_udpCaptureHeight, hello.RefreshRate);
                    foreach (var chunk in UdpPacketizer.Fragment(readyPayload, PacketType.Ready, 0, false))
                        udp.Send(chunk, chunk.Length, remote);
                }
                else if (type == PacketType.Touch)
                {
                    if (datagram.Length < UdpPacketizer.HeaderSize + 10) continue;
                    var touch = Protocol.ParseTouch(datagram.AsSpan(UdpPacketizer.HeaderSize, 10));
                    _udpTouchQueue.Enqueue(touch);
                }
                else if (type == PacketType.Key)
                {
                    int keyLen = datagram.Length - UdpPacketizer.HeaderSize;
                    if (keyLen < 7) continue;
                    var key = Protocol.ParseKey(datagram.AsSpan(UdpPacketizer.HeaderSize, keyLen));
                    _udpKeyQueue.Enqueue(key);
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"UDP receive loop error: {ex.Message}");
        }
    }

    /// <summary>Sends queued video frames + latest cursor to the UDP client, fragmented.</summary>
    private void UdpSendLoop(CancellationToken ct)
    {
        var udp = _udp;
        if (udp == null) return;
        try
        {
            long sentCursorSeq = -1;
            foreach (var frame in _udpSendQueue.GetConsumingEnumerable(ct))
            {
                IPEndPoint? ep;
                lock (_udpLock) { ep = _udpClientEp; }
                if (ep == null) continue;

                CursorState? cursor = null;
                long cursorSeq;
                lock (_udpCursorLock)
                {
                    cursorSeq = _udpCursorSeq;
                    if (cursorSeq != sentCursorSeq)
                        cursor = _udpLatestCursor;
                }

                if (cursor != null)
                {
                    var c = cursor.Value;
                    var curPayload = BuildCursorPayload(c.Visible, c.X, c.Y, c.W, c.H, c.Bgra);
                    foreach (var chunk in UdpPacketizer.Fragment(curPayload, PacketType.Cursor, 0, false))
                        udp.Send(chunk, chunk.Length, ep);
                    sentCursorSeq = cursorSeq;
                }

                foreach (var chunk in UdpPacketizer.Fragment(frame.Data, PacketType.Video, frame.PtsMicros, frame.Keyframe))
                    udp.Send(chunk, chunk.Length, ep);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"UDP send loop error: {ex.Message}");
        }
    }

    private static byte[] BuildReadyPayload(uint w, uint h, uint refresh)
    {
        var buf = new byte[13];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(0, 4), w);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(4, 4), h);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(8, 4), refresh);
        buf[12] = Codec.H265;
        return buf;
    }

    private static byte[] BuildCursorPayload(bool visible, int x, int y, int w, int h, byte[] bgra)
    {
        var buf = new byte[17 + bgra.Length];
        buf[0] = visible ? (byte)1 : (byte)0;
        System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(1, 4), x);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(5, 4), y);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(9, 4), w);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(13, 4), h);
        Buffer.BlockCopy(bgra, 0, buf, 17, bgra.Length);
        return buf;
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
        // UDP client (primary): enqueue — UDP send loop sends it, dropping on overflow.
        bool hasUdp;
        lock (_udpLock) hasUdp = _udpHasClient;
        if (hasUdp)
        {
            var frame = VideoPacket.Video(ptsMicros, keyframe, jpegData);
            if (!_udpSendQueue.TryAdd(frame, 0))
            {
                _udpSendQueue.TryTake(out _, 0);
                _udpSendQueue.TryAdd(frame, 0);
            }
        }

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
        bool hasUdp;
        lock (_udpLock) hasUdp = _udpHasClient;
        if (hasUdp)
        {
            lock (_udpCursorLock)
            {
                _udpLatestCursor = new CursorState(visible, x, y, w, h, bgra ?? Array.Empty<byte>());
                _udpCursorSeq++;
            }
        }

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
        if (_udpTouchQueue.TryDequeue(out var udpTouch))
            return udpTouch;

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
        if (_udpKeyQueue.TryDequeue(out var udpKey))
            return udpKey;

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
        get
        {
            bool hasUdp;
            lock (_udpLock) hasUdp = _udpHasClient;
            if (hasUdp) return true;
            lock (_clientsLock) return _clients.Count > 0;
        }
    }

    public int ClientCount
    {
        get
        {
            bool hasUdp;
            lock (_udpLock) hasUdp = _udpHasClient;
            if (hasUdp) return 1;
            lock (_clientsLock) return _clients.Count;
        }
    }

    public int PreferredRefreshRate
    {
        get
        {
            bool hasUdp;
            lock (_udpLock) hasUdp = _udpHasClient;
            if (hasUdp)
                return _udpRefreshRate;
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
        _udpCts.Cancel();
        _udpSendQueue.CompleteAdding();
        _udp?.Dispose();
        _udp = null;
        lock (_udpLock)
        {
            _udpHasClient = false;
            _udpClientEp = null;
        }
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
}

/// <summary>A queued video frame (TCP send queue).</summary>
internal readonly record struct VideoPacket(long PtsMicros, bool Keyframe, byte[] Data)
{
    public static VideoPacket Video(long ptsMicros, bool keyframe, byte[] data) =>
        new(ptsMicros, keyframe, data);
}

/// <summary>Latest cursor state (shared by TCP and UDP paths).</summary>
internal readonly record struct CursorState(bool Visible, int X, int Y, int W, int H, byte[] Bgra);
