// =============================================================================
// Module : scoreboard_v2
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

module scoreboard_v2 #(
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
    input  wire [0:0]              wb1_tid
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
reg  [31:0]             win_pc          [0:RS_DEPTH-1];
reg  [31:0]             win_imm         [0:RS_DEPTH-1];
reg  [2:0]              win_func3       [0:RS_DEPTH-1];
reg                     win_func7       [0:RS_DEPTH-1];
reg  [4:0]              win_rd          [0:RS_DEPTH-1];
reg                     win_br          [0:RS_DEPTH-1];
reg                     win_mem_read    [0:RS_DEPTH-1];
reg                     win_mem2reg     [0:RS_DEPTH-1];
reg  [2:0]              win_alu_op      [0:RS_DEPTH-1];
reg                     win_mem_write   [0:RS_DEPTH-1];
reg  [1:0]              win_alu_src1    [0:RS_DEPTH-1];
reg  [1:0]              win_alu_src2    [0:RS_DEPTH-1];
reg                     win_br_addr_mode[0:RS_DEPTH-1];
reg                     win_regs_write  [0:RS_DEPTH-1];
reg  [4:0]              win_rs1         [0:RS_DEPTH-1];
reg  [4:0]              win_rs2         [0:RS_DEPTH-1];
reg                     win_rs1_used    [0:RS_DEPTH-1];
reg                     win_rs2_used    [0:RS_DEPTH-1];
reg  [2:0]              win_fu          [0:RS_DEPTH-1];

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

// Stall: cannot accept 2 dispatches without 2 free slots
// (or 1 dispatch without 1 free slot)
wire can_accept_1, can_accept_2;
assign can_accept_1 = free0_found;
assign can_accept_2 = free0_found && free1_found;
assign disp_stall   = (disp0_valid && disp1_valid && !can_accept_2) ||
                      (disp0_valid && !disp1_valid && !can_accept_1) ||
                      (!disp0_valid && disp1_valid && !can_accept_1);

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
reg                     war_block_0, war_block_1;

always @(*) begin
    sel0_found  = 1'b0;
    sel1_found  = 1'b0;
    sel0_idx    = {RS_IDX_W{1'b0}};
    sel1_idx    = {RS_IDX_W{1'b0}};
    sel0_seq    = 16'hffff;
    sel1_seq    = 16'hffff;

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
    for (i = 0; i < RS_DEPTH; i = i + 1) begin
        if (win_valid[i] && !win_issued[i] && win_ready[i] &&
            (win_fu[i] != 3'd0) && !fu_busy[win_fu[i]]) begin

            // WAR check (same as original)
            war_block_0 = 1'b0;
            if (win_regs_write[i] && (win_rd[i] != 5'd0)) begin
                for (j = 0; j < RS_DEPTH; j = j + 1) begin
                    if (!war_block_0 && win_valid[j] && !win_issued[j] &&
                        (win_tid[j] == win_tid[i]) &&
                        (win_seq[j] < win_seq[i]) &&
                        ((win_rs1_used[j] && (win_rs1[j] == win_rd[i])) ||
                         (win_rs2_used[j] && (win_rs2[j] == win_rd[i])))) begin
                        war_block_0 = 1'b1;
                    end
                end
            end

            if (!war_block_0 && (!sel0_found || (win_seq[i] < sel0_seq))) begin
                sel0_found = 1'b1;
                sel0_idx   = i[RS_IDX_W-1:0];
                sel0_seq   = win_seq[i];
            end
        end
    end

    // ── Pass 2: select second instruction for Port 1 ───────────
    // Must be different entry, different FU from sel0
    for (i = 0; i < RS_DEPTH; i = i + 1) begin
        if (win_valid[i] && !win_issued[i] && win_ready[i] &&
            (win_fu[i] != 3'd0) && !fu_busy[win_fu[i]] &&
            !(sel0_found && (i[RS_IDX_W-1:0] == sel0_idx)) &&                 // not same entry
            !(sel0_found && (win_fu[i] == win_fu[sel0_idx])) &&              // not same FU
            !(sel0_found && win_br[sel0_idx] && win_br[i]) &&                // at most 1 branch
            !(sel0_found && (win_mem_read[sel0_idx]||win_mem_write[sel0_idx])  // at most 1 mem
                         && (win_mem_read[i]||win_mem_write[i]))) begin

            war_block_1 = 1'b0;
            if (win_regs_write[i] && (win_rd[i] != 5'd0)) begin
                for (j = 0; j < RS_DEPTH; j = j + 1) begin
                    if (!war_block_1 && win_valid[j] && !win_issued[j] &&
                        (win_tid[j] == win_tid[i]) &&
                        (win_seq[j] < win_seq[i]) &&
                        ((win_rs1_used[j] && (win_rs1[j] == win_rd[i])) ||
                         (win_rs2_used[j] && (win_rs2[j] == win_rd[i])))) begin
                        war_block_1 = 1'b1;
                    end
                end
            end

            if (!war_block_1 && (!sel1_found || (win_seq[i] < sel1_seq))) begin
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
    end
end

// ═══════════════ Sequential Logic ══════════════════════════════════════════
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        alloc_seq <= 16'd0;
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
        end
    end
    else begin
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
                win_ready[i] <= (nqj == {RS_TAG_W{1'b0}}) &&
                                (nqk == {RS_TAG_W{1'b0}}) &&
                                (nqd == {RS_TAG_W{1'b0}});
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
            if (sel0_found) begin
                win_issued[sel0_idx] <= 1'b1;
                win_ready[sel0_idx]  <= 1'b0;
                if (win_fu[sel0_idx] != 3'd0)
                    fu_busy[win_fu[sel0_idx]] <= 1'b1;
            end
            if (sel1_found) begin
                win_issued[sel1_idx] <= 1'b1;
                win_ready[sel1_idx]  <= 1'b0;
                if (win_fu[sel1_idx] != 3'd0)
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
                win_qj[free0_idx]           <= d0_src1_tag;
                win_qk[free0_idx]           <= d0_src2_tag;
                win_qd[free0_idx]           <= d0_dst_tag;
                win_ready[free0_idx]        <= (d0_src1_tag == {RS_TAG_W{1'b0}}) &&
                                               (d0_src2_tag == {RS_TAG_W{1'b0}}) &&
                                               (d0_dst_tag  == {RS_TAG_W{1'b0}});
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
                win_qj[free1_idx]           <= d1_src1_tag;
                win_qk[free1_idx]           <= d1_src2_tag;
                win_qd[free1_idx]           <= d1_dst_tag;
                win_ready[free1_idx]        <= (d1_src1_tag == {RS_TAG_W{1'b0}}) &&
                                               (d1_src2_tag == {RS_TAG_W{1'b0}}) &&
                                               (d1_dst_tag  == {RS_TAG_W{1'b0}});
                if (disp1_regs_write && (disp1_rd != 5'd0))
                    reg_result[disp1_tid][disp1_rd] <= alloc1_tag;
                alloc_seq <= alloc_seq + (disp0_valid ? 16'd2 : 16'd1);
            end
        end
    end
end

endmodule
