`timescale 1ns/1ns
// =============================================================================
// Module : iq_pipe1_arbiter
// Description: Selects the winning instruction for execution pipe 1 from
//   registered MEM and MUL candidate slots.
//   Priority: oldest-first across both queues (by order_id comparison).
// =============================================================================
`include "define.v"

module iq_pipe1_arbiter(
    input  wire                             mem_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] mem_order_id,
    input  wire                             mul_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] mul_order_id,
    output reg  [1:0]                      winner,       // 2'b00=none, 2'b10=MEM, 2'b11=MUL
    output reg                             winner_valid
);

    reg [`METADATA_ORDER_ID_W-1:0] best_order;

    always @(*) begin
        winner       = 2'b00;
        winner_valid = 1'b0;
        best_order   = {`METADATA_ORDER_ID_W{1'b1}};

        if (mem_valid) begin
            winner       = 2'b10;
            winner_valid = 1'b1;
            best_order   = mem_order_id;
        end

        if (mul_valid && (!winner_valid || mul_order_id < best_order)) begin
            winner       = 2'b11;
            winner_valid = 1'b1;
            best_order   = mul_order_id;
        end
    end

endmodule
