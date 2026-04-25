`timescale 1ns/1ns
// =============================================================================
// Module : dispatch_unit
// Description: Drop-in replacement for the scoreboard.
//   Internally uses 4 split issue-queues (INT/MEM/MUL/DIV) plus a shared
//   tag pool and reg_result table for dependency tracking.
//
//   IQ_INT  : 8 entries — FU_INT0, FU_INT1, FU_NOP → issues to pipe0
//   IQ_MEM  : 4 entries — FU_LOAD, FU_STORE          → issues to pipe1
//   IQ_MUL  : 4 entries — FU_MUL                     → issues to pipe1
//   IQ_DIV  : 4 entries — FU_DIV                     → issues to pipe1
//   Pipe1 winner is chosen by iq_pipe1_arbiter (oldest-first).
//
//   Port interface is identical to scoreboard.v for drop-in swap.
// =============================================================================
`include "define.v"

module dispatch_unit #(
    parameter RS_DEPTH   = 16,
    parameter RS_IDX_W   = 4,
    parameter RS_TAG_W   = 5,
    parameter NUM_FU     = 8,
    parameter NUM_THREAD = 2
)(
    input  wire        clk,
    input  wire        rstn,

    // ─── Flush ───────────────────────────────────────────────────
    input  wire        flush,
    input  wire [0:0]  flush_tid,
    input  wire        flush_order_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] flush_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]  flush_new_epoch,

    // ─── Dispatch Port 0 ────────────────────────────────────────
    input  wire        disp0_valid,
    input  wire [31:0] disp0_pc,
    input  wire [31:0] disp0_imm,
    input  wire [2:0]  disp0_func3,
    input  wire        disp0_func7,
    input  wire [4:0]  disp0_rd,
    input  wire        disp0_br,
    input  wire        disp0_mem_read,
    input  wire        disp0_mem2reg,
    input  wire [2:0]  disp0_alu_op,
    input  wire        disp0_mem_write,
    input  wire [1:0]  disp0_alu_src1,
    input  wire [1:0]  disp0_alu_src2,
    input  wire        disp0_br_addr_mode,
    input  wire        disp0_regs_write,
    input  wire [4:0]  disp0_rs1,
    input  wire [4:0]  disp0_rs2,
    input  wire        disp0_rs1_used,
    input  wire        disp0_rs2_used,
    input  wire [2:0]  disp0_fu,
    input  wire [0:0]  disp0_tid,
    input  wire        disp0_is_mret,
    input  wire        disp0_is_csr,
    input  wire        disp0_is_rocc,

    // ─── Dispatch Port 1 ────────────────────────────────────────
    input  wire        disp1_valid,
    input  wire [31:0] disp1_pc,
    input  wire [31:0] disp1_imm,
    input  wire [2:0]  disp1_func3,
    input  wire        disp1_func7,
    input  wire [4:0]  disp1_rd,
    input  wire        disp1_br,
    input  wire        disp1_mem_read,
    input  wire        disp1_mem2reg,
    input  wire [2:0]  disp1_alu_op,
    input  wire        disp1_mem_write,
    input  wire [1:0]  disp1_alu_src1,
    input  wire [1:0]  disp1_alu_src2,
    input  wire        disp1_br_addr_mode,
    input  wire        disp1_regs_write,
    input  wire [4:0]  disp1_rs1,
    input  wire [4:0]  disp1_rs2,
    input  wire        disp1_rs1_used,
    input  wire        disp1_rs2_used,
    input  wire [2:0]  disp1_fu,
    input  wire [0:0]  disp1_tid,
    input  wire        disp1_is_mret,
    input  wire        disp1_is_csr,
    input  wire        disp1_is_rocc,

    // ─── Stall ───────────────────────────────────────────────────
    output wire        disp_stall,
    output wire        disp1_blocked,  // d1 valid but couldn't dispatch (d0 went)

    // ─── Dispatch Tag Outputs ────────────────────────────────────
    output wire [RS_TAG_W-1:0] disp0_tag,
    output wire [RS_TAG_W-1:0] disp1_tag,

    // ─── Dispatch Metadata ──────────────────────────────────────
    input  wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]    disp0_epoch,
    input  wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]    disp1_epoch,

    // ─── Issue Port 0 (Pipe0: INT) ──────────────────────────────
    output wire        iss0_valid,
    output wire [RS_TAG_W-1:0] iss0_tag,
    output wire [31:0] iss0_pc,
    output wire [31:0] iss0_imm,
    output wire [2:0]  iss0_func3,
    output wire        iss0_func7,
    output wire [4:0]  iss0_rd,
    output wire [4:0]  iss0_rs1,
    output wire [4:0]  iss0_rs2,
    output wire        iss0_rs1_used,
    output wire        iss0_rs2_used,
    output wire [RS_TAG_W-1:0] iss0_src1_tag,
    output wire [RS_TAG_W-1:0] iss0_src2_tag,
    output wire        iss0_br,
    output wire        iss0_mem_read,
    output wire        iss0_mem2reg,
    output wire [2:0]  iss0_alu_op,
    output wire        iss0_mem_write,
    output wire [1:0]  iss0_alu_src1,
    output wire [1:0]  iss0_alu_src2,
    output wire        iss0_br_addr_mode,
    output wire        iss0_regs_write,
    output wire [2:0]  iss0_fu,
    output wire [0:0]  iss0_tid,
    output wire [`METADATA_ORDER_ID_W-1:0] iss0_order_id,
    output wire [`METADATA_EPOCH_W-1:0]    iss0_epoch,

    // ─── Issue Port 1 (Pipe1: MEM/MUL) ─────────────────────────
    output wire        p1_winner_valid,
    output wire [1:0]  p1_winner,
    output reg         p1_mem_cand_valid,
    output reg  [RS_TAG_W-1:0] p1_mem_cand_tag,
    output reg  [31:0] p1_mem_cand_pc,
    output reg  [31:0] p1_mem_cand_imm,
    output reg  [2:0]  p1_mem_cand_func3,
    output reg         p1_mem_cand_func7,
    output reg  [4:0]  p1_mem_cand_rd,
    output reg  [4:0]  p1_mem_cand_rs1,
    output reg  [4:0]  p1_mem_cand_rs2,
    output reg         p1_mem_cand_rs1_used,
    output reg         p1_mem_cand_rs2_used,
    output reg  [RS_TAG_W-1:0] p1_mem_cand_src1_tag,
    output reg  [RS_TAG_W-1:0] p1_mem_cand_src2_tag,
    output reg         p1_mem_cand_br,
    output reg         p1_mem_cand_mem_read,
    output reg         p1_mem_cand_mem2reg,
    output reg  [2:0]  p1_mem_cand_alu_op,
    output reg         p1_mem_cand_mem_write,
    output reg  [1:0]  p1_mem_cand_alu_src1,
    output reg  [1:0]  p1_mem_cand_alu_src2,
    output reg         p1_mem_cand_br_addr_mode,
    output reg         p1_mem_cand_regs_write,
    output reg  [2:0]  p1_mem_cand_fu,
    output reg  [0:0]  p1_mem_cand_tid,
    output reg         p1_mem_cand_is_mret,
    output reg  [`METADATA_ORDER_ID_W-1:0] p1_mem_cand_order_id,
    output reg  [`METADATA_EPOCH_W-1:0]    p1_mem_cand_epoch,
    output reg         p1_mul_cand_valid,
    output reg  [RS_TAG_W-1:0] p1_mul_cand_tag,
    output reg  [31:0] p1_mul_cand_pc,
    output reg  [31:0] p1_mul_cand_imm,
    output reg  [2:0]  p1_mul_cand_func3,
    output reg         p1_mul_cand_func7,
    output reg  [4:0]  p1_mul_cand_rd,
    output reg  [4:0]  p1_mul_cand_rs1,
    output reg  [4:0]  p1_mul_cand_rs2,
    output reg         p1_mul_cand_rs1_used,
    output reg         p1_mul_cand_rs2_used,
    output reg  [RS_TAG_W-1:0] p1_mul_cand_src1_tag,
    output reg  [RS_TAG_W-1:0] p1_mul_cand_src2_tag,
    output reg         p1_mul_cand_br,
    output reg         p1_mul_cand_mem_read,
    output reg         p1_mul_cand_mem2reg,
    output reg  [2:0]  p1_mul_cand_alu_op,
    output reg         p1_mul_cand_mem_write,
    output reg  [1:0]  p1_mul_cand_alu_src1,
    output reg  [1:0]  p1_mul_cand_alu_src2,
    output reg         p1_mul_cand_br_addr_mode,
    output reg         p1_mul_cand_regs_write,
    output reg  [2:0]  p1_mul_cand_fu,
    output reg  [0:0]  p1_mul_cand_tid,
    output reg         p1_mul_cand_is_mret,
    output reg  [`METADATA_ORDER_ID_W-1:0] p1_mul_cand_order_id,
    output reg  [`METADATA_EPOCH_W-1:0]    p1_mul_cand_epoch,
    output reg         p1_div_cand_valid,
    output reg  [RS_TAG_W-1:0] p1_div_cand_tag,
    output reg  [31:0] p1_div_cand_pc,
    output reg  [31:0] p1_div_cand_imm,
    output reg  [2:0]  p1_div_cand_func3,
    output reg         p1_div_cand_func7,
    output reg  [4:0]  p1_div_cand_rd,
    output reg  [4:0]  p1_div_cand_rs1,
    output reg  [4:0]  p1_div_cand_rs2,
    output reg         p1_div_cand_rs1_used,
    output reg         p1_div_cand_rs2_used,
    output reg  [RS_TAG_W-1:0] p1_div_cand_src1_tag,
    output reg  [RS_TAG_W-1:0] p1_div_cand_src2_tag,
    output reg         p1_div_cand_br,
    output reg         p1_div_cand_mem_read,
    output reg         p1_div_cand_mem2reg,
    output reg  [2:0]  p1_div_cand_alu_op,
    output reg         p1_div_cand_mem_write,
    output reg  [1:0]  p1_div_cand_alu_src1,
    output reg  [1:0]  p1_div_cand_alu_src2,
    output reg         p1_div_cand_br_addr_mode,
    output reg         p1_div_cand_regs_write,
    output reg  [2:0]  p1_div_cand_fu,
    output reg  [0:0]  p1_div_cand_tid,
    output reg         p1_div_cand_is_mret,
    output reg  [`METADATA_ORDER_ID_W-1:0] p1_div_cand_order_id,
    output reg  [`METADATA_EPOCH_W-1:0]    p1_div_cand_epoch,
    output wire        branch_pending_any,
    output wire        debug_br_found_t0,
    output wire        debug_branch_in_flight_t0,
    output wire        debug_oldest_br_ready_t0,
    output wire        debug_oldest_br_just_woke_t0,
    output wire [3:0]  debug_oldest_br_qj_t0,
    output wire [3:0]  debug_oldest_br_qk_t0,
    output wire [3:0]  debug_slot1_flags,
    output wire [7:0]  debug_slot1_pc_lo,
    output wire [3:0]  debug_slot1_qj,
    output wire [3:0]  debug_slot1_qk,
    output wire [3:0]  debug_tag2_flags,
    output wire [3:0]  debug_reg_x12_tag_t0,
    output wire [3:0]  debug_slot1_issue_flags,
    output wire [3:0]  debug_sel0_idx,
    output wire [3:0]  debug_slot1_fu,
    output wire [7:0]  debug_oldest_br_seq_lo_t0,
    output wire [15:0] debug_rs_flags_flat,
    output wire [31:0] debug_rs_pc_lo_flat,
    output wire [15:0] debug_rs_fu_flat,
    output wire [15:0] debug_rs_qj_flat,
    output wire [15:0] debug_rs_qk_flat,
    output wire [31:0] debug_rs_seq_lo_flat,
    output wire        debug_spec_dispatch0,
    output wire        debug_spec_dispatch1,
    output wire        debug_branch_gated_mem_issue,
    output wire        debug_flush_killed_speculative,

    // ─── Writeback Ports ────────────────────────────────────────
    input  wire        wb0_valid,
    input  wire [RS_TAG_W-1:0] wb0_tag,
    input  wire [4:0]  wb0_rd,
    input  wire        wb0_regs_write,
    input  wire [2:0]  wb0_fu,
    input  wire [0:0]  wb0_tid,
    input  wire        wb1_valid,
    input  wire [RS_TAG_W-1:0] wb1_tag,
    input  wire [4:0]  wb1_rd,
    input  wire        wb1_regs_write,
    input  wire [2:0]  wb1_fu,
    input  wire [0:0]  wb1_tid,

    // ─── LSU Early Wakeup ──────────────────────────────────────
    input  wire        lsu_early_wakeup_valid,
    input  wire [RS_TAG_W-1:0] lsu_early_wakeup_tag,

    // ─── Commit Ports ───────────────────────────────────────────
    input  wire        commit0_valid,
    input  wire [RS_TAG_W-1:0] commit0_tag,
    input  wire [0:0]  commit0_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id,
    input  wire        commit1_valid,
    input  wire [RS_TAG_W-1:0] commit1_tag,
    input  wire [0:0]  commit1_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] commit1_order_id,

    // ─── Branch Completion ──────────────────────────────────────
    input  wire        br_complete,
    input  wire [0:0]  br_complete_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] br_complete_order_id,

    // ─── RoCC ───────────────────────────────────────────────────
    input  wire        rocc_ready,
    output wire        iss0_is_rocc
);

localparam P1_CAND_BUNDLE_W = (RS_TAG_W * 3) + 32 + 32 + 3 + 1 +
                              5 + 5 + 5 + 1 + 1 +
                              1 + 1 + 1 + 3 + 1 + 2 + 2 + 1 + 1 +
                              3 + 1 + 1 +
                              `METADATA_ORDER_ID_W + `METADATA_EPOCH_W;

// ═════════════════════════════════════════════════════════════════
// Tag Pool (tags 1 .. RS_DEPTH)
// ═════════════════════════════════════════════════════════════════
reg  tag_in_use    [0:RS_DEPTH];  // index 0 unused
reg  [0:RS_DEPTH]  tag_ready_v;   // packed — Icarus needs this for always @(*) sensitivity
reg  tag_just_ready[0:RS_DEPTH];
reg [RS_TAG_W-1:0] tag_live_order [0:RS_DEPTH]; // NOT USED YET but reserved

// Combinational free-tag scan
reg                free0_found, free1_found;
reg [RS_TAG_W-1:0] free0_tag,   free1_tag;
integer fti;
always @(*) begin
    free0_found = 1'b0; free1_found = 1'b0;
    free0_tag   = {RS_TAG_W{1'b0}};
    free1_tag   = {RS_TAG_W{1'b0}};
    for (fti = 1; fti <= RS_DEPTH; fti = fti + 1) begin
        if (!tag_in_use[fti] && !free0_found) begin
            free0_found = 1'b1;
            free0_tag   = fti[RS_TAG_W-1:0];
        end
        else if (!tag_in_use[fti] && free0_found && !free1_found) begin
            free1_found = 1'b1;
            free1_tag   = fti[RS_TAG_W-1:0];
        end
    end
end

wire can_accept_1 = free0_found;
wire can_accept_2 = free0_found && free1_found;

assign disp0_tag = free0_tag;
assign disp1_tag = free1_tag;

// ═════════════════════════════════════════════════════════════════
// 2. reg_result Table (per-thread × 32 arch regs → producing tag)
// ═════════════════════════════════════════════════════════════════
reg [RS_TAG_W-1:0] reg_result       [0:NUM_THREAD-1][0:31];
reg [`METADATA_ORDER_ID_W-1:0] reg_result_order [0:NUM_THREAD-1][0:31];

// Tag-liveness tracking (matches scoreboard's approach)
reg  [0:RS_DEPTH]  tag_live_valid_v;
reg [`METADATA_ORDER_ID_W-1:0] tag_live_seq [0:RS_DEPTH];
reg [`METADATA_ORDER_ID_W-1:0] tag_ready_seq [0:RS_DEPTH];
reg  [0:0] tag_live_tid [0:RS_DEPTH];

// ═════════════════════════════════════════════════════════════════
// 3. Dependency Lookup (combinational)
// ═════════════════════════════════════════════════════════════════
// Inline dependency checks using packed vectors for proper Icarus
// Verilog sensitivity tracking in always @(*) blocks.

wire alloc0_wr = disp0_valid && disp0_regs_write && (disp0_rd != 5'd0);
wire alloc1_wr = disp1_valid && disp1_regs_write && (disp1_rd != 5'd0);

// Disp0 deps — no same-cycle forwarding from disp0 itself
reg [RS_TAG_W-1:0] d0_src1, d0_src2;
reg [`METADATA_ORDER_ID_W-1:0] d0_src1_order, d0_src2_order;
always @(*) begin : dep_lookup_d0
    reg [RS_TAG_W-1:0] t1, t2;
    reg src1_commit_ready, src2_commit_ready;
    t1 = reg_result[disp0_tid][disp0_rs1];
    t2 = reg_result[disp0_tid][disp0_rs2];
    src1_commit_ready =
        (commit0_valid && (commit0_tid == disp0_tid) && (commit0_tag == t1) &&
         (commit0_order_id == reg_result_order[disp0_tid][disp0_rs1])) ||
        (commit1_valid && (commit1_tid == disp0_tid) && (commit1_tag == t1) &&
         (commit1_order_id == reg_result_order[disp0_tid][disp0_rs1]));
    src2_commit_ready =
        (commit0_valid && (commit0_tid == disp0_tid) && (commit0_tag == t2) &&
         (commit0_order_id == reg_result_order[disp0_tid][disp0_rs2])) ||
        (commit1_valid && (commit1_tid == disp0_tid) && (commit1_tag == t2) &&
         (commit1_order_id == reg_result_order[disp0_tid][disp0_rs2]));

    // d0_src1
    d0_src1_order = {`METADATA_ORDER_ID_W{1'b0}};
    if (!disp0_rs1_used)
        d0_src1 = {RS_TAG_W{1'b0}};
    else if (t1 != {RS_TAG_W{1'b0}} && tag_live_valid_v[t1] &&
             tag_live_seq[t1] == reg_result_order[disp0_tid][disp0_rs1]) begin
        if ((tag_ready_v[t1] && tag_ready_seq[t1] == reg_result_order[disp0_tid][disp0_rs1]) ||
            src1_commit_ready)
            d0_src1 = {RS_TAG_W{1'b0}};
        else if (wb0_valid && wb0_regs_write && wb0_tag == t1)
            d0_src1 = {RS_TAG_W{1'b0}};
        else if (wb1_valid && wb1_regs_write && wb1_tag == t1)
            d0_src1 = {RS_TAG_W{1'b0}};
        else begin
            d0_src1 = t1;
            d0_src1_order = reg_result_order[disp0_tid][disp0_rs1];
        end
    end
    else
        d0_src1 = {RS_TAG_W{1'b0}};

    // d0_src2
    d0_src2_order = {`METADATA_ORDER_ID_W{1'b0}};
    if (!disp0_rs2_used)
        d0_src2 = {RS_TAG_W{1'b0}};
    else if (t2 != {RS_TAG_W{1'b0}} && tag_live_valid_v[t2] &&
             tag_live_seq[t2] == reg_result_order[disp0_tid][disp0_rs2]) begin
        if ((tag_ready_v[t2] && tag_ready_seq[t2] == reg_result_order[disp0_tid][disp0_rs2]) ||
            src2_commit_ready)
            d0_src2 = {RS_TAG_W{1'b0}};
        else if (wb0_valid && wb0_regs_write && wb0_tag == t2)
            d0_src2 = {RS_TAG_W{1'b0}};
        else if (wb1_valid && wb1_regs_write && wb1_tag == t2)
            d0_src2 = {RS_TAG_W{1'b0}};
        else begin
            d0_src2 = t2;
            d0_src2_order = reg_result_order[disp0_tid][disp0_rs2];
        end
    end
    else
        d0_src2 = {RS_TAG_W{1'b0}};
end

// Disp1 deps — check same-cycle RAW from disp0
reg [RS_TAG_W-1:0] d1_src1, d1_src2;
reg [`METADATA_ORDER_ID_W-1:0] d1_src1_order, d1_src2_order;
always @(*) begin : dep_lookup_d1
    reg [RS_TAG_W-1:0] t1, t2;
    reg src1_commit_ready, src2_commit_ready;
    t1 = reg_result[disp1_tid][disp1_rs1];
    t2 = reg_result[disp1_tid][disp1_rs2];
    src1_commit_ready =
        (commit0_valid && (commit0_tid == disp1_tid) && (commit0_tag == t1) &&
         (commit0_order_id == reg_result_order[disp1_tid][disp1_rs1])) ||
        (commit1_valid && (commit1_tid == disp1_tid) && (commit1_tag == t1) &&
         (commit1_order_id == reg_result_order[disp1_tid][disp1_rs1]));
    src2_commit_ready =
        (commit0_valid && (commit0_tid == disp1_tid) && (commit0_tag == t2) &&
         (commit0_order_id == reg_result_order[disp1_tid][disp1_rs2])) ||
        (commit1_valid && (commit1_tid == disp1_tid) && (commit1_tag == t2) &&
         (commit1_order_id == reg_result_order[disp1_tid][disp1_rs2]));

    // d1_src1
    d1_src1_order = {`METADATA_ORDER_ID_W{1'b0}};
    if (!disp1_rs1_used)
        d1_src1 = {RS_TAG_W{1'b0}};
    else if (alloc0_wr && disp0_rd == disp1_rs1 && disp0_tid == disp1_tid) begin
        d1_src1 = free0_tag;
        d1_src1_order = disp0_order_id;
    end
    else if (t1 != {RS_TAG_W{1'b0}} && tag_live_valid_v[t1] &&
             tag_live_seq[t1] == reg_result_order[disp1_tid][disp1_rs1]) begin
        if ((tag_ready_v[t1] && tag_ready_seq[t1] == reg_result_order[disp1_tid][disp1_rs1]) ||
            src1_commit_ready)
            d1_src1 = {RS_TAG_W{1'b0}};
        else if (wb0_valid && wb0_regs_write && wb0_tag == t1)
            d1_src1 = {RS_TAG_W{1'b0}};
        else if (wb1_valid && wb1_regs_write && wb1_tag == t1)
            d1_src1 = {RS_TAG_W{1'b0}};
        else begin
            d1_src1 = t1;
            d1_src1_order = reg_result_order[disp1_tid][disp1_rs1];
        end
    end
    else
        d1_src1 = {RS_TAG_W{1'b0}};

    // d1_src2
    d1_src2_order = {`METADATA_ORDER_ID_W{1'b0}};
    if (!disp1_rs2_used)
        d1_src2 = {RS_TAG_W{1'b0}};
    else if (alloc0_wr && disp0_rd == disp1_rs2 && disp0_tid == disp1_tid) begin
        d1_src2 = free0_tag;
        d1_src2_order = disp0_order_id;
    end
    else if (t2 != {RS_TAG_W{1'b0}} && tag_live_valid_v[t2] &&
             tag_live_seq[t2] == reg_result_order[disp1_tid][disp1_rs2]) begin
        if ((tag_ready_v[t2] && tag_ready_seq[t2] == reg_result_order[disp1_tid][disp1_rs2]) ||
            src2_commit_ready)
            d1_src2 = {RS_TAG_W{1'b0}};
        else if (wb0_valid && wb0_regs_write && wb0_tag == t2)
            d1_src2 = {RS_TAG_W{1'b0}};
        else if (wb1_valid && wb1_regs_write && wb1_tag == t2)
            d1_src2 = {RS_TAG_W{1'b0}};
        else begin
            d1_src2 = t2;
            d1_src2_order = reg_result_order[disp1_tid][disp1_rs2];
        end
    end
    else
        d1_src2 = {RS_TAG_W{1'b0}};
end

// ═════════════════════════════════════════════════════════════════
// 4. Dispatch Routing (FU → IQ)
// ═════════════════════════════════════════════════════════════════
wire d0_is_int = (disp0_fu == `FU_INT0) || (disp0_fu == `FU_INT1) || (disp0_fu == `FU_NOP);
wire d0_is_mem = (disp0_fu == `FU_LOAD) || (disp0_fu == `FU_STORE);
wire d0_is_mul = (disp0_fu == `FU_MUL);
wire d0_is_div = (disp0_fu == `FU_DIV);

wire d1_is_int = (disp1_fu == `FU_INT0) || (disp1_fu == `FU_INT1) || (disp1_fu == `FU_NOP);
wire d1_is_mem = (disp1_fu == `FU_LOAD) || (disp1_fu == `FU_STORE);
wire d1_is_mul = (disp1_fu == `FU_MUL);
wire d1_is_div = (disp1_fu == `FU_DIV);
wire d0_side_effect = disp0_is_mret || disp0_is_csr || disp0_is_rocc;
wire d1_side_effect = disp1_is_mret || disp1_is_csr || disp1_is_rocc;

// For each IQ: connect disp0 port from first matching dispatch,
//              disp1 port from second matching dispatch.
// IQ_INT dispatch:
wire iq_int_dp0_valid = disp0_valid && d0_is_int;
wire iq_int_dp0_from1 = !d0_is_int && d1_is_int;  // d1 goes to IQ_INT dp0
wire iq_int_dp1_valid = d0_is_int && disp1_valid && d1_is_int; // both INT
// If d0 not INT, d1 connects on dp0; dp1 unused
wire iq_int_d0_valid = iq_int_dp0_from1 ? (disp1_valid && d1_is_int) : iq_int_dp0_valid;
wire iq_int_d1_valid = iq_int_dp0_from1 ? 1'b0 : iq_int_dp1_valid;

// IQ_MEM dispatch:
wire iq_mem_dp0_from1 = !d0_is_mem && d1_is_mem;
wire iq_mem_d0_valid = iq_mem_dp0_from1 ? (disp1_valid && d1_is_mem) : (disp0_valid && d0_is_mem);
wire iq_mem_d1_valid = (d0_is_mem && disp1_valid && d1_is_mem) && !iq_mem_dp0_from1;

// IQ_MUL dispatch:
wire iq_mul_dp0_from1 = !d0_is_mul && d1_is_mul;
wire iq_mul_d0_valid = iq_mul_dp0_from1 ? (disp1_valid && d1_is_mul) : (disp0_valid && d0_is_mul);
wire iq_mul_d1_valid = (d0_is_mul && disp1_valid && d1_is_mul) && !iq_mul_dp0_from1;

// IQ_DIV dispatch:
wire iq_div_dp0_from1 = !d0_is_div && d1_is_div;
wire iq_div_d0_valid = iq_div_dp0_from1 ? (disp1_valid && d1_is_div) : (disp0_valid && d0_is_div);
wire iq_div_d1_valid = (d0_is_div && disp1_valid && d1_is_div) && !iq_div_dp0_from1;

// Dispatch data mux: when dp0_from1, IQ's disp0 port gets disp1 fields

// ═════════════════════════════════════════════════════════════════
// 5. Branch Tracking
// ═════════════════════════════════════════════════════════════════
reg branch_in_flight_t0, branch_in_flight_t1;
reg br_found_t0_r, br_found_t1_r; // registered version

// Branch found: any INT IQ entry is valid, not issued, is branch
// (We cannot easily scan IQ internals, so we track at dispatch)
reg [5:0] br_pending_cnt_t0, br_pending_cnt_t1;
reg spec_mem_after_branch_t0, spec_mem_after_branch_t1;

localparam BR_TRACK_DEPTH = 32;
localparam BR_TRACK_IDX_W = 5;
reg [BR_TRACK_IDX_W-1:0] br_head_t0, br_tail_t0;
reg [BR_TRACK_IDX_W-1:0] br_head_t1, br_tail_t1;
reg [`METADATA_ORDER_ID_W-1:0] br_order_fifo_t0 [0:BR_TRACK_DEPTH-1];
reg [`METADATA_ORDER_ID_W-1:0] br_order_fifo_t1 [0:BR_TRACK_DEPTH-1];

wire [`METADATA_ORDER_ID_W-1:0] pending_branch_order_id_t0 =
    (br_pending_cnt_t0 != 6'd0) ? br_order_fifo_t0[br_head_t0] :
                                  {`METADATA_ORDER_ID_W{1'b0}};
wire [`METADATA_ORDER_ID_W-1:0] pending_branch_order_id_t1 =
    (br_pending_cnt_t1 != 6'd0) ? br_order_fifo_t1[br_head_t1] :
                                  {`METADATA_ORDER_ID_W{1'b0}};
wire pending_branch_t0 = (br_pending_cnt_t0 != 6'd0);
wire pending_branch_t1 = (br_pending_cnt_t1 != 6'd0);
assign branch_pending_any = pending_branch_t0 || pending_branch_t1;

// IQ issue inhibit: Disabled — the branch dispatch stall is sufficient
// to serialize branches. Instructions already in-flight can issue freely;
// incorrect speculative results are flushed via epoch by the ROB.
wire issue_inhibit_t0 = 1'b0;
wire issue_inhibit_t1 = 1'b0;

wire int_iss_flush_kill =
    flush && int_iss_valid && int_iss_br &&
    (int_iss_tid == flush_tid) &&
    (!flush_order_valid || (int_iss_order_id > flush_order_id));

wire br_push0_t0 = d0_go && disp0_br && (disp0_tid == 1'b0);
wire br_push0_t1 = d0_go && disp0_br && (disp0_tid == 1'b1);
wire br_push1_t0 = d1_go && disp1_br && (disp1_tid == 1'b0);
wire br_push1_t1 = d1_go && disp1_br && (disp1_tid == 1'b1);

// Branch tracking sequential logic
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        integer bi;
        branch_in_flight_t0 <= 1'b0;
        branch_in_flight_t1 <= 1'b0;
        br_pending_cnt_t0   <= 6'd0;
        br_pending_cnt_t1   <= 6'd0;
        br_head_t0 <= {BR_TRACK_IDX_W{1'b0}};
        br_tail_t0 <= {BR_TRACK_IDX_W{1'b0}};
        br_head_t1 <= {BR_TRACK_IDX_W{1'b0}};
        br_tail_t1 <= {BR_TRACK_IDX_W{1'b0}};
        for (bi = 0; bi < BR_TRACK_DEPTH; bi = bi + 1) begin
            br_order_fifo_t0[bi] <= {`METADATA_ORDER_ID_W{1'b0}};
            br_order_fifo_t1[bi] <= {`METADATA_ORDER_ID_W{1'b0}};
        end
        spec_mem_after_branch_t0 <= 1'b0;
        spec_mem_after_branch_t1 <= 1'b0;
    end else begin
        // Branch in flight cleared by br_complete or flush
        if ((br_complete && (br_complete_tid == 1'b0)) || (flush && !flush_tid))
            branch_in_flight_t0 <= 1'b0;
        if ((br_complete && (br_complete_tid == 1'b1)) || (flush && flush_tid))
            branch_in_flight_t1 <= 1'b0;

        // Set on branch issue (from IQ_INT)
        if (int_iss_valid && int_iss_br && !int_iss_flush_kill) begin
            if (int_iss_tid == 1'b0) branch_in_flight_t0 <= 1'b1;
            else                     branch_in_flight_t1 <= 1'b1;
        end

        // Track unresolved branches in program order.  Side-effect and MEM
        // issue gates must compare against the oldest unresolved branch, not
        // the newest one, when dispatch is allowed to run past branches.
        if (flush) begin
            if (!flush_tid) begin
                br_pending_cnt_t0 <= 6'd0;
                br_head_t0 <= {BR_TRACK_IDX_W{1'b0}};
                br_tail_t0 <= {BR_TRACK_IDX_W{1'b0}};
                spec_mem_after_branch_t0 <= 1'b0;
            end else begin
                br_pending_cnt_t1 <= 6'd0;
                br_head_t1 <= {BR_TRACK_IDX_W{1'b0}};
                br_tail_t1 <= {BR_TRACK_IDX_W{1'b0}};
                spec_mem_after_branch_t1 <= 1'b0;
            end
        end

        if (!flush || flush_tid) begin : br_fifo_update_t0
            reg [5:0] next_count_t0;
            reg [BR_TRACK_IDX_W-1:0] next_head_t0;
            reg [BR_TRACK_IDX_W-1:0] next_tail_t0;
            next_count_t0 = br_pending_cnt_t0;
            next_head_t0 = br_head_t0;
            next_tail_t0 = br_tail_t0;

            if (br_complete && (br_complete_tid == 1'b0) && (next_count_t0 != 6'd0)) begin
                next_head_t0 = next_head_t0 + {{(BR_TRACK_IDX_W-1){1'b0}}, 1'b1};
                next_count_t0 = next_count_t0 - 6'd1;
            end
            if (br_push0_t0) begin
                br_order_fifo_t0[next_tail_t0] <= disp0_order_id;
                next_tail_t0 = next_tail_t0 + {{(BR_TRACK_IDX_W-1){1'b0}}, 1'b1};
                next_count_t0 = next_count_t0 + 6'd1;
            end
            if (br_push1_t0) begin
                br_order_fifo_t0[next_tail_t0] <= disp1_order_id;
                next_tail_t0 = next_tail_t0 + {{(BR_TRACK_IDX_W-1){1'b0}}, 1'b1};
                next_count_t0 = next_count_t0 + 6'd1;
            end
            br_head_t0 <= next_head_t0;
            br_tail_t0 <= next_tail_t0;
            br_pending_cnt_t0 <= next_count_t0;
            if (next_count_t0 == 6'd0)
                spec_mem_after_branch_t0 <= 1'b0;
        end

        if (!flush || !flush_tid) begin : br_fifo_update_t1
            reg [5:0] next_count_t1;
            reg [BR_TRACK_IDX_W-1:0] next_head_t1;
            reg [BR_TRACK_IDX_W-1:0] next_tail_t1;
            next_count_t1 = br_pending_cnt_t1;
            next_head_t1 = br_head_t1;
            next_tail_t1 = br_tail_t1;

            if (br_complete && (br_complete_tid == 1'b1) && (next_count_t1 != 6'd0)) begin
                next_head_t1 = next_head_t1 + {{(BR_TRACK_IDX_W-1){1'b0}}, 1'b1};
                next_count_t1 = next_count_t1 - 6'd1;
            end
            if (br_push0_t1) begin
                br_order_fifo_t1[next_tail_t1] <= disp0_order_id;
                next_tail_t1 = next_tail_t1 + {{(BR_TRACK_IDX_W-1){1'b0}}, 1'b1};
                next_count_t1 = next_count_t1 + 6'd1;
            end
            if (br_push1_t1) begin
                br_order_fifo_t1[next_tail_t1] <= disp1_order_id;
                next_tail_t1 = next_tail_t1 + {{(BR_TRACK_IDX_W-1){1'b0}}, 1'b1};
                next_count_t1 = next_count_t1 + 6'd1;
            end
            br_head_t1 <= next_head_t1;
            br_tail_t1 <= next_tail_t1;
            br_pending_cnt_t1 <= next_count_t1;
            if (next_count_t1 == 6'd0)
                spec_mem_after_branch_t1 <= 1'b0;
        end

        begin : br_spec_mem_update
            if (d0_go && d0_is_mem && d0_after_branch) begin
                if (disp0_tid == 1'b0) spec_mem_after_branch_t0 <= 1'b1;
                else                   spec_mem_after_branch_t1 <= 1'b1;
            end
            if (d1_go && d1_is_mem && d1_after_branch) begin
                if (disp1_tid == 1'b0) spec_mem_after_branch_t0 <= 1'b1;
                else                   spec_mem_after_branch_t1 <= 1'b1;
            end
        end
    end
end

// ═════════════════════════════════════════════════════════════════
// 6. Stall Logic — Per-port to avoid type-specific IQ deadlocks.
//    disp_stall  = d0 can't proceed → pipeline freezes.
//    disp1_blocked = d1 can't proceed (IQ full / no tag) but d0 can.
//      Upstream decoder consumes only d0 via consume_1 suppression.
// ═════════════════════════════════════════════════════════════════
wire iq_int_full, iq_int_almost_full;
wire iq_mem_full, iq_mem_almost_full;
wire iq_mul_full, iq_mul_almost_full;
wire iq_div_full, iq_div_almost_full;

// Branch state is still tracked for diagnostics and for the MEM IQ issue gate
// below, but dispatch itself is only limited by backend resources.
wire d0_pending_branch = (disp0_tid == 1'b0) ? pending_branch_t0 : pending_branch_t1;
wire d1_pending_branch = (disp1_tid == 1'b0) ? pending_branch_t0 : pending_branch_t1;
wire d0_after_branch = d0_pending_branch;
wire d1_after_branch = d1_pending_branch ||
                       (d0_go && disp0_br && (disp0_tid == disp1_tid));

// d0: target IQ has capacity?
wire d0_cap_ok = (!d0_is_int || !iq_int_full) &&
                 (!d0_is_mem || !iq_mem_full) &&
                 (!d0_is_mul || !iq_mul_full) &&
                 (!d0_is_div || !iq_div_full);

// d0: tag available?
wire d0_tag_ok = can_accept_1;

// disp_stall: pipeline-wide stall if d0 can't proceed
assign disp_stall = disp0_valid && (!d0_cap_ok || !d0_tag_ok);

wire d0_go = disp0_valid && !disp_stall;

// d1: target IQ has capacity (after d0 may have taken a slot)?
wire d1_int_ok = !d1_is_int || ((d0_is_int && d0_go) ? !iq_int_almost_full : !iq_int_full);
wire d1_mem_ok = !d1_is_mem || ((d0_is_mem && d0_go) ? !iq_mem_almost_full : !iq_mem_full);
wire d1_mul_ok = !d1_is_mul || ((d0_is_mul && d0_go) ? !iq_mul_almost_full : !iq_mul_full);
wire d1_div_ok = !d1_is_div || ((d0_is_div && d0_go) ? !iq_div_almost_full : !iq_div_full);
wire d1_cap_ok = d1_int_ok && d1_mem_ok && d1_mul_ok && d1_div_ok;

// d1: need 2 tags total (d0 uses 1)
wire d1_tag_ok = can_accept_2;

wire d1_go = disp1_valid && d0_go && d1_cap_ok && d1_tag_ok;

// Signal upstream: d1 was valid but couldn't dispatch (d0 did go)
assign disp1_blocked = disp1_valid && d0_go && !d1_go;

// ═════════════════════════════════════════════════════════════════
// 7. IQ Instantiation Wiring Helpers
// ═════════════════════════════════════════════════════════════════

// IQ_INT disp data mux
// dp0 source: disp0 when d0 is INT, else disp1 when d1 is INT
// dp1 source: disp1 (only when both are INT)

// Helper: select between disp0 and disp1 data for an IQ port
// "from1" means this IQ port should use disp1 data

// INT IQ issue wires
wire        int_iss_valid;
wire [RS_TAG_W-1:0] int_iss_tag;
wire [31:0] int_iss_pc, int_iss_imm;
wire [2:0]  int_iss_func3;
wire        int_iss_func7;
wire [4:0]  int_iss_rd, int_iss_rs1, int_iss_rs2;
wire        int_iss_rs1_used, int_iss_rs2_used;
wire [RS_TAG_W-1:0] int_iss_src1_tag, int_iss_src2_tag;
wire        int_iss_br, int_iss_mem_read, int_iss_mem2reg;
wire [2:0]  int_iss_alu_op;
wire        int_iss_mem_write;
wire [1:0]  int_iss_alu_src1, int_iss_alu_src2;
wire        int_iss_br_addr_mode, int_iss_regs_write;
wire [2:0]  int_iss_fu;
wire [0:0]  int_iss_tid;
wire        int_iss_is_mret;
wire [`METADATA_ORDER_ID_W-1:0] int_iss_order_id;
wire [`METADATA_EPOCH_W-1:0]    int_iss_epoch;

// MEM IQ issue wires
wire        mem_iss_valid;
wire [RS_TAG_W-1:0] mem_iss_tag;
wire [31:0] mem_iss_pc, mem_iss_imm;
wire [2:0]  mem_iss_func3;
wire        mem_iss_func7;
wire [4:0]  mem_iss_rd, mem_iss_rs1, mem_iss_rs2;
wire        mem_iss_rs1_used, mem_iss_rs2_used;
wire [RS_TAG_W-1:0] mem_iss_src1_tag, mem_iss_src2_tag;
wire        mem_iss_br, mem_iss_mem_read, mem_iss_mem2reg;
wire [2:0]  mem_iss_alu_op;
wire        mem_iss_mem_write;
wire [1:0]  mem_iss_alu_src1, mem_iss_alu_src2;
wire        mem_iss_br_addr_mode, mem_iss_regs_write;
wire [2:0]  mem_iss_fu;
wire [0:0]  mem_iss_tid;
wire        mem_iss_is_mret;
wire [`METADATA_ORDER_ID_W-1:0] mem_iss_order_id;
wire [`METADATA_EPOCH_W-1:0]    mem_iss_epoch;
wire                            mem_oldest_store_valid_t0;
wire [`METADATA_ORDER_ID_W-1:0] mem_oldest_store_order_id_t0;
wire                            mem_oldest_store_valid_t1;
wire [`METADATA_ORDER_ID_W-1:0] mem_oldest_store_order_id_t1;
wire                            iq_int_order_blocked_any;
wire                            iq_mem_order_blocked_any;
wire                            iq_mul_order_blocked_any;
wire                            iq_div_order_blocked_any;
wire                            iq_int_flush_killed_any;
wire                            iq_mem_flush_killed_any;
wire                            iq_mul_flush_killed_any;
wire                            iq_div_flush_killed_any;

// MUL IQ issue wires
wire        mul_iss_valid;
wire [RS_TAG_W-1:0] mul_iss_tag;
wire [31:0] mul_iss_pc, mul_iss_imm;
wire [2:0]  mul_iss_func3;
wire        mul_iss_func7;
wire [4:0]  mul_iss_rd, mul_iss_rs1, mul_iss_rs2;
wire        mul_iss_rs1_used, mul_iss_rs2_used;
wire [RS_TAG_W-1:0] mul_iss_src1_tag, mul_iss_src2_tag;
wire        mul_iss_br, mul_iss_mem_read, mul_iss_mem2reg;
wire [2:0]  mul_iss_alu_op;
wire        mul_iss_mem_write;
wire [1:0]  mul_iss_alu_src1, mul_iss_alu_src2;
wire        mul_iss_br_addr_mode, mul_iss_regs_write;
wire [2:0]  mul_iss_fu;
wire [0:0]  mul_iss_tid;
wire        mul_iss_is_mret;
wire [`METADATA_ORDER_ID_W-1:0] mul_iss_order_id;
wire [`METADATA_EPOCH_W-1:0]    mul_iss_epoch;

// DIV IQ issue wires
wire        div_iss_valid;
wire [RS_TAG_W-1:0] div_iss_tag;
wire [31:0] div_iss_pc, div_iss_imm;
wire [2:0]  div_iss_func3;
wire        div_iss_func7;
wire [4:0]  div_iss_rd, div_iss_rs1, div_iss_rs2;
wire        div_iss_rs1_used, div_iss_rs2_used;
wire [RS_TAG_W-1:0] div_iss_src1_tag, div_iss_src2_tag;
wire        div_iss_br, div_iss_mem_read, div_iss_mem2reg;
wire [2:0]  div_iss_alu_op;
wire        div_iss_mem_write;
wire [1:0]  div_iss_alu_src1, div_iss_alu_src2;
wire        div_iss_br_addr_mode, div_iss_regs_write;
wire [2:0]  div_iss_fu;
wire [0:0]  div_iss_tid;
wire        div_iss_is_mret;
wire [`METADATA_ORDER_ID_W-1:0] div_iss_order_id;
wire [`METADATA_EPOCH_W-1:0]    div_iss_epoch;

// ═════════════════════════════════════════════════════════════════
// 8. Issue Queue — INT (8 entries, commit-time dealloc)
// ═════════════════════════════════════════════════════════════════
issue_queue #(
    .IQ_DEPTH  (8),
    .IQ_IDX_W  (3),
    .RS_TAG_W  (RS_TAG_W),
    .NUM_THREAD(NUM_THREAD),
    .WAKE_HOLD (0),
    .DEALLOC_AT_COMMIT (1)
) u_iq_int (
    .clk        (clk),
    .rstn       (rstn),
    .flush      (flush),
    .flush_tid  (flush_tid),
    .flush_new_epoch (flush_new_epoch),
    .flush_order_valid (flush_order_valid),
    .flush_order_id    (flush_order_id),
    // Dispatch 0 — from disp0 if INT, else from disp1 if INT
    .disp0_valid       (iq_int_dp0_from1 ? (d1_go && d1_is_int) : (d0_go && d0_is_int)),
    .disp0_tag         (iq_int_dp0_from1 ? free1_tag   : free0_tag),
    .disp0_pc          (iq_int_dp0_from1 ? disp1_pc    : disp0_pc),
    .disp0_imm         (iq_int_dp0_from1 ? disp1_imm   : disp0_imm),
    .disp0_func3       (iq_int_dp0_from1 ? disp1_func3 : disp0_func3),
    .disp0_func7       (iq_int_dp0_from1 ? disp1_func7 : disp0_func7),
    .disp0_rd          (iq_int_dp0_from1 ? disp1_rd    : disp0_rd),
    .disp0_br          (iq_int_dp0_from1 ? disp1_br    : disp0_br),
    .disp0_mem_read    (iq_int_dp0_from1 ? disp1_mem_read    : disp0_mem_read),
    .disp0_mem2reg     (iq_int_dp0_from1 ? disp1_mem2reg     : disp0_mem2reg),
    .disp0_alu_op      (iq_int_dp0_from1 ? disp1_alu_op      : disp0_alu_op),
    .disp0_mem_write   (iq_int_dp0_from1 ? disp1_mem_write   : disp0_mem_write),
    .disp0_alu_src1    (iq_int_dp0_from1 ? disp1_alu_src1    : disp0_alu_src1),
    .disp0_alu_src2    (iq_int_dp0_from1 ? disp1_alu_src2    : disp0_alu_src2),
    .disp0_br_addr_mode(iq_int_dp0_from1 ? disp1_br_addr_mode: disp0_br_addr_mode),
    .disp0_regs_write  (iq_int_dp0_from1 ? disp1_regs_write  : disp0_regs_write),
    .disp0_rs1         (iq_int_dp0_from1 ? disp1_rs1   : disp0_rs1),
    .disp0_rs2         (iq_int_dp0_from1 ? disp1_rs2   : disp0_rs2),
    .disp0_rs1_used    (iq_int_dp0_from1 ? disp1_rs1_used    : disp0_rs1_used),
    .disp0_rs2_used    (iq_int_dp0_from1 ? disp1_rs2_used    : disp0_rs2_used),
    .disp0_fu          (iq_int_dp0_from1 ? disp1_fu    : disp0_fu),
    .disp0_tid         (iq_int_dp0_from1 ? disp1_tid   : disp0_tid),
    .disp0_is_mret     (iq_int_dp0_from1 ? disp1_is_mret     : disp0_is_mret),
    .disp0_side_effect (iq_int_dp0_from1 ? d1_side_effect     : d0_side_effect),
    .disp0_order_id    (iq_int_dp0_from1 ? disp1_order_id    : disp0_order_id),
    .disp0_epoch       (iq_int_dp0_from1 ? disp1_epoch       : disp0_epoch),
    .disp0_src1_tag    (iq_int_dp0_from1 ? d1_src1   : d0_src1),
    .disp0_src2_tag    (iq_int_dp0_from1 ? d1_src2   : d0_src2),
    .disp0_src1_order_id(iq_int_dp0_from1 ? d1_src1_order : d0_src1_order),
    .disp0_src2_order_id(iq_int_dp0_from1 ? d1_src2_order : d0_src2_order),
    // Dispatch 1 — only when both disp0 and disp1 are INT
    .disp1_valid       (d0_go && d0_is_int && d1_go && d1_is_int),
    .disp1_tag         (free1_tag),
    .disp1_pc          (disp1_pc),
    .disp1_imm         (disp1_imm),
    .disp1_func3       (disp1_func3),
    .disp1_func7       (disp1_func7),
    .disp1_rd          (disp1_rd),
    .disp1_br          (disp1_br),
    .disp1_mem_read    (disp1_mem_read),
    .disp1_mem2reg     (disp1_mem2reg),
    .disp1_alu_op      (disp1_alu_op),
    .disp1_mem_write   (disp1_mem_write),
    .disp1_alu_src1    (disp1_alu_src1),
    .disp1_alu_src2    (disp1_alu_src2),
    .disp1_br_addr_mode(disp1_br_addr_mode),
    .disp1_regs_write  (disp1_regs_write),
    .disp1_rs1         (disp1_rs1),
    .disp1_rs2         (disp1_rs2),
    .disp1_rs1_used    (disp1_rs1_used),
    .disp1_rs2_used    (disp1_rs2_used),
    .disp1_fu          (disp1_fu),
    .disp1_tid         (disp1_tid),
    .disp1_is_mret     (disp1_is_mret),
    .disp1_side_effect (d1_side_effect),
    .disp1_order_id    (disp1_order_id),
    .disp1_epoch       (disp1_epoch),
    .disp1_src1_tag    (d1_src1),
    .disp1_src2_tag    (d1_src2),
    .disp1_src1_order_id(d1_src1_order),
    .disp1_src2_order_id(d1_src2_order),
    // Outputs
    .iq_full        (iq_int_full),
    .iq_almost_full (iq_int_almost_full),
    // Issue
    .iss_valid       (int_iss_valid),
    .iss_tag         (int_iss_tag),
    .iss_pc          (int_iss_pc),
    .iss_imm         (int_iss_imm),
    .iss_func3       (int_iss_func3),
    .iss_func7       (int_iss_func7),
    .iss_rd          (int_iss_rd),
    .iss_rs1         (int_iss_rs1),
    .iss_rs2         (int_iss_rs2),
    .iss_rs1_used    (int_iss_rs1_used),
    .iss_rs2_used    (int_iss_rs2_used),
    .iss_src1_tag    (int_iss_src1_tag),
    .iss_src2_tag    (int_iss_src2_tag),
    .iss_br          (int_iss_br),
    .iss_mem_read    (int_iss_mem_read),
    .iss_mem2reg     (int_iss_mem2reg),
    .iss_alu_op      (int_iss_alu_op),
    .iss_mem_write   (int_iss_mem_write),
    .iss_alu_src1    (int_iss_alu_src1),
    .iss_alu_src2    (int_iss_alu_src2),
    .iss_br_addr_mode(int_iss_br_addr_mode),
    .iss_regs_write  (int_iss_regs_write),
    .iss_fu          (int_iss_fu),
    .iss_tid         (int_iss_tid),
    .iss_is_mret     (int_iss_is_mret),
    .iss_order_id    (int_iss_order_id),
    .iss_epoch       (int_iss_epoch),
    // Wakeup
    .wb0_valid       (wb0_valid),
    .wb0_tag         (wb0_tag),
    .wb0_tid         (wb0_tid),
    .wb0_order_id    (tag_live_seq[wb0_tag]),
    .wb0_regs_write  (wb0_regs_write),
    .wb1_valid       (wb1_valid),
    .wb1_tag         (wb1_tag),
    .wb1_tid         (wb1_tid),
    .wb1_order_id    (tag_live_seq[wb1_tag]),
    .wb1_regs_write  (wb1_regs_write),
    .early_wakeup_valid(lsu_early_wakeup_valid),
    .early_wakeup_tag(lsu_early_wakeup_tag),
    // Commit
    .commit0_valid   (commit0_valid),
    .commit0_tag     (commit0_tag),
    .commit0_tid     (commit0_tid),
    .commit0_order_id(commit0_order_id),
    .commit1_valid   (commit1_valid),
    .commit1_tag     (commit1_tag),
    .commit1_tid     (commit1_tid),
    .commit1_order_id(commit1_order_id),
    .older_store_valid_t0   (mem_oldest_store_valid_t0),
    .older_store_order_id_t0(mem_oldest_store_order_id_t0),
    .older_store_valid_t1   (mem_oldest_store_valid_t1),
    .older_store_order_id_t1(mem_oldest_store_order_id_t1),
    // Issue inhibit
    .issue_inhibit_t0(issue_inhibit_t0),
    .issue_inhibit_t1(issue_inhibit_t1),
    .issue_after_order_block_valid_t0(1'b0),
    .issue_after_order_block_id_t0({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_after_order_block_valid_t1(1'b0),
    .issue_after_order_block_id_t1({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_side_effect_block_valid_t0(pending_branch_t0),
    .issue_side_effect_block_id_t0(pending_branch_order_id_t0),
    .issue_side_effect_block_valid_t1(pending_branch_t1),
    .issue_side_effect_block_id_t1(pending_branch_order_id_t1),
    .oldest_store_valid_t0(),
    .oldest_store_order_id_t0(),
    .oldest_store_valid_t1(),
    .oldest_store_order_id_t1(),
    .debug_order_blocked_any(iq_int_order_blocked_any),
    .debug_flush_killed_any(iq_int_flush_killed_any)
);

// ═════════════════════════════════════════════════════════════════
// 9. Issue Queue — MEM (16 entries, commit-time dealloc, load-store ordering)
// ═════════════════════════════════════════════════════════════════
issue_queue #(
    .IQ_DEPTH  (RS_DEPTH),
    .IQ_IDX_W  (RS_IDX_W),
    .RS_TAG_W  (RS_TAG_W),
    .NUM_THREAD(NUM_THREAD),
    .WAKE_HOLD (1),
    .DEALLOC_AT_COMMIT    (1),
    .CHECK_LOAD_STORE_ORDER (1)
) u_iq_mem (
    .clk        (clk),
    .rstn       (rstn),
    .flush      (flush),
    .flush_tid  (flush_tid),
    .flush_new_epoch (flush_new_epoch),
    .flush_order_valid (flush_order_valid),
    .flush_order_id    (flush_order_id),
    // Dispatch 0
    .disp0_valid       (iq_mem_dp0_from1 ? (d1_go && d1_is_mem) : (d0_go && d0_is_mem)),
    .disp0_tag         (iq_mem_dp0_from1 ? free1_tag   : free0_tag),
    .disp0_pc          (iq_mem_dp0_from1 ? disp1_pc    : disp0_pc),
    .disp0_imm         (iq_mem_dp0_from1 ? disp1_imm   : disp0_imm),
    .disp0_func3       (iq_mem_dp0_from1 ? disp1_func3 : disp0_func3),
    .disp0_func7       (iq_mem_dp0_from1 ? disp1_func7 : disp0_func7),
    .disp0_rd          (iq_mem_dp0_from1 ? disp1_rd    : disp0_rd),
    .disp0_br          (iq_mem_dp0_from1 ? disp1_br    : disp0_br),
    .disp0_mem_read    (iq_mem_dp0_from1 ? disp1_mem_read    : disp0_mem_read),
    .disp0_mem2reg     (iq_mem_dp0_from1 ? disp1_mem2reg     : disp0_mem2reg),
    .disp0_alu_op      (iq_mem_dp0_from1 ? disp1_alu_op      : disp0_alu_op),
    .disp0_mem_write   (iq_mem_dp0_from1 ? disp1_mem_write   : disp0_mem_write),
    .disp0_alu_src1    (iq_mem_dp0_from1 ? disp1_alu_src1    : disp0_alu_src1),
    .disp0_alu_src2    (iq_mem_dp0_from1 ? disp1_alu_src2    : disp0_alu_src2),
    .disp0_br_addr_mode(iq_mem_dp0_from1 ? disp1_br_addr_mode: disp0_br_addr_mode),
    .disp0_regs_write  (iq_mem_dp0_from1 ? disp1_regs_write  : disp0_regs_write),
    .disp0_rs1         (iq_mem_dp0_from1 ? disp1_rs1   : disp0_rs1),
    .disp0_rs2         (iq_mem_dp0_from1 ? disp1_rs2   : disp0_rs2),
    .disp0_rs1_used    (iq_mem_dp0_from1 ? disp1_rs1_used    : disp0_rs1_used),
    .disp0_rs2_used    (iq_mem_dp0_from1 ? disp1_rs2_used    : disp0_rs2_used),
    .disp0_fu          (iq_mem_dp0_from1 ? disp1_fu    : disp0_fu),
    .disp0_tid         (iq_mem_dp0_from1 ? disp1_tid   : disp0_tid),
    .disp0_is_mret     (iq_mem_dp0_from1 ? disp1_is_mret     : disp0_is_mret),
    .disp0_side_effect (iq_mem_dp0_from1 ? d1_side_effect     : d0_side_effect),
    .disp0_order_id    (iq_mem_dp0_from1 ? disp1_order_id    : disp0_order_id),
    .disp0_epoch       (iq_mem_dp0_from1 ? disp1_epoch       : disp0_epoch),
    .disp0_src1_tag    (iq_mem_dp0_from1 ? d1_src1   : d0_src1),
    .disp0_src2_tag    (iq_mem_dp0_from1 ? d1_src2   : d0_src2),
    .disp0_src1_order_id(iq_mem_dp0_from1 ? d1_src1_order : d0_src1_order),
    .disp0_src2_order_id(iq_mem_dp0_from1 ? d1_src2_order : d0_src2_order),
    // Dispatch 1
    .disp1_valid       (d0_go && d0_is_mem && d1_go && d1_is_mem),
    .disp1_tag         (free1_tag),
    .disp1_pc          (disp1_pc),
    .disp1_imm         (disp1_imm),
    .disp1_func3       (disp1_func3),
    .disp1_func7       (disp1_func7),
    .disp1_rd          (disp1_rd),
    .disp1_br          (disp1_br),
    .disp1_mem_read    (disp1_mem_read),
    .disp1_mem2reg     (disp1_mem2reg),
    .disp1_alu_op      (disp1_alu_op),
    .disp1_mem_write   (disp1_mem_write),
    .disp1_alu_src1    (disp1_alu_src1),
    .disp1_alu_src2    (disp1_alu_src2),
    .disp1_br_addr_mode(disp1_br_addr_mode),
    .disp1_regs_write  (disp1_regs_write),
    .disp1_rs1         (disp1_rs1),
    .disp1_rs2         (disp1_rs2),
    .disp1_rs1_used    (disp1_rs1_used),
    .disp1_rs2_used    (disp1_rs2_used),
    .disp1_fu          (disp1_fu),
    .disp1_tid         (disp1_tid),
    .disp1_is_mret     (disp1_is_mret),
    .disp1_side_effect (d1_side_effect),
    .disp1_order_id    (disp1_order_id),
    .disp1_epoch       (disp1_epoch),
    .disp1_src1_tag    (d1_src1),
    .disp1_src2_tag    (d1_src2),
    .disp1_src1_order_id(d1_src1_order),
    .disp1_src2_order_id(d1_src2_order),
    // Outputs
    .iq_full        (iq_mem_full),
    .iq_almost_full (iq_mem_almost_full),
    .iss_valid       (mem_iss_valid),
    .iss_tag         (mem_iss_tag),
    .iss_pc          (mem_iss_pc),
    .iss_imm         (mem_iss_imm),
    .iss_func3       (mem_iss_func3),
    .iss_func7       (mem_iss_func7),
    .iss_rd          (mem_iss_rd),
    .iss_rs1         (mem_iss_rs1),
    .iss_rs2         (mem_iss_rs2),
    .iss_rs1_used    (mem_iss_rs1_used),
    .iss_rs2_used    (mem_iss_rs2_used),
    .iss_src1_tag    (mem_iss_src1_tag),
    .iss_src2_tag    (mem_iss_src2_tag),
    .iss_br          (mem_iss_br),
    .iss_mem_read    (mem_iss_mem_read),
    .iss_mem2reg     (mem_iss_mem2reg),
    .iss_alu_op      (mem_iss_alu_op),
    .iss_mem_write   (mem_iss_mem_write),
    .iss_alu_src1    (mem_iss_alu_src1),
    .iss_alu_src2    (mem_iss_alu_src2),
    .iss_br_addr_mode(mem_iss_br_addr_mode),
    .iss_regs_write  (mem_iss_regs_write),
    .iss_fu          (mem_iss_fu),
    .iss_tid         (mem_iss_tid),
    .iss_is_mret     (mem_iss_is_mret),
    .iss_order_id    (mem_iss_order_id),
    .iss_epoch       (mem_iss_epoch),
    .wb0_valid       (wb0_valid),
    .wb0_tag         (wb0_tag),
    .wb0_tid         (wb0_tid),
    .wb0_order_id    (tag_live_seq[wb0_tag]),
    .wb0_regs_write  (wb0_regs_write),
    .wb1_valid       (wb1_valid),
    .wb1_tag         (wb1_tag),
    .wb1_tid         (wb1_tid),
    .wb1_order_id    (tag_live_seq[wb1_tag]),
    .wb1_regs_write  (wb1_regs_write),
    .early_wakeup_valid(lsu_early_wakeup_valid),
    .early_wakeup_tag(lsu_early_wakeup_tag),
    .commit0_valid   (commit0_valid),
    .commit0_tag     (commit0_tag),
    .commit0_tid     (commit0_tid),
    .commit0_order_id(commit0_order_id),
    .commit1_valid   (commit1_valid),
    .commit1_tag     (commit1_tag),
    .commit1_tid     (commit1_tid),
    .commit1_order_id(commit1_order_id),
    .older_store_valid_t0   (1'b0),
    .older_store_order_id_t0({`METADATA_ORDER_ID_W{1'b0}}),
    .older_store_valid_t1   (1'b0),
    .older_store_order_id_t1({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_inhibit_t0(mem_issue_inhibit),
    .issue_inhibit_t1(mem_issue_inhibit),
    .issue_after_order_block_valid_t0(1'b0),
    .issue_after_order_block_id_t0({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_after_order_block_valid_t1(1'b0),
    .issue_after_order_block_id_t1({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_side_effect_block_valid_t0(1'b0),
    .issue_side_effect_block_id_t0({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_side_effect_block_valid_t1(1'b0),
    .issue_side_effect_block_id_t1({`METADATA_ORDER_ID_W{1'b0}}),
    .oldest_store_valid_t0   (mem_oldest_store_valid_t0),
    .oldest_store_order_id_t0(mem_oldest_store_order_id_t0),
    .oldest_store_valid_t1   (mem_oldest_store_valid_t1),
    .oldest_store_order_id_t1(mem_oldest_store_order_id_t1),
    .debug_order_blocked_any(iq_mem_order_blocked_any),
    .debug_flush_killed_any(iq_mem_flush_killed_any)
);

// ═════════════════════════════════════════════════════════════════
// 10. Issue Queue — MUL (4 entries, commit-time dealloc)
// ═════════════════════════════════════════════════════════════════
issue_queue #(
    .IQ_DEPTH  (4),
    .IQ_IDX_W  (2),
    .RS_TAG_W  (RS_TAG_W),
    .NUM_THREAD(NUM_THREAD),
    .WAKE_HOLD (0),
    .DEALLOC_AT_COMMIT (1)
) u_iq_mul (
    .clk        (clk),
    .rstn       (rstn),
    .flush      (flush),
    .flush_tid  (flush_tid),
    .flush_new_epoch (flush_new_epoch),
    .flush_order_valid (flush_order_valid),
    .flush_order_id    (flush_order_id),
    // Dispatch 0
    .disp0_valid       (iq_mul_dp0_from1 ? (d1_go && d1_is_mul) : (d0_go && d0_is_mul)),
    .disp0_tag         (iq_mul_dp0_from1 ? free1_tag   : free0_tag),
    .disp0_pc          (iq_mul_dp0_from1 ? disp1_pc    : disp0_pc),
    .disp0_imm         (iq_mul_dp0_from1 ? disp1_imm   : disp0_imm),
    .disp0_func3       (iq_mul_dp0_from1 ? disp1_func3 : disp0_func3),
    .disp0_func7       (iq_mul_dp0_from1 ? disp1_func7 : disp0_func7),
    .disp0_rd          (iq_mul_dp0_from1 ? disp1_rd    : disp0_rd),
    .disp0_br          (iq_mul_dp0_from1 ? disp1_br    : disp0_br),
    .disp0_mem_read    (iq_mul_dp0_from1 ? disp1_mem_read    : disp0_mem_read),
    .disp0_mem2reg     (iq_mul_dp0_from1 ? disp1_mem2reg     : disp0_mem2reg),
    .disp0_alu_op      (iq_mul_dp0_from1 ? disp1_alu_op      : disp0_alu_op),
    .disp0_mem_write   (iq_mul_dp0_from1 ? disp1_mem_write   : disp0_mem_write),
    .disp0_alu_src1    (iq_mul_dp0_from1 ? disp1_alu_src1    : disp0_alu_src1),
    .disp0_alu_src2    (iq_mul_dp0_from1 ? disp1_alu_src2    : disp0_alu_src2),
    .disp0_br_addr_mode(iq_mul_dp0_from1 ? disp1_br_addr_mode: disp0_br_addr_mode),
    .disp0_regs_write  (iq_mul_dp0_from1 ? disp1_regs_write  : disp0_regs_write),
    .disp0_rs1         (iq_mul_dp0_from1 ? disp1_rs1   : disp0_rs1),
    .disp0_rs2         (iq_mul_dp0_from1 ? disp1_rs2   : disp0_rs2),
    .disp0_rs1_used    (iq_mul_dp0_from1 ? disp1_rs1_used    : disp0_rs1_used),
    .disp0_rs2_used    (iq_mul_dp0_from1 ? disp1_rs2_used    : disp0_rs2_used),
    .disp0_fu          (iq_mul_dp0_from1 ? disp1_fu    : disp0_fu),
    .disp0_tid         (iq_mul_dp0_from1 ? disp1_tid   : disp0_tid),
    .disp0_is_mret     (iq_mul_dp0_from1 ? disp1_is_mret     : disp0_is_mret),
    .disp0_side_effect (iq_mul_dp0_from1 ? d1_side_effect     : d0_side_effect),
    .disp0_order_id    (iq_mul_dp0_from1 ? disp1_order_id    : disp0_order_id),
    .disp0_epoch       (iq_mul_dp0_from1 ? disp1_epoch       : disp0_epoch),
    .disp0_src1_tag    (iq_mul_dp0_from1 ? d1_src1   : d0_src1),
    .disp0_src2_tag    (iq_mul_dp0_from1 ? d1_src2   : d0_src2),
    .disp0_src1_order_id(iq_mul_dp0_from1 ? d1_src1_order : d0_src1_order),
    .disp0_src2_order_id(iq_mul_dp0_from1 ? d1_src2_order : d0_src2_order),
    // Dispatch 1
    .disp1_valid       (d0_go && d0_is_mul && d1_go && d1_is_mul),
    .disp1_tag         (free1_tag),
    .disp1_pc          (disp1_pc),
    .disp1_imm         (disp1_imm),
    .disp1_func3       (disp1_func3),
    .disp1_func7       (disp1_func7),
    .disp1_rd          (disp1_rd),
    .disp1_br          (disp1_br),
    .disp1_mem_read    (disp1_mem_read),
    .disp1_mem2reg     (disp1_mem2reg),
    .disp1_alu_op      (disp1_alu_op),
    .disp1_mem_write   (disp1_mem_write),
    .disp1_alu_src1    (disp1_alu_src1),
    .disp1_alu_src2    (disp1_alu_src2),
    .disp1_br_addr_mode(disp1_br_addr_mode),
    .disp1_regs_write  (disp1_regs_write),
    .disp1_rs1         (disp1_rs1),
    .disp1_rs2         (disp1_rs2),
    .disp1_rs1_used    (disp1_rs1_used),
    .disp1_rs2_used    (disp1_rs2_used),
    .disp1_fu          (disp1_fu),
    .disp1_tid         (disp1_tid),
    .disp1_is_mret     (disp1_is_mret),
    .disp1_side_effect (d1_side_effect),
    .disp1_order_id    (disp1_order_id),
    .disp1_epoch       (disp1_epoch),
    .disp1_src1_tag    (d1_src1),
    .disp1_src2_tag    (d1_src2),
    .disp1_src1_order_id(d1_src1_order),
    .disp1_src2_order_id(d1_src2_order),
    // Outputs
    .iq_full        (iq_mul_full),
    .iq_almost_full (iq_mul_almost_full),
    .iss_valid       (mul_iss_valid),
    .iss_tag         (mul_iss_tag),
    .iss_pc          (mul_iss_pc),
    .iss_imm         (mul_iss_imm),
    .iss_func3       (mul_iss_func3),
    .iss_func7       (mul_iss_func7),
    .iss_rd          (mul_iss_rd),
    .iss_rs1         (mul_iss_rs1),
    .iss_rs2         (mul_iss_rs2),
    .iss_rs1_used    (mul_iss_rs1_used),
    .iss_rs2_used    (mul_iss_rs2_used),
    .iss_src1_tag    (mul_iss_src1_tag),
    .iss_src2_tag    (mul_iss_src2_tag),
    .iss_br          (mul_iss_br),
    .iss_mem_read    (mul_iss_mem_read),
    .iss_mem2reg     (mul_iss_mem2reg),
    .iss_alu_op      (mul_iss_alu_op),
    .iss_mem_write   (mul_iss_mem_write),
    .iss_alu_src1    (mul_iss_alu_src1),
    .iss_alu_src2    (mul_iss_alu_src2),
    .iss_br_addr_mode(mul_iss_br_addr_mode),
    .iss_regs_write  (mul_iss_regs_write),
    .iss_fu          (mul_iss_fu),
    .iss_tid         (mul_iss_tid),
    .iss_is_mret     (mul_iss_is_mret),
    .iss_order_id    (mul_iss_order_id),
    .iss_epoch       (mul_iss_epoch),
    .wb0_valid       (wb0_valid),
    .wb0_tag         (wb0_tag),
    .wb0_tid         (wb0_tid),
    .wb0_order_id    (tag_live_seq[wb0_tag]),
    .wb0_regs_write  (wb0_regs_write),
    .wb1_valid       (wb1_valid),
    .wb1_tag         (wb1_tag),
    .wb1_tid         (wb1_tid),
    .wb1_order_id    (tag_live_seq[wb1_tag]),
    .wb1_regs_write  (wb1_regs_write),
    .early_wakeup_valid(lsu_early_wakeup_valid),
    .early_wakeup_tag(lsu_early_wakeup_tag),
    .commit0_valid   (commit0_valid),
    .commit0_tag     (commit0_tag),
    .commit0_tid     (commit0_tid),
    .commit0_order_id(commit0_order_id),
    .commit1_valid   (commit1_valid),
    .commit1_tag     (commit1_tag),
    .commit1_tid     (commit1_tid),
    .commit1_order_id(commit1_order_id),
    .older_store_valid_t0   (1'b0),
    .older_store_order_id_t0({`METADATA_ORDER_ID_W{1'b0}}),
    .older_store_valid_t1   (1'b0),
    .older_store_order_id_t1({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_inhibit_t0(mul_issue_inhibit),
    .issue_inhibit_t1(mul_issue_inhibit),
    .issue_after_order_block_valid_t0(1'b0),
    .issue_after_order_block_id_t0({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_after_order_block_valid_t1(1'b0),
    .issue_after_order_block_id_t1({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_side_effect_block_valid_t0(1'b0),
    .issue_side_effect_block_id_t0({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_side_effect_block_valid_t1(1'b0),
    .issue_side_effect_block_id_t1({`METADATA_ORDER_ID_W{1'b0}}),
    .oldest_store_valid_t0(),
    .oldest_store_order_id_t0(),
    .oldest_store_valid_t1(),
    .oldest_store_order_id_t1(),
    .debug_order_blocked_any(iq_mul_order_blocked_any),
    .debug_flush_killed_any(iq_mul_flush_killed_any)
);

// ═════════════════════════════════════════════════════════════════
// 10b. Issue Queue — DIV (4 entries, commit-time dealloc)
// ═════════════════════════════════════════════════════════════════
issue_queue #(
    .IQ_DEPTH  (4),
    .IQ_IDX_W  (2),
    .RS_TAG_W  (RS_TAG_W),
    .NUM_THREAD(NUM_THREAD),
    .WAKE_HOLD (0),
    .DEALLOC_AT_COMMIT (1)
) u_iq_div (
    .clk        (clk),
    .rstn       (rstn),
    .flush      (flush),
    .flush_tid  (flush_tid),
    .flush_new_epoch (flush_new_epoch),
    .flush_order_valid (flush_order_valid),
    .flush_order_id    (flush_order_id),
    // Dispatch 0
    .disp0_valid       (iq_div_dp0_from1 ? (d1_go && d1_is_div) : (d0_go && d0_is_div)),
    .disp0_tag         (iq_div_dp0_from1 ? free1_tag   : free0_tag),
    .disp0_pc          (iq_div_dp0_from1 ? disp1_pc    : disp0_pc),
    .disp0_imm         (iq_div_dp0_from1 ? disp1_imm   : disp0_imm),
    .disp0_func3       (iq_div_dp0_from1 ? disp1_func3 : disp0_func3),
    .disp0_func7       (iq_div_dp0_from1 ? disp1_func7 : disp0_func7),
    .disp0_rd          (iq_div_dp0_from1 ? disp1_rd    : disp0_rd),
    .disp0_br          (iq_div_dp0_from1 ? disp1_br    : disp0_br),
    .disp0_mem_read    (iq_div_dp0_from1 ? disp1_mem_read    : disp0_mem_read),
    .disp0_mem2reg     (iq_div_dp0_from1 ? disp1_mem2reg     : disp0_mem2reg),
    .disp0_alu_op      (iq_div_dp0_from1 ? disp1_alu_op      : disp0_alu_op),
    .disp0_mem_write   (iq_div_dp0_from1 ? disp1_mem_write   : disp0_mem_write),
    .disp0_alu_src1    (iq_div_dp0_from1 ? disp1_alu_src1    : disp0_alu_src1),
    .disp0_alu_src2    (iq_div_dp0_from1 ? disp1_alu_src2    : disp0_alu_src2),
    .disp0_br_addr_mode(iq_div_dp0_from1 ? disp1_br_addr_mode: disp0_br_addr_mode),
    .disp0_regs_write  (iq_div_dp0_from1 ? disp1_regs_write  : disp0_regs_write),
    .disp0_rs1         (iq_div_dp0_from1 ? disp1_rs1   : disp0_rs1),
    .disp0_rs2         (iq_div_dp0_from1 ? disp1_rs2   : disp0_rs2),
    .disp0_rs1_used    (iq_div_dp0_from1 ? disp1_rs1_used    : disp0_rs1_used),
    .disp0_rs2_used    (iq_div_dp0_from1 ? disp1_rs2_used    : disp0_rs2_used),
    .disp0_fu          (iq_div_dp0_from1 ? disp1_fu    : disp0_fu),
    .disp0_tid         (iq_div_dp0_from1 ? disp1_tid   : disp0_tid),
    .disp0_is_mret     (iq_div_dp0_from1 ? disp1_is_mret     : disp0_is_mret),
    .disp0_side_effect (iq_div_dp0_from1 ? d1_side_effect     : d0_side_effect),
    .disp0_order_id    (iq_div_dp0_from1 ? disp1_order_id    : disp0_order_id),
    .disp0_epoch       (iq_div_dp0_from1 ? disp1_epoch       : disp0_epoch),
    .disp0_src1_tag    (iq_div_dp0_from1 ? d1_src1   : d0_src1),
    .disp0_src2_tag    (iq_div_dp0_from1 ? d1_src2   : d0_src2),
    .disp0_src1_order_id(iq_div_dp0_from1 ? d1_src1_order : d0_src1_order),
    .disp0_src2_order_id(iq_div_dp0_from1 ? d1_src2_order : d0_src2_order),
    // Dispatch 1
    .disp1_valid       (d0_go && d0_is_div && d1_go && d1_is_div),
    .disp1_tag         (free1_tag),
    .disp1_pc          (disp1_pc),
    .disp1_imm         (disp1_imm),
    .disp1_func3       (disp1_func3),
    .disp1_func7       (disp1_func7),
    .disp1_rd          (disp1_rd),
    .disp1_br          (disp1_br),
    .disp1_mem_read    (disp1_mem_read),
    .disp1_mem2reg     (disp1_mem2reg),
    .disp1_alu_op      (disp1_alu_op),
    .disp1_mem_write   (disp1_mem_write),
    .disp1_alu_src1    (disp1_alu_src1),
    .disp1_alu_src2    (disp1_alu_src2),
    .disp1_br_addr_mode(disp1_br_addr_mode),
    .disp1_regs_write  (disp1_regs_write),
    .disp1_rs1         (disp1_rs1),
    .disp1_rs2         (disp1_rs2),
    .disp1_rs1_used    (disp1_rs1_used),
    .disp1_rs2_used    (disp1_rs2_used),
    .disp1_fu          (disp1_fu),
    .disp1_tid         (disp1_tid),
    .disp1_is_mret     (disp1_is_mret),
    .disp1_side_effect (d1_side_effect),
    .disp1_order_id    (disp1_order_id),
    .disp1_epoch       (disp1_epoch),
    .disp1_src1_tag    (d1_src1),
    .disp1_src2_tag    (d1_src2),
    .disp1_src1_order_id(d1_src1_order),
    .disp1_src2_order_id(d1_src2_order),
    // Outputs
    .iq_full        (iq_div_full),
    .iq_almost_full (iq_div_almost_full),
    .iss_valid       (div_iss_valid),
    .iss_tag         (div_iss_tag),
    .iss_pc          (div_iss_pc),
    .iss_imm         (div_iss_imm),
    .iss_func3       (div_iss_func3),
    .iss_func7       (div_iss_func7),
    .iss_rd          (div_iss_rd),
    .iss_rs1         (div_iss_rs1),
    .iss_rs2         (div_iss_rs2),
    .iss_rs1_used    (div_iss_rs1_used),
    .iss_rs2_used    (div_iss_rs2_used),
    .iss_src1_tag    (div_iss_src1_tag),
    .iss_src2_tag    (div_iss_src2_tag),
    .iss_br          (div_iss_br),
    .iss_mem_read    (div_iss_mem_read),
    .iss_mem2reg     (div_iss_mem2reg),
    .iss_alu_op      (div_iss_alu_op),
    .iss_mem_write   (div_iss_mem_write),
    .iss_alu_src1    (div_iss_alu_src1),
    .iss_alu_src2    (div_iss_alu_src2),
    .iss_br_addr_mode(div_iss_br_addr_mode),
    .iss_regs_write  (div_iss_regs_write),
    .iss_fu          (div_iss_fu),
    .iss_tid         (div_iss_tid),
    .iss_is_mret     (div_iss_is_mret),
    .iss_order_id    (div_iss_order_id),
    .iss_epoch       (div_iss_epoch),
    .wb0_valid       (wb0_valid),
    .wb0_tag         (wb0_tag),
    .wb0_tid         (wb0_tid),
    .wb0_order_id    (tag_live_seq[wb0_tag]),
    .wb0_regs_write  (wb0_regs_write),
    .wb1_valid       (wb1_valid),
    .wb1_tag         (wb1_tag),
    .wb1_tid         (wb1_tid),
    .wb1_order_id    (tag_live_seq[wb1_tag]),
    .wb1_regs_write  (wb1_regs_write),
    .early_wakeup_valid(lsu_early_wakeup_valid),
    .early_wakeup_tag(lsu_early_wakeup_tag),
    .commit0_valid   (commit0_valid),
    .commit0_tag     (commit0_tag),
    .commit0_tid     (commit0_tid),
    .commit0_order_id(commit0_order_id),
    .commit1_valid   (commit1_valid),
    .commit1_tag     (commit1_tag),
    .commit1_tid     (commit1_tid),
    .commit1_order_id(commit1_order_id),
    .older_store_valid_t0   (1'b0),
    .older_store_order_id_t0({`METADATA_ORDER_ID_W{1'b0}}),
    .older_store_valid_t1   (1'b0),
    .older_store_order_id_t1({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_inhibit_t0(div_issue_inhibit),
    .issue_inhibit_t1(div_issue_inhibit),
    .issue_after_order_block_valid_t0(1'b0),
    .issue_after_order_block_id_t0({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_after_order_block_valid_t1(1'b0),
    .issue_after_order_block_id_t1({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_side_effect_block_valid_t0(1'b0),
    .issue_side_effect_block_id_t0({`METADATA_ORDER_ID_W{1'b0}}),
    .issue_side_effect_block_valid_t1(1'b0),
    .issue_side_effect_block_id_t1({`METADATA_ORDER_ID_W{1'b0}}),
    .oldest_store_valid_t0(),
    .oldest_store_order_id_t0(),
    .oldest_store_valid_t1(),
    .oldest_store_order_id_t1(),
    .debug_order_blocked_any(iq_div_order_blocked_any),
    .debug_flush_killed_any(iq_div_flush_killed_any)
);

// ═════════════════════════════════════════════════════════════════
// 11. FU Busy Tracking (prevents over-issue to shared pipe1 resources)
//     MEM/MUL/DIV share pipe1. Only one mem op at a time (LSU single-port).
//     Busy set at issue, cleared at WB completion of that FU type.
//
//     Partial-flush awareness: the LSU can kill a pending load during a
//     branch redirect (flush_order_valid=1) if the load is younger than
//     the flush point. When that happens no WB1 arrives, so we must
//     also clear mem_fu_busy here using the same younger-than test.
// ═════════════════════════════════════════════════════════════════
reg mem_fu_busy, mul_fu_busy, div_fu_busy;
reg [`METADATA_ORDER_ID_W-1:0] mem_fu_order_id;
reg [0:0]                      mem_fu_tid;
wire mem_fu_wb_clear = wb1_valid && (wb1_fu == `FU_LOAD || wb1_fu == `FU_STORE);
wire mem_fu_blocks_issue = mem_fu_busy && !mem_fu_wb_clear;
wire mem_issue_inhibit = mem_fu_blocks_issue ||
                         (p1_mem_cand_valid &&
                          !(p1_winner_valid && p1_winner == 2'b10));
wire mul_issue_inhibit = mul_fu_busy ||
                         (p1_mul_cand_valid &&
                          !(p1_winner_valid && p1_winner == 2'b11));
wire div_issue_inhibit = div_fu_busy ||
                         (p1_div_cand_valid &&
                          !(p1_winner_valid && p1_winner == 2'b01));

wire mem_fu_flush_kill = mem_fu_busy &&
                         (mem_fu_tid == flush_tid) &&
                         (!flush_order_valid ||
                          (mem_fu_order_id > flush_order_id));
wire p1_mem_cand_flush_kill = flush &&
                              p1_mem_cand_valid &&
                              (p1_mem_cand_tid == flush_tid) &&
                              (!flush_order_valid ||
                               (p1_mem_cand_order_id > flush_order_id));
wire p1_mul_cand_flush_kill = flush &&
                              p1_mul_cand_valid &&
                              (p1_mul_cand_tid == flush_tid) &&
                              (!flush_order_valid ||
                               (p1_mul_cand_order_id > flush_order_id));
wire p1_div_cand_flush_kill = flush &&
                              p1_div_cand_valid &&
                              (p1_div_cand_tid == flush_tid) &&
                              (!flush_order_valid ||
                               (p1_div_cand_order_id > flush_order_id));
wire mem_raw_issue_flush_kill = flush &&
                                mem_iss_valid &&
                                (mem_iss_tid == flush_tid) &&
                                (!flush_order_valid ||
                                 (mem_iss_order_id > flush_order_id));
wire mul_raw_issue_flush_kill = flush &&
                                mul_iss_valid &&
                                (mul_iss_tid == flush_tid) &&
                                (!flush_order_valid ||
                                 (mul_iss_order_id > flush_order_id));
wire div_raw_issue_flush_kill = flush &&
                                div_iss_valid &&
                                (div_iss_tid == flush_tid) &&
                                (!flush_order_valid ||
                                 (div_iss_order_id > flush_order_id));
wire p1_mem_cand_arb_valid = p1_mem_cand_valid &&
                             !p1_mem_cand_flush_kill &&
                             !mem_fu_blocks_issue;
wire p1_mul_cand_arb_valid = p1_mul_cand_valid &&
                             !p1_mul_cand_flush_kill &&
                             !mul_fu_busy;
wire p1_div_cand_arb_valid = p1_div_cand_valid &&
                             !p1_div_cand_flush_kill &&
                             !div_fu_busy;
wire mem_cand_consume = p1_winner_valid && (p1_winner == 2'b10);
wire mem_cand_raw_valid = mem_iss_valid && !mem_raw_issue_flush_kill;
wire mem_cand_clear = p1_mem_cand_flush_kill ||
                      (mem_cand_consume && !mem_cand_raw_valid);
wire mem_cand_set = !p1_mem_cand_flush_kill &&
                    mem_cand_raw_valid &&
                    (!p1_mem_cand_valid || mem_cand_consume);
wire mem_cand_take_raw = mem_cand_set;
wire [P1_CAND_BUNDLE_W-1:0] mem_cand_raw_bundle = {
    mem_iss_tag, mem_iss_pc, mem_iss_imm, mem_iss_func3, mem_iss_func7,
    mem_iss_rd, mem_iss_rs1, mem_iss_rs2, mem_iss_rs1_used, mem_iss_rs2_used,
    mem_iss_src1_tag, mem_iss_src2_tag, mem_iss_br, mem_iss_mem_read, mem_iss_mem2reg,
    mem_iss_alu_op, mem_iss_mem_write, mem_iss_alu_src1, mem_iss_alu_src2,
    mem_iss_br_addr_mode, mem_iss_regs_write, mem_iss_fu, mem_iss_tid,
    mem_iss_is_mret, mem_iss_order_id, mem_iss_epoch
};
wire [P1_CAND_BUNDLE_W-1:0] mem_cand_curr_bundle = {
    p1_mem_cand_tag, p1_mem_cand_pc, p1_mem_cand_imm, p1_mem_cand_func3, p1_mem_cand_func7,
    p1_mem_cand_rd, p1_mem_cand_rs1, p1_mem_cand_rs2, p1_mem_cand_rs1_used, p1_mem_cand_rs2_used,
    p1_mem_cand_src1_tag, p1_mem_cand_src2_tag, p1_mem_cand_br, p1_mem_cand_mem_read, p1_mem_cand_mem2reg,
    p1_mem_cand_alu_op, p1_mem_cand_mem_write, p1_mem_cand_alu_src1, p1_mem_cand_alu_src2,
    p1_mem_cand_br_addr_mode, p1_mem_cand_regs_write, p1_mem_cand_fu, p1_mem_cand_tid,
    p1_mem_cand_is_mret, p1_mem_cand_order_id, p1_mem_cand_epoch
};
wire [P1_CAND_BUNDLE_W-1:0] mem_cand_data_d = mem_cand_take_raw ? mem_cand_raw_bundle
                                                                 : mem_cand_curr_bundle;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        mem_fu_busy              <= 1'b0;
        mul_fu_busy              <= 1'b0;
        div_fu_busy              <= 1'b0;
        mem_fu_order_id          <= {`METADATA_ORDER_ID_W{1'b0}};
        mem_fu_tid               <= 1'b0;
        p1_mem_cand_valid        <= 1'b0;
        {
            p1_mem_cand_tag, p1_mem_cand_pc, p1_mem_cand_imm, p1_mem_cand_func3, p1_mem_cand_func7,
            p1_mem_cand_rd, p1_mem_cand_rs1, p1_mem_cand_rs2, p1_mem_cand_rs1_used, p1_mem_cand_rs2_used,
            p1_mem_cand_src1_tag, p1_mem_cand_src2_tag, p1_mem_cand_br, p1_mem_cand_mem_read, p1_mem_cand_mem2reg,
            p1_mem_cand_alu_op, p1_mem_cand_mem_write, p1_mem_cand_alu_src1, p1_mem_cand_alu_src2,
            p1_mem_cand_br_addr_mode, p1_mem_cand_regs_write, p1_mem_cand_fu, p1_mem_cand_tid,
            p1_mem_cand_is_mret, p1_mem_cand_order_id, p1_mem_cand_epoch
        } <= {P1_CAND_BUNDLE_W{1'b0}};
        p1_mul_cand_valid        <= 1'b0;
        p1_mul_cand_tag          <= {RS_TAG_W{1'b0}};
        p1_mul_cand_pc           <= 32'd0;
        p1_mul_cand_imm          <= 32'd0;
        p1_mul_cand_func3        <= 3'd0;
        p1_mul_cand_func7        <= 1'b0;
        p1_mul_cand_rd           <= 5'd0;
        p1_mul_cand_rs1          <= 5'd0;
        p1_mul_cand_rs2          <= 5'd0;
        p1_mul_cand_rs1_used     <= 1'b0;
        p1_mul_cand_rs2_used     <= 1'b0;
        p1_mul_cand_src1_tag     <= {RS_TAG_W{1'b0}};
        p1_mul_cand_src2_tag     <= {RS_TAG_W{1'b0}};
        p1_mul_cand_br           <= 1'b0;
        p1_mul_cand_mem_read     <= 1'b0;
        p1_mul_cand_mem2reg      <= 1'b0;
        p1_mul_cand_alu_op       <= 3'd0;
        p1_mul_cand_mem_write    <= 1'b0;
        p1_mul_cand_alu_src1     <= 2'd0;
        p1_mul_cand_alu_src2     <= 2'd0;
        p1_mul_cand_br_addr_mode <= 1'b0;
        p1_mul_cand_regs_write   <= 1'b0;
        p1_mul_cand_fu           <= 3'd0;
        p1_mul_cand_tid          <= 1'b0;
        p1_mul_cand_is_mret      <= 1'b0;
        p1_mul_cand_order_id     <= {`METADATA_ORDER_ID_W{1'b0}};
        p1_mul_cand_epoch        <= {`METADATA_EPOCH_W{1'b0}};
        p1_div_cand_valid        <= 1'b0;
        p1_div_cand_tag          <= {RS_TAG_W{1'b0}};
        p1_div_cand_pc           <= 32'd0;
        p1_div_cand_imm          <= 32'd0;
        p1_div_cand_func3        <= 3'd0;
        p1_div_cand_func7        <= 1'b0;
        p1_div_cand_rd           <= 5'd0;
        p1_div_cand_rs1          <= 5'd0;
        p1_div_cand_rs2          <= 5'd0;
        p1_div_cand_rs1_used     <= 1'b0;
        p1_div_cand_rs2_used     <= 1'b0;
        p1_div_cand_src1_tag     <= {RS_TAG_W{1'b0}};
        p1_div_cand_src2_tag     <= {RS_TAG_W{1'b0}};
        p1_div_cand_br           <= 1'b0;
        p1_div_cand_mem_read     <= 1'b0;
        p1_div_cand_mem2reg      <= 1'b0;
        p1_div_cand_alu_op       <= 3'd0;
        p1_div_cand_mem_write    <= 1'b0;
        p1_div_cand_alu_src1     <= 2'd0;
        p1_div_cand_alu_src2     <= 2'd0;
        p1_div_cand_br_addr_mode <= 1'b0;
        p1_div_cand_regs_write   <= 1'b0;
        p1_div_cand_fu           <= 3'd0;
        p1_div_cand_tid          <= 1'b0;
        p1_div_cand_is_mret      <= 1'b0;
        p1_div_cand_order_id     <= {`METADATA_ORDER_ID_W{1'b0}};
        p1_div_cand_epoch        <= {`METADATA_EPOCH_W{1'b0}};
    end else begin
        if (flush) begin
            // Clear fu_busy on GLOBAL flush (trap/interrupt entry,
            // flush_order_valid=0): the LSU kills all pending ops for the
            // flushed thread, so no WB will arrive to clear fu_busy.
            if (!flush_order_valid) begin
                mem_fu_busy <= 1'b0;
                mul_fu_busy <= 1'b0;
                div_fu_busy <= 1'b0;
            end else if (mem_fu_flush_kill) begin
                // Partial flush (branch redirect): clear mem_fu_busy if the
                // in-flight mem op belongs to the flushed thread AND is younger
                // than the flush point. The LSU will discard this request
                // without producing wb1.
                mem_fu_busy <= 1'b0;
            end
        end

        if (mem_cand_clear) begin
            p1_mem_cand_valid <= 1'b0;
        end else if (mem_cand_set) begin
            p1_mem_cand_valid <= 1'b1;
        end
        {
            p1_mem_cand_tag, p1_mem_cand_pc, p1_mem_cand_imm, p1_mem_cand_func3, p1_mem_cand_func7,
            p1_mem_cand_rd, p1_mem_cand_rs1, p1_mem_cand_rs2, p1_mem_cand_rs1_used, p1_mem_cand_rs2_used,
            p1_mem_cand_src1_tag, p1_mem_cand_src2_tag, p1_mem_cand_br, p1_mem_cand_mem_read, p1_mem_cand_mem2reg,
            p1_mem_cand_alu_op, p1_mem_cand_mem_write, p1_mem_cand_alu_src1, p1_mem_cand_alu_src2,
            p1_mem_cand_br_addr_mode, p1_mem_cand_regs_write, p1_mem_cand_fu, p1_mem_cand_tid,
            p1_mem_cand_is_mret, p1_mem_cand_order_id, p1_mem_cand_epoch
        } <= mem_cand_data_d;

        if (p1_mul_cand_flush_kill) begin
            p1_mul_cand_valid <= 1'b0;
        end else if (p1_winner_valid && p1_winner == 2'b11) begin
            if (mul_iss_valid && !mul_raw_issue_flush_kill) begin
                p1_mul_cand_valid        <= 1'b1;
                p1_mul_cand_tag          <= mul_iss_tag;
                p1_mul_cand_pc           <= mul_iss_pc;
                p1_mul_cand_imm          <= mul_iss_imm;
                p1_mul_cand_func3        <= mul_iss_func3;
                p1_mul_cand_func7        <= mul_iss_func7;
                p1_mul_cand_rd           <= mul_iss_rd;
                p1_mul_cand_rs1          <= mul_iss_rs1;
                p1_mul_cand_rs2          <= mul_iss_rs2;
                p1_mul_cand_rs1_used     <= mul_iss_rs1_used;
                p1_mul_cand_rs2_used     <= mul_iss_rs2_used;
                p1_mul_cand_src1_tag     <= mul_iss_src1_tag;
                p1_mul_cand_src2_tag     <= mul_iss_src2_tag;
                p1_mul_cand_br           <= mul_iss_br;
                p1_mul_cand_mem_read     <= mul_iss_mem_read;
                p1_mul_cand_mem2reg      <= mul_iss_mem2reg;
                p1_mul_cand_alu_op       <= mul_iss_alu_op;
                p1_mul_cand_mem_write    <= mul_iss_mem_write;
                p1_mul_cand_alu_src1     <= mul_iss_alu_src1;
                p1_mul_cand_alu_src2     <= mul_iss_alu_src2;
                p1_mul_cand_br_addr_mode <= mul_iss_br_addr_mode;
                p1_mul_cand_regs_write   <= mul_iss_regs_write;
                p1_mul_cand_fu           <= mul_iss_fu;
                p1_mul_cand_tid          <= mul_iss_tid;
                p1_mul_cand_is_mret      <= mul_iss_is_mret;
                p1_mul_cand_order_id     <= mul_iss_order_id;
                p1_mul_cand_epoch        <= mul_iss_epoch;
            end else begin
                p1_mul_cand_valid <= 1'b0;
            end
        end else if (!p1_mul_cand_valid && mul_iss_valid && !mul_raw_issue_flush_kill) begin
            p1_mul_cand_valid        <= 1'b1;
            p1_mul_cand_tag          <= mul_iss_tag;
            p1_mul_cand_pc           <= mul_iss_pc;
            p1_mul_cand_imm          <= mul_iss_imm;
            p1_mul_cand_func3        <= mul_iss_func3;
            p1_mul_cand_func7        <= mul_iss_func7;
            p1_mul_cand_rd           <= mul_iss_rd;
            p1_mul_cand_rs1          <= mul_iss_rs1;
            p1_mul_cand_rs2          <= mul_iss_rs2;
            p1_mul_cand_rs1_used     <= mul_iss_rs1_used;
            p1_mul_cand_rs2_used     <= mul_iss_rs2_used;
            p1_mul_cand_src1_tag     <= mul_iss_src1_tag;
            p1_mul_cand_src2_tag     <= mul_iss_src2_tag;
            p1_mul_cand_br           <= mul_iss_br;
            p1_mul_cand_mem_read     <= mul_iss_mem_read;
            p1_mul_cand_mem2reg      <= mul_iss_mem2reg;
            p1_mul_cand_alu_op       <= mul_iss_alu_op;
            p1_mul_cand_mem_write    <= mul_iss_mem_write;
            p1_mul_cand_alu_src1     <= mul_iss_alu_src1;
            p1_mul_cand_alu_src2     <= mul_iss_alu_src2;
            p1_mul_cand_br_addr_mode <= mul_iss_br_addr_mode;
            p1_mul_cand_regs_write   <= mul_iss_regs_write;
            p1_mul_cand_fu           <= mul_iss_fu;
            p1_mul_cand_tid          <= mul_iss_tid;
            p1_mul_cand_is_mret      <= mul_iss_is_mret;
            p1_mul_cand_order_id     <= mul_iss_order_id;
            p1_mul_cand_epoch        <= mul_iss_epoch;
        end

        // DIV candidate update
        if (p1_div_cand_flush_kill) begin
            p1_div_cand_valid <= 1'b0;
        end else if (p1_winner_valid && p1_winner == 2'b01) begin
            if (div_iss_valid && !div_raw_issue_flush_kill) begin
                p1_div_cand_valid        <= 1'b1;
                p1_div_cand_tag          <= div_iss_tag;
                p1_div_cand_pc           <= div_iss_pc;
                p1_div_cand_imm          <= div_iss_imm;
                p1_div_cand_func3        <= div_iss_func3;
                p1_div_cand_func7        <= div_iss_func7;
                p1_div_cand_rd           <= div_iss_rd;
                p1_div_cand_rs1          <= div_iss_rs1;
                p1_div_cand_rs2          <= div_iss_rs2;
                p1_div_cand_rs1_used     <= div_iss_rs1_used;
                p1_div_cand_rs2_used     <= div_iss_rs2_used;
                p1_div_cand_src1_tag     <= div_iss_src1_tag;
                p1_div_cand_src2_tag     <= div_iss_src2_tag;
                p1_div_cand_br           <= div_iss_br;
                p1_div_cand_mem_read     <= div_iss_mem_read;
                p1_div_cand_mem2reg      <= div_iss_mem2reg;
                p1_div_cand_alu_op       <= div_iss_alu_op;
                p1_div_cand_mem_write    <= div_iss_mem_write;
                p1_div_cand_alu_src1     <= div_iss_alu_src1;
                p1_div_cand_alu_src2     <= div_iss_alu_src2;
                p1_div_cand_br_addr_mode <= div_iss_br_addr_mode;
                p1_div_cand_regs_write   <= div_iss_regs_write;
                p1_div_cand_fu           <= div_iss_fu;
                p1_div_cand_tid          <= div_iss_tid;
                p1_div_cand_is_mret      <= div_iss_is_mret;
                p1_div_cand_order_id     <= div_iss_order_id;
                p1_div_cand_epoch        <= div_iss_epoch;
            end else begin
                p1_div_cand_valid <= 1'b0;
            end
        end else if (!p1_div_cand_valid && div_iss_valid && !div_raw_issue_flush_kill) begin
            p1_div_cand_valid        <= 1'b1;
            p1_div_cand_tag          <= div_iss_tag;
            p1_div_cand_pc           <= div_iss_pc;
            p1_div_cand_imm          <= div_iss_imm;
            p1_div_cand_func3        <= div_iss_func3;
            p1_div_cand_func7        <= div_iss_func7;
            p1_div_cand_rd           <= div_iss_rd;
            p1_div_cand_rs1          <= div_iss_rs1;
            p1_div_cand_rs2          <= div_iss_rs2;
            p1_div_cand_rs1_used     <= div_iss_rs1_used;
            p1_div_cand_rs2_used     <= div_iss_rs2_used;
            p1_div_cand_src1_tag     <= div_iss_src1_tag;
            p1_div_cand_src2_tag     <= div_iss_src2_tag;
            p1_div_cand_br           <= div_iss_br;
            p1_div_cand_mem_read     <= div_iss_mem_read;
            p1_div_cand_mem2reg      <= div_iss_mem2reg;
            p1_div_cand_alu_op       <= div_iss_alu_op;
            p1_div_cand_mem_write    <= div_iss_mem_write;
            p1_div_cand_alu_src1     <= div_iss_alu_src1;
            p1_div_cand_alu_src2     <= div_iss_alu_src2;
            p1_div_cand_br_addr_mode <= div_iss_br_addr_mode;
            p1_div_cand_regs_write   <= div_iss_regs_write;
            p1_div_cand_fu           <= div_iss_fu;
            p1_div_cand_tid          <= div_iss_tid;
            p1_div_cand_is_mret      <= div_iss_is_mret;
            p1_div_cand_order_id     <= div_iss_order_id;
            p1_div_cand_epoch        <= div_iss_epoch;
        end

        if (p1_winner_valid && p1_winner == 2'b10) begin
            // A freshly issued pipe1 MEM op must keep the FU busy even if the
            // previous MEM op also completes on WB1 in the same cycle.
            mem_fu_busy     <= 1'b1;
            mem_fu_order_id <= p1_mem_cand_order_id;
            mem_fu_tid      <= p1_mem_cand_tid;
        end else if (wb1_valid && (wb1_fu == `FU_LOAD || wb1_fu == `FU_STORE)) begin
            mem_fu_busy <= 1'b0;
        end
        if (p1_winner_valid && p1_winner == 2'b11) begin
            // Same priority rule for MUL: new issue beats same-cycle clear.
            mul_fu_busy <= 1'b1;
        end else if (wb1_valid && wb1_fu == `FU_MUL) begin
            mul_fu_busy <= 1'b0;
        end
        if (p1_winner_valid && p1_winner == 2'b01) begin
            // Same priority rule for DIV: new issue beats same-cycle clear.
            div_fu_busy <= 1'b1;
        end else if (wb1_valid && wb1_fu == `FU_DIV) begin
            div_fu_busy <= 1'b0;
        end
    end
end


// ═════════════════════════════════════════════════════════════════
// 12. Pipe1 Arbiter
// ═════════════════════════════════════════════════════════════════
iq_pipe1_arbiter u_p1_arb (
    .mem_valid    (p1_mem_cand_arb_valid),
    .mem_order_id (p1_mem_cand_order_id),
    .mul_valid    (p1_mul_cand_arb_valid),
    .mul_order_id (p1_mul_cand_order_id),
    .div_valid    (p1_div_cand_arb_valid),
    .div_order_id (p1_div_cand_order_id),
    .winner       (p1_winner),
    .winner_valid (p1_winner_valid)
);

// ═════════════════════════════════════════════════════════════════
// 12. Issue Output Muxing
// ═════════════════════════════════════════════════════════════════

// Pipe0 = INT IQ issue
assign iss0_valid     = int_iss_valid;
assign iss0_tag       = int_iss_tag;
assign iss0_pc        = int_iss_pc;
assign iss0_imm       = int_iss_imm;
assign iss0_func3     = int_iss_func3;
assign iss0_func7     = int_iss_func7;
assign iss0_rd        = int_iss_rd;
assign iss0_rs1       = int_iss_rs1;
assign iss0_rs2       = int_iss_rs2;
assign iss0_rs1_used  = int_iss_rs1_used;
assign iss0_rs2_used  = int_iss_rs2_used;
assign iss0_src1_tag  = int_iss_src1_tag;
assign iss0_src2_tag  = int_iss_src2_tag;
assign iss0_br        = int_iss_br;
assign iss0_mem_read  = int_iss_mem_read;
assign iss0_mem2reg   = int_iss_mem2reg;
assign iss0_alu_op    = int_iss_alu_op;
assign iss0_mem_write = int_iss_mem_write;
assign iss0_alu_src1  = int_iss_alu_src1;
assign iss0_alu_src2  = int_iss_alu_src2;
assign iss0_br_addr_mode = int_iss_br_addr_mode;
assign iss0_regs_write= int_iss_regs_write;
assign iss0_fu        = int_iss_fu;
assign iss0_tid       = int_iss_tid;
assign iss0_order_id  = int_iss_order_id;
assign iss0_epoch     = int_iss_epoch;


// ═════════════════════════════════════════════════════════════════
// 13. Sequential: Tag alloc/free, reg_result update
// ═════════════════════════════════════════════════════════════════
integer ti, ri;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (ti = 0; ti <= RS_DEPTH; ti = ti + 1) begin
            tag_in_use[ti]     <= 1'b0;
            tag_ready_v[ti]    <= 1'b0;
            tag_just_ready[ti] <= 1'b0;
            tag_live_valid_v[ti] <= 1'b0;
            tag_live_seq[ti]   <= {`METADATA_ORDER_ID_W{1'b0}};
            tag_ready_seq[ti]  <= {`METADATA_ORDER_ID_W{1'b0}};
            tag_live_tid[ti]   <= 1'b0;
        end
        for (ti = 0; ti < NUM_THREAD; ti = ti + 1)
            for (ri = 0; ri < 32; ri = ri + 1) begin
                reg_result[ti][ri]       <= {RS_TAG_W{1'b0}};
                reg_result_order[ti][ri] <= {`METADATA_ORDER_ID_W{1'b0}};
            end
    end else begin
        // Clear just_ready pulses
        for (ti = 1; ti <= RS_DEPTH; ti = ti + 1)
            tag_just_ready[ti] <= 1'b0;

        // ── WB: mark tags ready ──
        if (wb0_valid && wb0_regs_write && wb0_tag != {RS_TAG_W{1'b0}}) begin
            tag_ready_v[wb0_tag]    <= 1'b1;
            tag_just_ready[wb0_tag] <= 1'b1;
            tag_ready_seq[wb0_tag]  <= tag_live_seq[wb0_tag];
        end
        if (wb1_valid && wb1_regs_write && wb1_tag != {RS_TAG_W{1'b0}}) begin
            tag_ready_v[wb1_tag]    <= 1'b1;
            tag_just_ready[wb1_tag] <= 1'b1;
            tag_ready_seq[wb1_tag]  <= tag_live_seq[wb1_tag];
        end
        if (lsu_early_wakeup_valid && lsu_early_wakeup_tag != {RS_TAG_W{1'b0}}) begin
            tag_ready_v[lsu_early_wakeup_tag] <= 1'b1;
            tag_just_ready[lsu_early_wakeup_tag] <= 1'b1;
            tag_ready_seq[lsu_early_wakeup_tag] <= tag_live_seq[lsu_early_wakeup_tag];
        end

        // ── Commit: free tags, clear reg_result ──
        if (commit0_valid && commit0_tag != {RS_TAG_W{1'b0}}) begin
            tag_in_use[commit0_tag]    <= 1'b0;
            tag_ready_v[commit0_tag]   <= 1'b0;
            tag_live_valid_v[commit0_tag]<= 1'b0;
            tag_ready_seq[commit0_tag] <= {`METADATA_ORDER_ID_W{1'b0}};
            tag_live_tid[commit0_tag]  <= 1'b0;
            // Clear reg_result if still pointing to this tag
            for (ri = 0; ri < 32; ri = ri + 1) begin
                if (reg_result[commit0_tid][ri] == commit0_tag &&
                    reg_result_order[commit0_tid][ri] == commit0_order_id) begin
                    reg_result[commit0_tid][ri] <= {RS_TAG_W{1'b0}};
                    reg_result_order[commit0_tid][ri] <= {`METADATA_ORDER_ID_W{1'b0}};
                end
            end
        end
        if (commit1_valid && commit1_tag != {RS_TAG_W{1'b0}}) begin
            tag_in_use[commit1_tag]    <= 1'b0;
            tag_ready_v[commit1_tag]   <= 1'b0;
            tag_live_valid_v[commit1_tag]<= 1'b0;
            tag_ready_seq[commit1_tag] <= {`METADATA_ORDER_ID_W{1'b0}};
            tag_live_tid[commit1_tag]  <= 1'b0;
            for (ri = 0; ri < 32; ri = ri + 1) begin
                if (reg_result[commit1_tid][ri] == commit1_tag &&
                    reg_result_order[commit1_tid][ri] == commit1_order_id) begin
                    reg_result[commit1_tid][ri] <= {RS_TAG_W{1'b0}};
                    reg_result_order[commit1_tid][ri] <= {`METADATA_ORDER_ID_W{1'b0}};
                end
            end
        end

        // ── Flush: clear reg_result for flushed thread ──
        if (flush) begin
            for (ti = 1; ti <= RS_DEPTH; ti = ti + 1) begin
                if (tag_live_valid_v[ti] && (tag_live_tid[ti] == flush_tid) &&
                    (!flush_order_valid || (tag_live_seq[ti] > flush_order_id))) begin
                    tag_in_use[ti]       <= 1'b0;
                    tag_ready_v[ti]      <= 1'b0;
                    tag_just_ready[ti]   <= 1'b0;
                    tag_live_valid_v[ti] <= 1'b0;
                    tag_live_seq[ti]     <= {`METADATA_ORDER_ID_W{1'b0}};
                    tag_ready_seq[ti]    <= {`METADATA_ORDER_ID_W{1'b0}};
                    tag_live_tid[ti]     <= 1'b0;
                end
            end
            for (ri = 0; ri < 32; ri = ri + 1) begin
                if (!flush_order_valid ||
                    (reg_result_order[flush_tid][ri] > flush_order_id)) begin
                    reg_result[flush_tid][ri] <= {RS_TAG_W{1'b0}};
                    reg_result_order[flush_tid][ri] <= {`METADATA_ORDER_ID_W{1'b0}};
                end
            end
        end

        // ── Dispatch: allocate tags, update reg_result ──
        if (d0_go) begin
            tag_in_use[free0_tag]    <= 1'b1;
            tag_ready_v[free0_tag]   <= 1'b0;
            tag_live_valid_v[free0_tag]<= 1'b1;
            tag_live_seq[free0_tag]  <= disp0_order_id;
            tag_live_tid[free0_tag]  <= disp0_tid;
            tag_ready_seq[free0_tag] <= {`METADATA_ORDER_ID_W{1'b0}};
            if (disp0_regs_write && disp0_rd != 5'd0) begin
                reg_result[disp0_tid][disp0_rd]       <= free0_tag;
                reg_result_order[disp0_tid][disp0_rd] <= disp0_order_id;
            end
        end
        if (d1_go) begin
            tag_in_use[free1_tag]    <= 1'b1;
            tag_ready_v[free1_tag]   <= 1'b0;
            tag_live_valid_v[free1_tag]<= 1'b1;
            tag_live_seq[free1_tag]  <= disp1_order_id;
            tag_live_tid[free1_tag]  <= disp1_tid;
            tag_ready_seq[free1_tag] <= {`METADATA_ORDER_ID_W{1'b0}};
            if (disp1_regs_write && disp1_rd != 5'd0) begin
                reg_result[disp1_tid][disp1_rd]       <= free1_tag;
                reg_result_order[disp1_tid][disp1_rd] <= disp1_order_id;
            end
        end
    end
end

// ═════════════════════════════════════════════════════════════════
// 14. Debug Signals (simplified — mostly zeroed)
// ═════════════════════════════════════════════════════════════════
assign debug_br_found_t0        = (br_pending_cnt_t0 != 6'd0);
assign debug_branch_in_flight_t0= branch_in_flight_t0;
assign debug_oldest_br_ready_t0 = 1'b0;
assign debug_oldest_br_just_woke_t0 = 1'b0;
assign debug_oldest_br_qj_t0   = 4'd0;
assign debug_oldest_br_qk_t0   = 4'd0;
assign debug_slot1_flags        = 4'd0;
assign debug_slot1_pc_lo        = 8'd0;
assign debug_slot1_qj           = 4'd0;
assign debug_slot1_qk           = 4'd0;
assign debug_tag2_flags         = 4'd0;
assign debug_reg_x12_tag_t0     = reg_result[0][12][3:0];
assign debug_slot1_issue_flags  = 4'd0;
assign debug_sel0_idx           = 4'd0;
assign debug_slot1_fu           = 4'd0;
assign debug_oldest_br_seq_lo_t0= 8'd0;
assign debug_rs_flags_flat      = 16'd0;
assign debug_rs_pc_lo_flat      = 32'd0;
assign debug_rs_fu_flat         = 16'd0;
assign debug_rs_qj_flat         = 16'd0;
assign debug_rs_qk_flat         = 16'd0;
assign debug_rs_seq_lo_flat     = 32'd0;
assign debug_spec_dispatch0     = d0_go && d0_after_branch;
assign debug_spec_dispatch1     = d1_go && d1_after_branch;
assign debug_branch_gated_mem_issue = iq_mem_order_blocked_any;
assign debug_flush_killed_speculative =
    iq_int_flush_killed_any || iq_mem_flush_killed_any ||
    iq_mul_flush_killed_any || iq_div_flush_killed_any ||
    p1_mem_cand_flush_kill || p1_mul_cand_flush_kill || p1_div_cand_flush_kill ||
    mem_raw_issue_flush_kill || mul_raw_issue_flush_kill || div_raw_issue_flush_kill;

// RoCC (unused in FPGA mode)
assign iss0_is_rocc = 1'b0;

endmodule
