# Card memory map & mailbox protocol

## Marty-side address window

| Marty physical | Size | Function |
|---|---|---|
| `0x00D00000–0x00DFFFFF` | 1 MB | IC card common memory window (bank-switched) |
| I/O `0x0490–0x0491` | 2 bytes | Bank register (R/W) — selects which 1 MB of card space is mapped |

## Card-side address space (FPGA-visible)

Total presented: **64 MB** maximum (26-bit, `bank << 20 | addr[19:0]`). Actual decoded ranges:

| Card offset | Size | Backing | Notes |
|---|---|---|---|
| `0x00000000` | 4 KB | FPGA block RAM (mailbox) | Always visible regardless of bank — alias into every bank's first page |
| `0x00001000–0x000FFFFF` | ~1 MB | FPGA block RAM (IPL + resident driver image) | Read-only from Marty; written by FPGA from SD at boot |
| `0x00100000–0x03FFFFFF` | up to 63 MB | SD card window (paged DMA) | Used for staging large reads if needed |

## Mailbox layout (offset `0x00000000` within window, bank-independent)

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

## Bank register semantics (port 0x0490)

- 16-bit register; reset value = 0.
- Bits [5:0] = bank index. Each bank = 1 MB of card space.
- Bits [15:6] reserved, read as 0.
- Marty writes 16-bit; FPGA latches both bytes on `IOWR_N` rising edge.

**Implementation note:** the bank register lives in the FPGA's I/O space, not in the memory window. The Marty's IC card controller decodes `0x0490–0x0491` internally and translates to a memory-window access with a special qualifier — verify against MAME `fmtowns.cpp` and Tsugaru source before finalising. If the controller does *not* expose the bank write to the card pins, the bank is unselectable and we must use a different scheme (e.g. write-triggered bank via a magic address within the memory window).
