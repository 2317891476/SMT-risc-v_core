// =============================================================================
// Module : mmu_sv32
// Description: Sv32 MMU with separate I/D TLBs and a serialized hardware PTW.
//
// Notes for the Linux bring-up path:
//   - M-mode always bypasses translation; Sv32 applies to S/U modes.
//   - PTW uses a simple physical request/response port. It never recursively
//     translates page-table memory accesses.
//   - Leaf PTE A/D bits are updated in hardware before refilling the TLB.
//   - Fault outputs report RISC-V page-fault causes and the faulting vaddr.
// =============================================================================
module mmu_sv32 #(
    parameter ITLB_ENTRIES = 16,
    parameter DTLB_ENTRIES = 32
)(
    input  wire               clk,
    input  wire               rstn,

    // CSR state
    input  wire [31:0]        satp,           // [31]=MODE, [30:22]=ASID, [21:0]=PPN
    input  wire [1:0]         priv_mode,
    input  wire               mstatus_mxr,
    input  wire               mstatus_sum,

    // SFENCE.VMA. The first integrated core path uses full flushes, but the
    // TLB still accepts selective fields for later optimization.
    input  wire               sfence_valid,
    input  wire [31:0]        sfence_vaddr,
    input  wire [8:0]         sfence_asid,

    // I-side translation request
    input  wire               itlb_req_valid,
    input  wire [31:0]        itlb_req_vaddr,
    output wire               itlb_resp_hit,
    output wire [31:0]        itlb_resp_paddr,
    output wire               itlb_resp_fault,
    output wire [4:0]         itlb_resp_cause,
    output wire [31:0]        itlb_resp_tval,
    output wire               itlb_busy,

    // D-side translation request
    input  wire               dtlb_req_valid,
    input  wire [31:0]        dtlb_req_vaddr,
    input  wire               dtlb_req_store,
    output wire               dtlb_resp_hit,
    output wire [31:0]        dtlb_resp_paddr,
    output wire               dtlb_resp_fault,
    output wire [4:0]         dtlb_resp_cause,
    output wire [31:0]        dtlb_resp_tval,
    output wire               dtlb_busy,

    // Physical page-table walker port
    output reg                ptw_req_valid,
    input  wire               ptw_req_ready,
    output reg                ptw_req_write,
    output reg  [31:0]        ptw_req_addr,
    output reg  [31:0]        ptw_req_wdata,
    output reg  [3:0]         ptw_req_wen,
    input  wire               ptw_resp_valid,
    input  wire [31:0]        ptw_resp_rdata
);

localparam [1:0] PRIV_U = 2'b00;
localparam [1:0] PRIV_S = 2'b01;
localparam [1:0] PRIV_M = 2'b11;

localparam [4:0] CAUSE_INST_PAGE_FAULT  = 5'd12;
localparam [4:0] CAUSE_LOAD_PAGE_FAULT  = 5'd13;
localparam [4:0] CAUSE_STORE_PAGE_FAULT = 5'd15;

localparam [1:0] ACCESS_FETCH = 2'd0;
localparam [1:0] ACCESS_LOAD  = 2'd1;
localparam [1:0] ACCESS_STORE = 2'd2;

wire        vm_enabled = satp[31] && (priv_mode != PRIV_M);
wire [8:0]  satp_asid  = satp[30:22];
wire [21:0] satp_ppn   = satp[21:0];

// -----------------------------------------------------------------------------
// TLBs
// -----------------------------------------------------------------------------
wire        itlb_hit;
wire [21:0] itlb_ppn;
wire        itlb_is_mega;
wire [7:0]  itlb_perm;

wire        dtlb_hit;
wire [21:0] dtlb_ppn;
wire        dtlb_is_mega;
wire [7:0]  dtlb_perm;

reg         ptw_refill_valid;
reg         ptw_for_itlb;
reg [19:0]  ptw_refill_vpn;
reg [21:0]  ptw_refill_ppn;
reg         ptw_refill_mega;
reg [7:0]   ptw_refill_perm;

tlb #(
    .ENTRIES (ITLB_ENTRIES),
    .VPN_W   (20),
    .PPN_W   (22),
    .ASID_W  (9)
) u_itlb (
    .clk           (clk),
    .rstn          (rstn),
    .lookup_valid  (itlb_req_valid && vm_enabled),
    .lookup_vpn    (itlb_req_vaddr[31:12]),
    .lookup_asid   (satp_asid),
    .lookup_hit    (itlb_hit),
    .lookup_ppn    (itlb_ppn),
    .lookup_is_mega(itlb_is_mega),
    .lookup_perm   (itlb_perm),
    .refill_valid  (ptw_refill_valid && ptw_for_itlb),
    .refill_vpn    (ptw_refill_vpn),
    .refill_asid   (satp_asid),
    .refill_ppn    (ptw_refill_ppn),
    .refill_is_mega(ptw_refill_mega),
    .refill_perm   (ptw_refill_perm),
    .sfence_valid  (sfence_valid),
    .sfence_vpn    (sfence_vaddr[31:12]),
    .sfence_asid   (sfence_asid)
);

tlb #(
    .ENTRIES (DTLB_ENTRIES),
    .VPN_W   (20),
    .PPN_W   (22),
    .ASID_W  (9)
) u_dtlb (
    .clk           (clk),
    .rstn          (rstn),
    .lookup_valid  (dtlb_req_valid && vm_enabled),
    .lookup_vpn    (dtlb_req_vaddr[31:12]),
    .lookup_asid   (satp_asid),
    .lookup_hit    (dtlb_hit),
    .lookup_ppn    (dtlb_ppn),
    .lookup_is_mega(dtlb_is_mega),
    .lookup_perm   (dtlb_perm),
    .refill_valid  (ptw_refill_valid && !ptw_for_itlb),
    .refill_vpn    (ptw_refill_vpn),
    .refill_asid   (satp_asid),
    .refill_ppn    (ptw_refill_ppn),
    .refill_is_mega(ptw_refill_mega),
    .refill_perm   (ptw_refill_perm),
    .sfence_valid  (sfence_valid),
    .sfence_vpn    (sfence_vaddr[31:12]),
    .sfence_asid   (sfence_asid)
);

// -----------------------------------------------------------------------------
// Permission checks for TLB hits
// -----------------------------------------------------------------------------
wire itlb_user_ok = (priv_mode == PRIV_U) ? itlb_perm[4] :
                    (priv_mode == PRIV_S) ? !itlb_perm[4] : 1'b1;
wire itlb_perm_ok = itlb_perm[3] && itlb_user_ok;
wire itlb_ad_ok   = itlb_perm[6];
wire itlb_perm_fault = itlb_req_valid && vm_enabled && itlb_hit && !itlb_perm_ok;
wire itlb_ad_miss    = itlb_req_valid && vm_enabled && itlb_hit && itlb_perm_ok && !itlb_ad_ok;

wire dtlb_user_ok = (priv_mode == PRIV_U) ? dtlb_perm[4] :
                    (priv_mode == PRIV_S) ? (!dtlb_perm[4] || mstatus_sum) : 1'b1;
wire dtlb_r_ok    = dtlb_perm[1] || (mstatus_mxr && dtlb_perm[3]);
wire dtlb_w_ok    = dtlb_perm[2];
wire dtlb_perm_ok = dtlb_user_ok && (dtlb_req_store ? (dtlb_r_ok && dtlb_w_ok) : dtlb_r_ok);
wire dtlb_ad_ok   = dtlb_perm[6] && (!dtlb_req_store || dtlb_perm[7]);
wire dtlb_perm_fault = dtlb_req_valid && vm_enabled && dtlb_hit && !dtlb_perm_ok;
wire dtlb_ad_miss    = dtlb_req_valid && vm_enabled && dtlb_hit && dtlb_perm_ok && !dtlb_ad_ok;

wire itlb_needs_walk = itlb_req_valid && vm_enabled && !itlb_perm_fault && (!itlb_hit || itlb_ad_miss);
wire dtlb_needs_walk = dtlb_req_valid && vm_enabled && !dtlb_perm_fault && (!dtlb_hit || dtlb_ad_miss);

// Physical address construction for hits.
wire [31:0] itlb_paddr_tlb = itlb_is_mega ?
    {itlb_ppn[21:10], itlb_req_vaddr[21:0]} :
    {itlb_ppn, itlb_req_vaddr[11:0]};

wire [31:0] dtlb_paddr_tlb = dtlb_is_mega ?
    {dtlb_ppn[21:10], dtlb_req_vaddr[21:0]} :
    {dtlb_ppn, dtlb_req_vaddr[11:0]};

// -----------------------------------------------------------------------------
// PTW FSM
// -----------------------------------------------------------------------------
localparam [3:0] PTW_IDLE       = 4'd0;
localparam [3:0] PTW_L1_REQ     = 4'd1;
localparam [3:0] PTW_L1_WAIT    = 4'd2;
localparam [3:0] PTW_L0_REQ     = 4'd3;
localparam [3:0] PTW_L0_WAIT    = 4'd4;
localparam [3:0] PTW_AD_REQ     = 4'd5;
localparam [3:0] PTW_AD_WAIT    = 4'd6;
localparam [3:0] PTW_REFILL     = 4'd7;
localparam [3:0] PTW_FAULT      = 4'd8;

reg [3:0]  ptw_state;
reg [19:0] ptw_vpn;
reg [31:0] ptw_vaddr;
reg [1:0]  ptw_access;
reg [31:0] ptw_pte;
reg [31:0] ptw_pte_addr;
reg        ptw_leaf_mega;
reg        ptw_fault_valid;
reg        ptw_fault_for_itlb;
reg [4:0]  ptw_fault_cause;
reg [31:0] ptw_fault_tval;

wire [9:0]  cur_pte_flags = ptw_pte[9:0];
wire [21:0] cur_pte_ppn   = ptw_pte[31:10];
wire        cur_pte_v     = ptw_pte[0];
wire        cur_pte_r     = ptw_pte[1];
wire        cur_pte_w     = ptw_pte[2];
wire        cur_pte_x     = ptw_pte[3];
wire        cur_pte_u     = ptw_pte[4];
wire        cur_pte_a     = ptw_pte[6];
wire        cur_pte_d     = ptw_pte[7];

wire ptw_req_fire = ptw_req_valid && ptw_req_ready;

function automatic [4:0] access_cause(input [1:0] access);
    begin
        case (access)
            ACCESS_FETCH: access_cause = CAUSE_INST_PAGE_FAULT;
            ACCESS_STORE: access_cause = CAUSE_STORE_PAGE_FAULT;
            default:      access_cause = CAUSE_LOAD_PAGE_FAULT;
        endcase
    end
endfunction

function automatic pte_user_allowed(
    input [1:0] access,
    input [1:0] mode,
    input       pte_u_bit,
    input       sum_bit
);
    begin
        if (mode == PRIV_U) begin
            pte_user_allowed = pte_u_bit;
        end
        else if (mode == PRIV_S) begin
            if (access == ACCESS_FETCH)
                pte_user_allowed = !pte_u_bit;
            else
                pte_user_allowed = !pte_u_bit || sum_bit;
        end
        else begin
            pte_user_allowed = 1'b1;
        end
    end
endfunction

function automatic pte_access_allowed(
    input [1:0] access,
    input       pte_r_bit,
    input       pte_w_bit,
    input       pte_x_bit,
    input       mxr_bit
);
    begin
        case (access)
            ACCESS_FETCH: pte_access_allowed = pte_x_bit;
            ACCESS_STORE: pte_access_allowed = pte_r_bit && pte_w_bit;
            default:      pte_access_allowed = pte_r_bit || (mxr_bit && pte_x_bit);
        endcase
    end
endfunction

wire cur_pte_user_ok = pte_user_allowed(ptw_access, priv_mode, cur_pte_u, mstatus_sum);
wire cur_pte_access_ok = pte_access_allowed(ptw_access, cur_pte_r, cur_pte_w, cur_pte_x, mstatus_mxr);
wire cur_pte_ad_ok = cur_pte_a && ((ptw_access != ACCESS_STORE) || cur_pte_d);
wire [31:0] cur_pte_ad_updated = ptw_pte | 32'h0000_0040 |
                                 ((ptw_access == ACCESS_STORE) ? 32'h0000_0080 : 32'h0000_0000);

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ptw_state           <= PTW_IDLE;
        ptw_for_itlb        <= 1'b0;
        ptw_vpn             <= 20'd0;
        ptw_vaddr           <= 32'd0;
        ptw_access          <= ACCESS_LOAD;
        ptw_pte             <= 32'd0;
        ptw_pte_addr        <= 32'd0;
        ptw_leaf_mega       <= 1'b0;
        ptw_refill_valid    <= 1'b0;
        ptw_refill_vpn      <= 20'd0;
        ptw_refill_ppn      <= 22'd0;
        ptw_refill_mega     <= 1'b0;
        ptw_refill_perm     <= 8'd0;
        ptw_fault_valid     <= 1'b0;
        ptw_fault_for_itlb  <= 1'b0;
        ptw_fault_cause     <= 5'd0;
        ptw_fault_tval      <= 32'd0;
        ptw_req_valid       <= 1'b0;
        ptw_req_write       <= 1'b0;
        ptw_req_addr        <= 32'd0;
        ptw_req_wdata       <= 32'd0;
        ptw_req_wen         <= 4'd0;
    end
    else begin
        ptw_refill_valid <= 1'b0;
        ptw_fault_valid  <= 1'b0;

        case (ptw_state)
            PTW_IDLE: begin
                ptw_req_valid <= 1'b0;
                ptw_req_write <= 1'b0;
                ptw_req_wen   <= 4'd0;
                if (itlb_needs_walk) begin
                    ptw_for_itlb <= 1'b1;
                    ptw_vpn      <= itlb_req_vaddr[31:12];
                    ptw_vaddr    <= itlb_req_vaddr;
                    ptw_access   <= ACCESS_FETCH;
                    ptw_state    <= PTW_L1_REQ;
                end
                else if (dtlb_needs_walk) begin
                    ptw_for_itlb <= 1'b0;
                    ptw_vpn      <= dtlb_req_vaddr[31:12];
                    ptw_vaddr    <= dtlb_req_vaddr;
                    ptw_access   <= dtlb_req_store ? ACCESS_STORE : ACCESS_LOAD;
                    ptw_state    <= PTW_L1_REQ;
                end
            end

            PTW_L1_REQ: begin
                ptw_req_valid <= 1'b1;
                ptw_req_write <= 1'b0;
                ptw_req_addr  <= {satp_ppn, 12'd0} + {20'd0, ptw_vpn[19:10], 2'b00};
                ptw_req_wdata <= 32'd0;
                ptw_req_wen   <= 4'd0;
                if (ptw_req_fire) begin
                    ptw_req_valid <= 1'b0;
                    ptw_state     <= PTW_L1_WAIT;
                end
            end

            PTW_L1_WAIT: begin
                if (ptw_resp_valid) begin
                    ptw_pte      <= ptw_resp_rdata;
                    ptw_pte_addr <= {satp_ppn, 12'd0} + {20'd0, ptw_vpn[19:10], 2'b00};
                    if (!ptw_resp_rdata[0] || (ptw_resp_rdata[2] && !ptw_resp_rdata[1])) begin
                        ptw_state <= PTW_FAULT;
                    end
                    else if (ptw_resp_rdata[1] || ptw_resp_rdata[3]) begin
                        if (ptw_resp_rdata[19:10] != 10'd0) begin
                            ptw_state <= PTW_FAULT;
                        end
                        else begin
                            ptw_leaf_mega <= 1'b1;
                            ptw_state     <= PTW_REFILL;
                        end
                    end
                    else begin
                        ptw_state <= PTW_L0_REQ;
                    end
                end
            end

            PTW_L0_REQ: begin
                ptw_req_valid <= 1'b1;
                ptw_req_write <= 1'b0;
                ptw_req_addr  <= {cur_pte_ppn, 12'd0} + {20'd0, ptw_vpn[9:0], 2'b00};
                ptw_req_wdata <= 32'd0;
                ptw_req_wen   <= 4'd0;
                if (ptw_req_fire) begin
                    ptw_req_valid <= 1'b0;
                    ptw_state     <= PTW_L0_WAIT;
                end
            end

            PTW_L0_WAIT: begin
                if (ptw_resp_valid) begin
                    ptw_pte      <= ptw_resp_rdata;
                    ptw_pte_addr <= {cur_pte_ppn, 12'd0} + {20'd0, ptw_vpn[9:0], 2'b00};
                    ptw_leaf_mega <= 1'b0;
                    if (!ptw_resp_rdata[0] || (ptw_resp_rdata[2] && !ptw_resp_rdata[1]) ||
                        !(ptw_resp_rdata[1] || ptw_resp_rdata[3])) begin
                        ptw_state <= PTW_FAULT;
                    end
                    else begin
                        ptw_state <= PTW_REFILL;
                    end
                end
            end

            PTW_AD_REQ: begin
                ptw_req_valid <= 1'b1;
                ptw_req_write <= 1'b1;
                ptw_req_addr  <= ptw_pte_addr;
                ptw_req_wdata <= cur_pte_ad_updated;
                ptw_req_wen   <= 4'hF;
                if (ptw_req_fire) begin
                    ptw_req_valid <= 1'b0;
                    ptw_state     <= PTW_AD_WAIT;
                end
            end

            PTW_AD_WAIT: begin
                if (ptw_resp_valid) begin
                    ptw_pte   <= cur_pte_ad_updated;
                    ptw_state <= PTW_REFILL;
                end
            end

            PTW_REFILL: begin
                if (!cur_pte_user_ok || !cur_pte_access_ok) begin
                    ptw_state <= PTW_FAULT;
                end
                else if (!cur_pte_ad_ok) begin
                    ptw_state <= PTW_AD_REQ;
                end
                else begin
                    ptw_refill_valid <= 1'b1;
                    ptw_refill_vpn   <= ptw_vpn;
                    ptw_refill_ppn   <= cur_pte_ppn;
                    ptw_refill_mega  <= ptw_leaf_mega;
                    ptw_refill_perm  <= cur_pte_flags[7:0];
                    ptw_state        <= PTW_IDLE;
                end
            end

            PTW_FAULT: begin
                ptw_fault_valid    <= 1'b1;
                ptw_fault_for_itlb <= ptw_for_itlb;
                ptw_fault_cause    <= access_cause(ptw_access);
                ptw_fault_tval     <= ptw_vaddr;
                ptw_state          <= PTW_IDLE;
            end

            default: begin
                ptw_state     <= PTW_IDLE;
                ptw_req_valid <= 1'b0;
            end
        endcase
    end
end

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
assign itlb_resp_hit = vm_enabled ? (itlb_req_valid && itlb_hit && itlb_perm_ok && itlb_ad_ok) :
                       itlb_req_valid;
assign itlb_resp_paddr = vm_enabled ? itlb_paddr_tlb : itlb_req_vaddr;
assign itlb_resp_fault = vm_enabled ? (itlb_perm_fault || (ptw_fault_valid && ptw_fault_for_itlb)) :
                         1'b0;
assign itlb_resp_cause = (ptw_fault_valid && ptw_fault_for_itlb) ? ptw_fault_cause :
                         CAUSE_INST_PAGE_FAULT;
assign itlb_resp_tval  = (ptw_fault_valid && ptw_fault_for_itlb) ? ptw_fault_tval : itlb_req_vaddr;
assign itlb_busy       = vm_enabled && itlb_req_valid && !itlb_resp_hit && !itlb_resp_fault;

assign dtlb_resp_hit = vm_enabled ? (dtlb_req_valid && dtlb_hit && dtlb_perm_ok && dtlb_ad_ok) :
                       dtlb_req_valid;
assign dtlb_resp_paddr = vm_enabled ? dtlb_paddr_tlb : dtlb_req_vaddr;
assign dtlb_resp_fault = vm_enabled ? (dtlb_perm_fault || (ptw_fault_valid && !ptw_fault_for_itlb)) :
                         1'b0;
assign dtlb_resp_cause = (ptw_fault_valid && !ptw_fault_for_itlb) ? ptw_fault_cause :
                         (dtlb_req_store ? CAUSE_STORE_PAGE_FAULT : CAUSE_LOAD_PAGE_FAULT);
assign dtlb_resp_tval  = (ptw_fault_valid && !ptw_fault_for_itlb) ? ptw_fault_tval : dtlb_req_vaddr;
assign dtlb_busy       = vm_enabled && dtlb_req_valid && !dtlb_resp_hit && !dtlb_resp_fault;

endmodule
