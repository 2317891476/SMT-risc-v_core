// =============================================================================
// Module : lsu_shell
// Description: Load-Store Unit Shell with Store Buffer integration
//              and mem_subsys M1 interface (Task 6: variable-latency support)
//
//   This module provides a clean boundary between the execution pipe and the
//   memory subsystem. It implements an explicit handshake protocol:
//
//   Request (from exec_pipe1):
//     - req_valid: memory operation request is valid
//     - req_accept: LSU can accept this request (output back to scoreboard)
//     - Request metadata: {tid, order_id, epoch, tag, rd, func3, addr, wdata, wen}
//
//   Response (to writeback):
//     - resp_valid: response data is valid
//     - Response metadata: {tid, order_id, epoch, tag, rd, func3}
//
//   Store Buffer Integration:
//     - Stores are sent to Store Buffer (speculative completion)
//     - Loads bypass Store Buffer and go directly to memory
//     - Store Buffer drains to memory only on commit
//     - Wrong-path stores are discarded on flush
//
//   Task 6 Updates:
//     - Added mem_subsys M1 interface with request/response handshakes
//     - Variable-latency memory responses via state machine
//     - Backward-compatible with direct stage_mem connection
//
// =============================================================================
`include "define_v2.v"

module lsu_shell #(
    parameter TAG_W = 5,
    parameter ORDER_ID_W = 16,
    parameter EPOCH_W = 8
)(
    input  wire               clk,
    input  wire               rstn,

    // ─── Flush (for speculation management) ─────────────────────
    input  wire               flush,
    input  wire [0:0]         flush_tid,
    input  wire [EPOCH_W-1:0] flush_new_epoch_t0,
    input  wire [EPOCH_W-1:0] flush_new_epoch_t1,

    // ═══════════════════════════════════════════════════════════════════════════
    // Request Interface (from exec_pipe1)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire               req_valid,         // Request is valid
    output wire               req_accept,        // LSU can accept this request

    // Request metadata
    input  wire [0:0]         req_tid,           // Thread ID
    input  wire [ORDER_ID_W-1:0] req_order_id,   // Per-thread instruction order
    input  wire [EPOCH_W-1:0] req_epoch,         // Speculation epoch
    input  wire [TAG_W-1:0]   req_tag,           // RS tag for matching
    input  wire [4:0]         req_rd,            // Destination register
    input  wire [2:0]         req_func3,         // Memory operation type
    input  wire               req_wen,           // 1=store, 0=load
    input  wire [31:0]        req_addr,          // Effective address
    input  wire [31:0]        req_wdata,         // Store data (for stores)
    input  wire               req_regs_write,    // Register write enable
    input  wire [2:0]         req_fu,            // FU type (FU_LOAD/FU_STORE)
    input  wire               req_mem2reg,       // Load to register

    // ═══════════════════════════════════════════════════════════════════════════
    // Response Interface (to writeback stage)
    // ═══════════════════════════════════════════════════════════════════════════
    output reg                resp_valid,        // Response is valid

    // Response metadata (echoed from request)
    output reg  [0:0]         resp_tid,
    output reg  [ORDER_ID_W-1:0] resp_order_id,
    output reg  [EPOCH_W-1:0] resp_epoch,
    output reg  [TAG_W-1:0]   resp_tag,
    output reg  [4:0]         resp_rd,
    output reg  [2:0]         resp_func3,
    output reg                resp_regs_write,
    output reg  [2:0]         resp_fu,

    // Response data (for loads)
    output reg  [31:0]        resp_rdata,        // Load data (sign/unsign extended)

    // ═══════════════════════════════════════════════════════════════════════════
    // Legacy Memory Interface (to stage_mem / data_memory) - for loads only
    // Kept for backward compatibility when use_mem_subsys=0
    // ═══════════════════════════════════════════════════════════════════════════
    output wire [31:0]        mem_addr,
    output wire [3:0]         mem_read,          // Byte-wise read enable for loads
    input  wire [31:0]        mem_rdata,         // Raw data from memory

    // ═══════════════════════════════════════════════════════════════════════════
    // MEM_SUBSYS M1 INTERFACE (Task 6: Variable-latency connection)
    // Used when use_mem_subsys=1
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire               use_mem_subsys,    // 1=use mem_subsys, 0=legacy

    // M1 Request (D-side)
    output reg                m1_req_valid,
    input  wire               m1_req_ready,
    output reg  [31:0]        m1_req_addr,
    output reg                m1_req_write,      // 0=read, 1=write
    output reg  [31:0]        m1_req_wdata,
    output reg  [3:0]         m1_req_wen,        // Byte-wise write enable

    // M1 Response
    input  wire               m1_resp_valid,
    input  wire [31:0]        m1_resp_data,

    // ═══════════════════════════════════════════════════════════════════════════
    // ROB Commit Interface (pass through to Store Buffer)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire               commit0_valid,
    input  wire               commit1_valid,
    input  wire [ORDER_ID_W-1:0] commit0_order_id,
    input  wire [ORDER_ID_W-1:0] commit1_order_id,
    input  wire               commit0_is_store,
    input  wire               commit1_is_store,

    // ═══════════════════════════════════════════════════════════════════════════
    // Store Buffer Drain Interface (to stage_mem/data_memory or mem_subsys)
    // ═══════════════════════════════════════════════════════════════════════════
    output wire               sb_mem_write_valid,
    output wire [31:0]        sb_mem_write_addr,
    output wire [31:0]        sb_mem_write_data,
    output wire [3:0]         sb_mem_write_wen,
    input  wire               sb_mem_write_ready,

    // ═══════════════════════════════════════════════════════════════════════════
    // Load Hazard Output (to scoreboard for stalling)
    // ═══════════════════════════════════════════════════════════════════════════
    output wire               load_hazard          // Load must be retried
);

// =============================================================================
// Internal Signals
// =============================================================================

// Store Buffer interface signals
wire                     sb_store_accept;
wire                     sb_mem_write_valid_int;
wire [31:0]              sb_mem_write_addr_int;
wire [31:0]              sb_mem_write_data_int;
wire [2:0]               sb_mem_write_func3_int;
wire [3:0]               sb_mem_write_wen_int;

// Store Buffer forwarding signals
wire [31:0]              sb_forward_data;
wire                     sb_forward_valid;
wire                     sb_load_hazard;

// Load vs Store classification
wire is_load  = req_valid && !req_wen;
wire is_store = req_valid && req_wen;



// =============================================================================
// Request Acceptance Logic (Task 6: State machine aware)
// =============================================================================

// LSU is ready to accept requests:
// - For loads: ready if no store buffer hazard detected and state machine idle
// - For stores: ready if store buffer has space and state machine idle
// Note: We check store buffer capacity here without creating a combinational loop
// by checking capacity directly rather than depending on store_req_valid

// State machine must be idle to accept new requests
wire state_machine_idle = (lsu_state == LSU_IDLE);

// Accept stores when store buffer has space and state machine idle
wire store_accept = sb_store_accept && state_machine_idle;

// Accept loads when no hazard is detected from store buffer and state machine idle
// The hazard check is combinational based on current SB state
wire load_accept = !sb_load_hazard && state_machine_idle;

assign req_accept = is_store ? store_accept : load_accept;

// Export load hazard signal for scoreboard stalling
assign load_hazard = is_load && sb_load_hazard;

// =============================================================================
// Memory Interface for Loads
// =============================================================================

// Load requests go directly to memory (bypass Store Buffer for now)
// In future: check Store Buffer for store-to-load forwarding
assign mem_addr = req_addr;
assign mem_read = (is_load && !sb_load_hazard) ? 4'b1111 : 4'b0000;  // Full word read, let stage_wb handle extraction

// =============================================================================
// Store Buffer Instance
// =============================================================================

store_buffer #(
    .SB_DEPTH      (4),
    .SB_IDX_W      (2),
    .ORDER_ID_W    (ORDER_ID_W),
    .EPOCH_W       (EPOCH_W),
    .NUM_THREAD    (2)
) u_store_buffer (
    .clk                    (clk),
    .rstn                   (rstn),

    // Flush interface
    .flush                  (flush),
    .flush_tid              (flush_tid),
    .flush_new_epoch_t0     (flush_new_epoch_t0),
    .flush_new_epoch_t1     (flush_new_epoch_t1),

    // Store request interface
    .store_req_valid        (is_store),
    .store_req_accept       (sb_store_accept),
    .store_tid              (req_tid),
    .store_order_id         (req_order_id),
    .store_epoch            (req_epoch),
    .store_addr             (req_addr),
    .store_data             (req_wdata),
    .store_func3            (req_func3),

    // ROB commit interface
    .commit0_valid          (commit0_valid),
    .commit1_valid          (commit1_valid),
    .commit0_order_id       (commit0_order_id),
    .commit1_order_id       (commit1_order_id),
    .commit0_is_store       (commit0_is_store),
    .commit1_is_store       (commit1_is_store),

    // Memory write interface (drain)
    .mem_write_valid        (sb_mem_write_valid_int),
    .mem_write_addr         (sb_mem_write_addr_int),
    .mem_write_data         (sb_mem_write_data_int),
    .mem_write_func3        (sb_mem_write_func3_int),
    .mem_write_wen          (sb_mem_write_wen_int),
    .mem_write_ready        (sb_mem_write_ready),

    // Load query interface (for store-to-load forwarding)
    .load_query_valid       (is_load),
    .load_query_tid         (req_tid),
    .load_query_order_id    (req_order_id),
    .load_query_addr        (req_addr),
    .load_query_func3       (req_func3),

    .forward_data           (sb_forward_data),
    .forward_valid          (sb_forward_valid),
    .load_hazard            (sb_load_hazard)
);

// Export Store Buffer memory interface
assign sb_mem_write_valid = sb_mem_write_valid_int;
assign sb_mem_write_addr  = sb_mem_write_addr_int;
assign sb_mem_write_data  = sb_mem_write_data_int;
assign sb_mem_write_wen   = sb_mem_write_wen_int;

// =============================================================================
// Task 6: State Machine for Variable-Latency Memory Access
// =============================================================================

// State encoding
localparam LSU_IDLE      = 2'b00;  // Ready to accept new request
localparam LSU_REQ       = 2'b01;  // Request sent, waiting for grant
localparam LSU_WAIT_RESP = 2'b10;  // Waiting for response
localparam LSU_RESP      = 2'b11;  // Response ready

reg [1:0] lsu_state;

// Pending request registers (for both legacy and mem_subsys modes)
reg               pending_valid;
reg [0:0]         pending_tid;
reg [ORDER_ID_W-1:0] pending_order_id;
reg [EPOCH_W-1:0] pending_epoch;
reg [TAG_W-1:0]   pending_tag;
reg [4:0]         pending_rd;
reg [2:0]         pending_func3;
reg               pending_regs_write;
reg [2:0]         pending_fu;
reg               pending_mem2reg;
reg               pending_wen;
reg [31:0]        pending_addr;
reg               pending_forward_valid;  // Forwarding was used for this load
reg [31:0]        pending_forward_data;   // Forwarded data

// Raw memory data register (for mem_subsys mode)
reg [31:0]        raw_mem_rdata;

// State machine
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        lsu_state         <= LSU_IDLE;
        pending_valid     <= 1'b0;
        m1_req_valid      <= 1'b0;
        raw_mem_rdata     <= 32'd0;
    end else if (flush) begin
        // On flush, abort pending operations for the flushed thread
        if (pending_tid == flush_tid || !pending_valid) begin
            lsu_state     <= LSU_IDLE;
            pending_valid <= 1'b0;
            m1_req_valid  <= 1'b0;
        end
    end else begin
        case (lsu_state)
            LSU_IDLE: begin
                // Ready to accept new request
                if (req_valid && req_accept) begin
                    // Capture request metadata
                    pending_valid         <= 1'b1;
                    pending_tid           <= req_tid;
                    pending_order_id      <= req_order_id;
                    pending_epoch         <= req_epoch;
                    pending_tag           <= req_tag;
                    pending_rd            <= req_rd;
                    pending_func3         <= req_func3;
                    pending_regs_write    <= req_regs_write;
                    pending_fu            <= req_fu;
                    pending_mem2reg       <= req_mem2reg;
                    pending_wen           <= req_wen;
                    pending_addr          <= req_addr;
                    pending_forward_valid <= is_load && sb_forward_valid;
                    pending_forward_data  <= sb_forward_data;

                    if (use_mem_subsys && is_load && !sb_forward_valid) begin
                        // Load with mem_subsys: need to send request
                        lsu_state     <= LSU_REQ;
                        m1_req_valid  <= 1'b1;
                        m1_req_addr   <= req_addr;
                        m1_req_write  <= 1'b0;  // Read
                        m1_req_wdata  <= 32'd0;
                        m1_req_wen    <= 4'b0000;
                    end else if (is_store) begin
                        // Store: complete immediately (speculative)
                        lsu_state     <= LSU_RESP;
                    end else begin
                        // Load with forwarding or legacy mode: single cycle
                        lsu_state     <= LSU_RESP;
                    end
                end
            end

            LSU_REQ: begin
                // Waiting for mem_subsys to accept request
                if (m1_req_ready) begin
                    m1_req_valid <= 1'b0;
                    lsu_state    <= LSU_WAIT_RESP;
                end
            end

            LSU_WAIT_RESP: begin
                // Waiting for mem_subsys response
                if (m1_resp_valid) begin
                    raw_mem_rdata <= m1_resp_data;
                    lsu_state     <= LSU_RESP;
                end
            end

            LSU_RESP: begin
                // Response ready, will be consumed by writeback
                lsu_state     <= LSU_IDLE;
                pending_valid <= 1'b0;
            end

            default: begin
                lsu_state <= LSU_IDLE;
            end
        endcase
    end
end

// Legacy memory interface (for use_mem_subsys=0)
assign mem_addr = req_addr;
assign mem_read = (!use_mem_subsys && is_load && !sb_load_hazard) ? 4'b1111 : 4'b0000;

// =============================================================================
// Load Data Shaping (replicated from stage_wb for single-cycle response)
// =============================================================================

wire [1:0]  addr_in_word = pending_addr[1:0];

// Select raw memory data source: legacy (1-cycle) or mem_subsys (variable)
wire [31:0] raw_mem_data = use_mem_subsys ? raw_mem_rdata : mem_rdata;

// Combinational load data shaping for memory data (same logic as stage_wb)
reg [31:0] mem_data_shaped;
always @(*) begin
    case (pending_func3)
        `LB: begin
            case (addr_in_word)
                2'b00:   mem_data_shaped = {{24{raw_mem_data[7]}}, raw_mem_data[7:0]};
                2'b01:   mem_data_shaped = {{24{raw_mem_data[15]}},raw_mem_data[15:8]};
                2'b10:   mem_data_shaped = {{24{raw_mem_data[23]}},raw_mem_data[23:16]};
                2'b11:   mem_data_shaped = {{24{raw_mem_data[31]}},raw_mem_data[31:24]};
                default: mem_data_shaped = 32'd0;
            endcase
        end
        `LH: begin
            case (addr_in_word[1])
                1'b0:    mem_data_shaped = {{16{raw_mem_data[15]}},raw_mem_data[15:0]};
                1'b1:    mem_data_shaped = {{16{raw_mem_data[31]}},raw_mem_data[31:16]};
                default: mem_data_shaped = 32'd0;
            endcase
        end
        `LW:     mem_data_shaped = raw_mem_data;
        `LBU: begin
            case (addr_in_word)
                2'b00:   mem_data_shaped = {24'd0,raw_mem_data[7:0]};
                2'b01:   mem_data_shaped = {24'd0,raw_mem_data[15:8]};
                2'b10:   mem_data_shaped = {24'd0,raw_mem_data[23:16]};
                2'b11:   mem_data_shaped = {24'd0,raw_mem_data[31:24]};
                default: mem_data_shaped = 32'd0;
            endcase
        end
        `LHU: begin
            case (addr_in_word[1])
                1'b0:    mem_data_shaped = {16'b0,raw_mem_data[15:0]};
                1'b1:    mem_data_shaped = {16'b0,raw_mem_data[31:16]};
                default: mem_data_shaped = 32'd0;
            endcase
        end
        default: mem_data_shaped = 32'd0;
    endcase
end

// Combinational load data shaping for forwarded store buffer data
// Forwarded data is raw 32-bit store word, need to extract bytes based on address
reg [31:0] forward_data_shaped;
always @(*) begin
    case (pending_func3)
        `LB: begin
            case (addr_in_word)
                2'b00:   forward_data_shaped = {{24{pending_forward_data[7]}}, pending_forward_data[7:0]};
                2'b01:   forward_data_shaped = {{24{pending_forward_data[15]}},pending_forward_data[15:8]};
                2'b10:   forward_data_shaped = {{24{pending_forward_data[23]}},pending_forward_data[23:16]};
                2'b11:   forward_data_shaped = {{24{pending_forward_data[31]}},pending_forward_data[31:24]};
                default: forward_data_shaped = 32'd0;
            endcase
        end
        `LH: begin
            case (addr_in_word[1])
                1'b0:    forward_data_shaped = {{16{pending_forward_data[15]}},pending_forward_data[15:0]};
                1'b1:    forward_data_shaped = {{16{pending_forward_data[31]}},pending_forward_data[31:16]};
                default: forward_data_shaped = 32'd0;
            endcase
        end
        `LW:     forward_data_shaped = pending_forward_data;
        `LBU: begin
            case (addr_in_word)
                2'b00:   forward_data_shaped = {24'd0,pending_forward_data[7:0]};
                2'b01:   forward_data_shaped = {24'd0,pending_forward_data[15:8]};
                2'b10:   forward_data_shaped = {24'd0,pending_forward_data[23:16]};
                2'b11:   forward_data_shaped = {24'd0,pending_forward_data[31:24]};
                default: forward_data_shaped = 32'd0;
            endcase
        end
        `LHU: begin
            case (addr_in_word[1])
                1'b0:    forward_data_shaped = {16'b0,pending_forward_data[15:0]};
                1'b1:    forward_data_shaped = {16'b0,pending_forward_data[31:16]};
                default: forward_data_shaped = 32'd0;
            endcase
        end
        default: forward_data_shaped = 32'd0;
    endcase
end

// =============================================================================
// Response Generation (Task 6: Works with state machine)
// =============================================================================

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        resp_valid        <= 1'b0;
        resp_tid          <= 1'b0;
        resp_order_id     <= {ORDER_ID_W{1'b0}};
        resp_epoch        <= {EPOCH_W{1'b0}};
        resp_tag          <= {TAG_W{1'b0}};
        resp_rd           <= 5'd0;
        resp_func3        <= 3'd0;
        resp_regs_write   <= 1'b0;
        resp_fu           <= 3'd0;
        resp_rdata        <= 32'd0;
    end else begin
        // Response valid when in RESP state
        if (lsu_state == LSU_RESP) begin
            if (!pending_wen) begin
                // Load response
                resp_valid        <= 1'b1;
                resp_tid          <= pending_tid;
                resp_order_id     <= pending_order_id;
                resp_epoch        <= pending_epoch;
                resp_tag          <= pending_tag;
                resp_rd           <= pending_rd;
                resp_func3        <= pending_func3;
                resp_regs_write   <= pending_regs_write && pending_mem2reg;
                resp_fu           <= pending_fu;
                // Use shaped forwarded data if available, otherwise use shaped memory data
                if (pending_forward_valid) begin
                    resp_rdata    <= forward_data_shaped;
                end else begin
                    resp_rdata    <= mem_data_shaped;
                end
            end else begin
                // Store response (speculative completion - store is in buffer)
                resp_valid        <= 1'b1;
                resp_tid          <= pending_tid;
                resp_order_id     <= pending_order_id;
                resp_epoch        <= pending_epoch;
                resp_tag          <= pending_tag;
                resp_rd           <= pending_rd;
                resp_func3        <= pending_func3;
                resp_regs_write   <= 1'b0;  // Stores don't write registers
                resp_fu           <= pending_fu;
                resp_rdata        <= 32'd0;
            end
        end else begin
            resp_valid <= 1'b0;
        end
    end
end

endmodule
