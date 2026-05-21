// =============================================================================
// Module : plic
// Description: Two-source, single-context Platform Level Interrupt Controller.
//
// Source IDs:
//   1 - existing external interrupt input
//   2 - UART 16550 interrupt
//
// Compatibility note:
//   Existing basic tests observe source 1 in PLIC_PENDING bit 0 while enabling
//   it through PLIC_ENABLE bit 1. Keep that legacy pending encoding and add
//   source 2 at bit 2.
// =============================================================================
`include "define.v"

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
    output wire [31:0] read_data,

    // External interrupt inputs
    input  wire        ext_irq_src,     // source ID 1
    input  wire        uart_irq_src,    // source ID 2

    // External interrupt output (to CSR mip.MEIP)
    output wire        external_irq
);

localparam NUM_SOURCES = 2;

reg [31:0] source_priority [1:NUM_SOURCES];
reg        pending         [1:NUM_SOURCES];
reg        enable          [1:NUM_SOURCES];
reg [31:0] threshold;
reg        claimed         [1:NUM_SOURCES];

wire addr_priority1 = (req_addr == `PLIC_PRIORITY1);
wire addr_priority2 = (req_addr == `PLIC_PRIORITY2);
wire addr_pending   = (req_addr == `PLIC_PENDING);
wire addr_enable    = (req_addr == `PLIC_ENABLE);
wire addr_threshold = (req_addr == `PLIC_THRESHOLD);
wire addr_claim     = (req_addr == `PLIC_CLAIM_COMPLETE);

wire source1_active = pending[1] && enable[1] && (source_priority[1] > threshold) && !claimed[1];
wire source2_active = pending[2] && enable[2] && (source_priority[2] > threshold) && !claimed[2];
wire source1_wins   = source1_active && (!source2_active || (source_priority[1] >= source_priority[2]));
wire source2_wins   = source2_active && !source1_wins;
wire [31:0] claim_id = source1_wins ? 32'd1 :
                       source2_wins ? 32'd2 :
                       32'd0;

assign external_irq = source1_active || source2_active;

assign read_data =
    addr_priority1 ? source_priority[1] :
    addr_priority2 ? source_priority[2] :
    addr_pending   ? {29'd0, pending[2], 1'b0, pending[1]} :
    addr_enable    ? {29'd0, enable[2], enable[1], 1'b0} :
    addr_threshold ? threshold :
    addr_claim     ? claim_id :
    32'd0;

integer i;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
            source_priority[i] <= 32'd0;
            pending[i]         <= 1'b0;
            enable[i]          <= 1'b0;
            claimed[i]         <= 1'b0;
        end
        threshold  <= 32'd0;
        resp_valid <= 1'b0;
        resp_rdata <= 32'd0;
    end else begin
        if (ext_irq_src && !claimed[1]) begin
            pending[1] <= 1'b1;
        end
        if (uart_irq_src && !claimed[2]) begin
            pending[2] <= 1'b1;
        end

        resp_valid <= req_valid;

        if (req_valid) begin
            if (req_wen) begin
                case (1'b1)
                    addr_priority1: source_priority[1] <= req_wdata;
                    addr_priority2: source_priority[2] <= req_wdata;
                    addr_enable: begin
                        enable[1] <= req_wdata[1];
                        enable[2] <= req_wdata[2];
                    end
                    addr_threshold: threshold <= req_wdata;
                    addr_claim: begin
                        if (req_wdata == 32'd1) begin
                            pending[1] <= 1'b0;
                            claimed[1] <= 1'b0;
                        end else if (req_wdata == 32'd2) begin
                            pending[2] <= 1'b0;
                            claimed[2] <= 1'b0;
                        end
                    end
                    default: ;
                endcase
                resp_rdata <= 32'd0;
            end else begin
                resp_rdata <= read_data;
                if (addr_claim && (claim_id != 32'd0)) begin
                    claimed[claim_id[1:0]] <= 1'b1;
                    pending[claim_id[1:0]] <= 1'b0;
                end
            end
        end
    end
end

endmodule
