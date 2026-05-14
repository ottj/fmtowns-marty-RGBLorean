; SPDX-License-Identifier: MIT
;
; int93_fwd.asm — RGBLorean int 0x93 mailbox-forwarding TSR (iteration 3)
;
; Builds on the chain-path validation in iteration 2. The matched-path
; branch now actually FORWARDS the CD-ROM read to the FPGA via the
; mailbox at 0xD00800 instead of chaining to the original BIOS.
;
; Boot model (verified earlier): the Marty BIOS maps the IC card image
; at segment 0xB000 and `jmp 0xB000:0x400` directly into sector 1. Code
; runs in place from the card window. `org 0x400` makes NASM symbol
; values match runtime IP.
;
; Mailbox protocol (offset 0x800 in the card window = linear 0xD00800):
;
;   0xD00800  command  (host writes — 0x00=NOOP, 0x01=READ_SECTOR,
;                                     0x10=FPGA_INFO)
;   0xD00801  status   (host reads  — 0x00=IDLE, 0x02=DONE)
;   0xD00804  lba       (host writes — 32-bit LE)
;   0xD00808  sector_count (host writes — 16-bit, currently we always
;                          submit 1 and loop client-side for multi-sector)
;   0xD01000  sector_data — 2048 B sector buffer (host reads after DONE)
;
; Sequence per sector:
;   1. write lba, sector_count=1 to mailbox flops
;   2. write command=0x01 (READ_SECTOR)
;   3. poll status==0x02 (DONE) with timeout
;   4. copy 2048 B of sector_data to caller's DS:DI buffer
;   5. write command=0x00 (NOOP) to release
;   6. poll status==0x00 (IDLE) with timeout
;
; In Tsugaru there is no FPGA — writes to 0xD00800 land in flat host
; RAM and status never transitions to DONE, so the poll loop times out.
; Result marker at 0:0x87A0 will read "FL\0\0" and we return synthetic
; success with the buffer untouched. On real hardware the FPGA mailbox
; FSM (firmware/fpga/rtl/pcmcia_target.sv) drives status through the
; full IDLE→BUSY→DONE→IDLE handshake and we get real sector data.
;
; Iteration 3 limitations (deferred to iteration 4):
;   - Caller's BX (sector count) > 1 is rejected by the hook with
;     CF=1 / AH=0x80 (no multi-sector loop yet).
;   - CH=0xFF (32-bit linear buffer) path not handled — falls through
;     to CF=1 / AH=0x80.
;   - Hook assumes FS still holds the 4 GB unreal-mode descriptor set
;     up in entry. If a caller reloads FS in real mode between entry
;     and the int 0x93, the assumption breaks. Self-test in entry is
;     safe; intercepting real-game int 0x93 calls is iteration 5.
;
; Scratch layout (0:0x8000+ to escape the BIOS's CD-driver scratch
; zone at 0x600..0x7FF — see iteration-2 forensics):
;
;   0:0x8600  "RGBLOK!\0\7\0"     entry reached (version 7)
;   0:0x8700  "INT93FW!"          install path executed
;   0:0x8750  "DONE"              control returned to entry after iret
;   0:0x8768  byte  'P' or 'F'    AH==0 after BIOS / iret path
;   0:0x876C  word  AX returned by our hook (synthetic success: 00 C0)
;   0:0x876E  word  FLAGS after int returns (CF in bit 0 — expect 0)
;   0:0x8770  16 B  buffer snapshot at 0:0x2000 (filled by the mailbox
;                   copy on real hw; FPGA stub pattern is
;                   word[i] = lba[15:0] + i, so first 8 words read
;                   from LBA 100 should be 64 00 65 00 66 00 67 00 …)
;   0:0x8780  word  hit counter (hook fired)
;   0:0x8784  byte  ring head
;   0:0x8790  ring slot 0 (16 B) — saved caller regs
;   0:0x87A0  4 B   mailbox result code:
;                     "OK\0\0" — full READ_SECTOR + IDLE handshake
;                     "FL\0\0" — timeout waiting for STATUS=DONE
;                     "PL\0\0" — DONE but timeout waiting for IDLE
;                     "BX\0\0" — caller BX != 1 (multi-sector NYI)
;                     "CH\0\0" — caller CH != 0 (32-bit linear NYI)

bits 16
cpu 386
org 0x400

int93_fwd_start:

; ----------------------------------------------------------------
; Entry
; ----------------------------------------------------------------
entry:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x1000

    ; "RGBLOK!\0\7\0"
    mov word [0x8600], 0x4752
    mov word [0x8602], 0x4C42
    mov word [0x8604], 0x4B4F
    mov word [0x8606], 0x0021
    mov word [0x8608], 0x0007

    ; "INT93FW!"
    mov word [0x8700], 0x4E49
    mov word [0x8702], 0x3954
    mov word [0x8704], 0x4633
    mov word [0x8706], 0x2157

    ; ----------------------------------------------------------------
    ; Unreal-mode setup — patch gdtr_desc.base with the runtime linear
    ; address of gdt_start, then PE/load FS=0x08/PE-off. Lifted from
    ; mbx_test.asm; see that file for the rationale.
    ; ----------------------------------------------------------------
    xor eax, eax
    mov ax, cs
    shl eax, 4
    add eax, gdt_start
    mov [cs:gdtr_desc + 2], eax

    lgdt [cs:gdtr_desc]

    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp short .pm_flush
.pm_flush:

    mov bx, 0x08                 ; selector 0x08 → 4 GB data descriptor
    mov fs, bx

    mov eax, cr0
    and al, 0xFE
    mov cr0, eax
    jmp short .real_flush
.real_flush:
    ; FS shadow now caches base=0, limit=0xFFFFFFFF. 32-bit linear
    ; addressing via [fs:dword 0x00D00xxx] now works in real mode.

    ; ----------------------------------------------------------------
    ; Save original int 0x93 vector and install our hook.
    ; ----------------------------------------------------------------
    mov ax, [0x024C]
    mov [cs:orig_int93_off], ax
    mov ax, [0x024E]
    mov [cs:orig_int93_seg], ax

    mov word [0x024C], hook
    mov [0x024E], cs

    ; Zero log scratch
    mov word [0x8780], 0
    mov byte  [0x8784], 0

    ; "    " pre-fill of the result-code slot so we can tell whether
    ; the hook wrote anything to it.
    mov dword [0x87A0], 0x20202020

    sti

    ; ----------------------------------------------------------------
    ; Self-test: synthesise a CD-ROM BIOS read-HSG call (single sector).
    ;
    ;   AX = 0x05C0   AH=0x05 (read HSG), AL=0xC0 (CD-ROM family)
    ;   BX = 0x0001   ONE sector (multi-sector NYI in iteration 3)
    ;   CX = 0x0000   CL=0 LBA-hi, CH=0 real-mode-buffer mode
    ;   DX = 0x0064   LBA = 100
    ;   DS:DI = 0:0x2000
    ; ----------------------------------------------------------------
    mov ax, 0x05C0
    mov bx, 0x0001
    mov cx, 0x0000
    mov dx, 0x0064
    mov si, 0
    mov di, 0x2000
    int 0x93

    ; ----------------------------------------------------------------
    ; Capture what our hook returned (AX/FLAGS) for inspection.
    ; ----------------------------------------------------------------
    pushf
    mov [0x876C], ax
    pop ax
    mov [0x876E], ax

    mov ax, [0x876C]
    test ah, ah
    jnz .got_err
    mov byte [0x8768], 'P'
    jmp .after_status
.got_err:
    mov byte [0x8768], 'F'
.after_status:

    ; Snapshot first 16 B of the destination buffer (0:0x2000) into
    ; 0:0x8770..0x877F. On real hardware these should show the FPGA
    ; mailbox pattern `word[i] = lba[15:0] + i = 0x64+i`, i.e.
    ;   64 00 65 00 66 00 67 00 68 00 69 00 6A 00 6B 00
    xor ax, ax
    mov ds, ax
    mov si, 0x2000
    mov di, 0x8770
    mov cx, 8
.copy_buf:
    mov ax, [si]
    mov [di], ax
    add si, 2
    add di, 2
    loop .copy_buf

    ; "DONE" marker
    mov word [0x8750], 0x4F44
    mov word [0x8752], 0x454E

    cli
.halt:
    hlt
    jmp short .halt

; ================================================================
; Hook handler — fires on every int 0x93. Filters AL=0xC0 + AH=0x05,
; forwards to the mailbox, returns synthetic success.
;
; Stack on entry (int instruction pushed):
;   SP+0   IP_caller
;   SP+2   CS_caller
;   SP+4   FLAGS_caller
;
; Hook assumes FS still holds the 4 GB unreal-mode descriptor that
; entry installed. The matched-path mailbox accesses use `fs:dword
; 0xNNNN` 32-bit linear addressing.
; ================================================================
hook:
    cmp al, 0xC0
    jne .chain
    cmp ah, 0x05
    jne .chain

    ; ------------------------------------------------------------
    ; Match. Snapshot caller regs to ring (same scheme as iteration 2).
    ; ------------------------------------------------------------
    pushf
    pusha
    push ds
    push es
    mov bp, sp

    xor ax, ax
    mov ds, ax

    inc word [0x8780]

    movzx bx, byte [0x8784]
    and bl, 0x70
    add bx, 0x8790

    mov ax, [bp+18]                  ; AX
    mov [bx+0x0], ax
    mov ax, [bp+12]                  ; BX (sector count)
    mov [bx+0x2], ax
    mov ax, [bp+16]                  ; CX
    mov [bx+0x4], ax
    mov ax, [bp+14]                  ; DX
    mov [bx+0x6], ax
    mov ax, [bp+ 2]                  ; DS (caller's)
    mov [bx+0x8], ax
    mov ax, [bp+ 4]                  ; DI
    mov [bx+0xA], ax
    mov ax, [bp+ 0]                  ; ES (caller's)
    mov [bx+0xC], ax
    mov ax, [bp+22]                  ; IP_caller
    mov [bx+0xE], ax

    add byte [0x8784], 0x10

    ; ------------------------------------------------------------
    ; Validate the request against this iteration's supported subset.
    ; - BX (sector count) must be 1
    ; - CH (mode) must be 0 (real-mode buffer; 0xFF linear is NYI)
    ; ------------------------------------------------------------
    mov ax, [bp+12]                  ; saved BX
    cmp ax, 1
    jne .unsupported_bx
    mov ax, [bp+16]                  ; saved CX
    test ah, ah                      ; CH (high byte of CX)
    jnz .unsupported_ch

    ; ------------------------------------------------------------
    ; Build the 24-bit HSG LBA from CL:DH:DL:
    ;   LBA = (CL << 16) | (DH << 8) | DL
    ; ------------------------------------------------------------
    mov ax, [bp+16]                  ; CX (CL = lba bits 23..16, CH unused)
    movzx eax, al                    ; eax = CL
    shl eax, 16                      ; eax = CL << 16

    mov dx, [bp+14]                  ; saved DX (DH = lba mid, DL = lba lo)
    mov bl, dh
    mov bh, 0
    shl ebx, 8                       ; ebx = DH << 8
    or eax, ebx                      ; eax |= DH << 8
    mov bl, dl
    mov bh, 0
    or eax, ebx                      ; eax |= DL
    ; eax now = full 24-bit LBA

    ; ------------------------------------------------------------
    ; Submit the mailbox request.
    ;   [0xD00804] = LBA (32-bit)
    ;   [0xD00808] = sector_count (16-bit = 1)
    ;   [0xD00800] = 0x01  (READ_SECTOR)
    ; ------------------------------------------------------------
    mov [fs:dword 0x00D00804], eax
    mov word [fs:dword 0x00D00808], 1
    mov byte [fs:dword 0x00D00800], 0x01

    ; Poll status @ 0xD00801 for DONE (0x02) with timeout (~20 ms @ 16 MHz).
    mov ecx, 0x00010000
.poll_done:
    mov al, [fs:dword 0x00D00801]
    cmp al, 0x02
    je .got_done
    dec ecx
    jnz .poll_done

    ; Timeout — mark FL, skip the copy, still return synthetic success
    ; so the caller (and our self-test) progresses.
    mov dword [0x87A0], 0x00004C46    ; "FL\0\0"
    jmp .return_success

.got_done:
    ; ------------------------------------------------------------
    ; Copy 2048 B (= 1024 words) of sector_data from 0xD01000 to
    ; caller's DS:DI buffer.
    ; ------------------------------------------------------------
    mov ax, [bp+2]                   ; caller's DS
    mov es, ax
    mov di, [bp+4]                   ; caller's DI
    mov esi, 0x00D01000
    mov cx, 1024
.copy_sector:
    mov ax, [fs:esi]
    mov [es:di], ax
    add esi, 2
    add di, 2
    dec cx
    jnz .copy_sector

    ; Release: NOOP command, poll for IDLE (status==0).
    mov byte [fs:dword 0x00D00800], 0x00
    mov ecx, 0x00010000
.poll_idle:
    mov al, [fs:dword 0x00D00801]
    test al, al
    jz .got_idle
    dec ecx
    jnz .poll_idle

    mov dword [0x87A0], 0x0000004C50  ; "PL\0\0"
    jmp .return_success

.got_idle:
    mov dword [0x87A0], 0x0000004B4F  ; "OK\0\0"
    jmp .return_success

.unsupported_bx:
    mov dword [0x87A0], 0x00005842    ; "BX\0\0"
    jmp .return_error

.unsupported_ch:
    mov dword [0x87A0], 0x00004843    ; "CH\0\0"
    jmp .return_error

    ; ------------------------------------------------------------
    ; Return paths.
    ;   .return_success → CF=0, AH=0  (synthetic success / IRET)
    ;   .return_error   → CF=1, AH=0x80
    ;
    ; In both cases we restore caller's pushed state with pop es / pop
    ; ds / popa / popf, then patch the stacked FLAGS image so CF
    ; reflects our return, and patch the stacked AX-via-AH so caller
    ; sees the correct AH on iret. (The popa-restored AX matches what
    ; the caller passed in — we override AH for the result.)
    ; ------------------------------------------------------------

.return_success:
    pop es
    pop ds
    popa
    popf

    push bp
    mov bp, sp
    and word [bp+6], 0xFFFE          ; clear CF in stacked FLAGS
    pop bp
    xor ah, ah                       ; AH=0 = success
    iret

.return_error:
    pop es
    pop ds
    popa
    popf

    push bp
    mov bp, sp
    or word [bp+6], 0x0001           ; set CF in stacked FLAGS
    pop bp
    mov ah, 0x80                     ; AH=0x80 = hard error
    iret

.chain:
    jmp far [cs:orig_int93]

; ----------------------------------------------------------------
; Saved original int 0x93 vector.
; ----------------------------------------------------------------
orig_int93:
orig_int93_off: dw 0
orig_int93_seg: dw 0

; ----------------------------------------------------------------
; Embedded GDT for unreal-mode setup (mirrors mbx_test.asm).
; ----------------------------------------------------------------
align 8
gdt_start:
    dq 0                             ; null descriptor (selector 0x00)

    ; selector 0x08: 4 GB R/W data descriptor (base=0, limit=4G, G=1, D=1)
    dw 0xFFFF                        ; limit[15:0]
    dw 0x0000                        ; base[15:0]
    db 0x00                          ; base[23:16]
    db 0x92                          ; access: data, R/W, present, ring 0
    db 0xCF                          ; flags + limit[19:16]: G=1, D=1
    db 0x00                          ; base[31:24]
gdt_end:

gdtr_desc:
    dw gdt_end - gdt_start - 1       ; limit
    dd 0                             ; base — patched at runtime by entry

times 1024 - ($ - int93_fwd_start) db 0xFF
