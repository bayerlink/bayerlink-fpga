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
set_false_path -from [get_cells -hier -filter {NAME =~ */ctrl_gpio/*gpio_Data_Out_reg*}] -to [get_clocks PixelClk_int]
