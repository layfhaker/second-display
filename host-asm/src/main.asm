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
; M6: D3D11CreateDevice + IDXGIOutput1::DuplicateOutput + AcquireNextFrame, then copy the desktop
;     texture into a staging texture, Map it and checksum the pixels.
;
; Next: D3D11 VideoProcessor (BGRA->NV12) and Media Foundation HEVC, then the orchestrator.

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
PKT_VIDEO              equ 10h
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
EXTERN Sleep:PROC
EXTERN QueryPerformanceCounter:PROC
EXTERN QueryPerformanceFrequency:PROC

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
EXTERN shutdown:PROC

; ---- COM imports (ole32 / dxgi) ----
EXTERN CoInitializeEx:PROC
EXTERN CoUninitialize:PROC
EXTERN CreateDXGIFactory1:PROC
EXTERN D3D11CreateDevice:PROC

; ---- Media Foundation imports (mfplat) ----
EXTERN MFStartup:PROC
EXTERN MFShutdown:PROC
EXTERN MFTEnumEx:PROC
EXTERN MFCreateMediaType:PROC
EXTERN MFCreateSample:PROC
EXTERN MFCreateMemoryBuffer:PROC
EXTERN CoTaskMemFree:PROC

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
szListenOk db "TCP listening on 0.0.0.0:27315", 13, 10, 0
szNoClient db "no client within 15s", 13, 10, 0
szClient  db "TCP client connected", 13, 10, 0
szPktType db "packet type=", 0
szPktLen  db "packet len=", 0
szHelloW  db "hello width=", 0
szHelloH  db "hello height=", 0
szHelloD  db "hello density=", 0
szHelloR  db "hello refresh=", 0
szReady   db "READY sent (1920x1280 refresh=60 codec=2)", 13, 10, 0
szStreamKeep db "client kept for streaming", 13, 10, 0
szSentBytes db "  sent VIDEO payload=", 0
szSentKey db "  sent keyframe=", 0
szSendFail db "  send failed wsa=", 0
szStreamTot db "STREAM: frames sent=", 0
szStreamTotB db "STREAM: bytes sent=", 0
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

; IID_IDXGIOutput1 {00CDDEA8-939B-4B83-A340-A685226666CC}
iidOutput1  db 0A8h,0DEh,0CDh,00h,9Bh,93h,83h,4Bh,0A3h,40h,0A6h,85h,22h,66h,66h,0CCh
; IID_ID3D11Texture2D {6f15aaf2-d208-4e89-9ab4-489535d34f9c}
iidTexture2D db 0F2h,0AAh,15h,6Fh,08h,0D2h,89h,4Eh,9Ah,0B4h,48h,95h,35h,0D3h,4Fh,9Ch

featureLevels dd 0B000h, 0A100h     ; D3D_FEATURE_LEVEL_11_0, _10_1

szDevFail  db "D3D11CreateDevice failed hr=", 0
szQiFail   db "QueryInterface(IDXGIOutput1) failed hr=", 0
szDupFail  db "DuplicateOutput failed hr=", 0
szAcqFail  db "AcquireNextFrame failed hr=", 0
szCapW     db "capture width=", 0
szCapH     db "capture height=", 0
szRowPitch db "capture rowpitch=", 0
szChecksum db "capture checksum=", 0
szCapOk    db "capture frame ok", 13, 10, 0
szCapSrc   db "capture source: ", 0
szNoDup    db "no duplicable output found on any adapter", 13, 10, 0
szAttached db "    attached=", 0
szSameAd   db "    device adapter matches", 13, 10, 0
szDiffAd   db "    DEVICE ADAPTER MISMATCH", 13, 10, 0
szDevPtr   db "    pDevice=", 0
szCtxPtr   db "    pContext=", 0
szQiDevHr  db "    QI(IDXGIDevice) hr=", 0
szGetAdHr  db "    GetAdapter hr=", 0
szDevAdVnd db "    device adapter vendor=", 0
szDevAdDev db "    device adapter device=", 0
szQiD11Hr  db "    QI(ID3D11Device) on pDevice hr=", 0
szDevLevel db "    device feature level=", 0
szOutPtr   db "    pOutput=", 0
szOut1Ptr  db "    pOutput1=", 0
szModeHr   db "    GetDisplayModeList1 hr=", 0
szNumModes db "    mode count=", 0

szVpQi     db "VPP: QI(ID3D11VideoDevice) hr=", 0
szVpCtx    db "VPP: QI(ID3D11VideoContext) hr=", 0
szVpEnum   db "VPP: CreateVideoProcessorEnumerator hr=", 0
szVpProc   db "VPP: CreateVideoProcessor hr=", 0
szVpNv12   db "VPP: NV12 CreateTexture2D hr=", 0
szVpOView  db "VPP: CreateVideoProcessorOutputView hr=", 0
szVpIView  db "VPP: CreateVideoProcessorInputView hr=", 0
szVpBlt    db "VPP: VideoProcessorBlt hr=", 0
szVpStg    db "VPP: NV12 staging CreateTexture2D hr=", 0
szVpBgra   db "VPP: BGRA CreateTexture2D hr=", 0
szLiveFrame db "live frame #", 13, 10, 0
szStageHead db "live stages total ms: acquire=", 0
szStageBlt db " blt=", 0
szStageRead db " readback=", 0
szStagePump db " pump=", 0
szStageFrames db " frames=", 0
szStageHeadPf db "live per-frame ms: acquire=", 0
szStageBltPf db " blt=", 0
szStageReadPf db " readback=", 0
szStagePumpPf db " pump=", 0
szStageCrlf db 13, 10, 0
szVpMap    db "VPP: NV12 Map hr=", 0
szVpOk     db "VPP: BGRA->NV12 blt ok", 13, 10, 0
szVpCopyDone db "VPP: NV12 frame captured", 13, 10, 0
szInSum    db "  enc: input luma sum=", 0
szYSum     db "VPP: Y checksum=", 0
szUvSum    db "VPP: UV checksum=", 0

; IID_ID3D11VideoDevice {10ec4d5b-975a-4689-b9e4-d0aac30fe333}
iidVideoDevice  db 5Bh,4Dh,0ECh,10h,5Ah,97h,89h,46h,0B9h,0E4h,0D0h,0AAh,0C3h,0Fh,0E3h,33h
; IID_ID3D11VideoContext {61f21c45-3c0e-4a74-9cea-671039e0b0d7}
iidVideoContext db 45h,1Ch,0F2h,61h,0Eh,3Ch,74h,4Ah,9Ch,0EAh,67h,10h,0Dh,9Ah,0D5h,0E4h

; ---- Media Foundation GUIDs (printed by tools\print_mf.cpp) ----
iidIMFTransform  db 21h,0C1h,94h,0BFh,05h,5Bh,6Fh,4Eh,80h,00h,0BAh,59h,89h,61h,41h,4Dh
iidIMFMEGen      db 52h,0BDh,0D0h,2Ch,0D5h,0BCh,89h,4Bh,0B6h,2Ch,0EAh,0DCh,0Ch,03h,1Eh,7Dh
mftCatVideoEnc   db 7Dh,0ACh,9Eh,0F7h,45h,0E5h,87h,43h,0BDh,0EEh,0D6h,47h,0D7h,0BDh,0E4h,2Ah
mediaTypeVideo   db 76h,69h,64h,73h,00h,00h,10h,00h,80h,00h,00h,0AAh,00h,38h,9Bh,71h
fmtHEVC          db 48h,45h,56h,43h,00h,00h,10h,00h,80h,00h,00h,0AAh,00h,38h,9Bh,71h
fmtNV12          db 4Eh,56h,31h,32h,00h,00h,10h,00h,80h,00h,00h,0AAh,00h,38h,9Bh,71h
mfMtMajorType    db 8Eh,0A1h,0EBh,48h,0C9h,0F8h,87h,46h,0BFh,11h,0Ah,74h,0C9h,0F9h,6Ah,8Fh
mfMtSubtype      db 9Ah,4Ch,0E3h,0F7h,0E8h,42h,14h,47h,0B7h,4Bh,0CBh,29h,0D7h,2Ch,35h,0E5h
mfMtAvgBitrate   db 24h,26h,33h,20h,0Dh,0FBh,9Eh,4Dh,0BDh,0Dh,0CBh,0F6h,78h,6Ch,10h,2Eh
mfMtFrameSize    db 3Dh,0C3h,52h,16h,0B2h,0D6h,12h,40h,0B8h,34h,72h,03h,08h,49h,0A3h,7Dh
mfMtFrameRate    db 0E8h,0A2h,59h,0C4h,2Ch,3Dh,44h,4Eh,0B1h,32h,0FEh,0E5h,15h,6Ch,7Bh,0B0h
mfMtPixelAspect  db 1Eh,6Ah,37h,0C6h,0Ah,8Dh,27h,40h,0BEh,45h,6Dh,9Ah,0Ah,0D3h,9Bh,0B6h
mfMtInterlace    db 0B8h,4Bh,72h,0E2h,76h,0E6h,06h,48h,0B4h,0B2h,0A8h,0D6h,0EFh,0B4h,4Ch,0CDh
mfAsyncUnlock    db 6Bh,6Dh,66h,0E5h,22h,34h,0B6h,4Eh,0A4h,21h,0DAh,7Dh,0B1h,0F8h,0E2h,07h
mfLowLatency     db 1Ah,89h,27h,9Ch,7Ah,0EDh,0E1h,40h,88h,0E8h,0B2h,27h,27h,0A0h,24h,0EEh

szMfStart    db "MF: MFStartup hr=", 0
szMfEnum     db "MF: MFTEnumEx hr=", 0
szMfFound    db "MF: hardware HEVC encoder MFTs found=", 0
szMfActivate db "MF: ActivateObject hr=", 0
szMfAttrs    db "MF: transform GetAttributes hr=", 0
szMfCreate   db "MF: MFCreateMediaType hr=", 0
szMfOutType  db "MF: SetOutputType hr=", 0
szMfInType   db "MF: SetInputType hr=", 0
szMfSetAttr  db "MF: SetGUID/SetUINT hr=", 0
szMfOutSize  db "MF: output stream cbSize=", 0
szMfSupplies db "MF: provides_samples=", 0
szMfMsg      db "MF: ProcessMessage hr=", 0
szMfReady    db "MF: encoder configured (HEVC <- NV12)", 13, 10, 0

szEncQiGen   db "MF: QI(IMFMediaEventGenerator) hr=", 0
szEncBuf     db "MF: MFCreateMemoryBuffer hr=", 0
szEncSmpl    db "MF: MFCreateSample hr=", 0
szEncInput   db "MF: ProcessInput hr=", 0
szEncEvent   db "MF: GetEvent hr=", 0
szEncOut     db "MF: ProcessOutput hr=", 0
szEncFrames  db "MF: encoded frames=", 0
szEncBytes   db "MF: total HEVC bytes=", 0
szEncFirst   db "MF: first frame bytes=", 0
szEncFirstSu db "MF: first frame checksum=", 0
szEncOk      db "MF: HEVC encode OK", 13, 10, 0
szE2 db "  enc: event type=", 0
; IID_ID3D11Device {db6f6ddb-ac77-4e88-8253-819df9bbf140} — first three fields little-endian
iidD3D11Device db 0DBh,6Dh,6Fh,0DBh,77h,0ACh,88h,4Eh,82h,53h,81h,9Dh,0F9h,0BBh,0F1h,40h

; IID_IDXGIDevice {54ec77fa-1377-44e6-8c32-88fd5f44c84c}
iidDxgiDevice db 0FAh,77h,0ECh,54h,77h,13h,0E6h,44h,8Ch,32h,88h,0FDh,5Fh,44h,0C8h,4Ch

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

pDevice   dq ?                 ; ID3D11Device*
pContext  dq ?                 ; ID3D11DeviceContext*
pDxgiDevice dq ?               ; IDXGIDevice* (from pDevice, for the adapter check)
pDevAdapter dq ?               ; IDXGIAdapter* behind pDevice
pProbe11    dq ?               ; ID3D11Device* QI'd from pDevice (identity check)
devLevel  dd ?                 ; D3D_FEATURE_LEVEL the device was created at
numModes  dd ?                 ; DXGI mode count reported by GetDisplayModeList1

pVideoDevice dq ?              ; ID3D11VideoDevice*
pVideoContext dq ?             ; ID3D11VideoContext*
pVpEnum   dq ?                 ; ID3D11VideoProcessorEnumerator*
pVpProc   dq ?                 ; ID3D11VideoProcessor*
pVpInView dq ?                 ; ID3D11VideoProcessorInputView* (the desktop frame)
pNv12Tex  dq ?                 ; ID3D11Texture2D* NV12 (blt target)
pNv12View dq ?                 ; ID3D11VideoProcessorOutputView* for pNv12Tex
pNv12Stg  dq ?                 ; ID3D11Texture2D* NV12 staging (CPU readable)
vpContent db 48 dup(?)         ; D3D11_VIDEO_PROCESSOR_CONTENT_DESC
vpInDesc  db 16 dup(?)         ; D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC
vpOutDesc db 16 dup(?)         ; D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC
vpStream  db 72 dup(?)         ; D3D11_VIDEO_PROCESSOR_STREAM
vpInSpace dd ?                 ; D3D11_VIDEO_PROCESSOR_COLOR_SPACE (input)
vpOutSpace dd ?                ; D3D11_VIDEO_PROCESSOR_COLOR_SPACE (output)
ySum      dd ?
uvSum     dd ?

pActivates dq ?                ; IMFActivate** returned by MFTEnumEx
mftCount  dd ?
pActivate dq ?                 ; IMFActivate*
pTransform dq ?                ; IMFTransform*
pEventGen dq ?                 ; IMFMediaEventGenerator* (QI of the transform)
pAttrs    dq ?                 ; IMFAttributes* of the transform
pOutType  dq ?                 ; IMFMediaType* (HEVC)
pInType   dq ?                 ; IMFMediaType* (NV12)
mftOutInfo db 32 dup(?)        ; MFT_OUTPUT_STREAM_INFO {dwFlags, cbSize, cbAlignment}
mftRegInfo db 32 dup(?)        ; MFT_REGISTER_TYPE_INFO {guidMajorType, guidSubtype}
providesSamples dd ?
outBufSize dd ?
pEvent    dq ?                 ; IMFMediaEvent* taken off the event queue
pInBuf    dq ?                 ; IMFMediaBuffer* with one NV12 frame
pInSample dq ?                 ; IMFSample* wrapping pInBuf
pContig   dq ?                 ; IMFMediaBuffer* of an encoded sample
evType    dd ?                 ; MediaEventType of the last event
bufPtr    dq ?                 ; Lock()ed pointer
bufMax    dd ?
bufCur    dd ?
outStatus dd ?                 ; ProcessOutput status
odb       db 32 dup(?)         ; MFT_OUTPUT_DATA_BUFFER
encFrames dd ?
encBytes  dd ?
firstSize dd ?
firstSum  dd ?
hnsPts    dq ?                 ; next sample time
feedFails dd ?                 ; consecutive ProcessInput failures
acqTimeouts dd ?               ; consecutive acquisition timeouts before we got any frame at all
haveFrame dd ?                 ; 1 once the capture stage stashed a real NV12 frame
streamSock dd ?                ; the client kept alive for streaming (0 = nobody connected)
; ---- live loop (one long-lived capture+encode cycle instead of the finite probes) ----
liveMode   dd ?                ; 1 = the encoder is set up once and pumped per captured frame
liveFrames dd ?                ; how many frames the live loop streams before it stops
liveCount  dd ?                ; frames the live loop has streamed so far
pumpCap    dd ?                ; event-poll iterations one pump call may spend before giving up
pumpDrained dd ?               ; frames this pump call has drained (live mode stops after one)
ptsStep    dd ?                ; how much the sample time advances per fed frame (100 ns units)
feedToggle dd ?                ; flips per captured frame so only every other one is encoded
vppReady   dd ?                ; 1 once the video-processor objects exist and can be reused
pBgraTex   dq ?                ; our own BGRA texture the video processor reads from every frame
sendPtr   dq ?                 ; Annex-B payload currently being sent
sendLen   dd ?
sentFrames dd ?
sentBytes dd ?
; ---- per-stage timing for the live loop (performance-counter ticks) ----
qpcFreq   dq ?                 ; ticks per second, measured once before the live loop
qpcTmp    dq ?                 ; scratch for QueryPerformanceCounter
tMark     dq ?                 ; stage start, written by mark_start
accPtr    dq ?                 ; accumulator that the current mark_acc adds to
accAcquire dq ?                ; AcquireNextFrame + QI of the desktop texture
accBlt    dq ?                 ; VideoProcessorBlt
accRead   dq ?                 ; NV12 Map + row-wise copy into nv12Frame
accPump   dq ?                 ; encoder feed/drain/send
accFrames dd ?                 ; encoded frames, i.e. pump calls
divisor   dd ?                 ; scratch for the per-frame division in the report
pktOut    db 32 dup(?)         ; VIDEO header + meta staging area
nv12Frame db 3686400 dup(?)    ; the captured frame, de-pitched (luma then chroma): 1920x1280x3/2,
                               ; the mode the capture source is selected by, so it must match it
devDesc   db 320 dup(?)        ; DXGI_ADAPTER_DESC of the device's adapter
pOutput1  dq ?                 ; IDXGIOutput1*
pDup      dq ?                 ; IDXGIOutputDuplication*
pRes      dq ?                 ; IDXGIResource*
pTex      dq ?                 ; ID3D11Texture2D* (the acquired desktop frame)
pStaging  dq ?                 ; ID3D11Texture2D* (CPU-readable staging copy)
frameInfo db 64 dup(?)         ; DXGI_OUTDUPL_FRAME_INFO
texDesc   db 48 dup(?)         ; D3D11_TEXTURE2D_DESC
mapped    db 16 dup(?)         ; D3D11_MAPPED_SUBRESOURCE
capW      dd ?
capH      dd ?
rowPitch  dd ?
checksum  dd ?

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
    ; Each serve cycle used to leave its listening and client sockets behind, so the next bind failed
    ; with WSAEACCES (10013) and the host churned: one session, then nothing. Close them first.
    mov     ecx, sockListen
    cmp     ecx, 0
    jle     ws_no_old_listen
    call    closesocket
    mov     dword ptr [sockListen], 0
ws_no_old_listen:
    mov     ecx, streamSock
    cmp     ecx, 0
    jle     ws_no_old_client
    call    closesocket
    mov     dword ptr [streamSock], 0
ws_no_old_client:

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
    mov     eax, PORT
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

    ; ---- keep this client alive: the capture/encoder stages stream frames into it ----
    mov     eax, sockClient
    mov     streamSock, eax
    lea     rcx, szStreamKeep
    call    emit_z
    jmp     tcp_done                       ; do not close it, do not WSACleanup under it

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

; ---------------------------------------------------------------------------
; send_video_frame — wrap the encoded Annex-B payload in a VIDEO packet and push it to the client.
; Wire format, mirroring the C#/Rust hosts:
;   [0x10][u32 payloadLen] + [i64 pts_micros][u8 keyframe] + Annex-B bytes
; Reads sendPtr/sendLen; a single packet is in flight at any moment, so staging in pktOut is safe.
; ---------------------------------------------------------------------------
send_video_frame proc
    push    rbx
    sub     rsp, 40h

    mov     eax, streamSock
    test    eax, eax
    jz      svf_done                       ; nobody connected — nothing to send

    mov     byte ptr [pktOut], PKT_VIDEO
    mov     eax, sendLen
    add     eax, 9                         ; 8-byte pts + key flag, then the payload
    mov     dword ptr [pktOut+1], eax

    mov     rax, hnsPts                    ; the probe clock runs in 100 ns; the wire wants microseconds
    xor     edx, edx
    mov     ecx, 10
    div     rcx
    mov     qword ptr [pktOut+5], rax

    call    payload_is_keyframe
    mov     byte ptr [pktOut+13], al

    mov     ecx, streamSock
    lea     rdx, pktOut
    mov     r8d, 14
    xor     r9d, r9d
    call    send
    cmp     eax, 14
    jne     svf_fail

    mov     ecx, streamSock
    mov     rdx, qword ptr [sendPtr]
    mov     r8d, sendLen
    xor     r9d, r9d
    call    send
    cmp     eax, sendLen
    jne     svf_fail

    inc     sentFrames
    mov     eax, sendLen
    add     sentBytes, eax
    lea     rcx, szSentBytes
    mov     edx, sendLen
    call    emit_num
    lea     rcx, szSentKey
    movzx   edx, byte ptr [pktOut+13]
    call    emit_num
    jmp     svf_done

svf_fail:
    call    WSAGetLastError
    mov     edx, eax
    lea     rcx, szSendFail
    call    emit_num
    mov     streamSock, 0                  ; the client is gone; stop trying instead of spamming

svf_done:
    add     rsp, 40h
    pop     rbx
    ret
send_video_frame endp

; ---------------------------------------------------------------------------
; payload_is_keyframe — 1 when the Annex-B payload carries an IRAP or a parameter-set NAL.
; Same rule as the Rust reference: locate 00 00 01 / 00 00 00 01, then read (byte >> 1) & 0x3F and
; accept 19/20 (IRAP) or 32/33/34 (VPS/SPS/PPS).
; ---------------------------------------------------------------------------
payload_is_keyframe proc
    push    rsi
    mov     rsi, qword ptr [sendPtr]
    mov     ecx, sendLen
    cmp     ecx, 6
    jb      pik_no
    xor     r8d, r8d
pik_scan:
    mov     eax, ecx
    sub     eax, 6
    cmp     r8d, eax
    jae     pik_no
    cmp     byte ptr [rsi+r8], 0
    jne     pik_next
    cmp     byte ptr [rsi+r8+1], 0
    jne     pik_next
    movzx   eax, byte ptr [rsi+r8+2]
    test    eax, eax
    jnz     pik_three
    cmp     byte ptr [rsi+r8+3], 1         ; 00 00 00 01
    jne     pik_next
    add     r8d, 4
    jmp     pik_check
pik_three:
    cmp     eax, 1                         ; 00 00 01
    jne     pik_next
    add     r8d, 3
pik_check:
    movzx   eax, byte ptr [rsi+r8]
    shr     eax, 1
    and     eax, 3Fh
    cmp     eax, 19
    je      pik_yes
    cmp     eax, 20
    je      pik_yes
    cmp     eax, 32
    je      pik_yes
    cmp     eax, 33
    je      pik_yes
    cmp     eax, 34
    je      pik_yes
pik_next:
    inc     r8d
    jmp     pik_scan
pik_yes:
    mov     eax, 1
    pop     rsi
    ret
pik_no:
    xor     eax, eax
    pop     rsi
    ret
payload_is_keyframe endp

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

; Desktop Duplication probe: D3D11 device on adapter 0, DuplicateOutput on output 0,
; AcquireNextFrame, CopyResource into a CPU-readable staging texture, Map and checksum a row.
;
; vtable slots used (verified against dxgi.h / dxgi1_2.h / d3d11.h in the Windows SDK):
;   IUnknown::QueryInterface = 0, Release = 16,
;   IDXGIAdapter::EnumOutputs = 56, GetDesc = 64, IDXGIFactory1::EnumAdapters1 = 96,
;   IDXGIDevice::GetAdapter = 56, IDXGIOutput::GetDesc = 56,
;   IDXGIOutput1::DuplicateOutput = 176                       <-- 22nd slot, not 17!
;   IDXGIOutputDuplication::AcquireNextFrame = 64, ReleaseFrame = 112,
;   ID3D11Device::CreateTexture2D = 40,
;   ID3D11DeviceContext::Map = 112, Unmap = 120, CopyResource = 376.
run_capture_probe proc
    push    r12
    push    r13
    sub     rsp, 88h

    mov     qword ptr [pFactory], 0
    mov     qword ptr [pAdapter], 0
    mov     qword ptr [pOutput], 0
    mov     qword ptr [pOutput1], 0
    mov     qword ptr [pDevice], 0
    mov     qword ptr [pContext], 0
    mov     qword ptr [pDxgiDevice], 0
    mov     qword ptr [pDevAdapter], 0
    mov     qword ptr [pDup], 0
    mov     qword ptr [pRes], 0
    mov     qword ptr [pTex], 0
    mov     qword ptr [pStaging], 0
    mov     qword ptr [pVideoDevice], 0
    mov     qword ptr [pVideoContext], 0
    mov     qword ptr [pVpEnum], 0
    mov     qword ptr [pVpProc], 0
    mov     qword ptr [pVpInView], 0
    mov     qword ptr [pNv12Tex], 0
    mov     qword ptr [pNv12View], 0
    mov     qword ptr [pNv12Stg], 0

    ; DXGI/D3D11 need no COM apartment of ours (the working Rust path initialises none either).

    ; ---- factory ----
    lea     rcx, iidFactory1
    lea     rdx, pFactory
    call    CreateDXGIFactory1
    test    eax, eax
    jnz     cap_cleanup

    xor     r13d, r13d             ; adapter index

cp_adapt_loop:
    mov     rcx, pFactory
    mov     rax, [rcx]
    mov     edx, r13d
    lea     r8, pAdapter
    call    qword ptr [rax+96]     ; EnumAdapters1
    test    eax, eax
    jnz     cap_nodup

    mov     rcx, pAdapter
    mov     rax, [rcx]
    lea     rdx, adapterDesc
    call    qword ptr [rax+64]     ; IDXGIAdapter::GetDesc (we need its LUID below)

    ; ---- D3D11CreateDevice(NULL, HARDWARE, NULL, BGRA_SUPPORT, levels, 1, SDK 7, ...) ----
    xor     ecx, ecx               ; default adapter, like the Microsoft sample
    mov     edx, 1                 ; D3D_DRIVER_TYPE_HARDWARE
    xor     r8d, r8d
    mov     r9d, 20h               ; D3D11_CREATE_DEVICE_BGRA_SUPPORT
    lea     rax, featureLevels
    mov     qword ptr [rsp+20h], rax
    mov     dword ptr [rsp+28h], 1
    mov     dword ptr [rsp+30h], 7 ; D3D11_SDK_VERSION
    lea     rax, pDevice
    mov     qword ptr [rsp+38h], rax
    lea     rax, devLevel
    mov     qword ptr [rsp+40h], rax
    lea     rax, pContext
    mov     qword ptr [rsp+48h], rax
    call    D3D11CreateDevice
    test    eax, eax
    jz      cp_device_ok
    mov     edx, eax
    lea     rcx, szDevFail
    call    emit_num
    jmp     cp_next_adapter

cp_device_ok:
    lea     rcx, szDevPtr
    mov     edx, dword ptr [pDevice]
    call    emit_num
    lea     rcx, szCtxPtr
    mov     edx, dword ptr [pContext]
    call    emit_num

    ; ---- is the device a real D3D11 device, and on which adapter? ----
    mov     rcx, pDevice
    mov     rax, [rcx]
    lea     rdx, iidDxgiDevice
    lea     r8, pDxgiDevice
    call    qword ptr [rax+0]      ; QueryInterface(IDXGIDevice)
    test    eax, eax
    jz      cp_have_dxgidev
    mov     edx, eax
    lea     rcx, szQiDevHr
    call    emit_num
    jmp     cp_adapter_checked

cp_have_dxgidev:
    mov     rcx, pDxgiDevice
    mov     rax, [rcx]
    lea     rdx, pDevAdapter
    call    qword ptr [rax+56]     ; IDXGIDevice::GetAdapter
    test    eax, eax
    jz      cp_have_devadapter
    mov     edx, eax
    lea     rcx, szGetAdHr
    call    emit_num
    jmp     cp_adapter_checked

cp_have_devadapter:
    mov     rcx, pDevAdapter
    mov     rax, [rcx]
    lea     rdx, devDesc
    call    qword ptr [rax+64]     ; IDXGIAdapter::GetDesc
    lea     rcx, szDevAdVnd
    mov     edx, dword ptr [devDesc+256]
    call    emit_num
    lea     rcx, szDevAdDev
    mov     edx, dword ptr [devDesc+260]
    call    emit_num
    mov     eax, dword ptr [adapterDesc+296]    ; LUID.LowPart
    cmp     eax, dword ptr [devDesc+296]
    jne     cp_adapter_diff
    mov     eax, dword ptr [adapterDesc+300]    ; LUID.HighPart
    cmp     eax, dword ptr [devDesc+300]
    jne     cp_adapter_diff
    lea     rcx, szSameAd
    call    emit_z
    jmp     cp_adapter_checked
cp_adapter_diff:
    lea     rcx, szDiffAd
    call    emit_z
cp_adapter_checked:
    ; ---- is the object behind pDevice really an ID3D11Device? ----
    mov     rcx, pDevice
    mov     rax, [rcx]
    lea     rdx, iidD3D11Device
    lea     r8, pProbe11
    call    qword ptr [rax+0]      ; QueryInterface(ID3D11Device)
    mov     edx, eax
    lea     rcx, szQiD11Hr
    call    emit_num
    mov     rcx, pProbe11
    call    rel_if
    mov     qword ptr [pProbe11], 0

    lea     rcx, szDevLevel
    mov     edx, devLevel
    call    emit_num

    xor     r12d, r12d             ; output index

cp_out_loop:
    mov     rcx, pAdapter
    mov     rax, [rcx]
    mov     edx, r12d
    lea     r8, pOutput
    call    qword ptr [rax+56]     ; EnumOutputs
    test    eax, eax
    jnz     cp_next_adapter

    mov     rcx, pOutput
    mov     rax, [rcx]
    lea     rdx, outDesc
    call    qword ptr [rax+56]     ; GetDesc
    lea     rcx, szOutName
    call    emit_z
    lea     rcx, ansiBuf
    lea     rdx, outDesc           ; WCHAR DeviceName[32]
    call    wc2a
    lea     rcx, ansiBuf
    call    emit_z

    lea     rcx, szAttached
    mov     edx, dword ptr [outDesc+80]   ; AttachedToDesktop
    call    emit_num

    ; Candidate size from DXGI_OUTPUT_DESC::DesktopCoordinates. Only the display whose mode is the
    ; one we stream becomes the capture source, and it must be the one that sets capW/capH: assigning
    ; them before the check let a later enumerated output overwrite the accepted one, which is what
    ; cut the desktop off at the wrong row and left the rest of the frame zero (green on the tablet).
    mov     eax, dword ptr [outDesc+72]
    sub     eax, dword ptr [outDesc+64]
    mov     ecx, dword ptr [outDesc+76]
    sub     ecx, dword ptr [outDesc+68]
    cmp     eax, 1920
    jne     cp_out_next
    cmp     ecx, 1280
    jne     cp_out_next
    mov     capW, eax
    mov     capH, ecx

    ; ---- IDXGIOutput1 (a prerequisite for DuplicateOutput) ----
    mov     rcx, pOutput
    mov     rax, [rcx]
    lea     rdx, iidOutput1
    lea     r8, pOutput1
    call    qword ptr [rax+0]      ; QueryInterface
    test    eax, eax
    jz      cp_have_output1
    mov     edx, eax
    lea     rcx, szQiFail
    call    emit_num
    jmp     cp_out_next

cp_have_output1:
    ; ---- prove pOutput1 really is an IDXGIOutput1: slot 15 = GetDisplayModeList1 ----
    lea     rcx, szOutPtr
    mov     edx, dword ptr [pOutput]
    call    emit_num
    lea     rcx, szOut1Ptr
    mov     edx, dword ptr [pOutput1]
    call    emit_num
    mov     dword ptr [numModes], 0
    mov     rcx, pOutput1
    mov     rax, [rcx]
    mov     edx, 87                ; DXGI_FORMAT_B8G8R8A8_UNORM
    xor     r8d, r8d
    lea     r9, numModes
    mov     qword ptr [rsp+20h], 0 ; pDesc = NULL -> just count the modes
    call    qword ptr [rax+120]
    mov     edx, eax
    lea     rcx, szModeHr
    call    emit_num
    lea     rcx, szNumModes
    mov     edx, numModes
    call    emit_num

    ; ---- DuplicateOutput(device, &dup) ----
    mov     rcx, pOutput1
    mov     rax, [rcx]
    mov     rdx, pDevice
    lea     r8, pDup
    call    qword ptr [rax+176]    ; DuplicateOutput (slot 22 — see dxgi1_2.h)
    test    eax, eax
    jz      cp_have_dup
    mov     edx, eax
    lea     rcx, szDupFail
    call    emit_num
    lea     rcx, ansiBuf
    call    emit_z
    jmp     cp_out_next

cp_have_dup:
    lea     rcx, szCapSrc
    call    emit_z
    lea     rcx, ansiBuf
    call    emit_z
    lea     rcx, szCrLf
    call    emit_z

cap_frame_begin:
    ; ---- AcquireNextFrame(5000, &frameInfo, &resource) ----
    call    mark_start
    mov     rcx, pDup
    mov     rax, [rcx]
    mov     edx, 16                        ; a short wait: a static display is the normal case, and a
                                           ; 5 second timeout throttled the loop to a frame every few
                                           ; seconds. The timeout path re-feeds the last frame, so the
                                           ; stream keeps flowing at capture speed either way.
    lea     r8, frameInfo
    lea     r9, pRes
    call    qword ptr [rax+64]
    test    eax, eax
    jz      cap_acq_ok
    ; DXGI_ERROR_WAIT_TIMEOUT (0x887A0027) means the captured display simply has not changed yet. That
    ; is not a failure: tearing the session down here is what left the app connected with zero frames
    ; sent while the virtual display sat still. Wait and try again.
    cmp     eax, 887A0027h
    jne     cap_acq_fail
    cmp     dword ptr [haveFrame], 0
    jne     cap_acq_resend
    ; No frame at all yet and the acquisition keeps timing out: that is a stale duplication. DXGI
    ; invalidates duplications on mode changes and the display then delivers nothing for this session
    ; (Rust on the very same display sees ~30 fps, so the frames are there). Waiting longer never helps
    ; - end the session so the serve loop rebuilds the capture stage and gets a fresh duplication.
    inc     dword ptr [acqTimeouts]
    cmp     dword ptr [acqTimeouts], 3
    jae     cap_frame_done
    jmp     cap_acq_wait
cap_acq_resend:
    ; A still desktop must not silence the stream: re-feed the frame we already hold in nv12Frame.
    call    run_encoder_loop
cap_acq_wait:
    mov     ecx, 5
    call    Sleep
    jmp     cap_frame_begin
cap_acq_ok:

    mov     dword ptr [acqTimeouts], 0
    ; ---- the acquired IDXGIResource is an ID3D11Texture2D ----
    mov     rcx, pRes
    mov     rax, [rcx]
    lea     rdx, iidTexture2D
    lea     r8, pTex
    call    qword ptr [rax+0]
    test    eax, eax
    jnz     cap_acq_fail

    lea     rcx, accAcquire
    call    mark_acc

    ; Trace the first few live frames: enough to see how far the cycle gets without flooding the log.
    cmp     dword ptr [liveMode], 0
    je      cap_trace_done
    mov     eax, liveCount
    cmp     eax, 4
    jae     cap_trace_done
    lea     rcx, szLiveFrame
    mov     edx, eax
    call    emit_num
cap_trace_done:

    ; Live mode skips the CPU-side copy and checksum, and reuses the video-processor objects built on
    ; the first frame: a frame then costs one GPU copy, one Blt and one NV12 readback.
    ; Per-frame video-processor setup, as in the milestone path. The cached-object variant crashed
    ; inside this block on the virtual display (the log dies right after "live frame #0"), and the
    ; per-frame cost is not the bottleneck anyway: blt 1 ms, readback 5-8 ms, pump 18 ms, the loop is
    ; paced by how often the captured display changes.
cap_staging_probe:
    ; ---- staging texture: the CPU-readable BGRA copy ----
    lea     r10, texDesc
    mov     eax, capW
    mov     dword ptr [r10], eax
    mov     eax, capH
    mov     dword ptr [r10+4], eax
    mov     dword ptr [r10+8], 1        ; MipLevels
    mov     dword ptr [r10+12], 1       ; ArraySize
    mov     dword ptr [r10+16], 87      ; DXGI_FORMAT_B8G8R8A8_UNORM
    mov     dword ptr [r10+20], 1       ; SampleDesc.Count
    mov     dword ptr [r10+24], 0       ; SampleDesc.Quality
    mov     dword ptr [r10+28], 3       ; D3D11_USAGE_STAGING
    mov     dword ptr [r10+32], 0       ; BindFlags
    mov     dword ptr [r10+36], 20000h  ; D3D11_CPU_ACCESS_READ
    mov     dword ptr [r10+40], 0       ; MiscFlags

    mov     rcx, pDevice
    mov     rax, [rcx]
    lea     rdx, texDesc
    xor     r8d, r8d
    lea     r9, pStaging
    call    qword ptr [rax+40]     ; CreateTexture2D
    test    eax, eax
    jnz     cap_cleanup

    ; ---- CopyResource(dst = staging, src = acquired) ----
    mov     rcx, pContext
    mov     rax, [rcx]
    mov     rdx, pStaging
    mov     r8, pTex
    call    qword ptr [rax+376]

    ; ---- Map(staging, 0, D3D11_MAP_READ, 0, &mapped) ----
    mov     rcx, pContext
    mov     rax, [rcx]
    mov     rdx, pStaging
    xor     r8d, r8d
    mov     r9d, 1
    mov     dword ptr [rsp+20h], 0         ; MapFlags
    lea     r10, mapped
    mov     qword ptr [rsp+28h], r10       ; pMappedResource (5th arg, NOT [rsp+20h])
    call    qword ptr [rax+112]
    test    eax, eax
    jnz     cap_cleanup

    ; ---- checksum the whole mapped frame: proof that real pixels came back ----
    mov     r11, qword ptr [mapped]        ; pData
    mov     r10d, dword ptr [mapped+8]     ; RowPitch
    mov     rowPitch, r10d
    mov     eax, r10d
    imul    eax, dword ptr [capH]          ; total bytes = RowPitch * Height
    mov     r10d, eax
    xor     edx, edx
    xor     eax, eax
cap_sum:
    cmp     eax, r10d
    jae     cap_sum_done
    movzx   r8d, byte ptr [r11+rax]
    add     edx, r8d
    inc     eax
    jmp     cap_sum
cap_sum_done:
    mov     checksum, edx

    lea     rcx, szCapW
    mov     edx, capW
    call    emit_num
    lea     rcx, szCapH
    mov     edx, capH
    call    emit_num
    lea     rcx, szRowPitch
    mov     edx, rowPitch
    call    emit_num
    lea     rcx, szChecksum
    mov     edx, checksum
    call    emit_num
    lea     rcx, szCapOk
    call    emit_z

    ; ---- Unmap(staging, 0) ----
    mov     rcx, pContext
    mov     rax, [rcx]
    mov     rdx, pStaging
    xor     r8d, r8d
    call    qword ptr [rax+120]

cap_vpp_setup:
    ; ================= D3D11 VideoProcessor: BGRA -> NV12 =================
    mov     rcx, pDevice
    mov     rax, [rcx]
    lea     rdx, iidVideoDevice
    lea     r8, pVideoDevice
    call    qword ptr [rax+0]              ; QI(ID3D11VideoDevice)
    test    eax, eax
    jnz     vp_qi_fail

    mov     rcx, pContext
    mov     rax, [rcx]
    lea     rdx, iidVideoContext
    lea     r8, pVideoContext
    call    qword ptr [rax+0]              ; QI(ID3D11VideoContext)
    test    eax, eax
    jnz     vp_ctx_fail

    ; content desc: progressive, 30 fps, capW x capH both ways, OPTIMAL_SPEED
    lea     r10, vpContent
    mov     qword ptr [r10], 0
    mov     qword ptr [r10+8], 0
    mov     qword ptr [r10+16], 0
    mov     qword ptr [r10+24], 0
    mov     qword ptr [r10+32], 0
    mov     dword ptr [r10+4], 30          ; InputFrameRate.Numerator
    mov     dword ptr [r10+8], 1           ; InputFrameRate.Denominator
    mov     eax, capW
    mov     dword ptr [r10+12], eax        ; InputWidth
    mov     eax, capH
    mov     dword ptr [r10+16], eax        ; InputHeight
    mov     dword ptr [r10+20], 30         ; OutputFrameRate.Numerator
    mov     dword ptr [r10+24], 1          ; OutputFrameRate.Denominator
    mov     eax, capW
    mov     dword ptr [r10+28], eax        ; OutputWidth
    mov     eax, capH
    mov     dword ptr [r10+32], eax        ; OutputHeight
    mov     dword ptr [r10+36], 1          ; D3D11_VIDEO_USAGE_OPTIMAL_SPEED

    mov     rcx, pVideoDevice
    mov     rax, [rcx]
    lea     rdx, vpContent
    lea     r8, pVpEnum
    call    qword ptr [rax+80]             ; CreateVideoProcessorEnumerator
    test    eax, eax
    jnz     vp_enum_fail

    mov     rcx, pVideoDevice
    mov     rax, [rcx]
    mov     rdx, pVpEnum
    xor     r8d, r8d
    lea     r9, pVpProc
    call    qword ptr [rax+32]             ; CreateVideoProcessor
    test    eax, eax
    jnz     vp_proc_fail

    mov     dword ptr [vpInSpace], 0       ; full-range RGB in
    mov     dword ptr [vpOutSpace], 2      ; nominal range out
    mov     rcx, pVideoContext
    mov     rax, [rcx]
    mov     rdx, pVpProc
    xor     r8d, r8d
    lea     r9, vpInSpace
    call    qword ptr [rax+224]            ; VideoProcessorSetStreamColorSpace
    mov     rcx, pVideoContext
    mov     rax, [rcx]
    mov     rdx, pVpProc
    lea     r8, vpOutSpace
    call    qword ptr [rax+120]            ; VideoProcessorSetOutputColorSpace
    mov     rcx, pVideoContext
    mov     rax, [rcx]
    mov     rdx, pVpProc
    xor     r8d, r8d
    xor     r9d, r9d
    call    qword ptr [rax+216]            ; SetStreamFrameFormat(PROGRESSIVE = 0)

    ; NV12 render-target texture
    lea     r10, texDesc
    mov     eax, capW
    mov     dword ptr [r10], eax
    mov     eax, capH
    mov     dword ptr [r10+4], eax
    mov     dword ptr [r10+8], 1           ; MipLevels
    mov     dword ptr [r10+12], 1          ; ArraySize
    mov     dword ptr [r10+16], 103        ; DXGI_FORMAT_NV12
    mov     dword ptr [r10+20], 1          ; SampleDesc.Count
    mov     dword ptr [r10+24], 0          ; SampleDesc.Quality
    mov     dword ptr [r10+28], 0          ; D3D11_USAGE_DEFAULT
    mov     dword ptr [r10+32], 20h        ; D3D11_BIND_RENDER_TARGET
    mov     dword ptr [r10+36], 0          ; CPUAccessFlags
    mov     dword ptr [r10+40], 0          ; MiscFlags
    mov     rcx, pDevice
    mov     rax, [rcx]
    lea     rdx, texDesc
    xor     r8d, r8d
    lea     r9, pNv12Tex
    call    qword ptr [rax+40]             ; CreateTexture2D
    test    eax, eax
    jnz     vp_nv12_fail

    lea     r10, vpOutDesc
    mov     qword ptr [r10], 0
    mov     qword ptr [r10+8], 0
    mov     dword ptr [r10+0], 1           ; D3D11_VPOV_DIMENSION_TEXTURE2D
    mov     dword ptr [r10+4], 0           ; MipSlice
    mov     rcx, pVideoDevice
    mov     rax, [rcx]
    mov     rdx, pNv12Tex
    mov     r8, pVpEnum
    lea     r9, vpOutDesc
    lea     r10, pNv12View
    mov     qword ptr [rsp+20h], r10
    call    qword ptr [rax+72]             ; CreateVideoProcessorOutputView
    test    eax, eax
    jnz     vp_oview_fail

    ; Our own BGRA texture: the video processor reads from this one, so its input view can be created
    ; once and reused - each frame copies the freshly acquired desktop image into it.
    lea     r10, texDesc
    mov     eax, capW
    mov     dword ptr [r10], eax
    mov     eax, capH
    mov     dword ptr [r10+4], eax
    mov     dword ptr [r10+8], 1           ; MipLevels
    mov     dword ptr [r10+12], 1          ; ArraySize
    mov     dword ptr [r10+16], 87         ; DXGI_FORMAT_B8G8R8A8_UNORM
    mov     dword ptr [r10+20], 1          ; SampleDesc.Count
    mov     dword ptr [r10+24], 0          ; SampleDesc.Quality
    mov     dword ptr [r10+28], 0          ; D3D11_USAGE_DEFAULT
    mov     dword ptr [r10+32], 20h        ; D3D11_BIND_RENDER_TARGET (a VP input view needs it)
    mov     dword ptr [r10+36], 0          ; CPUAccessFlags
    mov     dword ptr [r10+40], 0          ; MiscFlags
    mov     rcx, pDevice
    mov     rax, [rcx]
    lea     rdx, texDesc
    xor     r8d, r8d
    lea     r9, pBgraTex
    call    qword ptr [rax+40]             ; CreateTexture2D
    test    eax, eax
    jnz     vp_bgra_fail

    lea     r10, vpInDesc
    mov     qword ptr [r10], 0
    mov     qword ptr [r10+8], 0
    mov     dword ptr [r10+0], 0           ; FourCC
    mov     dword ptr [r10+4], 1           ; D3D11_VPIV_DIMENSION_TEXTURE2D
    mov     rcx, pVideoDevice
    mov     rax, [rcx]
    mov     rdx, pBgraTex
    mov     r8, pVpEnum
    lea     r9, vpInDesc
    lea     r10, pVpInView
    mov     qword ptr [rsp+20h], r10
    call    qword ptr [rax+64]             ; CreateVideoProcessorInputView
    test    eax, eax
    jnz     vp_iview_fail

    ; ---- the desktop image the video processor will read this time round ----
cap_after_setup:
    mov     rcx, pContext
    mov     rax, [rcx]
    mov     rdx, pBgraTex
    mov     r8, pTex
    call    qword ptr [rax+376]            ; CopyResource(our BGRA, acquired)

    lea     r10, vpStream
    mov     qword ptr [r10], 0
    mov     qword ptr [r10+8], 0
    mov     qword ptr [r10+16], 0
    mov     qword ptr [r10+24], 0
    mov     qword ptr [r10+32], 0
    mov     qword ptr [r10+40], 0
    mov     qword ptr [r10+48], 0
    mov     qword ptr [r10+56], 0
    mov     qword ptr [r10+64], 0
    mov     dword ptr [r10+0], 1           ; Enable
    mov     rax, pVpInView
    mov     qword ptr [r10+32], rax        ; pInputSurface

    call    mark_start
    mov     rcx, pVideoContext
    mov     rax, [rcx]
    mov     rdx, pVpProc
    mov     r8, pNv12View
    xor     r9d, r9d                       ; OutputFrame
    mov     qword ptr [rsp+20h], 1         ; NumStreams
    lea     r10, vpStream
    mov     qword ptr [rsp+28h], r10       ; pStreams
    call    qword ptr [rax+424]            ; VideoProcessorBlt
    test    eax, eax
    jnz     vp_blt_fail
    lea     rcx, accBlt
    call    mark_acc
    lea     rcx, szVpOk
    call    emit_z

    ; ---- read the NV12 result back through a staging texture ----
    lea     r10, texDesc
    mov     eax, capW
    mov     dword ptr [r10], eax
    mov     eax, capH
    mov     dword ptr [r10+4], eax
    mov     dword ptr [r10+8], 1
    mov     dword ptr [r10+12], 1
    mov     dword ptr [r10+16], 103        ; DXGI_FORMAT_NV12
    mov     dword ptr [r10+20], 1
    mov     dword ptr [r10+24], 0
    mov     dword ptr [r10+28], 3          ; D3D11_USAGE_STAGING
    mov     dword ptr [r10+32], 0
    mov     dword ptr [r10+36], 20000h     ; D3D11_CPU_ACCESS_READ
    mov     dword ptr [r10+40], 0
    mov     rcx, pDevice
    mov     rax, [rcx]
    lea     rdx, texDesc
    xor     r8d, r8d
    lea     r9, pNv12Stg
    call    qword ptr [rax+40]             ; CreateTexture2D
    test    eax, eax
    jnz     vp_stg_fail

    cmp     dword ptr [liveMode], 0
    je      cap_stg_created
    mov     dword ptr [vppReady], 1        ; live mode: everything above is now reusable
cap_stg_created:

    mov     rcx, pContext
    mov     rax, [rcx]
    mov     rdx, pNv12Stg
    mov     r8, pNv12Tex
    call    qword ptr [rax+376]            ; CopyResource

    call    mark_start
    mov     rcx, pContext
    mov     rax, [rcx]
    mov     rdx, pNv12Stg
    xor     r8d, r8d
    mov     r9d, 1
    mov     dword ptr [rsp+20h], 0
    lea     r10, mapped
    mov     qword ptr [rsp+28h], r10
    call    qword ptr [rax+112]            ; Map
    test    eax, eax
    jnz     vp_map_fail

    ; Live mode only needs the pixels: the byte-at-a-time sums below walk the whole frame (3.6M
    ; iterations) and cost far more than the encode they are meant to prove.
    cmp     dword ptr [liveMode], 0
    jne     vp_copy_start

    mov     r11, qword ptr [mapped]        ; pData
    mov     r10d, dword ptr [mapped+8]     ; RowPitch
    mov     eax, r10d
    imul    eax, dword ptr [capH]
    mov     r12d, eax                      ; luma plane bytes
    xor     edx, edx
    xor     eax, eax
vp_ysum:
    cmp     eax, r12d
    jae     vp_ysum_done
    movzx   r8d, byte ptr [r11+rax]
    add     edx, r8d
    inc     eax
    jmp     vp_ysum
vp_ysum_done:
    mov     ySum, edx

    mov     r9, r11
    add     r9, r12                        ; chroma plane follows luma
    mov     eax, dword ptr [capH]
    shr     eax, 1
    imul    eax, r10d
    mov     r13d, eax                      ; chroma plane bytes
    xor     edx, edx
    xor     eax, eax
vp_uvsum:
    cmp     eax, r13d
    jae     vp_uvsum_done
    movzx   r8d, byte ptr [r9+rax]
    add     edx, r8d
    inc     eax
    jmp     vp_uvsum
vp_uvsum_done:
    mov     uvSum, edx

vp_copy_start:
    ; ---- stash the real NV12 frame for the encoder stage ----
    ; The staging texture's row pitch may exceed the frame width, so rows are copied one by one
    ; (qword at a time, byte tail) instead of one big block.
    push    rsi
    push    rdi

    xor     r8d, r8d                       ; row index
    mov     r11, qword ptr [mapped]        ; source base
    mov     r10d, dword ptr [mapped+8]     ; source pitch
    mov     r9d, dword ptr [capW]          ; bytes per luma row
    mov     edx, dword ptr [capH]
    mov     eax, edx
    shr     eax, 1
    add     edx, eax                       ; total rows = height * 3 / 2
vp_copy:
    cmp     r8d, edx
    jae     vp_copy_done
    mov     eax, r8d
    imul    eax, r10d                      ; row * rowPitch
    lea     rsi, [r11+rax]
    mov     eax, r8d
    imul    eax, r9d                       ; row * width
    lea     rdi, nv12Frame
    add     rdi, rax
    mov     ecx, r9d                       ; bytes in this row
    shr     ecx, 3                         ; qwords
vp_copy_q:
    mov     rax, qword ptr [rsi]
    mov     qword ptr [rdi], rax
    add     rsi, 8
    add     rdi, 8
    dec     ecx
    jnz     vp_copy_q
    mov     ecx, r9d
    and     ecx, 7                         ; tail bytes, if the row is not a multiple of 8
vp_copy_b:
    jz      vp_copy_bdone
    movzx   eax, byte ptr [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jmp     vp_copy_b
vp_copy_bdone:
    inc     r8d
    jmp     vp_copy
vp_copy_done:
    pop     rdi
    pop     rsi
    lea     rcx, accRead
    call    mark_acc
    mov     dword ptr [haveFrame], 1
    cmp     dword ptr [liveMode], 0
    jne     cap_frame_logged               ; live mode: no per-frame chatter in the log
    lea     rcx, szVpCopyDone
    call    emit_z
cap_frame_logged:

    mov     rcx, pContext
    mov     rax, [rcx]
    mov     rdx, pNv12Stg
    xor     r8d, r8d
    call    qword ptr [rax+120]            ; Unmap

    cmp     dword ptr [liveMode], 0
    jne     cap_frame_live
    lea     rcx, szYSum
    mov     edx, ySum
    call    emit_num
    lea     rcx, szUvSum
    mov     edx, uvSum
    call    emit_num
    jmp     cap_cleanup

cap_frame_live:
    ; ---- live mode: hand this frame to the encoder and take the next one ----
    ; The virtual display presents at 60 Hz, but the hardware MFT sizes its output sample for the
    ; configured bitrate at 30 fps (12e6/8/30 = 50000 bytes) and clips anything larger. Encoding every
    ; other captured frame keeps the feed inside that budget and keeps the sample times honest.
    xor     dword ptr [feedToggle], 1
    inc     dword ptr [liveCount]
    mov     eax, liveCount
    cmp     eax, liveFrames
    jae     cap_frame_done

    ; The MFT emits its keyframe on the first frame it is fed, and the first frame of a session can be
    ; empty because the desktop is not composited yet. Feeding that one gives the client a black
    ; keyframe and every later frame is a P-frame against it, so the tablet stays black. Drop it.
    cmp     dword ptr [liveCount], 1
    jne     cap_live_feed
    call    cap_release_frame
    jmp     cap_frame_begin
cap_live_feed:

    cmp     dword ptr [feedToggle], 0
    je      cap_frame_release
    call    mark_start
    call    run_encoder_loop               ; pump: feeds on need-input, drains and sends on have-output
    lea     rcx, accPump
    call    mark_acc
    inc     dword ptr [accFrames]
    cmp     dword ptr [streamSock], 0      ; the client went away
    je      cap_frame_done
cap_frame_release:
    call    cap_release_frame
    jmp     cap_frame_begin

cap_frame_done:
    ; Let the client drain what is still queued instead of losing it to an abortive close.
    mov     ecx, streamSock
    test    ecx, ecx
    jz      cap_frame_cleanup
    mov     edx, 1                         ; SD_SEND
    call    shutdown
    mov     dword ptr [streamSock], 0
cap_frame_cleanup:
    jmp     cap_cleanup

cp_out_next:
    mov     rcx, pOutput1
    call    rel_if
    mov     qword ptr [pOutput1], 0
    mov     rcx, pOutput
    call    rel_if
    mov     qword ptr [pOutput], 0
    inc     r12d
    jmp     cp_out_loop

cp_next_adapter:
    mov     rcx, pDxgiDevice
    call    rel_if
    mov     qword ptr [pDxgiDevice], 0
    mov     rcx, pDevAdapter
    call    rel_if
    mov     qword ptr [pDevAdapter], 0
    mov     rcx, pOutput1
    call    rel_if
    mov     qword ptr [pOutput1], 0
    mov     rcx, pOutput
    call    rel_if
    mov     qword ptr [pOutput], 0
    mov     rcx, pDevice
    call    rel_if
    mov     qword ptr [pDevice], 0
    mov     rcx, pContext
    call    rel_if
    mov     qword ptr [pContext], 0
    mov     rcx, pAdapter
    call    rel_if
    mov     qword ptr [pAdapter], 0
    inc     r13d
    jmp     cp_adapt_loop

cap_nodup:
    lea     rcx, szNoDup
    call    emit_z
    jmp     cap_cleanup

cap_acq_fail:
    mov     edx, eax
    lea     rcx, szAcqFail
    call    emit_num
    jmp     cap_cleanup

vp_qi_fail:
    mov     edx, eax
    lea     rcx, szVpQi
    call    emit_num
    jmp     cap_cleanup
vp_ctx_fail:
    mov     edx, eax
    lea     rcx, szVpCtx
    call    emit_num
    jmp     cap_cleanup
vp_enum_fail:
    mov     edx, eax
    lea     rcx, szVpEnum
    call    emit_num
    jmp     cap_cleanup
vp_proc_fail:
    mov     edx, eax
    lea     rcx, szVpProc
    call    emit_num
    jmp     cap_cleanup
vp_nv12_fail:
    mov     edx, eax
    lea     rcx, szVpNv12
    call    emit_num
    jmp     cap_cleanup
vp_oview_fail:
    mov     edx, eax
    lea     rcx, szVpOView
    call    emit_num
    jmp     cap_cleanup
vp_bgra_fail:
    mov     edx, eax
    lea     rcx, szVpBgra
    call    emit_num
    jmp     cap_cleanup
vp_iview_fail:
    mov     edx, eax
    lea     rcx, szVpIView
    call    emit_num
    jmp     cap_cleanup
vp_blt_fail:
    mov     edx, eax
    lea     rcx, szVpBlt
    call    emit_num
    jmp     cap_cleanup
vp_stg_fail:
    mov     edx, eax
    lea     rcx, szVpStg
    call    emit_num
    jmp     cap_cleanup
vp_map_fail:
    mov     edx, eax
    lea     rcx, szVpMap
    call    emit_num

cap_cleanup:
    mov     rcx, pRes
    call    rel_if
    mov     qword ptr [pRes], 0
    mov     rcx, pTex
    call    rel_if
    mov     qword ptr [pTex], 0
    mov     rcx, pStaging
    call    rel_if
    mov     qword ptr [pStaging], 0
    mov     rcx, pNv12Stg
    call    rel_if
    mov     qword ptr [pNv12Stg], 0
    mov     rcx, pNv12View
    call    rel_if
    mov     qword ptr [pNv12View], 0
    mov     rcx, pNv12Tex
    call    rel_if
    mov     qword ptr [pNv12Tex], 0
    mov     rcx, pVpInView
    call    rel_if
    mov     qword ptr [pVpInView], 0
    mov     rcx, pVpProc
    call    rel_if
    mov     qword ptr [pVpProc], 0
    mov     rcx, pVpEnum
    call    rel_if
    mov     qword ptr [pVpEnum], 0
    mov     rcx, pVideoContext
    call    rel_if
    mov     qword ptr [pVideoContext], 0
    mov     rcx, pVideoDevice
    call    rel_if
    mov     qword ptr [pVideoDevice], 0
    mov     rcx, pDup
    test    rcx, rcx
    jz      cap_no_dup
    mov     rax, [rcx]
    call    qword ptr [rax+112]    ; ReleaseFrame (no-op if nothing was acquired)
cap_no_dup:
    mov     rcx, pDup
    call    rel_if
    mov     rcx, pContext
    call    rel_if
    mov     rcx, pDxgiDevice
    call    rel_if
    mov     rcx, pDevAdapter
    call    rel_if
    mov     rcx, pDevice
    call    rel_if
    mov     rcx, pOutput1
    call    rel_if
    mov     rcx, pOutput
    call    rel_if
    mov     rcx, pAdapter
    call    rel_if
    mov     rcx, pFactory
    call    rel_if

    add     rsp, 88h
    pop     r13
    pop     r12
    ret
run_capture_probe endp

; Release what a single captured frame owns and hand the desktop image back to DXGI. The device, the
; duplication and the output stay up, so the live loop can take the next frame straight away. This is
; the per-frame half of the teardown below; Clobbers rax/rcx/rdx.
cap_release_frame proc
    sub     rsp, 28h
    ; Live mode keeps the video-processor objects, the NV12 staging texture and the video device
    ; alive across frames: one frame owns only the acquired desktop image and the duplication lease.
    cmp     dword ptr [liveMode], 0
    je      crf_release_all
    cmp     dword ptr [vppReady], 0
    je      crf_release_all
crf_release_all:
    mov     rcx, pRes
    call    rel_if
    mov     qword ptr [pRes], 0
    mov     rcx, pTex
    call    rel_if
    mov     qword ptr [pTex], 0
    mov     rcx, pStaging
    call    rel_if
    mov     qword ptr [pStaging], 0
    mov     rcx, pNv12Stg
    call    rel_if
    mov     qword ptr [pNv12Stg], 0
    mov     rcx, pNv12View
    call    rel_if
    mov     qword ptr [pNv12View], 0
    mov     rcx, pNv12Tex
    call    rel_if
    mov     qword ptr [pNv12Tex], 0
    mov     rcx, pVpInView
    call    rel_if
    mov     qword ptr [pVpInView], 0
    mov     rcx, pVpProc
    call    rel_if
    mov     qword ptr [pVpProc], 0
    mov     rcx, pVpEnum
    call    rel_if
    mov     qword ptr [pVpEnum], 0
    mov     rcx, pVideoContext
    call    rel_if
    mov     qword ptr [pVideoContext], 0
    mov     rcx, pVideoDevice
    call    rel_if
    mov     qword ptr [pVideoDevice], 0
    ; The BGRA texture is 1920x1280x4 = 9.8 MB and is rebuilt every frame, so missing it here leaked
    ; hundreds of megabytes a second and took the machine to 95% RAM.
    mov     rcx, pBgraTex
    call    rel_if
    mov     qword ptr [pBgraTex], 0
crf_lease:
    mov     rcx, pDup
    test    rcx, rcx
    jz      crf_done
    mov     rax, [rcx]
    call    qword ptr [rax+112]            ; ReleaseFrame
crf_done:
    add     rsp, 28h
    ret
cap_release_frame endp

; Release a COM interface if the pointer is non-null: rcx = pointer. Clobbers rax/rdx.
rel_if proc
    sub     rsp, 8
    test    rcx, rcx
    jz      rel_if_done
    mov     rax, [rcx]
    call    qword ptr [rax+16]     ; IUnknown::Release
rel_if_done:
    add     rsp, 8
    ret
rel_if endp

; Copy a 16-byte GUID: rcx = dest, rdx = src.
copy16 proc
    mov     rax, qword ptr [rdx]
    mov     qword ptr [rcx], rax
    mov     rax, qword ptr [rdx+8]
    mov     qword ptr [rcx+8], rax
    ret
copy16 endp

; ---- per-stage timing: mark_start before the work, mark_acc(accumulator) after it ----
mark_start proc
    sub     rsp, 28h
    lea     rcx, qpcTmp
    call    QueryPerformanceCounter
    mov     rax, qpcTmp
    mov     tMark, rax
    add     rsp, 28h
    ret
mark_start endp

; rcx = accumulator. Ticks are kept raw; the report divides by the measured frequency.
mark_acc proc
    sub     rsp, 28h
    mov     accPtr, rcx
    lea     rcx, qpcTmp
    call    QueryPerformanceCounter
    mov     rcx, accPtr
    mov     rax, qpcTmp
    sub     rax, tMark
    add     qword ptr [rcx], rax
    add     rsp, 28h
    ret
mark_acc endp

; rcx = ticks -> eax = milliseconds. Clobbers rax/rcx/rdx/r8.
ticks_to_ms proc
    mov     rax, rcx
    xor     edx, edx
    mov     r8, 1000
    mul     r8
    mov     rcx, qpcFreq
    test    rcx, rcx
    jz      ttm_done
    div     rcx
ttm_done:
    ret
ticks_to_ms endp

; One line of totals plus one of per-frame averages for the live loop.
emit_stage_report proc
    sub     rsp, 38h

    mov     rcx, accAcquire
    call    ticks_to_ms
    mov     edx, eax
    lea     rcx, szStageHead
    call    emit_num
    mov     rcx, accBlt
    call    ticks_to_ms
    mov     edx, eax
    lea     rcx, szStageBlt
    call    emit_num
    mov     rcx, accRead
    call    ticks_to_ms
    mov     edx, eax
    lea     rcx, szStageRead
    call    emit_num
    mov     rcx, accPump
    call    ticks_to_ms
    mov     edx, eax
    lea     rcx, szStagePump
    call    emit_num
    lea     rcx, szStageFrames
    mov     edx, accFrames
    call    emit_num
    lea     rcx, szStageCrlf
    call    emit_z

    mov     ecx, accFrames
    test    ecx, ecx
    jz      esr_done
    mov     divisor, ecx

    mov     rcx, accAcquire
    call    ticks_to_ms
    xor     edx, edx
    div     divisor
    mov     edx, eax
    lea     rcx, szStageHeadPf
    call    emit_num
    mov     rcx, accBlt
    call    ticks_to_ms
    xor     edx, edx
    div     divisor
    mov     edx, eax
    lea     rcx, szStageBltPf
    call    emit_num
    mov     rcx, accRead
    call    ticks_to_ms
    xor     edx, edx
    div     divisor
    mov     edx, eax
    lea     rcx, szStageReadPf
    call    emit_num
    mov     rcx, accPump
    call    ticks_to_ms
    xor     edx, edx
    div     divisor
    mov     edx, eax
    lea     rcx, szStagePumpPf
    call    emit_num

esr_done:
    lea     rcx, szStageCrlf
    call    emit_z
    add     rsp, 38h
    ret
emit_stage_report endp

; Media Foundation HEVC encoder probe: start the platform, enumerate the hardware HEVC encoder
; MFT, activate it, unlock async + low latency, set the HEVC output type and the NV12 input type,
; then begin streaming.
;
; Vtable slots (see mftransform.h / mfobjects.h):
;   IMFTransform: GetOutputStreamInfo = 56, GetAttributes = 64, SetInputType = 120,
;                 SetOutputType = 128, ProcessMessage = 184, ProcessInput = 192, ProcessOutput = 200
;   IMFAttributes: SetUINT32 = 168, SetUINT64 = 176, SetGUID = 192
;   IMFActivate: ActivateObject = 264
;   IMFMediaEventGenerator: GetEvent = 24 ; IMFMediaEvent: GetType = 264
; Release everything a previous session left behind, including the Media Foundation platform itself.
; The hardware encoder MFT keeps memory per encoded frame until the platform is torn down - the same
; phenomenon that made the Rust host leak - and this host creates a new encoder for every session
; without ever letting the old one go. Left alone, that is megabytes per frame of growth.
release_previous_encoder proc
    sub     rsp, 28h
    mov     rcx, pInSample
    call    rel_if
    mov     qword ptr [pInSample], 0
    mov     rcx, pInBuf
    call    rel_if
    mov     qword ptr [pInBuf], 0
    mov     rcx, pContig
    call    rel_if
    mov     qword ptr [pContig], 0
    mov     rcx, pEvent
    call    rel_if
    mov     qword ptr [pEvent], 0
    mov     rcx, pEventGen
    call    rel_if
    mov     qword ptr [pEventGen], 0
    mov     rcx, pOutType
    call    rel_if
    mov     qword ptr [pOutType], 0
    mov     rcx, pInType
    call    rel_if
    mov     qword ptr [pInType], 0
    mov     rcx, pAttrs
    call    rel_if
    mov     qword ptr [pAttrs], 0
    mov     rcx, pTransform
    call    rel_if
    mov     qword ptr [pTransform], 0
    mov     rcx, pActivate
    call    rel_if
    mov     qword ptr [pActivate], 0
    ; The CoTaskMem list is freed by the probe itself; only the transform and the platform matter here.
    call    MFShutdown             ; gives the driver back what its MFT retained for this session
    add     rsp, 28h
    ret
release_previous_encoder endp

run_encoder_probe proc
    push    r12
    push    r13
    sub     rsp, 88h

    call    release_previous_encoder

    mov     qword ptr [pActivates], 0
    mov     qword ptr [pActivate], 0
    mov     qword ptr [pTransform], 0
    mov     qword ptr [pAttrs], 0
    mov     qword ptr [pOutType], 0
    mov     qword ptr [pInType], 0
    mov     dword ptr [mftCount], 0

    mov     ecx, 20070h                    ; MF_VERSION
    xor     edx, edx
    call    MFStartup
    test    eax, eax
    jz      mf_started
    mov     edx, eax
    lea     rcx, szMfStart
    call    emit_num
    jmp     enc_done

mf_started:
    lea     rcx, mftRegInfo                ; MFT_REGISTER_TYPE_INFO{ video, HEVC }
    lea     rdx, mediaTypeVideo
    call    copy16
    lea     rcx, mftRegInfo+16
    lea     rdx, fmtHEVC
    call    copy16

    lea     rcx, mftCatVideoEnc
    mov     edx, 44h                       ; MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER
    xor     r8d, r8d
    lea     r9, mftRegInfo
    lea     rax, pActivates
    mov     qword ptr [rsp+20h], rax
    lea     rax, mftCount
    mov     qword ptr [rsp+28h], rax
    call    MFTEnumEx
    test    eax, eax
    jz      mf_enumed
    mov     edx, eax
    lea     rcx, szMfEnum
    call    emit_num
    jmp     enc_done

mf_enumed:
    lea     rcx, szMfFound
    mov     edx, mftCount
    call    emit_num
    cmp     dword ptr [mftCount], 0
    jz      enc_cleanup
    mov     rax, pActivates
    mov     rcx, qword ptr [rax]
    mov     pActivate, rcx
    test    rcx, rcx
    jz      enc_cleanup
    mov     rax, [rcx]
    lea     rdx, iidIMFTransform
    lea     r8, pTransform
    call    qword ptr [rax+264]            ; IMFActivate::ActivateObject
    test    eax, eax
    jz      mf_activated
    mov     edx, eax
    lea     rcx, szMfActivate
    call    emit_num
    jmp     enc_cleanup

mf_activated:
    mov     rcx, pTransform
    mov     rax, [rcx]
    lea     rdx, pAttrs
    call    qword ptr [rax+64]             ; GetAttributes
    test    eax, eax
    jz      mf_got_attrs
    mov     edx, eax
    lea     rcx, szMfAttrs
    call    emit_num
    jmp     enc_cleanup

mf_got_attrs:
    mov     rcx, pAttrs
    mov     rax, [rcx]
    lea     rdx, mfAsyncUnlock
    mov     r8d, 1
    call    qword ptr [rax+168]            ; MF_TRANSFORM_ASYNC_UNLOCK
    mov     rcx, pAttrs
    mov     rax, [rcx]
    lea     rdx, mfLowLatency
    mov     r8d, 1
    call    qword ptr [rax+168]            ; MF_LOW_LATENCY

    ; ---- output type: HEVC 1920x1280 @30, 30 Mbps ----
    lea     rcx, pOutType
    call    MFCreateMediaType
    test    eax, eax
    jz      mf_out_created
    mov     edx, eax
    lea     rcx, szMfCreate
    call    emit_num
    jmp     enc_cleanup

mf_out_created:
    mov     rcx, pOutType
    mov     rax, [rcx]
    lea     rdx, mfMtMajorType
    lea     r8, mediaTypeVideo
    call    qword ptr [rax+192]            ; SetGUID(MAJOR, video)
    mov     rcx, pOutType
    mov     rax, [rcx]
    lea     rdx, mfMtSubtype
    lea     r8, fmtHEVC
    call    qword ptr [rax+192]            ; SetGUID(SUBTYPE, HEVC)
    mov     rcx, pOutType
    mov     rax, [rcx]
    lea     rdx, mfMtAvgBitrate
    mov     r8d, 1C9C380h                  ; 30 000 000: the rate control sizes its output sample for
                                           ; the average bitrate at the declared 30 fps, and at the
                                           ; capture rate we actually feed, 12 Mbps clipped most frames
    call    qword ptr [rax+168]            ; SetUINT32(AVG_BITRATE)
    mov     rcx, pOutType
    mov     rax, [rcx]
    lea     rdx, mfMtInterlace
    mov     r8d, 2                         ; MFVideoInterlace_Progressive
    call    qword ptr [rax+168]            ; SetUINT32(INTERLACE_MODE)
    mov     rcx, pOutType
    mov     rax, [rcx]
    lea     rdx, mfMtFrameSize
    mov     r8, 78000000500h               ; 1920 << 32 | 1280 - must match what READY announces
                                           ; and what nv12Frame holds, or the decoder shows garbage
    call    qword ptr [rax+176]            ; SetUINT64(FRAME_SIZE)
    mov     rcx, pOutType
    mov     rax, [rcx]
    lea     rdx, mfMtFrameRate
    mov     r8, 1E00000001h                ; 30 << 32 | 1
    call    qword ptr [rax+176]            ; SetUINT64(FRAME_RATE)
    mov     rcx, pOutType
    mov     rax, [rcx]
    lea     rdx, mfMtPixelAspect
    mov     r8, 100000001h                 ; 1 << 32 | 1
    call    qword ptr [rax+176]            ; SetUINT64(PIXEL_ASPECT_RATIO)

    mov     rcx, pTransform
    mov     rax, [rcx]
    xor     edx, edx
    mov     r8, pOutType
    xor     r9d, r9d
    call    qword ptr [rax+128]            ; SetOutputType(0, type, 0)
    test    eax, eax
    jz      mf_out_set
    mov     edx, eax
    lea     rcx, szMfOutType
    call    emit_num
    jmp     enc_cleanup

mf_out_set:
    ; ---- input type: NV12, same geometry ----
    lea     rcx, pInType
    call    MFCreateMediaType
    test    eax, eax
    jz      mf_in_created
    mov     edx, eax
    lea     rcx, szMfCreate
    call    emit_num
    jmp     enc_cleanup

mf_in_created:
    mov     rcx, pInType
    mov     rax, [rcx]
    lea     rdx, mfMtMajorType
    lea     r8, mediaTypeVideo
    call    qword ptr [rax+192]
    mov     rcx, pInType
    mov     rax, [rcx]
    lea     rdx, mfMtSubtype
    lea     r8, fmtNV12
    call    qword ptr [rax+192]            ; SetGUID(SUBTYPE, NV12)
    mov     rcx, pInType
    mov     rax, [rcx]
    lea     rdx, mfMtInterlace
    mov     r8d, 2
    call    qword ptr [rax+168]
    mov     rcx, pInType
    mov     rax, [rcx]
    lea     rdx, mfMtFrameSize
    mov     r8, 78000000500h               ; 1920 << 32 | 1280 - the input type has to describe the
                                           ; frame we actually feed, not the old 1080 one
    call    qword ptr [rax+176]
    mov     rcx, pInType
    mov     rax, [rcx]
    lea     rdx, mfMtFrameRate
    mov     r8, 1E00000001h
    call    qword ptr [rax+176]
    mov     rcx, pInType
    mov     rax, [rcx]
    lea     rdx, mfMtPixelAspect
    mov     r8, 100000001h
    call    qword ptr [rax+176]

    mov     rcx, pTransform
    mov     rax, [rcx]
    xor     edx, edx
    mov     r8, pInType
    xor     r9d, r9d
    call    qword ptr [rax+120]            ; SetInputType(0, type, 0)
    test    eax, eax
    jz      mf_in_set
    mov     edx, eax
    lea     rcx, szMfInType
    call    emit_num
    jmp     enc_cleanup

mf_in_set:
    mov     rcx, pTransform
    mov     rax, [rcx]
    xor     edx, edx
    lea     r8, mftOutInfo
    call    qword ptr [rax+56]             ; GetOutputStreamInfo(0)
    test    eax, eax
    jnz     enc_cleanup
    mov     eax, dword ptr [mftOutInfo]
    and     eax, 300h                      ; PROVIDES_SAMPLES | CAN_PROVIDE_SAMPLES
    mov     providesSamples, eax
    mov     eax, dword ptr [mftOutInfo+4]
    mov     outBufSize, eax
    lea     rcx, szMfOutSize
    mov     edx, outBufSize
    call    emit_num
    lea     rcx, szMfSupplies
    mov     edx, providesSamples
    call    emit_num

    mov     rcx, pTransform
    mov     rax, [rcx]
    mov     edx, 10000000h                 ; MFT_MESSAGE_NOTIFY_BEGIN_STREAMING
    xor     r8d, r8d
    call    qword ptr [rax+184]            ; ProcessMessage
    test    eax, eax
    jnz     mf_msg_fail
    mov     rcx, pTransform
    mov     rax, [rcx]
    mov     edx, 10000003h                 ; MFT_MESSAGE_NOTIFY_START_OF_STREAM
    xor     r8d, r8d
    call    qword ptr [rax+184]
    test    eax, eax
    jnz     mf_msg_fail
    lea     rcx, szMfReady
    call    emit_z
    cmp     dword ptr [liveMode], 0
    jne     enc_done                       ; live mode: keep the transform - the pump still needs it
    call    run_encoder_loop
    jmp     enc_cleanup

mf_msg_fail:
    mov     edx, eax
    lea     rcx, szMfMsg
    call    emit_num

enc_cleanup:
    mov     rcx, pOutType
    call    rel_if
    mov     rcx, pInType
    call    rel_if
    mov     rcx, pAttrs
    call    rel_if
    mov     rcx, pTransform
    call    rel_if
    mov     rcx, pActivate
    call    rel_if
    mov     rcx, pActivates
    test    rcx, rcx
    jz      enc_done
    call    CoTaskMemFree
    mov     qword ptr [pActivates], 0

enc_done:
    add     rsp, 88h
    pop     r13
    pop     r12
    ret
run_encoder_probe endp

; Feed one synthetic NV12 frame into the encoder: rcx = sample time in 100 ns units.
feed_nv12_frame proc
    push    r12
    sub     rsp, 50h
    mov     r12, rcx

    ; Release the previous frame's buffer and sample first: this runs on every feed, and leaving them
    ; behind leaked a 3.7 MB NV12 buffer plus its sample per frame - that is what drove the machine to
    ; 95% RAM. Our own input objects are ours to free; only the MFT's output sample is untouchable.
    mov     rcx, qword ptr [pInSample]
    call    rel_if
    mov     qword ptr [pInSample], 0
    mov     rcx, qword ptr [pInBuf]
    call    rel_if
    mov     qword ptr [pInBuf], 0

    mov     ecx, 3686400                   ; 1920x1280 NV12 = luma + half-size chroma
    lea     rdx, pInBuf
    call    MFCreateMemoryBuffer
    test    eax, eax
    jz      ff_have_buf
    mov     edx, eax
    lea     rcx, szEncBuf
    call    emit_num
    jmp     ff_done

ff_have_buf:
    mov     rcx, pInBuf
    mov     rax, [rcx]
    lea     rdx, bufPtr
    lea     r8, bufMax
    lea     r9, bufCur
    call    qword ptr [rax+24]             ; IMFMediaBuffer::Lock
    test    eax, eax
    jnz     ff_release
    mov     r11, qword ptr [bufPtr]
    cmp     dword ptr [haveFrame], 0
    je      ff_synthetic
    push    rsi
    push    rdi
    lea     rsi, nv12Frame                 ; feed what the capture stage produced
    mov     rdi, r11
    mov     ecx, 3110400
    mov     edx, ecx
    shr     ecx, 3
ff_copy_q:
    mov     rax, qword ptr [rsi]
    mov     qword ptr [rdi], rax
    add     rsi, 8
    add     rdi, 8
    dec     ecx
    jnz     ff_copy_q
    pop     rdi
    pop     rsi
    jmp     ff_filled
ff_synthetic:
    xor     ecx, ecx
ff_y:
    cmp     ecx, 2073600                   ; luma bytes: a gentle gradient
    jae     ff_uv
    mov     eax, ecx
    and     eax, 3Fh
    add     eax, 80h
    mov     byte ptr [r11+rcx], al
    inc     ecx
    jmp     ff_y
ff_uv:
    cmp     ecx, 3110400
    jae     ff_filled
    mov     byte ptr [r11+rcx], 80h        ; chroma: neutral grey
    inc     ecx
    jmp     ff_uv
ff_filled:
    ; sanity check: prove which frame the encoder actually received. With the real capture this
    ; must equal the VPP luma checksum printed above; the synthetic fallback gives a different sum.
    xor     ecx, ecx
    xor     edx, edx
ff_sum:
    cmp     ecx, 2073600
    jae     ff_sum_done
    movzx   eax, byte ptr [r11+rcx]
    add     edx, eax
    inc     ecx
    jmp     ff_sum
ff_sum_done:
    lea     rcx, szInSum
    call    emit_num
    mov     rcx, pInBuf
    mov     rax, [rcx]
    call    qword ptr [rax+32]             ; Unlock
    mov     rcx, pInBuf
    mov     rax, [rcx]
    mov     edx, 3110400
    call    qword ptr [rax+48]             ; SetCurrentLength

    lea     rcx, pInSample
    call    MFCreateSample
    test    eax, eax
    jz      ff_have_sample
    mov     edx, eax
    lea     rcx, szEncSmpl
    call    emit_num
    jmp     ff_release

ff_have_sample:
    mov     rcx, pInSample
    mov     rax, [rcx]
    mov     rdx, pInBuf
    call    qword ptr [rax+336]            ; IMFSample::AddBuffer
    mov     rcx, pInSample
    mov     rax, [rcx]
    mov     rdx, r12
    call    qword ptr [rax+288]            ; SetSampleTime
    mov     rcx, pInSample
    mov     rax, [rcx]
    mov     edx, 333333                    ; ~30 fps in 100 ns units
    call    qword ptr [rax+304]            ; SetSampleDuration

    mov     rcx, pTransform
    mov     rax, [rcx]
    xor     edx, edx
    mov     r8, pInSample
    xor     r9d, r9d
    call    qword ptr [rax+192]            ; ProcessInput(0, sample, 0)
    test    eax, eax
    jz      ff_release
    cmp     eax, 0C00D36B5h                ; MF_E_NOTACCEPTING: it has not asked for input yet
    je      ff_release
    inc     dword ptr [feedFails]
    mov     edx, eax
    lea     rcx, szEncInput
    call    emit_num

ff_release:
    mov     rcx, pInSample
    call    rel_if
    mov     qword ptr [pInSample], 0
    mov     rcx, pInBuf
    call    rel_if
    mov     qword ptr [pInBuf], 0
ff_done:
    add     rsp, 50h
    pop     r12
    ret
feed_nv12_frame endp

; Take one encoded access unit off the MFT (call only after it reported HaveOutput).
drain_one_frame proc
    push    r12
    sub     rsp, 50h
    lea     r10, odb
    mov     qword ptr [r10], 0             ; dwStreamID
    mov     qword ptr [r10+8], 0           ; pSample = NULL: the MFT provides samples
    mov     qword ptr [r10+16], 0          ; dwStatus
    mov     qword ptr [r10+24], 0          ; pEvents
    mov     dword ptr [outStatus], 0

    mov     rcx, pTransform
    mov     rax, [rcx]
    xor     edx, edx                       ; dwFlags
    mov     r8d, 1                         ; cOutputBufferCount
    lea     r9, odb
    lea     r10, outStatus
    mov     qword ptr [rsp+20h], r10
    call    qword ptr [rax+200]            ; ProcessOutput
    cmp     eax, 0C00D6D72h                ; MF_E_TRANSFORM_NEED_MORE_INPUT is normal
    je      dr_done
    test    eax, eax
    jz      dr_have_sample
    mov     edx, eax
    lea     rcx, szEncOut
    call    emit_num
    jmp     dr_done

dr_have_sample:
    mov     r12, qword ptr [odb+8]         ; the encoded sample
    test    r12, r12
    jz      dr_done
    mov     qword ptr [pContig], 0
    mov     rcx, r12
    mov     rax, [rcx]
    lea     rdx, pContig
    call    qword ptr [rax+328]            ; IMFSample::ConvertToContiguousBuffer
    test    eax, eax
    jnz     dr_release_sample
    mov     rcx, pContig
    mov     rax, [rcx]
    lea     rdx, bufPtr
    lea     r8, bufMax
    lea     r9, bufCur
    call    qword ptr [rax+24]             ; Lock
    test    eax, eax
    jnz     dr_release_contig
    mov     r11, qword ptr [bufPtr]
    mov     ecx, dword ptr [bufCur]
    xor     r9d, r9d
    xor     r8d, r8d
dr_sum:
    cmp     r8d, ecx
    jae     dr_sum_done
    movzx   eax, byte ptr [r11+r8]
    add     r9d, eax
    inc     r8d
    jmp     dr_sum
dr_sum_done:
    cmp     dword ptr [encFrames], 0
    jne     dr_not_first
    mov     firstSize, ecx
    mov     firstSum, r9d
dr_not_first:
    add     encBytes, ecx
    inc     encFrames
    mov     sendPtr, r11
    mov     sendLen, ecx
    call    send_video_frame
    mov     rcx, pContig
    mov     rax, [rcx]
    call    qword ptr [rax+32]             ; Unlock
dr_release_contig:
    mov     rcx, pContig
    call    rel_if
    mov     qword ptr [pContig], 0
dr_release_sample:
    cmp     dword ptr [providesSamples], 0
    jne     dr_done                        ; the MFT owns the samples it provides: never release them
    mov     rcx, r12
    call    rel_if
dr_done:
    add     rsp, 50h
    pop     r12
    ret
drain_one_frame endp

; Async MFT event loop: feed frames when the MFT asks for input, collect the bitstream when it has
; output. A blocking GetEvent would wedge the loop, so it always uses MF_EVENT_FLAG_NO_WAIT.
run_encoder_loop proc
    push    r12
    push    r13
    sub     rsp, 88h

    cmp     dword ptr [liveMode], 0
    jne     el_live_head
    mov     dword ptr [pumpCap], 4000
    mov     qword ptr [pEventGen], 0
    mov     qword ptr [pEvent], 0
    mov     dword ptr [encFrames], 0
    mov     dword ptr [encBytes], 0
    mov     dword ptr [firstSize], 0
    mov     dword ptr [firstSum], 0
    mov     qword ptr [hnsPts], 0
    mov     dword ptr [feedFails], 0

    mov     rcx, pTransform
    mov     rax, [rcx]
    lea     rdx, iidIMFMEGen
    lea     r8, pEventGen
    call    qword ptr [rax+0]              ; QI(IMFMediaEventGenerator)
    test    eax, eax
    jz      el_have_gen
    mov     edx, eax
    lea     rcx, szEncQiGen
    call    emit_num
    jmp     el_done

el_live_head:
    ; Live mode: the encoder was set up once, so the event generator and the stream counters have to
    ; survive from call to call. This call only pumps events, and it stops after one drained frame so
    ; that the capture loop can hand over the next one.
    mov     dword ptr [pumpDrained], 0
    cmp     qword ptr [pEventGen], 0
    jne     el_live_ready
    mov     rcx, pTransform
    mov     rax, [rcx]
    lea     rdx, iidIMFMEGen
    lea     r8, pEventGen
    call    qword ptr [rax+0]              ; QI(IMFMediaEventGenerator)
    test    eax, eax
    jz      el_live_ready
    mov     edx, eax
    lea     rcx, szEncQiGen
    call    emit_num
    jmp     el_done

el_live_ready:
    xor     r12d, r12d
    jmp     el_loop

el_have_gen:
    ; The MFT is asynchronous: it must be fed only after it asks with METransformNeedInput.
    mov     qword ptr [hnsPts], 0

    xor     r12d, r12d
el_loop:
    cmp     r12d, pumpCap
    jae     el_done
    inc     r12d

    mov     rcx, pEventGen
    mov     rax, [rcx]
    mov     edx, 1                         ; MF_EVENT_FLAG_NO_WAIT
    lea     r8, pEvent
    call    qword ptr [rax+24]             ; GetEvent
    test    eax, eax
    jz      el_got_event
    cmp     eax, 0C00D3E80h                ; MF_E_NO_EVENTS_AVAILABLE
    jne     el_event_fail
    mov     ecx, 1
    call    Sleep
    jmp     el_loop

el_event_fail:
    mov     edx, eax
    lea     rcx, szEncEvent
    call    emit_num
    jmp     el_done

el_got_event:
    mov     dword ptr [evType], 0
    mov     rcx, pEvent
    mov     rax, [rcx]
    lea     rdx, evType
    call    qword ptr [rax+264]            ; IMFMediaEvent::GetType
    mov     rcx, pEvent
    call    rel_if
    mov     qword ptr [pEvent], 0

    mov     eax, evType
    cmp     eax, 601                       ; METransformNeedInput
    je      el_need_input
    cmp     eax, 602                       ; METransformHaveOutput
    je      el_have_output
    lea     rcx, szE2                      ; log only unusual event types
    mov     edx, evType
    call    emit_num
    jmp     el_loop

el_need_input:
    lea     rcx, szE2                      ; trace: are we actually being asked for input?
    mov     edx, 601
    call    emit_num
    mov     rcx, qword ptr [hnsPts]
    call    feed_nv12_frame
    mov     eax, ptsStep
    add     dword ptr [hnsPts], eax        ; the low dword is enough - carrying would take hours
    cmp     dword ptr [feedFails], 5       ; the MFT is rejecting everything: stop hammering it
    jae     el_done
    jmp     el_loop

el_have_output:
    lea     rcx, szE2                      ; trace: does the MFT ever hand us an encoded frame?
    mov     edx, 602
    call    emit_num
    call    drain_one_frame
    inc     dword ptr [pumpDrained]
    cmp     dword ptr [liveMode], 0
    jne     el_live_drained
    cmp     dword ptr [encFrames], 3
    jb      el_loop
    jmp     el_done

el_live_drained:
    ; Live mode: one drained frame per call is the handover point back to the capture loop.
    cmp     dword ptr [pumpDrained], 1
    jb      el_loop

el_done:
    cmp     dword ptr [liveMode], 0
    jne     el_cleanup
    lea     rcx, szEncFrames
    mov     edx, encFrames
    call    emit_num
    lea     rcx, szEncBytes
    mov     edx, encBytes
    call    emit_num
    lea     rcx, szEncFirst
    mov     edx, firstSize
    call    emit_num
    lea     rcx, szEncFirstSu
    mov     edx, firstSum
    call    emit_num
    cmp     dword ptr [encFrames], 0
    jbe     el_cleanup
    lea     rcx, szEncOk
    call    emit_z

    lea     rcx, szStreamTot
    mov     edx, sentFrames
    call    emit_num
    lea     rcx, szStreamTotB
    mov     edx, sentBytes
    call    emit_num

    ; Flush the stream: FIN after the queued frames instead of tearing the socket down mid-flight
    ; (an abortive close discards what the client has not read yet).
    mov     ecx, streamSock
    test    ecx, ecx
    jz      el_cleanup
    mov     edx, 1                         ; SD_SEND
    call    shutdown
    mov     dword ptr [streamSock], 0

el_cleanup:
    mov     rcx, pEvent
    call    rel_if
    mov     qword ptr [pEvent], 0
    mov     rcx, pEventGen
    call    rel_if
    mov     qword ptr [pEventGen], 0
    mov     rcx, pInSample
    call    rel_if
    mov     qword ptr [pInSample], 0
    mov     rcx, pInBuf
    call    rel_if
    mov     qword ptr [pInBuf], 0

    add     rsp, 88h
    pop     r13
    pop     r12
    ret
run_encoder_loop endp

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

    ; ---- TCP handshake: listen, take one client, answer READY ----
serve_again:
    call    run_tcp_selftest

    ; ---- live loop: one encoder, one long-lived capture, frames handed over as they arrive ----
    mov     dword ptr [liveMode], 1
    mov     dword ptr [liveFrames], 20000
    mov     dword ptr [liveCount], 0
    mov     dword ptr [pumpCap], 12
    mov     dword ptr [ptsStep], 166667     ; the virtual display presents at 60 Hz
    call    run_encoder_probe               ; live mode: this call only sets the encoder up

    ; ---- DXGI adapter/output probe ----
    call    run_dxgi_probe

    ; ---- Desktop Duplication capture: the live capture+encode cycle ----
    lea     rcx, qpcFreq
    call    QueryPerformanceFrequency
    call    run_capture_probe

    ; ---- stage timings of the live loop (ticks -> ms) ----
    cmp     dword ptr [liveMode], 0
    je      skip_stage_report
    call    emit_stage_report
skip_stage_report:

    ; Back to listening: a host that exits when its client goes away leaves the tablet stuck on the
    ; last frame with nothing to reconnect to. Set the whole pipeline up again and serve the next one.
    jmp     serve_again

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
