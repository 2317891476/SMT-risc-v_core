// =============================================================================
// Module : icache
// Description: Simple direct-mapped instruction cache with one background refill.
//   - IF provides an explicit request-valid pulse for each launched fetch.
//   - Response is aligned 1 cycle later with the registered request metadata.
//   - On miss, the requested word is returned from bypass_data while the line
//     refills in the background.
//   - Only one line refill is tracked at a time, which is sufficient for the
//     serialized fetch path used by stage_if in this project.
// =============================================================================
module icache #(
    parameter CACHE_SIZE = 2048,
    parameter LINE_SIZE  = 32,
    parameter WAYS       = 1,
    parameter ADDR_WIDTH = 32,
    parameter TID_WIDTH  = 1
)(
    input  wire                     clk,
    input  wire                     rstn,

    // Synchronous fetch request/response
    input  wire                     cpu_req_valid,
    input  wire [ADDR_WIDTH-1:0]    cpu_req_addr,
    input  wire [TID_WIDTH-1:0]     cpu_req_tid,
    output reg  [31:0]              cpu_resp_data,
    output reg  [TID_WIDTH-1:0]     cpu_resp_tid,
    output reg  [3:0]               cpu_resp_epoch,
    output reg                      cpu_resp_valid,

    // Epoch tracking for stale-fill suppression
    input  wire [3:0]               current_epoch,
    input  wire [3:0]               current_epoch_t0,
    input  wire [3:0]               current_epoch_t1,
    input  wire                     flush,

    // Refill interface
    output reg                      mem_req_valid,
    input  wire                     mem_req_ready,
    output reg  [ADDR_WIDTH-1:0]    mem_req_addr,
    input  wire                     mem_resp_valid,
    input  wire [31:0]              mem_resp_data,
    input  wire                     mem_resp_last,
    output wire                     mem_resp_ready,

    // Direct backing-store word for the requested address
    input  wire [31:0]              bypass_data,

    // DDR3/XIP fetch debug summary
    output wire [7:0]               debug_high_miss_count,
    output wire [7:0]               debug_mem_req_count,
    output wire [7:0]               debug_mem_resp_count,
    output wire [7:0]               debug_cpu_resp_count,
    output wire [7:0]               debug_state_flags,

    // HPM event
    output wire                     icache_miss_event
);

localparam SETS           = CACHE_SIZE / (LINE_SIZE * WAYS);
localparam OFFSET_W       = $clog2(LINE_SIZE);
localparam INDEX_W        = $clog2(SETS);
localparam TAG_W          = ADDR_WIDTH - OFFSET_W - INDEX_W;
localparam WORDS_PER_LINE = LINE_SIZE / 4;

localparam S_IDLE      = 2'd0;
localparam S_MISS_REQ  = 2'd1;
localparam S_MISS_DATA = 2'd2;
localparam S_REFILL    = 2'd3;

reg [1:0] state;

reg [TAG_W-1:0]       tag_array   [0:SETS-1][0:WAYS-1];
reg                   valid_array [0:SETS-1][0:WAYS-1];
reg [LINE_SIZE*8-1:0] data_array  [0:SETS-1][0:WAYS-1];

reg [ADDR_WIDTH-1:0] req_addr_r;
reg [INDEX_W-1:0]    req_index_r;
reg [TAG_W-1:0]      req_tag_r;
reg [OFFSET_W-1:0]   req_offset_r;
reg [TID_WIDTH-1:0]  req_tid_r;
reg [3:0]            req_epoch_r;
reg                  req_valid_r;
reg [ADDR_WIDTH-1:0] deferred_req_addr_r;
reg [INDEX_W-1:0]    deferred_req_index_r;
reg [TAG_W-1:0]      deferred_req_tag_r;
reg [OFFSET_W-1:0]   deferred_req_offset_r;
reg [TID_WIDTH-1:0]  deferred_req_tid_r;
reg [3:0]            deferred_req_epoch_r;
reg                  deferred_req_valid_r;

reg [INDEX_W-1:0]      miss_index_r;
reg [TAG_W-1:0]        miss_tag_r;
reg [3:0]              miss_epoch_r;
reg [OFFSET_W-1:0]     miss_offset_r;
reg [TID_WIDTH-1:0]    miss_tid_r;
reg                    miss_wait_resp_r;
reg [31:0]             miss_word_r;
reg [LINE_SIZE*8-1:0]  fill_line_r;
reg [$clog2(WORDS_PER_LINE):0] fill_cnt_r;
reg [7:0]              debug_high_miss_count_r;
reg [7:0]              debug_mem_req_count_r;
reg [7:0]              debug_mem_resp_count_r;
reg [7:0]              debug_cpu_resp_count_r;

wire [TAG_W-1:0]    req_tag    = cpu_req_addr[ADDR_WIDTH-1 : OFFSET_W + INDEX_W];
wire [INDEX_W-1:0]  req_index  = cpu_req_addr[OFFSET_W + INDEX_W - 1 : OFFSET_W];
wire [OFFSET_W-1:0] req_offset = cpu_req_addr[OFFSET_W - 1 : 0];

wire hit = valid_array[req_index_r][0] && (tag_array[req_index_r][0] == req_tag_r);
wire [31:0] cached_data = data_array[req_index_r][0][req_offset_r * 8 +: 32];
wire [31:0] resp_data_sel =
    (hit && ((cached_data != 32'd0) || (bypass_data == 32'd0))) ? cached_data : bypass_data;
wire [($clog2(WORDS_PER_LINE)-1):0] req_word_offset = req_offset_r[OFFSET_W-1:2];
wire [($clog2(WORDS_PER_LINE)-1):0] miss_word_offset = miss_offset_r[OFFSET_W-1:2];
wire high_latency_miss = req_addr_r[31];
wire [3:0] miss_current_epoch = miss_tid_r == {TID_WIDTH{1'b0}} ? current_epoch_t0 : current_epoch_t1;
wire replay_deferred_req = !flush && !cpu_req_valid && deferred_req_valid_r && (state == S_IDLE);
wire capture_cpu_req = cpu_req_valid || replay_deferred_req;
wire [ADDR_WIDTH-1:0] cpu_req_addr_mux = replay_deferred_req ? deferred_req_addr_r : cpu_req_addr;
wire [INDEX_W-1:0] cpu_req_index_mux = replay_deferred_req ? deferred_req_index_r : req_index;
wire [TAG_W-1:0] cpu_req_tag_mux = replay_deferred_req ? deferred_req_tag_r : req_tag;
wire [OFFSET_W-1:0] cpu_req_offset_mux = replay_deferred_req ? deferred_req_offset_r : req_offset;
wire [TID_WIDTH-1:0] cpu_req_tid_mux = replay_deferred_req ? deferred_req_tid_r : cpu_req_tid;
wire [3:0] cpu_req_epoch_mux = replay_deferred_req ? deferred_req_epoch_r : current_epoch;

assign mem_resp_ready = 1'b1;
assign debug_high_miss_count = debug_high_miss_count_r;
assign debug_mem_req_count   = debug_mem_req_count_r;
assign debug_mem_resp_count  = debug_mem_resp_count_r;
assign debug_cpu_resp_count  = debug_cpu_resp_count_r;
assign debug_state_flags     = {state, fill_cnt_r[2:0], mem_req_valid, mem_req_ready, mem_resp_valid};
assign icache_miss_event     = req_valid_r && !hit;

integer i;
integer j;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        cpu_resp_data  <= 32'd0;
        cpu_resp_tid   <= {TID_WIDTH{1'b0}};
        cpu_resp_epoch <= 4'd0;
        cpu_resp_valid <= 1'b0;

        mem_req_valid  <= 1'b0;
        mem_req_addr   <= {ADDR_WIDTH{1'b0}};
        state          <= S_IDLE;

        req_addr_r     <= {ADDR_WIDTH{1'b0}};
        req_index_r    <= {INDEX_W{1'b0}};
        req_tag_r      <= {TAG_W{1'b0}};
        req_offset_r   <= {OFFSET_W{1'b0}};
        req_tid_r      <= {TID_WIDTH{1'b0}};
        req_epoch_r    <= 4'd0;
        req_valid_r    <= 1'b0;
        deferred_req_addr_r   <= {ADDR_WIDTH{1'b0}};
        deferred_req_index_r  <= {INDEX_W{1'b0}};
        deferred_req_tag_r    <= {TAG_W{1'b0}};
        deferred_req_offset_r <= {OFFSET_W{1'b0}};
        deferred_req_tid_r    <= {TID_WIDTH{1'b0}};
        deferred_req_epoch_r  <= 4'd0;
        deferred_req_valid_r  <= 1'b0;

        miss_index_r   <= {INDEX_W{1'b0}};
        miss_tag_r     <= {TAG_W{1'b0}};
        miss_epoch_r   <= 4'd0;
        miss_offset_r  <= {OFFSET_W{1'b0}};
        miss_tid_r     <= {TID_WIDTH{1'b0}};
        miss_wait_resp_r <= 1'b0;
        miss_word_r    <= 32'd0;
        fill_line_r    <= {(LINE_SIZE * 8){1'b0}};
        fill_cnt_r     <= {($clog2(WORDS_PER_LINE) + 1){1'b0}};
        debug_high_miss_count_r <= 8'd0;
        debug_mem_req_count_r   <= 8'd0;
        debug_mem_resp_count_r  <= 8'd0;
        debug_cpu_resp_count_r  <= 8'd0;

        for (i = 0; i < SETS; i = i + 1) begin
            for (j = 0; j < WAYS; j = j + 1) begin
                valid_array[i][j] <= 1'b0;
                tag_array[i][j]   <= {TAG_W{1'b0}};
                data_array[i][j]  <= {(LINE_SIZE * 8){1'b0}};
            end
        end
    end
    else begin
        cpu_resp_data  <= resp_data_sel;
        cpu_resp_tid   <= req_tid_r;
        cpu_resp_epoch <= req_epoch_r;
        // Low-address RAM misses can use the synchronous bypass word and
        // respond immediately. DDR3/XIP misses must wait for the external
        // refill, otherwise IF would consume the low RAM bypass value.
        cpu_resp_valid <= req_valid_r && (hit || !high_latency_miss);

        req_valid_r <= capture_cpu_req;
        if (capture_cpu_req) begin
            req_addr_r   <= cpu_req_addr_mux;
            req_index_r  <= cpu_req_index_mux;
            req_tag_r    <= cpu_req_tag_mux;
            req_offset_r <= cpu_req_offset_mux;
            req_tid_r    <= cpu_req_tid_mux;
            req_epoch_r  <= cpu_req_epoch_mux;
        end

        if (flush) begin
            deferred_req_valid_r <= 1'b0;
        end else if (cpu_req_valid && (state != S_IDLE)) begin
            // stage_if allows only one outstanding fetch; keep a single deferred
            // request so a new high-address fetch arriving during refill does
            // not get dropped before the FSM returns to S_IDLE.
            deferred_req_addr_r   <= cpu_req_addr;
            deferred_req_index_r  <= req_index;
            deferred_req_tag_r    <= req_tag;
            deferred_req_offset_r <= req_offset;
            deferred_req_tid_r    <= cpu_req_tid;
            deferred_req_epoch_r  <= current_epoch;
            deferred_req_valid_r  <= 1'b1;
        end else if (replay_deferred_req) begin
            deferred_req_valid_r <= 1'b0;
        end

        case (state)
            S_IDLE: begin
                if (req_valid_r && !hit && high_latency_miss) begin
                    // Low-address ROM misses are already served by the
                    // synchronous bypass word above.  Do not start a
                    // background refill for them: with SMT enabled, thread1's
                    // low ROM spin can otherwise keep the cache refill FSM busy
                    // exactly when thread0 launches the next DDR3/XIP miss,
                    // causing that high-address request to be dropped.
                    debug_high_miss_count_r <= debug_high_miss_count_r + 8'd1;
                    miss_index_r <= req_index_r;
                    miss_tag_r   <= req_tag_r;
                    miss_epoch_r <= req_epoch_r;
                    miss_offset_r <= req_offset_r;
                    miss_tid_r    <= req_tid_r;
                    miss_wait_resp_r <= 1'b1;
                    miss_word_r   <= 32'd0;
                    fill_line_r  <= {(LINE_SIZE * 8){1'b0}};
                    fill_cnt_r   <= {($clog2(WORDS_PER_LINE) + 1){1'b0}};
                    mem_req_addr <= {req_addr_r[ADDR_WIDTH-1:OFFSET_W], {OFFSET_W{1'b0}}};
                    mem_req_valid <= 1'b1;
                    state <= S_MISS_REQ;
                end
            end

            S_MISS_REQ: begin
                if (mem_req_ready) begin
                    if (mem_req_addr[31]) begin
                        debug_mem_req_count_r <= debug_mem_req_count_r + 8'd1;
                    end
                    mem_req_valid <= 1'b0;
                    fill_line_r   <= {(LINE_SIZE * 8){1'b0}};
                    fill_cnt_r    <= {($clog2(WORDS_PER_LINE) + 1){1'b0}};
                    state         <= S_MISS_DATA;
                end
            end

            S_MISS_DATA: begin
                if (mem_resp_valid) begin
                    if (miss_wait_resp_r) begin
                        debug_mem_resp_count_r <= debug_mem_resp_count_r + 8'd1;
                    end
                    fill_line_r[fill_cnt_r * 32 +: 32] <= mem_resp_data;
                    if (fill_cnt_r[$clog2(WORDS_PER_LINE)-1:0] == miss_word_offset) begin
                        miss_word_r <= mem_resp_data;
                    end
                    if (mem_resp_last) begin
                        state <= S_REFILL;
                    end
                    else begin
                        fill_cnt_r <= fill_cnt_r + 1'b1;
                    end
                end
            end

            S_REFILL: begin
                if (!flush && (miss_epoch_r == miss_current_epoch)) begin
                    valid_array[miss_index_r][0] <= 1'b1;
                    tag_array[miss_index_r][0]   <= miss_tag_r;
                    data_array[miss_index_r][0]  <= fill_line_r;
                end
                if (miss_wait_resp_r) begin
                    cpu_resp_data  <= miss_word_r;
                    cpu_resp_tid   <= miss_tid_r;
                    cpu_resp_epoch <= miss_epoch_r;
                    cpu_resp_valid <= !flush && (miss_epoch_r == miss_current_epoch);
                    if (!flush && (miss_epoch_r == miss_current_epoch)) begin
                        debug_cpu_resp_count_r <= debug_cpu_resp_count_r + 8'd1;
                    end
                end
                miss_wait_resp_r <= 1'b0;
                state <= S_IDLE;
            end

            default: begin
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule
