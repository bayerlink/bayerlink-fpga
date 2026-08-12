// Copyright 2026 Serge Rabyking
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Bench observability: which video facts are TRUE right now, readable
// over GPIO. Sticky bits catch rare events; the frame counter proves
// motion. Clears with the same software reset as the receiver.
module vid_probe (
    input  wire        clk,          // pixel clock
    input  wire        rst,
    input  wire        de,
    input  wire        vsync,
    input  wire [23:0] data,
    input  wire        rx_valid,
    output wire [15:0] status
);
    reg de_seen, vs_seen, data_seen, rxv_seen;
    reg [7:0] frames;
    reg vs_d;
    always @(posedge clk) begin
        if (rst) begin
            de_seen <= 0; vs_seen <= 0; data_seen <= 0; rxv_seen <= 0;
            frames <= 0; vs_d <= 0;
        end else begin
            vs_d <= vsync;
            if (de) de_seen <= 1;
            if (vsync) vs_seen <= 1;
            if (de && data != 24'd0) data_seen <= 1;
            if (rx_valid) rxv_seen <= 1;
            if (vsync && !vs_d) frames <= frames + 1;
        end
    end
    assign status = {frames, 4'b0, rxv_seen, data_seen, vs_seen, de_seen};
endmodule
