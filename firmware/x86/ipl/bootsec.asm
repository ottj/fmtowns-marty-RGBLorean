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
;     32-bit LE), loads count sectors from `LBA * 1024` into RAM at
;     0x400, then jumps to RAM 0x400 (start of the loaded sector).
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
