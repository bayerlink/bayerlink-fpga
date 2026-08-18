#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate the output tee: one ISP stream, two switchable consumers.

Off means DISCARD -- with both outputs off the pipeline keeps running,
which is what lets statistics keep computing in standby -- and
switching is frame-atomic, so neither the store nor the display ever
receives a partial frame.

    python3 gen/tee.py
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def main() -> None:
    from np2hw import skid, tee
    # 33 bits: {sof, last, eol, rgb[29:0]} -- tee_shim.v owns the layout.
    out = HERE / "hdl" / "generated"
    out.mkdir(exist_ok=True)
    result = tee(33, module_name="isp_tee")
    (out / "isp_tee.v").write_text(result["verilog"] + "\n")
    # The skid in front of it is what terminates the READY CONE: every
    # traced core's in_ready is combinational from its downstream, so
    # the chain passes ready sink-to-source, one gate deeper per block
    # -- boundary_report has said so since the day it was written, and
    # the tee's lockstep fork was the level that finally tipped it
    # (-0.557ns through seven blocks of ripple). One registered
    # boundary at the pipe's output ends the cone regardless of what
    # is wired downstream.
    result = skid(33, module_name="isp_skid")
    (out / "isp_skid.v").write_text(result["verilog"] + "\n")
    print("generated hdl/generated/isp_tee.v + isp_skid.v "
          "(33-bit, frame-atomic, ready cone terminated)")


if __name__ == "__main__":
    main()
