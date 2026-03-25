// =============================================================================
// Module : l2_arbiter
// Description: 2-master round-robin arbiter for L2 cache access.
//   - Master 0: I-side (instruction refill)
//   - Master 1: D-side (LSU/store buffer)
//   - Round-robin arbitration when both masters request simultaneously
// =============================================================================
`include "define_v2.v"

module l2_arbiter (
    input  wire        clk,
    input  wire        rstn,

    // ═══════════════════════════════════════════════════════════════════════════
    // Master 0: I-side interface
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        m0_req_valid,
    output wire        m0_req_ready,
    input  wire [31:0] m0_req_addr,
    output wire        m0_resp_valid,
    output wire [31:0] m0_resp_data,
    output wire        m0_resp_last,

    // ═══════════════════════════════════════════════════════════════════════════
    // Master 1: D-side interface
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        m1_req_valid,
    output wire        m1_req_ready,
    input  wire [31:0] m1_req_addr,
    input  wire        m1_req_write,
    input  wire [31:0] m1_req_wdata,
    input  wire [3:0]  m1_req_wen,
    output wire        m1_resp_valid,
    output wire [31:0] m1_resp_data,

    // ═══════════════════════════════════════════════════════════════════════════
    // L2 Cache interface (output)
    // ═══════════════════════════════════════════════════════════════════════════
    output wire        l2_req_valid,
    input  wire        l2_req_ready,
    output wire [31:0] l2_req_addr,
    output wire        l2_req_write,
    output wire [31:0] l2_req_wdata,
    output wire [3:0]  l2_req_wen,
    output wire        l2_req_uncached,
    input  wire        l2_resp_valid,
    input  wire [31:0] l2_resp_data,
    input  wire        l2_resp_last,

    // ═══════════════════════════════════════════════════════════════════════════
    // Status outputs (for debugging/tests)
    // ═══════════════════════════════════════════════════════════════════════════
    output wire        grant_m0,        // M0 currently granted
    output wire        grant_m1,        // M1 currently granted
    output wire [1:0]  grant_count      // Number of grants issued
);

// ═════════════════════════════════════════════════════════════════════════════
// Address Decode for Cacheability
// ═════════════════════════════════════════════════════════════════════════════

// Address regions (from define_v2.v)
// RAM cacheable: 0x0000_0000 - 0x0000_3FFF
// TUBE MMIO:     0x1300_0000
// CLINT MMIO:    0x0200_0000 - 0x0200_BFFC
// PLIC MMIO:     0x0C00_0000 - 0x0C20_0004

wire addr_is_ram_m0     = (m0_req_addr >= `RAM_CACHEABLE_BASE) && (m0_req_addr <= `RAM_CACHEABLE_TOP);
wire addr_is_ram_m1     = (m1_req_addr >= `RAM_CACHEABLE_BASE) && (m1_req_addr <= `RAM_CACHEABLE_TOP);
wire addr_is_tube_m1    = (m1_req_addr == `TUBE_ADDR);
wire addr_is_clint_m1   = (m1_req_addr >= `CLINT_BASE) && (m1_req_addr <= `CLINT_MTIME_HI);
wire addr_is_plic_m1    = (m1_req_addr >= `PLIC_BASE) && (m1_req_addr <= `PLIC_CLAIM_COMPLETE);
wire addr_is_uncached_m1 = addr_is_tube_m1 || addr_is_clint_m1 || addr_is_plic_m1;

// M0 (I-side) is always cacheable if in RAM region
wire m0_cacheable = addr_is_ram_m0;
// M1 (D-side) is cacheable only for RAM region
wire m1_cacheable = addr_is_ram_m1;

// ═════════════════════════════════════════════════════════════════════════════
// Round-Robin Arbitration State
// ═════════════════════════════════════════════════════════════════════════════

reg last_grant;     // 0 = last granted to M0, 1 = last granted to M1
reg active;         // Transaction in progress
reg master_select;  // 0 = M0 selected, 1 = M1 selected

// Request detection
wire m0_requesting = m0_req_valid && m0_cacheable;
wire m1_requesting = m1_req_valid && (m1_cacheable || addr_is_uncached_m1);

// Arbitration logic (combinational)
wire grant_m0_next;
wire grant_m1_next;

assign grant_m0_next = !active && (
    (m0_requesting && !m1_requesting) ||                          // Only M0
    (m0_requesting && m1_requesting && last_grant) ||             // Both, M1 had it last
    (m0_requesting && !m1_requesting && !last_grant)              // Only M0 (redundant but clear)
);

assign grant_m1_next = !active && (
    (!m0_requesting && m1_requesting) ||                          // Only M1
    (m0_requesting && m1_requesting && !last_grant) ||            // Both, M0 had it last
    (!m0_requesting && m1_requesting && last_grant)              // Only M1 (redundant but clear)
);

// Simplified arbitration
reg next_grant_m0;
reg next_grant_m1;

always @(*) begin
    if (active) begin
        // Hold current grant until transaction completes
        next_grant_m0 = (master_select == 1'b0);
        next_grant_m1 = (master_select == 1'b1);
    end else begin
        // New arbitration
        if (m0_requesting && !m1_requesting) begin
            next_grant_m0 = 1'b1;
            next_grant_m1 = 1'b0;
        end else if (!m0_requesting && m1_requesting) begin
            next_grant_m0 = 1'b0;
            next_grant_m1 = 1'b1;
        end else if (m0_requesting && m1_requesting) begin
            // Round-robin: give to the one that didn't have it last
            next_grant_m0 = last_grant;     // If last was M1 (1), give to M0
            next_grant_m1 = !last_grant;    // If last was M0 (0), give to M1
        end else begin
            next_grant_m0 = 1'b0;
            next_grant_m1 = 1'b0;
        end
    end
end

// Sequential state update
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        last_grant <= 1'b0;
        active <= 1'b0;
        master_select <= 1'b0;
    end else begin
        if (!active) begin
            // Start new transaction
            if (next_grant_m0) begin
                active <= 1'b1;
                master_select <= 1'b0;
                last_grant <= 1'b0;
            end else if (next_grant_m1) begin
                active <= 1'b1;
                master_select <= 1'b1;
                last_grant <= 1'b1;
            end
        end else begin
            // Transaction in progress - check for completion
            if (l2_resp_valid && l2_resp_last) begin
                active <= 1'b0;
            end
        end
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// Request Muxing to L2 Cache
// ═════════════════════════════════════════════════════════════════════════════

assign l2_req_valid = active;
assign l2_req_addr  = master_select ? m1_req_addr  : m0_req_addr;
assign l2_req_write = master_select ? m1_req_write : 1'b0;  // M0 never writes
assign l2_req_wdata = master_select ? m1_req_wdata : 32'd0;
assign l2_req_wen   = master_select ? m1_req_wen   : 4'd0;
assign l2_req_uncached = master_select ? addr_is_uncached_m1 : 1'b0;

// ═════════════════════════════════════════════════════════════════════════════
// Response Demuxing from L2 Cache
// ═════════════════════════════════════════════════════════════════════════════

// M0 response
assign m0_resp_valid = l2_resp_valid && (master_select == 1'b0) && active;
assign m0_resp_data  = l2_resp_data;
assign m0_resp_last  = l2_resp_last && (master_select == 1'b0);

// M1 response
assign m1_resp_valid = l2_resp_valid && (master_select == 1'b1) && active;
assign m1_resp_data  = l2_resp_data;

// ═════════════════════════════════════════════════════════════════════════════
// Ready Signals
// ═════════════════════════════════════════════════════════════════════════════

// M0 ready when not active or when completing M0 transaction
assign m0_req_ready = !active ? next_grant_m0 : (master_select == 1'b0 && l2_req_ready);

// M1 ready when not active or when completing M1 transaction  
assign m1_req_ready = !active ? next_grant_m1 : (master_select == 1'b1 && l2_req_ready);

// ═════════════════════════════════════════════════════════════════════════════
// Status Outputs
// ═════════════════════════════════════════════════════════════════════════════

assign grant_m0 = (master_select == 1'b0) && active;
assign grant_m1 = (master_select == 1'b1) && active;

// Simple grant counter (saturates at 3)
reg [1:0] grant_cnt;
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        grant_cnt <= 2'd0;
    end else begin
        if (l2_resp_valid && l2_resp_last && grant_cnt != 2'd3) begin
            grant_cnt <= grant_cnt + 2'd1;
        end
    end
end
assign grant_count = grant_cnt;

endmodule