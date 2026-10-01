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

The design must include the capture path. Its GPIO fields are read by
name from the gpio_layout.json its build wrote beside the bitstream:
this script writes no bit position down, and refuses a layout whose
checksum, built into the fabric, does not read back.
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
from bayerlink import pattern
from pynq import Overlay, allocate, MMIO


def field(layout, gpio, name):
    """(register offset, low bit, width) of one GPIO field, by name."""
    for channel in layout[gpio]["channels"]:
        if name in channel["fields"]:
            f = channel["fields"][name]
            return channel["offset"], f["lsb"], f["bits"]
    raise SystemExit(f"{gpio} has no field {name!r} in this build -- is "
                     "the capture path in it?")


def verify(layout, overlay):
    """Refuse a layout that is not the loaded bitstream's: every field the
    build marked `constant` must read back the value the file states."""
    for gpio, block in layout.items():
        mmio = MMIO(overlay.ip_dict[gpio]["phys_addr"], 0x1000)
        for channel in block["channels"]:
            for name, f in channel["fields"].items():
                if not f.get("constant"):
                    continue
                got = (mmio.read(channel["offset"]) >> f["lsb"]) \
                    & ((1 << f["bits"]) - 1)
                if got != f["value"]:
                    raise SystemExit(
                        f"gpio_layout.json is not this bitstream's: {gpio} "
                        f"{name} reads 0x{got:08X}, the file says "
                        f"0x{f['value']:08X}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bit", default="rx.bit")
    parser.add_argument("--width", type=int, default=512)
    parser.add_argument("--height", type=int, default=240)
    parser.add_argument("--frames", type=int, default=4)
    args = parser.parse_args()

    layout = json.loads(Path(args.bit).with_name("gpio_layout.json")
                        .read_text())
    overlay = Overlay(args.bit, download=True)
    verify(layout, overlay)
    ctrl = MMIO(overlay.ip_dict["ctrl_gpio"]["phys_addr"], 0x1000)
    gpio = MMIO(overlay.ip_dict["status_gpio"]["phys_addr"], 0x1000)
    dma = MMIO(overlay.ip_dict["dma"]["phys_addr"], 0x1000)
    n = args.width * args.height
    expect = np.asarray(pattern.counting(args.width, args.height)).ravel()
    buffer = allocate(shape=(max(200000, n + 4096),), dtype="u4")

    # Wait for the link, then ONE reset pulse with both clocks running:
    # the async crossings initialize only when both sides reset together.
    # A header accepted is the receiver saying a bayerlink source is
    # there.
    at, lsb, _ = field(layout, "status_gpio", "hdr_valid")
    for _ in range(60):
        if (gpio.read(at) >> lsb) & 1:
            break
        time.sleep(0.5)
    else:
        print("no header accepted: is the source streaming?")
        return 2
    # The judge is the stream's consumer (consumer = 0); everything else
    # in the word off, the broom pulsed.
    at, broom, _ = field(layout, "ctrl_gpio", "broom")
    field(layout, "ctrl_gpio", "consumer")
    ctrl.write(at, 1 << broom)
    time.sleep(0.05)
    ctrl.write(at, 0)
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
    try:
        for trial in range(args.frames):
            packet()                      # partial: aligns the next one
            words = packet()
            data = (words & 0xFFFF).astype(np.int64)
            sof = (words >> 17) & 1
            eol = (words >> 16) & 1
            ok = (len(words) == n and np.array_equal(data, expect)
                  and len(sof) and sof[0] == 1 and int(sof.sum()) == 1
                  and np.array_equal(np.flatnonzero(eol),
                                     np.arange(1, args.height + 1) * args.width
                                     - 1))
            passes += ok
            print(f"frame {trial + 1}: {len(words)} samples ->",
                  "BIT-EXACT, FRAMING EXACT" if ok else "MISMATCH")
    finally:
        # A writer must not outlive its buffer: a killed run would leave
        # the DMA holding this (about to be freed) address, writing into
        # it whenever the stream next flows. Stop the engine first.
        dma.write(0x30, 0)
    print(f"VERDICT: {passes}/{args.frames} frames exact")
    return 0 if passes == args.frames else 1


if __name__ == "__main__":
    sys.exit(main())
