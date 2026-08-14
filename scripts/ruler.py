#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Put a RULER on the screen, so an eye can measure the raster.

"Shifted right" is a feeling; this turns it into a number. The
framebuffer gets known landmarks at known coordinates and the display
path shows them: whatever the screen's edges cut off is exactly what
the raster and the display disagree about.

The ISP is left out of it -- only the read side runs -- so what appears
is a static pattern this script wrote, with nothing else able to move
it. The process STAYS ALIVE while it displays, because a raster reading
a freed buffer shows whatever the kernel puts there next.

    python3 ruler.py --bit rxlogo.bit --seconds 300
"""
import argparse
import signal
import sys
import time

import numpy as np
from pynq import Overlay, allocate, MMIO

W, H = 1920, 1080


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bit", default="rxlogo.bit")
    parser.add_argument("--seconds", type=float, default=300.0)
    parser.add_argument("--shift", type=int, default=0,
                        help="start the read this many pixels "
                             "into the buffer (must keep the address "
                             "64-byte aligned: multiples of 16 pixels)")
    parser.add_argument("--noise", action="store_true",
                        help="fill with random pixels instead of the "
                             "pattern: maximum transition density, which "
                             "is what a marginal TMDS link fails on")
    parser.add_argument("--vsize", type=int, default=0,
                        help="lines per VDMA frame (0 = the full frame). "
                             "1 makes every screen line show ONE buffer "
                             "line, which isolates the engine's own "
                             "frame-start offset from everything else")
    parser.add_argument("--line", type=int, default=0,
                        help="which buffer line to read (with --vsize 1)")
    args = parser.parse_args()

    # A plain kill must still stop the engines: a raster left reading a
    # buffer this process is about to free shows whatever the kernel
    # puts there next, which looks exactly like corrupted hardware.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    overlay = Overlay(args.bit, download=True)
    vdma = MMIO(overlay.ip_dict["vdma"]["phys_addr"], 0x1000)
    ctrl = MMIO(overlay.ip_dict["ctrl_gpio"]["phys_addr"], 0x1000)

    fb = allocate(shape=(H, W, 4), dtype="u1")
    print(f"framebuffer physical address: {fb.physical_address:#x}")
    img = np.zeros((H, W, 3), dtype=np.uint8)

    # 100-pixel bands across the whole width: red, green, blue, white,
    # repeating. Counting bands from either edge gives the offset to
    # within 100 px at a glance.
    band = [(180, 30, 30), (30, 180, 30), (40, 90, 220), (200, 200, 200)]
    for i in range(0, W, 100):
        img[:, i:i + 100] = band[(i // 100) % 4]

    # Ten-pixel ticks in a strip, for reading the offset finely.
    for x in range(0, W, 10):
        img[300:360, x:x + 1] = (255, 255, 0)
    for x in range(0, W, 50):
        img[280:380, x:x + 2] = (255, 255, 255)

    # The four extreme columns and rows, in a colour nothing else uses:
    # if these are missing, the display is cutting the edges (overscan),
    # not sliding the picture.
    img[:, 0:4] = (255, 0, 255)
    img[:, W - 4:W] = (0, 255, 255)
    img[0:4, :] = (255, 0, 255)
    img[H - 4:H, :] = (0, 255, 255)

    # A solid block in each corner, 60 px, so a cut corner is obvious.
    img[8:68, 8:68] = (255, 255, 255)
    img[8:68, W - 68:W - 8] = (255, 255, 0)
    img[H - 68:H - 8, 8:68] = (0, 255, 255)
    img[H - 68:H - 8, W - 68:W - 8] = (255, 0, 255)

    # The framebuffer's byte order is the one isp_axis packs and rgb2dvi
    # unpacks: G, B, R low to high (NOT R, G, B). Writing a picture from
    # software means writing it in the hardware's order, or every colour
    # name in the conversation is wrong -- which is how this pattern's
    # first outing got described in colours nobody had chosen.
    if args.noise:
        img = np.random.default_rng(1).integers(0, 256, img.shape,
                                                dtype=np.uint8)
    fb[:, :, 0] = img[:, :, 1]      # G
    fb[:, :, 1] = img[:, :, 2]      # B
    fb[:, :, 2] = img[:, :, 0]      # R
    fb[:, :, 3] = 0
    fb.flush()

    # STOP the engine before telling it where to read. Programming a
    # RUNNING VDMA leaves whatever it already prefetched at the head of
    # the stream, and that stale data carries the frame-start marker --
    # so the raster anchors correctly to a marker whose data belongs to
    # the previous configuration, and the picture rides a few hundred
    # pixels late for the rest of the session.
    vdma.write(0x00, 0x4)                 # reset this channel
    for _ in range(100):
        if not (vdma.read(0x00) & 0x4):   # self-clears when done
            break
        time.sleep(0.01)
    vdma.write(0x00, 0x0)                 # halted
    for _ in range(100):
        if vdma.read(0x04) & 0x1:         # SR.Halted
            break
        time.sleep(0.01)

    vdma.write(0x00, 0x3)
    for n in range(3):
        vdma.write(0x5C + 4 * n, fb.physical_address
                   + args.shift * 4 + args.line * W * 4)
    vdma.write(0x58, W * 4)
    vdma.write(0x54, W * 4)
    vdma.write(0x50, args.vsize if args.vsize else H)
    # Sweep the display path AFTER the engine is programmed, so the
    # raster hunts for a frame start in the stream it will actually be
    # fed. Re-programming a VDMA under a raster that still believes it
    # is aligned is how a picture acquires a permanent offset.
    ctrl.write(0, 0x1)
    time.sleep(0.05)
    ctrl.write(0, 0x0)
    time.sleep(0.2)
    print("ruler on screen: 100px bands (red, green, blue, white from x=0), "
          "10px ticks, magenta left/top edge, cyan right/bottom edge")
    try:
        time.sleep(args.seconds)
    except KeyboardInterrupt:
        pass
    finally:
        # The reader must not outlive the buffer either: it would keep
        # showing whatever lands in these pages next.
        vdma.write(0x00, 0x0)
        time.sleep(0.05)
    return 0


if __name__ == "__main__":
    sys.exit(main())
