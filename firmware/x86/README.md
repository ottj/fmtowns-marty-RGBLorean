# x86 firmware — RGBLorean

Three deliverables, all targeting **16-bit real mode → optional 32-bit unreal/protected** on the FM Towns Marty (AMD 386SX, 16 MHz).

## Status

| Component | State | Notes |
|---|---|---|
| `ipl/bootsec.asm` | done | 512 B IPL4 boot sector; points at sector 1 |
| `ipl/iosys_stub.asm` | done | Stub IO.SYS; drops "RGBLOK!" marker at 0x600 then halts |
| `ipl/Makefile` | done | NASM build → `card.bin` (emulator) + `card.hex` (FPGA BRAM init) |
| `tools/bin2hex.py` | done | Bin → `$readmemh` converter |
| `resident/` | not started | int 0x93 TSR (Phase 2) |
| other host tools | not started | |

## Building the IPL

One-time setup:
```sh
brew install nasm
```

Build:
```sh
cd firmware/x86/ipl
make
```

Produces:
- `bootsec.bin` — 512 B sector 0 (IPL4 magic + LBA pointers)
- `iosys_stub.bin` — 512 B sector 1 (fake IO.SYS, loaded to 0x400, entry at 0x500)
- `card.bin` — 1024 B raw image (used by FPGA `card.hex` build)
- `card_64k.bin` — 65 536 B image padded with 0xFF, **use this with emulators** — the Marty BIOS rejects 1 KB JEIDA4 images; 64 KB matches captainys' working reference (`ICMIMAGE.BIN`)
- `card.hex` — same image formatted for FPGA `$readmemh`

## Validating in an emulator

**Tsugaru** (the FM Towns emulator by captainys):
```sh
Tsugaru_CUI path/to/marty_bios -JEIDA4 card_64k.bin -BOOTKEY ICM -TOWNSTYPE MARTY
```
Or via the GUI: insert `card_64k.bin` as an IC card, hold I+C+M during reset.

To inspect what happens with the debugger:
```sh
Tsugaru_CUI path/to/marty_bios -JEIDA4 card_64k.bin -BOOTKEY ICM -TOWNSTYPE MARTY -DEBUG -PAUSE
# in the console that opened:
> BP 0:500           # break at our stub entry
> RUN
> MD 0:600           # after it halts, dump our marker — expect "RGBLOK!"
```

Expected behaviour: ROM loads our stub, jumps to `0x500`, executes the marker writes, halts. In Tsugaru's debugger you should see:
- `CS:IP` parked at the `hlt; jmp` loop near `0x0050:0x0010` (i.e., linear 0x510)
- Memory at `0x600..0x608` = `52 47 42 4C 4F 4B 21 00 01 00` = "RGBLOK!\0\1\0"

**MAME** (`fmtowns` driver) accepts the same image as `-icmem`.

## Validating against the FPGA sim

After `make` in `firmware/x86/ipl/`, the FPGA `ipl_smoke_tb` testbench can read the same image back through the PCMCIA bus model:
```sh
cd firmware/fpga/sim
make ipl    # loads card.hex into BRAM, asserts IPL4 magic + LBA pointers + stub bytes
```

## 1. `ipl/` — IPL4 boot sector

## 1. `ipl/` — IPL4 boot sector

512 bytes, written into the first sector of the card's logical image (offset 0 in the memory window). The Marty ROM looks for the magic `"IPL4"` at offset 0 and reads the IO.SYS location from offsets `0x20` (LBA) and `0x24` (sector count).

Trick: point `0x20`/`0x24` at our own loader image; the Marty ROM will read it as if it were IO.SYS, load it to `0x0000:0x0400`, and jump to `0x0000:0x0500`.

Toolchain: NASM, `nasm -f bin bootsec.asm -o bootsec.bin`.

## 2. `resident/` — TSR that hooks `int 0x93`

Replaces the IVT entry at `0x0000:0x024C` (= int 0x93 × 4) with our handler. The handler:

1. Saves all registers.
2. Inspects function code in AH (per FM Towns Technical Databook).
3. If the call targets the CD-ROM drive (drive code = 0xA0..) → translate to a mailbox request, poll for completion, copy `sector_data` to the caller's buffer (ES:BX or similar — verified per function), return.
4. Otherwise chains to the original `int 0x93` (saved at install time).

Size budget: **≤ 32 KB resident**. Written in NASM with a tiny C helper layer compiled with **Open Watcom 16-bit** (no runtime).

Key functions to implement (int 0x93, AH = ...):
- `0x05` Read sectors (CD-ROM mode 1)
- `0x52` Play audio
- `0x53` Stop / pause
- `0x54` Read subchannel
- `0x55` Read TOC

(Exact function codes to be verified against Tsugaru's TBIOS implementation in `townscdrom.cpp`.)

## 3. `tools/` — host-side build & image utilities

- `mkdiskimg.py` — assembles the card image (IPL4 sector + IO.SYS-shaped loader + resident.bin) into a binary suitable for flashing into FPGA BRAM at synthesis time or for staging on SD.
- `bin2coe.py` / `bin2hex.py` — convert binaries to FPGA-toolchain memory init formats.
- `cuepack.py` — pre-process BIN/CUE into a layout the FPGA's CUE parser can ingest without floating-point.

These run on the host (Linux/macOS) under Python 3.10+.
