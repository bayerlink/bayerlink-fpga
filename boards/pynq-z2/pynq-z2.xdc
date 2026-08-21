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
# DDC: served by ddc_slave now (EDID + registers), not dvi2rgb. The
# real pull-ups are the source's (the Pi carries them); the weak
# internal ones only keep the bus from floating with no cable in.
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 PULLUP true } [get_ports ddc_scl_io]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 PULLUP true } [get_ports ddc_sda_io]
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

## The coefficient crossing is GONE, and so are the three false paths
## that used to describe it. The register file and the datapath both
## live on clk_out1 now -- the board's own 148.5, no cable in its
## ancestry -- so register-to-datapath paths are ordinary same-domain
## timing, and a false path left here would not be conservative, it
## would HIDE real paths from analysis. A constraint file describes
## the design it was written against; the design changed, so it did.

## What remains crossing INTO the island is the header's facts:
## blrx latches width/height/phase/bits in the pixel domain, the ISP
## wrapper latches them again at each frame's SOF in its own. Safe by
## CONTRACT, not by timing: they change at header-accept, a full line
## (~2200 clocks) before the first pixel, and the SOF that triggers
## the wrapper's latch travels through the same converter behind them
## -- by the time it arrives they have been still for thousands of
## cycles. Between two unrelated 148.5MHz clocks the setup window is
## effectively zero, so timing these paths is not strict, it is
## meaningless. The receiver's diagnostic counters cross to the PS
## GPIOs under the same contract: counts, read at leisure.
set_false_path -from [get_cells -hier -filter {NAME =~ */blrx/*hdr_*_reg*}]

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

# The ISP clock island is BACK -- not for timing, which np2hw solved,
# but because the receiver's clock stops with the cable and the
# island's does not. Its one exception lives above, with the header
# facts it belongs to.

# The display raster's MMCM (clk_out74, genlock builds only) and the
# island's MMCM both derive from FCLK1, so the tools call their outputs
# related and time the crossing against an arbitrary inter-VCO phase --
# a 6 ps requirement on the gray-pointer synchronizers whose entire
# design is to not need one. The FIFO's gray discipline IS the
# synchronizer; the timer stands down. Declared, not false-pathed
# per-net: every island<->raster path goes through that FIFO.
set c74 [get_clocks -quiet clk_out1_rx_clk_out74_0]
if {[llength $c74]} {
    set_clock_groups -asynchronous \
        -group $c74 \
        -group [get_clocks clk_out1_rx_clk_out_0]
}
