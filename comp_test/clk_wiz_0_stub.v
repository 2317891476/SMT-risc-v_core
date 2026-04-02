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
    reg [3:0] div_cnt;

    initial begin
        clk_out1 = 1'b0;
        locked   = 1'b0;
        div_cnt  = 4'd0;
    end

    always @(posedge clk_in1 or posedge reset) begin
        if (reset) begin
            clk_out1 <= 1'b0;
            locked   <= 1'b0;
            div_cnt  <= 4'd0;
        end else begin
            locked <= 1'b1;
            if (div_cnt == 4'd4) begin
                div_cnt  <= 4'd0;
                clk_out1 <= ~clk_out1;
            end else begin
                div_cnt <= div_cnt + 4'd1;
            end
        end
    end
endmodule
