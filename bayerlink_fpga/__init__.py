# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""bayerlink on FPGAs: the receiver and what any board needs around it.

Two layers, the second reusable by any board:

  the receiver       np2hw's bayerlink_in, the DDC slave that is the
                     receiver's EDID and control port, and the Verilog
                     around them (hdl/): link reset and the capture
                     path's AXIS dressing. Nothing here knows a board.
  frontends/<name>   what turns a cable into parallel video -- pixel
                     clock, data enable, vsync, 24 bits -- and the facts
                     that follow from it, such as which lane carries
                     which container byte.

Nothing here knows a board. A board's own library says which front end
its jack uses, how it is configured there, and which pins it lands on,
and runs

    python3 -m bayerlink_fpga bayerlink_fpga.frontends.<name> --config ... \
        --out <build dir> ...

which writes the receiver's Verilog to <build dir>/hdl and a Tcl file,
<build dir>/generated/receiver.tcl, that the block design sources: the
files to add, and `bayerlink_frontend <refclk pin>`, which builds the
front end and returns its pins.
"""
from pathlib import Path

HDL = Path(__file__).resolve().parent / "hdl"
