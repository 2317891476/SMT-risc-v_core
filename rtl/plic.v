// =============================================================================
// Module : plic
// Description: Two-source, two-context Platform Level Interrupt Controller.
//
// Source IDs:
//   1 - existing external interrupt input
//   2 - UART 16550 interrupt
//
// Contexts:
//   M-context uses the legacy PLIC_ENABLE/THRESHOLD/CLAIM addresses.
//   S-context uses PLIC_S_ENABLE/S_THRESHOLD/S_CLAIM addresses.
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

    // External interrupt outputs
    output wire        external_irq,
    output wire        supervisor_external_irq
);

localparam NUM_SOURCES = 2;

reg [31:0] source_priority [1:NUM_SOURCES];
reg        pending         [1:NUM_SOURCES];
reg        enable_m        [1:NUM_SOURCES];
reg        enable_s        [1:NUM_SOURCES];
reg [31:0] threshold_m;
reg [31:0] threshold_s;
reg        claimed_m       [1:NUM_SOURCES];
reg        claimed_s       [1:NUM_SOURCES];

wire addr_priority1 = (req_addr == `PLIC_PRIORITY1);
wire addr_priority2 = (req_addr == `PLIC_PRIORITY2);
wire addr_pending   = (req_addr == `PLIC_PENDING);
wire addr_enable_m  = (req_addr == `PLIC_ENABLE);
wire addr_enable_s  = (req_addr == `PLIC_S_ENABLE);
wire addr_threshold_m = (req_addr == `PLIC_THRESHOLD);
wire addr_threshold_s = (req_addr == `PLIC_S_THRESHOLD);
wire addr_claim_m   = (req_addr == `PLIC_CLAIM_COMPLETE);
wire addr_claim_s   = (req_addr == `PLIC_S_CLAIM_COMPLETE);

wire source1_active_m = pending[1] && enable_m[1] && (source_priority[1] > threshold_m) && !claimed_m[1];
wire source2_active_m = pending[2] && enable_m[2] && (source_priority[2] > threshold_m) && !claimed_m[2];
wire source1_wins_m   = source1_active_m && (!source2_active_m || (source_priority[1] >= source_priority[2]));
wire source2_wins_m   = source2_active_m && !source1_wins_m;
wire [31:0] claim_id_m = source1_wins_m ? 32'd1 :
                         source2_wins_m ? 32'd2 :
                         32'd0;

wire source1_active_s = pending[1] && enable_s[1] && (source_priority[1] > threshold_s) && !claimed_s[1];
wire source2_active_s = pending[2] && enable_s[2] && (source_priority[2] > threshold_s) && !claimed_s[2];
wire source1_wins_s   = source1_active_s && (!source2_active_s || (source_priority[1] >= source_priority[2]));
wire source2_wins_s   = source2_active_s && !source1_wins_s;
wire [31:0] claim_id_s = source1_wins_s ? 32'd1 :
                         source2_wins_s ? 32'd2 :
                         32'd0;

assign external_irq = source1_active_m || source2_active_m;
assign supervisor_external_irq = source1_active_s || source2_active_s;

assign read_data =
    addr_priority1 ? source_priority[1] :
    addr_priority2 ? source_priority[2] :
    addr_pending   ? {29'd0, pending[2], 1'b0, pending[1]} :
    addr_enable_m  ? {29'd0, enable_m[2], enable_m[1], 1'b0} :
    addr_enable_s  ? {29'd0, enable_s[2], enable_s[1], 1'b0} :
    addr_threshold_m ? threshold_m :
    addr_threshold_s ? threshold_s :
    addr_claim_m   ? claim_id_m :
    addr_claim_s   ? claim_id_s :
    32'd0;

integer i;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
            source_priority[i] <= 32'd0;
            pending[i]         <= 1'b0;
            enable_m[i]        <= 1'b0;
            enable_s[i]        <= 1'b0;
            claimed_m[i]       <= 1'b0;
            claimed_s[i]       <= 1'b0;
        end
        threshold_m <= 32'd0;
        threshold_s <= 32'd0;
        resp_valid <= 1'b0;
        resp_rdata <= 32'd0;
    end else begin
        if (ext_irq_src && !claimed_m[1] && !claimed_s[1]) begin
            pending[1] <= 1'b1;
        end
        if (uart_irq_src && !claimed_m[2] && !claimed_s[2]) begin
            pending[2] <= 1'b1;
        end

        resp_valid <= req_valid;

        if (req_valid) begin
            if (req_wen) begin
                case (1'b1)
                    addr_priority1: source_priority[1] <= req_wdata;
                    addr_priority2: source_priority[2] <= req_wdata;
                    addr_enable_m: begin
                        enable_m[1] <= req_wdata[1];
                        enable_m[2] <= req_wdata[2];
                    end
                    addr_enable_s: begin
                        enable_s[1] <= req_wdata[1];
                        enable_s[2] <= req_wdata[2];
                    end
                    addr_threshold_m: threshold_m <= req_wdata;
                    addr_threshold_s: threshold_s <= req_wdata;
                    addr_claim_m: begin
                        if (req_wdata == 32'd1) begin
                            pending[1] <= 1'b0;
                            claimed_m[1] <= 1'b0;
                        end else if (req_wdata == 32'd2) begin
                            pending[2] <= 1'b0;
                            claimed_m[2] <= 1'b0;
                        end
                    end
                    addr_claim_s: begin
                        if (req_wdata == 32'd1) begin
                            pending[1] <= 1'b0;
                            claimed_s[1] <= 1'b0;
                        end else if (req_wdata == 32'd2) begin
                            pending[2] <= 1'b0;
                            claimed_s[2] <= 1'b0;
                        end
                    end
                    default: ;
                endcase
                resp_rdata <= 32'd0;
            end else begin
                resp_rdata <= read_data;
                if (addr_claim_m && (claim_id_m != 32'd0)) begin
                    claimed_m[claim_id_m[1:0]] <= 1'b1;
                    pending[claim_id_m[1:0]] <= 1'b0;
                end else if (addr_claim_s && (claim_id_s != 32'd0)) begin
                    claimed_s[claim_id_s[1:0]] <= 1'b1;
                    pending[claim_id_s[1:0]] <= 1'b0;
                end
            end
        end
    end
end

endmodule
