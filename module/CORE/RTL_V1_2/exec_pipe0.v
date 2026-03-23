// =============================================================================
// Module : exec_pipe0
// Description: Execution Pipeline 0 — Integer ALU + Branch Resolution
//   Single-cycle latency for all integer and branch operations.
//   Generates branch redirect signals (br_ctrl, br_addr) fed back to IF stage.
//   Wraps the existing alu_control + alu modules.
//
//   Pipeline stages: RO → EX (1 cycle) → WB
// =============================================================================
`include "define.v"

module exec_pipe0 #(
    parameter TAG_W = 5
)(
    input  wire               clk,
    input  wire               rstn,

    // ─── Input from Issue / RO stage ────────────────────────────
    input  wire               in_valid,
    input  wire [TAG_W-1:0]   in_tag,        // scoreboard tag
    input  wire [31:0]        in_pc,
    input  wire [31:0]        in_op_a,       // rs1 data (after bypass)
    input  wire [31:0]        in_op_b,       // rs2 data (after bypass)
    input  wire [31:0]        in_imm,
    input  wire [2:0]         in_func3,
    input  wire               in_func7,
    input  wire [2:0]         in_alu_op,
    input  wire [1:0]         in_alu_src1,
    input  wire [1:0]         in_alu_src2,
    input  wire               in_br_addr_mode,
    input  wire               in_br,         // is branch / jump
    input  wire [4:0]         in_rd,
    input  wire               in_regs_write,
    input  wire [2:0]         in_fu,
    input  wire [0:0]         in_tid,

    // ─── ALU result output (to WB and bypass network) ───────────
    output wire               out_valid,
    output wire [TAG_W-1:0]   out_tag,
    output wire [31:0]        out_result,
    output wire [4:0]         out_rd,
    output wire               out_regs_write,
    output wire [2:0]         out_fu,
    output wire [0:0]         out_tid,

    // ─── Branch resolution (to IF stage via top-level) ──────────
    output wire               br_ctrl,       // branch taken
    output wire [31:0]        br_addr,       // branch target address
    output wire [0:0]         br_tid         // which thread branched
);

// ─── ALU control ────────────────────────────────────────────────────────────
wire [3:0] alu_ctrl;

alu_control u_alu_control (
    .alu_op     (in_alu_op  ),
    .func3_code (in_func3   ),
    .func7_code (in_func7   ),
    .alu_ctrl_r (alu_ctrl   )
);

// ─── Operand selection (same logic as original stage_ex) ────────────────────
wire [31:0] op_A_pre = in_op_a;
wire [31:0] op_B_pre = in_op_b;
wire [31:0] op_A, op_B;

assign op_A = (in_alu_src1 == `NULL) ? 32'd0 :
              (in_alu_src1 == `PC)   ? in_pc  : op_A_pre;
assign op_B = (in_alu_src2 == `PC_PLUS4) ? 32'd4  :
              (in_alu_src2 == `IMM)      ? in_imm  : op_B_pre;

// ─── ALU ────────────────────────────────────────────────────────────────────
wire [31:0] alu_out;
wire        br_mark;

alu u_alu (
    .alu_ctrl (alu_ctrl),
    .op_A     (op_A    ),
    .op_B     (op_B    ),
    .alu_o    (alu_out ),
    .br_mark  (br_mark )
);

// ─── Branch target ──────────────────────────────────────────────────────────
wire [31:0] br_addr_op_A;
assign br_addr_op_A = (in_br_addr_mode == `J_REG) ? op_A_pre : in_pc;

// ─── Output: single-cycle, directly combinational ───────────────────────────
assign out_valid      = in_valid;
assign out_tag        = in_tag;
assign out_result     = alu_out;
assign out_rd         = in_rd;
assign out_regs_write = in_regs_write;
assign out_fu         = in_fu;
assign out_tid        = in_tid;

assign br_ctrl = in_valid && in_br && br_mark;
assign br_addr = br_addr_op_A + in_imm;
assign br_tid  = in_tid;

endmodule
