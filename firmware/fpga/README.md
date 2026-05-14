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
| `rtl/pcmcia_target.sv` | **Phase 1 in-progress** | Minimal BRAM-backed memory window; passes self-checking testbench |
| `sim/pcmcia_target_tb.sv` | passing | Word + byte-enable + reset + tri-state checks |
| everything else | not yet implemented | |

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

## What Phase 1 deliberately does *not* do yet

- **Bank register at I/O `0x0490`** — confirmed *not needed on the card*. The Marty IC-card controller decodes the I/O cycle internally and drives the banked 26-bit address onto the bus; the FPGA simply consumes it. See [`docs/memory-map.md`](../../docs/memory-map.md) for the trace from Tsugaru source.
- Mailbox protocol (see `docs/memory-map.md`) — RTL coming in next iteration.
- WAIT# handling — currently the FPGA always meets timing, no wait states asserted.
- Hooks for SD card, video capture, HDMI/VGA output — later phases.
