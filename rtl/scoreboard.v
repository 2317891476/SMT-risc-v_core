// =============================================================================
// Module : scoreboard
// Description: Enhanced Scoreboard with 16-entry Reservation Station and
//   Dual-Issue Arbiter. Implements the full Scoreboard algorithm:
//     Dispatch → Issue → Execute → WriteResult
//
//   Status Tables:
//     1) RS Entry Table   — per-entry {valid, issued, tag, seq, tid, qj, qk, qd, ready, payload}
//     2) FU Status        — fu_busy[1..7], which FU slots are occupied
//     3) Reg Result Status — reg_result[thread][0..31], tag producing that register
//
//   Dual-Issue Logic:
//     - Issue Port 0: selects oldest ready entry for any FU (INT/Branch preferred)
//     - Issue Port 1: selects second-oldest ready entry compatible with Port 1 FUs
//     - Constraint: two issued instructions must target different FUs
//     - Constraint: at most 1 branch per cycle
//     - Constraint: at most 1 load/store per cycle
//
//   Dual-Dispatch:
//     - Can accept 2 instructions per cycle from dual decoder
//     - Each dispatch port allocates one RS entry and updates reg_result table
//
//   CDB (Common Data Bus) Wakeup:
//     - Two writeback ports broadcast tag; matching qj/qk/qd entries are cleared
// =============================================================================
`include "define.v"

module scoreboard #(
    parameter RS_DEPTH   = 16,
    parameter RS_IDX_W   = 4,       // log2(RS_DEPTH)
    parameter RS_TAG_W   = 5,       // tag bits (must be > log2(RS_DEPTH))
    parameter NUM_FU     = 8,       // FU IDs 1..7 used
    parameter NUM_THREAD = 2
)(
    input  wire                    clk,
    input  wire                    rstn,

    // ─── Flush ──────────────────────────────────────────────────
    input  wire                    flush,
    input  wire [0:0]              flush_tid,

    // ─── Dispatch Port 0 ────────────────────────────────────────
    input  wire                    disp0_valid,
    input  wire [31:0]             disp0_pc,
    input  wire [31:0]             disp0_imm,
    input  wire [2:0]              disp0_func3,
    input  wire                    disp0_func7,
    input  wire [4:0]              disp0_rd,
    input  wire                    disp0_br,
    input  wire                    disp0_mem_read,
    input  wire                    disp0_mem2reg,
    input  wire [2:0]              disp0_alu_op,
    input  wire                    disp0_mem_write,
    input  wire [1:0]              disp0_alu_src1,
    input  wire [1:0]              disp0_alu_src2,
    input  wire                    disp0_br_addr_mode,
    input  wire                    disp0_regs_write,
    input  wire [4:0]              disp0_rs1,
    input  wire [4:0]              disp0_rs2,
    input  wire                    disp0_rs1_used,
    input  wire                    disp0_rs2_used,
    input  wire [2:0]              disp0_fu,
    input  wire [0:0]              disp0_tid,

    // ─── Dispatch Port 1 ────────────────────────────────────────
    input  wire                    disp1_valid,
    input  wire [31:0]             disp1_pc,
    input  wire [31:0]             disp1_imm,
    input  wire [2:0]              disp1_func3,
    input  wire                    disp1_func7,
    input  wire [4:0]              disp1_rd,
    input  wire                    disp1_br,
    input  wire                    disp1_mem_read,
    input  wire                    disp1_mem2reg,
    input  wire [2:0]              disp1_alu_op,
    input  wire                    disp1_mem_write,
    input  wire [1:0]              disp1_alu_src1,
    input  wire [1:0]              disp1_alu_src2,
    input  wire                    disp1_br_addr_mode,
    input  wire                    disp1_regs_write,
    input  wire [4:0]              disp1_rs1,
    input  wire [4:0]              disp1_rs2,
    input  wire                    disp1_rs1_used,
    input  wire                    disp1_rs2_used,
    input  wire [2:0]              disp1_fu,
    input  wire [0:0]              disp1_tid,

    // ─── Dispatch Stall ─────────────────────────────────────────
    output wire                    disp_stall,   // cannot accept either dispatch

    // ─── Dispatch Tag Outputs ───────────────────────────────────
    output wire [RS_TAG_W-1:0]     disp0_tag,    // tag allocated for dispatch 0
    output wire [RS_TAG_W-1:0]     disp1_tag,    // tag allocated for dispatch 1

    // ─── Issue Port 0 (INT/Branch pipe) ─────────────────────────
    output reg                     iss0_valid,
    output reg  [RS_TAG_W-1:0]     iss0_tag,
    output reg  [31:0]             iss0_pc,
    output reg  [31:0]             iss0_imm,
    output reg  [2:0]              iss0_func3,
    output reg                     iss0_func7,
    output reg  [4:0]              iss0_rd,
    output reg  [4:0]              iss0_rs1,
    output reg  [4:0]              iss0_rs2,
    output reg                     iss0_rs1_used,
    output reg                     iss0_rs2_used,
    output reg                     iss0_br,
    output reg                     iss0_mem_read,
    output reg                     iss0_mem2reg,
    output reg  [2:0]              iss0_alu_op,
    output reg                     iss0_mem_write,
    output reg  [1:0]              iss0_alu_src1,
    output reg  [1:0]              iss0_alu_src2,
    output reg                     iss0_br_addr_mode,
    output reg                     iss0_regs_write,
    output reg  [2:0]              iss0_fu,
    output reg  [0:0]              iss0_tid,

    // ─── Issue Port 1 (INT/MUL/MEM pipe) ────────────────────────
    output reg                     iss1_valid,
    output reg  [RS_TAG_W-1:0]     iss1_tag,
    output reg  [31:0]             iss1_pc,
    output reg  [31:0]             iss1_imm,
    output reg  [2:0]              iss1_func3,
    output reg                     iss1_func7,
    output reg  [4:0]              iss1_rd,
    output reg  [4:0]              iss1_rs1,
    output reg  [4:0]              iss1_rs2,
    output reg                     iss1_rs1_used,
    output reg                     iss1_rs2_used,
    output reg                     iss1_br,
    output reg                     iss1_mem_read,
    output reg                     iss1_mem2reg,
    output reg  [2:0]              iss1_alu_op,
    output reg                     iss1_mem_write,
    output reg  [1:0]              iss1_alu_src1,
    output reg  [1:0]              iss1_alu_src2,
    output reg                     iss1_br_addr_mode,
    output reg                     iss1_regs_write,
    output reg  [2:0]              iss1_fu,
    output reg  [0:0]              iss1_tid,

    // ─── Writeback Port 0 ───────────────────────────────────────
    input  wire                    wb0_valid,
    input  wire [RS_TAG_W-1:0]     wb0_tag,
    input  wire [4:0]              wb0_rd,
    input  wire                    wb0_regs_write,
    input  wire [2:0]              wb0_fu,
    input  wire [0:0]              wb0_tid,

    // ─── Writeback Port 1 ───────────────────────────────────────
    input  wire                    wb1_valid,
    input  wire [RS_TAG_W-1:0]     wb1_tag,
    input  wire [4:0]              wb1_rd,
    input  wire                    wb1_regs_write,
    input  wire [2:0]              wb1_fu,
    input  wire [0:0]              wb1_tid,

    // ─── Branch completion signal ───────────────────────────────
    input  wire                    br_complete,     // branch execution complete (taken or not)

    // ─── RoCC Backpressure ──────────────────────────────────────
    input  wire                    rocc_ready,      // RoCC is ready to accept command

    // ─── RoCC Identification ────────────────────────────────────
    input  wire                    iss0_is_rocc,    // Issue port 0 is RoCC command

    // ─── Dispatch Metadata ──────────────────────────────────────
    input  wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]    disp0_epoch,
    input  wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]    disp1_epoch,

    // ─── Issue Port 0 Metadata ──────────────────────────────────
    output reg  [`METADATA_ORDER_ID_W-1:0] iss0_order_id,
    output reg  [`METADATA_EPOCH_W-1:0]    iss0_epoch,

    // ─── Issue Port 1 Metadata ──────────────────────────────────
    output reg  [`METADATA_ORDER_ID_W-1:0] iss1_order_id,
    output reg  [`METADATA_EPOCH_W-1:0]    iss1_epoch
);

// ═══════════════ RS Entry Storage ═══════════════════════════════════════════
reg                     win_valid       [0:RS_DEPTH-1];
reg                     win_issued      [0:RS_DEPTH-1];
reg  [RS_TAG_W-1:0]     win_tag         [0:RS_DEPTH-1];
reg  [15:0]             win_seq         [0:RS_DEPTH-1];
reg  [0:0]              win_tid         [0:RS_DEPTH-1];

// Dependencies
reg  [RS_TAG_W-1:0]     win_qj          [0:RS_DEPTH-1];
reg  [RS_TAG_W-1:0]     win_qk          [0:RS_DEPTH-1];
reg  [RS_TAG_W-1:0]     win_qd          [0:RS_DEPTH-1];
reg                     win_ready       [0:RS_DEPTH-1];

// Instruction payload
reg [31:0]             win_pc          [0:RS_DEPTH-1];
reg [31:0]             win_imm         [0:RS_DEPTH-1];
reg [2:0]              win_func3       [0:RS_DEPTH-1];
reg                    win_func7       [0:RS_DEPTH-1];
reg [4:0]              win_rd          [0:RS_DEPTH-1];
reg                    win_br          [0:RS_DEPTH-1];
reg                    win_mem_read    [0:RS_DEPTH-1];
reg                    win_mem2reg     [0:RS_DEPTH-1];
reg [2:0]              win_alu_op      [0:RS_DEPTH-1];
reg                    win_mem_write   [0:RS_DEPTH-1];
reg [1:0]              win_alu_src1    [0:RS_DEPTH-1];
reg [1:0]              win_alu_src2    [0:RS_DEPTH-1];
reg                    win_br_addr_mode[0:RS_DEPTH-1];
reg                    win_regs_write  [0:RS_DEPTH-1];
reg [4:0]              win_rs1         [0:RS_DEPTH-1];
reg [4:0]              win_rs2         [0:RS_DEPTH-1];
reg                    win_rs1_used    [0:RS_DEPTH-1];
reg                    win_rs2_used    [0:RS_DEPTH-1];
reg [2:0]              win_fu          [0:RS_DEPTH-1];

// Metadata
reg [`METADATA_ORDER_ID_W-1:0] win_order_id  [0:RS_DEPTH-1];
reg [`METADATA_EPOCH_W-1:0]    win_epoch     [0:RS_DEPTH-1];

// ═══════════════ FU Status Table ═══════════════════════════════════════════
reg                     fu_busy         [1:NUM_FU-1];

// ═══════════════ Register Result Status (per-thread) ════════════════════════
reg  [RS_TAG_W-1:0]     reg_result      [0:NUM_THREAD-1][0:31];

// ═══════════════ Allocation Pointer ════════════════════════════════════════
reg  [15:0]             alloc_seq;

// ═══════════════ Free Slot Search ══════════════════════════════════════════
reg                     free0_found, free1_found;
reg  [RS_IDX_W-1:0]     free0_idx,   free1_idx;
wire [RS_TAG_W-1:0]     alloc0_tag,  alloc1_tag;

integer i, j;

always @(*) begin
    free0_found = 1'b0;
    free1_found = 1'b0;
    free0_idx   = {RS_IDX_W{1'b0}};
    free1_idx   = {RS_IDX_W{1'b0}};

    // Find first free slot
    for (i = 0; i < RS_DEPTH; i = i + 1) begin
        if (!free0_found && !win_valid[i]) begin
            free0_found = 1'b1;
            free0_idx   = i[RS_IDX_W-1:0];
        end
    end
    // Find second free slot (different from first)
    for (i = 0; i < RS_DEPTH; i = i + 1) begin
        if (!free1_found && !win_valid[i] && !(free0_found && (i[RS_IDX_W-1:0] == free0_idx))) begin
            free1_found = 1'b1;
            free1_idx   = i[RS_IDX_W-1:0];
        end
    end
end

assign alloc0_tag = win_tag[free0_idx];
assign alloc1_tag = win_tag[free1_idx];

// Dispatch tag outputs for ROB allocation
assign disp0_tag = alloc0_tag;
assign disp1_tag = alloc1_tag;

// Stall: cannot accept 2 dispatches without 2 free slots
// (or 1 dispatch without 1 free slot)
wire can_accept_1, can_accept_2;
assign can_accept_1 = free0_found;
assign can_accept_2 = free0_found && free1_found;

// ═══════════════ Pending Branch Detection ══════════════════════════════════
// When a branch is pending (dispatched but not yet issued), we must stall
// subsequent dispatches to prevent speculative execution issues.
// This is a conservative approach - the branch must be issued before we
// can dispatch more instructions for the same thread.

// Branch stall for dispatch: stop dispatch when branch is pending for the same thread
wire branch_stall;
assign branch_stall = (disp0_valid && pending_branch_t0 && disp0_tid == 1'b0) ||
                      (disp0_valid && pending_branch_t1 && disp0_tid == 1'b1) ||
                      (disp1_valid && pending_branch_t0 && disp1_tid == 1'b0) ||
                      (disp1_valid && pending_branch_t1 && disp1_tid == 1'b1);

assign disp_stall   = (disp0_valid && disp1_valid && !can_accept_2) ||
                      (disp0_valid && !disp1_valid && !can_accept_1) ||
                      (!disp0_valid && disp1_valid && !can_accept_1) ||
                      branch_stall;

// ═══════════════ Dependency Lookup (combinational) ═════════════════════════
// For dispatch port 0:
reg [RS_TAG_W-1:0] d0_src1_tag, d0_src2_tag, d0_dst_tag;
// For dispatch port 1:
reg [RS_TAG_W-1:0] d1_src1_tag, d1_src2_tag, d1_dst_tag;

always @(*) begin
    // ── Dispatch 0 dependency lookup ────────────────────────────
    d0_src1_tag = {RS_TAG_W{1'b0}};
    d0_src2_tag = {RS_TAG_W{1'b0}};
    d0_dst_tag  = {RS_TAG_W{1'b0}};

    if (disp0_rs1_used && (disp0_rs1 != 5'd0))
        d0_src1_tag = reg_result[disp0_tid][disp0_rs1];
    if (disp0_rs2_used && (disp0_rs2 != 5'd0))
        d0_src2_tag = reg_result[disp0_tid][disp0_rs2];
    if (disp0_regs_write && (disp0_rd != 5'd0))
        d0_dst_tag  = reg_result[disp0_tid][disp0_rd];

    // CDB bypass: if wb is clearing a tag this cycle, clear it here too
    if (wb0_valid && wb0_regs_write && (wb0_tag != {RS_TAG_W{1'b0}})) begin
        if (d0_src1_tag == wb0_tag) d0_src1_tag = {RS_TAG_W{1'b0}};
        if (d0_src2_tag == wb0_tag) d0_src2_tag = {RS_TAG_W{1'b0}};
        if (d0_dst_tag  == wb0_tag) d0_dst_tag  = {RS_TAG_W{1'b0}};
    end
    if (wb1_valid && wb1_regs_write && (wb1_tag != {RS_TAG_W{1'b0}})) begin
        if (d0_src1_tag == wb1_tag) d0_src1_tag = {RS_TAG_W{1'b0}};
        if (d0_src2_tag == wb1_tag) d0_src2_tag = {RS_TAG_W{1'b0}};
        if (d0_dst_tag  == wb1_tag) d0_dst_tag  = {RS_TAG_W{1'b0}};
    end
end

always @(*) begin
    // ── Dispatch 1 dependency lookup ────────────────────────────
    d1_src1_tag = {RS_TAG_W{1'b0}};
    d1_src2_tag = {RS_TAG_W{1'b0}};
    d1_dst_tag  = {RS_TAG_W{1'b0}};

    if (disp1_rs1_used && (disp1_rs1 != 5'd0))
        d1_src1_tag = reg_result[disp1_tid][disp1_rs1];
    if (disp1_rs2_used && (disp1_rs2 != 5'd0))
        d1_src2_tag = reg_result[disp1_tid][disp1_rs2];
    if (disp1_regs_write && (disp1_rd != 5'd0))
        d1_dst_tag  = reg_result[disp1_tid][disp1_rd];

    // Must also consider disp0's allocation (same cycle dispatch dependency)
    // If disp0 writes rd, disp1's rs1/rs2 may depend on it
    if (disp0_valid && !disp_stall && disp0_regs_write && (disp0_rd != 5'd0) &&
        (disp0_tid == disp1_tid)) begin
        if (disp1_rs1_used && (disp1_rs1 == disp0_rd))
            d1_src1_tag = alloc0_tag;
        if (disp1_rs2_used && (disp1_rs2 == disp0_rd))
            d1_src2_tag = alloc0_tag;
        if (disp1_regs_write && (disp1_rd == disp0_rd))
            d1_dst_tag  = alloc0_tag;
    end

    // CDB bypass
    if (wb0_valid && wb0_regs_write && (wb0_tag != {RS_TAG_W{1'b0}})) begin
        if (d1_src1_tag == wb0_tag) d1_src1_tag = {RS_TAG_W{1'b0}};
        if (d1_src2_tag == wb0_tag) d1_src2_tag = {RS_TAG_W{1'b0}};
        if (d1_dst_tag  == wb0_tag) d1_dst_tag  = {RS_TAG_W{1'b0}};
    end
    if (wb1_valid && wb1_regs_write && (wb1_tag != {RS_TAG_W{1'b0}})) begin
        if (d1_src1_tag == wb1_tag) d1_src1_tag = {RS_TAG_W{1'b0}};
        if (d1_src2_tag == wb1_tag) d1_src2_tag = {RS_TAG_W{1'b0}};
        if (d1_dst_tag  == wb1_tag) d1_dst_tag  = {RS_TAG_W{1'b0}};
    end
end

// ═══════════════ Dual-Issue Selection (combinational) ══════════════════════
reg                     sel0_found, sel1_found;
reg  [RS_IDX_W-1:0]     sel0_idx,   sel1_idx;
reg  [15:0]             sel0_seq,   sel1_seq;
reg                     sel0_is_br, sel1_is_br;  // Track if selected instruction is a branch

// Captured issue info (for use in sequential logic)
reg                     sel0_issued_br_r, sel1_issued_br_r;  // Registered versions
reg  [RS_IDX_W-1:0]     sel0_issued_idx_r, sel1_issued_idx_r;
reg  [0:0]              sel0_issued_tid_r, sel1_issued_tid_r;

// ═══════════════ Branch Priority Issue ═════════════════════════════════════
// When a branch is pending, we must issue it before any other instruction.
// This prevents speculative execution of instructions after the branch.
// Find the oldest pending branch for each thread (even if not ready).

reg  [RS_IDX_W-1:0]     br_idx_t0,  br_idx_t1;
reg  [15:0]             br_seq_t0,  br_seq_t1;  // Min seq of pending branch
reg                     br_found_t0, br_found_t1;

always @(*) begin
    br_found_t0 = 1'b0;
    br_found_t1 = 1'b0;
    br_idx_t0   = {RS_IDX_W{1'b0}};
    br_idx_t1   = {RS_IDX_W{1'b0}};
    br_seq_t0   = 16'hffff;
    br_seq_t1   = 16'hffff;

    // Find the oldest pending branch (even if not ready yet)
    for (i = 0; i < RS_DEPTH; i = i + 1) begin
        if (win_valid[i] && !win_issued[i] && win_br[i]) begin
            if (win_tid[i] == 1'b0) begin
                if (!br_found_t0 || (win_seq[i] < br_seq_t0)) begin
                    br_found_t0 = 1'b1;
                    br_idx_t0   = i[RS_IDX_W-1:0];
                    br_seq_t0   = win_seq[i];
                end
            end else begin
                if (!br_found_t1 || (win_seq[i] < br_seq_t1)) begin
                    br_found_t1 = 1'b1;
                    br_idx_t1   = i[RS_IDX_W-1:0];
                    br_seq_t1   = win_seq[i];
                end
            end
        end
    end
end

// A thread has a pending branch if there's any valid unissued branch OR branch in flight
// "Branch in flight" means branch has been issued but result not yet determined (1 cycle delay)
reg  branch_in_flight_t0, branch_in_flight_t1;
// Track if we just issued a branch this cycle (to block same-cycle dual-issue)
reg  branch_issued_t0, branch_issued_t1;
// Save the seq of the last issued branch (used when branch_in_flight but br_found=0)
reg  [15:0]            last_br_seq_t0, last_br_seq_t1;

wire pending_branch_t0 = br_found_t0 || branch_in_flight_t0;
wire pending_branch_t1 = br_found_t1 || branch_in_flight_t1;
// Effective branch seq: use the branch being selected this cycle (if any), otherwise use saved seq
wire [15:0] effective_br_seq_t0 = (sel0_found && sel0_is_br && win_tid[sel0_idx] == 1'b0) ? win_seq[sel0_idx] :
                                  (sel1_found && sel1_is_br && win_tid[sel1_idx] == 1'b0) ? win_seq[sel1_idx] :
                                  branch_in_flight_t0 ? last_br_seq_t0 : br_seq_t0;
wire [15:0] effective_br_seq_t1 = (sel0_found && sel0_is_br && win_tid[sel0_idx] == 1'b1) ? win_seq[sel0_idx] :
                                  (sel1_found && sel1_is_br && win_tid[sel1_idx] == 1'b1) ? win_seq[sel1_idx] :
                                  branch_in_flight_t1 ? last_br_seq_t1 : br_seq_t1;

always @(*) begin
    sel0_found  = 1'b0;
    sel1_found  = 1'b0;
    sel0_idx    = {RS_IDX_W{1'b0}};
    sel1_idx    = {RS_IDX_W{1'b0}};
    sel0_seq    = 16'hffff;
    sel1_seq    = 16'hffff;
    sel0_is_br  = 1'b0;
    sel1_is_br  = 1'b0;

    // ── Default issue outputs ───────────────────────────────────
    iss0_valid = 1'b0; iss0_tag = 0; iss0_pc = 0; iss0_imm = 0;
    iss0_func3 = 0; iss0_func7 = 0; iss0_rd = 0;
    iss0_rs1 = 0; iss0_rs2 = 0; iss0_rs1_used = 0; iss0_rs2_used = 0;
    iss0_br = 0; iss0_mem_read = 0; iss0_mem2reg = 0;
    iss0_alu_op = 0; iss0_mem_write = 0;
    iss0_alu_src1 = 0; iss0_alu_src2 = 0;
    iss0_br_addr_mode = 0; iss0_regs_write = 0;
    iss0_fu = 0; iss0_tid = 0;

    iss1_valid = 1'b0; iss1_tag = 0; iss1_pc = 0; iss1_imm = 0;
    iss1_func3 = 0; iss1_func7 = 0; iss1_rd = 0;
    iss1_rs1 = 0; iss1_rs2 = 0; iss1_rs1_used = 0; iss1_rs2_used = 0;
    iss1_br = 0; iss1_mem_read = 0; iss1_mem2reg = 0;
    iss1_alu_op = 0; iss1_mem_write = 0;
    iss1_alu_src1 = 0; iss1_alu_src2 = 0;
    iss1_br_addr_mode = 0; iss1_regs_write = 0;
    iss1_fu = 0; iss1_tid = 0;

    // ── Pass 1: select oldest ready instruction for Port 0 ─────
    // Port 0 (exec_pipe0) handles: FU_INT0 (Branch/LUI/AUIPC), and can also take FU_INT1
    // Note: FU_INT0 and FU_INT1 don't use fu_busy since they can dual-issue
    // IMPORTANT: If a branch is pending, only issue instructions with seq <= branch seq
    `ifndef SYNTHESIS
    if (branch_in_flight_t0 || branch_in_flight_t1) begin
        $display("SB PASS1: branch_in_flight t0=%b t1=%b at start", branch_in_flight_t0, branch_in_flight_t1);
    end
    `endif
    `ifndef SYNTHESIS
    // Debug: show PASS1 selection status
    if (branch_in_flight_t0 || branch_in_flight_t1) begin
        $display("SB PASS1 START: branch_in_flight t0=%b t1=%b, sel0_is_br=%b", branch_in_flight_t0, branch_in_flight_t1, sel0_is_br);
        // Show all valid, not issued entries that could be candidates
        for (i = 0; i < RS_DEPTH; i = i + 1) begin
            if (win_valid[i] && !win_issued[i] && win_ready[i] &&
                (win_fu[i] == `FU_INT0 || win_fu[i] == `FU_INT1)) begin
                $display("  RS[%0d]: PC=%h fu=%0d br=%b tid=%0d seq=%0d will_check_bif=%b", 
                         i, win_pc[i], win_fu[i], win_br[i], win_tid[i], win_seq[i],
                         (win_tid[i] == 1'b0) ? branch_in_flight_t0 : branch_in_flight_t1);
            end
        end
    end
    `endif
    for (i = 0; i < RS_DEPTH; i = i + 1) begin
        if (win_valid[i] && !win_issued[i] && win_ready[i] &&
            (win_fu[i] != `FU_NOP) && 
            (win_fu[i] == `FU_INT0 || win_fu[i] == `FU_INT1)) begin

            // Branch serialization: if pending branch or branch in flight, only issue:
            // 1. The pending branch itself (if pending), or
            // 2. Instructions older than the branch (seq < branch seq)
            // Note: when branch_in_flight, don't issue ANY instruction (including other branches)
            // Also: if we already selected a branch in this pass, don't select anything else
            if ((win_tid[i] == 1'b0 && branch_in_flight_t0) ||
                (win_tid[i] == 1'b1 && branch_in_flight_t1)) begin
                // Skip - a branch is in flight
                `ifndef SYNTHESIS
                $display("SB: SKIP PC=%h tid=%0d seq=%0d due to branch_in_flight t0=%b", 
                         win_pc[i], win_tid[i], win_seq[i], branch_in_flight_t0);
                `endif
            end
            else if (sel0_is_br) begin
                // Skip - already selected a branch this pass
                `ifndef SYNTHESIS
                $display("SB: SKIP PC=%h tid=%0d seq=%0d due to sel0_is_br=1 (branch already selected)", 
                         win_pc[i], win_tid[i], win_seq[i]);
                `endif
            end
            else if ((win_tid[i] == 1'b0 && pending_branch_t0 && !win_br[i] && win_seq[i] >= effective_br_seq_t0) ||
                (win_tid[i] == 1'b1 && pending_branch_t1 && !win_br[i] && win_seq[i] >= effective_br_seq_t1)) begin
                // Skip - this instruction is after the pending branch
            end
            else if (!sel0_found || (win_seq[i] < sel0_seq)) begin
                sel0_found = 1'b1;
                sel0_idx   = i[RS_IDX_W-1:0];
                sel0_seq   = win_seq[i];
                sel0_is_br = win_br[i];  // Track if this is a branch
                `ifndef SYNTHESIS
                $display("SB SELECT: idx=%0d PC=%h br=%b seq=%0d bif_t0=%b", 
                         i, win_pc[i], win_br[i], win_seq[i], branch_in_flight_t0);
                `endif
            end
        end
    end

    // ── Pass 2: select second instruction for Port 1 ───────────
    // Port 1 (exec_pipe1) handles: FU_INT1, FU_MUL, FU_LOAD, FU_STORE
    // Note: FU_INT0 and FU_INT1 don't use fu_busy since they can dual-issue
    // IMPORTANT: Don't issue instructions if:
    // 1. A branch is in flight (from previous cycle)
    // 2. Port 0 is issuing a branch this cycle (it will be in flight next cycle)
    // port0_issuing_branch is computed as: sel0_found && win_br[sel0_idx]
    // We inline this check in the conditions below
    
    for (i = 0; i < RS_DEPTH; i = i + 1) begin
        if (win_valid[i] && !win_issued[i] && win_ready[i] &&
            (win_fu[i] == `FU_INT1 || win_fu[i] == `FU_MUL || 
             win_fu[i] == `FU_LOAD || win_fu[i] == `FU_STORE) &&
            !(win_fu[i] == `FU_MUL && fu_busy[win_fu[i]]) &&
            !(win_fu[i] == `FU_LOAD && fu_busy[win_fu[i]]) &&
            !(win_fu[i] == `FU_STORE && fu_busy[win_fu[i]]) &&
            !(sel0_found && (i[RS_IDX_W-1:0] == sel0_idx)) &&                 // not same entry
            !(sel0_is_br && win_br[i]) &&                                     // at most 1 branch
            !(sel0_found && (win_mem_read[sel0_idx]||win_mem_write[sel0_idx])  // at most 1 mem
                         && (win_mem_read[i]||win_mem_write[i]))) begin

            // Branch serialization: don't issue if branch is in flight or port 0 is issuing branch
            if ((win_tid[i] == 1'b0 && branch_in_flight_t0) ||
                (win_tid[i] == 1'b1 && branch_in_flight_t1) ||
                sel0_is_br) begin
                // Skip - a branch is in flight or will be in flight next cycle
            end
            else if ((win_tid[i] == 1'b0 && pending_branch_t0 && win_seq[i] >= effective_br_seq_t0) ||
                (win_tid[i] == 1'b1 && pending_branch_t1 && win_seq[i] >= effective_br_seq_t1)) begin
                // Skip - this instruction is after the pending branch
            end
            else if (!sel1_found || (win_seq[i] < sel1_seq)) begin
                sel1_found = 1'b1;
                sel1_idx   = i[RS_IDX_W-1:0];
                sel1_seq   = win_seq[i];
            end
        end
    end

    // ── Drive issue port 0 ──────────────────────────────────────
    if (sel0_found) begin
        iss0_valid        = 1'b1;
        iss0_tag          = win_tag[sel0_idx];
        iss0_pc           = win_pc[sel0_idx];
        iss0_imm          = win_imm[sel0_idx];
        iss0_func3        = win_func3[sel0_idx];
        iss0_func7        = win_func7[sel0_idx];
        iss0_rd           = win_rd[sel0_idx];
        iss0_rs1          = win_rs1[sel0_idx];
        iss0_rs2          = win_rs2[sel0_idx];
        iss0_rs1_used     = win_rs1_used[sel0_idx];
        iss0_rs2_used     = win_rs2_used[sel0_idx];
        iss0_br           = win_br[sel0_idx];
        iss0_mem_read     = win_mem_read[sel0_idx];
        iss0_mem2reg      = win_mem2reg[sel0_idx];
        iss0_alu_op       = win_alu_op[sel0_idx];
        iss0_mem_write    = win_mem_write[sel0_idx];
        iss0_alu_src1     = win_alu_src1[sel0_idx];
        iss0_alu_src2     = win_alu_src2[sel0_idx];
        iss0_br_addr_mode = win_br_addr_mode[sel0_idx];
        iss0_regs_write   = win_regs_write[sel0_idx];
        iss0_fu           = win_fu[sel0_idx];
        iss0_tid          = win_tid[sel0_idx];
        iss0_order_id     = win_order_id[sel0_idx];
        iss0_epoch        = win_epoch[sel0_idx];
    end

    // ── Drive issue port 1 ──────────────────────────────────────
    if (sel1_found) begin
        iss1_valid        = 1'b1;
        iss1_tag          = win_tag[sel1_idx];
        iss1_pc           = win_pc[sel1_idx];
        iss1_imm          = win_imm[sel1_idx];
        iss1_func3        = win_func3[sel1_idx];
        iss1_func7        = win_func7[sel1_idx];
        iss1_rd           = win_rd[sel1_idx];
        iss1_rs1          = win_rs1[sel1_idx];
        iss1_rs2          = win_rs2[sel1_idx];
        iss1_rs1_used     = win_rs1_used[sel1_idx];
        iss1_rs2_used     = win_rs2_used[sel1_idx];
        iss1_br           = win_br[sel1_idx];
        iss1_mem_read     = win_mem_read[sel1_idx];
        iss1_mem2reg      = win_mem2reg[sel1_idx];
        iss1_alu_op       = win_alu_op[sel1_idx];
        iss1_mem_write    = win_mem_write[sel1_idx];
        iss1_alu_src1     = win_alu_src1[sel1_idx];
        iss1_alu_src2     = win_alu_src2[sel1_idx];
        iss1_br_addr_mode = win_br_addr_mode[sel1_idx];
        iss1_regs_write   = win_regs_write[sel1_idx];
        iss1_fu           = win_fu[sel1_idx];
        iss1_tid          = win_tid[sel1_idx];
        iss1_order_id     = win_order_id[sel1_idx];
        iss1_epoch        = win_epoch[sel1_idx];
    end
end

// ═══════════════ Sequential Logic ══════════════════════════════════════════
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        alloc_seq <= 16'd0;
        branch_in_flight_t0 <= 1'b0;
        branch_in_flight_t1 <= 1'b0;
        branch_issued_t0 <= 1'b0;
        branch_issued_t1 <= 1'b0;
        sel0_issued_br_r <= 1'b0;
        sel1_issued_br_r <= 1'b0;
        sel0_issued_idx_r <= {RS_IDX_W{1'b0}};
        sel1_issued_idx_r <= {RS_IDX_W{1'b0}};
        sel0_issued_tid_r <= 1'b0;
        sel1_issued_tid_r <= 1'b0;
        last_br_seq_t0 <= 16'hffff;
        last_br_seq_t1 <= 16'hffff;
        for (i = 1; i < NUM_FU; i = i + 1)
            fu_busy[i] <= 1'b0;
        for (i = 0; i < 32; i = i + 1) begin
            reg_result[0][i] <= {RS_TAG_W{1'b0}};
            reg_result[1][i] <= {RS_TAG_W{1'b0}};
        end
        for (i = 0; i < RS_DEPTH; i = i + 1) begin
            win_valid[i]  <= 1'b0;
            win_issued[i] <= 1'b0;
            win_tag[i]    <= i[RS_TAG_W-1:0] + 1; // tags 1..RS_DEPTH
            win_seq[i]    <= 16'd0;
            win_tid[i]    <= 1'b0;
            win_qj[i]     <= {RS_TAG_W{1'b0}};
            win_qk[i]     <= {RS_TAG_W{1'b0}};
            win_qd[i]     <= {RS_TAG_W{1'b0}};
            win_ready[i]  <= 1'b0;
            win_pc[i]     <= 32'd0; win_imm[i]    <= 32'd0;
            win_func3[i]  <= 3'd0;  win_func7[i]  <= 1'b0;
            win_rd[i]     <= 5'd0;  win_br[i]     <= 1'b0;
            win_mem_read[i]     <= 1'b0; win_mem2reg[i]     <= 1'b0;
            win_alu_op[i]       <= 3'd0; win_mem_write[i]   <= 1'b0;
            win_alu_src1[i]     <= 2'd0; win_alu_src2[i]    <= 2'd0;
            win_br_addr_mode[i] <= 1'b0; win_regs_write[i]  <= 1'b0;
            win_rs1[i]          <= 5'd0; win_rs2[i]         <= 5'd0;
            win_rs1_used[i]     <= 1'b0; win_rs2_used[i]    <= 1'b0;
            win_fu[i]           <= 3'd0;
            win_order_id[i]     <= {`METADATA_ORDER_ID_W{1'b0}};
            win_epoch[i]        <= {`METADATA_EPOCH_W{1'b0}};
        end
    end
    else begin
        // ── Capture issue info for branch tracking ─────────────────────────────
        // These capture the selection state at the clock edge before combinational logic changes
        sel0_issued_br_r  <= sel0_is_br;
        sel1_issued_br_r  <= sel1_is_br;
        sel0_issued_idx_r <= sel0_idx;
        sel1_issued_idx_r <= sel1_idx;
        sel0_issued_tid_r <= win_tid[sel0_idx];
        sel1_issued_tid_r <= win_tid[sel1_idx];
        
        // ── Branch in flight tracking ───────────────────────────────────
        // branch_in_flight should be 1 from branch issue until branch result is known
        // This blocks subsequent instructions from issuing until branch result is known
        // Set when a branch is issued, clear when br_complete is received
        branch_in_flight_t0 <= ((sel0_found && sel0_is_br && win_tid[sel0_idx] == 1'b0) ||
                               (sel1_found && sel1_is_br && win_tid[sel1_idx] == 1'b0)) ||
                              (branch_in_flight_t0 && !br_complete);
        branch_in_flight_t1 <= ((sel0_found && sel0_is_br && win_tid[sel0_idx] == 1'b1) ||
                               (sel1_found && sel1_is_br && win_tid[sel1_idx] == 1'b1)) ||
                              (branch_in_flight_t1 && !br_complete);
        
        // Save the seq of the branch being issued (for use in next cycle when branch is in flight)
        if (sel0_found && sel0_is_br && win_tid[sel0_idx] == 1'b0)
            last_br_seq_t0 <= win_seq[sel0_idx];
        if (sel1_found && sel1_is_br && win_tid[sel1_idx] == 1'b0)
            last_br_seq_t0 <= win_seq[sel1_idx];
        if (sel0_found && sel0_is_br && win_tid[sel0_idx] == 1'b1)
            last_br_seq_t1 <= win_seq[sel0_idx];
        if (sel1_found && sel1_is_br && win_tid[sel1_idx] == 1'b1)
            last_br_seq_t1 <= win_seq[sel1_idx];
        
        // No longer need branch_issued - we use the direct assignment above
        // branch_issued_t0 and branch_issued_t1 are kept for debug only
        
        `ifndef SYNTHESIS
        // Debug: show branch_in_flight status at each clock
        if (branch_in_flight_t0 || branch_in_flight_t1) begin
            $display("SB[%0t]: branch_in_flight t0=%b t1=%b, br_complete=%b", $time, branch_in_flight_t0, branch_in_flight_t1, br_complete);
        end
        // Debug: show what's being selected this cycle
        if (sel0_found) begin
            $display("SB ISSUE: sel0_idx=%0d, is_br=%b, tid=%0d, PC=%h, seq=%0d", 
                     sel0_idx, sel0_is_br, win_tid[sel0_idx], win_pc[sel0_idx], win_seq[sel0_idx]);
        end
        if (sel1_found) begin
            $display("SB ISSUE1: sel1_idx=%0d, is_br=%b, tid=%0d, PC=%h, seq=%0d", 
                     sel1_idx, sel1_is_br, win_tid[sel1_idx], win_pc[sel1_idx], win_seq[sel1_idx]);
        end
        `endif
        // ── CDB Wakeup + FU release (WB port 0) ────────────────
        if (wb0_valid && (wb0_fu != 3'd0))
            fu_busy[wb0_fu] <= 1'b0;
        if (wb0_valid && wb0_regs_write && (wb0_rd != 5'd0) &&
            (wb0_tag != {RS_TAG_W{1'b0}}) &&
            (reg_result[wb0_tid][wb0_rd] == wb0_tag))
            reg_result[wb0_tid][wb0_rd] <= {RS_TAG_W{1'b0}};

        // ── CDB Wakeup + FU release (WB port 1) ────────────────
        if (wb1_valid && (wb1_fu != 3'd0))
            fu_busy[wb1_fu] <= 1'b0;
        if (wb1_valid && wb1_regs_write && (wb1_rd != 5'd0) &&
            (wb1_tag != {RS_TAG_W{1'b0}}) &&
            (reg_result[wb1_tid][wb1_rd] == wb1_tag))
            reg_result[wb1_tid][wb1_rd] <= {RS_TAG_W{1'b0}};

        // ── Wakeup RS entries: clear matching qj/qk/qd ─────────
        for (i = 0; i < RS_DEPTH; i = i + 1) begin
            if (win_valid[i]) begin : wakeup_logic
                reg [RS_TAG_W-1:0] nqj, nqk, nqd;
                nqj = win_qj[i]; nqk = win_qk[i]; nqd = win_qd[i];

                if (wb0_valid && wb0_regs_write && (wb0_tag != {RS_TAG_W{1'b0}})) begin
                    if (nqj == wb0_tag) nqj = {RS_TAG_W{1'b0}};
                    if (nqk == wb0_tag) nqk = {RS_TAG_W{1'b0}};
                    if (nqd == wb0_tag) nqd = {RS_TAG_W{1'b0}};
                end
                if (wb1_valid && wb1_regs_write && (wb1_tag != {RS_TAG_W{1'b0}})) begin
                    if (nqj == wb1_tag) nqj = {RS_TAG_W{1'b0}};
                    if (nqk == wb1_tag) nqk = {RS_TAG_W{1'b0}};
                    if (nqd == wb1_tag) nqd = {RS_TAG_W{1'b0}};
                end

                win_qj[i]    <= nqj;
                win_qk[i]    <= nqk;
                win_qd[i]    <= nqd;
                // Only source operand dependencies determine readiness
                win_ready[i] <= (nqj == {RS_TAG_W{1'b0}}) &&
                                (nqk == {RS_TAG_W{1'b0}});
            end
        end

        // ── Deallocate completed entries (match wb tag) ─────────
        for (i = 0; i < RS_DEPTH; i = i + 1) begin
            if (win_valid[i]) begin
                if ((wb0_valid && (wb0_tag != {RS_TAG_W{1'b0}}) && (win_tag[i] == wb0_tag)) ||
                    (wb1_valid && (wb1_tag != {RS_TAG_W{1'b0}}) && (win_tag[i] == wb1_tag))) begin
                    win_valid[i]  <= 1'b0;
                    win_issued[i] <= 1'b0;
                end
            end
        end

        // ── Flush ───────────────────────────────────────────────
        if (flush) begin
            alloc_seq <= 16'd0;
            for (i = 0; i < RS_DEPTH; i = i + 1) begin
                if (win_valid[i] && (win_tid[i] == flush_tid)) begin
                    if (win_regs_write[i] && (win_rd[i] != 5'd0) &&
                        (reg_result[win_tid[i]][win_rd[i]] == win_tag[i]))
                        reg_result[win_tid[i]][win_rd[i]] <= {RS_TAG_W{1'b0}};
                    win_valid[i]  <= 1'b0;
                    win_issued[i] <= 1'b0;
                    win_seq[i]    <= 16'd0;
                end
            end
        end
        else begin
            // ── Issue: mark selected entries as issued ───────────
            // Note: Only set fu_busy for MUL/LOAD/STORE, not for INT operations
            // For RoCC commands, only mark issued if RoCC is ready (backpressure)
            if (sel0_found && (!iss0_is_rocc || rocc_ready)) begin
                win_issued[sel0_idx] <= 1'b1;
                win_ready[sel0_idx]  <= 1'b0;
                if (win_fu[sel0_idx] != `FU_NOP && win_fu[sel0_idx] != `FU_INT0 && win_fu[sel0_idx] != `FU_INT1)
                    fu_busy[win_fu[sel0_idx]] <= 1'b1;
            end
            if (sel1_found) begin
                win_issued[sel1_idx] <= 1'b1;
                win_ready[sel1_idx]  <= 1'b0;
                if (win_fu[sel1_idx] != `FU_NOP && win_fu[sel1_idx] != `FU_INT0 && win_fu[sel1_idx] != `FU_INT1)
                    fu_busy[win_fu[sel1_idx]] <= 1'b1;
            end

            // ── Dispatch 0: allocate RS entry ───────────────────
            if (disp0_valid && !disp_stall && free0_found) begin
                win_valid[free0_idx]        <= 1'b1;
                win_issued[free0_idx]       <= 1'b0;
                win_seq[free0_idx]          <= alloc_seq;
                win_tid[free0_idx]          <= disp0_tid;
                win_pc[free0_idx]           <= disp0_pc;
                win_imm[free0_idx]          <= disp0_imm;
                win_func3[free0_idx]        <= disp0_func3;
                win_func7[free0_idx]        <= disp0_func7;
                win_rd[free0_idx]           <= disp0_rd;
                win_br[free0_idx]           <= disp0_br;
                win_mem_read[free0_idx]     <= disp0_mem_read;
                win_mem2reg[free0_idx]      <= disp0_mem2reg;
                win_alu_op[free0_idx]       <= disp0_alu_op;
                win_mem_write[free0_idx]    <= disp0_mem_write;
                win_alu_src1[free0_idx]     <= disp0_alu_src1;
                win_alu_src2[free0_idx]     <= disp0_alu_src2;
                win_br_addr_mode[free0_idx] <= disp0_br_addr_mode;
                win_regs_write[free0_idx]   <= disp0_regs_write;
                win_rs1[free0_idx]          <= disp0_rs1;
                win_rs2[free0_idx]          <= disp0_rs2;
                win_rs1_used[free0_idx]     <= disp0_rs1_used;
                win_rs2_used[free0_idx]     <= disp0_rs2_used;
                win_fu[free0_idx]           <= disp0_fu;
                win_order_id[free0_idx]     <= disp0_order_id;
                win_epoch[free0_idx]        <= disp0_epoch;
                win_qj[free0_idx]           <= d0_src1_tag;
                win_qk[free0_idx]           <= d0_src2_tag;
                win_qd[free0_idx]           <= d0_dst_tag;
                // Note: win_qd is for WAW tracking, NOT a readiness condition
                // Only source operand dependencies (qj, qk) determine readiness
                win_ready[free0_idx]        <= (d0_src1_tag == {RS_TAG_W{1'b0}}) &&
                                               (d0_src2_tag == {RS_TAG_W{1'b0}});
                if (disp0_regs_write && (disp0_rd != 5'd0))
                    reg_result[disp0_tid][disp0_rd] <= alloc0_tag;
                alloc_seq <= alloc_seq + 16'd1;
            end

            // ── Dispatch 1: allocate second RS entry ────────────
            if (disp1_valid && !disp_stall && free1_found) begin
                win_valid[free1_idx]        <= 1'b1;
                win_issued[free1_idx]       <= 1'b0;
                win_seq[free1_idx]          <= alloc_seq + (disp0_valid ? 16'd1 : 16'd0);
                win_tid[free1_idx]          <= disp1_tid;
                win_pc[free1_idx]           <= disp1_pc;
                win_imm[free1_idx]          <= disp1_imm;
                win_func3[free1_idx]        <= disp1_func3;
                win_func7[free1_idx]        <= disp1_func7;
                win_rd[free1_idx]           <= disp1_rd;
                win_br[free1_idx]           <= disp1_br;
                win_mem_read[free1_idx]     <= disp1_mem_read;
                win_mem2reg[free1_idx]      <= disp1_mem2reg;
                win_alu_op[free1_idx]       <= disp1_alu_op;
                win_mem_write[free1_idx]    <= disp1_mem_write;
                win_alu_src1[free1_idx]     <= disp1_alu_src1;
                win_alu_src2[free1_idx]     <= disp1_alu_src2;
                win_br_addr_mode[free1_idx] <= disp1_br_addr_mode;
                win_regs_write[free1_idx]   <= disp1_regs_write;
                win_rs1[free1_idx]          <= disp1_rs1;
                win_rs2[free1_idx]          <= disp1_rs2;
                win_rs1_used[free1_idx]     <= disp1_rs1_used;
                win_rs2_used[free1_idx]     <= disp1_rs2_used;
                win_fu[free1_idx]           <= disp1_fu;
                win_order_id[free1_idx]     <= disp1_order_id;
                win_epoch[free1_idx]        <= disp1_epoch;
                win_qj[free1_idx]           <= d1_src1_tag;
                win_qk[free1_idx]           <= d1_src2_tag;
                win_qd[free1_idx]           <= d1_dst_tag;
                // Note: win_qd is for WAW tracking, NOT a readiness condition
                // Only source operand dependencies (qj, qk) determine readiness
                win_ready[free1_idx]        <= (d1_src1_tag == {RS_TAG_W{1'b0}}) &&
                                               (d1_src2_tag == {RS_TAG_W{1'b0}});
                if (disp1_regs_write && (disp1_rd != 5'd0))
                    reg_result[disp1_tid][disp1_rd] <= alloc1_tag;
                alloc_seq <= alloc_seq + (disp0_valid ? 16'd2 : 16'd1);
            end
        end
    end
end

endmodule
