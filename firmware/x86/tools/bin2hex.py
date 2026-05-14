#!/usr/bin/env python3
"""bin2hex.py — convert a binary blob to Verilog `$readmemh`-compatible text.

Each output line is one 16-bit little-endian word from the input, written
as four hex digits. Matches the byte-ordering expected by the BRAM in
`firmware/fpga/rtl/pcmcia_target.sv` (which stores `{high_byte, low_byte}`
in each 16-bit word).

Usage:
    bin2hex.py <input.bin> <output.hex>

If the input length is odd, the trailing byte is paired with 0xFF.
"""

import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    in_path = Path(argv[1])
    out_path = Path(argv[2])

    data = in_path.read_bytes()
    if len(data) % 2:
        data += b"\xff"

    lines = [f"{(data[i] | (data[i + 1] << 8)):04x}" for i in range(0, len(data), 2)]
    out_path.write_text("\n".join(lines) + "\n")
    print(f"bin2hex: {in_path.name} ({len(data)} B) -> {out_path.name} ({len(lines)} words)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
