// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tmds_align -- find where one TMDS lane's bits are worth sampling, and
// which ten of them are a word.
//
// A lane is a stream of 10-bit words a bit at a time, and the receiver
// has two knobs: the input delay (IDELAYE2, TAPS steps) moves where in
// the bit the deserialiser samples, and the bit slip moves which ten
// bits it calls a word. Only one combination sees the words the source
// sent, and it is recognised by the control tokens: blanking is a run of
// them, four distinct 10-bit patterns no data word can produce in a row.
//
// So every tap is TESTED: the tap is set, the lane settles, and it is
// watched for TEST pixel clocks -- tens of lines of blanking -- for two
// things: whether it saw a whole blank at all (a run of CTL_COUNT tokens),
// and how many tokens it misread (a word or two that is not a token,
// between tokens). A link blanks every line, so TEST need only hold a few
// lines to see a blank; it holds tens to count errors.
//
// A slip's eye is the run of taps that SEE blanks, and the lane samples
// at its middle. Its edges are where blanks stop being seen at all: the
// walls of the bit, steep and the same on both sides. The taps that
// misread nothing lie inside it, but they say less about where the middle
// is than it seems: an eye closes gently on one side and abruptly on the
// other -- inter-symbol interference does that -- so the error-free taps
// sit off the middle, toward the abrupt side, and their own middle is
// a tap from where the data is read best. Measured on a link at a bit
// period of 8.5 taps, the middle of the error-free taps misread data words
// that every token around them passed, and the middle between the walls
// misread none. The error-free taps only qualify an eye: MIN_EYE of them,
// or it is no eye. An eye an even number of taps wide has its middle
// between two; the lane takes the one toward the edge that misreads less,
// where the eye is wider.
//
// But only an eye closed on BOTH sides has a middle that can be found:
// one running into the first or the last tap is cut short by the delay
// line's range, not by the bit, and the middle of what is left lies near
// the bit's edge. So an eye touching either end counts only when it is
// ENOUGH taps wide that its middle is safe anyway; otherwise that slip has
// no eye. A slip moves the eye a bit period along the line, so another
// slip's eye lies inside it.
//
// Every bit slip is scanned, and of the eyes found the lane takes the one
// at the LEAST delay. A slip's eye is a bit period from the next, so the
// lane sees the same eyes whatever bit the search began on, and taking
// them in one fixed order lands every lock on the same tap; the delay line
// also adds jitter with each tap it passes the data through, which the
// first eye is spared most of. The search costs SLIPS scans, every time.
//
// What each tap showed at each slip is kept: `map` reads it, a tap's
// misread tokens (saturating at 254) or 255 where it saw no blank at all
// -- the lane's eye, measured, for whoever wants to see the margin.
//
// Aligned, the lane keeps watching: tokens stop arriving for LOST pixel
// clocks and the alignment is taken to be gone, and searched for again.
module tmds_align #(
    parameter TAPS = 32,                // IDELAYE2 taps: 0..TAPS-1
    parameter TAP_BITS = 5,
    parameter CTL_COUNT = 128,          // tokens in a row that are a blank
    parameter TEST = 65536,             // pixel clocks each tap is watched
    parameter LOST = 262144,            // pixel clocks with no blank: lost
    parameter SLIPS = 10,               // bit slips before the scan repeats
    parameter MIN_EYE = 3,              // open taps that are an eye
    parameter ENOUGH = 16               // ...even cut off at the line's end
) (
    input  wire                clk,     // the lane's pixel clock
    input  wire                rst,
    input  wire [9:0]          word,    // the deserialiser's word
    // the delay line: load tap 0, then step it up
    output reg                 idly_ld,
    output reg                 idly_ce,
    output reg                 bitslip,
    output reg                 aligned,
    output reg [TAP_BITS-1:0]  tap,     // the tap the lane samples at
    output reg [TAP_BITS-1:0]  eye,     // its eye's taps that misread nothing
    output reg [3:0]           slips,   // the bit slip: 0..SLIPS-1
    // what the search saw: {slip, tap} in, its count out a clock later
    input  wire [8:0]          map_addr,
    output reg  [7:0]          map_q
);
    // the four control tokens: what blanking is made of
    wire token = (word == 10'b1101010100) || (word == 10'b0010101011) ||
                 (word == 10'b0101010100) || (word == 10'b1010101011);

    localparam S_LOAD = 3'd0, S_STEP = 3'd1, S_SETTLE = 3'd2,
               S_TEST = 3'd3, S_NEXT = 3'd4, S_CENTRE = 3'd5,
               S_SLIP = 3'd6, S_HOLD = 3'd7;
    reg [2:0]  st;
    reg [TAP_BITS-1:0] at, goal;        // the tap set, the tap wanted
    reg [17:0] wait_n;                  // pixel clocks in this state
    reg [7:0]  run_n;                   // tokens in a row
    reg        open;                    // this tap saw a blank...
    reg [7:0]  errs;                    // ...and misread this many tokens
    reg        tk1, tk2, tk3;           // the words before: tokens?
    // the eye: the widest run of taps that saw blanks at this bit slip,
    // and how many of them misread nothing -- a bit longer than the delay
    // line sees blanks at every tap, so a run counts to TAPS itself
    reg [TAP_BITS-1:0] run_lo, best_lo;
    reg [TAP_BITS:0]   run_w, run_c, best_w, best_c;
    reg [7:0]  run_e0, run_e1, best_e0, best_e1;    // its edges' misreads
    reg        in_run;
    wire       clean = open && errs == 0;
    // the scan: slips scanned so far, and the least-delay eye among them
    reg [3:0]  scan_n, todo;
    reg        cand_ok;
    reg [3:0]  cand_slip;
    reg [TAP_BITS-1:0] cand_mid, cand_w;
    // a run is an eye if enough of it misreads nothing, and it is closed
    // both sides or ENOUGH wide: one still open at the last tap is cut
    wire run_eye = run_c >= MIN_EYE && (run_lo != 0 || run_w >= ENOUGH);
    wire top = in_run && run_w >= ENOUGH && run_c >= MIN_EYE &&
               run_w > best_w;
    wire [TAP_BITS-1:0] e_lo = top ? run_lo : best_lo;
    wire [TAP_BITS:0]   e_w  = top ? run_w : best_w;
    wire [TAP_BITS:0]   e_c  = top ? run_c : best_c;
    wire [7:0] e_e0 = top ? run_e0 : best_e0;
    wire [7:0] e_e1 = top ? run_e1 : best_e1;
    // ...taken over three clocks, a pixel clock being too short for it
    reg        q_ok;
    reg [TAP_BITS-1:0] q_lo, q_mid, q_eye;
    reg [TAP_BITS:0]   q_w;
    reg [7:0]  q_e0, q_e1;

    reg [7:0] map [0:511];
    always @(posedge clk) map_q <= map[map_addr];

    // A blank seen: the run of tokens CTL_COUNT long, begun after data.
    wire blank_done = token && (run_n == CTL_COUNT - 1);

    always @(posedge clk) begin
        idly_ld <= 1'b0; idly_ce <= 1'b0; bitslip <= 1'b0;
        tk1 <= token; tk2 <= tk1; tk3 <= tk2;
        // tokens counted only while a tap is under test, so a run that
        // began at the tap before is not credited to this one
        if (st != S_TEST || !token) run_n <= 0;
        else if (run_n != 8'hFF) run_n <= run_n + 1'b1;
        if (rst) begin
            st <= S_LOAD; at <= 0; goal <= 0; wait_n <= 0;
            aligned <= 1'b0; tap <= 0; eye <= 0; slips <= 0;
            in_run <= 1'b0; run_lo <= 0; run_w <= 0;
            best_lo <= 0; best_w <= 0; best_c <= 0; run_c <= 0;
            open <= 1'b0; errs <= 0;
            scan_n <= 0; todo <= 0; cand_ok <= 1'b0;
            cand_slip <= 0; cand_mid <= 0; cand_w <= 0;
        end else case (st)
            // the delay line to tap 0, then up to the tap wanted
            S_LOAD: begin
                idly_ld <= 1'b1; at <= 0; wait_n <= 0; st <= S_STEP;
            end
            S_STEP: begin
                wait_n <= wait_n + 1'b1;
                if (wait_n[1:0] == 2'd3) begin  // a step every 4 clocks
                    if (at == goal) begin
                        wait_n <= 0; st <= S_SETTLE;
                    end else begin
                        idly_ce <= 1'b1; at <= at + 1'b1;
                    end
                end
            end
            // the new tap through the deserialiser before it is judged
            S_SETTLE: begin
                wait_n <= wait_n + 1'b1;
                if (wait_n == 18'd15) begin
                    wait_n <= 0; open <= 1'b0; errs <= 0;
                    st <= S_TEST;
                end
            end
            S_TEST: begin
                wait_n <= wait_n + 1'b1;
                if (blank_done) open <= 1'b1;
                // one word, or two, not a token between tokens: a token
                // misread (data runs far longer)
                if (token && ((tk2 && !tk1) || (tk3 && !tk2 && !tk1)) &&
                    wait_n > 3 && errs != 8'd254)
                    errs <= errs + 1'b1;
                if (wait_n == TEST - 1) begin
                    map[{slips, at}] <= open ? errs : 8'd255;
                    st <= S_NEXT;
                end
            end
            // the tap's verdict into the eye; then the next tap, or the
            // eye's middle, or another bit slip
            S_NEXT: begin
                if (open) begin
                    if (!in_run) begin
                        in_run <= 1'b1; run_lo <= at; run_w <= 1;
                        run_c <= clean; run_e0 <= errs; run_e1 <= errs;
                    end else begin
                        run_w <= run_w + 1'b1; run_c <= run_c + clean;
                        run_e1 <= errs;
                    end
                end else if (in_run) begin
                    // a run closed by this tap: the widest eye so far?
                    in_run <= 1'b0;
                    if (run_eye && run_w > best_w) begin
                        best_lo <= run_lo; best_w <= run_w; best_c <= run_c;
                        best_e0 <= run_e0; best_e1 <= run_e1;
                    end
                end
                if (at != TAPS - 1) begin
                    goal <= at + 1'b1; wait_n <= 0; st <= S_STEP;
                end else begin
                    wait_n <= 0; st <= S_CENTRE;
                end
            end
            // this slip's eye, if it has one, and at less delay than any
            // before; then the next slip, or, all scanned, back to the best
            S_CENTRE: begin
                wait_n <= wait_n + 1'b1;
                if (wait_n == 0) begin
                    q_ok <= e_w != 0; q_lo <= e_lo; q_w <= e_w;
                    q_e0 <= e_e0; q_e1 <= e_e1;
                    // `eye` reports at most TAPS - 1: all of them is that
                    q_eye <= e_c[TAP_BITS] ? {TAP_BITS{1'b1}} :
                                             e_c[TAP_BITS-1:0];
                end
                if (wait_n == 1)
                    q_mid <= q_lo + ((q_w - 1'b1) >> 1) +
                             (!q_w[0] && q_e1 < q_e0);
                if (wait_n == 2) begin
                    in_run <= 1'b0; run_w <= 0; run_c <= 0; best_w <= 0;
                    best_c <= 0; wait_n <= 0;
                    st <= S_SLIP;
                    if (q_ok && (!cand_ok || q_mid < cand_mid)) begin
                        cand_ok <= 1'b1; cand_slip <= slips;
                        cand_mid <= q_mid; cand_w <= q_eye;
                    end
                    if (scan_n != SLIPS - 1) begin
                        scan_n <= scan_n + 1'b1; todo <= 4'd1;
                    end else if (q_ok && (!cand_ok || q_mid < cand_mid)) begin
                        // the best is this slip's own: no slip, to its middle
                        goal <= q_mid; eye <= q_eye; st <= S_HOLD;
                        idly_ld <= 1'b1; at <= 0;
                    end else if (cand_ok) begin
                        // SLIPS slips go round: from the last slip to the best
                        todo <= (cand_slip > slips) ? cand_slip - slips :
                                cand_slip + SLIPS - slips;
                        scan_n <= SLIPS;    // marks the return
                    end else begin
                        scan_n <= 0; todo <= 4'd1;
                    end
                end
            end
            S_SLIP: begin
                // a pulse each, and the deserialiser left alone a while
                // before it is asked again
                wait_n <= wait_n + 1'b1;
                if (wait_n == 0 && todo != 0) begin
                    bitslip <= 1'b1; todo <= todo - 1'b1;
                    slips <= (slips == SLIPS - 1) ? 4'd0 : slips + 1'b1;
                end
                if (wait_n == 18'd7) begin
                    wait_n <= 0;
                    if (todo != 0) begin
                        // another slip
                    end else if (scan_n == SLIPS) begin
                        goal <= cand_mid; eye <= cand_w; st <= S_HOLD;
                        idly_ld <= 1'b1; at <= 0;
                    end else begin
                        goal <= 0; st <= S_LOAD;
                    end
                end
            end
            // to the middle of the eye, then aligned: watched for blanks
            S_HOLD: begin
                if (!aligned) begin
                    wait_n <= wait_n + 1'b1;
                    if (wait_n[1:0] == 2'd3) begin
                        if (at == goal) begin
                            aligned <= 1'b1; tap <= at; wait_n <= 0;
                        end else begin
                            idly_ce <= 1'b1; at <= at + 1'b1;
                        end
                    end
                end else begin
                    // any token is the lane still framed: a vertical blank
                    // is one long run of them, with no blank STARTING in
                    // it for hundreds of lines at a slow frame rate
                    if (token) wait_n <= 0;
                    else wait_n <= wait_n + 1'b1;
                    if (wait_n == LOST - 1) begin
                        aligned <= 1'b0; goal <= 0; st <= S_LOAD;
                        scan_n <= 0; cand_ok <= 1'b0;
                    end
                end
            end
            default: st <= S_LOAD;
        endcase
    end
endmodule
