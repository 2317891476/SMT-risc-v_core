// =============================================================================
// Module : stage_if_v2
// Description: Upgraded IF stage with BPU integration and fetch buffer output.
//   - Fetches 1 instruction per cycle from the selected thread (via scheduler)
//   - Integrates inst_memory (which now contains ICache with epoch tracking)
//   - Queries BPU for branch prediction alongside fetch
//   - Outputs to fetch_buffer for dual-issue decode
//   - Supports per-thread branch redirect and flush
//   - Implements stale response detection using epoch tracking
//
//   This module wraps: pc_mt (multi-thread PC), inst_memory (with ICache), bpu_bimodal
// =============================================================================
module stage_if_v2 (
    input  wire        clk,
    input  wire        rstn,

    // ─── Stall / Flush ──────────────────────────────────────────
    input  wire        pc_stall,       // pipeline stall (from scoreboard full)
    input  wire [1:0]  if_flush,       // [t] = flush thread t

    // ─── Branch redirect from EX stage ──────────────────────────
    input  wire [31:0] br_addr_t0,     // branch target for thread 0
    input  wire [31:0] br_addr_t1,     // branch target for thread 1
    input  wire [1:0]  br_ctrl,        // [t] = branch taken for thread t

    // ─── BPU update from EX stage ───────────────────────────────
    input  wire        bpu_update_valid,
    input  wire [31:0] bpu_update_pc,
    input  wire [0:0]  bpu_update_tid,
    input  wire        bpu_update_taken,
    input  wire [31:0] bpu_update_target,

    // ─── Thread scheduler ───────────────────────────────────────
    input  wire [0:0]  fetch_tid,

    // ─── Fetch buffer backpressure ──────────────────────────────
    input  wire        fb_ready,       // fetch buffer can accept

    // ─── Outputs to fetch buffer ────────────────────────────────
    output wire        if_valid,       // fetched instruction valid
    output wire [31:0] if_inst,        // instruction word
    output wire [31:0] if_pc,          // instruction PC
    output wire [0:0]  if_tid,         // thread ID
    output wire        if_pred_taken,  // BPU prediction for this instruction

    // ─── External refill interface to mem_subsys (Task 5) ───────
    output wire        ext_mem_req_valid,
    input  wire        ext_mem_req_ready,
    output wire [31:0] ext_mem_req_addr,
    input  wire        ext_mem_resp_valid,
    input  wire [31:0] ext_mem_resp_data,
    input  wire        ext_mem_resp_last,
    output wire        ext_mem_resp_ready,
    input  wire        use_external_refill
);

// ─── PC management ──────────────────────────────────────────────────────────
wire [31:0] pc_out;
wire [0:0]  tid_out;

// Stall PC when: pipeline stall OR fetch buffer full
wire pc_stall_combined;
assign pc_stall_combined = pc_stall || !fb_ready;

pc_mt #(
    .N_T             (2             ),
    .THREAD1_BOOT_PC (32'h00000800  )  // Thread 1 starts at 0x800 for SMT tests
) u_pc_mt (
    .clk         (clk                 ),
    .rstn        (rstn                ),
    .br_ctrl     (br_ctrl             ),
    .br_addr_t0  (br_addr_t0          ),
    .br_addr_t1  (br_addr_t1          ),
    .pc_stall    ({pc_stall_combined, pc_stall_combined}),
    .flush       (if_flush            ),
    .fetch_tid   (fetch_tid           ),
    .if_pc       (pc_out              ),
    .if_tid      (tid_out             )
);

// ─── Epoch tracking per thread ──────────────────────────────────────────────
// Epoch is incremented on flush per thread to track stale responses
reg [3:0] epoch_t0, epoch_t1;
wire [3:0] current_epoch = (fetch_tid == 1'b0) ? epoch_t0 : epoch_t1;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        epoch_t0 <= 4'd0;
        epoch_t1 <= 4'd0;
    end else begin
        // Increment epoch on flush per thread
        if (if_flush[0])
            epoch_t0 <= epoch_t0 + 4'd1;
        if (if_flush[1])
            epoch_t1 <= epoch_t1 + 4'd1;
    end
end

// ─── Instruction memory (now with ICache) ───────────────────────────────────
// Note: inst_memory is a shared resource, do NOT reset on per-thread flush
wire [31:0] inst_from_mem;
wire [0:0]  resp_tid_from_mem;
wire [3:0]  resp_epoch_from_mem;
wire        resp_valid_from_mem;

inst_memory #(
    .IROM_SPACE (4096)
) u_inst_memory (
    .clk            (clk               ),
    .rstn           (rstn              ),
    .inst_addr      (pc_out            ),
    .req_tid        (tid_out           ),
    .inst_o         (inst_from_mem     ),
    .resp_tid       (resp_tid_from_mem ),
    .resp_epoch     (resp_epoch_from_mem),
    .resp_valid     (resp_valid_from_mem),
    .current_epoch  (current_epoch     ),
    .flush          (|if_flush         ),

    // Task 5: External refill interface to mem_subsys M0
    .ext_mem_req_valid  (ext_mem_req_valid),
    .ext_mem_req_ready  (ext_mem_req_ready),
    .ext_mem_req_addr   (ext_mem_req_addr),
    .ext_mem_resp_valid (ext_mem_resp_valid),
    .ext_mem_resp_data  (ext_mem_resp_data),
    .ext_mem_resp_last  (ext_mem_resp_last),
    .ext_mem_resp_ready (ext_mem_resp_ready),
    .use_external_refill(use_external_refill)
);

// ─── Branch prediction ──────────────────────────────────────────────────────
wire bpu_pred_taken;

bpu_bimodal #(
    .PHT_ENTRIES (256)
) u_bpu (
    .clk           (clk               ),
    .rstn          (rstn              ),
    // Prediction port
    .pred_pc       (pc_out            ),
    .pred_tid      (tid_out           ),
    .pred_taken    (bpu_pred_taken    ),
    .pred_target   (/* unused for now, target comes from EX */),
    // Update port
    .update_valid  (bpu_update_valid  ),
    .update_pc     (bpu_update_pc     ),
    .update_tid    (bpu_update_tid    ),
    .update_taken  (bpu_update_taken  ),
    .update_target (bpu_update_target )
);

// ─── Outputs ────────────────────────────────────────────────────────────────
// CRITICAL FIX: Synchronous RAM has 1-cycle latency
// - Cycle N: RAM receives address (pc_out), BPU makes prediction
// - Cycle N+1: RAM outputs instruction data, prediction must align
// All outputs must be delayed by 1 cycle to match RAM output timing.
//
// Additionally: Stale response detection
// - Response includes {tid, epoch} from ICache
// - Drop response if epoch doesn't match current epoch (stale)
reg [31:0] pc_latched;
reg [0:0]  tid_latched;
reg        valid_latched;
reg        pred_taken_latched;
wire       fetch_in_progress;

assign fetch_in_progress = rstn && !pc_stall_combined;

// Stale response detection signals (registered to align with data)
reg [0:0]  resp_tid_latched;
reg [3:0]  resp_epoch_latched;
reg        resp_valid_latched;
reg        fetch_tid_latched;     // Thread that made the request

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        pc_latched         <= 32'd0;
        tid_latched        <= 1'b0;
        valid_latched      <= 1'b0;
        pred_taken_latched <= 1'b0;
        resp_tid_latched   <= 1'b0;
        resp_epoch_latched <= 4'd0;
        resp_valid_latched <= 1'b0;
        fetch_tid_latched  <= 1'b0;
    end
    else begin
        // Latch PC, prediction, and request metadata when we send address to RAM
        // These values will align with RAM output data next cycle
        pc_latched         <= pc_out;
        tid_latched        <= tid_out;
        valid_latched      <= fetch_in_progress;
        pred_taken_latched <= bpu_pred_taken;
        fetch_tid_latched  <= tid_out;

        // Capture response metadata from ICache (1 cycle later)
        resp_tid_latched   <= resp_tid_from_mem;
        resp_epoch_latched <= resp_epoch_from_mem;
        resp_valid_latched <= resp_valid_from_mem;
    end
end

// Determine if response is stale by comparing epochs
// Current epoch depends on which thread made the request
wire [3:0] expected_epoch = (resp_tid_latched == 1'b0) ? epoch_t0 : epoch_t1;
wire       response_stale = (resp_epoch_latched != expected_epoch);

// Final valid signal: must be valid from ICache AND not stale AND epochs match
wire       final_valid = valid_latched && resp_valid_latched && !response_stale;

// Use latched values for output (matches RAM timing)
assign if_pc         = pc_latched;
assign if_tid        = tid_latched;
assign if_valid      = final_valid;
assign if_inst       = inst_from_mem;
assign if_pred_taken = pred_taken_latched;

endmodule
