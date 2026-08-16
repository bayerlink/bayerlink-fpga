// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The case no other testbench here can reach: the pixel clock STOPS.
//
// Every other check in this project drives a running clock. An unplug
// does not: the domain's clock is recovered from the cable, so pulling
// it takes the clock away, and a reset that needs an edge to assert
// never asserts. Gate the clock and the difference shows -- with the
// assertion made synchronous, "reset still asserts" fails, which is
// exactly the bug this module exists to prevent.
//
// Run:  iverilog -g2012 -o /tmp/lr.vvp sim/tb_link_reset.v \
//           hdl/link_reset.v && /tmp/lr.vvp
`timescale 1ns/1ps
module tb;
  reg stable_clk = 0;
  reg locked = 0;
  reg broom = 0;
  reg pix_en = 0;                 // 0 => the recovered clock is gone
  reg pix_raw = 0;
  wire pix_clk = pix_en & pix_raw;
  wire rst_pix, link_up;
  wire [7:0] loss;

  always #5 stable_clk = ~stable_clk;   // 100 MHz, never stops
  always #3 pix_raw    = ~pix_raw;

  link_reset #(.SETTLE_BITS(6)) dut (
      .stable_clk(stable_clk), .pix_clk(pix_clk), .locked_a(locked),
      .soft_rst(broom), .rst_pix(rst_pix), .link_up(link_up),
      .loss_count(loss));

  integer errs = 0;

  task chk;
    input got;
    input want;
    input [8*64-1:0] what;
    begin
      if (got !== want) begin
        $display("  FAIL %0s (got %b want %b)", what, got, want);
        errs = errs + 1;
      end else begin
        $display("  PASS %0s", what);
      end
    end
  endtask

  initial begin
    #200;
    chk(rst_pix, 1'b1, "power-up, no source: held in reset, unasked");
    chk(link_up, 1'b0, "power-up: link reported down");

    locked = 1; pix_en = 1; #900;
    chk(rst_pix, 1'b0, "lock settles: domain released");
    chk(link_up, 1'b1, "lock settles: link up");

    // THE CASE: cable out. Lock drops and the clock stops together.
    locked = 0; pix_en = 0; #50;
    chk(rst_pix, 1'b1, "unplug, pixel clock STOPPED: reset still asserts");

    #3000;
    chk(rst_pix, 1'b1, "held through a long outage");
    chk(link_up, 1'b0, "outage: link reported down");

    // Replug. No host, no register write.
    locked = 1; pix_en = 1; #900;
    chk(rst_pix, 1'b0, "replug: released with no host in the loop");
    chk(link_up, 1'b1, "replug: link up again");
    if (loss !== 8'd1) begin
      $display("  FAIL loss_count (got %0d want 1)", loss);
      errs = errs + 1;
    end else $display("  PASS the drop was counted");

    // The broom still overrides.
    broom = 1; #50;
    chk(rst_pix, 1'b1, "broom reset still asserts");
    broom = 0; #50;
    chk(rst_pix, 1'b0, "broom reset releases");

    // A bouncing connector must not release early.
    locked = 0; #30; locked = 1; #30; locked = 0; #30; locked = 1; #20;
    chk(rst_pix, 1'b1, "mid-bounce: still held");
    #900;
    chk(rst_pix, 1'b0, "bouncing over: released");

    if (errs == 0) $display("\nLINK_RESET PASS");
    else $display("\nLINK_RESET FAILED (%0d)", errs);
    $finish;
  end
endmodule
