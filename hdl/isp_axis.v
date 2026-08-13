// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The ISP's 30-bit RGB stream, dressed as AXI4-Stream video for a
// VDMA S2MM writing the framebuffer. Channel 0 rides the LOW bits of
// the pipeline word (revela's packing law); the framebuffer byte
// order comes from rgb2dvi's bus: [23:16] R, [15:8] B, [7:0] G --
// via the little-endian framebuffer word, bytes G, B, R, pad.
// tuser marks start of frame, tlast end of line: the VDMA's dialect.
module isp_axis (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [29:0] in_data,   // R [9:0], G [19:10], B [29:20]
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_last,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [31:0] m_axis_tdata,
    output wire [3:0]  m_axis_tkeep,
    output wire        m_axis_tuser,
    output wire        m_axis_tlast
);
    wire [7:0] r8 = in_data[9:2];
    wire [7:0] g8 = in_data[19:12];
    wire [7:0] b8 = in_data[29:22];
    assign m_axis_tkeep  = 4'b1111;
    assign m_axis_tvalid = in_valid;
    assign in_ready      = m_axis_tready;
    assign m_axis_tdata  = {8'h00, r8, b8, g8};
    assign m_axis_tuser  = in_sof;
    assign m_axis_tlast  = in_eol;
endmodule
