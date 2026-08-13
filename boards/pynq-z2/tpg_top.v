// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Port-prover, no block design: PS7 gives FCLK0 (the PS is already
// booted and its clocks run regardless of what the PL contains), an
// MMCM makes 74.25, the TPG paints bars, two rgb2dvi drive BOTH
// HDMI jacks. Whichever jack lights a monitor has working TX pins.
module tpg_top (
    output wire       a_clk_p, a_clk_n,
    output wire [2:0] a_dat_p, a_dat_n,
    output wire       b_clk_p, b_clk_n,
    output wire [2:0] b_dat_p, b_dat_n
);
    wire [3:0] fclk;
    (* DONT_TOUCH = "true" *)
    PS7 ps7_i (.FCLKCLK(fclk));
    wire clk100 = fclk[0];

    wire fb, fbb, pix_raw, pix, locked;
    // ADV with INTERNAL compensation: the input is a fabric net (PS
    // FCLK), not a clock-capable pin, and ZHOLD refuses that diet.
    MMCME2_ADV #(
        .CLKIN1_PERIOD(10.0),
        .CLKFBOUT_MULT_F(37.125),
        .DIVCLK_DIVIDE(5),
        .CLKOUT0_DIVIDE_F(10.0),
        .COMPENSATION("INTERNAL")
    ) mmcm_i (
        .CLKIN1(clk100), .CLKIN2(1'b0), .CLKINSEL(1'b1),
        .CLKFBIN(fbb), .CLKFBOUT(fb),
        .CLKOUT0(pix_raw), .LOCKED(locked),
        .DADDR(7'b0), .DCLK(1'b0), .DEN(1'b0), .DI(16'b0), .DWE(1'b0),
        .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0),
        .PWRDWN(1'b0), .RST(1'b0)
    );
    assign fbb = fb;                 // INTERNAL compensation: direct
    BUFG pixbuf (.I(pix_raw), .O(pix));

    wire        de, hs, vs;
    wire [23:0] data;
    fabric_tpg tpg_i (
        .clk(pix),
        .vid_active_video(de), .vid_data(data),
        .vid_hsync(hs), .vid_vsync(vs)
    );

    rgb2dvi #(
        .kGenerateSerialClk(1'b1),
        .kClkPrimitive("MMCM"),
        .kClkRange(2),
        .kRstActiveHigh(1'b1)
    ) tx_a (
        .TMDS_Clk_p(a_clk_p), .TMDS_Clk_n(a_clk_n),
        .TMDS_Data_p(a_dat_p), .TMDS_Data_n(a_dat_n),
        .aRst(~locked), .aRst_n(locked),
        .vid_pData({data[23:16], data[7:0], data[15:8]}),
        .vid_pVDE(de), .vid_pHSync(hs), .vid_pVSync(vs),
        .PixelClk(pix), .SerialClk(1'b0)
    );
    rgb2dvi #(
        .kGenerateSerialClk(1'b1),
        .kClkPrimitive("MMCM"),
        .kClkRange(2),
        .kRstActiveHigh(1'b1)
    ) tx_b (
        .TMDS_Clk_p(b_clk_p), .TMDS_Clk_n(b_clk_n),
        .TMDS_Data_p(b_dat_p), .TMDS_Data_n(b_dat_n),
        .aRst(~locked), .aRst_n(locked),
        .vid_pData({data[23:16], data[7:0], data[15:8]}),
        .vid_pVDE(de), .vid_pHSync(hs), .vid_pVSync(vs),
        .PixelClk(pix), .SerialClk(1'b0)
    );
endmodule
