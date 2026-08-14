#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Bring the ISP up exactly as isp.py does, then SAVE the framebuffer.

A picture that sits in the wrong place on a screen has two suspects:
what the ISP wrote, and where the raster read it. This reads the
framebuffer itself, which settles it -- the file is what the fabric
actually deposited in memory, before any raster touched it.

    python3 fbdump.py --bit rxlogo.bit --out fb.npy
"""
import argparse
import signal
import sys
import time

import numpy as np
from pynq import Overlay, allocate, MMIO

MODE_W, MODE_H = 1920, 1080
ISP_W, ISP_H = 1920, 1080


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bit", default="rxlogo.bit")
    parser.add_argument("--out", default="fb.npy")
    parser.add_argument("--settle", type=float, default=3.0)
    args = parser.parse_args()

    # A plain kill must still stop the engines: a raster left reading a
    # buffer this process is about to free shows whatever the kernel
    # puts there next, which looks exactly like corrupted hardware.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    overlay = Overlay(args.bit, download=True)
    ctrl = MMIO(overlay.ip_dict["ctrl_gpio"]["phys_addr"], 0x1000)
    gpio = MMIO(overlay.ip_dict["status_gpio"]["phys_addr"], 0x1000)
    vdma = MMIO(overlay.ip_dict["vdma"]["phys_addr"], 0x1000)

    for _ in range(60):
        if (gpio.read(0) >> 5) & 1:
            break
        time.sleep(0.5)
    else:
        print("no receiver activity: is the source streaming?")
        return 2

    fb = allocate(shape=(MODE_H, MODE_W, 4), dtype="u1")
    fb[:] = 0                       # black, so anything written stands out
    fb.flush()

    vdma.write(0x00, 0x3)
    for n in range(3):
        vdma.write(0x5C + 4 * n, fb.physical_address)
    vdma.write(0x58, MODE_W * 4)
    vdma.write(0x54, MODE_W * 4)
    vdma.write(0x50, MODE_H)

    x0 = (MODE_W - ISP_W) // 2
    y0 = (MODE_H - ISP_H) // 2
    base = fb.physical_address + (y0 * MODE_W + x0) * 4
    vdma.write(0x30, 0x3)
    for n in range(3):
        vdma.write(0xAC + 4 * n, base)
    vdma.write(0xA8, MODE_W * 4)
    vdma.write(0xA4, ISP_W * 4)
    vdma.write(0xA0, ISP_H)

    ctrl.write(0, 0x3)
    time.sleep(0.05)
    ctrl.write(0, 0x2)

    time.sleep(args.settle)
    try:
        fb.invalidate()
        np.save(args.out, np.array(fb[:, :, :3]))
        print(f"saved {args.out}: {MODE_H}x{MODE_W}x3")
    finally:
        vdma.write(0x30, 0x0)       # a writer must not outlive its buffer
        time.sleep(0.05)
    return 0


if __name__ == "__main__":
    sys.exit(main())
