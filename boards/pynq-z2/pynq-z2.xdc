# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
## Active pins for the receive proof -- names match the BD's external
## ports; package pins from TUL's PYNQ-Z2 master XDC (v1.0).
set_property -dict { PACKAGE_PIN N18 IOSTANDARD TMDS_33 } [get_ports TMDS_clk_p]
set_property -dict { PACKAGE_PIN P19 IOSTANDARD TMDS_33 } [get_ports TMDS_clk_n]
set_property -dict { PACKAGE_PIN V20 IOSTANDARD TMDS_33 } [get_ports {TMDS_data_p[0]}]
set_property -dict { PACKAGE_PIN W20 IOSTANDARD TMDS_33 } [get_ports {TMDS_data_n[0]}]
set_property -dict { PACKAGE_PIN T20 IOSTANDARD TMDS_33 } [get_ports {TMDS_data_p[1]}]
set_property -dict { PACKAGE_PIN U20 IOSTANDARD TMDS_33 } [get_ports {TMDS_data_n[1]}]
set_property -dict { PACKAGE_PIN N20 IOSTANDARD TMDS_33 } [get_ports {TMDS_data_p[2]}]
set_property -dict { PACKAGE_PIN P20 IOSTANDARD TMDS_33 } [get_ports {TMDS_data_n[2]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports ddc_scl_io]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports ddc_sda_io]
set_property -dict { PACKAGE_PIN T19 IOSTANDARD LVCMOS33 } [get_ports hdmi_hpd]
## 148.5 MHz: the frontend is CONSTRAINED for its fastest legal link
## (1080p), as the board's base overlay does; slower actual links (our
## 720p60) are handled by the IP at runtime. Constraining at the actual
## 74.25 puts the MMCM VCO below its floor and DRC rightly refuses.
create_clock -period 6.734 -name tmds_clk [get_ports TMDS_clk_p]
## The software reset is quasi-static: held for milliseconds by a GPIO
## write, absorbed by the receiver re-anchoring on the next vsync. Scoped
## to the one register so the clock converter's own CDC stays timed.
## The software reset is quasi-static everywhere by design: held for
## milliseconds by a GPIO write, absorbed by re-anchoring on the next
## frame. False-path it wholesale rather than per destination clock.
set_false_path -from [get_cells -hier -filter {NAME =~ */ctrl_gpio/*gpio_Data_Out_reg*}]

## The framebuffer's base address, and the enable beside it. Software
## writes the address, then enables, and the address does not move again
## while the engine runs -- so this crossing is quasi-static by
## contract, and the contract is what makes it safe rather than the
## timing. Left timed it fails by 4.3ns against a 148.5MHz raster, for a
## value that changes once a session.
set_false_path -from [get_cells -hier -filter {NAME =~ */ctrl_gpio/*gpio2_Data_Out_reg*}]

## The ISP's coefficient registers. They now live on the PROCESSOR's
## clock and not the pixel clock, because a register file on a clock
## recovered from the HDMI link has no clock whenever the link is down --
## and an AXI slave that cannot answer hangs the processor that asked.
## That cost a power cycle on 2026-08-17.
##
## Reading them from the pixel clock is therefore a crossing between two
## genuinely unrelated clocks, which is what this states. It states only
## that. It does NOT make the crossing safe: what will do that is the
## arm-and-refuse contract -- software arms, the file refuses writes
## while armed, so the values are provably still while the datapath
## copies them -- and that is not built yet.
##
## Until it is, nothing writes these registers, so they hold their reset
## values and never transition. That is what makes THIS bitstream safe,
## and it is a fact about the software, not about the hardware. A driver
## that starts writing coefficients before the contract lands can tear a
## value, and the picture is where it would show.
set_false_path -from [get_cells -hier -filter {NAME =~ */u_csr/reg_*}]

## ...and the ACKNOWLEDGEMENT, coming back the other way. The datapath
## says it has taken the values; that bit lands on the first flop of a
## two-flop synchroniser, which is exactly the structure that makes the
## crossing safe and exactly the path static timing cannot judge -- it
## carries 0.6ns of logic and misses by 5ns purely because the two
## clocks have no relationship.
##
## Constraining the FIRST FLOP of the synchroniser is the whole point:
## everything after it is ordinary same-domain logic and stays timed.
##
## This was missing because when the constraint above was written the
## acknowledgement did not exist -- the wire was never connected, so no
## path existed to constrain. A constraint file can only describe the
## design it was written against.
set_false_path -to [get_pins -hier -filter {NAME =~ */u_csr/ack_s0_reg/D}]
set_false_path -to [get_pins -hier -filter {NAME =~ */cfg_arm_req_s0_reg/D}]

## link_reset: two paths here are asynchronous BY CONSTRUCTION, and
## timing them is not a conservative choice, it is a meaningless one.
##
## 1. The lock signal. dvi2rgb's `aLocked` is named for what it is --
##    asynchronous -- and lk0/lk1 are the synchroniser that makes it
##    usable. Timing the launch into lk0 asks the tool to guarantee a
##    relationship the design explicitly does not rely on.
##
## 2. The reset's ASSERTION. `arst` drives the asynchronous preset of
##    the r0/r1 pair, and asserting with no pixel clock at all is the
##    entire reason this module exists -- an unplug takes the clock
##    away. Its DEASSERTION is synchronous, through those same two
##    flops, and that path stays timed, which is the half that matters.
##
## Left timed and this fails by 3.2ns on a route the tool has no
## reason to keep short, since nothing depends on its length.
set_false_path -to [get_pins -hier -filter {NAME =~ *link_rst*/lk0_reg*/D}]
set_false_path -to [get_pins -hier -filter {NAME =~ *link_rst*/r0_reg*/PRE}]
set_false_path -to [get_pins -hier -filter {NAME =~ *link_rst*/r1_reg*/PRE}]

## HDMI TX -- the display side (TUL master XDC v1.0 pin facts)
set_property -dict { PACKAGE_PIN L16 IOSTANDARD TMDS_33 } [get_ports hdmi_tx_clk_p]
set_property -dict { PACKAGE_PIN L17 IOSTANDARD TMDS_33 } [get_ports hdmi_tx_clk_n]
set_property -dict { PACKAGE_PIN K17 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_data_p[0]}]
set_property -dict { PACKAGE_PIN K18 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_data_n[0]}]
set_property -dict { PACKAGE_PIN K19 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_data_p[1]}]
set_property -dict { PACKAGE_PIN J19 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_data_n[1]}]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_data_p[2]}]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_data_n[2]}]

# There is no ISP clock island any more, and so no CDC exception here:
# once np2hw learned to read its line buffers through a register, the
# wide pipeline closed on the receiver's own pixel clock and the
# header's facts reach it as an ordinary timed path.
