// =============================================================================
// define_v2.v — Extended defines for the upgraded AdamRISCV micro-architecture
// Includes original RV32I defines + new defines for dual-issue, MMU, AI accel
// =============================================================================

// ─── Original defines (preserved) ───────────────────────────────────────────
`include "define.v"

// ─── Functional Unit Types (extended for dual-issue) ────────────────────────
//   Original: 0=NOP, 1-5=INT variants, 6=LOAD, 7=STORE
//   Extended: add MUL, DIV, BRANCH_UNIT, ROCC
`define FU_NOP     3'd0
`define FU_INT0    3'd1   // Integer pipe 0 (ADD/SUB/shifts/logic)
`define FU_INT1    3'd2   // Integer pipe 1 (same ops, second port)
`define FU_MUL     3'd3   // Multiplier (3-cycle latency)
`define FU_LOAD    3'd6   // Load unit (reuse original encoding)
`define FU_STORE   3'd7   // Store unit (reuse original encoding)

// ─── Issue Port Assignment ──────────────────────────────────────────────────
`define ISS_PORT0  1'b0   // ALU Pipe 0 (INT + Branch)
`define ISS_PORT1  1'b1   // ALU Pipe 1 (INT + MUL + MEM)

// ─── Scoreboard V2 Constants ────────────────────────────────────────────────
`define SB_RS_DEPTH    16  // Reservation station depth
`define SB_RS_IDX_W    4   // log2(RS_DEPTH)
`define SB_RS_TAG_W    5   // tag width (> log2(RS_DEPTH))

// ─── BPU Constants ──────────────────────────────────────────────────────────
`define BPU_ENTRIES     256  // 2-bit counter table size
`define BPU_IDX_W       8    // log2(BPU_ENTRIES)
`define BPU_ST          2'b00  // Strongly Not Taken
`define BPU_WNT         2'b01  // Weakly Not Taken
`define BPU_WT          2'b10  // Weakly Taken
`define BPU_SNT         2'b11  // Strongly Taken

// ─── Custom RoCC Opcodes ────────────────────────────────────────────────────
`define OPC_CUSTOM0  7'b0001011  // custom-0 (opcode 0x0B)
`define OPC_CUSTOM1  7'b0101011  // custom-1 (opcode 0x2B)

// ─── RoCC funct7 encodings ──────────────────────────────────────────────────
`define ROCC_GEMM_START    7'd0
`define ROCC_VEC_OP        7'd1
`define ROCC_CTX_COMPRESS  7'd2
`define ROCC_LOAD_SCRATCH  7'd3
`define ROCC_STORE_SCRATCH 7'd4
`define ROCC_STATUS_READ   7'd5

// ─── Cache / Memory Constants ───────────────────────────────────────────────
`define CACHE_LINE_BYTES   64
`define CACHE_WAYS         4
`define MSHR_ENTRIES       4
`define AXI_BURST_INCR     2'b01

// ─── MMU Constants ──────────────────────────────────────────────────────────
`define SATP_MODE_BARE     1'b0
`define SATP_MODE_SV32     1'b1
`define PRIV_M             2'b11
`define PRIV_S             2'b01
`define PRIV_U             2'b00
