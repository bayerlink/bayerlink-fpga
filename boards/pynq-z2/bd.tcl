# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# The receive-proof bitstream: dvi2rgb front end, two capture paths.
# Batch: vivado -mode batch -source build.tcl (from /work in the container)
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. ..]]
set_param board.repoPaths [file join $root board-files]
create_project rx [file join $here build rx] -part xc7z020clg400-1 -force
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]
set_property ip_repo_paths [file join $root vivado-library] [current_project]
update_ip_catalog

add_files [file join $root hdl generated scanout.v] \
    [file join $root hdl generated fbread.v] [file join $root hdl link_reset.v] [file join $root hdl stream_switch.v] [file join $root hdl axis_unpack.v] \
    [file join $root hdl isp_axis.v] [file join $root hdl generated revela_isp.v] \
    [file join $root hdl generated bayerlink_rx.v] \
    [file join $root hdl rx_axis.v] [file join $root hdl vid_probe.v] \
    [file join $root hdl axis_spy.v]
add_files -fileset constrs_1 [file join $here pynq-z2.xdc]

create_bd_design rx

# --- PS, with the board preset; HP0 for both DMAs; 200 MHz for IDELAYCTRL
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1"} $ps
set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP1 {1} \
    CONFIG.PCW_EN_CLK1_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {142.857143} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1}] $ps
# FCLK0 (every AXI clock here) at 142.86, not 100: a 1080p60 scanout
# READS 497 MB/s sustained, and a 64-bit HP port at 100 MHz peaks at
# 800 -- close enough to the edge that the raster starves and the
# display path spends its life re-hunting the frame start. The PS can
# make 1000/7; it cannot make 150.

# --- TMDS decode
set dvi [create_bd_cell -type ip -vlnv digilentinc.com:ip:dvi2rgb dvi_rx]
# kClkRange 1: the board's own base overlay runs this exact 74.25 MHz
# mode with range 1 -- the IP comment's bucket arithmetic says 2, and
# empirically range 2 locks the clock but never aligns the data. Trust
# the design that demonstrably receives.
set_property -dict [list CONFIG.kClkRange {1} CONFIG.kEdidFileName {dgl_720p_cea.data} \
    CONFIG.kAddBUFG {true}] $dvi
make_bd_intf_pins_external [get_bd_intf_pins dvi_rx/TMDS]
set_property name TMDS [get_bd_intf_ports TMDS_0]
make_bd_intf_pins_external [get_bd_intf_pins dvi_rx/DDC]
set_property name ddc [get_bd_intf_ports DDC_0]
connect_bd_net [get_bd_pins ps7/FCLK_CLK1] [get_bd_pins dvi_rx/RefClk]

# HPD high: the Pi must see a sink.
set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant hpd_one]
create_bd_port -dir O hdmi_hpd
connect_bd_net [get_bd_pins hpd_one/dout] [get_bd_ports hdmi_hpd]

# dvi2rgb wants a reset; not held in reset when locked
set rstinv [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant rst_lo]
set_property CONFIG.CONST_VAL {0} $rstinv
connect_bd_net [get_bd_pins rst_lo/dout] [get_bd_pins dvi_rx/aRst]

# --- the framebuffer writer: the ISP's output lands here
set vdma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma vdma]
set_property -dict [list CONFIG.c_include_mm2s {0} CONFIG.c_include_s2mm {1} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_s2mm_linebuffer_depth {2048}] $vdma

# --- R2 path: the unpacked line stream to DDR
#
# The sample width. The receiver ALIGNS every source depth to the depth
# this build was made for, so one number describes the whole datapath
# from its output to the ISP's input, and the glue is parameterised on
# it rather than assuming a 16-bit lane. build.sh owns it and exports
# it; the default matches build.sh's, so a hand-run of this script
# produces the same design.
set sample_bits [expr {[info exists ::env(BITS)] ? $::env(BITS) : 10}]

# BUILD-TIME, like the sample width, and the second of its kind here.
# The CAPTURE branch writes received frames to DDR so the ARM can judge
# them against what the camera sent -- the tap that proved this link
# bit-exact. It costs a DMA, a clock converter, an interconnect port
# and the switch that exists only because there are two consumers, so a
# build that is not being brought up should be able to leave it out.
# Whether the board CAN is board business (it needs the PS and an HP
# port); whether this build DOES is build.sh's. build.sh resolves the
# two and exports the answer.
set capture [expr {[info exists ::env(CAPTURE)] ? $::env(CAPTURE) : 1}]
# WHICH read engine feeds the display. 0 is the VDMA, which works and has
# always worked; 1 is fbread, which is right in simulation and does not
# yet fetch a byte on this board. The default is the one that puts a
# picture on a screen. A new engine does not get to be the only engine
# until it has been one that works.
set fbread_en [expr {[info exists ::env(FBREAD)] ? $::env(FBREAD) : 0}]
# BAKED or LIVE coefficients. 0 bakes them into the wrapper, which is
# the demo that has a picture behind it; 1 brings up np2hw's AXI4-Lite
# register file, whose writes land in a shadow and commit at a frame
# boundary. The ISP's ports differ between the two, so the bitstream and
# gen/isp.py --control must agree -- build.sh passes the same flag to
# both.
set control_en [expr {[info exists ::env(CONTROL)] ? $::env(CONTROL) : 0}]
puts "bd.tcl: display reader = [expr {$fbread_en ? {fbread} : {vdma}}], coefficients = [expr {$control_en ? {live} : {baked}}]"
puts "bd.tcl: sample width $sample_bits bits, capture path $capture"
set rx [create_bd_cell -type module -reference bayerlink_rx blrx]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins blrx/clk]
foreach {a b} {vid_pData vid_data vid_pVDE vid_de vid_pVSync vid_vsync} {
    connect_bd_net [get_bd_pins dvi_rx/$a] [get_bd_pins blrx/$b]
}
# One stream, two consumers, a register deciding which: the judge's
# byte-exact capture, or the ISP. The unselected side sees silence.
# With capture, one stream has two consumers and a register picks; the
# ISP then reads the switch's B side. Without it there is one consumer,
# so there is no switch, no select bit, and the ISP reads the receiver.
# `isp_src` is whichever of the two the ISP branch is wired from.
if {$capture} {
    set sw [create_bd_cell -type module -reference stream_switch sw]
    set_property CONFIG.SAMPLE_BITS $sample_bits $sw
    foreach s {valid ready data sof eol last} {
        connect_bd_net [get_bd_pins blrx/out_$s] [get_bd_pins sw/in_$s]
    }
    set shim [create_bd_cell -type module -reference rx_axis shim]
    set_property CONFIG.SAMPLE_BITS $sample_bits $shim
    connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins shim/clk]
    foreach s {valid ready data sof eol last} {
        connect_bd_net [get_bd_pins sw/a_$s] [get_bd_pins shim/in_$s]
    }
    set isp_src {sw/b}
} else {
    set isp_src {blrx/out}
}
set cw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_out]
# No_buffer: FCLK arrives from the PS already buffered; the default
# expects a package PIN and builds an input path to nowhere -- an MMCM
# that never sees an edge, and a perfectly silent dead clock.
# Fed from FCLK1 (200 MHz), not FCLK0: the AXI clock moved to 1000/7
# for scanout bandwidth, and 142.86 cannot synthesize an exact 148.5
# (the nearest fractional divide lands 0.24% low). 200 x 3.7125 =
# 742.5 VCO, /5 = 148.5 exactly -- the same VCO the 74.25 recipe used.
set_property -dict [list CONFIG.PRIM_IN_FREQ {200.000} \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {148.500} \
    CONFIG.USE_LOCKED {true} CONFIG.USE_RESET {false}] $cw
connect_bd_net [get_bd_pins ps7/FCLK_CLK1] [get_bd_pins clk_out/clk_in1]

# --- the ISP branch, an island on the BOARD'S OWN clock.
#
# This island existed once, retired when np2hw closed timing on the
# receiver's clock, and is back for a reason that has nothing to do
# with timing: the receiver's clock is recovered from the cable, so it
# STOPS -- on unplug, and in the moments after the fabric is
# reprogrammed. Everything that lived on it inherited that: an AXI
# slave there hung the processor (power cycle, 2026-08-17), the
# register file fled to the PS clock, and every coefficient became a
# clock crossing with constraints in both directions.
#
# clk_out1 is 148.5MHz from FCLK_CLK1 -- no cable anywhere in its
# ancestry -- and the scanout already runs on it. With the ISP and its
# register file BOTH there, the coefficient crossing does not need
# constraining, arming, or explaining: it is gone. One stream crossing
# remains, in the converter below, proven vendor IP doing the one job.
#
# The pieces are the ORIGINAL island's: rx_axis dresses the elastic
# stream as AXIS, the converter crosses, axis_unpack undresses it.
# One layout, owned by rx_axis, both directions.
set iin [create_bd_cell -type module -reference rx_axis isp_in_shim]
set_property CONFIG.SAMPLE_BITS $sample_bits $iin
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins isp_in_shim/clk]
foreach s {valid ready data sof eol last} {
    connect_bd_net [get_bd_pins ${isp_src}_$s] [get_bd_pins isp_in_shim/in_$s]
}
set icdc [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter isp_cdc]
connect_bd_intf_net [get_bd_intf_pins isp_in_shim/m_axis] [get_bd_intf_pins isp_cdc/S_AXIS]
connect_bd_net [get_bd_pins dvi_rx/PixelClk]  [get_bd_pins isp_cdc/s_axis_aclk]
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins isp_cdc/m_axis_aclk]
set iun [create_bd_cell -type module -reference axis_unpack isp_unpack]
set_property CONFIG.SAMPLE_BITS $sample_bits $iun
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins isp_unpack/clk]
connect_bd_intf_net [get_bd_intf_pins isp_cdc/M_AXIS] [get_bd_intf_pins isp_unpack/s_axis]
set isp [create_bd_cell -type module -reference revela_isp isp]
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins isp/clk]
# The stream's own facts drive the pipeline context: header to ctx,
# one owner end to end. This is now a REAL clock crossing -- pixel
# domain to the island -- and it is safe for the same reason it always
# was: the values change at header-accept, a full line before the
# payload, and the wrapper latches them at each frame's SOF, by which
# time they have been still for thousands of cycles. The XDC says so.
foreach f {width height phase bits} {
    connect_bd_net [get_bd_pins blrx/hdr_$f] [get_bd_pins isp/hdr_$f]
}
foreach s {valid ready data sof eol last} {
    connect_bd_net [get_bd_pins isp_unpack/out_$s] [get_bd_pins isp/in_$s]
}
set iax [create_bd_cell -type module -reference isp_axis isp_out]
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins isp_out/clk]
foreach s {valid ready data sof eol last} {
    connect_bd_net [get_bd_pins isp/out_$s] [get_bd_pins isp_out/in_$s]
}
connect_bd_intf_net [get_bd_intf_pins isp_out/m_axis] [get_bd_intf_pins vdma/S_AXIS_S2MM]
if {$capture} {
set cdc [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter cdc]
connect_bd_intf_net [get_bd_intf_pins shim/m_axis] [get_bd_intf_pins cdc/S_AXIS]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins cdc/s_axis_aclk]

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma]
# 32-bit words: the v2 receiver's samples are 16-bit unshifted, plus
# sof/eol above them (rx_axis owns the layout).
set_property -dict [list CONFIG.c_include_mm2s {0} CONFIG.c_include_sg {0} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} CONFIG.c_sg_length_width {26}] $dma
set spy [create_bd_cell -type module -reference axis_spy spy_cdc]
set_property -dict [list CONFIG.DW {32}] $spy
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins spy_cdc/clk]
connect_bd_intf_net [get_bd_intf_pins cdc/M_AXIS] [get_bd_intf_pins spy_cdc/s_axis]
connect_bd_intf_net [get_bd_intf_pins spy_cdc/m_axis] [get_bd_intf_pins dma/S_AXIS_S2MM]
}

# --- display side: 1080p60 out -- the TV's best is the target, and
# the sensor is configured to serve it. Pixel clock is OURS (static
# 148.5 from FCLK0); rgb2dvi makes its own 5x serial clock (MMCM:
# 742.5 sits inside the MMCM VCO window; a PLL's floor is above it).
# clk_out (the board's own 148.5) is created up with the receiver now:
# the ISP island uses it before the display side does.

# No v_tc, no v_axi4s_vid_out: that pair's lock was never witnessed
# here across every mode it offers. The raster is GENERATED -- np2hw's
# scanout, emitted from the one raster table, arriving with the claims
# this bench paid for: a frame may be dropped but never displaced, a
# window that does not fit is refused rather than clipped, and pixel
# and enable leave on the same clock. Placement is baked by
# gen/scanout.py until the register file lands.
set tx [create_bd_cell -type ip -vlnv digilentinc.com:ip:rgb2dvi hdmi_tx]
# kClkRange 1: the >=120 MHz bucket (MULT_F = range*5, so 148.5 * 5
# = 742.5 VCO, serial clock 742.5 -> 1.485 Gb/s per TMDS pair).
set_property -dict [list CONFIG.kGenerateSerialClk {true} \
    CONFIG.kClkPrimitive {MMCM} CONFIG.kClkRange {1} \
    CONFIG.kRstActiveHigh {true}] $tx
set vp [create_bd_cell -type module -reference scanout_top scanout]
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins scanout/clk]
connect_bd_net [get_bd_pins clk_out/locked] [get_bd_pins scanout/locked]
connect_bd_intf_net [get_bd_intf_pins scanout/vid_io] [get_bd_intf_pins hdmi_tx/RGB]
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins hdmi_tx/PixelClk]
make_bd_intf_pins_external [get_bd_intf_pins hdmi_tx/TMDS]
set_property name hdmi_tx [get_bd_intf_ports TMDS_0]

# VDMA grows its read side: the framebuffer out.
# The read stream lives on the PIXEL clock: scanout pops at raster
# pace with no elastic in between beyond the vdma's own line buffer.
# The stream stays 32-bit (the core refuses 24): xRGB pixels, and
# scanout takes the low three bytes of each beat.
# FREE-RUN, explicitly: propagation once slipped in use_fsync=1 and
# genlock-slave -- a scheduler waiting forever on a sync and a frame
# pointer that nothing drives. Running-while-starving, no error bit.
# The VDMA keeps the WRITE side and loses the read side. Its read side
# fetched the frame back perfectly well while making one thing
# impossible: knowing when its first beat arrived relative to the
# raster's first pixel. That offset landed somewhere new on every lock
# -- 0, 16, 48 and 80 were all measured here from reloads of an
# unchanged bitstream -- and `--skew` corrected it by hand. Survivable
# while a person reloaded anyway; not survivable once the link recovers
# by itself, because every replug re-locks and re-rolls it.
if {$fbread_en} {
    set_property -dict [list CONFIG.c_include_mm2s {0} \
        CONFIG.c_use_fsync {0} \
        CONFIG.c_s2mm_genlock_mode {0}] $vdma
} else {
    set_property -dict [list CONFIG.c_include_mm2s {1} \
        CONFIG.c_mm2s_linebuffer_depth {4096} \
        CONFIG.c_use_fsync {0} \
        CONFIG.c_mm2s_genlock_mode {0} \
        CONFIG.c_s2mm_genlock_mode {0}] $vdma
    connect_bd_intf_net [get_bd_intf_pins vdma/M_AXIS_MM2S] \
        [get_bd_intf_pins scanout/s_axis]
    connect_bd_net [get_bd_pins clk_out/clk_out1] \
        [get_bd_pins vdma/m_axis_mm2s_aclk]
}

if {$fbread_en} {
# fbread owns its addressing, so its first beat IS the frame's first
# pixel and it says so on tuser. Nothing to measure, nothing to correct.
# It runs on the DISPLAY's clock, beside the raster it feeds, and its
# geometry is the display's -- fixed by the mode. Only the base address
# is run-time, because only Linux knows where it put the buffer.
set fbr [create_bd_cell -type module -reference fbread fbread]
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins fbread/clk]
connect_bd_intf_net [get_bd_intf_pins fbread/m_axis] [get_bd_intf_pins scanout/s_axis]

set fbgeom [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant fb_lbeats]
set_property -dict [list CONFIG.CONST_WIDTH {16} \
    CONFIG.CONST_VAL {1920}] $fbgeom
connect_bd_net [get_bd_pins fb_lbeats/dout] [get_bd_pins fbread/line_beats]
set fblines [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant fb_lines]
set_property -dict [list CONFIG.CONST_WIDTH {16} \
    CONFIG.CONST_VAL {1080}] $fblines
connect_bd_net [get_bd_pins fb_lines/dout] [get_bd_pins fbread/lines]
set fbstride [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant fb_stride]
set_property -dict [list CONFIG.CONST_WIDTH {32} \
    CONFIG.CONST_VAL {7680}] $fbstride
connect_bd_net [get_bd_pins fb_stride/dout] [get_bd_pins fbread/stride_bytes]
}

# --- interrupts: the pynq drivers refuse to exist without them
set irqcat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_cat]
connect_bd_net [get_bd_pins vdma/s2mm_introut] [get_bd_pins irq_cat/In0]
if {$capture} {
    connect_bd_net [get_bd_pins dma/s2mm_introut] [get_bd_pins irq_cat/In1]
} else {
    # Same vector shape either way, so the driver's view does not move.
    set irq0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant irq_tie]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $irq0
    connect_bd_net [get_bd_pins irq_tie/dout] [get_bd_pins irq_cat/In1]
}
connect_bd_net [get_bd_pins irq_cat/dout] [get_bd_pins ps7/IRQ_F2P]

# --- software reset for the receiver: a sticky overflow needs a broom
set ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio ctrl_gpio]
# Channel 2 carries the framebuffer's base address. Only Linux knows
# where it allocated the buffer, so that one number has to come from
# software; everything else about the fetch is the display's geometry
# and is fixed at build. `enable` follows from the address being set, so
# there is no separate go bit to forget.
set_property -dict [list CONFIG.C_GPIO_WIDTH {3} CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_ALL_OUTPUTS_2 {1}] $ctrl
# Bit 0 is the broom, bit 1 selects the stream's consumer (judge/ISP).
set brm [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice broom]
set_property -dict [list CONFIG.DIN_WIDTH {3} CONFIG.DIN_FROM {0} \
    CONFIG.DIN_TO {0}] $brm
connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins broom/Din]
if {$fbread_en} {
connect_bd_net [get_bd_pins ctrl_gpio/gpio2_io_o] [get_bd_pins fbread/base_addr]
# Bit 2 enables the fetch, and is written AFTER the address. Derived
# from the address instead, it would rise while those 32 bits were
# still crossing into the display clock -- half the old address, half
# the new, and an engine pointed at neither. Write, then enable, is
# the handshake; fbread synchronises this bit on its side.
set fbsel [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice fb_en]
set_property -dict [list CONFIG.DIN_WIDTH {3} CONFIG.DIN_FROM {2} \
    CONFIG.DIN_TO {2}] $fbsel
connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins fb_en/Din]
connect_bd_net [get_bd_pins fb_en/Dout] [get_bd_pins fbread/enable]
}

# The pixel domain's reset comes from the LINK, not from a person.
# That domain runs on the clock recovered from the cable, so an unplug
# stops it: FIFOs freeze half full, the ISP mid-line, the writer mid
# frame. Nothing in there can notice, which is why a replug used to
# need a register poke. The supervisor runs on FCLK0, which cannot
# stop, asserts asynchronously so it lands with no pixel clock at all,
# and releases synchronously so the domain leaves reset on an edge.
# Power-up needs no special case: no lock, so the domain is held until
# a source appears. The broom still overrides, for a stuck sticky bit.
set lrst [create_bd_cell -type module -reference link_reset link_rst]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins link_rst/stable_clk]
connect_bd_net [get_bd_pins dvi_rx/PixelClk]    [get_bd_pins link_rst/pix_clk]
connect_bd_net [get_bd_pins dvi_rx/aPixelClkLckd] [get_bd_pins link_rst/locked_a]
connect_bd_net [get_bd_pins broom/Dout]         [get_bd_pins link_rst/soft_rst]
# Bit 1 chooses the stream's consumer, which is only a choice when
# there are two of them. Without capture the ISP is the only consumer
# and the bit means nothing, so the slice is not built; bit 0, the
# broom, is unaffected and keeps its meaning either way.
if {$capture} {
    set msel [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice isp_sel]
    set_property -dict [list CONFIG.DIN_WIDTH {3} CONFIG.DIN_FROM {1} \
        CONFIG.DIN_TO {1}] $msel
    connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins isp_sel/Din]
    connect_bd_net [get_bd_pins isp_sel/Dout] [get_bd_pins sw/sel]
}
# The island still FOLLOWS the link -- a half-frame left in the pipe
# by an unplug is cleared the same way as before -- but through a
# reset of its own, because rst_pix deasserts synchronously to a clock
# the island does not use. proc_sys_reset re-synchronises the release
# to clk_out1, and holds until the MMCM locks, which is what makes
# power-up need no special case. Instantiated HERE, explicitly, with
# an input whose state software can read (link_up in hdr_gpio) -- not
# left to the automation, whose hidden resets cost three builds once.
#
# The register file is deliberately NOT in this reset: it rides
# s_axil_aresetn, so coefficients survive a cable pull, and the
# datapath reloads its copies the moment its own reset releases.
set irst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_isp]
connect_bd_net [get_bd_pins clk_out/clk_out1]  [get_bd_pins rst_isp/slowest_sync_clk]
connect_bd_net [get_bd_pins link_rst/rst_pix]  [get_bd_pins rst_isp/ext_reset_in]
connect_bd_net [get_bd_pins clk_out/locked]    [get_bd_pins rst_isp/dcm_locked]
foreach cell {isp isp_out isp_unpack} {
    connect_bd_net [get_bd_pins rst_isp/peripheral_reset] [get_bd_pins $cell/rst]
}
connect_bd_net [get_bd_pins rst_isp/peripheral_aresetn] \
    [get_bd_pins isp_cdc/m_axis_aresetn]
# The converter's pixel side follows the link directly, like the shim
# feeding it: both are IN the pixel domain, where rst_pix is the law.
set rlk [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic rstn_link]
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] $rlk
connect_bd_net [get_bd_pins link_rst/rst_pix] [get_bd_pins rstn_link/Op1]
connect_bd_net [get_bd_pins rstn_link/Res]    [get_bd_pins isp_cdc/s_axis_aresetn]
connect_bd_net [get_bd_pins link_rst/rst_pix] [get_bd_pins isp_in_shim/rst]
connect_bd_net [get_bd_pins link_rst/rst_pix] [get_bd_pins blrx/rst]
# The tallies clear on a deliberate ask, not on every cable drop: rst
# now arrives from the LINK, and a counter reset by the event it counts
# tells you nothing. The broom is a person saying "start again".
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins blrx/diag_clear]
if {$capture} {
    catch {connect_bd_net [get_bd_pins link_rst/rst_pix] [get_bd_pins shim/rst]}
}

# --- status: lock + overflow + the probe's testimony
set probe [create_bd_cell -type module -reference vid_probe probe]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins probe/clk]
connect_bd_net [get_bd_pins link_rst/rst_pix] [get_bd_pins probe/rst]
connect_bd_net [get_bd_pins dvi_rx/vid_pVDE] [get_bd_pins probe/de]
connect_bd_net [get_bd_pins dvi_rx/vid_pVSync] [get_bd_pins probe/vsync]
connect_bd_net [get_bd_pins dvi_rx/vid_pData] [get_bd_pins probe/data]
connect_bd_net [get_bd_pins blrx/out_valid] [get_bd_pins probe/rx_valid]

set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio status_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {30} CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_INPUTS_2 {1}] $gpio
if {$capture} {
    connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins spy_cdc/rst]
}
set cat2 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat status2_cat]
set_property CONFIG.NUM_PORTS {3} $cat2
if {$capture} {
    connect_bd_net [get_bd_pins spy_cdc/status] [get_bd_pins status2_cat/In0]
} else {
    # The spy's 16 status bits read zero rather than moving every other
    # field in the word: a host reading this register keeps its offsets.
    set spy0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant spy_tie]
    set_property -dict [list CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {0}] $spy0
    connect_bd_net [get_bd_pins spy_tie/dout] [get_bd_pins status2_cat/In0]
}
connect_bd_net [get_bd_pins clk_out/locked] [get_bd_pins status2_cat/In1]
connect_bd_net [get_bd_pins scanout/status] [get_bd_pins status2_cat/In2]
connect_bd_net [get_bd_pins status2_cat/dout] [get_bd_pins status_gpio/gpio2_io_i]
# The v2 receiver's verdicts and header facts, packed for one read:
# {hdr_phase[1:0], hdr_valid, hdr_bits[4:0], refuse_code[2:0], refused}
set hcat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat hdr_cat]
set_property CONFIG.NUM_PORTS {5} $hcat
connect_bd_net [get_bd_pins blrx/refused] [get_bd_pins hdr_cat/In0]
connect_bd_net [get_bd_pins blrx/refuse_code] [get_bd_pins hdr_cat/In1]
connect_bd_net [get_bd_pins blrx/hdr_bits] [get_bd_pins hdr_cat/In2]
connect_bd_net [get_bd_pins blrx/hdr_valid] [get_bd_pins hdr_cat/In3]
connect_bd_net [get_bd_pins blrx/hdr_phase] [get_bd_pins hdr_cat/In4]
# The island must say WHY it is idle. Held in reset, starved by the
# converter, refusing input and producing nothing all look identical
# from software -- no data, no error -- and telling those apart by
# guesswork cost a day once (#20). Six levels, sampled raw across the
# clock boundary: these are read as LEVELS for stuck-at diagnosis, not
# as events, so the crossing needs no synchroniser to be useful.
#   bit2 island reset held    bit3 stream reaching the ISP
#   bit4 ISP accepting        bit5 ISP producing
#   bit6 pixel side offering  bit7 pixel side accepted
# These taps join EXISTING nets, so every one uses the -net form; the
# plain form errors on a pin that is already connected.
set islcat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat isl_cat]
set_property CONFIG.NUM_PORTS {7} $islcat
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rst_isp/peripheral_reset]] \
    [get_bd_pins isl_cat/In0]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins isp/in_valid]] \
    [get_bd_pins isl_cat/In1]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins isp/in_ready]] \
    [get_bd_pins isl_cat/In2]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins isp/out_valid]] \
    [get_bd_pins isl_cat/In3]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins isp_in_shim/in_valid]] \
    [get_bd_pins isl_cat/In4]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins isp_in_shim/in_ready]] \
    [get_bd_pins isl_cat/In5]
# Pad to the 16 bits the probe used to occupy, so the header facts
# stay at bit 18 and every host script keeps its offsets.
set islpad [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant isl_pad]
set_property -dict [list CONFIG.CONST_WIDTH {10} CONFIG.CONST_VAL {0}] $islpad
connect_bd_net [get_bd_pins isl_pad/dout] [get_bd_pins isl_cat/In6]

set cat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat status_cat]
set_property CONFIG.NUM_PORTS {4} $cat
connect_bd_net [get_bd_pins dvi_rx/aPixelClkLckd] [get_bd_pins status_cat/In0]
connect_bd_net [get_bd_pins blrx/overflow] [get_bd_pins status_cat/In1]
connect_bd_net [get_bd_pins isl_cat/dout] [get_bd_pins status_cat/In2]
connect_bd_net [get_bd_pins hdr_cat/dout] [get_bd_pins status_cat/In3]

# --- WHICH frame, and WHICH camera. Both status words are full to the
# bit, and these do not belong crammed into a spare corner anyway: they
# are the stream's identity. Software reads them to recognise a source
# and load ITS calibration, and to tell a frame the link LOST from one
# the camera never sent.
#
# OBSERVABILITY, not correlation. This reports the LAST ACCEPTED
# header -- the frame ENTERING the pipeline. By the time a frame's
# statistics are ready the next header has landed and this has moved
# on, so statistics must carry their OWN frame id, latched with the
# accumulators in one snapshot. Reading this beside a separate stats
# register is a race with a one-frame error, which is what makes an
# exposure loop oscillate.
set hgpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio hdr_gpio]
# Channel 2 is exactly as wide as the facts it carries -- 8 + 8 + 1 + 8.
# A wider channel would leave its top bits unconnected, which Vivado
# reports and which reads back as whatever the fabric felt like.
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_ALL_INPUTS_2 {1}] $hgpio
connect_bd_net [get_bd_pins blrx/hdr_frame_seq] [get_bd_pins hdr_gpio/gpio_io_i]
# Channel 2 is the stream's identity plus the link's own testimony:
# {fb_slverr, fb_underflow, loss_count[7:0], link_up,
#  resync_count[7:0], source_id[7:0]}.
# A host polls this one word and knows what is connected, whether the
# cable has dropped since it last looked, and whether the stream
# restarted -- all as COUNTS, so a poll that misses an event still
# sees that it happened.
set icat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat ident_cat]
set_property CONFIG.NUM_PORTS {7} $icat
connect_bd_net [get_bd_pins blrx/hdr_source_id]  [get_bd_pins ident_cat/In0]
connect_bd_net [get_bd_pins blrx/resync_count]   [get_bd_pins ident_cat/In1]
connect_bd_net [get_bd_pins link_rst/link_up]    [get_bd_pins ident_cat/In2]
connect_bd_net [get_bd_pins link_rst/loss_count] [get_bd_pins ident_cat/In3]
if {$fbread_en} {
    connect_bd_net [get_bd_pins fbread/underflow] [get_bd_pins ident_cat/In4]
    connect_bd_net [get_bd_pins fbread/slverr]    [get_bd_pins ident_cat/In5]
} else {
    set fbz [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant fb_absent]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $fbz
    connect_bd_net [get_bd_pins fb_absent/dout] [get_bd_pins ident_cat/In4]
    connect_bd_net [get_bd_pins fb_absent/dout] [get_bd_pins ident_cat/In5]
}
# WHY it is idle, if it is. Held in reset, never enabled, and asking a
# bus that never answers are three different faults that look the same
# from outside: no data and no error. Three builds went on telling them
# apart by guessing.
if {$fbread_en} {
    connect_bd_net [get_bd_pins fbread/dbg] [get_bd_pins ident_cat/In6]
} else {
    set fbz8 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant fb_dbg0]
    set_property -dict [list CONFIG.CONST_WIDTH {8} CONFIG.CONST_VAL {0}] $fbz8
    connect_bd_net [get_bd_pins fb_dbg0/dout] [get_bd_pins ident_cat/In6]
}
connect_bd_net [get_bd_pins ident_cat/dout] [get_bd_pins hdr_gpio/gpio2_io_i]
connect_bd_net [get_bd_pins status_cat/dout] [get_bd_pins status_gpio/gpio_io_i]

# --- automation for AXI plumbing, resets, address map
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} intc_ip {New AXI Interconnect}} \
    [get_bd_intf_pins vdma/S_AXI_LITE]
if {$capture} {
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} intc_ip {New AXI Interconnect}} \
    [get_bd_intf_pins dma/S_AXI_LITE]
}
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} intc_ip {New AXI Interconnect}} \
    [get_bd_intf_pins status_gpio/S_AXI]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} intc_ip {New AXI Interconnect}} \
    [get_bd_intf_pins hdr_gpio/S_AXI]
if {$control_en} {
    # Every coefficient behind one slave, ON THE PROCESSOR'S CLOCK.
    #
    # It rode the PIXEL clock once. That clock is recovered from the
    # HDMI link and stops with it, including in the moments just after
    # this bitstream is loaded -- and AXI has no timeout, so a slave
    # with no clock never answers and the processor waits for it
    # forever. The board hung on 2026-08-17 and needed the power pulled.
    #
    # Clk_slave is NAMED rather than left to Auto. Auto picked the pixel
    # clock, correctly, because the wrapper's interface association said
    # that is where the port lived; the fix is in the wrapper, and this
    # says the same thing out loud so the two cannot drift apart.
    # Master and slave on one clock also means no clock converter.
    # ...and on the ISLAND's clock, which is the whole point: the
    # register file and the datapath that reads it share a domain, so
    # the coefficient crossing that needed an arm for safety and false
    # paths in both directions simply does not exist. clk_out1 never
    # stops -- FCLK_CLK1 through an MMCM, no cable in its ancestry --
    # so the lesson of 2026-08-17 (a slave must answer) still holds.
    # The automation drops in the one AXI clock converter the PS needs.
    connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins isp/s_axi_aclk]
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
        {Clk_master {/ps7/FCLK_CLK0} Clk_slave {/clk_out/clk_out1} Clk_xbar {/ps7/FCLK_CLK0} Master {/ps7/M_AXI_GP0} intc_ip {New AXI Interconnect}} \
        [get_bd_intf_pins isp/s_axi]
}
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} intc_ip {New AXI Interconnect}} \
    [get_bd_intf_pins ctrl_gpio/S_AXI]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/vdma/M_AXI_S2MM} \
     Slave {/ps7/S_AXI_HP0} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
    [get_bd_intf_pins ps7/S_AXI_HP0]
# NOT automation: its second pass built the dma a private interconnect
# whose master port went to __NOC__ -- nowhere -- and called it a
# warning. The capture engines share this interconnect, explicitly.
# The scanout read does NOT: 1080p60 is 594 MB/s sustained, and one
# 800 MB/s HP port carrying that plus the ISP's write loses on plain
# arithmetic. The read side gets a port of its own (HP1, below).
# Two masters write DDR when capture is in: the framebuffer and the
# capture DMA. Without it the framebuffer is alone and the second
# slave port is not created at all.
if {$capture} {
    set_property CONFIG.NUM_SI {2} [get_bd_cells axi_mem_intercon]
}
# HP1 now carries fbread instead of the VDMA's read side. Same traffic,
# same port, same reason for it having a port of its own -- only the
# master changed, and with it the guarantee about WHEN its first beat
# lands. It runs on the display clock, so the crossing into the PS
# happens in this interconnect rather than inside a vendor core where
# it could not be reasoned about.
# Whichever reader is in use takes HP1. Written out TWICE rather than
# substituting the master into one call: Tcl does not substitute inside
# braces, and the quoted form that would is not the list this option
# wants. Two literal calls have neither problem.
if {$fbread_en} {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
        {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/fbread/m_axi} \
         Slave {/ps7/S_AXI_HP1} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
        [get_bd_intf_pins ps7/S_AXI_HP1]
} else {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
        {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/vdma/M_AXI_MM2S} \
         Slave {/ps7/S_AXI_HP1} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
        [get_bd_intf_pins ps7/S_AXI_HP1]
}

# The automation's reset generator for this clock has the MMCM's lock on
# dcm_locked already -- checked in the .xci, not assumed. Its
# ext_reset_in and aux_reset_in are left unconnected, which the block
# design ties to 0, and whether 0 means "reset" depends on a polarity
# nobody stated. State it: with both ACTIVE_HIGH, a tied-off 0 is
# unambiguously "not asserted", and this generator releases after its
# power-on sequence instead of possibly never.
if {$fbread_en} {
    # This reset generator only exists when fbread is the master: the
    # automation makes one for the display clock domain, and with the
    # VDMA driving HP1 there is no such domain to make it for.
    set_property -dict [list CONFIG.C_EXT_RST_ACTIVE_HIGH {1} \
        CONFIG.C_AUX_RST_ACTIVE_HIGH {1}] [get_bd_cells rst_clk_out_148M]
}
if {$capture} {
connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_S2MM] \
    [get_bd_intf_pins axi_mem_intercon/S01_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi_mem_intercon/S01_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins dma/m_axi_s2mm_aclk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_mem_intercon/S00_ARESETN]] \
    [get_bd_pins axi_mem_intercon/S01_ARESETN]
}
# Stream-side clocks the automation does not own: everything AXI in
# this design lives on FCLK0, so the crossings are exactly the two
# declared ones (TMDS pixel clock in, FCLK0 out).
# The write side follows the ISP onto the island: producer and
# consumer on one clock, no converter, and a clock that keeps running
# through an unplug -- the engine can now finish or fault a frame
# instead of freezing mid-word when the cable goes.
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins vdma/s_axis_s2mm_aclk]
# `cdc` belongs to the capture branch, so this belongs inside the same
# guard. Left outside it, CAPTURE=0 -- a configuration this repo
# documents and build.sh offers -- failed to build at all.
if {$capture} {
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins cdc/m_axis_aclk]
}

# RESETS the automation does not own. A floating aresetn is a HELD
# reset -- the clock converter and video-in have sat in reset through
# every test so far. AXI-side resetns join the net the automation
# gives the DMA; the converter's pixel-side resetn is the software
# reset, inverted, so one broom sweeps the whole receive path.
set inv [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic rstn_pix]
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] $inv
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins rstn_pix/Op1]
# An async-FIFO crossing initializes only when BOTH sides reset while
# BOTH clocks run. At boot the pixel clock does not exist, so boot-time
# resets can never do it. The RECEIVE path no longer depends on anyone
# noticing: link_rst holds it until lock settles, which is by
# definition a moment when both clocks run. This converter belongs to
# the capture branch and keeps the broom, which is honest -- it is a
# bring-up path, and it is brought up by hand.
if {$capture} {
    connect_bd_net [get_bd_pins rstn_pix/Res] [get_bd_pins cdc/s_axis_aresetn]
    connect_bd_net [get_bd_pins rstn_pix/Res] [get_bd_pins cdc/m_axis_aresetn]
}
# The display deliberately does NOT follow the link. The scanout runs
# on this board's own 148.5 MHz, and a TV that loses sync every time a
# camera is unplugged is worse than one showing a stale frame: the
# picture path is the board's, the source is the cable's. So the broom,
# not link_rst.
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins scanout/rst]
# fbread's reset is wired HERE, from the broom, and deliberately not by
# the AXI automation. The automation connects whatever its generated
# proc_sys_reset produces, and whether that block is holding cannot be
# read back from a build log or from software -- which is how an engine
# came to sit in reset for three builds while every register a host can
# see said it should be running. The broom is a signal whose state is
# readable, and it already resets the scanout on this same clock.
if {$fbread_en} {
    set fbrstn [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic fb_rstn]
    set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] $fbrstn
    connect_bd_net [get_bd_pins broom/Dout]  [get_bd_pins fb_rstn/Op1]
    connect_bd_net [get_bd_pins fb_rstn/Res] [get_bd_pins fbread/rst_n]
}
# fbread's reset is NOT connected here. Its port declares
# ASSOCIATED_RESET, so the AXI automation gives it the interconnect's
# own peripheral reset -- which is the right source for a bus master:
# a broom pulse landing mid-burst would leave the interconnect holding
# a transaction nobody will finish. It is stopped instead by taking its
# base address away, which is also how it is started.
# The prover's reset recipe, kept verbatim: rgb2dvi held in reset by
# nothing but the pixel MMCM's own lock.
set lockinv [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic lock_inv]
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] $lockinv
connect_bd_net [get_bd_pins clk_out/locked] [get_bd_pins lock_inv/Op1]
connect_bd_net [get_bd_pins lock_inv/Res] [get_bd_pins hdmi_tx/aRst]
assign_bd_address
# Explicitly: both stream engines write the DDR through HP0. The
# automation left dma/Data_S2MM UNMAPPED and validate called that a
# warning -- ten builds of silence for want of one segment.
if {$capture} {
    assign_bd_address -target_address_space /dma/Data_S2MM \
        [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM] -force
}
assign_bd_address -target_address_space /vdma/Data_S2MM \
    [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM] -force
assign_bd_address -target_address_space /vdma/Data_MM2S \
    [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM] -force

validate_bd_design
save_bd_design
make_wrapper -files [get_files rx.bd] -top -import
set_property top rx_wrapper [current_fileset]

puts "BD_DONE"
