// =============================================================================
// Module : csr_unit
// Description: RISC-V Control and Status Register (CSR) unit.
//   Implements a subset of Machine-mode CSRs needed for basic exception
//   handling and virtual memory support (satp):
//
//   Supported CSRs:
//     Machine Information:
//       - mvendorid  (0xF11) — read-only 0
//       - marchid    (0xF12) — read-only 0
//       - mimpid     (0xF13) — read-only 0
//       - mhartid    (0xF14) — read-only, from parameter
//     Machine Trap Setup:
//       - mstatus    (0x300) — MIE, MPIE, MPP, MXR, SUM
//       - misa       (0x301) — read-only, RV32I
//       - mie        (0x304) — interrupt enable
//       - mtvec      (0x305) — trap vector base
//     Machine Trap Handling:
//       - mscratch   (0x340)
//       - mepc       (0x341) — exception PC
//       - mcause     (0x342) — exception cause
//       - mtval      (0x343) — exception value
//       - mip        (0x344) — interrupt pending
//     Machine Counters:
//       - mcycle     (0xB00) — cycle counter
//       - minstret   (0xB02) — instruction retired counter
//     Supervisor (for VM):
//       - satp       (0x180) — address translation mode + PPN
//
//   CSR instructions: CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI
//   Opcode: SYSTEM (7'b1110011), funct3 selects operation
// =============================================================================
`include "define.v"

module csr_unit #(
    parameter HART_ID = 0
)(
    input  wire               clk,
    input  wire               rstn,

    // ─── CSR Read/Write Request (from WB or dedicated CSR stage) ─
    input  wire               csr_valid,       // CSR instruction valid
    input  wire [11:0]        csr_addr,        // CSR address (12-bit)
    input  wire [2:0]         csr_op,          // funct3: 001=CSRRW,010=CSRRS,011=CSRRC
                                               //         101=CSRRWI,110=CSRRSI,111=CSRRCI
    input  wire [31:0]        csr_wdata,       // write data (rs1 value or zimm)
    output reg  [31:0]        csr_rdata,       // read data (to rd)

    // ─── Exception Interface ────────────────────────────────────
    input  wire               exc_valid,       // exception occurred
    input  wire [31:0]        exc_cause,       // exception cause code
    input  wire [31:0]        exc_pc,          // PC of faulting instruction
    input  wire [31:0]        exc_tval,        // trap value (e.g. faulting address)

    // ─── MRET ───────────────────────────────────────────────────
    input  wire               mret_valid,      // MRET instruction executed

    // ─── Trap Entry / Return signals (to pipeline control) ──────
    output wire               trap_enter,      // take trap this cycle
    output wire [31:0]        trap_target,     // where to redirect PC
    output wire               trap_return,     // returning from trap (MRET)
    output wire [31:0]        mepc_out,        // MEPC value for MRET return address

    // ─── Output CSRs to other modules ───────────────────────────
    output wire [31:0]        satp_out,        // to MMU
    output wire [1:0]         priv_mode_out,   // current privilege mode
    output wire               mstatus_mxr,     // MXR bit
    output wire               mstatus_sum,     // SUM bit
    output wire               global_int_en,   // MIE (global interrupt enable)

    // ─── Performance Counters ───────────────────────────────────
    input  wire               instr_retired,   // pulse: 1 instruction retired this cycle
    input  wire               instr_retired_1, // pulse: second instruction retired (dual-issue)

    // ─── External Interrupt Inputs ──────────────────────────────
    input  wire               ext_timer_irq,   // CLINT timer interrupt (MTIP)
    input  wire               ext_external_irq // PLIC external interrupt (MEIP)
);

// ─── CSR Storage ────────────────────────────────────────────────────────────
reg [31:0] mstatus;    // 0x300
reg [31:0] mie;        // 0x304
reg [31:0] mtvec;      // 0x305
reg [31:0] mscratch;   // 0x340
reg [31:0] mepc;       // 0x341
reg [31:0] mcause;     // 0x342
reg [31:0] mtval;      // 0x343
reg [31:0] mip;        // 0x344
reg [63:0] mcycle;     // 0xB00 (64-bit)
reg [63:0] minstret;   // 0xB02 (64-bit)
reg [31:0] satp;       // 0x180
reg [1:0]  priv_mode;  // current privilege: 2'b11=M, 2'b01=S, 2'b00=U

// ─── misa: fixed RV32I ──────────────────────────────────────────────────────
localparam [31:0] MISA = {2'b01,             // MXL = 32-bit
                          4'd0,              // reserved
                          26'b00000000000000000100000000}; // I extension (bit 8)

// ─── mstatus field positions ────────────────────────────────────────────────
// [3]=MIE, [7]=MPIE, [12:11]=MPP, [19]=MXR, [18]=SUM
wire mstatus_MIE  = mstatus[3];
wire mstatus_MPIE = mstatus[7];
wire [1:0] mstatus_MPP = mstatus[12:11];

// ─── Output wiring ─────────────────────────────────────────────────────────
assign satp_out      = satp;
assign priv_mode_out = priv_mode;
assign mstatus_mxr   = mstatus[19];
assign mstatus_sum   = mstatus[18];
assign global_int_en = mstatus_MIE;
assign mepc_out      = mepc;

// ─── Trap logic ─────────────────────────────────────────────────────────────
assign trap_enter  = exc_valid;
assign trap_target = {mtvec[31:2], 2'b00};  // Direct mode (MODE=0)
assign trap_return = mret_valid;

// ─── CSR Read (combinational) ───────────────────────────────────────────────
always @(*) begin
    csr_rdata = 32'd0;
    case (csr_addr)
        12'hF11: csr_rdata = 32'd0;              // mvendorid
        12'hF12: csr_rdata = 32'd0;              // marchid
        12'hF13: csr_rdata = 32'd0;              // mimpid
        12'hF14: csr_rdata = HART_ID;            // mhartid
        12'h300: csr_rdata = mstatus;            // mstatus
        12'h301: csr_rdata = MISA;               // misa (read-only)
        12'h304: csr_rdata = mie;                // mie
        12'h305: csr_rdata = mtvec;              // mtvec
        12'h340: csr_rdata = mscratch;           // mscratch
        12'h341: csr_rdata = mepc;               // mepc
        12'h342: csr_rdata = mcause;             // mcause
        12'h343: csr_rdata = mtval;              // mtval
        12'h344: csr_rdata = mip;                // mip
        12'hB00: csr_rdata = mcycle[31:0];       // mcycle
        12'hB80: csr_rdata = mcycle[63:32];      // mcycleh
        12'hB02: csr_rdata = minstret[31:0];     // minstret
        12'hB82: csr_rdata = minstret[63:32];    // minstreth
        12'h180: csr_rdata = satp;               // satp
        default: csr_rdata = 32'd0;
    endcase
end

// ─── CSR Write Logic ────────────────────────────────────────────────────────
reg [31:0] csr_wval;  // computed write value

always @(*) begin
    csr_wval = 32'd0;
    case (csr_op)
        3'b001: csr_wval = csr_wdata;                          // CSRRW
        3'b010: csr_wval = csr_rdata | csr_wdata;              // CSRRS
        3'b011: csr_wval = csr_rdata & ~csr_wdata;             // CSRRC
        3'b101: csr_wval = csr_wdata;                          // CSRRWI (zimm)
        3'b110: csr_wval = csr_rdata | csr_wdata;              // CSRRSI
        3'b111: csr_wval = csr_rdata & ~csr_wdata;             // CSRRCI
        default: csr_wval = csr_wdata;
    endcase
end

// ─── Sequential update ─────────────────────────────────────────────────────
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        mstatus   <= 32'h00001800;  // MPP=M-mode (2'b11)
        mie       <= 32'd0;
        mtvec     <= 32'd0;
        mscratch  <= 32'd0;
        mepc      <= 32'd0;
        mcause    <= 32'd0;
        mtval     <= 32'd0;
        mip       <= 32'd0;
        mcycle    <= 64'd0;
        minstret  <= 64'd0;
        satp      <= 32'd0;         // Bare mode (MODE=0)
        priv_mode <= 2'b11;         // Boot in Machine mode
    end
    else begin
        // ── Cycle counter (always runs) ─────────────────────────
        mcycle <= mcycle + 64'd1;

        // ── Instruction retired counter ─────────────────────────
        minstret <= minstret + {63'd0, instr_retired} + {63'd0, instr_retired_1};

        // ── Update mip from external interrupt sources ──────────
        // mip[7] = MTIP (timer interrupt pending)
        // mip[11] = MEIP (external interrupt pending)
        mip[7]  <= ext_timer_irq;
        mip[11] <= ext_external_irq;

        // ── Exception entry ─────────────────────────────────────
        if (exc_valid) begin
            mepc      <= exc_pc;
            mcause    <= exc_cause;
            mtval     <= exc_tval;
            // Save MIE to MPIE, clear MIE, save current mode to MPP
            mstatus[7]     <= mstatus[3];    // MPIE = MIE
            mstatus[3]     <= 1'b0;          // MIE = 0
            mstatus[12:11] <= priv_mode;     // MPP = current mode
            priv_mode      <= 2'b11;         // Enter M-mode
        end
        // ── MRET ────────────────────────────────────────────────
        else if (mret_valid) begin
            mstatus[3]     <= mstatus[7];    // MIE = MPIE
            mstatus[7]     <= 1'b1;          // MPIE = 1
            priv_mode      <= mstatus[12:11]; // mode = MPP
            mstatus[12:11] <= 2'b00;         // MPP = U-mode
        end
        // ── CSR write ───────────────────────────────────────────
        else if (csr_valid) begin
            case (csr_addr)
                12'h300: mstatus  <= csr_wval;
                12'h304: mie      <= csr_wval;
                12'h305: mtvec    <= csr_wval;
                12'h340: mscratch <= csr_wval;
                12'h341: mepc     <= csr_wval;
                12'h342: mcause   <= csr_wval;
                12'h343: mtval    <= csr_wval;
                12'hB00: mcycle[31:0]   <= csr_wval;
                12'hB80: mcycle[63:32]  <= csr_wval;
                12'hB02: minstret[31:0] <= csr_wval;
                12'hB82: minstret[63:32]<= csr_wval;
                12'h180: satp     <= csr_wval;
                default: ;  // read-only or unimplemented
            endcase
        end
    end
end

endmodule
