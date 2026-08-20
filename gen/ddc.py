#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate the DDC slave: this receiver's calling card and control port.

The EDID stops being a borrowed monitor identity (a canned 720p file)
and becomes the receiver's own: the preferred detailed timing IS the
bayerlink container -- 1920x1081 at 30, one header row above the
payload -- so a source that honours EDID lands on the right raster
without being forced, and the monitor name says plainly what answered.
The same engine serves the register personality at 0x37: the ISP's
whole register file, readable and writable across the display cable,
refusal (SLVERR while the file is armed) answered as NACK.

    python3 gen/ddc.py
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

# The container raster, from the same numbers scanout and the bridge
# use: 74.25 MHz, 2200x1125 total, 1920x1081 active.
PCLK_10KHZ = 7425
HACT, HBLANK = 1920, 280
VACT, VBLANK = 1081, 44
HSO, HSW = 88, 44          # hsync offset/width (2008-1920, 2052-2008)
VSO, VSW = 3, 5            # vsync offset/width (1084-1081, 1089-1084)


def build_edid() -> bytes:
    e = bytearray(128)
    e[0:8] = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    # PnP id "BLK" -- three 5-bit letters, A=1
    pnp = (2 << 10) | (12 << 5) | 11
    e[8], e[9] = pnp >> 8, pnp & 0xFF
    e[10:12] = (1).to_bytes(2, "little")     # product: 1 = the rx
    e[12:16] = (0).to_bytes(4, "little")     # serial
    e[16], e[17] = 1, 2026 - 1990            # week, year
    e[18], e[19] = 1, 3                      # EDID 1.3
    e[20] = 0x80                             # digital input
    e[21], e[22] = 0x30, 0x1B                # 48x27 cm, honesty optional
    e[23] = 120                              # gamma 2.2
    e[24] = 0x0A                             # RGB, preferred timing
    e[25:35] = bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F,
                      0x50, 0x54])           # sRGB-ish chromaticity
    e[35:38] = bytes(3)                      # no established timings
    e[38:54] = bytes([0x01, 0x01] * 8)       # no standard timings
    # The one detailed timing: the container itself.
    e[54:72] = bytes([
        PCLK_10KHZ & 0xFF, PCLK_10KHZ >> 8,
        HACT & 0xFF, HBLANK & 0xFF,
        ((HACT >> 8) << 4) | (HBLANK >> 8),
        VACT & 0xFF, VBLANK & 0xFF,
        ((VACT >> 8) << 4) | (VBLANK >> 8),
        HSO & 0xFF, HSW & 0xFF,
        ((VSO & 0xF) << 4) | (VSW & 0xF),
        ((HSO >> 8) << 6) | ((HSW >> 8) << 4)
        | ((VSO >> 4) << 2) | (VSW >> 4),
        0, 0, 0, 0, 0,
        0x1E,                                # separate sync, +h +v
    ])
    e[72:90] = bytes([0, 0, 0, 0xFC, 0]) + b"BAYERLINK RX\n"
    e[90:108] = (bytes([0, 0, 0, 0xFD, 0, 29, 31, 30, 40, 8, 0, 0x0A])
                 + b"\x20" * 6)              # 29-31 Hz, 30-40 kHz
    e[108:126] = bytes([0, 0, 0, 0x10, 0]) + bytes(13)
    e[126] = 0                               # no extension blocks
    e[127] = (-sum(e[:127])) % 256
    return bytes(e)


def main() -> None:
    from np2hw import ddc_slave
    out = HERE / "hdl" / "generated"
    out.mkdir(exist_ok=True)
    edid = build_edid()
    result = ddc_slave(reg_addr7=0x37, edid=edid, edid_addr7=0x50)
    (out / "ddc_slave.v").write_text(result["verilog"] + "\n")
    (out / "edid.bin").write_bytes(edid)
    print(f"ddc_slave.v: regs at 0x37, EDID at 0x50 "
          f"({len(edid)} bytes, checksum ok, "
          f"preferred {HACT}x{VACT}@30)")


if __name__ == "__main__":
    main()
