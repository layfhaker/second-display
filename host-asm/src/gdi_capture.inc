; ==============================================================================
; SecondDisplay host-asm: Native GDI Capture & BGRA to NV12 Conversion (Pure Assembly)
; ==============================================================================

EXTERN VirtualAlloc:PROC
EXTERN GetDC:PROC
EXTERN ReleaseDC:PROC
EXTERN CreateCompatibleDC:PROC
EXTERN CreateDIBSection:PROC
EXTERN SelectObject:PROC
EXTERN BitBlt:PROC
EXTERN DeleteDC:PROC
EXTERN DeleteObject:PROC

.data
pGdiBits      dq 0
pDIBits       dq 0
hdcScreen     dq 0
hdcMemGdi     dq 0
hbmGdi        dq 0
useGdi        dd 0

szGdiInitOk   db "Native display capture initialized successfully", 13, 10, 0
szGdiInitFail db "Native display capture initialization failed", 13, 10, 0

.code

; ------------------------------------------------------------------------------
; init_gdi_capture: rcx = display name pointer (or NULL), edx = W, r8d = H
; Returns eax = 0 on success, 1 on failure
; ------------------------------------------------------------------------------
init_gdi_capture proc
    sub     rsp, 58h

    ; Allocate the 1920x1280x4 BGRA buffer if not already allocated
    mov     rax, pGdiBits
    test    rax, rax
    jnz     igc_dc_init

    ; VirtualAlloc(NULL, 1920*1280*4, MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE)
    xor     ecx, ecx                ; lpAddress = NULL
    mov     edx, 1920 * 1280 * 4    ; dwSize = 9830400 bytes
    mov     r8d, 3000h              ; MEM_COMMIT (1000h) | MEM_RESERVE (2000h)
    mov     r9d, 4                  ; PAGE_READWRITE
    call    VirtualAlloc
    mov     pGdiBits, rax
    test    rax, rax
    jz      igc_fail

igc_dc_init:
    ; GetDC(NULL) captures the entire desktop spanning all monitors
    xor     ecx, ecx
    call    GetDC
    mov     hdcScreen, rax
    test    rax, rax
    jz      igc_fail

    mov     rcx, rax
    call    CreateCompatibleDC
    mov     hdcMemGdi, rax
    test    rax, rax
    jz      igc_fail

    ; BITMAPINFOHEADER at [rsp+20h]
    lea     rax, [rsp+20h]
    mov     dword ptr [rax], 40         ; biSize
    mov     dword ptr [rax+4], 1920     ; biWidth
    mov     dword ptr [rax+8], -1280    ; biHeight (negative = top-down)
    mov     word ptr [rax+12], 1        ; biPlanes
    mov     word ptr [rax+14], 32       ; biBitCount
    mov     dword ptr [rax+16], 0       ; biCompression = BI_RGB
    mov     dword ptr [rax+20], 0
    mov     dword ptr [rax+24], 0
    mov     dword ptr [rax+28], 0
    mov     dword ptr [rax+32], 0
    mov     dword ptr [rax+36], 0

    mov     rcx, hdcMemGdi
    mov     rdx, rax
    xor     r8d, r8d
    lea     r9, pDIBits
    mov     qword ptr [rsp+28h], 0
    mov     dword ptr [rsp+30h], 0
    call    CreateDIBSection
    mov     hbmGdi, rax
    test    rax, rax
    jz      igc_fail

    mov     rcx, hdcMemGdi
    mov     rdx, hbmGdi
    call    SelectObject

    mov     dword ptr [useGdi], 1
    lea     rcx, szGdiInitOk
    call    emit_z
    xor     eax, eax
    add     rsp, 58h
    ret

igc_fail:
    mov     dword ptr [useGdi], 0
    lea     rcx, szGdiInitFail
    call    emit_z
    mov     eax, 1
    add     rsp, 58h
    ret
init_gdi_capture endp

; ------------------------------------------------------------------------------
; capture_gdi_bitblt: captures BGRA frame via BitBlt into pDIBits
; ------------------------------------------------------------------------------
capture_gdi_bitblt proc
    sub     rsp, 58h
    mov     rcx, hdcMemGdi
    xor     edx, edx
    xor     r8d, r8d
    mov     r9d, 1920
    mov     dword ptr [rsp+20h], 1280
    mov     rax, hdcScreen
    mov     qword ptr [rsp+28h], rax
    mov     eax, dword ptr [originX]
    mov     dword ptr [rsp+30h], eax
    mov     eax, dword ptr [originY]
    mov     dword ptr [rsp+38h], eax
    mov     dword ptr [rsp+40h], 00CC0020h ; SRCCOPY
    call    BitBlt

    mov     rax, pDIBits
    test    rax, rax
    jz      cgb_done
    mov     pGdiBits, rax

cgb_done:
    add     rsp, 58h
    ret
capture_gdi_bitblt endp

; ------------------------------------------------------------------------------
; convert_bgra_to_nv12_asm: rcx = dst nv12Frame
; Converts 1920x1280 32-bit BGRA at pGdiBits into NV12 (Y + interleaved UV)
; ------------------------------------------------------------------------------
convert_bgra_to_nv12_asm proc
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 28h

    mov     r12, rcx               ; r12 = dst luma base
    mov     rsi, pGdiBits          ; rsi = src BGRA
    test    rsi, rsi
    jz      cbn_done

    ; ---- 1. LUMA (Y plane: 1920 * 1280 = 2457600 bytes) ----
    mov     rdi, r12
    mov     ecx, 2457600
cbn_y_loop:
    movzx   ebx, byte ptr [rsi]     ; B
    movzx   edx, byte ptr [rsi+1]   ; G
    movzx   eax, byte ptr [rsi+2]   ; R
    add     rsi, 4

    imul    eax, 66                 ; 66 * R
    imul    edx, 129                ; 129 * G
    imul    ebx, 25                 ; 25 * B
    add     eax, edx
    add     eax, ebx
    add     eax, 128
    shr     eax, 8
    add     eax, 16                 ; BT.601 limited Y is strictly [16..235]
    mov     byte ptr [rdi], al
    inc     rdi
    dec     ecx
    jnz     cbn_y_loop

    ; ---- 2. CHROMA (UV plane: 640 lines of 1920 bytes = 1228800 bytes) ----
    ; rdi now points to the beginning of the UV plane (dst luma + 2457600)
    ; For each 2x2 block, average 4 RGB pixels and compute U and V
    xor     r13d, r13d             ; r13d = row index (0, 2, 4, ... 1278)

cbn_uv_row_loop:
    cmp     r13d, 1280
    jge     cbn_done

    ; row0 = pGdiBits + r13 * (1920 * 4)
    mov     eax, r13d
    imul    rax, 1920 * 4
    add     rax, pGdiBits
    mov     r14, rax               ; r14 = row0 ptr

    ; row1 = row0 + (1920 * 4)
    lea     r15, [r14 + 1920 * 4]  ; r15 = row1 ptr

    xor     r8d, r8d               ; r8d = col index (0, 2, 4, ... 1918)

cbn_uv_col_loop:
    cmp     r8d, 1920
    jge     cbn_uv_col_done

    ; col offset = r8d * 4
    mov     eax, r8d
    shl     eax, 2
    movsxd  rax, eax

    ; sum 4 pixels: (row0[x], row0[x+1], row1[x], row1[x+1])
    ; pixel 1: row0[x]
    movzx   ebx, byte ptr [r14 + rax]     ; B
    movzx   edx, byte ptr [r14 + rax + 1] ; G
    movzx   ecx, byte ptr [r14 + rax + 2] ; R

    ; pixel 2: row0[x+1]
    movzx   esi, byte ptr [r14 + rax + 4]
    add     ebx, esi
    movzx   esi, byte ptr [r14 + rax + 5]
    add     edx, esi
    movzx   esi, byte ptr [r14 + rax + 6]
    add     ecx, esi

    ; pixel 3: row1[x]
    movzx   esi, byte ptr [r15 + rax]
    add     ebx, esi
    movzx   esi, byte ptr [r15 + rax + 1]
    add     edx, esi
    movzx   esi, byte ptr [r15 + rax + 2]
    add     ecx, esi

    ; pixel 4: row1[x+1]
    movzx   esi, byte ptr [r15 + rax + 4]
    add     ebx, esi
    movzx   esi, byte ptr [r15 + rax + 5]
    add     edx, esi
    movzx   esi, byte ptr [r15 + rax + 6]
    add     ecx, esi

    ; Average: divide by 4
    shr     ebx, 2                 ; ebx = avg B
    shr     edx, 2                 ; edx = avg G
    shr     ecx, 2                 ; ecx = avg R

    ; U = ((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128
    mov     eax, ecx
    imul    eax, -38
    mov     esi, edx
    imul    esi, -74
    add     eax, esi
    mov     esi, ebx
    imul    esi, 112
    add     eax, esi
    add     eax, 128
    sar     eax, 8
    add     eax, 128

    ; clamp U to [0..255]
    cmp     eax, 0
    jge     clamp_u_max
    xor     eax, eax
clamp_u_max:
    cmp     eax, 255
    jle     clamp_u_ok
    mov     eax, 255
clamp_u_ok:
    mov     byte ptr [rdi], al     ; U

    ; V = ((112 * R - 94 * G - 18 * B + 128) >> 8) + 128
    mov     eax, ecx
    imul    eax, 112
    mov     esi, edx
    imul    esi, -94
    add     eax, esi
    mov     esi, ebx
    imul    esi, -18
    add     eax, esi
    add     eax, 128
    sar     eax, 8
    add     eax, 128

    ; clamp V to [0..255]
    cmp     eax, 0
    jge     clamp_v_max
    xor     eax, eax
clamp_v_max:
    cmp     eax, 255
    jle     clamp_v_ok
    mov     eax, 255
clamp_v_ok:
    mov     byte ptr [rdi+1], al   ; V

    add     rdi, 2
    add     r8d, 2
    jmp     cbn_uv_col_loop

cbn_uv_col_done:
    add     r13d, 2                ; next row pair
    jmp     cbn_uv_row_loop

cbn_done:
    add     rsp, 28h
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    ret
convert_bgra_to_nv12_asm endp

; ------------------------------------------------------------------------------
; release_gdi_capture: frees GDI capture resources
; ------------------------------------------------------------------------------
release_gdi_capture proc
    sub     rsp, 28h
    mov     rcx, hbmGdi
    test    rcx, rcx
    jz      rgc_mem
    call    DeleteObject
    mov     hbmGdi, 0

rgc_mem:
    mov     rcx, hdcMemGdi
    test    rcx, rcx
    jz      rgc_screen
    call    DeleteDC
    mov     hdcMemGdi, 0

rgc_screen:
    mov     rdx, hdcScreen
    test    rdx, rdx
    jz      rgc_done
    xor     ecx, ecx
    call    ReleaseDC
    mov     hdcScreen, 0

rgc_done:
    add     rsp, 28h
    ret
release_gdi_capture endp

; ------------------------------------------------------------------------------
; Pure ASM forwarders for wgc_ symbols called by main.asm
; ------------------------------------------------------------------------------
wgc_init proc
    jmp     init_gdi_capture
wgc_init endp

wgc_capture_bgra proc
    jmp     capture_gdi_bitblt
wgc_capture_bgra endp

wgc_capture_nv12 proc
    push    rbx
    sub     rsp, 28h
    mov     rbx, rcx                ; rbx = out_nv12 buffer
    call    capture_gdi_bitblt
    mov     rcx, rbx
    call    convert_bgra_to_nv12_asm
    mov     eax, 1
    add     rsp, 28h
    pop     rbx
    ret
wgc_capture_nv12 endp

wgc_release proc
    jmp     release_gdi_capture
wgc_release endp
