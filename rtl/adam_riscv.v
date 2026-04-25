// =============================================================================
// Module : adam_riscv
// Description: Upgraded top-level processor integrating all new micro-architecture
//   modules from the 4-phase upgrade. This module preserves backward compatibility
//   with the existing adam_riscv.v module interface (sys_clk, sys_rstn, led) while
//   wiring the new internal pipeline.
//
//   New Pipeline:
//   IF → FetchBuffer → DualDecoder → Scoreboard → RO → BypassNet →
//   ExecPipe0 (INT+Branch) / ExecPipe1 (INT+MUL+DIV+AGU) → MEM → WB

`include "define.v"
//
//   Additional subsystems:
//   - BPU (bimodal branch predictor in stage_if)
//   - CSR Unit (Machine-mode CSRs + exception handling)
//   - MMU (Sv32, currently in bare mode for simulation)
//   - L1 DCache (non-blocking, currently bypassed for sim with direct SRAM)
//   - RoCC AI Accelerator (stub connected, not activated in basic tests)
// =============================================================================

module adam_riscv(
    input wire sys_clk,
`ifdef FPGA_MODE
    output wire[2:0] led,
`endif
    input wire sys_rstn,
    input wire uart_rx,
    input wire ext_irq_src,
    output wire [7:0] tube_status, // Task 4: Export for testbench observation
    output wire       uart_tx,
    output wire       debug_core_ready,
    output wire       debug_core_clk,
    output wire       debug_retire_seen,
    output wire       debug_uart_status_busy,
    output wire       debug_uart_busy,
    output wire       debug_uart_pending_valid,
    output wire [7:0] debug_uart_status_load_count,
    output wire [7:0] debug_uart_tx_store_count,
    output wire       debug_uart_tx_byte_valid,
    output wire [7:0] debug_uart_tx_byte,
`ifdef VERILATOR_FAST_UART
    input  wire       fast_uart_rx_byte_valid,
    input  wire [7:0] fast_uart_rx_byte,
`endif
    output wire [7:0] debug_last_iss0_pc_lo,
    output wire [7:0] debug_last_iss1_pc_lo,
    output wire       debug_branch_pending_any,
    output wire       debug_br_found_t0,
    output wire       debug_branch_in_flight_t0,
    output wire       debug_oldest_br_ready_t0,
    output wire       debug_oldest_br_just_woke_t0,
    output wire [3:0] debug_oldest_br_qj_t0,
    output wire [3:0] debug_oldest_br_qk_t0,
    output wire [3:0] debug_slot1_flags,
    output wire [7:0] debug_slot1_pc_lo,
    output wire [3:0] debug_slot1_qj,
    output wire [3:0] debug_slot1_qk,
    output wire [3:0] debug_tag2_flags,
    output wire [3:0] debug_reg_x12_tag_t0,
    output wire [3:0] debug_slot1_issue_flags,
    output wire [3:0] debug_sel0_idx,
    output wire [3:0] debug_slot1_fu,
    output wire [7:0] debug_oldest_br_seq_lo_t0,
    output wire [15:0] debug_rs_flags_flat,
    output wire [31:0] debug_rs_pc_lo_flat,
    output wire [15:0] debug_rs_fu_flat,
    output wire [15:0] debug_rs_qj_flat,
    output wire [15:0] debug_rs_qk_flat,
    output wire [31:0] debug_rs_seq_lo_flat,
    output wire       debug_spec_dispatch0,
    output wire       debug_spec_dispatch1,
    output wire       debug_branch_gated_mem_issue,
    output wire       debug_flush_killed_speculative,
    output wire       debug_commit_suppressed,
    output wire       debug_spec_mmio_load_blocked,
    output wire       debug_spec_mmio_load_violation,
    output wire       debug_mmio_load_at_rob_head,
    output wire       debug_older_store_blocked_mmio_load,
    output wire [7:0] debug_branch_issue_count,
    output wire [7:0] debug_branch_complete_count,
    output wire [383:0] debug_ddr3_fetch_bus

`ifdef ENABLE_DDR3
    ,
    // DDR3 external memory port (from mem_subsys, active for addr >= 0x8000_0000)
    output wire        ddr3_req_valid,
    input  wire        ddr3_req_ready,
    output wire [31:0] ddr3_req_addr,
    output wire        ddr3_req_write,
    output wire [31:0] ddr3_req_wdata,
    output wire [3:0]  ddr3_req_wen,
    input  wire        ddr3_resp_valid,
    input  wire [31:0] ddr3_resp_data,
    input  wire        ddr3_init_calib_complete
`endif
);

// SMT mode parameter (0=single-thread, 1=SMT)
// Can be overridden at instantiation time
`ifndef SMT_MODE
    `define SMT_MODE 0
`endif
wire smt_mode = `SMT_MODE;

// RoCC accelerator integration is optional during bring-up. Keep it disabled by
// default so the core/basic test flow can stabilize independently.
`ifndef ENABLE_ROCC_ACCEL
    `define ENABLE_ROCC_ACCEL 0
`endif
localparam ROCC_ACCEL_ENABLE = `ENABLE_ROCC_ACCEL;

// The full mem_subsys/L2 path is useful for simulation coverage, but board
// bring-up can switch to a lighter legacy memory profile when LUT pressure is
// more important than cache/MMIO feature coverage.
`ifndef ENABLE_MEM_SUBSYS
    `define ENABLE_MEM_SUBSYS 1
`endif

`ifdef FPGA_MODE
`ifndef FPGA_FETCH_BUFFER_DEPTH
    `define FPGA_FETCH_BUFFER_DEPTH 16
`endif
`ifndef FPGA_SCOREBOARD_RS_DEPTH
    `define FPGA_SCOREBOARD_RS_DEPTH 16
`endif
`ifndef FPGA_SCOREBOARD_RS_IDX_W
    `define FPGA_SCOREBOARD_RS_IDX_W 4
`endif
`endif

// ─── Clock / Reset ───────────────────────────────────────────────────────────
wire rstn;
wire clk;
wire clk_locked;
wire rstn_in;

`ifdef FPGA_MODE
    clk_wiz_0 clk2cpu(
        .clk_out1(clk),
        .reset   (~sys_rstn),
        .locked  (clk_locked),
        .clk_in1 (sys_clk)
    );
`else
    assign clk = sys_clk;
    assign clk_locked = 1'b1;
`endif

// The OoO backend (dispatch_unit, ROB, freelist, issue queues) has complex
// internal state that is sensitive to glitchy clock edges during MMCM startup.
// Gate the reset release with clk_locked AND a short post-lock delay to ensure
// the core only begins execution on a stable clock.
`ifdef FPGA_MODE
reg [7:0] post_lock_cnt;
reg       post_lock_ready;
always @(posedge clk or negedge sys_rstn) begin
    if (!sys_rstn) begin
        post_lock_cnt   <= 8'd0;
        post_lock_ready <= 1'b0;
    end else if (!clk_locked) begin
        post_lock_cnt   <= 8'd0;
        post_lock_ready <= 1'b0;
    end else if (!post_lock_ready) begin
        if (post_lock_cnt == 8'd255)
            post_lock_ready <= 1'b1;
        else
            post_lock_cnt <= post_lock_cnt + 8'd1;
    end
end
assign rstn_in = sys_rstn & post_lock_ready;
`else
assign rstn_in = sys_rstn;
`endif

syn_rst u_syn_rst(
    .clock    (clk     ),
    .rstn     (rstn_in ),
    .syn_rstn (rstn    )
);

// FPGA board runs use explicit macro-controlled window sizes so the Vivado
// flow, board smoke tests, and diagnostic scripts can all target the same
// RS/fetch profile without editing RTL constants by hand.
`ifdef FPGA_MODE
localparam FETCH_BUFFER_DEPTH_CFG = `FPGA_FETCH_BUFFER_DEPTH;
localparam SCOREBOARD_RS_DEPTH_CFG = `FPGA_SCOREBOARD_RS_DEPTH;
localparam SCOREBOARD_RS_IDX_W_CFG = `FPGA_SCOREBOARD_RS_IDX_W;
`else
`ifdef SIM_SCOREBOARD_RS_DEPTH
localparam FETCH_BUFFER_DEPTH_CFG = 16;
localparam SCOREBOARD_RS_DEPTH_CFG = `SIM_SCOREBOARD_RS_DEPTH;
localparam SCOREBOARD_RS_IDX_W_CFG = `SIM_SCOREBOARD_RS_IDX_W;
`else
localparam FETCH_BUFFER_DEPTH_CFG = 16;
localparam SCOREBOARD_RS_DEPTH_CFG = 16;
localparam SCOREBOARD_RS_IDX_W_CFG = 4;
`endif
`endif

// ─── Thread Scheduler ──────────────────────────────────────────────────────
wire [0:0] fetch_tid;
wire [1:0] smt_stall;
wire [1:0] smt_flush;
wire       flush_any;

// SMT mode control (hardcoded for now, can be made configurable)
// Set to 0 for single-thread tests, 1 for SMT tests
// Use `define SMT_MODE 1 before including this file to enable SMT

// Branch from Pipe0
wire       pipe0_br_ctrl;
wire [31:0] pipe0_br_addr;
wire [0:0] pipe0_br_tid;
wire [`METADATA_ORDER_ID_W-1:0] pipe0_br_order_id;
wire       pipe0_br_complete;  // branch execution complete (taken or not)
wire       pipe0_br_update_valid;
wire [31:0] pipe0_br_update_pc;
wire       pipe0_br_update_taken;
wire [31:0] pipe0_br_update_target;
wire       pipe0_br_update_is_call;
wire       pipe0_br_update_is_return;
reg        pipe0_br_complete_hold_r;
wire       scoreboard_br_complete;

// CSR from Pipe0
wire       pipe0_csr_valid;
wire [31:0] pipe0_csr_wdata;
wire [2:0] pipe0_csr_op;
wire [11:0] pipe0_csr_addr_unused;
wire       pipe0_mret_valid;
wire [`METADATA_ORDER_ID_W-1:0] pipe0_mret_order_id;

// CSR read data from csr_unit
wire [31:0] csr_rdata;

// RoCC AI Accelerator interface
wire        rocc_cmd_valid;
wire        rocc_cmd_ready;
wire [6:0]  rocc_cmd_funct7;
wire [2:0]  rocc_cmd_funct3;
wire [4:0]  rocc_cmd_rd;
wire [31:0] rocc_cmd_rs1_data;
wire [31:0] rocc_cmd_rs2_data;
wire [4:0]  rocc_cmd_tag;
wire [0:0]  rocc_cmd_tid;

wire        rocc_resp_valid;
wire        rocc_resp_ready;
wire [4:0]  rocc_resp_rd;
wire [31:0] rocc_resp_data;
wire [4:0]  rocc_resp_tag;
wire [0:0]  rocc_resp_tid;

wire        rocc_mem_req_valid;
wire        rocc_mem_req_ready;
wire [31:0] rocc_mem_req_addr;
wire [31:0] rocc_mem_req_wdata;
wire        rocc_mem_req_wen;
wire        rocc_mem_resp_valid;
wire [31:0] rocc_mem_resp_rdata;

wire        rocc_busy;
wire        rocc_interrupt;

// Trap signals
wire        trap_enter;
wire [31:0] trap_target;
wire        trap_return;
wire [31:0] mepc_out;
wire        global_int_en;

assign smt_flush[0] = pipe0_br_ctrl && (pipe0_br_tid == 1'b0);
assign smt_flush[1] = pipe0_br_ctrl && (pipe0_br_tid == 1'b1);
assign flush_any    = pipe0_br_ctrl;

// Stall from scoreboard / ROB. The ROB can fill before the scoreboard does;
// if we don't reflect that backpressure to the front-end, the scoreboard may
// accept an instruction that the ROB silently drops.
wire rob0_full, rob1_full;
wire sb_disp_stall;
wire sb_disp1_blocked;  // d1 valid but IQ-blocked (d0 went through)
wire rob_disp_stall;
wire fl_disp_stall;
wire sys_disp_stall;
wire stall;
assign stall       = sb_disp_stall || rob_disp_stall || fl_disp_stall || sys_disp_stall;

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        pipe0_br_complete_hold_r <= 1'b0;
    else
        pipe0_br_complete_hold_r <= pipe0_br_complete;
end

`ifdef FPGA_MODE
assign scoreboard_br_complete = pipe0_br_complete || pipe0_br_complete_hold_r;
`else
assign scoreboard_br_complete = pipe0_br_complete;
`endif
assign smt_stall   = {stall, stall};

// ─── Thread Scheduler ──────────────────────────────────────────────────────
thread_scheduler u_thread_scheduler(
    .clk          (clk         ),
    .rstn         (rstn        ),
    .thread_stall (smt_stall   ),
    .smt_mode     (smt_mode    ),
    .fetch_tid    (fetch_tid   )
);

// ════════════════════════════════════════════════════════════════════════════
// Per-Thread Metadata Counters (order_id and epoch)
// ════════════════════════════════════════════════════════════════════════════
// Epoch counters: increment on flush per thread, 8-bit wide
reg [7:0] epoch_t0, epoch_t1;
// Flush new epoch = next epoch value (current + 1) for correct flush semantics
wire [7:0] flush_new_epoch_t0 = epoch_t0 + 8'd1;
wire [7:0] flush_new_epoch_t1 = epoch_t1 + 8'd1;

// Order ID counters: increment on dispatch accept per thread, 16-bit wide
// These will be updated in the always block after scoreboard signals are defined
reg [`METADATA_ORDER_ID_W-1:0] order_id_t0, order_id_t1;
reg        mret_pending_t0, mret_pending_t1;
reg [`METADATA_ORDER_ID_W-1:0] mret_pending_order_t0, mret_pending_order_t1;
reg        csr_pending_t0, csr_pending_t1;
reg [`METADATA_ORDER_ID_W-1:0] csr_pending_order_t0, csr_pending_order_t1;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        epoch_t0   <= 8'd0;
        epoch_t1   <= 8'd0;
    end else begin
        // Increment epoch on any architecturally-visible redirect/flush.
        // Branches already did this historically; trap enter / MRET must do
        // the same so younger wrong-path work cannot survive with the old
        // epoch after the redirect boundary.
        if (trap_enter || trap_return || pipe0_br_ctrl) begin
            if ((trap_enter || trap_return) ? 1'b0 : pipe0_br_tid)
                epoch_t1 <= epoch_t1 + 8'd1;
            else
                epoch_t0 <= epoch_t0 + 8'd1;
        end
    end
end

// Order ID update logic moved below after scoreboard is defined
// Order ID and epoch assignments will be defined after decoder signals

// Memory subsystem mode: default to full mem_subsys, but keep a configurable
// legacy path for FPGA bring-up builds.
localparam USE_MEM_SUBSYS = `ENABLE_MEM_SUBSYS;
wire use_mem_subsys = USE_MEM_SUBSYS;

// Forward-declared interconnects that are consumed before their producer
// instances appear later in the file.
wire        m0_req_valid;
wire        m0_req_ready;
wire [31:0] m0_req_addr;
wire        m0_resp_valid;
wire [31:0] m0_resp_data;
wire        m0_resp_last;
wire        m0_resp_ready;
wire [31:0] m0_bypass_addr;
wire [31:0] m0_bypass_data;
wire        rob_commit0_valid, rob_commit1_valid;
wire [4:0]  rob_commit0_rd, rob_commit1_rd;
wire [4:0]  rob_commit0_tag, rob_commit1_tag;
wire        rob_commit0_has_result, rob_commit1_has_result;
wire [31:0] rob_commit0_data, rob_commit1_data;
wire [`METADATA_ORDER_ID_W-1:0] rob_commit0_order_id, rob_commit1_order_id;
wire        rob_commit0_is_store, rob_commit1_is_store;
wire        rob_commit0_is_mret,  rob_commit1_is_mret;
wire [1:0]  rob_instr_retired;
// Expanded ROB rename support outputs (Stage A: unused, wired to defaults)
wire [5:0]  rob_commit0_prd_old, rob_commit1_prd_old;
wire        rob_commit0_regs_write, rob_commit1_regs_write;
wire        rob_recover_walk_active;
wire        rob_recover_en;
wire [4:0]  rob_recover_rd;
wire [5:0]  rob_recover_prd_old, rob_recover_prd_new;
wire        rob_recover_regs_write;
wire [0:0]  rob_recover_tid;
wire        rob_debug_commit_suppressed;
wire        rob_head_valid_t0, rob_head_valid_t1;
wire [`METADATA_ORDER_ID_W-1:0] rob_head_order_id_t0, rob_head_order_id_t1;
wire        rob_head_flushed_t0, rob_head_flushed_t1;
wire [3:0]  rob_disp0_rob_idx, rob_disp1_rob_idx;
wire [4:0]  sb_disp0_tag, sb_disp1_tag;
wire        iss0_is_csr;
wire        iss0_is_mret;
wire [11:0] iss0_csr_addr;
wire        iss0_is_rocc;
wire [6:0]  iss0_rocc_funct7;
wire        iss0_pred_taken;
wire [31:0] iss0_pred_target;
reg         retire_seen_r;

// ════════════════════════════════════════════════════════════════════════════
// STAGE 1: Instruction Fetch (stage_if with BPU)
// ════════════════════════════════════════════════════════════════════════════
wire        if_valid;
wire [31:0] if_inst;
wire [31:0] if_pc;
wire [0:0]  if_tid;
wire        if_pred_taken;
wire [31:0] if_pred_target;
wire [31:0] debug_fetch_pc_pending;
wire [31:0] debug_fetch_pc_out;
wire [31:0] debug_fetch_if_inst;
wire [7:0]  debug_fetch_if_flags;
wire [7:0]  debug_ic_high_miss_count;
wire [7:0]  debug_ic_mem_req_count;
wire [7:0]  debug_ic_mem_resp_count;
wire [7:0]  debug_ic_cpu_resp_count;
wire [7:0]  debug_ic_state_flags;
wire        hpm_icache_miss_event;
wire        hpm_sb_stall_event;

// Fetch buffer backpressure
wire fb_push_ready;

// ════════════════════════════════════════════════════════════════════════════
// Trap Redirect Mux: Prioritize trap entry > MRET > Branch > Normal flow
// ════════════════════════════════════════════════════════════════════════════
wire        trap_redirect_valid = trap_enter || trap_return;
wire [31:0] trap_redirect_pc    = trap_enter ? trap_target : 
                                   trap_return ? mepc_out : 32'd0;
wire [0:0]  trap_redirect_tid   = 1'b0;  // M-mode only, single context
wire [0:0]  flush_tid_mux       = trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid;

// flush_order_valid: order-based flush for branches and MRET (not trap_enter)
wire flush_is_order_based = (!trap_redirect_valid && pipe0_br_ctrl) || (trap_return && !trap_enter);
wire [`METADATA_ORDER_ID_W-1:0] flush_order_id_mux = (trap_return && !trap_enter) ? pipe0_mret_order_id : pipe0_br_order_id;

// Combine flush signals: trap_redirect overrides branch
wire [1:0]  combined_flush      = trap_redirect_valid ? {trap_redirect_tid == 1'b1, 
                                                          trap_redirect_tid == 1'b0} :
                                  smt_flush;
wire        combined_flush_any  = trap_redirect_valid || flush_any;

stage_if u_stage_if(
    .clk              (clk              ),
    .rstn             (rstn             ),
    .pc_stall         (stall            ),
    .if_flush         (combined_flush   ),  // Use combined flush (trap > branch)
    .br_addr_t0       (trap_redirect_valid ? trap_redirect_pc :
                        (pipe0_br_ctrl && (pipe0_br_tid==1'b0) ? pipe0_br_addr : 32'd0)),
    .br_addr_t1       (trap_redirect_valid ? trap_redirect_pc :
                        (pipe0_br_ctrl && (pipe0_br_tid==1'b1) ? pipe0_br_addr : 32'd0)),
    .br_ctrl          (trap_redirect_valid ? {trap_redirect_tid == 1'b1, trap_redirect_tid == 1'b0} :
                        {pipe0_br_ctrl && (pipe0_br_tid==1'b1),
                         pipe0_br_ctrl && (pipe0_br_tid==1'b0)}),
    .bpu_update_valid (pipe0_br_update_valid),
    .bpu_update_pc    (pipe0_br_update_pc),
    .bpu_update_tid   (pipe0_br_tid),
    .bpu_update_taken (pipe0_br_update_taken),
    .bpu_update_target(pipe0_br_update_target),
    .bpu_update_is_call(pipe0_br_update_is_call),
    .bpu_update_is_return(pipe0_br_update_is_return),
    .fetch_tid        (fetch_tid        ),
    .fb_ready         (fb_push_ready    ),
    .if_valid         (if_valid         ),
    .if_inst          (if_inst          ),
    .if_pc            (if_pc            ),
    .if_tid           (if_tid           ),
    .if_pred_taken    (if_pred_taken    ),
    .if_pred_target   (if_pred_target   ),

    // Task 5: External refill interface to mem_subsys M0
    .ext_mem_req_valid  (m0_req_valid),
    .ext_mem_req_ready  (m0_req_ready),
    .ext_mem_req_addr   (m0_req_addr),
    .ext_mem_resp_valid (m0_resp_valid),
    .ext_mem_resp_data  (m0_resp_data),
    .ext_mem_resp_last  (m0_resp_last),
    .ext_mem_resp_ready (m0_resp_ready),
    .ext_mem_bypass_addr(m0_bypass_addr),
    .ext_mem_bypass_data(m0_bypass_data),
    .use_external_refill(use_mem_subsys),
    .debug_fetch_pc_pending(debug_fetch_pc_pending),
    .debug_pc_out          (debug_fetch_pc_out),
    .debug_if_inst         (debug_fetch_if_inst),
    .debug_if_flags        (debug_fetch_if_flags),
    .debug_ic_high_miss_count(debug_ic_high_miss_count),
    .debug_ic_mem_req_count  (debug_ic_mem_req_count),
    .debug_ic_mem_resp_count (debug_ic_mem_resp_count),
    .debug_ic_cpu_resp_count (debug_ic_cpu_resp_count),
    .debug_ic_state_flags    (debug_ic_state_flags),
    .icache_miss_event       (hpm_icache_miss_event)
);

// ════════════════════════════════════════════════════════════════════════════
// STAGE 2: Fetch Buffer (4-entry FIFO)
// ════════════════════════════════════════════════════════════════════════════
wire        fb_pop0_valid, fb_pop1_valid;
wire [31:0] fb_pop0_inst,  fb_pop1_inst;
wire [31:0] fb_pop0_pc,    fb_pop1_pc;
wire [0:0]  fb_pop0_tid,   fb_pop1_tid;
wire        fb_pop0_pred_taken, fb_pop1_pred_taken;
wire [31:0] fb_pop0_pred_target, fb_pop1_pred_target;
wire        fb_consume_0,  fb_consume_1;

fetch_buffer #(.DEPTH(FETCH_BUFFER_DEPTH_CFG)) u_fetch_buffer(
    .clk        (clk            ),
    .rstn       (rstn           ),
    .flush      (combined_flush ),
    .push_valid (if_valid       ),
    .push_inst  (if_inst        ),
    .push_pc    (if_pc          ),
    .push_tid   (if_tid         ),
    .push_pred_taken (if_pred_taken),
    .push_pred_target(if_pred_target),
    .push_ready (fb_push_ready  ),
    .pop0_valid (fb_pop0_valid  ),
    .pop0_inst  (fb_pop0_inst   ),
    .pop0_pc    (fb_pop0_pc     ),
    .pop0_tid   (fb_pop0_tid    ),
    .pop0_pred_taken (fb_pop0_pred_taken),
    .pop0_pred_target(fb_pop0_pred_target),
    .pop1_valid (fb_pop1_valid  ),
    .pop1_inst  (fb_pop1_inst   ),
    .pop1_pc    (fb_pop1_pc     ),
    .pop1_tid   (fb_pop1_tid    ),
    .pop1_pred_taken (fb_pop1_pred_taken),
    .pop1_pred_target(fb_pop1_pred_target),
    .consume_0  (fb_consume_0   ),
    .consume_1  (fb_consume_1   )
);

// ════════════════════════════════════════════════════════════════════════════
// STAGE 3: Dual Decoder
// ════════════════════════════════════════════════════════════════════════════
wire        dec0_valid, dec1_valid;
wire [31:0] dec0_pc,    dec1_pc;
wire [31:0] dec0_imm,   dec1_imm;
wire [2:0]  dec0_func3, dec1_func3;
wire        dec0_func7, dec1_func7;
wire [4:0]  dec0_rd,    dec1_rd;
wire        dec0_br,    dec1_br;
wire        dec0_mem_read,  dec1_mem_read;
wire        dec0_mem2reg,   dec1_mem2reg;
wire [2:0]  dec0_alu_op,    dec1_alu_op;
wire        dec0_mem_write, dec1_mem_write;
wire [1:0]  dec0_alu_src1,  dec1_alu_src1;
wire [1:0]  dec0_alu_src2,  dec1_alu_src2;
wire        dec0_br_addr_mode, dec1_br_addr_mode;
wire        dec0_regs_write, dec1_regs_write;
wire [4:0]  dec0_rs1,   dec1_rs1;
wire [4:0]  dec0_rs2,   dec1_rs2;
wire        dec0_rs1_used, dec1_rs1_used;
wire        dec0_rs2_used, dec1_rs2_used;
wire [2:0]  dec0_fu,    dec1_fu;
wire [0:0]  dec0_tid,   dec1_tid;
wire        dec0_is_csr, dec1_is_csr;
wire        dec0_is_mret, dec1_is_mret;
wire [11:0] dec0_csr_addr, dec1_csr_addr;
wire        dec0_is_rocc, dec1_is_rocc;
wire [6:0]  dec0_rocc_funct7, dec1_rocc_funct7;

decoder_dual u_decoder_dual(
    .stall           (stall           ),
    .inst0_valid     (fb_pop0_valid    ),
    .inst0_word      (fb_pop0_inst     ),
    .inst0_pc        (fb_pop0_pc       ),
    .inst0_tid       (fb_pop0_tid      ),
    .inst1_valid     (fb_pop1_valid    ),
    .inst1_word      (fb_pop1_inst     ),
    .inst1_pc        (fb_pop1_pc       ),
    .inst1_tid       (fb_pop1_tid      ),
    .dec0_valid      (dec0_valid       ),
    .dec0_pc         (dec0_pc          ),
    .dec0_imm        (dec0_imm         ),
    .dec0_func3      (dec0_func3       ),
    .dec0_func7      (dec0_func7       ),
    .dec0_rd         (dec0_rd          ),
    .dec0_br         (dec0_br          ),
    .dec0_mem_read   (dec0_mem_read    ),
    .dec0_mem2reg    (dec0_mem2reg     ),
    .dec0_alu_op     (dec0_alu_op      ),
    .dec0_mem_write  (dec0_mem_write   ),
    .dec0_alu_src1   (dec0_alu_src1    ),
    .dec0_alu_src2   (dec0_alu_src2    ),
    .dec0_br_addr_mode(dec0_br_addr_mode),
    .dec0_regs_write (dec0_regs_write  ),
    .dec0_rs1        (dec0_rs1         ),
    .dec0_rs2        (dec0_rs2         ),
    .dec0_rs1_used   (dec0_rs1_used    ),
    .dec0_rs2_used   (dec0_rs2_used    ),
    .dec0_fu         (dec0_fu          ),
    .dec0_tid        (dec0_tid         ),
    .dec0_is_csr     (dec0_is_csr      ),
    .dec0_is_mret    (dec0_is_mret     ),
    .dec0_csr_addr   (dec0_csr_addr    ),
    .dec1_valid      (dec1_valid       ),
    .dec1_pc         (dec1_pc          ),
    .dec1_imm        (dec1_imm         ),
    .dec1_func3      (dec1_func3       ),
    .dec1_func7      (dec1_func7       ),
    .dec1_rd         (dec1_rd          ),
    .dec1_br         (dec1_br          ),
    .dec1_mem_read   (dec1_mem_read    ),
    .dec1_mem2reg    (dec1_mem2reg     ),
    .dec1_alu_op     (dec1_alu_op      ),
    .dec1_mem_write  (dec1_mem_write   ),
    .dec1_alu_src1   (dec1_alu_src1    ),
    .dec1_alu_src2   (dec1_alu_src2    ),
    .dec1_br_addr_mode(dec1_br_addr_mode),
    .dec1_regs_write (dec1_regs_write  ),
    .dec1_rs1        (dec1_rs1         ),
    .dec1_rs2        (dec1_rs2         ),
    .dec1_rs1_used   (dec1_rs1_used    ),
    .dec1_rs2_used   (dec1_rs2_used    ),
    .dec1_fu         (dec1_fu          ),
    .dec1_tid        (dec1_tid         ),
    .dec1_is_csr     (dec1_is_csr     ),
    .dec1_is_mret    (dec1_is_mret    ),
    .dec1_csr_addr   (dec1_csr_addr   ),
    .dec0_is_rocc    (dec0_is_rocc    ),
    .dec0_rocc_funct7(dec0_rocc_funct7),
    .dec1_is_rocc    (dec1_is_rocc    ),
    .dec1_rocc_funct7(dec1_rocc_funct7),
    .consume_0       (fb_consume_0    ),
    .consume_1       (fb_consume_1    ),
    .disp1_blocked   (sb_disp1_blocked)
);

// Squash dispatches if flush active
wire disp0_valid_pre_rob = dec0_valid && !smt_flush[dec0_tid];
wire disp1_valid_pre_rob = dec1_valid && !smt_flush[dec1_tid];
assign rob_disp_stall = (disp0_valid_pre_rob && rob0_full) ||
                        (disp1_valid_pre_rob && rob1_full);
// Freelist stall: prevent dispatch when freelist can't provide physical regs
wire d0_needs_alloc = disp0_valid_pre_rob && dec0_regs_write && (dec0_rd != 5'd0);
wire d1_needs_alloc = disp1_valid_pre_rob && dec1_regs_write && (dec1_rd != 5'd0);
assign fl_disp_stall = (d0_needs_alloc && d1_needs_alloc) ? !fl_can_alloc_2 :
                       (d0_needs_alloc || d1_needs_alloc) ? !fl_can_alloc_1 :
                       1'b0;
// Never dispatch in the same cycle as a redirect/flush. The IQ flush logic
// runs before dispatch allocation, so allowing same-cycle dispatch can leak
// wrong-path entries into the IQs after branch/trap redirects.
wire dec0_system_pending = dec0_tid ? (mret_pending_t1 || csr_pending_t1) :
                                      (mret_pending_t0 || csr_pending_t0);
wire dec1_system_pending = dec1_tid ? (mret_pending_t1 || csr_pending_t1) :
                                      (mret_pending_t0 || csr_pending_t0);
wire dec0_blocked_by_pending_system = dec0_system_pending;
wire dec1_blocked_by_pending_system =
    dec1_system_pending ||
    (disp0_valid_pre_rob && (dec0_is_mret || dec0_is_csr) && (dec0_tid == dec1_tid));
assign sys_disp_stall = disp0_valid_pre_rob && dec0_blocked_by_pending_system;
wire disp0_valid_gated = disp0_valid_pre_rob && !rob_disp_stall && !fl_disp_stall &&
                         !combined_flush_any && !dec0_blocked_by_pending_system;
wire disp1_valid_gated = disp1_valid_pre_rob && !rob_disp_stall && !fl_disp_stall &&
                         !combined_flush_any && !dec1_blocked_by_pending_system;

// Order ID and epoch assignments for dispatch ports (using decoder tid)
// disp0 gets current order_id for its thread
wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id = (dec0_tid == 1'b0) ? order_id_t0 : order_id_t1;
// disp1 gets current+1 if same thread as disp0, otherwise current for its thread
wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id = (dec1_tid == 1'b0) ? 
    ((dec0_tid == 1'b0 && disp0_accepted) ? order_id_t0 + 1'b1 : order_id_t0) :
    ((dec0_tid == 1'b1 && disp0_accepted) ? order_id_t1 + 1'b1 : order_id_t1);
wire [7:0] disp0_epoch = (dec0_tid == 1'b0) ? epoch_t0 : epoch_t1;
wire [7:0] disp1_epoch = (dec1_tid == 1'b0) ? epoch_t0 : epoch_t1;

// ════════════════════════════════════════════════════════════════════════════
// Tag → Physical Register Sideband Maps
// ════════════════════════════════════════════════════════════════════════════
// These tables map RS tags to physical register addresses. They are written at
// dispatch (alongside scoreboard allocation) and read at WB time (PRF write)
// and at issue time (PRF source operand read).
reg [5:0] tag_prd_map  [0:31];   // dest phys reg for each RS tag
reg [5:0] tag_prs1_map [0:31];   // source 1 phys reg for each RS tag
reg [5:0] tag_prs2_map [0:31];   // source 2 phys reg for each RS tag
reg [0:0] tag_tid_map  [0:31];   // thread ID for each RS tag
`ifdef VERILATOR_MAINLINE
reg [31:0] tag_pc_map [0:31];
reg [`METADATA_ORDER_ID_W-1:0] tag_order_map [0:31];
reg [4:0] tag_rd_map [0:31];
`endif
integer tp_idx;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (tp_idx = 0; tp_idx < 32; tp_idx = tp_idx + 1) begin
            tag_prd_map[tp_idx]  <= 6'd0;
            tag_prs1_map[tp_idx] <= 6'd0;
            tag_prs2_map[tp_idx] <= 6'd0;
            tag_tid_map[tp_idx]  <= 1'b0;
`ifdef VERILATOR_MAINLINE
            tag_pc_map[tp_idx] <= 32'd0;
            tag_order_map[tp_idx] <= {`METADATA_ORDER_ID_W{1'b0}};
            tag_rd_map[tp_idx] <= 5'd0;
`endif
        end
    end else begin
        if (disp0_accepted && sb_disp0_tag != 5'd0) begin
            tag_prd_map[sb_disp0_tag]  <= shadow_alloc0_valid ? fl_alloc0_prd : 6'd0;
            tag_prs1_map[sb_disp0_tag] <= rmt_prs0_1;
            tag_prs2_map[sb_disp0_tag] <= rmt_prs0_2;
            tag_tid_map[sb_disp0_tag]  <= dec0_tid;
`ifdef VERILATOR_MAINLINE
            tag_pc_map[sb_disp0_tag] <= dec0_pc;
            tag_order_map[sb_disp0_tag] <= disp0_order_id;
            tag_rd_map[sb_disp0_tag] <= dec0_rd;
`endif
        end
        if (disp1_accepted && sb_disp1_tag != 5'd0) begin
            tag_prd_map[sb_disp1_tag]  <= shadow_alloc1_valid ? fl_alloc1_prd : 6'd0;
            tag_prs1_map[sb_disp1_tag] <= rmt_prs1_1;
            tag_prs2_map[sb_disp1_tag] <= rmt_prs1_2;
            tag_tid_map[sb_disp1_tag]  <= dec1_tid;
`ifdef VERILATOR_MAINLINE
            tag_pc_map[sb_disp1_tag] <= dec1_pc;
            tag_order_map[sb_disp1_tag] <= disp1_order_id;
            tag_rd_map[sb_disp1_tag] <= dec1_rd;
`endif
        end
    end
end

// ════════════════════════════════════════════════════════════════════════════
// STAGE 4: Scoreboard (16-entry RS, Dual-Issue)
// ════════════════════════════════════════════════════════════════════════════
// Issue port 0 wires
wire        iss0_valid;
wire [4:0]  iss0_tag;
wire [31:0] iss0_pc, iss0_imm;
wire [2:0]  iss0_func3;
wire        iss0_func7;
wire [4:0]  iss0_rd, iss0_rs1, iss0_rs2;
wire        iss0_rs1_used, iss0_rs2_used;
wire [4:0]  iss0_src1_tag, iss0_src2_tag;
wire        iss0_br, iss0_mem_read, iss0_mem2reg;
wire [2:0]  iss0_alu_op;
wire        iss0_mem_write;
wire [1:0]  iss0_alu_src1, iss0_alu_src2;
wire        iss0_br_addr_mode, iss0_regs_write;
wire [2:0]  iss0_fu;
wire [0:0]  iss0_tid;

wire        p1_winner_valid;
wire [1:0]  p1_winner;
wire        p1_mem_cand_valid;
wire [4:0]  p1_mem_cand_tag;
wire [31:0] p1_mem_cand_pc, p1_mem_cand_imm;
wire [2:0]  p1_mem_cand_func3;
wire        p1_mem_cand_func7;
wire [4:0]  p1_mem_cand_rd, p1_mem_cand_rs1, p1_mem_cand_rs2;
wire        p1_mem_cand_rs1_used, p1_mem_cand_rs2_used;
wire [4:0]  p1_mem_cand_src1_tag, p1_mem_cand_src2_tag;
wire        p1_mem_cand_br, p1_mem_cand_mem_read, p1_mem_cand_mem2reg;
wire [2:0]  p1_mem_cand_alu_op;
wire        p1_mem_cand_mem_write;
wire [1:0]  p1_mem_cand_alu_src1, p1_mem_cand_alu_src2;
wire        p1_mem_cand_br_addr_mode, p1_mem_cand_regs_write;
wire [2:0]  p1_mem_cand_fu;
wire [0:0]  p1_mem_cand_tid;
wire [`METADATA_ORDER_ID_W-1:0] p1_mem_cand_order_id;
wire [`METADATA_EPOCH_W-1:0]    p1_mem_cand_epoch;
wire        p1_mul_cand_valid;
wire [4:0]  p1_mul_cand_tag;
wire [31:0] p1_mul_cand_pc, p1_mul_cand_imm;
wire [2:0]  p1_mul_cand_func3;
wire        p1_mul_cand_func7;
wire [4:0]  p1_mul_cand_rd, p1_mul_cand_rs1, p1_mul_cand_rs2;
wire        p1_mul_cand_rs1_used, p1_mul_cand_rs2_used;
wire [4:0]  p1_mul_cand_src1_tag, p1_mul_cand_src2_tag;
wire        p1_mul_cand_br, p1_mul_cand_mem_read, p1_mul_cand_mem2reg;
wire [2:0]  p1_mul_cand_alu_op;
wire        p1_mul_cand_mem_write;
wire [1:0]  p1_mul_cand_alu_src1, p1_mul_cand_alu_src2;
wire        p1_mul_cand_br_addr_mode, p1_mul_cand_regs_write;
wire [2:0]  p1_mul_cand_fu;
wire [0:0]  p1_mul_cand_tid;
wire [`METADATA_ORDER_ID_W-1:0] p1_mul_cand_order_id;
wire [`METADATA_EPOCH_W-1:0]    p1_mul_cand_epoch;
wire        p1_div_cand_valid;
wire [4:0]  p1_div_cand_tag;
wire [31:0] p1_div_cand_pc, p1_div_cand_imm;
wire [2:0]  p1_div_cand_func3;
wire        p1_div_cand_func7;
wire [4:0]  p1_div_cand_rd, p1_div_cand_rs1, p1_div_cand_rs2;
wire        p1_div_cand_rs1_used, p1_div_cand_rs2_used;
wire [4:0]  p1_div_cand_src1_tag, p1_div_cand_src2_tag;
wire        p1_div_cand_br, p1_div_cand_mem_read, p1_div_cand_mem2reg;
wire [2:0]  p1_div_cand_alu_op;
wire        p1_div_cand_mem_write;
wire [1:0]  p1_div_cand_alu_src1, p1_div_cand_alu_src2;
wire        p1_div_cand_br_addr_mode, p1_div_cand_regs_write;
wire [2:0]  p1_div_cand_fu;
wire [0:0]  p1_div_cand_tid;
wire [`METADATA_ORDER_ID_W-1:0] p1_div_cand_order_id;
wire [`METADATA_EPOCH_W-1:0]    p1_div_cand_epoch;
wire        sb_branch_pending_any;
wire        sb_debug_br_found_t0;
wire        sb_debug_branch_in_flight_t0;
wire        sb_debug_oldest_br_ready_t0;
wire        sb_debug_oldest_br_just_woke_t0;
wire [3:0]  sb_debug_oldest_br_qj_t0;
wire [3:0]  sb_debug_oldest_br_qk_t0;
wire [3:0]  sb_debug_slot1_flags;
wire [7:0]  sb_debug_slot1_pc_lo;
wire [3:0]  sb_debug_slot1_qj;
wire [3:0]  sb_debug_slot1_qk;
wire [3:0]  sb_debug_tag2_flags;
wire [3:0]  sb_debug_reg_x12_tag_t0;
wire [3:0]  sb_debug_slot1_issue_flags;
wire [3:0]  sb_debug_sel0_idx;
wire [3:0]  sb_debug_slot1_fu;
wire [7:0]  sb_debug_oldest_br_seq_lo_t0;
wire [15:0] sb_debug_rs_flags_flat;
wire [31:0] sb_debug_rs_pc_lo_flat;
wire [15:0] sb_debug_rs_fu_flat;
wire [15:0] sb_debug_rs_qj_flat;
wire [15:0] sb_debug_rs_qk_flat;
wire [31:0] sb_debug_rs_seq_lo_flat;
wire        sb_debug_spec_dispatch0;
wire        sb_debug_spec_dispatch1;
wire        sb_debug_branch_gated_mem_issue;
wire        sb_debug_flush_killed_speculative;

// Issue metadata wires
wire [`METADATA_ORDER_ID_W-1:0] iss0_order_id;
wire [`METADATA_EPOCH_W-1:0]    iss0_epoch;

// Writeback port wires (from pipes)
wire        wb0_valid, wb1_valid;
wire [4:0]  wb0_tag,   wb1_tag;
wire [4:0]  wb0_rd,    wb1_rd;
wire        wb0_regs_write, wb1_regs_write;
wire [2:0]  wb0_fu,    wb1_fu;
wire [0:0]  wb0_tid,   wb1_tid;

dispatch_unit #(
    .RS_DEPTH(SCOREBOARD_RS_DEPTH_CFG),
    .RS_IDX_W(SCOREBOARD_RS_IDX_W_CFG),
    .RS_TAG_W(5)
) u_dispatch_unit (
    .clk         (clk              ),
    .rstn        (rstn             ),
    .flush       (combined_flush_any ),
    .flush_tid   (trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid ),
    .flush_order_valid(flush_is_order_based),
    .flush_order_id(flush_order_id_mux),
    .flush_new_epoch((trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid) ? flush_new_epoch_t1 : flush_new_epoch_t0),

    // Dispatch 0
    .disp0_valid       (disp0_valid_gated ),
    .disp0_pc          (dec0_pc           ),
    .disp0_imm         (dec0_imm          ),
    .disp0_func3       (dec0_func3        ),
    .disp0_func7       (dec0_func7        ),
    .disp0_rd          (dec0_rd           ),
    .disp0_br          (dec0_br           ),
    .disp0_mem_read    (dec0_mem_read     ),
    .disp0_mem2reg     (dec0_mem2reg      ),
    .disp0_alu_op      (dec0_alu_op       ),
    .disp0_mem_write   (dec0_mem_write    ),
    .disp0_alu_src1    (dec0_alu_src1     ),
    .disp0_alu_src2    (dec0_alu_src2     ),
    .disp0_br_addr_mode(dec0_br_addr_mode ),
    .disp0_regs_write  (dec0_regs_write   ),
    .disp0_rs1         (dec0_rs1          ),
    .disp0_rs2         (dec0_rs2          ),
    .disp0_rs1_used    (dec0_rs1_used     ),
    .disp0_rs2_used    (dec0_rs2_used     ),
    .disp0_fu          (dec0_fu           ),
    .disp0_tid         (dec0_tid          ),
    .disp0_is_mret     (dec0_is_mret      ),
    .disp0_is_csr      (dec0_is_csr       ),
    .disp0_is_rocc     (dec0_is_rocc      ),

    // Dispatch 1
    .disp1_valid       (disp1_valid_gated ),
    .disp1_pc          (dec1_pc           ),
    .disp1_imm         (dec1_imm          ),
    .disp1_func3       (dec1_func3        ),
    .disp1_func7       (dec1_func7        ),
    .disp1_rd          (dec1_rd           ),
    .disp1_br          (dec1_br           ),
    .disp1_mem_read    (dec1_mem_read     ),
    .disp1_mem2reg     (dec1_mem2reg      ),
    .disp1_alu_op      (dec1_alu_op       ),
    .disp1_mem_write   (dec1_mem_write    ),
    .disp1_alu_src1    (dec1_alu_src1     ),
    .disp1_alu_src2    (dec1_alu_src2     ),
    .disp1_br_addr_mode(dec1_br_addr_mode ),
    .disp1_regs_write  (dec1_regs_write   ),
    .disp1_rs1         (dec1_rs1          ),
    .disp1_rs2         (dec1_rs2          ),
    .disp1_rs1_used    (dec1_rs1_used     ),
    .disp1_rs2_used    (dec1_rs2_used     ),
    .disp1_fu          (dec1_fu           ),
    .disp1_tid         (dec1_tid          ),
    .disp1_is_mret     (dec1_is_mret      ),
    .disp1_is_csr      (dec1_is_csr       ),
    .disp1_is_rocc     (dec1_is_rocc      ),

    .disp_stall  (sb_disp_stall    ),
    .disp1_blocked(sb_disp1_blocked ),

    // Dispatch Tag Outputs (for ROB)
    .disp0_tag   (sb_disp0_tag     ),
    .disp1_tag   (sb_disp1_tag     ),

    // Dispatch Metadata
    .disp0_order_id    (disp0_order_id    ),
    .disp0_epoch       (disp0_epoch       ),
    .disp1_order_id    (disp1_order_id    ),
    .disp1_epoch       (disp1_epoch       ),

    // Issue port 0
    .iss0_valid        (iss0_valid        ),
    .iss0_tag          (iss0_tag          ),
    .iss0_pc           (iss0_pc           ),
    .iss0_imm          (iss0_imm          ),
    .iss0_func3        (iss0_func3        ),
    .iss0_func7        (iss0_func7        ),
    .iss0_rd           (iss0_rd           ),
    .iss0_rs1          (iss0_rs1          ),
    .iss0_rs2          (iss0_rs2          ),
    .iss0_rs1_used     (iss0_rs1_used     ),
    .iss0_rs2_used     (iss0_rs2_used     ),
    .iss0_src1_tag     (iss0_src1_tag     ),
    .iss0_src2_tag     (iss0_src2_tag     ),
    .iss0_br           (iss0_br           ),
    .iss0_mem_read     (iss0_mem_read     ),
    .iss0_mem2reg      (iss0_mem2reg      ),
    .iss0_alu_op       (iss0_alu_op       ),
    .iss0_mem_write    (iss0_mem_write    ),
    .iss0_alu_src1     (iss0_alu_src1     ),
    .iss0_alu_src2     (iss0_alu_src2     ),
    .iss0_br_addr_mode (iss0_br_addr_mode ),
    .iss0_regs_write   (iss0_regs_write   ),
    .iss0_fu           (iss0_fu           ),
    .iss0_tid          (iss0_tid          ),
    .iss0_order_id     (iss0_order_id     ),
    .iss0_epoch        (iss0_epoch        ),

    // Pipe1 candidate slots
    .p1_winner_valid   (p1_winner_valid   ),
    .p1_winner         (p1_winner         ),
    .p1_mem_cand_valid (p1_mem_cand_valid ),
    .p1_mem_cand_tag   (p1_mem_cand_tag   ),
    .p1_mem_cand_pc    (p1_mem_cand_pc    ),
    .p1_mem_cand_imm   (p1_mem_cand_imm   ),
    .p1_mem_cand_func3 (p1_mem_cand_func3 ),
    .p1_mem_cand_func7 (p1_mem_cand_func7 ),
    .p1_mem_cand_rd    (p1_mem_cand_rd    ),
    .p1_mem_cand_rs1   (p1_mem_cand_rs1   ),
    .p1_mem_cand_rs2   (p1_mem_cand_rs2   ),
    .p1_mem_cand_rs1_used(p1_mem_cand_rs1_used),
    .p1_mem_cand_rs2_used(p1_mem_cand_rs2_used),
    .p1_mem_cand_src1_tag(p1_mem_cand_src1_tag),
    .p1_mem_cand_src2_tag(p1_mem_cand_src2_tag),
    .p1_mem_cand_br    (p1_mem_cand_br    ),
    .p1_mem_cand_mem_read(p1_mem_cand_mem_read),
    .p1_mem_cand_mem2reg(p1_mem_cand_mem2reg),
    .p1_mem_cand_alu_op(p1_mem_cand_alu_op),
    .p1_mem_cand_mem_write(p1_mem_cand_mem_write),
    .p1_mem_cand_alu_src1(p1_mem_cand_alu_src1),
    .p1_mem_cand_alu_src2(p1_mem_cand_alu_src2),
    .p1_mem_cand_br_addr_mode(p1_mem_cand_br_addr_mode),
    .p1_mem_cand_regs_write(p1_mem_cand_regs_write),
    .p1_mem_cand_fu    (p1_mem_cand_fu    ),
    .p1_mem_cand_tid   (p1_mem_cand_tid   ),
    .p1_mem_cand_is_mret(),
    .p1_mem_cand_order_id(p1_mem_cand_order_id),
    .p1_mem_cand_epoch (p1_mem_cand_epoch ),
    .p1_mul_cand_valid (p1_mul_cand_valid ),
    .p1_mul_cand_tag   (p1_mul_cand_tag   ),
    .p1_mul_cand_pc    (p1_mul_cand_pc    ),
    .p1_mul_cand_imm   (p1_mul_cand_imm   ),
    .p1_mul_cand_func3 (p1_mul_cand_func3 ),
    .p1_mul_cand_func7 (p1_mul_cand_func7 ),
    .p1_mul_cand_rd    (p1_mul_cand_rd    ),
    .p1_mul_cand_rs1   (p1_mul_cand_rs1   ),
    .p1_mul_cand_rs2   (p1_mul_cand_rs2   ),
    .p1_mul_cand_rs1_used(p1_mul_cand_rs1_used),
    .p1_mul_cand_rs2_used(p1_mul_cand_rs2_used),
    .p1_mul_cand_src1_tag(p1_mul_cand_src1_tag),
    .p1_mul_cand_src2_tag(p1_mul_cand_src2_tag),
    .p1_mul_cand_br    (p1_mul_cand_br    ),
    .p1_mul_cand_mem_read(p1_mul_cand_mem_read),
    .p1_mul_cand_mem2reg(p1_mul_cand_mem2reg),
    .p1_mul_cand_alu_op(p1_mul_cand_alu_op),
    .p1_mul_cand_mem_write(p1_mul_cand_mem_write),
    .p1_mul_cand_alu_src1(p1_mul_cand_alu_src1),
    .p1_mul_cand_alu_src2(p1_mul_cand_alu_src2),
    .p1_mul_cand_br_addr_mode(p1_mul_cand_br_addr_mode),
    .p1_mul_cand_regs_write(p1_mul_cand_regs_write),
    .p1_mul_cand_fu    (p1_mul_cand_fu    ),
    .p1_mul_cand_tid   (p1_mul_cand_tid   ),
    .p1_mul_cand_is_mret(),
    .p1_mul_cand_order_id(p1_mul_cand_order_id),
    .p1_mul_cand_epoch (p1_mul_cand_epoch ),
    .p1_div_cand_valid (p1_div_cand_valid ),
    .p1_div_cand_tag   (p1_div_cand_tag   ),
    .p1_div_cand_pc    (p1_div_cand_pc    ),
    .p1_div_cand_imm   (p1_div_cand_imm   ),
    .p1_div_cand_func3 (p1_div_cand_func3 ),
    .p1_div_cand_func7 (p1_div_cand_func7 ),
    .p1_div_cand_rd    (p1_div_cand_rd    ),
    .p1_div_cand_rs1   (p1_div_cand_rs1   ),
    .p1_div_cand_rs2   (p1_div_cand_rs2   ),
    .p1_div_cand_rs1_used(p1_div_cand_rs1_used),
    .p1_div_cand_rs2_used(p1_div_cand_rs2_used),
    .p1_div_cand_src1_tag(p1_div_cand_src1_tag),
    .p1_div_cand_src2_tag(p1_div_cand_src2_tag),
    .p1_div_cand_br    (p1_div_cand_br    ),
    .p1_div_cand_mem_read(p1_div_cand_mem_read),
    .p1_div_cand_mem2reg(p1_div_cand_mem2reg),
    .p1_div_cand_alu_op(p1_div_cand_alu_op),
    .p1_div_cand_mem_write(p1_div_cand_mem_write),
    .p1_div_cand_alu_src1(p1_div_cand_alu_src1),
    .p1_div_cand_alu_src2(p1_div_cand_alu_src2),
    .p1_div_cand_br_addr_mode(p1_div_cand_br_addr_mode),
    .p1_div_cand_regs_write(p1_div_cand_regs_write),
    .p1_div_cand_fu    (p1_div_cand_fu    ),
    .p1_div_cand_tid   (p1_div_cand_tid   ),
    .p1_div_cand_is_mret(),
    .p1_div_cand_order_id(p1_div_cand_order_id),
    .p1_div_cand_epoch (p1_div_cand_epoch ),
    .branch_pending_any(sb_branch_pending_any),
    .debug_br_found_t0 (sb_debug_br_found_t0),
    .debug_branch_in_flight_t0(sb_debug_branch_in_flight_t0),
    .debug_oldest_br_ready_t0(sb_debug_oldest_br_ready_t0),
    .debug_oldest_br_just_woke_t0(sb_debug_oldest_br_just_woke_t0),
    .debug_oldest_br_qj_t0(sb_debug_oldest_br_qj_t0),
    .debug_oldest_br_qk_t0(sb_debug_oldest_br_qk_t0),
    .debug_slot1_flags(sb_debug_slot1_flags),
    .debug_slot1_pc_lo(sb_debug_slot1_pc_lo),
    .debug_slot1_qj(sb_debug_slot1_qj),
    .debug_slot1_qk(sb_debug_slot1_qk),
    .debug_tag2_flags(sb_debug_tag2_flags),
    .debug_reg_x12_tag_t0(sb_debug_reg_x12_tag_t0),
    .debug_slot1_issue_flags(sb_debug_slot1_issue_flags),
    .debug_sel0_idx(sb_debug_sel0_idx),
    .debug_slot1_fu(sb_debug_slot1_fu),
    .debug_oldest_br_seq_lo_t0(sb_debug_oldest_br_seq_lo_t0),
    .debug_rs_flags_flat(sb_debug_rs_flags_flat),
    .debug_rs_pc_lo_flat(sb_debug_rs_pc_lo_flat),
    .debug_rs_fu_flat(sb_debug_rs_fu_flat),
    .debug_rs_qj_flat(sb_debug_rs_qj_flat),
    .debug_rs_qk_flat(sb_debug_rs_qk_flat),
    .debug_rs_seq_lo_flat(sb_debug_rs_seq_lo_flat),
    .debug_spec_dispatch0(sb_debug_spec_dispatch0),
    .debug_spec_dispatch1(sb_debug_spec_dispatch1),
    .debug_branch_gated_mem_issue(sb_debug_branch_gated_mem_issue),
    .debug_flush_killed_speculative(sb_debug_flush_killed_speculative),

    // Writeback ports
    .wb0_valid       (wb0_valid       ),
    .wb0_tag         (wb0_tag         ),
    .wb0_rd          (wb0_rd          ),
    .wb0_regs_write  (wb0_regs_write  ),
    .wb0_fu          (wb0_fu          ),
    .wb0_tid         (wb0_tid         ),
    .wb1_valid       (wb1_valid       ),
    .wb1_tag         (wb1_tag         ),
    .wb1_rd          (wb1_rd          ),
    .wb1_regs_write  (wb1_regs_write  ),
    .wb1_fu          (wb1_fu          ),
    .wb1_tid         (wb1_tid         ),
    .lsu_early_wakeup_valid(lsu_early_wakeup_valid),
    .lsu_early_wakeup_tag(lsu_early_wakeup_tag),
    .commit0_valid   (rob_commit0_valid),
    .commit0_tag     (rob_commit0_tag  ),
    .commit0_tid     (1'b0             ),
    .commit0_order_id(rob_commit0_order_id),
    .commit1_valid   (rob_commit1_valid),
    .commit1_tag     (rob_commit1_tag  ),
    .commit1_tid     (1'b1             ),
    .commit1_order_id(rob_commit1_order_id),

    // Branch completion
    .br_complete     (scoreboard_br_complete),

    // RoCC backpressure
    .rocc_ready      (rocc_cmd_ready),
    .iss0_is_rocc    (iss0_is_rocc)
);

wire       p1_issue_is_mem     = (p1_winner == 2'b10);
wire       p1_issue_is_div     = (p1_winner == 2'b01);
wire [0:0] p1_issue_arch_tid   = p1_issue_is_mem ? p1_mem_cand_tid :
                                  p1_issue_is_div ? p1_div_cand_tid : p1_mul_cand_tid;
wire [`METADATA_ORDER_ID_W-1:0] p1_issue_arch_order_id =
                                  p1_issue_is_mem ? p1_mem_cand_order_id :
                                  p1_issue_is_div ? p1_div_cand_order_id : p1_mul_cand_order_id;
wire [4:0] p1_issue_arch_rs1   = p1_issue_is_mem ? p1_mem_cand_rs1 :
                                  p1_issue_is_div ? p1_div_cand_rs1 : p1_mul_cand_rs1;
wire [4:0] p1_issue_arch_rs2   = p1_issue_is_mem ? p1_mem_cand_rs2 :
                                  p1_issue_is_div ? p1_div_cand_rs2 : p1_mul_cand_rs2;

// ════════════════════════════════════════════════════════════════════════════
// ROB Lite (Reorder Buffer for in-order commit)
// ════════════════════════════════════════════════════════════════════════════

// Calculate is_store for dispatch
wire disp0_is_store = (dec0_fu == `FU_STORE);
wire disp1_is_store = (dec1_fu == `FU_STORE);

// Dispatch tag wires from scoreboard

// Per-tag SYSTEM metadata (decoder → scoreboard issue sideband)
reg        rs_is_csr  [0:31];
reg        rs_is_mret [0:31];
reg [11:0] rs_csr_addr[0:31];
reg        rs_pred_taken [0:31];
reg [31:0] rs_pred_target[0:31];
integer    sys_meta_idx;

// Per-tag RoCC metadata (decoder → scoreboard issue sideband)
reg        rs_is_rocc    [0:31];
reg [6:0]  rs_rocc_funct7[0:31];
integer    rocc_meta_idx;

rob #(
    .ROB_DEPTH      (16),
    .ROB_IDX_W      (4),
    .RS_TAG_W       (5),
    .PHYS_REG_W     (6),
    .NUM_THREAD     (2)
) u_rob (
    .clk                (clk),
    .rstn               (rstn),

    // Flush interface
    .flush              (combined_flush_any),
    .flush_tid          (trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid),
    .flush_new_epoch    ((trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid) ? flush_new_epoch_t1 : flush_new_epoch_t0),
    .flush_order_valid  (flush_is_order_based),
    .flush_order_id     (flush_order_id_mux),

    // Dispatch Port 0
    .disp0_valid        (disp0_accepted),
    .disp0_tag          (sb_disp0_tag),
    .disp0_tid          (dec0_tid),
    .disp0_order_id     (disp0_order_id),
    .disp0_epoch        (disp0_epoch),
    .disp0_rd           (dec0_rd),
    .disp0_is_store     (disp0_is_store),
    .disp0_is_mret      (dec0_is_mret),
    .disp0_prd_new      (shadow_alloc0_valid ? fl_alloc0_prd : 6'd0),
    .disp0_prd_old      (rmt_prd0_old),
    .disp0_is_branch    (dec0_br),
    .disp0_regs_write   (dec0_regs_write),
    .disp0_pc           (dec0_pc),
    .rob0_full          (rob0_full),
    .disp0_rob_idx      (rob_disp0_rob_idx),

    // Dispatch Port 1
    .disp1_valid        (disp1_accepted),
    .disp1_tag          (sb_disp1_tag),
    .disp1_tid          (dec1_tid),
    .disp1_order_id     (disp1_order_id),
    .disp1_epoch        (disp1_epoch),
    .disp1_rd           (dec1_rd),
    .disp1_is_store     (disp1_is_store),
    .disp1_is_mret      (dec1_is_mret),
    .disp1_prd_new      (shadow_alloc1_valid ? fl_alloc1_prd : 6'd0),
    .disp1_prd_old      (rmt_prd1_old),
    .disp1_is_branch    (dec1_br),
    .disp1_regs_write   (dec1_regs_write),
    .disp1_pc           (dec1_pc),
    .rob1_full          (rob1_full),
    .disp1_rob_idx      (rob_disp1_rob_idx),

    // Writeback Port 0
    .wb0_valid          (wb0_valid),
    .wb0_tag            (wb0_tag),
    .wb0_tid            (wb0_tid),
    .wb0_data           (wb0_result_data),
    .wb0_regs_write     (wb0_regs_write),

    // Writeback Port 1
    .wb1_valid          (wb1_valid),
    .wb1_tag            (wb1_tag),
    .wb1_tid            (wb1_tid),
    .wb1_data           (wb1_result_data),
    .wb1_regs_write     (wb1_regs_write),

    // Commit Outputs
    .commit0_valid      (rob_commit0_valid),
    .commit1_valid      (rob_commit1_valid),
    .commit0_rd         (rob_commit0_rd),
    .commit1_rd         (rob_commit1_rd),
    .instr_retired      (rob_instr_retired),

    // Commit Data Outputs
    .commit0_tag        (rob_commit0_tag),
    .commit1_tag        (rob_commit1_tag),
    .commit0_has_result (rob_commit0_has_result),
    .commit1_has_result (rob_commit1_has_result),
    .commit0_data       (rob_commit0_data),
    .commit1_data       (rob_commit1_data),

    // Store Buffer Commit Outputs
    .commit0_order_id   (rob_commit0_order_id),
    .commit1_order_id   (rob_commit1_order_id),
    .commit0_is_store   (rob_commit0_is_store),
    .commit1_is_store   (rob_commit1_is_store),
    .commit0_is_mret    (rob_commit0_is_mret),
    .commit1_is_mret    (rob_commit1_is_mret),

    // Rename Commit Outputs (Stage A: unused)
    .commit0_prd_old         (rob_commit0_prd_old),
    .commit0_regs_write_out  (rob_commit0_regs_write),
    .commit1_prd_old         (rob_commit1_prd_old),
    .commit1_regs_write_out  (rob_commit1_regs_write),

    // Recovery Walk Interface (Stage A: unused)
    .recover_walk_active (rob_recover_walk_active),
    .recover_en          (rob_recover_en),
    .recover_rd          (rob_recover_rd),
    .recover_prd_old     (rob_recover_prd_old),
    .recover_prd_new     (rob_recover_prd_new),
    .recover_regs_write  (rob_recover_regs_write),
    .recover_tid         (rob_recover_tid),
    .debug_commit_suppressed(rob_debug_commit_suppressed),
    .head_valid_t0       (rob_head_valid_t0),
    .head_order_id_t0    (rob_head_order_id_t0),
    .head_flushed_t0     (rob_head_flushed_t0),
    .head_valid_t1       (rob_head_valid_t1),
    .head_order_id_t1    (rob_head_order_id_t1),
    .head_flushed_t1     (rob_head_flushed_t1)
);

// ════════════════════════════════════════════════════════════════════════════
// STAGE 4b: Rename Map Table + Freelist (Shadow – not yet on critical path)
// ════════════════════════════════════════════════════════════════════════════
// Rename outputs (shadow – unused by scoreboard path for now)
wire [5:0] rmt_prs0_1, rmt_prs0_2, rmt_prd0_old;
wire [5:0] rmt_prs1_1, rmt_prs1_2, rmt_prd1_old;
wire       rmt_prs0_1_ready, rmt_prs0_2_ready;
wire       rmt_prs1_1_ready, rmt_prs1_2_ready;

// Freelist outputs (shadow)
wire [5:0] fl_alloc0_prd, fl_alloc1_prd;
wire       fl_can_alloc_1, fl_can_alloc_2;

// Shadow rename alloc valid: inst writes to rd != x0
wire shadow_alloc0_valid = disp0_accepted && dec0_regs_write && (dec0_rd != 5'd0);
wire shadow_alloc1_valid = disp1_accepted && dec1_regs_write && (dec1_rd != 5'd0);

rename_map_table #(
    .PHYS_REG_W   (6),
    .NUM_PHYS_REG (48)
) u_rename_map_table (
    .clk            (clk),
    .rstn           (rstn),
    .tid            (dec0_tid),
    // Inst 0 lookup
    .lookup0_rs1    (dec0_rs1),
    .lookup0_rs2    (dec0_rs2),
    .lookup0_rd     (dec0_rd),
    // Inst 1 lookup
    .lookup1_rs1    (dec1_rs1),
    .lookup1_rs2    (dec1_rs2),
    .lookup1_rd     (dec1_rd),
    // Inst 0 rename outputs
    .prs0_1         (rmt_prs0_1),
    .prs0_2         (rmt_prs0_2),
    .prd0_old       (rmt_prd0_old),
    // Inst 1 rename outputs
    .prs1_1         (rmt_prs1_1),
    .prs1_2         (rmt_prs1_2),
    .prd1_old       (rmt_prd1_old),
    // Ready bits
    .prs0_1_ready   (rmt_prs0_1_ready),
    .prs0_2_ready   (rmt_prs0_2_ready),
    .prs1_1_ready   (rmt_prs1_1_ready),
    .prs1_2_ready   (rmt_prs1_2_ready),
    // Rename update
    .alloc0_valid   (shadow_alloc0_valid),
    .alloc0_rd      (dec0_rd),
    .alloc0_prd_new (fl_alloc0_prd),
    .alloc1_valid   (shadow_alloc1_valid),
    .alloc1_rd      (dec1_rd),
    .alloc1_prd_new (fl_alloc1_prd),
    // CDB writeback (mark phys reg as ready at WB time)
    .cdb0_valid     (wb0_valid && wb0_regs_write),
    .cdb0_prd       (tag_prd_map[wb0_tag]),
    .cdb1_valid     (wb1_valid && wb1_regs_write),
    .cdb1_prd       (tag_prd_map[wb1_tag]),
    // Recovery
    .recover_en     (rob_recover_en),
    .recover_rd     (rob_recover_rd),
    .recover_prd    (rob_recover_prd_old),
    .recover_tid    (rob_recover_tid),
    // Bulk reset
    .reset_to_arch  (1'b0),
    .reset_tid      (1'b0)
);

freelist #(
    .PHYS_REG_W (6),
    .NUM_FREE   (16),
    .FL_DEPTH   (64),
    .FL_IDX_W   (6)
) u_freelist (
    .clk                (clk),
    .rstn               (rstn),
    .tid                (dec0_tid),
    // Alloc
    .alloc0_req         (shadow_alloc0_valid),
    .alloc0_prd         (fl_alloc0_prd),
    .alloc1_req         (shadow_alloc1_valid),
    .alloc1_prd         (fl_alloc1_prd),
    .can_alloc_1        (fl_can_alloc_1),
    .can_alloc_2        (fl_can_alloc_2),
    // Free at commit
    .free0_valid        (rob_commit0_valid && rob_commit0_regs_write),
    .free0_prd          (rob_commit0_prd_old),
    .free0_tid          (1'b0),   // commit0 is always thread 0
    .free1_valid        (rob_commit1_valid && rob_commit1_regs_write),
    .free1_prd          (rob_commit1_prd_old),
    .free1_tid          (1'b1),   // commit1 is always thread 1
    // Recovery push
    .recover_push_valid (rob_recover_en && rob_recover_regs_write),
    .recover_push_prd   (rob_recover_prd_new),
    .recover_push_tid   (rob_recover_tid),
    // Bulk reset
    .reset_list         (1'b0),
    .reset_tid          (1'b0)
);

// ════════════════════════════════════════════════════════════════════════════
// STAGE 5: Read Operands (dual-port register file access)
// ════════════════════════════════════════════════════════════════════════════
// Port 0 operands (for Pipe 0)
wire [31:0] ro0_data1, ro0_data2;

// We reuse the existing regs_mt for port 0 read
// Port 1 uses the same register file with a second read port
// For simplicity: time-multiplex or add a second regs_mt reader
// Here: instantiate single regs_mt with port 0 read + WB write port 0

wire        w_regs_en_0;     // WB write enable (from pipe 0 result)
wire [4:0]  w_regs_addr_0;
wire [31:0] w_regs_data_0;
wire [0:0]  w_regs_tid_0;

wire        w_regs_en_1;     // WB write enable (from pipe 1 / MEM result)
wire [4:0]  w_regs_addr_1;
wire [31:0] w_regs_data_1;
wire [0:0]  w_regs_tid_1;

// Register file: use a dual-write port wrapper by instantiating regs_mt twice
// For now: single write port, prioritize pipe 0 writeback, pipe 1 writes next cycle
// (simplified approach for correctness; true dual-port can be added)

// Dual write ports for dual-issue support
regs_mt #(.N_T(2)) u_regs_mt(
    .clk            (clk             ),
    .rstn           (rstn            ),
    .r_thread_id    (iss0_tid        ),
    .r_regs_addr1   (iss0_rs1        ),
    .r_regs_addr2   (iss0_rs2        ),
    .w_thread_id_0  (w_regs_tid_0    ),
    .w_regs_addr_0  (w_regs_addr_0   ),
    .w_regs_data_0  (w_regs_data_0   ),
    .w_regs_en_0    (w_regs_en_0     ),
    .w_thread_id_1  (w_regs_tid_1    ),
    .w_regs_addr_1  (w_regs_addr_1   ),
    .w_regs_data_1  (w_regs_data_1   ),
    .w_regs_en_1    (w_regs_en_1     ),
    .r_regs_o1      (ro0_data1       ),
    .r_regs_o2      (ro0_data2       )
);

// Port 1 read: second instance for pipe1 operands
wire [31:0] ro1_data1, ro1_data2;

regs_mt #(.N_T(2)) u_regs_mt_p1(
    .clk            (clk             ),
    .rstn           (rstn            ),
    .r_thread_id    (p1_issue_arch_tid),
    .r_regs_addr1   (p1_issue_arch_rs1),
    .r_regs_addr2   (p1_issue_arch_rs2),
    .w_thread_id_0  (w_regs_tid_0    ),
    .w_regs_addr_0  (w_regs_addr_0   ),
    .w_regs_data_0  (w_regs_data_0   ),
    .w_regs_en_0    (w_regs_en_0     ),
    .w_thread_id_1  (w_regs_tid_1    ),
    .w_regs_addr_1  (w_regs_addr_1   ),
    .w_regs_data_1  (w_regs_data_1   ),
    .w_regs_en_1    (w_regs_en_1     ),
    .r_regs_o1      (ro1_data1       ),
    .r_regs_o2      (ro1_data2       )
);

// ═══ Physical Register File — written at WB time (speculative state) ═══
wire [31:0] prf_r0_data, prf_r1_data, prf_r2_data, prf_r3_data;

// PRF write signals: write at WB using phys reg from tag_prd_map
wire        prf_w0_en   = wb0_valid && wb0_regs_write && (tag_prd_map[wb0_tag] != 6'd0);
wire [5:0]  prf_w0_addr = tag_prd_map[wb0_tag];
wire [0:0]  prf_w0_tid  = tag_tid_map[wb0_tag];
wire [31:0] prf_w0_data = wb0_result_data;

wire        prf_w1_en   = wb1_valid && wb1_regs_write && (tag_prd_map[wb1_tag] != 6'd0);
wire [5:0]  prf_w1_addr = tag_prd_map[wb1_tag];
wire [0:0]  prf_w1_tid  = tag_tid_map[wb1_tag];
wire [31:0] prf_w1_data = wb1_result_data;

// ════════════════════════════════════════════════════════════════════════════
// Pipe1 Pre-RO Stage
//   Split the long path:
//     IQ/MEM winner select -> tag_prs fanout -> PRF read -> bypass -> ro1
//   into two stages:
//     1) issue/select -> p1_pre_ro (metadata + phys addrs + src tags)
//     2) PRF read -> tagbuf bypass -> ro1
//   This applies to all builds so the functional timing model stays uniform.
// ════════════════════════════════════════════════════════════════════════════
reg         p0_pre_ro_valid;
reg  [4:0]  p0_pre_ro_tag;
reg  [31:0] p0_pre_ro_pc;
reg  [31:0] p0_pre_ro_imm;
reg  [2:0]  p0_pre_ro_func3;
reg         p0_pre_ro_func7;
reg  [4:0]  p0_pre_ro_rd;
reg  [4:0]  p0_pre_ro_rs1, p0_pre_ro_rs2;
reg         p0_pre_ro_rs1_used, p0_pre_ro_rs2_used;
reg  [4:0]  p0_pre_ro_src1_tag, p0_pre_ro_src2_tag;
reg  [2:0]  p0_pre_ro_alu_op;
reg  [1:0]  p0_pre_ro_alu_src1, p0_pre_ro_alu_src2;
reg         p0_pre_ro_br;
reg         p0_pre_ro_mem_read, p0_pre_ro_mem_write, p0_pre_ro_mem2reg;
reg         p0_pre_ro_regs_write, p0_pre_ro_br_addr_mode;
reg  [2:0]  p0_pre_ro_fu;
reg  [0:0]  p0_pre_ro_tid;
reg  [`METADATA_ORDER_ID_W-1:0] p0_pre_ro_order_id;
reg  [`METADATA_EPOCH_W-1:0]    p0_pre_ro_epoch;
reg         p0_pre_ro_pred_taken;
reg  [31:0] p0_pre_ro_pred_target;
reg  [5:0]  p0_pre_ro_prs1, p0_pre_ro_prs2;
reg         p0_pre_ro_is_csr, p0_pre_ro_is_mret;
reg  [11:0] p0_pre_ro_csr_addr;
reg         p0_pre_ro_is_rocc;
reg  [6:0]  p0_pre_ro_rocc_funct7;

reg         p1_pre_ro_valid;
reg  [4:0]  p1_pre_ro_tag;
reg  [31:0] p1_pre_ro_pc;
reg  [31:0] p1_pre_ro_imm;
reg  [2:0]  p1_pre_ro_func3;
reg         p1_pre_ro_func7;
reg  [4:0]  p1_pre_ro_rd;
reg  [4:0]  p1_pre_ro_rs1, p1_pre_ro_rs2;
reg         p1_pre_ro_rs1_used, p1_pre_ro_rs2_used;
reg  [4:0]  p1_pre_ro_src1_tag, p1_pre_ro_src2_tag;
reg  [2:0]  p1_pre_ro_alu_op;
reg  [1:0]  p1_pre_ro_alu_src1, p1_pre_ro_alu_src2;
reg         p1_pre_ro_br;
reg         p1_pre_ro_mem_read, p1_pre_ro_mem_write, p1_pre_ro_mem2reg;
reg         p1_pre_ro_regs_write, p1_pre_ro_br_addr_mode;
reg  [2:0]  p1_pre_ro_fu;
reg  [0:0]  p1_pre_ro_tid;
reg  [`METADATA_ORDER_ID_W-1:0] p1_pre_ro_order_id;
reg  [`METADATA_EPOCH_W-1:0]    p1_pre_ro_epoch;
reg  [5:0]  p1_pre_ro_prs1, p1_pre_ro_prs2;

wire iss0_flush_kill =
    combined_flush_any && (iss0_tid == flush_tid_mux) &&
    (!flush_is_order_based || (iss0_order_id > flush_order_id_mux));
wire p1_winner_flush_kill =
    combined_flush_any && (p1_issue_arch_tid == flush_tid_mux) &&
    (!flush_is_order_based || (p1_issue_arch_order_id > flush_order_id_mux));
wire p0_pre_ro_flush_kill =
    combined_flush_any && (p0_pre_ro_tid == flush_tid_mux) &&
    (!flush_is_order_based || (p0_pre_ro_order_id > flush_order_id_mux));
wire p1_pre_ro_flush_kill =
    combined_flush_any && (p1_pre_ro_tid == flush_tid_mux) &&
    (!flush_is_order_based || (p1_pre_ro_order_id > flush_order_id_mux));

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        p0_pre_ro_valid <= 1'b0;
        p1_pre_ro_valid <= 1'b0;
    end else begin
        p0_pre_ro_valid <= iss0_valid && !iss0_flush_kill;
        if (iss0_valid && !iss0_flush_kill) begin
            p0_pre_ro_tag          <= iss0_tag;
            p0_pre_ro_pc           <= iss0_pc;
            p0_pre_ro_imm          <= iss0_imm;
            p0_pre_ro_func3        <= iss0_func3;
            p0_pre_ro_func7        <= iss0_func7;
            p0_pre_ro_rd           <= iss0_rd;
            p0_pre_ro_rs1          <= iss0_rs1;
            p0_pre_ro_rs2          <= iss0_rs2;
            p0_pre_ro_rs1_used     <= iss0_rs1_used;
            p0_pre_ro_rs2_used     <= iss0_rs2_used;
            p0_pre_ro_src1_tag     <= iss0_src1_tag;
            p0_pre_ro_src2_tag     <= iss0_src2_tag;
            p0_pre_ro_alu_op       <= iss0_alu_op;
            p0_pre_ro_alu_src1     <= iss0_alu_src1;
            p0_pre_ro_alu_src2     <= iss0_alu_src2;
            p0_pre_ro_br           <= iss0_br;
            p0_pre_ro_mem_read     <= iss0_mem_read;
            p0_pre_ro_mem_write    <= iss0_mem_write;
            p0_pre_ro_mem2reg      <= iss0_mem2reg;
            p0_pre_ro_regs_write   <= iss0_regs_write;
            p0_pre_ro_br_addr_mode <= iss0_br_addr_mode;
            p0_pre_ro_fu           <= iss0_fu;
            p0_pre_ro_tid          <= iss0_tid;
            p0_pre_ro_order_id     <= iss0_order_id;
            p0_pre_ro_epoch        <= iss0_epoch;
            p0_pre_ro_pred_taken   <= iss0_pred_taken;
            p0_pre_ro_pred_target  <= iss0_pred_target;
            p0_pre_ro_prs1         <= tag_prs1_map[iss0_tag];
            p0_pre_ro_prs2         <= tag_prs2_map[iss0_tag];
            p0_pre_ro_is_csr       <= iss0_is_csr;
            p0_pre_ro_is_mret      <= iss0_is_mret;
            p0_pre_ro_csr_addr     <= iss0_csr_addr;
            p0_pre_ro_is_rocc      <= iss0_is_rocc;
            p0_pre_ro_rocc_funct7  <= iss0_rocc_funct7;
        end

        p1_pre_ro_valid <= p1_winner_valid && !p1_winner_flush_kill;
        if (p1_winner_valid && !p1_winner_flush_kill) begin
            if (p1_issue_is_mem) begin
                p1_pre_ro_tag          <= p1_mem_cand_tag;
                p1_pre_ro_pc           <= p1_mem_cand_pc;
                p1_pre_ro_imm          <= p1_mem_cand_imm;
                p1_pre_ro_func3        <= p1_mem_cand_func3;
                p1_pre_ro_func7        <= p1_mem_cand_func7;
                p1_pre_ro_rd           <= p1_mem_cand_rd;
                p1_pre_ro_rs1          <= p1_mem_cand_rs1;
                p1_pre_ro_rs2          <= p1_mem_cand_rs2;
                p1_pre_ro_rs1_used     <= p1_mem_cand_rs1_used;
                p1_pre_ro_rs2_used     <= p1_mem_cand_rs2_used;
                p1_pre_ro_src1_tag     <= p1_mem_cand_src1_tag;
                p1_pre_ro_src2_tag     <= p1_mem_cand_src2_tag;
                p1_pre_ro_alu_op       <= p1_mem_cand_alu_op;
                p1_pre_ro_alu_src1     <= p1_mem_cand_alu_src1;
                p1_pre_ro_alu_src2     <= p1_mem_cand_alu_src2;
                p1_pre_ro_br           <= p1_mem_cand_br;
                p1_pre_ro_mem_read     <= p1_mem_cand_mem_read;
                p1_pre_ro_mem_write    <= p1_mem_cand_mem_write;
                p1_pre_ro_mem2reg      <= p1_mem_cand_mem2reg;
                p1_pre_ro_regs_write   <= p1_mem_cand_regs_write;
                p1_pre_ro_br_addr_mode <= p1_mem_cand_br_addr_mode;
                p1_pre_ro_fu           <= p1_mem_cand_fu;
                p1_pre_ro_tid          <= p1_mem_cand_tid;
                p1_pre_ro_order_id     <= p1_mem_cand_order_id;
                p1_pre_ro_epoch        <= p1_mem_cand_epoch;
                p1_pre_ro_prs1         <= tag_prs1_map[p1_mem_cand_tag];
                p1_pre_ro_prs2         <= tag_prs2_map[p1_mem_cand_tag];
            end else if (p1_issue_is_div) begin
                p1_pre_ro_tag          <= p1_div_cand_tag;
                p1_pre_ro_pc           <= p1_div_cand_pc;
                p1_pre_ro_imm          <= p1_div_cand_imm;
                p1_pre_ro_func3        <= p1_div_cand_func3;
                p1_pre_ro_func7        <= p1_div_cand_func7;
                p1_pre_ro_rd           <= p1_div_cand_rd;
                p1_pre_ro_rs1          <= p1_div_cand_rs1;
                p1_pre_ro_rs2          <= p1_div_cand_rs2;
                p1_pre_ro_rs1_used     <= p1_div_cand_rs1_used;
                p1_pre_ro_rs2_used     <= p1_div_cand_rs2_used;
                p1_pre_ro_src1_tag     <= p1_div_cand_src1_tag;
                p1_pre_ro_src2_tag     <= p1_div_cand_src2_tag;
                p1_pre_ro_alu_op       <= p1_div_cand_alu_op;
                p1_pre_ro_alu_src1     <= p1_div_cand_alu_src1;
                p1_pre_ro_alu_src2     <= p1_div_cand_alu_src2;
                p1_pre_ro_br           <= p1_div_cand_br;
                p1_pre_ro_mem_read     <= p1_div_cand_mem_read;
                p1_pre_ro_mem_write    <= p1_div_cand_mem_write;
                p1_pre_ro_mem2reg      <= p1_div_cand_mem2reg;
                p1_pre_ro_regs_write   <= p1_div_cand_regs_write;
                p1_pre_ro_br_addr_mode <= p1_div_cand_br_addr_mode;
                p1_pre_ro_fu           <= p1_div_cand_fu;
                p1_pre_ro_tid          <= p1_div_cand_tid;
                p1_pre_ro_order_id     <= p1_div_cand_order_id;
                p1_pre_ro_epoch        <= p1_div_cand_epoch;
                p1_pre_ro_prs1         <= tag_prs1_map[p1_div_cand_tag];
                p1_pre_ro_prs2         <= tag_prs2_map[p1_div_cand_tag];
            end else begin
                p1_pre_ro_tag          <= p1_mul_cand_tag;
                p1_pre_ro_pc           <= p1_mul_cand_pc;
                p1_pre_ro_imm          <= p1_mul_cand_imm;
                p1_pre_ro_func3        <= p1_mul_cand_func3;
                p1_pre_ro_func7        <= p1_mul_cand_func7;
                p1_pre_ro_rd           <= p1_mul_cand_rd;
                p1_pre_ro_rs1          <= p1_mul_cand_rs1;
                p1_pre_ro_rs2          <= p1_mul_cand_rs2;
                p1_pre_ro_rs1_used     <= p1_mul_cand_rs1_used;
                p1_pre_ro_rs2_used     <= p1_mul_cand_rs2_used;
                p1_pre_ro_src1_tag     <= p1_mul_cand_src1_tag;
                p1_pre_ro_src2_tag     <= p1_mul_cand_src2_tag;
                p1_pre_ro_alu_op       <= p1_mul_cand_alu_op;
                p1_pre_ro_alu_src1     <= p1_mul_cand_alu_src1;
                p1_pre_ro_alu_src2     <= p1_mul_cand_alu_src2;
                p1_pre_ro_br           <= p1_mul_cand_br;
                p1_pre_ro_mem_read     <= p1_mul_cand_mem_read;
                p1_pre_ro_mem_write    <= p1_mul_cand_mem_write;
                p1_pre_ro_mem2reg      <= p1_mul_cand_mem2reg;
                p1_pre_ro_regs_write   <= p1_mul_cand_regs_write;
                p1_pre_ro_br_addr_mode <= p1_mul_cand_br_addr_mode;
                p1_pre_ro_fu           <= p1_mul_cand_fu;
                p1_pre_ro_tid          <= p1_mul_cand_tid;
                p1_pre_ro_order_id     <= p1_mul_cand_order_id;
                p1_pre_ro_epoch        <= p1_mul_cand_epoch;
                p1_pre_ro_prs1         <= tag_prs1_map[p1_mul_cand_tag];
                p1_pre_ro_prs2         <= tag_prs2_map[p1_mul_cand_tag];
            end
        end
    end
end


phys_regfile #(
    .NUM_PHYS_REG (48),
    .PHYS_REG_W   (6)
) u_phys_regfile (
    .clk    (clk),
    .rstn   (rstn),
    // Read ports (using phys reg addresses from tag→prs sideband maps)
    .r0_tid  (p0_pre_ro_tid),  .r0_addr (p0_pre_ro_prs1), .r0_data (prf_r0_data),
    .r1_tid  (p0_pre_ro_tid),  .r1_addr (p0_pre_ro_prs2), .r1_data (prf_r1_data),
    .r2_tid  (p1_pre_ro_tid),  .r2_addr (p1_pre_ro_prs1), .r2_data (prf_r2_data),
    .r3_tid  (p1_pre_ro_tid),  .r3_addr (p1_pre_ro_prs2), .r3_data (prf_r3_data),
    // Write ports (at WB time – speculative writes)
    .w0_en   (prf_w0_en),  .w0_tid (prf_w0_tid), .w0_addr (prf_w0_addr), .w0_data (prf_w0_data),
    .w1_en   (prf_w1_en),  .w1_tid (prf_w1_tid), .w1_addr (prf_w1_addr), .w1_data (prf_w1_data)
);

// Order ID increment logic (after scoreboard is defined)
// Dispatch is accepted when valid is asserted and stall is not asserted
wire disp0_accepted = disp0_valid_gated && !sb_disp_stall;
wire disp1_accepted = disp1_valid_gated && !sb_disp_stall && !sb_disp1_blocked;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        mret_pending_t0       <= 1'b0;
        mret_pending_t1       <= 1'b0;
        mret_pending_order_t0 <= {`METADATA_ORDER_ID_W{1'b0}};
        mret_pending_order_t1 <= {`METADATA_ORDER_ID_W{1'b0}};
        csr_pending_t0        <= 1'b0;
        csr_pending_t1        <= 1'b0;
        csr_pending_order_t0  <= {`METADATA_ORDER_ID_W{1'b0}};
        csr_pending_order_t1  <= {`METADATA_ORDER_ID_W{1'b0}};
    end else begin
        if (combined_flush_any) begin
            if (!flush_is_order_based) begin
                if (flush_tid_mux == 1'b0) begin
                    mret_pending_t0 <= 1'b0;
                    csr_pending_t0  <= 1'b0;
                end else begin
                    mret_pending_t1 <= 1'b0;
                    csr_pending_t1  <= 1'b0;
                end
            end else begin
                if (mret_pending_t0 && flush_tid_mux == 1'b0 &&
                    mret_pending_order_t0 > flush_order_id_mux)
                    mret_pending_t0 <= 1'b0;
                if (mret_pending_t1 && flush_tid_mux == 1'b1 &&
                    mret_pending_order_t1 > flush_order_id_mux)
                    mret_pending_t1 <= 1'b0;
                if (csr_pending_t0 && flush_tid_mux == 1'b0 &&
                    csr_pending_order_t0 > flush_order_id_mux)
                    csr_pending_t0 <= 1'b0;
                if (csr_pending_t1 && flush_tid_mux == 1'b1 &&
                    csr_pending_order_t1 > flush_order_id_mux)
                    csr_pending_t1 <= 1'b0;
            end
        end

        if (pipe0_mret_valid) begin
            if (p0_pre_ro_tid == 1'b0)
                mret_pending_t0 <= 1'b0;
            else
                mret_pending_t1 <= 1'b0;
        end

        if (pipe0_csr_valid) begin
            if (p0_pre_ro_tid == 1'b0)
                csr_pending_t0 <= 1'b0;
            else
                csr_pending_t1 <= 1'b0;
        end

        if (disp0_accepted && dec0_is_mret) begin
            if (dec0_tid == 1'b0) begin
                mret_pending_t0       <= 1'b1;
                mret_pending_order_t0 <= disp0_order_id;
            end else begin
                mret_pending_t1       <= 1'b1;
                mret_pending_order_t1 <= disp0_order_id;
            end
        end
        if (disp1_accepted && dec1_is_mret) begin
            if (dec1_tid == 1'b0) begin
                mret_pending_t0       <= 1'b1;
                mret_pending_order_t0 <= disp1_order_id;
            end else begin
                mret_pending_t1       <= 1'b1;
                mret_pending_order_t1 <= disp1_order_id;
            end
        end

        if (disp0_accepted && dec0_is_csr) begin
            if (dec0_tid == 1'b0) begin
                csr_pending_t0       <= 1'b1;
                csr_pending_order_t0 <= disp0_order_id;
            end else begin
                csr_pending_t1       <= 1'b1;
                csr_pending_order_t1 <= disp0_order_id;
            end
        end
        if (disp1_accepted && dec1_is_csr) begin
            if (dec1_tid == 1'b0) begin
                csr_pending_t0       <= 1'b1;
                csr_pending_order_t0 <= disp1_order_id;
            end else begin
                csr_pending_t1       <= 1'b1;
                csr_pending_order_t1 <= disp1_order_id;
            end
        end
    end
end

// Best-effort trap resume PC for interrupt entry.
// Prefer the oldest visible in-flight PC, and avoid overwriting it with
// speculative control-flow fall-through PCs from decode/fetch.
reg [31:0] trap_pc_r;
wire trap_pc_speculative = sb_branch_pending_any ||
                           pipe0_br_ctrl ||
                           pipe0_br_complete ||
                           mret_pending_t0 ||
                           mret_pending_t1 ||
                           csr_pending_t0 ||
                           csr_pending_t1 ||
                           (p0_pre_ro_valid && p0_pre_ro_is_mret) ||
                           pipe0_mret_valid;
wire trap_pc_fetch_safe = !trap_pc_speculative && !dec0_br && !dec1_br;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        trap_pc_r <= 32'd0;
    end else if (p0_pre_ro_valid && !p0_pre_ro_br && !trap_pc_speculative) begin
        trap_pc_r <= p0_pre_ro_pc;
    end else if (dec0_valid && !dec0_br && !trap_pc_speculative) begin
        trap_pc_r <= dec0_pc;
    end else if (fb_pop0_valid && trap_pc_fetch_safe) begin
        trap_pc_r <= fb_pop0_pc;
    end else if (if_valid && trap_pc_fetch_safe) begin
        trap_pc_r <= if_pc;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (sys_meta_idx = 0; sys_meta_idx < 32; sys_meta_idx = sys_meta_idx + 1) begin
            rs_is_csr[sys_meta_idx]   <= 1'b0;
            rs_is_mret[sys_meta_idx]  <= 1'b0;
            rs_csr_addr[sys_meta_idx] <= 12'd0;
            rs_pred_taken[sys_meta_idx]  <= 1'b0;
            rs_pred_target[sys_meta_idx] <= 32'd0;
        end
        for (rocc_meta_idx = 0; rocc_meta_idx < 32; rocc_meta_idx = rocc_meta_idx + 1) begin
            rs_is_rocc[rocc_meta_idx]     <= 1'b0;
            rs_rocc_funct7[rocc_meta_idx] <= 7'd0;
        end
    end else begin
        if (disp0_accepted) begin
            rs_is_csr[sb_disp0_tag]   <= dec0_is_csr;
            rs_is_mret[sb_disp0_tag]  <= dec0_is_mret;
            rs_csr_addr[sb_disp0_tag] <= dec0_csr_addr;
            rs_pred_taken[sb_disp0_tag]  <= fb_pop0_pred_taken;
            rs_pred_target[sb_disp0_tag] <= fb_pop0_pred_target;
            rs_is_rocc[sb_disp0_tag]     <= dec0_is_rocc;
            rs_rocc_funct7[sb_disp0_tag] <= dec0_rocc_funct7;
        end
        if (disp1_accepted) begin
            rs_is_csr[sb_disp1_tag]   <= dec1_is_csr;
            rs_is_mret[sb_disp1_tag]  <= dec1_is_mret;
            rs_csr_addr[sb_disp1_tag] <= dec1_csr_addr;
            rs_pred_taken[sb_disp1_tag]  <= fb_pop1_pred_taken;
            rs_pred_target[sb_disp1_tag] <= fb_pop1_pred_target;
            rs_is_rocc[sb_disp1_tag]     <= dec1_is_rocc;
            rs_rocc_funct7[sb_disp1_tag] <= dec1_rocc_funct7;
        end
    end
end

// Issue-time SYSTEM metadata reconstructed from the dispatched tag.
// Pipe 0 can issue a freshly-dispatched SYSTEM op in the same cycle, so bypass
// decoder metadata around the tag RAM when the issue tag matches a new dispatch.
wire iss0_tag_hits_disp0 = disp0_accepted && (iss0_tag == sb_disp0_tag) && (iss0_tid == dec0_tid);
wire iss0_tag_hits_disp1 = disp1_accepted && (iss0_tag == sb_disp1_tag) && (iss0_tid == dec1_tid);
assign iss0_is_csr  = iss0_tag_hits_disp0 ? dec0_is_csr  :
                      iss0_tag_hits_disp1 ? dec1_is_csr  : rs_is_csr[iss0_tag];
assign iss0_is_mret = iss0_tag_hits_disp0 ? dec0_is_mret :
                      iss0_tag_hits_disp1 ? dec1_is_mret : rs_is_mret[iss0_tag];
assign iss0_csr_addr = iss0_tag_hits_disp0 ? dec0_csr_addr :
                       iss0_tag_hits_disp1 ? dec1_csr_addr : rs_csr_addr[iss0_tag];
assign iss0_pred_taken = iss0_tag_hits_disp0 ? fb_pop0_pred_taken :
                         iss0_tag_hits_disp1 ? fb_pop1_pred_taken :
                         rs_pred_taken[iss0_tag];
assign iss0_pred_target = iss0_tag_hits_disp0 ? fb_pop0_pred_target :
                          iss0_tag_hits_disp1 ? fb_pop1_pred_target :
                          rs_pred_target[iss0_tag];

// Issue-time RoCC metadata reconstructed from the dispatched tag (same bypass pattern)
// FPGA_MODE: RoCC not synthesized, hardwire to 0 to cut cross-module feedback path
`ifdef FPGA_MODE
assign iss0_is_rocc          = 1'b0;
`else
assign iss0_is_rocc          = iss0_tag_hits_disp0 ? dec0_is_rocc :
                               iss0_tag_hits_disp1 ? dec1_is_rocc : rs_is_rocc[iss0_tag];
`endif
assign iss0_rocc_funct7 = iss0_tag_hits_disp0 ? dec0_rocc_funct7 :
                          iss0_tag_hits_disp1 ? dec1_rocc_funct7 : rs_rocc_funct7[iss0_tag];

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        order_id_t0 <= {`METADATA_ORDER_ID_W{1'b0}};
        order_id_t1 <= {`METADATA_ORDER_ID_W{1'b0}};
    end else begin
        // Increment order_id on dispatch accept per thread
        // When dual-dispatch to same thread, increment by 2; otherwise by 1
        
        // Thread 0: count accepts from disp0 and disp1
        if ((disp0_accepted && dec0_tid == 1'b0) && (disp1_accepted && dec1_tid == 1'b0))
            order_id_t0 <= order_id_t0 + 2'd2;  // Dual-dispatch to T0
        else if ((disp0_accepted && dec0_tid == 1'b0) || (disp1_accepted && dec1_tid == 1'b0))
            order_id_t0 <= order_id_t0 + 1'b1;  // Single dispatch to T0
            
        // Thread 1: count accepts from disp0 and disp1
        if ((disp0_accepted && dec0_tid == 1'b1) && (disp1_accepted && dec1_tid == 1'b1))
            order_id_t1 <= order_id_t1 + 2'd2;  // Dual-dispatch to T1
        else if ((disp0_accepted && dec0_tid == 1'b1) || (disp1_accepted && dec1_tid == 1'b1))
            order_id_t1 <= order_id_t1 + 1'b1;  // Single dispatch to T1
    end
end

// ════════════════════════════════════════════════════════════════════════════
// STAGE 6: Bypass Network → Execution Pipes
// ════════════════════════════════════════════════════════════════════════════

// Pipe 0 EX results (for bypass)
wire        p0_ex_valid;
wire [4:0]  p0_ex_rd;
wire        p0_ex_rd_wen;
wire [31:0] p0_ex_result;
wire [4:0]  p0_ex_tag;
wire [2:0]  p0_ex_fu;
wire [0:0]  p0_ex_tid;

// Pipe 1 ALU results (for bypass)
wire        p1_alu_valid;
wire [4:0]  p1_alu_rd;
wire        p1_alu_rd_wen;
wire [31:0] p1_alu_result;
wire [4:0]  p1_alu_tag;
wire [2:0]  p1_alu_fu;
wire [0:0]  p1_alu_tid;

// MEM stage result (for bypass)
wire        mem_wb_valid;
wire [4:0]  mem_wb_rd;
wire        mem_wb_rd_wen;
wire [31:0] mem_wb_data;

// Bypass Network for Pipe 0 operands
wire [31:0] byp0_op_a, byp0_op_b;
wire [1:0]  byp0_fwd_a, byp0_fwd_b;
wire        p0_tagbuf_a_valid, p0_tagbuf_b_valid;
wire [31:0] p0_tagbuf_a_data,  p0_tagbuf_b_data;

bypass_network u_bypass0(
    .ro_rs1_addr     (p0_pre_ro_rs1  ),
    .ro_rs2_addr     (p0_pre_ro_rs2  ),
    .ro_rs1_regdata  (prf_r0_data    ),
    .ro_rs2_regdata  (prf_r1_data    ),
    .ro_tid          (p0_pre_ro_tid  ),
    .tagbuf_rs1_valid(p0_tagbuf_a_valid),
    .tagbuf_rs1_data (p0_tagbuf_a_data ),
    .tagbuf_rs2_valid(p0_tagbuf_b_valid),
    .tagbuf_rs2_data (p0_tagbuf_b_data ),
    .pipe0_valid     (p0_ex_valid    ),
    .pipe0_rd        (p0_ex_rd       ),
    .pipe0_rd_wen    (p0_ex_rd_wen   ),
    .pipe0_data      (p0_ex_result   ),
    .pipe0_tid       (p0_ex_tid      ),
    .pipe1_valid     (p1_alu_valid   ),
    .pipe1_rd        (p1_alu_rd      ),
    .pipe1_rd_wen    (p1_alu_rd_wen  ),
    .pipe1_data      (p1_alu_result  ),
    .pipe1_tid       (p1_alu_tid     ),
    .mem_valid       (mem_wb_valid   ),
    .mem_rd          (mem_wb_rd      ),
    .mem_rd_wen      (mem_wb_rd_wen  ),
    .mem_data        (mem_wb_data    ),
    .mem_tid         (mem_wb_tid_r   ),
    .op_a            (byp0_op_a      ),
    .op_b            (byp0_op_b      ),
    .fwd_src_a       (byp0_fwd_a     ),
    .fwd_src_b       (byp0_fwd_b     )
);

// Bypass Network for Pipe 1 operands
wire [31:0] byp1_op_a, byp1_op_b;
wire [1:0]  byp1_fwd_a, byp1_fwd_b;
wire        p1_tagbuf_a_valid, p1_tagbuf_b_valid;
wire [31:0] p1_tagbuf_a_data,  p1_tagbuf_b_data;

bypass_network u_bypass1(
    .ro_rs1_addr     (p1_pre_ro_rs1  ),
    .ro_rs2_addr     (p1_pre_ro_rs2  ),
    .ro_rs1_regdata  (prf_r2_data    ),
    .ro_rs2_regdata  (prf_r3_data    ),
    .ro_tid          (p1_pre_ro_tid  ),
    .tagbuf_rs1_valid(p1_tagbuf_a_valid),
    .tagbuf_rs1_data (p1_tagbuf_a_data ),
    .tagbuf_rs2_valid(p1_tagbuf_b_valid),
    .tagbuf_rs2_data (p1_tagbuf_b_data ),
    .pipe0_valid     (p0_ex_valid    ),
    .pipe0_rd        (p0_ex_rd       ),
    .pipe0_rd_wen    (p0_ex_rd_wen   ),
    .pipe0_data      (p0_ex_result   ),
    .pipe0_tid       (p0_ex_tid      ),
    .pipe1_valid     (p1_alu_valid   ),
    .pipe1_rd        (p1_alu_rd      ),
    .pipe1_rd_wen    (p1_alu_rd_wen  ),
    .pipe1_data      (p1_alu_result  ),
    .pipe1_tid       (p1_alu_tid     ),
    .mem_valid       (mem_wb_valid   ),
    .mem_rd          (mem_wb_rd      ),
    .mem_rd_wen      (mem_wb_rd_wen  ),
    .mem_data        (mem_wb_data    ),
    .mem_tid         (mem_wb_tid_r   ),
    .op_a            (byp1_op_a      ),
    .op_b            (byp1_op_b      ),
    .fwd_src_a       (byp1_fwd_a     ),
    .fwd_src_b       (byp1_fwd_b     )
);

    // ════════════════════════════════════════════════════════════════════════════
    // RoCC AI Accelerator Integration
    // ════════════════════════════════════════════════════════════════════════════

    // RoCC Command Interface: When iss0_is_rocc, bypass exec_pipe0 and send to RoCC
    // Backpressure: only assert valid if RoCC is ready, and only mark RS issued when accepted
    assign rocc_cmd_valid    = p0_pre_ro_valid && p0_pre_ro_is_rocc && rocc_cmd_ready;
    assign rocc_cmd_funct7   = p0_pre_ro_rocc_funct7;
    assign rocc_cmd_funct3   = p0_pre_ro_func3;
    assign rocc_cmd_rd       = p0_pre_ro_rd;
    assign rocc_cmd_rs1_data = byp0_op_a;  // RS1 data from bypass network
    assign rocc_cmd_rs2_data = byp0_op_b;  // RS2 data from bypass network
    assign rocc_cmd_tag      = p0_pre_ro_tag;
    assign rocc_cmd_tid      = p0_pre_ro_tid;

    // RoCC is always ready to accept response
    assign rocc_resp_ready   = 1'b1;

// ════════════════════════════════════════════════════════════════════════════
// RoCC Flush-Safe Completion Handling
// ════════════════════════════════════════════════════════════════════════════
// Track the epoch and tid of each in-flight RoCC command by tag
reg [`METADATA_EPOCH_W-1:0] rocc_cmd_epoch [0:31];
reg                         rocc_cmd_in_flight [0:31];
reg [0:0]                   rocc_cmd_tid_per_tag [0:31];
integer                     rocc_epoch_idx;

// Capture epoch when RoCC command is issued
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (rocc_epoch_idx = 0; rocc_epoch_idx < 32; rocc_epoch_idx = rocc_epoch_idx + 1) begin
            rocc_cmd_epoch[rocc_epoch_idx] <= {`METADATA_EPOCH_W{1'b0}};
            rocc_cmd_in_flight[rocc_epoch_idx] <= 1'b0;
            rocc_cmd_tid_per_tag[rocc_epoch_idx] <= 1'b0;
        end
    end else begin
        // Clear in-flight entries for flushed thread when flush occurs
        if (combined_flush_any) begin
            for (rocc_epoch_idx = 0; rocc_epoch_idx < 32; rocc_epoch_idx = rocc_epoch_idx + 1) begin
                if (rocc_cmd_in_flight[rocc_epoch_idx] && rocc_cmd_tid_per_tag[rocc_epoch_idx] == (trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid)) begin
                    rocc_cmd_in_flight[rocc_epoch_idx] <= 1'b0;
                end
            end
        end

        // Mark in-flight when RoCC command is accepted
        if (rocc_cmd_valid && rocc_cmd_ready) begin
            rocc_cmd_epoch[rocc_cmd_tag] <= p0_pre_ro_epoch;
            rocc_cmd_tid_per_tag[rocc_cmd_tag] <= p0_pre_ro_tid;
            rocc_cmd_in_flight[rocc_cmd_tag] <= 1'b1;
        end

        // Clear in-flight when response is accepted
        if (rocc_resp_valid && rocc_resp_ready) begin
            rocc_cmd_in_flight[rocc_resp_tag] <= 1'b0;
        end
    end
end

// Get current epoch for each thread
wire [`METADATA_EPOCH_W-1:0] current_epoch_for_rocc_resp = (rocc_resp_tid == 1'b0) ? epoch_t0 : epoch_t1;

// Check if RoCC response is valid (not flushed)
// Response is valid if: epoch matches current epoch for that thread AND was in-flight
wire rocc_resp_epoch_match = (rocc_cmd_epoch[rocc_resp_tag] == current_epoch_for_rocc_resp);
wire rocc_resp_not_flushed = rocc_resp_epoch_match && rocc_cmd_in_flight[rocc_resp_tag];

// ─── Execution Pipe 0 (INT + Branch) ───────────────────────────────────────
// When p0_pre_ro_is_rocc, don't send to exec_pipe0 (RoCC bypasses it)
wire p0_pre_ro_to_pipe0_valid = p0_pre_ro_valid && !p0_pre_ro_is_rocc && !p0_pre_ro_flush_kill;

exec_pipe0 #(.TAG_W(5)) u_exec_pipe0(
    .clk              (clk              ),
    .rstn             (rstn             ),
    .in_valid         (p0_pre_ro_to_pipe0_valid),
    .in_tag           (p0_pre_ro_tag    ),
    .in_pc            (p0_pre_ro_pc     ),
    .in_op_a          (byp0_op_a        ),
    .in_op_b          (byp0_op_b        ),
    .in_rs1_idx       (p0_pre_ro_rs1    ),
    .in_imm           (p0_pre_ro_imm    ),
    .in_order_id      (p0_pre_ro_order_id),
    .in_func3         (p0_pre_ro_func3  ),
    .in_func7         (p0_pre_ro_func7  ),
    .in_alu_op        (p0_pre_ro_alu_op ),
    .in_alu_src1      (p0_pre_ro_alu_src1),
    .in_alu_src2      (p0_pre_ro_alu_src2),
    .in_br_addr_mode  (p0_pre_ro_br_addr_mode),
    .in_br            (p0_pre_ro_br     ),
    .in_pred_taken    (p0_pre_ro_pred_taken),
    .in_pred_target   (p0_pre_ro_pred_target),
    .in_rd            (p0_pre_ro_rd     ),
    .in_regs_write    (p0_pre_ro_regs_write),
    .in_fu            (p0_pre_ro_fu     ),
    .in_tid           (p0_pre_ro_tid    ),
    .flush            (combined_flush_any),
    .flush_tid        (trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid),
    .flush_order_valid(flush_is_order_based),
    .flush_order_id   (flush_order_id_mux),
    .in_is_csr        (p0_pre_ro_is_csr ),
    .in_is_mret       (p0_pre_ro_is_mret),
    .in_csr_addr      (p0_pre_ro_csr_addr),
    .csr_rdata        (csr_rdata        ),
    .out_valid        (p0_ex_valid      ),
    .out_tag          (p0_ex_tag        ),
    .out_result       (p0_ex_result     ),
    .out_rd           (p0_ex_rd         ),
    .out_regs_write   (p0_ex_rd_wen     ),
    .out_fu           (p0_ex_fu         ),
    .out_tid          (p0_ex_tid        ),
    .csr_valid        (pipe0_csr_valid  ),
    .csr_wdata        (pipe0_csr_wdata  ),
    .csr_op           (pipe0_csr_op     ),
    .csr_addr         (pipe0_csr_addr_unused),
    .mret_valid       (pipe0_mret_valid ),
    .mret_order_id    (pipe0_mret_order_id),
    .br_ctrl          (pipe0_br_ctrl    ),
    .br_addr          (pipe0_br_addr    ),
    .br_tid           (pipe0_br_tid     ),
    .br_order_id      (pipe0_br_order_id),
    .br_complete      (pipe0_br_complete),
    .br_update_valid  (pipe0_br_update_valid),
    .br_update_pc     (pipe0_br_update_pc),
    .br_update_taken  (pipe0_br_update_taken),
    .br_update_target (pipe0_br_update_target),
    .br_update_is_call(pipe0_br_update_is_call),
    .br_update_is_return(pipe0_br_update_is_return)
);

// ─── Execution Pipe 1 (INT + MUL + AGU) ────────────────────────────────────
wire        p1_mem_req_valid;
wire        p1_mem_req_wen;
wire [31:0] p1_mem_req_addr;
wire [31:0] p1_mem_req_wdata;
wire [2:0]  p1_mem_req_func3;
wire [4:0]  p1_mem_req_tag;
wire [4:0]  p1_mem_req_rd;
wire        p1_mem_req_regs_write;
wire [2:0]  p1_mem_req_fu;
wire        p1_mem_req_mem2reg;
wire [0:0]  p1_mem_req_tid;
wire [`METADATA_ORDER_ID_W-1:0] p1_mem_req_order_id;
wire [7:0]  p1_mem_req_epoch;

wire        p1_mul_valid;
wire [4:0]  p1_mul_tag;
wire [31:0] p1_mul_result;
wire [4:0]  p1_mul_rd;
wire        p1_mul_regs_write;
wire [2:0]  p1_mul_fu;
wire [0:0]  p1_mul_tid;

wire        p1_div_valid;
wire [4:0]  p1_div_tag;
wire [31:0] p1_div_result;
wire [4:0]  p1_div_rd;
wire        p1_div_regs_write;
wire [2:0]  p1_div_fu;
wire [0:0]  p1_div_tid;
wire        p1_div_busy;

// ════════════════════════════════════════════════════════════════════════════
// Pipeline Register: PRF + Bypass → Exec Pipe1  (ro1 stage)
//   The issue side has already been captured by p1_pre_ro. This stage now only
//   closes PRF read + tagbuf bypass into exec_pipe1.
// ════════════════════════════════════════════════════════════════════════════
reg         ro1_valid;
reg  [4:0]  ro1_tag;
reg  [31:0] ro1_pc;
reg  [31:0] ro1_imm;
reg  [2:0]  ro1_func3;
reg         ro1_func7;
reg  [4:0]  ro1_rd;
reg  [2:0]  ro1_alu_op;
reg  [1:0]  ro1_alu_src1, ro1_alu_src2;
reg         ro1_br;
reg         ro1_mem_read, ro1_mem_write, ro1_mem2reg;
reg         ro1_regs_write, ro1_br_addr_mode;
reg  [2:0]  ro1_fu;
reg  [0:0]  ro1_tid;
reg  [`METADATA_ORDER_ID_W-1:0] ro1_order_id;
reg  [`METADATA_EPOCH_W-1:0]    ro1_epoch;
reg  [31:0] ro1_op_a, ro1_op_b;

`ifdef VERILATOR_MAINLINE
reg  [4:0]  ro1_dbg_rs1, ro1_dbg_rs2;
reg  [4:0]  ro1_dbg_src1_tag, ro1_dbg_src2_tag;
reg  [5:0]  ro1_dbg_prs1, ro1_dbg_prs2;
reg  [31:0] ro1_dbg_prf_a, ro1_dbg_prf_b;
reg         ro1_dbg_tagbuf_a_valid, ro1_dbg_tagbuf_b_valid;
reg  [31:0] ro1_dbg_tagbuf_a_data, ro1_dbg_tagbuf_b_data;
reg  [1:0]  ro1_dbg_fwd_a, ro1_dbg_fwd_b;

reg         dbg_bad_uart_store_seen_r;
reg  [31:0] dbg_bad_uart_store_pc_r;
reg  [31:0] dbg_bad_uart_store_addr_r;
reg  [31:0] dbg_bad_uart_store_op_a_r;
reg  [31:0] dbg_bad_uart_store_op_b_r;
reg  [31:0] dbg_bad_uart_store_imm_r;
reg  [`METADATA_ORDER_ID_W-1:0] dbg_bad_uart_store_order_id_r;
reg  [4:0]  dbg_bad_uart_store_tag_r;
reg  [4:0]  dbg_bad_uart_store_rd_r;
reg  [4:0]  dbg_bad_uart_store_rs1_r;
reg  [4:0]  dbg_bad_uart_store_rs2_r;
reg  [4:0]  dbg_bad_uart_store_src1_tag_r;
reg  [4:0]  dbg_bad_uart_store_src2_tag_r;
reg  [5:0]  dbg_bad_uart_store_prs1_r;
reg  [5:0]  dbg_bad_uart_store_prs2_r;
reg  [31:0] dbg_bad_uart_store_prf_a_r;
reg  [31:0] dbg_bad_uart_store_prf_b_r;
reg         dbg_bad_uart_store_tagbuf_a_valid_r;
reg         dbg_bad_uart_store_tagbuf_b_valid_r;
reg  [31:0] dbg_bad_uart_store_tagbuf_a_data_r;
reg  [31:0] dbg_bad_uart_store_tagbuf_b_data_r;
reg  [1:0]  dbg_bad_uart_store_fwd_a_r;
reg  [1:0]  dbg_bad_uart_store_fwd_b_r;
reg  [2:0]  dbg_bad_uart_store_func3_r;
reg  [0:0]  dbg_bad_uart_store_tid_r;

reg         dbg_strcpy_mv_seen_r;
reg  [31:0] dbg_strcpy_mv_pc_r;
reg  [31:0] dbg_strcpy_mv_op_a_r;
reg  [31:0] dbg_strcpy_mv_op_b_r;
reg  [`METADATA_ORDER_ID_W-1:0] dbg_strcpy_mv_order_id_r;
reg  [4:0]  dbg_strcpy_mv_tag_r;
reg  [4:0]  dbg_strcpy_mv_rd_r;
reg  [0:0]  dbg_strcpy_mv_tid_r;
reg  [4:0]  dbg_strcpy_mv_rs1_r;
reg  [4:0]  dbg_strcpy_mv_rs2_r;
reg  [4:0]  dbg_strcpy_mv_src1_tag_r;
reg  [4:0]  dbg_strcpy_mv_src2_tag_r;
reg  [5:0]  dbg_strcpy_mv_prd_r;
reg  [5:0]  dbg_strcpy_mv_prs1_r;
reg  [5:0]  dbg_strcpy_mv_prs2_r;
reg  [31:0] dbg_strcpy_mv_prf_a_r;
reg  [31:0] dbg_strcpy_mv_prf_b_r;
reg         dbg_strcpy_mv_tagbuf_a_valid_r;
reg         dbg_strcpy_mv_tagbuf_b_valid_r;
reg  [31:0] dbg_strcpy_mv_tagbuf_a_data_r;
reg  [31:0] dbg_strcpy_mv_tagbuf_b_data_r;
reg  [1:0]  dbg_strcpy_mv_fwd_a_r;
reg  [1:0]  dbg_strcpy_mv_fwd_b_r;
reg         dbg_strcpy_mv_prf_w0_en_r;
reg  [5:0]  dbg_strcpy_mv_prf_w0_addr_r;
reg  [31:0] dbg_strcpy_mv_prf_w0_data_r;
reg         dbg_strcpy_mv_prf_w1_en_r;
reg  [5:0]  dbg_strcpy_mv_prf_w1_addr_r;
reg  [31:0] dbg_strcpy_mv_prf_w1_data_r;

reg         dbg_main_lw_a0_seen_r;
reg  [31:0] dbg_main_lw_a0_addr_r;
reg  [`METADATA_ORDER_ID_W-1:0] dbg_main_lw_a0_order_id_r;
reg  [4:0]  dbg_main_lw_a0_tag_r;
reg  [5:0]  dbg_main_lw_a0_prd_r;
reg  [5:0]  dbg_main_lw_a0_prs1_r;
reg  [31:0] dbg_main_lw_a0_base_r;
reg  [31:0] dbg_main_lw_a0_imm_r;
reg         dbg_main_lw_a0_wb_seen_r;
reg  [31:0] dbg_main_lw_a0_wb_data_r;
reg  [5:0]  dbg_main_lw_a0_wb_prd_r;

reg         dbg_main_addi_a0_seen_r;
reg  [31:0] dbg_main_addi_a0_op_a_r;
reg  [31:0] dbg_main_addi_a0_result_r;
reg  [`METADATA_ORDER_ID_W-1:0] dbg_main_addi_a0_order_id_r;
reg  [4:0]  dbg_main_addi_a0_tag_r;
reg  [5:0]  dbg_main_addi_a0_prd_r;
reg  [5:0]  dbg_main_addi_a0_prs1_r;
reg  [4:0]  dbg_main_addi_a0_src1_tag_r;
reg  [31:0] dbg_main_addi_a0_prf_a_r;
reg         dbg_main_addi_a0_tagbuf_a_valid_r;
reg  [31:0] dbg_main_addi_a0_tagbuf_a_data_r;

reg  [7:0]  dbg_main_a0_prd_write_count_r;
reg         dbg_main_a0_prd_last_write_port_r;
reg  [31:0] dbg_main_a0_prd_last_write_data_r;
reg  [4:0]  dbg_main_a0_prd_last_write_tag_r;
reg  [4:0]  dbg_main_a0_prd_last_write_rd_r;
reg  [2:0]  dbg_main_a0_prd_last_write_fu_r;
reg  [31:0] dbg_main_a0_prd_last_write_pc_r;
reg  [`METADATA_ORDER_ID_W-1:0] dbg_main_a0_prd_last_write_order_id_r;
reg         dbg_main_a0_prd_first_bad_write_seen_r;
reg         dbg_main_a0_prd_first_bad_write_port_r;
reg  [31:0] dbg_main_a0_prd_first_bad_write_data_r;
reg  [4:0]  dbg_main_a0_prd_first_bad_write_tag_r;
reg  [4:0]  dbg_main_a0_prd_first_bad_write_rd_r;
reg  [2:0]  dbg_main_a0_prd_first_bad_write_fu_r;
reg  [31:0] dbg_main_a0_prd_first_bad_write_pc_r;
reg  [`METADATA_ORDER_ID_W-1:0] dbg_main_a0_prd_first_bad_write_order_id_r;
reg         dbg_main_a0_prd_first_free_seen_r;
reg         dbg_main_a0_prd_first_free_port_r;
reg  [4:0]  dbg_main_a0_prd_first_free_rd_r;
reg  [4:0]  dbg_main_a0_prd_first_free_tag_r;
reg  [`METADATA_ORDER_ID_W-1:0] dbg_main_a0_prd_first_free_order_id_r;
reg         dbg_main_addi_a0_wb_seen_r;
reg         dbg_main_addi_a0_wb_port_r;
reg  [0:0]  dbg_main_addi_a0_wb_tid_r;
reg  [5:0]  dbg_main_addi_a0_wb_prd_r;
reg  [31:0] dbg_main_addi_a0_wb_data_r;
reg         dbg_main_addi_a0_wb_w0_en_r;
reg  [5:0]  dbg_main_addi_a0_wb_w0_addr_r;
reg  [31:0] dbg_main_addi_a0_wb_w0_data_r;
reg         dbg_main_addi_a0_wb_w1_en_r;
reg  [5:0]  dbg_main_addi_a0_wb_w1_addr_r;
reg  [31:0] dbg_main_addi_a0_wb_w1_data_r;

wire [31:0] ro1_dbg_eff_addr = ro1_op_a + ro1_imm;
wire        ro1_dbg_bad_uart_store =
    ro1_valid && ro1_mem_write &&
    (ro1_pc >= 32'h8000_10AC) && (ro1_pc <= 32'h8000_10C8) &&
    (ro1_dbg_eff_addr >= 32'h1300_0010) && (ro1_dbg_eff_addr <= 32'h1300_001F);
`endif

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ro1_valid <= 1'b0;
`ifdef VERILATOR_MAINLINE
        ro1_dbg_rs1 <= 5'd0;
        ro1_dbg_rs2 <= 5'd0;
        ro1_dbg_src1_tag <= 5'd0;
        ro1_dbg_src2_tag <= 5'd0;
        ro1_dbg_prs1 <= 6'd0;
        ro1_dbg_prs2 <= 6'd0;
        ro1_dbg_prf_a <= 32'd0;
        ro1_dbg_prf_b <= 32'd0;
        ro1_dbg_tagbuf_a_valid <= 1'b0;
        ro1_dbg_tagbuf_b_valid <= 1'b0;
        ro1_dbg_tagbuf_a_data <= 32'd0;
        ro1_dbg_tagbuf_b_data <= 32'd0;
        ro1_dbg_fwd_a <= 2'd0;
        ro1_dbg_fwd_b <= 2'd0;
`endif
    end else begin
        ro1_valid <= p1_pre_ro_valid && !p1_pre_ro_flush_kill;
        if (p1_pre_ro_valid && !p1_pre_ro_flush_kill) begin
            ro1_tag        <= p1_pre_ro_tag;
            ro1_pc         <= p1_pre_ro_pc;
            ro1_imm        <= p1_pre_ro_imm;
            ro1_func3      <= p1_pre_ro_func3;
            ro1_func7      <= p1_pre_ro_func7;
            ro1_rd         <= p1_pre_ro_rd;
            ro1_alu_op     <= p1_pre_ro_alu_op;
            ro1_alu_src1   <= p1_pre_ro_alu_src1;
            ro1_alu_src2   <= p1_pre_ro_alu_src2;
            ro1_br         <= p1_pre_ro_br;
            ro1_mem_read   <= p1_pre_ro_mem_read;
            ro1_mem_write  <= p1_pre_ro_mem_write;
            ro1_mem2reg    <= p1_pre_ro_mem2reg;
            ro1_regs_write <= p1_pre_ro_regs_write;
            ro1_br_addr_mode <= p1_pre_ro_br_addr_mode;
            ro1_fu         <= p1_pre_ro_fu;
            ro1_tid        <= p1_pre_ro_tid;
            ro1_order_id   <= p1_pre_ro_order_id;
            ro1_epoch      <= p1_pre_ro_epoch;
            ro1_op_a       <= byp1_op_a;
            ro1_op_b       <= byp1_op_b;
`ifdef VERILATOR_MAINLINE
            ro1_dbg_rs1            <= p1_pre_ro_rs1;
            ro1_dbg_rs2            <= p1_pre_ro_rs2;
            ro1_dbg_src1_tag       <= p1_pre_ro_src1_tag;
            ro1_dbg_src2_tag       <= p1_pre_ro_src2_tag;
            ro1_dbg_prs1           <= p1_pre_ro_prs1;
            ro1_dbg_prs2           <= p1_pre_ro_prs2;
            ro1_dbg_prf_a          <= prf_r2_data;
            ro1_dbg_prf_b          <= prf_r3_data;
            ro1_dbg_tagbuf_a_valid <= p1_tagbuf_a_valid;
            ro1_dbg_tagbuf_b_valid <= p1_tagbuf_b_valid;
            ro1_dbg_tagbuf_a_data  <= p1_tagbuf_a_data;
            ro1_dbg_tagbuf_b_data  <= p1_tagbuf_b_data;
            ro1_dbg_fwd_a          <= byp1_fwd_a;
            ro1_dbg_fwd_b          <= byp1_fwd_b;
`endif
        end
    end
end

`ifdef VERILATOR_MAINLINE
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        dbg_bad_uart_store_seen_r <= 1'b0;
        dbg_bad_uart_store_pc_r <= 32'd0;
        dbg_bad_uart_store_addr_r <= 32'd0;
        dbg_bad_uart_store_op_a_r <= 32'd0;
        dbg_bad_uart_store_op_b_r <= 32'd0;
        dbg_bad_uart_store_imm_r <= 32'd0;
        dbg_bad_uart_store_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        dbg_bad_uart_store_tag_r <= 5'd0;
        dbg_bad_uart_store_rd_r <= 5'd0;
        dbg_bad_uart_store_rs1_r <= 5'd0;
        dbg_bad_uart_store_rs2_r <= 5'd0;
        dbg_bad_uart_store_src1_tag_r <= 5'd0;
        dbg_bad_uart_store_src2_tag_r <= 5'd0;
        dbg_bad_uart_store_prs1_r <= 6'd0;
        dbg_bad_uart_store_prs2_r <= 6'd0;
        dbg_bad_uart_store_prf_a_r <= 32'd0;
        dbg_bad_uart_store_prf_b_r <= 32'd0;
        dbg_bad_uart_store_tagbuf_a_valid_r <= 1'b0;
        dbg_bad_uart_store_tagbuf_b_valid_r <= 1'b0;
        dbg_bad_uart_store_tagbuf_a_data_r <= 32'd0;
        dbg_bad_uart_store_tagbuf_b_data_r <= 32'd0;
        dbg_bad_uart_store_fwd_a_r <= 2'd0;
        dbg_bad_uart_store_fwd_b_r <= 2'd0;
        dbg_bad_uart_store_func3_r <= 3'd0;
        dbg_bad_uart_store_tid_r <= 1'b0;
        dbg_strcpy_mv_seen_r <= 1'b0;
        dbg_strcpy_mv_pc_r <= 32'd0;
        dbg_strcpy_mv_op_a_r <= 32'd0;
        dbg_strcpy_mv_op_b_r <= 32'd0;
        dbg_strcpy_mv_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        dbg_strcpy_mv_tag_r <= 5'd0;
        dbg_strcpy_mv_rd_r <= 5'd0;
        dbg_strcpy_mv_tid_r <= 1'b0;
        dbg_strcpy_mv_rs1_r <= 5'd0;
        dbg_strcpy_mv_rs2_r <= 5'd0;
        dbg_strcpy_mv_src1_tag_r <= 5'd0;
        dbg_strcpy_mv_src2_tag_r <= 5'd0;
        dbg_strcpy_mv_prd_r <= 6'd0;
        dbg_strcpy_mv_prs1_r <= 6'd0;
        dbg_strcpy_mv_prs2_r <= 6'd0;
        dbg_strcpy_mv_prf_a_r <= 32'd0;
        dbg_strcpy_mv_prf_b_r <= 32'd0;
        dbg_strcpy_mv_tagbuf_a_valid_r <= 1'b0;
        dbg_strcpy_mv_tagbuf_b_valid_r <= 1'b0;
        dbg_strcpy_mv_tagbuf_a_data_r <= 32'd0;
        dbg_strcpy_mv_tagbuf_b_data_r <= 32'd0;
        dbg_strcpy_mv_fwd_a_r <= 2'd0;
        dbg_strcpy_mv_fwd_b_r <= 2'd0;
        dbg_strcpy_mv_prf_w0_en_r <= 1'b0;
        dbg_strcpy_mv_prf_w0_addr_r <= 6'd0;
        dbg_strcpy_mv_prf_w0_data_r <= 32'd0;
        dbg_strcpy_mv_prf_w1_en_r <= 1'b0;
        dbg_strcpy_mv_prf_w1_addr_r <= 6'd0;
        dbg_strcpy_mv_prf_w1_data_r <= 32'd0;
        dbg_main_lw_a0_seen_r <= 1'b0;
        dbg_main_lw_a0_addr_r <= 32'd0;
        dbg_main_lw_a0_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        dbg_main_lw_a0_tag_r <= 5'd0;
        dbg_main_lw_a0_prd_r <= 6'd0;
        dbg_main_lw_a0_prs1_r <= 6'd0;
        dbg_main_lw_a0_base_r <= 32'd0;
        dbg_main_lw_a0_imm_r <= 32'd0;
        dbg_main_lw_a0_wb_seen_r <= 1'b0;
        dbg_main_lw_a0_wb_data_r <= 32'd0;
        dbg_main_lw_a0_wb_prd_r <= 6'd0;
        dbg_main_addi_a0_seen_r <= 1'b0;
        dbg_main_addi_a0_op_a_r <= 32'd0;
        dbg_main_addi_a0_result_r <= 32'd0;
        dbg_main_addi_a0_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        dbg_main_addi_a0_tag_r <= 5'd0;
        dbg_main_addi_a0_prd_r <= 6'd0;
        dbg_main_addi_a0_prs1_r <= 6'd0;
        dbg_main_addi_a0_src1_tag_r <= 5'd0;
        dbg_main_addi_a0_prf_a_r <= 32'd0;
        dbg_main_addi_a0_tagbuf_a_valid_r <= 1'b0;
        dbg_main_addi_a0_tagbuf_a_data_r <= 32'd0;
        dbg_main_a0_prd_write_count_r <= 8'd0;
        dbg_main_a0_prd_last_write_port_r <= 1'b0;
        dbg_main_a0_prd_last_write_data_r <= 32'd0;
        dbg_main_a0_prd_last_write_tag_r <= 5'd0;
        dbg_main_a0_prd_last_write_rd_r <= 5'd0;
        dbg_main_a0_prd_last_write_fu_r <= 3'd0;
        dbg_main_a0_prd_last_write_pc_r <= 32'd0;
        dbg_main_a0_prd_last_write_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        dbg_main_a0_prd_first_bad_write_seen_r <= 1'b0;
        dbg_main_a0_prd_first_bad_write_port_r <= 1'b0;
        dbg_main_a0_prd_first_bad_write_data_r <= 32'd0;
        dbg_main_a0_prd_first_bad_write_tag_r <= 5'd0;
        dbg_main_a0_prd_first_bad_write_rd_r <= 5'd0;
        dbg_main_a0_prd_first_bad_write_fu_r <= 3'd0;
        dbg_main_a0_prd_first_bad_write_pc_r <= 32'd0;
        dbg_main_a0_prd_first_bad_write_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        dbg_main_a0_prd_first_free_seen_r <= 1'b0;
        dbg_main_a0_prd_first_free_port_r <= 1'b0;
        dbg_main_a0_prd_first_free_rd_r <= 5'd0;
        dbg_main_a0_prd_first_free_tag_r <= 5'd0;
        dbg_main_a0_prd_first_free_order_id_r <= {`METADATA_ORDER_ID_W{1'b0}};
        dbg_main_addi_a0_wb_seen_r <= 1'b0;
        dbg_main_addi_a0_wb_port_r <= 1'b0;
        dbg_main_addi_a0_wb_tid_r <= 1'b0;
        dbg_main_addi_a0_wb_prd_r <= 6'd0;
        dbg_main_addi_a0_wb_data_r <= 32'd0;
        dbg_main_addi_a0_wb_w0_en_r <= 1'b0;
        dbg_main_addi_a0_wb_w0_addr_r <= 6'd0;
        dbg_main_addi_a0_wb_w0_data_r <= 32'd0;
        dbg_main_addi_a0_wb_w1_en_r <= 1'b0;
        dbg_main_addi_a0_wb_w1_addr_r <= 6'd0;
        dbg_main_addi_a0_wb_w1_data_r <= 32'd0;
    end else if (!dbg_bad_uart_store_seen_r && ro1_dbg_bad_uart_store) begin
        dbg_bad_uart_store_seen_r <= 1'b1;
        dbg_bad_uart_store_pc_r <= ro1_pc;
        dbg_bad_uart_store_addr_r <= ro1_dbg_eff_addr;
        dbg_bad_uart_store_op_a_r <= ro1_op_a;
        dbg_bad_uart_store_op_b_r <= ro1_op_b;
        dbg_bad_uart_store_imm_r <= ro1_imm;
        dbg_bad_uart_store_order_id_r <= ro1_order_id;
        dbg_bad_uart_store_tag_r <= ro1_tag;
        dbg_bad_uart_store_rd_r <= ro1_rd;
        dbg_bad_uart_store_rs1_r <= ro1_dbg_rs1;
        dbg_bad_uart_store_rs2_r <= ro1_dbg_rs2;
        dbg_bad_uart_store_src1_tag_r <= ro1_dbg_src1_tag;
        dbg_bad_uart_store_src2_tag_r <= ro1_dbg_src2_tag;
        dbg_bad_uart_store_prs1_r <= ro1_dbg_prs1;
        dbg_bad_uart_store_prs2_r <= ro1_dbg_prs2;
        dbg_bad_uart_store_prf_a_r <= ro1_dbg_prf_a;
        dbg_bad_uart_store_prf_b_r <= ro1_dbg_prf_b;
        dbg_bad_uart_store_tagbuf_a_valid_r <= ro1_dbg_tagbuf_a_valid;
        dbg_bad_uart_store_tagbuf_b_valid_r <= ro1_dbg_tagbuf_b_valid;
        dbg_bad_uart_store_tagbuf_a_data_r <= ro1_dbg_tagbuf_a_data;
        dbg_bad_uart_store_tagbuf_b_data_r <= ro1_dbg_tagbuf_b_data;
        dbg_bad_uart_store_fwd_a_r <= ro1_dbg_fwd_a;
        dbg_bad_uart_store_fwd_b_r <= ro1_dbg_fwd_b;
        dbg_bad_uart_store_func3_r <= ro1_func3;
        dbg_bad_uart_store_tid_r <= ro1_tid;
    end

    if (rstn && !dbg_strcpy_mv_seen_r && p0_pre_ro_to_pipe0_valid && (p0_pre_ro_pc == 32'h8000_10AC)) begin
        dbg_strcpy_mv_seen_r <= 1'b1;
        dbg_strcpy_mv_pc_r <= p0_pre_ro_pc;
        dbg_strcpy_mv_op_a_r <= byp0_op_a;
        dbg_strcpy_mv_op_b_r <= byp0_op_b;
        dbg_strcpy_mv_order_id_r <= p0_pre_ro_order_id;
        dbg_strcpy_mv_tag_r <= p0_pre_ro_tag;
        dbg_strcpy_mv_rd_r <= p0_pre_ro_rd;
        dbg_strcpy_mv_tid_r <= p0_pre_ro_tid;
        dbg_strcpy_mv_rs1_r <= p0_pre_ro_rs1;
        dbg_strcpy_mv_rs2_r <= p0_pre_ro_rs2;
        dbg_strcpy_mv_src1_tag_r <= p0_pre_ro_src1_tag;
        dbg_strcpy_mv_src2_tag_r <= p0_pre_ro_src2_tag;
        dbg_strcpy_mv_prd_r <= tag_prd_map[p0_pre_ro_tag];
        dbg_strcpy_mv_prs1_r <= p0_pre_ro_prs1;
        dbg_strcpy_mv_prs2_r <= p0_pre_ro_prs2;
        dbg_strcpy_mv_prf_a_r <= prf_r0_data;
        dbg_strcpy_mv_prf_b_r <= prf_r1_data;
        dbg_strcpy_mv_tagbuf_a_valid_r <= p0_tagbuf_a_valid;
        dbg_strcpy_mv_tagbuf_b_valid_r <= p0_tagbuf_b_valid;
        dbg_strcpy_mv_tagbuf_a_data_r <= p0_tagbuf_a_data;
        dbg_strcpy_mv_tagbuf_b_data_r <= p0_tagbuf_b_data;
        dbg_strcpy_mv_fwd_a_r <= byp0_fwd_a;
        dbg_strcpy_mv_fwd_b_r <= byp0_fwd_b;
        dbg_strcpy_mv_prf_w0_en_r <= prf_w0_en;
        dbg_strcpy_mv_prf_w0_addr_r <= prf_w0_addr;
        dbg_strcpy_mv_prf_w0_data_r <= prf_w0_data;
        dbg_strcpy_mv_prf_w1_en_r <= prf_w1_en;
        dbg_strcpy_mv_prf_w1_addr_r <= prf_w1_addr;
        dbg_strcpy_mv_prf_w1_data_r <= prf_w1_data;
    end

    if (rstn && !dbg_main_lw_a0_seen_r && ro1_valid && ro1_mem_read && (ro1_pc == 32'h8000_0484)) begin
        dbg_main_lw_a0_seen_r <= 1'b1;
        dbg_main_lw_a0_addr_r <= ro1_dbg_eff_addr;
        dbg_main_lw_a0_order_id_r <= ro1_order_id;
        dbg_main_lw_a0_tag_r <= ro1_tag;
        dbg_main_lw_a0_prd_r <= tag_prd_map[ro1_tag];
        dbg_main_lw_a0_prs1_r <= ro1_dbg_prs1;
        dbg_main_lw_a0_base_r <= ro1_op_a;
        dbg_main_lw_a0_imm_r <= ro1_imm;
    end

    if (rstn && dbg_main_lw_a0_seen_r && !dbg_main_lw_a0_wb_seen_r &&
        wb1_valid && (wb1_tag == dbg_main_lw_a0_tag_r) && (wb1_tid == 1'b0)) begin
        dbg_main_lw_a0_wb_seen_r <= 1'b1;
        dbg_main_lw_a0_wb_data_r <= wb1_result_data;
        dbg_main_lw_a0_wb_prd_r <= tag_prd_map[wb1_tag];
    end

    if (rstn && !dbg_main_addi_a0_seen_r && p0_pre_ro_to_pipe0_valid && (p0_pre_ro_pc == 32'h8000_049C)) begin
        dbg_main_addi_a0_seen_r <= 1'b1;
        dbg_main_addi_a0_op_a_r <= byp0_op_a;
        dbg_main_addi_a0_result_r <= byp0_op_a + p0_pre_ro_imm;
        dbg_main_addi_a0_order_id_r <= p0_pre_ro_order_id;
        dbg_main_addi_a0_tag_r <= p0_pre_ro_tag;
        dbg_main_addi_a0_prd_r <= tag_prd_map[p0_pre_ro_tag];
        dbg_main_addi_a0_prs1_r <= p0_pre_ro_prs1;
        dbg_main_addi_a0_src1_tag_r <= p0_pre_ro_src1_tag;
        dbg_main_addi_a0_prf_a_r <= prf_r0_data;
        dbg_main_addi_a0_tagbuf_a_valid_r <= p0_tagbuf_a_valid;
        dbg_main_addi_a0_tagbuf_a_data_r <= p0_tagbuf_a_data;
    end

    if (rstn && dbg_main_addi_a0_seen_r && prf_w0_en && (prf_w0_addr == dbg_main_addi_a0_prd_r)) begin
        dbg_main_a0_prd_write_count_r <= dbg_main_a0_prd_write_count_r + 8'd1;
        dbg_main_a0_prd_last_write_port_r <= 1'b0;
        dbg_main_a0_prd_last_write_data_r <= prf_w0_data;
        dbg_main_a0_prd_last_write_tag_r <= wb0_tag;
        dbg_main_a0_prd_last_write_rd_r <= wb0_rd;
        dbg_main_a0_prd_last_write_fu_r <= wb0_fu;
        dbg_main_a0_prd_last_write_pc_r <= tag_pc_map[wb0_tag];
        dbg_main_a0_prd_last_write_order_id_r <= tag_order_map[wb0_tag];
        if (!dbg_main_a0_prd_first_bad_write_seen_r && (prf_w0_data != dbg_main_addi_a0_result_r)) begin
            dbg_main_a0_prd_first_bad_write_seen_r <= 1'b1;
            dbg_main_a0_prd_first_bad_write_port_r <= 1'b0;
            dbg_main_a0_prd_first_bad_write_data_r <= prf_w0_data;
            dbg_main_a0_prd_first_bad_write_tag_r <= wb0_tag;
            dbg_main_a0_prd_first_bad_write_rd_r <= wb0_rd;
            dbg_main_a0_prd_first_bad_write_fu_r <= wb0_fu;
            dbg_main_a0_prd_first_bad_write_pc_r <= tag_pc_map[wb0_tag];
            dbg_main_a0_prd_first_bad_write_order_id_r <= tag_order_map[wb0_tag];
        end
    end

    if (rstn && dbg_main_addi_a0_seen_r && prf_w1_en && (prf_w1_addr == dbg_main_addi_a0_prd_r)) begin
        dbg_main_a0_prd_write_count_r <= dbg_main_a0_prd_write_count_r + 8'd1;
        dbg_main_a0_prd_last_write_port_r <= 1'b1;
        dbg_main_a0_prd_last_write_data_r <= prf_w1_data;
        dbg_main_a0_prd_last_write_tag_r <= wb1_tag;
        dbg_main_a0_prd_last_write_rd_r <= wb1_rd;
        dbg_main_a0_prd_last_write_fu_r <= wb1_fu;
        dbg_main_a0_prd_last_write_pc_r <= tag_pc_map[wb1_tag];
        dbg_main_a0_prd_last_write_order_id_r <= tag_order_map[wb1_tag];
        if (!dbg_main_a0_prd_first_bad_write_seen_r && (prf_w1_data != dbg_main_addi_a0_result_r)) begin
            dbg_main_a0_prd_first_bad_write_seen_r <= 1'b1;
            dbg_main_a0_prd_first_bad_write_port_r <= 1'b1;
            dbg_main_a0_prd_first_bad_write_data_r <= prf_w1_data;
            dbg_main_a0_prd_first_bad_write_tag_r <= wb1_tag;
            dbg_main_a0_prd_first_bad_write_rd_r <= wb1_rd;
            dbg_main_a0_prd_first_bad_write_fu_r <= wb1_fu;
            dbg_main_a0_prd_first_bad_write_pc_r <= tag_pc_map[wb1_tag];
            dbg_main_a0_prd_first_bad_write_order_id_r <= tag_order_map[wb1_tag];
        end
    end

    if (rstn && dbg_main_addi_a0_seen_r && !dbg_main_a0_prd_first_free_seen_r &&
        rob_commit0_valid && rob_commit0_regs_write && (rob_commit0_prd_old == dbg_main_addi_a0_prd_r)) begin
        dbg_main_a0_prd_first_free_seen_r <= 1'b1;
        dbg_main_a0_prd_first_free_port_r <= 1'b0;
        dbg_main_a0_prd_first_free_rd_r <= rob_commit0_rd;
        dbg_main_a0_prd_first_free_tag_r <= rob_commit0_tag;
        dbg_main_a0_prd_first_free_order_id_r <= rob_commit0_order_id;
    end

    if (rstn && dbg_main_addi_a0_seen_r && !dbg_main_a0_prd_first_free_seen_r &&
        rob_commit1_valid && rob_commit1_regs_write && (rob_commit1_prd_old == dbg_main_addi_a0_prd_r)) begin
        dbg_main_a0_prd_first_free_seen_r <= 1'b1;
        dbg_main_a0_prd_first_free_port_r <= 1'b1;
        dbg_main_a0_prd_first_free_rd_r <= rob_commit1_rd;
        dbg_main_a0_prd_first_free_tag_r <= rob_commit1_tag;
        dbg_main_a0_prd_first_free_order_id_r <= rob_commit1_order_id;
    end

    if (rstn && dbg_main_addi_a0_seen_r && !dbg_main_addi_a0_wb_seen_r &&
        prf_w0_en && (wb0_tag == dbg_main_addi_a0_tag_r)) begin
        dbg_main_addi_a0_wb_seen_r <= 1'b1;
        dbg_main_addi_a0_wb_port_r <= 1'b0;
        dbg_main_addi_a0_wb_tid_r <= prf_w0_tid;
        dbg_main_addi_a0_wb_prd_r <= prf_w0_addr;
        dbg_main_addi_a0_wb_data_r <= prf_w0_data;
        dbg_main_addi_a0_wb_w0_en_r <= prf_w0_en;
        dbg_main_addi_a0_wb_w0_addr_r <= prf_w0_addr;
        dbg_main_addi_a0_wb_w0_data_r <= prf_w0_data;
        dbg_main_addi_a0_wb_w1_en_r <= prf_w1_en;
        dbg_main_addi_a0_wb_w1_addr_r <= prf_w1_addr;
        dbg_main_addi_a0_wb_w1_data_r <= prf_w1_data;
    end

    if (rstn && dbg_main_addi_a0_seen_r && !dbg_main_addi_a0_wb_seen_r &&
        prf_w1_en && (wb1_tag == dbg_main_addi_a0_tag_r)) begin
        dbg_main_addi_a0_wb_seen_r <= 1'b1;
        dbg_main_addi_a0_wb_port_r <= 1'b1;
        dbg_main_addi_a0_wb_tid_r <= prf_w1_tid;
        dbg_main_addi_a0_wb_prd_r <= prf_w1_addr;
        dbg_main_addi_a0_wb_data_r <= prf_w1_data;
        dbg_main_addi_a0_wb_w0_en_r <= prf_w0_en;
        dbg_main_addi_a0_wb_w0_addr_r <= prf_w0_addr;
        dbg_main_addi_a0_wb_w0_data_r <= prf_w0_data;
        dbg_main_addi_a0_wb_w1_en_r <= prf_w1_en;
        dbg_main_addi_a0_wb_w1_addr_r <= prf_w1_addr;
        dbg_main_addi_a0_wb_w1_data_r <= prf_w1_data;
    end
end
`endif

// Pipeline register ro1: no epoch squash needed here.
// Stale instructions pass through to exec_pipe1 → produce wb1 that the ROB
// harmlessly ignores (flushed entries). The store buffer handles wrong-path
// stores via its own epoch-based flush. Squashing here is unsafe because the
// IQ marks entries as 'issued' at issue time, and epoch-squash in ro1 can
// kill correct-path instructions whose epoch was updated between dispatch and
// the ro1 stage, leaving fu_busy stuck forever.

exec_pipe1 #(.TAG_W(5)) u_exec_pipe1(
    .clk           (clk              ),
    .rstn          (rstn             ),
    .in_valid      (ro1_valid        ),
    .in_tag        (ro1_tag          ),
    .in_pc         (ro1_pc           ),
    .in_op_a       (ro1_op_a         ),
    .in_op_b       (ro1_op_b         ),
    .in_imm        (ro1_imm          ),
    .in_func3      (ro1_func3        ),
    .in_func7      (ro1_func7        ),
    .in_alu_op     (ro1_alu_op       ),
    .in_alu_src1   (ro1_alu_src1     ),
    .in_alu_src2   (ro1_alu_src2     ),
    .in_br         (ro1_br           ),
    .in_mem_read   (ro1_mem_read     ),
    .in_mem_write  (ro1_mem_write    ),
    .in_mem2reg    (ro1_mem2reg      ),
    .in_rd         (ro1_rd           ),
    .in_regs_write (ro1_regs_write   ),
    .in_fu         (ro1_fu           ),
    .in_tid        (ro1_tid          ),
    .in_order_id   (ro1_order_id     ),
    .in_epoch      (ro1_epoch        ),
    .flush         (combined_flush_any),
    .flush_tid     (trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid),
    .flush_order_valid(flush_is_order_based),
    .flush_order_id(flush_order_id_mux),
    .alu_out_valid      (p1_alu_valid     ),
    .alu_out_tag        (p1_alu_tag       ),
    .alu_out_result     (p1_alu_result    ),
    .alu_out_rd         (p1_alu_rd        ),
    .alu_out_regs_write (p1_alu_rd_wen    ),
    .alu_out_fu         (p1_alu_fu        ),
    .alu_out_tid        (p1_alu_tid       ),
    .mem_req_valid      (p1_mem_req_valid     ),
    .mem_req_accept     (lsu_req_accept       ),
    .mem_req_wen        (p1_mem_req_wen       ),
    .mem_req_addr       (p1_mem_req_addr      ),
    .mem_req_wdata      (p1_mem_req_wdata     ),
    .mem_req_func3      (p1_mem_req_func3     ),
    .mem_req_tag        (p1_mem_req_tag       ),
    .mem_req_rd         (p1_mem_req_rd        ),
    .mem_req_regs_write (p1_mem_req_regs_write),
    .mem_req_fu         (p1_mem_req_fu        ),
    .mem_req_mem2reg    (p1_mem_req_mem2reg   ),
    .mem_req_tid        (p1_mem_req_tid       ),
    .mem_req_order_id   (p1_mem_req_order_id  ),
    .mem_req_epoch      (p1_mem_req_epoch     ),
    .mul_out_valid      (p1_mul_valid         ),
    .mul_out_tag        (p1_mul_tag           ),
    .mul_out_result     (p1_mul_result        ),
    .mul_out_rd         (p1_mul_rd            ),
    .mul_out_regs_write (p1_mul_regs_write    ),
    .mul_out_fu         (p1_mul_fu            ),
    .mul_out_tid        (p1_mul_tid           ),
    .div_out_valid      (p1_div_valid         ),
    .div_out_tag        (p1_div_tag           ),
    .div_out_result     (p1_div_result        ),
    .div_out_rd         (p1_div_rd            ),
    .div_out_regs_write (p1_div_regs_write    ),
    .div_out_fu         (p1_div_fu            ),
    .div_out_tid        (p1_div_tid           ),
    .div_busy           (p1_div_busy          )
);

// ════════════════════════════════════════════════════════════════════════════
// LSU Shell with Store Buffer Integration
// ════════════════════════════════════════════════════════════════════════════

// LSU Shell wires
wire        lsu_req_accept;
wire        lsu_resp_valid;
wire [31:0] lsu_resp_rdata;
wire [4:0]  lsu_resp_tag;
wire [4:0]  lsu_resp_rd;
wire        lsu_resp_regs_write;
wire [2:0]  lsu_resp_fu;
wire [0:0]  lsu_resp_tid;
wire        lsu_load_hazard;
wire        lsu_early_wakeup_valid;
wire [4:0]  lsu_early_wakeup_tag;
wire        lsu_debug_spec_mmio_load_blocked;
wire        lsu_debug_spec_mmio_load_violation;
wire        lsu_debug_mmio_load_at_rob_head;
wire        lsu_debug_older_store_blocked_mmio_load;

wire [31:0] lsu_mem_addr;
wire [3:0]  lsu_mem_read;
wire [31:0] lsu_mem_rdata;

wire        sb_mem_write_valid;
wire [31:0] sb_mem_write_addr;
wire [31:0] sb_mem_write_data;
wire [3:0]  sb_mem_write_wen;
wire        sb_mem_write_ready;
wire        lsu_debug_store_buffer_empty;
wire [2:0]  lsu_debug_store_buffer_count_t0;
wire [2:0]  lsu_debug_store_buffer_count_t1;
wire [7:0]  legacy_tube_status;
wire        legacy_uart_tx;
wire        legacy_debug_uart_status_busy;
wire        legacy_debug_uart_busy;
wire        legacy_debug_uart_pending_valid;
wire [7:0]  legacy_debug_uart_status_load_count;
wire [7:0]  legacy_debug_uart_tx_store_count;
wire        legacy_debug_uart_tx_byte_valid;
wire [7:0]  legacy_debug_uart_tx_byte;

// ROB-driven commit signals for store buffer
// Stores are committed in-order when they reach ROB head and complete

// LSU Shell - integrates Store Buffer with forwarding
lsu_shell #(
    .TAG_W        (5),
    .ORDER_ID_W   (`METADATA_ORDER_ID_W),
    .EPOCH_W      (8)
) u_lsu_shell (
    .clk                (clk),
    .rstn               (rstn),

    // Flush interface
    .flush              (combined_flush_any ),
    .flush_tid          (trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid ),
    .flush_new_epoch_t0 (flush_new_epoch_t0   ),
    .flush_new_epoch_t1 (flush_new_epoch_t1   ),
    .current_epoch_t0   (epoch_t0             ),
    .current_epoch_t1   (epoch_t1             ),
    .flush_order_valid  (flush_is_order_based),
    .flush_order_id     (flush_order_id_mux),

    // Request from exec_pipe1
    .req_valid          (p1_mem_req_valid     ),
    .req_accept         (lsu_req_accept       ),
    .req_tid            (p1_mem_req_tid       ),
    .req_order_id       (p1_mem_req_order_id  ),
    .req_epoch          (p1_mem_req_epoch     ),
    .req_tag            (p1_mem_req_tag       ),
    .req_rd             (p1_mem_req_rd        ),
    .req_func3          (p1_mem_req_func3     ),
    .req_wen            (p1_mem_req_wen       ),
    .req_addr           (p1_mem_req_addr      ),
    .req_wdata          (p1_mem_req_wdata     ),
    .req_regs_write     (p1_mem_req_regs_write),
    .req_fu             (p1_mem_req_fu        ),
    .req_mem2reg        (p1_mem_req_mem2reg   ),
    .rob_head_valid_t0  (rob_head_valid_t0),
    .rob_head_order_id_t0(rob_head_order_id_t0),
    .rob_head_flushed_t0(rob_head_flushed_t0),
    .rob_head_valid_t1  (rob_head_valid_t1),
    .rob_head_order_id_t1(rob_head_order_id_t1),
    .rob_head_flushed_t1(rob_head_flushed_t1),

    // Response to writeback
    .resp_valid         (lsu_resp_valid       ),
    .resp_tid           (lsu_resp_tid         ),
    .resp_order_id      (                     ),
    .resp_epoch         (                     ),
    .resp_tag           (lsu_resp_tag         ),
    .resp_rd            (lsu_resp_rd          ),
    .resp_func3         (                     ),
    .resp_regs_write    (lsu_resp_regs_write  ),
    .resp_fu            (lsu_resp_fu          ),
    .resp_rdata         (lsu_resp_rdata       ),
    .resp_early_wakeup_valid(lsu_early_wakeup_valid),
    .resp_early_wakeup_tag(lsu_early_wakeup_tag),

    // Memory interface
    .mem_addr           (lsu_mem_addr         ),
    .mem_read           (lsu_mem_read         ),
    .mem_rdata          (lsu_mem_rdata        ),

    // ROB Commit (driven by ROB in-order retirement)
    .commit0_valid      (rob_commit0_valid    ),
    .commit1_valid      (rob_commit1_valid    ),
    .commit0_order_id   (rob_commit0_order_id ),
    .commit1_order_id   (rob_commit1_order_id ),
    .commit0_is_store   (rob_commit0_is_store ),
    .commit1_is_store   (rob_commit1_is_store ),

    // Store Buffer Drain
    .sb_mem_write_valid (sb_mem_write_valid   ),
    .sb_mem_write_addr  (sb_mem_write_addr    ),
    .sb_mem_write_data  (sb_mem_write_data    ),
    .sb_mem_write_wen   (sb_mem_write_wen     ),
    .sb_mem_write_ready (sb_mem_write_ready   ),
    .debug_store_buffer_empty(lsu_debug_store_buffer_empty),
    .debug_store_buffer_count_t0(lsu_debug_store_buffer_count_t0),
    .debug_store_buffer_count_t1(lsu_debug_store_buffer_count_t1),

    // Load hazard output
    .load_hazard        (lsu_load_hazard      ),

    // HPM event
    .hpm_sb_stall_event (hpm_sb_stall_event   ),
    .debug_spec_mmio_load_blocked(lsu_debug_spec_mmio_load_blocked),
    .debug_spec_mmio_load_violation(lsu_debug_spec_mmio_load_violation),
    .debug_mmio_load_at_rob_head(lsu_debug_mmio_load_at_rob_head),
    .debug_older_store_blocked_mmio_load(lsu_debug_older_store_blocked_mmio_load),

    // Task 6: Mem_subsys M1 interface
    .use_mem_subsys     (use_mem_subsys       ),
    .m1_req_valid       (m1_req_valid         ),
    .m1_req_ready       (m1_req_ready         ),
    .m1_req_addr        (m1_req_addr          ),
    .m1_req_write       (m1_req_write         ),
    .m1_req_wdata       (m1_req_wdata         ),
    .m1_req_wen         (m1_req_wen           ),
    .m1_resp_valid      (m1_resp_valid        ),
    .m1_resp_data       (m1_resp_data         )
);

// ════════════════════════════════════════════════════════════════════════════
// Legacy stage_mem path is disabled in mem_subsys mode.
// mem_subsys is now the only lower-memory endpoint for both LSU loads and
// committed store-buffer drains.
// ════════════════════════════════════════════════════════════════════════════
generate
if (USE_MEM_SUBSYS) begin : gen_disable_legacy_mem
    assign lsu_mem_rdata      = 32'd0;
    assign sb_mem_write_ready = 1'b0;
    assign legacy_tube_status = 8'd0;
    assign legacy_uart_tx     = 1'b1;
    assign legacy_debug_uart_status_busy = 1'b0;
    assign legacy_debug_uart_busy = 1'b0;
    assign legacy_debug_uart_pending_valid = 1'b0;
    assign legacy_debug_uart_status_load_count = 8'd0;
    assign legacy_debug_uart_tx_store_count = 8'd0;
    assign legacy_debug_uart_tx_byte_valid = 1'b0;
    assign legacy_debug_uart_tx_byte = 8'd0;
end else begin : gen_legacy_mem
    legacy_mem_subsys #(
        .RAM_WORDS(4096)
    ) u_legacy_mem_subsys (
        .clk            (clk               ),
        .rstn           (rstn              ),
        .uart_rx        (uart_rx           ),
        .load_addr      (lsu_mem_addr      ),
        .load_read      (lsu_mem_read      ),
        .load_rdata     (lsu_mem_rdata     ),
        .sb_write_valid (sb_mem_write_valid),
        .sb_write_addr  (sb_mem_write_addr ),
        .sb_write_data  (sb_mem_write_data ),
        .sb_write_wen   (sb_mem_write_wen  ),
        .sb_write_ready (sb_mem_write_ready),
        .tube_status    (legacy_tube_status),
        .uart_tx        (legacy_uart_tx    ),
        .debug_uart_status_busy(legacy_debug_uart_status_busy),
        .debug_uart_busy(legacy_debug_uart_busy),
        .debug_uart_pending_valid(legacy_debug_uart_pending_valid),
        .debug_uart_status_load_count(legacy_debug_uart_status_load_count),
        .debug_uart_tx_store_count(legacy_debug_uart_tx_store_count),
        .debug_uart_tx_byte_valid(legacy_debug_uart_tx_byte_valid),
        .debug_uart_tx_byte(legacy_debug_uart_tx_byte)
    );
end
endgenerate

// ════════════════════════════════════════════════════════════════════════════
// STAGE 8: Write-Back (select between ALU result and MEM load data)
// ════════════════════════════════════════════════════════════════════════════

// LSU shell handles the load data shaping, so we use its response directly
wire [31:0] mem_wb_data_sel;
assign mem_wb_data_sel = lsu_resp_rdata;

// Bypass signals - use LSU shell response
assign mem_wb_valid  = lsu_resp_valid;
assign mem_wb_rd     = lsu_resp_rd;
assign mem_wb_rd_wen = lsu_resp_regs_write && (lsu_resp_fu == `FU_LOAD);
assign mem_wb_data   = mem_wb_data_sel;

// mem_wb_tid for bypass network
wire [0:0] mem_wb_tid_r;
assign mem_wb_tid_r = lsu_resp_tid;

// ─── WB Port 0: from Pipe 0 (INT + Branch) OR RoCC Response ──────────────────
// WB0 outputs (for CDB/scoreboard/bypass)
// RoCC instructions bypass exec_pipe0 and send response directly to WB0
// Flush-safe: Only accept RoCC response if epoch matches (rocc_resp_not_flushed)
wire wb0_from_rocc = rocc_resp_valid && rocc_resp_not_flushed;
wire wb0_from_pipe0 = p0_ex_valid && !wb0_from_rocc;  // RoCC takes priority if valid

assign wb0_valid      = wb0_from_rocc ? rocc_resp_valid   : p0_ex_valid;
assign wb0_tag        = wb0_from_rocc ? rocc_resp_tag     : p0_ex_tag;
assign wb0_rd         = wb0_from_rocc ? rocc_resp_rd      : p0_ex_rd;
assign wb0_regs_write = wb0_from_rocc ? (rocc_resp_rd != 5'd0) : p0_ex_rd_wen;
assign wb0_fu         = wb0_from_rocc ? `FU_INT0          : p0_ex_fu;
assign wb0_tid        = wb0_from_rocc ? rocc_resp_tid     : p0_ex_tid;

// ─── WB Port 1: from DIV, MUL, MEM, or ALU (priority order) ──────────────
// DIV takes highest priority, then MUL, then MEM, then ALU
wire        wb1_div_curr_valid = p1_div_valid;
wire [4:0]  wb1_div_curr_tag = p1_div_tag;
wire [4:0]  wb1_div_curr_rd = p1_div_rd;
wire        wb1_div_curr_regs_write = p1_div_regs_write;
wire [2:0]  wb1_div_curr_fu = p1_div_fu;
wire [0:0]  wb1_div_curr_tid = p1_div_tid;
wire [31:0] wb1_div_curr_data = p1_div_result;

wire        wb1_mul_curr_valid = p1_mul_valid;
wire [4:0]  wb1_mul_curr_tag = p1_mul_tag;
wire [4:0]  wb1_mul_curr_rd = p1_mul_rd;
wire        wb1_mul_curr_regs_write = p1_mul_regs_write;
wire [2:0]  wb1_mul_curr_fu = p1_mul_fu;
wire [0:0]  wb1_mul_curr_tid = p1_mul_tid;
wire [31:0] wb1_mul_curr_data = p1_mul_result;

wire        wb1_mem_curr_valid = lsu_resp_valid;
wire [4:0]  wb1_mem_curr_tag = lsu_resp_tag;
wire [4:0]  wb1_mem_curr_rd = lsu_resp_rd;
wire        wb1_mem_curr_regs_write = lsu_resp_regs_write;
wire [2:0]  wb1_mem_curr_fu = lsu_resp_fu;
wire [0:0]  wb1_mem_curr_tid = lsu_resp_tid;
wire [31:0] wb1_mem_curr_data = mem_wb_data_sel;

wire        wb1_alu_curr_valid = p1_alu_valid;
wire [4:0]  wb1_alu_curr_tag = p1_alu_tag;
wire [4:0]  wb1_alu_curr_rd = p1_alu_rd;
wire        wb1_alu_curr_regs_write = p1_alu_rd_wen;
wire [2:0]  wb1_alu_curr_fu = p1_alu_fu;
wire [0:0]  wb1_alu_curr_tid = p1_alu_tid;
wire [31:0] wb1_alu_curr_data = p1_alu_result;

reg         wb1_div_pending_valid;
reg  [4:0]  wb1_div_pending_tag;
reg  [4:0]  wb1_div_pending_rd;
reg         wb1_div_pending_regs_write;
reg  [2:0]  wb1_div_pending_fu;
reg  [0:0]  wb1_div_pending_tid;
reg  [31:0] wb1_div_pending_data;

reg         wb1_mul_pending_valid;
reg  [4:0]  wb1_mul_pending_tag;
reg  [4:0]  wb1_mul_pending_rd;
reg         wb1_mul_pending_regs_write;
reg  [2:0]  wb1_mul_pending_fu;
reg  [0:0]  wb1_mul_pending_tid;
reg  [31:0] wb1_mul_pending_data;

reg         wb1_mem_pending_valid;
reg  [4:0]  wb1_mem_pending_tag;
reg  [4:0]  wb1_mem_pending_rd;
reg         wb1_mem_pending_regs_write;
reg  [2:0]  wb1_mem_pending_fu;
reg  [0:0]  wb1_mem_pending_tid;
reg  [31:0] wb1_mem_pending_data;

reg         wb1_alu_pending_valid;
reg  [4:0]  wb1_alu_pending_tag;
reg  [4:0]  wb1_alu_pending_rd;
reg         wb1_alu_pending_regs_write;
reg  [2:0]  wb1_alu_pending_fu;
reg  [0:0]  wb1_alu_pending_tid;
reg  [31:0] wb1_alu_pending_data;

wire wb1_div_avail = wb1_div_pending_valid || wb1_div_curr_valid;
wire wb1_mul_avail = wb1_mul_pending_valid || wb1_mul_curr_valid;
wire wb1_mem_avail = wb1_mem_pending_valid || wb1_mem_curr_valid;
wire wb1_alu_avail = wb1_alu_pending_valid || wb1_alu_curr_valid;

wire wb1_from_div = wb1_div_avail;
wire wb1_from_mul = !wb1_from_div && wb1_mul_avail;
wire wb1_from_mem = !wb1_from_div && !wb1_from_mul && wb1_mem_avail;
wire wb1_from_alu = !wb1_from_div && !wb1_from_mul && !wb1_from_mem && wb1_alu_avail;

wire [4:0]  wb1_div_sel_tag = wb1_div_pending_valid ? wb1_div_pending_tag : wb1_div_curr_tag;
wire [4:0]  wb1_div_sel_rd = wb1_div_pending_valid ? wb1_div_pending_rd : wb1_div_curr_rd;
wire        wb1_div_sel_regs_write = wb1_div_pending_valid ? wb1_div_pending_regs_write : wb1_div_curr_regs_write;
wire [2:0]  wb1_div_sel_fu = wb1_div_pending_valid ? wb1_div_pending_fu : wb1_div_curr_fu;
wire [0:0]  wb1_div_sel_tid = wb1_div_pending_valid ? wb1_div_pending_tid : wb1_div_curr_tid;
wire [31:0] wb1_div_sel_data = wb1_div_pending_valid ? wb1_div_pending_data : wb1_div_curr_data;

wire [4:0]  wb1_mul_sel_tag = wb1_mul_pending_valid ? wb1_mul_pending_tag : wb1_mul_curr_tag;
wire [4:0]  wb1_mul_sel_rd = wb1_mul_pending_valid ? wb1_mul_pending_rd : wb1_mul_curr_rd;
wire        wb1_mul_sel_regs_write = wb1_mul_pending_valid ? wb1_mul_pending_regs_write : wb1_mul_curr_regs_write;
wire [2:0]  wb1_mul_sel_fu = wb1_mul_pending_valid ? wb1_mul_pending_fu : wb1_mul_curr_fu;
wire [0:0]  wb1_mul_sel_tid = wb1_mul_pending_valid ? wb1_mul_pending_tid : wb1_mul_curr_tid;
wire [31:0] wb1_mul_sel_data = wb1_mul_pending_valid ? wb1_mul_pending_data : wb1_mul_curr_data;

wire [4:0]  wb1_mem_sel_tag = wb1_mem_pending_valid ? wb1_mem_pending_tag : wb1_mem_curr_tag;
wire [4:0]  wb1_mem_sel_rd = wb1_mem_pending_valid ? wb1_mem_pending_rd : wb1_mem_curr_rd;
wire        wb1_mem_sel_regs_write = wb1_mem_pending_valid ? wb1_mem_pending_regs_write : wb1_mem_curr_regs_write;
wire [2:0]  wb1_mem_sel_fu = wb1_mem_pending_valid ? wb1_mem_pending_fu : wb1_mem_curr_fu;
wire [0:0]  wb1_mem_sel_tid = wb1_mem_pending_valid ? wb1_mem_pending_tid : wb1_mem_curr_tid;
wire [31:0] wb1_mem_sel_data = wb1_mem_pending_valid ? wb1_mem_pending_data : wb1_mem_curr_data;

wire [4:0]  wb1_alu_sel_tag = wb1_alu_pending_valid ? wb1_alu_pending_tag : wb1_alu_curr_tag;
wire [4:0]  wb1_alu_sel_rd = wb1_alu_pending_valid ? wb1_alu_pending_rd : wb1_alu_curr_rd;
wire        wb1_alu_sel_regs_write = wb1_alu_pending_valid ? wb1_alu_pending_regs_write : wb1_alu_curr_regs_write;
wire [2:0]  wb1_alu_sel_fu = wb1_alu_pending_valid ? wb1_alu_pending_fu : wb1_alu_curr_fu;
wire [0:0]  wb1_alu_sel_tid = wb1_alu_pending_valid ? wb1_alu_pending_tid : wb1_alu_curr_tid;
wire [31:0] wb1_alu_sel_data = wb1_alu_pending_valid ? wb1_alu_pending_data : wb1_alu_curr_data;

assign wb1_valid      = wb1_from_div || wb1_from_mul || wb1_from_mem || wb1_from_alu;
assign wb1_tag        = wb1_from_div ? wb1_div_sel_tag  :
                        wb1_from_mul ? wb1_mul_sel_tag  :
                        wb1_from_mem ? wb1_mem_sel_tag  :
                        wb1_from_alu ? wb1_alu_sel_tag  : 5'd0;
assign wb1_rd         = wb1_from_div ? wb1_div_sel_rd  :
                        wb1_from_mul ? wb1_mul_sel_rd  :
                        wb1_from_mem ? wb1_mem_sel_rd  :
                        wb1_from_alu ? wb1_alu_sel_rd  : 5'd0;
assign wb1_regs_write = wb1_from_div ? wb1_div_sel_regs_write :
                        wb1_from_mul ? wb1_mul_sel_regs_write :
                        wb1_from_mem ? wb1_mem_sel_regs_write :
                        wb1_from_alu ? wb1_alu_sel_regs_write : 1'b0;
assign wb1_fu         = wb1_from_div ? wb1_div_sel_fu  :
                        wb1_from_mul ? wb1_mul_sel_fu  :
                        wb1_from_mem ? wb1_mem_sel_fu  :
                        wb1_from_alu ? wb1_alu_sel_fu  : 3'd0;
assign wb1_tid        = wb1_from_div ? wb1_div_sel_tid  :
                        wb1_from_mul ? wb1_mul_sel_tid  :
                        wb1_from_mem ? wb1_mem_sel_tid  :
                        wb1_from_alu ? wb1_alu_sel_tid  : 1'b0;

// ════════════════════════════════════════════════════════════════════════════
// Result Buffer: Store WB results indexed by tag for commit-time RF write
// ════════════════════════════════════════════════════════════════════════════
// 32-entry buffer (one per tag), stores result data for instructions in flight
reg [31:0] result_buffer [0:31];
reg        result_valid  [0:31];
reg [7:0]  debug_last_iss0_pc_lo_r;
reg [7:0]  debug_last_iss1_pc_lo_r;
reg [7:0]  debug_branch_issue_count_r;
reg [7:0]  debug_branch_complete_count_r;
reg [7:0]  debug_if_valid_count_r;
reg [7:0]  debug_fb_pop_count_r;
reg [7:0]  debug_dec0_count_r;
reg [7:0]  debug_disp0_count_r;
reg [7:0]  debug_retire_count_r;
reg [7:0]  debug_m1_req_count_r;
reg [7:0]  debug_m1_resp_count_r;
reg [7:0]  debug_uart_tx_start_count_r;

// WB data sources for result buffer
wire [31:0] wb0_result_data = wb0_from_rocc ? rocc_resp_data : p0_ex_result;
wire [31:0] wb1_result_data = wb1_from_div ? wb1_div_sel_data :
                              wb1_from_mul ? wb1_mul_sel_data :
                              wb1_from_mem ? wb1_mem_sel_data :
                              wb1_from_alu ? wb1_alu_sel_data : 32'd0;

wire wb1_div_emit_curr = wb1_from_div && !wb1_div_pending_valid;
wire wb1_mul_emit_curr = wb1_from_mul && !wb1_mul_pending_valid;
wire wb1_mem_emit_curr = wb1_from_mem && !wb1_mem_pending_valid;
wire wb1_alu_emit_curr = wb1_from_alu && !wb1_alu_pending_valid;

wire wb1_div_capture_curr = wb1_div_curr_valid && !wb1_div_emit_curr;
wire wb1_mul_capture_curr = wb1_mul_curr_valid && !wb1_mul_emit_curr;
wire wb1_mem_capture_curr = wb1_mem_curr_valid && !wb1_mem_emit_curr;
wire wb1_alu_capture_curr = wb1_alu_curr_valid && !wb1_alu_emit_curr;

// Write to result buffer on WB (capture completion data)
integer i;
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (i = 0; i < 32; i = i + 1) begin
            result_buffer[i] <= 32'd0;
            result_valid[i]  <= 1'b0;
        end
        wb1_div_pending_valid <= 1'b0;
        wb1_div_pending_tag <= 5'd0;
        wb1_div_pending_rd <= 5'd0;
        wb1_div_pending_regs_write <= 1'b0;
        wb1_div_pending_fu <= 3'd0;
        wb1_div_pending_tid <= 1'b0;
        wb1_div_pending_data <= 32'd0;
        wb1_mul_pending_valid <= 1'b0;
        wb1_mul_pending_tag <= 5'd0;
        wb1_mul_pending_rd <= 5'd0;
        wb1_mul_pending_regs_write <= 1'b0;
        wb1_mul_pending_fu <= 3'd0;
        wb1_mul_pending_tid <= 1'b0;
        wb1_mul_pending_data <= 32'd0;
        wb1_mem_pending_valid <= 1'b0;
        wb1_mem_pending_tag <= 5'd0;
        wb1_mem_pending_rd <= 5'd0;
        wb1_mem_pending_regs_write <= 1'b0;
        wb1_mem_pending_fu <= 3'd0;
        wb1_mem_pending_tid <= 1'b0;
        wb1_mem_pending_data <= 32'd0;
        wb1_alu_pending_valid <= 1'b0;
        wb1_alu_pending_tag <= 5'd0;
        wb1_alu_pending_rd <= 5'd0;
        wb1_alu_pending_regs_write <= 1'b0;
        wb1_alu_pending_fu <= 3'd0;
        wb1_alu_pending_tid <= 1'b0;
        wb1_alu_pending_data <= 32'd0;
        debug_last_iss0_pc_lo_r <= 8'd0;
        debug_last_iss1_pc_lo_r <= 8'd0;
        debug_branch_issue_count_r <= 8'd0;
        debug_branch_complete_count_r <= 8'd0;
        debug_if_valid_count_r <= 8'd0;
        debug_fb_pop_count_r <= 8'd0;
        debug_dec0_count_r <= 8'd0;
        debug_disp0_count_r <= 8'd0;
        debug_retire_count_r <= 8'd0;
        debug_m1_req_count_r <= 8'd0;
        debug_m1_resp_count_r <= 8'd0;
        debug_uart_tx_start_count_r <= 8'd0;
    end else begin
        if (if_valid)
            debug_if_valid_count_r <= debug_if_valid_count_r + 8'd1;
        if (fb_pop0_valid && fb_consume_0)
            debug_fb_pop_count_r <= debug_fb_pop_count_r + 8'd1;
        if (dec0_valid)
            debug_dec0_count_r <= debug_dec0_count_r + 8'd1;
        if (disp0_accepted)
            debug_disp0_count_r <= debug_disp0_count_r + 8'd1;
        if (|rob_instr_retired)
            debug_retire_count_r <= debug_retire_count_r + 8'd1;
        if (m1_req_valid && m1_req_ready)
            debug_m1_req_count_r <= debug_m1_req_count_r + 8'd1;
        if (m1_resp_valid)
            debug_m1_resp_count_r <= debug_m1_resp_count_r + 8'd1;
        if (mem_subsys_debug_uart_tx_byte_valid || legacy_debug_uart_tx_byte_valid)
            debug_uart_tx_start_count_r <= debug_uart_tx_start_count_r + 8'd1;
        if (p0_pre_ro_valid)
            debug_last_iss0_pc_lo_r <= p0_pre_ro_pc[7:0];
        if (p1_winner_valid)
            debug_last_iss1_pc_lo_r <= p1_issue_is_mem ? p1_mem_cand_pc[7:0] :
                                        p1_issue_is_div ? p1_div_cand_pc[7:0] : p1_mul_cand_pc[7:0];
        if (p0_pre_ro_valid && p0_pre_ro_br)
            debug_branch_issue_count_r <= debug_branch_issue_count_r + 8'd1;
        if (pipe0_br_complete)
            debug_branch_complete_count_r <= debug_branch_complete_count_r + 8'd1;

        // Tags are recycled with RS entry reuse, so clear any stale buffered
        // result as soon as a fresh instruction claims the tag.
        if (disp0_accepted && (sb_disp0_tag != 5'd0))
            result_valid[sb_disp0_tag] <= 1'b0;
        if (disp1_accepted && (sb_disp1_tag != 5'd0))
            result_valid[sb_disp1_tag] <= 1'b0;

        if (wb1_from_div && wb1_div_pending_valid)
            wb1_div_pending_valid <= 1'b0;
        if (wb1_from_mul && wb1_mul_pending_valid)
            wb1_mul_pending_valid <= 1'b0;
        if (wb1_from_mem && wb1_mem_pending_valid)
            wb1_mem_pending_valid <= 1'b0;
        if (wb1_from_alu && wb1_alu_pending_valid)
            wb1_alu_pending_valid <= 1'b0;

        if (wb1_div_capture_curr && (!wb1_div_pending_valid || wb1_from_div)) begin
            wb1_div_pending_valid <= 1'b1;
            wb1_div_pending_tag <= wb1_div_curr_tag;
            wb1_div_pending_rd <= wb1_div_curr_rd;
            wb1_div_pending_regs_write <= wb1_div_curr_regs_write;
            wb1_div_pending_fu <= wb1_div_curr_fu;
            wb1_div_pending_tid <= wb1_div_curr_tid;
            wb1_div_pending_data <= wb1_div_curr_data;
        end
        if (wb1_mul_capture_curr && (!wb1_mul_pending_valid || wb1_from_mul)) begin
            wb1_mul_pending_valid <= 1'b1;
            wb1_mul_pending_tag <= wb1_mul_curr_tag;
            wb1_mul_pending_rd <= wb1_mul_curr_rd;
            wb1_mul_pending_regs_write <= wb1_mul_curr_regs_write;
            wb1_mul_pending_fu <= wb1_mul_curr_fu;
            wb1_mul_pending_tid <= wb1_mul_curr_tid;
            wb1_mul_pending_data <= wb1_mul_curr_data;
        end
        if (wb1_mem_capture_curr && (!wb1_mem_pending_valid || wb1_from_mem)) begin
            wb1_mem_pending_valid <= 1'b1;
            wb1_mem_pending_tag <= wb1_mem_curr_tag;
            wb1_mem_pending_rd <= wb1_mem_curr_rd;
            wb1_mem_pending_regs_write <= wb1_mem_curr_regs_write;
            wb1_mem_pending_fu <= wb1_mem_curr_fu;
            wb1_mem_pending_tid <= wb1_mem_curr_tid;
            wb1_mem_pending_data <= wb1_mem_curr_data;
        end
        if (wb1_alu_capture_curr && (!wb1_alu_pending_valid || wb1_from_alu)) begin
            wb1_alu_pending_valid <= 1'b1;
            wb1_alu_pending_tag <= wb1_alu_curr_tag;
            wb1_alu_pending_rd <= wb1_alu_curr_rd;
            wb1_alu_pending_regs_write <= wb1_alu_curr_regs_write;
            wb1_alu_pending_fu <= wb1_alu_curr_fu;
            wb1_alu_pending_tid <= wb1_alu_curr_tid;
            wb1_alu_pending_data <= wb1_alu_curr_data;
        end

        // Write WB0 result (highest priority if same tag)
        if (wb0_valid && wb0_regs_write) begin
            result_buffer[wb0_tag] <= wb0_result_data;
            result_valid[wb0_tag]  <= 1'b1;
        end

        // Write WB1 result
        if (wb1_valid && wb1_regs_write) begin
            result_buffer[wb1_tag] <= wb1_result_data;
            result_valid[wb1_tag]  <= 1'b1;
`ifdef VERBOSE_SIM_LOGS
            if (wb1_from_div)
                $display("[WB1_DIV] t=%0t tag=%0d rd=%0d data=%h", $time, wb1_tag, wb1_rd, wb1_result_data);
`endif
        end

        if (rob_commit0_valid && rob_commit0_has_result && (rob_commit0_tag != 5'd0))
            result_valid[rob_commit0_tag] <= 1'b0;
        if (rob_commit1_valid && rob_commit1_has_result && (rob_commit1_tag != 5'd0))
            result_valid[rob_commit1_tag] <= 1'b0;
    end
end

assign p0_tagbuf_a_valid = (p0_pre_ro_src1_tag != 5'd0) && result_valid[p0_pre_ro_src1_tag];
assign p0_tagbuf_a_data  = result_buffer[p0_pre_ro_src1_tag];
assign p0_tagbuf_b_valid = (p0_pre_ro_src2_tag != 5'd0) && result_valid[p0_pre_ro_src2_tag];
assign p0_tagbuf_b_data  = result_buffer[p0_pre_ro_src2_tag];
assign p1_tagbuf_a_valid = (p1_pre_ro_src1_tag != 5'd0) && result_valid[p1_pre_ro_src1_tag];
assign p1_tagbuf_a_data  = result_buffer[p1_pre_ro_src1_tag];
assign p1_tagbuf_b_valid = (p1_pre_ro_src2_tag != 5'd0) && result_valid[p1_pre_ro_src2_tag];
assign p1_tagbuf_b_data  = result_buffer[p1_pre_ro_src2_tag];

// ════════════════════════════════════════════════════════════════════════════
// Register File Write: Drive from ROB commit (not WB)
// ════════════════════════════════════════════════════════════════════════════
// ROB commit0 is for Thread 0, commit1 is for Thread 1.
// Only architectural writers leave a result behind in result_buffer; branch/store
// commits must not drive arbitrary rd fields back into the register file.
// Port 0: ROB commit 0 (Thread 0)
assign w_regs_en_0   = rob_commit0_valid && rob_commit0_has_result;
assign w_regs_addr_0 = rob_commit0_rd;
assign w_regs_data_0 = rob_commit0_data;
assign w_regs_tid_0  = 1'b0;  // Thread 0

// Port 1: ROB commit 1 (Thread 1)
assign w_regs_en_1   = rob_commit1_valid && rob_commit1_has_result;
assign w_regs_addr_1 = rob_commit1_rd;
assign w_regs_data_1 = rob_commit1_data;
assign w_regs_tid_1  = 1'b1;  // Thread 1

// ════════════════════════════════════════════════════════════════════════════
// CSR Unit (Live connection for CSR/MRET support)
// ════════════════════════════════════════════════════════════════════════════
csr_unit #(.HART_ID(0)) u_csr_unit(
    .clk             (clk               ),
    .rstn            (rstn              ),
    .csr_valid       (pipe0_csr_valid   ),
    .csr_addr        (p0_pre_ro_csr_addr),
    .csr_op          (pipe0_csr_op      ),
    .csr_wdata       (pipe0_csr_wdata   ),
    .csr_rdata       (csr_rdata         ),
    .exc_valid       (1'b0              ),
    .exc_cause       (32'd0             ),
    .exc_pc          (trap_pc_r         ),
    .exc_tval        (32'd0             ),
    .mret_valid      (pipe0_mret_valid  ),
    .mret_commit     (rob_commit0_is_mret || rob_commit1_is_mret),
    .trap_enter      (trap_enter        ),
    .trap_target     (trap_target       ),
    .trap_return     (trap_return       ),
    .mepc_out        (mepc_out          ),
    .satp_out        (                  ),
    .priv_mode_out   (                  ),
    .mstatus_mxr     (                  ),
    .mstatus_sum     (                  ),
    .global_int_en   (global_int_en     ),
    .instr_retired   (rob_instr_retired[0]),
    .instr_retired_1 (rob_instr_retired[1]),
    .hpm_branch_mispredict (pipe0_br_ctrl),
    .hpm_icache_miss       (hpm_icache_miss_event),
    .hpm_dcache_miss       (1'b0),
    .hpm_l2_miss           (1'b0),
    .hpm_sb_stall          (hpm_sb_stall_event),
    .hpm_issue_bubble      (rob_instr_retired == 2'b00),
    .hpm_rocc_busy         (1'b0),
    .ext_timer_irq   (ext_timer_irq     ),
    .ext_external_irq(ext_external_irq  )
);

// ════════════════════════════════════════════════════════════════════════════
// RoCC AI Accelerator Instantiation
// ════════════════════════════════════════════════════════════════════════════

generate
if (ROCC_ACCEL_ENABLE) begin : gen_rocc_accel
    rocc_ai_accelerator #(
        .SA_SIZE   (8),
        .VEC_WIDTH (128),
        .SCRATCH_KB(4),
        .TAG_W     (5)
    ) u_rocc_ai_accelerator (
        .clk              (clk),
        .rstn             (rstn),

        // Command interface (from scoreboard issue port 0)
        .cmd_valid        (rocc_cmd_valid),
        .cmd_ready        (rocc_cmd_ready),
        .cmd_funct7       (rocc_cmd_funct7),
        .cmd_funct3       (rocc_cmd_funct3),
        .cmd_rd           (rocc_cmd_rd),
        .cmd_rs1_data     (rocc_cmd_rs1_data),
        .cmd_rs2_data     (rocc_cmd_rs2_data),
        .cmd_tag          (rocc_cmd_tag),
        .cmd_tid          (rocc_cmd_tid),

        // Response interface (to WB0)
        .resp_valid       (rocc_resp_valid),
        .resp_ready       (rocc_resp_ready),
        .resp_rd          (rocc_resp_rd),
        .resp_data        (rocc_resp_data),
        .resp_tag         (rocc_resp_tag),
        .resp_tid         (rocc_resp_tid),

        // DMA memory interface (to M2 port)
        .mem_req_valid    (rocc_mem_req_valid),
        .mem_req_ready    (rocc_mem_req_ready),
        .mem_req_addr     (rocc_mem_req_addr),
        .mem_req_wdata    (rocc_mem_req_wdata),
        .mem_req_wen      (rocc_mem_req_wen),
        .mem_resp_valid   (rocc_mem_resp_valid),
        .mem_resp_rdata   (rocc_mem_resp_rdata),

        // Status
        .accel_busy       (rocc_busy),
        .accel_interrupt  (rocc_interrupt)
    );
end else begin : gen_rocc_stub
    assign rocc_cmd_ready     = 1'b0;
    assign rocc_resp_valid    = 1'b0;
    assign rocc_resp_rd       = 5'd0;
    assign rocc_resp_data     = 32'd0;
    assign rocc_resp_tag      = 5'd0;
    assign rocc_resp_tid      = 1'b0;
    assign rocc_mem_req_valid = 1'b0;
    assign rocc_mem_req_addr  = 32'd0;
    assign rocc_mem_req_wdata = 32'd0;
    assign rocc_mem_req_wen   = 1'b0;
    assign rocc_busy          = 1'b0;
    assign rocc_interrupt     = 1'b0;
end
endgenerate

// ════════════════════════════════════════════════════════════════════════════
// Task 4: Memory Subsystem Integration
// ════════════════════════════════════════════════════════════════════════════

// M1 (D-side) interface signals
wire        m1_req_valid;
wire        m1_req_ready;
wire [31:0] m1_req_addr;
wire        m1_req_write;
wire [31:0] m1_req_wdata;
wire [3:0]  m1_req_wen;
wire        m1_resp_valid;
wire [31:0] m1_resp_data;

// M2 (RoCC DMA) interface signals
wire        m2_req_valid;
wire        m2_req_ready;
wire [31:0] m2_req_addr;
wire        m2_req_write;
wire [31:0] m2_req_wdata;
wire [3:0]  m2_req_wen;
wire        m2_resp_valid;
wire [31:0] m2_resp_data;

// Internal status/interrupts from the full mem_subsys path
wire [7:0]  mem_subsys_tube_status;
wire        mem_subsys_ext_timer_irq;     // CLINT timer interrupt (MTIP)
wire        mem_subsys_ext_external_irq;  // PLIC external interrupt (MEIP)
wire        mem_subsys_uart_tx;           // UART TX from mem_subsys MMIO
wire        mem_subsys_debug_uart_tx_byte_valid;
wire [7:0]  mem_subsys_debug_uart_tx_byte;
wire [7:0]  mem_subsys_debug_uart_status_load_count;
wire [7:0]  mem_subsys_debug_uart_tx_store_count;
wire [127:0] mem_subsys_debug_ddr3_m0_bus;
wire        ext_timer_irq;
wire        ext_external_irq;
wire        ext_irq_src_clean = (ext_irq_src === 1'b1);

// RoCC DMA to M2 port connections
assign m2_req_valid  = rocc_mem_req_valid;
assign m2_req_addr   = rocc_mem_req_addr;
assign m2_req_write  = rocc_mem_req_wen;
assign m2_req_wdata  = rocc_mem_req_wdata;
assign m2_req_wen    = rocc_mem_req_wen ? 4'b1111 : 4'b0000;  // Word-wide writes
assign rocc_mem_req_ready = m2_req_ready;
assign rocc_mem_resp_valid = m2_resp_valid;
assign rocc_mem_resp_rdata = m2_resp_data;

generate
if (USE_MEM_SUBSYS) begin : gen_mem_subsys
    mem_subsys u_mem_subsys (
        .clk               (clk),
        .rstn              (rstn),

        // M0: I-side (inst_memory refill)
        .m0_req_valid      (m0_req_valid),
        .m0_req_ready      (m0_req_ready),
        .m0_req_addr       (m0_req_addr),
        .m0_resp_valid     (m0_resp_valid),
        .m0_resp_data      (m0_resp_data),
        .m0_resp_last      (m0_resp_last),
        .m0_resp_ready     (m0_resp_ready),
        .m0_bypass_addr    (m0_bypass_addr),
        .m0_bypass_data    (m0_bypass_data),

        // M1: D-side (LSU/store buffer)
        .m1_req_valid      (m1_req_valid),
        .m1_req_ready      (m1_req_ready),
        .m1_req_addr       (m1_req_addr),
        .m1_req_write      (m1_req_write),
        .m1_req_wdata      (m1_req_wdata),
        .m1_req_wen        (m1_req_wen),
        .m1_resp_valid     (m1_resp_valid),
        .m1_resp_data      (m1_resp_data),

        // M2: RoCC DMA interface
        .m2_req_valid      (m2_req_valid),
        .m2_req_ready      (m2_req_ready),
        .m2_req_addr       (m2_req_addr),
        .m2_req_write      (m2_req_write),
        .m2_req_wdata      (m2_req_wdata),
        .m2_req_wen        (m2_req_wen),
        .m2_resp_valid     (m2_resp_valid),
        .m2_resp_data      (m2_resp_data),

        // Testbench observation
        .tube_status       (mem_subsys_tube_status),

        // External interrupt wiring
        .ext_irq_src       (ext_irq_src_clean),
        .ext_timer_irq     (mem_subsys_ext_timer_irq),
        .ext_external_irq  (mem_subsys_ext_external_irq),

        // UART physical interface
        .uart_rx           (uart_rx),
        .uart_tx           (mem_subsys_uart_tx),
        .debug_uart_tx_byte_valid(mem_subsys_debug_uart_tx_byte_valid),
        .debug_uart_tx_byte(mem_subsys_debug_uart_tx_byte),
        .debug_uart_status_load_count(mem_subsys_debug_uart_status_load_count),
        .debug_uart_tx_store_count(mem_subsys_debug_uart_tx_store_count),
`ifdef VERILATOR_FAST_UART
        .fast_uart_rx_byte_valid(fast_uart_rx_byte_valid),
        .fast_uart_rx_byte      (fast_uart_rx_byte),
`endif
        .debug_store_buffer_empty(lsu_debug_store_buffer_empty),
        .debug_store_buffer_count_t0(lsu_debug_store_buffer_count_t0),
        .debug_store_buffer_count_t1(lsu_debug_store_buffer_count_t1),
        .debug_ddr3_m0_bus (mem_subsys_debug_ddr3_m0_bus)

`ifdef ENABLE_DDR3
        ,
        // DDR3 external memory port
        .ddr3_req_valid    (ddr3_req_valid),
        .ddr3_req_ready    (ddr3_req_ready),
        .ddr3_req_addr     (ddr3_req_addr),
        .ddr3_req_write    (ddr3_req_write),
        .ddr3_req_wdata    (ddr3_req_wdata),
        .ddr3_req_wen      (ddr3_req_wen),
        .ddr3_resp_valid   (ddr3_resp_valid),
        .ddr3_resp_data    (ddr3_resp_data),
        .ddr3_init_calib_complete (ddr3_init_calib_complete)
`endif
    );
end else begin : gen_mem_subsys_tieoff
    assign m0_req_ready              = 1'b0;
    assign m0_resp_valid             = 1'b0;
    assign m0_resp_data              = 32'd0;
    assign m0_resp_last              = 1'b0;
    assign m1_req_ready              = 1'b0;
    assign m1_resp_valid             = 1'b0;
    assign m1_resp_data              = 32'd0;
    assign m2_req_ready              = 1'b0;
    assign m2_resp_valid             = 1'b0;
    assign m2_resp_data              = 32'd0;
    assign mem_subsys_tube_status    = 8'd0;
    assign mem_subsys_ext_timer_irq  = 1'b0;
    assign mem_subsys_ext_external_irq = 1'b0;
    assign mem_subsys_uart_tx        = 1'b1;
    assign mem_subsys_debug_uart_tx_byte_valid = 1'b0;
    assign mem_subsys_debug_uart_tx_byte = 8'd0;
    assign mem_subsys_debug_uart_status_load_count = 8'd0;
    assign mem_subsys_debug_uart_tx_store_count = 8'd0;
    assign mem_subsys_debug_ddr3_m0_bus = 128'd0;
end
endgenerate

assign ext_timer_irq    = use_mem_subsys ? mem_subsys_ext_timer_irq : 1'b0;
assign ext_external_irq = use_mem_subsys ? mem_subsys_ext_external_irq : 1'b0;
assign tube_status      = use_mem_subsys ? mem_subsys_tube_status : legacy_tube_status;
assign uart_tx          = use_mem_subsys ? mem_subsys_uart_tx : legacy_uart_tx;
assign debug_core_ready = rstn;
assign debug_core_clk = clk;
assign debug_retire_seen = retire_seen_r;
assign debug_uart_status_busy = use_mem_subsys ? 1'b0 : legacy_debug_uart_status_busy;
assign debug_uart_busy = use_mem_subsys ? 1'b0 : legacy_debug_uart_busy;
assign debug_uart_pending_valid = use_mem_subsys ? 1'b0 : legacy_debug_uart_pending_valid;
assign debug_uart_status_load_count = use_mem_subsys ? mem_subsys_debug_uart_status_load_count : legacy_debug_uart_status_load_count;
assign debug_uart_tx_store_count = use_mem_subsys ? mem_subsys_debug_uart_tx_store_count : legacy_debug_uart_tx_store_count;
assign debug_uart_tx_byte_valid = use_mem_subsys ? mem_subsys_debug_uart_tx_byte_valid : legacy_debug_uart_tx_byte_valid;
assign debug_uart_tx_byte = use_mem_subsys ? mem_subsys_debug_uart_tx_byte : legacy_debug_uart_tx_byte;

wire _unused_uart_rx = use_mem_subsys ? uart_rx : 1'b0;
assign debug_last_iss0_pc_lo = debug_last_iss0_pc_lo_r;
assign debug_last_iss1_pc_lo = debug_last_iss1_pc_lo_r;
assign debug_branch_pending_any = sb_branch_pending_any;
assign debug_br_found_t0 = sb_debug_br_found_t0;
assign debug_branch_in_flight_t0 = sb_debug_branch_in_flight_t0;
assign debug_oldest_br_ready_t0 = sb_debug_oldest_br_ready_t0;
assign debug_oldest_br_just_woke_t0 = sb_debug_oldest_br_just_woke_t0;
assign debug_oldest_br_qj_t0 = sb_debug_oldest_br_qj_t0;
assign debug_oldest_br_qk_t0 = sb_debug_oldest_br_qk_t0;
assign debug_slot1_flags = sb_debug_slot1_flags;
assign debug_slot1_pc_lo = sb_debug_slot1_pc_lo;
assign debug_slot1_qj = sb_debug_slot1_qj;
assign debug_slot1_qk = sb_debug_slot1_qk;
assign debug_tag2_flags = sb_debug_tag2_flags;
assign debug_reg_x12_tag_t0 = sb_debug_reg_x12_tag_t0;
assign debug_slot1_issue_flags = sb_debug_slot1_issue_flags;
assign debug_sel0_idx = sb_debug_sel0_idx;
assign debug_slot1_fu = sb_debug_slot1_fu;
assign debug_oldest_br_seq_lo_t0 = sb_debug_oldest_br_seq_lo_t0;
assign debug_rs_flags_flat = sb_debug_rs_flags_flat;
assign debug_rs_pc_lo_flat = sb_debug_rs_pc_lo_flat;
assign debug_rs_fu_flat = sb_debug_rs_fu_flat;
assign debug_rs_qj_flat = sb_debug_rs_qj_flat;
assign debug_rs_qk_flat = sb_debug_rs_qk_flat;
assign debug_rs_seq_lo_flat = sb_debug_rs_seq_lo_flat;
assign debug_spec_dispatch0 = sb_debug_spec_dispatch0;
assign debug_spec_dispatch1 = sb_debug_spec_dispatch1;
assign debug_branch_gated_mem_issue = sb_debug_branch_gated_mem_issue;
assign debug_flush_killed_speculative = sb_debug_flush_killed_speculative;
assign debug_commit_suppressed = rob_debug_commit_suppressed;
assign debug_spec_mmio_load_blocked = lsu_debug_spec_mmio_load_blocked;
assign debug_spec_mmio_load_violation = lsu_debug_spec_mmio_load_violation;
assign debug_mmio_load_at_rob_head = lsu_debug_mmio_load_at_rob_head;
assign debug_older_store_blocked_mmio_load = lsu_debug_older_store_blocked_mmio_load;
assign debug_branch_issue_count = debug_branch_issue_count_r;
assign debug_branch_complete_count = debug_branch_complete_count_r;
assign debug_ddr3_fetch_bus = {
    {mem_subsys_debug_uart_tx_byte, debug_uart_tx_start_count_r,
     mem_subsys_debug_uart_tx_store_count, mem_subsys_debug_uart_status_load_count},
    {16'd0, mem_subsys_debug_ddr3_m0_bus[127:112]},
    debug_m1_resp_count_r,
    debug_m1_req_count_r,
    debug_retire_count_r,
    debug_disp0_count_r,
    debug_dec0_count_r,
    debug_fb_pop_count_r,
    debug_if_valid_count_r,
    {retire_seen_r, fb_pop0_valid, dec0_valid, disp0_accepted,
     p0_pre_ro_valid, |rob_instr_retired, sb_disp_stall, stall},
    8'd0,
    debug_fetch_if_inst,
    debug_ic_state_flags,
    mem_subsys_debug_ddr3_m0_bus[103:96],
    debug_fetch_if_flags,
    debug_fetch_pc_out,
    debug_fetch_pc_pending,
    debug_ic_cpu_resp_count,
    debug_ic_mem_resp_count,
    debug_ic_mem_req_count,
    debug_ic_high_miss_count,
    mem_subsys_debug_ddr3_m0_bus[95:0]
};

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        retire_seen_r <= 1'b0;
    else if (|rob_instr_retired)
        retire_seen_r <= 1'b1;
end

endmodule
