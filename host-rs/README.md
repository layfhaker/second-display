# SecondDisplay host — Rust rewrite (`host-rs`)

A parallel, from-scratch port of the C# host (`../host-c#/SecondDisplay.Host`) to Rust.
Both live side by side: the **C# host stays the shipped/reference build**, this one is the Rust
branch and the two will keep existing together.

## Status

Compiles and its core pipeline runs (verified on this machine):

| Area | State |
|------|-------|
| Options / logging (`%LOCALAPPDATA%\SecondDisplay\host.log`) | ✅ |
| Wire protocol (HELLO/READY/VIDEO/CURSOR/TOUCH/KEY/PING) | ✅ |
| Single-instance (named mutex), High priority | ✅ |
| adb controller (timeouts, reverse, readiness, restart-suppression) | ✅ runtime-tested |
| Device readiness parsing | ✅ |
| Monitor enumeration + VDD detection + layout control (DXGI/GDI/Win32) | ✅ runtime-tested |
| VDD control (pnputil / PowerShell) | ✅ ported |
| Input injection (SendInput) | ✅ ported |
| TCP server + client sessions + heartbeat + drop-oldest queue | ✅ ported |
| DXGI Desktop Duplication capture (+ cursor shape) | ✅ runtime-tested |
| GPU zero-copy (D3D11 VPP BGRA→NV12 + D3D11 encoder input) | ✅ runtime-tested |
| BGRA→NV12 (CPU fallback, `--cpu`) | ✅ |
| Media Foundation HEVC encoder (QuickSync MFT) | ✅ runtime-tested |
| Streaming session (capture→convert→encode→broadcast) | ✅ |
| Orchestrator (passive state machine + resilience fixes) | ✅ ported |

Default is the **GPU zero-copy** path; `--cpu` selects DXGI capture + CPU convert + memory input.
Not yet ported: GDI capture fallback; the dead UDP/RNDIS transport; force-keyframe instead of
encoder recreate on client join.

## Build & run

```powershell
cd host-rs
cargo build --release           # -> target\release\seconddisplay-host.exe
```

Flags (same spirit as the C# host):

```powershell
seconddisplay-host.exe --auto                 # passive orchestration (as the scheduled task does)
seconddisplay-host.exe --display 2            # manual: capture monitor index 2, serve on :27315
seconddisplay-host.exe --probe                # list monitors + adb devices and exit (no port/mutex)
seconddisplay-host.exe --selftest-hevc        # feed synthetic NV12 through the MF HEVC encoder
seconddisplay-host.exe --selftest-gpu -1 --selftest-seconds 5   # GPU zero-copy pipeline (add --cpu for the CPU path)
```

`--cpu` selects the DXGI-capture + CPU-convert path (the default here); `--encode-width/-height`
scale the encoder; `--max-fps` caps adaptive fps.

## Notes

- Uses the [`windows`](https://crates.io/crates/windows) crate (windows-rs) for DXGI / D3D11 /
  Media Foundation / Win32 — the Rust analogue of the Vortice bindings the C# host uses.
- MF event loop gotchas that cost time: `METransformNeedInput = 601`, `METransformHaveOutput = 602`,
  `MF_E_NO_EVENTS_AVAILABLE = 0xC00D3E80`, and `GetEvent` must use `MF_EVENT_FLAG_NO_WAIT`.
- The `--probe` / `--selftest-*` modes deliberately avoid the single-instance mutex, the log file
  and port 27315, so they can run next to a live C# host.
