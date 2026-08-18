`timescale 1ns/1ps
// The fence's one law: tvalid, once raised, falls only after tready.
// The consumer's reset is not this module's reset -- a VDMA keeps its
// clock and its memory of promises through a link drop, and a promise
// broken mid-beat wedged a processor on 2026-08-18. So the testbench
// holds tready LOW, asserts rst mid-offer, and watches whether the
// offer survives. The combinational version fails in one cycle.
module tb;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;
  reg        in_valid = 0;
  wire       in_ready;
  reg [29:0] in_data = 0;
  reg in_sof = 0, in_eol = 0, in_last = 0;
  wire tvalid; reg tready = 0;
  wire [31:0] tdata; wire [3:0] tkeep; wire tuser, tlast;

  isp_axis dut (.clk(clk), .rst(rst),
    .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
    .in_sof(in_sof), .in_eol(in_eol), .in_last(in_last),
    .m_axis_tvalid(tvalid), .m_axis_tready(tready),
    .m_axis_tdata(tdata), .m_axis_tkeep(tkeep),
    .m_axis_tuser(tuser), .m_axis_tlast(tlast));

  // The protocol monitor: a drop of tvalid without a handshake, or
  // data moving while an offer stands un-taken, is the violation.
  integer chops = 0, wobbles = 0;
  reg tv_q = 0; reg [31:0] td_q;
  always @(posedge clk) begin
    if (tv_q && !tvalid && !(tv_q && tready)) chops = chops + 1;
    if (tv_q && tvalid && !tready && tdata !== td_q) wobbles = wobbles + 1;
    tv_q <= tvalid; td_q <= tdata;
  end

  integer got = 0, errs = 0, i;
  reg [31:0] expect_q [0:63];
  integer eq_w = 0, eq_r = 0;
  always @(posedge clk) if (tvalid && tready) begin
    if (tdata !== expect_q[eq_r]) errs = errs + 1;
    eq_r = eq_r + 1; got = got + 1;
  end

  task offer(input [29:0] d);
    begin
      in_data = d; in_valid = 1;
      expect_q[eq_w] = {8'h00, d[9:2], d[29:22], d[19:12]};
      eq_w = eq_w + 1;
      @(posedge clk); while (!in_ready) @(posedge clk);
      #1 in_valid = 0;
    end
  endtask

  integer survived = 0, held_stable = 0, quiet_in_rst = 0;
  initial begin
    repeat (4) @(posedge clk);
    // --- plain flow, sink willing --------------------------------
    tready = 1;
    for (i = 0; i < 8; i = i + 1) offer(i * 30'h1041041 + 30'h3);
    repeat (2) @(posedge clk);

    // --- THE test: offer a beat, sink stalls, reset lands --------
    tready = 0;
    offer(30'h2AAAAAAA);
    // the beat is now offered and un-taken; the link drops:
    rst = 1;
    repeat (10) @(posedge clk);
    survived = tvalid;                 // the offer must still stand
    held_stable = (tdata === {8'h00, 8'hAA, 8'hAA, 8'hAA});
    // the sink finally takes it, mid-reset:
    tready = 1; @(posedge clk); #1;
    repeat (2) @(posedge clk);
    quiet_in_rst = !tvalid;            // and then: silence, while rst
    in_valid = 1; in_data = 30'h15555555;   // upstream noise in reset
    repeat (4) @(posedge clk);
    quiet_in_rst = quiet_in_rst && !tvalid;
    in_valid = 0;
    eq_w = eq_r;                       // discard the noise expectation
    // --- release, stream resumes ---------------------------------
    rst = 0; repeat (2) @(posedge clk);
    for (i = 0; i < 4; i = i + 1) offer(i * 30'h2082082 + 30'h7);
    repeat (4) @(posedge clk);
    $display("RESULT chops=%0d wobbles=%0d errs=%0d got=%0d survived=%0d stable=%0d quiet=%0d",
             chops, wobbles, errs, got, survived, held_stable, quiet_in_rst);
    $finish;
  end
  initial begin #8000; $display("RESULT TIMEOUT"); $finish; end
endmodule
