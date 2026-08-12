// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// bayerlink_rx's elastic stream, dressed as AXI4-Stream for an S2MM DMA.
// One DMA packet per FRAME (tlast = the stream's last flag): the judge
// on the ARM wants whole frames, and 512x240 samples fit one transfer.
// sof/eol travel IN the data's framing position on the wire already;
// the judge re-derives them from geometry, so tdata carries the sample.
module rx_axis (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [11:0] in_data,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_last,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [15:0] m_axis_tdata,
    output wire [1:0]  m_axis_tkeep,
    output wire        m_axis_tlast
);
    // Every byte is always a byte: an ABSENT tkeep ties low in a block
    // design, and a DMA politely discards a perfect stream marked
    // all-bytes-invalid -- accepting beats, writing nothing, raising no
    // error. Cost of learning this: one bench evening.
    assign m_axis_tkeep = 2'b11;
    assign m_axis_tvalid = in_valid;
    assign in_ready      = m_axis_tready;
    assign m_axis_tdata  = {2'b00, in_sof, in_eol, in_data};
    assign m_axis_tlast  = in_last;
endmodule
