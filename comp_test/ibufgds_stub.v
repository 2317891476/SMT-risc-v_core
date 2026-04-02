`timescale 1ns/1ps

// Simple simulation stub for the AX7203 differential clock input buffer.
module IBUFGDS (
    output wire O,
    input  wire I,
    input  wire IB
);
    assign O = I;
endmodule
