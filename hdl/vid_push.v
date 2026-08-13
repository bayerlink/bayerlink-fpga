// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Framebuffer-to-raster push. Owns the 720p timing outright -- the
// same fabric counters the port prover lit a display with -- and pops
// one AXIS beat per active pixel from the VDMA read stream. Replaces
// v_axi4s_vid_out, whose lock was never once witnessed here; every
// alignment decision this block makes is a readable status bit.
//
// Alignment: while unaligned, beats are discarded during vertical
// blanking until the next pending beat carries start-of-frame; that
// beat is left waiting and becomes pixel (0,0). Each frame start
// audits that the consumed beat really is a SOF; a mismatch drops
// back to hunting. Underflow paints magenta and sticks a bit.
module vid_push (
    input  wire        clk,     // 74.25 MHz pixel clock
    input  wire        rst,     // software broom, active high
    input  wire        locked,  // pixel MMCM's own testimony
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [23:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire        s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire        s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TUSER" *)
    input  wire        s_axis_tuser,   // start of frame
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
    input  wire        s_axis_tlast,   // end of line (unused: the raster rules)
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid_io ACTIVE_VIDEO" *)
    output reg         vid_active_video,
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid_io DATA" *)
    output reg  [23:0] vid_data,
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid_io HSYNC" *)
    output reg         vid_hsync,
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid_io VSYNC" *)
    output reg         vid_vsync,
    output wire [14:0] status
);
    // 720p60 CEA-861: 1650x750 total, 1280x720 active, +hsync +vsync
    localparam H_TOT = 1650, V_TOT = 750, H_ACT = 1280, V_ACT = 720,
               HS_BEG = 1390, HS_END = 1430, VS_BEG = 725, VS_END = 730;
    reg [11:0] x;
    reg [9:0]  y;
    wire active = (x < H_ACT) && (y < V_ACT);
    wire frame0 = (x == 0) && (y == 0);
    wire blank  = (y >= V_ACT);

    reg aligned;
    wire hunting = !aligned && blank;
    // Hunting discards until the pending beat is a SOF, then holds it;
    // aligned consumes exactly one beat per active pixel.
    assign s_axis_tready = aligned ? active
                                   : (hunting && !(s_axis_tvalid && s_axis_tuser));

    reg [24:0] alive;                    // MSB flips ~2Hz at 74.25 MHz
    reg [3:0]  vsyncs;
    reg vs_d, underflow, misalign, sof_seen;
    always @(posedge clk) begin
        alive <= alive + 1;
        if (rst || !locked) begin
            x <= 0; y <= 0; aligned <= 0;
            vid_active_video <= 0; vid_hsync <= 0; vid_vsync <= 0;
            vid_data <= 0; vsyncs <= 0; vs_d <= 0;
            underflow <= 0; misalign <= 0; sof_seen <= 0;
        end else begin
            x <= (x == H_TOT-1) ? 12'd0 : x + 12'd1;
            if (x == H_TOT-1) y <= (y == V_TOT-1) ? 10'd0 : y + 10'd1;

            // outputs share one register stage: the raster stays rigid
            vid_hsync <= (x >= HS_BEG) && (x < HS_END);
            vid_vsync <= (y >= VS_BEG) && (y < VS_END);
            vid_active_video <= active;
            vid_data <= (active && s_axis_tvalid) ? s_axis_tdata : 24'h800080;

            vs_d <= vid_vsync;
            if (vid_vsync && !vs_d) vsyncs <= vsyncs + 4'd1;

            if (s_axis_tvalid && s_axis_tuser) sof_seen <= 1;
            if (hunting && s_axis_tvalid && s_axis_tuser) aligned <= 1;
            if (aligned && active && !s_axis_tvalid) underflow <= 1;
            // frame-boundary audit: pixel (0,0) must consume a SOF beat
            if (aligned && frame0 && s_axis_tvalid && !s_axis_tuser) begin
                misalign <= 1;
                aligned  <= 0;
            end
        end
    end
    assign status = {vsyncs, alive[24:22], misalign, underflow,
                     aligned, sof_seen, locked, 3'b0};
endmodule
