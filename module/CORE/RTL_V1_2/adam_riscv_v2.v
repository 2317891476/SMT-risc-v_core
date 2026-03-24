// =============================================================================
// Module : adam_riscv_v2
// Description: Upgraded top-level processor integrating all new micro-architecture
//   modules from the 4-phase upgrade. This module preserves backward compatibility
//   with the existing adam_riscv.v module interface (sys_clk, sys_rstn, led) while
//   wiring the new internal pipeline.
//
//   New Pipeline:
//   IF_v2 → FetchBuffer → DualDecoder → Scoreboard_v2 → RO → BypassNet →
//   ExecPipe0 (INT+Branch) / ExecPipe1 (INT+MUL+AGU) → MEM → WB
//
//   Additional subsystems:
//   - BPU (bimodal branch predictor in stage_if_v2)
//   - CSR Unit (Machine-mode CSRs + exception handling)
//   - MMU (Sv32, currently in bare mode for simulation)
//   - L1 DCache (non-blocking, currently bypassed for sim with direct SRAM)
//   - RoCC AI Accelerator (stub connected, not activated in basic tests)
// =============================================================================

module adam_riscv_v2(
    input wire sys_clk,
`ifdef FPGA_MODE
    output wire[2:0] led,
`endif
    input wire sys_rstn
);

// SMT mode parameter (0=single-thread, 1=SMT)
// Can be overridden at instantiation time
`ifndef SMT_MODE
    `define SMT_MODE 0
`endif
wire smt_mode = `SMT_MODE;

// ─── Clock / Reset ───────────────────────────────────────────────────────────
wire rstn;
wire clk;

`ifdef FPGA_MODE
    clk_wiz_0 clk2cpu(.clk_out1(clk), .clk_in1(sys_clk));
`else
    assign clk = sys_clk;
`endif

syn_rst u_syn_rst(
    .clock    (clk     ),
    .rstn     (sys_rstn),
    .syn_rstn (rstn    )
);

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
wire       pipe0_br_complete;  // branch execution complete (taken or not)

assign smt_flush[0] = pipe0_br_ctrl && (pipe0_br_tid == 1'b0);
assign smt_flush[1] = pipe0_br_ctrl && (pipe0_br_tid == 1'b1);
assign flush_any    = pipe0_br_ctrl;

// Stall from scoreboard
wire sb_disp_stall;
wire stall;
assign stall       = sb_disp_stall;
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
// STAGE 1: Instruction Fetch (stage_if_v2 with BPU)
// ════════════════════════════════════════════════════════════════════════════
wire        if_valid;
wire [31:0] if_inst;
wire [31:0] if_pc;
wire [0:0]  if_tid;
wire        if_pred_taken;

// Fetch buffer backpressure
wire fb_push_ready;

stage_if_v2 u_stage_if_v2(
    .clk              (clk              ),
    .rstn             (rstn             ),
    .pc_stall         (stall            ),
    .if_flush         (smt_flush        ),
    .br_addr_t0       (pipe0_br_ctrl && (pipe0_br_tid==1'b0) ? pipe0_br_addr : 32'd0),
    .br_addr_t1       (pipe0_br_ctrl && (pipe0_br_tid==1'b1) ? pipe0_br_addr : 32'd0),
    .br_ctrl          ({pipe0_br_ctrl && (pipe0_br_tid==1'b1),
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
    .if_pred_taken    (if_pred_taken    )
);

// ════════════════════════════════════════════════════════════════════════════
// STAGE 2: Fetch Buffer (4-entry FIFO)
// ════════════════════════════════════════════════════════════════════════════
wire        fb_pop0_valid, fb_pop1_valid;
wire [31:0] fb_pop0_inst,  fb_pop1_inst;
wire [31:0] fb_pop0_pc,    fb_pop1_pc;
wire [0:0]  fb_pop0_tid,   fb_pop1_tid;
wire        fb_consume_0,  fb_consume_1;

fetch_buffer #(.DEPTH(4)) u_fetch_buffer(
    .clk        (clk            ),
    .rstn       (rstn           ),
    .flush      (smt_flush      ),
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

decoder_dual u_decoder_dual(
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
    .consume_0       (fb_consume_0     ),
    .consume_1       (fb_consume_1     )
);

// Squash dispatches if flush active
wire disp0_valid_gated = dec0_valid && !smt_flush[dec0_tid];
wire disp1_valid_gated = dec1_valid && !smt_flush[dec1_tid];

// ════════════════════════════════════════════════════════════════════════════
// STAGE 4: Scoreboard V2 (16-entry RS, Dual-Issue)
// ════════════════════════════════════════════════════════════════════════════
// Issue port 0 wires
wire        iss0_valid;
wire [4:0]  iss0_tag;
wire [31:0] iss0_pc, iss0_imm;
wire [2:0]  iss0_func3;
wire        iss0_func7;
wire [4:0]  iss0_rd, iss0_rs1, iss0_rs2;
wire        iss0_rs1_used, iss0_rs2_used;
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
wire        iss1_br, iss1_mem_read, iss1_mem2reg;
wire [2:0]  iss1_alu_op;
wire        iss1_mem_write;
wire [1:0]  iss1_alu_src1, iss1_alu_src2;
wire        iss1_br_addr_mode, iss1_regs_write;
wire [2:0]  iss1_fu;
wire [0:0]  iss1_tid;

// Writeback port wires (from pipes)
wire        wb0_valid, wb1_valid;
wire [4:0]  wb0_tag,   wb1_tag;
wire [4:0]  wb0_rd,    wb1_rd;
wire        wb0_regs_write, wb1_regs_write;
wire [2:0]  wb0_fu,    wb1_fu;
wire [0:0]  wb0_tid,   wb1_tid;

scoreboard_v2 #(
    .RS_DEPTH(16), .RS_IDX_W(4), .RS_TAG_W(5)
) u_scoreboard_v2 (
    .clk         (clk              ),
    .rstn        (rstn             ),
    .flush       (flush_any        ),
    .flush_tid   (pipe0_br_tid     ),

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

    .disp_stall  (sb_disp_stall    ),

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

    // Branch completion
    .br_complete     (pipe0_br_complete)
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

bypass_network u_bypass0(
    .ro_rs1_addr     (iss0_rs1       ),
    .ro_rs2_addr     (iss0_rs2       ),
    .ro_rs1_regdata  (ro0_data1      ),
    .ro_rs2_regdata  (ro0_data2      ),
    .ro_tid          (iss0_tid       ),
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

bypass_network u_bypass1(
    .ro_rs1_addr     (iss1_rs1       ),
    .ro_rs2_addr     (iss1_rs2       ),
    .ro_rs1_regdata  (ro1_data1      ),
    .ro_rs2_regdata  (ro1_data2      ),
    .ro_tid          (iss1_tid       ),
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

// ─── Execution Pipe 0 (INT + Branch) ───────────────────────────────────────
exec_pipe0 #(.TAG_W(5)) u_exec_pipe0(
    .clk              (clk              ),
    .rstn             (rstn             ),
    .in_valid         (iss0_valid       ),
    .in_tag           (iss0_tag         ),
    .in_pc            (iss0_pc          ),
    .in_op_a          (byp0_op_a        ),
    .in_op_b          (byp0_op_b        ),
    .in_imm           (iss0_imm         ),
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
    .out_valid        (p0_ex_valid      ),
    .out_tag          (p0_ex_tag        ),
    .out_result       (p0_ex_result     ),
    .out_rd           (p0_ex_rd         ),
    .out_regs_write   (p0_ex_rd_wen     ),
    .out_fu           (p0_ex_fu         ),
    .out_tid          (p0_ex_tid        ),
    .br_ctrl          (pipe0_br_ctrl    ),
    .br_addr          (pipe0_br_addr    ),
    .br_tid           (pipe0_br_tid     ),
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
    .alu_out_valid      (p1_alu_valid     ),
    .alu_out_tag        (p1_alu_tag       ),
    .alu_out_result     (p1_alu_result    ),
    .alu_out_rd         (p1_alu_rd        ),
    .alu_out_regs_write (p1_alu_rd_wen    ),
    .alu_out_fu         (p1_alu_fu        ),
    .alu_out_tid        (p1_alu_tid       ),
    .mem_req_valid      (p1_mem_req_valid     ),
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
    .mul_out_valid      (p1_mul_valid         ),
    .mul_out_tag        (p1_mul_tag           ),
    .mul_out_result     (p1_mul_result        ),
    .mul_out_rd         (p1_mul_rd            ),
    .mul_out_regs_write (p1_mul_regs_write    ),
    .mul_out_fu         (p1_mul_fu            ),
    .mul_out_tid        (p1_mul_tid           )
);

// ════════════════════════════════════════════════════════════════════════════
// STAGE 7: Memory Stage (using existing data_memory / stage_mem for simulation)
// ════════════════════════════════════════════════════════════════════════════
wire [31:0] mem_rdata;
wire        forward_data_dummy = 1'b0;

`ifdef FPGA_MODE
stage_mem u_stage_mem(
    .clk           (clk                ),
    .rstn          (rstn               ),
    .me_regs_data2 (p1_mem_req_wdata   ),
    .me_alu_o      (p1_mem_req_addr    ),
    .me_mem_read   (!p1_mem_req_wen && p1_mem_req_valid),
    .me_mem_write  (p1_mem_req_wen  && p1_mem_req_valid),
    .me_func3_code (p1_mem_req_func3   ),
    .forward_data  (forward_data_dummy ),
    .w_regs_data   (32'd0             ),
    .me_led        (led                ),
    .me_mem_data   (mem_rdata          )
);
`else
stage_mem u_stage_mem(
    .clk           (clk                ),
    .rstn          (rstn               ),
    .me_regs_data2 (p1_mem_req_wdata   ),
    .me_alu_o      (p1_mem_req_addr    ),
    .me_mem_read   (!p1_mem_req_wen && p1_mem_req_valid),
    .me_mem_write  (p1_mem_req_wen  && p1_mem_req_valid),
    .me_func3_code (p1_mem_req_func3   ),
    .forward_data  (forward_data_dummy ),
    .w_regs_data   (32'd0             ),
    .me_mem_data   (mem_rdata          )
);
`endif

// ════════════════════════════════════════════════════════════════════════════
// STAGE 8: Write-Back (select between ALU result and MEM load data)
// ════════════════════════════════════════════════════════════════════════════

// MEM stage writeback (load data, 1-cycle delay after MEM access)
reg        mem_wb_valid_r;
reg [4:0]  mem_wb_rd_r;
reg        mem_wb_rd_wen_r;
reg [31:0] mem_wb_data_r;
reg [4:0]  mem_wb_tag_r;
reg [2:0]  mem_wb_fu_r;
reg [0:0]  mem_wb_tid_r;
reg        mem_wb_mem2reg_r;
reg [2:0]  mem_wb_func3_r;  // Added: delayed func3

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        mem_wb_valid_r   <= 1'b0;
        mem_wb_rd_r      <= 5'd0;
        mem_wb_rd_wen_r  <= 1'b0;
        mem_wb_data_r    <= 32'd0;
        mem_wb_tag_r     <= 5'd0;
        mem_wb_fu_r      <= 3'd0;
        mem_wb_tid_r     <= 1'b0;
        mem_wb_mem2reg_r <= 1'b0;
        mem_wb_func3_r   <= 3'd0;
    end else begin
        mem_wb_valid_r   <= p1_mem_req_valid;
        mem_wb_rd_r      <= p1_mem_req_rd;
        mem_wb_rd_wen_r  <= p1_mem_req_regs_write;
        mem_wb_tag_r     <= p1_mem_req_tag;
        mem_wb_fu_r      <= p1_mem_req_fu;
        mem_wb_tid_r     <= p1_mem_req_tid;
        mem_wb_mem2reg_r <= p1_mem_req_mem2reg;
        mem_wb_func3_r   <= p1_mem_req_func3;  // Save func3 for later use
    end
end

// Select between ALU result and load data for MEM writeback
wire [31:0] mem_wb_data_sel;
wire [31:0] wb_load_data;

stage_wb u_stage_wb_mem(
    .wb_mem_data   (mem_rdata        ),
    .wb_alu_o      (32'd0            ), // not used for load path
    .wb_mem2reg    (1'b1             ), // always select mem data for this path
    .wb_func3_code (mem_wb_func3_r   ), // Use delayed func3
    .w_regs_data   (wb_load_data     )
);

assign mem_wb_data_sel = mem_wb_mem2reg_r ? wb_load_data : mem_wb_data_r;

// Bypass signals
assign mem_wb_valid  = mem_wb_valid_r;
assign mem_wb_rd     = mem_wb_rd_r;
assign mem_wb_rd_wen = mem_wb_rd_wen_r;
assign mem_wb_data   = mem_wb_data_sel;

// ─── WB Port 0: from Pipe 0 (INT + Branch, single-cycle) ──────────────────
assign w_regs_en_0   = p0_ex_valid && p0_ex_rd_wen;
assign w_regs_addr_0 = p0_ex_rd;
assign w_regs_data_0 = p0_ex_result;
assign w_regs_tid_0  = p0_ex_tid;

assign wb0_valid      = p0_ex_valid;
assign wb0_tag        = p0_ex_tag;
assign wb0_rd         = p0_ex_rd;
assign wb0_regs_write = p0_ex_rd_wen;
assign wb0_fu         = p0_ex_fu;
assign wb0_tid        = p0_ex_tid;

// ─── WB Port 1: from MEM or MUL (whichever is valid) ──────────────────────
// MUL takes priority if both valid simultaneously (edge case)
wire wb1_from_mul = p1_mul_valid;
wire wb1_from_mem = mem_wb_valid_r && !p1_mul_valid;
wire wb1_from_alu = p1_alu_valid && !p1_mul_valid && !mem_wb_valid_r;

assign w_regs_en_1   = wb1_from_mul ? p1_mul_regs_write :
                       wb1_from_mem ? mem_wb_rd_wen_r   :
                       wb1_from_alu ? p1_alu_rd_wen     : 1'b0;
assign w_regs_addr_1 = wb1_from_mul ? p1_mul_rd         :
                       wb1_from_mem ? mem_wb_rd_r       :
                       wb1_from_alu ? p1_alu_rd         : 5'd0;
assign w_regs_data_1 = wb1_from_mul ? p1_mul_result     :
                       wb1_from_mem ? mem_wb_data_sel   :
                       wb1_from_alu ? p1_alu_result     : 32'd0;
assign w_regs_tid_1  = wb1_from_mul ? p1_mul_tid        :
                       wb1_from_mem ? mem_wb_tid_r      :
                       wb1_from_alu ? p1_alu_tid        : 1'b0;

assign wb1_valid      = wb1_from_mul || wb1_from_mem || wb1_from_alu;
assign wb1_tag        = wb1_from_mul ? p1_mul_tag  :
                        wb1_from_mem ? mem_wb_tag_r :
                        wb1_from_alu ? p1_alu_tag  : 5'd0;
assign wb1_rd         = w_regs_addr_1;
assign wb1_regs_write = w_regs_en_1;
assign wb1_fu         = wb1_from_mul ? p1_mul_fu  :
                        wb1_from_mem ? mem_wb_fu_r :
                        wb1_from_alu ? p1_alu_fu  : 3'd0;
assign wb1_tid        = w_regs_tid_1;

// ════════════════════════════════════════════════════════════════════════════
// CSR Unit (currently unused in basic RV32I tests, connected for future use)
// ════════════════════════════════════════════════════════════════════════════
csr_unit #(.HART_ID(0)) u_csr_unit(
    .clk             (clk           ),
    .rstn            (rstn          ),
    .csr_valid       (1'b0          ),  // not driven in basic tests
    .csr_addr        (12'd0         ),
    .csr_op          (3'd0          ),
    .csr_wdata       (32'd0         ),
    .csr_rdata       (              ),
    .exc_valid       (1'b0          ),
    .exc_cause       (32'd0         ),
    .exc_pc          (32'd0         ),
    .exc_tval        (32'd0         ),
    .mret_valid      (1'b0          ),
    .trap_enter      (              ),
    .trap_target     (              ),
    .trap_return     (              ),
    .mepc_out        (              ),
    .satp_out        (              ),
    .priv_mode_out   (              ),
    .mstatus_mxr     (              ),
    .mstatus_sum     (              ),
    .global_int_en   (              ),
    .instr_retired   (wb0_valid     ),
    .instr_retired_1 (wb1_valid     )
);

endmodule
