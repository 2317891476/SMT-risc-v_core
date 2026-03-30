// =============================================================================
// Module : l2_cache
// Description: Blocking unified L2 cache with 32B lines, 4 ways, 8KB total.
//   - Blocking design: one outstanding miss only
//   - Write-back + write-allocate for RAM-window stores
//   - PLRU replacement policy
//   - Interfaces with backing RAM for refill and write-back
// =============================================================================
`include "define.v"

module l2_cache (
    input  wire        clk,
    input  wire        rstn,

    // ═══════════════════════════════════════════════════════════════════════════
    // Request interface (from arbiter)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] req_addr,
    input  wire        req_write,       // 0=read, 1=write
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wen,         // Byte-wise write enable
    input  wire        req_uncached,    // Bypass cache for MMIO

    // ═══════════════════════════════════════════════════════════════════════════
    // Response interface (to arbiter)
    // ═══════════════════════════════════════════════════════════════════════════
    output wire        resp_valid,
    output wire [31:0] resp_data,
    output wire        resp_last,       // Last beat of multi-beat refill

    // ═══════════════════════════════════════════════════════════════════════════
    // Backing RAM interface (for refill and write-back)
    // ═══════════════════════════════════════════════════════════════════════════
    output wire [31:0] ram_addr,        // RAM address for read/write
    output wire        ram_write,       // RAM write enable
    output wire [31:0] ram_wdata,       // RAM write data
    input  wire [31:0] ram_rdata,       // RAM read data
    output wire [2:0]  ram_word_idx,    // Word index within line

    // ═══════════════════════════════════════════════════════════════════════════
    // Cache status (for debugging/tests)
    // ═══════════════════════════════════════════════════════════════════════════
    output wire [2:0]  cache_state,
    output wire        cache_hit,
    output wire        cache_miss
);

// ═════════════════════════════════════════════════════════════════════════════
// L2 Cache Parameters
// ═════════════════════════════════════════════════════════════════════════════
localparam L2_SIZE_BYTES    = 8192;     // 8KB total
localparam L2_WAYS          = 4;        // 4-way set associative
localparam L2_LINE_BYTES    = 32;       // 32-byte cache lines
localparam L2_SETS          = L2_SIZE_BYTES / (L2_WAYS * L2_LINE_BYTES); // 64 sets
localparam L2_SET_IDX_W     = 6;        // log2(64) = 6 bits
localparam L2_OFFSET_W      = 5;        // log2(32) = 5 bits
localparam L2_TAG_W         = 32 - L2_SET_IDX_W - L2_OFFSET_W; // 21 bits
localparam L2_WORDS_PER_LINE = L2_LINE_BYTES / 4; // 8 words per line
localparam L2_REFILL_CYCLES = 8;        // 8 cycles to refill 32B line

// ═════════════════════════════════════════════════════════════════════════════
// Cache Arrays
// ═════════════════════════════════════════════════════════════════════════════

// Tag array: [valid, dirty, tag]
// Each entry: 1 + 1 + 21 = 23 bits
reg [L2_TAG_W+1:0] tag_array [0:L2_SETS-1][0:L2_WAYS-1];

// Data array: 32 bytes per line
// Organized as 8 words (32-bit) per line × 4 ways × 64 sets
reg [31:0] data_array [0:L2_SETS-1][0:L2_WAYS-1][0:L2_WORDS_PER_LINE-1];

// PLRU state: 3 bits per set (tree structure for 4-way)
// Bits: [2:1] = level 1 (way select), [0] = level 0
reg [2:0] plru [0:L2_SETS-1];

// ═════════════════════════════════════════════════════════════════════════════
// Cache State Machine
// ═════════════════════════════════════════════════════════════════════════════

localparam IDLE       = 3'd0;
localparam LOOKUP     = 3'd1;
localparam MISS       = 3'd2;
localparam REFILL     = 3'd3;
localparam WRITE_BACK = 3'd4;
localparam UNCACHED   = 3'd5;
localparam UPDATE     = 3'd6;

reg [2:0] state;

// Current transaction registers
reg        active;
reg [31:0] addr;
reg        write;
reg [31:0] wdata;
reg [3:0]  wen;
reg        uncached;

// Cache line address breakdown
wire [L2_TAG_W-1:0]     req_tag    = addr[31:L2_SET_IDX_W+L2_OFFSET_W];
wire [L2_SET_IDX_W-1:0] req_set    = addr[L2_SET_IDX_W+L2_OFFSET_W-1:L2_OFFSET_W];
wire [L2_OFFSET_W-1:0]  req_offset = addr[L2_OFFSET_W-1:0];
wire [2:0]              req_word   = addr[4:2]; // Word index within line
wire [31:0]             hit_word_data = data_array[req_set][hit_way][req_word];
wire [31:0]             update_word_data = {
    wen[3] ? wdata[31:24] : hit_word_data[31:24],
    wen[2] ? wdata[23:16] : hit_word_data[23:16],
    wen[1] ? wdata[15:8]  : hit_word_data[15:8],
    wen[0] ? wdata[7:0]   : hit_word_data[7:0]
};

// Tag comparison results
wire [L2_TAG_W-1:0] tag_way [0:L2_WAYS-1];
wire way_valid [0:L2_WAYS-1];
wire way_dirty [0:L2_WAYS-1];
wire way_hit [0:L2_WAYS-1];
reg [1:0] hit_way;
reg hit;

// Extract tag array fields
assign tag_way[0] = tag_array[req_set][0][L2_TAG_W-1:0];
assign tag_way[1] = tag_array[req_set][1][L2_TAG_W-1:0];
assign tag_way[2] = tag_array[req_set][2][L2_TAG_W-1:0];
assign tag_way[3] = tag_array[req_set][3][L2_TAG_W-1:0];

assign way_valid[0] = tag_array[req_set][0][L2_TAG_W];
assign way_valid[1] = tag_array[req_set][1][L2_TAG_W];
assign way_valid[2] = tag_array[req_set][2][L2_TAG_W];
assign way_valid[3] = tag_array[req_set][3][L2_TAG_W];

assign way_dirty[0] = tag_array[req_set][0][L2_TAG_W+1];
assign way_dirty[1] = tag_array[req_set][1][L2_TAG_W+1];
assign way_dirty[2] = tag_array[req_set][2][L2_TAG_W+1];
assign way_dirty[3] = tag_array[req_set][3][L2_TAG_W+1];

assign way_hit[0] = way_valid[0] && (tag_way[0] == req_tag);
assign way_hit[1] = way_valid[1] && (tag_way[1] == req_tag);
assign way_hit[2] = way_valid[2] && (tag_way[2] == req_tag);
assign way_hit[3] = way_valid[3] && (tag_way[3] == req_tag);

// Hit detection (combinational)
always @(*) begin
    hit = 1'b0;
    hit_way = 2'd0;
    if (way_hit[0]) begin hit = 1'b1; hit_way = 2'd0; end
    else if (way_hit[1]) begin hit = 1'b1; hit_way = 2'd1; end
    else if (way_hit[2]) begin hit = 1'b1; hit_way = 2'd2; end
    else if (way_hit[3]) begin hit = 1'b1; hit_way = 2'd3; end
end

// PLRU replacement (victim selection)
reg [1:0] victim_way;
always @(*) begin
    // Tree-based PLRU for 4-way
    case (plru[req_set][2:1])
        2'b00: victim_way = {1'b0, plru[req_set][0]};
        2'b01: victim_way = {1'b1, plru[req_set][0]};
        default: victim_way = 2'd0;
    endcase
    
    // If there's an invalid way, use that instead
    if (!way_valid[0]) victim_way = 2'd0;
    else if (!way_valid[1]) victim_way = 2'd1;
    else if (!way_valid[2]) victim_way = 2'd2;
    else if (!way_valid[3]) victim_way = 2'd3;
end

// Refill counter
reg [3:0] refill_cnt;
wire refill_done = (refill_cnt == L2_REFILL_CYCLES - 1);

// ═════════════════════════════════════════════════════════════════════════════
// Sequential Logic
// ═════════════════════════════════════════════════════════════════════════════

reg [31:0] resp_data_r;
reg        resp_valid_r;
reg        resp_last_r;

integer init_idx;
integer wb_idx;
integer init_way;
integer init_word;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state <= IDLE;
        active <= 1'b0;
        addr <= 32'd0;
        write <= 1'b0;
        wdata <= 32'd0;
        wen <= 4'd0;
        uncached <= 1'b0;
        refill_cnt <= 4'd0;
        resp_data_r <= 32'd0;
        resp_valid_r <= 1'b0;
        resp_last_r <= 1'b0;
        for (init_idx = 0; init_idx < L2_SETS; init_idx = init_idx + 1) begin
            plru[init_idx] <= 3'd0;
            for (init_way = 0; init_way < L2_WAYS; init_way = init_way + 1) begin
                tag_array[init_idx][init_way] <= {(L2_TAG_W+2){1'b0}};
                for (init_word = 0; init_word < L2_WORDS_PER_LINE; init_word = init_word + 1) begin
                    data_array[init_idx][init_way][init_word] <= 32'd0;
                end
            end
        end
    end else begin
        // Default: clear response valid
        resp_valid_r <= 1'b0;
        resp_last_r <= 1'b0;
        
        case (state)
            IDLE: begin
                refill_cnt <= 4'd0;
                
                if (req_valid) begin
                    `ifndef SYNTHESIS
                    $display("[L2 CACHE] accept addr=%h write=%0b uncached=%0b state=%0d",
                             req_addr, req_write, req_uncached, state);
                    `endif
                    if (req_uncached) begin
                        state <= UNCACHED;
                        active <= 1'b1;
                        addr <= req_addr;
                        write <= req_write;
                        wdata <= req_wdata;
                        wen <= req_wen;
                        uncached <= 1'b1;
                    end else begin
                        state <= LOOKUP;
                        active <= 1'b1;
                        addr <= req_addr;
                        write <= req_write;
                        wdata <= req_wdata;
                        wen <= req_wen;
                        uncached <= 1'b0;
                    end
                end
            end
            
            LOOKUP: begin
                `ifndef SYNTHESIS
                $display("[L2 CACHE] lookup addr=%h hit=%0b hit_way=%0d valid=%b%b%b%b tag=%h/%h/%h/%h",
                         addr, hit, hit_way,
                         way_valid[3], way_valid[2], way_valid[1], way_valid[0],
                         tag_way[0], tag_way[1], tag_way[2], tag_way[3]);
                `endif
                if (hit) begin
                    // Cache hit - update PLRU and return data
                    case (hit_way)
                        2'd0: plru[req_set] <= {plru[req_set][2], 2'b11};
                        2'd1: plru[req_set] <= {plru[req_set][2], 2'b10};
                        2'd2: plru[req_set] <= {plru[req_set][2], 2'b01};
                        2'd3: plru[req_set] <= {plru[req_set][2], 2'b00};
                    endcase
                    plru[req_set][2] <= hit_way[1];
                    
                    if (write) begin
                        state <= UPDATE;
                    end else begin
                        resp_data_r <= data_array[req_set][hit_way][req_word];
                        resp_valid_r <= 1'b1;
                        resp_last_r <= 1'b1;
                        state <= IDLE;
                        active <= 1'b0;
                    end
                end else begin
                    `ifndef SYNTHESIS
                    $display("[L2 CACHE] miss addr=%h victim=%0d dirty=%0b",
                             addr, victim_way, way_dirty[victim_way]);
                    `endif
                    state <= MISS;
                end
            end
            
            UPDATE: begin
                // Perform write to cache line
                if (wen[0]) data_array[req_set][hit_way][req_word][7:0]   <= wdata[7:0];
                if (wen[1]) data_array[req_set][hit_way][req_word][15:8]  <= wdata[15:8];
                if (wen[2]) data_array[req_set][hit_way][req_word][23:16] <= wdata[23:16];
                if (wen[3]) data_array[req_set][hit_way][req_word][31:24] <= wdata[31:24];
                
                // Keep the backing RAM coherent on store hits so the shared
                // mem_subsys image reflects architecturally committed memory.
                tag_array[req_set][hit_way][L2_TAG_W+1] <= 1'b0;
                
                resp_data_r <= wdata;
                resp_valid_r <= 1'b1;
                resp_last_r <= 1'b1;
                
                state <= IDLE;
                active <= 1'b0;
            end
            
            MISS: begin
                if (way_valid[victim_way] && way_dirty[victim_way]) begin
                    state <= WRITE_BACK;
                end else begin
                    state <= REFILL;
                end
            end
            
            WRITE_BACK: begin
                // Single-cycle write-back for simulation
                state <= REFILL;
            end
            
            REFILL: begin
                // Refill from RAM
                data_array[req_set][victim_way][refill_cnt[2:0]] <= ram_rdata;
                `ifndef SYNTHESIS
                $display("[L2 CACHE] refill cnt=%0d ram_addr=%h ram_rdata=%h victim=%0d",
                         refill_cnt, ram_addr, ram_rdata, victim_way);
                `endif
                
                if (refill_done) begin
                    tag_array[req_set][victim_way] <= {1'b0, 1'b1, req_tag};
                    state <= LOOKUP;
                end else begin
                    refill_cnt <= refill_cnt + 4'd1;
                end
            end
            
            UNCACHED: begin
                resp_data_r <= ram_rdata;
                resp_valid_r <= 1'b1;
                resp_last_r <= 1'b1;
                state <= IDLE;
                active <= 1'b0;
            end
            
            default: state <= IDLE;
        endcase
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// Output Assignments
// ═════════════════════════════════════════════════════════════════════════════

assign req_ready = (state == IDLE);
assign resp_valid = resp_valid_r;
assign resp_data = resp_data_r;
assign resp_last = resp_last_r;

// RAM interface
assign ram_addr = (state == UPDATE)
    ? {req_tag, req_set, req_word, 2'b0}
    : ({req_tag, req_set, 5'b0} + {26'd0, refill_cnt[2:0], 2'b0});
assign ram_write = (state == WRITE_BACK) || (state == UPDATE);
assign ram_wdata = (state == UPDATE) ? update_word_data : data_array[req_set][victim_way][ram_word_idx];
assign ram_word_idx = refill_cnt[2:0];

// Status outputs
assign cache_state = state;
assign cache_hit = (state == LOOKUP) && hit;
assign cache_miss = (state == MISS) || ((state == LOOKUP) && !hit && active);

endmodule
