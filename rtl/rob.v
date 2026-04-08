`timescale 1ns/1ns
// =============================================================================
// Module : rob
// Description: Full Reorder Buffer for in-order commit with rename support.
//   Evolved from rob_lite:
//   - Depth increased from 8 to 16 per thread
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
    parameter ROB_DEPTH     = 16,       // Entries per thread (power of 2)
    parameter ROB_IDX_W     = 4,        // log2(ROB_DEPTH)
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
    output wire                        commit0_is_store,
    output wire                        commit1_is_store,

    // ─── Rename Commit Outputs (for freelist release) ────────────
    output wire [PHYS_REG_W-1:0]       commit0_prd_old,
    output wire                        commit0_regs_write_out,
    output wire [PHYS_REG_W-1:0]       commit1_prd_old,
    output wire                        commit1_regs_write_out,

    // ─── Recovery Walk Interface (for rename map restore) ────────
    output wire                        recover_walk_active,
    output wire                        recover_en,
    output wire [4:0]                  recover_rd,
    output wire [PHYS_REG_W-1:0]       recover_prd_old,
    output wire [PHYS_REG_W-1:0]       recover_prd_new,  // To push back to freelist
    output wire                        recover_regs_write,
    output wire [0:0]                  recover_tid
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
reg                     rob_has_result [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg  [31:0]             rob_result     [0:NUM_THREAD-1][0:ROB_DEPTH-1];

// ─── New fields for rename support ───────────────────────────────
reg  [PHYS_REG_W-1:0]  rob_prd_new    [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg  [PHYS_REG_W-1:0]  rob_prd_old    [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg                     rob_is_branch  [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg                     rob_regs_write [0:NUM_THREAD-1][0:ROB_DEPTH-1];
reg  [31:0]             rob_pc         [0:NUM_THREAD-1][0:ROB_DEPTH-1];

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
reg                     commit0_is_store_r, commit1_is_store_r;
reg  [PHYS_REG_W-1:0]  commit0_prd_old_r, commit1_prd_old_r;
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
assign commit0_is_store   = commit0_is_store_r;
assign commit1_is_store   = commit1_is_store_r;
assign commit0_prd_old    = commit0_prd_old_r;
assign commit0_regs_write_out = commit0_regs_write_r;
assign commit1_prd_old    = commit1_prd_old_r;
assign commit1_regs_write_out = commit1_regs_write_r;

// Recovery outputs
assign recover_walk_active = recovering_r;
assign recover_en          = recover_en_r;
assign recover_rd          = recover_rd_r;
assign recover_prd_old     = recover_prd_old_r;
assign recover_prd_new     = recover_prd_new_r;
assign recover_regs_write  = recover_regs_write_r;
assign recover_tid         = recover_tid_r;

// ═════════════════════════════════════════════════════════════════════════════
// Sequential Logic
// ═════════════════════════════════════════════════════════════════════════════

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
        commit0_is_store_r <= 1'b0;
        commit1_is_store_r <= 1'b0;
        commit0_prd_old_r  <= {PHYS_REG_W{1'b0}};
        commit1_prd_old_r  <= {PHYS_REG_W{1'b0}};
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
        recover_en_r    <= 1'b0;

        // ── Recovery Walk ──────────────────────────────────────
        // Walk from tail-1 backward, restoring one rename
        // mapping per cycle for each flushed entry and freeing
        // prd_new.  Stops at the first non-flushed (or invalid)
        // entry and resets the tail pointer accordingly.
        // During recovery, no dispatch or commit occurs.
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
            end else begin
                // Walk complete — hit non-flushed or invalid entry
                recovering_r <= 1'b0;
                rob_tail[recover_tid_r] <= recover_ptr_r + 1;
            end
        end

        // ── Flush Handling ─────────────────────────────────────
        if (flush && !recovering_r) begin
            // Mark entries for flushed thread
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                if (rob_valid[flush_tid][j] &&
                    (rob_epoch[flush_tid][j] != flush_new_epoch) &&
                    (!flush_order_valid ||
                     (rob_order_id[flush_tid][j] > flush_order_id) ||
                     (!rob_complete[flush_tid][j] && (rob_order_id[flush_tid][j] == flush_order_id)))) begin
                    rob_flushed[flush_tid][j] <= 1'b1;
                    `ifndef SYNTHESIS
                    $display("[ROB FLUSH] tid=%0d entry_order=%0d flush_order_valid=%0b flush_order=%0d @%0t",
                             flush_tid, rob_order_id[flush_tid][j], flush_order_valid, flush_order_id, $time);
                    `endif
                end
            end
            // Start recovery walk from tail-1 backward.
            // Walk will restore rename map & free speculative phys regs.
            if (rob_count[flush_tid] > 0) begin
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

        // ── Thread 0 Commit + Dispatch ─────────────────────────
        if (!recovering_r) begin : t0_next_state
            reg [ROB_IDX_W-1:0] next_head;
            reg [ROB_IDX_W-1:0] next_tail;
            reg [ROB_IDX_W:0]   next_count;
            integer             skip_idx;

            next_head  = rob_head[0];
            next_tail  = rob_tail[0];
            next_count = rob_count[0];

            // Heal stale head holes
            for (skip_idx = 0; skip_idx < ROB_DEPTH; skip_idx = skip_idx + 1) begin
                if ((next_count != {ROB_IDX_W+1{1'b0}}) && !rob_valid[0][next_head])
                    next_head = next_head + 1;
            end

            // Step 1: Commit or skip flushed
            if (rob_valid[0][next_head] && rob_flushed[0][next_head]) begin
                rob_valid[0][next_head] <= 1'b0;
                rob_has_result[0][next_head] <= 1'b0;
                rob_result[0][next_head] <= 32'd0;
                next_head = next_head + 1;
                next_count = next_count - 1;
            end else if (rob_valid[0][next_head] && rob_complete[0][next_head] && !rob_flushed[0][next_head]) begin
                commit0_valid_r      <= 1'b1;
                commit0_rd_r         <= rob_rd[0][next_head];
                commit0_tag_r        <= rob_tag[0][next_head];
                commit0_has_result_r <= rob_has_result[0][next_head];
                commit0_data_r       <= rob_result[0][next_head];
                commit0_order_id_r   <= rob_order_id[0][next_head];
                commit0_is_store_r   <= rob_is_store[0][next_head];
                commit0_prd_old_r    <= rob_prd_old[0][next_head];
                commit0_regs_write_r <= rob_regs_write[0][next_head];
                rob_valid[0][next_head] <= 1'b0;
                rob_has_result[0][next_head] <= 1'b0;
                rob_result[0][next_head] <= 32'd0;
                next_head = next_head + 1;
                next_count = next_count - 1;
            end

            // Step 2: Dispatch allocation(s)
            if (disp0_valid && !rob0_full && (disp0_tid == 1'b0)) begin
                rob_valid[0][next_tail]      <= 1'b1;
                rob_complete[0][next_tail]   <= 1'b0;
                rob_flushed[0][next_tail]    <= 1'b0;
                rob_tag[0][next_tail]        <= disp0_tag;
                rob_order_id[0][next_tail]   <= disp0_order_id;
                rob_epoch[0][next_tail]      <= disp0_epoch;
                rob_rd[0][next_tail]         <= disp0_rd;
                rob_is_store[0][next_tail]   <= disp0_is_store;
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

            if (disp1_valid && !rob1_full && (disp1_tid == 1'b0)) begin
                rob_valid[0][next_tail]      <= 1'b1;
                rob_complete[0][next_tail]   <= 1'b0;
                rob_flushed[0][next_tail]    <= 1'b0;
                rob_tag[0][next_tail]        <= disp1_tag;
                rob_order_id[0][next_tail]   <= disp1_order_id;
                rob_epoch[0][next_tail]      <= disp1_epoch;
                rob_rd[0][next_tail]         <= disp1_rd;
                rob_is_store[0][next_tail]   <= disp1_is_store;
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

        // ── Thread 1 Commit + Dispatch ─────────────────────────
        if (!recovering_r) begin : t1_next_state
            reg [ROB_IDX_W-1:0] next_head;
            reg [ROB_IDX_W-1:0] next_tail;
            reg [ROB_IDX_W:0]   next_count;
            integer             skip_idx;

            next_head  = rob_head[1];
            next_tail  = rob_tail[1];
            next_count = rob_count[1];

            // Heal stale head holes
            for (skip_idx = 0; skip_idx < ROB_DEPTH; skip_idx = skip_idx + 1) begin
                if ((next_count != {ROB_IDX_W+1{1'b0}}) && !rob_valid[1][next_head])
                    next_head = next_head + 1;
            end

            // Step 1: Commit or skip flushed
            if (rob_valid[1][next_head] && rob_flushed[1][next_head]) begin
                rob_valid[1][next_head] <= 1'b0;
                rob_has_result[1][next_head] <= 1'b0;
                rob_result[1][next_head] <= 32'd0;
                next_head = next_head + 1;
                next_count = next_count - 1;
            end else if (rob_valid[1][next_head] && rob_complete[1][next_head] && !rob_flushed[1][next_head]) begin
                commit1_valid_r      <= 1'b1;
                commit1_rd_r         <= rob_rd[1][next_head];
                commit1_tag_r        <= rob_tag[1][next_head];
                commit1_has_result_r <= rob_has_result[1][next_head];
                commit1_data_r       <= rob_result[1][next_head];
                commit1_order_id_r   <= rob_order_id[1][next_head];
                commit1_is_store_r   <= rob_is_store[1][next_head];
                commit1_prd_old_r    <= rob_prd_old[1][next_head];
                commit1_regs_write_r <= rob_regs_write[1][next_head];
                rob_valid[1][next_head] <= 1'b0;
                rob_has_result[1][next_head] <= 1'b0;
                rob_result[1][next_head] <= 32'd0;
                next_head = next_head + 1;
                next_count = next_count - 1;
            end

            // Step 2: Dispatch allocation(s)
            if (disp0_valid && !rob0_full && (disp0_tid == 1'b1)) begin
                rob_valid[1][next_tail]      <= 1'b1;
                rob_complete[1][next_tail]   <= 1'b0;
                rob_flushed[1][next_tail]    <= 1'b0;
                rob_tag[1][next_tail]        <= disp0_tag;
                rob_order_id[1][next_tail]   <= disp0_order_id;
                rob_epoch[1][next_tail]      <= disp0_epoch;
                rob_rd[1][next_tail]         <= disp0_rd;
                rob_is_store[1][next_tail]   <= disp0_is_store;
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

            if (disp1_valid && !rob1_full && (disp1_tid == 1'b1)) begin
                rob_valid[1][next_tail]      <= 1'b1;
                rob_complete[1][next_tail]   <= 1'b0;
                rob_flushed[1][next_tail]    <= 1'b0;
                rob_tag[1][next_tail]        <= disp1_tag;
                rob_order_id[1][next_tail]   <= disp1_order_id;
                rob_epoch[1][next_tail]      <= disp1_epoch;
                rob_rd[1][next_tail]         <= disp1_rd;
                rob_is_store[1][next_tail]   <= disp1_is_store;
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
