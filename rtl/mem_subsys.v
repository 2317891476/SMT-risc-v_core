// =============================================================================
// Module : mem_subsys
// Description: Shared memory subsystem with unified L2 cache, arbiter, and MMIO.
//   - Serves both I-side (instruction refill) and D-side (LSU/store buffer)
//   - Implements blocking unified L2 cache with 32B lines, 4 ways, 8KB total
//   - Round-robin arbitration between I-side (master 0) and D-side (master 1)
//   - MMIO decode for TUBE, CLINT, PLIC (uncached)
//   - CLINT/PLIC registers stubbed (return 0) until Tasks 10-11
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
    // Testbench observation interface
    // ═══════════════════════════════════════════════════════════════════════════
    output reg [7:0]   tube_status,       // TUBE MMIO register (observable by tb)

    // ═══════════════════════════════════════════════════════════════════════════
    // External interrupt inputs (from PLIC, Task 11)
    // ═══════════════════════════════════════════════════════════════════════════
    output wire        ext_irq_pending    // External interrupt pending to csr_unit
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
// Address Decode
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
// Shared Backing RAM (4096 x 32-bit words = 16KB)
// ═════════════════════════════════════════════════════════════════════════════
reg [31:0] ram [0:4095];

// ═════════════════════════════════════════════════════════════════════════════
// MMIO Registers (stubbed for Task 4, implemented in Tasks 10-11)
// ═════════════════════════════════════════════════════════════════════════════
// CLINT registers (stubbed)
reg [63:0] clint_mtime;
reg [63:0] clint_mtimecmp;
wire       clint_mtip = (clint_mtime >= clint_mtimecmp);

// PLIC registers (stubbed)
reg [2:0]  plic_priority1;
reg        plic_pending;
reg        plic_enable;
reg [2:0]  plic_threshold;
reg [31:0] plic_claim;
wire       plic_meip = plic_pending && plic_enable && (plic_priority1 > plic_threshold);

// External interrupt output (wired to csr_unit in top level)
assign ext_irq_pending = plic_meip;

// ═════════════════════════════════════════════════════════════════════════════
// Round-Robin Arbiter
// ═════════════════════════════════════════════════════════════════════════════
// Alternates between M0 and M1 each cycle when both request
// When one master is in a multi-cycle operation, the other is stalled

reg arbiter_state;  // 0 = priority to M0, 1 = priority to M1
reg arbiter_last_grant; // Track last granted master for round-robin

// Arbitrate between masters
// M0 (I-side) requests are always reads to cacheable memory
// M1 (D-side) requests can be reads or writes to cached or uncached memory

wire m0_requesting = m0_req_valid;
wire m1_requesting = m1_req_valid;

// Current arbitration winner
reg master_select;  // 0 = M0, 1 = M1
reg master_select_r; // Registered for multi-cycle operations

// Round-robin arbitration logic
always @(*) begin
    if (!m0_requesting && !m1_requesting) begin
        master_select = arbiter_last_grant; // Keep last state when idle
    end else if (m0_requesting && !m1_requesting) begin
        master_select = 1'b0; // Only M0 requesting
    end else if (!m0_requesting && m1_requesting) begin
        master_select = 1'b1; // Only M1 requesting
    end else begin
        // Both requesting - round-robin
        master_select = ~arbiter_last_grant;
    end
end

// Update arbiter state
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        arbiter_last_grant <= 1'b0;
        master_select_r <= 1'b0;
    end else begin
        // Update last_grant when a request is accepted
        if (m0_req_ready && m0_req_valid) begin
            arbiter_last_grant <= 1'b0;
            master_select_r <= 1'b0;
        end else if (m1_req_ready && m1_req_valid) begin
            arbiter_last_grant <= 1'b1;
            master_select_r <= 1'b1;
        end
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// L2 Cache Arrays
// ═════════════════════════════════════════════════════════════════════════════

// Tag array: [valid, dirty, tag]
// Each entry: 1 + 1 + 21 = 23 bits
reg [L2_TAG_W+1:0] l2_tag_array [0:L2_SETS-1][0:L2_WAYS-1];

// Data array: 32 bytes per line
// Organized as 8 words (32-bit) per line × 4 ways × 64 sets
reg [31:0] l2_data_array [0:L2_SETS-1][0:L2_WAYS-1][0:L2_WORDS_PER_LINE-1];

// PLRU state: 3 bits per set (tree structure for 4-way)
// Bits: [2:1] = level 1 (way select), [0] = level 0
reg [2:0] l2_plru [0:L2_SETS-1];

// ═════════════════════════════════════════════════════════════════════════════
// L2 Cache State Machine
// ═════════════════════════════════════════════════════════════════════════════

localparam L2_IDLE      = 3'd0;
localparam L2_LOOKUP    = 3'd1;
localparam L2_MISS      = 3'd2;
localparam L2_REFILL    = 3'd3;
localparam L2_WRITE_BACK= 3'd4;
localparam L2_UNCACHED  = 3'd5;
localparam L2_UPDATE    = 3'd6;

reg [2:0] l2_state;
reg [2:0] l2_state_next;

// Current transaction registers
reg        l2_active;           // L2 is processing a request
reg        l2_master;           // Which master: 0=M0, 1=M1
reg [31:0] l2_addr;
reg        l2_write;            // Write request
reg [31:0] l2_wdata;
reg [3:0]  l2_wen;
reg        l2_uncached;         // Uncached access

// Cache line address breakdown
wire [L2_TAG_W-1:0]    req_tag    = l2_addr[31:L2_SET_IDX_W+L2_OFFSET_W];
wire [L2_SET_IDX_W-1:0] req_set   = l2_addr[L2_SET_IDX_W+L2_OFFSET_W-1:L2_OFFSET_W];
wire [L2_OFFSET_W-1:0]  req_offset= l2_addr[L2_OFFSET_W-1:0];
wire [2:0]              req_word  = l2_addr[4:2]; // Word index within line

// Tag comparison results
wire [L2_TAG_W-1:0] tag_way [0:L2_WAYS-1];
wire way_valid [0:L2_WAYS-1];
wire way_dirty [0:L2_WAYS-1];
wire way_hit [0:L2_WAYS-1];
reg [1:0] hit_way;
reg hit;

// Extract tag array fields
assign tag_way[0] = l2_tag_array[req_set][0][L2_TAG_W-1:0];
assign tag_way[1] = l2_tag_array[req_set][1][L2_TAG_W-1:0];
assign tag_way[2] = l2_tag_array[req_set][2][L2_TAG_W-1:0];
assign tag_way[3] = l2_tag_array[req_set][3][L2_TAG_W-1:0];

assign way_valid[0] = l2_tag_array[req_set][0][L2_TAG_W];
assign way_valid[1] = l2_tag_array[req_set][1][L2_TAG_W];
assign way_valid[2] = l2_tag_array[req_set][2][L2_TAG_W];
assign way_valid[3] = l2_tag_array[req_set][3][L2_TAG_W];

assign way_dirty[0] = l2_tag_array[req_set][0][L2_TAG_W+1];
assign way_dirty[1] = l2_tag_array[req_set][1][L2_TAG_W+1];
assign way_dirty[2] = l2_tag_array[req_set][2][L2_TAG_W+1];
assign way_dirty[3] = l2_tag_array[req_set][3][L2_TAG_W+1];

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
    // l2_plru[2:1] selects between pairs: 0 = way0/1, 1 = way2/3
    // l2_plru[0] selects within pair: 0 = even, 1 = odd
    case (l2_plru[req_set][2:1])
        2'b00: victim_way = {1'b0, l2_plru[req_set][0]}; // Select way 0 or 1
        2'b01: victim_way = {1'b1, l2_plru[req_set][0]}; // Select way 2 or 3
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

// Write-back address calculation
wire [31:0] wb_addr = {tag_way[victim_way], req_set, 5'b0};

// ═════════════════════════════════════════════════════════════════════════════
// L2 Cache State Machine - Sequential Logic
// ═════════════════════════════════════════════════════════════════════════════

reg [31:0] l2_resp_data_r;
reg        l2_m0_resp_valid_r;
reg        l2_m1_resp_valid_r;
reg        l2_m0_resp_last_r;
reg [2:0]  m0_beat_cnt;

// Request registers
reg        m0_req_accepted;
reg        m1_req_accepted;

// Loop indices
integer init_idx;
integer wb_idx;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        l2_state <= L2_IDLE;
        l2_active <= 1'b0;
        l2_master <= 1'b0;
        l2_addr <= 32'd0;
        l2_write <= 1'b0;
        l2_wdata <= 32'd0;
        l2_wen <= 4'd0;
        l2_uncached <= 1'b0;
        refill_cnt <= 4'd0;
        l2_resp_data_r <= 32'd0;
        l2_m0_resp_valid_r <= 1'b0;
        l2_m1_resp_valid_r <= 1'b0;
        l2_m0_resp_last_r <= 1'b0;
        m0_beat_cnt <= 3'd0;
        m0_req_accepted <= 1'b0;
        m1_req_accepted <= 1'b0;
        // Initialize PLRU
        for (init_idx = 0; init_idx < L2_SETS; init_idx = init_idx + 1) begin
            l2_plru[init_idx] <= 3'd0;
        end
    end else begin
        // Default: clear response valid
        l2_m0_resp_valid_r <= 1'b0;
        l2_m1_resp_valid_r <= 1'b0;
        l2_m0_resp_last_r <= 1'b0;
        
        // Update MMIO registers (CLINT time always increments)
        clint_mtime <= clint_mtime + 64'd1;
        
        case (l2_state)
            L2_IDLE: begin
                refill_cnt <= 4'd0;
                m0_beat_cnt <= 3'd0;
                
                // Check for M1 uncached request (priority for MMIO)
                if (m1_req_valid && addr_is_uncached_m1) begin
                    l2_state <= L2_UNCACHED;
                    l2_active <= 1'b1;
                    l2_master <= 1'b1;
                    l2_addr <= m1_req_addr;
                    l2_write <= m1_req_write;
                    l2_wdata <= m1_req_wdata;
                    l2_wen <= m1_req_wen;
                    l2_uncached <= 1'b1;
                    m1_req_accepted <= 1'b1;
                end
                // Check for M0 request (I-side cacheable)
                else if (m0_req_valid && addr_is_ram_m0) begin
                    l2_state <= L2_LOOKUP;
                    l2_active <= 1'b1;
                    l2_master <= 1'b0;
                    l2_addr <= m0_req_addr;
                    l2_write <= 1'b0;
                    l2_wdata <= 32'd0;
                    l2_wen <= 4'd0;
                    l2_uncached <= 1'b0;
                    m0_req_accepted <= 1'b1;
                end
                // Check for M1 cached request
                else if (m1_req_valid && addr_is_ram_m1) begin
                    l2_state <= L2_LOOKUP;
                    l2_active <= 1'b1;
                    l2_master <= 1'b1;
                    l2_addr <= m1_req_addr;
                    l2_write <= m1_req_write;
                    l2_wdata <= m1_req_wdata;
                    l2_wen <= m1_req_wen;
                    l2_uncached <= 1'b0;
                    m1_req_accepted <= 1'b1;
                end
            end
            
            L2_LOOKUP: begin
                m0_req_accepted <= 1'b0;
                m1_req_accepted <= 1'b0;
                
                if (hit) begin
                    // Cache hit - update PLRU and return data
                    // Update PLRU: mark hit way as most recently used
                    case (hit_way)
                        2'd0: l2_plru[req_set] <= {l2_plru[req_set][2], 2'b11};
                        2'd1: l2_plru[req_set] <= {l2_plru[req_set][2], 2'b10};
                        2'd2: l2_plru[req_set] <= {l2_plru[req_set][2], 2'b01};
                        2'd3: l2_plru[req_set] <= {l2_plru[req_set][2], 2'b00};
                    endcase
                    l2_plru[req_set][2] <= hit_way[1];
                    
                    if (l2_write) begin
                        // Write hit - update cache line
                        l2_state <= L2_UPDATE;
                    end else begin
                        // Read hit - return data
                        l2_resp_data_r <= l2_data_array[req_set][hit_way][req_word];
                        if (l2_master == 1'b0) begin
                            l2_m0_resp_valid_r <= 1'b1;
                            l2_m0_resp_last_r <= (m0_beat_cnt == 3'd7);
                            m0_beat_cnt <= m0_beat_cnt + 3'd1;
                            if (m0_beat_cnt == 3'd7) begin
                                l2_state <= L2_IDLE;
                                l2_active <= 1'b0;
                                m0_beat_cnt <= 3'd0;
                            end
                        end else begin
                            l2_m1_resp_valid_r <= 1'b1;
                            l2_state <= L2_IDLE;
                            l2_active <= 1'b0;
                        end
                    end
                end else begin
                    // Cache miss - go to miss handling
                    l2_state <= L2_MISS;
                end
            end
            
            L2_UPDATE: begin
                // Perform write to cache line
                if (l2_wen[0]) l2_data_array[req_set][hit_way][req_word][7:0]   <= l2_wdata[7:0];
                if (l2_wen[1]) l2_data_array[req_set][hit_way][req_word][15:8]  <= l2_wdata[15:8];
                if (l2_wen[2]) l2_data_array[req_set][hit_way][req_word][23:16] <= l2_wdata[23:16];
                if (l2_wen[3]) l2_data_array[req_set][hit_way][req_word][31:24] <= l2_wdata[31:24];
                
                // Set dirty bit
                l2_tag_array[req_set][hit_way][L2_TAG_W+1] <= 1'b1;
                
                // Return response
                l2_resp_data_r <= l2_wdata;
                l2_m1_resp_valid_r <= 1'b1;
                
                l2_state <= L2_IDLE;
                l2_active <= 1'b0;
            end
            
            L2_MISS: begin
                // Blocking: stall both masters
                // Check if victim line needs write-back
                if (way_valid[victim_way] && way_dirty[victim_way]) begin
                    l2_state <= L2_WRITE_BACK;
                end else begin
                    l2_state <= L2_REFILL;
                end
            end
            
            L2_WRITE_BACK: begin
                // Write back dirty line to RAM
                // For simplicity, do this in one cycle (would take 8 cycles in real implementation)
                // Write all 8 words of the victim line to backing RAM
                for (wb_idx = 0; wb_idx < L2_WORDS_PER_LINE; wb_idx = wb_idx + 1) begin
                    ram[{tag_way[victim_way], req_set, wb_idx[2:0]}] <= l2_data_array[req_set][victim_way][wb_idx];
                end
                l2_state <= L2_REFILL;
            end
            
            L2_REFILL: begin
                // Refill cache line from RAM over 8 cycles
                // Each cycle read one word from backing RAM
                ram[{req_tag, req_set, refill_cnt[2:0]}] <= ram[{req_tag, req_set, refill_cnt[2:0]}]; // Keep RAM value
                l2_data_array[req_set][victim_way][refill_cnt[2:0]] <= ram[{req_tag, req_set, refill_cnt[2:0]}];
                
                // Update tag array on last beat
                if (refill_done) begin
                    l2_tag_array[req_set][victim_way] <= {1'b0, 1'b1, req_tag}; // not dirty, valid, tag
                    l2_state <= L2_LOOKUP; // Go back to lookup (now should hit)
                end else begin
                    refill_cnt <= refill_cnt + 4'd1;
                end
            end
            
            L2_UNCACHED: begin
                // Handle uncached M1 request
                m1_req_accepted <= 1'b0;
                
                if (addr_is_tube_m1) begin
                    // TUBE MMIO
                    if (l2_write) begin
                        tube_status <= l2_wdata[7:0];
                    end
                    l2_resp_data_r <= 32'd0;
                    l2_m1_resp_valid_r <= 1'b1;
                end else if (addr_is_clint_m1) begin
                    // CLINT MMIO handled by clint module (combinational response)
                    l2_resp_data_r <= clint_resp_rdata;
                    l2_m1_resp_valid_r <= clint_resp_valid;
                end else if (addr_is_plic_m1) begin
                    // PLIC MMIO handled by plic module (combinational response)
                    l2_resp_data_r <= plic_resp_rdata;
                    l2_m1_resp_valid_r <= plic_resp_valid;
                end else begin
                    // Fallback to RAM for uncached RAM access
                    if (l2_write) begin
                        if (l2_wen[0]) ram[l2_addr[13:2]][7:0]   <= l2_wdata[7:0];
                        if (l2_wen[1]) ram[l2_addr[13:2]][15:8]  <= l2_wdata[15:8];
                        if (l2_wen[2]) ram[l2_addr[13:2]][23:16] <= l2_wdata[23:16];
                        if (l2_wen[3]) ram[l2_addr[13:2]][31:24] <= l2_wdata[31:24];
                    end
                    l2_resp_data_r <= ram[l2_addr[13:2]];
                    l2_m1_resp_valid_r <= 1'b1;
                end
                
                l2_state <= L2_IDLE;
                l2_active <= 1'b0;
            end
            
            default: l2_state <= L2_IDLE;
        endcase
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// CLINT and PLIC Instances
// ═════════════════════════════════════════════════════════════════════════════

// CLINT wires
wire        clint_req_valid = addr_is_clint_m1 && m1_req_valid && (l2_state == L2_IDLE);
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

// PLIC wires
wire        plic_req_valid = addr_is_plic_m1 && m1_req_valid && (l2_state == L2_IDLE);
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
    .ext_irq_src (1'b0),  // TODO: Connect external interrupt source
    .external_irq(plic_ext_irq)
);

// External interrupt pending (OR of timer and external IRQs)
assign ext_irq_pending = clint_timer_irq || plic_ext_irq;

// ═════════════════════════════════════════════════════════════════════════════
// Interface Assignments
// ═════════════════════════════════════════════════════════════════════════════

// Ready signals - only ready when IDLE and not handling a miss
// When in miss state, both masters are stalled
assign m0_req_ready = (l2_state == L2_IDLE) && m0_req_valid && !m1_req_valid && addr_is_ram_m0 && !m1_req_accepted;
assign m1_req_ready = (l2_state == L2_IDLE) && m1_req_valid && !m0_req_valid && !m0_req_accepted;

// Response outputs
assign m0_resp_valid = l2_m0_resp_valid_r;
assign m0_resp_data  = l2_resp_data_r;
assign m0_resp_last  = l2_m0_resp_last_r;

// M1 response mux: CLINT/PLIC responses take priority
assign m1_resp_valid = l2_m1_resp_valid_r || clint_resp_valid || plic_resp_valid;
assign m1_resp_data  = clint_resp_valid ? clint_resp_rdata :
                       plic_resp_valid  ? plic_resp_rdata  :
                       l2_resp_data_r;

// ═════════════════════════════════════════════════════════════════════════════
// RAM Preload Interface (for testbench)
// Testbench can access ram[] array directly via hierarchical reference
// ═════════════════════════════════════════════════════════════════════════════

endmodule
