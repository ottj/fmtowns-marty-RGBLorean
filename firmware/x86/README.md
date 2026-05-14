# x86 firmware — RGBLorean

Three deliverables, all targeting **16-bit real mode → optional 32-bit unreal/protected** on the FM Towns Marty (AMD 386SX, 16 MHz).

## Status

| Component | State | Notes |
|---|---|---|
| `ipl/bootsec.asm` | done | 1024 B IPL4 boot sector (Marty uses 1 KB sectors); points at sector 1 |
| `ipl/iosys_stub.asm` | done | Stub IO.SYS; drops "RGBLOK!" marker at 0x600 then halts. Validated in Tsugaru. |
| `resident/mbx_test.asm` | done — pending hw | Unreal-mode mailbox client; issues FPGA_INFO and verifies the build-ID readback. Compile-time validated; runtime needs real FPGA hardware (or a Tsugaru build with a mailbox-aware memcard model). |
| `resident/int93_tsr.asm` | done — Tsugaru-validatable | IVT-hook validation harness. Three-stage smoke test (boot model / direct call / int dispatch). |
| `resident/int93_fwd.asm` | iteration 3 (mailbox forwarding) | Filters on `AL=0xC0 + AH=0x05`, decodes the call, issues a `READ_SECTOR` mailbox request to the FPGA (via unreal-mode FS at `0xD00800`), copies sector_data to caller `DS:DI`, returns synthetic success. Single-sector only; multi-sector + MSF + 32-bit linear are deferred. Self-test in Tsugaru lands on `"FL"` (timeout, no FPGA); real hardware should land on `"OK"`. |
| `ipl/Makefile` | done | NASM build → `card.bin`, `card_mbx.bin`, `card_64k.bin`, `card_mbx_64k.bin`, plus `card.hex` for FPGA BRAM init |
| `tools/bin2hex.py` | done | Bin → `$readmemh` converter |
| `resident/` (TSR) | not started | int 0x93 TSR for the real ODE path (Phase 2) |

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
- `iosys_stub.bin` — 1024 B sector 1 (fake IO.SYS, runs in place at `0xB000:0x400`)
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

Expected behaviour: Marty BIOS maps the IC card at segment `0xB000` and `jmp 0xB000:0x400` directly into sector 1 — our stub runs in place from the card window. In Tsugaru's debugger you should see:
- `MD B000:0` showing the boot sector's `49 50 4C 34 …` ("IPL4…") header
- `CS:IP` parked at the `hlt; jmp` loop inside the stub at `0xB000:0x4xx`
- Memory at `0x600..0x608` = `52 47 42 4C 4F 4B 21 00 02 00` = "RGBLOK!\0\2\0" (DS=0 absolute writes still land in low RAM regardless of CS)

**MAME** (`fmtowns` driver) accepts the same image as `-icmem`.

## Validating against the FPGA sim

After `make` in `firmware/x86/ipl/`, the FPGA `ipl_smoke_tb` testbench can read the same image back through the PCMCIA bus model:
```sh
cd firmware/fpga/sim
make ipl    # loads card.hex into BRAM, asserts IPL4 magic + LBA pointers + stub bytes
make mbx    # exercises the mailbox FSM directly via the bus model (no x86 client)
```

The two testbenches together cover both sides of the mailbox protocol:
- `ipl_smoke_tb` proves the FPGA correctly *serves* the boot image to the Marty bus
- `mailbox_tb` proves the FPGA correctly *responds* to mailbox commands

`resident/mbx_test.asm` is the x86 *client* side of the mailbox protocol — what the Marty CPU will run to talk to the FPGA. It assembles cleanly but its meaningful runtime test target is real hardware (or a Tsugaru fork that knows about our mailbox).

### int 0x93 TSR card image

```sh
cd firmware/x86/ipl
make card_tsr_64k.bin
```

Layout:

```
0x00000 .. 0x003FF   bootsec.bin       (IPL4 magic + LBA pointers)
0x00400 .. 0x007FF   int93_tsr.bin     (hook installer + handler)
0x00800 .. 0x0FFFF   0xFF padding
```

Run in Tsugaru:
```sh
Tsugaru_CUI path/to/marty_bios -JEIDA4 card_tsr_64k.bin -BOOTKEY ICM -TOWNSTYPE MARTY
```

Expected markers after boot:

| Linear addr | Expected bytes | Meaning |
|---|---|---|
| `0x0600` | `52 47 42 4C 4F 4B 21 00 04 00` | `"RGBLOK!\0\4\0"` — entry reached (TSR stub, version 4) |
| `0x0700` | `49 4E 54 39 33 48 4B 00` | `"INT93HK\0"` — install path executed |
| `0x0720` | `99 48 4F 4F 4B` | `0x99` + `"HOOK"` — hook fired with AH=0x99 |
| `0x0740` | dword | saved original int 0x93 vector |
| `0x0750` | `54 45 53 54 4F 4B 00 00` | `"TESTOK\0\0"` — control returned after `int 0x93` |

If `0x720` does NOT show `99`, the IVT install failed (check that `[0x24C]` points to our hook). If `0x750` is empty, the IRET path didn't return control to main.

### int 0x93 forwarding TSR card image

Mailbox-forwarding TSR. The hook on `AL=0xC0, AH=0x05` (CD-ROM read HSG) issues a `READ_SECTOR` mailbox request to the FPGA at `0xD00800`, copies the returned `sector_data` to the caller's `DS:DI` buffer, and returns synthetic success — **without** ever chaining to the original BIOS.

```sh
cd firmware/x86/ipl
make card_fwd_64k.bin
```

Layout:

```
0x00000 .. 0x003FF   bootsec.bin       (IPL4 magic + LBA pointers)
0x00400 .. 0x007FF   int93_fwd.bin     (forwarding hook installer + handler)
0x00800 .. 0x0FFFF   0xFF padding
```

Run in Tsugaru (no `-CD` needed — the hook doesn't chain):
```sh
Tsugaru_CUI path/to/marty_bios -JEIDA4 card_fwd_64k.bin -BOOTKEY ICM -TOWNSTYPE MARTY
```

`entry` puts the CPU into unreal mode (so the hook can use 32-bit linear addressing via FS to reach `0xD00800`), installs the hook at IVT[0x93], then synthesises one `int 0x93` shaped like a real CD-ROM read: `AX=0x05C0`, `BX=1` (single sector — multi-sector NYI), `CX=0` (CH=0 real-mode buffer), `DX=0x0064` (LBA=100), `DS:DI = 0:0x2000`.

In Tsugaru there is no FPGA — writes to `0xD00800` go into flat host RAM and `STATUS` never transitions to `DONE`, so the hook's poll times out. Expected markers:

| Linear addr | Tsugaru (no FPGA) | Real hw (FPGA stub) |
|---|---|---|
| `0x8600` | `52 47 42 4C 4F 4B 21 00 07 00` (`"RGBLOK!\0\7\0"`) | same |
| `0x8700` | `"INT93FW!"` | same |
| `0x8750` | `"DONE"` — main resumed after iret | same |
| `0x8768` | `'P'` (`0x50`) — hook returned `AH=0` synthetic success | same |
| `0x876C` | AX with AH=0 | same |
| `0x876E` | CF clear (bit 0 = 0) | same |
| `0x8770..0x877F` | **unchanged** (whatever was at `0:0x2000` before) | `64 00 65 00 66 00 67 00 68 00 69 00 6A 00 6B 00` — FPGA stub pattern `word[i] = lba[15:0] + i` for LBA=100 |
| `0x8780` | hit count = `01 00` | same |
| `0x8790..0x879F` | ring slot 0 (table below) | same |
| `0x87A0` | `"FL\0\0"` — timeout waiting for `STATUS=DONE` | `"OK\0\0"` — full handshake completed |

Ring slot 0 (`MD 0:8790`, little-endian words):

| Offset | Field | Expected |
|---|---|---|
| `+0` | AX | `C0 05` (AH=0x05 read-HSG, AL=0xC0 CD-ROM family) |
| `+2` | BX | `01 00` (sector count = 1) |
| `+4` | CX | `00 00` (CL=0 LBA-hi, CH=0 real-mode buffer mode) |
| `+6` | DX | `64 00` (DH=0 LBA-mid, DL=0x64=100 LBA-lo) → LBA = 100 |
| `+8` | DS | `00 00` (caller's DS at int) |
| `+A` | DI | `00 20` (= 0x2000, buffer offset) |
| `+C` | ES | `00 00` (caller's ES at int) |
| `+E` | IP | offset of instruction immediately after `int 0x93` |

Result-code semantics at `0:0x87A0`:

| Bytes | Meaning |
|---|---|
| `"OK\0\0"` | READ_SECTOR + NOOP/IDLE handshake completed cleanly |
| `"FL\0\0"` | Timeout polling for `STATUS=DONE` (expected in Tsugaru — no FPGA to drive it) |
| `"PL\0\0"` | Got DONE but timed out waiting for IDLE after NOOP release |
| `"BX\0\0"` | Caller passed `BX != 1` (multi-sector NYI) — returns `CF=1, AH=0x80` |
| `"CH\0\0"` | Caller passed `CH != 0` (32-bit linear buffer mode NYI) — returns `CF=1, AH=0x80` |

Failure modes:
- `0x8780 == 0` → AL/AH filter rejected our synthetic call.
- `0x8780 == 1` but `0x8750` empty → hook didn't iret cleanly — likely a stack-frame bug in `.return_success`.
- `0x87A0 == "    "` (4× space) → matched path branched somewhere that doesn't write a result code; check the assert lines for BX/CH unsupported.

Note: scratch is in the `0x8000+` band because the Marty BIOS scribbles `0:0x600..0x7FF` as CD-driver scratch when chained calls run (verified in iteration 2). The mailbox-forwarding path doesn't chain, but the same scratch convention is kept for consistency with the rest of the binary.

Next iteration: multi-sector reads (`BX > 1`), 32-bit linear buffer mode (`CH=0xFF`), and the AH=0x15 (MSF) path with MSF→HSG conversion.

### Mailbox-test card image

```sh
cd firmware/x86/ipl
make card_mbx_64k.bin
```

Layout:

```
0x00000 .. 0x003FF   bootsec.bin     (IPL4 magic + LBA pointers)
0x00400 .. 0x007FF   mbx_test.bin    (unreal-mode mailbox client)
0x00800 .. 0x0FFFF   0xFF padding
```

On real Marty + RGBLorean card, expected results after boot from this image:

| Linear addr | Expected bytes | Meaning |
|---|---|---|
| `0x8600` | `52 47 42 4C 4F 4B 21 00 03 00` | `"RGBLOK!\0\3\0"` — boot stub reached entry |
| `0x8700` | `4D 41 49 4C 42 4F 58 00` | `"MAILBOX\0"` — mailbox path reached |
| `0x0710` | `52 47 42 4C 30 30 30 31` | `"RGBL0001"` — FPGA build ID round-tripped |
| `0x0718` | `4F 4B 00 00` | `"OK"` — happy path |
|         | `46 4C 00 00` | `"FL"` — timed out waiting for STATUS=DONE |
|         | `50 4C 00 00` | `"PL"` — partial: DONE seen but IDLE never returned |

## 1. `ipl/` — IPL4 boot sector

## 1. `ipl/` — IPL4 boot sector

512 bytes, written into the first sector of the card's logical image (offset 0 in the memory window). The Marty ROM looks for the magic `"IPL4"` at offset 0 and reads the IO.SYS location from offsets `0x20` (LBA) and `0x24` (sector count).

Trick: point `0x20`/`0x24` at our own loader image; the Marty ROM will read it as if it were IO.SYS and `jmp 0xB000:0x400` directly into the payload (the whole card image is window-mapped at segment `0xB000` — the BIOS does **not** copy IO.SYS into low RAM). NASM payload sources therefore `org 0x400` so that symbol values match runtime IP.

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
