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
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 a VALID" *)
    output wire        a_valid,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 a READY" *)
    input  wire        a_ready,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 a DATA" *)
    output wire [SAMPLE_BITS-1:0] a_data,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 a SOF" *)
    output wire        a_sof,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 a EOL" *)
    output wire        a_eol,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 a LAST" *)
    output wire        a_last,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 b VALID" *)
    output wire        b_valid,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 b READY" *)
    input  wire        b_ready,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 b DATA" *)
    output wire [SAMPLE_BITS-1:0] b_data,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 b SOF" *)
    output wire        b_sof,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 b EOL" *)
    output wire        b_eol,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 b LAST" *)
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
