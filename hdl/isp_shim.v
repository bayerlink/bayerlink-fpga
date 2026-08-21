// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// This board's shim around the revela design pack: the header latch and
// the AXI4-Lite port carried to the boundary, nothing else. The pack
// itself (hdl/generated/revela_isp_core.v) is generated and verified by
// revela from gen/pipeline.json; this file is hand-shaped board glue,
// like tee_shim.v. The literals below -- the sample width, the reset
// geometry, the core's name -- restate that design's facts, so the two
// files change together or not at all.
//
// Parameters are LIVE: written over the register map, landing in a
// shadow, committed at the frame boundary, so a frame is processed with
// one coherent set or none of it. NEUTRAL at power-on -- calibration is
// a sensor fact, restored over the cable by whoever holds the sensor's
// profile.
module revela_isp (
    input  wire        clk,
    input  wire        rst,
    // The header's facts, straight from the receiver, latched as each
    // frame's SOF enters so a change lands on a frame boundary. NOT the
    // depth: the receiver has already aligned samples to this build's,
    // so hdr_bits is carried for software only.
    input  wire [15:0] hdr_width,
    input  wire [15:0] hdr_height,
    input  wire [1:0]  hdr_phase,
    input  wire [4:0]  hdr_bits,
    // Every coefficient, and every identity word, behind this port. The
    // interface is DECLARED, not left to be inferred from port names: an
    // inferred one is a guess, and a guess about an AXI interface cost a
    // day on 2026-08-17.
    //
    // ON ITS OWN CLOCK. `clk` above is recovered from the HDMI link, so
    // it STOPS whenever the link is down -- including just after this
    // bitstream is loaded. AXI has no timeout, so a slave with no clock
    // never answers and the processor waits for it forever. That hung
    // this board on 2026-08-17 and needed the power pulled. The
    // association below is what tells the block design which clock this
    // port runs on, and naming the wrong one is exactly how it ended up
    // on a clock that can stop.
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    input  wire        s_axi_aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    input  wire        s_axi_aresetn,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    input  wire [14:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire        s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire        s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire        s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire        s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire        s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire        s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [14:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire        s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire        s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire        s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire        s_axi_rready,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [9:0]  in_data,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_last,
    output wire        out_valid,
    input  wire        out_ready,
    output wire [29:0] out_data,
    output wire        out_sof,
    output wire        out_eol,
    output wire        out_last
);
    reg [15:0] ctx_w = 16'd1920;
    reg [15:0] ctx_h = 16'd1080;
    reg [1:0]  ctx_ph = 2'd2;
    reg [4:0]  ctx_bd = 5'd10;
    always @(posedge clk)
        if (in_valid && in_ready && in_sof) begin
            ctx_w  <= hdr_width;
            ctx_h  <= hdr_height;
            ctx_ph <= hdr_phase;
            ctx_bd <= hdr_bits;
        end
    revela_isp_core_ctrl core (
        .clk(clk), .rst(rst),
        .s_axil_aclk(s_axi_aclk), .s_axil_aresetn(s_axi_aresetn),
        .s_axil_awaddr(s_axi_awaddr), .s_axil_awvalid(s_axi_awvalid),
        .s_axil_awready(s_axi_awready),
        .s_axil_wdata(s_axi_wdata), .s_axil_wstrb(s_axi_wstrb),
        .s_axil_wvalid(s_axi_wvalid), .s_axil_wready(s_axi_wready),
        .s_axil_bresp(s_axi_bresp), .s_axil_bvalid(s_axi_bvalid),
        .s_axil_bready(s_axi_bready),
        .s_axil_araddr(s_axi_araddr), .s_axil_arvalid(s_axi_arvalid),
        .s_axil_arready(s_axi_arready),
        .s_axil_rdata(s_axi_rdata), .s_axil_rresp(s_axi_rresp),
        .s_axil_rvalid(s_axi_rvalid), .s_axil_rready(s_axi_rready),
        .ctx_width(ctx_w), .ctx_height(ctx_h),
        .ctx_bayer_phase(ctx_ph), .ctx_bit_depth(ctx_bd),
        .isp_in_valid(in_valid), .isp_in_ready(in_ready),
        .isp_in_data(in_data),
        .isp_in_sof(in_sof), .isp_in_eol(in_eol), .isp_in_last(in_last),
        .isp_out_valid(out_valid), .isp_out_ready(out_ready),
        .isp_out_data(out_data),
        .isp_out_sof(out_sof), .isp_out_eol(out_eol),
        .isp_out_last(out_last)
    );
endmodule
