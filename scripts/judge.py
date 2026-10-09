#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Judge the receive path on the board's own ARM, against the codec.

Run on PYNQ Linux, with the bitstream loaded (load.py) and the source
streaming the counting pattern:

    sudo -s   # or the sudo -v dance; the registers and the DMA need root
    python3 judge.py --bit rx.bit --width 512 --height 240

Captures are aligned by discarding one DMA packet (the stream cannot
be paused; the first packet starts mid-frame and ends at its tlast),
then judged: every sample equal to pattern.counting, sof exactly once
and first, eol on every line end. Four consecutive frames must pass.

The DMA is re-armed the moment the discarded packet ends, and nothing is
done in between: the stream does not wait for it. While the engine is
idle the capture FIFO fills with the next frame's first few thousand
samples and the rest is dropped, so a re-arm later than the vertical
blank and that FIFO cover captures the frame's head, a hole, and its
tail -- a short frame the receiver never sent. Polling the engine with
5 ms sleeps, and copying the discarded packet first, was late that way
about one frame in two hundred.

The design must include the capture path. Its GPIO fields are read by
name from the gpio_layout.json its build wrote beside the bitstream, and
its registers found through the address_map.json beside it: this script
writes no bit position or address down, and refuses a layout whose
checksum, built into the fabric, does not read back.

It judges the fabric as loaded and programs nothing: loading is
load.py's, and the checksum is what proves the loaded bitstream is the
one whose files it reads. While it judges, it is the stream's consumer
and the direct picture is off; when it is done, however it ends, the
control word is given back as it found it.
"""
import argparse
import json
import signal
import sys
import time
from pathlib import Path

import numpy as np
from bayerlink import pattern
from pynq import allocate, MMIO


def field(layout, gpio, name):
    """(register offset, low bit, width) of one GPIO field, by name."""
    for channel in layout[gpio]["channels"]:
        if name in channel["fields"]:
            f = channel["fields"][name]
            return channel["offset"], f["lsb"], f["bits"]
    raise SystemExit(f"{gpio} has no field {name!r} in this build -- is "
                     "the capture path in it?")


def mmio(bit, name):
    """A register slave's window, from the address map its build wrote
    beside the bitstream: the design's bus places the slaves, and the
    hardware handoff cannot see where."""
    slaves = json.loads(Path(bit).with_name("address_map.json").read_text())
    if name not in slaves:
        raise SystemExit(f"address_map.json places no {name!r}; it places "
                         f"{sorted(slaves)}")
    return MMIO(slaves[name]["base"], slaves[name]["size"])


def verify(layout, bit):
    """Refuse a layout that is not the loaded bitstream's: every field the
    build marked `constant` must read back the value the file states."""
    for gpio, block in layout.items():
        regs = mmio(bit, gpio)
        for channel in block["channels"]:
            for name, f in channel["fields"].items():
                if not f.get("constant"):
                    continue
                got = (regs.read(channel["offset"]) >> f["lsb"]) \
                    & ((1 << f["bits"]) - 1)
                if got != f["value"]:
                    raise SystemExit(
                        f"gpio_layout.json is not this bitstream's: {gpio} "
                        f"{name} reads 0x{got:08X}, the file says "
                        f"0x{f['value']:08X}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bit", default="rx.bit",
                        help="the loaded bitstream: its build's files are "
                             "read from beside it")
    parser.add_argument("--width", type=int, default=512)
    parser.add_argument("--height", type=int, default=240)
    parser.add_argument("--frames", type=int, default=4)
    args = parser.parse_args()
    # stopped by `timeout`, a service manager or `kill`, the judge still
    # stops its engine and gives the board back: SIGTERM is an exit, and
    # the cleanup below runs on it as on any other
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

    layout = json.loads(Path(args.bit).with_name("gpio_layout.json")
                        .read_text())
    verify(layout, args.bit)
    ctrl = mmio(args.bit, "ctrl_gpio")
    gpio = mmio(args.bit, "status_gpio")
    dma = mmio(args.bit, "dma")
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
    at, broom, _ = field(layout, "ctrl_gpio", "broom")
    field(layout, "ctrl_gpio", "consumer")
    # what the board was doing -- the ISP the consumer, the direct picture
    # on, as it powers up -- given back when the judge is done, however it
    # ends: a judge that left the board judging would leave the TV black
    before = ctrl.read(at)

    def packet(keep=True):
        """One packet, to its tlast: polled without sleeping, so whatever
        follows starts the moment it ends; its samples, if `keep`."""
        dma.write(0x30, 1)
        dma.write(0x48, buffer.physical_address)
        dma.write(0x58, len(buffer) * 4)
        deadline = time.monotonic() + 2.5    # a frame at 3 fps, with room
        while not dma.read(0x34) & 0x2 and time.monotonic() < deadline:
            pass
        if not keep:
            return None
        got = dma.read(0x58) // 4
        buffer.invalidate()
        return np.array(buffer[:got])

    passes = 0
    try:
        # The judge is the stream's consumer (consumer = 0); everything
        # else in the word off, the broom pulsed.
        ctrl.write(at, 1 << broom)
        time.sleep(0.05)
        ctrl.write(at, 0)
        time.sleep(0.1)
        for trial in range(args.frames):
            packet(keep=False)            # partial: aligns the next one
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
        ctrl.write(at, before & ~(1 << broom))
    print(f"VERDICT: {passes}/{args.frames} frames exact")
    return 0 if passes == args.frames else 1


if __name__ == "__main__":
    sys.exit(main())
