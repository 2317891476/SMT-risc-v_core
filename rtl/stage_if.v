// =============================================================================
// Module : stage_if
// Description: IF stage with BPU integration and fetch buffer output (single-thread).
//   - Fetches 1 instruction per cycle
//   - Integrates inst_memory (which now contains ICache with epoch tracking)
//   - Queries BPU for branch prediction alongside fetch
//   - Outputs to fetch_buffer for dual-issue decode
//   - Supports branch redirect and flush
//   - Implements stale response detection using epoch tracking
//
//   This module wraps: pc_mt (single-thread PC), inst_memory (with ICache), bpu_bimodal
// =============================================================================
module stage_if #(
    parameter USE_EXTERNAL_REFILL_STATIC = 0,
    parameter BPU_PHT_ENTRIES = 1024,
    parameter ICACHE_SIZE = 8192
)(
    input  wire        clk,
    input  wire        rstn,

    // ─── Stall / Flush ──────────────────────────────────────────
    input  wire        pc_stall,       // pipeline stall (from scoreboard full)
    input  wire        if_flush,       // single-thread flush
    input  wire        icache_invalidate,

    // ─── Branch redirect from EX stage ──────────────────────────
    input  wire [31:0] br_addr,        // branch target
    input  wire        br_ctrl,        // branch taken

    // ─── BPU update from EX stage ───────────────────────────────
    input  wire        bpu_update_valid,
    input  wire [31:0] bpu_update_pc,
    input  wire        bpu_update_taken,
    input  wire [31:0] bpu_update_target,
    input  wire        bpu_update_is_call,
    input  wire        bpu_update_is_return,

    // ─── Fetch buffer backpressure ──────────────────────────────
    input  wire        fb_ready,       // fetch buffer can accept

    // ─── Outputs to fetch buffer ────────────────────────────────
    output wire        if_valid,       // fetched instruction valid
    output wire [31:0] if_inst,        // instruction word
    output wire [31:0] if_pc,          // instruction PC
    output wire        if_pred_taken,  // BPU prediction for this instruction
    output wire [31:0] if_pred_target,

    // ─── External refill interface to mem_subsys (Task 5) ───────
    output wire        ext_mem_req_valid,
    input  wire        ext_mem_req_ready,
    output wire [31:0] ext_mem_req_addr,
    input  wire        ext_mem_resp_valid,
    input  wire [31:0] ext_mem_resp_data,
    input  wire        ext_mem_resp_last,
    output wire        ext_mem_resp_ready,
    output wire [31:0] ext_mem_bypass_addr,
    input  wire [31:0] ext_mem_bypass_data,
    input  wire        use_external_refill,

    // DDR3/XIP fetch debug summary
    output wire [31:0] debug_fetch_pc_pending,
    output wire [31:0] debug_pc_out,
    output wire [31:0] debug_if_inst,
    output wire [7:0]  debug_if_flags,
    output wire [7:0]  debug_ic_high_miss_count,
    output wire [7:0]  debug_ic_mem_req_count,
    output wire [7:0]  debug_ic_mem_resp_count,
    output wire [7:0]  debug_ic_cpu_resp_count,
    output wire [7:0]  debug_ic_state_flags,

    // HPM event
    output wire        icache_miss_event
);

// ─── PC management ──────────────────────────────────────────────────────────
wire [31:0] pc_out;
wire        resp_valid_from_mem;
wire        req_ready_from_mem;
wire        bpu_pred_taken;
wire [31:0] bpu_pred_target;

localparam FETCH_Q_DEPTH = 4;
localparam FETCH_Q_IDX_W = 2;

reg [31:0] meta_pc          [0:FETCH_Q_DEPTH-1];
reg        meta_pred_taken  [0:FETCH_Q_DEPTH-1];
reg [31:0] meta_pred_target [0:FETCH_Q_DEPTH-1];
reg        meta_valid       [0:FETCH_Q_DEPTH-1];
reg [FETCH_Q_IDX_W:0] meta_head;
reg [FETCH_Q_IDX_W:0] meta_tail;
reg [FETCH_Q_IDX_W:0] meta_count;

reg [31:0] resp_inst        [0:FETCH_Q_DEPTH-1];
reg [31:0] resp_pc          [0:FETCH_Q_DEPTH-1];
reg        resp_pred_taken  [0:FETCH_Q_DEPTH-1];
reg [31:0] resp_pred_target [0:FETCH_Q_DEPTH-1];
reg        resp_valid_q     [0:FETCH_Q_DEPTH-1];
reg [FETCH_Q_IDX_W:0] resp_head;
reg [FETCH_Q_IDX_W:0] resp_tail;
reg [FETCH_Q_IDX_W:0] resp_count;
reg [31:0]             fetch_bypass_addr_r;

wire [FETCH_Q_IDX_W-1:0] meta_head_idx = meta_head[FETCH_Q_IDX_W-1:0];
wire [FETCH_Q_IDX_W-1:0] meta_tail_idx = meta_tail[FETCH_Q_IDX_W-1:0];
wire [FETCH_Q_IDX_W-1:0] resp_head_idx = resp_head[FETCH_Q_IDX_W-1:0];
wire [FETCH_Q_IDX_W-1:0] resp_tail_idx = resp_tail[FETCH_Q_IDX_W-1:0];
wire                     meta_empty    = (meta_count == {(FETCH_Q_IDX_W+1){1'b0}});
wire                     meta_full     = (meta_count == FETCH_Q_DEPTH[FETCH_Q_IDX_W:0]);
wire                     resp_empty    = (resp_count == {(FETCH_Q_IDX_W+1){1'b0}});
wire                     resp_full     = (resp_count == FETCH_Q_DEPTH[FETCH_Q_IDX_W:0]);
wire                     if_valid_r    = !resp_empty && resp_valid_q[resp_head_idx];
wire                     output_consumed = if_valid_r && fb_ready;
wire                     resp_skip_invalid = !resp_empty && !resp_valid_q[resp_head_idx];
wire                     response_buffer_pop = output_consumed || resp_skip_invalid;
wire                     fetch_resp_done;
wire                     response_keep;
wire                     response_fifo_push;
wire                     meta_slot_available;
wire                     response_credit_available;
wire                     response_stale;
wire                     response_flushed;
wire [FETCH_Q_IDX_W+1:0] fetch_credits_used =
    {1'b0, meta_count} + {1'b0, resp_count};
wire [31:0] fetch_pc_pending;

// Keep request metadata in order so ICache hits can be pipelined.  The
// response FIFO absorbs fetch-buffer backpressure without losing one-cycle
// ICache response pulses.
wire pc_stall_combined;
assign fetch_resp_done = resp_valid_from_mem && !meta_empty;
assign meta_slot_available = !meta_full || fetch_resp_done;
assign response_keep = fetch_resp_done && meta_valid[meta_head_idx] &&
                       !response_stale && !response_flushed;
assign response_fifo_push = response_keep && (!resp_full || response_buffer_pop);
assign response_credit_available =
    (fetch_credits_used < FETCH_Q_DEPTH[FETCH_Q_IDX_W+1:0]) ||
    response_buffer_pop || (fetch_resp_done && !response_keep);
assign pc_stall_combined = pc_stall || !meta_slot_available ||
                           !response_credit_available || !req_ready_from_mem ||
                           if_flush || icache_invalidate;
wire fetch_req_launch = rstn && !pc_stall && meta_slot_available &&
                        response_credit_available && req_ready_from_mem &&
                        !if_flush && !icache_invalidate;
wire pc_advance = fetch_req_launch;
wire pred_ctrl  = fetch_req_launch ? bpu_pred_taken : 1'b0;

pc_mt u_pc_mt (
    .clk         (clk                 ),
    .rstn        (rstn                ),
    .br_ctrl     (br_ctrl             ),
    .br_addr     (br_addr             ),
    .pred_ctrl   (pred_ctrl           ),
    .pred_addr   (bpu_pred_target     ),
    .pc_stall    (pc_stall_combined   ),
    .pc_advance  (pc_advance          ),
    .if_pc       (pc_out              )
);

// ─── Epoch tracking ─────────────────────────────────────────────────────────
// Epoch is incremented on flush to track stale responses
reg [3:0] epoch;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        epoch <= 4'd0;
    end else begin
        if (if_flush)
            epoch <= epoch + 4'd1;
    end
end

// ─── Instruction memory (now with ICache) ───────────────────────────────────
// Note: inst_memory is a shared resource, do NOT reset on per-thread flush
wire [31:0] inst_from_mem;
wire [3:0]  resp_epoch_from_mem;
wire [7:0]  ic_high_miss_count_dbg;
wire [7:0]  ic_mem_req_count_dbg;
wire [7:0]  ic_mem_resp_count_dbg;
wire [7:0]  ic_cpu_resp_count_dbg;
wire [7:0]  ic_state_flags_dbg;

inst_memory #(
    .IROM_SPACE (4096),
    .ICACHE_SIZE(ICACHE_SIZE),
    .OMIT_BACKING_STORE(USE_EXTERNAL_REFILL_STATIC)
) u_inst_memory (
    .clk            (clk               ),
    .rstn           (rstn              ),
    .req_valid      (fetch_req_launch   ),
    .req_ready      (req_ready_from_mem ),
    .inst_addr      (pc_out            ),
    .inst_o         (inst_from_mem     ),
    .resp_epoch     (resp_epoch_from_mem),
    .resp_valid     (resp_valid_from_mem),
    .current_epoch  (epoch             ),
    .current_epoch_t0(epoch            ),
    .flush          (if_flush          ),
    .invalidate     (icache_invalidate ),

    // Task 5: External refill interface to mem_subsys M0
    .ext_mem_req_valid  (ext_mem_req_valid),
    .ext_mem_req_ready  (ext_mem_req_ready),
    .ext_mem_req_addr   (ext_mem_req_addr),
    .ext_mem_resp_valid (ext_mem_resp_valid),
    .ext_mem_resp_data  (ext_mem_resp_data),
    .ext_mem_resp_last  (ext_mem_resp_last),
    .ext_mem_resp_ready (ext_mem_resp_ready),
    .ext_mem_bypass_data(ext_mem_bypass_data),
    .use_external_refill(use_external_refill),
    .debug_ic_high_miss_count(ic_high_miss_count_dbg),
    .debug_ic_mem_req_count  (ic_mem_req_count_dbg),
    .debug_ic_mem_resp_count (ic_mem_resp_count_dbg),
    .debug_ic_cpu_resp_count (ic_cpu_resp_count_dbg),
    .debug_ic_state_flags    (ic_state_flags_dbg),
    .icache_miss_event       (icache_miss_event)
);

// ─── Branch prediction ──────────────────────────────────────────────────────
bpu_bimodal #(
    .PHT_ENTRIES (BPU_PHT_ENTRIES)
) u_bpu (
    .clk           (clk               ),
    .rstn          (rstn              ),
    // Prediction port
    .pred_pc       (pc_out            ),
    .pred_taken    (bpu_pred_taken    ),
    .pred_target   (bpu_pred_target   ),
    // Update port
    .update_valid  (bpu_update_valid  ),
    .update_pc     (bpu_update_pc     ),
    .update_taken  (bpu_update_taken  ),
    .update_target (bpu_update_target ),
    .update_is_call(bpu_update_is_call),
    .update_is_return(bpu_update_is_return)
);

// Bypass address needs to be delayed by 1 cycle to match mem_subsys RAM read latency
// When pc_out presents addr_N, mem_subsys reads ram[addr_N] and outputs data on next cycle
// So bypass_addr should be addr_N when bypass_data is for addr_N
assign response_stale = resp_valid_from_mem && (resp_epoch_from_mem != epoch);
assign response_flushed = resp_valid_from_mem && if_flush;

integer fetch_q_i;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        meta_head <= {(FETCH_Q_IDX_W+1){1'b0}};
        meta_tail <= {(FETCH_Q_IDX_W+1){1'b0}};
        meta_count <= {(FETCH_Q_IDX_W+1){1'b0}};
        resp_head <= {(FETCH_Q_IDX_W+1){1'b0}};
        resp_tail <= {(FETCH_Q_IDX_W+1){1'b0}};
        resp_count <= {(FETCH_Q_IDX_W+1){1'b0}};
        fetch_bypass_addr_r <= 32'd0;
        for (fetch_q_i = 0; fetch_q_i < FETCH_Q_DEPTH; fetch_q_i = fetch_q_i + 1) begin
            meta_pc[fetch_q_i]          <= 32'd0;
            meta_pred_taken[fetch_q_i]  <= 1'b0;
            meta_pred_target[fetch_q_i] <= 32'd0;
            meta_valid[fetch_q_i]       <= 1'b0;
            resp_inst[fetch_q_i]        <= 32'd0;
            resp_pc[fetch_q_i]          <= 32'd0;
            resp_pred_taken[fetch_q_i]  <= 1'b0;
            resp_pred_target[fetch_q_i] <= 32'd0;
            resp_valid_q[fetch_q_i]     <= 1'b0;
        end
    end
    else begin
        if (icache_invalidate) begin
            meta_head <= {(FETCH_Q_IDX_W+1){1'b0}};
            meta_tail <= {(FETCH_Q_IDX_W+1){1'b0}};
            meta_count <= {(FETCH_Q_IDX_W+1){1'b0}};
            resp_head <= {(FETCH_Q_IDX_W+1){1'b0}};
            resp_tail <= {(FETCH_Q_IDX_W+1){1'b0}};
            resp_count <= {(FETCH_Q_IDX_W+1){1'b0}};
            for (fetch_q_i = 0; fetch_q_i < FETCH_Q_DEPTH; fetch_q_i = fetch_q_i + 1) begin
                meta_valid[fetch_q_i] <= 1'b0;
                resp_valid_q[fetch_q_i] <= 1'b0;
            end
        end else if (if_flush) begin
            meta_head <= {(FETCH_Q_IDX_W+1){1'b0}};
            meta_tail <= {(FETCH_Q_IDX_W+1){1'b0}};
            meta_count <= {(FETCH_Q_IDX_W+1){1'b0}};
            for (fetch_q_i = 0; fetch_q_i < FETCH_Q_DEPTH; fetch_q_i = fetch_q_i + 1) begin
                meta_valid[fetch_q_i] <= 1'b0;
                if (resp_valid_q[fetch_q_i]) begin
                    resp_valid_q[fetch_q_i] <= 1'b0;
                end
            end
        end else begin
            if (fetch_resp_done) begin
                meta_valid[meta_head_idx] <= 1'b0;
                meta_head <= meta_head + {{FETCH_Q_IDX_W{1'b0}}, 1'b1};
            end

            if (fetch_req_launch) begin
                meta_pc[meta_tail_idx]          <= pc_out;
                meta_pred_taken[meta_tail_idx]  <= bpu_pred_taken;
                meta_pred_target[meta_tail_idx] <= bpu_pred_target;
                meta_valid[meta_tail_idx]       <= 1'b1;
                meta_tail <= meta_tail + {{FETCH_Q_IDX_W{1'b0}}, 1'b1};
                fetch_bypass_addr_r <= pc_out;
            end

            meta_count <= meta_count +
                          {{FETCH_Q_IDX_W{1'b0}}, fetch_req_launch} -
                          {{FETCH_Q_IDX_W{1'b0}}, fetch_resp_done};

            if (response_buffer_pop) begin
`ifdef VERBOSE_SIM_LOGS
                $display("[SIF_POP] head=%d inst=%h valid=%b @%0t",
                         resp_head_idx, resp_inst[resp_head_idx], resp_valid_q[resp_head_idx], $time);
`endif
                resp_valid_q[resp_head_idx] <= 1'b0;
                resp_head <= resp_head + {{FETCH_Q_IDX_W{1'b0}}, 1'b1};
            end

            if (response_fifo_push) begin
`ifdef VERBOSE_SIM_LOGS
                $display("[SIF_PUSH] inst_from_mem=%h resp_done=%b keep=%b stale=%b flushed=%b meta_valid=%b @%0t",
                         inst_from_mem, fetch_resp_done, response_keep, response_stale, response_flushed,
                         meta_valid[meta_head_idx], $time);
`endif
                resp_inst[resp_tail_idx]        <= inst_from_mem;
                resp_pc[resp_tail_idx]          <= meta_pc[meta_head_idx];
                resp_pred_taken[resp_tail_idx]  <= meta_pred_taken[meta_head_idx];
                resp_pred_target[resp_tail_idx] <= meta_pred_target[meta_head_idx];
                resp_valid_q[resp_tail_idx]     <= 1'b1;
                resp_tail <= resp_tail + {{FETCH_Q_IDX_W{1'b0}}, 1'b1};
            end

            resp_count <= resp_count +
                          {{FETCH_Q_IDX_W{1'b0}}, response_fifo_push} -
                          {{FETCH_Q_IDX_W{1'b0}}, response_buffer_pop};
        end
    end
end
assign fetch_pc_pending = !meta_empty ? meta_pc[meta_head_idx] : pc_out;
assign ext_mem_bypass_addr = fetch_bypass_addr_r;

// ─── Outputs ────────────────────────────────────────────────────────────────
// CRITICAL FIX: Synchronous RAM has 1-cycle latency
// - Cycle N: RAM receives address (pc_out), BPU makes prediction
// - Cycle N+1: RAM outputs instruction data, prediction must align
// All outputs must be delayed by 1 cycle to match RAM output timing.
//
// Additionally: Stale response detection
// - Response includes epoch from ICache
// - Drop response if epoch doesn't match current epoch (stale)
assign if_pc         = resp_pc[resp_head_idx];
assign if_valid      = if_valid_r;
assign if_inst       = resp_inst[resp_head_idx];
assign if_pred_taken = resp_pred_taken[resp_head_idx];
assign if_pred_target = resp_pred_target[resp_head_idx];
assign debug_fetch_pc_pending = fetch_pc_pending;
assign debug_pc_out           = pc_out;
assign debug_if_inst          = if_inst;
assign debug_if_flags         = {!meta_empty, fetch_req_launch, resp_valid_from_mem,
                                 if_valid_r, response_stale, use_external_refill,
                                 fetch_pc_pending[31], pc_out[31]};
assign debug_ic_high_miss_count = ic_high_miss_count_dbg;
assign debug_ic_mem_req_count   = ic_mem_req_count_dbg;
assign debug_ic_mem_resp_count  = ic_mem_resp_count_dbg;
assign debug_ic_cpu_resp_count  = ic_cpu_resp_count_dbg;
assign debug_ic_state_flags     = ic_state_flags_dbg;

endmodule
