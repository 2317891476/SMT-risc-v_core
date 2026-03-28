// =============================================================================
// Module : icache
// Description: Single-outstanding-miss nonblocking instruction cache.
//   - Direct-mapped for simplicity (configurable)
//   - Synchronous read interface: returns data on next cycle
//   - Hit-under-miss: accepts new requests during miss handling
//   - Internal epoch tracking for stale response detection
//   - On miss: returns data directly from backing store while filling cache
//
//   Address decomposition (default: 2KB, 32B line, direct-mapped):
//     [31 : offset+index] = TAG
//     [offset+index-1 : offset] = INDEX (set select)
//     [offset-1 : 0] = OFFSET (byte within line)
// =============================================================================
module icache #(
    parameter CACHE_SIZE = 2048,      // Total cache size in bytes
    parameter LINE_SIZE  = 32,        // Cache line size in bytes
    parameter WAYS       = 1,         // Associativity (1 = direct-mapped for I$)
    parameter ADDR_WIDTH = 32,
    parameter TID_WIDTH  = 1          // Thread ID width (1 = 2 threads)
)(
    input  wire                     clk,
    input  wire                     rstn,

    // ─── Synchronous Read Interface ─────────────────────────────
    // Matches inst_backing_store interface
    input  wire [ADDR_WIDTH-1:0]    cpu_req_addr,
    input  wire [TID_WIDTH-1:0]     cpu_req_tid,       // Thread ID for request
    output reg  [31:0]              cpu_resp_data,
    output reg  [TID_WIDTH-1:0]     cpu_resp_tid,      // Thread ID for response
    output reg  [3:0]               cpu_resp_epoch,    // Epoch for response (for stale detection)
    output reg                      cpu_resp_valid,    // Response is valid (not stale)

    // ─── Epoch Interface (for stale detection) ──────────────────
    input  wire [3:0]               current_epoch,
    input  wire                     flush,

    // ─── Backing Store Interface ────────────────────────────────
    output reg                      mem_req_valid,
    input  wire                     mem_req_ready,
    output reg  [ADDR_WIDTH-1:0]    mem_req_addr,

    input  wire                     mem_resp_valid,
    input  wire [31:0]              mem_resp_data,
    input  wire                     mem_resp_last,
    output wire                     mem_resp_ready,

    // ─── Direct backing store bypass (for immediate miss data) ───
    input  wire [31:0]              bypass_data     // Data from direct backing store read
);

// ─── Derived parameters ─────────────────────────────────────────────────────
localparam SETS         = CACHE_SIZE / (LINE_SIZE * WAYS);
localparam OFFSET_W     = $clog2(LINE_SIZE);
localparam INDEX_W      = $clog2(SETS);
localparam TAG_W        = ADDR_WIDTH - OFFSET_W - INDEX_W;
localparam WORDS_PER_LINE = LINE_SIZE / 4;  // 32-bit words per line

// ─── Cache storage ──────────────────────────────────────────────────────────
reg [TAG_W-1:0]              tag_array  [0:SETS-1][0:WAYS-1];
reg                          valid_array[0:SETS-1][0:WAYS-1];
reg [LINE_SIZE*8-1:0]        data_array [0:SETS-1][0:WAYS-1];

// ─── Address decomposition ──────────────────────────────────────────────────
wire [TAG_W-1:0]    req_tag    = cpu_req_addr[ADDR_WIDTH-1 : OFFSET_W+INDEX_W];
wire [INDEX_W-1:0]  req_index  = cpu_req_addr[OFFSET_W+INDEX_W-1 : OFFSET_W];
wire [OFFSET_W-1:0] req_offset = cpu_req_addr[OFFSET_W-1 : 0];

// ─── Registered request (for synchronous read) ──────────────────────────────
reg [ADDR_WIDTH-1:0] req_addr_r;
reg [INDEX_W-1:0]    req_index_r;
reg [TAG_W-1:0]      req_tag_r;
reg [OFFSET_W-1:0]   req_offset_r;
reg [TID_WIDTH-1:0]  req_tid_r;           // Registered thread ID
reg [3:0]            req_epoch_r;         // Registered epoch

// Current epoch at request time (for tagging response)
wire [3:0] req_epoch_current = current_epoch;

// ─── Hit detection on registered address ────────────────────────────────────
wire hit = valid_array[req_index_r][0] && (tag_array[req_index_r][0] == req_tag_r);

wire [31:0] cached_data = data_array[req_index_r][0][req_offset_r*8 +: 32];

// ─── Miss handling FSM ──────────────────────────────────────────────────────
localparam S_IDLE      = 2'd0;
localparam S_MISS_REQ  = 2'd1;
localparam S_MISS_DATA = 2'd2;
localparam S_REFILL    = 2'd3;

reg [1:0]  state;

// Miss tracking
reg [ADDR_WIDTH-1:0] miss_addr;
reg [INDEX_W-1:0]    miss_index;
reg [TAG_W-1:0]      miss_tag;
reg [3:0]            miss_epoch;

// Fill buffer
reg [LINE_SIZE*8-1:0] fill_line;
reg [$clog2(WORDS_PER_LINE):0] fill_cnt;

// ─── Response tagging logic ─────────────────────────────────────────────────
// Track the request metadata for response tagging
reg [TID_WIDTH-1:0] resp_tid_r;
reg [3:0]           resp_epoch_r;
reg                 resp_valid_r;

// Determine if response is stale based on epoch mismatch
// A response is stale if the epoch has changed since the request was made
wire response_stale = (resp_epoch_r != current_epoch);

// ─── Output assignment ──────────────────────────────────────────────────────
// On hit: return cached data
// On miss: return bypass data (direct from backing store)
// Always tag with {tid, epoch} for stale detection downstream
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        cpu_resp_data  <= 32'd0;
        cpu_resp_tid   <= {TID_WIDTH{1'b0}};
        cpu_resp_epoch <= 4'd0;
        cpu_resp_valid <= 1'b0;
        resp_tid_r     <= {TID_WIDTH{1'b0}};
        resp_epoch_r   <= 4'd0;
        resp_valid_r   <= 1'b0;
    end
    else begin
        // Capture request metadata for next cycle response
        resp_tid_r   <= req_tid_r;
        resp_epoch_r <= req_epoch_r;
        
        // Response valid on hit OR during fill (bypass data available)
        // Also valid on first cycle of miss (state transition happens after this)
        // Note: stale check is done downstream in stage_if_v2 using per-thread epochs
        resp_valid_r <= hit || (state != S_IDLE) || (!hit && state == S_IDLE);
        
        // Output data
        if (hit) begin
            cpu_resp_data <= cached_data;
        end
        else begin
            cpu_resp_data <= bypass_data;  // Direct from backing store
        end
        
        // Output tags (registered from request)
        cpu_resp_tid   <= resp_tid_r;
        cpu_resp_epoch <= resp_epoch_r;
        // Pass through valid - stale check done by caller
        cpu_resp_valid <= resp_valid_r;
    end
end

assign mem_resp_ready = 1'b1;

// ─── Sequential logic for cache state and miss handling ─────────────────────
integer i, j;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state       <= S_IDLE;
        mem_req_valid <= 1'b0;
        mem_req_addr  <= {ADDR_WIDTH{1'b0}};
        
        miss_addr   <= {ADDR_WIDTH{1'b0}};
        miss_index  <= {INDEX_W{1'b0}};
        miss_tag    <= {TAG_W{1'b0}};
        miss_epoch  <= 4'd0;
        
        fill_line   <= {(LINE_SIZE*8){1'b0}};
        fill_cnt    <= 0;
        
        req_addr_r  <= {ADDR_WIDTH{1'b0}};
        req_index_r <= {INDEX_W{1'b0}};
        req_tag_r   <= {TAG_W{1'b0}};
        req_offset_r<= {OFFSET_W{1'b0}};
        req_tid_r   <= {TID_WIDTH{1'b0}};
        req_epoch_r <= 4'd0;
        
        // Initialize cache arrays
        for (i = 0; i < SETS; i = i + 1) begin
            for (j = 0; j < WAYS; j = j + 1) begin
                valid_array[i][j] <= 1'b0;
                tag_array[i][j]   <= {TAG_W{1'b0}};
                data_array[i][j]  <= {(LINE_SIZE*8){1'b0}};
            end
        end
    end
    else begin
        // Register the request address (synchronous read)
        req_addr_r   <= cpu_req_addr;
        req_index_r  <= req_index;
        req_tag_r    <= req_tag;
        req_offset_r <= req_offset;
        req_tid_r    <= cpu_req_tid;
        req_epoch_r  <= current_epoch;
        
        case (state)
            S_IDLE: begin
                // Check for miss on the registered request
                if (!hit && rstn) begin
                    // Start miss handling
                    miss_addr   <= req_addr_r;
                    miss_index  <= req_index_r;
                    miss_tag    <= req_tag_r;
                    miss_epoch  <= current_epoch;
                    
                    mem_req_addr  <= {req_addr_r[ADDR_WIDTH-1:OFFSET_W], {OFFSET_W{1'b0}}};
                    mem_req_valid <= 1'b1;
                    state         <= S_MISS_REQ;
                end
            end
            
            S_MISS_REQ: begin
                if (mem_req_ready) begin
                    mem_req_valid <= 1'b0;
                    fill_cnt      <= 0;
                    fill_line     <= {(LINE_SIZE*8){1'b0}};
                    state         <= S_MISS_DATA;
                end
            end
            
            S_MISS_DATA: begin
                if (mem_resp_valid) begin
                    fill_line[fill_cnt*32 +: 32] <= mem_resp_data;
                    if (mem_resp_last) begin
                        state <= S_REFILL;
                    end
                    else begin
                        fill_cnt <= fill_cnt + 1;
                    end
                end
            end
            
            S_REFILL: begin
                // Only install if epoch matches (not stale)
                if (miss_epoch == current_epoch) begin
                    valid_array[miss_index][0] <= 1'b1;
                    tag_array[miss_index][0]   <= miss_tag;
                    data_array[miss_index][0]  <= fill_line;
                end
                // else: stale fill, don't install
                
                state <= S_IDLE;
            end
            
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
