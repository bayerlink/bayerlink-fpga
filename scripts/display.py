#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Receive frames, show them on the second HDMI: the loopback demo.

The simplest possible ISP sits in the middle -- shift 12-bit samples to
8 and replicate to gray -- running on the ARM between the two proven
DMA paths. Its entire purpose is the moment a monitor on HDMI OUT
shows what enters HDMI IN through the fabric. The fabric ISP replaces
exactly this loop later; the display plumbing stays.

Run on PYNQ Linux, source streaming (pattern or camera):

    python3 display.py --bit rx.bit --width 512 --height 240
"""
import argparse
import sys
import time

import numpy as np
from pynq import Overlay, allocate, MMIO

MODE_W, MODE_H = 1280, 720


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bit", default="rx.bit")
    parser.add_argument("--width", type=int, default=512)
    parser.add_argument("--height", type=int, default=240)
    parser.add_argument("--seconds", type=float, default=60.0)
    parser.add_argument("--bits", type=int, default=12,
                        choices=(8, 10, 12, 14, 16),
                        help="source sample depth, for the gray shift only: "
                             "the v2 receiver unpacks every depth in fabric "
                             "and hands over unshifted samples")
    args = parser.parse_args()

    overlay = Overlay(args.bit, download=True)
    ctrl = MMIO(overlay.ip_dict["ctrl_gpio"]["phys_addr"], 0x1000)
    gpio = MMIO(overlay.ip_dict["status_gpio"]["phys_addr"], 0x1000)
    dma = MMIO(overlay.ip_dict["dma"]["phys_addr"], 0x1000)
    vdma = MMIO(overlay.ip_dict["vdma"]["phys_addr"], 0x1000)

    for _ in range(60):
        if (gpio.read(0) >> 5) & 1:
            break
        time.sleep(0.5)
    else:
        print("no receiver activity: is the source streaming?")
        return 2
    ctrl.write(0, 1)
    time.sleep(0.05)
    ctrl.write(0, 0)
    time.sleep(0.1)

    # Framebuffer out: VDMA MM2S parked circularly over one buffer.
    # 4 bytes per pixel: the vdma streams 32-bit beats and vid_push
    # takes the low 24 -- xRGB in memory, word-aligned blits.
    fb = allocate(shape=(MODE_H, MODE_W, 4), dtype="u1")
    fb[:] = 16
    fb.flush()
    vdma.write(0x00, 0x3)                       # MM2S: run, circular
    for n in range(3):
        vdma.write(0x5C + 4 * n, fb.physical_address)
    vdma.write(0x58, MODE_W * 4)                # stride
    vdma.write(0x54, MODE_W * 4)                # hsize
    vdma.write(0x50, MODE_H)                    # vsize -> go

    def txstat():
        s = gpio.read(0x8)                      # channel 2: TX testimony
        vp = s >> 17                            # vid_push status[14:1]... [14:0]>>3 below
        return {"mmcm": (s >> 16) & 1,
                "sof": (vp >> 4) & 1, "aligned": (vp >> 5) & 1,
                "under": (vp >> 6) & 1, "misalign": (vp >> 7) & 1,
                "alive": (vp >> 8) & 7, "vsyncs": (vp >> 11) & 0xF}
    time.sleep(0.5)
    a = txstat()
    time.sleep(0.5)
    b = txstat()
    ticking = (a["alive"] != b["alive"]) or (a["vsyncs"] != b["vsyncs"])
    print(f"display running; framebuffer live; tx: mmcm={b['mmcm']} "
          f"aligned={b['aligned']} sof={b['sof']} under={b['under']} "
          f"misalign={b['misalign']} raster_ticking={ticking}")

    n = args.width * args.height
    cap = allocate(shape=(max(200000, n + 4096),), dtype="u4")
    x0 = (MODE_W - args.width) // 2
    y0 = (MODE_H - args.height) // 2

    def packet():
        dma.write(0x30, 1)
        dma.write(0x48, cap.physical_address)
        dma.write(0x58, len(cap) * 4)
        for _ in range(500):
            if dma.read(0x34) & 0x2:
                break
            time.sleep(0.002)
        got = dma.read(0x58) // 4
        cap.invalidate()
        return np.array(cap[:got])

    # The v2 receiver unpacks every depth in fabric (the header owns the
    # format); samples arrive unshifted in [15:0]. Gray is just a shift.
    shift = max(args.bits - 8, 0)

    frames = 0
    t0 = time.time()
    while time.time() - t0 < args.seconds:
        packet()                                # align on a frame boundary
        words = packet()
        if len(words) != n:
            continue
        gray = ((words & 0xFFFF) >> shift).astype("u1").reshape(
            args.height, args.width)
        fb[y0:y0 + args.height, x0:x0 + args.width, 0] = gray
        fb[y0:y0 + args.height, x0:x0 + args.width, 1] = gray
        fb[y0:y0 + args.height, x0:x0 + args.width, 2] = gray
        fb.flush()
        frames += 1
    print(f"{frames} frames shown in {args.seconds:.0f}s "
          f"({frames / max(args.seconds, 1):.1f} fps through the ARM)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
