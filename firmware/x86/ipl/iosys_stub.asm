; SPDX-License-Identifier: MIT
;
; iosys_stub.asm — RGBLorean "fake IO.SYS" for FM Towns Marty.
;
; Layout (after fixing the sector-size assumption — see bootsec.asm header):
;
;   - This file is concatenated at file offset 0x400 within card.bin
;     (= sector 1, with sector size 1024 bytes).
;   - Marty ROM loads it into RAM at physical 0x400 and **jumps directly
;     to RAM 0x400** — entry point is therefore the first byte of this
;     file, not 0x100 in.
;   - 1 sector = 1024 bytes total.
;
; What we do:
;   1) Set DS = ES = SS = 0 (segment registers may already be 0 but we
;      can't rely on it). Set SP somewhere safe — well above us, at 0x1000.
;   2) Drop the recognisable "RGBLOK!" marker at linear 0x600..
;   3) Halt loop.
;
; Confirmed by Tsugaru debugger: with BP at 0:400, this entry fires
; after the BIOS sees IPL4 + LBA/count and loads sector 1.

bits 16

iosys_stub_start:

    ; -----------------------------------------------------------------
    ; Entry point — file offset 0x000 in this image,
    ; = card.bin offset 0x400, = RAM physical 0x400 after the ROM load.
    ; -----------------------------------------------------------------
entry:
    cli

    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; Park SP at 0x1000 — well above our 0x400..0x7FF load region so
    ; the first PUSH won't trample the code we just got loaded into.
    mov sp, 0x1000

    ; -----------------------------------------------------------------
    ; Marker pattern at linear 0x600..0x608  →  "RGBLOK!\0" + version
    ; -----------------------------------------------------------------
    mov word [0x600], 0x4752   ; 'R' 'G'  (LE bytes: 52 47)
    mov word [0x602], 0x4C42   ; 'B' 'L'           42 4C
    mov word [0x604], 0x4B4F   ; 'O' 'K'           4F 4B
    mov word [0x606], 0x0021   ; '!' '\0'          21 00
    mov word [0x608], 0x0002   ; RGBLorean IPL stub version (bumped: rev B)

    ; -----------------------------------------------------------------
    ; Halt loop. Tsugaru / MAME will show CS:IP parked here.
    ; -----------------------------------------------------------------
.halt:
    hlt
    jmp short .halt

    ; -----------------------------------------------------------------
    ; Pad to one full 1024-byte Marty sector. The ROM loads `count`
    ; sectors of 1024 bytes each into RAM starting at 0x400. With
    ; count = 1 in the boot sector, only this 1024-byte stub is
    ; loaded — anything past offset 0x3FF here is loaded into RAM
    ; 0x7FF and beyond unused.
    ; -----------------------------------------------------------------
    times 1024 - ($ - iosys_stub_start) db 0xFF
