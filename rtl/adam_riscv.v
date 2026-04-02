// =============================================================================
// Module : adam_riscv
// Description: Upgraded top-level processor integrating all new micro-architecture
//   modules from the 4-phase upgrade. This module preserves backward compatibility
//   with the existing adam_riscv.v module interface (sys_clk, sys_rstn, led) while
//   wiring the new internal pipeline.
//
//   New Pipeline:
//   IF → FetchBuffer → DualDecoder → Scoreboard → RO → BypassNet →
//   ExecPipe0 (INT+Branch) / ExecPipe1 (INT+MUL+AGU) → MEM → WB

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
    output wire [7:0] debug_branch_issue_count,
    output wire [7:0] debug_branch_complete_count
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

// The AX7203 top-level already applies a long power-on-reset window before the
// core is released. Keeping an additional `clk_locked` gate here has proven
// brittle in hardware builds because stale/mis-modeled clock-wizard lock
// behavior can collapse the whole core into permanent reset during synthesis.
// For FPGA_MODE bring-up we therefore rely on the board wrapper POR and only
// use the local synchronizer below to release reset cleanly into `clk`.
assign rstn_in = sys_rstn;

syn_rst u_syn_rst(
    .clock    (clk     ),
    .rstn     (rstn_in ),
    .syn_rstn (rstn    )
);

// Board bring-up does not need the full simulator-oriented OoO window sizes.
// Shrinking the FPGA profile keeps the smoke-test core behavior intact while
// materially reducing timing pressure on the AX7203 build.
`ifdef FPGA_MODE
localparam FETCH_BUFFER_DEPTH_CFG = 4;
localparam SCOREBOARD_RS_DEPTH_CFG = 4;
localparam SCOREBOARD_RS_IDX_W_CFG = 2;
`else
localparam FETCH_BUFFER_DEPTH_CFG = 16;
localparam SCOREBOARD_RS_DEPTH_CFG = 16;
localparam SCOREBOARD_RS_IDX_W_CFG = 4;
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
wire [15:0] pipe0_br_order_id;
wire       pipe0_br_complete;  // branch execution complete (taken or not)
reg        pipe0_br_complete_hold_r;
wire       scoreboard_br_complete;

// CSR from Pipe0
wire       pipe0_csr_valid;
wire [31:0] pipe0_csr_wdata;
wire [2:0] pipe0_csr_op;
wire [11:0] pipe0_csr_addr_unused;
wire       pipe0_mret_valid;

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
wire rob_disp_stall;
wire stall;
assign stall       = sb_disp_stall || rob_disp_stall;

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
reg [15:0] order_id_t0, order_id_t1;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        epoch_t0   <= 8'd0;
        epoch_t1   <= 8'd0;
    end else begin
        // Increment epoch on flush
        if (pipe0_br_ctrl) begin
            if (pipe0_br_tid == 1'b0)
                epoch_t0 <= epoch_t0 + 8'd1;
            else
                epoch_t1 <= epoch_t1 + 8'd1;
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
wire [15:0] rob_commit0_order_id, rob_commit1_order_id;
wire        rob_commit0_is_store, rob_commit1_is_store;
wire [1:0]  rob_instr_retired;
wire [4:0]  sb_disp0_tag, sb_disp1_tag;
wire        iss0_is_rocc;
reg         retire_seen_r;

// ════════════════════════════════════════════════════════════════════════════
// STAGE 1: Instruction Fetch (stage_if with BPU)
// ════════════════════════════════════════════════════════════════════════════
wire        if_valid;
wire [31:0] if_inst;
wire [31:0] if_pc;
wire [0:0]  if_tid;
wire        if_pred_taken;

// Fetch buffer backpressure
wire fb_push_ready;

// ════════════════════════════════════════════════════════════════════════════
// Trap Redirect Mux: Prioritize trap entry > MRET > Branch > Normal flow
// ════════════════════════════════════════════════════════════════════════════
wire        trap_redirect_valid = trap_enter || trap_return;
wire [31:0] trap_redirect_pc    = trap_enter ? trap_target : 
                                   trap_return ? mepc_out : 32'd0;
wire [0:0]  trap_redirect_tid   = 1'b0;  // M-mode only, single context

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
    .bpu_update_valid (pipe0_br_ctrl    ),
    .bpu_update_pc    (pipe0_br_addr    ),  // simplified
    .bpu_update_tid   (pipe0_br_tid     ),
    .bpu_update_taken (pipe0_br_ctrl    ),
    .bpu_update_target(pipe0_br_addr    ),
    .fetch_tid        (fetch_tid        ),
    .fb_ready         (fb_push_ready    ),
    .if_valid         (if_valid         ),
    .if_inst          (if_inst          ),
    .if_pc            (if_pc            ),
    .if_tid           (if_tid           ),
    .if_pred_taken    (if_pred_taken    ),

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
    .use_external_refill(use_mem_subsys)
);

// ════════════════════════════════════════════════════════════════════════════
// STAGE 2: Fetch Buffer (4-entry FIFO)
// ════════════════════════════════════════════════════════════════════════════
wire        fb_pop0_valid, fb_pop1_valid;
wire [31:0] fb_pop0_inst,  fb_pop1_inst;
wire [31:0] fb_pop0_pc,    fb_pop1_pc;
wire [0:0]  fb_pop0_tid,   fb_pop1_tid;
wire        fb_consume_0,  fb_consume_1;

fetch_buffer #(.DEPTH(FETCH_BUFFER_DEPTH_CFG)) u_fetch_buffer(
    .clk        (clk            ),
    .rstn       (rstn           ),
    .flush      (combined_flush ),
    .push_valid (if_valid       ),
    .push_inst  (if_inst        ),
    .push_pc    (if_pc          ),
    .push_tid   (if_tid         ),
    .push_ready (fb_push_ready  ),
    .pop0_valid (fb_pop0_valid  ),
    .pop0_inst  (fb_pop0_inst   ),
    .pop0_pc    (fb_pop0_pc     ),
    .pop0_tid   (fb_pop0_tid    ),
    .pop1_valid (fb_pop1_valid  ),
    .pop1_inst  (fb_pop1_inst   ),
    .pop1_pc    (fb_pop1_pc     ),
    .pop1_tid   (fb_pop1_tid    ),
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
    .consume_1       (fb_consume_1    )
);

// Squash dispatches if flush active
wire disp0_valid_pre_rob = dec0_valid && !smt_flush[dec0_tid];
wire disp1_valid_pre_rob = dec1_valid && !smt_flush[dec1_tid];
assign rob_disp_stall = (disp0_valid_pre_rob && rob0_full) ||
                        (disp1_valid_pre_rob && rob1_full);
wire disp0_valid_gated = disp0_valid_pre_rob && !rob_disp_stall;
wire disp1_valid_gated = disp1_valid_pre_rob && !rob_disp_stall;

// Order ID and epoch assignments for dispatch ports (using decoder tid)
// disp0 gets current order_id for its thread
wire [15:0] disp0_order_id = (dec0_tid == 1'b0) ? order_id_t0 : order_id_t1;
// disp1 gets current+1 if same thread as disp0, otherwise current for its thread
wire [15:0] disp1_order_id = (dec1_tid == 1'b0) ? 
    ((dec0_tid == 1'b0 && disp0_accepted) ? order_id_t0 + 16'd1 : order_id_t0) :
    ((dec0_tid == 1'b1 && disp0_accepted) ? order_id_t1 + 16'd1 : order_id_t1);
wire [7:0] disp0_epoch = (dec0_tid == 1'b0) ? epoch_t0 : epoch_t1;
wire [7:0] disp1_epoch = (dec1_tid == 1'b0) ? epoch_t0 : epoch_t1;

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

// Issue port 1 wires
wire        iss1_valid;
wire [4:0]  iss1_tag;
wire [31:0] iss1_pc, iss1_imm;
wire [2:0]  iss1_func3;
wire        iss1_func7;
wire [4:0]  iss1_rd, iss1_rs1, iss1_rs2;
wire        iss1_rs1_used, iss1_rs2_used;
wire [4:0]  iss1_src1_tag, iss1_src2_tag;
wire        iss1_br, iss1_mem_read, iss1_mem2reg;
wire [2:0]  iss1_alu_op;
wire        iss1_mem_write;
wire [1:0]  iss1_alu_src1, iss1_alu_src2;
wire        iss1_br_addr_mode, iss1_regs_write;
wire [2:0]  iss1_fu;
wire [0:0]  iss1_tid;
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

// Issue metadata wires
wire [`METADATA_ORDER_ID_W-1:0] iss0_order_id;
wire [`METADATA_EPOCH_W-1:0]    iss0_epoch;
wire [`METADATA_ORDER_ID_W-1:0] iss1_order_id;
wire [`METADATA_EPOCH_W-1:0]    iss1_epoch;

// Writeback port wires (from pipes)
wire        wb0_valid, wb1_valid;
wire [4:0]  wb0_tag,   wb1_tag;
wire [4:0]  wb0_rd,    wb1_rd;
wire        wb0_regs_write, wb1_regs_write;
wire [2:0]  wb0_fu,    wb1_fu;
wire [0:0]  wb0_tid,   wb1_tid;

scoreboard #(
    .RS_DEPTH(SCOREBOARD_RS_DEPTH_CFG),
    .RS_IDX_W(SCOREBOARD_RS_IDX_W_CFG),
    .RS_TAG_W(5)
) u_scoreboard (
    .clk         (clk              ),
    .rstn        (rstn             ),
    .flush       (combined_flush_any ),
    .flush_tid   (trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid ),
    .flush_order_valid(!trap_redirect_valid && pipe0_br_ctrl),
    .flush_order_id(pipe0_br_order_id),

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

    .disp_stall  (sb_disp_stall    ),

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

    // Issue port 1
    .iss1_valid        (iss1_valid        ),
    .iss1_tag          (iss1_tag          ),
    .iss1_pc           (iss1_pc           ),
    .iss1_imm          (iss1_imm          ),
    .iss1_func3        (iss1_func3        ),
    .iss1_func7        (iss1_func7        ),
    .iss1_rd           (iss1_rd           ),
    .iss1_rs1          (iss1_rs1          ),
    .iss1_rs2          (iss1_rs2          ),
    .iss1_rs1_used     (iss1_rs1_used     ),
    .iss1_rs2_used     (iss1_rs2_used     ),
    .iss1_src1_tag     (iss1_src1_tag     ),
    .iss1_src2_tag     (iss1_src2_tag     ),
    .iss1_br           (iss1_br           ),
    .iss1_mem_read     (iss1_mem_read     ),
    .iss1_mem2reg      (iss1_mem2reg      ),
    .iss1_alu_op       (iss1_alu_op       ),
    .iss1_mem_write    (iss1_mem_write    ),
    .iss1_alu_src1     (iss1_alu_src1     ),
    .iss1_alu_src2     (iss1_alu_src2     ),
    .iss1_br_addr_mode (iss1_br_addr_mode ),
    .iss1_regs_write   (iss1_regs_write   ),
    .iss1_fu           (iss1_fu           ),
    .iss1_tid          (iss1_tid          ),
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
    .iss1_order_id     (iss1_order_id     ),
    .iss1_epoch        (iss1_epoch        ),

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
integer    sys_meta_idx;

// Per-tag RoCC metadata (decoder → scoreboard issue sideband)
reg        rs_is_rocc    [0:31];
reg [6:0]  rs_rocc_funct7[0:31];
integer    rocc_meta_idx;

rob_lite #(
    .ROB_DEPTH      (8),
    .ROB_IDX_W      (3),
    .RS_TAG_W       (5),
    .NUM_THREAD     (2)
) u_rob_lite (
    .clk                (clk),
    .rstn               (rstn),

    // Flush interface
    .flush              (combined_flush_any),
    .flush_tid          (trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid),
    .flush_new_epoch    ((trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid) ? flush_new_epoch_t1 : flush_new_epoch_t0),
    .flush_order_valid  (!trap_redirect_valid && pipe0_br_ctrl),
    .flush_order_id     (pipe0_br_order_id),

    // Dispatch Port 0
    .disp0_valid        (disp0_accepted),
    .disp0_tag          (sb_disp0_tag),
    .disp0_tid          (dec0_tid),
    .disp0_order_id     (disp0_order_id),
    .disp0_epoch        (disp0_epoch),
    .disp0_rd           (dec0_rd),
    .disp0_is_store     (disp0_is_store),
    .rob0_full          (rob0_full),

    // Dispatch Port 1
    .disp1_valid        (disp1_accepted),
    .disp1_tag          (sb_disp1_tag),
    .disp1_tid          (dec1_tid),
    .disp1_order_id     (disp1_order_id),
    .disp1_epoch        (disp1_epoch),
    .disp1_rd           (dec1_rd),
    .disp1_is_store     (disp1_is_store),
    .rob1_full          (rob1_full),

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
    .commit1_is_store   (rob_commit1_is_store)
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
    .r_thread_id    (iss1_tid        ),
    .r_regs_addr1   (iss1_rs1        ),
    .r_regs_addr2   (iss1_rs2        ),
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

// Order ID increment logic (after scoreboard is defined)
// Dispatch is accepted when valid is asserted and stall is not asserted
wire disp0_accepted = disp0_valid_gated && !sb_disp_stall;
wire disp1_accepted = disp1_valid_gated && !sb_disp_stall;

// Best-effort trap resume PC for interrupt entry.
// Prefer the oldest visible in-flight PC, and avoid overwriting it with
// speculative control-flow fall-through PCs from decode/fetch.
reg [31:0] trap_pc_r;
wire trap_pc_speculative = sb_branch_pending_any || pipe0_br_ctrl || pipe0_br_complete;
wire trap_pc_fetch_safe = !trap_pc_speculative && !dec0_br && !dec1_br;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        trap_pc_r <= 32'd0;
    end else if (iss0_valid && !iss0_br && !trap_pc_speculative) begin
        trap_pc_r <= iss0_pc;
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
            rs_is_rocc[sb_disp0_tag]     <= dec0_is_rocc;
            rs_rocc_funct7[sb_disp0_tag] <= dec0_rocc_funct7;
        end
        if (disp1_accepted) begin
            rs_is_csr[sb_disp1_tag]   <= dec1_is_csr;
            rs_is_mret[sb_disp1_tag]  <= dec1_is_mret;
            rs_csr_addr[sb_disp1_tag] <= dec1_csr_addr;
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
wire        iss0_is_csr  = iss0_tag_hits_disp0 ? dec0_is_csr  :
                           iss0_tag_hits_disp1 ? dec1_is_csr  : rs_is_csr[iss0_tag];
wire        iss0_is_mret = iss0_tag_hits_disp0 ? dec0_is_mret :
                           iss0_tag_hits_disp1 ? dec1_is_mret : rs_is_mret[iss0_tag];
wire [11:0] iss0_csr_addr = iss0_tag_hits_disp0 ? dec0_csr_addr :
                            iss0_tag_hits_disp1 ? dec1_csr_addr : rs_csr_addr[iss0_tag];

// Issue-time RoCC metadata reconstructed from the dispatched tag (same bypass pattern)
assign iss0_is_rocc          = iss0_tag_hits_disp0 ? dec0_is_rocc :
                               iss0_tag_hits_disp1 ? dec1_is_rocc : rs_is_rocc[iss0_tag];
wire [6:0]  iss0_rocc_funct7 = iss0_tag_hits_disp0 ? dec0_rocc_funct7 :
                               iss0_tag_hits_disp1 ? dec1_rocc_funct7 : rs_rocc_funct7[iss0_tag];

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        order_id_t0 <= 16'd0;
        order_id_t1 <= 16'd0;
    end else begin
        // Increment order_id on dispatch accept per thread
        // When dual-dispatch to same thread, increment by 2; otherwise by 1
        
        // Thread 0: count accepts from disp0 and disp1
        if ((disp0_accepted && dec0_tid == 1'b0) && (disp1_accepted && dec1_tid == 1'b0))
            order_id_t0 <= order_id_t0 + 16'd2;  // Dual-dispatch to T0
        else if ((disp0_accepted && dec0_tid == 1'b0) || (disp1_accepted && dec1_tid == 1'b0))
            order_id_t0 <= order_id_t0 + 16'd1;  // Single dispatch to T0
            
        // Thread 1: count accepts from disp0 and disp1
        if ((disp0_accepted && dec0_tid == 1'b1) && (disp1_accepted && dec1_tid == 1'b1))
            order_id_t1 <= order_id_t1 + 16'd2;  // Dual-dispatch to T1
        else if ((disp0_accepted && dec0_tid == 1'b1) || (disp1_accepted && dec1_tid == 1'b1))
            order_id_t1 <= order_id_t1 + 16'd1;  // Single dispatch to T1
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
    .ro_rs1_addr     (iss0_rs1       ),
    .ro_rs2_addr     (iss0_rs2       ),
    .ro_rs1_regdata  (ro0_data1      ),
    .ro_rs2_regdata  (ro0_data2      ),
    .ro_tid          (iss0_tid       ),
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
    .ro_rs1_addr     (iss1_rs1       ),
    .ro_rs2_addr     (iss1_rs2       ),
    .ro_rs1_regdata  (ro1_data1      ),
    .ro_rs2_regdata  (ro1_data2      ),
    .ro_tid          (iss1_tid       ),
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
    assign rocc_cmd_valid    = iss0_valid && iss0_is_rocc && rocc_cmd_ready;
    assign rocc_cmd_funct7   = iss0_rocc_funct7;
    assign rocc_cmd_funct3   = iss0_func3;
    assign rocc_cmd_rd       = iss0_rd;
    assign rocc_cmd_rs1_data = byp0_op_a;  // RS1 data from bypass network
    assign rocc_cmd_rs2_data = byp0_op_b;  // RS2 data from bypass network
    assign rocc_cmd_tag      = iss0_tag;
    assign rocc_cmd_tid      = iss0_tid;

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
            rocc_cmd_epoch[rocc_cmd_tag] <= iss0_epoch;
            rocc_cmd_tid_per_tag[rocc_cmd_tag] <= iss0_tid;
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
// When iss0_is_rocc, don't send to exec_pipe0 (RoCC bypasses it)
wire iss0_to_pipe0_valid = iss0_valid && !iss0_is_rocc;

exec_pipe0 #(.TAG_W(5)) u_exec_pipe0(
    .clk              (clk              ),
    .rstn             (rstn             ),
    .in_valid         (iss0_to_pipe0_valid),
    .in_tag           (iss0_tag         ),
    .in_pc            (iss0_pc          ),
    .in_op_a          (byp0_op_a        ),
    .in_op_b          (byp0_op_b        ),
    .in_rs1_idx       (iss0_rs1         ),
    .in_imm           (iss0_imm         ),
    .in_order_id      (iss0_order_id    ),
    .in_func3         (iss0_func3       ),
    .in_func7         (iss0_func7       ),
    .in_alu_op        (iss0_alu_op      ),
    .in_alu_src1      (iss0_alu_src1    ),
    .in_alu_src2      (iss0_alu_src2    ),
    .in_br_addr_mode  (iss0_br_addr_mode),
    .in_br            (iss0_br          ),
    .in_rd            (iss0_rd          ),
    .in_regs_write    (iss0_regs_write  ),
    .in_fu            (iss0_fu          ),
    .in_tid           (iss0_tid         ),
    .in_is_csr        (iss0_is_csr      ),
    .in_is_mret       (iss0_is_mret     ),
    .in_csr_addr      (iss0_csr_addr    ),
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
    .br_ctrl          (pipe0_br_ctrl    ),
    .br_addr          (pipe0_br_addr    ),
    .br_tid           (pipe0_br_tid     ),
    .br_order_id      (pipe0_br_order_id),
    .br_complete      (pipe0_br_complete)
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
wire [15:0] p1_mem_req_order_id;
wire [7:0]  p1_mem_req_epoch;

wire        p1_mul_valid;
wire [4:0]  p1_mul_tag;
wire [31:0] p1_mul_result;
wire [4:0]  p1_mul_rd;
wire        p1_mul_regs_write;
wire [2:0]  p1_mul_fu;
wire [0:0]  p1_mul_tid;

exec_pipe1 #(.TAG_W(5)) u_exec_pipe1(
    .clk           (clk              ),
    .rstn          (rstn             ),
    .in_valid      (iss1_valid       ),
    .in_tag        (iss1_tag         ),
    .in_pc         (iss1_pc          ),
    .in_op_a       (byp1_op_a        ),
    .in_op_b       (byp1_op_b        ),
    .in_imm        (iss1_imm         ),
    .in_func3      (iss1_func3       ),
    .in_func7      (iss1_func7       ),
    .in_alu_op     (iss1_alu_op      ),
    .in_alu_src1   (iss1_alu_src1    ),
    .in_alu_src2   (iss1_alu_src2    ),
    .in_br         (iss1_br          ),
    .in_mem_read   (iss1_mem_read    ),
    .in_mem_write  (iss1_mem_write   ),
    .in_mem2reg    (iss1_mem2reg     ),
    .in_rd         (iss1_rd          ),
    .in_regs_write (iss1_regs_write  ),
    .in_fu         (iss1_fu          ),
    .in_tid        (iss1_tid         ),
    .in_order_id   (iss1_order_id    ),
    .in_epoch      (iss1_epoch       ),
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
    .mul_out_tid        (p1_mul_tid           )
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

wire [31:0] lsu_mem_addr;
wire [3:0]  lsu_mem_read;
wire [31:0] lsu_mem_rdata;

wire        sb_mem_write_valid;
wire [31:0] sb_mem_write_addr;
wire [31:0] sb_mem_write_data;
wire [3:0]  sb_mem_write_wen;
wire        sb_mem_write_ready;
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
    .ORDER_ID_W   (16),
    .EPOCH_W      (8)
) u_lsu_shell (
    .clk                (clk),
    .rstn               (rstn),

    // Flush interface
    .flush              (combined_flush_any ),
    .flush_tid          (trap_redirect_valid ? trap_redirect_tid : pipe0_br_tid ),
    .flush_new_epoch_t0 (flush_new_epoch_t0   ),
    .flush_new_epoch_t1 (flush_new_epoch_t1   ),
    .flush_order_valid  (!trap_redirect_valid && pipe0_br_ctrl),
    .flush_order_id     (pipe0_br_order_id    ),

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

    // Load hazard output
    .load_hazard        (lsu_load_hazard      ),

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

// ─── WB Port 1: from MEM or MUL (whichever is valid) ──────────────────────
// MUL takes priority if both valid simultaneously (edge case)
wire wb1_from_mul = p1_mul_valid;
wire wb1_from_mem = lsu_resp_valid && !p1_mul_valid;
wire wb1_from_alu = p1_alu_valid && !p1_mul_valid && !lsu_resp_valid;

assign wb1_valid      = wb1_from_mul || wb1_from_mem || wb1_from_alu;
assign wb1_tag        = wb1_from_mul ? p1_mul_tag  :
                        wb1_from_mem ? lsu_resp_tag :
                        wb1_from_alu ? p1_alu_tag  : 5'd0;
assign wb1_rd         = wb1_from_mul ? p1_mul_rd  :
                        wb1_from_mem ? lsu_resp_rd :
                        wb1_from_alu ? p1_alu_rd  : 5'd0;
assign wb1_regs_write = wb1_from_mul ? p1_mul_regs_write :
                        wb1_from_mem ? lsu_resp_regs_write :
                        wb1_from_alu ? p1_alu_rd_wen : 1'b0;
assign wb1_fu         = wb1_from_mul ? p1_mul_fu  :
                        wb1_from_mem ? lsu_resp_fu :
                        wb1_from_alu ? p1_alu_fu  : 3'd0;
assign wb1_tid        = wb1_from_mul ? p1_mul_tid  :
                        wb1_from_mem ? lsu_resp_tid :
                        wb1_from_alu ? p1_alu_tid  : 1'b0;

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

// WB data sources for result buffer
wire [31:0] wb0_result_data = wb0_from_rocc ? rocc_resp_data : p0_ex_result;
wire [31:0] wb1_result_data = wb1_from_mul ? p1_mul_result :
                              wb1_from_mem ? mem_wb_data_sel :
                              wb1_from_alu ? p1_alu_result : 32'd0;

// Write to result buffer on WB (capture completion data)
integer i;
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (i = 0; i < 32; i = i + 1) begin
            result_buffer[i] <= 32'd0;
            result_valid[i]  <= 1'b0;
        end
        debug_last_iss0_pc_lo_r <= 8'd0;
        debug_last_iss1_pc_lo_r <= 8'd0;
        debug_branch_issue_count_r <= 8'd0;
        debug_branch_complete_count_r <= 8'd0;
    end else begin
        if (iss0_valid)
            debug_last_iss0_pc_lo_r <= iss0_pc[7:0];
        if (iss1_valid)
            debug_last_iss1_pc_lo_r <= iss1_pc[7:0];
        if (iss0_valid && iss0_br)
            debug_branch_issue_count_r <= debug_branch_issue_count_r + 8'd1;
        if (pipe0_br_complete)
            debug_branch_complete_count_r <= debug_branch_complete_count_r + 8'd1;

        // Tags are recycled with RS entry reuse, so clear any stale buffered
        // result as soon as a fresh instruction claims the tag.
        if (disp0_accepted && (sb_disp0_tag != 5'd0))
            result_valid[sb_disp0_tag] <= 1'b0;
        if (disp1_accepted && (sb_disp1_tag != 5'd0))
            result_valid[sb_disp1_tag] <= 1'b0;

        // Write WB0 result (highest priority if same tag)
        if (wb0_valid && wb0_regs_write) begin
            result_buffer[wb0_tag] <= wb0_result_data;
            result_valid[wb0_tag]  <= 1'b1;
        end

        // Write WB1 result
        if (wb1_valid && wb1_regs_write) begin
            result_buffer[wb1_tag] <= wb1_result_data;
            result_valid[wb1_tag]  <= 1'b1;
        end

        if (rob_commit0_valid && rob_commit0_has_result && (rob_commit0_tag != 5'd0))
            result_valid[rob_commit0_tag] <= 1'b0;
        if (rob_commit1_valid && rob_commit1_has_result && (rob_commit1_tag != 5'd0))
            result_valid[rob_commit1_tag] <= 1'b0;
    end
end

assign p0_tagbuf_a_valid = (iss0_src1_tag != 5'd0) && result_valid[iss0_src1_tag];
assign p0_tagbuf_a_data  = result_buffer[iss0_src1_tag];
assign p0_tagbuf_b_valid = (iss0_src2_tag != 5'd0) && result_valid[iss0_src2_tag];
assign p0_tagbuf_b_data  = result_buffer[iss0_src2_tag];
assign p1_tagbuf_a_valid = (iss1_src1_tag != 5'd0) && result_valid[iss1_src1_tag];
assign p1_tagbuf_a_data  = result_buffer[iss1_src1_tag];
assign p1_tagbuf_b_valid = (iss1_src2_tag != 5'd0) && result_valid[iss1_src2_tag];
assign p1_tagbuf_b_data  = result_buffer[iss1_src2_tag];

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
    .csr_addr        (iss0_csr_addr     ),
    .csr_op          (pipe0_csr_op      ),
    .csr_wdata       (pipe0_csr_wdata   ),
    .csr_rdata       (csr_rdata         ),
    .exc_valid       (1'b0              ),
    .exc_cause       (32'd0             ),
    .exc_pc          (trap_pc_r         ),
    .exc_tval        (32'd0             ),
    .mret_valid      (pipe0_mret_valid  ),
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
        .ext_external_irq  (mem_subsys_ext_external_irq)
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
end
endgenerate

assign ext_timer_irq    = use_mem_subsys ? mem_subsys_ext_timer_irq : 1'b0;
assign ext_external_irq = use_mem_subsys ? mem_subsys_ext_external_irq : 1'b0;
assign tube_status      = use_mem_subsys ? mem_subsys_tube_status : legacy_tube_status;
assign uart_tx          = use_mem_subsys ? 1'b1 : legacy_uart_tx;
assign debug_core_ready = rstn;
assign debug_core_clk = clk;
assign debug_retire_seen = retire_seen_r;
assign debug_uart_status_busy = use_mem_subsys ? 1'b0 : legacy_debug_uart_status_busy;
assign debug_uart_busy = use_mem_subsys ? 1'b0 : legacy_debug_uart_busy;
assign debug_uart_pending_valid = use_mem_subsys ? 1'b0 : legacy_debug_uart_pending_valid;
assign debug_uart_status_load_count = use_mem_subsys ? 8'd0 : legacy_debug_uart_status_load_count;
assign debug_uart_tx_store_count = use_mem_subsys ? 8'd0 : legacy_debug_uart_tx_store_count;
assign debug_uart_tx_byte_valid = use_mem_subsys ? 1'b0 : legacy_debug_uart_tx_byte_valid;
assign debug_uart_tx_byte = use_mem_subsys ? 8'd0 : legacy_debug_uart_tx_byte;
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
assign debug_branch_issue_count = debug_branch_issue_count_r;
assign debug_branch_complete_count = debug_branch_complete_count_r;

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        retire_seen_r <= 1'b0;
    else if (|rob_instr_retired)
        retire_seen_r <= 1'b1;
end

endmodule
