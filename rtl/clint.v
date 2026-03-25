// =============================================================================
// Module : clint
// Description: Core Local Interruptor (CLINT) for RISC-V
//   Implements:
//   - mtime: 64-bit machine timer (increments every clock cycle)
//   - mtimecmp: 64-bit machine timer compare register
//   
//   When mtime >= mtimecmp, generates timer interrupt (MTIP)
//   
//   RV32 split-write safe sequence:
//   - Write high word first with temporary compare value
//   - Write low word (which may temporarily trigger interrupt)
//   - Write high word with final value (clears any spurious interrupt)
//   
//   Memory Map (from define_v2.v):
//   - mtimecmp lo: 0x0200_4000
//   - mtimecmp hi: 0x0200_4004
//   - mtime lo:    0x0200_BFF8
//   - mtime hi:    0x0200_BFFC
// =============================================================================
`include "define_v2.v"

module clint (
    input  wire        clk,
    input  wire        rstn,

    // Memory-mapped register interface
    input  wire        req_valid,
    input  wire [31:0] req_addr,
    input  wire        req_wen,
    input  wire [31:0] req_wdata,
    output reg  [31:0] resp_rdata,
    output reg         resp_valid,

    // Timer interrupt output (to CSR mip.MTIP)
    output wire        timer_irq
);

// ─── 64-bit timer counter ───────────────────────────────────────────────────
reg [63:0] mtime;
reg [63:0] mtimecmp;

// ─── Timer interrupt generation ─────────────────────────────────────────────
assign timer_irq = (mtime >= mtimecmp);

// ─── Address decode ─────────────────────────────────────────────────────────
wire addr_mtime_lo    = (req_addr == `CLINT_MTIME_LO);
wire addr_mtime_hi    = (req_addr == `CLINT_MTIME_HI);
wire addr_mtimecmp_lo = (req_addr == `CLINT_MTIMECMP_LO);
wire addr_mtimecmp_hi = (req_addr == `CLINT_MTIMECMP_HI);
wire addr_valid       = addr_mtime_lo || addr_mtime_hi || 
                         addr_mtimecmp_lo || addr_mtimecmp_hi;

// ─── Sequential logic ───────────────────────────────────────────────────────
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        mtime     <= 64'd0;
        mtimecmp  <= 64'hFFFFFFFFFFFFFFFF;  // Max value = no interrupt initially
        resp_valid <= 1'b0;
        resp_rdata <= 32'd0;
    end else begin
        // Increment mtime every cycle
        mtime <= mtime + 64'd1;

        // Handle register access
        resp_valid <= req_valid;
        
        if (req_valid) begin
            if (req_wen) begin
                // Write access
                case (1'b1)
                    addr_mtime_lo:    mtime[31:0]   <= req_wdata;
                    addr_mtime_hi:    mtime[63:32]  <= req_wdata;
                    addr_mtimecmp_lo: mtimecmp[31:0]  <= req_wdata;
                    addr_mtimecmp_hi: mtimecmp[63:32] <= req_wdata;
                endcase
                resp_rdata <= 32'd0;
            end else begin
                // Read access
                case (1'b1)
                    addr_mtime_lo:    resp_rdata <= mtime[31:0];
                    addr_mtime_hi:    resp_rdata <= mtime[63:32];
                    addr_mtimecmp_lo: resp_rdata <= mtimecmp[31:0];
                    addr_mtimecmp_hi: resp_rdata <= mtimecmp[63:32];
                    default:          resp_rdata <= 32'd0;
                endcase
            end
        end
    end
end

endmodule
