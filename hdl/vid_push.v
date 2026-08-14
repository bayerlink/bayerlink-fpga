// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Framebuffer-to-raster push. Owns its timing outright -- the same
// fabric counters the port prover lit a display with -- and pops
// one AXIS beat per active pixel from the VDMA read stream. Replaces
// v_axi4s_vid_out, whose lock was never once witnessed here; every
// alignment decision this block makes is a readable status bit.
// The raster is a parameter set (defaults: 720p60); the board file
// states the mode it feeds the display.
//
// Alignment is PER FRAME, not once. During vertical blanking beats are
// discarded until the next one carries start-of-frame; that beat is
// left waiting and becomes pixel (0,0), and only then is the raster
// armed to consume. A frame that is not armed when active video begins
// paints fill and waits for the next blanking, because starting a
// frame on faith is how a picture acquires a permanent horizontal
// roll: the engine answers a few hundred clocks late, the raster takes
// its first beat late, and every later audit sees a perfectly ordinary
// stream. A beat that has not arrived carries no evidence, so the
// arming IS the check. Underflow paints magenta and sticks a bit.
module vid_push #(
    // 720p60 CEA-861 defaults: 1650x750 total, 1280x720 active
    parameter H_TOT  = 1650, parameter V_TOT  = 750,
    parameter H_ACT  = 1280, parameter V_ACT  = 720,
    parameter HS_BEG = 1390, parameter HS_END = 1430,
    parameter VS_BEG = 725,  parameter VS_END = 730,
    // SELFTEST paints from the raster's OWN counters and ignores the
    // stream: it answers one question and no other -- is the data this
    // block emits where its own data-enable says it is? A displacement
    // that survives this is downstream of here, and nothing about the
    // memory path can explain it.
    parameter SELFTEST = 0
) (
    input  wire        clk,     // the raster's pixel clock
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
    reg [11:0] x;
    reg [10:0] y;
    wire active = (x < H_ACT) && (y < V_ACT);
    wire frame0 = (x == 0) && (y == 0);
    wire blank  = (y >= V_ACT);

    reg aligned;                         // has armed at least once: status
    reg armed;                           // this frame's first beat is HERE
    wire head_sof = s_axis_tvalid && s_axis_tuser;
    // A frame may only START when its first beat is already at the head.
    // Waiting for it costs nothing -- vertical blanking is idle time --
    // while starting without it paints the WHOLE frame rolled by however
    // long the engine took to answer. That gap is invisible to any audit
    // downstream, because a beat that has not arrived carries no
    // evidence: the frame-boundary check can only inspect a beat it can
    // see. So the arming is the check, and it happens every frame.
    assign s_axis_tready = armed ? active : (blank && !head_sof);

    reg [24:0] alive;                    // MSB flips ~2Hz at 74.25 MHz
    reg [3:0]  vsyncs;
    reg vs_d, underflow, misalign, sof_seen;
    // How many beats per frame actually carry start-of-frame. It should
    // be exactly one. If an engine marks more than one -- or marks them
    // continuously -- then every "aligned" this block has ever reported
    // means only "some beat claimed to be a frame start", and the phase
    // it locks is arbitrary. Saturating, latched per frame, so the
    // number survives to be read.
    reg [2:0] sof_run, sof_seen_cnt;
    always @(posedge clk) begin
        alive <= alive + 1;
        if (rst || !locked) begin
            x <= 0; y <= 0; aligned <= 0; armed <= 0;
            vid_active_video <= 0; vid_hsync <= 0; vid_vsync <= 0;
            vid_data <= 0; vsyncs <= 0; vs_d <= 0;
            underflow <= 0; misalign <= 0; sof_seen <= 0;
            sof_run <= 0; sof_seen_cnt <= 0;
        end else begin
            x <= (x == H_TOT-1) ? 12'd0 : x + 12'd1;
            if (x == H_TOT-1) y <= (y == V_TOT-1) ? 11'd0 : y + 11'd1;

            // outputs share one register stage: the raster stays rigid
            vid_hsync <= (x >= HS_BEG) && (x < HS_END);
            vid_vsync <= (y >= VS_BEG) && (y < VS_END);
            vid_active_video <= active;
            // Only a beat that is actually CONSUMED may be shown: an
            // unarmed frame must paint fill, not repeat a beat it is
            // not taking.
            if (SELFTEST)
                // white posts at the first four and last four columns,
                // a ramp between: position, stated by the block itself
                vid_data <= (x < 4 || x >= H_ACT-4) ? 24'hFFFFFF
                                                    : {3{x[7:0]}};
            else
                vid_data <= (armed && active && s_axis_tvalid)
                            ? s_axis_tdata : 24'h800080;

            vs_d <= vid_vsync;
            if (vid_vsync && !vs_d) vsyncs <= vsyncs + 4'd1;

            if (head_sof) sof_seen <= 1;
            // count SOF-marked beats that actually TRANSFER, per frame
            if (head_sof && s_axis_tready && sof_run != 3'd7)
                sof_run <= sof_run + 3'd1;
            if (frame0) begin
                sof_seen_cnt <= sof_run;
                sof_run <= (head_sof && s_axis_tready) ? 3'd1 : 3'd0;
            end
            // Arm on the frame start, in the blanking before it is due.
            if (blank && head_sof) begin armed <= 1; aligned <= 1; end
            if (armed && active && !s_axis_tvalid) underflow <= 1;
            // The audit still runs, and now it is a real assertion rather
            // than a hope: if an armed frame's first pixel is not a SOF
            // beat, something upstream changed the stream's shape.
            if (armed && frame0 && s_axis_tvalid && !s_axis_tuser)
                misalign <= 1;
            // The frame is spent at its last active pixel; the next
            // blanking must arm again. Alignment is per FRAME, not once.
            if (armed && active && (x == H_ACT-1) && (y == V_ACT-1))
                armed <= 1'b0;
        end
    end
    assign status = {vsyncs, alive[24:22], misalign, underflow,
                     aligned, sof_seen, locked, sof_seen_cnt};
endmodule
