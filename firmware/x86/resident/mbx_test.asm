; SPDX-License-Identifier: MIT
;
; mbx_test.asm — RGBLorean mailbox-protocol smoke test.
;
; Replaces iosys_stub.asm as the IO.SYS-equivalent payload (sector 1, LBA=1)
; for end-to-end testing of the FPGA mailbox once real hardware is available.
;
; Boot model (verified empirically — see iosys_stub.asm header):
;   The Marty BIOS maps the IC card at segment 0xB000 and `jmp 0xB000:0x400`
;   directly into sector 1. CS=0xB000, IP=0x400 at entry. We execute in
;   place from the card window, not from copied low RAM. `org 0x400`
;   below aligns NASM's symbol values with runtime IP.
;
; Architectural note
; ------------------
; The IC card memory window lives at physical 0x00D00000 — beyond the
; ~1 MB reach of real mode. To access it from a real-mode IO.SYS payload
; we briefly enter protected mode, cache a 4 GB descriptor into FS, then
; exit protected mode. The cached descriptor base / limit survive in the
; FS shadow register ("unreal mode" / "big real mode"), so subsequent
; real-mode accesses through FS can use 32-bit linear offsets.
;
; Pass / fail markers (inspect in Tsugaru: MD 0:600, MD 0:700, MD 0:710, MD 0:718)
; -----------------------------------------------------------------------------
;   0x0600  "RGBLOK!\0\3\0"     stub entered (segment setup ok)
;   0x0700  "MAILBOX\0"         mailbox section reached
;   0x0710  "RGBL0001"          build ID read back from FPGA mailbox
;   0x0718  "OK\0\0"            FPGA_INFO completed cleanly
;             "FL\0\0"          timeout polling for STATUS=DONE
;             "PL\0\0"          timeout on IDLE-poll after NOOP release
;
; Caveat
; ------
; This test is meaningful only on real hardware (or in a simulator that
; emulates the FPGA mailbox). In stock Tsugaru the IC card slot is just
; a flat memory image, so writing 0x10 to 0xD00800 just stores 0x10
; there and reading 0xD00801 always returns whatever's there — DONE
; never appears, and the test will park at "FL". The FPGA-side mailbox
; logic is validated independently by firmware/fpga/sim/mailbox_tb.sv.
;
; Build (concatenated with bootsec.bin → card_mbx.bin):
;   make -C firmware/x86/ipl card_mbx.bin

bits 16
cpu 386                         ; need MOV EAX,CR0 + 32-bit operands
org 0x400                       ; runtime IP at entry (see boot-model note)

mbx_test_start:

; --------------------------------------------------------------------
; Entry — file offset 0x000, run-time linear 0x400
; --------------------------------------------------------------------
entry:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x1000              ; stack high above us

    ; Marker: "RGBLOK!\0" + version 0x0003
    mov word [0x600], 0x4752    ; 'R' 'G'
    mov word [0x602], 0x4C42    ; 'B' 'L'
    mov word [0x604], 0x4B4F    ; 'O' 'K'
    mov word [0x606], 0x0021    ; '!' '\0'
    mov word [0x608], 0x0003    ; stub version 3

    ; Marker: "MAILBOX\0"
    mov word [0x700], 0x414D    ; 'M' 'A'
    mov word [0x702], 0x4C49    ; 'I' 'L'
    mov word [0x704], 0x4F42    ; 'B' 'O'
    mov word [0x706], 0x0058    ; 'X' '\0'

    ; ----------------------------------------------------------------
    ; Unreal-mode setup: compute the *linear* base of our embedded GDT
    ; (CS may be 0 or 0x40 or anything else — Marty BIOS choice), patch
    ; gdtr_desc.base with it, then do the PE/PM/PE-off dance.
    ; ----------------------------------------------------------------
    xor eax, eax
    mov ax, cs
    shl eax, 4                  ; eax = CS * 16 (linear base of our code)
    add eax, gdt_start          ; + offset of gdt_start in our image
    mov [cs:gdtr_desc + 2], eax

    lgdt [cs:gdtr_desc]

    ; Enter protected mode
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp short .flush_pe
.flush_pe:

    ; Load FS with selector 0x08 → 4 GB data descriptor. FS shadow regs
    ; cache base=0, limit=0xFFFFFFFF, granularity=4K.
    mov bx, 0x08
    mov fs, bx

    ; Leave protected mode (FS shadow regs persist)
    mov eax, cr0
    and al, 0xFE
    mov cr0, eax
    jmp short .flush_real
.flush_real:

    ; FS now allows 32-bit linear addressing from real mode.

    ; ----------------------------------------------------------------
    ; Mailbox: write FPGA_INFO command (0x10) to byte 0xD00800
    ; ----------------------------------------------------------------
    mov byte [fs:dword 0x00D00800], 0x10

    ; Poll status byte 0xD00801 until it reads 0x02 (DONE), with timeout.
    mov ecx, 0x00010000          ; ~65k attempts ≈ 20 ms @ 16 MHz
.poll_done:
    mov al, [fs:dword 0x00D00801]
    cmp al, 0x02
    je short .got_done
    dec ecx
    jnz short .poll_done

    ; Timed out waiting for DONE → drop "FL" marker and halt.
    mov word [0x718], 0x4C46     ; 'F' 'L'
    jmp short .halt

.got_done:
    ; Copy 8 bytes of build ID from physical 0xD01000 to RAM 0x710.
    mov esi, 0x00D01000
    mov di, 0x0710
    mov cx, 8
.copy_loop:
    mov al, [fs:esi]
    mov [di], al
    inc esi
    inc di
    dec cx
    jnz short .copy_loop

    ; Release: write NOOP (0x00) to command, then wait for IDLE.
    mov byte [fs:dword 0x00D00800], 0x00
    mov ecx, 0x00010000
.poll_idle:
    mov al, [fs:dword 0x00D00801]
    test al, al
    jz short .ok
    dec ecx
    jnz short .poll_idle

    ; DONE went away but we never saw IDLE in time → "PL" (partial).
    mov word [0x718], 0x4C50     ; 'P' 'L'
    jmp short .halt

.ok:
    mov word [0x718], 0x4B4F     ; 'O' 'K'

.halt:
    hlt
    jmp short .halt

; --------------------------------------------------------------------
; Embedded GDT (2 entries: null + 4 GB data)
; --------------------------------------------------------------------

align 8
gdt_start:
    dq 0                         ; null descriptor (selector 0x00)

    ; selector 0x08: 4 GB data descriptor
    dw 0xFFFF                    ; limit[15:0]
    dw 0x0000                    ; base[15:0]
    db 0x00                      ; base[23:16]
    db 0x92                      ; access: data, R/W, present, ring 0
    db 0xCF                      ; flags + limit[19:16]: G=1, D=1, AVL=0, lim=F
    db 0x00                      ; base[31:24]
gdt_end:

gdtr_desc:
    dw gdt_end - gdt_start - 1   ; limit
    dd 0                         ; base — patched at runtime by entry code

; --------------------------------------------------------------------
; Pad to one full 1024-byte Marty sector.
; --------------------------------------------------------------------
    times 1024 - ($ - mbx_test_start) db 0xFF
