// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// One elastic stream, two consumers, a REGISTER deciding which -- the
// judge's capture path or the ISP. An elastic stream cannot fan out
// (two readies, one truth), so the unselected side sees no valid and
// offers no backpressure. Switch only across a broom pulse: mid-frame
// flips are the reader's problem by construction.
module stream_switch #(
    // Sample width. The receiver aligns to the build's depth, so
    // this is that depth; 16 keeps a caller that never says.
    parameter SAMPLE_BITS = 16
) (
    input  wire        sel,        // 0: A (judge), 1: B (ISP)
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [SAMPLE_BITS-1:0] in_data,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_last,
    output wire        a_valid,
    input  wire        a_ready,
    output wire [SAMPLE_BITS-1:0] a_data,
    output wire        a_sof,
    output wire        a_eol,
    output wire        a_last,
    output wire        b_valid,
    input  wire        b_ready,
    output wire [SAMPLE_BITS-1:0] b_data,
    output wire        b_sof,
    output wire        b_eol,
    output wire        b_last
);
    assign a_valid = in_valid & ~sel;
    assign b_valid = in_valid &  sel;
    assign in_ready = sel ? b_ready : a_ready;
    assign a_data = in_data; assign b_data = in_data;
    assign a_sof = in_sof;   assign b_sof = in_sof;
    assign a_eol = in_eol;   assign b_eol = in_eol;
    assign a_last = in_last; assign b_last = in_last;
endmodule
