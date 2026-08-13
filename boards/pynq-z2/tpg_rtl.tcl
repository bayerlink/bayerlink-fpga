# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. ..]]
create_project -in_memory -part xc7z020clg400-1
foreach f [glob [file join $root vivado-library ip rgb2dvi src *.vhd]] {
    read_vhdl $f
}
read_verilog [file join $root hdl fabric_tpg.v]
read_verilog [file join $here tpg_top.v]
read_xdc [file join $here tpg_rtl.xdc]
synth_design -top tpg_top -part xc7z020clg400-1
opt_design
place_design
route_design
puts "WNS: [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]"
file mkdir /tmp/rxout
write_bitstream -force /tmp/rxout/tpg.bit
puts "BITSTREAM_DONE"
