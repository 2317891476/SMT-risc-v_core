`timescale 1ns/1ps

// Lightweight simulation stub for FPGA_MODE smoke tests.
// It models the AX7203 200 MHz -> 20 MHz clock wizard closely enough for
// functional verification without requiring vendor simulation libraries.
module clk_wiz_0 (
    output reg clk_out1,
    input  wire reset,
    output reg locked,
    input  wire clk_in1
);
    `ifndef FPGA_CLK_WIZ_HALF_DIV
        `define FPGA_CLK_WIZ_HALF_DIV 5
    `endif

    localparam integer HALF_DIV = (`FPGA_CLK_WIZ_HALF_DIV < 1) ? 1 : `FPGA_CLK_WIZ_HALF_DIV;
    localparam integer DIV_CNT_W = (HALF_DIV <= 1) ? 1 : $clog2(HALF_DIV);
    reg [DIV_CNT_W-1:0] div_cnt;

    initial begin
        clk_out1 = 1'b0;
        locked   = 1'b0;
        div_cnt  = {DIV_CNT_W{1'b0}};
    end

    always @(posedge clk_in1 or posedge reset) begin
        if (reset) begin
            clk_out1 <= 1'b0;
            locked   <= 1'b0;
            div_cnt  <= {DIV_CNT_W{1'b0}};
        end else begin
            if (div_cnt == (HALF_DIV - 1)) begin
                div_cnt  <= {DIV_CNT_W{1'b0}};
                clk_out1 <= ~clk_out1;
            end else begin
                div_cnt <= div_cnt + {{(DIV_CNT_W-1){1'b0}}, 1'b1};
            end
            // Model realistic lock delay: lock after a few output toggles
            if (!locked && clk_out1)
                locked <= 1'b1;
        end
    end
endmodule
