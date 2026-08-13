// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The simplest possible video source: 720p timing and color bars,
// generated in fabric, no memory, no stream, no alignment -- nothing
// to lock, nothing to starve. Exists to prove a TMDS transmitter and
// a monitor with the fewest moving parts on the die.
module fabric_tpg (
    input  wire        clk,             // 74.25 MHz
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid ACTIVE_VIDEO" *)
    output reg         vid_active_video,
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid DATA" *)
    output reg [23:0]  vid_data,
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid HSYNC" *)
    output reg         vid_hsync,
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid VSYNC" *)
    output reg         vid_vsync
);
    // CEA-861 720p60: 1650 x 750 total, 1280 x 720 active,
    // hsync 110+40, vsync 5+5 (front porch + width), both active high.
    reg [11:0] x = 0;
    reg [9:0]  y = 0;
    always @(posedge clk) begin
        x <= (x == 1649) ? 0 : x + 1;
        if (x == 1649) y <= (y == 749) ? 0 : y + 1;
        vid_hsync <= (x >= 1390) && (x < 1430);
        vid_vsync <= (y >= 725) && (y < 730);
        vid_active_video <= (x < 1280) && (y < 720);
        case (x[10:8])                   // eight 160-px-ish bars
            3'd0: vid_data <= 24'hFFFFFF;
            3'd1: vid_data <= 24'hFFFF00;
            3'd2: vid_data <= 24'h00FFFF;
            3'd3: vid_data <= 24'h00FF00;
            3'd4: vid_data <= 24'hFF00FF;
            3'd5: vid_data <= 24'hFF0000;
            3'd6: vid_data <= 24'h0000FF;
            default: vid_data <= 24'h101010;
        endcase
    end
endmodule
