# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""bayerlink on FPGAs: the receiver and what any board needs around it.

Two layers, the second reusable by any board:

  the receiver       bayerlink_in (hdl/bayerlink_in.v, sized by
                     receiver.py), the DDC slave that is the receiver's
                     EDID and control port, and the Verilog around them
                     (hdl/): link reset and the capture path's AXIS
                     dressing. Nothing here knows a board.
  frontends/         what turns a cable into parallel video -- pixel
                     clock, data enable, vsync, 24 bits -- and the facts
                     that follow from it, such as which lane carries
                     which container byte.

Nothing here knows a board. A board's own library says which front end
its jack uses, how it is configured there, and which pins it lands on.
Its design names the receiver and the DDC slave as leaves --
bayerlink_fpga.receiver:bayerlink_in and bayerlink_fpga.ddc:ddc_slave --
which its build sets from the design's settings.
"""
from pathlib import Path

HDL = Path(__file__).resolve().parent / "hdl"
