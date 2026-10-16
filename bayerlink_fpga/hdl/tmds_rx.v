// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tmds_rx -- an HDMI/DVI receiver on a 7-series part: a TMDS link in,
// parallel video out.
//
// The link's own clock is the pixel clock. An MMCM multiplies it by
// five: through a BUFIO that is the deserialisers' bit clock (a bit
// each edge), through a BUFR dividing by five, their word clock. Only an
// MMCM reaches a BUFIO, and a BUFIO is what reaches the I/O at these
// rates. The words are aligned lane by lane (tmds_align), bonded across
// the lanes and decoded (tmds_bond), and handed over to a BUFG copy of
// the pixel clock, which reaches the whole device where the BUFR's
// region does not.
//
// The MMCM's VCO is the link times five times RANGE, which only keeps it
// inside its 600-1200 MHz specification: RANGE 1 for a link of 120-240
// MHz, 2 for 60-120. `locked` is the clock locked AND the lanes bonded:
// the video behind it is the source's.
//
// An MMCM that loses its input does not always lock again by itself, so it
// is reset the moment its lock falls, and a watchdog on the reference
// clock resets one that has stayed unlocked. The input delays' controller
// is reset for 320 ns -- past the 72 ns the part asks -- every time the link
// clock locks, not only at configuration: by then the reference clock it
// calibrates against has certainly settled, whatever order the processor
// set its clocks in, and delays calibrated against a clock still settling
// leave every tap at one place, where no tap and no bit slip finds a word.
module tmds_rx #(
    parameter LINK_KHZ = 148500,
    parameter RANGE = 1,
    parameter REFCLK_MHZ = 200,
    // pixel clocks each delay tap is watched for: tens of lines of blanking
    parameter TEST = 65536,
    parameter LOST = 262144,
    // pixel clocks each entry of `survey` is held: ~110 us at 148.5 MHz
    parameter SURVEY_HOLD = 16384
) (
    input  wire        TMDS_Clk_p,
    input  wire        TMDS_Clk_n,
    input  wire [2:0]  TMDS_Data_p,
    input  wire [2:0]  TMDS_Data_n,
    input  wire        refclk,          // for the input delays: REFCLK_MHZ
    input  wire        rst,             // asynchronous, active high
    output wire        pclk,            // the pixel clock, global
    output wire        locked,
    output reg         de,
    output reg         hsync,
    output reg         vsync,
    output reg  [23:0] data,            // lane 0 [23:16], 1 [15:8], 2 [7:0]
    // what the receiver is doing: the bond, the clock, and per lane (lane
    // 0 lowest) its alignment, its eye's error-free taps and its bit slip
    output wire        bonded,
    output wire        clock_locked,
    output wire [2:0]  aligned,
    output wire [14:0] eye,
    output wire [11:0] slip,
    // what each lane's search saw, one entry at a time (below)
    output reg  [7:0]  survey_count,
    output reg  [4:0]  survey_tap,
    output reg  [3:0]  survey_slip,
    output reg  [1:0]  survey_lane,
    output reg  [4:0]  survey_lane_tap,
    output reg  [3:0]  survey_lane_slip,
    output reg         survey_lane_aligned
);
    // ---- the reference clock's side: the delay controller, the watchdog
    (* ASYNC_REG = "TRUE" *) reg rr0 = 1'b1, rr1 = 1'b1;
    always @(posedge refclk or posedge rst)
        if (rst) begin rr0 <= 1'b1; rr1 <= 1'b1; end
        else begin rr0 <= 1'b0; rr1 <= rr0; end
    wire rrst = rr1;
    wire idly_rdy;
    reg [5:0] dly_rst_n = 6'd63;        // 64 reference clocks: 320 ns
    (* IODELAY_GROUP = "tmds_rx" *)
    IDELAYCTRL u_idelayctrl (.REFCLK(refclk), .RST(dly_rst_n != 0),
                             .RDY(idly_rdy));

    wire mmcm_locked;
    (* ASYNC_REG = "TRUE" *) reg ml0 = 1'b0, ml1 = 1'b0;
    reg [16:0] unlocked_n = 0;          // ~0.65 ms at 200 MHz
    reg        mmcm_rst = 1'b1;
    reg [4:0]  rst_hold = 5'd31;
    reg        ml_d = 1'b0;
    reg        bufr_clr = 1'b1;
    always @(posedge refclk) begin
        ml0 <= mmcm_locked; ml1 <= ml0; ml_d <= ml1;
        // the BUFR divides from the clock's return, CLR pulsed then; and
        // the delays calibrated afresh
        bufr_clr <= ml1 && !ml_d;
        if (rrst || (ml1 && !ml_d)) dly_rst_n <= 6'd63;
        else if (dly_rst_n != 0) dly_rst_n <= dly_rst_n - 1'b1;
        if (rrst || rst_hold != 0) begin
            mmcm_rst <= 1'b1; unlocked_n <= 0;
            rst_hold <= rrst ? 5'd31 : rst_hold - 1'b1;
        end else begin
            mmcm_rst <= 1'b0;
            if (ml_d && !ml1) rst_hold <= 5'd31;        // lock lost: reset
            if (ml1) unlocked_n <= 0;
            else if (&unlocked_n) rst_hold <= 5'd31;   // reset it, and wait
            else unlocked_n <= unlocked_n + 1'b1;
        end
    end

    // ---- the clocks, made from the link's
    wire clk_in, clkfb, clk5x;
    IBUFDS u_clk_ibuf (.I(TMDS_Clk_p), .IB(TMDS_Clk_n), .O(clk_in));
    MMCME2_ADV #(
        .BANDWIDTH("OPTIMIZED"), .COMPENSATION("ZHOLD"),
        .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(5.0 * RANGE),
        .CLKFBOUT_PHASE(0.0), .CLKOUT0_DIVIDE_F(1.0 * RANGE),
        .CLKOUT0_PHASE(0.0), .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKIN1_PERIOD(1.0e6 / LINK_KHZ), .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKFBOUT(clkfb), .CLKFBOUTB(), .CLKOUT0(clk5x), .CLKOUT0B(),
        .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(),
        .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBIN(clkfb), .CLKIN1(clk_in), .CLKIN2(1'b0), .CLKINSEL(1'b1),
        .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DO(),
        .DRDY(), .DWE(1'b0), .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0),
        .PSDONE(), .LOCKED(mmcm_locked), .CLKINSTOPPED(),
        .CLKFBSTOPPED(), .PWRDWN(1'b0), .RST(mmcm_rst));
    wire sclk, pclk_r;
    BUFIO u_bufio (.I(clk5x), .O(sclk));
    BUFR #(.BUFR_DIVIDE("5"), .SIM_DEVICE("7SERIES")) u_bufr (
        .I(clk5x), .CE(1'b1), .CLR(bufr_clr), .O(pclk_r));
    BUFG u_bufg (.I(pclk_r), .O(pclk));

    // ---- the pixel clock's side: held in reset while the clock or the
    // delays are not to be trusted, let go on an edge
    wire arst = rst || !mmcm_locked || !idly_rdy;
    (* ASYNC_REG = "TRUE" *) reg pr0 = 1'b1, pr1 = 1'b1;
    always @(posedge pclk_r or posedge arst)
        if (arst) begin pr0 <= 1'b1; pr1 <= 1'b1; end
        else begin pr0 <= 1'b0; pr1 <= pr0; end
    wire prst = pr1;

    // a 10-bit word has ten places to begin: the bit slips there are
    localparam SLIPS = 10;
    wire [29:0] words;
    wire [14:0] taps;
    wire [23:0] map_q;
    reg  [1:0]  sv_lane = 0;
    reg  [3:0]  sv_slip = 0;
    reg  [4:0]  sv_tap = 0;
    genvar i;
    generate for (i = 0; i < 3; i = i + 1) begin : lane
        wire [3:0] s;
        tmds_rx_lane #(.REFCLK_MHZ(REFCLK_MHZ), .TEST(TEST),
                       .LOST(LOST), .SLIPS(SLIPS)) u_lane (
            .data_p(TMDS_Data_p[i]), .data_n(TMDS_Data_n[i]),
            .sclk(sclk), .pclk(pclk_r), .rst(prst),
            .word(words[10*i +: 10]), .aligned(aligned[i]),
            .tap(taps[5*i +: 5]), .eye(eye[5*i +: 5]), .slips(s),
            .map_addr({sv_slip, sv_tap}), .map_q(map_q[8*i +: 8]));
        assign slip[4*i +: 4] = s;
    end endgenerate

    wire        delivering, b_de, b_hs, b_vs;
    wire [23:0] b_data;
    tmds_bond u_bond (
        .clk(pclk_r), .rst(prst), .words(words), .aligned(aligned),
        .bonded(bonded), .delivering(delivering), .de(b_de), .hsync(b_hs), .vsync(b_vs),
        .data(b_data));

    // into the global copy of the same clock
    always @(posedge pclk) begin
        de <= b_de; hsync <= b_hs; vsync <= b_vs; data <= b_data;
    end
    // NOT a register on the pixel clock: that clock stops with the cable,
    // and a lock held in its last state would hide the loss from whoever
    // watches it. The clock manager's own lock falls at once.
    assign locked = mmcm_locked && delivering;
    assign clock_locked = mmcm_locked;

    // The survey: every lane's map, an entry at a time, each held for
    // SURVEY_HOLD pixel clocks so a reader on another clock sees it whole
    // (read it twice, alike); the whole of it in under a second. Each entry
    // says where it is from -- lane, slip, tap -- and where its lane
    // samples; its count is the tap's misread tokens at that slip, 255 for
    // no blank seen.
    reg [13:0] sv_n = 0;
    always @(posedge pclk_r) begin
        sv_n <= (sv_n == SURVEY_HOLD - 1) ? 14'd0 : sv_n + 1'b1;
        if (sv_n == SURVEY_HOLD - 1) begin
            sv_tap <= sv_tap + 1'b1;
            if (&sv_tap) begin
                sv_slip <= (sv_slip == SLIPS - 1) ? 4'd0 : sv_slip + 1'b1;
                if (sv_slip == SLIPS - 1)
                    sv_lane <= (sv_lane == 2'd2) ? 2'd0 : sv_lane + 1'b1;
            end
        end
        if (sv_n == 14'd3) begin        // the map read, the address settled
            survey_count <= map_q[8*sv_lane +: 8];
            survey_tap <= sv_tap; survey_slip <= sv_slip;
            survey_lane <= sv_lane;
            survey_lane_tap <= taps[5*sv_lane +: 5];
            survey_lane_slip <= slip[4*sv_lane +: 4];
            survey_lane_aligned <= aligned[sv_lane];
        end
    end
endmodule
