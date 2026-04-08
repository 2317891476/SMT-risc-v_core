`timescale 1ns/1ns
// =============================================================================
// Module : iq_pipe1_arbiter
// Description: Selects the winning instruction for execution pipe 1 from
//   multiple issue queues (INT_IQ, MEM_IQ, MUL_IQ).
//   Priority: oldest-first across all queues (by order_id comparison).
//   Pipe 0 winner (from INT_IQ) is excluded from this arbiter.
// =============================================================================
`include "define.v"

module iq_pipe1_arbiter #(
    parameter RS_TAG_W = 5
)(
    // ─── Candidate from INT IQ (FU_INT1 eligible for pipe1) ──────
    input  wire                             int_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] int_order_id,
    input  wire [RS_TAG_W-1:0]            int_tag,

    // ─── Candidate from MEM IQ ───────────────────────────────────
    input  wire                             mem_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] mem_order_id,
    input  wire [RS_TAG_W-1:0]            mem_tag,

    // ─── Candidate from MUL IQ ───────────────────────────────────
    input  wire                             mul_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] mul_order_id,
    input  wire [RS_TAG_W-1:0]            mul_tag,

    // ─── Winner selection ────────────────────────────────────────
    output reg  [1:0]  winner,    // 2'b00=none, 2'b01=INT, 2'b10=MEM, 2'b11=MUL
    output reg         winner_valid
);

    reg [`METADATA_ORDER_ID_W-1:0] best_order;

    always @(*) begin
        winner       = 2'b00;
        winner_valid = 1'b0;
        best_order   = {`METADATA_ORDER_ID_W{1'b1}};

        if (int_valid) begin
            winner       = 2'b01;
            winner_valid = 1'b1;
            best_order   = int_order_id;
        end

        if (mem_valid && (!winner_valid || mem_order_id < best_order)) begin
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
