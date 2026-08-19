using System.Buffers.Binary;
using System.Net.Sockets;

namespace SecondDisplay.Host;

public static class PacketType
{
    public const byte Hello = 0x01;
    public const byte Ready = 0x02;
    public const byte Video = 0x10;
    public const byte Cursor = 0x11;
    public const byte Touch = 0x20;
    public const byte Scroll = 0x21;
    public const byte Key = 0x22;
}

public static class Codec
{
    public const byte Jpeg = 0;
    public const byte H264 = 1;
    public const byte H265 = 2;
}

public record HelloPacket(uint Width, uint Height, uint Density, uint RefreshRate);
public record ReadyPacket(uint Width, uint Height, uint RefreshRate, byte CodecId);
public record TouchPacket(byte Action, byte PointerId, float X, float Y);
public record KeyPacket(byte Action, ushort KeyCode, uint MetaState, ushort ScanCode);

public static class Protocol
{
    public const int HeaderSize = 5; // 1 type + 4 length

    public static void WritePacket(NetworkStream stream, byte type, ReadOnlySpan<byte> payload)
    {
        Span<byte> header = stackalloc byte[HeaderSize];
        header[0] = type;
        BinaryPrimitives.WriteUInt32LittleEndian(header[1..], (uint)payload.Length);
        stream.Write(header);
        stream.Write(payload);
    }

    public static (byte type, byte[] payload) ReadPacket(NetworkStream stream)
    {
        Span<byte> header = stackalloc byte[HeaderSize];
        ReadExact(stream, header);
        byte type = header[0];
        uint length = BinaryPrimitives.ReadUInt32LittleEndian(header[1..]);
        if (length > 16 * 1024 * 1024)
            throw new InvalidDataException($"Packet too large: {length}");
        var payload = new byte[length];
        ReadExact(stream, payload);
        return (type, payload);
    }

    public static void WriteReady(NetworkStream stream, ReadyPacket pkt)
    {
        Span<byte> buf = stackalloc byte[13];
        BinaryPrimitives.WriteUInt32LittleEndian(buf[0..], pkt.Width);
        BinaryPrimitives.WriteUInt32LittleEndian(buf[4..], pkt.Height);
        BinaryPrimitives.WriteUInt32LittleEndian(buf[8..], pkt.RefreshRate);
        buf[12] = pkt.CodecId;
        WritePacket(stream, PacketType.Ready, buf);
    }

    public static void WriteVideoFrame(NetworkStream stream, long ptsMicros, bool keyframe, ReadOnlySpan<byte> data)
    {
        Span<byte> header = stackalloc byte[HeaderSize];
        header[0] = PacketType.Video;
        BinaryPrimitives.WriteUInt32LittleEndian(header[1..], (uint)(9 + data.Length));

        Span<byte> meta = stackalloc byte[9];
        BinaryPrimitives.WriteInt64LittleEndian(meta, ptsMicros);
        meta[8] = keyframe ? (byte)1 : (byte)0;

        stream.Write(header);
        stream.Write(meta);
        stream.Write(data);
    }

    public static void WriteCursor(NetworkStream stream, bool visible, int x, int y, int w, int h, ReadOnlySpan<byte> bgra)
    {
        Span<byte> header = stackalloc byte[HeaderSize];
        header[0] = PacketType.Cursor;
        BinaryPrimitives.WriteUInt32LittleEndian(header[1..], (uint)(17 + bgra.Length));

        Span<byte> meta = stackalloc byte[17];
        meta[0] = visible ? (byte)1 : (byte)0;
        BinaryPrimitives.WriteInt32LittleEndian(meta[1..], x);
        BinaryPrimitives.WriteInt32LittleEndian(meta[5..], y);
        BinaryPrimitives.WriteInt32LittleEndian(meta[9..], w);
        BinaryPrimitives.WriteInt32LittleEndian(meta[13..], h);

        stream.Write(header);
        stream.Write(meta);
        stream.Write(bgra);
    }

    public static HelloPacket ParseHello(ReadOnlySpan<byte> payload)
    {
        return new HelloPacket(
            BinaryPrimitives.ReadUInt32LittleEndian(payload[0..]),
            BinaryPrimitives.ReadUInt32LittleEndian(payload[4..]),
            BinaryPrimitives.ReadUInt32LittleEndian(payload[8..]),
            BinaryPrimitives.ReadUInt32LittleEndian(payload[12..])
        );
    }

    public static TouchPacket ParseTouch(ReadOnlySpan<byte> payload)
    {
        return new TouchPacket(
            payload[0],
            payload[1],
            BinaryPrimitives.ReadSingleLittleEndian(payload[2..]),
            BinaryPrimitives.ReadSingleLittleEndian(payload[6..])
        );
    }

    public static KeyPacket ParseKey(ReadOnlySpan<byte> payload)
    {
        // ScanCode is optional for backward compatibility with older clients (7-byte payload).
        ushort scanCode = payload.Length >= 9
            ? BinaryPrimitives.ReadUInt16LittleEndian(payload[7..])
            : (ushort)0;
        return new KeyPacket(
            payload[0],
            BinaryPrimitives.ReadUInt16LittleEndian(payload[1..]),
            BinaryPrimitives.ReadUInt32LittleEndian(payload[3..]),
            scanCode
        );
    }

    private static void ReadExact(NetworkStream stream, Span<byte> buffer)
    {
        int offset = 0;
        while (offset < buffer.Length)
        {
            int read = stream.Read(buffer[offset..]);
            if (read == 0) throw new IOException("Connection closed");
            offset += read;
        }
    }
}
