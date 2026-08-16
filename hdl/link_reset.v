// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Hold the pixel-clock domain in reset while the link is down.
//
// The receive and ISP domain runs on the clock RECOVERED from the
// incoming TMDS. Unplug the cable and that clock STOPS: the receiver's
// FIFOs freeze half full, the ISP mid-line, the framebuffer writer mid
// frame with a burst outstanding. Nothing in that domain notices,
// because nothing in it is running -- which is why a replug used to
// need a person and a register write, and why the recovery cannot live
// where the damage is.
//
// So the supervisor runs on a clock that cannot stop. It watches the
// receiver's lock, holds the pixel domain in reset while the link is
// down, and lets go a settled interval after lock returns. Assertion is
// ASYNCHRONOUS, so it lands with no pixel clock at all; deassertion is
// SYNCHRONISED to the pixel clock, so the domain leaves reset on an
// edge rather than between two -- the half-released reset is the
// classic way a design comes back from a replug subtly broken.
//
// Power-up needs no special case and gets none: there is no lock before
// a source is connected, so the domain is held until one appears.
module link_reset #(
    // Cycles of `stable_clk` the lock must hold before the domain is
    // let go. An MMCM raises lock before its output is worth trusting,
    // and a connector being pushed home bounces. 4096 at 100 MHz is
    // ~41us: far longer than either, far shorter than a frame.
    parameter SETTLE_BITS = 12
) (
    input  wire       stable_clk,   // a clock that keeps running (FCLK0)
    input  wire       pix_clk,      // the recovered one, which does not
    input  wire       locked_a,     // dvi2rgb's lock: ASYNCHRONOUS
    input  wire       soft_rst,     // the broom, still honoured
    output wire       rst_pix,      // active high, for the pixel domain
    output reg        link_up,      // settled lock, in stable_clk
    output reg  [7:0] loss_count    // link drops seen, wrapping
);
    initial begin link_up = 1'b0; loss_count = 8'd0; end

    // `locked_a` is asynchronous to everything. Two stages before it is
    // allowed to decide anything.
    (* ASYNC_REG = "TRUE" *) reg lk0 = 1'b0, lk1 = 1'b0;
    always @(posedge stable_clk) begin
        lk0 <= locked_a;
        lk1 <= lk0;
    end

    reg [SETTLE_BITS-1:0] settle = {SETTLE_BITS{1'b0}};
    always @(posedge stable_clk) begin
        if (!lk1) begin
            // Losing the link is believed IMMEDIATELY. Waiting to be
            // sure would be waiting while a frozen domain holds a bus.
            settle <= {SETTLE_BITS{1'b0}};
            if (link_up) loss_count <= loss_count + 8'd1;
            link_up <= 1'b0;
        end else if (!link_up) begin
            // Regaining it is believed slowly.
            if (&settle) link_up <= 1'b1;
            else settle <= settle + 1'b1;
        end
    end

    // Async assert, sync deassert. With the pixel clock stopped this
    // holds reset on the strength of `arst` alone; when the clock
    // returns, the domain is released two edges later, aligned.
    wire arst = soft_rst | ~link_up;
    (* ASYNC_REG = "TRUE" *) reg r0 = 1'b1, r1 = 1'b1;
    always @(posedge pix_clk or posedge arst) begin
        if (arst) begin
            r0 <= 1'b1;
            r1 <= 1'b1;
        end else begin
            r0 <= 1'b0;
            r1 <= r0;
        end
    end
    assign rst_pix = r1;
endmodule
