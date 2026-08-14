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

add_files [file join $root hdl vid_push.v] \
    [file join $root hdl stream_switch.v] [file join $root hdl axis_unpack.v] \
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
    CONFIG.PCW_EN_CLK1_PORT {1} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1}] $ps

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
set rx [create_bd_cell -type module -reference bayerlink_rx blrx]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins blrx/clk]
foreach {a b} {vid_pData vid_data vid_pVDE vid_de vid_pVSync vid_vsync} {
    connect_bd_net [get_bd_pins dvi_rx/$a] [get_bd_pins blrx/$b]
}
# One stream, two consumers, a register deciding which: the judge's
# byte-exact capture, or the ISP. The unselected side sees silence.
set sw [create_bd_cell -type module -reference stream_switch sw]
foreach s {valid ready data sof eol last} {
    connect_bd_net [get_bd_pins blrx/out_$s] [get_bd_pins sw/in_$s]
}
set shim [create_bd_cell -type module -reference rx_axis shim]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins shim/clk]
foreach s {valid ready data sof eol last} {
    connect_bd_net [get_bd_pins sw/a_$s] [get_bd_pins shim/in_$s]
}
# --- the ISP branch: ONE domain with the receiver. The pixel clock is
# constrained at 148.5 MHz (the fastest legal link) and the revela
# pipeline is generated against that same budget -- the traced depth
# model cuts any too-deep stage into pipeline stages at generation
# time, so the island and its clock converter are gone.
set shimb [create_bd_cell -type module -reference rx_axis shim_isp]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins shim_isp/clk]
foreach s {valid ready data sof eol last} {
    connect_bd_net [get_bd_pins sw/b_$s] [get_bd_pins shim_isp/in_$s]
}
set unp [create_bd_cell -type module -reference axis_unpack unpack_isp]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins unpack_isp/clk]
connect_bd_intf_net [get_bd_intf_pins shim_isp/m_axis] [get_bd_intf_pins unpack_isp/s_axis]
set isp [create_bd_cell -type module -reference revela_isp isp]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins isp/clk]
# The stream's own facts drive the pipeline context: header to ctx,
# one owner end to end, and now one CLOCK end to end -- an ordinary
# timed path, no CDC exception needed.
foreach f {width height phase bits} {
    connect_bd_net [get_bd_pins blrx/hdr_$f] [get_bd_pins isp/hdr_$f]
}
foreach s {valid ready data sof eol last} {
    connect_bd_net [get_bd_pins unpack_isp/out_$s] [get_bd_pins isp/in_$s]
}
set iax [create_bd_cell -type module -reference isp_axis isp_out]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins isp_out/clk]
foreach s {valid ready data sof eol last} {
    connect_bd_net [get_bd_pins isp/out_$s] [get_bd_pins isp_out/in_$s]
}
connect_bd_intf_net [get_bd_intf_pins isp_out/m_axis] [get_bd_intf_pins vdma/S_AXIS_S2MM]
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

# --- display side: the same 720p the receiver listens to, sourced from
# a framebuffer in DDR. Pixel clock is OURS (static 74.25 from FCLK0);
# rgb2dvi makes its own 5x serial clock (MMCM: 742.5 sits inside the
# MMCM VCO window; a PLL's floor is above it).
set cw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_out]
# No_buffer: FCLK arrives from the PS already buffered; the default
# expects a package PIN and builds an input path to nowhere -- an MMCM
# that never sees an edge, and a perfectly silent dead clock.
set_property -dict [list CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.250} \
    CONFIG.USE_LOCKED {true} CONFIG.USE_RESET {false}] $cw
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins clk_out/clk_in1]

# No v_tc, no v_axi4s_vid_out: that pair's lock was never witnessed
# here across every mode it offers. The raster is OURS -- vid_push
# carries the exact counters the port prover lit a display with, and
# pops the VDMA stream one beat per active pixel. Its alignment and
# underflow decisions are status bits, not a lock to pray over.
set tx [create_bd_cell -type ip -vlnv digilentinc.com:ip:rgb2dvi hdmi_tx]
set_property -dict [list CONFIG.kGenerateSerialClk {true} \
    CONFIG.kClkPrimitive {MMCM} CONFIG.kClkRange {2} \
    CONFIG.kRstActiveHigh {true}] $tx
set vp [create_bd_cell -type module -reference vid_push vid_push]
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins vid_push/clk]
connect_bd_net [get_bd_pins clk_out/locked] [get_bd_pins vid_push/locked]
connect_bd_intf_net [get_bd_intf_pins vid_push/vid_io] [get_bd_intf_pins hdmi_tx/RGB]
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins hdmi_tx/PixelClk]
make_bd_intf_pins_external [get_bd_intf_pins hdmi_tx/TMDS]
set_property name hdmi_tx [get_bd_intf_ports TMDS_0]

# VDMA grows its read side: the framebuffer out.
# The read stream lives on the PIXEL clock: vid_push pops at raster
# pace with no elastic in between beyond the vdma's own line buffer.
# The stream stays 32-bit (the core refuses 24): xRGB pixels, and
# vid_push takes the low three bytes of each beat.
# FREE-RUN, explicitly: propagation once slipped in use_fsync=1 and
# genlock-slave -- a scheduler waiting forever on a sync and a frame
# pointer that nothing drives. Running-while-starving, no error bit.
set_property -dict [list CONFIG.c_include_mm2s {1} \
    CONFIG.c_mm2s_linebuffer_depth {2048} \
    CONFIG.c_use_fsync {0} \
    CONFIG.c_mm2s_genlock_mode {0} \
    CONFIG.c_s2mm_genlock_mode {0}] $vdma
connect_bd_intf_net [get_bd_intf_pins vdma/M_AXIS_MM2S] [get_bd_intf_pins vid_push/s_axis]
connect_bd_net [get_bd_pins clk_out/clk_out1] [get_bd_pins vdma/m_axis_mm2s_aclk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins vdma/m_axi_mm2s_aclk]

# --- interrupts: the pynq drivers refuse to exist without them
set irqcat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_cat]
connect_bd_net [get_bd_pins vdma/s2mm_introut] [get_bd_pins irq_cat/In0]
connect_bd_net [get_bd_pins dma/s2mm_introut] [get_bd_pins irq_cat/In1]
connect_bd_net [get_bd_pins irq_cat/dout] [get_bd_pins ps7/IRQ_F2P]

# --- software reset for the receiver: a sticky overflow needs a broom
set ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio ctrl_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {2} CONFIG.C_ALL_OUTPUTS {1}] $ctrl
# Bit 0 is the broom, bit 1 selects the stream's consumer (judge/ISP).
set brm [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice broom]
set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {0} \
    CONFIG.DIN_TO {0}] $brm
connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins broom/Din]
set msel [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice isp_sel]
set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {1} \
    CONFIG.DIN_TO {1}] $msel
connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins isp_sel/Din]
connect_bd_net [get_bd_pins isp_sel/Dout] [get_bd_pins sw/sel]
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins shim_isp/rst]
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins unpack_isp/rst]
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins isp/rst]
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins isp_out/rst]
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins blrx/rst]
catch {connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins shim/rst]}

# --- status: lock + overflow + the probe's testimony
set probe [create_bd_cell -type module -reference vid_probe probe]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins probe/clk]
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins probe/rst]
connect_bd_net [get_bd_pins dvi_rx/vid_pVDE] [get_bd_pins probe/de]
connect_bd_net [get_bd_pins dvi_rx/vid_pVSync] [get_bd_pins probe/vsync]
connect_bd_net [get_bd_pins dvi_rx/vid_pData] [get_bd_pins probe/data]
connect_bd_net [get_bd_pins blrx/out_valid] [get_bd_pins probe/rx_valid]

set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio status_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {30} CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_INPUTS_2 {1}] $gpio
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins spy_cdc/rst]
set cat2 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat status2_cat]
set_property CONFIG.NUM_PORTS {3} $cat2
connect_bd_net [get_bd_pins spy_cdc/status] [get_bd_pins status2_cat/In0]
connect_bd_net [get_bd_pins clk_out/locked] [get_bd_pins status2_cat/In1]
connect_bd_net [get_bd_pins vid_push/status] [get_bd_pins status2_cat/In2]
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
set cat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat status_cat]
set_property CONFIG.NUM_PORTS {4} $cat
connect_bd_net [get_bd_pins dvi_rx/aPixelClkLckd] [get_bd_pins status_cat/In0]
connect_bd_net [get_bd_pins blrx/overflow] [get_bd_pins status_cat/In1]
connect_bd_net [get_bd_pins probe/status] [get_bd_pins status_cat/In2]
connect_bd_net [get_bd_pins hdr_cat/dout] [get_bd_pins status_cat/In3]
connect_bd_net [get_bd_pins status_cat/dout] [get_bd_pins status_gpio/gpio_io_i]

# --- automation for AXI plumbing, resets, address map
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} intc_ip {New AXI Interconnect}} \
    [get_bd_intf_pins vdma/S_AXI_LITE]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} intc_ip {New AXI Interconnect}} \
    [get_bd_intf_pins dma/S_AXI_LITE]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} intc_ip {New AXI Interconnect}} \
    [get_bd_intf_pins status_gpio/S_AXI]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} intc_ip {New AXI Interconnect}} \
    [get_bd_intf_pins ctrl_gpio/S_AXI]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/vdma/M_AXI_S2MM} \
     Slave {/ps7/S_AXI_HP0} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
    [get_bd_intf_pins ps7/S_AXI_HP0]
# NOT automation: its second pass built the dma a private interconnect
# whose master port went to __NOC__ -- nowhere -- and called it a
# warning. Both stream engines share the one interconnect, explicitly.
set_property CONFIG.NUM_SI {3} [get_bd_cells axi_mem_intercon]
connect_bd_intf_net [get_bd_intf_pins vdma/M_AXI_MM2S] \
    [get_bd_intf_pins axi_mem_intercon/S02_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi_mem_intercon/S02_ACLK]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_mem_intercon/S00_ARESETN]] \
    [get_bd_pins axi_mem_intercon/S02_ARESETN]
connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_S2MM] \
    [get_bd_intf_pins axi_mem_intercon/S01_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi_mem_intercon/S01_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins dma/m_axi_s2mm_aclk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_mem_intercon/S00_ARESETN]] \
    [get_bd_pins axi_mem_intercon/S01_ARESETN]
# Stream-side clocks the automation does not own: everything AXI in
# this design lives on FCLK0, so the crossings are exactly the two
# declared ones (TMDS pixel clock in, FCLK0 out).
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins vdma/s_axis_s2mm_aclk]
foreach pin {cdc/m_axis_aclk} {
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins $pin]
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
# resets can never do it -- the software reset owns every reset pin of
# the receive path, and one pulse with the link up brings it all to a
# known state: converter (both sides), video-in (both sides), receiver.
connect_bd_net [get_bd_pins rstn_pix/Res] [get_bd_pins cdc/s_axis_aresetn]
connect_bd_net [get_bd_pins rstn_pix/Res] [get_bd_pins cdc/m_axis_aresetn]
connect_bd_net [get_bd_pins broom/Dout] [get_bd_pins vid_push/rst]
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
assign_bd_address -target_address_space /dma/Data_S2MM \
    [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM] -force
assign_bd_address -target_address_space /vdma/Data_S2MM \
    [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM] -force
assign_bd_address -target_address_space /vdma/Data_MM2S \
    [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM] -force

validate_bd_design
save_bd_design
make_wrapper -files [get_files rx.bd] -top -import
set_property top rx_wrapper [current_fileset]

puts "BD_DONE"
