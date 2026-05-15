# Card memory map & mailbox protocol

## Marty-side address window

| Marty physical | Size | Function |
|---|---|---|
| `0x00D00000–0x00DFFFFF` | 1 MB | IC card common memory window |
| I/O `0x048A` | 1 byte | Card-status / write-protect (read) — internal to the controller |
| I/O `0x0490` | 1 byte | Bank-register low byte — **internal to the controller, never reaches the card** |
| I/O `0x0491` | 1 byte | Attribute-memory select (`REG#`) + card-type read — internal to the controller |

### Who decodes the bank register?

The bank register at I/O `0x0490` is **decoded entirely inside the Marty's IC-card controller** on the motherboard, *not* on the card. Confirmed by reading the Tsugaru source ([`src/towns/memory/physmem.cpp`](https://github.com/captainys/TOWNSEMU/blob/master/src/towns/memory/physmem.cpp)):

```cpp
case TOWNSIO_MEMCARD_BANK: //             0x490
    state.memCardBank = (data & 0x3F);
case TOWNSIO_MEMCARD_ATTRIB: //           0x491
    state.memCardREG  = (0 != (data & 1));
```

The controller stores `memCardBank` and `memCardREG` internally and *translates* every CPU access to the `0xD00000` window into a bus cycle on the card with the appropriate address bits driven from the bank value. No I/O cycle ever reaches the PCMCIA bus pins.

**Implications for RGBLorean:**

1. The FPGA target does **not** need to implement an I/O-cycle decoder for `0x0490` / `0x0491`. `MA_IORD_N` / `MA_IOWR_N` from the PCMCIA bus are never asserted during normal Marty memory-window accesses, and the bank register isn't seen by the card.
2. The FPGA simply consumes the **26-bit address** the controller drives onto `A[25:0]`. Whatever bank the CPU has programmed, the resulting linear address is what the FPGA sees.
3. The 4 PCMCIA control pins we wired through U_LS4 group 1 (`MA_IORD_N`, `MA_IOWR_N`) can therefore stay marked DNP / unused on the Marty target without functional loss. Keep them on the schematic for future PCMCIA-compatible designs but they have no firmware consequence here.
4. Tsugaru models a slightly looser address mapping on Marty (386SX): the 1 MB window at `0x00D00000` maps directly to `memCard.data[physAddr & 0xFFFFF]` without applying `memCardBank`. So in Tsugaru, only the first 1 MB of the card image is reachable in the Marty configuration — banking is a no-op for the 386SX path. Verify against real hardware once the FPGA card is fabricated.

## Card-side address space (FPGA-visible)

Given the controller-side banking story above, the FPGA sees a single linear address space driven by `A[25:0]`. We organise our internal storage as:

| Card offset | Size | Backing | Notes |
|---|---|---|---|
| `0x00000000–0x000003FF` | 1 KB | FPGA block RAM (mailbox) | Host ↔ FPGA control region (struct below) |
| `0x00000400–0x000007FF` | 1 KB | FPGA block RAM (IPL payload, sector 1) | Read-only from Marty; built by `firmware/x86/ipl/` |
| `0x00000000–0x0007FFFF` | up to 512 KB | FPGA block RAM (boot sector + IPL + initial resident driver image) | Read-only; written by FPGA from SD at boot if larger images become necessary |
| `0x00080000–0x000FFFFF` | up to 512 KB | SD card streaming window | Used for staging sector reads beyond the BRAM footprint |

Initial FPGA capacity (Phase 1) is just the first 8 KB of BRAM; later phases can fan out to SDRAM-backed regions.

**Sector-size convention:** Marty IC-card sectors are **1024 bytes**, not 512. The boot sector (sector 0) lives at file offsets `0x000..0x3FF`; the IPL payload (sector 1, LBA=1) at `0x400..0x7FF`. See `docs/context.md §5` and `firmware/x86/ipl/` for the verified layout.

**Execution model:** The Marty BIOS does not copy IO.SYS into low RAM. It maps the IC card image at host segment `0xB000` (= physical `0xB0000`) and `jmp 0xB000:0x400` directly into the payload. Code therefore runs **in place from the card window** (= FPGA BRAM on real hardware), with `CS=0xB000, IP=0x400` at entry. NASM payload sources must `org 0x400`. Confirmed in Tsugaru `MD B000:0` showing the boot sector's IPL4 magic verbatim.

## Mailbox layout (offset `0x00000000` within window)

```c
struct mailbox {
    volatile uint8_t  command;          // 0x000 — written by host
    volatile uint8_t  status;           // 0x001 — written by FPGA
    volatile uint16_t seq;              // 0x002 — host increments per request
    volatile uint32_t lba;              // 0x004
    volatile uint16_t sector_count;     // 0x008
    volatile uint16_t flags;            // 0x00A
    volatile uint32_t aux0;             // 0x00C — audio start LBA / TOC track
    volatile uint32_t aux1;             // 0x010 — audio length
    uint8_t  _pad[0x800 - 0x014];       // pad to 2 KB
    volatile uint8_t  sector_data[2048];// 0x800 — DATA: returned by FPGA
};
```

Note: the mailbox struct occupies offsets `0x000..0xFFF` (4 KB) of card space and lives **inside the boot sector**. The IPL4 magic (offset 0), LBA pointer (offset 0x20) and sector count (offset 0x24) overlay the first few mailbox fields. This is intentional: at power-on the FPGA initialises BRAM such that the first 64 bytes are a valid IPL4 boot sector, and the mailbox `command`/`status` reuse the otherwise-padding region after offset 0x28. The x86 driver must avoid disturbing offsets 0..0x27 once boot completes.

### Commands
| Code | Name | Args | Returns |
|---|---|---|---|
| 0x00 | NOOP | — | status=DONE |
| 0x01 | READ_SECTOR | lba, sector_count | sector_data[] |
| 0x02 | PLAY_AUDIO | aux0=start_lba, aux1=length_sectors | status=BUSY while playing |
| 0x03 | PAUSE | — | |
| 0x04 | STOP | — | |
| 0x05 | READ_TOC | aux0=track_num | sector_data[0..7] = MSF + flags |
| 0x06 | READ_SUBCH | — | sector_data[0..15] = current Q-channel |
| 0x10 | FPGA_INFO | — | sector_data = build ID + capabilities |

### Status
| Code | Meaning |
|---|---|
| 0x00 | IDLE — FPGA ready |
| 0x01 | BUSY — request in flight |
| 0x02 | DONE — result valid in sector_data |
| 0xFE | NOT_READY — SD not yet enumerated |
| 0xFF | ERROR — see `aux1` low byte for error code |

### Protocol

1. Host polls `status` until `IDLE`.
2. Host writes `lba`, `sector_count`, `aux*`, then increments `seq`, then writes `command` last.
3. Host polls `status` until `DONE` or `ERROR`. Audio commands return `DONE` immediately after queueing (playback continues async).
4. Host reads `sector_data` then writes `command = NOOP` to release.

`seq` is included so the FPGA can ignore torn writes (Marty writes the mailbox as half-words; only the last byte of `command` should trigger execution).
