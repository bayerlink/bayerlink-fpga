// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The ISP's stream, split for two consumers: the store (VDMA) and the
// direct display branch. The tee itself is np2hw's, payload-agnostic;
// this shim owns ONE fact -- how the flags pack beside the pixels --
// stated here once so both branches unpack the same layout.
//   [29:0] rgb   [30] eol   [31] last   [32] sof
module tee_shim (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [29:0] in_data,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_last,
    input  wire        en_a,       // direct display branch
    input  wire        en_b,       // framebuffer store branch
    output wire        a_valid,
    input  wire        a_ready,
    output wire [29:0] a_data,
    output wire        a_sof,
    output wire        a_eol,
    output wire        a_last,
    output wire        b_valid,
    input  wire        b_ready,
    output wire [29:0] b_data,
    output wire        b_sof,
    output wire        b_eol,
    output wire        b_last
);
    wire [32:0] packed_in = {in_sof, in_last, in_eol, in_data};
    wire [32:0] a_packed, b_packed;

    // The skid FIRST: the ISP's in_ready ripples combinationally from
    // its sink through every block (the boundary_report finding), and
    // the tee's lockstep fork below would add its own levels to that
    // cone. The skid's registered ready is where the cone ends -- the
    // ISP sees a flop whatever is wired past this point.
    wire [32:0] sk_data;
    wire        sk_valid, sk_ready;
    isp_skid #(.W(33)) u_skid (
        .clk(clk), .rst(rst),
        .s_data(packed_in), .s_valid(in_valid), .s_ready(in_ready),
        .m_data(sk_data), .m_valid(sk_valid), .m_ready(sk_ready));

    isp_tee #(.W(33)) u_tee (
        .clk(clk), .rst(rst),
        .in_valid(sk_valid), .in_ready(sk_ready),
        .in_data(sk_data), .in_sof(sk_data[32]),
        .en_a(en_a), .en_b(en_b),
        .a_valid(a_valid), .a_ready(a_ready), .a_data(a_packed),
        .b_valid(b_valid), .b_ready(b_ready), .b_data(b_packed));

    assign {a_sof, a_last, a_eol, a_data} = a_packed;
    assign {b_sof, b_last, b_eol, b_data} = b_packed;
endmodule
