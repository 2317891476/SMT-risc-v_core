// =============================================================================
// Module : mem_subsys
// Description: Shared memory subsystem with unified L2 cache, arbiter, and MMIO.
//   - Serves both I-side (instruction refill) and D-side (LSU/store buffer)
//   - Uses separate l2_arbiter and l2_cache modules
//   - MMIO decode for TUBE, CLINT, PLIC (uncached)
// =============================================================================
`include "define_v2.v"

module mem_subsys (
    input  wire        clk,
    input  wire        rstn,

    // ═══════════════════════════════════════════════════════════════════════════
    // Master 0: I-side refill interface (from inst_memory/icache)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        m0_req_valid,
    output wire        m0_req_ready,
    input  wire [31:0] m0_req_addr,
    output wire        m0_resp_valid,
    output wire [31:0] m0_resp_data,
    output wire        m0_resp_last,
    input  wire        m0_resp_ready,
    input  wire [31:0] m0_bypass_addr,
    output wire [31:0] m0_bypass_data,

    // ═══════════════════════════════════════════════════════════════════════════
    // Master 1: D-side LSU/store buffer interface
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        m1_req_valid,
    output wire        m1_req_ready,
    input  wire [31:0] m1_req_addr,
    input  wire        m1_req_write,      // 0=read, 1=write
    input  wire [31:0] m1_req_wdata,
    input  wire [3:0]  m1_req_wen,        // Byte-wise write enable
    output wire        m1_resp_valid,
    output wire [31:0] m1_resp_data,

    // ═══════════════════════════════════════════════════════════════════════════
    // Master 2: RoCC DMA interface (AI accelerator memory access)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        m2_req_valid,
    output wire        m2_req_ready,
    input  wire [31:0] m2_req_addr,
    input  wire        m2_req_write,      // 0=read, 1=write
    input  wire [31:0] m2_req_wdata,
    input  wire [3:0]  m2_req_wen,        // Byte-wise write enable
    output wire        m2_resp_valid,
    output wire [31:0] m2_resp_data,

    // ═══════════════════════════════════════════════════════════════════════════
    // Testbench observation interface
    // ═══════════════════════════════════════════════════════════════════════════
    output reg [7:0]   tube_status,       // TUBE MMIO register (observable by tb)

    // ═══════════════════════════════════════════════════════════════════════════
    // External interrupt wiring
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        ext_irq_src,       // Raw PLIC source input (optional TB/device drive)
    output wire        ext_timer_irq,     // CLINT timer interrupt pending (MTIP)
    output wire        ext_external_irq   // PLIC external interrupt pending (MEIP)
);

// ═════════════════════════════════════════════════════════════════════════════
// Shared Backing RAM (4096 x 32-bit words = 16KB)
// ═════════════════════════════════════════════════════════════════════════════
reg [31:0] ram [0:4095];

// ═════════════════════════════════════════════════════════════════════════════
// Internal Wires for Arbiter-Cache Interface
// ═════════════════════════════════════════════════════════════════════════════

// Arbiter to Cache
wire        l2_req_valid;
wire        l2_req_ready;
wire [31:0] l2_req_addr;
wire        l2_req_write;
wire [31:0] l2_req_wdata;
wire [3:0]  l2_req_wen;
wire        l2_req_uncached;
wire        l2_resp_valid;
wire [31:0] l2_resp_data;
wire        l2_resp_last;

// Arbiter status
wire        grant_m0;
wire        grant_m1;
wire        grant_m2;
wire [2:0]  grant_count;

// Cache status
wire [2:0]  cache_state;
wire        cache_hit;
wire        cache_miss;

// M1 cached response wires (internal, before MMIO mux)
wire        m1_resp_valid_int;
wire [31:0] m1_resp_data_int;

// Address decode for MMIO (used by arbiter and MMIO handling)
wire addr_is_tube_m1    = (m1_req_addr == `TUBE_ADDR);
wire addr_is_clint_m1   = (m1_req_addr >= `CLINT_BASE) && (m1_req_addr <= `CLINT_MTIME_HI);
wire addr_is_plic_m1    = (m1_req_addr >= `PLIC_BASE) && (m1_req_addr <= `PLIC_CLAIM_COMPLETE);
wire addr_is_uncached_m1 = addr_is_tube_m1 || addr_is_clint_m1 || addr_is_plic_m1;

// M2 (RoCC DMA) address decode - RAM-only access (0x0000_0000 - 0x0000_3FFF)
wire addr_is_ram_m2     = (m2_req_addr >= `RAM_CACHEABLE_BASE) && (m2_req_addr <= `RAM_CACHEABLE_TOP);
wire m2_cached_req      = m2_req_valid && addr_is_ram_m2;

// ═════════════════════════════════════════════════════════════════════════════
// L2 Arbiter Instance (only for cacheable traffic)
// ═════════════════════════════════════════════════════════════════════════════

// M1 cached request - filter out MMIO
wire        m1_cached_req   = m1_req_valid && !addr_is_uncached_m1;
wire        m1_cached_ready;

// M1 ready: MMIO is immediate, cached goes through arbiter
assign m1_req_ready = addr_is_uncached_m1 ? m1_mmio_req : m1_cached_ready;

l2_arbiter u_l2_arbiter (
    .clk            (clk),
    .rstn           (rstn),
    
    // Master 0: I-side (always cacheable)
    .m0_req_valid   (m0_req_valid),
    .m0_req_ready   (m0_req_ready),
    .m0_req_addr    (m0_req_addr),
    .m0_resp_valid  (m0_resp_valid),
    .m0_resp_data   (m0_resp_data),
    .m0_resp_last   (m0_resp_last),
    
    // Master 1: D-side (cacheable only - MMIO filtered out)
    .m1_req_valid   (m1_cached_req),
    .m1_req_ready   (m1_cached_ready),
    .m1_req_addr    (m1_req_addr),
    .m1_req_write   (m1_req_write),
    .m1_req_wdata   (m1_req_wdata),
    .m1_req_wen     (m1_req_wen),
    .m1_resp_valid  (m1_resp_valid_int),
    .m1_resp_data   (m1_resp_data_int),
    
    // Master 2: RoCC DMA (RAM-only cacheable access)
    .m2_req_valid   (m2_cached_req),
    .m2_req_ready   (m2_req_ready),
    .m2_req_addr    (m2_req_addr),
    .m2_req_write   (m2_req_write),
    .m2_req_wdata   (m2_req_wdata),
    .m2_req_wen     (m2_req_wen),
    .m2_resp_valid  (m2_resp_valid),
    .m2_resp_data   (m2_resp_data),
    
    // L2 Cache interface
    .l2_req_valid   (l2_req_valid),
    .l2_req_ready   (l2_req_ready),
    .l2_req_addr    (l2_req_addr),
    .l2_req_write   (l2_req_write),
    .l2_req_wdata   (l2_req_wdata),
    .l2_req_wen     (l2_req_wen),
    .l2_req_uncached(l2_req_uncached),
    .l2_resp_valid  (l2_resp_valid),
    .l2_resp_data   (l2_resp_data),
    .l2_resp_last   (l2_resp_last),
    
    // Status
    .grant_m0       (grant_m0),
    .grant_m1       (grant_m1),
    .grant_m2       (grant_m2),
    .grant_count    (grant_count)
);

// ═════════════════════════════════════════════════════════════════════════════
// L2 Cache Instance
// ═════════════════════════════════════════════════════════════════════════════

// RAM interface wires
wire [31:0] ram_addr;
wire        ram_write;
wire [31:0] ram_wdata;
wire [31:0] ram_rdata;
wire [2:0]  ram_word_idx;

// RAM read data assignment
assign ram_rdata = ram[ram_addr[13:2]];
// I-side miss fast path: source the requested instruction word from the
// shared mem_subsys RAM instead of a separate inst_backing_store image.
assign m0_bypass_data = ram[m0_bypass_addr[13:2]];


l2_cache u_l2_cache (
    .clk            (clk),
    .rstn           (rstn),
    
    // Request interface
    .req_valid      (l2_req_valid),
    .req_ready      (l2_req_ready),
    .req_addr       (l2_req_addr),
    .req_write      (l2_req_write),
    .req_wdata      (l2_req_wdata),
    .req_wen        (l2_req_wen),
    .req_uncached   (l2_req_uncached),
    
    // Response interface
    .resp_valid     (l2_resp_valid),
    .resp_data      (l2_resp_data),
    .resp_last      (l2_resp_last),
    
    // RAM interface
    .ram_addr       (ram_addr),
    .ram_write      (ram_write),
    .ram_wdata      (ram_wdata),
    .ram_rdata      (ram_rdata),
    .ram_word_idx   (ram_word_idx),
    
    // Status
    .cache_state    (cache_state),
    .cache_hit      (cache_hit),
    .cache_miss     (cache_miss)
);

// RAM write handling
always @(posedge clk) begin
    if (ram_write) begin
        ram[ram_addr[13:2]] <= ram_wdata;
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// MMIO Bypass Path (deterministic, bypasses L2 entirely)
// ═════════════════════════════════════════════════════════════════════════════

// Detect MMIO requests - these bypass the arbiter/L2 for deterministic access
wire        m1_mmio_req = m1_req_valid && addr_is_uncached_m1;

// CLINT wires - MMIO bypass (no grant needed)
wire        clint_req_valid = addr_is_clint_m1 && m1_mmio_req;
wire [31:0] clint_resp_rdata;
wire        clint_resp_valid;
wire        clint_timer_irq;

clint u_clint (
    .clk         (clk),
    .rstn        (rstn),
    .req_valid   (clint_req_valid),
    .req_addr    (m1_req_addr),
    .req_wen     (m1_req_write),
    .req_wdata   (m1_req_wdata),
    .resp_rdata  (clint_resp_rdata),
    .resp_valid  (clint_resp_valid),
    .timer_irq   (clint_timer_irq)
);

// PLIC wires - MMIO bypass (no grant needed)
wire        plic_req_valid = addr_is_plic_m1 && m1_mmio_req;
wire [31:0] plic_resp_rdata;
wire        plic_resp_valid;
wire        plic_ext_irq;

plic u_plic (
    .clk         (clk),
    .rstn        (rstn),
    .req_valid   (plic_req_valid),
    .req_addr    (m1_req_addr),
    .req_wen     (m1_req_write),
    .req_wdata   (m1_req_wdata),
    .resp_rdata  (plic_resp_rdata),
    .resp_valid  (plic_resp_valid),
    .ext_irq_src (ext_irq_src),
    .external_irq(plic_ext_irq)
);

assign ext_timer_irq    = clint_timer_irq;
assign ext_external_irq = plic_ext_irq;

// ═════════════════════════════════════════════════════════════════════════════
// M1 Response Mux (MMIO bypass takes priority over cached L2 path)
// ═════════════════════════════════════════════════════════════════════════════

wire        m1_resp_valid_int;
wire [31:0] m1_resp_data_int;

// Handle TUBE MMIO - deterministic bypass
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        tube_status <= 8'd0;
    end else begin
        if (addr_is_tube_m1 && m1_mmio_req && m1_req_write) begin
            tube_status <= m1_req_wdata[7:0];
        end
    end
end

// Response mux - MMIO valid immediately (no L2 latency)
wire        tube_resp_valid = addr_is_tube_m1 && m1_mmio_req;
wire [31:0] tube_resp_data  = 32'd0;

assign m1_resp_valid = m1_mmio_req ? (clint_resp_valid || plic_resp_valid || tube_resp_valid) : m1_resp_valid_int;
assign m1_resp_data  = clint_resp_valid ? clint_resp_rdata :
                       plic_resp_valid  ? plic_resp_rdata  :
                       tube_resp_valid  ? tube_resp_data   :
                       m1_resp_data_int;

// ═════════════════════════════════════════════════════════════════════════════
// RAM Preload Interface (for testbench)
// Testbench can access ram[] array directly via hierarchical reference
// ═════════════════════════════════════════════════════════════════════════════

endmodule