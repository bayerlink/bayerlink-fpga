#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Judge the receive path on the board's own ARM, against the codec.

Run on PYNQ Linux, with the source streaming the counting pattern:

    sudo -s   # or the sudo -v dance; the overlay download needs root
    python3 judge.py --bit rx.bit --width 512 --height 240

Captures are aligned by discarding one DMA packet (the stream cannot
be paused; the first packet starts mid-frame and ends at its tlast),
then judged: every sample equal to pattern.counting, sof exactly once
and first, eol on every line end. Four consecutive frames must pass.
"""
import argparse
import sys
import time

import numpy as np
from bayerlink import pattern
from pynq import Overlay, allocate, MMIO


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bit", default="rx.bit")
    parser.add_argument("--width", type=int, default=512)
    parser.add_argument("--height", type=int, default=240)
    parser.add_argument("--frames", type=int, default=4)
    args = parser.parse_args()

    overlay = Overlay(args.bit, download=True)
    ctrl = MMIO(overlay.ip_dict["ctrl_gpio"]["phys_addr"], 0x1000)
    gpio = MMIO(overlay.ip_dict["status_gpio"]["phys_addr"], 0x1000)
    dma = MMIO(overlay.ip_dict["dma"]["phys_addr"], 0x1000)
    n = args.width * args.height
    expect = np.asarray(pattern.counting(args.width, args.height)).ravel()
    buffer = allocate(shape=(max(200000, n + 4096),), dtype="u4")

    # Wait for the link, then ONE reset pulse with both clocks running:
    # the async crossings initialize only when both sides reset together.
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

    def packet():
        dma.write(0x30, 1)
        dma.write(0x48, buffer.physical_address)
        dma.write(0x58, len(buffer) * 4)
        for _ in range(500):
            if dma.read(0x34) & 0x2:
                break
            time.sleep(0.005)
        got = dma.read(0x58) // 4
        buffer.invalidate()
        return np.array(buffer[:got])

    passes = 0
    for trial in range(args.frames):
        packet()                          # partial: aligns the next one
        words = packet()
        data = (words & 0xFFFF).astype(np.int64)
        sof = (words >> 17) & 1
        eol = (words >> 16) & 1
        ok = (len(words) == n and np.array_equal(data, expect)
              and len(sof) and sof[0] == 1 and int(sof.sum()) == 1
              and np.array_equal(np.flatnonzero(eol),
                                 np.arange(1, args.height + 1) * args.width - 1))
        passes += ok
        print(f"frame {trial + 1}: {len(words)} samples ->",
              "BIT-EXACT, FRAMING EXACT" if ok else "MISMATCH")
    print(f"VERDICT: {passes}/{args.frames} frames exact")
    return 0 if passes == args.frames else 1


if __name__ == "__main__":
    sys.exit(main())
