# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# The receive-proof bitstream: dvi2rgb front end, two capture paths.
# Batch: vivado -mode batch -source build.tcl (from /work in the container)
set here [file dirname [file normalize [info script]]]
set_param board.repoPaths [file join $root board-files]
create_project rx [file join $here build rx] -part xc7z020clg400-1 -force
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]
set_property ip_repo_paths [file join $root vivado-library] [current_project]
update_ip_catalog

set root [file normalize [file join $here .. ..]]
add_files [file join $root hdl generated bayerlink_rx.v] \
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

# --- R1 path: raw display pixels to DDR
set v2s [create_bd_cell -type ip -vlnv xilinx.com:ip:v_vid_in_axi4s vid_in]
set_property -dict [list CONFIG.C_HAS_ASYNC_CLK {1}] $v2s
connect_bd_intf_net [get_bd_intf_pins dvi_rx/RGB] [get_bd_intf_pins vid_in/vid_io_in]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins vid_in/vid_io_in_clk]
# Enables are INPUTS, and floating inputs tie to zero: a video-in block
# with vid_io_in_ce=0 is a very reliable source of empty buffers.
foreach pin {vid_io_in_ce axis_enable aclken} {
    catch {connect_bd_net [get_bd_pins hpd_one/dout] [get_bd_pins vid_in/$pin]}
}

set vdma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma vdma]
set_property -dict [list CONFIG.c_include_mm2s {0} CONFIG.c_include_s2mm {1} \
    CONFIG.c_s2mm_linebuffer_depth {2048}] $vdma
connect_bd_intf_net [get_bd_intf_pins vid_in/video_out] [get_bd_intf_pins vdma/S_AXIS_S2MM]

# --- R2 path: the unpacked line stream to DDR
set rx [create_bd_cell -type module -reference bayerlink_rx blrx]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins blrx/clk]
foreach {a b} {vid_pData vid_data vid_pVDE vid_de vid_pVSync vid_vsync} {
    connect_bd_net [get_bd_pins dvi_rx/$a] [get_bd_pins blrx/$b]
}
set shim [create_bd_cell -type module -reference rx_axis shim]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins shim/clk]
foreach s {valid ready data sof eol last} {
    connect_bd_net [get_bd_pins blrx/out_$s] [get_bd_pins shim/in_$s]
}
set cdc [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter cdc]
connect_bd_intf_net [get_bd_intf_pins shim/m_axis] [get_bd_intf_pins cdc/S_AXIS]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins cdc/s_axis_aclk]

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma]
set_property -dict [list CONFIG.c_include_mm2s {0} CONFIG.c_include_sg {0} \
    CONFIG.c_s_axis_s2mm_tdata_width {16} CONFIG.c_sg_length_width {26}] $dma
set spy [create_bd_cell -type module -reference axis_spy spy_cdc]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins spy_cdc/clk]
connect_bd_intf_net [get_bd_intf_pins cdc/M_AXIS] [get_bd_intf_pins spy_cdc/s_axis]
connect_bd_intf_net [get_bd_intf_pins spy_cdc/m_axis] [get_bd_intf_pins dma/S_AXIS_S2MM]

# --- interrupts: the pynq drivers refuse to exist without them
set irqcat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_cat]
connect_bd_net [get_bd_pins vdma/s2mm_introut] [get_bd_pins irq_cat/In0]
connect_bd_net [get_bd_pins dma/s2mm_introut] [get_bd_pins irq_cat/In1]
connect_bd_net [get_bd_pins irq_cat/dout] [get_bd_pins ps7/IRQ_F2P]

# --- software reset for the receiver: a sticky overflow needs a broom
set ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio ctrl_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_OUTPUTS {1}] $ctrl
connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins blrx/rst]
catch {connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins shim/rst]}

# --- status: lock + overflow + the probe's testimony
set probe [create_bd_cell -type module -reference vid_probe probe]
connect_bd_net [get_bd_pins dvi_rx/PixelClk] [get_bd_pins probe/clk]
connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins probe/rst]
connect_bd_net [get_bd_pins dvi_rx/vid_pVDE] [get_bd_pins probe/de]
connect_bd_net [get_bd_pins dvi_rx/vid_pVSync] [get_bd_pins probe/vsync]
connect_bd_net [get_bd_pins dvi_rx/vid_pData] [get_bd_pins probe/data]
connect_bd_net [get_bd_pins blrx/out_valid] [get_bd_pins probe/rx_valid]

set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio status_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {18} CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {16} CONFIG.C_ALL_INPUTS_2 {1}] $gpio
connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins spy_cdc/rst]
connect_bd_net [get_bd_pins spy_cdc/status] [get_bd_pins status_gpio/gpio2_io_i]
set cat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat status_cat]
set_property CONFIG.NUM_PORTS {3} $cat
connect_bd_net [get_bd_pins dvi_rx/aPixelClkLckd] [get_bd_pins status_cat/In0]
connect_bd_net [get_bd_pins blrx/overflow] [get_bd_pins status_cat/In1]
connect_bd_net [get_bd_pins probe/status] [get_bd_pins status_cat/In2]
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
set_property CONFIG.NUM_SI {2} [get_bd_cells axi_mem_intercon]
connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_S2MM] \
    [get_bd_intf_pins axi_mem_intercon/S01_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi_mem_intercon/S01_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins dma/m_axi_s2mm_aclk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_mem_intercon/S00_ARESETN]] \
    [get_bd_pins axi_mem_intercon/S01_ARESETN]
# Stream-side clocks the automation does not own: everything AXI in
# this design lives on FCLK0, so the crossings are exactly the two
# declared ones (TMDS pixel clock in, FCLK0 out).
foreach pin {vid_in/aclk vdma/s_axis_s2mm_aclk cdc/m_axis_aclk} {
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins $pin]
}

# RESETS the automation does not own. A floating aresetn is a HELD
# reset -- the clock converter and video-in have sat in reset through
# every test so far. AXI-side resetns join the net the automation
# gives the DMA; the converter's pixel-side resetn is the software
# reset, inverted, so one broom sweeps the whole receive path.
set inv [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic rstn_pix]
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] $inv
connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins rstn_pix/Op1]
# An async-FIFO crossing initializes only when BOTH sides reset while
# BOTH clocks run. At boot the pixel clock does not exist, so boot-time
# resets can never do it -- the software reset owns every reset pin of
# the receive path, and one pulse with the link up brings it all to a
# known state: converter (both sides), video-in (both sides), receiver.
connect_bd_net [get_bd_pins rstn_pix/Res] [get_bd_pins cdc/s_axis_aresetn]
connect_bd_net [get_bd_pins rstn_pix/Res] [get_bd_pins cdc/m_axis_aresetn]
connect_bd_net [get_bd_pins rstn_pix/Res] [get_bd_pins vid_in/aresetn]
connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins vid_in/vid_io_in_reset]
assign_bd_address
# Explicitly: both stream engines write the DDR through HP0. The
# automation left dma/Data_S2MM UNMAPPED and validate called that a
# warning -- ten builds of silence for want of one segment.
assign_bd_address -target_address_space /dma/Data_S2MM \
    [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM] -force
assign_bd_address -target_address_space /vdma/Data_S2MM \
    [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM] -force

validate_bd_design
save_bd_design
make_wrapper -files [get_files rx.bd] -top -import
set_property top rx_wrapper [current_fileset]

puts "BD_DONE"
