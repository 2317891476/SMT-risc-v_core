`timescale 1ns/1ns
// =============================================================================
// Module : rob
// Description: Full Reorder Buffer for in-order commit with rename support.
//   Evolved from rob_lite:
//   - Depth increased from 8 to 32 per thread
//   - Added prd_new/prd_old fields for register rename support
//   - Added is_branch, pc fields
//   - Outputs rob_idx at dispatch time (indexed WB, no CAM)
//   - Recovery walk FSM for rename map restoration on flush
//   - Backward compatible: new rename ports have defaults when not connected
//
//   Entry fields (additions over rob_lite marked with *):
//     - valid, complete, flushed, tag, order_id, epoch, rd, is_store
//     - *prd_new: newly allocated physical register
//     - *prd_old: previous physical mapping (freed at commit)
//     - *is_branch: branch instruction flag
//     - *pc: instruction PC (exception/recovery)
//     - has_result, result: writeback data
// =============================================================================
`include "define.v"

module rob #(
    parameter ROB_DEPTH     = 32,       // Entries per thread (power of 2)
    parameter ROB_IDX_W     = 5,        // log2(ROB_DEPTH)
    parameter RS_TAG_W      = 5,        // Match scoreboard tag width
    parameter PHYS_REG_W    = 6,        // Physical register address width
    parameter NUM_THREAD    = 2
)(
    input  wire                        clk,
    input  wire                        rstn,

    // ─── Flush Interface ─────────────────────────────────────────
    input  wire                        flush,
    input  wire [0:0]                  flush_tid,
    input  wire [`METADATA_EPOCH_W-1:0] flush_new_epoch,
    input  wire                        flush_order_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] flush_order_id,

    // ─── Dispatch Port 0 ─────────────────────────────────────────
    input  wire                        disp0_valid,
    input  wire [RS_TAG_W-1:0]         disp0_tag,
    input  wire [0:0]                  disp0_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]    disp0_epoch,
    input  wire [4:0]                  disp0_rd,
    input  wire                        disp0_is_store,
    input  wire                        disp0_is_mret,
    input  wire [PHYS_REG_W-1:0]       disp0_prd_new,    // New phys dest (from freelist)
    input  wire [PHYS_REG_W-1:0]       disp0_prd_old,    // Old phys mapping (to free at commit)
    input  wire                        disp0_is_branch,
    input  wire                        disp0_regs_write,  // Has register destination
    input  wire [31:0]                 disp0_pc,
    output wire                        rob0_full,
    output wire [ROB_IDX_W-1:0]        disp0_rob_idx,    // Allocated ROB index

    // ─── Dispatch Port 1 ─────────────────────────────────────────
    input  wire                        disp1_valid,
    input  wire [RS_TAG_W-1:0]         disp1_tag,
    input  wire [0:0]                  disp1_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]    disp1_epoch,
    input  wire [4:0]                  disp1_rd,
    input  wire                        disp1_is_store,
    input  wire                        disp1_is_mret,
    input  wire [PHYS_REG_W-1:0]       disp1_prd_new,
    input  wire [PHYS_REG_W-1:0]       disp1_prd_old,
    input  wire                        disp1_is_branch,
    input  wire                        disp1_regs_write,
    input  wire [31:0]                 disp1_pc,
    output wire                        rob1_full,
    output wire [ROB_IDX_W-1:0]        disp1_rob_idx,

    // ─── Writeback Port 0 ────────────────────────────────────────
    input  wire                        wb0_valid,
    input  wire [RS_TAG_W-1:0]         wb0_tag,
    input  wire [0:0]                  wb0_tid,
    input  wire [31:0]                 wb0_data,
    input  wire                        wb0_regs_write,

    // ─── Writeback Port 1 ────────────────────────────────────────
    input  wire                        wb1_valid,
    input  wire [RS_TAG_W-1:0]         wb1_tag,
    input  wire [0:0]                  wb1_tid,
    input  wire [31:0]                 wb1_data,
    input  wire                        wb1_regs_write,

    // ─── Commit Outputs ──────────────────────────────────────────
    output wire                        commit0_valid,
    output wire                        commit1_valid,
    output wire [4:0]                  commit0_rd,
    output wire [4:0]                  commit1_rd,
    output wire [1:0]                  instr_retired,

    // ─── Commit Data Outputs ─────────────────────────────────────
    output wire [RS_TAG_W-1:0]         commit0_tag,
    output wire [RS_TAG_W-1:0]         commit1_tag,
    output wire                        commit0_has_result,
    output wire                        commit1_has_result,
    output wire [31:0]                 commit0_data,
    output wire [31:0]                 commit1_data,

    // ─── Store Buffer Commit Outputs ─────────────────────────────
    output wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id,
    output wire [`METADATA_ORDER_ID_W-1:0] commit1_order_id,
    output wire [31:0]                 commit0_pc,
    output wire [31:0]                 commit1_pc,
    output wire                        commit0_is_store,
    output wire                        commit1_is_store,
    output wire                        commit0_is_mret,
    output wire                        commit1_is_mret,
    output wire                        commit0_is_branch,
    output wire                        commit1_is_branch,

    // ─── Rename Commit Outputs (for freelist release) ────────────
    output wire [PHYS_REG_W-1:0]       commit0_prd_old,
    output wire [PHYS_REG_W-1:0]       commit0_prd_new,
    output wire                        commit0_regs_write_out,
    output wire [PHYS_REG_W-1:0]       commit1_prd_old,
    output wire [PHYS_REG_W-1:0]       commit1_prd_new,
    output wire                        commit1_regs_write_out,

    // ─── Recovery Walk Interface (for rename map restore) ────────
    output wire                        recover_walk_active,
    output wire                        recover_en,
    output wire [4:0]                  recover_rd,
    output wire [PHYS_REG_W-1:0]       recover_prd_old,
    output wire [PHYS_REG_W-1:0]       recover_prd_new,  // To push back to freelist
    output wire                        recover_regs_write,
    output wire [0:0]                  recover_tid,
    output wire                        debug_commit_suppressed,

    input  wire [PHYS_REG_W-1:0]       free_query0_prd,
    input  wire [0:0]                  free_query0_tid,
    output reg                         free_query0_prd_old_live,
    input  wire [PHYS_REG_W-1:0]       free_query1_prd,
    input  wire [0:0]                  free_query1_tid,
    output reg                         free_query1_prd_old_live,

    // ROB head query for non-speculative side-effect gating
    output wire                        head_valid_t0,
    output wire [`METADATA_ORDER_ID_W-1:0] head_order_id_t0,
    output wire                        head_flushed_t0,
    output wire                        head_valid_t1,
    output wire [`METADATA_ORDER_ID_W-1:0] head_order_id_t1,
    output wire                        head_flushed_t1
);

// ═════════════════════════════════════════════════════════════════════════════
// Per-Thread ROB Storage
// ═════════════════════════════════════════════════════════════════════════════

reg                     rob_valid      [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg                     rob_complete   [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg                     rob_flushed    [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg  [RS_TAG_W-1:0]     rob_tag        [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg  [`METADATA_ORDER_ID_W-1:0] rob_order_id [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg  [`METADATA_EPOCH_W-1:0]    rob_epoch    [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg  [4:0]              rob_rd         [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg                     rob_is_store   [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg                     rob_is_mret    [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg                     rob_has_result [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg  [31:0]             rob_result     [0:NUM_THREAD-1][0:ROB_DEPTH-1];

// ─── New fields for rename support ───────────────────────────────
reg  [PHYS_REG_W-1:0]  rob_prd_new    [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg  [PHYS_REG_W-1:0]  rob_prd_old    [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg                     rob_is_branch  [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg                     rob_regs_write [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg  [31:0]             rob_pc         [0:NUM_THREAD-1][0:ROB_DEPTH-1];

integer free_q0_idx, free_q1_idx;
always @(*) begin
    free_query0_prd_old_live = 1'b0;
    if (free_query0_prd != {PHYS_REG_W{1'b0}}) begin
        for (free_q0_idx = 0; free_q0_idx < ROB_DEPTH; free_q0_idx = free_q0_idx + 1) begin
            if (rob_valid[free_query0_tid][free_q0_idx] &&
                rob_regs_write[free_query0_tid][free_q0_idx] &&
                (rob_prd_old[free_query0_tid][free_q0_idx] == free_query0_prd))
                free_query0_prd_old_live = 1'b1;
        end
    end
end

always @(*) begin
    free_query1_prd_old_live = 1'b0;
    if (free_query1_prd != {PHYS_REG_W{1'b0}}) begin
        for (free_q1_idx = 0; free_q1_idx < ROB_DEPTH; free_q1_idx = free_q1_idx + 1) begin
            if (rob_valid[free_query1_tid][free_q1_idx] &&
                rob_regs_write[free_query1_tid][free_q1_idx] &&
                (rob_prd_old[free_query1_tid][free_q1_idx] == free_query1_prd))
                free_query1_prd_old_live = 1'b1;
        end
    end
end

// ─── Head/Tail Pointers ──────────────────────────────────────────
reg  [ROB_IDX_W-1:0]    rob_head    [0:NUM_THREAD-1];
reg  [ROB_IDX_W-1:0]    rob_tail    [0:NUM_THREAD-1];
reg  [ROB_IDX_W:0]      rob_count   [0:NUM_THREAD-1];

// ─── Registered Commit Outputs ───────────────────────────────────
reg                     commit0_valid_r, commit1_valid_r;
reg  [4:0]              commit0_rd_r, commit1_rd_r;
reg  [RS_TAG_W-1:0]     commit0_tag_r, commit1_tag_r;
reg                     commit0_has_result_r, commit1_has_result_r;
reg  [31:0]             commit0_data_r, commit1_data_r;
reg  [`METADATA_ORDER_ID_W-1:0] commit0_order_id_r, commit1_order_id_r;
reg  [31:0]             commit0_pc_r, commit1_pc_r;
reg                     commit0_is_store_r, commit1_is_store_r;
reg                     commit0_is_mret_r,  commit1_is_mret_r;
reg                     commit0_is_branch_r, commit1_is_branch_r;
reg  [PHYS_REG_W-1:0]  commit0_prd_old_r, commit1_prd_old_r;
reg  [PHYS_REG_W-1:0]  commit0_prd_new_r, commit1_prd_new_r;
reg                     commit0_regs_write_r, commit1_regs_write_r;

// ─── Recovery Walk State Machine ─────────────────────────────────
reg                     recovering_r;
reg  [0:0]              recover_tid_r;
reg  [ROB_IDX_W-1:0]   recover_ptr_r;     // Current walk pointer
reg  [ROB_IDX_W-1:0]   recover_stop_r;    // Walk endpoint (exclusive)
reg                     recover_en_r;
reg  [4:0]              recover_rd_r;
reg  [PHYS_REG_W-1:0]  recover_prd_old_r;
reg  [PHYS_REG_W-1:0]  recover_prd_new_r;
reg                     recover_regs_write_r;
reg                     debug_commit_suppressed_r;

// ═════════════════════════════════════════════════════════════════════════════
// ROB Full Check
// ═════════════════════════════════════════════════════════════════════════════

wire rob_full_t0 = (rob_count[0] >= ROB_DEPTH - 2);
wire rob_full_t1 = (rob_count[1] >= ROB_DEPTH - 2);

assign rob0_full = (disp0_tid ? rob_full_t1 : rob_full_t0) || recovering_r;
assign rob1_full = (disp1_tid ? rob_full_t1 : rob_full_t0) || recovering_r;

// ═════════════════════════════════════════════════════════════════════════════
// Dispatch Allocation — ROB Index Output
// ═════════════════════════════════════════════════════════════════════════════

// disp0 gets current tail of its thread
wire [ROB_IDX_W-1:0] d0_tail = (disp0_tid == 1'b0) ? rob_tail[0] : rob_tail[1];
// disp1 gets next slot (if same thread as disp0 and disp0 is valid, +1)
wire d1_same_thread = (disp0_tid == disp1_tid);
wire [ROB_IDX_W-1:0] d1_tail = (disp1_tid == 1'b0) ? rob_tail[0] : rob_tail[1];
assign disp0_rob_idx = d0_tail;
assign disp1_rob_idx = d1_tail + ((disp0_valid && d1_same_thread) ? {{(ROB_IDX_W-1){1'b0}}, 1'b1} : {ROB_IDX_W{1'b0}});

// ═════════════════════════════════════════════════════════════════════════════
// Single-Cycle Commit: WB Bypass + Flush-Blocks-Head
// ═════════════════════════════════════════════════════════════════════════════
// Same-cycle WB bypass: if WB completes the head entry THIS cycle, treat
// it as complete for commit without waiting a cycle.
wire wb0_completes_head_t0 = wb0_valid && (wb0_tid == 1'b0) &&
    rob_valid[0][rob_head[0]] && !rob_complete[0][rob_head[0]] &&
    (rob_tag[0][rob_head[0]] == wb0_tag);
wire wb1_completes_head_t0 = wb1_valid && (wb1_tid == 1'b0) &&
    rob_valid[0][rob_head[0]] && !rob_complete[0][rob_head[0]] &&
    (rob_tag[0][rob_head[0]] == wb1_tag);
wire head_complete_now_t0 = rob_complete[0][rob_head[0]] ||
    wb0_completes_head_t0 || wb1_completes_head_t0;
wire head_has_result_t0 = rob_has_result[0][rob_head[0]] ||
    (wb0_completes_head_t0 && wb0_regs_write && (rob_rd[0][rob_head[0]] != 5'd0)) ||
    (wb1_completes_head_t0 && wb1_regs_write && (rob_rd[0][rob_head[0]] != 5'd0));
wire [31:0] head_result_t0 = rob_has_result[0][rob_head[0]] ? rob_result[0][rob_head[0]] :
    wb0_completes_head_t0 ? wb0_data :
    wb1_completes_head_t0 ? wb1_data : 32'd0;

wire wb0_completes_head_t1 = wb0_valid && (wb0_tid == 1'b1) &&
    rob_valid[1][rob_head[1]] && !rob_complete[1][rob_head[1]] &&
    (rob_tag[1][rob_head[1]] == wb0_tag);
wire wb1_completes_head_t1 = wb1_valid && (wb1_tid == 1'b1) &&
    rob_valid[1][rob_head[1]] && !rob_complete[1][rob_head[1]] &&
    (rob_tag[1][rob_head[1]] == wb1_tag);
wire head_complete_now_t1 = rob_complete[1][rob_head[1]] ||
    wb0_completes_head_t1 || wb1_completes_head_t1;
wire head_has_result_t1 = rob_has_result[1][rob_head[1]] ||
    (wb0_completes_head_t1 && wb0_regs_write && (rob_rd[1][rob_head[1]] != 5'd0)) ||
    (wb1_completes_head_t1 && wb1_regs_write && (rob_rd[1][rob_head[1]] != 5'd0));
wire [31:0] head_result_t1 = rob_has_result[1][rob_head[1]] ? rob_result[1][rob_head[1]] :
    wb0_completes_head_t1 ? wb0_data :
    wb1_completes_head_t1 ? wb1_data : 32'd0;

wire commit_flush_blocks_t0 =
    flush && (flush_tid == 1'b0) && rob_valid[0][rob_head[0]] &&
    (!flush_order_valid || (rob_order_id[0][rob_head[0]] > flush_order_id));
wire commit_flush_blocks_t1 =
    flush && (flush_tid == 1'b1) && rob_valid[1][rob_head[1]] &&
    (!flush_order_valid || (rob_order_id[1][rob_head[1]] > flush_order_id));

// ═════════════════════════════════════════════════════════════════════════════
// Commit Output Wiring
// ═════════════════════════════════════════════════════════════════════════════

assign commit0_valid      = commit0_valid_r;
assign commit1_valid      = commit1_valid_r;
assign commit0_rd         = commit0_rd_r;
assign commit1_rd         = commit1_rd_r;
assign commit0_tag        = commit0_tag_r;
assign commit1_tag        = commit1_tag_r;
assign commit0_has_result = commit0_has_result_r;
assign commit1_has_result = commit1_has_result_r;
assign commit0_data       = commit0_data_r;
assign commit1_data       = commit1_data_r;
assign instr_retired      = {commit1_valid_r, commit0_valid_r};
assign commit0_order_id   = commit0_order_id_r;
assign commit1_order_id   = commit1_order_id_r;
assign commit0_pc         = commit0_pc_r;
assign commit1_pc         = commit1_pc_r;
assign commit0_is_store   = commit0_is_store_r;
assign commit1_is_store   = commit1_is_store_r;
assign commit0_is_mret    = commit0_is_mret_r;
assign commit1_is_mret    = commit1_is_mret_r;
assign commit0_is_branch  = commit0_is_branch_r;
assign commit1_is_branch  = commit1_is_branch_r;
assign commit0_prd_old    = commit0_prd_old_r;
assign commit0_prd_new    = commit0_prd_new_r;
assign commit0_regs_write_out = commit0_regs_write_r;
assign commit1_prd_old    = commit1_prd_old_r;
assign commit1_prd_new    = commit1_prd_new_r;
assign commit1_regs_write_out = commit1_regs_write_r;

// Recovery outputs
assign recover_walk_active = recovering_r;
assign recover_en          = recover_en_r;
assign recover_rd          = recover_rd_r;
assign recover_prd_old     = recover_prd_old_r;
assign recover_prd_new     = recover_prd_new_r;
assign recover_regs_write  = recover_regs_write_r;
assign recover_tid         = recover_tid_r;
assign debug_commit_suppressed = debug_commit_suppressed_r;
assign head_valid_t0       = rob_valid[0][rob_head[0]];
assign head_order_id_t0    = rob_order_id[0][rob_head[0]];
assign head_flushed_t0     = rob_flushed[0][rob_head[0]];
assign head_valid_t1       = rob_valid[1][rob_head[1]];
assign head_order_id_t1    = rob_order_id[1][rob_head[1]];
assign head_flushed_t1     = rob_flushed[1][rob_head[1]];

// ═════════════════════════════════════════════════════════════════════════════
// Sequential Logic
// ═════════════════════════════════════════════════════════════════════════════

`ifdef VERBOSE_SIM_LOGS
always @(posedge clk) begin
    if (disp0_valid && disp0_tid == 0)
        $display("[MON DISP0] rd=%0d tag=%0d pc=%h @%0t", disp0_rd, disp0_tag, disp0_pc, $time);
end
`endif

integer t, j;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        commit0_valid_r    <= 1'b0;
        commit1_valid_r    <= 1'b0;
        commit0_rd_r       <= 5'd0;
        commit1_rd_r       <= 5'd0;
        commit0_tag_r      <= {RS_TAG_W{1'b0}};
        commit1_tag_r      <= {RS_TAG_W{1'b0}};
        commit0_has_result_r <= 1'b0;
        commit1_has_result_r <= 1'b0;
        commit0_data_r     <= 32'd0;
        commit1_data_r     <= 32'd0;
        commit0_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        commit1_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        commit0_pc_r       <= 32'd0;
        commit1_pc_r       <= 32'd0;
        commit0_is_store_r <= 1'b0;
        commit1_is_store_r <= 1'b0;
        commit0_is_mret_r  <= 1'b0;
        commit1_is_mret_r  <= 1'b0;
        commit0_is_branch_r <= 1'b0;
        commit1_is_branch_r <= 1'b0;
        commit0_prd_old_r  <= {PHYS_REG_W{1'b0}};
        commit1_prd_old_r  <= {PHYS_REG_W{1'b0}};
        commit0_prd_new_r  <= {PHYS_REG_W{1'b0}};
        commit1_prd_new_r  <= {PHYS_REG_W{1'b0}};
        commit0_regs_write_r <= 1'b0;
        commit1_regs_write_r <= 1'b0;

        recovering_r       <= 1'b0;
        recover_tid_r      <= 1'b0;
        recover_ptr_r      <= {ROB_IDX_W{1'b0}};
        recover_stop_r     <= {ROB_IDX_W{1'b0}};
        recover_en_r       <= 1'b0;
        recover_rd_r       <= 5'd0;
        recover_prd_old_r  <= {PHYS_REG_W{1'b0}};
        recover_prd_new_r  <= {PHYS_REG_W{1'b0}};
        recover_regs_write_r <= 1'b0;
        debug_commit_suppressed_r <= 1'b0;

        for (t = 0; t < NUM_THREAD; t = t + 1) begin
            rob_head[t]  <= {ROB_IDX_W{1'b0}};
            rob_tail[t]  <= {ROB_IDX_W{1'b0}};
            rob_count[t] <= {(ROB_IDX_W+1){1'b0}};
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                rob_valid[t][j]      <= 1'b0;
                rob_complete[t][j]   <= 1'b0;
                rob_flushed[t][j]    <= 1'b0;
                rob_tag[t][j]        <= {RS_TAG_W{1'b0}};
                rob_order_id[t][j]   <= {`METADATA_ORDER_ID_W{1'b0}};
                rob_epoch[t][j]      <= {`METADATA_EPOCH_W{1'b0}};
                rob_rd[t][j]         <= 5'd0;
                rob_is_store[t][j]   <= 1'b0;
                rob_is_mret[t][j]    <= 1'b0;
                rob_has_result[t][j] <= 1'b0;
                rob_result[t][j]     <= 32'd0;
                rob_prd_new[t][j]    <= {PHYS_REG_W{1'b0}};
                rob_prd_old[t][j]    <= {PHYS_REG_W{1'b0}};
                rob_is_branch[t][j]  <= 1'b0;
                rob_regs_write[t][j] <= 1'b0;
                rob_pc[t][j]         <= 32'd0;
            end
        end
    end else begin
        commit0_valid_r <= 1'b0;
        commit1_valid_r <= 1'b0;
        commit0_is_mret_r <= 1'b0;
        commit1_is_mret_r <= 1'b0;
        commit0_is_branch_r <= 1'b0;
        commit1_is_branch_r <= 1'b0;
        recover_en_r    <= 1'b0;
        debug_commit_suppressed_r <= 1'b0;
        if ((commit_flush_blocks_t0 && head_complete_now_t0) ||
            (commit_flush_blocks_t1 && head_complete_now_t1)) begin
            debug_commit_suppressed_r <= 1'b1;
        end

        // ── Recovery Walk ──────────────────────────────────────
        // Walk from tail-1 backward, restoring one rename
        // mapping per cycle for each flushed entry and freeing
        // prd_new.  Stops at the first non-flushed (or invalid)
        // entry and resets the tail pointer accordingly.
        // During recovery, no dispatch or commit occurs.
        // A new flush CAN arrive mid-recovery (e.g. trap_enter
        // after MRET).  In that case additional entries are
        // marked flushed below, and the walk holds position for
        // one cycle so it sees the newly-flushed entries next.
        if (recovering_r) begin
            if (rob_valid[recover_tid_r][recover_ptr_r] &&
                rob_flushed[recover_tid_r][recover_ptr_r]) begin
                // Output current (flushed) entry's recovery info
                recover_en_r         <= rob_regs_write[recover_tid_r][recover_ptr_r] && (rob_rd[recover_tid_r][recover_ptr_r] != 5'd0);
                recover_rd_r         <= rob_rd[recover_tid_r][recover_ptr_r];
                recover_prd_old_r    <= rob_prd_old[recover_tid_r][recover_ptr_r];
                recover_prd_new_r    <= rob_prd_new[recover_tid_r][recover_ptr_r];
                recover_regs_write_r <= rob_regs_write[recover_tid_r][recover_ptr_r];

                // Invalidate entry
                rob_valid[recover_tid_r][recover_ptr_r]   <= 1'b0;
                rob_flushed[recover_tid_r][recover_ptr_r] <= 1'b0;
                rob_count[recover_tid_r] <= rob_count[recover_tid_r] - 1;

                // Walk backward (toward head)
                recover_ptr_r <= recover_ptr_r - 1;
            end else if (flush && (flush_tid == recover_tid_r)) begin
                // New flush arrived this cycle — entries just marked
                // flushed via NB assign below.  Hold position so the
                // walk re-checks this entry next cycle.
                `ifdef VERBOSE_SIM_LOGS
                $display("[ROB FLUSH-EXTEND] walk held at ptr=%0d, new flush_order_valid=%0b @%0t",
                         recover_ptr_r, flush_order_valid, $time);
                `endif
            end else begin
                // Walk complete — hit non-flushed or invalid entry
                recovering_r <= 1'b0;
                rob_tail[recover_tid_r] <= recover_ptr_r + 1;
            end
        end

        // ── Flush Handling ─────────────────────────────────────
        // Allowed both when idle and during an active recovery
        // walk.  During recovery the mark-flushed loop still
        // runs so that a trap_enter following an MRET flush can
        // mark older, previously-preserved entries.  Only the
        // recovery-start is gated on !recovering_r.
        if (flush) begin
            // Mark entries for flushed thread
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                if (rob_valid[flush_tid][j] &&
                    (!flush_order_valid ||
                     (rob_order_id[flush_tid][j] > flush_order_id) ||
                     (!rob_is_mret[flush_tid][j] &&
                      !rob_complete[flush_tid][j] &&
                      (rob_order_id[flush_tid][j] == flush_order_id)))) begin
                    rob_flushed[flush_tid][j] <= 1'b1;
                    `ifdef VERBOSE_SIM_LOGS
                    $display("[ROB FLUSH] tid=%0d entry_order=%0d flush_order_valid=%0b flush_order=%0d @%0t",
                             flush_tid, rob_order_id[flush_tid][j], flush_order_valid, flush_order_id, $time);
                    `endif
                end
            end
            // Start recovery walk from tail-1 backward (only if
            // not already recovering — the running walk will pick
            // up the newly-flushed entries automatically).
            if (!recovering_r && rob_count[flush_tid] > 0) begin
                recovering_r  <= 1'b1;
                recover_tid_r <= flush_tid;
                recover_ptr_r <= rob_tail[flush_tid] - 1;
            end
        end

        // ── WB Completion ──────────────────────────────────────
        if (wb0_valid) begin
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                if (wb0_tid == 1'b0 && rob_valid[0][j] && !rob_complete[0][j] && (rob_tag[0][j] == wb0_tag)) begin
                    rob_complete[0][j] <= 1'b1;
                    rob_has_result[0][j] <= wb0_regs_write && (rob_rd[0][j] != 5'd0);
                    if (wb0_regs_write)
                        rob_result[0][j] <= wb0_data;
                end
                if (wb0_tid == 1'b1 && rob_valid[1][j] && !rob_complete[1][j] && (rob_tag[1][j] == wb0_tag)) begin
                    rob_complete[1][j] <= 1'b1;
                    rob_has_result[1][j] <= wb0_regs_write && (rob_rd[1][j] != 5'd0);
                    if (wb0_regs_write)
                        rob_result[1][j] <= wb0_data;
                end
            end
        end

        if (wb1_valid) begin
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                if (wb1_tid == 1'b0 && rob_valid[0][j] && !rob_complete[0][j] && (rob_tag[0][j] == wb1_tag)) begin
                    rob_complete[0][j] <= 1'b1;
                    rob_has_result[0][j] <= wb1_regs_write && (rob_rd[0][j] != 5'd0);
                    if (wb1_regs_write)
                        rob_result[0][j] <= wb1_data;
                end
                if (wb1_tid == 1'b1 && rob_valid[1][j] && !rob_complete[1][j] && (rob_tag[1][j] == wb1_tag)) begin
                    rob_complete[1][j] <= 1'b1;
                    rob_has_result[1][j] <= wb1_regs_write && (rob_rd[1][j] != 5'd0);
                    if (wb1_regs_write)
                        rob_result[1][j] <= wb1_data;
                end
            end
        end

        // ── Single-Cycle Commit + Dispatch: Thread 0 ───────────
        if (!recovering_r) begin : t0_next_state
            reg [ROB_IDX_W-1:0] next_head;
            reg [ROB_IDX_W-1:0] next_tail;
            reg [ROB_IDX_W:0]   next_count;

            next_head  = rob_head[0];
            next_tail  = rob_tail[0];
            next_count = rob_count[0];

            // ── Commit ──
            if (next_count != {(ROB_IDX_W+1){1'b0}} && !commit_flush_blocks_t0) begin
                if (!rob_valid[0][rob_head[0]]) begin
                    // Skip invalid entry
                    next_head = rob_head[0] + 1;
                    next_count = next_count - 1;
                end else if (rob_flushed[0][rob_head[0]]) begin
                    // Skip flushed entry
                    rob_valid[0][rob_head[0]]      <= 1'b0;
                    rob_has_result[0][rob_head[0]] <= 1'b0;
                    rob_result[0][rob_head[0]]     <= 32'd0;
                    next_head = rob_head[0] + 1;
                    next_count = next_count - 1;
                end else if (head_complete_now_t0) begin
                    // Commit head entry
                    commit0_valid_r      <= 1'b1;
                    commit0_rd_r         <= rob_rd[0][rob_head[0]];
                    commit0_tag_r        <= rob_tag[0][rob_head[0]];
                    commit0_has_result_r <= head_has_result_t0;
                    commit0_data_r       <= head_result_t0;
                    commit0_order_id_r   <= rob_order_id[0][rob_head[0]];
                    commit0_pc_r         <= rob_pc[0][rob_head[0]];
                    commit0_is_store_r   <= rob_is_store[0][rob_head[0]];
                    commit0_is_mret_r    <= rob_is_mret[0][rob_head[0]];
                    commit0_is_branch_r  <= rob_is_branch[0][rob_head[0]];
                    commit0_prd_old_r    <= rob_prd_old[0][rob_head[0]];
                    commit0_prd_new_r    <= rob_prd_new[0][rob_head[0]];
                    commit0_regs_write_r <= rob_regs_write[0][rob_head[0]];
                    rob_valid[0][rob_head[0]]      <= 1'b0;
                    rob_has_result[0][rob_head[0]] <= 1'b0;
                    rob_result[0][rob_head[0]]     <= 32'd0;
                    next_head = rob_head[0] + 1;
                    next_count = next_count - 1;
                end
            end

            // ── Dispatch Allocation ──
            if (!flush && disp0_valid && !rob0_full && (disp0_tid == 1'b0)) begin
                `ifdef VERBOSE_SIM_LOGS
                $display("[ROB DISP0] t0 tail=%0d tag=%0d rd=%0d pc=%h @%0t",
                         next_tail, disp0_tag, disp0_rd, disp0_pc, $time);
                `endif
                rob_valid[0][next_tail]      <= 1'b1;
                rob_complete[0][next_tail]   <= 1'b0;
                rob_flushed[0][next_tail]    <= 1'b0;
                rob_tag[0][next_tail]        <= disp0_tag;
                rob_order_id[0][next_tail]   <= disp0_order_id;
                rob_epoch[0][next_tail]      <= disp0_epoch;
                rob_rd[0][next_tail]         <= disp0_rd;
                rob_is_store[0][next_tail]   <= disp0_is_store;
                rob_is_mret[0][next_tail]    <= disp0_is_mret;
                rob_has_result[0][next_tail] <= 1'b0;
                rob_result[0][next_tail]     <= 32'd0;
                rob_prd_new[0][next_tail]    <= disp0_prd_new;
                rob_prd_old[0][next_tail]    <= disp0_prd_old;
                rob_is_branch[0][next_tail]  <= disp0_is_branch;
                rob_regs_write[0][next_tail] <= disp0_regs_write;
                rob_pc[0][next_tail]         <= disp0_pc;
                next_tail = next_tail + 1;
                next_count = next_count + 1;
            end

            if (!flush && disp1_valid && !rob1_full && (disp1_tid == 1'b0)) begin
                rob_valid[0][next_tail]      <= 1'b1;
                rob_complete[0][next_tail]   <= 1'b0;
                rob_flushed[0][next_tail]    <= 1'b0;
                rob_tag[0][next_tail]        <= disp1_tag;
                rob_order_id[0][next_tail]   <= disp1_order_id;
                rob_epoch[0][next_tail]      <= disp1_epoch;
                rob_rd[0][next_tail]         <= disp1_rd;
                rob_is_store[0][next_tail]   <= disp1_is_store;
                rob_is_mret[0][next_tail]    <= disp1_is_mret;
                rob_has_result[0][next_tail] <= 1'b0;
                rob_result[0][next_tail]     <= 32'd0;
                rob_prd_new[0][next_tail]    <= disp1_prd_new;
                rob_prd_old[0][next_tail]    <= disp1_prd_old;
                rob_is_branch[0][next_tail]  <= disp1_is_branch;
                rob_regs_write[0][next_tail] <= disp1_regs_write;
                rob_pc[0][next_tail]         <= disp1_pc;
                next_tail = next_tail + 1;
                next_count = next_count + 1;
            end

            rob_head[0]  <= next_head;
            rob_tail[0]  <= next_tail;
            rob_count[0] <= next_count;
        end

        // ── Single-Cycle Commit + Dispatch: Thread 1 ───────────
        if (!recovering_r) begin : t1_next_state
            reg [ROB_IDX_W-1:0] next_head;
            reg [ROB_IDX_W-1:0] next_tail;
            reg [ROB_IDX_W:0]   next_count;

            next_head  = rob_head[1];
            next_tail  = rob_tail[1];
            next_count = rob_count[1];

            // ── Commit ──
            if (next_count != {(ROB_IDX_W+1){1'b0}} && !commit_flush_blocks_t1) begin
                if (!rob_valid[1][rob_head[1]]) begin
                    next_head = rob_head[1] + 1;
                    next_count = next_count - 1;
                end else if (rob_flushed[1][rob_head[1]]) begin
                    rob_valid[1][rob_head[1]]      <= 1'b0;
                    rob_has_result[1][rob_head[1]] <= 1'b0;
                    rob_result[1][rob_head[1]]     <= 32'd0;
                    next_head = rob_head[1] + 1;
                    next_count = next_count - 1;
                end else if (head_complete_now_t1) begin
                    commit1_valid_r      <= 1'b1;
                    commit1_rd_r         <= rob_rd[1][rob_head[1]];
                    commit1_tag_r        <= rob_tag[1][rob_head[1]];
                    commit1_has_result_r <= head_has_result_t1;
                    commit1_data_r       <= head_result_t1;
                    commit1_order_id_r   <= rob_order_id[1][rob_head[1]];
                    commit1_pc_r         <= rob_pc[1][rob_head[1]];
                    commit1_is_store_r   <= rob_is_store[1][rob_head[1]];
                    commit1_is_mret_r    <= rob_is_mret[1][rob_head[1]];
                    commit1_is_branch_r  <= rob_is_branch[1][rob_head[1]];
                    commit1_prd_old_r    <= rob_prd_old[1][rob_head[1]];
                    commit1_prd_new_r    <= rob_prd_new[1][rob_head[1]];
                    commit1_regs_write_r <= rob_regs_write[1][rob_head[1]];
                    rob_valid[1][rob_head[1]]      <= 1'b0;
                    rob_has_result[1][rob_head[1]] <= 1'b0;
                    rob_result[1][rob_head[1]]     <= 32'd0;
                    next_head = rob_head[1] + 1;
                    next_count = next_count - 1;
                end
            end

            // ── Dispatch Allocation ──
            if (!flush && disp0_valid && !rob0_full && (disp0_tid == 1'b1)) begin
                rob_valid[1][next_tail]      <= 1'b1;
                rob_complete[1][next_tail]   <= 1'b0;
                rob_flushed[1][next_tail]    <= 1'b0;
                rob_tag[1][next_tail]        <= disp0_tag;
                rob_order_id[1][next_tail]   <= disp0_order_id;
                rob_epoch[1][next_tail]      <= disp0_epoch;
                rob_rd[1][next_tail]         <= disp0_rd;
                rob_is_store[1][next_tail]   <= disp0_is_store;
                rob_is_mret[1][next_tail]    <= disp0_is_mret;
                rob_has_result[1][next_tail] <= 1'b0;
                rob_result[1][next_tail]     <= 32'd0;
                rob_prd_new[1][next_tail]    <= disp0_prd_new;
                rob_prd_old[1][next_tail]    <= disp0_prd_old;
                rob_is_branch[1][next_tail]  <= disp0_is_branch;
                rob_regs_write[1][next_tail] <= disp0_regs_write;
                rob_pc[1][next_tail]         <= disp0_pc;
                next_tail = next_tail + 1;
                next_count = next_count + 1;
            end

            if (!flush && disp1_valid && !rob1_full && (disp1_tid == 1'b1)) begin
                rob_valid[1][next_tail]      <= 1'b1;
                rob_complete[1][next_tail]   <= 1'b0;
                rob_flushed[1][next_tail]    <= 1'b0;
                rob_tag[1][next_tail]        <= disp1_tag;
                rob_order_id[1][next_tail]   <= disp1_order_id;
                rob_epoch[1][next_tail]      <= disp1_epoch;
                rob_rd[1][next_tail]         <= disp1_rd;
                rob_is_store[1][next_tail]   <= disp1_is_store;
                rob_is_mret[1][next_tail]    <= disp1_is_mret;
                rob_has_result[1][next_tail] <= 1'b0;
                rob_result[1][next_tail]     <= 32'd0;
                rob_prd_new[1][next_tail]    <= disp1_prd_new;
                rob_prd_old[1][next_tail]    <= disp1_prd_old;
                rob_is_branch[1][next_tail]  <= disp1_is_branch;
                rob_regs_write[1][next_tail] <= disp1_regs_write;
                rob_pc[1][next_tail]         <= disp1_pc;
                next_tail = next_tail + 1;
                next_count = next_count + 1;
            end

            rob_head[1]  <= next_head;
            rob_tail[1]  <= next_tail;
            rob_count[1] <= next_count;
        end
    end
end

endmodule
