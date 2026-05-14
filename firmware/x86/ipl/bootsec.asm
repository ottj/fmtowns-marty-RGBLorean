; SPDX-License-Identifier: MIT
;
; bootsec.asm — RGBLorean IPL4 boot sector for FM Towns Marty (Sector 0)
;
; Confirmed against captainys' working `ICM_IPLM.ASM` + `ICMIMAGE.BIN`
; reference image (which boots on real Marty hardware and in Tsugaru):
;
;   - Sector size for IC-card boot on Marty is **1024 bytes**, not 512.
;   - The boot sector occupies file offset 0x000 .. 0x3FF.
;   - The Marty ROM reads this sector, checks for "IPL4" at offset 0,
;     reads LBA (offset 0x20, 32-bit LE) and sector-count (offset 0x24,
;     32-bit LE). It does NOT copy the IPL payload to low RAM — instead
;     the whole card image is window-mapped at host segment 0xB000 and
;     the ROM does `jmp 0xB000:(LBA*1024)` directly into sector 1. So
;     payload code runs in place from the card window with CS=0xB000,
;     IP=LBA*1024 at entry. Empirically verified in Tsugaru via
;     `MD B000:0` showing this boot sector's IPL4 header at the entry
;     segment.
;
;   - The Marty ROM does NOT execute any code in this boot sector —
;     it only parses the metadata. So this file has no executable code,
;     just the IPL4 signature + pointers.

bits 16

boot_sector_start:

    ; -----------------------------------------------------------------
    ; Offset 0x00 — "IPL4" magic (FM Towns Marty boot signature)
    ; -----------------------------------------------------------------
    db 'IPL4'

    ; -----------------------------------------------------------------
    ; Offsets 0x04..0x1F — volume label / reserved
    ; (Real images often put an ASCII label here. Marty ROM ignores it.)
    ; -----------------------------------------------------------------
    db 'RGBLOREAN MARTY IPL', 0
    times 0x20 - ($ - boot_sector_start) db 0

    ; -----------------------------------------------------------------
    ; Offset 0x20 — IO.SYS start LBA (32-bit little-endian)
    ;
    ; LBA 1 → file offset 1 * 1024 = 0x400 in card.bin (which is
    ; exactly where `iosys_stub.asm` is concatenated).
    ; -----------------------------------------------------------------
    dd 1

    ; -----------------------------------------------------------------
    ; Offset 0x24 — IO.SYS sector count (32-bit little-endian)
    ; -----------------------------------------------------------------
    dd 1

    ; -----------------------------------------------------------------
    ; Pad to one full Marty sector (1024 bytes).
    ; -----------------------------------------------------------------
    times 1024 - ($ - boot_sector_start) db 0
