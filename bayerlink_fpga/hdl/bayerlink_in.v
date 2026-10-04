// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// bayerlink v2 receiver: parallel video in, one sample per clock out.
//
// Line 0 of the active area is the bayerlink header; every following line
// holds one camera line of CSI-2 packed bytes. Depth and geometry are
// RUN-TIME, owned by each frame's header: the unpack engine carries all
// five packings (8/10/12/14/16-bit), and a header the silicon cannot
// honour -- bad magic, unknown fourcc, a width that misaligns its packing
// groups, a line beyond capacity, a zero dimension -- refuses the FRAME,
// latches a sticky code, and waits for the next header. The parameters fix
// only capacity, the depth samples leave at, and the link's lane order and
// frame-pulse polarity.
//
// The fourcc table and the magic are the reference codec's: they arrive as
// bayerlink_formats, generated from `bayerlink.protocol` by
// bayerlink_fpga.receiver.formats(), so this file restates no protocol
// fact. The output slice is np2hw's np2hw_skid. The header's CRC is host business.
module bayerlink_in #(
    // The largest packed camera line the buffers hold. A header whose
    // width * bits / 8 exceeds it is refused, coded. Sizes the byte FIFO:
    // one full line plus slack, in 3-byte words.
    parameter MAX_LINE_BYTES = 4096,
    // The sample-side elastic, in samples: a power of two, at least 16.
    // Four banks, so a whole emit batch lands in one cycle.
    parameter FIFO_DEPTH = 1024,
    // The depth samples LEAVE at, and the output stream's width: the
    // build's. Each sample is aligned to full scale at BITS on the way
    // out (see "ALIGN" below), so downstream the depth is a build fact.
    parameter BITS = 12,
    // Which video lane carries container byte 0, 1, 2. Lane 0 is
    // vid_data[23:16], lane 1 [15:8], lane 2 [7:0]. A permutation fixed
    // per platform pair, resolved once with a test pattern.
    parameter LANE0 = 0,
    parameter LANE1 = 1,
    parameter LANE2 = 2,
    // The frame pulse's polarity.
    parameter VSYNC_ACTIVE_HIGH = 1
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK", X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF out_stream, ASSOCIATED_RESET rst" *)
    input  wire        clk,  // the recovered pixel clock
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst RST", X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire        rst,
    // Clears the DIAGNOSTIC tallies below, and only those. It is
    // separate from rst because rst is now the LINK's: a reset
    // arrives on every cable drop, and a tally cleared by the
    // event it exists to count is not a tally. This one means a
    // person, or software, asking to start counting again.
    input  wire        diag_clear,
    // Parallel video from the HDMI/DVI receiver. No ready exists on
    // this side: video cannot be stalled, only missed.
    input  wire        vid_de,
    input  wire        vid_vsync,
    input  wire [23:0] vid_data,
    // The elastic stream a generated core consumes. Samples are
    // ALIGNED to BITS bits: whatever depth the header names,
    // what leaves here is full scale at this build's depth.
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream VALID" *)
    output wire        out_valid,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream READY" *)
    input  wire        out_ready,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream DATA" *)
    output wire [BITS-1:0] out_data,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream SOF" *)
    output wire        out_sof,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream EOL" *)
    output wire        out_eol,
    (* X_INTERFACE_INFO = "lanserge:interface:np2hw_stream_rtl:1.0 out_stream LAST" *)
    output wire        out_last,
    // STICKY until reset: unobservable loss is a debugging season.
    output reg         overflow,
    output reg         refused,
    output reg  [2:0]  refuse_code,  // 1 magic, 2 fourcc, 3 group
                                     // alignment, 4 capacity, 5 zero
    // The last ACCEPTED header, for hosts to observe.
    output reg  [4:0]  hdr_bits,
    output reg  [15:0] hdr_width,
    output reg  [15:0] hdr_height,
    output reg  [1:0]  hdr_phase,
    output reg  [7:0]  hdr_source_id,  // WHICH camera sent it
    output reg  [31:0] hdr_frame_seq,  // WHICH frame it is
    output reg  [7:0]  resync_count,   // stream restarts, wrapping
    output reg         hdr_valid
);
    // Byte FIFO: 3-byte words, a full line plus slack, a power of two.
    localparam integer BWORDS = 1 << $clog2((MAX_LINE_BYTES + 2) / 3 + 8);
    localparam integer BPTRW  = $clog2(BWORDS);
    localparam integer BCNTW  = $clog2(BWORDS + 1);
    localparam integer HALF   = FIFO_DEPTH / 4;   // per-bank samples
    localparam integer SPTRW  = $clog2(FIFO_DEPTH);
    localparam integer SCNTW  = $clog2(FIFO_DEPTH + 1);
    localparam integer LBW    = $clog2(MAX_LINE_BYTES + 1);  // line bytes
    localparam integer WINDOW = 12;   // bytes; >= 7 (widest group) + 3
    // The same numbers at the widths they are compared and counted at.
    localparam [BCNTW-1:0] BFULL = BWORDS, BC1 = 1, BC0 = 0;
    localparam [SCNTW-1:0] SROOM = FIFO_DEPTH - 8, SC1 = 1, SC0 = 0;
    localparam [3:0]       WFILL = WINDOW - 3;

    wire vs_in = VSYNC_ACTIVE_HIGH ? vid_vsync : ~vid_vsync;

    // ---- position in the display frame ----
    reg de_q, vs_q;
    wire frame_start = vs_in & ~vs_q;
    wire line_end    = de_q & ~vid_de;   // DE falling edge
    reg [15:0] line;                     // display lines since vsync
    reg [LBW-1:0] bytecnt;             // payload bytes into the line

    // ---- container bytes, lane permutation undone ----
    wire [7:0] byte0 = vid_data[23 - 8 * LANE0 -: 8];
    wire [7:0] byte1 = vid_data[23 - 8 * LANE1 -: 8];
    wire [7:0] byte2 = vid_data[23 - 8 * LANE2 -: 8];

    // ---- header capture: line 0, first 7 pixels = bytes 0..20 ----
    reg [7:0] hb [0:29];
    reg [4:0] hbi;                       // header bytes stored, caps at 21
    wire hdr_line = (line == 16'd0);
    // The decode is PIPELINED over three cycles -- the header sits
    // a full display line ahead of its payload, so the fourcc table
    // and the capacity compare never share a cycle. Stage 1 latches
    // the fields, stage 2 the table lookups, stage 3 the verdict.
    reg [31:0] h_magic, h_fourcc, h_width, h_height;
    reg [7:0]  h_source;
    reg [31:0] h_seq;

    // SELF-RECOVERY. Nothing outside has to notice a stream
    // restarted. A header whose camera changed, or whose sequence
    // does not follow the last accepted one, means whatever is
    // still in the buffers belongs to a stream that ended: a
    // half-line left by an unplug, or another camera entirely.
    // Draining it into the new frame corrupts the new frame.
    //
    // Detected IN BAND, from the header the protocol already
    // carries, so it needs no timer, no host, and no second
    // opinion about what is connected. A CONSECUTIVE sequence is
    // left alone: a stalled tail draining under its own header is
    // this design working, not a fault.
    reg        have_last;
    reg [7:0]  last_source;
    reg [31:0] last_seq;

    // fourcc -> depth code + CFA phase, and the magic: the reference
    // codec's tables, generated from it as bayerlink_formats -- the
    // protocol's facts have one owner, and this file restates none.
    wire        f_known;
    wire [2:0]  f_code;
    wire [1:0]  f_phase;
    wire [31:0] magic;
    bayerlink_formats u_formats (
        .fourcc(h_fourcc), .known(f_known), .code(f_code), .phase(f_phase),
        .magic(magic));

    // Bytes per line, width * bits / 8, for EVERY packing at once:
    // each is one add on the width alone, so none waits for the
    // format to be decoded. The decode and the arithmetic used to
    // chain in one cycle -- a 32-bit compare against the whole table
    // selecting an 18-bit add -- the deepest path in the receiver,
    // timed as if it changed every cycle when it changes once a
    // frame. Registered side by side in stage 2, they are chosen in
    // stage 3 by the format registered beside them.
    wire [17:0] w_8  = {2'b0, h_width[15:0]};                         // w
    wire [17:0] w_10 = {2'b0, h_width[15:0]} + {4'b0, h_width[15:2]};   // w + w/4
    wire [17:0] w_12 = {2'b0, h_width[15:0]} + {3'b0, h_width[15:1]};   // w + w/2
    wire [17:0] w_14 = {1'b0, h_width[15:0], 1'b0} - {4'b0, h_width[15:2]}; // 2w - w/4
    wire [17:0] w_16 = {1'b0, h_width[15:0], 1'b0};                   // 2w

    // ---- stage-2 registers: the format decoded, every length ----
    reg        c_known;
    reg [2:0]  c_code;
    reg [1:0]  c_phase;
    reg [17:0] c_8, c_10, c_12, c_14, c_16;
    reg [1:0]  c_low;     // the width's low bits, for alignment

    reg [17:0] f_linebytes;
    always @* case (c_code)
        3'd0: f_linebytes = c_8;
        3'd1: f_linebytes = c_10;
        3'd2: f_linebytes = c_12;
        3'd3: f_linebytes = c_14;
        default: f_linebytes = c_16;
    endcase

    // group alignment: width % group_samples == 0
    reg f_aligned;
    always @* case (c_code)
        3'd1, 3'd3: f_aligned = (c_low == 2'b00);   // groups of 4
        3'd2:       f_aligned = (c_low[0] == 1'b0); // pairs
        default:    f_aligned = 1'b1;               // bytes/LE16
    endcase

    // ---- stage-3 registers, then the verdict on registered facts ----
    reg        d_known, d_aligned;
    reg [2:0]  d_code;
    reg [1:0]  d_phase;
    reg [17:0] d_linebytes;
    wire [2:0] verdict =
        (h_magic != magic)    ? 3'd1 :
        (!d_known)            ? 3'd2 :
        (!d_aligned)          ? 3'd3 :
        (d_linebytes > MAX_LINE_BYTES || h_width[31:16] != 16'h0
            || h_height[31:16] != 16'h0) ? 3'd4 :
        (h_width == 32'd0 || h_height == 32'd0) ? 3'd5 : 3'd0;

    // Pending = this frame's accepted facts; active copies arrive on
    // the drain side with the frame's first byte, so a stalled tail
    // of the previous frame still unpacks under ITS OWN header.
    reg        pend_ok;
    reg [2:0]  pend_code;
    reg [1:0]  pend_phase;
    reg [15:0] pend_width, pend_height;
    reg [LBW-1:0] pend_linebytes;
    // 0 idle/latched, 1 fields held, 2 decoded, 3 chosen, 4 done
    reg [2:0] hstage;

    // THE TALLIES. A link drop resets this whole domain, so these
    // live outside that reset and answer only to diag_clear --
    // otherwise the recovery erases the evidence of what went
    // wrong just before it, which is how a fault becomes a
    // season. Power-up values come from configuration.
    initial begin
        overflow = 1'b0; refused = 1'b0; refuse_code = 3'd0;
        resync_count = 8'd0;
    end
    always @(posedge clk) begin
        if (rst) begin
            de_q <= 0; vs_q <= 0; line <= 16'hFFFF; bytecnt <= 0;
            hbi <= 0; hstage <= 0; pend_ok <= 0;
            h_magic <= 0; h_fourcc <= 0; h_width <= 0; h_height <= 0;
            h_source <= 0; h_seq <= 0;
            d_known <= 0; d_aligned <= 0; d_code <= 0; d_phase <= 0;
            d_linebytes <= 0;
            // refused/refuse_code/resync_count are NOT cleared
            // here -- a link drop resets this domain, and a tally
            // cleared by the event it counts is not a tally.
            hdr_valid <= 0; hdr_bits <= 0; hdr_width <= 0;
            hdr_height <= 0; hdr_phase <= 0; hdr_source_id <= 0;
            hdr_frame_seq <= 0;
            have_last <= 0; last_source <= 0; last_seq <= 0;
        end else begin
            if (diag_clear) begin
                refused <= 1'b0; refuse_code <= 3'd0;
                resync_count <= 8'd0;
            end
            de_q <= vid_de;
            vs_q <= vs_in;
            if (vid_de && hdr_line && hbi != 5'd30) begin
                hb[hbi] <= byte0;
                hb[hbi + 5'd1] <= byte1;
                hb[hbi + 5'd2] <= byte2;
                hbi <= hbi + 5'd3;
            end
            if (hdr_line && hbi == 5'd30 && hstage == 3'd0) begin
                hstage <= 3'd1;   // stage 1: hold the fields
                h_magic  <= {hb[3],  hb[2],  hb[1],  hb[0]};
                h_fourcc <= {hb[11], hb[10], hb[9],  hb[8]};
                h_width  <= {hb[15], hb[14], hb[13], hb[12]};
                h_height <= {hb[19], hb[18], hb[17], hb[16]};
                // WHICH CAMERA. The protocol carries it so two
                // independent streams are never mistaken for
                // stripes of one another; reporting it lets
                // software recognise the source and load ITS
                // calibration. Black level and colour belong to a
                // sensor and, unlike the CFA order and the depth,
                // cannot be derived from the stream. Identity
                // travels in band, so it survives being replugged
                // into a different capture device.
                h_source <= hb[28];
                // WHICH frame. A statistic is meaningless without the
                // frame it was measured on: an exposure loop that
                // corrects frame N from frame N-2 numbers oscillates,
                // and the fault reads as bad gain maths. It also tells
                // a frame the LINK lost from one the camera never
                // sent -- a gap in the sequence, against a sticky
                // overflow bit.
                h_seq <= {hb[23], hb[22], hb[21], hb[20]};
            end
            if (hstage == 3'd1) begin
                hstage <= 3'd2;   // stage 2: the table lookup, held
                c_known <= f_known; c_code <= f_code; c_phase <= f_phase;
                c_8 <= w_8; c_10 <= w_10; c_12 <= w_12;
                c_14 <= w_14; c_16 <= w_16; c_low <= h_width[1:0];
            end
            if (hstage == 3'd2) begin
                hstage <= 3'd3;   // stage 3: this format's length
                d_known <= c_known; d_code <= c_code;
                d_phase <= c_phase; d_aligned <= f_aligned;
                d_linebytes <= f_linebytes;
            end
            if (hstage == 3'd3) begin
                hstage <= 3'd4;   // stage 4: the verdict
                if (verdict == 3'd0) begin
                    pend_ok <= 1'b1;
                    pend_code <= d_code; pend_phase <= d_phase;
                    pend_width <= h_width[15:0];
                    pend_height <= h_height[15:0];
                    pend_linebytes <= d_linebytes[LBW-1:0];
                    hdr_valid <= 1'b1;
                    case (d_code)   // observable, in plain bits
                        3'd0: hdr_bits <= 5'd8;  3'd1: hdr_bits <= 5'd10;
                        3'd2: hdr_bits <= 5'd12; 3'd3: hdr_bits <= 5'd14;
                        default: hdr_bits <= 5'd16;
                    endcase
                    hdr_width <= h_width[15:0];
                    hdr_height <= h_height[15:0];
                    hdr_phase <= d_phase;
                    hdr_source_id <= h_source;
                    hdr_frame_seq <= h_seq;
                    // A RESTART, not merely a change. The link
                    // repeats containers when the camera is slower
                    // than the display, so a sequence that stays
                    // put is ordinary, and one that steps forward
                    // by more than one is a DROPPED frame -- also
                    // ordinary, and a different fact. What cannot
                    // happen within one stream is time going
                    // BACKWARDS: a source that restarts counts
                    // from the beginning again. That, or the
                    // camera itself changing.
                    //
                    // Learned on the bench: keyed on `== last + 1`
                    // this fired once per frame forever, because
                    // every simulation had counted cleanly and no
                    // real link does.
                    if (!have_last || h_source != last_source
                        || h_seq < last_seq) begin
                        resync_count <= resync_count + 8'd1;
                    end
                    have_last   <= 1'b1;
                    last_source <= h_source;
                    last_seq    <= h_seq;
                end else begin
                    pend_ok <= 1'b0;
                    refused <= 1'b1;      // sticky; frame is dropped
                    refuse_code <= verdict;
                end
            end
            if (line_end) begin
                bytecnt <= 0;
                if (line != 16'hFFFF) line <= line + 16'd1;
            end else if (vid_de && !hdr_line)
                bytecnt <= (bytecnt > MAX_LINE_BYTES - 3) ? bytecnt
                           : bytecnt + 3'd3;
            if (frame_start) begin
                line <= 16'd0; bytecnt <= 0; hbi <= 0; hstage <= 0;
            end
        end
    end

    // ---- payload ingest: 3-byte words with a valid count + frame tag ----
    wire in_frame = pend_ok && !hdr_line
                    && line != 16'hFFFF && line <= {1'b0, pend_height};
    wire payload  = vid_de && in_frame && bytecnt < pend_linebytes;
    wire [LBW-1:0] left = pend_linebytes - bytecnt;
    wire [1:0] vb = (left >= 3) ? 2'd3 : left[1:0];
    wire ff = (line == 16'd1) && (bytecnt == 0);   // frame's first word
    // FRAMING DECIDED AT INGEST, the v1 law: position is known
    // here and only here. le marks each line's final payload word,
    // fe the frame's; the drain fires eol/last on the TAG, so a
    // lossy stretch corrupts its own frame and nothing after it.
    wire le = (left <= 3);
    wire fe = le && (line == {1'b0, pend_height});

    // The ingest DECISION is registered: the line-bytes compare
    // never shares a cycle with the FIFO bookkeeping.
    reg        p_valid, p_ff, p_le, p_fe;
    reg [1:0]  p_vb;
    reg [23:0] p_b;
    reg [28:0] bfifo [0:BWORDS-1];   // {fe, le, ff, vb, b0, b1, b2}
    reg [BPTRW-1:0] bwr, brd;
    reg [BCNTW-1:0] bcount;
    wire bspace = (bcount != BFULL);
    wire bwr_en = p_valid && bspace;

    // ---- drain: window of bytes, one packing group per cycle ----
    reg [7:0] win [0:WINDOW-1];  // win[0] is oldest
    reg [3:0] wcnt;
    // Active facts travel with the frame tag, not the wire clock:
    reg [2:0]  act_code;
    reg [15:0] act_width, act_height;
    reg        act_valid;
    // Position: `rem` (samples left in the line) exists ONLY for
    // the 8-bit clamp and resyncs at every tagged line end; the
    // FLAGS come from the ingest tags, never from delivered-sample
    // counts -- loss corrupts its own frame and nothing after it.
    reg [15:0] rem;
    reg        sof_p;
    reg        eol_pend, fe_pend;   // a tagged line end is in the window
    reg [3:0]  eol_mark;            // bytes from window head to it
    reg [3:0]  need_r;              // registered shift: min(mark, be)

    // The byte FIFO reads REGISTERED (block RAM, not a BWORDS-deep
    // LUT mux): bdout always holds the word at brd, one cycle after
    // brd settles; bprimed covers the latency and the same-address
    // write-through corner by simply waiting a cycle.
    reg [28:0] bdout;
    reg        bprimed;
    wire [28:0] bhead = bdout;
    // A frame tag waits for the window to drain, then swaps geometry.
    // One-word SKID between the BRAM and the window: the BRAM's
    // slow output lands only in registers, and every control
    // decision reads registers, never the RAM.
    reg        sk_valid, sk_ff, sk_le, sk_fe;
    reg [1:0]  sk_vb;
    reg [23:0] sk_b;
    wire sk_take = sk_valid
               && (wcnt <= WFILL)
               && (!sk_ff || wcnt == 4'd0)
               && (!sk_le || !eol_pend);
    wire pop = bprimed && (bcount != 0) && (!sk_valid || sk_take);
    // A lossy frame can strand a stub: leftover window bytes too
    // few to emit, with the next frame's barrier waiting for an
    // empty window that can never come. The stub belongs to a dead
    // frame -- flush it, and the barrier opens.
    wire stub_flush = sk_valid && sk_ff && (wcnt != 4'd0)
                      && ({1'b0, wcnt} < {1'b0, need_r});
    wire [BPTRW-1:0] brd_n = pop ? brd + 1'b1 : brd;

    function [2:0] eng_be; input [2:0] c;
        case (c)
            3'd0: eng_be = 3'd3;
            3'd1: eng_be = 3'd5;
            3'd2: eng_be = 3'd3;
            3'd3: eng_be = 3'd7;
            3'd4: eng_be = 3'd2;
            default: eng_be = 3'd3;
        endcase
    endfunction
    function [2:0] eng_se; input [2:0] c;
        case (c)
            3'd0: eng_se = 3'd3;
            3'd1: eng_se = 3'd4;
            3'd2: eng_se = 3'd2;
            3'd3: eng_se = 3'd4;
            3'd4: eng_se = 3'd1;
            default: eng_se = 3'd2;
        endcase
    endfunction
    reg [2:0] be; reg [2:0] se;         // bytes, samples per emit
    // The depth of the frame being UNPACKED, which is not always
    // the last header accepted: a stalled tail drains under its
    // own header while the next one is already parsed.
    reg [4:0] act_bits;
    always @* case (act_code)
        3'd0: act_bits = 5'd8;  3'd1: act_bits = 5'd10;
        3'd2: act_bits = 5'd12; 3'd3: act_bits = 5'd14;
        default: act_bits = 5'd16;
    endcase
    always @* case (act_code)
        3'd0: begin be = 3'd3; se = 3'd3; end // 8-bit
        3'd1: begin be = 3'd5; se = 3'd4; end // 10-bit
        3'd2: begin be = 3'd3; se = 3'd2; end // 12-bit
        3'd3: begin be = 3'd7; se = 3'd4; end // 14-bit
        3'd4: begin be = 3'd2; se = 3'd1; end // 16-bit
        default: begin be = 3'd3; se = 3'd2; end
    endcase
    // 8-bit is the one engine whose emit batch is not a packing
    // group (three 1-byte groups per cycle, to outpace ingest), so
    // it alone may meet a line boundary mid-batch: clamp it there,
    // and the whole-groups-per-line invariant holds for every depth.
    // The clamp is REGISTERED: both writers of `rem` know its next
    // value, so the compare rides their paths, not the emit loop's.
    reg [2:0] be_eff, se_eff;
    function [2:0] clamp8;
        input [2:0] code; input [15:0] r; input [2:0] full;
        clamp8 = (code == 3'd0 && r[15:2] == 14'd0
                  && r[1:0] != 2'd3 && r != 16'd0)
                 ? {1'b0, r[1:0]} : full;
    endfunction

    reg [SPTRW-1:0] swr, srd;
    // Two counters, one truth each: RESERVED (bumped when a batch is
    // extracted, gates emission) and AVAILABLE (bumped a cycle later
    // when the banks are physically written, gates the reader) --
    // the bank write is its own pipeline stage, so the rotation mux
    // never shares a cycle with the sample extraction.
    reg [SCNTW-1:0] scount_res, scount_avail;
    wire raw_valid = (scount_avail != 0);
    wire raw_ready;
    wire sroom = (scount_res <= SROOM);
    wire emit = act_valid && ({1'b0, wcnt} >= {1'b0, need_r}) && sroom;

    // Samples of the head group, every depth in parallel; act_code picks.
    wire [15:0] smp0, smp1, smp2, smp3;
    reg  [15:0] s0m, s1m, s2m, s3m;
    always @* case (act_code)
        3'd0: begin                                        // 8-bit
            s0m = {8'b0, win[0]}; s1m = {8'b0, win[1]};
            s2m = {8'b0, win[2]}; s3m = 16'd0;
        end
        3'd1: begin                                        // 10P
            s0m = {6'b0, win[0], win[4][1:0]};
            s1m = {6'b0, win[1], win[4][3:2]};
            s2m = {6'b0, win[2], win[4][5:4]};
            s3m = {6'b0, win[3], win[4][7:6]};
        end
        3'd2: begin                                        // 12P
            s0m = {4'b0, win[0], win[2][3:0]};
            s1m = {4'b0, win[1], win[2][7:4]};
            s2m = 16'd0; s3m = 16'd0;
        end
        3'd3: begin                                        // 14P
            s0m = {2'b0, win[0], win[4][5:0]};
            s1m = {2'b0, win[1], win[5][3:0], win[4][7:6]};
            s2m = {2'b0, win[2], win[6][1:0], win[5][7:4]};
            s3m = {2'b0, win[3], win[6][7:2]};
        end
        default: begin                                     // 16 LE
            s0m = {win[1], win[0]};
            s1m = 16'd0; s2m = 16'd0; s3m = 16'd0;
        end
    endcase
    assign smp0 = s0m; assign smp1 = s1m;
    assign smp2 = s2m; assign smp3 = s3m;

    // Flags: an emit batch is whole packing groups, and a line is
    // whole groups too, so a batch never straddles a line boundary --
    // eol can only be the batch's LAST sample, sof only its first.
    wire batch_eol  = eol_pend && (eol_mark <= {1'b0, be_eff});
    wire batch_sof  = sof_p;
    wire batch_last = batch_eol && fe_pend;
    wire [15:0] rem_next = batch_eol ? act_width
                                     : rem - {13'b0, se_eff};

    reg [BITS+2:0] sbank0 [0:HALF-1];   // {last, eol, sof, data}
    reg [BITS+2:0] sbank1 [0:HALF-1];
    reg [BITS+2:0] sbank2 [0:HALF-1];
    reg [BITS+2:0] sbank3 [0:HALF-1];
    // The extracted batch, registered: stage B writes the banks.
    reg        q_valid;
    reg [2:0]  q_se;
    reg [SPTRW-1:0] q_swr;
    reg        q_sof, q_eol, q_last;
    reg [BITS-1:0] q_smp0, q_smp1, q_smp2, q_smp3;

    // ALIGN TO THIS BUILD'S DEPTH, on the way into the FIFO.
    // The header's depth is run-time and the datapath's is not,
    // so the two meet here and only here; downstream the depth is
    // a build fact again and every traced stage keeps its
    // constants. Up-shifting replicates the top bits into what it
    // vacated, so full scale lands on full scale -- a plain shift
    // maps an 8-bit 255 to 4080 in 12 bits and leaves every white
    // 0.4%% dark forever. Down-shifting drops low bits: a deeper
    // source than the datapath loses precision, where truncating
    // the top would lose the picture.
    //
    // On the WRITE side deliberately. On the read side it sat
    // between the bank mux and the first consumer stage and cost
    // 1.4ns of a 6.7ns period -- measured, not feared. Here the
    // unpack engine batches, so the slack is already there, and
    // the FIFO carries narrower words as a bonus.
    localparam integer OUT_BITS = BITS;
    wire [4:0] shl_a = (act_bits <= OUT_BITS[4:0])
                     ? (OUT_BITS[4:0] - act_bits) : 5'd0;
    wire [4:0] shr_a = (act_bits <= OUT_BITS[4:0])
                     ? 5'd0 : (act_bits - OUT_BITS[4:0]);
    wire [4:0] rep_a = (act_bits > shl_a) ? (act_bits - shl_a) : 5'd31;
    function [OUT_BITS-1:0] align;
        input [15:0] v;
        reg [31:0] w;
        begin
            w = (act_bits <= OUT_BITS[4:0])
              ? ((({16'd0, v} << shl_a))
                 | ((rep_a == 5'd31) ? 32'd0 : ({16'd0, v} >> rep_a)))
              : ({16'd0, v} >> shr_a);
            align = w[OUT_BITS-1:0];
        end
    endfunction

    // window shift by be, then refill from the popped word
    integer k;
    reg [7:0] wnext [0:WINDOW-1];
    reg [3:0] cnt_s;
    always @* begin
        for (k = 0; k < WINDOW; k = k + 1)
            wnext[k] = emit ? ((k + need_r < WINDOW) ? win[k + need_r] : 8'd0)
                            : win[k];
        cnt_s = emit ? (wcnt - need_r) : wcnt;
    end

    // next-values feeding need_r's register (mirrors the updates)
    wire nr_ins  = sk_take && sk_le;
    wire nr_pend = nr_ins ? 1'b1 : (emit && batch_eol ? 1'b0 : eol_pend);
    wire [3:0] nr_mark = nr_ins ? (cnt_s + {2'b0, sk_vb})
                       : ((emit && eol_pend) ? eol_mark - need_r
                                             : eol_mark);
    wire [2:0] nr_be = (sk_take && sk_ff)
                       ? clamp8(pend_code, pend_width, eng_be(pend_code))
                       : (emit ? clamp8(act_code, rem_next, be) : be_eff);
    // Per-slot addresses at POINTER width: a batch that straddles
    // the wrap must wrap with it, not run off the end of the banks.
    wire [SPTRW-1:0] q_adr0 = q_swr + 0;
    wire [SPTRW-1:0] q_adr1 = q_swr + 1;
    wire [SPTRW-1:0] q_adr2 = q_swr + 2;
    wire [SPTRW-1:0] q_adr3 = q_swr + 3;
    always @(posedge clk) begin
        // No flush on a discontinuity, deliberately: there is
        // nothing to flush. The rate rule drains a line within a
        // line time, and a whole blanking period plus the header
        // line separate one frame's payload from the next header,
        // so these buffers are already empty when a new stream is
        // recognised -- measured, with a slow reader, not assumed.
        // And the case that motivates one -- an unplug -- stops
        // this clock, so nothing here could run anyway; that
        // recovery belongs to whatever holds rst.
        if (rst) begin
            bwr <= 0; brd <= 0; bcount <= 0;
            bprimed <= 0; bdout <= 0;
            p_valid <= 0; p_ff <= 0; p_le <= 0; p_fe <= 0;
            p_vb <= 0; p_b <= 0;
            sk_valid <= 0; sk_ff <= 0; sk_le <= 0; sk_fe <= 0;
            sk_vb <= 0; sk_b <= 0;
            wcnt <= 0; swr <= 0; srd <= 0;
            scount_res <= 0; scount_avail <= 0; q_valid <= 0;
            q_se <= 0; q_swr <= 0; q_sof <= 0; q_eol <= 0;
            q_last <= 0; q_smp0 <= 0; q_smp1 <= 0; q_smp2 <= 0;
            q_smp3 <= 0;
            act_valid <= 0; act_code <= 0; act_width <= 0;
            act_height <= 0; rem <= 0; sof_p <= 0;
            be_eff <= 3'd3; se_eff <= 3'd3; need_r <= 4'd3;
            eol_pend <= 0; fe_pend <= 0; eol_mark <= 0;
            for (k = 0; k < WINDOW; k = k + 1) win[k] <= 8'd0;
        end else begin
            // ingest side, one registered stage after the compare
            p_valid <= payload;
            p_ff <= ff; p_le <= le; p_fe <= fe; p_vb <= vb;
            p_b <= {byte0, byte1, byte2};
            if (bwr_en) begin
                bfifo[bwr] <= {p_fe, p_le, p_ff, p_vb, p_b};
                bwr <= bwr + 1'b1;
            end
            if (diag_clear) overflow <= 1'b0;
            else if (p_valid && !bspace) overflow <= 1'b1;  // sticky
            // registered FIFO head: next cycle bdout matches brd
            bdout <= bfifo[brd_n];
            bprimed <= ((bcount + (bwr_en ? BC1 : BC0)
                         - (pop ? BC1 : BC0)) != 0)
                       && !(bwr_en && (bwr == brd_n));

            // drain side: shift, then insert the popped word's bytes
            for (k = 0; k < WINDOW; k = k + 1) win[k] <= wnext[k];
            wcnt <= cnt_s;
            if (pop) begin
                sk_valid <= 1'b1;
                sk_fe <= bhead[28];
                sk_le <= bhead[27];
                sk_ff <= bhead[26];
                sk_vb <= bhead[25:24];
                sk_b  <= bhead[23:0];
                brd <= brd_n;
            end else if (sk_take)
                sk_valid <= 1'b0;
            if (sk_take) begin
                if (sk_ff) begin     // the frame's facts arrive HERE
                    act_valid <= 1'b1;
                    act_code <= pend_code;
                    act_width <= pend_width;
                    act_height <= pend_height;
                    rem <= pend_width;
                    sof_p <= 1'b1;
                    be_eff <= clamp8(pend_code, pend_width,
                                     eng_be(pend_code));
                    se_eff <= clamp8(pend_code, pend_width,
                                     eng_se(pend_code));
                end
                // bytes land at the post-shift count
                if (sk_vb >= 2'd1) win[cnt_s + 4'd0] <= sk_b[23:16];
                if (sk_vb >= 2'd2) win[cnt_s + 4'd1] <= sk_b[15:8];
                if (sk_vb == 2'd3) win[cnt_s + 4'd2] <= sk_b[7:0];
                wcnt <= cnt_s + {2'b0, sk_vb};
            end
            bcount <= bcount + (bwr_en ? BC1 : BC0)
                             - (pop ? BC1 : BC0);

            // stage A: extract the batch and reserve its slots
            q_valid <= emit;
            if (emit) begin
                q_se <= se_eff; q_swr <= swr;
                q_sof <= batch_sof; q_eol <= batch_eol;
                q_last <= batch_last;
                q_smp0 <= align(smp0); q_smp1 <= align(smp1);
                q_smp2 <= align(smp2); q_smp3 <= align(smp3);
                swr <= swr + {{(SPTRW-3){1'b0}}, se_eff};
                sof_p <= 1'b0;
                rem <= rem_next;
                be_eff <= clamp8(act_code, rem_next, be);
                se_eff <= clamp8(act_code, rem_next, se);
                if (batch_eol) begin
                    eol_pend <= 1'b0; fe_pend <= 1'b0;
                end else if (eol_pend)
                    eol_mark <= eol_mark - need_r;
            end
            if (sk_take && sk_le) begin
                eol_pend <= 1'b1;
                fe_pend <= sk_fe;
                eol_mark <= cnt_s + {2'b0, sk_vb};
            end
            if (stub_flush) begin
                wcnt <= 4'd0;
                eol_pend <= 1'b0; fe_pend <= 1'b0;
            end
            // registered shift: min(next mark, next be), from the
            // same next-values its sources register this cycle
            // the SELECT compares registers only (be_eff, not its
            // next): at ff-loads pend is provably clear, and the
            // 8-bit clamp coincides with the tag on intact streams,
            // so the one-cycle skew never picks a wrong minimum.
            need_r <= nr_pend && ({1'b0, nr_mark} < {2'b0, be_eff})
                      ? nr_mark : {1'b0, nr_be};
            // stage B: the physical bank writes, from registers only
            if (q_valid) begin
                case (q_swr[1:0])
                    2'd0: begin
                        if (q_se > 3'd0) sbank0[q_adr0 >> 2] <= {
                            (q_se == 3'd1) ? q_last : 1'b0,
                            (q_se == 3'd1) ? q_eol  : 1'b0,
                            q_sof, q_smp0};
                        if (q_se > 3'd1) sbank1[q_adr1 >> 2] <= {
                            (q_se == 3'd2) ? q_last : 1'b0,
                            (q_se == 3'd2) ? q_eol  : 1'b0,
                            1'b0, q_smp1};
                        if (q_se > 3'd2) sbank2[q_adr2 >> 2] <= {
                            (q_se == 3'd3) ? q_last : 1'b0,
                            (q_se == 3'd3) ? q_eol  : 1'b0,
                            1'b0, q_smp2};
                        if (q_se > 3'd3) sbank3[q_adr3 >> 2] <= {
                            (q_se == 3'd4) ? q_last : 1'b0,
                            (q_se == 3'd4) ? q_eol  : 1'b0,
                            1'b0, q_smp3};
                    end
                    2'd1: begin
                        if (q_se > 3'd0) sbank1[q_adr0 >> 2] <= {
                            (q_se == 3'd1) ? q_last : 1'b0,
                            (q_se == 3'd1) ? q_eol  : 1'b0,
                            q_sof, q_smp0};
                        if (q_se > 3'd1) sbank2[q_adr1 >> 2] <= {
                            (q_se == 3'd2) ? q_last : 1'b0,
                            (q_se == 3'd2) ? q_eol  : 1'b0,
                            1'b0, q_smp1};
                        if (q_se > 3'd2) sbank3[q_adr2 >> 2] <= {
                            (q_se == 3'd3) ? q_last : 1'b0,
                            (q_se == 3'd3) ? q_eol  : 1'b0,
                            1'b0, q_smp2};
                        if (q_se > 3'd3) sbank0[q_adr3 >> 2] <= {
                            (q_se == 3'd4) ? q_last : 1'b0,
                            (q_se == 3'd4) ? q_eol  : 1'b0,
                            1'b0, q_smp3};
                    end
                    2'd2: begin
                        if (q_se > 3'd0) sbank2[q_adr0 >> 2] <= {
                            (q_se == 3'd1) ? q_last : 1'b0,
                            (q_se == 3'd1) ? q_eol  : 1'b0,
                            q_sof, q_smp0};
                        if (q_se > 3'd1) sbank3[q_adr1 >> 2] <= {
                            (q_se == 3'd2) ? q_last : 1'b0,
                            (q_se == 3'd2) ? q_eol  : 1'b0,
                            1'b0, q_smp1};
                        if (q_se > 3'd2) sbank0[q_adr2 >> 2] <= {
                            (q_se == 3'd3) ? q_last : 1'b0,
                            (q_se == 3'd3) ? q_eol  : 1'b0,
                            1'b0, q_smp2};
                        if (q_se > 3'd3) sbank1[q_adr3 >> 2] <= {
                            (q_se == 3'd4) ? q_last : 1'b0,
                            (q_se == 3'd4) ? q_eol  : 1'b0,
                            1'b0, q_smp3};
                    end
                    2'd3: begin
                        if (q_se > 3'd0) sbank3[q_adr0 >> 2] <= {
                            (q_se == 3'd1) ? q_last : 1'b0,
                            (q_se == 3'd1) ? q_eol  : 1'b0,
                            q_sof, q_smp0};
                        if (q_se > 3'd1) sbank0[q_adr1 >> 2] <= {
                            (q_se == 3'd2) ? q_last : 1'b0,
                            (q_se == 3'd2) ? q_eol  : 1'b0,
                            1'b0, q_smp1};
                        if (q_se > 3'd2) sbank1[q_adr2 >> 2] <= {
                            (q_se == 3'd3) ? q_last : 1'b0,
                            (q_se == 3'd3) ? q_eol  : 1'b0,
                            1'b0, q_smp2};
                        if (q_se > 3'd3) sbank2[q_adr3 >> 2] <= {
                            (q_se == 3'd4) ? q_last : 1'b0,
                            (q_se == 3'd4) ? q_eol  : 1'b0,
                            1'b0, q_smp3};
                    end
                endcase
            end
            if (raw_valid && raw_ready) srd <= srd + 1'b1;
            scount_res <= scount_res + (emit ? {{(SCNTW-3){1'b0}}, se_eff} : SC0)
                             - ((raw_valid && raw_ready) ? SC1 : SC0);
            scount_avail <= scount_avail + (q_valid ? {{(SCNTW-3){1'b0}}, q_se} : SC0)
                             - ((raw_valid && raw_ready) ? SC1 : SC0);
        end
    end

    reg [BITS+2:0] shead;
    always @* case (srd[1:0])
        2'd0: shead = sbank0[srd >> 2];
        2'd1: shead = sbank1[srd >> 2];
        2'd2: shead = sbank2[srd >> 2];
        default: shead = sbank3[srd >> 2];
    endcase
    // The head is already at this build's depth: alignment happened
    // on the way IN, so the read path is a mux and nothing else.
    //
    // ...and a mux is still too much to hand the next core. `shead`
    // is a distributed-RAM read followed by a 4:1 select, all of it
    // combinational from `srd`. Presented raw, that depth lands in
    // front of whatever this feeds, BEFORE that core reaches its own
    // first register -- so a receiver and a pipeline that each close
    // timing alone can fail together, which is exactly what happened
    // here twice: -1.424ns into one consumer's first stage, -1.792ns
    // into another's. Neither module was wrong about itself.
    //
    // The slice ends the argument. Downstream sees flops, so this
    // module's timing is its own no matter what it is wired to --
    // which matters most when the wiring is done by a block design
    // that np2hw never sees. One cycle of latency, no loss of rate.
    np2hw_skid #(.W(BITS + 3)) u_out_slice (
        .clk(clk), .rst(rst),
        .s_data(shead),
        .s_valid(raw_valid), .s_ready(raw_ready),
        .m_data({out_last, out_eol, out_sof, out_data}),
        .m_valid(out_valid), .m_ready(out_ready));
endmodule
