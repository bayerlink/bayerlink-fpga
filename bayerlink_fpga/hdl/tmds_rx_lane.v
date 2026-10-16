// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tmds_rx_lane -- one TMDS data lane into 10-bit words, aligned.
//
// The pin through a variable delay (IDELAYE2) into a 1:10 deserialiser
// (two ISERDESE2 in DDR networking mode, master and slave), clocked by
// the five-times serial clock and the pixel clock both made from the
// link's own clock; tmds_align sets the delay and the bit slip. TMDS
// sends a word's bit 0 first, and the deserialiser puts the bit received
// last on the master's Q1 and the first on the slave's Q4, so the word
// is read from Q4 of the slave down to Q1 of the master.
module tmds_rx_lane #(
    parameter REFCLK_MHZ = 200,
    parameter TEST = 65536,
    parameter LOST = 262144,
    parameter SLIPS = 10
) (
    input  wire       data_p,
    input  wire       data_n,
    input  wire       sclk,             // five times the pixel clock, BUFIO
    input  wire       pclk,             // the pixel clock, BUFR
    input  wire       rst,              // in pclk
    output reg  [9:0] word,             // aligned when `aligned`
    output wire       aligned,
    output wire [4:0] tap,
    output wire [4:0] eye,
    output wire [3:0] slips,
    input  wire [8:0] map_addr,         // tmds_align's map: {slip, tap}
    output wire [7:0] map_q
);
    wire data_i, data_d;
    IBUFDS u_ibuf (.I(data_p), .IB(data_n), .O(data_i));

    wire idly_ld, idly_ce, bitslip;
    (* IODELAY_GROUP = "tmds_rx" *)
    IDELAYE2 #(
        .IDELAY_TYPE("VARIABLE"), .DELAY_SRC("IDATAIN"),
        .IDELAY_VALUE(0), .HIGH_PERFORMANCE_MODE("TRUE"),
        .SIGNAL_PATTERN("DATA"), .REFCLK_FREQUENCY(REFCLK_MHZ),
        .CINVCTRL_SEL("FALSE"), .PIPE_SEL("FALSE")
    ) u_delay (
        .C(pclk), .REGRST(1'b0), .LD(idly_ld), .CE(idly_ce), .INC(1'b1),
        .CINVCTRL(1'b0), .CNTVALUEIN(5'd0), .IDATAIN(data_i),
        .DATAIN(1'b0), .LDPIPEEN(1'b0), .DATAOUT(data_d),
        .CNTVALUEOUT());

    wire [7:0] qm;                      // master Q1..Q8
    wire [1:0] qs;                      // slave Q3, Q4
    wire shift1, shift2;
    ISERDESE2 #(
        .DATA_RATE("DDR"), .DATA_WIDTH(10), .INTERFACE_TYPE("NETWORKING"),
        .DYN_CLKDIV_INV_EN("FALSE"), .DYN_CLK_INV_EN("FALSE"),
        .NUM_CE(2), .OFB_USED("FALSE"), .IOBDELAY("IFD"),
        .SERDES_MODE("MASTER")
    ) u_master (
        .Q1(qm[0]), .Q2(qm[1]), .Q3(qm[2]), .Q4(qm[3]),
        .Q5(qm[4]), .Q6(qm[5]), .Q7(qm[6]), .Q8(qm[7]),
        .SHIFTOUT1(shift1), .SHIFTOUT2(shift2),
        .BITSLIP(bitslip), .CE1(1'b1), .CE2(1'b1),
        .CLK(sclk), .CLKB(~sclk), .CLKDIV(pclk), .CLKDIVP(1'b0),
        .OCLK(1'b0), .OCLKB(1'b0), .DYNCLKDIVSEL(1'b0), .DYNCLKSEL(1'b0),
        .D(1'b0), .DDLY(data_d), .OFB(1'b0), .RST(rst),
        .SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .O());
    ISERDESE2 #(
        .DATA_RATE("DDR"), .DATA_WIDTH(10), .INTERFACE_TYPE("NETWORKING"),
        .DYN_CLKDIV_INV_EN("FALSE"), .DYN_CLK_INV_EN("FALSE"),
        .NUM_CE(2), .OFB_USED("FALSE"), .IOBDELAY("IFD"),
        .SERDES_MODE("SLAVE")
    ) u_slave (
        .Q1(), .Q2(), .Q3(qs[0]), .Q4(qs[1]), .Q5(), .Q6(), .Q7(), .Q8(),
        .SHIFTOUT1(), .SHIFTOUT2(),
        .BITSLIP(bitslip), .CE1(1'b1), .CE2(1'b1),
        .CLK(sclk), .CLKB(~sclk), .CLKDIV(pclk), .CLKDIVP(1'b0),
        .OCLK(1'b0), .OCLKB(1'b0), .DYNCLKDIVSEL(1'b0), .DYNCLKSEL(1'b0),
        .D(1'b0), .DDLY(1'b0), .OFB(1'b0), .RST(rst),
        .SHIFTIN1(shift1), .SHIFTIN2(shift2), .O());

    // first bit received first: slave Q4, Q3, then master Q8 .. Q1
    always @(posedge pclk)
        word <= {qm[0], qm[1], qm[2], qm[3], qm[4], qm[5], qm[6], qm[7],
                 qs[0], qs[1]};

    tmds_align #(.TEST(TEST), .LOST(LOST), .SLIPS(SLIPS)) u_align (
        .clk(pclk), .rst(rst), .word(word),
        .idly_ld(idly_ld), .idly_ce(idly_ce), .bitslip(bitslip),
        .aligned(aligned), .tap(tap), .eye(eye), .slips(slips),
        .map_addr(map_addr), .map_q(map_q));
endmodule
