# SecondDisplay host — HolyC port

A third implementation of the same host, next to `host/` (C# reference), `host-rs/` (Rust, production)
and `host-asm/` (MASM). It speaks the same wire protocol, so the existing Android client, the test
client in the scratchpad and the Rust host's selftests all apply unchanged.

## What is here now

`src/host.HC` — milestone 1, the transport layer, mirroring the asm host's M4 + M8a:

- `PktHead` / `SendPacket` build the `u8 type, u32 length, payload` framing.
- `Handshake` reads the client's HELLO and reports the size it asked for.
- `SendReady` answers with READY `1920x1280 @60, codec 2 (HEVC)`.
- `SendVideo` emits `i64 pts_micros, u8 keyframe, Annex-B` — the exact layout the Rust host writes
  (`host-rs/src/protocol.rs`) and the client already parses.
- `ServeOnce` listens on 27315, serves one client, and returns so the caller listens again — a host
  that exits with its client leaves the tablet frozen on its last frame, which is exactly the failure
  the asm host spent a day learning.

## What has to be honest about the platform

TempleOS is not Windows, and three of the five pipeline stages have no equivalent there:

| stage | asm/Rust host | HolyC host |
|---|---|---|
| capture | DXGI Desktop Duplication | `VGA`/`Graphics()` memory, or a ring-0 sweep of the framebuffer |
| BGRA→NV12 | D3D11 VideoProcessor | written by hand over the frame buffer |
| HEVC | Intel QuickSync MFT | no MFT exists: either a software HEVC written here, or a raw/intra codec the client is taught to accept |
| transport | winsock | `SockTCP`/`SockRead`/`SockWrite` (this file) |
| input | `SendInput` | TempleOS `Kbd`/mouse queue injection |

So the transport and the protocol are portable as-is, and the other rows are real work, not a rename.
The client will need one addition: a codec id for whatever the HolyC encoder produces.

## Verifying the TempleOS calls

`SockTCP`, `SockAccept`, `SockRead`, `SockWrite`, `SockClose`, `NetAlive`, `Sleep`, `MemCpy`, `MAlloc`
must be checked against the installed `Kernel/Net*` and `Kernel/Str*` headers before this compiles —
the same discipline the asm host uses for COM vtables (never guess a signature, read it).

## Running

    # in TempleOS (bare metal or QEMU):
    #include "host.HC"
    // Host_Main already runs at include time, exactly like a HolyC script

Build/run helper once the encoder stage exists: `scripts/run-holyc-qemu.ps1` (to be added with the
capture milestone, when there is something to look at).
