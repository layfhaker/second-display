; SecondDisplay host — x86-64 assembly (MASM) rewrite, staged.
;
; M1: linkable Windows exe, hand-written entry point, Win32 calls (GetStdHandle/WriteFile).
; M2: runtime logging to %LOCALAPPDATA%\SecondDisplay\host-asm.log with a local timestamp.
; M3: spawn adb via CreateProcessA with CREATE_NO_WINDOW, capture its output through a pipe
;     (CreatePipe / SetHandleInformation / ReadFile), and log it.
; M4: TCP listener on ws2_32 — WSAStartup / socket / SO_REUSEADDR / bind / listen / select /
;     accept / recv / send — decoding a real HELLO packet and answering with READY.
; M5: COM from scratch — CoInitializeEx, CreateDXGIFactory1, then hand-rolled vtable calls
;     (EnumAdapters1 / GetDesc / EnumOutputs / GetDesc / Release) to enumerate adapters/outputs.
;
; Next: D3D11 device + DXGI Desktop Duplication; then D3D11 VideoProcessor and Media Foundation HEVC.

option casemap:none

; ---- Win32 constants ----
STD_OUTPUT_HANDLE      equ -11
GENERIC_WRITE          equ 40000000h
FILE_SHARE_READ        equ 1
CREATE_ALWAYS          equ 2
FILE_ATTRIBUTE_NORMAL  equ 80h
INVALID_HANDLE_VALUE   equ 0FFFFFFFFFFFFFFFFh
HANDLE_FLAG_INHERIT    equ 1
STARTF_USESTDHANDLES   equ 100h
CREATE_NO_WINDOW       equ 08000000h
INFINITE               equ 0FFFFFFFFh

; ---- winsock constants ----
AF_INET                equ 2
SOCK_STREAM            equ 1
IPPROTO_TCP            equ 6
SOL_SOCKET             equ 0FFFFh
SO_REUSEADDR           equ 4

; ---- wire protocol ----
PKT_HELLO              equ 01h
PKT_READY              equ 02h
CODEC_H265             equ 2

PORT                   equ 27315   ; the shipped host listens here
SELFTEST_PORT          equ 27316   ; this milestone self-tests alongside a running host

; ---- Win32 imports (kernel32) ----
EXTERN GetStdHandle:PROC
EXTERN WriteFile:PROC
EXTERN ExitProcess:PROC
EXTERN GetEnvironmentVariableA:PROC
EXTERN CreateDirectoryA:PROC
EXTERN CreateFileA:PROC
EXTERN CloseHandle:PROC
EXTERN GetLocalTime:PROC
EXTERN CreatePipe:PROC
EXTERN SetHandleInformation:PROC
EXTERN CreateProcessA:PROC
EXTERN ReadFile:PROC
EXTERN WaitForSingleObject:PROC
EXTERN GetExitCodeProcess:PROC
EXTERN GetLastError:PROC

; ---- winsock imports (ws2_32) ----
EXTERN WSAStartup:PROC
EXTERN WSACleanup:PROC
EXTERN WSAGetLastError:PROC
EXTERN socket:PROC
EXTERN setsockopt:PROC
EXTERN bind:PROC
EXTERN listen:PROC
EXTERN select:PROC
EXTERN accept:PROC
EXTERN recv:PROC
EXTERN send:PROC
EXTERN closesocket:PROC

; ---- COM imports (ole32 / dxgi) ----
EXTERN CoInitializeEx:PROC
EXTERN CoUninitialize:PROC
EXTERN CreateDXGIFactory1:PROC

.data
szLocal   db "LOCALAPPDATA", 0
szSub     db "\SecondDisplay", 0
szLog     db "\host-asm.log", 0
msg       db "] SecondDisplay Host (asm) v0.1", 13, 10, 0
msg_len   equ $ - msg - 1
szAdbTail db "adb devices:", 13, 10, 0
szAdbTail_len equ $ - szAdbTail - 1
szCrLf    db 13, 10, 0
szAdbCmd  db "adb.exe devices", 0
szCpFail  db "CreateProcessA failed: ", 0
szPipeFail db "CreatePipe failed", 13, 10, 0
szExit    db "adb exit=", 0
szBr      db "bytes=", 0
szReadErr db "ReadFile err=", 0
szHOut    db "hOut=", 0
szHWrite  db "writeH=", 0

szWsaFail db "WSAStartup failed", 13, 10, 0
szSockFail db "socket() failed", 13, 10, 0
szBindFail db "bind() failed wsa=", 0
szListenOk db "TCP listening on 0.0.0.0:27316", 13, 10, 0
szNoClient db "no client within 15s", 13, 10, 0
szClient  db "TCP client connected", 13, 10, 0
szPktType db "packet type=", 0
szPktLen  db "packet len=", 0
szHelloW  db "hello width=", 0
szHelloH  db "hello height=", 0
szHelloD  db "hello density=", 0
szHelloR  db "hello refresh=", 0
szReady   db "READY sent (1920x1280 refresh=60 codec=2)", 13, 10, 0
szRecvFail db "recv failed wsa=", 0
szAccept  db "accept() failed wsa=", 0

oneInt    dd 1

; IID_IDXGIFactory1 {770AAE78-F26F-4DBA-A829-253C83D1B387}, stored the way COM wants it
iidFactory1 db 78h,0AEh,0Ah,77h,6Fh,0F2h,0BAh,4Dh,0A8h,29h,25h,3Ch,83h,0D1h,0B3h,87h

szCoFail   db "CoInitializeEx failed hr=", 0
szDxgiFail db "CreateDXGIFactory1 failed hr=", 0
szAdapter  db "adapter: ", 0
szVendor   db "  vendor=", 0
szDevice   db "  device=", 0
szOutName  db "  output: ", 0
szRectX    db "    x=", 0
szRectY    db "    y=", 0
szDxgiDone db "DXGI probe done", 13, 10, 0

; SECURITY_ATTRIBUTES { nLength=24, lpSecurityDescriptor=NULL, bInheritHandle=TRUE }
saBuf     dd 24
          dd 0                    ; padding
          dq 0                    ; lpSecurityDescriptor
          dd 1                    ; bInheritHandle = TRUE
          dd 0                    ; padding

.data?
envBuf    db 260 dup(?)
lineBuf   db 128 dup(?)
stdTime   dw 8 dup(?)          ; SYSTEMTIME (8 x WORD)
written   dq ?
logHandle dq ?

readH     dq ?
writeH    dq ?
siBuf     db 104 dup(?)        ; STARTUPINFOA
piBuf     db 24 dup(?)         ; PROCESS_INFORMATION
outBuf    db 8192 dup(?)
br        dd ?
ec        dd ?
numBuf    db 16 dup(?)

wsaData   db 512 dup(?)        ; WSADATA
sa2       db 16 dup(?)         ; sockaddr_in
fdset     db 24 dup(?)         ; fd_set { u_int count; SOCKET fd_array[] }
tv        db 8 dup(?)          ; timeval { long sec; long usec }
recvHdr   db 8 dup(?)          ; 5-byte packet header
recvPay   db 64 dup(?)
readyBuf  db 32 dup(?)
sockListen dd ?
sockClient dd ?
pktLen    dd ?

pFactory  dq ?                 ; IDXGIFactory1*
pAdapter  dq ?                 ; IDXGIAdapter1*
pOutput   dq ?                 ; IDXGIOutput*
adapterDesc db 320 dup(?)      ; DXGI_ADAPTER_DESC
outDesc   db 128 dup(?)        ; DXGI_OUTPUT_DESC
ansiBuf   db 320 dup(?)        ; wide -> ansi scratch

.code

; Copy a NUL-terminated string: rcx = dest, rdx = src. Returns rax = dest end (at the NUL).
copy_z proc
    mov     rax, rcx
copy_loop:
    mov     r8b, byte ptr [rdx]
    mov     byte ptr [rax], r8b
    test    r8b, r8b
    jz      copy_done
    inc     rax
    inc     rdx
    jmp     copy_loop
copy_done:
    ret
copy_z endp

; Wide (UTF-16) -> ANSI: rcx = dest, rdx = src. Non-ASCII becomes '?'. Returns rax = dest end.
wc2a proc
    mov     rax, rcx
wc_loop:
    movzx   r8d, word ptr [rdx]
    test    r8d, r8d
    jz      wc_done
    cmp     r8d, 7Fh
    jbe     wc_store
    mov     r8d, '?'
wc_store:
    mov     byte ptr [rax], r8b
    inc     rax
    add     rdx, 2
    jmp     wc_loop
wc_done:
    mov     byte ptr [rax], 0
    ret
wc2a endp

; Write two decimal digits: rcx = dest, edx = value (0..99). Returns rax = dest + 2.
u2 proc
    movzx   eax, dl
    xor     edx, edx
    mov     r8d, 10
    div     r8d
    add     al, '0'
    add     dl, '0'
    mov     byte ptr [rcx], al
    mov     byte ptr [rcx+1], dl
    lea     rax, [rcx+2]
    ret
u2 endp

; Write an ANSI buffer to stdout: rcx = ptr, edx = len.
write_stdout proc
    sub     rsp, 38h
    mov     qword ptr [rsp+28h], rcx
    mov     dword ptr [rsp+30h], edx
    mov     ecx, STD_OUTPUT_HANDLE
    call    GetStdHandle
    mov     rcx, rax
    mov     rdx, [rsp+28h]
    mov     r8d, [rsp+30h]
    lea     r9, written
    mov     qword ptr [rsp+20h], 0
    call    WriteFile
    add     rsp, 38h
    ret
write_stdout endp

; Write an ANSI buffer to the log file (if open) and to stdout: rcx = ptr, edx = len.
emit proc
    sub     rsp, 38h
    mov     qword ptr [rsp+28h], rcx
    mov     dword ptr [rsp+30h], edx
    mov     rax, logHandle
    test    rax, rax
    jz      emit_stdout
    mov     rcx, rax
    mov     rdx, [rsp+28h]
    mov     r8d, [rsp+30h]
    lea     r9, written
    mov     qword ptr [rsp+20h], 0
    call    WriteFile
emit_stdout:
    mov     rcx, [rsp+28h]
    mov     edx, [rsp+30h]
    call    write_stdout
    add     rsp, 38h
    ret
emit endp

; Emit a NUL-terminated string: rcx = ptr.
emit_z proc
    sub     rsp, 28h
    mov     r8, rcx
    xor     edx, edx
ez_scan:
    cmp     byte ptr [r8+rdx], 0
    je      ez_go
    inc     edx
    jmp     ez_scan
ez_go:
    call    emit
    add     rsp, 28h
    ret
emit_z endp

; Unsigned decimal: rcx = dest buffer, edx = value. Returns rax = end pointer (NUL written).
u32_dec proc
    push    rbx
    mov     r8, rcx
    mov     eax, edx
    mov     r9d, 10
    sub     rsp, 16
    lea     r10, [rsp+15]
    mov     byte ptr [r10], 0
    xor     ebx, ebx
dec_loop:
    xor     edx, edx
    div     r9d
    add     dl, '0'
    dec     r10
    mov     byte ptr [r10], dl
    inc     ebx
    test    eax, eax
    jnz     dec_loop
    mov     rcx, r8
dec_copy:
    mov     al, byte ptr [r10]
    mov     byte ptr [rcx], al
    inc     r10
    inc     rcx
    dec     ebx
    jnz     dec_copy
    mov     byte ptr [rcx], 0
    mov     rax, rcx
    add     rsp, 16
    pop     rbx
    ret
u32_dec endp

; Emit "<label><decimal><CRLF>": rcx = label ptr, edx = value.
emit_num proc
    sub     rsp, 38h
    mov     qword ptr [rsp+28h], rcx
    mov     dword ptr [rsp+30h], edx
    call    emit_z
    lea     rcx, numBuf
    mov     edx, dword ptr [rsp+30h]
    call    u32_dec
    lea     rcx, numBuf
    call    emit_z
    lea     rcx, szCrLf
    call    emit_z
    add     rsp, 38h
    ret
emit_num endp

; Run "adb devices", capture its stdout through a pipe and emit it. No arguments.
run_adb_devices proc
    sub     rsp, 58h               ; shadow + args 5..10 for CreateProcessA

    ; ---- CreatePipe(&readH, &writeH, NULL, 0) ----
    lea     rcx, readH
    lea     rdx, writeH
    lea     r8, saBuf
    xor     r9d, r9d
    call    CreatePipe
    test    eax, eax
    jnz     adb_pipe_ok
    lea     rcx, szPipeFail
    call    emit_z
    jmp     adb_done
adb_pipe_ok:

    ; the read end must not be inherited by adb
    mov     rcx, readH
    mov     edx, HANDLE_FLAG_INHERIT
    xor     r8d, r8d
    call    SetHandleInformation

    ; ---- STARTUPINFOA: use our pipe as the child's stdout/stderr ----
    mov     r14, offset siBuf
    mov     dword ptr [r14], 104
    mov     dword ptr [r14+60], STARTF_USESTDHANDLES
    mov     rax, writeH
    mov     qword ptr [r14+88], rax
    mov     qword ptr [r14+96], rax

    ; ---- CreateProcessA(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi) ----
    xor     ecx, ecx
    lea     rdx, szAdbCmd
    xor     r8d, r8d
    xor     r9d, r9d
    mov     qword ptr [rsp+20h], 1
    mov     dword ptr [rsp+28h], CREATE_NO_WINDOW
    mov     qword ptr [rsp+30h], 0
    mov     qword ptr [rsp+38h], 0
    lea     rax, siBuf
    mov     qword ptr [rsp+40h], rax
    lea     rax, piBuf
    mov     qword ptr [rsp+48h], rax
    call    CreateProcessA
    test    eax, eax
    jnz     adb_started
    call    GetLastError
    mov     edx, eax
    lea     rcx, szCpFail
    call    emit_num
    jmp     adb_close
adb_started:

    ; we don't need our copy of the write end
    mov     rcx, writeH
    call    CloseHandle

    ; ---- drain the pipe ----
read_loop:
    mov     rcx, readH
    lea     rdx, outBuf
    mov     r8d, 2000h             ; = sizeof(outBuf)
    lea     r9, br
    mov     qword ptr [rsp+20h], 0
    call    ReadFile
    test    eax, eax
    jnz     rd_ok
    call    GetLastError
    cmp     eax, 109               ; ERROR_BROKEN_PIPE = normal EOF
    je      adb_wait
    mov     edx, eax
    lea     rcx, szReadErr
    call    emit_num
    jmp     adb_wait
rd_ok:
    mov     edx, dword ptr [br]
    test    edx, edx
    jz      adb_wait
    lea     rcx, outBuf
    call    emit
    jmp     read_loop

adb_wait:
    lea     rcx, szBr
    mov     edx, dword ptr [br]
    call    emit_num
    mov     rcx, qword ptr [piBuf]
    mov     edx, INFINITE
    call    WaitForSingleObject
    mov     rcx, qword ptr [piBuf]
    lea     rdx, ec
    call    GetExitCodeProcess
    lea     rcx, szExit
    mov     edx, dword ptr [ec]
    call    emit_num
    mov     rcx, qword ptr [piBuf]
    call    CloseHandle
    mov     rcx, qword ptr [piBuf+8]
    call    CloseHandle

adb_close:
    mov     rcx, readH
    call    CloseHandle

adb_done:
    add     rsp, 58h
    ret
run_adb_devices endp

; TCP self-test: listen on 0.0.0.0:27315, accept one client within 15s, decode its packet,
; answer a HELLO with READY. Mirrors the real handshake in host-rs/src/protocol.rs.
run_tcp_selftest proc
    sub     rsp, 48h

    ; ---- WSAStartup(MAKEWORD(2,2), &wsaData) ----
    mov     ecx, 202h
    lea     rdx, wsaData
    call    WSAStartup
    test    eax, eax
    jz      ws_ok
    lea     rcx, szWsaFail
    call    emit_z
    jmp     tcp_done

ws_ok:
    ; ---- socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) ----
    mov     ecx, AF_INET
    mov     edx, SOCK_STREAM
    mov     r8d, IPPROTO_TCP
    call    socket
    cmp     eax, -1
    jne     sock_ok
    lea     rcx, szSockFail
    call    emit_z
    jmp     ws_cleanup

sock_ok:
    mov     sockListen, eax

    ; ---- setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, 4) — never refuse a rebind ----
    mov     ecx, sockListen
    mov     edx, SOL_SOCKET
    mov     r8d, SO_REUSEADDR
    lea     r9, oneInt
    mov     dword ptr [rsp+20h], 4
    call    setsockopt

    ; ---- bind(s, &sockaddr_in{AF_INET, htons(27315), INADDR_ANY}, 16) ----
    mov     word ptr [sa2], AF_INET
    mov     eax, SELFTEST_PORT
    xchg    al, ah                 ; htons
    mov     word ptr [sa2+2], ax
    mov     dword ptr [sa2+4], 0   ; INADDR_ANY
    mov     qword ptr [sa2+8], 0

    mov     ecx, sockListen
    lea     rdx, sa2
    mov     r8d, 16
    call    bind
    test    eax, eax
    jz      bind_ok
    call    WSAGetLastError
    mov     edx, eax
    lea     rcx, szBindFail
    call    emit_num
    jmp     close_listen

bind_ok:
    mov     ecx, sockListen
    mov     edx, 5
    call    listen
    lea     rcx, szListenOk
    call    emit_z

    ; ---- select(0, &fdset{sockListen}, NULL, NULL, &timeval{15s}) ----
    mov     dword ptr [fdset], 1
    mov     eax, sockListen
    mov     qword ptr [fdset+8], rax
    mov     dword ptr [tv], 15
    mov     dword ptr [tv+4], 0
    xor     ecx, ecx
    lea     rdx, fdset
    xor     r8d, r8d
    xor     r9d, r9d
    lea     rax, tv
    mov     qword ptr [rsp+20h], rax
    call    select
    test    eax, eax
    jg      have_client
    lea     rcx, szNoClient
    call    emit_z
    jmp     close_listen

have_client:
    mov     ecx, sockListen
    xor     edx, edx
    xor     r8d, r8d
    call    accept
    cmp     eax, -1
    jne     accepted
    call    WSAGetLastError
    mov     edx, eax
    lea     rcx, szAccept
    call    emit_num
    jmp     close_listen
accepted:
    mov     sockClient, eax
    lea     rcx, szClient
    call    emit_z

    ; ---- recv the 5-byte header: [type][u32 LE length] ----
    mov     ecx, sockClient
    lea     rdx, recvHdr
    mov     r8d, 5
    xor     r9d, r9d
    call    recv
    cmp     eax, 5
    je      hdr_ok
    call    WSAGetLastError
    mov     edx, eax
    lea     rcx, szRecvFail
    call    emit_num
    jmp     close_client

hdr_ok:
    lea     rcx, szPktType
    movzx   edx, byte ptr [recvHdr]
    call    emit_num
    mov     eax, dword ptr [recvHdr+1]   ; payload length, little-endian
    mov     pktLen, eax
    lea     rcx, szPktLen
    mov     edx, eax
    call    emit_num

    ; ---- recv the payload ----
    mov     eax, pktLen
    test    eax, eax
    jz      send_ready
    mov     ecx, sockClient
    lea     rdx, recvPay
    mov     r8d, eax
    xor     r9d, r9d
    call    recv

    ; ---- HELLO = 4 little-endian u32: width, height, density, refresh ----
    cmp     byte ptr [recvHdr], PKT_HELLO
    jne     send_ready
    cmp     pktLen, 16
    jb      send_ready
    lea     rcx, szHelloW
    mov     edx, dword ptr [recvPay]
    call    emit_num
    lea     rcx, szHelloH
    mov     edx, dword ptr [recvPay+4]
    call    emit_num
    lea     rcx, szHelloD
    mov     edx, dword ptr [recvPay+8]
    call    emit_num
    lea     rcx, szHelloR
    mov     edx, dword ptr [recvPay+12]
    call    emit_num

send_ready:
    ; ---- READY: header [0x02][13] + width, height, refresh, codec ----
    mov     byte ptr [readyBuf], PKT_READY
    mov     dword ptr [readyBuf+1], 13
    mov     dword ptr [readyBuf+5], 1920
    mov     dword ptr [readyBuf+9], 1280
    mov     dword ptr [readyBuf+13], 60
    mov     byte ptr [readyBuf+17], CODEC_H265
    mov     ecx, sockClient
    lea     rdx, readyBuf
    mov     r8d, 18
    xor     r9d, r9d
    call    send
    lea     rcx, szReady
    call    emit_z

close_client:
    mov     ecx, sockClient
    call    closesocket

close_listen:
    mov     ecx, sockListen
    call    closesocket

ws_cleanup:
    call    WSACleanup

tcp_done:
    add     rsp, 48h
    ret
run_tcp_selftest endp

; DXGI probe: initialise COM, create a DXGI factory, walk every adapter and its outputs,
; logging what the desktop actually exposes. Proves hand-written vtable dispatch works.
;
; vtable slots used (see the DXGI headers):
;   IDXGIObject/IDXGIFactory:  56 = EnumAdapters,  96 = EnumAdapters1
;   IDXGIAdapter:              56 = EnumOutputs,   64 = GetDesc
;   IDXGIOutput:               56 = GetDesc
;   IUnknown:                  16 = Release
run_dxgi_probe proc
    push    r12
    push    r13
    sub     rsp, 68h

    ; ---- CoInitializeEx(NULL, COINIT_MULTITHREADED) ----
    xor     ecx, ecx
    xor     edx, edx
    call    CoInitializeEx
    test    eax, eax
    jz      co_ok
    cmp     eax, 1                 ; S_FALSE = already initialised, still fine
    je      co_ok
    mov     edx, eax
    lea     rcx, szCoFail
    call    emit_num
    jmp     probe_done

co_ok:
    ; ---- CreateDXGIFactory1(&IID_IDXGIFactory1, &pFactory) ----
    lea     rcx, iidFactory1
    lea     rdx, pFactory
    call    CreateDXGIFactory1
    test    eax, eax
    jz      factory_ok
    mov     edx, eax
    lea     rcx, szDxgiFail
    call    emit_num
    jmp     probe_uninit

factory_ok:
    xor     r12d, r12d             ; adapter index

adapt_loop:
    mov     rcx, pFactory
    mov     rax, [rcx]             ; vtable
    mov     edx, r12d
    lea     r8, pAdapter
    call    qword ptr [rax+96]     ; EnumAdapters1
    test    eax, eax
    jnz     adapt_done

    mov     rcx, pAdapter
    mov     rax, [rcx]
    lea     rdx, adapterDesc
    call    qword ptr [rax+64]     ; IDXGIAdapter::GetDesc

    lea     rcx, szAdapter
    call    emit_z
    lea     rcx, ansiBuf
    lea     rdx, adapterDesc       ; WCHAR Description[128]
    call    wc2a
    lea     rcx, ansiBuf
    call    emit_z
    lea     rcx, szVendor
    mov     edx, dword ptr [adapterDesc+256]
    call    emit_num
    lea     rcx, szDevice
    mov     edx, dword ptr [adapterDesc+260]
    call    emit_num

    xor     r13d, r13d             ; output index
out_loop:
    mov     rcx, pAdapter
    mov     rax, [rcx]
    mov     edx, r13d
    lea     r8, pOutput
    call    qword ptr [rax+56]     ; IDXGIAdapter::EnumOutputs
    test    eax, eax
    jnz     out_done

    mov     rcx, pOutput
    mov     rax, [rcx]
    lea     rdx, outDesc
    call    qword ptr [rax+56]     ; IDXGIOutput::GetDesc

    lea     rcx, szOutName
    call    emit_z
    lea     rcx, ansiBuf
    lea     rdx, outDesc           ; WCHAR DeviceName[32]
    call    wc2a
    lea     rcx, ansiBuf
    call    emit_z
    lea     rcx, szRectX
    mov     edx, dword ptr [outDesc+64]   ; DesktopCoordinates.left
    call    emit_num
    lea     rcx, szRectY
    mov     edx, dword ptr [outDesc+68]   ; DesktopCoordinates.top
    call    emit_num

    mov     rcx, pOutput
    mov     rax, [rcx]
    call    qword ptr [rax+16]     ; Release
    inc     r13d
    jmp     out_loop

out_done:
    mov     rcx, pAdapter
    mov     rax, [rcx]
    call    qword ptr [rax+16]     ; Release
    inc     r12d
    jmp     adapt_loop

adapt_done:
    lea     rcx, szDxgiDone
    call    emit_z
    mov     rcx, pFactory
    mov     rax, [rcx]
    call    qword ptr [rax+16]     ; Release

probe_uninit:
    call    CoUninitialize

probe_done:
    add     rsp, 68h
    pop     r13
    pop     r12
    ret
run_dxgi_probe endp

; int mainCRTStartup(void)
mainCRTStartup proc
    sub     rsp, 38h

    ; ---- env: LOCALAPPDATA ----
    lea     rcx, szLocal
    lea     rdx, envBuf
    mov     r8d, 260
    call    GetEnvironmentVariableA
    test    eax, eax
    jz      no_log

    ; ---- dir = %LOCALAPPDATA% + "\SecondDisplay" ----
    lea     r12, envBuf
    mov     r13d, eax
    add     r12, r13
    mov     rcx, r12
    lea     rdx, szSub
    call    copy_z
    mov     r12, rax

    lea     rcx, envBuf
    xor     edx, edx
    call    CreateDirectoryA

    ; ---- path = dir + "\host-asm.log" ----
    mov     rcx, r12
    lea     rdx, szLog
    call    copy_z

    lea     rcx, envBuf
    mov     edx, GENERIC_WRITE
    mov     r8d, FILE_SHARE_READ
    xor     r9d, r9d
    mov     qword ptr [rsp+20h], CREATE_ALWAYS
    mov     qword ptr [rsp+28h], FILE_ATTRIBUTE_NORMAL
    mov     qword ptr [rsp+30h], 0
    call    CreateFileA
    cmp     rax, INVALID_HANDLE_VALUE
    je      no_log
    mov     logHandle, rax

    ; ---- "[HH:MM:SS] <msg>" ----
    lea     rcx, stdTime
    call    GetLocalTime

    lea     r14, lineBuf
    mov     byte ptr [r14], '['
    lea     rcx, [r14+1]
    movzx   edx, word ptr [stdTime+8]
    call    u2
    mov     byte ptr [r14+3], ':'
    lea     rcx, [r14+4]
    movzx   edx, word ptr [stdTime+10]
    call    u2
    mov     byte ptr [r14+7], ':'
    lea     rcx, [r14+8]
    movzx   edx, word ptr [stdTime+12]
    call    u2
    lea     rcx, [r14+10]
    lea     rdx, msg
    call    copy_z
    mov     r15, rax
    sub     r15, r14
    lea     rcx, lineBuf
    mov     edx, r15d
    call    emit

    ; ---- adb devices ----
    lea     rcx, szAdbTail
    mov     edx, szAdbTail_len
    call    emit
    call    run_adb_devices

    ; ---- TCP handshake self-test ----
    call    run_tcp_selftest

    ; ---- DXGI adapter/output probe ----
    call    run_dxgi_probe

    mov     rcx, logHandle
    call    CloseHandle
    mov     logHandle, 0
    jmp     done

no_log:
    lea     rcx, msg
    mov     edx, msg_len
    call    write_stdout

done:
    xor     ecx, ecx
    call    ExitProcess
mainCRTStartup endp

end
