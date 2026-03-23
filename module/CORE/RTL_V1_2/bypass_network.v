// =============================================================================
// Module : bypass_network
// Description: Dual-pipe forwarding / bypass network.
//   Resolves RAW hazards by forwarding results from:
//     1) Pipe 0 EX-stage writeback
//     2) Pipe 1 EX-stage writeback
//     3) MEM stage writeback (load data)
//   Priority: pipe0_ex > pipe1_ex > mem_wb > regfile (most recent wins)
//
//   Pure combinational — sits between regfile read and ALU input.
//   Critical path: 1-level comparator + MUX. Designed for high Fmax.
// =============================================================================
module bypass_network #(
    parameter DATA_W = 32
)(
    // ─── Operand request (from RO stage) ────────────────────────
    input  wire [4:0]          ro_rs1_addr,
    input  wire [4:0]          ro_rs2_addr,
    input  wire [DATA_W-1:0]   ro_rs1_regdata,   // data from register file
    input  wire [DATA_W-1:0]   ro_rs2_regdata,

    // ─── Pipe 0 result (EX stage, 1-cycle ALU) ──────────────────
    input  wire                pipe0_valid,
    input  wire [4:0]          pipe0_rd,
    input  wire                pipe0_rd_wen,
    input  wire [DATA_W-1:0]   pipe0_data,

    // ─── Pipe 1 result (EX stage, ALU / MUL / AGU) ──────────────
    input  wire                pipe1_valid,
    input  wire [4:0]          pipe1_rd,
    input  wire                pipe1_rd_wen,
    input  wire [DATA_W-1:0]   pipe1_data,

    // ─── MEM stage result (load writeback, 1 cycle later) ───────
    input  wire                mem_valid,
    input  wire [4:0]          mem_rd,
    input  wire                mem_rd_wen,
    input  wire [DATA_W-1:0]   mem_data,

    // ─── Bypassed operands ──────────────────────────────────────
    output wire [DATA_W-1:0]   op_a,
    output wire [DATA_W-1:0]   op_b,

    // ─── Forward hit indicators (for debug / perf counters) ─────
    output wire [1:0]          fwd_src_a,    // 00=reg, 01=pipe0, 10=pipe1, 11=mem
    output wire [1:0]          fwd_src_b
);

// ─── Forwarding match detection ─────────────────────────────────────────────
wire p0_match_a = pipe0_valid && pipe0_rd_wen && (pipe0_rd != 5'd0) && (pipe0_rd == ro_rs1_addr);
wire p1_match_a = pipe1_valid && pipe1_rd_wen && (pipe1_rd != 5'd0) && (pipe1_rd == ro_rs1_addr);
wire mm_match_a = mem_valid   && mem_rd_wen   && (mem_rd   != 5'd0) && (mem_rd   == ro_rs1_addr);

wire p0_match_b = pipe0_valid && pipe0_rd_wen && (pipe0_rd != 5'd0) && (pipe0_rd == ro_rs2_addr);
wire p1_match_b = pipe1_valid && pipe1_rd_wen && (pipe1_rd != 5'd0) && (pipe1_rd == ro_rs2_addr);
wire mm_match_b = mem_valid   && mem_rd_wen   && (mem_rd   != 5'd0) && (mem_rd   == ro_rs2_addr);

// ─── Priority MUX: pipe0 > pipe1 > mem > regfile ────────────────────────────
assign op_a = p0_match_a ? pipe0_data :
              p1_match_a ? pipe1_data :
              mm_match_a ? mem_data   :
                           ro_rs1_regdata;

assign op_b = p0_match_b ? pipe0_data :
              p1_match_b ? pipe1_data :
              mm_match_b ? mem_data   :
                           ro_rs2_regdata;

// Debug indicators
assign fwd_src_a = p0_match_a ? 2'b01 : p1_match_a ? 2'b10 : mm_match_a ? 2'b11 : 2'b00;
assign fwd_src_b = p0_match_b ? 2'b01 : p1_match_b ? 2'b10 : mm_match_b ? 2'b11 : 2'b00;

endmodule
