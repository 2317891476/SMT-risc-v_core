`timescale 1ns/1ns
// =============================================================================
// Module : rob_lite
// Description: Minimal per-thread Reorder Buffer for in-order commit.
//   - Metadata-only: does NOT store result values
//   - Circular queue per thread with head/tail pointers
//   - Allocated at dispatch, completed at WB, retired at commit
//   - Flush support via epoch tracking
//
//   Entry fields:
//     - valid: entry is allocated
//     - complete: WB has arrived for this instruction
//     - flushed: instruction should not retire (wrong path)
//     - order_id: per-thread instruction sequence number
//     - epoch: dispatch epoch for flush detection
//     - rd: destination register (for retirement accounting)
//     - is_store: memory store flag
// =============================================================================
`include "define.v"

module rob_lite #(
    parameter ROB_DEPTH     = 8,        // Entries per thread (power of 2)
    parameter ROB_IDX_W     = 3,        // log2(ROB_DEPTH)
    parameter RS_TAG_W      = 5,        // Match scoreboard tag width
    parameter NUM_THREAD    = 2
)(
    input  wire                        clk,
    input  wire                        rstn,

    // ─── Flush Interface ─────────────────────────────────────────
    input  wire                        flush,
    input  wire [0:0]                  flush_tid,
    input  wire [`METADATA_EPOCH_W-1:0] flush_new_epoch,  // New epoch after flush
    input  wire                        flush_order_valid, // 1 for branch redirect, 0 for trap/global flush
    input  wire [`METADATA_ORDER_ID_W-1:0] flush_order_id,

    // ─── Dispatch Port 0 ─────────────────────────────────────────
    input  wire                        disp0_valid,
    input  wire [RS_TAG_W-1:0]         disp0_tag,       // Scoreboard tag for WB matching
    input  wire [0:0]                  disp0_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]    disp0_epoch,
    input  wire [4:0]                  disp0_rd,
    input  wire                        disp0_is_store,
    output wire                        rob0_full,       // Cannot accept dispatch

    // ─── Dispatch Port 1 ─────────────────────────────────────────
    input  wire                        disp1_valid,
    input  wire [RS_TAG_W-1:0]         disp1_tag,
    input  wire [0:0]                  disp1_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]    disp1_epoch,
    input  wire [4:0]                  disp1_rd,
    input  wire                        disp1_is_store,
    output wire                        rob1_full,       // Cannot accept dispatch

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
    output wire                        commit0_valid,   // Instruction retired thread 0
    output wire                        commit1_valid,   // Instruction retired thread 1
    output wire [4:0]                  commit0_rd,      // Destination register for thread 0
    output wire [4:0]                  commit1_rd,      // Destination register for thread 1
    output wire [1:0]                  instr_retired,   // {t1_retire, t0_retire} for CSR

    // ─── Commit Data Outputs (for regfile write at commit) ───────
    output wire [RS_TAG_W-1:0]         commit0_tag,     // Tag of committing instruction T0
    output wire [RS_TAG_W-1:0]         commit1_tag,     // Tag of committing instruction T1
    output wire                        commit0_has_result,
    output wire                        commit1_has_result,
    output wire [31:0]                 commit0_data,
    output wire [31:0]                 commit1_data,

    // ─── Store Buffer Commit Outputs ─────────────────────────────
    output wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id,  // Order ID for store buffer
    output wire [`METADATA_ORDER_ID_W-1:0] commit1_order_id,
    output wire                        commit0_is_store,  // Is committing instruction a store?
    output wire                        commit1_is_store
);

// ═════════════════════════════════════════════════════════════════════════════
// Per-Thread ROB State
// ═════════════════════════════════════════════════════════════════════════════

// Circular buffer storage for each thread
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

// Head/tail pointers per thread
reg  [ROB_IDX_W-1:0]    rob_head    [0:NUM_THREAD-1];  // Commit pointer (oldest)
reg  [ROB_IDX_W-1:0]    rob_tail    [0:NUM_THREAD-1];  // Allocate pointer (next free)
reg  [ROB_IDX_W:0]      rob_count   [0:NUM_THREAD-1];  // Occupancy count (extra bit for full/empty)

// Registered commit outputs keep retirement metadata stable for downstream
// bookkeeping instead of exposing the live head entry combinationally.
reg                     commit0_valid_r, commit1_valid_r;
reg  [4:0]              commit0_rd_r, commit1_rd_r;
reg  [RS_TAG_W-1:0]     commit0_tag_r, commit1_tag_r;
reg                     commit0_has_result_r, commit1_has_result_r;
reg  [31:0]             commit0_data_r, commit1_data_r;
reg  [`METADATA_ORDER_ID_W-1:0] commit0_order_id_r, commit1_order_id_r;
reg                     commit0_is_store_r, commit1_is_store_r;

// ═════════════════════════════════════════════════════════════════════════════
// Utility functions
// ═════════════════════════════════════════════════════════════════════════════

// Check if ROB is full for a thread
wire rob_full_t0 = (rob_count[0] >= ROB_DEPTH - 2);  // Leave margin for dual-dispatch
wire rob_full_t1 = (rob_count[1] >= ROB_DEPTH - 2);

assign rob0_full = disp0_tid ? rob_full_t1 : rob_full_t0;
assign rob1_full = disp1_tid ? rob_full_t1 : rob_full_t0;

// ═════════════════════════════════════════════════════════════════════════════
// Dispatch Allocation Logic
// ═════════════════════════════════════════════════════════════════════════════

// Find allocation slots for dual-dispatch
wire [ROB_IDX_W-1:0] alloc0_idx_t0 = rob_tail[0];
wire [ROB_IDX_W-1:0] alloc0_idx_t1 = rob_tail[1];
wire [ROB_IDX_W-1:0] alloc1_idx_t0 = rob_tail[0] + 1;
wire [ROB_IDX_W-1:0] alloc1_idx_t1 = rob_tail[1] + 1;

// ═════════════════════════════════════════════════════════════════════════════
// WB Completion Logic - Find entries by tag
// ═════════════════════════════════════════════════════════════════════════════

// For WB port 0: search for matching tag in each thread
reg [ROB_IDX_W-1:0] wb0_match_idx_t0, wb0_match_idx_t1;
reg                 wb0_match_found_t0, wb0_match_found_t1;

// For WB port 1: search for matching tag in each thread
reg [ROB_IDX_W-1:0] wb1_match_idx_t0, wb1_match_idx_t1;
reg                 wb1_match_found_t0, wb1_match_found_t1;

integer i;
always @(*) begin
    // Initialize to not found
    wb0_match_found_t0 = 1'b0;
    wb0_match_found_t1 = 1'b0;
    wb1_match_found_t0 = 1'b0;
    wb1_match_found_t1 = 1'b0;
    wb0_match_idx_t0 = {ROB_IDX_W{1'b0}};
    wb0_match_idx_t1 = {ROB_IDX_W{1'b0}};
    wb1_match_idx_t0 = {ROB_IDX_W{1'b0}};
    wb1_match_idx_t1 = {ROB_IDX_W{1'b0}};

    // Search for WB0 tag match in thread 0
    for (i = 0; i < ROB_DEPTH; i = i + 1) begin
        if (!wb0_match_found_t0 && rob_valid[0][i] && !rob_complete[0][i] &&
            (rob_tag[0][i] == wb0_tag) && (wb0_tid == 1'b0) && wb0_valid) begin
            wb0_match_found_t0 = 1'b1;
            wb0_match_idx_t0 = i[ROB_IDX_W-1:0];
        end
    end

    // Search for WB0 tag match in thread 1
    for (i = 0; i < ROB_DEPTH; i = i + 1) begin
        if (!wb0_match_found_t1 && rob_valid[1][i] && !rob_complete[1][i] &&
            (rob_tag[1][i] == wb0_tag) && (wb0_tid == 1'b1) && wb0_valid) begin
            wb0_match_found_t1 = 1'b1;
            wb0_match_idx_t1 = i[ROB_IDX_W-1:0];
        end
    end

    // Search for WB1 tag match in thread 0
    for (i = 0; i < ROB_DEPTH; i = i + 1) begin
        if (!wb1_match_found_t0 && rob_valid[0][i] && !rob_complete[0][i] &&
            (rob_tag[0][i] == wb1_tag) && (wb1_tid == 1'b0) && wb1_valid) begin
            wb1_match_found_t0 = 1'b1;
            wb1_match_idx_t0 = i[ROB_IDX_W-1:0];
        end
    end

    // Search for WB1 tag match in thread 1
    for (i = 0; i < ROB_DEPTH; i = i + 1) begin
        if (!wb1_match_found_t1 && rob_valid[1][i] && !rob_complete[1][i] &&
            (rob_tag[1][i] == wb1_tag) && (wb1_tid == 1'b1) && wb1_valid) begin
            wb1_match_found_t1 = 1'b1;
            wb1_match_idx_t1 = i[ROB_IDX_W-1:0];
        end
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// Commit Logic - Head of queue retirement
// ═════════════════════════════════════════════════════════════════════════════

assign commit0_valid = commit0_valid_r;
assign commit1_valid = commit1_valid_r;
assign commit0_rd = commit0_rd_r;
assign commit1_rd = commit1_rd_r;
assign commit0_tag = commit0_tag_r;
assign commit1_tag = commit1_tag_r;
assign commit0_has_result = commit0_has_result_r;
assign commit1_has_result = commit1_has_result_r;
assign commit0_data = commit0_data_r;
assign commit1_data = commit1_data_r;

// instr_retired for CSR unit: per-thread retirement pulses
assign instr_retired = {commit1_valid_r, commit0_valid_r};

// Store buffer commit outputs
assign commit0_order_id = commit0_order_id_r;
assign commit1_order_id = commit1_order_id_r;
assign commit0_is_store = commit0_is_store_r;
assign commit1_is_store = commit1_is_store_r;

// ═════════════════════════════════════════════════════════════════════════════
// Sequential Logic
// ═════════════════════════════════════════════════════════════════════════════

integer t, j;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        commit0_valid_r <= 1'b0;
        commit1_valid_r <= 1'b0;
        commit0_rd_r <= 5'd0;
        commit1_rd_r <= 5'd0;
        commit0_tag_r <= {RS_TAG_W{1'b0}};
        commit1_tag_r <= {RS_TAG_W{1'b0}};
        commit0_has_result_r <= 1'b0;
        commit1_has_result_r <= 1'b0;
        commit0_data_r <= 32'd0;
        commit1_data_r <= 32'd0;
        commit0_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        commit1_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        commit0_is_store_r <= 1'b0;
        commit1_is_store_r <= 1'b0;
        // Reset all entries
        for (t = 0; t < NUM_THREAD; t = t + 1) begin
            rob_head[t]  <= {ROB_IDX_W{1'b0}};
            rob_tail[t]  <= {ROB_IDX_W{1'b0}};
            rob_count[t] <= {(ROB_IDX_W+1){1'b0}};
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                rob_valid[t][j]    <= 1'b0;
                rob_complete[t][j] <= 1'b0;
                rob_flushed[t][j]  <= 1'b0;
                rob_tag[t][j]      <= {RS_TAG_W{1'b0}};
                rob_order_id[t][j] <= {`METADATA_ORDER_ID_W{1'b0}};
                rob_epoch[t][j]    <= {`METADATA_EPOCH_W{1'b0}};
                rob_rd[t][j]       <= 5'd0;
                rob_is_store[t][j] <= 1'b0;
                rob_has_result[t][j] <= 1'b0;
                rob_result[t][j]   <= 32'd0;
            end
        end
    end else begin
        commit0_valid_r <= 1'b0;
        commit1_valid_r <= 1'b0;
        // ── Flush Handling ─────────────────────────────────────
        if (flush) begin
            // Mark entries for flushed thread as flushed
            // (Epoch comparison will prevent retirement)
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                if (rob_valid[flush_tid][j] &&
                    (!flush_order_valid ||
                     (rob_order_id[flush_tid][j] > flush_order_id) ||
                     (!rob_is_mret[flush_tid][j] &&
                      !rob_complete[flush_tid][j] &&
                      (rob_order_id[flush_tid][j] == flush_order_id)))) begin
                    rob_flushed[flush_tid][j] <= 1'b1;
                    `ifndef SYNTHESIS
                    $display("[ROB FLUSH] tid=%0d entry_order=%0d flush_order_valid=%0b flush_order=%0d @%0t",
                             flush_tid, rob_order_id[flush_tid][j], flush_order_valid, flush_order_id, $time);
                    `endif
                end
            end
        end

        // ── WB Completion ──────────────────────────────────────
        // Mark ALL matching entries as complete (handles duplicate tags)
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

        // ── Single Next-State Calculation Per Thread ──────────
        // Thread 0: Calculate head/tail/count next state atomically
        begin : t0_next_state
            reg [ROB_IDX_W-1:0] next_head;
            reg [ROB_IDX_W-1:0] next_tail;
            reg [ROB_IDX_W:0]   next_count;
            reg                 t0_commit_done;
            integer             skip_idx;

            next_head  = rob_head[0];
            next_tail  = rob_tail[0];
            next_count = rob_count[0];
            t0_commit_done = 1'b0;

            // Heal any stale head hole so retirement cannot deadlock on an
            // invalid slot while later entries are still live.
            for (skip_idx = 0; skip_idx < ROB_DEPTH; skip_idx = skip_idx + 1) begin
                if ((next_count != {ROB_IDX_W+1{1'b0}}) && !rob_valid[0][next_head])
                    next_head = next_head + 1;
            end

            // Step 1: Advance head past completed or flushed entries
            // Head moves if entry is valid AND (completed AND not flushed OR flushed)
            // Flushed entries are bypassed without committing
            if (rob_valid[0][next_head] && rob_flushed[0][next_head]) begin
                // Skip flushed entry - deallocate and advance
                rob_valid[0][next_head] <= 1'b0;
                rob_has_result[0][next_head] <= 1'b0;
                rob_result[0][next_head] <= 32'd0;
                next_head = next_head + 1;
                next_count = next_count - 1;
            end else if (rob_valid[0][next_head] && rob_complete[0][next_head] && !rob_flushed[0][next_head]) begin
                // Commit valid completed entry
                commit0_valid_r <= 1'b1;
                commit0_rd_r <= rob_rd[0][next_head];
                commit0_tag_r <= rob_tag[0][next_head];
                commit0_has_result_r <= rob_has_result[0][next_head];
                commit0_data_r <= rob_result[0][next_head];
                commit0_order_id_r <= rob_order_id[0][next_head];
                commit0_is_store_r <= rob_is_store[0][next_head];
                rob_valid[0][next_head] <= 1'b0;
                rob_has_result[0][next_head] <= 1'b0;
                rob_result[0][next_head] <= 32'd0;
                next_head = next_head + 1;
                next_count = next_count - 1;
                t0_commit_done = 1'b1;
            end

            // Step 2: Handle dispatch allocation(s)
            if (disp0_valid && !rob0_full && (disp0_tid == 1'b0)) begin
                rob_valid[0][next_tail]    <= 1'b1;
                rob_complete[0][next_tail] <= 1'b0;
                rob_flushed[0][next_tail]  <= 1'b0;
                rob_tag[0][next_tail]      <= disp0_tag;
                rob_order_id[0][next_tail] <= disp0_order_id;
                rob_epoch[0][next_tail]    <= disp0_epoch;
                rob_rd[0][next_tail]       <= disp0_rd;
                rob_is_store[0][next_tail] <= disp0_is_store;
                rob_has_result[0][next_tail] <= 1'b0;
                rob_result[0][next_tail]   <= 32'd0;
                next_tail = next_tail + 1;
                next_count = next_count + 1;
            end

            if (disp1_valid && !rob1_full && (disp1_tid == 1'b0)) begin
                rob_valid[0][next_tail]    <= 1'b1;
                rob_complete[0][next_tail] <= 1'b0;
                rob_flushed[0][next_tail]  <= 1'b0;
                rob_tag[0][next_tail]      <= disp1_tag;
                rob_order_id[0][next_tail] <= disp1_order_id;
                rob_epoch[0][next_tail]    <= disp1_epoch;
                rob_rd[0][next_tail]       <= disp1_rd;
                rob_is_store[0][next_tail] <= disp1_is_store;
                rob_has_result[0][next_tail] <= 1'b0;
                rob_result[0][next_tail]   <= 32'd0;
                next_tail = next_tail + 1;
                next_count = next_count + 1;
            end

            // Step 3: Apply next state
            rob_head[0]  <= next_head;
            rob_tail[0]  <= next_tail;
            rob_count[0] <= next_count;
        end

        // Thread 1: Calculate head/tail/count next state atomically
        begin : t1_next_state
            reg [ROB_IDX_W-1:0] next_head;
            reg [ROB_IDX_W-1:0] next_tail;
            reg [ROB_IDX_W:0]   next_count;
            reg                 t1_commit_done;
            integer             skip_idx;

            next_head  = rob_head[1];
            next_tail  = rob_tail[1];
            next_count = rob_count[1];
            t1_commit_done = 1'b0;

            // Heal any stale head hole so retirement cannot deadlock on an
            // invalid slot while later entries are still live.
            for (skip_idx = 0; skip_idx < ROB_DEPTH; skip_idx = skip_idx + 1) begin
                if ((next_count != {ROB_IDX_W+1{1'b0}}) && !rob_valid[1][next_head])
                    next_head = next_head + 1;
            end

            // Step 1: Advance head past completed or flushed entries
            if (rob_valid[1][next_head] && rob_flushed[1][next_head]) begin
                // Skip flushed entry - deallocate and advance
                rob_valid[1][next_head] <= 1'b0;
                rob_has_result[1][next_head] <= 1'b0;
                rob_result[1][next_head] <= 32'd0;
                next_head = next_head + 1;
                next_count = next_count - 1;
            end else if (rob_valid[1][next_head] && rob_complete[1][next_head] && !rob_flushed[1][next_head]) begin
                // Commit valid completed entry
                commit1_valid_r <= 1'b1;
                commit1_rd_r <= rob_rd[1][next_head];
                commit1_tag_r <= rob_tag[1][next_head];
                commit1_has_result_r <= rob_has_result[1][next_head];
                commit1_data_r <= rob_result[1][next_head];
                commit1_order_id_r <= rob_order_id[1][next_head];
                commit1_is_store_r <= rob_is_store[1][next_head];
                rob_valid[1][next_head] <= 1'b0;
                rob_has_result[1][next_head] <= 1'b0;
                rob_result[1][next_head] <= 32'd0;
                next_head = next_head + 1;
                next_count = next_count - 1;
                t1_commit_done = 1'b1;
            end

            // Step 2: Handle dispatch allocation(s)
            if (disp0_valid && !rob0_full && (disp0_tid == 1'b1)) begin
                rob_valid[1][next_tail]    <= 1'b1;
                rob_complete[1][next_tail] <= 1'b0;
                rob_flushed[1][next_tail]  <= 1'b0;
                rob_tag[1][next_tail]      <= disp0_tag;
                rob_order_id[1][next_tail] <= disp0_order_id;
                rob_epoch[1][next_tail]    <= disp0_epoch;
                rob_rd[1][next_tail]       <= disp0_rd;
                rob_is_store[1][next_tail] <= disp0_is_store;
                rob_has_result[1][next_tail] <= 1'b0;
                rob_result[1][next_tail]   <= 32'd0;
                next_tail = next_tail + 1;
                next_count = next_count + 1;
            end

            if (disp1_valid && !rob1_full && (disp1_tid == 1'b1)) begin
                rob_valid[1][next_tail]    <= 1'b1;
                rob_complete[1][next_tail] <= 1'b0;
                rob_flushed[1][next_tail]  <= 1'b0;
                rob_tag[1][next_tail]      <= disp1_tag;
                rob_order_id[1][next_tail] <= disp1_order_id;
                rob_epoch[1][next_tail]    <= disp1_epoch;
                rob_rd[1][next_tail]       <= disp1_rd;
                rob_is_store[1][next_tail] <= disp1_is_store;
                rob_has_result[1][next_tail] <= 1'b0;
                rob_result[1][next_tail]   <= 32'd0;
                next_tail = next_tail + 1;
                next_count = next_count + 1;
            end

            // Step 3: Apply next state
            rob_head[1]  <= next_head;
            rob_tail[1]  <= next_tail;
            rob_count[1] <= next_count;
        end
    end
end

endmodule
