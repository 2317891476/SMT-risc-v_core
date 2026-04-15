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
    input  wire [4:0]         in_rs1_idx,    // rs1 index (used for CSR zimm ops)
    input  wire [31:0]        in_imm,
    input  wire [15:0]        in_order_id,   // per-thread order id for flush bookkeeping
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

    // ─── CSR/MRET inputs ────────────────────────────────────────
    input  wire               in_is_csr,     // CSR instruction
    input  wire               in_is_mret,    // MRET instruction
    input  wire [11:0]        in_csr_addr,   // CSR address
    input  wire [31:0]        csr_rdata,     // CSR read data from csr_unit

    // ─── ALU result output (to WB and bypass network) ───────────
    output wire               out_valid,
    output wire [TAG_W-1:0]   out_tag,
    output wire [31:0]        out_result,
    output wire [4:0]         out_rd,
    output wire               out_regs_write,
    output wire [2:0]         out_fu,
    output wire [0:0]         out_tid,

    // ─── CSR outputs ────────────────────────────────────────────
    output wire               csr_valid,     // CSR instruction executed
    output wire [31:0]        csr_wdata,     // CSR write data
    output wire [2:0]         csr_op,        // CSR operation
    output wire [11:0]        csr_addr,      // CSR address
    output wire               mret_valid,    // MRET executed
    output wire [`METADATA_ORDER_ID_W-1:0] mret_order_id, // MRET order ID for flush

    // ─── Branch resolution (to IF stage via top-level) ──────────
    output wire               br_ctrl,       // branch taken
    output wire [31:0]        br_addr,       // branch target address
    output wire [0:0]         br_tid,        // which thread branched
    output wire [15:0]        br_order_id,   // branch order id when redirecting
    output wire               br_complete    // branch execution complete (taken or not)
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
wire        csr_is_imm = in_is_csr && in_func3[2];
wire [31:0] csr_write_data = csr_is_imm ? {27'd0, in_rs1_idx} : in_op_a;

alu u_alu (
    .alu_ctrl (alu_ctrl),
    .op_A     (op_A    ),
    .op_B     (op_B    ),
    .alu_o    (alu_out ),
    .br_mark  (br_mark )
);

// ─── Output: single-cycle, with output registers for proper timing ─────────
reg               out_valid_r;
reg [TAG_W-1:0]   out_tag_r;
reg [31:0]        out_result_r;
reg [4:0]         out_rd_r;
reg               out_regs_write_r;
reg [2:0]         out_fu_r;
reg [0:0]         out_tid_r;
reg               br_ctrl_r;
reg [31:0]        br_addr_r;
reg [0:0]         br_tid_r;
reg [15:0]        br_order_id_r;
reg               br_complete_r;   // branch execution complete

// Store issue-time values for branch resolution (these are used 1 cycle later)
reg [31:0]        stored_pc;
reg [31:0]        stored_imm;
reg [31:0]        stored_op_a;     // for JALR
reg [15:0]        stored_order_id;
reg               stored_br;
reg               stored_br_addr_mode;
reg               stored_valid;
reg               stored_br_mark;  // store the branch decision

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        out_valid_r         <= 1'b0;
        out_tag_r           <= {TAG_W{1'b0}};
        out_result_r        <= 32'd0;
        out_rd_r            <= 5'd0;
        out_regs_write_r    <= 1'b0;
        out_fu_r            <= 3'd0;
        out_tid_r           <= 1'b0;
        br_ctrl_r           <= 1'b0;
        br_addr_r           <= 32'd0;
        br_tid_r            <= 1'b0;
        br_order_id_r       <= 16'd0;
        br_complete_r       <= 1'b0;
        stored_pc           <= 32'd0;
        stored_imm          <= 32'd0;
        stored_op_a         <= 32'd0;
        stored_order_id     <= 16'd0;
        stored_br           <= 1'b0;
        stored_br_addr_mode <= 1'b0;
        stored_valid        <= 1'b0;
        stored_br_mark      <= 1'b0;
    end else begin
        // Store issue-time values (including br_mark computed from current inputs)
        stored_pc           <= in_pc;
        stored_imm          <= in_imm;
        stored_op_a         <= op_A_pre;   // for JALR (rs1 value)
        stored_order_id     <= in_order_id;
        stored_br           <= in_br;
        stored_br_addr_mode <= in_br_addr_mode;
        stored_valid        <= in_valid;
        stored_br_mark      <= br_mark;

        `ifdef VERBOSE_SIM_LOGS
        if (in_valid) begin
            $display("EXEC0: PC=%h, in_br=%b, br_mark=%b", in_pc, in_br, br_mark);
        end
        `endif

        // Output registers (1 cycle delay)
        out_valid_r      <= in_valid;
        out_tag_r        <= in_tag;
        out_result_r     <= in_is_csr ? csr_rdata : alu_out;
        out_rd_r         <= in_rd;
        out_regs_write_r <= in_regs_write;
        out_fu_r         <= in_fu;
        out_tid_r        <= in_tid;

        // Branch resolution uses stored values from previous cycle
        br_ctrl_r     <= stored_valid && stored_br && stored_br_mark;
        br_addr_r     <= (stored_br_addr_mode == `J_REG) ? (stored_op_a + stored_imm) : (stored_pc + stored_imm);
        br_tid_r      <= out_tid_r;  // use output register's tid
        br_order_id_r <= stored_order_id;
        br_complete_r <= stored_valid && stored_br;
    end
end

assign out_valid      = out_valid_r;
assign out_tag        = out_tag_r;
assign out_result     = out_result_r;
assign out_rd         = out_rd_r;
assign out_regs_write = out_regs_write_r;
assign out_fu         = out_fu_r;
assign out_tid        = out_tid_r;

assign csr_valid  = in_valid && in_is_csr;
assign csr_wdata  = csr_write_data;
assign csr_op     = in_func3;    // funct3 encodes CSR operation
assign csr_addr   = in_csr_addr;
assign mret_valid    = in_valid && in_is_mret;
assign mret_order_id = in_order_id;

assign br_ctrl     = br_ctrl_r;
assign br_addr     = br_addr_r;
assign br_tid      = br_tid_r;
assign br_order_id = br_order_id_r;
assign br_complete = br_complete_r;

endmodule
