// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// bayerlink_rx's elastic stream, dressed as AXI4-Stream for an S2MM DMA.
// One DMA packet per FRAME (tlast = the stream's last flag): the judge
// on the ARM wants whole frames. The DMA word is 32 bits: sample in
// [15:0], eol at 16, sof at 17, the rest zero.
//
// That LAYOUT IS FIXED even when the sample is narrower than 16 bits --
// the receiver aligns to the build's depth, which may be 10 or 12, and
// the sample is zero-extended into the field. Host software reading
// captures does not move when the datapath's depth changes; what the
// value MEANS is the header's business, which the host already reads.
module rx_axis #(
    parameter SAMPLE_BITS = 16
) (
    input  wire        clk,
    input  wire        rst,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 in VALID" *)
    input  wire        in_valid,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 in READY" *)
    output wire        in_ready,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 in DATA" *)
    input  wire [SAMPLE_BITS-1:0] in_data,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 in SOF" *)
    input  wire        in_sof,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 in EOL" *)
    input  wire        in_eol,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 in LAST" *)
    input  wire        in_last,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [31:0] m_axis_tdata,
    output wire [3:0]  m_axis_tkeep,
    output wire        m_axis_tlast
);
    // Every byte is always a byte: an ABSENT tkeep ties low in a block
    // design, and a DMA politely discards a perfect stream marked
    // all-bytes-invalid -- accepting beats, writing nothing, raising no
    // error. Cost of learning this: one bench evening.
    assign m_axis_tkeep = 4'b1111;
    assign m_axis_tvalid = in_valid;
    assign in_ready      = m_axis_tready;
    // Widening on assignment zero-extends: the sample sits in the low
    // bits of a field that stays 16 wide whatever SAMPLE_BITS is.
    wire [15:0] sample_field = in_data;
    assign m_axis_tdata  = {14'b0, in_sof, in_eol, sample_field};
    assign m_axis_tlast  = in_last;
endmodule
