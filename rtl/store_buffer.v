// =============================================================================
// Module : store_buffer
// Description: Store Buffer with commit-gated drain and wrong-path discard
//
//   - Buffers speculative store requests from LSU shell
//   - Stores complete speculatively for scoreboard/ROB tracking
//   - Drains to memory only when ROB signals commit for that store
//   - Discards wrong-path stores on flush (epoch mismatch)
//   - Maintains FIFO order for in-order drain
//
//   Entry fields:
//     - valid: entry contains a store
//     - addr: store address
//     - data: store data
//     - func3: store type (SB/SH/SW)
//     - order_id: for ROB commit ordering
//     - epoch: for flush detection
//     - committed: store has received commit signal from ROB
// =============================================================================
`include "define.v"

module store_buffer #(
    parameter SB_DEPTH      = 4,        // Entries (power of 2)
    parameter SB_IDX_W      = 2,        // log2(SB_DEPTH)
    parameter ORDER_ID_W    = `METADATA_ORDER_ID_W, // Match METADATA_ORDER_ID_W
    parameter EPOCH_W       = 8         // Match METADATA_EPOCH_W
)(
    input  wire                     clk,
    input  wire                     rstn,

    // ─── Flush Interface ─────────────────────────────────────────
    input  wire                     flush,
    input  wire [EPOCH_W-1:0]       flush_new_epoch_t0,  // Expected epoch after flush
    input  wire [EPOCH_W-1:0]       current_epoch_t0,
    input  wire                     flush_order_valid,   // 1 for branch redirect, 0 for trap/global flush
    input  wire [ORDER_ID_W-1:0]    flush_order_id,

    // ═══════════════════════════════════════════════════════════════════════════
    // Store Request Interface (from LSU shell)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire                     store_req_valid,     // Store request valid
    output wire                     store_req_accept,    // Store buffer can accept

    input  wire [ORDER_ID_W-1:0]    store_order_id,
    input  wire [EPOCH_W-1:0]       store_epoch,
    input  wire [31:0]              store_addr,
    input  wire [31:0]              store_data,
    input  wire [2:0]               store_func3,         // SB/SH/SW encoding

    // ═══════════════════════════════════════════════════════════════════════════
    // ROB Commit Interface (for drain authorization)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire                     commit0_valid,       // Commit
    input  wire [ORDER_ID_W-1:0]    commit0_order_id,    // Committing order_id
    input  wire                     commit0_is_store,    // Committing store

    // ═══════════════════════════════════════════════════════════════════════════
    // Memory Write Interface (to stage_mem/data_memory)
    // ═══════════════════════════════════════════════════════════════════════════
    output reg                      mem_write_valid,     // Valid memory write
    output reg  [31:0]              mem_write_addr,
    output reg  [31:0]              mem_write_data,
    output reg  [2:0]               mem_write_func3,
    output reg  [3:0]               mem_write_wen,       // Byte-wise write enable
    input  wire                     mem_write_ready,     // Memory accepts write

    // ═══════════════════════════════════════════════════════════════════════════
    // Load Query Interface (for store-to-load forwarding)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire                     load_query_valid,    // Load is querying SB
    input  wire [ORDER_ID_W-1:0]    load_query_order_id, // Load's order_id (for age check)
    input  wire [31:0]              load_query_addr,     // Load address
    input  wire [2:0]               load_query_func3,    // Load type (LB/LH/LW/LBU/LHU)

    output wire [31:0]              forward_data,        // Forwarded data (if exact match)
    output wire                     forward_valid,       // Forward data is valid
    output wire                     load_hazard,         // Stall: unresolved/partial overlap
    output wire                     older_store_pending_for_load,
    output wire                     debug_empty,
    output wire [SB_IDX_W:0]        debug_count_t0,

    // HPM event
    output wire                     sb_stall_event,

    // Drain urgency: a committed store is ready AND buffer is nearly full
    output wire                     sb_drain_urgent
);

// ═════════════════════════════════════════════════════════════════════════════
// Store Buffer State
// ═════════════════════════════════════════════════════════════════════════════

// Circular buffer storage
reg                     sb_valid    [0:SB_DEPTH-1];
reg [31:0]              sb_addr     [0:SB_DEPTH-1];
reg [31:0]              sb_data     [0:SB_DEPTH-1];
reg [2:0]               sb_func3    [0:SB_DEPTH-1];
reg [ORDER_ID_W-1:0]    sb_order_id [0:SB_DEPTH-1];
reg [EPOCH_W-1:0]       sb_epoch    [0:SB_DEPTH-1];
reg                     sb_committed[0:SB_DEPTH-1];

// ROB commit can arrive before the corresponding store has reached this
// buffer once MEM issue is no longer branch-order gated.  Keep that retire
// permission until the late store enqueue shows up.
reg                     pending_commit_valid[0:SB_DEPTH-1];
reg [ORDER_ID_W-1:0]    pending_commit_order[0:SB_DEPTH-1];

// Head/tail pointers
reg  [SB_IDX_W-1:0]     sb_head;    // Drain pointer (oldest)
reg  [SB_IDX_W-1:0]     sb_tail;    // Allocate pointer (next free)
reg  [SB_IDX_W:0]       sb_count;   // Occupancy count

// ═════════════════════════════════════════════════════════════════════════════
// Full/Empty Status
// ═════════════════════════════════════════════════════════════════════════════

wire sb_full  = (sb_count >= SB_DEPTH);
wire sb_empty = (sb_count == 0);

assign sb_stall_event = sb_full;

assign sb_drain_urgent = (can_drain && sb_issue_full);

`ifdef ENABLE_MEM_SUBSYS
localparam [SB_IDX_W:0] SB_ACTIVE_LIMIT = {{SB_IDX_W{1'b0}}, 1'b1};
`else
localparam [SB_IDX_W:0] SB_ACTIVE_LIMIT = (SB_DEPTH - 1);
`endif
wire sb_issue_full = (sb_count >= SB_ACTIVE_LIMIT);

// Note: We always indicate capacity status regardless of store_req_valid
// to avoid combinational loops with the LSU shell.
assign store_req_accept = !sb_issue_full;

// Stores can execute out of program order. Allocate into any free slot, then
// drain the oldest valid entry by order_id rather than the physical FIFO head.
reg [SB_IDX_W-1:0] alloc_idx_r;
reg                alloc_slot_found_r;
reg [SB_IDX_W-1:0] drain_idx_r;
reg                oldest_valid_r;
reg [ORDER_ID_W-1:0] oldest_order_r;
reg                older_pending_commit_r;

integer sel_i;
integer pend_i;
always @(*) begin
    alloc_idx_r = {SB_IDX_W{1'b0}};
    alloc_slot_found_r = 1'b0;
    drain_idx_r = {SB_IDX_W{1'b0}};
    oldest_valid_r = 1'b0;
    oldest_order_r = {ORDER_ID_W{1'b1}};
    older_pending_commit_r = 1'b0;

    for (sel_i = 0; sel_i < SB_DEPTH; sel_i = sel_i + 1) begin
        if (!alloc_slot_found_r && !sb_valid[sel_i]) begin
            alloc_idx_r = sel_i[SB_IDX_W-1:0];
            alloc_slot_found_r = 1'b1;
        end
        if (sb_valid[sel_i] &&
            (!oldest_valid_r || (sb_order_id[sel_i] < oldest_order_r))) begin
            drain_idx_r = sel_i[SB_IDX_W-1:0];
            oldest_valid_r = 1'b1;
            oldest_order_r = sb_order_id[sel_i];
        end
    end

    for (pend_i = 0; pend_i < SB_DEPTH; pend_i = pend_i + 1) begin
        if (oldest_valid_r &&
            pending_commit_valid[pend_i] &&
            (pending_commit_order[pend_i] < oldest_order_r)) begin
            older_pending_commit_r = 1'b1;
        end
    end
end

wire store_flush_kill =
    flush &&
    (!flush_order_valid || (store_order_id > flush_order_id));
wire store_alloc_fire = store_req_valid && store_req_accept && !store_flush_kill;
wire commit0_flush_kill =
    flush &&
    (!flush_order_valid || (commit0_order_id > flush_order_id));

// ═════════════════════════════════════════════════════════════════════════════
// Drain Logic - Write oldest committed store to memory
// ═════════════════════════════════════════════════════════════════════════════

wire older_current_commit =
    oldest_valid_r &&
    commit0_valid && commit0_is_store && !commit0_flush_kill &&
    (commit0_order_id < oldest_order_r);

// Determine if a store is ready to drain.  A commit can arrive before the
// corresponding store reaches this buffer; in that case, hold younger valid
// stores back so MMIO side effects cannot pass the missing older store.
wire can_drain = oldest_valid_r && sb_committed[drain_idx_r] &&
                 !older_pending_commit_r && !older_current_commit;

wire drain_fire = can_drain && mem_write_ready;

// Generate byte-wise write enable from func3
reg [3:0] wen_from_func3;
wire [1:0] head_addr_offset = sb_addr[drain_idx_r][1:0];

always @(*) begin
    case (sb_func3[drain_idx_r])
        3'b000:  wen_from_func3 = 4'b0001 << head_addr_offset;  // SB
        3'b001:  wen_from_func3 = 4'b0011 << {head_addr_offset[1], 1'b0};  // SH
        3'b010:  wen_from_func3 = 4'b1111;  // SW
        default: wen_from_func3 = 4'b0000;
    endcase
end

// ═════════════════════════════════════════════════════════════════════════════
// Combinational Memory Interface
// ═════════════════════════════════════════════════════════════════════════════

always @(*) begin
    if (can_drain) begin
        mem_write_valid = 1'b1;
        mem_write_addr  = sb_addr[drain_idx_r];
        mem_write_data  = sb_data[drain_idx_r];
        mem_write_func3 = sb_func3[drain_idx_r];
        mem_write_wen   = wen_from_func3;
    end else begin
        mem_write_valid = 1'b0;
        mem_write_addr  = 32'd0;
        mem_write_data  = 32'd0;
        mem_write_func3 = 3'd0;
        mem_write_wen   = 4'b0000;
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// Store-to-Load Forwarding Logic
// ═════════════════════════════════════════════════════════════════════════════

// Function to compute store byte mask from func3 and address
function [3:0] store_byte_mask;
    input [2:0] func3;
    input [1:0] addr_offset;
    begin
        case (func3[1:0])
            2'b00:   store_byte_mask = 4'b0001 << addr_offset;  // SB
            2'b01:   store_byte_mask = 4'b0011 << {addr_offset[1], 1'b0};  // SH
            2'b10:   store_byte_mask = 4'b1111;  // SW
            default: store_byte_mask = 4'b0000;
        endcase
    end
endfunction

// Align store payload into the addressed byte lanes so both backing-memory
// writes and same-address forwarding see the architecturally correct word.
function [31:0] align_store_data;
    input [31:0] store_data_in;
    input [2:0] func3;
    input [1:0] addr_offset;
    begin
        case (func3[1:0])
            2'b00: begin
                case (addr_offset)
                    2'b00: align_store_data = {24'd0, store_data_in[7:0]};
                    2'b01: align_store_data = {16'd0, store_data_in[7:0], 8'd0};
                    2'b10: align_store_data = {8'd0, store_data_in[7:0], 16'd0};
                    2'b11: align_store_data = {store_data_in[7:0], 24'd0};
                    default: align_store_data = 32'd0;
                endcase
            end
            2'b01: begin
                case (addr_offset[1])
                    1'b0: align_store_data = {16'd0, store_data_in[15:0]};
                    1'b1: align_store_data = {store_data_in[15:0], 16'd0};
                    default: align_store_data = 32'd0;
                endcase
            end
            2'b10: align_store_data = store_data_in;
            default: align_store_data = 32'd0;
        endcase
    end
endfunction

// Function to compute load byte mask from func3 and address
function [3:0] load_byte_mask;
    input [2:0] func3;
    input [1:0] addr_offset;
    begin
        case (func3[2:0])
            `LB, `LBU: load_byte_mask = 4'b0001 << addr_offset;
            `LH, `LHU: load_byte_mask = 4'b0011 << {addr_offset[1], 1'b0};
            `LW:       load_byte_mask = 4'b1111;
            default:   load_byte_mask = 4'b0000;
        endcase
    end
endfunction

// Check if store fully covers the load (conservative: exact match only)
// For exact match: store address must match load address
// AND store size must be >= load size
function store_covers_load;
    input [2:0] store_func3;
    input [2:0] load_func3;
    input [31:0] store_addr;
    input [31:0] load_addr;
    begin
        // Exact address match required for forwarding
        if (store_addr != load_addr) begin
            store_covers_load = 1'b0;
        end else begin
            // Same address: check if store size >= load size
            // SB=byte(0), SH=half(1), SW=word(2)
            // Load size encoded similarly
            store_covers_load = (store_func3[1:0] >= load_func3[1:0]);
        end
    end
endfunction

// Combinational forwarding search logic
integer fwd_i;
reg [31:0] fwd_data_r;
reg        fwd_valid_r;
reg        hazard_r;
reg        found_match_r;
reg        older_store_pending_r;
reg [ORDER_ID_W-1:0] match_order_id_r;
reg [3:0]  load_mask;

always @(*) begin
    // Default outputs
    fwd_data_r = 32'd0;
    fwd_valid_r = 1'b0;
    hazard_r = 1'b0;
    found_match_r = 1'b0;
    older_store_pending_r = 1'b0;
    match_order_id_r = {ORDER_ID_W{1'b0}};
    load_mask = load_byte_mask(load_query_func3, load_query_addr[1:0]);

    if (load_query_valid) begin
        // Search all entries
        for (fwd_i = 0; fwd_i < SB_DEPTH; fwd_i = fwd_i + 1) begin
            if (sb_valid[fwd_i]) begin
                // Check if this store is older than the load (smaller order_id)
                // order_ids are monotonically increasing
                if (sb_order_id[fwd_i] < load_query_order_id) begin
                    older_store_pending_r = 1'b1;
                    // Check address match
                    if (sb_addr[fwd_i] == load_query_addr) begin
                        // Same address: check coverage
                        if (store_covers_load(sb_func3[fwd_i],
                                               load_query_func3,
                                               sb_addr[fwd_i],
                                               load_query_addr)) begin
                            // This store covers the load - track youngest matching
                            if (!found_match_r ||
                                (sb_order_id[fwd_i] > match_order_id_r)) begin
                                found_match_r = 1'b1;
                                match_order_id_r = sb_order_id[fwd_i];
                                // Extract data based on store func3
                                fwd_data_r = sb_data[fwd_i];
                            end
                        end else begin
                            // Same address but store doesn't fully cover load
                            // This is a partial overlap - signal hazard
                            hazard_r = 1'b1;
                        end
                    end
                    // else: different address - no forwarding, no hazard

                    // Check for unresolved older store that cannot be forwarded.
                    // For same address: allow forwarding from uncommitted store (found_match_r handles this)
                    // For different address: only hazard if uncommitted AND older than any matching store
                    if (!sb_committed[fwd_i] &&
                        (sb_addr[fwd_i] != load_query_addr)) begin
                        // Different address: hazard only if this store is older than
                        // the youngest matching store we found (if any)
                        if (!found_match_r ||
                            (sb_order_id[fwd_i] < match_order_id_r)) begin
                            hazard_r = 1'b1;
                        end
                    end
                    // Note: Same-address uncommitted stores are handled by found_match_r logic above.
                    // If store_covers_load is true, found_match_r is set and forwarding is allowed.
                end
                // else: store is younger than load - ignore for forwarding
            end
        end

        // Forwarding valid only if we found a match AND no hazard
        if (found_match_r && !hazard_r) begin
            fwd_valid_r = 1'b1;
        end
    end
end

// Output assignments
assign forward_data = fwd_data_r;
assign forward_valid = fwd_valid_r;
assign load_hazard = hazard_r;
assign older_store_pending_for_load = older_store_pending_r;
assign debug_empty = sb_empty;
assign debug_count_t0 = sb_count;

// ═════════════════════════════════════════════════════════════════════════════
// Sequential Logic - Single Next-State Calculation
// ═════════════════════════════════════════════════════════════════════════════

integer j;
reg [EPOCH_W-1:0] flush_expected_epoch;
reg [EPOCH_W-1:0] alloc_expected_epoch;

// Next-state registers for single-cycle update
reg [SB_IDX_W-1:0]  sb_head_next;
reg [SB_IDX_W-1:0]  sb_tail_next;
reg [SB_IDX_W:0]    sb_count_next;
reg                 sb_valid_next [0:SB_DEPTH-1];
reg                 sb_committed_next[0:SB_DEPTH-1];
reg                 pending_commit_valid_next[0:SB_DEPTH-1];
reg [ORDER_ID_W-1:0] pending_commit_order_next[0:SB_DEPTH-1];
reg                 alloc_committed;
reg                 commit_marked;
reg                 pending_stored;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        // Reset all entries
        sb_head  <= {SB_IDX_W{1'b0}};
        sb_tail  <= {SB_IDX_W{1'b0}};
        sb_count <= {(SB_IDX_W+1){1'b0}};
        for (j = 0; j < SB_DEPTH; j = j + 1) begin
            sb_valid[j]     <= 1'b0;
            sb_addr[j]      <= 32'd0;
            sb_data[j]      <= 32'd0;
            sb_func3[j]     <= 3'd0;
            sb_order_id[j]  <= {ORDER_ID_W{1'b0}};
            sb_epoch[j]     <= {EPOCH_W{1'b0}};
            sb_committed[j] <= 1'b0;
            pending_commit_valid[j] <= 1'b0;
            pending_commit_order[j] <= {ORDER_ID_W{1'b0}};
        end
    end else begin
        // ── Single Next-State Calculation ──────────────────────

        // Initialize next-state from current state
        sb_head_next  = sb_head;
        sb_tail_next  = sb_tail;
        sb_count_next = sb_count;
        for (j = 0; j < SB_DEPTH; j = j + 1) begin
            sb_valid_next[j]     = sb_valid[j];
            sb_committed_next[j] = sb_committed[j];
            pending_commit_valid_next[j] = pending_commit_valid[j];
            pending_commit_order_next[j] = pending_commit_order[j];
        end

        // ── Flush Handling ─────────────────────────────────────
        // Mark entries with mismatched epoch as invalid and repair occupancy
        if (flush) begin
            flush_expected_epoch = flush_new_epoch_t0;

            // Branch redirects only discard younger wrong-path stores. Trap/
            // global flushes discard speculative stores from the old epoch,
            // but must preserve already-committed entries so handler-side MMIO
            // writes can still drain before/after MRET.
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                if (sb_valid_next[j] &&
                    (flush_order_valid ? (sb_order_id[j] > flush_order_id)
                                      : !sb_committed_next[j])) begin
                    sb_valid_next[j] = 1'b0;
                    sb_committed_next[j] = 1'b0;
                end
                if (flush_order_valid &&
                    pending_commit_valid_next[j] &&
                    (pending_commit_order_next[j] > flush_order_id)) begin
                    pending_commit_valid_next[j] = 1'b0;
                    pending_commit_order_next[j] = {ORDER_ID_W{1'b0}};
                end
            end

            // Recalculate count after flush
            sb_count_next = 0;
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                if (sb_valid_next[j])
                    sb_count_next = sb_count_next + 1;
            end

            if (sb_count_next == 0)
                sb_head_next = sb_tail_next;
        end

        // ── Store Allocation ───────────────────────────────────
        // Accept new store into buffer.
        // During a partial flush (branch redirect), only block stores that
        // are YOUNGER than the flush point (wrong-path). Correct-path stores
        // (older than the flush) must still be enqueued or they'll be lost.
        // During a global flush (!flush_order_valid), block all stores from
        // the flushed thread.
        alloc_expected_epoch = current_epoch_t0;
        if (store_alloc_fire) begin
            alloc_committed = commit0_valid && commit0_is_store &&
                              !commit0_flush_kill &&
                              (commit0_order_id == store_order_id);
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                if (pending_commit_valid_next[j] &&
                    (pending_commit_order_next[j] == store_order_id)) begin
                    alloc_committed = 1'b1;
                    pending_commit_valid_next[j] = 1'b0;
                    pending_commit_order_next[j] = {ORDER_ID_W{1'b0}};
                end
            end
            sb_valid_next[alloc_idx_r]     = 1'b1;
            sb_addr[alloc_idx_r]      <= store_addr;
            sb_data[alloc_idx_r]      <= align_store_data(store_data, store_func3, store_addr[1:0]);
            sb_func3[alloc_idx_r]     <= store_func3;
            sb_order_id[alloc_idx_r]  <= store_order_id;
            sb_epoch[alloc_idx_r]     <= store_epoch;
            sb_committed_next[alloc_idx_r] = alloc_committed;
            sb_count_next = sb_count_next + 1;
            `ifdef VERBOSE_SIM_LOGS
            $display("[SB ENQ] order=%0d addr=%h data=%h func3=%0d",
                     store_order_id, store_addr, store_data, store_func3);
            `endif
        end else if (store_req_valid && store_req_accept) begin
            `ifdef VERBOSE_SIM_LOGS
            $display("[SB DROP] order=%0d addr=%h data=%h func3=%0d epoch=%0d expected=%0d flush=%0b flush_order_valid=%0b flush_order=%0d",
                     store_order_id, store_addr, store_data, store_func3,
                     store_epoch, alloc_expected_epoch,
                     flush, flush_order_valid, flush_order_id);
            `endif
        end

        // ── Commit Processing ──────────────────────────────────
        // Mark stores as committed when ROB signals

        if (commit0_valid && commit0_is_store && !commit0_flush_kill) begin
            commit_marked = store_alloc_fire &&
                            (store_order_id == commit0_order_id);
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                if (sb_valid_next[j] && !sb_committed_next[j] &&
                    (sb_order_id[j] == commit0_order_id)) begin
                    sb_committed_next[j] = 1'b1;
                    commit_marked = 1'b1;
                    `ifdef VERBOSE_SIM_LOGS
                    $display("[SB COMMIT] order=%0d idx=%0d addr=%h",
                             commit0_order_id, j, sb_addr[j]);
                    `endif
                end
            end
            if (!commit_marked) begin
                pending_stored = 1'b0;
                for (j = 0; j < SB_DEPTH; j = j + 1) begin
                    if (!pending_stored && !pending_commit_valid_next[j]) begin
                        pending_commit_valid_next[j] = 1'b1;
                        pending_commit_order_next[j] = commit0_order_id;
                        pending_stored = 1'b1;
                    end
                end
            end
        end

        // ── Store Drain ─────────────────────────────────────────
        // Remove drained stores from buffer
        if (drain_fire) begin
            `ifdef VERBOSE_SIM_LOGS
            $display("[SB DRAIN] order=%0d addr=%h data=%h wen=%b",
                     sb_order_id[drain_idx_r], sb_addr[drain_idx_r],
                     sb_data[drain_idx_r], mem_write_wen);
            `endif
            sb_valid_next[drain_idx_r] = 1'b0;  // Deallocate
            sb_committed_next[drain_idx_r] = 1'b0;
            sb_count_next = sb_count_next - 1;
        end

        // ── Apply Next-State ───────────────────────────────────
        sb_head  <= sb_head_next;
        sb_tail  <= sb_tail_next;
        sb_count <= sb_count_next;
        for (j = 0; j < SB_DEPTH; j = j + 1) begin
            sb_valid[j]     <= sb_valid_next[j];
            sb_committed[j] <= sb_committed_next[j];
            pending_commit_valid[j] <= pending_commit_valid_next[j];
            pending_commit_order[j] <= pending_commit_order_next[j];
        end
    end
end

endmodule
