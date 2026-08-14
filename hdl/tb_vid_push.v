// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The claim this testbench exists for: a raster must not start a frame
// before the frame's first beat has arrived.
//
// The bench's own bug, stated as a stimulus: a read engine that pauses
// at each frame boundary and answers a few clocks after active video
// has already begun. A raster that starts anyway consumes its first
// beat late and paints the WHOLE frame rolled by that gap -- and no
// audit downstream can see it, because the missing beat carries no
// evidence. On real hardware this was a 306-pixel roll that survived
// resets and looked like a display fault.
//
//   iverilog -o tb.vvp hdl/tb_vid_push.v hdl/vid_push.v && vvp tb.vvp
`timescale 1ns/1ps
module tb_vid_push;
    localparam H_TOT = 40, V_TOT = 12, H_ACT = 32, V_ACT = 8;
    localparam FRAME = H_ACT * V_ACT;
    // The engine answers late ONCE -- long enough that active video has
    // already begun -- and then keeps up forever after. That is the
    // bench's real history: one slow start, and a roll that outlived it.
    // Blanking here is 4 lines x 40 = 160 clocks. The engine's first
    // answer takes 200 -- so active video has already begun when the
    // frame's first beat finally arrives. That is the bench's measured
    // 2.15 microseconds of DDR latency, in miniature.
    localparam STALL_FIRST = 3;
    localparam STALL       = 3;
    localparam STALL_LATE  = 200;   // the hiccup, AFTER alignment
    localparam LATE_FRAME  = 3;     // which frame boundary hiccups

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    wire tready;
    reg  tvalid = 0;
    // data and SOF track the beat counter COMBINATIONALLY: a model that
    // registers them lags its own handshake and tests nothing real
    wire [23:0] tdata;
    wire tuser;
    wire vde, vhs, vvs;
    wire [23:0] vdata;
    wire [14:0] status;

    vid_push #(.H_TOT(H_TOT), .V_TOT(V_TOT), .H_ACT(H_ACT), .V_ACT(V_ACT),
               .HS_BEG(34), .HS_END(36), .VS_BEG(9), .VS_END(10)) dut (
        .clk(clk), .rst(rst), .locked(1'b1),
        .s_axis_tdata(tdata), .s_axis_tvalid(tvalid),
        .s_axis_tready(tready), .s_axis_tuser(tuser), .s_axis_tlast(1'b0),
        .vid_active_video(vde), .vid_data(vdata),
        .vid_hsync(vhs), .vid_vsync(vvs), .status(status));

    // A read engine that pauses at every frame boundary.
    integer beat = 0, stall = 0, wraps = 0;
    assign tdata = beat[23:0];
    assign tuser = (beat == 0);
    always @(posedge clk) begin
        if (rst) begin
            beat <= 0; stall <= STALL_FIRST; tvalid <= 0; wraps <= 0;
        end else if (stall > 0) begin
            stall  <= stall - 1;
            tvalid <= 0;
        end else begin
            tvalid <= 1;
            if (tvalid && tready) begin
                if (beat == FRAME - 1) begin
                    beat   <= 0;
                    wraps  <= wraps + 1;
                    // One hiccup, once the raster is long since aligned:
                    // memory answers late and active video has begun.
                    stall  <= (wraps == LATE_FRAME) ? STALL_LATE : STALL;
                    tvalid <= 0;
                end else begin
                    beat <= beat + 1;
                end
            end
        end
    end

    // Watch the emitted picture: every frame must read 0,1,2,...,FRAME-1.
    integer seen = 0, frames = 0, errors = 0;
    always @(posedge clk) if (!rst && vde) begin
        // THE CLAIM: a frame may be DROPPED, never DISPLACED. Fill is
        // an honest refusal -- the raster could not start that frame on
        // a frame boundary, so it painted nothing. A real pixel in the
        // wrong place is the fault: it means the picture slid, and on
        // hardware it slides for the rest of the session.
        if (frames > 0 && vdata !== 24'h800080 && vdata !== seen[23:0]) begin
            if (errors < 4)
                $display("  ROLLED: pixel %0d of frame %0d carries %0d", seen, frames, vdata);
            errors = errors + 1;
        end
        seen = seen + 1;
        if (seen == FRAME) begin
            seen = 0;
            frames = frames + 1;
        end
    end

    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        repeat (V_TOT * H_TOT * 12) @(negedge clk);
        $display("tb_vid_push: %0d frames, %0d rolled pixels, underflow=%0d misalign=%0d",
                 frames, errors, (status >> 6) & 1, (status >> 7) & 1);
        if (frames >= 6 && errors == 0)
            $display("TB_VID_PUSH PASS");
        else
            $display("TB_VID_PUSH FAIL");
        $finish;
    end
endmodule
