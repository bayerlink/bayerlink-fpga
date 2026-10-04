# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Front ends: what turns a cable into the receiver's parallel video.

hdmi_rx.json describes the block -- TMDS in; pixel clock, lock, data
enable, syncs and 24 data bits out -- and its implementations, each from
a vendor or of our own, each stating what follows from it: which video
lane carries which container byte, the frame pulse's polarity, the
reference clock it calibrates with. Every implementation offers the
block's ports, so the receiver and the designs above it do not change
when it does.

How a front end is configured on a particular board, and which pins it
lands on, is that board's: a board's jack names the block,
bayerlink_fpga.frontends.hdmi_rx, chooses its implementation and passes
its configuration.
"""
