// =============================================================================
// Module : plic
// Description: Platform Level Interrupt Controller (PLIC) for RISC-V
//   Single source (ID=1), single context (M-mode Hart 0) implementation.
//   
//   Supports:
//   - Priority register per source (source 1)
//   - Pending bits per source
//   - Enable bits per context
//   - Priority threshold per context
//   - Claim/Complete mechanism
//   
//   Memory Map (from define_v2.v):
//   - Priority[1]: 0x0C00_0004 (source 1 priority)
//   - Pending:     0x0C00_1000 (pending bits)
//   - Enable[0]:   0x0C00_2000 (context 0 enable)
//   - Threshold:   0x0C20_0000 (context 0 threshold)
//   - Claim/Comp:  0x0C20_0004 (context 0 claim/complete)
// =============================================================================
`include "define_v2.v"

module plic (
    input  wire        clk,
    input  wire        rstn,

    // Memory-mapped register interface
    input  wire        req_valid,
    input  wire [31:0] req_addr,
    input  wire        req_wen,
    input  wire [31:0] req_wdata,
    output reg  [31:0] resp_rdata,
    output reg         resp_valid,

    // External interrupt input (from devices)
    input  wire        ext_irq_src,    // External interrupt source (ID=1)

    // External interrupt output (to CSR mip.MEIP)
    output wire        external_irq
);

// ─── Configuration ──────────────────────────────────────────────────────────
localparam NUM_SOURCES = 1;   // Only source 1
localparam NUM_CONTEXTS = 1;  // Only context 0 (M-mode hart 0)

// ─── Registers ───────────────────────────────────────────────────────────────
// Priority[1]: 32-bit register for source 1 (0 = disabled)
reg [31:0] source_priority [1:NUM_SOURCES];

// Pending[1]: 1 bit per source
reg pending [1:NUM_SOURCES];

// Enable[context][source]: enable bit per context per source
reg enable [0:NUM_CONTEXTS-1] [1:NUM_SOURCES];

// Threshold[context]: priority threshold per context
reg [31:0] threshold [0:NUM_CONTEXTS-1];

// Claimed[context][source]: track which interrupts have been claimed
reg claimed [0:NUM_CONTEXTS-1] [1:NUM_SOURCES];

// ─── Address decode ─────────────────────────────────────────────────────────
wire [31:0] base_addr = req_addr - `PLIC_BASE;

wire addr_priority1   = (req_addr == `PLIC_PRIORITY1);
wire addr_pending     = (req_addr == `PLIC_PENDING);
wire addr_enable      = (req_addr == `PLIC_ENABLE);
wire addr_threshold   = (req_addr == `PLIC_THRESHOLD);
wire addr_claim       = (req_addr == `PLIC_CLAIM_COMPLETE);

// ─── Interrupt logic ────────────────────────────────────────────────────────
// External interrupt is asserted when:
// 1. Source has pending interrupt
// 2. Source is enabled for context 0
// 3. Source priority > threshold
// 4. Interrupt not already claimed

wire source_active = pending[1] && enable[0][1] && 
                     (source_priority[1] > threshold[0]) && 
                     !claimed[0][1];
assign external_irq = source_active;

// ─── Sequential logic ───────────────────────────────────────────────────────
integer i, j;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        // Initialize all registers
            for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
                source_priority[i] <= 32'd0;
            pending[i]  <= 1'b0;
        end
        for (i = 0; i < NUM_CONTEXTS; i = i + 1) begin
            threshold[i] <= 32'd0;
            for (j = 1; j <= NUM_SOURCES; j = j + 1) begin
                enable[i][j] <= 1'b0;
                claimed[i][j] <= 1'b0;
            end
        end
        resp_valid <= 1'b0;
        resp_rdata <= 32'd0;
    end else begin
        // Update pending from external source
        // Pending is set by external interrupt, cleared by claim
        if (ext_irq_src && !claimed[0][1]) begin
            pending[1] <= 1'b1;
        end

        // Handle register access
        resp_valid <= req_valid;
        
        if (req_valid) begin
            if (req_wen) begin
                // Write access
                case (1'b1)
                    addr_priority1: begin
                        source_priority[1] <= req_wdata;
                    end
                    addr_enable: begin
                        enable[0][1] <= req_wdata[1];  // bit 1 for source 1
                    end
                    addr_threshold: begin
                        threshold[0] <= req_wdata;
                    end
                    addr_claim: begin
                        // Complete: write source ID to complete
                        if (req_wdata == 32'd1) begin
                            // Complete source 1
                            pending[1]   <= 1'b0;     // Clear pending
                            claimed[0][1] <= 1'b0;    // Clear claimed
                        end
                    end
                    default: ;
                endcase
                resp_rdata <= 32'd0;
            end else begin
                // Read access
                case (1'b1)
                    addr_priority1: begin
                        resp_rdata <= source_priority[1];
                    end
                    addr_pending: begin
                        resp_rdata <= {31'd0, pending[1]};
                    end
                    addr_enable: begin
                        resp_rdata <= {31'd0, enable[0][1]};
                    end
                    addr_threshold: begin
                        resp_rdata <= threshold[0];
                    end
                    addr_claim: begin
                        // Claim: return highest priority pending interrupt ID
                        if (source_active) begin
                            resp_rdata <= 32'd1;  // Source 1
                            claimed[0][1] <= 1'b1; // Mark as claimed
                        end else begin
                            resp_rdata <= 32'd0;  // No interrupt
                        end
                    end
                    default: resp_rdata <= 32'd0;
                endcase
            end
        end
    end
end

endmodule
