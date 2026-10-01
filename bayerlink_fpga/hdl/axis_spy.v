// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Pass-through AXIS spy: wires straight through, remembers what it saw.
// The status nibble answers the only bring-up question that matters:
// who is refusing -- the producer (no valid) or the consumer (no ready).
module axis_spy #(
    parameter DW = 16
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          s_axis_tvalid,
    output wire          s_axis_tready,
    input  wire [DW-1:0] s_axis_tdata,
    input  wire [DW/8-1:0] s_axis_tkeep,
    input  wire          s_axis_tlast,
    output wire          m_axis_tvalid,
    input  wire          m_axis_tready,
    output wire [DW-1:0] m_axis_tdata,
    output wire [DW/8-1:0] m_axis_tkeep,
    output wire          m_axis_tlast,
    output wire [15:0]   status
);
    assign m_axis_tvalid = s_axis_tvalid;
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tkeep  = s_axis_tkeep;
    assign m_axis_tlast  = s_axis_tlast;

    reg v_seen, r_seen, beat_seen, last_seen;
    reg [11:0] beats;
    always @(posedge clk) begin
        if (rst) begin
            v_seen <= 0; r_seen <= 0; beat_seen <= 0; last_seen <= 0;
            beats <= 0;
        end else begin
            if (s_axis_tvalid) v_seen <= 1;
            if (m_axis_tready) r_seen <= 1;
            if (s_axis_tvalid && m_axis_tready) begin
                beat_seen <= 1;
                beats <= beats + 1;
            end
            if (s_axis_tvalid && m_axis_tready && s_axis_tlast) last_seen <= 1;
        end
    end
    assign status = {beats, last_seen, beat_seen, r_seen, v_seen};
endmodule
