// SecondDisplay host, HolyC port - transport layer.
//
// Milestone 1 mirrors the asm host's M4/M8a: open the network, listen on the production port, take one
// client, answer its HELLO with READY, then push VIDEO packets built in the exact wire format the
// Android client and the C#/Rust hosts already speak.
//
// Wire format (authoritative source: host-rs/src/protocol.rs):
//   every packet:  u8 type, u32 length (little endian), payload
//   HELLO  0x01 : u32 width, u32 height, u32 refresh, u32 dpi
//   READY  0x02 : u32 width, u32 height, u32 refresh, u8 codec  (2 = HEVC)
//   VIDEO  0x10 : i64 pts_micros, u8 keyframe, then Annex-B HEVC access unit
//
// TempleOS notes, stated plainly so nobody pretends otherwise:
//   - There is no DXGI and no Media Foundation here. Screen capture has to come from the HolyC side
//     (VGA/Graphics() memory) and the HEVC encoder has to be written or replaced by a raw/intra
//     codec that our client is taught to accept. The transport below is the part that can be ported
//     as-is, and it is what this file does.
//   - NetInit()/SockTCP() are TempleOS's own networking calls. Their exact prototypes must be read
//     from the installed Kernel/Net headers before this compiles: see README.md.

#define PORT            27315
#define PKT_HELLO       0x01
#define PKT_READY       0x02
#define PKT_VIDEO       0x10
#define CODEC_HEVC      2
#define STREAM_W        1920
#define STREAM_H        1280
#define STREAM_REFRESH  60

U8 *pkt;                // scratch for one outgoing packet
U8 *pkt_payload;        // payload area inside it

U0 PktInit()
{
    pkt = MAlloc(5 + 32);
    pkt_payload = pkt + 5;
}

U0 PktWrite32(U8 *p, U32 v)
{
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
}

U32 PktRead32(U8 *p)
{
    return p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24);
}

U0 PktHead(U8 type, U32 len)
{
    pkt[0] = type;
    PktWrite32(pkt + 1, len);
}

// Send one whole packet: header first, then payload.
U0 SendPacket(I64 sock, U8 type, U32 len)
{
    PktHead(type, len);
    SockWrite(sock, pkt, 5 + len);
}

// READY tells the client the mode we encode and that the stream is HEVC.
U0 SendReady(I64 sock)
{
    PktWrite32(pkt_payload + 0, STREAM_W);
    PktWrite32(pkt_payload + 4, STREAM_H);
    PktWrite32(pkt_payload + 8, STREAM_REFRESH);
    pkt_payload[12] = CODEC_HEVC;
    SendPacket(sock, PKT_READY, 13);
    "READY sent (%dx%d refresh=%d codec=%d)\n", STREAM_W, STREAM_H, STREAM_REFRESH, CODEC_HEVC;
}

// One VIDEO packet: pts in microseconds, keyframe flag, then the access unit.
U0 SendVideo(I64 sock, I64 pts_us, U8 keyframe, U8 *au, U32 au_len)
{
    U8 *p = pkt_payload;
    p[0] = pts_us & 0xFF; p[1] = (pts_us >> 8) & 0xFF; p[2] = (pts_us >> 16) & 0xFF;
    p[3] = (pts_us >> 24) & 0xFF; p[4] = (pts_us >> 32) & 0xFF; p[5] = (pts_us >> 40) & 0xFF;
    p[6] = (pts_us >> 48) & 0xFF; p[7] = (pts_us >> 56) & 0xFF;
    p[8] = keyframe;
    if (au_len)
        MemCpy(p + 9, au, au_len);
    SendPacket(sock, PKT_VIDEO, 9 + au_len);
}

// Read exactly n bytes off the socket; returns FALSE if the peer went away.
Bool SockReadAll(I64 sock, U8 *buf, I64 n)
{
    I64 got = 0;
    while (got < n) {
        I64 r = SockRead(sock, buf + got, n - got);
        if (r <= 0)
            return FALSE;
        got += r;
    }
    return TRUE;
}

// Take one HELLO: header, then the 16-byte payload the client sends.
Bool Handshake(I64 sock)
{
    U8 hdr[5];
    if (!SockReadAll(sock, hdr, 5))
        return FALSE;
    U8 type = hdr[0];
    U32 len = PktRead32(hdr + 1);
    if (len > 256)
        return FALSE;
    U8 body[256];
    if (len && !SockReadAll(sock, body, len))
        return FALSE;
    "packet type=%d len=%d\n", type, len;
    if (type != PKT_HELLO)
        return FALSE;
    if (len >= 4) {
        U32 w = PktRead32(body + 0);
        U32 h = PktRead32(body + 4);
        "client wants %dx%d\n", w, h;
    }
    return TRUE;
}

// The milestone entry point: listen, serve one client until it goes away, then return so the caller
// can listen again - the same shape the asm host settled on, because a host that dies with its client
// leaves the tablet frozen with nothing to reconnect to.
U0 ServeOnce()
{
    I64 listen = SockTCP(PORT);
    if (listen < 0) {
        "bind/socket failed\n";
        return;
    }
    "TCP listening on 0.0.0.0:%d\n", PORT;
    I64 client = SockAccept(listen);
    if (client < 0) {
        SockClose(listen);
        return;
    }
    "client connected\n";
    if (!Handshake(client)) {
        SockClose(client); SockClose(listen);
        return;
    }
    SendReady(client);

    // Until the real encoder exists, send a keyframe-shaped placeholder so the client's plumbing can be
    // exercised end to end: pts advances at 30 fps and the payload is a single Annex-B start code.
    U8 start_code[4] = {0x00, 0x00, 0x00, 0x01};
    I64 pts = 0;
    Bool first = TRUE;
    while (first || NetAlive(client)) {
        SendVideo(client, pts, first, start_code, 4);
        pts += 33333;
        first = FALSE;
        Sleep(33);
    }
    "client gone\n";
    SockClose(client);
    SockClose(listen);
}

U0 Host_Main()
{
    PktInit();
    while (TRUE)
        ServeOnce();
}

Host_Main;
