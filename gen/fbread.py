#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate the framebuffer read engine that feeds the display.

This replaces the vendor DMA's read side. The DMA fetched the frame back
perfectly well and made one thing impossible: knowing when its first beat
arrived relative to the raster's first pixel. That offset landed
somewhere new every time the link locked -- 0, 16, 48 and 80 pixels were
all measured on this bench from reloads of an unchanged bitstream -- and
it was corrected by hand, with `--skew` on a command line.

That was survivable while a person reloaded the design anyway. It stopped
being survivable when the link learned to recover on its own: every
replug re-locks, so every replug re-rolled the offset, and a picture that
comes back in a random place has not recovered.

This engine owns the addressing, so its first beat IS the frame's first
pixel and it says so on tuser. There is no offset to measure.

    python3 gen/fbread.py
"""
import argparse
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser()
    # 64-beat bursts, not 16: the address channel cannot raise arvalid
    # again until the cycle after it is accepted, so every burst costs
    # about two cycles it does not spend moving data. At 16 beats that
    # is 0.87 beats/clock against the 0.84 a 1080p60 raster averages --
    # true, but four percent is not margin. At 64 it is 0.95, and the
    # raster's own blanking absorbs what is left: measured at zero
    # starved cycles across a whole frame.
    parser.add_argument("--burst", type=int, default=64)
    parser.add_argument("--fifo", type=int, default=512,
                        help="beats of prefetch: the whole tolerance for "
                             "DDR latency and for other masters holding "
                             "the bus, so it is what decides whether a "
                             "busy interconnect shows on the screen")
    args = parser.parse_args()

    from np2hw.video_mem import framebuffer_read

    result = framebuffer_read(data_bits=32, addr_bits=32,
                              burst_len=args.burst, fifo_depth=args.fifo,
                              module_name="fbread")
    out = HERE / "hdl" / "generated"
    out.mkdir(exist_ok=True)
    (out / "fbread.v").write_text(result["verilog"] + "\n")
    print(f"generated hdl/generated/fbread.v "
          f"(32-bit, {args.burst}-beat bursts, {args.fifo}-beat prefetch)")


if __name__ == "__main__":
    main()
