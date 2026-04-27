// =============================================================================
// Module : bypass_network
// Description: Dual-pipe forwarding / bypass network.
//   Resolves RAW hazards by forwarding results from:
//     1) Pipe 0 EX-stage writeback
//     2) Pipe 1 EX-stage writeback
//     3) MEM stage writeback (load data)
//   Priority: pipe0_ex > pipe1_ex > mem_wb > regfile (most recent wins)
//
//   IMPORTANT: Thread ID must match for forwarding to work correctly in SMT mode.
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
    input  wire [0:0]          ro_tid,           // requesting thread ID
    input  wire                tagbuf_rs1_valid,
    input  wire [DATA_W-1:0]   tagbuf_rs1_data,
    input  wire                tagbuf_rs2_valid,
    input  wire [DATA_W-1:0]   tagbuf_rs2_data,

    // ─── Pipe 0 result (EX stage, 1-cycle ALU) ──────────────────
    input  wire                pipe0_valid,
    input  wire [4:0]          pipe0_rd,
    input  wire                pipe0_rd_wen,
    input  wire [DATA_W-1:0]   pipe0_data,
    input  wire [0:0]          pipe0_tid,

    // ─── Pipe 1 result (EX stage, ALU / MUL / AGU) ──────────────
    input  wire                pipe1_valid,
    input  wire [4:0]          pipe1_rd,
    input  wire                pipe1_rd_wen,
    input  wire [DATA_W-1:0]   pipe1_data,
    input  wire [0:0]          pipe1_tid,

    // ─── MEM stage result (load writeback, 1 cycle later) ───────
    input  wire                mem_valid,
    input  wire [4:0]          mem_rd,
    input  wire                mem_rd_wen,
    input  wire [DATA_W-1:0]   mem_data,
    input  wire [0:0]          mem_tid,

    // ─── Bypassed operands ──────────────────────────────────────
    output wire [DATA_W-1:0]   op_a,
    output wire [DATA_W-1:0]   op_b,

    // ─── Forward hit indicators (for debug / perf counters) ─────
    output wire [1:0]          fwd_src_a,    // 00=reg, 01=pipe0, 10=pipe1, 11=mem
    output wire [1:0]          fwd_src_b
);

// ─── Forwarding match detection ─────────────────────────────────────────────
// Pipeline-stage forwarding (pipe0/pipe1/mem) is DISABLED for the OoO+PRF
// backend.  With rename + PRF + WAKE_HOLD ≥ 1, the PRF already contains the
// correct value by the time the consumer issues (1 cycle after wakeup).
// Matching on architectural register addresses would be incorrect in OoO
// because multiple in-flight instructions can target the same arch reg.
// The tag-indexed result buffer (tagbuf) is still used for same-cycle
// forwarding keyed on the producing *tag*, which is unique.

wire p0_match_a = 1'b0;
wire p1_match_a = 1'b0;
wire mm_match_a = 1'b0;

wire p0_match_b = 1'b0;
wire p1_match_b = 1'b0;
wire mm_match_b = 1'b0;

// ─── Priority MUX: result-buffer (tag-indexed) > PRF ────────────────────────
assign op_a = tagbuf_rs1_valid ? tagbuf_rs1_data :
                                 ro_rs1_regdata;

assign op_b = tagbuf_rs2_valid ? tagbuf_rs2_data :
                                 ro_rs2_regdata;

// Debug indicators
assign fwd_src_a = tagbuf_rs1_valid ? 2'b11 : 2'b00;
assign fwd_src_b = tagbuf_rs2_valid ? 2'b11 : 2'b00;

endmodule
