; SecondDisplay host — x86-64 assembly (MASM) rewrite, staged.
;
; Milestone 1: linkable Windows exe, hand-written entry point, Win32 calls (GetStdHandle/WriteFile).
; Milestone 2: runtime logging to %LOCALAPPDATA%\SecondDisplay\host-asm.log with a local timestamp
;              (GetEnvironmentVariableA / CreateDirectoryA / CreateFileA / GetLocalTime / WriteFile).
;
; Next milestones build on this: adb via CreateProcessW, the wire protocol + TCP, then DXGI
; capture / D3D11 VPP / Media Foundation HEVC.

option casemap:none

; ---- Win32 constants ----
STD_OUTPUT_HANDLE      equ -11
GENERIC_WRITE          equ 40000000h
FILE_SHARE_READ        equ 1
CREATE_ALWAYS          equ 2
FILE_ATTRIBUTE_NORMAL  equ 80h
INVALID_HANDLE_VALUE   equ 0FFFFFFFFFFFFFFFFh

; ---- Win32 imports (kernel32) ----
EXTERN GetStdHandle:PROC
EXTERN WriteFile:PROC
EXTERN ExitProcess:PROC
EXTERN GetEnvironmentVariableA:PROC
EXTERN CreateDirectoryA:PROC
EXTERN CreateFileA:PROC
EXTERN CloseHandle:PROC
EXTERN GetLocalTime:PROC

.data
szLocal   db "LOCALAPPDATA", 0
szSub     db "\SecondDisplay", 0
szLog     db "\host-asm.log", 0
msg       db "] SecondDisplay Host (asm) v0.1", 13, 10, 0
msg_len   equ $ - msg - 1

.data?
envBuf    db 260 dup(?)
lineBuf   db 128 dup(?)
stdTime   dw 8 dup(?)          ; SYSTEMTIME (8 x WORD)
written   dq ?
logHandle dq ?

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

; Write two decimal digits: rcx = dest, edx = value (0..99). Returns rax = dest + 2.
u2 proc
    movzx   eax, dl
    xor     edx, edx
    mov     r8d, 10
    div     r8d                    ; eax = tens, edx = ones
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
    mov     r10, rcx
    mov     r11d, edx
    mov     ecx, STD_OUTPUT_HANDLE
    call    GetStdHandle
    mov     rcx, rax
    mov     rdx, r10
    mov     r8d, r11d
    lea     r9, written
    mov     qword ptr [rsp+20h], 0
    call    WriteFile
    add     rsp, 38h
    ret
write_stdout endp

; int mainCRTStartup(void)
mainCRTStartup proc
    sub     rsp, 38h               ; shadow (20h) + args 5..7 (28h,30h) + 16-byte alignment

    ; ---- env: LOCALAPPDATA ----
    lea     rcx, szLocal           ; lpName
    lea     rdx, envBuf            ; lpBuffer
    mov     r8d, 260               ; nSize
    call    GetEnvironmentVariableA
    test    eax, eax
    jz      no_log

    ; ---- dir = %LOCALAPPDATA% + "\SecondDisplay" ----
    lea     r12, envBuf
    mov     r13d, eax              ; chars in the env value
    add     r12, r13
    mov     rcx, r12
    lea     rdx, szSub
    call    copy_z
    mov     r12, rax               ; end-of-dir pointer

    lea     rcx, envBuf
    xor     edx, edx
    call    CreateDirectoryA       ; ignore "already exists"

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

    ; ---- build the log line: "[HH:MM:SS] <msg>" ----
    lea     rcx, stdTime
    call    GetLocalTime

    lea     r14, lineBuf
    mov     byte ptr [r14], '['
    lea     rcx, [r14+1]
    movzx   edx, word ptr [stdTime+8]   ; wHour
    call    u2
    mov     byte ptr [r14+3], ':'
    lea     rcx, [r14+4]
    movzx   edx, word ptr [stdTime+10]  ; wMinute
    call    u2
    mov     byte ptr [r14+7], ':'
    lea     rcx, [r14+8]
    movzx   edx, word ptr [stdTime+12]  ; wSecond
    call    u2

    lea     rcx, [r14+10]
    lea     rdx, msg
    call    copy_z
    ; rax = pointer to the appended NUL; total length = rax - lineBuf
    mov     r15, rax
    sub     r15, r14                    ; length (bytes incl. the 0 we wrote)

    ; ---- write to the log file ----
    mov     rcx, logHandle
    mov     rdx, r14
    mov     r8d, r15d
    lea     r9, written
    mov     qword ptr [rsp+20h], 0
    call    WriteFile

    mov     rcx, logHandle
    call    CloseHandle

    ; ---- also echo the line to stdout ----
    lea     rcx, lineBuf
    mov     edx, r15d
    call    write_stdout
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
