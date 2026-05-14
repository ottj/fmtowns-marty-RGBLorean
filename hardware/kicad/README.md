# RGBLorean — KiCad project

Target: **KiCad 8.x**. PCB stack: **4-layer, 0.8 mm finished thickness** (required for PCMCIA Type I slot fit).

## Initial setup (do this once, from KiCad)

The `.kicad_pro` / `.kicad_sch` / `.kicad_pcb` files are not committed yet — create them from the KiCad GUI so the file format matches your installed version exactly:

1. KiCad 8 → **File → New Project…**
2. Project name: `RGBLorean`
3. Location: `hardware/kicad/` (this directory)
4. Untick "Create a new folder for the project" — files should land directly in `hardware/kicad/`.
5. Open the schematic, save as hierarchical root, then add the sheets listed below.
6. Open the PCB, **File → Board Setup → Physical Stackup**: set finished thickness to **0.8 mm**, 4 copper layers.

## Hierarchical sheet plan

Each sheet lives in `sheets/` and is referenced from the root schematic.

| Sheet file | Contents |
|---|---|
| `sheets/pcmcia.kicad_sch` | J1 68-pin connector, CD1#/CD2# tied to GND, VS1#/VS2# config, bus level translators (74LVC16245 × 2 for D[15:0] + 74LVC4245 for A[25:0]/control) |
| `sheets/power.kicad_sch` | +5V input from J1 pins 17/51, LDOs: 5V→3.3V (I/O + ADV7513 + SD), 5V→1.1V (ECP5 core), bulk + decoupling |
| `sheets/fpga.kicad_sch` | Lattice ECP5-25F caBGA256, configuration SPI flash, JTAG header, 25 MHz reference oscillator, all bypass caps |
| `sheets/video_in.kicad_sch` | 2×N pin header for digital RGB666 + HSYNC + VSYNC + HBLANK + FIELD + native pixel clock from the CRTC→downscaler bus on the Marty motherboard; 5V→3.3V level shifter (74LVC16245A), series termination, ESD diodes |
| `sheets/vga_out.kicad_sch` | ADV7123 triple 10-bit DAC + DE-15 connector, 75 Ω terminations, sync output buffers |
| `sheets/hdmi_out.kicad_sch` | ADV7513 + micro HDMI Type D + TMDS ESD/CMC, I²C pullups, I²S routing from FPGA |
| `sheets/sd_card.kicad_sch` | Micro SD socket (SDIO 4-bit + card detect), pullups, ESD |

## Component height constraint

| Region | Max above PCB | Max below PCB |
|---|---|---|
| Inside slot (first 85.6 mm from J1) | ~1.25 mm | ~1.25 mm |
| Extension (outside case) | unrestricted | unrestricted |

Place **only** J1 and any passives ≤1.0 mm tall (0402/0201 R/C, thin SOT-553 ESD) in the in-slot region. Everything active goes in the extension region.

## BOM-critical parts (long-lead / sourcing checks before committing footprints)

- PCMCIA 68-pin connector: **Amphenol FCI 95622-003LF** (Mouser) — needs custom footprint
- FPGA: **Lattice LFE5U-25F-6BG256C** (ECP5-25F caBGA256)
- HDMI TX: **ADV7513BSWZ** (BGA-100)
- Video DAC: **ADV7123KSTZ140** (TQFP-48)
- Bus translators: **74LVC16245A** (TSSOP-48), **74LVC4245A** (TSSOP-24)
- SDRAM: **AS4C32M16SB-7TCN** (16-bit, 64 MB, TSOP-54) — for HDMI frame buffer
- SD socket: Hirose DM3AT-SF-PEJM5 or similar push-push micro SD
