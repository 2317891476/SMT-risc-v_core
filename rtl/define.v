//-------------------inst_type-------------------
`define ItypeL 7'b0000011 //Itype for Load
`define ItypeA 7'b0010011 //Itype for ALU
`define ItypeJ 7'b1100111 //Itype for Jalr
`define Rtype  7'b0110011
`define Btype  7'b1100011
`define Stype  7'b0100011
`define UtypeL 7'b0110111 //Utype for lui
`define UtypeU 7'b0010111 //Utype for auipc
`define Jtype  7'b1101111 //Utype for jal
`define SYSTEM 7'b1110011 // SYSTEM opcode for CSR/MRET
 
 
//-------------------ALU_MODE------------------
`define ADD    4'd0 
`define SUB    4'd1 
`define SLL    4'd2 
`define SRL    4'd3 
`define SRA    4'd4 
`define SLT    4'd5 
`define SLTU   4'd6 
`define AND    4'd7 
`define OR     4'd8
`define XOR    4'd9 
`define NOTEQ  4'd10 // NOT equel
`define SGE    4'd11   // set greater than
`define SGEU   4'd12  // set greater than unsigned
`define JUMP   4'd13   // FOR JAL,JALR

//-------------------Itype_Func3----------------
`define I_ADDI  3'b000
`define I_JALR  3'b000
`define I_SLLI  3'b001
`define I_SLTI  3'b010 
`define I_SLTIU 3'b011
`define I_XORI  3'b100  
`define I_SRLI  3'b101
`define I_SRAI  3'b101 
`define I_ORI   3'b110
`define I_ANDI  3'b111 

//-------------------Rtype_Func3----------------
`define R_ADD  4'b0000 
`define R_SUB  4'b0001 
`define R_SLL  4'b0010
`define R_SLT  4'b0100 
`define R_SLTU 4'b0110
`define R_XOR  4'b1000  
`define R_SRL  4'b1010
`define R_SRA  4'b1011 
`define R_OR   4'b1100
`define R_AND  4'b1110 

//-------------------Btype_Func3----------------
`define B_BEQ   3'b000 
`define B_BNE   3'b001
`define B_BLT   3'b100 
`define B_BGE   3'b101
`define B_BLTU  3'b110  
`define B_BGEU  3'b111

//-------------------forwarding--------------------
`define ID_EX_A   2'b00
`define EX_MEM_A  2'b10
`define MEM_WB_A  2'b01
`define ID_EX_B   2'b00
`define EX_MEM_B  2'b10
`define MEM_WB_B  2'b01

//-------------------EX STAGE control----------------
`define IMM         2'b01
`define PC_PLUS4    2'b10
`define REG         2'b00

`define PC          2'b10
`define NULL        2'b01

`define J_REG         2'b0
`define B_PC          2'b1

//------------------MEM STAGE control-----------------
`define LB  3'b000
`define LH  3'b001
`define LW  3'b010
`define LBU 3'b100
`define LHU 3'b101
`define SB  2'b00
`define SH  2'b01
`define SW  2'b10

// =============================================================================
// Extended defines for the upgraded AdamRISCV micro-architecture
// Dual-issue, MMU, AI accel constants
// =============================================================================

// ─── Functional Unit Types (extended for dual-issue) ────────────────────────
`define FU_NOP     3'd0
`define FU_INT0    3'd1   // Integer pipe 0 (ADD/SUB/shifts/logic)
`define FU_INT1    3'd2   // Integer pipe 1 (same ops, second port)
`define FU_MUL     3'd3   // Multiplier (3-cycle latency)
`define FU_LOAD    3'd6   // Load unit
`define FU_STORE   3'd7   // Store unit

// ─── Issue Port Assignment ──────────────────────────────────────────────────
`define ISS_PORT0  1'b0   // ALU Pipe 0 (INT + Branch)
`define ISS_PORT1  1'b1   // ALU Pipe 1 (INT + MUL + MEM)

// ─── Scoreboard Constants ────────────────────────────────────────────────
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

// ─── RoCC DMA/GEMM Contract Constants ─────────────────────────────────────
`define ROCC_GEMM_SIZE     8
`define ROCC_GEMM_TILE_BYTES  256
`define ROCC_STATUS_BUSY   0
`define ROCC_STATUS_DONE   1
`define ROCC_STATUS_ERROR  2

// ─── RoCC DMA Address Constraints ────────────────────────────────────────────
`define ROCC_DMA_ADDR_MIN  32'h0000_0000
`define ROCC_DMA_ADDR_MAX  32'h0000_3FFF

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
`define METADATA_EPOCH_W   8
`define METADATA_ORDER_ID_W 16

// ════════════════════════════════════════════════════════════════════════════
// MMIO Address Map Constants
// ════════════════════════════════════════════════════════════════════════════

// Cacheable RAM window (first 16KB)
`define RAM_CACHEABLE_BASE  32'h0000_0000
`define RAM_CACHEABLE_TOP   32'h0000_3FFF

// TUBE MMIO (test completion marker)
`define TUBE_ADDR           32'h1300_0000
`define UART_TXDATA_ADDR    32'h1300_0010
`define UART_STATUS_ADDR    32'h1300_0014
`define UART_RXDATA_ADDR    32'h1300_0018
`define UART_CTRL_ADDR      32'h1300_001C
`define DDR3_STATUS_ADDR    32'h1300_0020
`define DEBUG_BEACON_EVT_ADDR 32'h1300_0024

// CLINT (Core Local Interruptor) - Machine Timer
`define CLINT_BASE          32'h0200_0000
`define CLINT_MTIMECMP_LO   32'h02004000
`define CLINT_MTIMECMP_HI   32'h02004004
`define CLINT_MTIME_LO      32'h0200BFF8
`define CLINT_MTIME_HI      32'h0200BFFC

// PLIC (Platform Level Interrupt Controller)
`define PLIC_BASE           32'h0C00_0000
`define PLIC_PRIORITY1      32'h0C000004
`define PLIC_PENDING        32'h0C001000
`define PLIC_ENABLE         32'h0C002000
`define PLIC_THRESHOLD      32'h0C200000
`define PLIC_CLAIM_COMPLETE 32'h0C200004

// DDR3 SDRAM (external, active when ENABLE_DDR3)
`define DDR3_BASE           32'h8000_0000
`define DDR3_TOP            32'hBFFF_FFFF
