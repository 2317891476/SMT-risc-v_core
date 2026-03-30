// =============================================================================
// Module : store_buffer
// Description: Per-thread Store Buffer with commit-gated drain and wrong-path discard
//
//   - Buffers speculative store requests from LSU shell
//   - Stores complete speculatively for scoreboard/ROB tracking
//   - Drains to memory only when ROB signals commit for that store
//   - Discards wrong-path stores on flush (epoch mismatch)
//   - Maintains per-thread FIFO order for in-order drain
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
    parameter SB_DEPTH      = 4,        // Entries per thread (power of 2)
    parameter SB_IDX_W      = 2,        // log2(SB_DEPTH)
    parameter ORDER_ID_W    = 16,       // Match METADATA_ORDER_ID_W
    parameter EPOCH_W       = 8,        // Match METADATA_EPOCH_W
    parameter NUM_THREAD    = 2
)(
    input  wire                     clk,
    input  wire                     rstn,

    // ─── Flush Interface ─────────────────────────────────────────
    input  wire                     flush,
    input  wire [0:0]               flush_tid,
    input  wire [EPOCH_W-1:0]       flush_new_epoch_t0,  // Expected epoch after flush
    input  wire [EPOCH_W-1:0]       flush_new_epoch_t1,
    input  wire                     flush_order_valid,   // 1 for branch redirect, 0 for trap/global flush
    input  wire [ORDER_ID_W-1:0]    flush_order_id,

    // ═══════════════════════════════════════════════════════════════════════════
    // Store Request Interface (from LSU shell)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire                     store_req_valid,     // Store request valid
    output wire                     store_req_accept,    // Store buffer can accept

    input  wire [0:0]               store_tid,
    input  wire [ORDER_ID_W-1:0]    store_order_id,
    input  wire [EPOCH_W-1:0]       store_epoch,
    input  wire [31:0]              store_addr,
    input  wire [31:0]              store_data,
    input  wire [2:0]               store_func3,         // SB/SH/SW encoding

    // ═══════════════════════════════════════════════════════════════════════════
    // ROB Commit Interface (for drain authorization)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire                     commit0_valid,       // Thread 0 commit
    input  wire                     commit1_valid,       // Thread 1 commit
    input  wire [ORDER_ID_W-1:0]    commit0_order_id,    // Thread 0 committing order_id
    input  wire [ORDER_ID_W-1:0]    commit1_order_id,    // Thread 1 committing order_id
    input  wire                     commit0_is_store,    // Thread 0 committing store
    input  wire                     commit1_is_store,    // Thread 1 committing store

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
    input  wire [0:0]               load_query_tid,      // Thread ID for load
    input  wire [ORDER_ID_W-1:0]    load_query_order_id, // Load's order_id (for age check)
    input  wire [31:0]              load_query_addr,     // Load address
    input  wire [2:0]               load_query_func3,    // Load type (LB/LH/LW/LBU/LHU)

    output wire [31:0]              forward_data,        // Forwarded data (if exact match)
    output wire                     forward_valid,       // Forward data is valid
    output wire                     load_hazard          // Stall: unresolved/partial overlap
);

// ═════════════════════════════════════════════════════════════════════════════
// Per-Thread Store Buffer State
// ═════════════════════════════════════════════════════════════════════════════

// Circular buffer storage for each thread
reg                     sb_valid    [0:NUM_THREAD-1][0:SB_DEPTH-1];
reg [31:0]              sb_addr     [0:NUM_THREAD-1][0:SB_DEPTH-1];
reg [31:0]              sb_data     [0:NUM_THREAD-1][0:SB_DEPTH-1];
reg [2:0]               sb_func3    [0:NUM_THREAD-1][0:SB_DEPTH-1];
reg [ORDER_ID_W-1:0]    sb_order_id [0:NUM_THREAD-1][0:SB_DEPTH-1];
reg [EPOCH_W-1:0]       sb_epoch    [0:NUM_THREAD-1][0:SB_DEPTH-1];
reg                     sb_committed[0:NUM_THREAD-1][0:SB_DEPTH-1];

// Head/tail pointers per thread
reg  [SB_IDX_W-1:0]     sb_head     [0:NUM_THREAD-1];  // Drain pointer (oldest)
reg  [SB_IDX_W-1:0]     sb_tail     [0:NUM_THREAD-1];  // Allocate pointer (next free)
reg  [SB_IDX_W:0]       sb_count    [0:NUM_THREAD-1];  // Occupancy count

// ═════════════════════════════════════════════════════════════════════════════
// Full/Empty Status
// ═════════════════════════════════════════════════════════════════════════════

wire sb_full_t0  = (sb_count[0] >= SB_DEPTH);
wire sb_full_t1  = (sb_count[1] >= SB_DEPTH);
wire sb_empty_t0 = (sb_count[0] == 0);
wire sb_empty_t1 = (sb_count[1] == 0);

// Accept new stores if not full for that thread
// Note: We always indicate capacity status regardless of store_req_valid
// to avoid combinational loops with the LSU shell
assign store_req_accept = store_tid ? !sb_full_t1 : !sb_full_t0;

// ═════════════════════════════════════════════════════════════════════════════
// Drain Logic - Write oldest committed store to memory
// ═════════════════════════════════════════════════════════════════════════════

// Determine which thread has a store ready to drain
// Priority: Thread 0 > Thread 1 (simple arbitration)
wire t0_can_drain = !sb_empty_t0 && sb_valid[0][sb_head[0]] && 
                     sb_committed[0][sb_head[0]];
wire t1_can_drain = !sb_empty_t1 && sb_valid[1][sb_head[1]] && 
                     sb_committed[1][sb_head[1]];

wire drain_sel_t0  = t0_can_drain;
wire drain_sel_t1  = !t0_can_drain && t1_can_drain;
wire drain_fire_t0 = drain_sel_t0 && mem_write_ready;
wire drain_fire_t1 = drain_sel_t1 && mem_write_ready;

// Generate byte-wise write enable from func3
reg [3:0] wen_from_func3_t0;
reg [3:0] wen_from_func3_t1;
wire [1:0] t0_addr_offset = sb_addr[0][sb_head[0]][1:0];
wire [1:0] t1_addr_offset = sb_addr[1][sb_head[1]][1:0];

always @(*) begin
    case (sb_func3[0][sb_head[0]])
        3'b000:  wen_from_func3_t0 = 4'b0001 << t0_addr_offset;  // SB
        3'b001:  wen_from_func3_t0 = 4'b0011 << {t0_addr_offset[1], 1'b0};  // SH
        3'b010:  wen_from_func3_t0 = 4'b1111;  // SW
        default: wen_from_func3_t0 = 4'b0000;
    endcase
end

always @(*) begin
    case (sb_func3[1][sb_head[1]])
        3'b000:  wen_from_func3_t1 = 4'b0001 << t1_addr_offset;  // SB
        3'b001:  wen_from_func3_t1 = 4'b0011 << {t1_addr_offset[1], 1'b0};  // SH
        3'b010:  wen_from_func3_t1 = 4'b1111;  // SW
        default: wen_from_func3_t1 = 4'b0000;
    endcase
end

// ═════════════════════════════════════════════════════════════════════════════
// Combinational Memory Interface
// ═════════════════════════════════════════════════════════════════════════════

always @(*) begin
    if (drain_sel_t0) begin
        mem_write_valid = 1'b1;
        mem_write_addr  = sb_addr[0][sb_head[0]];
        mem_write_data  = sb_data[0][sb_head[0]];
        mem_write_func3 = sb_func3[0][sb_head[0]];
        mem_write_wen   = wen_from_func3_t0;
    end else if (drain_sel_t1) begin
        mem_write_valid = 1'b1;
        mem_write_addr  = sb_addr[1][sb_head[1]];
        mem_write_data  = sb_data[1][sb_head[1]];
        mem_write_func3 = sb_func3[1][sb_head[1]];
        mem_write_wen   = wen_from_func3_t1;
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
reg [ORDER_ID_W-1:0] match_order_id_r;
reg [3:0]  load_mask;

always @(*) begin
    // Default outputs
    fwd_data_r = 32'd0;
    fwd_valid_r = 1'b0;
    hazard_r = 1'b0;
    found_match_r = 1'b0;
    match_order_id_r = {ORDER_ID_W{1'b0}};
    load_mask = load_byte_mask(load_query_func3, load_query_addr[1:0]);

    if (load_query_valid) begin
        // Search all entries for this thread
        for (fwd_i = 0; fwd_i < SB_DEPTH; fwd_i = fwd_i + 1) begin
            if (sb_valid[load_query_tid][fwd_i]) begin
                // Check if this store is older than the load (smaller order_id)
                // order_ids are monotonically increasing per thread
                if (sb_order_id[load_query_tid][fwd_i] < load_query_order_id) begin
                    // Check address match
                    if (sb_addr[load_query_tid][fwd_i] == load_query_addr) begin
                        // Same address: check coverage
                        if (store_covers_load(sb_func3[load_query_tid][fwd_i], 
                                               load_query_func3,
                                               sb_addr[load_query_tid][fwd_i],
                                               load_query_addr)) begin
                            // This store covers the load - track youngest matching
                            if (!found_match_r || 
                                (sb_order_id[load_query_tid][fwd_i] > match_order_id_r)) begin
                                found_match_r = 1'b1;
                                match_order_id_r = sb_order_id[load_query_tid][fwd_i];
                                // Extract data based on store func3
                                fwd_data_r = sb_data[load_query_tid][fwd_i];
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
                    if (!sb_committed[load_query_tid][fwd_i] &&
                        (sb_addr[load_query_tid][fwd_i] != load_query_addr)) begin
                        // Different address: hazard only if this store is older than
                        // the youngest matching store we found (if any)
                        if (!found_match_r ||
                            (sb_order_id[load_query_tid][fwd_i] < match_order_id_r)) begin
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

// ═════════════════════════════════════════════════════════════════════════════
// Sequential Logic - Single Next-State Calculation
// ═════════════════════════════════════════════════════════════════════════════

integer t, j, k;
reg [EPOCH_W-1:0] flush_expected_epoch;

// Next-state registers for single-cycle update
reg [SB_IDX_W-1:0]  sb_head_next  [0:NUM_THREAD-1];
reg [SB_IDX_W-1:0]  sb_tail_next  [0:NUM_THREAD-1];
reg [SB_IDX_W:0]    sb_count_next [0:NUM_THREAD-1];
reg                 sb_valid_next [0:NUM_THREAD-1][0:SB_DEPTH-1];
reg                 sb_committed_next[0:NUM_THREAD-1][0:SB_DEPTH-1];

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        // Reset all entries
        for (t = 0; t < NUM_THREAD; t = t + 1) begin
            sb_head[t]  <= {SB_IDX_W{1'b0}};
            sb_tail[t]  <= {SB_IDX_W{1'b0}};
            sb_count[t] <= {(SB_IDX_W+1){1'b0}};
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                sb_valid[t][j]     <= 1'b0;
                sb_addr[t][j]      <= 32'd0;
                sb_data[t][j]      <= 32'd0;
                sb_func3[t][j]     <= 3'd0;
                sb_order_id[t][j]  <= {ORDER_ID_W{1'b0}};
                sb_epoch[t][j]     <= {EPOCH_W{1'b0}};
                sb_committed[t][j] <= 1'b0;
            end
        end
    end else begin
        // ── Single Next-State Calculation ──────────────────────
        
        // Initialize next-state from current state
        for (t = 0; t < NUM_THREAD; t = t + 1) begin
            sb_head_next[t]  = sb_head[t];
            sb_tail_next[t]  = sb_tail[t];
            sb_count_next[t] = sb_count[t];
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                sb_valid_next[t][j]     = sb_valid[t][j];
                sb_committed_next[t][j] = sb_committed[t][j];
            end
        end
        
        // ── Flush Handling ─────────────────────────────────────
        // Mark entries with mismatched epoch as invalid and repair occupancy
        if (flush) begin
            flush_expected_epoch = flush_tid ? flush_new_epoch_t1 : flush_new_epoch_t0;
            
            // Branch redirects only discard younger wrong-path stores. Trap/
            // global flushes discard speculative stores from the old epoch,
            // but must preserve already-committed entries so handler-side MMIO
            // writes can still drain before/after MRET.
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                if (sb_valid_next[flush_tid][j] && 
                    (sb_epoch[flush_tid][j] != flush_expected_epoch) &&
                    (flush_order_valid ? (sb_order_id[flush_tid][j] > flush_order_id)
                                      : !sb_committed_next[flush_tid][j])) begin
                    sb_valid_next[flush_tid][j] = 1'b0;
                    sb_committed_next[flush_tid][j] = 1'b0;
                end
            end
            
            // Recalculate count after flush
            sb_count_next[flush_tid] = 0;
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                if (sb_valid_next[flush_tid][j])
                    sb_count_next[flush_tid] = sb_count_next[flush_tid] + 1;
            end

            if (sb_count_next[flush_tid] == 0)
                sb_head_next[flush_tid] = sb_tail_next[flush_tid];
        end

        // ── Store Allocation ───────────────────────────────────
        // Accept new store into buffer (only if not flushing same cycle)
        if (store_req_valid && store_req_accept && !(flush && (store_tid == flush_tid))) begin
            if (store_tid == 1'b0) begin
                sb_valid_next[0][sb_tail_next[0]]     = 1'b1;
                sb_addr[0][sb_tail_next[0]]      <= store_addr;
                sb_data[0][sb_tail_next[0]]      <= align_store_data(store_data, store_func3, store_addr[1:0]);
                sb_func3[0][sb_tail_next[0]]     <= store_func3;
                sb_order_id[0][sb_tail_next[0]]  <= store_order_id;
                sb_epoch[0][sb_tail_next[0]]     <= store_epoch;
                sb_committed_next[0][sb_tail_next[0]] = 1'b0;  // Never commit on allocation
                sb_tail_next[0] = sb_tail_next[0] + 1;
                sb_count_next[0] = sb_count_next[0] + 1;
            end else begin
                sb_valid_next[1][sb_tail_next[1]]     = 1'b1;
                sb_addr[1][sb_tail_next[1]]      <= store_addr;
                sb_data[1][sb_tail_next[1]]      <= align_store_data(store_data, store_func3, store_addr[1:0]);
                sb_func3[1][sb_tail_next[1]]     <= store_func3;
                sb_order_id[1][sb_tail_next[1]]  <= store_order_id;
                sb_epoch[1][sb_tail_next[1]]     <= store_epoch;
                sb_committed_next[1][sb_tail_next[1]] = 1'b0;  // Never commit on allocation
                sb_tail_next[1] = sb_tail_next[1] + 1;
                sb_count_next[1] = sb_count_next[1] + 1;
            end
            `ifndef SYNTHESIS
            $display("[SB ENQ] tid=%0d order=%0d addr=%h data=%h func3=%0d",
                     store_tid, store_order_id, store_addr, store_data, store_func3);
            `endif
        end

        // ── Commit Processing ──────────────────────────────────
        // Mark stores as committed when ROB signals
        
        // Thread 0 commit
        if (commit0_valid && commit0_is_store) begin
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                if (sb_valid_next[0][j] && !sb_committed_next[0][j] &&
                    (sb_order_id[0][j] == commit0_order_id)) begin
                    sb_committed_next[0][j] = 1'b1;
                    `ifndef SYNTHESIS
                    $display("[SB COMMIT] tid=0 order=%0d idx=%0d addr=%h",
                             commit0_order_id, j, sb_addr[0][j]);
                    `endif
                end
            end
        end

        // Thread 1 commit
        if (commit1_valid && commit1_is_store) begin
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                if (sb_valid_next[1][j] && !sb_committed_next[1][j] &&
                    (sb_order_id[1][j] == commit1_order_id)) begin
                    sb_committed_next[1][j] = 1'b1;
                    `ifndef SYNTHESIS
                    $display("[SB COMMIT] tid=1 order=%0d idx=%0d addr=%h",
                             commit1_order_id, j, sb_addr[1][j]);
                    `endif
                end
            end
        end

        // ── Store Drain ─────────────────────────────────────────
        // Remove drained stores from buffer (T0 has priority)
        if (drain_fire_t0) begin
            `ifndef SYNTHESIS
            $display("[SB DRAIN] tid=0 order=%0d addr=%h data=%h wen=%b",
                     sb_order_id[0][sb_head_next[0]], sb_addr[0][sb_head_next[0]],
                     sb_data[0][sb_head_next[0]], mem_write_wen);
            `endif
            sb_valid_next[0][sb_head_next[0]] = 1'b0;  // Deallocate
            sb_committed_next[0][sb_head_next[0]] = 1'b0;
            sb_head_next[0] = sb_head_next[0] + 1;
            sb_count_next[0] = sb_count_next[0] - 1;
        end else if (drain_fire_t1) begin
            `ifndef SYNTHESIS
            $display("[SB DRAIN] tid=1 order=%0d addr=%h data=%h wen=%b",
                     sb_order_id[1][sb_head_next[1]], sb_addr[1][sb_head_next[1]],
                     sb_data[1][sb_head_next[1]], mem_write_wen);
            `endif
            sb_valid_next[1][sb_head_next[1]] = 1'b0;  // Deallocate
            sb_committed_next[1][sb_head_next[1]] = 1'b0;
            sb_head_next[1] = sb_head_next[1] + 1;
            sb_count_next[1] = sb_count_next[1] - 1;
        end
        
        // ── Apply Next-State ───────────────────────────────────
        for (t = 0; t < NUM_THREAD; t = t + 1) begin
            sb_head[t]  <= sb_head_next[t];
            sb_tail[t]  <= sb_tail_next[t];
            sb_count[t] <= sb_count_next[t];
            for (j = 0; j < SB_DEPTH; j = j + 1) begin
                sb_valid[t][j]     <= sb_valid_next[t][j];
                sb_committed[t][j] <= sb_committed_next[t][j];
            end
        end
    end
end

endmodule
