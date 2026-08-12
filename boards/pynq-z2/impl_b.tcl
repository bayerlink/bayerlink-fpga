# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Fresh heap: open the placed checkpoint, route, write the bitstream.
set here [file dirname [file normalize [info script]]]
# Threaded route is the last suspect standing: the crash survives
# allocator swaps and fresh processes, but always follows the one
# heavily threaded command. One thread, one truth.
set_param general.maxThreads 1
open_checkpoint [file join $here build placed.dcp]
route_design
puts "WNS: [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]"
file mkdir /tmp/rxout
write_bitstream -force /tmp/rxout/rx.bit
file mkdir [file join $here out]
file copy -force /tmp/rxout/rx.bit [file join $here out rx.bit]
file copy -force [glob [file join $here build rx *.gen sources_1 bd rx hw_handoff rx.hwh]] \
    [file join $here out rx.hwh]
puts "BITSTREAM_DONE"
