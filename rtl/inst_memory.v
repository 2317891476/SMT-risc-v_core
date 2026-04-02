// =============================================================================
// Module : inst_memory
// Description: Instruction memory with ICache integration for V2 architecture.
//   - Wraps icache and inst_backing_store for testbench compatibility
//   - Preserves hierarchy: u_inst_memory.u_inst_backing_store.u_ram
//   - Presents synchronous RAM interface externally
//   - Internally uses nonblocking ICache with hit-under-miss
//   - Exposes refill interface for connection to mem_subsys
// =============================================================================
module inst_memory #(
    parameter IROM_SPACE = 4096
)(
    input  wire       clk,
    input  wire       rstn,
    input  wire       req_valid,
    input  wire [31:0] inst_addr,
    input  wire [0:0]  req_tid,           // Thread ID for request
    output wire [31:0] inst_o,
    output wire [0:0]  resp_tid,          // Thread ID for response
    output wire [3:0]  resp_epoch,        // Epoch for response
    output wire        resp_valid,        // Response is valid (not stale)

    // Epoch and flush interface from top level
    input  wire [3:0]  current_epoch,     // Current epoch for stale detection
    input  wire        flush,             // Flush signal

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTERNAL REFILL INTERFACE (Connect to mem_subsys M0)
    // ═══════════════════════════════════════════════════════════════════════════
    // When USE_EXTERNAL_REFILL=1, these connect to mem_subsys
    // When USE_EXTERNAL_REFILL=0 (default), internal adapter is used
    output wire        ext_mem_req_valid,
    input  wire        ext_mem_req_ready,
    output wire [31:0] ext_mem_req_addr,
    input  wire        ext_mem_resp_valid,
    input  wire [31:0] ext_mem_resp_data,
    input  wire        ext_mem_resp_last,
    output wire        ext_mem_resp_ready,
    input  wire [31:0] ext_mem_bypass_data,
    input  wire        use_external_refill  // 1=use external refill, 0=internal
);

// Internal signals
wire [31:0] icache_resp_data;
wire [0:0]  icache_resp_tid;
wire [3:0]  icache_resp_epoch;
wire        icache_resp_valid;
wire [31:0] backing_store_data_raw;
wire [31:0] backing_store_data;
reg  [0:0]  legacy_resp_tid_r;
reg  [3:0]  legacy_resp_epoch_r;
reg         legacy_resp_valid_r;

// Backing store has 1-cycle read latency (synchronous RAM).
// When icache detects a miss on cycle N+1 for address presented on cycle N,
// the backing_store_data_raw IS the data for that address (1-cycle delayed).
// No additional register needed - the raw output aligns with miss detection.
assign backing_store_data = backing_store_data_raw;

wire [31:0] miss_bypass_data = use_external_refill ? ext_mem_bypass_data : backing_store_data;

// ICache memory interface signals
wire        icache_mem_req_valid;
wire        icache_mem_req_ready;
wire [31:0] icache_mem_req_addr;
wire        icache_mem_resp_valid;
wire [31:0] icache_mem_resp_data;
wire        icache_mem_resp_last;
wire        icache_mem_resp_ready;

// Internal adapter signals (for when use_external_refill=0)
wire        int_mem_req_ready;
wire        int_mem_resp_valid;
wire [31:0] int_mem_resp_data;
wire        int_mem_resp_last;

// Mux between external and internal refill interface
wire        mem_req_ready_mux  = use_external_refill ? ext_mem_req_ready  : int_mem_req_ready;
wire        mem_resp_valid_mux = use_external_refill ? ext_mem_resp_valid : int_mem_resp_valid;
wire [31:0] mem_resp_data_mux  = use_external_refill ? ext_mem_resp_data  : int_mem_resp_data;
wire        mem_resp_last_mux  = use_external_refill ? ext_mem_resp_last  : int_mem_resp_last;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        legacy_resp_tid_r   <= 1'b0;
        legacy_resp_epoch_r <= 4'd0;
        legacy_resp_valid_r <= 1'b0;
    end else begin
        legacy_resp_valid_r <= req_valid;
        if (req_valid) begin
            legacy_resp_tid_r   <= req_tid;
            legacy_resp_epoch_r <= current_epoch;
        end
    end
end

// ICache instance - synchronous interface
icache #(
    .CACHE_SIZE   (2048),
    .LINE_SIZE    (32),
    .WAYS         (1),
    .ADDR_WIDTH   (32),
    .TID_WIDTH    (1)
) u_icache (
    .clk              (clk               ),
    .rstn             (rstn              ),

    // Synchronous interface
    .cpu_req_valid    (req_valid         ),
    .cpu_req_addr     (inst_addr         ),
    .cpu_req_tid      (req_tid           ),
    .cpu_resp_data    (icache_resp_data  ),
    .cpu_resp_tid     (icache_resp_tid   ),
    .cpu_resp_epoch   (icache_resp_epoch ),
    .cpu_resp_valid   (icache_resp_valid ),

    // Epoch
    .current_epoch    (current_epoch     ),
    .flush            (flush             ),

    // Memory interface for fills
    .mem_req_valid    (icache_mem_req_valid ),
    .mem_req_ready    (icache_mem_req_ready ),
    .mem_req_addr     (icache_mem_req_addr  ),
    .mem_resp_valid   (icache_mem_resp_valid),
    .mem_resp_data    (icache_mem_resp_data ),
    .mem_resp_last    (icache_mem_resp_last ),
    .mem_resp_ready   (icache_mem_resp_ready),

    // Bypass from direct backing store read
    .bypass_data      (miss_bypass_data)
);

// External refill interface assignments
assign ext_mem_req_valid  = icache_mem_req_valid;
assign ext_mem_req_addr   = icache_mem_req_addr;
assign ext_mem_resp_ready = icache_mem_resp_ready;

// ICache memory interface connections (muxed)
assign icache_mem_req_ready  = mem_req_ready_mux;
assign icache_mem_resp_valid = mem_resp_valid_mux;
assign icache_mem_resp_data  = mem_resp_data_mux;
assign icache_mem_resp_last  = mem_resp_last_mux;

// ICache Memory Adapter (used when use_external_refill=0)
icache_mem_adapter #(
    .ADDR_WIDTH   (32),
    .LINE_SIZE    (32),
    .IROM_SPACE   (IROM_SPACE)
) u_icache_adapter (
    .clk           (clk               ),
    .rstn          (rstn              ),
    .req_valid     (icache_mem_req_valid ),
    .req_ready     (int_mem_req_ready    ),
    .req_addr      (icache_mem_req_addr  ),
    .resp_valid    (int_mem_resp_valid   ),
    .resp_data     (int_mem_resp_data    ),
    .resp_last     (int_mem_resp_last    ),
    .resp_ready    (1'b1                 ),  // Always ready when using internal adapter
    .mem_addr      (                     ),
    .mem_data      (backing_store_data   )
);

// Backing Store (preserved hierarchy for testbench compatibility)
// This provides both the bypass data and the fill data.
// Miss bypass must align with icache's registered req_addr_r on the following
// cycle, so the synchronous RAM should see the raw request address in cycle N.
inst_backing_store #(
    .IROM_SPACE (IROM_SPACE)
) u_inst_backing_store (
    .clk       (clk               ),
    .rstn      (rstn              ),
    .inst_addr (inst_addr         ),
    .inst_o    (backing_store_data_raw)
);

// Output assignment
assign inst_o      = use_external_refill ? icache_resp_data  : backing_store_data;
assign resp_tid    = use_external_refill ? icache_resp_tid   : legacy_resp_tid_r;
assign resp_epoch  = use_external_refill ? icache_resp_epoch : legacy_resp_epoch_r;
assign resp_valid  = use_external_refill ? icache_resp_valid : legacy_resp_valid_r;

endmodule
