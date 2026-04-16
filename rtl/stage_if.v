// =============================================================================
// Module : stage_if
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
module stage_if (
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
    output wire [7:0]  debug_ic_state_flags
);

// ─── PC management ──────────────────────────────────────────────────────────
wire [31:0] pc_out;
wire [0:0]  tid_out;
reg         fetch_req_active;
reg [31:0]  fetch_pc_pending;
reg [0:0]   fetch_tid_pending;
reg         fetch_pred_pending;

// Stall PC when: pipeline stall, fetch buffer full, or a previous fetch
// request is still waiting for its response.
wire pc_stall_combined;
assign pc_stall_combined = pc_stall || !fb_ready || fetch_req_active;
wire fetch_req_launch = rstn && !pc_stall && fb_ready && !fetch_req_active && (if_flush == 2'b00);
wire [1:0] pc_advance = fetch_req_launch ? (tid_out == 1'b0 ? 2'b01 : 2'b10) : 2'b00;

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
    .pc_advance  (pc_advance          ),
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
wire [7:0]  ic_high_miss_count_dbg;
wire [7:0]  ic_mem_req_count_dbg;
wire [7:0]  ic_mem_resp_count_dbg;
wire [7:0]  ic_cpu_resp_count_dbg;
wire [7:0]  ic_state_flags_dbg;

inst_memory #(
    .IROM_SPACE (4096)
) u_inst_memory (
    .clk            (clk               ),
    .rstn           (rstn              ),
    .req_valid      (fetch_req_launch   ),
    .inst_addr      (pc_out            ),
    .req_tid        (tid_out           ),
    .inst_o         (inst_from_mem     ),
    .resp_tid       (resp_tid_from_mem ),
    .resp_epoch     (resp_epoch_from_mem),
    .resp_valid     (resp_valid_from_mem),
    .current_epoch  (current_epoch     ),
    .current_epoch_t0(epoch_t0          ),
    .current_epoch_t1(epoch_t1          ),
    .flush          (|if_flush         ),

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
    .debug_ic_state_flags    (ic_state_flags_dbg)
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

// Bypass address needs to be delayed by 1 cycle to match mem_subsys RAM read latency
// When pc_out presents addr_N, mem_subsys reads ram[addr_N] and outputs data on next cycle
// So bypass_addr should be addr_N when bypass_data is for addr_N

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        fetch_req_active   <= 1'b0;
        fetch_pc_pending   <= 32'd0;
        fetch_tid_pending  <= 1'b0;
        fetch_pred_pending <= 1'b0;
    end
    else begin
        if (|if_flush) begin
            fetch_req_active <= 1'b0;
        end
        else begin
            if (fetch_req_launch) begin
                fetch_req_active   <= 1'b1;
                fetch_pc_pending   <= pc_out;
                fetch_tid_pending  <= tid_out;
                fetch_pred_pending <= bpu_pred_taken;
            end

            if (fetch_req_active && resp_valid_from_mem) begin
                fetch_req_active <= 1'b0;
            end
        end
    end
end
assign ext_mem_bypass_addr = fetch_req_active ? fetch_pc_pending : pc_out;

// ─── Outputs ────────────────────────────────────────────────────────────────
// CRITICAL FIX: Synchronous RAM has 1-cycle latency
// - Cycle N: RAM receives address (pc_out), BPU makes prediction
// - Cycle N+1: RAM outputs instruction data, prediction must align
// All outputs must be delayed by 1 cycle to match RAM output timing.
//
// Additionally: Stale response detection
// - Response includes {tid, epoch} from ICache
// - Drop response if epoch doesn't match current epoch (stale)
// Determine if response is stale by comparing epochs
// Current epoch depends on which thread made the request
wire [3:0] expected_epoch = (resp_tid_from_mem == 1'b0) ? epoch_t0 : epoch_t1;
wire       response_stale = resp_valid_from_mem && (resp_epoch_from_mem != expected_epoch);

wire       final_valid = fetch_req_active && resp_valid_from_mem && !response_stale;

assign if_pc         = fetch_pc_pending;
assign if_tid        = fetch_tid_pending;
assign if_valid      = final_valid;
assign if_inst       = inst_from_mem;
assign if_pred_taken = fetch_pred_pending;
assign debug_fetch_pc_pending = fetch_pc_pending;
assign debug_pc_out           = pc_out;
assign debug_if_inst          = inst_from_mem;
assign debug_if_flags         = {fetch_req_active, fetch_req_launch, resp_valid_from_mem,
                                 final_valid, response_stale, use_external_refill,
                                 fetch_pc_pending[31], pc_out[31]};
assign debug_ic_high_miss_count = ic_high_miss_count_dbg;
assign debug_ic_mem_req_count   = ic_mem_req_count_dbg;
assign debug_ic_mem_resp_count  = ic_mem_resp_count_dbg;
assign debug_ic_cpu_resp_count  = ic_cpu_resp_count_dbg;
assign debug_ic_state_flags     = ic_state_flags_dbg;

endmodule
