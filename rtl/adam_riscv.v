// author       : adam_wu
// course       : Microprocessor Architecture and Design
// ID           : 21033075
// project_name : AdamRiscv (RV32I 9-stage SMT Processor)
// SMT notes    : 2-thread hyperthreading added
//   - thread_scheduler: round-robin fetch selection
//   - pc_mt         : 2 independent PCs
//   - regs_mt       : 2-bank register file (indexed by thread_id)
//   - scoreboard    : per-thread reg_result_status, thread-scoped dep checks
//   - All pipeline regs carry thread_id (tid) through the pipe
//   - Per-thread flush: branch only flushes its own thread's instructions

module adam_riscv(
    input wire sys_clk,
`ifdef FPGA_MODE
    output wire[2:0] led,
`endif
    input wire sys_rstn
);

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

// ─── SMT control signals ─────────────────────────────────────────────────────
wire [0:0] fetch_tid;          // thread selected by scheduler this cycle
wire [1:0] smt_stall;          // per-thread stall flag (simplified: same for both)
wire [1:0] smt_flush;          // per-thread flush (from branch detection)

// ─── Global stall / flush (single RS, shared stall) ─────────────────────────
wire stall;
wire br_ctrl;
wire [31:0] br_addr;           // branch target (from EX stage)

// Per-thread flush: a branch only flushes instructions of its thread
// We capture which thread generated the branch at the EX stage via ex_tid
wire [0:0] br_tid;             // thread that generated the branch (from pipeline)
assign smt_flush[0] = br_ctrl && (br_tid == 1'b0);
assign smt_flush[1] = br_ctrl && (br_tid == 1'b1);
// Global flush for modules that still use a single flush signal
wire flush_any;
assign flush_any = br_ctrl;

assign stall    = sb_rs_full;
assign smt_stall = {stall, stall};  // simplified: both threads stall together

// ─── IF stage ────────────────────────────────────────────────────────────────
wire [31:0] if_pc;
wire [31:0] if_inst;
wire [0:0]  if_tid;

// ─── IF/ID (IS) register outputs ─────────────────────────────────────────────
wire [31:0] is_inst;
wire [31:0] is_pc;
wire [0:0]  is_tid;  // thread_id that came out of IF/ID

// ─── IS decode outputs ───────────────────────────────────────────────────────
wire [31:0] is_pc_o;
wire [31:0] is_imm;
wire [2:0]  is_func3_code;
wire        is_func7_code;
wire [4:0]  is_rd;
wire        is_br;
wire        is_mem_read;
wire        is_mem2reg;
wire [2:0]  is_alu_op;
wire        is_mem_write;
wire [1:0]  is_alu_src1;
wire [1:0]  is_alu_src2;
wire        is_br_addr_mode;
wire        is_regs_write;
wire [4:0]  is_rs1;
wire [4:0]  is_rs2;
wire        is_rs1_used;
wire        is_rs2_used;
wire [2:0]  is_fu;
wire        is_valid;

// ─── Scoreboard / RS ─────────────────────────────────────────────────────────
wire        sb_rs_full;
wire        is_push;
wire        sb_issue_valid;
wire [31:0] sb_issue_pc;
wire [31:0] sb_issue_imm;
wire [2:0]  sb_issue_func3_code;
wire        sb_issue_func7_code;
wire [4:0]  sb_issue_rd;
wire        sb_issue_br;
wire        sb_issue_mem_read;
wire        sb_issue_mem2reg;
wire [2:0]  sb_issue_alu_op;
wire        sb_issue_mem_write;
wire [1:0]  sb_issue_alu_src1;
wire [1:0]  sb_issue_alu_src2;
wire        sb_issue_br_addr_mode;
wire        sb_issue_regs_write;
wire [4:0]  sb_issue_rs1;
wire [4:0]  sb_issue_rs2;
wire        sb_issue_rs1_used;
wire        sb_issue_rs2_used;
wire [2:0]  sb_issue_fu;
wire [3:0]  sb_issue_sb_tag;
wire [0:0]  sb_issue_tid;

// ─── RO outputs ──────────────────────────────────────────────────────────────
wire        ro_valid;
wire        ro_fire;
wire [31:0] ro_pc;
wire [31:0] ro_imm;
wire [2:0]  ro_func3_code;
wire        ro_func7_code;
wire [4:0]  ro_rd;
wire        ro_br;
wire        ro_mem_read;
wire        ro_mem2reg;
wire [2:0]  ro_alu_op;
wire        ro_mem_write;
wire [1:0]  ro_alu_src1;
wire [1:0]  ro_alu_src2;
wire        ro_br_addr_mode;
wire        ro_regs_write;
wire [4:0]  ro_rs1;
wire [4:0]  ro_rs2;
wire        ro_rs1_used;
wire        ro_rs2_used;
wire [2:0]  ro_fu;
wire [3:0]  ro_sb_tag;
wire [0:0]  ro_tid;
wire [31:0] ro_regs_data1;
wire [31:0] ro_regs_data2;

// ─── EX inputs (from reg_ro_ex) ──────────────────────────────────────────────
wire [31:0] ex_pc;
wire [31:0] ex_regs_data1;
wire [31:0] ex_regs_data2;
wire [31:0] ex_imm;
wire [2:0]  ex_func3_code;
wire        ex_func7_code;
wire [4:0]  ex_rd;
wire        ex_br;
wire        ex_mem_read;
wire        ex_mem2reg;
wire [2:0]  ex_alu_op;
wire        ex_mem_write;
wire [1:0]  ex_alu_src1;
wire [1:0]  ex_alu_src2;
wire        ex_br_addr_mode;
wire        ex_regs_write;
wire [2:0]  ex_fu;
wire [3:0]  ex_sb_tag;
wire [0:0]  ex_tid;  // thread_id at EX1 stage — used for branch flush routing

// ─── EX pipeline stages (EX1→EX4) ───────────────────────────────────────────
wire [31:0] ex1_alu_o;
wire [31:0] ex1_regs_data2;

wire [31:0] ex2_alu_o;   wire [31:0] ex2_regs_data2;
wire [4:0]  ex2_rd;      wire        ex2_mem_read;
wire        ex2_mem2reg; wire        ex2_mem_write;
wire        ex2_regs_write; wire [2:0] ex2_func3_code;
wire [2:0]  ex2_fu;      wire [3:0]  ex2_sb_tag;
wire [0:0]  ex2_tid;

wire [31:0] ex3_alu_o;   wire [31:0] ex3_regs_data2;
wire [4:0]  ex3_rd;      wire        ex3_mem_read;
wire        ex3_mem2reg; wire        ex3_mem_write;
wire        ex3_regs_write; wire [2:0] ex3_func3_code;
wire [2:0]  ex3_fu;      wire [3:0]  ex3_sb_tag;
wire [0:0]  ex3_tid;

wire [31:0] ex4_alu_o;   wire [31:0] ex4_regs_data2;
wire [4:0]  ex4_rd;      wire        ex4_mem_read;
wire        ex4_mem2reg; wire        ex4_mem_write;
wire        ex4_regs_write; wire [2:0] ex4_func3_code;
wire [2:0]  ex4_fu;      wire [3:0]  ex4_sb_tag;
wire [0:0]  ex4_tid;

// ─── MEM stage ───────────────────────────────────────────────────────────────
wire [4:0]  me_rs2_unused;
wire [31:0] me_regs_data2;
wire [31:0] me_alu_o;
wire [4:0]  me_rd;
wire        me_mem_read;
wire        me_mem2reg;
wire        me_mem_write;
wire        me_regs_write;
wire [2:0]  me_fu;
wire [3:0]  me_sb_tag;
wire [31:0] me_mem_data;
wire [2:0]  me_func3_code;
wire [0:0]  me_tid;

// ─── WB stage ────────────────────────────────────────────────────────────────
wire        w_regs_en;
wire [4:0]  w_regs_addr;
wire [31:0] w_regs_data;
wire [2:0]  wb_func3_code;
wire [31:0] wb_mem_data;
wire [31:0] wb_alu_o;
wire        wb_mem2reg;
wire [2:0]  wb_fu;
wire [3:0]  wb_sb_tag;
wire [0:0]  wb_tid;

// The thread that generated the branch is tracked through the EX stages.
// For simplicity we use ex_tid (available at EX1) as br_tid.
// The branch result (br_ctrl) also comes from EX1.
assign br_tid = ex_tid;

wire forward_data;
assign forward_data = 1'b0;
assign ro_fire = ro_valid;
// is_push: per-thread flush check — must not push if current thread is being flushed
assign is_push = is_valid && (!sb_rs_full) && (!smt_flush[is_tid]);

// ─── Thread Scheduler ────────────────────────────────────────────────────────
thread_scheduler u_thread_scheduler(
    .clk          (clk         ),
    .rstn         (rstn        ),
    .thread_stall (smt_stall   ),
    .fetch_tid    (fetch_tid   )
);

// ─── IF Stage ────────────────────────────────────────────────────────────────
stage_if u_stage_if(
    .clk         (clk          ),
    .rstn        (rstn         ),
    .pc_stall    (stall        ),
    .if_flush    (smt_flush    ),
    .br_addr_t0  (br_ctrl && (br_tid == 1'b0) ? br_addr : 32'd0),
    .br_addr_t1  (br_ctrl && (br_tid == 1'b1) ? br_addr : 32'd0),
    .br_ctrl     ({br_ctrl && (br_tid==1'b1), br_ctrl && (br_tid==1'b0)}),
    .fetch_tid   (fetch_tid    ),
    .if_inst     (if_inst      ),
    .if_pc       (if_pc        ),
    .if_tid      (if_tid       )
);

// ─── IF/ID Buffer ────────────────────────────────────────────────────────────
reg_if_id u_reg_if_id(
    .clk         (clk         ),
    .rstn        (rstn        ),
    .if_pc       (if_pc       ),
    .if_inst     (if_inst     ),
    .if_tid      (if_tid      ),
    .id_inst     (is_inst     ),
    .id_pc       (is_pc       ),
    .id_tid      (is_tid      ),
    .if_id_flush (flush_any   ),
    .if_id_stall (stall       )
);

// ─── IS (Decode) Stage ───────────────────────────────────────────────────────
stage_is u_stage_is(
    .is_inst         (is_inst         ),
    .is_pc           (is_pc           ),
    .is_pc_o         (is_pc_o         ),
    .is_imm          (is_imm          ),
    .is_func3_code   (is_func3_code   ),
    .is_func7_code   (is_func7_code   ),
    .is_rd           (is_rd           ),
    .is_br           (is_br           ),
    .is_mem_read     (is_mem_read     ),
    .is_mem2reg      (is_mem2reg      ),
    .is_alu_op       (is_alu_op       ),
    .is_mem_write    (is_mem_write    ),
    .is_alu_src1     (is_alu_src1     ),
    .is_alu_src2     (is_alu_src2     ),
    .is_br_addr_mode (is_br_addr_mode ),
    .is_regs_write   (is_regs_write   ),
    .is_rs1          (is_rs1          ),
    .is_rs2          (is_rs2          ),
    .is_rs1_used     (is_rs1_used     ),
    .is_rs2_used     (is_rs2_used     ),
    .is_fu           (is_fu           ),
    .is_valid        (is_valid        )
);

// ─── Scoreboard ──────────────────────────────────────────────────────────────
scoreboard u_scoreboard(
    .clk                  (clk                  ),
    .rstn                 (rstn                 ),
    .flush                (flush_any            ),
    .flush_tid            (br_tid               ),   // SMT: per-thread flush
    .is_push              (is_push              ),
    .is_pc                (is_pc_o              ),
    .is_imm               (is_imm               ),
    .is_func3_code        (is_func3_code        ),
    .is_func7_code        (is_func7_code        ),
    .is_rd                (is_rd                ),
    .is_br                (is_br                ),
    .is_mem_read          (is_mem_read          ),
    .is_mem2reg           (is_mem2reg           ),
    .is_alu_op            (is_alu_op            ),
    .is_mem_write         (is_mem_write         ),
    .is_alu_src1          (is_alu_src1          ),
    .is_alu_src2          (is_alu_src2          ),
    .is_br_addr_mode      (is_br_addr_mode      ),
    .is_regs_write        (is_regs_write        ),
    .is_rs1               (is_rs1               ),
    .is_rs2               (is_rs2               ),
    .is_rs1_used          (is_rs1_used          ),
    .is_rs2_used          (is_rs2_used          ),
    .is_fu                (is_fu                ),
    .is_tid               (is_tid               ),   // SMT
    .rs_full              (sb_rs_full           ),
    .ro_issue_valid       (sb_issue_valid       ),
    .ro_issue_pc          (sb_issue_pc          ),
    .ro_issue_imm         (sb_issue_imm         ),
    .ro_issue_func3_code  (sb_issue_func3_code  ),
    .ro_issue_func7_code  (sb_issue_func7_code  ),
    .ro_issue_rd          (sb_issue_rd          ),
    .ro_issue_br          (sb_issue_br          ),
    .ro_issue_mem_read    (sb_issue_mem_read    ),
    .ro_issue_mem2reg     (sb_issue_mem2reg     ),
    .ro_issue_alu_op      (sb_issue_alu_op      ),
    .ro_issue_mem_write   (sb_issue_mem_write   ),
    .ro_issue_alu_src1    (sb_issue_alu_src1    ),
    .ro_issue_alu_src2    (sb_issue_alu_src2    ),
    .ro_issue_br_addr_mode(sb_issue_br_addr_mode),
    .ro_issue_regs_write  (sb_issue_regs_write  ),
    .ro_issue_rs1         (sb_issue_rs1         ),
    .ro_issue_rs2         (sb_issue_rs2         ),
    .ro_issue_rs1_used    (sb_issue_rs1_used    ),
    .ro_issue_rs2_used    (sb_issue_rs2_used    ),
    .ro_issue_fu          (sb_issue_fu          ),
    .ro_issue_sb_tag      (sb_issue_sb_tag      ),
    .ro_issue_tid         (sb_issue_tid         ),   // SMT
    .wb_fu                (wb_fu                ),
    .wb_rd                (w_regs_addr          ),
    .wb_regs_write        (w_regs_en            ),
    .wb_sb_tag            (wb_sb_tag            ),
    .wb_tid               (wb_tid               )    // SMT
);

// ─── IS→RO Buffer ────────────────────────────────────────────────────────────
reg_is_ro u_reg_is_ro(
    .clk               (clk                  ),
    .rstn              (rstn                 ),
    .flush             (flush_any            ),
    .flush_tid         (br_tid               ),  // SMT: per-thread flush
    .issue_en          (sb_issue_valid       ),
    .ro_fire           (ro_fire              ),
    .issue_pc          (sb_issue_pc          ),
    .issue_imm         (sb_issue_imm         ),
    .issue_func3_code  (sb_issue_func3_code  ),
    .issue_func7_code  (sb_issue_func7_code  ),
    .issue_rd          (sb_issue_rd          ),
    .issue_br          (sb_issue_br          ),
    .issue_mem_read    (sb_issue_mem_read    ),
    .issue_mem2reg     (sb_issue_mem2reg     ),
    .issue_alu_op      (sb_issue_alu_op      ),
    .issue_mem_write   (sb_issue_mem_write   ),
    .issue_alu_src1    (sb_issue_alu_src1    ),
    .issue_alu_src2    (sb_issue_alu_src2    ),
    .issue_br_addr_mode(sb_issue_br_addr_mode),
    .issue_regs_write  (sb_issue_regs_write  ),
    .issue_rs1         (sb_issue_rs1         ),
    .issue_rs2         (sb_issue_rs2         ),
    .issue_rs1_used    (sb_issue_rs1_used    ),
    .issue_rs2_used    (sb_issue_rs2_used    ),
    .issue_fu          (sb_issue_fu          ),
    .issue_sb_tag      (sb_issue_sb_tag      ),
    .issue_tid         (sb_issue_tid         ),  // SMT
    .ro_valid          (ro_valid             ),
    .ro_pc             (ro_pc                ),
    .ro_imm            (ro_imm               ),
    .ro_func3_code     (ro_func3_code        ),
    .ro_func7_code     (ro_func7_code        ),
    .ro_rd             (ro_rd                ),
    .ro_br             (ro_br                ),
    .ro_mem_read       (ro_mem_read          ),
    .ro_mem2reg        (ro_mem2reg           ),
    .ro_alu_op         (ro_alu_op            ),
    .ro_mem_write      (ro_mem_write         ),
    .ro_alu_src1       (ro_alu_src1          ),
    .ro_alu_src2       (ro_alu_src2          ),
    .ro_br_addr_mode   (ro_br_addr_mode      ),
    .ro_regs_write     (ro_regs_write        ),
    .ro_rs1            (ro_rs1               ),
    .ro_rs2            (ro_rs2               ),
    .ro_rs1_used       (ro_rs1_used          ),
    .ro_rs2_used       (ro_rs2_used          ),
    .ro_fu             (ro_fu                ),
    .ro_sb_tag         (ro_sb_tag            ),
    .ro_tid            (ro_tid               )   // SMT
);

// ─── RO (Read Operand) Stage ─────────────────────────────────────────────────
stage_ro u_stage_ro(
    .clk          (clk          ),
    .rstn         (rstn         ),
    .ro_tid       (ro_tid       ),  // SMT: read from correct register bank
    .ro_rs1       (ro_rs1       ),
    .ro_rs2       (ro_rs2       ),
    .w_thread_id  (wb_tid       ),  // SMT: write to correct register bank
    .w_regs_en    (w_regs_en    ),
    .w_regs_addr  (w_regs_addr  ),
    .w_regs_data  (w_regs_data  ),
    .ro_regs_data1(ro_regs_data1),
    .ro_regs_data2(ro_regs_data2)
);

// ─── RO→EX Buffer ────────────────────────────────────────────────────────────
reg_ro_ex u_reg_ro_ex(
    .clk            (clk            ),
    .rstn           (rstn           ),
    .flush          (flush_any      ),
    .flush_tid      (br_tid         ),  // SMT: per-thread flush
    .ro_fire        (ro_fire        ),
    .ro_pc          (ro_pc          ),
    .ro_regs_data1  (ro_regs_data1  ),
    .ro_regs_data2  (ro_regs_data2  ),
    .ro_imm         (ro_imm         ),
    .ro_func3_code  (ro_func3_code  ),
    .ro_func7_code  (ro_func7_code  ),
    .ro_rd          (ro_rd          ),
    .ro_br          (ro_br          ),
    .ro_mem_read    (ro_mem_read    ),
    .ro_mem2reg     (ro_mem2reg     ),
    .ro_alu_op      (ro_alu_op      ),
    .ro_mem_write   (ro_mem_write   ),
    .ro_alu_src1    (ro_alu_src1    ),
    .ro_alu_src2    (ro_alu_src2    ),
    .ro_br_addr_mode(ro_br_addr_mode),
    .ro_regs_write  (ro_regs_write  ),
    .ro_fu          (ro_fu          ),
    .ro_sb_tag      (ro_sb_tag      ),
    .ro_tid         (ro_tid         ),  // SMT
    .ex_pc          (ex_pc          ),
    .ex_regs_data1  (ex_regs_data1  ),
    .ex_regs_data2  (ex_regs_data2  ),
    .ex_imm         (ex_imm         ),
    .ex_func3_code  (ex_func3_code  ),
    .ex_func7_code  (ex_func7_code  ),
    .ex_rd          (ex_rd          ),
    .ex_br          (ex_br          ),
    .ex_mem_read    (ex_mem_read    ),
    .ex_mem2reg     (ex_mem2reg     ),
    .ex_alu_op      (ex_alu_op      ),
    .ex_mem_write   (ex_mem_write   ),
    .ex_alu_src1    (ex_alu_src1    ),
    .ex_alu_src2    (ex_alu_src2    ),
    .ex_br_addr_mode(ex_br_addr_mode),
    .ex_regs_write  (ex_regs_write  ),
    .ex_fu          (ex_fu          ),
    .ex_sb_tag      (ex_sb_tag      ),
    .ex_tid         (ex_tid         )   // SMT
);

// ─── EX Stage ────────────────────────────────────────────────────────────────
stage_ex u_stage_ex(
    .ex_pc           (ex_pc          ),
    .ex_regs_data1   (ex_regs_data1  ),
    .ex_regs_data2   (ex_regs_data2  ),
    .ex_imm          (ex_imm         ),
    .ex_func3_code   (ex_func3_code  ),
    .ex_func7_code   (ex_func7_code  ),
    .ex_alu_op       (ex_alu_op      ),
    .ex_alu_src1     (ex_alu_src1    ),
    .ex_alu_src2     (ex_alu_src2    ),
    .ex_br_addr_mode (ex_br_addr_mode),
    .ex_br           (ex_br          ),
    .ex_alu_o        (ex1_alu_o      ),
    .ex_regs_data2_o (ex1_regs_data2 ),
    .br_pc           (br_addr        ),
    .br_ctrl         (br_ctrl        )
);

// ─── EX1→EX2 ─────────────────────────────────────────────────────────────────
reg_ex_stage u_reg_ex1_ex2(
    .clk            (clk            ),
    .rstn           (rstn           ),
    .in_regs_data2  (ex1_regs_data2 ),
    .in_alu_o       (ex1_alu_o      ),
    .in_rd          (ex_rd          ),
    .in_mem_read    (ex_mem_read    ),
    .in_mem2reg     (ex_mem2reg     ),
    .in_mem_write   (ex_mem_write   ),
    .in_regs_write  (ex_regs_write  ),
    .in_func3_code  (ex_func3_code  ),
    .in_fu          (ex_fu          ),
    .in_sb_tag      (ex_sb_tag      ),
    .in_tid         (ex_tid         ),  // SMT
    .out_regs_data2 (ex2_regs_data2 ),
    .out_alu_o      (ex2_alu_o      ),
    .out_rd         (ex2_rd         ),
    .out_mem_read   (ex2_mem_read   ),
    .out_mem2reg    (ex2_mem2reg    ),
    .out_mem_write  (ex2_mem_write  ),
    .out_regs_write (ex2_regs_write ),
    .out_func3_code (ex2_func3_code ),
    .out_fu         (ex2_fu         ),
    .out_sb_tag     (ex2_sb_tag     ),
    .out_tid        (ex2_tid        )   // SMT
);

// ─── EX2→EX3 ─────────────────────────────────────────────────────────────────
reg_ex_stage u_reg_ex2_ex3(
    .clk            (clk            ),
    .rstn           (rstn           ),
    .in_regs_data2  (ex2_regs_data2 ),
    .in_alu_o       (ex2_alu_o      ),
    .in_rd          (ex2_rd         ),
    .in_mem_read    (ex2_mem_read   ),
    .in_mem2reg     (ex2_mem2reg    ),
    .in_mem_write   (ex2_mem_write  ),
    .in_regs_write  (ex2_regs_write ),
    .in_func3_code  (ex2_func3_code ),
    .in_fu          (ex2_fu         ),
    .in_sb_tag      (ex2_sb_tag     ),
    .in_tid         (ex2_tid        ),  // SMT
    .out_regs_data2 (ex3_regs_data2 ),
    .out_alu_o      (ex3_alu_o      ),
    .out_rd         (ex3_rd         ),
    .out_mem_read   (ex3_mem_read   ),
    .out_mem2reg    (ex3_mem2reg    ),
    .out_mem_write  (ex3_mem_write  ),
    .out_regs_write (ex3_regs_write ),
    .out_func3_code (ex3_func3_code ),
    .out_fu         (ex3_fu         ),
    .out_sb_tag     (ex3_sb_tag     ),
    .out_tid        (ex3_tid        )   // SMT
);

// ─── EX3→EX4 ─────────────────────────────────────────────────────────────────
reg_ex_stage u_reg_ex3_ex4(
    .clk            (clk            ),
    .rstn           (rstn           ),
    .in_regs_data2  (ex3_regs_data2 ),
    .in_alu_o       (ex3_alu_o      ),
    .in_rd          (ex3_rd         ),
    .in_mem_read    (ex3_mem_read   ),
    .in_mem2reg     (ex3_mem2reg    ),
    .in_mem_write   (ex3_mem_write  ),
    .in_regs_write  (ex3_regs_write ),
    .in_func3_code  (ex3_func3_code ),
    .in_fu          (ex3_fu         ),
    .in_sb_tag      (ex3_sb_tag     ),
    .in_tid         (ex3_tid        ),  // SMT
    .out_regs_data2 (ex4_regs_data2 ),
    .out_alu_o      (ex4_alu_o      ),
    .out_rd         (ex4_rd         ),
    .out_mem_read   (ex4_mem_read   ),
    .out_mem2reg    (ex4_mem2reg    ),
    .out_mem_write  (ex4_mem_write  ),
    .out_regs_write (ex4_regs_write ),
    .out_func3_code (ex4_func3_code ),
    .out_fu         (ex4_fu         ),
    .out_sb_tag     (ex4_sb_tag     ),
    .out_tid        (ex4_tid        )   // SMT
);

// ─── EX4→MEM Buffer ──────────────────────────────────────────────────────────
reg_ex_mem u_reg_ex_mem(
    .clk           (clk            ),
    .rstn          (rstn           ),
    .ex_regs_data2 (ex4_regs_data2 ),
    .ex_alu_o      (ex4_alu_o      ),
    .ex_rd         (ex4_rd         ),
    .ex_mem_read   (ex4_mem_read   ),
    .ex_mem2reg    (ex4_mem2reg    ),
    .ex_mem_write  (ex4_mem_write  ),
    .ex_regs_write (ex4_regs_write ),
    .ex_func3_code (ex4_func3_code ),
    .ex_fu         (ex4_fu         ),
    .ex_sb_tag     (ex4_sb_tag     ),
    .ex_tid        (ex4_tid        ),  // SMT
    .ex_rs2        (5'd0           ),
    .me_rs2        (me_rs2_unused  ),
    .me_regs_data2 (me_regs_data2  ),
    .me_alu_o      (me_alu_o       ),
    .me_rd         (me_rd          ),
    .me_mem_read   (me_mem_read    ),
    .me_mem2reg    (me_mem2reg     ),
    .me_mem_write  (me_mem_write   ),
    .me_regs_write (me_regs_write  ),
    .me_func3_code (me_func3_code  ),
    .me_fu         (me_fu          ),
    .me_sb_tag     (me_sb_tag      ),
    .me_tid        (me_tid         )   // SMT
);

// ─── MEM Stage ───────────────────────────────────────────────────────────────
`ifdef FPGA_MODE
stage_mem u_stage_mem(
    .clk           (clk           ),
    .rstn          (rstn          ),
    .me_regs_data2 (me_regs_data2 ),
    .me_alu_o      (me_alu_o      ),
    .me_mem_read   (me_mem_read   ),
    .me_mem_write  (me_mem_write  ),
    .me_func3_code (me_func3_code ),
    .forward_data  (forward_data  ),
    .w_regs_data   (w_regs_data   ),
    .me_led        (led           ),
    .me_mem_data   (me_mem_data   )
);
`else
stage_mem u_stage_mem(
    .clk           (clk           ),
    .rstn          (rstn          ),
    .me_regs_data2 (me_regs_data2 ),
    .me_alu_o      (me_alu_o      ),
    .me_mem_read   (me_mem_read   ),
    .me_mem_write  (me_mem_write  ),
    .me_func3_code (me_func3_code ),
    .forward_data  (forward_data  ),
    .w_regs_data   (w_regs_data   ),
    .me_mem_data   (me_mem_data   )
);
`endif

// ─── MEM→WB Buffer ───────────────────────────────────────────────────────────
reg_mem_wb u_reg_mem_wb(
    .clk           (clk          ),
    .rstn          (rstn         ),
    .me_mem_data   (me_mem_data  ),
    .me_alu_o      (me_alu_o     ),
    .me_rd         (me_rd        ),
    .me_mem2reg    (me_mem2reg   ),
    .me_regs_write (me_regs_write),
    .me_func3_code (me_func3_code),
    .me_fu         (me_fu        ),
    .me_sb_tag     (me_sb_tag    ),
    .me_tid        (me_tid       ),  // SMT
    .wb_func3_code (wb_func3_code),
    .wb_mem_data   (wb_mem_data  ),
    .wb_alu_o      (wb_alu_o     ),
    .wb_rd         (w_regs_addr  ),
    .wb_mem2reg    (wb_mem2reg   ),
    .wb_regs_write (w_regs_en    ),
    .wb_fu         (wb_fu        ),
    .wb_sb_tag     (wb_sb_tag    ),
    .wb_tid        (wb_tid       )   // SMT
);

// ─── WB Stage ────────────────────────────────────────────────────────────────
stage_wb u_stage_wb(
    .wb_mem_data   (wb_mem_data  ),
    .wb_alu_o      (wb_alu_o     ),
    .wb_mem2reg    (wb_mem2reg   ),
    .wb_func3_code (wb_func3_code),
    .w_regs_data   (w_regs_data  )
);

endmodule
