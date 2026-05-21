`timescale 1ns/1ns
// =============================================================================
// Module : rob_lite
// Description: Minimal single-thread Reorder Buffer for in-order commit.
//   - Metadata-only: does NOT store result values
//   - Circular queue with head/tail pointers
//   - Allocated at dispatch, completed at WB, retired at commit
//   - Flush support via epoch tracking
//
//   Entry fields:
//     - valid: entry is allocated
//     - complete: WB has arrived for this instruction
//     - flushed: instruction should not retire (wrong path)
//     - order_id: instruction sequence number
//     - epoch: dispatch epoch for flush detection
//     - rd: destination register (for retirement accounting)
//     - is_store: memory store flag
// =============================================================================
`include "define.v"

module rob_lite #(
    parameter ROB_DEPTH     = 8,        // Entries (power of 2)
    parameter ROB_IDX_W     = 3,        // log2(ROB_DEPTH)
    parameter RS_TAG_W      = 5         // Match scoreboard tag width
)(
    input  wire                        clk,
    input  wire                        rstn,

    // --- Flush Interface -------------------------------------------------
    input  wire                        flush,
    input  wire [`METADATA_EPOCH_W-1:0] flush_new_epoch,  // New epoch after flush
    input  wire                        flush_order_valid, // 1 for branch redirect, 0 for trap/global flush
    input  wire [`METADATA_ORDER_ID_W-1:0] flush_order_id,

    // --- Dispatch Port 0 -------------------------------------------------
    input  wire                        disp0_valid,
    input  wire [RS_TAG_W-1:0]         disp0_tag,       // Scoreboard tag for WB matching
    input  wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]    disp0_epoch,
    input  wire [4:0]                  disp0_rd,
    input  wire                        disp0_is_store,
    output wire                        rob0_full,       // Cannot accept dispatch

    // --- Dispatch Port 1 -------------------------------------------------
    input  wire                        disp1_valid,
    input  wire [RS_TAG_W-1:0]         disp1_tag,
    input  wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]    disp1_epoch,
    input  wire [4:0]                  disp1_rd,
    input  wire                        disp1_is_store,
    output wire                        rob1_full,       // Cannot accept dispatch

    // --- Writeback Port 0 ------------------------------------------------
    input  wire                        wb0_valid,
    input  wire [RS_TAG_W-1:0]         wb0_tag,
    input  wire [31:0]                 wb0_data,
    input  wire                        wb0_regs_write,

    // --- Writeback Port 1 ------------------------------------------------
    input  wire                        wb1_valid,
    input  wire [RS_TAG_W-1:0]         wb1_tag,
    input  wire [31:0]                 wb1_data,
    input  wire                        wb1_regs_write,

    // --- Commit Outputs --------------------------------------------------
    output wire                        commit0_valid,   // Instruction retired
    output wire [4:0]                  commit0_rd,      // Destination register
    output wire [1:0]                  instr_retired,   // {1'b0, retire} for CSR

    // --- Commit Data Outputs (for regfile write at commit) ---------------
    output wire [RS_TAG_W-1:0]         commit0_tag,     // Tag of committing instruction
    output wire                        commit0_has_result,
    output wire [31:0]                 commit0_data,

    // --- Store Buffer Commit Outputs -------------------------------------
    output wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id,  // Order ID for store buffer
    output wire                        commit0_is_store       // Is committing instruction a store?
);

// =============================================================================
// ROB State
// =============================================================================

// Circular buffer storage
reg                     rob_valid      [0:ROB_DEPTH-1];
reg                     rob_complete   [0:ROB_DEPTH-1];
reg                     rob_flushed    [0:ROB_DEPTH-1];
reg  [RS_TAG_W-1:0]     rob_tag        [0:ROB_DEPTH-1];
reg  [`METADATA_ORDER_ID_W-1:0] rob_order_id [0:ROB_DEPTH-1];
reg  [`METADATA_EPOCH_W-1:0]    rob_epoch    [0:ROB_DEPTH-1];
reg  [4:0]              rob_rd         [0:ROB_DEPTH-1];
reg                     rob_is_store   [0:ROB_DEPTH-1];
reg                     rob_has_result [0:ROB_DEPTH-1];
reg  [31:0]             rob_result     [0:ROB_DEPTH-1];

// Head/tail pointers
reg  [ROB_IDX_W-1:0]    rob_head;      // Commit pointer (oldest)
reg  [ROB_IDX_W-1:0]    rob_tail;      // Allocate pointer (next free)
reg  [ROB_IDX_W:0]      rob_count;     // Occupancy count (extra bit for full/empty)

// Registered commit outputs keep retirement metadata stable for downstream
// bookkeeping instead of exposing the live head entry combinationally.
reg                     commit0_valid_r;
reg  [4:0]              commit0_rd_r;
reg  [RS_TAG_W-1:0]     commit0_tag_r;
reg                     commit0_has_result_r;
reg  [31:0]             commit0_data_r;
reg  [`METADATA_ORDER_ID_W-1:0] commit0_order_id_r;
reg                     commit0_is_store_r;

// =============================================================================
// Utility
// =============================================================================

// Check if ROB is full
wire rob_full_flag = (rob_count >= ROB_DEPTH - 2);  // Leave margin for dual-dispatch

assign rob0_full = rob_full_flag;
assign rob1_full = rob_full_flag;

// =============================================================================
// Dispatch Allocation Logic
// =============================================================================

// Allocation slots for dual-dispatch
wire [ROB_IDX_W-1:0] alloc0_idx = rob_tail;
wire [ROB_IDX_W-1:0] alloc1_idx = rob_tail + 1;

// =============================================================================
// WB Completion Logic - Find entries by tag
// =============================================================================

// For WB port 0: search for matching tag
reg [ROB_IDX_W-1:0] wb0_match_idx;
reg                 wb0_match_found;

// For WB port 1: search for matching tag
reg [ROB_IDX_W-1:0] wb1_match_idx;
reg                 wb1_match_found;

integer i;
always @(*) begin
    // Initialize to not found
    wb0_match_found = 1'b0;
    wb1_match_found = 1'b0;
    wb0_match_idx = {ROB_IDX_W{1'b0}};
    wb1_match_idx = {ROB_IDX_W{1'b0}};

    // Search for WB0 tag match
    for (i = 0; i < ROB_DEPTH; i = i + 1) begin
        if (!wb0_match_found && rob_valid[i] && !rob_complete[i] &&
            (rob_tag[i] == wb0_tag) && wb0_valid) begin
            wb0_match_found = 1'b1;
            wb0_match_idx = i[ROB_IDX_W-1:0];
        end
    end

    // Search for WB1 tag match
    for (i = 0; i < ROB_DEPTH; i = i + 1) begin
        if (!wb1_match_found && rob_valid[i] && !rob_complete[i] &&
            (rob_tag[i] == wb1_tag) && wb1_valid) begin
            wb1_match_found = 1'b1;
            wb1_match_idx = i[ROB_IDX_W-1:0];
        end
    end
end

// =============================================================================
// Commit Logic - Head of queue retirement
// =============================================================================

assign commit0_valid = commit0_valid_r;
assign commit0_rd = commit0_rd_r;
assign commit0_tag = commit0_tag_r;
assign commit0_has_result = commit0_has_result_r;
assign commit0_data = commit0_data_r;

// instr_retired for CSR unit: single-thread retirement pulse
assign instr_retired = {1'b0, commit0_valid_r};

// Store buffer commit outputs
assign commit0_order_id = commit0_order_id_r;
assign commit0_is_store = commit0_is_store_r;

// =============================================================================
// Sequential Logic
// =============================================================================

integer j;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        commit0_valid_r <= 1'b0;
        commit0_rd_r <= 5'd0;
        commit0_tag_r <= {RS_TAG_W{1'b0}};
        commit0_has_result_r <= 1'b0;
        commit0_data_r <= 32'd0;
        commit0_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        commit0_is_store_r <= 1'b0;
        // Reset all entries
        rob_head  <= {ROB_IDX_W{1'b0}};
        rob_tail  <= {ROB_IDX_W{1'b0}};
        rob_count <= {(ROB_IDX_W+1){1'b0}};
        for (j = 0; j < ROB_DEPTH; j = j + 1) begin
            rob_valid[j]    <= 1'b0;
            rob_complete[j] <= 1'b0;
            rob_flushed[j]  <= 1'b0;
            rob_tag[j]      <= {RS_TAG_W{1'b0}};
            rob_order_id[j] <= {`METADATA_ORDER_ID_W{1'b0}};
            rob_epoch[j]    <= {`METADATA_EPOCH_W{1'b0}};
            rob_rd[j]       <= 5'd0;
            rob_is_store[j] <= 1'b0;
            rob_has_result[j] <= 1'b0;
            rob_result[j]   <= 32'd0;
        end
    end else begin
        commit0_valid_r <= 1'b0;

        // -- Flush Handling -----------------------------------------------
        if (flush) begin
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                if (rob_valid[j] &&
                    (!flush_order_valid ||
                     (rob_order_id[j] > flush_order_id) ||
                     (!rob_is_mret[j] &&
                      !rob_complete[j] &&
                      (rob_order_id[j] == flush_order_id)))) begin
                    rob_flushed[j] <= 1'b1;
                    `ifndef SYNTHESIS
                    $display("[ROB FLUSH] entry_order=%0d flush_order_valid=%0b flush_order=%0d @%0t",
                             rob_order_id[j], flush_order_valid, flush_order_id, $time);
                    `endif
                end
            end
        end

        // -- WB Completion ------------------------------------------------
        if (wb0_valid) begin
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                if (rob_valid[j] && !rob_complete[j] && (rob_tag[j] == wb0_tag)) begin
                    rob_complete[j] <= 1'b1;
                    rob_has_result[j] <= wb0_regs_write && (rob_rd[j] != 5'd0);
                    if (wb0_regs_write)
                        rob_result[j] <= wb0_data;
                end
            end
        end

        if (wb1_valid) begin
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                if (rob_valid[j] && !rob_complete[j] && (rob_tag[j] == wb1_tag)) begin
                    rob_complete[j] <= 1'b1;
                    rob_has_result[j] <= wb1_regs_write && (rob_rd[j] != 5'd0);
                    if (wb1_regs_write)
                        rob_result[j] <= wb1_data;
                end
            end
        end

        // -- Next-State Calculation ---------------------------------------
        begin : next_state
            reg [ROB_IDX_W-1:0] next_head;
            reg [ROB_IDX_W-1:0] next_tail;
            reg [ROB_IDX_W:0]   next_count;
            reg                 commit_done;
            integer             skip_idx;

            next_head  = rob_head;
            next_tail  = rob_tail;
            next_count = rob_count;
            commit_done = 1'b0;

            // Heal any stale head hole so retirement cannot deadlock on an
            // invalid slot while later entries are still live.
            for (skip_idx = 0; skip_idx < ROB_DEPTH; skip_idx = skip_idx + 1) begin
                if ((next_count != {ROB_IDX_W+1{1'b0}}) && !rob_valid[next_head])
                    next_head = next_head + 1;
            end

            // Step 1: Advance head past completed or flushed entries
            if (rob_valid[next_head] && rob_flushed[next_head]) begin
                // Skip flushed entry - deallocate and advance
                rob_valid[next_head] <= 1'b0;
                rob_has_result[next_head] <= 1'b0;
                rob_result[next_head] <= 32'd0;
                next_head = next_head + 1;
                next_count = next_count - 1;
            end else if (rob_valid[next_head] && rob_complete[next_head] && !rob_flushed[next_head]) begin
                // Commit valid completed entry
                commit0_valid_r <= 1'b1;
                commit0_rd_r <= rob_rd[next_head];
                commit0_tag_r <= rob_tag[next_head];
                commit0_has_result_r <= rob_has_result[next_head];
                commit0_data_r <= rob_result[next_head];
                commit0_order_id_r <= rob_order_id[next_head];
                commit0_is_store_r <= rob_is_store[next_head];
                rob_valid[next_head] <= 1'b0;
                rob_has_result[next_head] <= 1'b0;
                rob_result[next_head] <= 32'd0;
                next_head = next_head + 1;
                next_count = next_count - 1;
                commit_done = 1'b1;
            end

            // Step 2: Handle dispatch allocation(s)
            if (disp0_valid && !rob0_full) begin
                rob_valid[next_tail]    <= 1'b1;
                rob_complete[next_tail] <= 1'b0;
                rob_flushed[next_tail]  <= 1'b0;
                rob_tag[next_tail]      <= disp0_tag;
                rob_order_id[next_tail] <= disp0_order_id;
                rob_epoch[next_tail]    <= disp0_epoch;
                rob_rd[next_tail]       <= disp0_rd;
                rob_is_store[next_tail] <= disp0_is_store;
                rob_has_result[next_tail] <= 1'b0;
                rob_result[next_tail]   <= 32'd0;
                next_tail = next_tail + 1;
                next_count = next_count + 1;
            end

            if (disp1_valid && !rob1_full) begin
                rob_valid[next_tail]    <= 1'b1;
                rob_complete[next_tail] <= 1'b0;
                rob_flushed[next_tail]  <= 1'b0;
                rob_tag[next_tail]      <= disp1_tag;
                rob_order_id[next_tail] <= disp1_order_id;
                rob_epoch[next_tail]    <= disp1_epoch;
                rob_rd[next_tail]       <= disp1_rd;
                rob_is_store[next_tail] <= disp1_is_store;
                rob_has_result[next_tail] <= 1'b0;
                rob_result[next_tail]   <= 32'd0;
                next_tail = next_tail + 1;
                next_count = next_count + 1;
            end

            // Step 3: Apply next state
            rob_head  <= next_head;
            rob_tail  <= next_tail;
            rob_count <= next_count;
        end
    end
end

endmodule
