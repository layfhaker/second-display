using Xunit;

namespace SecondDisplay.Host.Tests;

public class UdpPacketizerTests
{
    [Fact]
    public void Fragment_Reassemble_RoundTrip_PreservesData()
    {
        // A typical HEVC frame can exceed the ~64KB UDP datagram limit, so it must be
        // fragmented into multiple datagrams and reassembled on the client in order.
        var payload = new byte[200_000];
        for (int i = 0; i < payload.Length; i++) payload[i] = (byte)(i * 31);

        var chunks = UdpPacketizer.Fragment(payload, packetType: 0x10, ptsMicros: 123456L, keyframe: true);

        Assert.True(chunks.Count > 1, "large payload must fragment into multiple datagrams");

        var reassembled = UdpPacketizer.Reassemble(chunks);
        Assert.Equal(payload, reassembled);
    }

    [Fact]
    public void Fragment_SmallPayload_SingleDatagram()
    {
        var payload = new byte[100];
        var chunks = UdpPacketizer.Fragment(payload, packetType: 0x11, ptsMicros: 0, keyframe: false);

        Assert.Single(chunks);
        var reassembled = UdpPacketizer.Reassemble(chunks);
        Assert.Equal(payload, reassembled);
    }

    [Fact]
    public void Fragment_MaxChunk_ExactBoundary()
    {
        // Payload of exactly MaxPayloadPerChunk should be one chunk.
        var payload = new byte[UdpPacketizer.MaxPayloadPerChunk];
        var chunks = UdpPacketizer.Fragment(payload, packetType: 0x10, ptsMicros: 1, keyframe: true);
        Assert.Single(chunks);
    }

    [Fact]
    public void Reassemble_OutOfOrderChunks_StillReassemblesInOrder()
    {
        var payload = new byte[150_000];
        for (int i = 0; i < payload.Length; i++) payload[i] = (byte)(i & 0xff);

        var chunks = UdpPacketizer.Fragment(payload, packetType: 0x10, ptsMicros: 7, keyframe: false);
        // Reverse chunk order (each chunk carries its fragment index, reassembly must sort).
        chunks.Reverse();

        var reassembled = UdpPacketizer.Reassemble(chunks);
        Assert.Equal(payload, reassembled);
    }

    [Fact]
    public void Reassemble_MissingChunk_Throws()
    {
        var payload = new byte[150_000];
        var chunks = UdpPacketizer.Fragment(payload, packetType: 0x10, ptsMicros: 7, keyframe: false);
        chunks.RemoveAt(1); // drop the second fragment

        Assert.Throws<InvalidDataException>(() => UdpPacketizer.Reassemble(chunks));
    }
}
