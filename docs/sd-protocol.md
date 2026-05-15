# SD-card protocol — minimal read-only reference

Reference notes for implementing the `sd_reader.sv` real-hardware layer. Compiled from the SD Physical Layer Simplified Spec v6.00+, ChaN's MMC/SD article, ZipCPU's SDSPI blog series, and a handful of open-source FPGA SD cores.

**Mode decision for RGBLorean: SPI mode.** Rationale at the bottom.

---

## 1. Init sequence

Power on the card with VDD stable at 3.3 V for ≥ 1 ms. With CMD/CS held high via pull-ups, drive **≥ 74 SDCLK cycles at 100–400 kHz**. This wakes the card's internal state machine. In SPI mode, CS must be high during these dummy clocks; assert CS low only when sending CMD0.

| # | Cmd | Name | Arg (32-bit) | Resp | Notes |
|---|-----|------|--------------|------|-------|
| 1 | CMD0 | GO_IDLE_STATE | 0x00000000 | R1 | Resets card to idle. In SPI mode this is what *enters* SPI mode (CS low during the command). CRC7 must be valid — magic byte is `0x40 0x00 0x00 0x00 0x00 0x95`. |
| 2 | CMD8 | SEND_IF_COND | 0x000001AA | R7 | 0x1AA = 2.7–3.6 V (`0001`) + check pattern `0xAA`. Card must echo `0xAA` + voltage nibble. CRC byte is `0x87`. No response → pre-v2 card; we don't care, all retail ≥ 4 GB cards are v2 SDHC. |
| 3 | CMD55 | APP_CMD | 0x00000000 | R1 | Prefix for any ACMD*. RCA matters only after CMD3; before then use 0. |
| 4 | ACMD41 | SD_SEND_OP_COND | 0x40FF8000 | R3 | Bit 30 = **HCS** (host supports SDHC). Bits 23:8 = VDD window. **Loop:** send CMD55+ACMD41 until R3's bit 31 (busy = 0 when ready) goes high. Spec timeout = 1 s. R3 also returns **CCS** (bit 30 of OCR): 1 = block-addressed (SDHC/SDXC), 0 = byte-addressed (SDSC). |
| 5 | CMD16 | SET_BLOCKLEN | 512 | R1 | **Not required for SDHC** — block length is fixed at 512. Skip if CCS=1. |

After this the card is ready. Switch SDCLK to **25 MHz** (default speed). Skip CMD6 high-speed (50 MHz) — we don't need the throughput.

## 2. Wire formats

**Command frame — always 48 bits, MSB first:**
```
[47] start=0   [46] tx=1   [45:40] cmd index   [39:8] argument   [7:1] CRC7   [0] end=1
```
6 bytes. CRC7 covers bits [47:8] (40 bits before the CRC).

**Response frames (SPI mode):**
- **R1** (1 byte): bit 7 = 0, then idle / erase-reset / illegal-cmd / CRC-err / erase-seq-err / addr-err / param-err.
- **R1b**: R1 + zero-valued busy bytes on MISO until card releases (reads `0x00` while busy, `0xFF` when done).
- **R2** (2 bytes): R1 + extended status.
- **R3 / R7** (5 bytes): R1 + 4-byte trailing payload (OCR or voltage-echo).

**Data block read (SPI):** after CMD17's R1, card sends `0xFF` idle bytes, then a **start token `0xFE`**, then 512 data bytes, then 2-byte CRC16 (big-endian).

## 3. CRC details

- **CRC7**, poly `x^7 + x^3 + 1` = `0x09`, init 0, over command bits [47:8]; placed at [7:1]; bit [0] is end=1.
- **CRC16-CCITT**, poly `x^16 + x^12 + x^5 + 1` = `0x1021`, init 0, over the 512 data bytes; appended.
- In **SPI mode**, CRC checking is *disabled by default* — card accepts any CRC7 except CMD0 (`0x95`) and CMD8 (`0x87`). You can enable with CMD59 CRC_ON_OFF but don't have to.
- **Data CRC16**: card always transmits it on reads. Host validation is optional in SPI. For an ODE feeding a CD bus that has its own EDC/ECC at the sector layer, **safe to skip** in v1.

## 4. Clocking & timing

- **Init clock**: 100–400 kHz. 200 kHz is conventional. From 100 MHz system clock, divide by 256 (~391 kHz).
- **Default speed**: 0–25 MHz. Divide 100 MHz by 4. Sample card outputs on rising edge, drive host outputs on falling edge.
- **74 dummy clocks** with CMD/CS high before CMD0. Spec is "≥ 74".
- **VDD ramp**: ≥ 0.1 ms, ≤ 35 ms, then ≥ 1 ms before first command.
- **Pull-ups**: 10–100 kΩ on CMD line, every DAT line including DAT3 (DAT3 doubles as CS in SPI mode — needs external pull-up for SPI-mode detect at CMD0). CLK doesn't need a pull-up.
- **Current**: peak ~100 mA on writes; reads 40–80 mA. Decouple VDD with 10 µF + 100 nF close to socket.

## 5. CMD17 single-block read

1. Compose CMD17 with arg = LBA (sector index) for SDHC. For SDSC use byte offset = LBA × 512.
2. Send 48-bit frame on MOSI.
3. Receive R1. Status byte must read 0 (or "in idle" cleared and no error bits set).
4. **Wait for the start token** `0xFE` on MISO. Timeout window `Nac` is up to **100 ms** — don't time out aggressively.
5. Clock in 512 data bytes on MISO.
6. Clock in 16-bit CRC16. Validate or discard.
7. Card returns to `0xFF` idle on MISO.

For CMD18 (multi-block) repeat from step 4; terminate with **CMD12 STOP_TRANSMISSION** (R1b).

After read, drop CS and pulse 8 clocks to let the card finalize internal state (ChaN-style defensive practice).

## 6. Open-source RTL references

- **[WangXuan95/FPGA-SDcard-Reader](https://github.com/WangXuan95/FPGA-SDcard-Reader)** — read-only SD-mode (1-bit) controller, MIT, ~500 LOC Verilog. Closest match to our use case despite being SD-mode not SPI; skip CRC16 validation (fine). **Read this first.**
- **ZipCPU's `sdspi`** — single-file SPI host in Verilog with [excellent companion blog series](https://zipcpu.com/blog/2018/06/06/sdspi-fsm.html). Best teaching reference for from-scratch. GPL.
- **OpenCores `sdcard_mass_storage_controller`** (Adam Edvardsson) — full SD-mode Wishbone core. Heavy but the CRC7/CRC16 modules are tidy and reusable. LGPL.
- **LiteSDCard** (enjoy-digital, used by LiteX/LambdaConcept) — production-quality, Migen-generated. Useful to read state-machine structure; not great as RTL to copy.

For ECP5 specifically, ULX3S and OrangeCrab ship working SD examples (mostly LiteSDCard-based) — sanity-check IO standards and pinning against.

## 7. Gotchas (FPGA from-scratch)

- **CMD0 CRC7 must be `0x95`** and **CMD8 CRC7 must be `0x87`** even in SPI mode, before CRC is "turned off". Hard-code these two if lazy; otherwise just always compute CRC7.
- **R1 in SPI arrives 0–8 byte-times after the command** (spec `Ncr`). Poll MISO for the first byte whose MSB is 0.
- **R1b busy in SD mode is on DAT0, not CMD**. Many first-timers wait on CMD and hang. (Not relevant in SPI but documented for completeness.)
- **ACMD vs CMD**: ACMD41 = CMD55 then CMD41. Check CMD55's R1, *then* send ACMD41. Forgetting CMD55 makes ACMD41 look like an illegal command — a useful debug signal in R1.
- **HCS bit in ACMD41** must be 1 for SDHC. Cards otherwise loop forever returning busy=1.
- **SDHC addresses are blocks (LBA)**, not bytes. Mixing this up makes every read return offset 0. Common error.
- **`Nac` read access time** can legitimately be tens of ms after CMD17 before the start token. Use a 100–250 ms timeout.
- **DAT3 pull-up in SPI mode**: omit it and some cards refuse to enter SPI mode (default-detect happens at CMD0).
- **Dirty hot-insert**: cards inserted under power sometimes need an extra CMD0 sequence after longer settle. Plan a re-init path triggered by any unexpected R1 bit.
- **Cheap card timing skew at 25 MHz**: some cards need the host to sample MISO on the *falling* edge (half-cycle delay). Make the sample edge a synth-time parameter.
- **CRC7 of all-zero arg** is easy to unit-test against the known CMD0/CMD8 magic bytes.

## SPI vs 1-bit SD mode — recommendation

**Start with SPI mode.** For RGBLorean specifically:

1. **No tri-state pads** in the ECP5 RTL — every signal is unidirectional. Far easier to write, simulate, and timing-close.
2. **Init flow is shorter** (no CMD2/CMD3/CMD7/RCA dance).
3. **R1 = 1 byte** makes the host state machine almost trivial.
4. **Bandwidth budget is trivial** — single-speed CD is 150 KB/s, 2× is 300 KB/s. Even 1 MHz SPI keeps up; 25 MHz SPI = ~3 MB/s with huge buffering headroom.
5. **Retarget path is contained** — if SPI ever proves flaky on a specific card, refactor to SD 1-bit reusing the CRC7/CRC16 and command-builder logic.

The only scenario pushing toward SD mode is sustained > 10 MB/s. Not our case.

## Sources

- SD Association, [Physical Layer Simplified Specification v6.00+](https://www.sdcard.org/downloads/pls/) — sections 4.2 (card identification), 4.7 (command format), 4.9 (response format), 4.4 (clock), 7 (SPI mode).
- ChaN, [How to Use MMC/SD](http://elm-chan.org/docs/mmc/mmc_e.html) — best practical SPI walkthrough, source of the `0x95`/`0x87` CRC-magic-byte trick.
- Wikipedia, [SD card](https://en.wikipedia.org/wiki/SD_card) — protocol overview.
- ZipCPU, [Building an SD Card Controller](https://zipcpu.com/blog/2018/06/06/sdspi-fsm.html) — RTL design notes.
- [WangXuan95/FPGA-SDcard-Reader](https://github.com/WangXuan95/FPGA-SDcard-Reader) — minimal read-only reference.
- [enjoy-digital/litesdcard](https://github.com/enjoy-digital/litesdcard) — production-quality reference.
