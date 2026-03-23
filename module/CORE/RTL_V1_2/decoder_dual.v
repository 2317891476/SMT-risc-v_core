// =============================================================================
// Module : decoder_dual
// Description: Dual-path instruction decoder wrapper.
//   Instantiates two copies of the existing stage_is logic to decode up to
//   two instructions per cycle. Each decoder produces the full set of control
//   signals, rs1/rs2/rd addresses, immediate, FU type, and validity.
//
//   The dual decoder also performs a structural hazard check:
//   - If both instructions target the same FU that cannot be dual-issued
//     (e.g. both are loads, both are stores, both are branches),
//     only the first instruction is marked valid for dispatch.
//   - WAW on the same rd is also caught; only inst0 proceeds.
//
//   NOTE: This module is pure combinational. Pipeline registers are external.
// =============================================================================
`include "define.v"

module decoder_dual (
    // ─── Input: two instruction words from Fetch Buffer ──────────
    input  wire        inst0_valid,
    input  wire [31:0] inst0_word,      // instruction 0 (older in program order)
    input  wire [31:0] inst0_pc,
    input  wire [0:0]  inst0_tid,

    input  wire        inst1_valid,
    input  wire [31:0] inst1_word,      // instruction 1 (younger)
    input  wire [31:0] inst1_pc,
    input  wire [0:0]  inst1_tid,

    // ─── Output: Decoded instruction 0 ──────────────────────────
    output wire        dec0_valid,      // decoded & can be dispatched
    output wire [31:0] dec0_pc,
    output wire [31:0] dec0_imm,
    output wire [2:0]  dec0_func3,
    output wire        dec0_func7,
    output wire [4:0]  dec0_rd,
    output wire        dec0_br,
    output wire        dec0_mem_read,
    output wire        dec0_mem2reg,
    output wire [2:0]  dec0_alu_op,
    output wire        dec0_mem_write,
    output wire [1:0]  dec0_alu_src1,
    output wire [1:0]  dec0_alu_src2,
    output wire        dec0_br_addr_mode,
    output wire        dec0_regs_write,
    output wire [4:0]  dec0_rs1,
    output wire [4:0]  dec0_rs2,
    output wire        dec0_rs1_used,
    output wire        dec0_rs2_used,
    output wire [2:0]  dec0_fu,
    output wire [0:0]  dec0_tid,

    // ─── Output: Decoded instruction 1 ──────────────────────────
    output wire        dec1_valid,
    output wire [31:0] dec1_pc,
    output wire [31:0] dec1_imm,
    output wire [2:0]  dec1_func3,
    output wire        dec1_func7,
    output wire [4:0]  dec1_rd,
    output wire        dec1_br,
    output wire        dec1_mem_read,
    output wire        dec1_mem2reg,
    output wire [2:0]  dec1_alu_op,
    output wire        dec1_mem_write,
    output wire [1:0]  dec1_alu_src1,
    output wire [1:0]  dec1_alu_src2,
    output wire        dec1_br_addr_mode,
    output wire        dec1_regs_write,
    output wire [4:0]  dec1_rs1,
    output wire [4:0]  dec1_rs2,
    output wire        dec1_rs1_used,
    output wire        dec1_rs2_used,
    output wire [2:0]  dec1_fu,
    output wire [0:0]  dec1_tid,

    // ─── Backpressure: how many instructions consumed ───────────
    output wire        consume_0,      // decoder consumed inst0
    output wire        consume_1       // decoder consumed inst1
);

// ─── Internal decoded signals for instruction 0 ─────────────────────────────
wire        d0_valid_raw;
wire [31:0] d0_imm;
wire [2:0]  d0_func3;
wire        d0_func7;
wire [4:0]  d0_rd;
wire        d0_br;
wire        d0_mem_read;
wire        d0_mem2reg;
wire [2:0]  d0_alu_op;
wire        d0_mem_write;
wire [1:0]  d0_alu_src1;
wire [1:0]  d0_alu_src2;
wire        d0_br_addr_mode;
wire        d0_regs_write;
wire [4:0]  d0_rs1;
wire [4:0]  d0_rs2;
wire        d0_rs1_used;
wire        d0_rs2_used;
wire [2:0]  d0_fu;
wire [31:0] d0_pc_o;

// ─── Internal decoded signals for instruction 1 ─────────────────────────────
wire        d1_valid_raw;
wire [31:0] d1_imm;
wire [2:0]  d1_func3;
wire        d1_func7;
wire [4:0]  d1_rd;
wire        d1_br;
wire        d1_mem_read;
wire        d1_mem2reg;
wire [2:0]  d1_alu_op;
wire        d1_mem_write;
wire [1:0]  d1_alu_src1;
wire [1:0]  d1_alu_src2;
wire        d1_br_addr_mode;
wire        d1_regs_write;
wire [4:0]  d1_rs1;
wire [4:0]  d1_rs2;
wire        d1_rs1_used;
wire        d1_rs2_used;
wire [2:0]  d1_fu;
wire [31:0] d1_pc_o;

// ─── Decoder 0 (reuses existing stage_is logic) ─────────────────────────────
stage_is u_dec0 (
    .is_inst         (inst0_word      ),
    .is_pc           (inst0_pc        ),
    .is_pc_o         (d0_pc_o         ),
    .is_imm          (d0_imm          ),
    .is_func3_code   (d0_func3        ),
    .is_func7_code   (d0_func7        ),
    .is_rd           (d0_rd           ),
    .is_br           (d0_br           ),
    .is_mem_read     (d0_mem_read     ),
    .is_mem2reg      (d0_mem2reg      ),
    .is_alu_op       (d0_alu_op       ),
    .is_mem_write    (d0_mem_write    ),
    .is_alu_src1     (d0_alu_src1     ),
    .is_alu_src2     (d0_alu_src2     ),
    .is_br_addr_mode (d0_br_addr_mode ),
    .is_regs_write   (d0_regs_write   ),
    .is_rs1          (d0_rs1          ),
    .is_rs2          (d0_rs2          ),
    .is_rs1_used     (d0_rs1_used     ),
    .is_rs2_used     (d0_rs2_used     ),
    .is_fu           (d0_fu           ),
    .is_valid        (d0_valid_raw    )
);

// ─── Decoder 1 (second copy) ────────────────────────────────────────────────
stage_is u_dec1 (
    .is_inst         (inst1_word      ),
    .is_pc           (inst1_pc        ),
    .is_pc_o         (d1_pc_o         ),
    .is_imm          (d1_imm          ),
    .is_func3_code   (d1_func3        ),
    .is_func7_code   (d1_func7        ),
    .is_rd           (d1_rd           ),
    .is_br           (d1_br           ),
    .is_mem_read     (d1_mem_read     ),
    .is_mem2reg      (d1_mem2reg      ),
    .is_alu_op       (d1_alu_op       ),
    .is_mem_write    (d1_mem_write    ),
    .is_alu_src1     (d1_alu_src1     ),
    .is_alu_src2     (d1_alu_src2     ),
    .is_br_addr_mode (d1_br_addr_mode ),
    .is_regs_write   (d1_regs_write   ),
    .is_rs1          (d1_rs1          ),
    .is_rs2          (d1_rs2          ),
    .is_rs1_used     (d1_rs1_used     ),
    .is_rs2_used     (d1_rs2_used     ),
    .is_fu           (d1_fu           ),
    .is_valid        (d1_valid_raw    )
);

// ─── Dual-issue structural hazard check ─────────────────────────────────────
// Conditions that block inst1 dispatch:
//   1) Both are branches
//   2) Both access memory (load or store)
//   3) WAW: both write to the same rd (rd != 0)
//   4) inst0 is invalid (must issue in program order)
//   5) inst1 thread differs from inst0 (fetch_buffer already guarantees same-thread,
//      but double-check for safety)

wire structural_conflict;
wire both_branch;
wire both_mem;
wire waw_conflict;
wire thread_mismatch;

assign both_branch     = d0_br && d1_br;
assign both_mem        = (d0_mem_read || d0_mem_write) && (d1_mem_read || d1_mem_write);
assign waw_conflict    = d0_regs_write && d1_regs_write && (d0_rd == d1_rd) && (d0_rd != 5'd0);
assign thread_mismatch = (inst0_tid != inst1_tid);
assign structural_conflict = both_branch || both_mem || waw_conflict || thread_mismatch;

// ─── Final valid signals ────────────────────────────────────────────────────
wire dec0_valid_int;
wire dec1_valid_int;

assign dec0_valid_int = inst0_valid && d0_valid_raw;
assign dec1_valid_int = inst1_valid && d1_valid_raw && dec0_valid_int && !structural_conflict;

assign dec0_valid = dec0_valid_int;
assign dec1_valid = dec1_valid_int;

// ─── Feed through decoded signals ───────────────────────────────────────────
assign dec0_pc           = d0_pc_o;
assign dec0_imm          = d0_imm;
assign dec0_func3        = d0_func3;
assign dec0_func7        = d0_func7;
assign dec0_rd           = d0_rd;
assign dec0_br           = d0_br;
assign dec0_mem_read     = d0_mem_read;
assign dec0_mem2reg      = d0_mem2reg;
assign dec0_alu_op       = d0_alu_op;
assign dec0_mem_write    = d0_mem_write;
assign dec0_alu_src1     = d0_alu_src1;
assign dec0_alu_src2     = d0_alu_src2;
assign dec0_br_addr_mode = d0_br_addr_mode;
assign dec0_regs_write   = d0_regs_write;
assign dec0_rs1          = d0_rs1;
assign dec0_rs2          = d0_rs2;
assign dec0_rs1_used     = d0_rs1_used;
assign dec0_rs2_used     = d0_rs2_used;
assign dec0_fu           = d0_fu;
assign dec0_tid          = inst0_tid;

assign dec1_pc           = d1_pc_o;
assign dec1_imm          = d1_imm;
assign dec1_func3        = d1_func3;
assign dec1_func7        = d1_func7;
assign dec1_rd           = d1_rd;
assign dec1_br           = d1_br;
assign dec1_mem_read     = d1_mem_read;
assign dec1_mem2reg      = d1_mem2reg;
assign dec1_alu_op       = d1_alu_op;
assign dec1_mem_write    = d1_mem_write;
assign dec1_alu_src1     = d1_alu_src1;
assign dec1_alu_src2     = d1_alu_src2;
assign dec1_br_addr_mode = d1_br_addr_mode;
assign dec1_regs_write   = d1_regs_write;
assign dec1_rs1          = d1_rs1;
assign dec1_rs2          = d1_rs2;
assign dec1_rs1_used     = d1_rs1_used;
assign dec1_rs2_used     = d1_rs2_used;
assign dec1_fu           = d1_fu;
assign dec1_tid          = inst1_tid;

// ─── Consume signals (feedback to fetch_buffer) ─────────────────────────────
assign consume_0 = dec0_valid_int;
assign consume_1 = dec1_valid_int;

endmodule
