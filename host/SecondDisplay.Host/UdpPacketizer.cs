using System.Buffers.Binary;

namespace SecondDisplay.Host;

/// <summary>
/// Fragments large datagrams (e.g. HEVC video frames that exceed the ~64KB UDP limit)
/// into chunks with a small binary header, and reassembles them on the receiving side.
/// Pure logic — no socket or platform dependencies, so it can be unit-tested directly.
///
/// Wire format per datagram:
///   [0]      byte   packet type (Video=0x10, Cursor=0x11, ...)
///   [1..4]   uint   seq (fragment index within the logical packet; 0-based)
///   [5..8]   uint   total fragments
///   [9..16]  long   ptsMicros (0 for non-video packets)
///   [17]     byte   flags (bit0 = keyframe)
///   [18..]   byte[] fragment payload
/// </summary>
public static class UdpPacketizer
{
    public const int HeaderSize = 18;
    /// <summary>Max UDP payload that is safe to send without IP fragmentation on a LAN link.</summary>
    public const int MaxPayloadPerChunk = 60 * 1024;

    public static List<byte[]> Fragment(byte[] payload, byte packetType, long ptsMicros, bool keyframe)
    {
        if (payload.Length == 0)
            throw new ArgumentException("payload must not be empty", nameof(payload));

        int totalFragments = (payload.Length + MaxPayloadPerChunk - 1) / MaxPayloadPerChunk;
        var chunks = new List<byte[]>(totalFragments);

        for (int frag = 0; frag < totalFragments; frag++)
        {
            int offset = frag * MaxPayloadPerChunk;
            int len = Math.Min(MaxPayloadPerChunk, payload.Length - offset);

            var chunk = new byte[HeaderSize + len];
            chunk[0] = packetType;
            BinaryPrimitives.WriteUInt32LittleEndian(chunk.AsSpan(1, 4), (uint)frag);
            BinaryPrimitives.WriteUInt32LittleEndian(chunk.AsSpan(5, 4), (uint)totalFragments);
            BinaryPrimitives.WriteInt64LittleEndian(chunk.AsSpan(9, 8), ptsMicros);
            chunk[17] = keyframe ? (byte)1 : (byte)0;
            Buffer.BlockCopy(payload, offset, chunk, HeaderSize, len);

            chunks.Add(chunk);
        }
        return chunks;
    }

    /// <summary>
    /// Reassembles a list of fragments (in any order) for one logical packet.
    /// Throws InvalidDataException if a fragment index is missing/duplicated or totals mismatch.
    /// </summary>
    public static byte[] Reassemble(IReadOnlyList<byte[]> chunks)
    {
        if (chunks.Count == 0)
            throw new InvalidDataException("no chunks to reassemble");

        // Header of the first chunk tells us totals.
        uint totalFragments = BinaryPrimitives.ReadUInt32LittleEndian(chunks[0].AsSpan(5, 4));
        if (totalFragments == 0 || totalFragments > 4096)
            throw new InvalidDataException($"invalid total fragments: {totalFragments}");

        var fragmentData = new byte[totalFragments][];
        bool[] seen = new bool[totalFragments];
        int totalLength = 0;

        foreach (var chunk in chunks)
        {
            if (chunk.Length < HeaderSize)
                throw new InvalidDataException("chunk too short");
            uint frag = BinaryPrimitives.ReadUInt32LittleEndian(chunk.AsSpan(1, 4));
            uint total = BinaryPrimitives.ReadUInt32LittleEndian(chunk.AsSpan(5, 4));
            if (total != totalFragments || frag >= totalFragments)
                throw new InvalidDataException("fragment metadata mismatch");
            if (seen[frag])
                throw new InvalidDataException($"duplicate fragment {frag}");

            var data = new byte[chunk.Length - HeaderSize];
            Buffer.BlockCopy(chunk, HeaderSize, data, 0, data.Length);
            fragmentData[frag] = data;
            seen[frag] = true;
            totalLength += data.Length;
        }

        for (int i = 0; i < totalFragments; i++)
        {
            if (!seen[i])
                throw new InvalidDataException($"missing fragment {i}");
        }

        var result = new byte[totalLength];
        int offset = 0;
        for (int i = 0; i < totalFragments; i++)
        {
            var data = fragmentData[i]!;
            Buffer.BlockCopy(data, 0, result, offset, data.Length);
            offset += data.Length;
        }
        return result;
    }
}
