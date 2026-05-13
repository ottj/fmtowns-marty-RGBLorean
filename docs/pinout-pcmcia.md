# PCMCIA 68-pin connector — net names for schematic

Source: `docs/context.md` §3. Use these exact net names in `sheets/pcmcia.kicad_sch` so the FPGA pin assignments match without translation.

## Connector reference designator: **J1**

| Pin | Net (Marty side) | FPGA-side net (after level shift) | Notes |
|---:|---|---|---|
| 1 | GND | GND | |
| 2 | MA_D3 | FP_D3 | |
| 3 | MA_D4 | FP_D4 | |
| 4 | MA_D5 | FP_D5 | |
| 5 | MA_D6 | FP_D6 | |
| 6 | MA_D7 | FP_D7 | |
| 7 | MA_CE1_N | FP_CE1_N | active-low |
| 8 | MA_A10 | FP_A10 | |
| 9 | MA_OE_N | FP_OE_N | active-low |
| 10 | MA_A11 | FP_A11 | |
| 11 | MA_A9 | FP_A9 | |
| 12 | MA_A8 | FP_A8 | |
| 13 | MA_A13 | FP_A13 | |
| 14 | MA_A14 | FP_A14 | |
| 15 | MA_WE_N | FP_WE_N | active-low |
| 16 | MA_IREQ_N | FP_IREQ_N | open-drain, optional |
| 17 | +5V_IN | — | power pin |
| 18 | NC (Vpp1) | — | leave floating |
| 19 | MA_A16 | FP_A16 | |
| 20 | MA_A15 | FP_A15 | |
| 21 | MA_A12 | FP_A12 | |
| 22 | MA_A7 | FP_A7 | |
| 23 | MA_A6 | FP_A6 | |
| 24 | MA_A5 | FP_A5 | |
| 25 | MA_A4 | FP_A4 | |
| 26 | MA_A3 | FP_A3 | |
| 27 | MA_A2 | FP_A2 | |
| 28 | MA_A1 | FP_A1 | |
| 29 | MA_A0 | FP_A0 | |
| 30 | MA_D0 | FP_D0 | |
| 31 | MA_D1 | FP_D1 | |
| 32 | MA_D2 | FP_D2 | |
| 33 | MA_WP / IOIS16_N | FP_IOIS16_N | tie low or drive from FPGA |
| 34 | GND | GND | |
| 35 | GND | GND | |
| 36 | CD1_N | — | **tie to GND** |
| 37 | MA_D11 | FP_D11 | |
| 38 | MA_D12 | FP_D12 | |
| 39 | MA_D13 | FP_D13 | |
| 40 | MA_D14 | FP_D14 | |
| 41 | MA_D15 | FP_D15 | |
| 42 | MA_CE2_N | FP_CE2_N | active-low |
| 43 | VS1_N | — | leave floating (5V card) |
| 44 | MA_IORD_N | FP_IORD_N | unused in memory mode |
| 45 | MA_IOWR_N | FP_IOWR_N | unused in memory mode |
| 46 | MA_A17 | FP_A17 | |
| 47 | MA_A18 | FP_A18 | |
| 48 | MA_A19 | FP_A19 | |
| 49 | MA_A20 | FP_A20 | |
| 50 | MA_A21 | FP_A21 | |
| 51 | +5V_IN | — | power pin (parallel with 17) |
| 52 | NC (Vpp2) | — | leave floating |
| 53 | MA_A22 | FP_A22 | |
| 54 | MA_A23 | FP_A23 | |
| 55 | MA_A24 | FP_A24 | wired but unused on Marty (24-bit CPU) |
| 56 | MA_A25 | FP_A25 | wired but unused on Marty |
| 57 | VS2_N | — | leave floating |
| 58 | MA_RESET | FP_RESET | |
| 59 | MA_WAIT_N | FP_WAIT_N | open-drain from card |
| 60 | MA_INPACK_N | FP_INPACK_N | |
| 61 | MA_REG_N | FP_REG_N | |
| 62 | MA_BVD2 | FP_BVD2 | |
| 63 | MA_BVD1 | FP_BVD1 | |
| 64 | MA_D8 | FP_D8 | |
| 65 | MA_D9 | FP_D9 | |
| 66 | MA_D10 | FP_D10 | |
| 67 | CD2_N | — | **tie to GND** |
| 68 | GND | GND | |

## Mandatory ties

- **CD1_N (36), CD2_N (67) → GND** directly on the card. Marty refuses to enumerate otherwise.
- **+5V_IN (17, 51)** → bulk cap and LDO inputs. Treat as a single net but route both pins.
- **VS1_N (43), VS2_N (57)** → no connect (5 V card signalling).

## Level-shifter mapping (74LVC16245 × 2 + 74LVC4245 × 1, all in /OE permanent-enable layout)

Direction is controlled per cycle by `MA_OE_N` / `MA_WE_N` for data lanes; address and control are always Marty→FPGA.

| Translator | Function | A-side (5V) | B-side (3.3V) | DIR |
|---|---|---|---|---|
| U_LS1 | D[7:0] bidir | MA_D[7:0] | FP_D[7:0] | OE_N = output, else input |
| U_LS2 | D[15:8] bidir | MA_D[15:8] | FP_D[15:8] | OE_N = output, else input |
| U_LS3 | A[25:0] + ctrl in | MA_A[25:0], CE1/2_N, OE_N, WE_N, REG_N, RESET | FP_* | fixed Marty→FPGA |

WAIT_N is an open-drain output from the card — drive via discrete N-FET pulldown rather than through a translator, so it never fights other cards on a shared bus (not relevant here, but it's the canonical pattern).
