; SecondDisplay host — x86-64 assembly (MASM) rewrite, staged.
;
; M1: linkable Windows exe, hand-written entry point, Win32 calls (GetStdHandle/WriteFile).
; M2: runtime logging to %LOCALAPPDATA%\SecondDisplay\host-asm.log with a local timestamp.
; M3: spawn adb via CreateProcessA with CREATE_NO_WINDOW, capture its output through a pipe
;     (CreatePipe / SetHandleInformation / ReadFile), and log it.
;
; Next: wire protocol + TCP (ws2_32); then DXGI capture / D3D11 VPP / Media Foundation HEVC (COM).

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
