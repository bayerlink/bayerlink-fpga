# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Move the picture without restarting anything.

    python3 scripts/skew.py <pixels> <framebuffer base>


The VDMA's read start address is what --skew sets, and it can be
rewritten while the design runs: change the three frame pointers, then
write VSIZE to make the engine take them. Bigger skew starts the read
further into the buffer, so the picture moves LEFT; smaller moves it
RIGHT.
"""
import sys
from pynq import Overlay, MMIO

MODE_W, MODE_H = 1920, 1080
skew = int(sys.argv[1])
base = int(sys.argv[2], 0)

ov = Overlay("/home/xilinx/rxvdma.bit", download=False)
vdma = MMIO(ov.ip_dict["vdma"]["phys_addr"], 0x1000)
for n in range(3):
    vdma.write(0x5C + 4 * n, base + skew * 4)
vdma.write(0x50, MODE_H)          # commit
print(f"skew now {skew} (base 0x{base:08x})")
