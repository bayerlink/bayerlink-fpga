// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The inverse of rx_axis: the 32-bit DMA word format back into the
// elastic stream, on the far side of a clock converter. Sample in
// [15:0], eol at 16, sof at 17, last as tlast -- one layout, two
// directions, rx_axis owns the definition.
module axis_unpack #(
    parameter SAMPLE_BITS = 16
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tlast,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream VALID" *)
    output wire        out_valid,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream READY" *)
    input  wire        out_ready,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream DATA" *)
    output wire [SAMPLE_BITS-1:0] out_data,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream SOF" *)
    output wire        out_sof,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream EOL" *)
    output wire        out_eol,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream LAST" *)
    output wire        out_last
);
    assign out_valid     = s_axis_tvalid;
    assign s_axis_tready = out_ready;
    assign out_data      = s_axis_tdata[SAMPLE_BITS-1:0];
    assign out_eol       = s_axis_tdata[16];
    assign out_sof       = s_axis_tdata[17];
    assign out_last      = s_axis_tlast;
endmodule
