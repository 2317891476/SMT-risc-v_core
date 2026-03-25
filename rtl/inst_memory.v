// =============================================================================
// Module : inst_memory
// Description: Instruction memory with ICache integration.
//   - Wraps icache and inst_backing_store for testbench compatibility
//   - Preserves hierarchy: u_inst_memory.u_inst_backing_store.u_ram
//   - Presents synchronous RAM interface externally
//   - Internally uses nonblocking ICache with hit-under-miss
// =============================================================================
module inst_memory #(
    parameter IROM_SPACE = 4096
)(
    input  wire       clk,
    input  wire       rstn,
    input  wire [31:0] inst_addr,
    input  wire [0:0]  req_tid,           // Thread ID for request
    output wire [31:0] inst_o,
    output wire [0:0]  resp_tid,          // Thread ID for response
    output wire [3:0]  resp_epoch,        // Epoch for response
    output wire        resp_valid,        // Response is valid (not stale)

    // Epoch and flush interface from top level
    input  wire [3:0]  current_epoch,     // Current epoch for stale detection
    input  wire        flush              // Flush signal
);

// Internal signals
wire [31:0] icache_resp_data;
wire [0:0]  icache_resp_tid;
wire [3:0]  icache_resp_epoch;
wire        icache_resp_valid;
wire [31:0] backing_store_data;  // Direct read for bypass on miss

wire        mem_req_valid;
wire        mem_req_ready;
wire [31:0] mem_req_addr;
wire        mem_resp_valid;
wire [31:0] mem_resp_data;
wire        mem_resp_last;
wire        mem_resp_ready;

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
    .mem_req_valid    (mem_req_valid     ),
    .mem_req_ready    (mem_req_ready     ),
    .mem_req_addr     (mem_req_addr      ),
    .mem_resp_valid   (mem_resp_valid    ),
    .mem_resp_data    (mem_resp_data     ),
    .mem_resp_last    (mem_resp_last     ),
    .mem_resp_ready   (mem_resp_ready    ),

    // Bypass from direct backing store read
    .bypass_data      (backing_store_data)
);

// ICache Memory Adapter
icache_mem_adapter #(
    .ADDR_WIDTH   (32),
    .LINE_SIZE    (32),
    .IROM_SPACE   (IROM_SPACE)
) u_icache_adapter (
    .clk           (clk               ),
    .rstn          (rstn              ),
    .req_valid     (mem_req_valid     ),
    .req_ready     (mem_req_ready     ),
    .req_addr      (mem_req_addr      ),
    .resp_valid    (mem_resp_valid    ),
    .resp_data     (mem_resp_data     ),
    .resp_last     (mem_resp_last     ),
    .resp_ready    (mem_resp_ready    ),
    .mem_addr      (                  ),
    .mem_data      (backing_store_data)
);

// Backing Store (preserved hierarchy for testbench compatibility)
// This provides both the bypass data and the fill data
inst_backing_store #(
    .IROM_SPACE (IROM_SPACE)
) u_inst_backing_store (
    .clk       (clk               ),
    .rstn      (rstn              ),
    .inst_addr (inst_addr         ),  // Direct read address
    .inst_o    (backing_store_data)
);

// Output assignment
assign inst_o      = icache_resp_data;
assign resp_tid    = icache_resp_tid;
assign resp_epoch  = icache_resp_epoch;
assign resp_valid  = icache_resp_valid;

endmodule
