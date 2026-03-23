// =============================================================================
// Module : stage_if_v2
// Description: Upgraded IF stage with BPU integration and fetch buffer output.
//   - Fetches 1 instruction per cycle from the selected thread (via scheduler)
//   - Queries BPU for branch prediction alongside fetch
//   - Outputs to fetch_buffer for dual-issue decode
//   - Supports per-thread branch redirect and flush
//
//   This module wraps: pc_mt (multi-thread PC), inst_memory (IROM), bpu_bimodal
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
    output wire        if_pred_taken   // BPU prediction for this instruction
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

// ─── Instruction memory ────────────────────────────────────────────────────
wire flush_active;
assign flush_active = if_flush[fetch_tid];

inst_memory #(
    .IROM_SPACE (4096)
) u_inst_memory (
    .clk       (clk                    ),
    .rstn      (rstn && !flush_active  ),
    .inst_addr (pc_out                 ),
    .inst_o    (if_inst                )
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
// - Cycle N: RAM receives address (pc_out), latches PC and valid flag
// - Cycle N+1: RAM outputs instruction data
// The PC and valid must be delayed by 1 cycle to match RAM output timing.
reg [31:0] pc_latched;
reg [0:0]  tid_latched;
reg        valid_latched;
wire       fetch_in_progress;

assign fetch_in_progress = rstn && !flush_active && !pc_stall_combined;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        pc_latched    <= 32'd0;
        tid_latched   <= 1'b0;
        valid_latched <= 1'b0;
    end
    else begin
        // Latch PC when we send address to RAM (before PC advances)
        // This value will be valid when RAM outputs data next cycle
        pc_latched    <= pc_out;
        tid_latched   <= tid_out;
        valid_latched <= fetch_in_progress;
    end
end

// Use latched values for output (matches RAM timing)
assign if_pc         = pc_latched;
assign if_tid        = tid_latched;
assign if_valid      = valid_latched;
assign if_pred_taken = bpu_pred_taken;

endmodule
