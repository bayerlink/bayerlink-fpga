// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Behavioural stand-ins for the 7-series primitives tmds_rx uses, for
// simulating it under iverilog: they model what the receiver relies on,
// not the silicon. In particular the deserialiser's bit slip steps the
// word boundary one bit at a time (silicon's DDR order differs; the
// aligner only needs every boundary reachable), and its eye is a window
// after each data transition in which a sample reads at random -- so
// there are taps that work and taps that do not, as on a cable.
`timescale 1ps/1ps

module IBUFDS (input I, input IB, output O);
    assign O = I;
endmodule

module BUFIO (input I, output O);
    assign O = I;
endmodule

module BUFG (input I, output O);
    assign O = I;
endmodule

module BUFR #(parameter BUFR_DIVIDE = "BYPASS", parameter SIM_DEVICE = "7SERIES")
             (input I, input CE, input CLR, output reg O);
    integer n = 0;
    initial O = 0;
    always @(posedge I or posedge CLR)
        if (CLR) begin n <= 0; O <= 0; end
        else begin
            n <= (n == 4) ? 0 : n + 1;
            if (n == 4) O <= 1; else if (n == 1) O <= 0;
        end
endmodule

module IDELAYCTRL (input REFCLK, input RST, output RDY);
    assign RDY = !RST;
endmodule

module IDELAYE2 #(
    parameter IDELAY_TYPE = "VARIABLE", parameter DELAY_SRC = "IDATAIN",
    parameter IDELAY_VALUE = 0, parameter HIGH_PERFORMANCE_MODE = "TRUE",
    parameter SIGNAL_PATTERN = "DATA", parameter REFCLK_FREQUENCY = 200,
    parameter CINVCTRL_SEL = "FALSE", parameter PIPE_SEL = "FALSE"
) (
    input C, input REGRST, input LD, input CE, input INC, input CINVCTRL,
    input [4:0] CNTVALUEIN, input IDATAIN, input DATAIN, input LDPIPEEN,
    output reg DATAOUT, output [4:0] CNTVALUEOUT
);
    reg [4:0] cnt = IDELAY_VALUE;
    assign CNTVALUEOUT = cnt;
    always @(posedge C)
        if (LD) cnt <= IDELAY_VALUE;
        else if (CE) cnt <= INC ? cnt + 1'b1 : cnt - 1'b1;
    initial DATAOUT = 0;
    always @(IDATAIN) DATAOUT <= #(cnt * 78) IDATAIN;
endmodule

module ISERDESE2 #(
    parameter DATA_RATE = "DDR", parameter DATA_WIDTH = 10,
    parameter INTERFACE_TYPE = "NETWORKING", parameter DYN_CLKDIV_INV_EN = "FALSE",
    parameter DYN_CLK_INV_EN = "FALSE", parameter NUM_CE = 2,
    parameter OFB_USED = "FALSE", parameter IOBDELAY = "IFD",
    parameter SERDES_MODE = "MASTER"
) (
    output reg Q1, output reg Q2, output reg Q3, output reg Q4,
    output reg Q5, output reg Q6, output reg Q7, output reg Q8,
    output reg SHIFTOUT1, output reg SHIFTOUT2,
    input BITSLIP, input CE1, input CE2, input CLK, input CLKB,
    input CLKDIV, input CLKDIVP, input OCLK, input OCLKB,
    input DYNCLKDIVSEL, input DYNCLKSEL, input D, input DDLY, input OFB,
    input RST, input SHIFTIN1, input SHIFTIN2, output O
);
    localparam MASTER = (SERDES_MODE == "MASTER");
    localparam integer WINDOW = 200;    // ps after a transition: unreadable
    assign O = DDLY;
    reg [19:0] sr = 0;                  // sr[0]: the bit received last
    integer slip = 0;
    time last = 0;
    integer seed = 1;
    always @(DDLY) last = $time;
    task sample;
        reg b;
        begin
            b = ($time - last < WINDOW) ? ($random(seed) & 1) : DDLY;
            sr = {sr[18:0], b};
        end
    endtask
    always @(posedge CLK) if (MASTER) sample;
    always @(posedge CLKB) if (MASTER) sample;
    // a picosecond after the edge, so the word never races the bit
    // sampled on the same edge
    always @(posedge CLKDIV) #1
        if (RST) begin
            slip <= 0;
            {Q1, Q2, Q3, Q4, Q5, Q6, Q7, Q8} <= 0;
        end else if (MASTER) begin
            if (BITSLIP) slip <= (slip == 9) ? 0 : slip + 1;
            Q1 <= sr[slip];     Q2 <= sr[slip + 1]; Q3 <= sr[slip + 2];
            Q4 <= sr[slip + 3]; Q5 <= sr[slip + 4]; Q6 <= sr[slip + 5];
            Q7 <= sr[slip + 6]; Q8 <= sr[slip + 7];
            SHIFTOUT1 <= sr[slip + 8]; SHIFTOUT2 <= sr[slip + 9];
        end
    // the slave's Q3 and Q4 are the master's two oldest bits, cascaded
    always @(SHIFTIN1 or SHIFTIN2)
        if (!MASTER) begin Q3 = SHIFTIN1; Q4 = SHIFTIN2; end
endmodule

module MMCME2_ADV #(
    parameter BANDWIDTH = "OPTIMIZED", parameter COMPENSATION = "ZHOLD",
    parameter integer DIVCLK_DIVIDE = 1, parameter real CLKFBOUT_MULT_F = 5.0,
    parameter real CLKFBOUT_PHASE = 0.0, parameter real CLKOUT0_DIVIDE_F = 1.0,
    parameter real CLKOUT0_PHASE = 0.0, parameter real CLKOUT0_DUTY_CYCLE = 0.5,
    parameter real CLKIN1_PERIOD = 6.734, parameter real REF_JITTER1 = 0.010,
    parameter STARTUP_WAIT = "FALSE"
) (
    output CLKFBOUT, output CLKFBOUTB, output reg CLKOUT0, output CLKOUT0B,
    output CLKOUT1, output CLKOUT1B, output CLKOUT2, output CLKOUT2B,
    output CLKOUT3, output CLKOUT3B, output CLKOUT4, output CLKOUT5,
    output CLKOUT6, input CLKFBIN, input CLKIN1, input CLKIN2,
    input CLKINSEL, input [6:0] DADDR, input DCLK, input DEN,
    input [15:0] DI, output [15:0] DO, output DRDY, input DWE, input PSCLK,
    input PSEN, input PSINCDEC, output PSDONE, output reg LOCKED,
    output CLKINSTOPPED, output CLKFBSTOPPED, input PWRDWN, input RST
);
    // the output: CLKFBOUT_MULT_F / CLKOUT0_DIVIDE_F edges a period of the
    // input, the first on the input's own edge -- phase locked
    localparam integer N = CLKFBOUT_MULT_F / CLKOUT0_DIVIDE_F / DIVCLK_DIVIDE;
    assign CLKFBOUT = CLKIN1;
    time t_prev = 0, period = 0;
    integer good = 0, k;
    initial begin CLKOUT0 = 0; LOCKED = 0; end
    always @(posedge CLKIN1) begin
        if (t_prev != 0 && ($time - t_prev) * 100 > period * 98 &&
            ($time - t_prev) * 100 < period * 102) good = good + 1;
        else good = 0;
        if (t_prev != 0) period = $time - t_prev;
        t_prev = $time;
        LOCKED <= !RST && good > 8;
        if (!RST && period != 0)
            for (k = 0; k < N; k = k + 1) begin
                CLKOUT0 <= #(k * period / N) 1'b1;
                CLKOUT0 <= #(k * period / N + period / (2 * N)) 1'b0;
            end
    end
    // an input that stops: no lock
    always @(posedge RST) begin LOCKED <= 0; good = 0; end
    always begin
        #(1000000);
        if (t_prev != 0 && period != 0 && $time - t_prev > 4 * period) begin
            LOCKED <= 0; good = 0;
        end
    end
endmodule
