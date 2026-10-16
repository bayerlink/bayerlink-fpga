// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tmds_bond -- three aligned TMDS lanes into one stream of pixels.
//
// Each lane found its own word boundary, so the lanes may be a few words
// apart: the cable's skew, and which bit slip each settled on. The words
// that line up are the ones a source sent together, and every line says
// which those are: blanking ends on all three lanes at once. So the
// moment each lane's blanking ends is measured, and each lane is delayed
// by what it leads the last one by; then the lanes are watched, and held
// bonded while their blanking keeps ending together.
//
// Held, not re-measured at the first doubt. A link misreads a control
// token now and then -- one in a hundred million is a picture no one can
// fault -- and a misread token is a lone word of "data" on one lane: an
// edge the other lanes do not have. Blanking is most of a link's words,
// a hundred million of them a second, so a bond that let go at every
// such edge would let go every second, and the picture with it. So the
// bond is let go only when the lanes disagree LOSE times running, with no
// line ending together between -- as lanes whose skew has really changed
// do, every line. And a line's data is what the lanes say by majority:
// it begins where two of the three leave blanking together and ends where
// two return to it, so one lane's misread neither makes a pixel in the
// blanking nor loses a line, or cuts one short, in the picture.
//
// Then the words are decoded, TMDS's 10 bits into 8, and the syncs read
// from lane 0's control tokens, as DVI carries them.
module tmds_bond #(
    parameter MAX_SKEW = 7,             // words a lane may lead by
    parameter GOOD = 4,                 // lines together that are bonded
    parameter LOSE = 4                  // disagreements running: not
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [29:0] words,           // lane 2, 1, 0
    input  wire [2:0]  aligned,
    output reg         bonded,
    output wire        delivering,     // bonded, from a line's start
    output reg         de,
    output reg         hsync,
    output reg         vsync,
    output reg  [23:0] data             // lane 0 [23:16], 1 [15:8], 2 [7:0]
);
    function token;
        input [9:0] w;
        token = (w == 10'b1101010100) || (w == 10'b0010101011) ||
                (w == 10'b0101010100) || (w == 10'b1010101011);
    endfunction
    function [7:0] tmds_decode;
        input [9:0] w;
        reg [7:0] d;
        integer i;
        begin
            d = w[9] ? ~w[7:0] : w[7:0];
            tmds_decode[0] = d[0];
            for (i = 1; i < 8; i = i + 1)
                tmds_decode[i] = w[8] ? (d[i] ^ d[i-1]) : ~(d[i] ^ d[i-1]);
        end
    endfunction

    // each lane's recent words, newest at [0], and the delay it takes
    reg [9:0] hist0 [0:MAX_SKEW];
    reg [9:0] hist1 [0:MAX_SKEW];
    reg [9:0] hist2 [0:MAX_SKEW];
    reg [2:0] dly0, dly1, dly2;
    integer k;
    always @(posedge clk) begin
        hist0[0] <= words[9:0];
        hist1[0] <= words[19:10];
        hist2[0] <= words[29:20];
        for (k = 1; k <= MAX_SKEW; k = k + 1) begin
            hist0[k] <= hist0[k-1]; hist1[k] <= hist1[k-1];
            hist2[k] <= hist2[k-1];
        end
    end
    wire [9:0] l0 = hist0[dly0], l1 = hist1[dly1], l2 = hist2[dly2];

    // where blanking ends: data now, a token the word before
    reg [9:0] r0, r1, r2;               // each lane's raw word before
    always @(posedge clk) begin
        r0 <= hist0[0]; r1 <= hist1[0]; r2 <= hist2[0];
    end
    wire e0 = !token(hist0[0]) && token(r0);
    wire e1 = !token(hist1[0]) && token(r1);
    wire e2 = !token(hist2[0]) && token(r2);
    // ...and on the delayed lanes, where they should coincide
    reg [9:0] p0, p1, p2;
    always @(posedge clk) begin p0 <= l0; p1 <= l1; p2 <= l2; end
    wire d0 = !token(l0) && token(p0);
    wire d1 = !token(l1) && token(p1);
    wire d2 = !token(l2) && token(p2);

    localparam B_IDLE = 2'd0, B_MEASURE = 2'd1, B_CHECK = 2'd2;
    reg [1:0] st;
    reg [3:0] t, t0, t1, t2;            // when each lane's blanking ended
    reg [2:0] seen;
    reg [3:0] good, bad;
    wire [3:0] tmax = (t0 > t1 ? (t0 > t2 ? t0 : t2) : (t1 > t2 ? t1 : t2));

    always @(posedge clk) begin
        if (rst || aligned != 3'b111) begin
            st <= B_IDLE; bonded <= 1'b0; seen <= 0; good <= 0; bad <= 0;
            dly0 <= 0; dly1 <= 0; dly2 <= 0;
        end else case (st)
            B_IDLE: if (e0 || e1 || e2) begin
                // the first lane's edge opens a window MAX_SKEW wide
                seen <= {e2, e1, e0}; t <= 1;
                t0 <= 0; t1 <= 0; t2 <= 0;
                st <= B_MEASURE;
            end
            B_MEASURE: begin
                t <= t + 1'b1;
                if (e0 && !seen[0]) begin t0 <= t; seen[0] <= 1'b1; end
                if (e1 && !seen[1]) begin t1 <= t; seen[1] <= 1'b1; end
                if (e2 && !seen[2]) begin t2 <= t; seen[2] <= 1'b1; end
                if (seen == 3'b111) begin
                    dly0 <= tmax - t0; dly1 <= tmax - t1; dly2 <= tmax - t2;
                    good <= 0; bad <= 0; st <= B_CHECK;
                end else if (t == MAX_SKEW) begin
                    st <= B_IDLE;   // a lane's edge did not come: again
                end
            end
            B_CHECK: begin
                if (d0 || d1 || d2) begin
                    if (d0 && d1 && d2) begin
                        bad <= 0;
                        if (good != GOOD) good <= good + 1'b1;
                        else bonded <= 1'b1;
                    end else if (bonded && bad != LOSE - 1) begin
                        bad <= bad + 1'b1;  // a stray, until it is not
                    end else begin
                        bonded <= 1'b0; st <= B_IDLE;
                    end
                end
            end
            default: st <= B_IDLE;
        endcase
    end

    // the pixels, the data enable and the syncs, from the bonded lanes.
    // The bond is declared at the edge it measures, mid-line: the data
    // enable waits for the next blanking, so no line is delivered short.
    // Data begins where two lanes leave blanking together, and ends where
    // two return to it.
    reg in_force = 1'b0;
    reg in_data = 1'b0;
    wire k0 = token(l0), k1 = token(l1), k2 = token(l2);
    wire data_next = ((d0 && d1) || (d0 && d2) || (d1 && d2)) ? 1'b1 :
                     ((k0 && k1) || (k0 && k2) || (k1 && k2)) ? 1'b0 : in_data;
    always @(posedge clk) begin
        if (!bonded) in_force <= 1'b0;
        else if (token(l0)) in_force <= 1'b1;
        in_data <= data_next;
        de <= in_force && data_next;
        if (token(l0)) begin
            hsync <= (l0 == 10'b0010101011) || (l0 == 10'b1010101011);
            vsync <= (l0 == 10'b0101010100) || (l0 == 10'b1010101011);
        end
        data <= {tmds_decode(l0), tmds_decode(l1), tmds_decode(l2)};
    end
    assign delivering = in_force;
endmodule
