// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The pins' side of the DDC slave: one tri-state, stated in RTL so
// the block design keeps every logical net visible. SDA is open
// drain -- driven low or released, never high; the pull-ups live at
// the source end of the cable (they are the source's per the spec,
// and the Pi carries them). SCL is INPUT ONLY: this slave never
// stretches, and a slave that could hold the bus clock low would be
// the cable-owns-no-clock rule violated one layer up.
module ddc_phy (
    inout  wire sda_io,
    input  wire scl_io,
    output wire scl_i,
    output wire sda_i,
    input  wire sda_pull
);
    assign sda_io = sda_pull ? 1'b0 : 1'bz;
    assign sda_i  = sda_io;
    assign scl_i  = scl_io;
endmodule
