# FPGA gateware — RGBLorean

Target: **Lattice ECP5-25F caBGA256** (`LFE5U-25F-6BG256C`).
Toolchain: **Yosys + nextpnr-ecp5 + Project Trellis** (fully open source).

## Module tree (planned)

```
rtl/
├── top.sv                  Top-level: clocks, instantiates everything.
├── pcmcia_target.sv        Bus state machine: CE1#/CE2#/OE#/WE# → BRAM port.
├── bank_reg.sv             I/O 0x0490 bank register, latched on IOWR#.
├── mailbox.sv              Dual-port BRAM at offset 0 + command FSM.
├── sd/
│   ├── sd_phy.sv           SDIO line driver, CRC7/CRC16.
│   ├── sd_cmd.sv           Command issuer.
│   └── fat32_ro.sv         Read-only FAT32 walker (cluster chains, dir).
├── cue_parser.sv           Minimal CUE sheet decoder (called from soft core or done host-side).
├── video/
│   ├── rgb_capture.sv      Pin-synchronous RGB666 + HSYNC/VSYNC/BLANK/FIELD capture from CRTC→downscaler tap.
│   ├── rgb_extend.sv       RGB666 → RGB888 (MSB-replicate) for ADV7123 / ADV7513.
│   ├── vga_out.sv          Drives ADV7123 (passes RGB + HSYNC/VSYNC at native rate).
│   └── scaler.sv           Frame-buffered scaler to 480p/720p for HDMI.
├── hdmi/
│   ├── adv7513_init.sv     I²C ROM playback for ADV7513 register init.
│   └── i2s_out.sv          PCM → I²S to ADV7513 audio in.
├── audio/
│   └── cd_pcm_streamer.sv  Pulls PCM from SD, feeds i2s_out.
└── util/
    ├── i2c_master.sv
    ├── async_fifo.sv
    └── reset_sync.sv
```

## Clocks

| Domain | Source | Frequency | Used by |
|---|---|---|---|
| `clk_ref` | 25 MHz crystal oscillator (Y1) | 25.000 MHz | PLL reference |
| `clk_sys` | PLL #1 | 100 MHz | SD controller, mailbox, bus shadow |
| `clk_pix_in` | external from Marty CRTC tap (pre-downscaler bus) | 13.5 / 19.85 / 25.175 MHz (native, depends on video mode) | RGB capture |
| `clk_pix_out` | PLL #2 | 27 / 74.25 MHz | HDMI / VGA output |
| `clk_audio` | PLL #3 | 11.2896 MHz (256× 44.1 kHz) | I²S MCLK |

## Status

| Module | State | Notes |
|---|---|---|
| `rtl/pcmcia_target.sv` | **Phase 1 + mailbox + sd_reader integration** | BRAM-backed memory window + mailbox FSM. `READ_SECTOR` now goes through the `sd_reader` interface instead of an inline pattern generator. |
| `rtl/sd_reader.sv` | **stub** | Behavioral stub returning `word[i] = lba[15:0] + i` — same data the inline path emitted, so existing testbench assertions still hold. Real SDIO line protocol (CMD0/8/55+ACMD41/CMD17, CRC7/16) is a follow-up that will keep this exact interface. |
| `sim/pcmcia_target_tb.sv` | passing | Word + byte-enable + reset + tri-state checks |
| `sim/ipl_smoke_tb.sv` | passing | Loads `card.hex`, verifies IPL4 magic + LBA pointers + stub bytes |
| `sim/mailbox_tb.sv` | passing | Full mailbox protocol exercise (NOOP/FPGA_INFO/READ_SECTOR/unknown). Routes through `sd_reader` for READ_SECTOR. |
| SDIO real-hw layer | not yet implemented | Replaces the stub in `sd_reader.sv`. Will need: SDIO clock generation, CMD7/CRC, CMD17, R1/R7 response parsing. |

## Simulating the PCMCIA target

One-time setup on macOS:
```sh
brew install icarus-verilog gtkwave
```

Run the testbench:
```sh
cd firmware/fpga/sim
make           # → vvp pcmcia_target_tb.vvp ; prints PASS/FAIL
make wave      # → opens VCD in GTKWave
```

Expected output ends with `=== ALL TESTS PASSED ===`.

The testbench instantiates the target with `ADDR_BITS=8` (256-word / 512-byte
BRAM) for fast simulation and drives Marty-style PCMCIA bus cycles:

| Test | Behaviour exercised |
|---|---|
| T1 | Word write + read-back at 3 addresses |
| T2 | Address wrap when `fp_a` exceeds BRAM depth |
| T3 | Byte-enabled writes (~CE1 / ~CE2 alone) preserve the other byte |
| T4 | PCMCIA RESET clears the read latch but preserves memory contents |
| T5 | Data bus tri-states cleanly when no CE is asserted |

## Mailbox FSM commands

| Code | Name | Action |
|---|---|---|
| `0x00` | NOOP | release back to `IDLE` (also used to clear DONE / ERROR) |
| `0x01` | **READ_SECTOR** | reads `lba` (32-bit) + `sector_count` (16-bit) from mailbox flops, streams `SECTOR_WORDS` words into `sector_data[]` with pattern `word[i] = lba[15:0] + i`. Phase 1 stub — to be wired to real SDIO sector reads later. |
| `0x10` | FPGA_INFO | writes `"RGBL0001"` to `sector_data[0..7]` |
| any other | — | sets `ERROR` |

`SECTOR_WORDS` is a module parameter (default 1024 = 2 KB sector to match Marty CD-ROM convention; testbench overrides to 16 for fast simulation).

## What's *not* implemented yet

- **Bank register at I/O `0x0490`** — confirmed not the card's responsibility (decoded by the Marty mainboard's IC-card controller). See [`docs/memory-map.md`](../../docs/memory-map.md).
- Real backing for READ_SECTOR — `sd_reader.sv` exists as a stub returning a deterministic pattern. The next gateware phase replaces its behavioral implementation with **SPI-mode** SD-card host RTL (init: CMD0/CMD8/CMD55+ACMD41 loop, read: CMD17 + 0xFE start token + 512 data + CRC16). Protocol reference: [`docs/sd-protocol.md`](../../docs/sd-protocol.md). The `req` / `wr_idx` / `wr_data` / `wr_en` / `done` ports stay the same; each CD-ROM sector = 4 successive CMD17 reads concatenated.
- `PLAY_AUDIO`, `READ_TOC`, `READ_SUBCH` — placeholders only; will return ERROR.
- WAIT# generation — FPGA always meets timing for now.
- Video capture, scan conversion, HDMI / VGA output drivers — later phases.

## sd_reader interface contract

When the mailbox FSM enters `S_DECODE` with `command == CMD_READ_SECTOR`, it:
1. Pulses `sd_req` high for one cycle (with `lba_reg` stable on `sd_reader`'s `lba` input).
2. Transitions to `S_READ_WAIT`.

The `sd_reader` module then:
1. Latches the LBA, raises `busy`.
2. Streams `SECTOR_WORDS` (default 1024) words by driving `wr_idx` (0..SECTOR_WORDS-1) and `wr_data`, with `wr_en` high for one cycle per word.
3. Pulses `done` for one cycle after the last word, drops `busy`, returns to idle.

`pcmcia_target.sv` routes each (`wr_idx`, `wr_data`, `wr_en`) into the BRAM-write mux at `SECDATA_WORD + wr_idx`. On `done` the FSM advances to `S_DONE_WAIT`.

This contract is intentionally small and synchronous — fits real SDIO (CMD17 single-block read produces 512 bytes ≈ 256 16-bit words; we'll concatenate four reads inside the SDIO implementation to fill the 2048-byte CD-ROM sector). Multi-sector reads on the mailbox side would issue multiple `sd_req`s with successive LBAs.
