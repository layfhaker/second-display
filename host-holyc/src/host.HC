// SecondDisplay host, HolyC port - main host and streaming orchestrator.
//
// Full feature parity with the reference host:
// - TCP Server listening on 0.0.0.0:27315.
// - Handshake: receives 0x01 PKT_HELLO (16 bytes), sends 0x02 PKT_READY (13 bytes: 1920x1280 @60, codec 2 = HEVC).
// - Video streaming: Screen capture of \\.\DISPLAY6 (1920x1280) via GDI BitBlt into 32-bit DIB,
//   convert BGRA to NV12 using BT.601 integer algorithm, encode to HEVC via Media Foundation MFT,
//   and send 0x10 PKT_VIDEO packets ([pts_micros i64][is_key u8][annex-b payload]).
// - Cursor overlay: send 0x11 PKT_CURSOR packets ([visible u8][x i32][y i32][w i32][h i32][1024 bytes arrow]).
// - Dedicated input thread: receives 0x20 PKT_TOUCH & 0x22 PKT_KEY and injects via Windows SendInput.
// - Runs adb reverse tcp:27315 tcp:27315 on startup.

#define PORT            27315
#define PKT_HELLO       0x01
#define PKT_READY       0x02
#define PKT_VIDEO       0x10
#define CODEC_HEVC      2

#include <string.h>

Bool client_alive = FALSE;

U0 PktWrite32(U8 *p, U32 v)
{
    p[0] = v & 0xFF;
    p[1] = (v >> 8) & 0xFF;
    p[2] = (v >> 16) & 0xFF;
    p[3] = (v >> 24) & 0xFF;
}

U32 PktRead32(U8 *p)
{
    return (U32)p[0] | ((U32)p[1] << 8) | ((U32)p[2] << 16) | ((U32)p[3] << 24);
}

// Read exactly n bytes from socket; returns FALSE if disconnected
Bool SockReadAll(I64 sock, U8 *buf, I64 n)
{
    I64 got = 0;
    while (got < n) {
        int r = recv((SOCKET)sock, (char*)(buf + got), (int)(n - got), 0);
        if (r <= 0)
            return FALSE;
        got += r;
    }
    return TRUE;
}

// Direct ADB-server socket fast path (adb-link): talk to 127.0.0.1:5037 with the same
// framing adb.exe itself uses, so the hot poll costs one ~2ms TCP round-trip instead of
// spawning adb.exe. Every op falls back to the adb.exe subprocess path on any error.
#define ADB_PORT 5037

I64 AdbLinkConnect(I64 timeout_ms)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return -1;
    DWORD to = (DWORD)timeout_ms;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&to, sizeof(to));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&to, sizeof(to));
    sockaddr_in a;
    MemSet(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(0x7F000001);
    a.sin_port = htons(ADB_PORT);
    u_long nb = 1;
    ioctlsocket(s, FIONBIO, &nb);
    int cr = connect(s, (sockaddr*)&a, sizeof(a));
    if (cr != 0) {
        int e = WSAGetLastError();
        if (e != WSAEWOULDBLOCK && e != WSAEINPROGRESS) {
            closesocket(s);
            return -1;
        }
        fd_set wf;
        FD_ZERO(&wf);
        FD_SET(s, &wf);
        timeval tv;
        tv.tv_sec = (long)(timeout_ms / 1000);
        tv.tv_usec = (long)((timeout_ms % 1000) * 1000);
        int r = select(0, NULL, &wf, NULL, &tv);
        if (r <= 0) {
            closesocket(s);
            return -1;
        }
    }
    nb = 0;
    ioctlsocket(s, FIONBIO, &nb);
    return (I64)s;
}

// Send one framed service string on an adb-link socket. Returns TRUE on success.
Bool AdbLinkSendRaw(I64 sock, char *service)
{
    char frame[520];
    int n = (int)strlen(service);
    if (n <= 0 || n > 512) return FALSE;
    frame[0] = "0123456789abcdef"[(n >> 12) & 15];
    frame[1] = "0123456789abcdef"[(n >> 8) & 15];
    frame[2] = "0123456789abcdef"[(n >> 4) & 15];
    frame[3] = "0123456789abcdef"[n & 15];
    MemCpy(frame + 4, service, n);
    I64 sent = 0;
    while (sent < 4 + n) {
        int r = send((SOCKET)sock, (const char*)(frame + sent), (int)(4 + n - sent), 0);
        if (r <= 0) return FALSE;
        sent += r;
    }
    return TRUE;
}

Bool AdbLinkSendService(I64 sock, char *service)
{
    return AdbLinkSendRaw(sock, service);
}

// Single-shot host service (host:devices, ...). Returns payload length or -1.
// Uses raw send/recv (SockWrite/SockClose are defined further below).
I64 AdbLinkDevicesQuery(U8 *out, I64 out_cap, I64 timeout_ms)
{
    I64 sock = AdbLinkConnect(timeout_ms);
    if (sock < 0) return -1;
    I64 len = -1;
    char *service = "host:devices";
    char frame[32];
    int n = 12;
    frame[0] = '0'; frame[1] = '0'; frame[2] = '0'; frame[3] = 'c';
    MemCpy(frame + 4, service, n);
    I64 sent = 0;
    while (sent < 4 + n) {
        int r = send((SOCKET)sock, (const char*)(frame + sent), (int)(4 + n - sent), 0);
        if (r <= 0) {
            closesocket((SOCKET)sock);
            return -1;
        }
        sent += r;
    }
    U8 st[4];
    I64 got = 0;
    while (got < 4) {
        int r = recv((SOCKET)sock, (char*)(st + got), (int)(4 - got), 0);
        if (r <= 0) {
            closesocket((SOCKET)sock);
            return -1;
        }
        got += r;
    }
    if (st[0] == 'O' && st[1] == 'K' && st[2] == 'A' && st[3] == 'Y') {
        char lb[4];
        got = 0;
        while (got < 4) {
            int r = recv((SOCKET)sock, (char*)(lb + got), (int)(4 - got), 0);
            if (r <= 0) {
                closesocket((SOCKET)sock);
                return -1;
            }
            got += r;
        }
        char tmp[5];
        tmp[0] = lb[0]; tmp[1] = lb[1]; tmp[2] = lb[2]; tmp[3] = lb[3]; tmp[4] = '\0';
        len = (I64)strtol(tmp, NULL, 16);
        if (len < 0) len = 0;
        if (len > out_cap) len = out_cap;
        got = 0;
        while (got < len) {
            int r = recv((SOCKET)sock, (char*)(out + got), (int)(len - got), 0);
            if (r <= 0) {
                closesocket((SOCKET)sock);
                return -1;
            }
            got += r;
        }
    }
    closesocket((SOCKET)sock);
    return len;
}

// Two-step device service: host:transport:<serial> then a local service
// (shell:<cmd>, reverse:forward:<local>;<remote>, reverse:killforward:<local>).
// Returns streamed byte count or -1.
I64 AdbLinkTransportExec(char *serial, char *local, U8 *out, I64 out_cap, I64 timeout_ms)
{
    I64 sock = AdbLinkConnect(timeout_ms);
    if (sock < 0) return -1;
    char svc[300];
    strcpy(svc, "host:transport:");
    strcat(svc, serial);
    I64 total = -1;
    U8 st[4];
    I64 got = 0;
    if (!AdbLinkSendRaw(sock, svc)) {
        closesocket((SOCKET)sock);
        return -1;
    }
    got = 0;
    while (got < 4) {
        int r = recv((SOCKET)sock, (char*)(st + got), (int)(4 - got), 0);
        if (r <= 0) {
            closesocket((SOCKET)sock);
            return -1;
        }
        got += r;
    }
    if (!(st[0] == 'O' && st[1] == 'K' && st[2] == 'A' && st[3] == 'Y')) {
        closesocket((SOCKET)sock);
        return -1;
    }
    if (!AdbLinkSendRaw(sock, local)) {
        closesocket((SOCKET)sock);
        return -1;
    }
    got = 0;
    while (got < 4) {
        int r = recv((SOCKET)sock, (char*)(st + got), (int)(4 - got), 0);
        if (r <= 0) {
            closesocket((SOCKET)sock);
            return -1;
        }
        got += r;
    }
    if (!(st[0] == 'O' && st[1] == 'K' && st[2] == 'A' && st[3] == 'Y')) {
        closesocket((SOCKET)sock);
        return -1;
    }
    total = 0;
    while (total < out_cap) {
        int r = recv((SOCKET)sock, (char*)(out + total), (int)(out_cap - total), 0);
        if (r <= 0) break;
        total += r;
    }
    closesocket((SOCKET)sock);
    return total;
}

// Parse one host:devices payload into the first serial in "device" state.
Bool AdbLinkFirstDevice(char *serial_out, I64 cap, I64 timeout_ms)
{
    U8 buf[1024];
    I64 len = AdbLinkDevicesQuery(buf, 1024, timeout_ms);
    if (len <= 0) return FALSE;
    buf[len] = '\0';
    char *line = (char*)buf;
    char *p = line;
    while (TRUE) {
        if (*p == '\n' || *p == '\0') {
            char save = *p;
            *p = '\0';
            char *tab = strchr(line, '\t');
            if (tab) {
                *tab = '\0';
                char *state = tab + 1;
                while (*state == ' ' || *state == '\t') state++;
                char *end = state + strlen(state);
                while (end > state && (end[-1] == '\r' || end[-1] == ' ' || end[-1] == '\t')) {
                    end--;
                    *end = '\0';
                }
                if (line[0] != '\0' && strcmp(state, "device") == 0) {
                    strncpy(serial_out, line, cap - 1);
                    serial_out[cap - 1] = '\0';
                    return TRUE;
                }
            }
            if (save == '\0') break;
            line = p + 1;
        }
        p++;
    }
    return FALSE;
}

// Write exactly n bytes to socket; returns bytes sent or <= 0 on error
I64 SockWrite(I64 sock, U8 *buf, I64 n)
{
    I64 sent = 0;
    while (sent < n) {
        int r = send((SOCKET)sock, (const char*)(buf + sent), (int)(n - sent), 0);
        if (r <= 0)
            return r;
        sent += r;
    }
    return sent;
}

U0 SockClose(I64 sock)
{
    if (sock != 0 && sock != -1) {
        closesocket((SOCKET)sock);
    }
}

#include "capture.HC"
#include "encoder.HC"
#include "input.HC"

// Send one packet: 5-byte header, then payload
U0 SendPacket(I64 sock, U8 type, U32 len, U8 *payload)
{
    U8 hdr[5];
    hdr[0] = type;
    PktWrite32(hdr + 1, len);
    if (SockWrite(sock, hdr, 5) <= 0) {
        client_alive = FALSE;
        return;
    }
    if (len > 0 && payload) {
        if (SockWrite(sock, payload, len) <= 0) {
            client_alive = FALSE;
            return;
        }
    }
}

// Send 0x02 PKT_READY (13 bytes: 1920, 1280, 60, codec 2)
U0 SendReady(I64 sock)
{
    U8 ready_buf[13];
    PktWrite32(ready_buf + 0, STREAM_W);
    PktWrite32(ready_buf + 4, STREAM_H);
    PktWrite32(ready_buf + 8, STREAM_REFRESH);
    ready_buf[12] = CODEC_HEVC;
    SendPacket(sock, PKT_READY, 13, ready_buf);
    "READY sent (%dx%d refresh=%d codec=%d)\n", STREAM_W, STREAM_H, STREAM_REFRESH, CODEC_HEVC;
}

// Send 0x10 PKT_VIDEO packet: [pts_micros i64][is_key u8][annex-b payload]
U0 SendVideo(I64 sock, I64 pts_us, U8 keyframe, U8 *au, U32 au_len)
{
    U8 head[14];
    head[0] = PKT_VIDEO;
    PktWrite32(head + 1, 9 + au_len);

    head[5]  = pts_us & 0xFF;
    head[6]  = (pts_us >> 8) & 0xFF;
    head[7]  = (pts_us >> 16) & 0xFF;
    head[8]  = (pts_us >> 24) & 0xFF;
    head[9]  = (pts_us >> 32) & 0xFF;
    head[10] = (pts_us >> 40) & 0xFF;
    head[11] = (pts_us >> 48) & 0xFF;
    head[12] = (pts_us >> 56) & 0xFF;
    head[13] = keyframe;

    if (SockWrite(sock, head, 14) <= 0) {
        client_alive = FALSE;
        return;
    }
    if (au_len > 0 && au) {
        if (SockWrite(sock, au, au_len) <= 0) {
            client_alive = FALSE;
            return;
        }
    }
}

// Handshake: receive 0x01 PKT_HELLO (16 bytes: width, height, refresh, dpi)
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

    "Handshake: packet type=0x%02X len=%u\n", type, len;
    if (type != PKT_HELLO)
        return FALSE;

    if (len >= 8) {
        U32 w = PktRead32(body + 0);
        U32 h = PktRead32(body + 4);
        "Client HELLO: wants %ux%u\n", w, h;
    }
    return TRUE;
}

Bool g_vdd_active = FALSE;

char g_adb_path[260] = "";
Bool g_adb_ready = FALSE;

// Resolve the adb shipped next to the host (<app>\platform-tools\adb.exe),
// so an installed host does not depend on adb being on the user's PATH.
U0 AdbPathInit()
{
    if (g_adb_ready) return;
    char exe[260];
    DWORD n = GetModuleFileNameA(NULL, exe, 260);
    if (n > 0 && n < 260) {
        char *slash = strrchr(exe, '\\');
        if (slash) {
            slash[1] = '\0';
            strcpy(g_adb_path, exe);
            strcat(g_adb_path, "platform-tools\\adb.exe");
            if (GetFileAttributesA(g_adb_path) != (DWORD)-1) {
                g_adb_ready = TRUE;
                "Using bundled adb: %s\n", g_adb_path;
                return;
            }
        }
    }
    strcpy(g_adb_path, "adb.exe");
    g_adb_ready = TRUE;
    "Using PATH adb: %s\n", g_adb_path;
}

// Fire-and-forget hidden process: no console window flash.
U0 RunHidden(char *cmd)
{
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    MemSet(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    MemSet(&pi, 0, sizeof(pi));
    char buf[1024];
    strncpy(buf, cmd, 1023);
    buf[1023] = '\0';
    if (CreateProcessA(NULL, buf, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
}

// Run adb reverse tcp:27315 tcp:27315 (socket first, hidden exe fallback)
U0 AdbSetup()
{
    if (!g_adb_ready) AdbPathInit();
    "Configuring ADB reverse forwarding: tcp:%d -> tcp:%d\n", PORT, PORT;
    char serial[64];
    if (AdbLinkFirstDevice(serial, 64, 1500)) {
        char local[64];
        strcpy(local, "reverse:forward:tcp:27315;tcp:27315");
        U8 out[64];
        if (AdbLinkTransportExec(serial, local, out, 64, 10000) >= 0) return;
    }
    char cmd[512];
    strcpy(cmd, "\"");
    strcat(cmd, g_adb_path);
    strcat(cmd, "\" reverse tcp:27315 tcp:27315");
    RunHidden(cmd);
}

// Run adb shell am start for the client (socket first, hidden exe fallback)
U0 AdbAmStart()
{
    if (!g_adb_ready) AdbPathInit();
    char serial[64];
    if (AdbLinkFirstDevice(serial, 64, 1500)) {
        U8 out[256];
        if (AdbLinkTransportExec(serial, "shell:am start -n com.seconddisplay.client/.MainActivity", out, 256, 10000) >= 0) return;
    }
    char cmd[512];
    strcpy(cmd, "\"");
    strcat(cmd, g_adb_path);
    strcat(cmd, "\" shell am start -n com.seconddisplay.client/.MainActivity");
    RunHidden(cmd);
}

U0 VddDetachPhantoms()
{
    typedef BOOL (WINAPI *PFN_EnumDisplayDevicesA)(LPCSTR, DWORD, void*, DWORD);
    typedef LONG (WINAPI *PFN_ChangeDisplaySettingsExA)(LPCSTR, void*, HWND, DWORD, LPVOID);
    HMODULE hUser32 = GetModuleHandleA("user32.dll");
    if (!hUser32) return;
    PFN_EnumDisplayDevicesA pEnum = (PFN_EnumDisplayDevicesA)GetProcAddress(hUser32, "EnumDisplayDevicesA");
    PFN_ChangeDisplaySettingsExA pChange = (PFN_ChangeDisplaySettingsExA)GetProcAddress(hUser32, "ChangeDisplaySettingsExA");
    if (!pEnum || !pChange) return;

    U8 dev[164];
    U8 mon[164];
    int i;
    for (i = 0; i < 16; i++) {
        MemSet(dev, 0, sizeof(dev));
        *(I32*)dev = 164;
        if (!pEnum(NULL, i, dev, 0)) break;
        MemSet(mon, 0, sizeof(mon));
        *(I32*)mon = 164;
        if (!pEnum((LPCSTR)(dev + 4), 0, mon, 0)) continue;
        char *id = (char*)(mon + 4 + 32 + 128 + 4);
        char *name = (char*)(dev + 4);
        if (name[0] == '\0') continue;
        if (strstr(id, "MTT") || strstr(id, "mtt")) {
            "Removing phantom monitor: %s\n", name;
            pChange(name, NULL, NULL, 0x00000008, NULL);
        }
    }
    Sleep(100);
}

U0 VddEnable()
{
    if (g_vdd_active) return;
    "Enabling Virtual Display Driver (ROOT\\DISPLAY\\0000)...\n";
    RunHidden("pnputil.exe /enable-device \"ROOT\\DISPLAY\\0000\"");
    RunHidden("powershell.exe -NoProfile -NonInteractive -Command \"$d = Get-PnpDevice -FriendlyName 'Virtual Display Driver' -ErrorAction SilentlyContinue; if ($d -and $d.Status -ne 'OK') { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false }\"");
    Sleep(500);

    typedef LONG (WINAPI *PFN_SetDisplayConfig)(UINT32, void*, UINT32, void*, UINT32);
    HMODULE hUser32 = GetModuleHandleA("user32.dll");
    if (hUser32) {
        PFN_SetDisplayConfig pSetDisplayConfig = (PFN_SetDisplayConfig)GetProcAddress(hUser32, "SetDisplayConfig");
        if (pSetDisplayConfig) {
            pSetDisplayConfig(0, NULL, 0, NULL, 0x00000080 | 0x00000004);
        }
    }
    ChangeDisplaySettingsExA(NULL, NULL, NULL, 0, NULL);
    g_vdd_active = TRUE;
    "Virtual Display Driver enabled successfully.\n";
}

U0 VddDisable()
{
    "Disabling Virtual Display Driver (ROOT\\DISPLAY\\0000)...\n";
    VddDetachPhantoms();
    RunHidden("pnputil.exe /disable-device \"ROOT\\DISPLAY\\0000\"");
    RunHidden("powershell.exe -NoProfile -NonInteractive -Command \"$d = Get-PnpDevice -FriendlyName 'Virtual Display Driver' -ErrorAction SilentlyContinue; if ($d -and $d.Status -eq 'OK') { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false }\"");
    Sleep(300);
    ChangeDisplaySettingsExA(NULL, NULL, NULL, 0, NULL);
    g_vdd_active = FALSE;
    "Virtual Display Driver disabled successfully.\n";
}

Bool CheckTabletConnected()
{
    // Socket fast path first: one ~2ms round-trip, zero process spawns.
    char serial[64];
    if (AdbLinkFirstDevice(serial, 64, 1500)) return TRUE;
    // Fallback: spawn adb.exe (covers server-down / socket-blocked cases).
    if (!g_adb_ready) AdbPathInit();
    char cmd[512];
    strcpy(cmd, "\"");
    strcat(cmd, g_adb_path);
    strcat(cmd, "\" devices");

    HANDLE hRead = NULL;
    HANDLE hWrite = NULL;
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = TRUE;
    if (!CreatePipe(&hRead, &hWrite, &sa, 0)) return FALSE;
    SetHandleInformation(hRead, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    MemSet(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.hStdOutput = hWrite;
    si.hStdError = hWrite;
    si.dwFlags |= STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    MemSet(&pi, 0, sizeof(pi));

    char buf[1024];
    strncpy(buf, cmd, 1023);
    buf[1023] = '\0';

    Bool found = FALSE;
    if (CreateProcessA(NULL, buf, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        CloseHandle(hWrite);
        hWrite = NULL;
        char out[4096];
        DWORD total = 0;
        DWORD br = 0;
        while (total < sizeof(out) - 1) {
            if (!ReadFile(hRead, out + total, (DWORD)(sizeof(out) - 1 - total), &br, NULL) || br == 0)
                break;
            total += br;
        }
        out[total] = '\0';
        char *p = out;
        while ((p = strstr(p, "device")) != NULL) {
            char before = (p == out) ? '\0' : *(p - 1);
            char after = *(p + 6);
            if ((before == '\t' || before == ' ') &&
                (after == '\r' || after == '\n' || after == '\0' || after == ' ')) {
                found = TRUE;
                break;
            }
            p += 6;
        }
        WaitForSingleObject(pi.hProcess, 5000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
    if (hWrite) CloseHandle(hWrite);
    CloseHandle(hRead);
    return found;
}

// Background thread: continuously monitors tablet connection state,
// turns VDD ON when tablet connects and OFF when tablet disconnects.
DWORD WINAPI TabletWatcherThread(LPVOID lpParam)
{
    (void)lpParam;
    Bool was_connected = CheckTabletConnected();
    if (was_connected) {
        "Startup: tablet connected. Ensuring VDD enabled...\n";
        VddEnable();
        AdbSetup();
    } else {
        "Startup: no tablet connected. Ensuring VDD disabled (passive mode)...\n";
        VddDisable();
    }

    I64 poll_cycle = 0;
    I64 missing_polls = 0;
    I64 present_polls = 0;
    while (TRUE) {
        // Fast disconnect path: drop the virtual screen on the FIRST missed poll,
        // then debounce the reconnect (USB re-enumeration flaps otherwise).
        Sleep(500);
        poll_cycle++;

        Bool has_tablet = CheckTabletConnected();
        if (!has_tablet) {
            missing_polls++;
            present_polls = 0;
        } else {
            missing_polls = 0;
            present_polls++;
        }

        if (has_tablet) {
            // Debounce the connect edge: USB re-enumeration drops adb for a poll or two
            // right after plugging in, so require two in a row before touching the VDD.
            if (!was_connected && present_polls >= 2) {
                "Tablet connection detected! Enabling Virtual Display Driver...\n";
                VddEnable();
                Sleep(1500); // Wait for Windows display manager to enumerate new monitor
                AdbSetup();
                AdbAmStart();
                was_connected = TRUE;
            } else if (was_connected && !client_alive) {
                // Tablet is connected, but client dropped: reassert reverse tunnel and wake client app
                if (poll_cycle % 6 == 0) {
                    AdbSetup();
                    AdbAmStart();
                }
            }
        } else {
            if (was_connected && missing_polls >= 1) {
                "Tablet disconnected! Disabling Virtual Display Driver...\n";
                client_alive = FALSE;
                VddDisable();
                was_connected = FALSE;
            }
        }
    }
    return 0;
}

BOOL WINAPI ConsoleCtrlHandler(DWORD ctrlType)
{
    (void)ctrlType;
    "Process terminating -> Disabling Virtual Display Driver...\n";
    VddDisable();
    return FALSE;
}

// Serve one client session until disconnection
U0 ServeOnce(I64 listen_sock)
{
    sockaddr_in client_addr;
    int addr_len = sizeof(client_addr);
    SOCKET client = accept((SOCKET)listen_sock, (sockaddr*)&client_addr, &addr_len);
    if (client == INVALID_SOCKET)
        return;

    int opt = 1;
    setsockopt(client, IPPROTO_TCP, TCP_NODELAY, (const char*)&opt, sizeof(opt));
    int sndbuf = 524288;
    setsockopt(client, SOL_SOCKET, SO_SNDBUF, (const char*)&sndbuf, sizeof(sndbuf));

    "Client connected from %s:%d\n", inet_ntoa(client_addr.sin_addr), ntohs(client_addr.sin_port);

    if (!Handshake((I64)client)) {
        "Handshake failed with client\n";
        closesocket(client);
        return;
    }

    client_alive = TRUE;
    SendReady((I64)client);

    // Initialise DXGI Desktop Duplication capture of virtual display
    if (!CaptureInit()) {
        "CaptureInit failed\n";
        client_alive = FALSE;
        closesocket(client);
        return;
    }

    // Initialise Media Foundation HEVC hardware/software encoder
    if (!EncoderInit(STREAM_W, STREAM_H, STREAM_REFRESH, 12000000)) {
        "EncoderInit failed\n";
        CaptureCleanup();
        client_alive = FALSE;
        closesocket(client);
        return;
    }

    // Spawn dedicated input thread for touch & keyboard injection
    HANDLE hInputThread = CreateThread(NULL, 0, InputThreadProc, (LPVOID)(I64)client, 0, NULL);
    if (!hInputThread) {
        "Warning: Failed to create input thread\n";
    }

    // High-resolution clock for PTS and Watchdog
    LARGE_INTEGER qpcFreq, qpcStart, qpcNow, qpcLastFrameDrain;
    QueryPerformanceFrequency(&qpcFreq);
    QueryPerformanceCounter(&qpcStart);
    qpcLastFrameDrain = qpcStart;

    // Warmup 5 frames to let desktop compositor initialize
    for (I64 w = 0; w < 5; w++) {
        CaptureFrame();
        Sleep(16);
    }

    I64 frame_idx = 0;
    static I64 last_watchdog_bytes = 0;
    last_watchdog_bytes = bytes_encoded;
    "Starting video streaming loop @%d fps...\n", STREAM_REFRESH;

    while (client_alive) {
        // Send cursor position packet FIRST for instant zero-latency cursor response
        SendCursorPacket((I64)client);

        QueryPerformanceCounter(&qpcNow);
        I64 pts_us = ((qpcNow.QuadPart - qpcStart.QuadPart) * 1000000) / qpcFreq.QuadPart;

        EncoderPollEvents((I64)client);

        Bool got_frame = FALSE;
        if (enc_need_input) {
            // Capture screen via DXGI Desktop Duplication and convert BGRA to NV12.
            // CaptureScreen returns FALSE on duplicate/static frames: pace to ~60fps
            // instead of spin-feeding the same image (that was the CPU+commit blowup).
            if (CaptureFrame()) {
                got_frame = TRUE;
                if (EncoderFeedNv12(frame_nv12, FRAME_NV12, pts_us, 166666)) {
                    frame_idx++;
                }
            }
        }

        // Drain synchronously only if non-async encoder
        if (!enc_is_async) {
            EncoderDrainOutput((I64)client);
        }

        // Watchdog: detect pipeline/network stalls > 2500 ms
        if (bytes_encoded != last_watchdog_bytes) {
            last_watchdog_bytes = bytes_encoded;
            qpcLastFrameDrain = qpcNow;
        } else if (frame_idx > 5) {
            I64 stall_us = ((qpcNow.QuadPart - qpcLastFrameDrain.QuadPart) * 1000000) / qpcFreq.QuadPart;
            if (stall_us > 2500000) {
                "Watchdog: streaming stall detected (>2.5s), resetting session to restore low latency...\n";
                client_alive = FALSE;
                break;
            }
        }

        // Pace the loop: a fresh frame was just fed, or nothing new arrived.
        // Sleeping ~8ms here caps the spin at ~120Hz worst case and lets the
        // encoder/CPU breathe on a static desktop (was: Sleep(1) only when idle,
        // i.e. a hot spin feeding duplicates thousands of times per second).
        Sleep(8);
    }

    "Client session ended\n";
    client_alive = FALSE;

    // Wait for input thread to finish and close socket
    SockClose((I64)client);

    if (hInputThread) {
        WaitForSingleObject(hInputThread, 500);
        CloseHandle(hInputThread);
    }

    EncoderCleanup();
    CaptureCleanup();
}

U0 Host_Main()
{
    HANDLE hSingleMutex = CreateMutexA(NULL, TRUE, "Global\\SecondDisplayHost");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        "Another instance of SecondDisplay Host is already running.\n";
        if (hSingleMutex) CloseHandle(hSingleMutex);
        return;
    }

    "=== SecondDisplay HolyC Host (Windows target) ===\n";

    SetConsoleCtrlHandler(ConsoleCtrlHandler, TRUE);
    CreateThread(NULL, 0, TabletWatcherThread, NULL, 0, NULL);

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        "WSAStartup failed\n";
        return;
    }

    SOCKET listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listen_sock == INVALID_SOCKET) {
        "Socket creation failed\n";
        WSACleanup();
        return;
    }

    int opt = 1;
    setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));

    sockaddr_in addr;
    MemSet(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(PORT);

    if (bind(listen_sock, (sockaddr*)&addr, sizeof(addr)) != 0) {
        "Bind to 0.0.0.0:%d failed\n", PORT;
        closesocket(listen_sock);
        WSACleanup();
        return;
    }

    if (listen(listen_sock, SOMAXCONN) != 0) {
        "Listen failed\n";
        closesocket(listen_sock);
        WSACleanup();
        return;
    }

    "TCP Server listening on 0.0.0.0:%d\n", PORT;

    while (TRUE) {
        ServeOnce((I64)listen_sock);
    }

    closesocket(listen_sock);
    WSACleanup();
}

Host_Main;
