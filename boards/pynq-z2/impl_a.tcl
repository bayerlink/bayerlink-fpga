# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Bitstream in ONE process. launch_runs spawns children through Vivado's
# own wrappers, which shed the LD_PRELOAD that keeps the allocator sane
# in this container -- so no children: global synthesis (no per-IP OOC
# runs), synth/place/route/bitstream all in this Tcl session.
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. ..]]
open_project [file join $here build rx rx.xpr]
set bd [get_files rx.bd]
set_property synth_checkpoint_mode None $bd
generate_target all $bd
update_compile_order -fileset sources_1
# dvi2rgb's EDID ROM reads its .data file RELATIVE at synth time; the
# launch_runs flow would have copied it beside the run. We are the run.
foreach f [glob -nocomplain [file join $root vivado-library ip dvi2rgb src *.data]] {
    file copy -force $f [pwd]
}
synth_design -top rx_wrapper -part xc7z020clg400-1
opt_design
# Explore: the last tens of picoseconds live in the placer's seed.
place_design -directive Explore
# Stop HERE: this process has a long allocation history, and heavy
# commands' teardowns are where the container heap detonates. The
# placed checkpoint hands a fresh process the short half.
file mkdir /tmp/rxout
write_checkpoint -force /tmp/rxout/placed.dcp
file copy -force /tmp/rxout/placed.dcp [file join $here build placed.dcp]
puts "PLACED_DONE"
