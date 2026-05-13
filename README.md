# RGBLorean

Expansion card for the FM Towns Marty that adds RGB / VGA / HDMI video out,
HDMI CD audio, and optical-disc emulation from an SD card — all through the
console's PCMCIA IC card slot, with no case cutting.

### Note: this project is in concept phase, nothing was built or tested!

See [`docs/context.md`](docs/context.md) for the full technical background.

## Repository layout

| Path | Contents |
|---|---|
| [`docs/`](docs/) | Technical context, pinouts, memory map, bring-up plan |
| [`hardware/kicad/`](hardware/kicad/) | KiCad 8 PCB project (hierarchical sheets in `sheets/`) |
| [`firmware/fpga/`](firmware/fpga/) | Lattice ECP5 gateware (Verilog/SV, Yosys + nextpnr) |
| [`firmware/x86/`](firmware/x86/) | IPL4 boot sector, `int 0x93` TSR, host tools |
| [`tools/`](tools/) | Shared utilities (SD image builder, mailbox harness) |

## Hardware design choices (locked)

- **FPGA:** Lattice ECP5-25F caBGA256 (`LFE5U-25F-6BG256C`), Yosys + nextpnr.
- **Bus interface:** 74LVC16245 / 74LVC4245 level translators between the
  Marty's 5 V bus and the FPGA's 3.3 V I/O.
- **PCB:** 4-layer, **0.8 mm** finished thickness (required for slot fit).
- **KiCad version:** 8.x.

## Development phases

Tracked in [`docs/bringup-plan.md`](docs/bringup-plan.md). High level:

1. PCMCIA memory interface + bank register (rev A PCB, minimum populate)
2. Boot from card (IPL4 stub)
3. SD card reader + `int 0x93` TSR (data-only ODE)
4. Video tap + VGA out (ADV7123)
5. HDMI out + scan conversion (ADV7513)
6. CD audio streaming over HDMI I²S
7. Rev B PCB (production)
