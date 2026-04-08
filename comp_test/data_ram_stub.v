`timescale 1ns/1ps

// Simple simulation stub for FPGA block RAM (DATA_RAM IP)
module DATA_RAM (
    input  wire        clka,
    input  wire        ena,
    input  wire [3:0]  wea,
    input  wire [11:0] addra,
    input  wire [31:0] dina,
    output reg  [31:0] douta
);
    reg [31:0] mem [0:4095];

    integer k;
    initial begin
        for (k = 0; k < 4096; k = k + 1)
            mem[k] = 32'd0;
        douta = 32'd0;
    end

    always @(posedge clka) begin
        if (ena) begin
            if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
            if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
            if (wea[2]) mem[addra][23:16] <= dina[23:16];
            if (wea[3]) mem[addra][31:24] <= dina[31:24];
            douta <= mem[addra];
        end
    end
endmodule
