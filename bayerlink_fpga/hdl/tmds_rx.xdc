# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tmds_rx's timing intent, SCOPED to the module (Vivado: SCOPED_TO_REF
# tmds_rx), so its own cell names apply to every instance.
#
# Two things in it are asynchronous by construction, and timing them
# asks for a relationship the design does not rely on:
#
# 1. The clock manager's lock, into the reference clock's synchroniser.
set_false_path -to [get_pins {ml0_reg/D}]
#
# 2. The resets' ASSERTION, into the asynchronous presets of each
#    synchroniser: the reset with no reference clock, and the pixel side's
#    with no pixel clock at all -- an unplug takes it away. Their release
#    is synchronous, through the same flops, and stays timed.
set_false_path -to [get_pins {rr0_reg/PRE rr1_reg/PRE pr0_reg/PRE pr1_reg/PRE}]
#
# Where the receiver's account of the link is read -- its alignment, its
# bond, its survey -- is the design's to constrain: it changes once per
# search, or holds each survey entry for thousands of clocks, and the clock
# that samples it is the design's, not this file's.
