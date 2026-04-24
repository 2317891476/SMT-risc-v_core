// L1 DCache — 4KB 4-way set-associative, write-back write-allocate, M1-native
// Replaces dcache_m1_wrapper. Sits between M1 DDR3 address check and DDR3 arbiter.
`include "define.v"

// Debug modes (uncomment ONE, or comment all for full DCache):
// `define DCACHE_PASSTHROUGH 1
// `define DCACHE_READ_ONLY 1
// `define DCACHE_REGISTERED_PT 1

module l1_dcache_m1 (
    input  wire        clk,
    input  wire        rstn,

    // Upstream M1 (from mem_subsys DDR3-region filter)
    input  wire        up_m1_req_valid,
    output wire        up_m1_req_ready,
    input  wire [31:0] up_m1_req_addr,
    input  wire        up_m1_req_write,
    input  wire [31:0] up_m1_req_wdata,
    input  wire [3:0]  up_m1_req_wen,
    output wire        up_m1_resp_valid,
    output wire [31:0] up_m1_resp_data,

    // Downstream M1 (to DDR3 arbiter)
    output wire        dn_m1_req_valid,
    input  wire        dn_m1_req_ready,
    output wire [31:0] dn_m1_req_addr,
    output wire        dn_m1_req_write,
    output wire [31:0] dn_m1_req_wdata,
    output wire [3:0]  dn_m1_req_wen,
    input  wire        dn_m1_resp_valid,
    input  wire [31:0] dn_m1_resp_data,

    output wire        dcache_miss_event
);

`ifdef DCACHE_PASSTHROUGH
// Pure pass-through: no caching, just wire upstream to downstream
assign dn_m1_req_valid = up_m1_req_valid;
assign up_m1_req_ready = dn_m1_req_ready;
assign dn_m1_req_addr  = up_m1_req_addr;
assign dn_m1_req_write = up_m1_req_write;
assign dn_m1_req_wdata = up_m1_req_wdata;
assign dn_m1_req_wen   = up_m1_req_wen;
assign up_m1_resp_valid = dn_m1_resp_valid;
assign up_m1_resp_data  = dn_m1_resp_data;
assign dcache_miss_event = 1'b0;

`elsif DCACHE_REGISTERED_PT
// Registered pass-through: all requests go to DDR3, but through a registered FSM.
// Stores: combinational pass-through (identical to DCACHE_PASSTHROUGH for stores)
// Loads: accept immediately, forward to arbiter via registered req, wait for response.
// This tests the accept-then-wait-for-response protocol without any caching.

localparam RPT_IDLE      = 3'd0;
localparam RPT_STORE_REQ = 3'd1;
localparam RPT_STORE_RSP = 3'd2;
localparam RPT_FILL_REQ  = 3'd3;
localparam RPT_FILL_RSP  = 3'd4;
localparam RPT_DONE      = 3'd5;
localparam RPT_EXACT_RSP = 3'd6;

reg [2:0]   rpt_state;
reg [31:0]  rpt_addr;
reg         rpt_is_wr;
reg [31:0]  rpt_wdata;
reg [3:0]   rpt_wen;
reg         rpt_resp_valid;
reg [31:0]  rpt_resp_data;
reg         rpt_dn_valid;
reg [31:0]  rpt_dn_addr;
reg         rpt_dn_write;
reg [31:0]  rpt_dn_wdata;
reg [3:0]   rpt_dn_wen;
reg [2:0]   rpt_word_cnt;
reg [255:0] rpt_fill_line;

wire rpt_can_accept = (rpt_state == RPT_IDLE) && !rpt_resp_valid;

assign up_m1_req_ready = rpt_can_accept;

assign dn_m1_req_valid = rpt_dn_valid;
assign dn_m1_req_addr  = rpt_dn_addr;
assign dn_m1_req_write = rpt_dn_write;
assign dn_m1_req_wdata = rpt_dn_wdata;
assign dn_m1_req_wen   = rpt_dn_wen;

assign up_m1_resp_valid = rpt_resp_valid;
assign up_m1_resp_data  = rpt_resp_data;
assign dcache_miss_event = 1'b0;

wire [2:0] rpt_req_word = rpt_addr[4:2];

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        rpt_state <= RPT_IDLE;
        rpt_resp_valid <= 1'b0;
        rpt_dn_valid <= 1'b0;
        rpt_dn_addr <= 32'd0;
        rpt_dn_write <= 1'b0;
        rpt_dn_wdata <= 32'd0;
        rpt_dn_wen <= 4'd0;
        rpt_addr <= 32'd0;
        rpt_is_wr <= 1'b0;
        rpt_wdata <= 32'd0;
        rpt_wen <= 4'd0;
        rpt_resp_data <= 32'd0;
        rpt_word_cnt <= 3'd0;
        rpt_fill_line <= 256'd0;
    end else begin
        rpt_resp_valid <= 1'b0;
        case (rpt_state)
        RPT_IDLE: begin
            rpt_dn_valid <= 1'b0;
            if (rpt_can_accept && up_m1_req_valid) begin
                rpt_addr  <= up_m1_req_addr;
                rpt_is_wr <= up_m1_req_write;
                rpt_wdata <= up_m1_req_wdata;
                rpt_wen   <= up_m1_req_wen;
                if (up_m1_req_write) begin
                    rpt_state <= RPT_STORE_REQ;
                end else begin
                    rpt_word_cnt <= 3'd0;
                    rpt_state <= RPT_FILL_REQ;
                end
            end
        end

        RPT_STORE_REQ: begin
            rpt_dn_valid <= 1'b1;
            rpt_dn_addr  <= rpt_addr;
            rpt_dn_write <= 1'b1;
            rpt_dn_wdata <= rpt_wdata;
            rpt_dn_wen   <= rpt_wen;
            if (dn_m1_req_ready) begin
                rpt_dn_valid <= 1'b0;
                rpt_state <= RPT_STORE_RSP;
            end
        end

        RPT_STORE_RSP: begin
            rpt_dn_valid <= 1'b0;
            if (dn_m1_resp_valid) begin
                rpt_resp_valid <= 1'b1;
                rpt_resp_data <= 32'd0;
                rpt_state <= RPT_IDLE;
            end
        end

        RPT_FILL_REQ: begin
            rpt_dn_valid <= 1'b1;
            rpt_dn_addr  <= rpt_addr;
            rpt_dn_write <= 1'b0;
            rpt_dn_wdata <= 32'd0;
            rpt_dn_wen   <= 4'd0;
            if (dn_m1_req_ready) begin
                rpt_dn_valid <= 1'b0;
                rpt_state <= RPT_FILL_RSP;
            end
        end

        RPT_FILL_RSP: begin
            rpt_dn_valid <= 1'b0;
            if (dn_m1_resp_valid) begin
                rpt_resp_data <= dn_m1_resp_data;
                rpt_word_cnt <= 3'd0;
                rpt_state <= RPT_DONE;
            end
        end

        RPT_DONE: begin
            if (rpt_word_cnt == 3'd2) begin
                rpt_resp_valid <= 1'b1;
                rpt_state <= RPT_IDLE;
            end else begin
                rpt_word_cnt <= rpt_word_cnt + 3'd1;
            end
        end
        RPT_EXACT_RSP: rpt_state <= RPT_IDLE;

        default: rpt_state <= RPT_IDLE;
        endcase
    end
end

`elsif DCACHE_READ_ONLY
// Read-only cache: loads go through cache, stores pass through directly.
// No dirty tracking, no writeback. Stores invalidate matching cache lines.

localparam RO_SETS     = 32;
localparam RO_WAYS     = 4;
localparam RO_TAG_W    = 22;
localparam RO_WPL      = 8;

localparam RO_IDLE      = 2'd0;
localparam RO_FILL_REQ  = 2'd1;
localparam RO_FILL_RESP = 2'd2;
localparam RO_INSTALL   = 2'd3;

reg [1:0] ro_state;

reg [RO_TAG_W-1:0] ro_tag   [0:RO_SETS-1][0:RO_WAYS-1];
reg                 ro_valid [0:RO_SETS-1][0:RO_WAYS-1];
reg [255:0]         ro_data  [0:RO_SETS-1][0:RO_WAYS-1];
reg [2:0]           ro_plru  [0:RO_SETS-1];

wire [RO_TAG_W-1:0] ro_req_tag   = up_m1_req_addr[31:10];
wire [4:0]           ro_req_index = up_m1_req_addr[9:5];
wire [2:0]           ro_req_word  = up_m1_req_addr[4:2];

reg        ro_hit;
reg [1:0]  ro_hit_way;
integer    ro_hw;
always @(*) begin
    ro_hit = 1'b0; ro_hit_way = 2'd0;
    for (ro_hw = 0; ro_hw < RO_WAYS; ro_hw = ro_hw + 1)
        if (ro_valid[ro_req_index][ro_hw] && ro_tag[ro_req_index][ro_hw] == ro_req_tag) begin
            ro_hit = 1'b1; ro_hit_way = ro_hw[1:0];
        end
end

wire [31:0] ro_cached_word;
assign ro_cached_word = (ro_req_word == 3'd0) ? ro_data[ro_req_index][ro_hit_way][ 31:  0] :
                        (ro_req_word == 3'd1) ? ro_data[ro_req_index][ro_hit_way][ 63: 32] :
                        (ro_req_word == 3'd2) ? ro_data[ro_req_index][ro_hit_way][ 95: 64] :
                        (ro_req_word == 3'd3) ? ro_data[ro_req_index][ro_hit_way][127: 96] :
                        (ro_req_word == 3'd4) ? ro_data[ro_req_index][ro_hit_way][159:128] :
                        (ro_req_word == 3'd5) ? ro_data[ro_req_index][ro_hit_way][191:160] :
                        (ro_req_word == 3'd6) ? ro_data[ro_req_index][ro_hit_way][223:192] :
                                                ro_data[ro_req_index][ro_hit_way][255:224];

function [1:0] ro_get_victim;
    input [2:0] p;
    begin
        if (!p[0]) ro_get_victim = p[1] ? 2'd1 : 2'd0;
        else       ro_get_victim = p[2] ? 2'd3 : 2'd2;
    end
endfunction

reg [1:0] ro_victim_sel;
always @(*) begin
    if      (!ro_valid[ro_req_index][0]) ro_victim_sel = 2'd0;
    else if (!ro_valid[ro_req_index][1]) ro_victim_sel = 2'd1;
    else if (!ro_valid[ro_req_index][2]) ro_victim_sel = 2'd2;
    else if (!ro_valid[ro_req_index][3]) ro_victim_sel = 2'd3;
    else                                  ro_victim_sel = ro_get_victim(ro_plru[ro_req_index]);
end

reg [31:0]  ro_miss_addr;
reg [1:0]   ro_victim_r;
reg [255:0] ro_fill_line;
reg [2:0]   ro_word_cnt;

wire [4:0]  ro_miss_index = ro_miss_addr[9:5];
wire [2:0]  ro_miss_word  = ro_miss_addr[4:2];

reg        ro_hit_resp_valid;
reg [31:0] ro_hit_resp_data;
reg        ro_install_resp_valid;
reg [31:0] ro_install_resp_data;

// Stores: pass-through (combinational when idle, blocked during refill)
wire ro_is_store = up_m1_req_valid && up_m1_req_write;
wire ro_is_load  = up_m1_req_valid && !up_m1_req_write;

wire ro_can_accept = (ro_state == RO_IDLE) && !ro_hit_resp_valid && !ro_install_resp_valid && !ro_pt_pending;

// Store pass-through tracking
reg ro_pt_pending;
wire ro_pt_resp = ro_pt_pending && dn_m1_resp_valid && (ro_state == RO_IDLE);

// Upstream ready: load hit = accept, load miss = accept (will stall in FSM), store = pass-through
assign up_m1_req_ready = ro_is_store ? (ro_can_accept && dn_m1_req_ready) :
                         ro_is_load  ? ro_can_accept :
                         1'b0;

// Downstream request mux
reg        ro_dn_valid;
reg [31:0] ro_dn_addr;
assign dn_m1_req_valid = (ro_state == RO_FILL_REQ) ? ro_dn_valid :
                          ro_is_store && ro_can_accept ? up_m1_req_valid : 1'b0;
assign dn_m1_req_addr  = (ro_state == RO_FILL_REQ) ? ro_dn_addr : up_m1_req_addr;
assign dn_m1_req_write = (ro_state == RO_FILL_REQ) ? 1'b0 : up_m1_req_write;
assign dn_m1_req_wdata = up_m1_req_wdata;
assign dn_m1_req_wen   = (ro_state == RO_FILL_REQ) ? 4'd0 : up_m1_req_wen;

// Upstream response
assign up_m1_resp_valid = ro_hit_resp_valid || ro_install_resp_valid || ro_pt_resp;
assign up_m1_resp_data  = ro_hit_resp_valid     ? ro_hit_resp_data :
                          ro_install_resp_valid  ? ro_install_resp_data :
                          dn_m1_resp_data;

assign dcache_miss_event = ro_can_accept && ro_is_load && !ro_hit;

integer ro_si, ro_sj;
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ro_state <= RO_IDLE;
        ro_hit_resp_valid <= 1'b0;
        ro_install_resp_valid <= 1'b0;
        ro_dn_valid <= 1'b0;
        ro_word_cnt <= 3'd0;
        ro_pt_pending <= 1'b0;
        ro_miss_addr <= 32'd0;
        ro_victim_r <= 2'd0;
        ro_fill_line <= 256'd0;
        ro_hit_resp_data <= 32'd0;
        ro_install_resp_data <= 32'd0;
        ro_dn_addr <= 32'd0;
        for (ro_si = 0; ro_si < RO_SETS; ro_si = ro_si + 1) begin
            for (ro_sj = 0; ro_sj < RO_WAYS; ro_sj = ro_sj + 1) begin
                ro_valid[ro_si][ro_sj] <= 1'b0;
                ro_tag[ro_si][ro_sj] <= {RO_TAG_W{1'b0}};
            end
            ro_plru[ro_si] <= 3'd0;
        end
    end else begin
        ro_hit_resp_valid <= 1'b0;
        ro_install_resp_valid <= 1'b0;

        // Store pass-through tracking
        if (ro_is_store && up_m1_req_ready && dn_m1_req_ready)
            ro_pt_pending <= 1'b1;
        if (ro_pt_resp)
            ro_pt_pending <= 1'b0;

        // Store invalidation: if store hits a cached line, invalidate it
        if (ro_is_store && up_m1_req_ready && ro_hit)
            ro_valid[ro_req_index][ro_hit_way] <= 1'b0;

        case (ro_state)
        RO_IDLE: begin
            ro_dn_valid <= 1'b0;
            if (ro_can_accept && ro_is_load) begin
                if (ro_hit) begin
                    ro_hit_resp_valid <= 1'b1;
                    ro_hit_resp_data  <= ro_cached_word;
                    case (ro_hit_way)
                        2'd0: begin ro_plru[ro_req_index][0] <= 1'b1; ro_plru[ro_req_index][1] <= 1'b1; end
                        2'd1: begin ro_plru[ro_req_index][0] <= 1'b1; ro_plru[ro_req_index][1] <= 1'b0; end
                        2'd2: begin ro_plru[ro_req_index][0] <= 1'b0; ro_plru[ro_req_index][2] <= 1'b1; end
                        2'd3: begin ro_plru[ro_req_index][0] <= 1'b0; ro_plru[ro_req_index][2] <= 1'b0; end
                    endcase
                end else begin
                    ro_miss_addr <= up_m1_req_addr;
                    ro_victim_r  <= ro_victim_sel;
                    ro_word_cnt  <= 3'd0;
                    ro_fill_line <= 256'd0;
                    ro_state     <= RO_FILL_REQ;
                end
            end
        end

        RO_FILL_REQ: begin
            ro_dn_valid <= 1'b1;
            ro_dn_addr  <= {ro_miss_addr[31:5], ro_word_cnt, 2'b00};
            if (dn_m1_req_ready) begin
                ro_dn_valid <= 1'b0;
                ro_state <= RO_FILL_RESP;
            end
        end

        RO_FILL_RESP: begin
            ro_dn_valid <= 1'b0;
            if (dn_m1_resp_valid) begin
                case (ro_word_cnt)
                    3'd0: ro_fill_line[ 31:  0] <= dn_m1_resp_data;
                    3'd1: ro_fill_line[ 63: 32] <= dn_m1_resp_data;
                    3'd2: ro_fill_line[ 95: 64] <= dn_m1_resp_data;
                    3'd3: ro_fill_line[127: 96] <= dn_m1_resp_data;
                    3'd4: ro_fill_line[159:128] <= dn_m1_resp_data;
                    3'd5: ro_fill_line[191:160] <= dn_m1_resp_data;
                    3'd6: ro_fill_line[223:192] <= dn_m1_resp_data;
                    3'd7: ro_fill_line[255:224] <= dn_m1_resp_data;
                endcase
                if (ro_word_cnt == 3'd7)
                    ro_state <= RO_INSTALL;
                else begin
                    ro_word_cnt <= ro_word_cnt + 3'd1;
                    ro_state <= RO_FILL_REQ;
                end
            end
        end

        RO_INSTALL: begin
            ro_data[ro_miss_index][ro_victim_r]  <= ro_fill_line;
            ro_tag[ro_miss_index][ro_victim_r]   <= ro_miss_addr[31:10];
            ro_valid[ro_miss_index][ro_victim_r] <= 1'b1;
            ro_install_resp_valid <= 1'b1;
            case (ro_miss_word)
                3'd0: ro_install_resp_data <= ro_fill_line[ 31:  0];
                3'd1: ro_install_resp_data <= ro_fill_line[ 63: 32];
                3'd2: ro_install_resp_data <= ro_fill_line[ 95: 64];
                3'd3: ro_install_resp_data <= ro_fill_line[127: 96];
                3'd4: ro_install_resp_data <= ro_fill_line[159:128];
                3'd5: ro_install_resp_data <= ro_fill_line[191:160];
                3'd6: ro_install_resp_data <= ro_fill_line[223:192];
                3'd7: ro_install_resp_data <= ro_fill_line[255:224];
            endcase
            case (ro_victim_r)
                2'd0: begin ro_plru[ro_miss_index][0] <= 1'b1; ro_plru[ro_miss_index][1] <= 1'b1; end
                2'd1: begin ro_plru[ro_miss_index][0] <= 1'b1; ro_plru[ro_miss_index][1] <= 1'b0; end
                2'd2: begin ro_plru[ro_miss_index][0] <= 1'b0; ro_plru[ro_miss_index][2] <= 1'b1; end
                2'd3: begin ro_plru[ro_miss_index][0] <= 1'b0; ro_plru[ro_miss_index][2] <= 1'b0; end
            endcase
            ro_state <= RO_IDLE;
        end

        default: ro_state <= RO_IDLE;
        endcase
    end
end

`else

// ─────────────────────────────────────────────────────────────
// Parameters
// ─────────────────────────────────────────────────────────────
localparam SETS     = 32;
localparam WAYS     = 4;
localparam OFFSET_W = 5;   // log2(32B line)
localparam INDEX_W  = 5;   // log2(32 sets)
localparam TAG_W    = 22;  // 32 - 5 - 5
localparam WPL      = 8;   // words per line

// ─────────────────────────────────────────────────────────────
// FSM states
// ─────────────────────────────────────────────────────────────
localparam S_IDLE      = 3'd0;
localparam S_WB_REQ    = 3'd1;
localparam S_WB_RESP   = 3'd2;
localparam S_FILL_REQ  = 3'd3;
localparam S_FILL_RESP = 3'd4;
localparam S_INSTALL   = 3'd5;

reg [2:0] state;

// ─────────────────────────────────────────────────────────────
// Storage arrays
// ─────────────────────────────────────────────────────────────
reg [TAG_W-1:0]   tag_array   [0:SETS-1][0:WAYS-1];
reg               valid_array [0:SETS-1][0:WAYS-1];
reg               dirty_array [0:SETS-1][0:WAYS-1];
reg [255:0]       data_array  [0:SETS-1][0:WAYS-1];
reg [2:0]         plru        [0:SETS-1];

// ─────────────────────────────────────────────────────────────
// Address decomposition (upstream request)
// ─────────────────────────────────────────────────────────────
wire [TAG_W-1:0]    req_tag   = up_m1_req_addr[31:10];
wire [INDEX_W-1:0]  req_index = up_m1_req_addr[9:5];
wire [2:0]          req_word  = up_m1_req_addr[4:2];

// ─────────────────────────────────────────────────────────────
// Combinational hit detection
// ─────────────────────────────────────────────────────────────
reg        hit;
reg [1:0]  hit_way;
integer    hw;
always @(*) begin
    hit = 1'b0;
    hit_way = 2'd0;
    for (hw = 0; hw < WAYS; hw = hw + 1)
        if (valid_array[req_index][hw] && tag_array[req_index][hw] == req_tag) begin
            hit = 1'b1;
            hit_way = hw[1:0];
        end
end

wire [31:0] cached_word = data_array[req_index][hit_way][req_word*32 +: 32];

// ─────────────────────────────────────────────────────────────
// PLRU victim selection
// ─────────────────────────────────────────────────────────────
// Tree: plru[0]=root, plru[1]=left child, plru[2]=right child
// Bit=0 means "go this direction for victim"
function [1:0] get_victim;
    input [2:0] p;
    begin
        if (!p[0])
            get_victim = p[1] ? 2'd1 : 2'd0;
        else
            get_victim = p[2] ? 2'd3 : 2'd2;
    end
endfunction

// Invalid-way override: prefer invalid way over PLRU victim
reg [1:0] victim_sel;
always @(*) begin
    if      (!valid_array[req_index][0]) victim_sel = 2'd0;
    else if (!valid_array[req_index][1]) victim_sel = 2'd1;
    else if (!valid_array[req_index][2]) victim_sel = 2'd2;
    else if (!valid_array[req_index][3]) victim_sel = 2'd3;
    else                                 victim_sel = get_victim(plru[req_index]);
end

// ─────────────────────────────────────────────────────────────
// Miss-handling registers
// ─────────────────────────────────────────────────────────────
reg [31:0]  miss_addr_r;
reg         miss_write_r;
reg [31:0]  miss_wdata_r;
reg [3:0]   miss_wen_r;
reg [1:0]   victim_r;
reg [255:0] fill_line_r;
reg [2:0]   word_cnt_r;

wire [INDEX_W-1:0] miss_index = miss_addr_r[9:5];
wire [2:0]         miss_word  = miss_addr_r[4:2];

// ─────────────────────────────────────────────────────────────
// Writeback address reconstruction
// ─────────────────────────────────────────────────────────────
wire [TAG_W-1:0]   wb_tag  = tag_array[miss_index][victim_r];
wire [31:0]        wb_addr = {wb_tag, miss_index, word_cnt_r, 2'b00};

// ─────────────────────────────────────────────────────────────
// Response registers
// ─────────────────────────────────────────────────────────────
reg        hit_resp_valid_r;
reg [31:0] hit_resp_data_r;
reg        install_resp_valid_r;
reg [31:0] install_resp_data_r;

// ─────────────────────────────────────────────────────────────
// Upstream interface
// ─────────────────────────────────────────────────────────────
wire can_accept = (state == S_IDLE) && !hit_resp_valid_r && !install_resp_valid_r;
assign up_m1_req_ready = can_accept && up_m1_req_valid;

assign up_m1_resp_valid = hit_resp_valid_r || install_resp_valid_r;
assign up_m1_resp_data  = hit_resp_valid_r ? hit_resp_data_r : install_resp_data_r;

// ─────────────────────────────────────────────────────────────
// Downstream interface mux
// ─────────────────────────────────────────────────────────────
reg        dn_req_valid_r;
reg [31:0] dn_req_addr_r;
reg        dn_req_write_r;
reg [31:0] dn_req_wdata_r;
reg [3:0]  dn_req_wen_r;

assign dn_m1_req_valid = dn_req_valid_r;
assign dn_m1_req_addr  = dn_req_addr_r;
assign dn_m1_req_write = dn_req_write_r;
assign dn_m1_req_wdata = dn_req_wdata_r;
assign dn_m1_req_wen   = dn_req_wen_r;

// ─────────────────────────────────────────────────────────────
// Miss event for HPM
// ─────────────────────────────────────────────────────────────
assign dcache_miss_event = can_accept && up_m1_req_valid && !hit;

// ─────────────────────────────────────────────────────────────
// Byte-masked merge for write-allocate
// ─────────────────────────────────────────────────────────────
reg [255:0] merged_line;
always @(*) begin
    merged_line = fill_line_r;
    if (miss_write_r) begin
        if (miss_wen_r[0]) merged_line[miss_word*32     +: 8] = miss_wdata_r[ 7: 0];
        if (miss_wen_r[1]) merged_line[miss_word*32 + 8 +: 8] = miss_wdata_r[15: 8];
        if (miss_wen_r[2]) merged_line[miss_word*32 +16 +: 8] = miss_wdata_r[23:16];
        if (miss_wen_r[3]) merged_line[miss_word*32 +24 +: 8] = miss_wdata_r[31:24];
    end
end

// ─────────────────────────────────────────────────────────────
// Byte-masked write for store hit
// ─────────────────────────────────────────────────────────────
reg [255:0] hit_write_line;
always @(*) begin
    hit_write_line = data_array[req_index][hit_way];
    if (up_m1_req_wen[0]) hit_write_line[req_word*32     +: 8] = up_m1_req_wdata[ 7: 0];
    if (up_m1_req_wen[1]) hit_write_line[req_word*32 + 8 +: 8] = up_m1_req_wdata[15: 8];
    if (up_m1_req_wen[2]) hit_write_line[req_word*32 +16 +: 8] = up_m1_req_wdata[23:16];
    if (up_m1_req_wen[3]) hit_write_line[req_word*32 +24 +: 8] = up_m1_req_wdata[31:24];
end

// ─────────────────────────────────────────────────────────────
// Main FSM
// ─────────────────────────────────────────────────────────────
integer si, sj;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state              <= S_IDLE;
        hit_resp_valid_r   <= 1'b0;
        install_resp_valid_r <= 1'b0;
        hit_resp_data_r    <= 32'd0;
        install_resp_data_r <= 32'd0;
        dn_req_valid_r     <= 1'b0;
        dn_req_addr_r      <= 32'd0;
        dn_req_write_r     <= 1'b0;
        dn_req_wdata_r     <= 32'd0;
        dn_req_wen_r       <= 4'd0;
        miss_addr_r        <= 32'd0;
        miss_write_r       <= 1'b0;
        miss_wdata_r       <= 32'd0;
        miss_wen_r         <= 4'd0;
        victim_r           <= 2'd0;
        fill_line_r        <= 256'd0;
        word_cnt_r         <= 3'd0;
        for (si = 0; si < SETS; si = si + 1) begin
            for (sj = 0; sj < WAYS; sj = sj + 1) begin
                valid_array[si][sj] <= 1'b0;
                dirty_array[si][sj] <= 1'b0;
                tag_array[si][sj]   <= {TAG_W{1'b0}};
            end
            plru[si] <= 3'd0;
        end
    end
    else begin
        // Default: clear response pulses
        hit_resp_valid_r     <= 1'b0;
        install_resp_valid_r <= 1'b0;

        case (state)
        // ─────────────────────────────────────────────────────
        S_IDLE: begin
            dn_req_valid_r <= 1'b0;

            if (can_accept && up_m1_req_valid) begin
                if (hit) begin
                    // === HIT PATH ===
                    if (up_m1_req_write) begin
                        // Store hit: update cache line, mark dirty
                        data_array[req_index][hit_way] <= hit_write_line;
                        dirty_array[req_index][hit_way] <= 1'b1;
                        hit_resp_valid_r <= 1'b1;
                        hit_resp_data_r  <= 32'd0;
                    end else begin
                        // Load hit: return cached word
                        hit_resp_valid_r <= 1'b1;
                        hit_resp_data_r  <= cached_word;
                    end
                    // Update PLRU (point away from accessed way)
                    case (hit_way)
                        2'd0: begin plru[req_index][0] <= 1'b1; plru[req_index][1] <= 1'b1; end
                        2'd1: begin plru[req_index][0] <= 1'b1; plru[req_index][1] <= 1'b0; end
                        2'd2: begin plru[req_index][0] <= 1'b0; plru[req_index][2] <= 1'b1; end
                        2'd3: begin plru[req_index][0] <= 1'b0; plru[req_index][2] <= 1'b0; end
                    endcase
                end else begin
                    // === MISS PATH ===
                    miss_addr_r  <= up_m1_req_addr;
                    miss_write_r <= up_m1_req_write;
                    miss_wdata_r <= up_m1_req_wdata;
                    miss_wen_r   <= up_m1_req_wen;
                    victim_r     <= victim_sel;
                    word_cnt_r   <= 3'd0;
                    fill_line_r  <= 256'd0;

                    if (valid_array[req_index][victim_sel] &&
                        dirty_array[req_index][victim_sel]) begin
                        // Dirty victim: writeback first
                        state <= S_WB_REQ;
                    end else begin
                        // Clean/invalid victim: straight to refill
                        state <= S_FILL_REQ;
                    end
                end
            end
        end

        // ─────────────────────────────────────────────────────
        S_WB_REQ: begin
            dn_req_valid_r <= 1'b1;
            dn_req_addr_r  <= wb_addr;
            dn_req_write_r <= 1'b1;
            dn_req_wdata_r <= data_array[miss_index][victim_r][word_cnt_r*32 +: 32];
            dn_req_wen_r   <= 4'b1111;

            if (dn_m1_req_ready) begin
                dn_req_valid_r <= 1'b0;
                state <= S_WB_RESP;
            end
        end

        // ─────────────────────────────────────────────────────
        S_WB_RESP: begin
            dn_req_valid_r <= 1'b0;
            if (dn_m1_resp_valid) begin
                if (word_cnt_r == 3'd7) begin
                    word_cnt_r <= 3'd0;
                    state <= S_FILL_REQ;
                end else begin
                    word_cnt_r <= word_cnt_r + 3'd1;
                    state <= S_WB_REQ;
                end
            end
        end

        // ─────────────────────────────────────────────────────
        S_FILL_REQ: begin
            dn_req_valid_r <= 1'b1;
            dn_req_addr_r  <= {miss_addr_r[31:5], word_cnt_r, 2'b00};
            dn_req_write_r <= 1'b0;
            dn_req_wdata_r <= 32'd0;
            dn_req_wen_r   <= 4'd0;

            if (dn_m1_req_ready) begin
                dn_req_valid_r <= 1'b0;
                state <= S_FILL_RESP;
            end
        end

        // ─────────────────────────────────────────────────────
        S_FILL_RESP: begin
            dn_req_valid_r <= 1'b0;
            if (dn_m1_resp_valid) begin
                fill_line_r[word_cnt_r*32 +: 32] <= dn_m1_resp_data;
                if (word_cnt_r == 3'd7) begin
                    state <= S_INSTALL;
                end else begin
                    word_cnt_r <= word_cnt_r + 3'd1;
                    state <= S_FILL_REQ;
                end
            end
        end

        // ─────────────────────────────────────────────────────
        S_INSTALL: begin
            // Install line into cache
            if (miss_write_r) begin
                data_array[miss_index][victim_r]  <= merged_line;
                dirty_array[miss_index][victim_r] <= 1'b1;
                install_resp_valid_r <= 1'b1;
                install_resp_data_r  <= 32'd0;
            end else begin
                data_array[miss_index][victim_r]  <= fill_line_r;
                dirty_array[miss_index][victim_r] <= 1'b0;
                install_resp_valid_r <= 1'b1;
                install_resp_data_r  <= fill_line_r[miss_word*32 +: 32];
            end
            tag_array[miss_index][victim_r]   <= miss_addr_r[31:10];
            valid_array[miss_index][victim_r] <= 1'b1;

            // Update PLRU (point away from installed way)
            case (victim_r)
                2'd0: begin plru[miss_index][0] <= 1'b1; plru[miss_index][1] <= 1'b1; end
                2'd1: begin plru[miss_index][0] <= 1'b1; plru[miss_index][1] <= 1'b0; end
                2'd2: begin plru[miss_index][0] <= 1'b0; plru[miss_index][2] <= 1'b1; end
                2'd3: begin plru[miss_index][0] <= 1'b0; plru[miss_index][2] <= 1'b0; end
            endcase

            state <= S_IDLE;
        end

        default: state <= S_IDLE;
        endcase
    end
end

`endif // DCACHE_PASSTHROUGH

endmodule
