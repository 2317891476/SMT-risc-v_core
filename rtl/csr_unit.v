// =============================================================================
// Module : csr_unit
// Description:
//   CSR and privilege-state block for the single-hart SifangCore bring-up path.
//   This block keeps the existing M-mode CSR/MRET behavior and adds the first
//   Linux-critical S-mode state: supervisor CSR aliases, delegation registers,
//   SRET, satp exposure, and delegated interrupt/exception routing.
// =============================================================================
`include "define.v"

module csr_unit #(
    parameter HART_ID = 0
)(
    input  wire               clk,
    input  wire               rstn,

    input  wire               csr_valid,
    input  wire [11:0]        csr_addr,
    input  wire [2:0]         csr_op,
    input  wire [31:0]        csr_wdata,
    output reg  [31:0]        csr_rdata,

    input  wire               exc_valid,
    input  wire [31:0]        exc_cause,
    input  wire [31:0]        exc_pc,
    input  wire [31:0]        exc_tval,

    input  wire               mret_valid,
    input  wire               mret_commit,
    input  wire               sret_valid,
    input  wire               sret_commit,

    output wire               trap_enter,
    output wire [31:0]        trap_target,
    output wire               trap_return,
    output wire [31:0]        trap_return_target,
    output wire [31:0]        mepc_out,
    output wire [31:0]        sepc_out,

    output wire [31:0]        satp_out,
    output wire [1:0]         priv_mode_out,
    output wire               mstatus_mxr,
    output wire               mstatus_sum,
    output wire               mstatus_mprv,
    output wire [1:0]         mstatus_mpp_out,
    output wire               global_int_en,

    input  wire               instr_retired,
    input  wire               instr_retired_1,

    input  wire               hpm_branch_mispredict,
    input  wire               hpm_icache_miss,
    input  wire               hpm_dcache_miss,
    input  wire               hpm_l2_miss,
    input  wire               hpm_sb_stall,
    input  wire               hpm_issue_bubble,
    input  wire               hpm_rocc_busy,

    input  wire               ext_timer_irq,
    input  wire               ext_external_irq,
    input  wire               ext_supervisor_external_irq
);

localparam [1:0] PRIV_U = 2'b00;
localparam [1:0] PRIV_S = 2'b01;
localparam [1:0] PRIV_M = 2'b11;

localparam integer CSR_MSTATUS = 12'h300;
localparam integer CSR_MISA    = 12'h301;
localparam integer CSR_MEDELEG = 12'h302;
localparam integer CSR_MIDELEG = 12'h303;
localparam integer CSR_MIE     = 12'h304;
localparam integer CSR_MTVEC   = 12'h305;
localparam integer CSR_MCOUNTEREN = 12'h306;
localparam integer CSR_MSCRATCH = 12'h340;
localparam integer CSR_MEPC    = 12'h341;
localparam integer CSR_MCAUSE  = 12'h342;
localparam integer CSR_MTVAL   = 12'h343;
localparam integer CSR_MIP     = 12'h344;

localparam integer CSR_SSTATUS = 12'h100;
localparam integer CSR_SIE     = 12'h104;
localparam integer CSR_STVEC   = 12'h105;
localparam integer CSR_SCOUNTEREN = 12'h106;
localparam integer CSR_SSCRATCH = 12'h140;
localparam integer CSR_SEPC    = 12'h141;
localparam integer CSR_SCAUSE  = 12'h142;
localparam integer CSR_STVAL   = 12'h143;
localparam integer CSR_SIP     = 12'h144;
localparam integer CSR_SATP    = 12'h180;

localparam [31:0] MSTATUS_SIE  = 32'h0000_0002;
localparam [31:0] MSTATUS_MIE  = 32'h0000_0008;
localparam [31:0] MSTATUS_SPIE = 32'h0000_0020;
localparam [31:0] MSTATUS_MPIE = 32'h0000_0080;
localparam [31:0] MSTATUS_SPP  = 32'h0000_0100;
localparam [31:0] MSTATUS_MPP  = 32'h0000_1800;
localparam [31:0] MSTATUS_SUM  = 32'h0004_0000;
localparam [31:0] MSTATUS_MXR  = 32'h0008_0000;
localparam [31:0] SSTATUS_MASK = MSTATUS_SIE | MSTATUS_SPIE | MSTATUS_SPP |
                                  MSTATUS_SUM | MSTATUS_MXR;
localparam [31:0] SIE_MASK     = 32'h0000_0222; // SSIE, STIE, SEIE
localparam [31:0] MIE_MASK     = 32'h0000_0AAA; // S/M software, timer, external
localparam [31:0] MIP_WR_MASK  = 32'h0000_0222; // OpenSBI can inject supervisor IRQs
localparam [31:0] MISA_VALUE   = 32'h4000_1101; // RV32IMA

reg [31:0] mstatus;
reg [31:0] mie;
reg [31:0] mtvec;
reg [31:0] mscratch;
reg [31:0] mepc;
reg [31:0] mcause;
reg [31:0] mtval;
reg [31:0] mip;
reg [31:0] medeleg;
reg [31:0] mideleg;
reg [31:0] mcounteren;

reg [31:0] stvec;
reg [31:0] sscratch;
reg [31:0] sepc;
reg [31:0] scause;
reg [31:0] stval;
reg [31:0] scounteren;
reg [31:0] satp;

reg [63:0] mcycle;
reg [63:0] minstret;
reg [63:0] mhpmcounter3;
reg [63:0] mhpmcounter4;
reg [63:0] mhpmcounter5;
reg [63:0] mhpmcounter6;
reg [63:0] mhpmcounter7;
reg [63:0] mhpmcounter8;
reg [63:0] mhpmcounter9;

reg [1:0]  priv_mode;

wire mstatus_sie = mstatus[1];
wire mstatus_mie = mstatus[3];
wire mstatus_spie = mstatus[5];
wire mstatus_mpie = mstatus[7];
wire mstatus_spp = mstatus[8];
wire [1:0] mstatus_mpp = mstatus[12:11];

wire [31:0] mip_effective = (mip & ~(32'h0000_0A80)) |
                            (ext_timer_irq ? 32'h0000_0080 : 32'd0) |
                            (ext_supervisor_external_irq ? 32'h0000_0200 : 32'd0) |
                            (ext_external_irq ? 32'h0000_0800 : 32'd0);
wire [31:0] pending_enabled = mip_effective & mie;
wire [31:0] pending_m_irq = pending_enabled & ~mideleg;
wire [31:0] pending_s_irq = pending_enabled & mideleg & SIE_MASK;

wire m_irq_global_en = (priv_mode != PRIV_M) || mstatus_mie;
wire s_irq_global_en = (priv_mode == PRIV_U) || ((priv_mode == PRIV_S) && mstatus_sie);

wire take_m_ext   = m_irq_global_en && pending_m_irq[11];
wire take_m_timer = m_irq_global_en && !take_m_ext && pending_m_irq[7];
wire take_m_soft  = m_irq_global_en && !take_m_ext && !take_m_timer && pending_m_irq[3];
wire take_s_ext   = s_irq_global_en && pending_s_irq[9];
wire take_s_timer = s_irq_global_en && !take_s_ext && pending_s_irq[5];
wire take_s_soft  = s_irq_global_en && !take_s_ext && !take_s_timer && pending_s_irq[1];

wire take_m_irq = take_m_ext || take_m_timer || take_m_soft;
wire take_s_irq = !take_m_irq && (take_s_ext || take_s_timer || take_s_soft);
wire irq_valid = take_m_irq || take_s_irq;

wire [31:0] irq_cause =
    take_m_ext   ? 32'h8000_000B :
    take_m_timer ? 32'h8000_0007 :
    take_m_soft  ? 32'h8000_0003 :
    take_s_ext   ? 32'h8000_0009 :
    take_s_timer ? 32'h8000_0005 :
    take_s_soft  ? 32'h8000_0001 :
                   32'd0;

wire exc_delegated = exc_valid && (priv_mode != PRIV_M) &&
                     (exc_cause[31] == 1'b0) &&
                     medeleg[exc_cause[4:0]];
wire trap_to_s = take_s_irq || exc_delegated;

assign trap_enter = exc_valid || irq_valid;
assign trap_target = trap_to_s ? {stvec[31:2], 2'b00} :
                                  {mtvec[31:2], 2'b00};
assign trap_return = mret_valid || sret_valid;
assign trap_return_target = sret_valid ? sepc : mepc;
assign mepc_out = mepc;
assign sepc_out = sepc;
assign satp_out = satp;
assign priv_mode_out = priv_mode;
assign mstatus_mxr = mstatus[19];
assign mstatus_sum = mstatus[18];
assign mstatus_mprv = mstatus[17];
assign mstatus_mpp_out = mstatus_mpp;
assign global_int_en = mstatus_mie;

reg        csr_write_pending;
reg [11:0] csr_write_addr;
reg [31:0] csr_write_value;
reg [31:0] csr_wval;

wire [31:0] sstatus_value = mstatus & SSTATUS_MASK;
wire [31:0] sie_value = mie & SIE_MASK;
wire [31:0] sip_value = mip_effective & SIE_MASK;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        csr_write_pending <= 1'b0;
        csr_write_addr    <= 12'd0;
        csr_write_value   <= 32'd0;
    end else begin
        csr_write_pending <= csr_valid;
        csr_write_addr    <= csr_addr;
        csr_write_value   <= csr_wval;
    end
end

always @(*) begin
    csr_rdata = 32'd0;
    if (csr_write_pending && (csr_addr == csr_write_addr)) begin
        csr_rdata = csr_write_value;
    end else begin
        case (csr_addr)
            12'hF11: csr_rdata = 32'd0;
            12'hF12: csr_rdata = 32'd0;
            12'hF13: csr_rdata = 32'd0;
            12'hF14: csr_rdata = HART_ID;
            CSR_MSTATUS: csr_rdata = mstatus;
            CSR_MISA:    csr_rdata = MISA_VALUE;
            CSR_MEDELEG: csr_rdata = medeleg;
            CSR_MIDELEG: csr_rdata = mideleg;
            CSR_MIE:     csr_rdata = mie;
            CSR_MTVEC:   csr_rdata = mtvec;
            CSR_MCOUNTEREN: csr_rdata = mcounteren;
            CSR_MSCRATCH: csr_rdata = mscratch;
            CSR_MEPC:    csr_rdata = mepc;
            CSR_MCAUSE:  csr_rdata = mcause;
            CSR_MTVAL:   csr_rdata = mtval;
            CSR_MIP:     csr_rdata = mip_effective;
            CSR_SSTATUS: csr_rdata = sstatus_value;
            CSR_SIE:     csr_rdata = sie_value;
            CSR_STVEC:   csr_rdata = stvec;
            CSR_SCOUNTEREN: csr_rdata = scounteren;
            CSR_SSCRATCH: csr_rdata = sscratch;
            CSR_SEPC:    csr_rdata = sepc;
            CSR_SCAUSE:  csr_rdata = scause;
            CSR_STVAL:   csr_rdata = stval;
            CSR_SIP:     csr_rdata = sip_value;
            CSR_SATP:    csr_rdata = satp;
            12'hB00: csr_rdata = mcycle[31:0];
            12'hB80: csr_rdata = mcycle[63:32];
            12'hB02: csr_rdata = minstret[31:0];
            12'hB82: csr_rdata = minstret[63:32];
            12'hB03: csr_rdata = mhpmcounter3[31:0];
            12'hB83: csr_rdata = mhpmcounter3[63:32];
            12'hB04: csr_rdata = mhpmcounter4[31:0];
            12'hB84: csr_rdata = mhpmcounter4[63:32];
            12'hB05: csr_rdata = mhpmcounter5[31:0];
            12'hB85: csr_rdata = mhpmcounter5[63:32];
            12'hB06: csr_rdata = mhpmcounter6[31:0];
            12'hB86: csr_rdata = mhpmcounter6[63:32];
            12'hB07: csr_rdata = mhpmcounter7[31:0];
            12'hB87: csr_rdata = mhpmcounter7[63:32];
            12'hB08: csr_rdata = mhpmcounter8[31:0];
            12'hB88: csr_rdata = mhpmcounter8[63:32];
            12'hB09: csr_rdata = mhpmcounter9[31:0];
            12'hB89: csr_rdata = mhpmcounter9[63:32];
            12'hC00: csr_rdata = mcycle[31:0];
            12'hC80: csr_rdata = mcycle[63:32];
            12'hC02: csr_rdata = minstret[31:0];
            12'hC82: csr_rdata = minstret[63:32];
            12'hC03: csr_rdata = mhpmcounter3[31:0];
            12'hC83: csr_rdata = mhpmcounter3[63:32];
            12'hC04: csr_rdata = mhpmcounter4[31:0];
            12'hC84: csr_rdata = mhpmcounter4[63:32];
            12'hC05: csr_rdata = mhpmcounter5[31:0];
            12'hC85: csr_rdata = mhpmcounter5[63:32];
            12'hC06: csr_rdata = mhpmcounter6[31:0];
            12'hC86: csr_rdata = mhpmcounter6[63:32];
            12'hC07: csr_rdata = mhpmcounter7[31:0];
            12'hC87: csr_rdata = mhpmcounter7[63:32];
            12'hC08: csr_rdata = mhpmcounter8[31:0];
            12'hC88: csr_rdata = mhpmcounter8[63:32];
            12'hC09: csr_rdata = mhpmcounter9[31:0];
            12'hC89: csr_rdata = mhpmcounter9[63:32];
            default: csr_rdata = 32'd0;
        endcase
    end
end

always @(*) begin
    case (csr_op)
        3'b001: csr_wval = csr_wdata;
        3'b010: csr_wval = csr_rdata | csr_wdata;
        3'b011: csr_wval = csr_rdata & ~csr_wdata;
        3'b101: csr_wval = csr_wdata;
        3'b110: csr_wval = csr_rdata | csr_wdata;
        3'b111: csr_wval = csr_rdata & ~csr_wdata;
        default: csr_wval = csr_wdata;
    endcase
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        mstatus   <= 32'h0000_1800;
        mie       <= 32'd0;
        mtvec     <= 32'd0;
        mscratch  <= 32'd0;
        mepc      <= 32'd0;
        mcause    <= 32'd0;
        mtval     <= 32'd0;
        mip       <= 32'd0;
        medeleg   <= 32'd0;
        mideleg   <= 32'd0;
        mcounteren <= 32'd0;
        stvec     <= 32'd0;
        sscratch  <= 32'd0;
        sepc      <= 32'd0;
        scause    <= 32'd0;
        stval     <= 32'd0;
        scounteren <= 32'd0;
        satp      <= 32'd0;
        mcycle    <= 64'd0;
        minstret  <= 64'd0;
        mhpmcounter3 <= 64'd0;
        mhpmcounter4 <= 64'd0;
        mhpmcounter5 <= 64'd0;
        mhpmcounter6 <= 64'd0;
        mhpmcounter7 <= 64'd0;
        mhpmcounter8 <= 64'd0;
        mhpmcounter9 <= 64'd0;
        priv_mode <= PRIV_M;
    end else begin
        mcycle <= mcycle + 64'd1;
        minstret <= minstret + {63'd0, instr_retired} + {63'd0, instr_retired_1};
        mhpmcounter3 <= mhpmcounter3 + {63'd0, hpm_branch_mispredict};
        mhpmcounter4 <= mhpmcounter4 + {63'd0, hpm_icache_miss};
        mhpmcounter5 <= mhpmcounter5 + {63'd0, hpm_dcache_miss};
        mhpmcounter6 <= mhpmcounter6 + {63'd0, hpm_l2_miss};
        mhpmcounter7 <= mhpmcounter7 + {63'd0, hpm_sb_stall};
        mhpmcounter8 <= mhpmcounter8 + {63'd0, hpm_issue_bubble};
        mhpmcounter9 <= mhpmcounter9 + {63'd0, hpm_rocc_busy};

        mip[7]  <= ext_timer_irq;
        mip[9]  <= ext_supervisor_external_irq;
        mip[11] <= ext_external_irq;

        if (trap_enter) begin
            if (trap_to_s) begin
                sepc   <= exc_pc;
                scause <= irq_valid ? irq_cause : exc_cause;
                stval  <= irq_valid ? 32'd0 : exc_tval;
                mstatus[5] <= mstatus[1];          // SPIE = SIE
                mstatus[1] <= 1'b0;                // SIE = 0
                mstatus[8] <= (priv_mode == PRIV_S); // SPP
                priv_mode  <= PRIV_S;
            end else begin
                mepc   <= exc_pc;
                mcause <= irq_valid ? irq_cause : exc_cause;
                mtval  <= irq_valid ? 32'd0 : exc_tval;
                mstatus[7]     <= mstatus[3];      // MPIE = MIE
                mstatus[3]     <= 1'b0;            // MIE = 0
                mstatus[12:11] <= priv_mode;       // MPP
                priv_mode      <= PRIV_M;
            end
        end else if (csr_valid) begin
            case (csr_addr)
                CSR_MSTATUS: mstatus <= csr_wval;
                CSR_MEDELEG: medeleg <= csr_wval;
                CSR_MIDELEG: mideleg <= csr_wval & MIE_MASK;
                CSR_MIE:     mie <= csr_wval & MIE_MASK;
                CSR_MTVEC:   mtvec <= {csr_wval[31:2], 2'b00};
                CSR_MCOUNTEREN: mcounteren <= csr_wval;
                CSR_MSCRATCH: mscratch <= csr_wval;
                CSR_MEPC:    mepc <= {csr_wval[31:1], 1'b0};
                CSR_MCAUSE:  mcause <= csr_wval;
                CSR_MTVAL:   mtval <= csr_wval;
                CSR_MIP:     mip <= (mip & ~MIP_WR_MASK) | (csr_wval & MIP_WR_MASK);
                CSR_SSTATUS: mstatus <= (mstatus & ~SSTATUS_MASK) | (csr_wval & SSTATUS_MASK);
                CSR_SIE:     mie <= (mie & ~SIE_MASK) | (csr_wval & SIE_MASK);
                CSR_STVEC:   stvec <= {csr_wval[31:2], 2'b00};
                CSR_SCOUNTEREN: scounteren <= csr_wval;
                CSR_SSCRATCH: sscratch <= csr_wval;
                CSR_SEPC:    sepc <= {csr_wval[31:1], 1'b0};
                CSR_SCAUSE:  scause <= csr_wval;
                CSR_STVAL:   stval <= csr_wval;
                CSR_SIP:     mip <= (mip & ~SIE_MASK) | (csr_wval & SIE_MASK);
                CSR_SATP:    satp <= csr_wval;
                12'hB00: mcycle[31:0] <= csr_wval;
                12'hB80: mcycle[63:32] <= csr_wval;
                12'hB02: minstret[31:0] <= csr_wval;
                12'hB82: minstret[63:32] <= csr_wval;
                default: ;
            endcase
        end

        if (mret_commit && !trap_enter) begin
            mstatus[3]     <= mstatus[7];
            mstatus[7]     <= 1'b1;
            priv_mode      <= mstatus_mpp;
            mstatus[12:11] <= PRIV_U;
        end
        if (sret_commit && !trap_enter) begin
            mstatus[1] <= mstatus[5];
            mstatus[5] <= 1'b1;
            priv_mode  <= mstatus_spp ? PRIV_S : PRIV_U;
            mstatus[8] <= 1'b0;
        end
    end
end

endmodule
