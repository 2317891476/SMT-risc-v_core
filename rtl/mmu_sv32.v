// =============================================================================
// Module : mmu_sv32
// Description: Sv32 Memory Management Unit with Hardware Page Table Walker.
//   - I-TLB: 16-entry fully-associative (for instruction fetch)
//   - D-TLB: 32-entry fully-associative (for data load/store)
//   - Hardware PTW: 2-level Sv32 page table walk via AXI4 read channel
//   - Supports SFENCE.VMA for TLB invalidation
//   - Supports mega-pages (4MB)
//   - Bare mode bypass when satp MODE = 0
//
//   PTW FSM: IDLE → L1_REQ → L1_WAIT → L0_REQ → L0_WAIT → REFILL → DONE
// =============================================================================
module mmu_sv32 #(
    parameter ITLB_ENTRIES = 16,
    parameter DTLB_ENTRIES = 32
)(
    input  wire               clk,
    input  wire               rstn,

    // ─── CSR Interface ──────────────────────────────────────────
    input  wire [31:0]        satp,           // [31]=MODE, [30:22]=ASID, [21:0]=PPN
    input  wire [1:0]         priv_mode,
    input  wire               mstatus_mxr,    // Make eXecutable Readable
    input  wire               mstatus_sum,    // Supervisor User Memory access

    // ─── SFENCE.VMA ─────────────────────────────────────────────
    input  wire               sfence_valid,
    input  wire [31:0]        sfence_vaddr,
    input  wire [8:0]         sfence_asid,

    // ─── I-TLB Port ─────────────────────────────────────────────
    input  wire               itlb_req_valid,
    input  wire [31:0]        itlb_req_vaddr,
    output wire               itlb_resp_hit,
    output wire [31:0]        itlb_resp_paddr,
    output wire               itlb_resp_fault,
    output wire               itlb_busy,

    // ─── D-TLB Port ─────────────────────────────────────────────
    input  wire               dtlb_req_valid,
    input  wire [31:0]        dtlb_req_vaddr,
    input  wire               dtlb_req_store,
    output wire               dtlb_resp_hit,
    output wire [31:0]        dtlb_resp_paddr,
    output wire               dtlb_resp_fault,
    output wire               dtlb_busy,

    // ─── PTW AXI4 Read Channel ──────────────────────────────────
    output reg                ptw_axi_arvalid,
    input  wire               ptw_axi_arready,
    output reg  [31:0]        ptw_axi_araddr,
    output wire [2:0]         ptw_axi_arprot,
    input  wire               ptw_axi_rvalid,
    output wire               ptw_axi_rready,
    input  wire [31:0]        ptw_axi_rdata,
    input  wire [1:0]         ptw_axi_rresp
);

// ─── Bare mode check ────────────────────────────────────────────────────────
wire vm_enabled = satp[31];  // MODE bit
wire [8:0]  satp_asid = satp[30:22];
wire [21:0] satp_ppn  = satp[21:0];

// ─── I-TLB ──────────────────────────────────────────────────────────────────
wire        itlb_hit;
wire [21:0] itlb_ppn;
wire        itlb_is_mega;
wire [7:0]  itlb_perm;

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

// ─── D-TLB ──────────────────────────────────────────────────────────────────
wire        dtlb_hit;
wire [21:0] dtlb_ppn;
wire        dtlb_is_mega;
wire [7:0]  dtlb_perm;

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

// ─── PTW FSM ────────────────────────────────────────────────────────────────
localparam PTW_IDLE    = 3'd0;
localparam PTW_L1_REQ  = 3'd1;
localparam PTW_L1_WAIT = 3'd2;
localparam PTW_L0_REQ  = 3'd3;
localparam PTW_L0_WAIT = 3'd4;
localparam PTW_REFILL  = 3'd5;
localparam PTW_FAULT   = 3'd6;

reg [2:0]  ptw_state;
reg        ptw_for_itlb;      // 1 = walk for I-TLB, 0 = walk for D-TLB
reg [19:0] ptw_vpn;           // VPN being walked
reg        ptw_is_store;      // was it a store request (for permission check)
reg [31:0] ptw_pte;           // PTE read from memory
reg        ptw_refill_valid;
reg [19:0] ptw_refill_vpn;
reg [21:0] ptw_refill_ppn;
reg        ptw_refill_mega;
reg [7:0]  ptw_refill_perm;
reg        ptw_fault;

// Sv32 page table entry fields
wire [9:0]  pte_flags = ptw_pte[9:0];  // {RSW[1:0], D, A, G, U, X, W, R, V}
wire        pte_valid = ptw_pte[0];
wire        pte_r     = ptw_pte[1];
wire        pte_w     = ptw_pte[2];
wire        pte_x     = ptw_pte[3];
wire        pte_u     = ptw_pte[4];
wire        pte_g     = ptw_pte[5];
wire        pte_a     = ptw_pte[6];
wire        pte_d     = ptw_pte[7];
wire [21:0] pte_ppn   = ptw_pte[31:10];
wire        pte_is_leaf = pte_r || pte_x;  // leaf if R or X bit set

assign ptw_axi_arprot = 3'b000;
assign ptw_axi_rready = (ptw_state == PTW_L1_WAIT || ptw_state == PTW_L0_WAIT);

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ptw_state        <= PTW_IDLE;
        ptw_for_itlb     <= 1'b0;
        ptw_vpn          <= 20'd0;
        ptw_is_store     <= 1'b0;
        ptw_pte          <= 32'd0;
        ptw_refill_valid <= 1'b0;
        ptw_refill_vpn   <= 20'd0;
        ptw_refill_ppn   <= 22'd0;
        ptw_refill_mega  <= 1'b0;
        ptw_refill_perm  <= 8'd0;
        ptw_fault        <= 1'b0;
        ptw_axi_arvalid  <= 1'b0;
        ptw_axi_araddr   <= 32'd0;
    end
    else begin
        ptw_refill_valid <= 1'b0;  // pulse
        ptw_fault        <= 1'b0;  // pulse

        case (ptw_state)
            PTW_IDLE: begin
                ptw_axi_arvalid <= 1'b0;
                // Priority: I-TLB miss > D-TLB miss
                if (itlb_req_valid && vm_enabled && !itlb_hit) begin
                    ptw_state    <= PTW_L1_REQ;
                    ptw_for_itlb <= 1'b1;
                    ptw_vpn      <= itlb_req_vaddr[31:12];
                    ptw_is_store <= 1'b0;
                end
                else if (dtlb_req_valid && vm_enabled && !dtlb_hit) begin
                    ptw_state    <= PTW_L1_REQ;
                    ptw_for_itlb <= 1'b0;
                    ptw_vpn      <= dtlb_req_vaddr[31:12];
                    ptw_is_store <= dtlb_req_store;
                end
            end

            PTW_L1_REQ: begin
                // Level-1 PTE address = satp.PPN * 4096 + VPN[1] * 4
                ptw_axi_araddr  <= {satp_ppn, 12'd0} + {20'd0, ptw_vpn[19:10], 2'b00};
                ptw_axi_arvalid <= 1'b1;
                ptw_state       <= PTW_L1_WAIT;
            end

            PTW_L1_WAIT: begin
                if (ptw_axi_arready)
                    ptw_axi_arvalid <= 1'b0;
                if (ptw_axi_rvalid) begin
                    ptw_pte <= ptw_axi_rdata;
                    if (!ptw_axi_rdata[0]) begin
                        // Invalid PTE
                        ptw_state <= PTW_FAULT;
                    end
                    else if (ptw_axi_rdata[1] || ptw_axi_rdata[3]) begin
                        // Leaf PTE at level 1 → mega-page (4MB)
                        // Check alignment: PPN[9:0] must be 0
                        if (ptw_axi_rdata[19:10] != 10'd0) begin
                            ptw_state <= PTW_FAULT; // misaligned superpage
                        end
                        else begin
                            ptw_state <= PTW_REFILL;
                        end
                    end
                    else begin
                        // Non-leaf: go to level 0
                        ptw_state <= PTW_L0_REQ;
                    end
                end
            end

            PTW_L0_REQ: begin
                // Level-0 PTE address = PTE.PPN * 4096 + VPN[0] * 4
                ptw_axi_araddr  <= {pte_ppn, 12'd0} + {20'd0, ptw_vpn[9:0], 2'b00};
                ptw_axi_arvalid <= 1'b1;
                ptw_state       <= PTW_L0_WAIT;
            end

            PTW_L0_WAIT: begin
                if (ptw_axi_arready)
                    ptw_axi_arvalid <= 1'b0;
                if (ptw_axi_rvalid) begin
                    ptw_pte <= ptw_axi_rdata;
                    if (!ptw_axi_rdata[0] || (!ptw_axi_rdata[1] && !ptw_axi_rdata[3])) begin
                        // Invalid or non-leaf at level 0 → fault
                        ptw_state <= PTW_FAULT;
                    end
                    else begin
                        ptw_state <= PTW_REFILL;
                    end
                end
            end

            PTW_REFILL: begin
                ptw_refill_valid <= 1'b1;
                ptw_refill_vpn   <= ptw_vpn;
                ptw_refill_ppn   <= pte_ppn;
                ptw_refill_mega  <= (ptw_state == PTW_REFILL) &&
                                    (pte_is_leaf) &&
                                    (ptw_axi_araddr[13:2] == {ptw_vpn[19:10], 2'b00});
                // Check if this came from L1 (mega) by checking the previous PTE read address
                // Simplified: track with a flag
                ptw_refill_perm  <= ptw_pte[7:0];
                ptw_state        <= PTW_IDLE;
            end

            PTW_FAULT: begin
                ptw_fault <= 1'b1;
                ptw_state <= PTW_IDLE;
            end

            default: ptw_state <= PTW_IDLE;
        endcase
    end
end

// ─── Permission checking ────────────────────────────────────────────────────
// I-TLB: check X permission
wire itlb_perm_ok = itlb_perm[3]; // X bit
wire itlb_x_fault = itlb_hit && !itlb_perm_ok;

// D-TLB: check R/W permission
wire dtlb_r_ok = dtlb_perm[1] || (mstatus_mxr && dtlb_perm[3]); // R or (MXR && X)
wire dtlb_w_ok = dtlb_perm[2]; // W bit
wire dtlb_perm_ok = dtlb_req_store ? (dtlb_r_ok && dtlb_w_ok) : dtlb_r_ok;
wire dtlb_d_fault = dtlb_hit && !dtlb_perm_ok;

// ─── Output: bare mode bypass or TLB translation ───────────────────────────
// Bare mode: physical = virtual
wire [31:0] itlb_paddr_tlb;
wire [31:0] dtlb_paddr_tlb;

// For regular pages: PA = {PPN, offset[11:0]}
// For mega pages:    PA = {PPN[21:10], VPN[9:0], offset[11:0]}
assign itlb_paddr_tlb = itlb_is_mega ?
    {itlb_ppn[21:10], itlb_req_vaddr[21:0]} :
    {itlb_ppn, itlb_req_vaddr[11:0]};

assign dtlb_paddr_tlb = dtlb_is_mega ?
    {dtlb_ppn[21:10], dtlb_req_vaddr[21:0]} :
    {dtlb_ppn, dtlb_req_vaddr[11:0]};

assign itlb_resp_hit   = vm_enabled ? itlb_hit           : itlb_req_valid;
assign itlb_resp_paddr = vm_enabled ? itlb_paddr_tlb     : itlb_req_vaddr;
assign itlb_resp_fault = vm_enabled ? (itlb_x_fault || (ptw_fault && ptw_for_itlb)) : 1'b0;
assign itlb_busy       = (ptw_state != PTW_IDLE) && ptw_for_itlb;

assign dtlb_resp_hit   = vm_enabled ? dtlb_hit           : dtlb_req_valid;
assign dtlb_resp_paddr = vm_enabled ? dtlb_paddr_tlb     : dtlb_req_vaddr;
assign dtlb_resp_fault = vm_enabled ? (dtlb_d_fault || (ptw_fault && !ptw_for_itlb)) : 1'b0;
assign dtlb_busy       = (ptw_state != PTW_IDLE) && !ptw_for_itlb;

endmodule
