// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tmds_rx against a TMDS source: DVI's own encoding, a small raster of
// pixels that say where they are, each lane skewed differently. The
// receiver must lock, bond, and then deliver every pixel of every line of
// every frame as sent; then the cable is pulled, the skews change, and it
// must do so again. The lock times are reported, because they are the
// point.
`timescale 1ps/1ps
module tb;
    // the link: 148.5 MHz, or with LINK74 defined 74.25 MHz, where a bit
    // is some seventeen delay taps and an eye can run into the line's end,
    // or with LINK27 27 MHz, where a bit is longer than the whole line
`ifdef LINK74
    localparam TBIT = 1347, LINK_KHZ = 74250, RANGE = 2;
`elsif LINK27
    localparam TBIT = 3704, LINK_KHZ = 27000, RANGE = 5;
`else
    localparam TBIT = 673, LINK_KHZ = 148500, RANGE = 1;
`endif
    localparam TPIX = 10 * TBIT;
    localparam H_ACT = 64, H_TOT = 256, V_ACT = 8;
    // the frame's lines: short at first; then a frame whose vertical
    // blank -- token after token, with no blank starting in it -- outlasts
    // the receiver's LOST, as a slow frame rate's does
    integer V_TOT = 12;
    localparam HS_BEG = 80, HS_END = 100, VS_BEG = 9, VS_END = 11;

    reg clk_p = 0;
    reg [2:0] d_p = 0;
    reg refclk = 0, rst = 1;
    always #2500 refclk = ~refclk;                 // 200 MHz

    wire pclk, locked, de, hsync, vsync;
    wire [23:0] data;
    wire        bonded, clock_locked, sv_aligned;
    wire [2:0]  aligned;
    wire [14:0] eye;
    wire [11:0] slip;
    wire [7:0]  sv_count;
    wire [4:0]  sv_tap, sv_lane_tap;
    wire [3:0]  sv_slip, sv_lane_slip;
    wire [1:0]  sv_lane;
    // the receiver's account, as one word for the log
    wire [31:0] status = {bonded, clock_locked, aligned, eye, slip};
    tmds_rx #(.LINK_KHZ(LINK_KHZ), .RANGE(RANGE), .TEST(1024),
              .LOST(65536), .SURVEY_HOLD(64)) dut (
        .TMDS_Clk_p(clk_p), .TMDS_Clk_n(~clk_p),
        .TMDS_Data_p(d_p), .TMDS_Data_n(~d_p),
        .refclk(refclk), .rst(rst), .pclk(pclk), .locked(locked),
        .de(de), .hsync(hsync), .vsync(vsync), .data(data),
        .bonded(bonded), .clock_locked(clock_locked), .aligned(aligned),
        .eye(eye), .slip(slip), .survey_count(sv_count),
        .survey_tap(sv_tap), .survey_slip(sv_slip), .survey_lane(sv_lane),
        .survey_lane_tap(sv_lane_tap), .survey_lane_slip(sv_lane_slip),
        .survey_lane_aligned(sv_aligned));

    // ---- the source: DVI 1.0's encoder, one running disparity per lane
    integer disp [0:2];
    function integer ones;
        input [7:0] v;
        integer i;
        begin ones = 0; for (i = 0; i < 8; i = i + 1) ones = ones + v[i]; end
    endfunction
    reg [9:0] enc_out;
    task encode;
        input integer ln;
        input [7:0] d;
        input den, c0, c1;
        reg [8:0] qm;
        integer i, n1, n1q, n0q;
        begin
            if (!den) begin
                disp[ln] = 0;
                case ({c1, c0})
                    2'b00: enc_out = 10'b1101010100;
                    2'b01: enc_out = 10'b0010101011;
                    2'b10: enc_out = 10'b0101010100;
                    default: enc_out = 10'b1010101011;
                endcase
            end else begin
                n1 = ones(d);
                qm[0] = d[0];
                if (n1 > 4 || (n1 == 4 && d[0] == 0)) begin
                    for (i = 1; i < 8; i = i + 1) qm[i] = ~(qm[i-1] ^ d[i]);
                    qm[8] = 0;
                end else begin
                    for (i = 1; i < 8; i = i + 1) qm[i] = qm[i-1] ^ d[i];
                    qm[8] = 1;
                end
                n1q = ones(qm[7:0]); n0q = 8 - n1q;
                if (disp[ln] == 0 || n1q == n0q) begin
                    enc_out = {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
                    disp[ln] = qm[8] ? disp[ln] + n1q - n0q
                                     : disp[ln] + n0q - n1q;
                end else if ((disp[ln] > 0 && n1q > n0q) ||
                             (disp[ln] < 0 && n0q > n1q)) begin
                    enc_out = {1'b1, qm[8], ~qm[7:0]};
                    disp[ln] = disp[ln] + 2 * qm[8] + n0q - n1q;
                end else begin
                    enc_out = {1'b0, qm[8], qm[7:0]};
                    disp[ln] = disp[ln] - 2 * (1 - qm[8]) + n1q - n0q;
                end
            end
        end
    endtask

    // the raster, bit by bit, each lane skewed; `run` stops the cable
    integer skew [0:2];
    integer x = 0, y = 0, frame = 0, j, ln;
    reg run = 1;
    // stray bit errors: one bit of one lane's token flipped every other
    // line, in the blanking, the lane taking turns -- as a link with a
    // little noise misreads one token in a hundred million -- and on the
    // lines between, the last token before a line's pixels, so that lane
    // leaves blanking a word early
    reg strays = 0;
    reg [7:0] px [0:2];
    reg [9:0] w [0:2];
    initial begin
        disp[0] = 0; disp[1] = 0; disp[2] = 0;
        // whole words apart, as well as bits: lane 2 a word and a half
        // behind, so the lanes must be bonded, not just aligned -- and
        // placed so its first bit slip's eye runs into the delay line's
        // first tap, which is no eye to centre on
        skew[0] = 300; skew[1] = 1100; skew[2] = 10890;
    end
    always begin
        if (!run) #(TPIX);
        else begin
            px[0] = x; px[1] = y * 16 + frame % 16; px[2] = px[0] ^ px[1];
            for (ln = 0; ln < 3; ln = ln + 1) begin
                encode(ln, px[ln], x < H_ACT && y < V_ACT,
                       ln == 0 && x >= HS_BEG && x < HS_END,
                       ln == 0 && y >= VS_BEG && y < VS_END);
                w[ln] = enc_out;
            end
            if (strays && x == 150 && y % 2 == 0)
                w[(y / 2) % 3][4] = ~w[(y / 2) % 3][4];
            if (strays && x == H_TOT - 1 && y % 2 == 1 && y + 1 < V_ACT)
                w[(y / 2) % 3][4] = ~w[(y / 2) % 3][4];
            for (j = 0; j < 10; j = j + 1)
                for (ln = 0; ln < 3; ln = ln + 1)
                    d_p[ln] <= #(skew[ln] + j * TBIT) w[ln][j];
            clk_p <= 1'b1;
            clk_p <= #(5 * TBIT) 1'b0;
            #(TPIX);
            x = x + 1;
            if (x == H_TOT) begin
                x = 0; y = y + 1;
                if (y == V_TOT) begin y = 0; frame = frame + 1; end
            end
        end
    end

    // ---- the checker: every pixel, line and frame once locked
    integer errors = 0, frames_ok = 0, px_n = 0, lines = 0;
    integer cycle_frames = 0;
    reg [7:0] cur_v = 0, prev_v = 0;
    reg de_d = 0, vs_d = 0;
    time t_lock = 0;
    always @(posedge pclk) begin
        de_d <= de; vs_d <= vsync;
        if (locked && t_lock == 0) t_lock = $time;
        if (locked) begin
            if (de) begin
                if (!de_d) px_n = 0;
                if (data[23:16] != px_n[7:0] ||
                    data[7:0] != (data[23:16] ^ data[15:8])) begin
                    if (errors < 8)
                        $display("ERROR at %0t: pixel %0d of a line: %h",
                                 $time, px_n, data);
                    errors = errors + 1;
                end
                px_n = px_n + 1;
                cur_v = data[15:8];
            end
            if (!de && de_d) begin
                if (px_n != H_ACT) begin
                    $display("ERROR: a line of %0d pixels", px_n);
                    errors = errors + 1;
                end
                // lines follow one another within a frame: lane 1 is
                // the line times 16, plus the frame
                if (lines > 0 && cur_v != prev_v + 8'd16) begin
                    $display("ERROR: line %h after %h", cur_v, prev_v);
                    errors = errors + 1;
                end
                prev_v = cur_v;
                lines = lines + 1;
            end
            if (vsync && !vs_d) begin
                if (lines == V_ACT) frames_ok = frames_ok + 1;
                else if (cycle_frames > 0) begin
                    $display("ERROR: a frame of %0d lines", lines);
                    errors = errors + 1;
                end
                cycle_frames = cycle_frames + 1;
                lines = 0;
            end
        end else begin
            lines = 0; cycle_frames = 0;
        end
    end

    // each lane's eye, as its aligner settled it: closed on both sides --
    // not running into the delay line's first or last tap -- or wide enough
    // that its middle is safe anyway
    // Each lane must sample at the middle of the eye at the LEAST delay
    // among every slip's eye, as its own map records them: the map read
    // back here and the choice worked out again from it. An eye is a run
    // of taps that saw blanks, three of them misreading nothing, closed
    // both sides or 16 wide; its middle, between two taps, the one toward
    // the edge that misreads less.
    task check_choice;
        input integer ln, tap, slip;
        integer sl, t, lo, w, c, rlo, rw, rc, best_mid, best_slip, mid;
        integer e0, e1, re0, re1;
        reg [7:0] v;
        begin
            best_mid = 99; best_slip = -1;
            for (sl = 0; sl < 10; sl = sl + 1) begin
                w = 0; rw = 0; rc = 0;
                for (t = 0; t <= 32; t = t + 1) begin
                    v = (t == 32) ? 8'd255 : map_at(ln, sl, t);
                    if (v != 255) begin
                        if (rw == 0) begin rlo = t; re0 = v; end
                        re1 = v;
                        rw = rw + 1; rc = rc + (v == 0);
                    end else if (rw != 0) begin
                        if (rc >= 3 && rw > w &&
                            (rw >= 16 || (rlo != 0 && t != 32))) begin
                            w = rw; lo = rlo; c = rc; e0 = re0; e1 = re1;
                        end
                        rw = 0; rc = 0;
                    end
                end
                if (w != 0) begin
                    mid = lo + (w - 1) / 2 + (w % 2 == 0 && e1 < e0);
                    if (mid < best_mid) begin best_mid = mid; best_slip = sl; end
                end
            end
            if (tap != best_mid || slip != best_slip) begin
                $display("ERROR: lane %0d samples slip %0d tap %0d, its map's least-delay eye is slip %0d tap %0d",
                         ln, slip, tap, best_slip, best_mid);
                errors = errors + 1;
            end
        end
    endtask
    function [7:0] map_at;
        input integer ln, sl, t;
        begin
            case (ln)
                0: map_at = dut.lane[0].u_lane.u_align.map[sl * 32 + t];
                1: map_at = dut.lane[1].u_lane.u_align.map[sl * 32 + t];
                default: map_at = dut.lane[2].u_lane.u_align.map[sl * 32 + t];
            endcase
        end
    endfunction
    task check_eyes;
        begin
            check_choice(0, dut.lane[0].u_lane.u_align.tap, dut.lane[0].u_lane.u_align.slips);
            check_choice(1, dut.lane[1].u_lane.u_align.tap, dut.lane[1].u_lane.u_align.slips);
            check_choice(2, dut.lane[2].u_lane.u_align.tap, dut.lane[2].u_lane.u_align.slips);
        end
    endtask
    // The survey must be the maps, entry by entry, and say where each
    // lane samples.
    task check_survey;
        integer k, ln, sl, t;
        begin
            for (k = 0; k < 40; k = k + 1) begin
                #(TPIX * 64 * 7);
                ln = sv_lane; sl = sv_slip; t = sv_tap;
                if (sv_count !== map_at(ln, sl, t) ||
                    sv_lane_tap !== status_tap(ln) ||
                    sv_lane_slip !== slip[4*ln +: 4] || !sv_aligned) begin
                    $display("ERROR: survey count %0d is not lane %0d's map at slip %0d tap %0d (%0d)",
                             sv_count, ln, sl, t, map_at(ln, sl, t));
                    errors = errors + 1;
                end
            end
        end
    endtask
    function [4:0] status_tap;
        input integer ln;
        begin
            case (ln)
                0: status_tap = dut.lane[0].u_lane.u_align.tap;
                1: status_tap = dut.lane[1].u_lane.u_align.tap;
                default: status_tap = dut.lane[2].u_lane.u_align.tap;
            endcase
        end
    endfunction

    time t_start, t_replug;
    integer first_ok, second_ok, third_ok, falls = 0;
    always @(negedge locked) falls = falls + 1;
    initial begin
        #(100000) rst = 0;
        t_start = $time;
        wait (locked);
        #(TPIX * H_TOT * V_TOT * 4);
        first_ok = frames_ok;
        check_eyes;
        check_survey;
        $display("lock after %0d us, %0d frames whole, status %h",
                 (t_lock - t_start) / 1000000, frames_ok, status);
        // the cable pulled, and put back with every lane's skew changed
        run = 0;
        #(50000000);
        if (locked) begin
            $display("ERROR: still locked with the cable out");
            errors = errors + 1;
        end
        skew[0] = 14000; skew[1] = 200; skew[2] = 900;
        t_lock = 0; run = 1; t_replug = $time;
        wait (locked);
        #(TPIX * H_TOT * V_TOT * 4);
        $display("relock after %0d us, %0d frames whole, status %h",
                 (t_lock - t_replug) / 1000000, frames_ok - first_ok, status);
        check_eyes;
        // a long vertical blank: 300 lines of tokens, past LOST
        second_ok = frames_ok;
        V_TOT = 300;
        #(TPIX * H_TOT * 300 * 4);
        $display("long blank: %0d frames whole, status %h",
                 frames_ok - second_ok, status);
        if (!locked) begin
            $display("ERROR: the long blank lost the lock");
            errors = errors + 1;
        end
        // stray errors: the lock and every pixel must survive them
        V_TOT = 12;
        #(TPIX * H_TOT * 12 * 2);
        third_ok = frames_ok; falls = 0; strays = 1;
        #(TPIX * H_TOT * 12 * 8);
        strays = 0;
        $display("stray errors: %0d frames whole, the lock lost %0d times",
                 frames_ok - third_ok, falls);
        if (falls != 0) begin
            $display("ERROR: stray errors dropped the lock");
            errors = errors + 1;
        end
        if (errors == 0 && first_ok >= 3 && frames_ok - first_ok >= 3 &&
            frames_ok - second_ok >= 3 && frames_ok - third_ok >= 6)
            $display("tmds_rx: PASS");
        else $display("tmds_rx: FAIL, %0d errors", errors);
        $finish;
    end
    initial begin #(60000000000); $display("tmds_rx: FAIL, timeout"); $finish; end
endmodule
