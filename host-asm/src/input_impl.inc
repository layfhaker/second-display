; ---------------------------------------------------------------------------
; input_impl.inc — Cursor overlay and input injection (touch & keyboard)
; 100% Pure MASM x64 Assembly for SecondDisplay Host
; ---------------------------------------------------------------------------

EXTERN SendInput:PROC
EXTERN GetCursorInfo:PROC

.data
lastCurX       dd -9999
lastCurY       dd -9999
lastCurVis     db 255
lastHCursor    dq 0
curRelX        dd 0
curRelY        dd 0
curVis         dd 0
curW           dd 36
curH           dd 36
curShapeDirty  dd 1
clientHasShape db 0
curBgra        db 5184 dup(0)

.code

; ------------------------------------------------------------------------------
; wgc_get_cursor_state in pure ASM
; ------------------------------------------------------------------------------
wgc_get_cursor_state proc
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    sub     rsp, 48h

    mov     r10, rcx                ; out_x
    mov     r11, rdx                ; out_y
    mov     r12, r8                 ; out_vis
    mov     r13, r9                 ; out_w

    ; CURSORINFO ci at [rsp] (24 bytes in x64: cbSize=4, flags=4, hCursor=8, ptScreenPos=8)
    mov     dword ptr [rsp], 24     ; cbSize
    lea     rcx, [rsp]
    call    GetCursorInfo
    test    eax, eax
    jz      wgcs_hide

    ; check flags: 1 = CURSOR_SHOWING
    test    dword ptr [rsp+4], 1
    jz      wgcs_hide

    ; ptScreenPos.x at [rsp+16], ptScreenPos.y at [rsp+20]
    mov     eax, dword ptr [rsp+16]
    sub     eax, dword ptr [originX]
    mov     dword ptr [r10], eax    ; *out_x = rel_x

    mov     ecx, dword ptr [rsp+20]
    sub     ecx, dword ptr [originY]
    mov     dword ptr [r11], ecx    ; *out_y = rel_y

    ; check bounds: 0 <= rel_x < capW and 0 <= rel_y < capH
    cmp     eax, 0
    jl      wgcs_hide
    cmp     eax, dword ptr [capW]
    jge     wgcs_hide
    cmp     ecx, 0
    jl      wgcs_hide
    cmp     ecx, dword ptr [capH]
    jge     wgcs_hide

    ; Cursor is visible on display!
    mov     dword ptr [r12], 1      ; *out_vis = 1
    mov     dword ptr [r13], 36     ; *out_w = 36
    mov     rax, qword ptr [rsp+48h+48h] ; out_h
    test    rax, rax
    jz      wgcs_shape
    mov     dword ptr [rax], 36

wgcs_shape:
    mov     rbx, qword ptr [rsp+8]  ; hCursor
    cmp     rbx, qword ptr [lastHCursor]
    je      wgcs_same

    mov     qword ptr [lastHCursor], rbx
    mov     rax, qword ptr [rsp+48h+58h] ; out_dirty
    test    rax, rax
    jz      wgcs_copy
    mov     dword ptr [rax], 1

wgcs_copy:
    mov     rdi, qword ptr [rsp+48h+50h] ; out_bgra
    test    rdi, rdi
    jz      wgcs_done
    ; Copy 36*36*4 = 5184 bytes from arrowBgra
    lea     rsi, arrowBgra
    mov     ecx, 5184
    rep     movsb
    jmp     wgcs_done

wgcs_same:
    mov     rax, qword ptr [rsp+48h+58h] ; out_dirty
    test    rax, rax
    jz      wgcs_done
    mov     dword ptr [rax], 0
    jmp     wgcs_done

wgcs_hide:
    mov     dword ptr [r12], 0
    mov     dword ptr [r13], 36
    mov     rax, qword ptr [rsp+48h+48h]
    test    rax, rax
    jz      wgcs_done
    mov     dword ptr [rax], 36

wgcs_done:
    xor     eax, eax
    add     rsp, 48h
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    ret
wgc_get_cursor_state endp

; ------------------------------------------------------------------------------
; Send cursor packet over streaming socket
; ------------------------------------------------------------------------------
send_cursor_packet proc
    push    rbx
    sub     rsp, 50h

    mov     eax, dword ptr [streamSock]
    test    eax, eax
    jz      scp_done

    lea     rcx, curRelX
    lea     rdx, curRelY
    lea     r8, curVis
    lea     r9, curW
    lea     rax, curH
    mov     qword ptr [rsp+20h], rax
    lea     rax, curBgra
    mov     qword ptr [rsp+28h], rax
    lea     rax, curShapeDirty
    mov     qword ptr [rsp+30h], rax
    call    wgc_get_cursor_state

    mov     r8d, dword ptr [curRelX]       ; rel_x
    mov     r9d, dword ptr [curRelY]       ; rel_y
    movzx   ebx, byte ptr [curVis]         ; bl = visible (0 or 1)

    cmp     dword ptr [curShapeDirty], 0
    jz      scp_check_has_shape
    mov     byte ptr [clientHasShape], 0

scp_check_has_shape:
    xor     r10d, r10d                    ; r10d = need_shape = 0
    test    bl, bl
    jz      scp_check_movement
    cmp     byte ptr [clientHasShape], 0
    jnz     scp_check_movement
    mov     r10d, 1                       ; need_shape = 1

scp_check_movement:
    test    r10d, r10d
    jnz     scp_changed                   ; need shape -> must send!
    cmp     r8d, dword ptr [lastCurX]
    jne     scp_changed
    cmp     r9d, dword ptr [lastCurY]
    jne     scp_changed
    cmp     bl, byte ptr [lastCurVis]
    je      scp_done                      ; unchanged: return immediately

scp_changed:
    mov     dword ptr [lastCurX], r8d
    mov     dword ptr [lastCurY], r9d
    mov     byte ptr [lastCurVis], bl

    ; Calculate bgra_len (0 or 5184)
    xor     r11d, r11d                    ; bgra_len = 0
    test    r10d, r10d
    jz      scp_build_hdr
    mov     byte ptr [clientHasShape], 1
    mov     r11d, 5184                    ; 36 * 36 * 4

scp_build_hdr:
    mov     eax, r11d
    add     eax, 17                       ; payload len = 17 + bgra_len

    mov     byte ptr [curPkt], PKT_CURSOR  ; 11h
    mov     dword ptr [curPkt+1], eax      ; payload len (little endian)
    mov     byte ptr [curPkt+5], bl        ; visible
    mov     dword ptr [curPkt+6], r8d      ; x
    mov     dword ptr [curPkt+10], r9d     ; y
    mov     eax, dword ptr [curW]
    mov     dword ptr [curPkt+14], eax     ; cw = 36
    mov     eax, dword ptr [curH]
    mov     dword ptr [curPkt+18], eax     ; ch = 36

    ; send header + metadata (5 + 17 = 22 bytes)
    mov     ecx, dword ptr [streamSock]
    lea     rdx, curPkt
    mov     r8d, 22
    call    send_all
    test    eax, eax
    jnz     scp_fail

    ; send dynamic BGRA bitmap if bgra_len > 0
    test    r11d, r11d
    jz      scp_done

    mov     ecx, dword ptr [streamSock]
    lea     rdx, curBgra
    mov     r8d, r11d
    call    send_all
    test    eax, eax
    jnz     scp_fail
    jmp     scp_done

scp_fail:
    mov     dword ptr [streamSock], 0
    mov     byte ptr [clientHasShape], 0

scp_done:
    add     rsp, 50h
    pop     rbx
    ret
send_cursor_packet endp

; ------------------------------------------------------------------------------
; Pure ASM input injection: Touch
; ------------------------------------------------------------------------------
input_inject_touch proc
    sub     rsp, 58h

    movss   dword ptr [rsp+40h], xmm1
    movss   dword ptr [rsp+44h], xmm2

    cvtsi2ss xmm0, dword ptr [capW]
    mulss   xmm1, xmm0
    cvttss2si eax, xmm1
    add     eax, dword ptr [originX]
    imul    rax, 65535
    cdq
    mov     r8d, 3840
    test    r8d, r8d
    jz      iit_zero_dx
    idiv    r8d
    jmp     iit_dx_ok
iit_zero_dx:
    xor     eax, eax
iit_dx_ok:
    mov     edx, eax                ; edx = norm_x

    cvtsi2ss xmm0, dword ptr [capH]
    movss   xmm2, dword ptr [rsp+44h]
    mulss   xmm2, xmm0
    cvttss2si eax, xmm2
    add     eax, dword ptr [originY]
    imul    rax, 65535
    cdq
    mov     r8d, 1280
    test    r8d, r8d
    jz      iit_zero_dy
    idiv    r8d
    jmp     iit_dy_ok
iit_zero_dy:
    xor     eax, eax
iit_dy_ok:
    mov     r8d, eax                ; r8d = norm_y

    ; Flags: MOUSEEVENTF_MOVE(1) | MOUSEEVENTF_ABSOLUTE(8000h) | MOUSEEVENTF_VIRTUALDESK(4000h)
    mov     r9d, 0C001h
    cmp     ecx, 0                  ; action 0 = DOWN
    jne     iit_check_up
    or      r9d, 0002h              ; MOUSEEVENTF_LEFTDOWN
    jmp     iit_send
iit_check_up:
    cmp     ecx, 2                  ; action 2 = UP
    jne     iit_send
    or      r9d, 0004h              ; MOUSEEVENTF_LEFTUP

iit_send:
    mov     dword ptr [rsp], 0      ; type = INPUT_MOUSE (0)
    mov     dword ptr [rsp+4], 0    ; padding
    mov     dword ptr [rsp+8], edx  ; dx
    mov     dword ptr [rsp+12], r8d ; dy
    mov     dword ptr [rsp+16], 0   ; mouseData
    mov     dword ptr [rsp+20], r9d ; dwFlags
    mov     dword ptr [rsp+24], 0   ; time
    mov     qword ptr [rsp+32], 0   ; dwExtraInfo

    mov     ecx, 1
    lea     rdx, [rsp]
    mov     r8d, 40
    call    SendInput

    add     rsp, 58h
    ret
input_inject_touch endp

; ------------------------------------------------------------------------------
; Pure ASM input injection: Keyboard
; ------------------------------------------------------------------------------
input_inject_key proc
    sub     rsp, 58h

    mov     dword ptr [rsp], 1      ; type = INPUT_KEYBOARD (1)
    mov     dword ptr [rsp+4], 0

    test    r9d, r9d
    jnz     iik_have_scan
    mov     r9d, edx
iik_have_scan:
    mov     word ptr [rsp+8], dx    ; wVk
    mov     word ptr [rsp+10], r9w  ; wScan

    xor     r10d, r10d
    cmp     ecx, 1                  ; action 1 = UP
    jne     iik_flags
    mov     r10d, 2                 ; KEYEVENTF_KEYUP
iik_flags:
    test    r9w, r9w
    jz      iik_apply_flags
    or      r10d, 8                 ; KEYEVENTF_SCANCODE
iik_apply_flags:
    mov     dword ptr [rsp+12], r10d ; dwFlags
    mov     dword ptr [rsp+16], 0    ; time
    mov     qword ptr [rsp+24], 0    ; dwExtraInfo

    mov     ecx, 1
    lea     rdx, [rsp]
    mov     r8d, 40
    call    SendInput

    add     rsp, 58h
    ret
input_inject_key endp

; rcx = payload pointer
inject_touch_event proc
    sub     rsp, 28h
    movss   xmm1, dword ptr [rcx+2]        ; x (f32)
    movss   xmm2, dword ptr [rcx+6]        ; y (f32)
    movzx   ecx, byte ptr [rcx]            ; action
    call    input_inject_touch
    add     rsp, 28h
    ret
inject_touch_event endp

; rcx = payload pointer
inject_key_event proc
    sub     rsp, 28h
    movzx   eax, byte ptr [rcx]            ; action
    movzx   edx, word ptr [rcx+1]          ; key_code
    mov     r8d, dword ptr [rcx+3]         ; meta_state
    movzx   r9d, word ptr [rcx+7]          ; scan_code
    mov     ecx, eax                       ; ecx = action
    call    input_inject_key
    add     rsp, 28h
    ret
inject_key_event endp

input_thread_proc proc
    push    rbx
    push    r12
    push    r13
    sub     rsp, 30h

itp_loop:
    ; read 5 byte header
    xor     ebx, ebx
itp_hdr_loop:
    mov     ecx, dword ptr [streamSock]
    test    ecx, ecx
    jz      itp_exit
    lea     rdx, inputHdr
    add     rdx, rbx
    mov     r8d, 5
    sub     r8d, ebx
    xor     r9d, r9d
    call    recv
    cmp     eax, 0
    jle     itp_closed
    add     ebx, eax
    cmp     ebx, 5
    jl      itp_hdr_loop

    movzx   r12d, byte ptr [inputHdr]      ; type
    mov     r13d, dword ptr [inputHdr+1]   ; len
    cmp     r13d, 1024
    ja      itp_closed

    test    r13d, r13d
    jz      itp_dispatch

    ; read payload
    xor     ebx, ebx
itp_pay_loop:
    mov     ecx, dword ptr [streamSock]
    test    ecx, ecx
    jz      itp_exit
    lea     rdx, inputPay
    add     rdx, rbx
    mov     r8d, r13d
    sub     r8d, ebx
    xor     r9d, r9d
    call    recv
    cmp     eax, 0
    jle     itp_closed
    add     ebx, eax
    cmp     ebx, r13d
    jl      itp_pay_loop

itp_dispatch:
    cmp     r12d, PKT_TOUCH                ; 20h
    jne     itp_check_key
    cmp     r13d, 10
    jb      itp_loop
    lea     rcx, inputPay
    call    inject_touch_event
    jmp     itp_loop

itp_check_key:
    cmp     r12d, PKT_KEY                  ; 22h
    jne     itp_loop
    cmp     r13d, 7
    jb      itp_loop
    lea     rcx, inputPay
    call    inject_key_event
    jmp     itp_loop

itp_closed:
    mov     dword ptr [streamSock], 0

itp_exit:
    add     rsp, 30h
    pop     r13
    pop     r12
    pop     rbx
    ret
input_thread_proc endp
