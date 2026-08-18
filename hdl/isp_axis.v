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

    // A FENCE, not a wire -- because this module's reset and its
    // consumer's are different laws. The ISP island resets when the
    // LINK drops; the VDMA on the far side keeps its clock and its
    // reset and remembers every promise made to it. The combinational
    // version passed tvalid straight through, so the island reset
    // CHOPPED a transfer mid-beat -- an AXI-Stream protocol violation
    // -- and a DataMover holding a violated handshake wedges, taking
    // its register interface with it and, since AXI has no timeout,
    // the first software access after that, and the processor. Pulled
    // cable, frozen TV, dead board: measured on 2026-08-18.
    //
    // So the output is a register, and reset does NOT clear it: a beat
    // already offered stays offered, stable, until the sink takes it.
    // Reset only stops NEW beats entering. The sink sees a clean
    // starve -- at worst the restartable frame-count halt, never a
    // violation. Power-on state comes from the initial values (GSR),
    // which is exactly the one moment nothing can be in flight.
    reg        v_q = 1'b0;
    reg [31:0] d_q = 32'h0;
    reg        u_q = 1'b0, l_q = 1'b0;

    assign m_axis_tvalid = v_q;
    assign m_axis_tdata  = d_q;
    assign m_axis_tuser  = u_q;
    assign m_axis_tlast  = l_q;
    assign m_axis_tkeep  = 4'b1111;
    assign in_ready      = !rst && (!v_q || m_axis_tready);

    always @(posedge clk) begin
        if (v_q && m_axis_tready)
            v_q <= 1'b0;
        if (!rst && in_valid && (!v_q || m_axis_tready)) begin
            v_q <= 1'b1;
            d_q <= {8'h00, r8, b8, g8};
            u_q <= in_sof;
            l_q <= in_eol;
        end
    end
endmodule
