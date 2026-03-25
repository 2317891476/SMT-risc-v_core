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

// ─── ROB Lite Metadata Constants ────────────────────────────────────────────
`define METADATA_EPOCH_W   8   // Epoch width for flush detection (8 bits)
`define METADATA_ORDER_ID_W 16  // Order ID width for in-order commit tracking (16 bits)

// ════════════════════════════════════════════════════════════════════════════
// P2 MMIO Address Map Constants (for unified L2 + interrupt controller bring-up)
// ════════════════════════════════════════════════════════════════════════════

// Cacheable RAM window (first 16KB)
`define RAM_CACHEABLE_BASE  32'h0000_0000
`define RAM_CACHEABLE_TOP   32'h0000_3FFF

// TUBE MMIO (test completion marker)
`define TUBE_ADDR           32'h1300_0000

// CLINT (Core Local Interruptor) - Machine Timer
`define CLINT_BASE          32'h0200_0000
`define CLINT_MTIMECMP_LO   32'h02004000  // mtimecmp low 32 bits
`define CLINT_MTIMECMP_HI   32'h02004004  // mtimecmp high 32 bits
`define CLINT_MTIME_LO      32'h0200BFF8  // mtime low 32 bits
`define CLINT_MTIME_HI      32'h0200BFFC  // mtime high 32 bits

// PLIC (Platform Level Interrupt Controller) - Single source, single context
`define PLIC_BASE           32'h0C00_0000
`define PLIC_PRIORITY1      32'h0C000004  // Priority for source 1
`define PLIC_PENDING        32'h0C001000  // Pending bits
`define PLIC_ENABLE         32'h0C002000  // Enable bits for context 0
`define PLIC_THRESHOLD      32'h0C200000  // Priority threshold for context 0
`define PLIC_CLAIM_COMPLETE 32'h0C200004  // Claim/complete for context 0
