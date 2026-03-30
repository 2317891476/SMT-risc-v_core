// =============================================================================
// Module : l2_arbiter
// Description: 3-master round-robin arbiter for L2 cache access.
//   - Master 0: I-side (instruction refill)
//   - Master 1: D-side (LSU/store buffer)
//   - Master 2: RoCC DMA (AI accelerator)
//   - Priority: M2 (RoCC) > M0/M1 when active
//   - Round-robin between M0/M1 when M2 is not requesting
// =============================================================================
`include "define.v"

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
    // Master 2: RoCC DMA interface (AI accelerator)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        m2_req_valid,
    output wire        m2_req_ready,
    input  wire [31:0] m2_req_addr,
    input  wire        m2_req_write,
    input  wire [31:0] m2_req_wdata,
    input  wire [3:0]  m2_req_wen,
    output wire        m2_resp_valid,
    output wire [31:0] m2_resp_data,

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
    output wire        grant_m2,        // M2 currently granted (RoCC DMA)
    output wire [2:0]  grant_count      // Number of grants issued (3-bit for 3 masters)
);

// ═════════════════════════════════════════════════════════════════════════════
// Address Decode for Cacheability
// ═════════════════════════════════════════════════════════════════════════════

// Address regions (from define.v)
// RAM cacheable: 0x0000_0000 - 0x0000_3FFF
// TUBE MMIO:     0x1300_0000
// CLINT MMIO:    0x0200_0000 - 0x0200_BFFC
// PLIC MMIO:     0x0C00_0000 - 0x0C20_0004

wire addr_is_ram_m0     = (m0_req_addr >= `RAM_CACHEABLE_BASE) && (m0_req_addr <= `RAM_CACHEABLE_TOP);
wire addr_is_ram_m1     = (m1_req_addr >= `RAM_CACHEABLE_BASE) && (m1_req_addr <= `RAM_CACHEABLE_TOP);
wire addr_is_ram_m2     = (m2_req_addr >= `RAM_CACHEABLE_BASE) && (m2_req_addr <= `RAM_CACHEABLE_TOP);
wire addr_is_tube_m1    = (m1_req_addr == `TUBE_ADDR);
wire addr_is_clint_m1   = (m1_req_addr >= `CLINT_BASE) && (m1_req_addr <= `CLINT_MTIME_HI);
wire addr_is_plic_m1    = (m1_req_addr >= `PLIC_BASE) && (m1_req_addr <= `PLIC_CLAIM_COMPLETE);
wire addr_is_uncached_m1 = addr_is_tube_m1 || addr_is_clint_m1 || addr_is_plic_m1;

// M0 (I-side) is always cacheable if in RAM region
wire m0_cacheable = addr_is_ram_m0;
// M1 (D-side) is cacheable only for RAM region
wire m1_cacheable = addr_is_ram_m1;
// M2 (RoCC DMA) is cacheable only for RAM region (addresses 0x0000_0000 to 0x0000_3FFF)
wire m2_cacheable = addr_is_ram_m2;

// ═════════════════════════════════════════════════════════════════════════════
// Priority Arbitration State (M2 > M0/M1, round-robin M0/M1)
// ═════════════════════════════════════════════════════════════════════════════

// last_grant encoding: 2'b00=M0, 2'b01=M1, 2'b10=M2
reg [1:0] last_grant;
reg active;             // Transaction in progress
reg [1:0] master_select; // 2'b00=M0, 2'b01=M1, 2'b10=M2
reg [31:0] req_addr_r;
reg        req_write_r;
reg [31:0] req_wdata_r;
reg [3:0]  req_wen_r;
reg        req_uncached_r;
reg        req_issued;

// Request detection
wire m0_requesting = m0_req_valid && m0_cacheable;
wire m1_requesting = m1_req_valid && (m1_cacheable || addr_is_uncached_m1);
wire m2_requesting = m2_req_valid && m2_cacheable;

// Priority arbitration logic (combinational)
// M2 (RoCC DMA) gets priority when active to ensure deterministic GEMM timing
reg next_grant_m0;
reg next_grant_m1;
reg next_grant_m2;

always @(*) begin
    if (active) begin
        // Hold current grant until transaction completes
        next_grant_m0 = (master_select == 2'b00);
        next_grant_m1 = (master_select == 2'b01);
        next_grant_m2 = (master_select == 2'b10);
    end else begin
        // Priority: M2 > M0/M1
        // When M2 is not requesting, round-robin between M0 and M1
        if (m2_requesting) begin
            // M2 has highest priority
            next_grant_m0 = 1'b0;
            next_grant_m1 = 1'b0;
            next_grant_m2 = 1'b1;
        end else if (m0_requesting && !m1_requesting) begin
            next_grant_m0 = 1'b1;
            next_grant_m1 = 1'b0;
            next_grant_m2 = 1'b0;
        end else if (!m0_requesting && m1_requesting) begin
            next_grant_m0 = 1'b0;
            next_grant_m1 = 1'b1;
            next_grant_m2 = 1'b0;
        end else if (m0_requesting && m1_requesting) begin
            // Round-robin between M0 and M1 when both request
            next_grant_m0 = last_grant[0];  // If last was M1 (2'b01), give to M0
            next_grant_m1 = !last_grant[0]; // If last was M0 (2'b00), give to M1
            next_grant_m2 = 1'b0;
        end else begin
            next_grant_m0 = 1'b0;
            next_grant_m1 = 1'b0;
            next_grant_m2 = 1'b0;
        end
    end
end

// Sequential state update
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        last_grant <= 2'b00;
        active <= 1'b0;
        master_select <= 2'b00;
        req_addr_r <= 32'd0;
        req_write_r <= 1'b0;
        req_wdata_r <= 32'd0;
        req_wen_r <= 4'd0;
        req_uncached_r <= 1'b0;
        req_issued <= 1'b0;
    end else begin
        if (!active) begin
            // Start new transaction
            if (next_grant_m0) begin
                `ifndef SYNTHESIS
                $display("[L2 ARB] grant M0 addr=%h", m0_req_addr);
                `endif
                active <= 1'b1;
                master_select <= 2'b00;
                last_grant <= 2'b00;
                req_addr_r <= m0_req_addr;
                req_write_r <= 1'b0;
                req_wdata_r <= 32'd0;
                req_wen_r <= 4'd0;
                req_uncached_r <= 1'b0;
                req_issued <= 1'b0;
            end else if (next_grant_m1) begin
                `ifndef SYNTHESIS
                $display("[L2 ARB] grant M1 addr=%h write=%0b wdata=%h", m1_req_addr, m1_req_write, m1_req_wdata);
                `endif
                active <= 1'b1;
                master_select <= 2'b01;
                last_grant <= 2'b01;
                req_addr_r <= m1_req_addr;
                req_write_r <= m1_req_write;
                req_wdata_r <= m1_req_wdata;
                req_wen_r <= m1_req_wen;
                req_uncached_r <= addr_is_uncached_m1;
                req_issued <= 1'b0;
            end else if (next_grant_m2) begin
                active <= 1'b1;
                master_select <= 2'b10;
                last_grant <= 2'b10;
                req_addr_r <= m2_req_addr;
                req_write_r <= m2_req_write;
                req_wdata_r <= m2_req_wdata;
                req_wen_r <= m2_req_wen;
                req_uncached_r <= 1'b0;
                req_issued <= 1'b0;
            end
        end else begin
            if (!req_issued && l2_req_ready) begin
                req_issued <= 1'b1;
            end
            // Transaction in progress - check for completion
            if (req_issued && l2_resp_valid && l2_resp_last) begin
                `ifndef SYNTHESIS
                $display("[L2 ARB] resp master=%0d data=%h", master_select, l2_resp_data);
                `endif
                active <= 1'b0;
                req_issued <= 1'b0;
            end
        end
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// Request Muxing to L2 Cache
// ═════════════════════════════════════════════════════════════════════════════

assign l2_req_valid = active && !req_issued;

assign l2_req_addr  = req_addr_r;
assign l2_req_write = req_write_r;
assign l2_req_wdata = req_wdata_r;
assign l2_req_wen   = req_wen_r;
assign l2_req_uncached = req_uncached_r;

// ═════════════════════════════════════════════════════════════════════════════
// Response Demuxing from L2 Cache
// ═════════════════════════════════════════════════════════════════════════════

// M0 response
assign m0_resp_valid = l2_resp_valid && req_issued && (master_select == 2'b00) && active;
assign m0_resp_data  = l2_resp_data;
assign m0_resp_last  = l2_resp_last && (master_select == 2'b00);

// M1 response
assign m1_resp_valid = l2_resp_valid && req_issued && (master_select == 2'b01) && active;
assign m1_resp_data  = l2_resp_data;

// M2 response (RoCC DMA)
assign m2_resp_valid = l2_resp_valid && req_issued && (master_select == 2'b10) && active;
assign m2_resp_data  = l2_resp_data;

// ═════════════════════════════════════════════════════════════════════════════
// Ready Signals
// ═════════════════════════════════════════════════════════════════════════════

// M0 ready when not active or when completing M0 transaction
assign m0_req_ready = !active ? next_grant_m0 : (master_select == 2'b00 && !req_issued && l2_req_ready);

// M1 ready when not active or when completing M1 transaction  
assign m1_req_ready = !active ? next_grant_m1 : (master_select == 2'b01 && !req_issued && l2_req_ready);

// M2 ready when not active or when completing M2 transaction  
assign m2_req_ready = !active ? next_grant_m2 : (master_select == 2'b10 && !req_issued && l2_req_ready);

// ═════════════════════════════════════════════════════════════════════════════
// Status Outputs
// ═════════════════════════════════════════════════════════════════════════════

assign grant_m0 = (master_select == 2'b00) && active;
assign grant_m1 = (master_select == 2'b01) && active;
assign grant_m2 = (master_select == 2'b10) && active;

// Simple grant counter (saturates at 7 for 3-bit)
reg [2:0] grant_cnt;
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        grant_cnt <= 3'd0;
    end else begin
        if (l2_resp_valid && l2_resp_last && grant_cnt != 3'd7) begin
            grant_cnt <= grant_cnt + 3'd1;
        end
    end
end
assign grant_count = grant_cnt;

endmodule
