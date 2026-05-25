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
`include "define.v"

module lsu_shell #(
    parameter TAG_W = 5,
    parameter ORDER_ID_W = `METADATA_ORDER_ID_W,
    parameter EPOCH_W = 8
)(
    input  wire               clk,
    input  wire               rstn,

    // ─── Flush (for speculation management) ─────────────────────
    input  wire               flush,
    input  wire [0:0]         flush_tid,
    input  wire [EPOCH_W-1:0] flush_new_epoch_t0,
    input  wire [EPOCH_W-1:0] flush_new_epoch_t1,
    input  wire [EPOCH_W-1:0] current_epoch_t0,
    input  wire [EPOCH_W-1:0] current_epoch_t1,
    input  wire               flush_order_valid,
    input  wire [ORDER_ID_W-1:0] flush_order_id,

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
    input  wire               req_amo,           // RV32A atomic memory op
    input  wire [4:0]         req_amo_op,        // AMO funct5 from inst[31:27]
    input  wire               req_wen,           // 1=store, 0=load
    input  wire [31:0]        req_addr,          // Effective address
    input  wire [31:0]        req_wdata,         // Store data (for stores)
    input  wire               req_regs_write,    // Register write enable
    input  wire [2:0]         req_fu,            // FU type (FU_LOAD/FU_STORE)
    input  wire               req_mem2reg,       // Load to register

    // Sv32 D-side translation. Store buffer and mem_subsys see physical
    // addresses; fault delivery is plumbed to ROB in the next stage.
    output wire               mmu_dtlb_req_valid,
    output wire [31:0]        mmu_dtlb_req_vaddr,
    output wire               mmu_dtlb_req_store,
    input  wire               mmu_dtlb_resp_hit,
    input  wire [31:0]        mmu_dtlb_resp_paddr,
    input  wire               mmu_dtlb_resp_fault,
    input  wire [4:0]         mmu_dtlb_resp_cause,
    input  wire [31:0]        mmu_dtlb_resp_tval,
    input  wire               mmu_dtlb_busy,

    // ROB head query: side-effecting MMIO loads may only issue at ROB head.
    input  wire               rob_head_valid_t0,
    input  wire [ORDER_ID_W-1:0] rob_head_order_id_t0,
    input  wire               rob_head_flushed_t0,
    input  wire               rob_head_valid_t1,
    input  wire [ORDER_ID_W-1:0] rob_head_order_id_t1,
    input  wire               rob_head_flushed_t1,

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
    output reg                resp_exc_valid,
    output reg  [31:0]        resp_exc_cause,
    output reg  [31:0]        resp_exc_tval,

    // Early wakeup for IQ dependency tracking
    output wire               resp_early_wakeup_valid,
    output wire [TAG_W-1:0]   resp_early_wakeup_tag,

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
    output wire               m1_req_valid,
    input  wire               m1_req_ready,
    output wire [31:0]        m1_req_addr,
    output wire               m1_req_write,      // 0=read, 1=write
    output wire [31:0]        m1_req_wdata,
    output wire [3:0]         m1_req_wen,        // Byte-wise write enable

    // M1 Response
    input  wire               m1_resp_valid,
    input  wire [31:0]        m1_resp_data,
    input  wire               m1_resp_l1d_hit,

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
    output wire               debug_store_buffer_empty,
    output wire [2:0]         debug_store_buffer_count_t0,
    output wire [2:0]         debug_store_buffer_count_t1,

    // ═══════════════════════════════════════════════════════════════════════════
    // Load Hazard Output (to scoreboard for stalling)
    // ═══════════════════════════════════════════════════════════════════════════
    output wire               load_hazard,          // Load must be retried

    // HPM event
    output wire               hpm_sb_stall_event,

    // Speculation firewall debug
    output wire               debug_spec_mmio_load_blocked,
    output wire               debug_spec_mmio_load_violation,
    output wire               debug_mmio_load_at_rob_head,
    output wire               debug_older_store_blocked_mmio_load,
    output reg                debug_lsu_cooldown_set,
    output reg                debug_lsu_cooldown_skipped_l1hit
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

wire                     sb_mem_write_ready_mux;

// Store Buffer forwarding signals
wire [31:0]              sb_forward_data;
wire                     sb_forward_valid;
wire                     sb_load_hazard;
wire                     sb_older_store_pending_for_load;
wire                     sb_debug_empty;
wire [2:0]               sb_debug_count_t0;
wire [2:0]               sb_debug_count_t1 = 3'd0; // Single-thread: no T1
wire                     sb_stall_event;
wire                     sb_drain_urgent;

// Load/Store/AMO classification. AMO carries both read and write intent but is
// handled as a serialized read-modify-write transaction, not as a store-buffer
// enqueue.
wire is_amo   = req_valid && req_amo;
wire is_load  = req_valid && !req_wen && !req_amo;
wire is_store = req_valid && req_wen && !req_amo;
wire store_enqueue_fire;
wire legacy_load_issue_fire;
wire req_flush_kill =
    req_valid && flush &&
    (!flush_order_valid || (req_order_id > flush_order_id));
wire req_amo_is_store_side = req_amo && (req_amo_op != `AMO_LR);
assign mmu_dtlb_req_valid = req_valid && !req_flush_kill;
assign mmu_dtlb_req_vaddr = req_addr;
assign mmu_dtlb_req_store = req_wen || req_amo_is_store_side;
wire req_translation_fault = req_valid && !req_flush_kill && mmu_dtlb_resp_fault;
wire req_translation_ready = mmu_dtlb_resp_hit && !mmu_dtlb_resp_fault;
wire [31:0] req_paddr = req_translation_ready ? mmu_dtlb_resp_paddr : req_addr;
wire _unused_mmu_dtlb_meta = |{mmu_dtlb_resp_cause, mmu_dtlb_resp_tval, mmu_dtlb_busy};

wire req_addr_is_mmio_0x13 = (req_paddr[31:16] == 16'h1300);
wire req_addr_is_clint     = (req_paddr >= `CLINT_BASE) && (req_paddr <= `CLINT_MTIME_HI);
wire req_addr_is_plic      = (req_paddr >= `PLIC_BASE) && (req_paddr <= `PLIC_CLAIM_COMPLETE);
wire req_addr_is_mmio      = req_addr_is_mmio_0x13 || req_addr_is_clint || req_addr_is_plic;
wire req_is_mmio_load      = is_load && req_translation_ready && req_addr_is_mmio;

wire req_at_rob_head_t0 =
    rob_head_valid_t0 && !rob_head_flushed_t0 &&
    (rob_head_order_id_t0 == req_order_id);
wire req_at_rob_head_t1 =
    rob_head_valid_t1 && !rob_head_flushed_t1 &&
    (rob_head_order_id_t1 == req_order_id);
wire req_at_rob_head = req_at_rob_head_t0;
wire mmio_load_spec_block = req_is_mmio_load && !req_at_rob_head;
wire mmio_load_older_store_block =
    req_is_mmio_load && req_at_rob_head && sb_older_store_pending_for_load;



// =============================================================================
// Request Acceptance Logic (Task 6: State machine aware)
// =============================================================================

// LSU is ready to accept requests:
// - For loads: ready if no store buffer hazard detected and state machine idle
// - For stores: ready if store buffer has space and state machine idle
// Note: We check store buffer capacity here without creating a combinational loop
// by checking capacity directly rather than depending on store_req_valid

// State machine must be idle to accept most new requests.  A returning M1 load
// response can also accept the next non-forwarded load in the same cycle: the
// response path consumes the old pending metadata, while the state machine
// captures the new request with nonblocking assignments.
wire state_machine_idle = (lsu_state == LSU_IDLE);
wire sb_drain_ready_to_issue =
    use_mem_subsys && state_machine_idle && sb_mem_write_valid_int;
wire mem_subsys_load_resp_fire =
                use_mem_subsys && (lsu_state == LSU_WAIT_RESP) &&
                m1_resp_valid && !m1_txn_is_drain && !m1_txn_is_amo;
wire load_resp_accept_slot = mem_subsys_load_resp_fire;

assign resp_early_wakeup_valid =
    mem_subsys_load_resp_fire && pending_valid && !(flush && flush_kills_pending) &&
    !pending_wen && pending_regs_write && pending_mem2reg;
assign resp_early_wakeup_tag = pending_tag;

// After completing an M1 transaction, hold off accepting new requests
// until the store buffer has drained below the full threshold.
// This prevents store buffer starvation during long-latency loads.
reg m1_cooldown_r;
wire sb_has_pending_stores = (sb_debug_count_t0 > 0) || (sb_debug_count_t1 > 0);
wire m1_drain_holdoff = m1_cooldown_r && sb_has_pending_stores;

// Accept stores when store buffer has space and the state machine is idle.
// In mem_subsys mode, a committed store-buffer drain takes priority over new
// requests so the LSU cannot acknowledge a request while capturing a drain.
wire store_accept = req_translation_ready &&
                    sb_store_accept && state_machine_idle &&
                    !sb_drain_ready_to_issue && !req_flush_kill;

// Accept loads when no hazard is detected from store buffer and state machine idle
// The hazard check is combinational based on current SB state
wire load_accept = req_translation_ready &&
                   !sb_load_hazard && !m1_drain_holdoff &&
                   !sb_drain_ready_to_issue &&
                   !req_flush_kill &&
                   !mmio_load_spec_block && !mmio_load_older_store_block &&
                   (state_machine_idle ||
                    (load_resp_accept_slot && !sb_forward_valid));
wire amo_accept = req_translation_ready &&
                  use_mem_subsys && state_machine_idle &&
                  !sb_drain_ready_to_issue &&
                  !req_flush_kill &&
                  req_at_rob_head &&
                  !sb_older_store_pending_for_load;
wire fault_accept = req_translation_fault &&
                    state_machine_idle &&
                    !sb_drain_ready_to_issue;

assign req_accept = req_amo ? (amo_accept || fault_accept) :
                    is_store ? (store_accept || fault_accept) :
                    (load_accept || fault_accept);
assign store_enqueue_fire = is_store && store_accept;
assign legacy_load_issue_fire = !use_mem_subsys && is_load && load_accept && !sb_forward_valid;

// Export load hazard signal for scoreboard stalling
assign load_hazard = is_load && sb_load_hazard;

// =============================================================================
// Store Buffer Instance
// =============================================================================

store_buffer #(
    .SB_DEPTH      (4),
    .SB_IDX_W      (2),
    .ORDER_ID_W    (ORDER_ID_W),
    .EPOCH_W       (EPOCH_W)
) u_store_buffer (
    .clk                    (clk),
    .rstn                   (rstn),

    // Flush interface
    .flush                  (flush),
    .flush_new_epoch_t0     (flush_new_epoch_t0),
    .current_epoch_t0       (current_epoch_t0),
    .flush_order_valid      (flush_order_valid),
    .flush_order_id         (flush_order_id),

    // Store request interface
    // Only enqueue a store when the LSU request handshake succeeds. Using the
    // raw store request here lets a busy LSU leak stores into the buffer before
    // the ROB/writeback path sees them, which wedges commit behind an
    // incomplete store entry.
    .store_req_valid        (store_enqueue_fire),
    .store_req_accept       (sb_store_accept),
    .store_order_id         (req_order_id),
    .store_epoch            (req_epoch),
    .store_addr             (req_paddr),
    .store_data             (req_wdata),
    .store_func3            (req_func3),

    // ROB commit interface
    .commit0_valid          (commit0_valid),
    .commit0_order_id       (commit0_order_id),
    .commit0_is_store       (commit0_is_store),

    // Memory write interface (drain)
    .mem_write_valid        (sb_mem_write_valid_int),
    .mem_write_addr         (sb_mem_write_addr_int),
    .mem_write_data         (sb_mem_write_data_int),
    .mem_write_func3        (sb_mem_write_func3_int),
    .mem_write_wen          (sb_mem_write_wen_int),
    .mem_write_ready        (sb_mem_write_ready_mux),

    // Load query interface (for store-to-load forwarding)
    .load_query_valid       (is_load || is_amo),
    .load_query_order_id    (req_order_id),
    .load_query_addr        (req_paddr),
    .load_query_func3       (req_func3),

    .forward_data           (sb_forward_data),
    .forward_valid          (sb_forward_valid),
    .load_hazard            (sb_load_hazard),
    .older_store_pending_for_load(sb_older_store_pending_for_load),
    .debug_empty            (sb_debug_empty),
    .debug_count_t0         (sb_debug_count_t0),
    .sb_stall_event         (sb_stall_event),
    .sb_drain_urgent        (sb_drain_urgent)
);

// Export Store Buffer memory interface
assign sb_mem_write_valid = sb_mem_write_valid_int;
assign sb_mem_write_addr  = sb_mem_write_addr_int;
assign sb_mem_write_data  = sb_mem_write_data_int;
assign sb_mem_write_wen   = sb_mem_write_wen_int;
assign debug_store_buffer_empty = sb_debug_empty;
assign hpm_sb_stall_event = sb_stall_event;
assign debug_store_buffer_count_t0 = sb_debug_count_t0;
assign debug_store_buffer_count_t1 = sb_debug_count_t1;

// =============================================================================
// Task 6: State Machine for Variable-Latency Memory Access
// =============================================================================

// State encoding
localparam LSU_IDLE           = 3'd0;  // Ready to accept new request
localparam LSU_REQ            = 3'd1;  // Request sent, waiting for grant
localparam LSU_WAIT_RESP      = 3'd2;  // Waiting for response
localparam LSU_RESP           = 3'd3;  // Response ready
localparam LSU_AMO_WRITE_REQ  = 3'd4;  // AMO writeback request
localparam LSU_AMO_WRITE_RESP = 3'd5;  // AMO writeback response
localparam [19:0] LSU_WAIT_WATCHDOG_MAX = 20'hfffff;

reg [2:0] lsu_state;
reg               m1_req_valid_r;
reg [31:0]        m1_req_addr_r;
reg               m1_req_write_r;
reg [31:0]        m1_req_wdata_r;
reg [3:0]         m1_req_wen_r;
reg [19:0]        lsu_wait_watchdog_r;

// Pending request registers (for both legacy and mem_subsys modes)
reg               pending_valid;
reg [ORDER_ID_W-1:0] pending_order_id;
reg [EPOCH_W-1:0] pending_epoch;
reg [TAG_W-1:0]   pending_tag;
reg [4:0]         pending_rd;
reg [2:0]         pending_func3;
reg               pending_regs_write;
reg [2:0]         pending_fu;
reg               pending_mem2reg;
reg               pending_wen;
reg               pending_amo;
reg [4:0]         pending_amo_op;
reg [31:0]        pending_addr;
reg [31:0]        pending_wdata;
reg               pending_forward_valid;  // Forwarding was used for this load
reg [31:0]        pending_forward_data;   // Forwarded data
reg [31:0]        pending_amo_resp_data;

// Raw memory data register (for mem_subsys mode)
reg [31:0]        raw_mem_rdata;
reg               m1_txn_is_drain;
reg               m1_txn_is_amo;
reg               dbg_beacon_block_reported_r;
reg               lr_reservation_valid_r;
reg [29:0]        lr_reservation_word_r;
wire              flush_hits_pending =
                    pending_valid;
// Only kill when there IS a pending speculative request to kill.
// The old `!pending_valid || ...` made the flush branch vacuously
// true when idle, which silently dropped new requests arriving in
// the same cycle as a flush (the if/else skipped the state machine).
wire              flush_kills_pending =
                    pending_valid &&
                    flush_hits_pending &&
                    (!flush_order_valid || (pending_order_id > flush_order_id));
wire              pending_flush_kill = flush && flush_kills_pending;

assign sb_mem_write_ready_mux = use_mem_subsys ?
                                state_machine_idle :
                                sb_mem_write_ready;

wire mem_subsys_load_issue_fire =
    use_mem_subsys && req_valid && load_accept && is_load && !sb_forward_valid;
wire mem_subsys_amo_issue_fire =
    use_mem_subsys && req_valid && amo_accept && is_amo;
wire store_accept_resp_fire =
    (lsu_state == LSU_IDLE) && req_valid && store_accept && is_store;
wire fault_accept_resp_fire =
    (lsu_state == LSU_IDLE) && req_valid && fault_accept;

assign m1_req_valid = (mem_subsys_load_issue_fire || mem_subsys_amo_issue_fire) ?
                      1'b1 : m1_req_valid_r;
assign m1_req_addr  = (mem_subsys_load_issue_fire || mem_subsys_amo_issue_fire) ?
                      req_paddr : m1_req_addr_r;
assign m1_req_write = (mem_subsys_load_issue_fire || mem_subsys_amo_issue_fire) ?
                      1'b0 : m1_req_write_r;
assign m1_req_wdata = (mem_subsys_load_issue_fire || mem_subsys_amo_issue_fire) ?
                      32'd0 : m1_req_wdata_r;
assign m1_req_wen   = (mem_subsys_load_issue_fire || mem_subsys_amo_issue_fire) ?
                      4'b0000 : m1_req_wen_r;

wire pending_at_rob_head_t0 =
    rob_head_valid_t0 && !rob_head_flushed_t0 &&
    (rob_head_order_id_t0 == pending_order_id);
wire pending_at_rob_head_t1 =
    rob_head_valid_t1 && !rob_head_flushed_t1 &&
    (rob_head_order_id_t1 == pending_order_id);
wire pending_at_rob_head = pending_at_rob_head_t0;
wire m1_req_addr_is_mmio_0x13 = (m1_req_addr[31:16] == 16'h1300);
wire m1_req_addr_is_clint     = (m1_req_addr >= `CLINT_BASE) && (m1_req_addr <= `CLINT_MTIME_HI);
wire m1_req_addr_is_plic      = (m1_req_addr >= `PLIC_BASE) && (m1_req_addr <= `PLIC_CLAIM_COMPLETE);
wire m1_req_addr_is_mmio      = m1_req_addr_is_mmio_0x13 || m1_req_addr_is_clint || m1_req_addr_is_plic;
wire current_mmio_load_violation =
    mem_subsys_load_issue_fire && req_addr_is_mmio && !req_at_rob_head;
wire pending_mmio_load_violation =
    m1_req_valid_r && !m1_req_write_r && m1_req_addr_is_mmio &&
    !(pending_valid && pending_at_rob_head);

assign debug_spec_mmio_load_blocked = req_valid && mmio_load_spec_block;
assign debug_mmio_load_at_rob_head = req_valid && req_is_mmio_load && req_at_rob_head;
assign debug_older_store_blocked_mmio_load =
    req_valid && mmio_load_older_store_block;
assign debug_spec_mmio_load_violation =
    use_mem_subsys && (current_mmio_load_violation || pending_mmio_load_violation);

wire lr_reservation_match =
    lr_reservation_valid_r && (lr_reservation_word_r == pending_addr[31:2]);

function [31:0] amo_next_value;
    input [4:0]  amo_op;
    input [31:0] old_value;
    input [31:0] operand;
    begin
        case (amo_op)
            `AMO_SWAP: amo_next_value = operand;
            `AMO_ADD:  amo_next_value = old_value + operand;
            `AMO_XOR:  amo_next_value = old_value ^ operand;
            `AMO_AND:  amo_next_value = old_value & operand;
            `AMO_OR:   amo_next_value = old_value | operand;
            `AMO_MIN:  amo_next_value = ($signed(old_value) < $signed(operand)) ? old_value : operand;
            `AMO_MAX:  amo_next_value = ($signed(old_value) > $signed(operand)) ? old_value : operand;
            `AMO_MINU: amo_next_value = (old_value < operand) ? old_value : operand;
            `AMO_MAXU: amo_next_value = (old_value > operand) ? old_value : operand;
            default:   amo_next_value = operand;
        endcase
    end
endfunction

// State machine
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        lsu_state         <= LSU_IDLE;
        pending_valid     <= 1'b0;
        pending_amo       <= 1'b0;
        pending_amo_op    <= 5'd0;
        pending_wdata     <= 32'd0;
        pending_amo_resp_data <= 32'd0;
        m1_req_valid_r    <= 1'b0;
        m1_req_addr_r     <= 32'd0;
        m1_req_write_r    <= 1'b0;
        m1_req_wdata_r    <= 32'd0;
        m1_req_wen_r      <= 4'd0;
        lsu_wait_watchdog_r <= 20'd0;
        raw_mem_rdata     <= 32'd0;
        m1_txn_is_drain   <= 1'b0;
        m1_txn_is_amo     <= 1'b0;
        dbg_beacon_block_reported_r <= 1'b0;
        m1_cooldown_r     <= 1'b0;
        debug_lsu_cooldown_set <= 1'b0;
        debug_lsu_cooldown_skipped_l1hit <= 1'b0;
        lr_reservation_valid_r <= 1'b0;
        lr_reservation_word_r  <= 30'd0;
    end else begin
        debug_lsu_cooldown_set <= 1'b0;
        debug_lsu_cooldown_skipped_l1hit <= 1'b0;
        if (lsu_state != LSU_WAIT_RESP)
            lsu_wait_watchdog_r <= 20'd0;
        if (!sb_has_pending_stores)
            m1_cooldown_r <= 1'b0;
        if (!(req_valid && !req_accept && is_store && (req_paddr == `DEBUG_BEACON_EVT_ADDR))) begin
            dbg_beacon_block_reported_r <= 1'b0;
        end
        if (!m1_txn_is_drain && pending_flush_kill) begin
            // On flush, abort speculative load requests, but never discard a
            // committed store-buffer drain that has already been handed off.
            // Branch redirects only kill younger requests from the flushed thread.
            `ifdef VERBOSE_SIM_LOGS
            $display("[LSU FLUSH] pending_valid=%0b pending_tid=0 pending_order=%0d flush_tid=%0d flush_order_valid=%0b flush_order=%0d @%0t",
                     pending_valid, pending_order_id,
                     flush_tid, flush_order_valid, flush_order_id, $time);
            `endif
            pending_valid   <= 1'b0;
            pending_amo     <= 1'b0;
            m1_req_valid_r  <= 1'b0;
            m1_txn_is_drain <= 1'b0;
            m1_txn_is_amo   <= 1'b0;
            // Allow drain to proceed concurrently with flush — committed
            // stores must reach memory even during continuous trap/mret cycles.
            if (lsu_state == LSU_IDLE && use_mem_subsys &&
                sb_mem_write_valid_int && sb_mem_write_ready_mux) begin
                m1_txn_is_drain <= 1'b1;
                lsu_state       <= LSU_REQ;
                m1_req_valid_r  <= 1'b1;
                m1_req_addr_r   <= sb_mem_write_addr_int;
                m1_req_write_r  <= 1'b1;
                m1_req_wdata_r  <= sb_mem_write_data_int;
                m1_req_wen_r    <= sb_mem_write_wen_int;
                lr_reservation_valid_r <= 1'b0;
            end else begin
                lsu_state       <= LSU_IDLE;
            end
        end else begin
        case (lsu_state)
            LSU_IDLE: begin
                // When store buffer is nearly full with committed stores,
                // prioritize drain over new request acceptance to prevent
                // store buffer starvation during long-latency loads.
                if (use_mem_subsys &&
                    sb_mem_write_valid_int && sb_mem_write_ready_mux) begin
                    pending_valid       <= 1'b0;
                    pending_amo         <= 1'b0;
                    m1_txn_is_drain     <= 1'b1;
                    m1_txn_is_amo       <= 1'b0;
                    lsu_state           <= LSU_REQ;
                    m1_req_valid_r      <= 1'b1;
                    m1_req_addr_r       <= sb_mem_write_addr_int;
                    m1_req_write_r      <= 1'b1;
                    m1_req_wdata_r      <= sb_mem_write_data_int;
                    m1_req_wen_r        <= sb_mem_write_wen_int;
                    lr_reservation_valid_r <= 1'b0;
                end else if (req_valid && fault_accept) begin
                    pending_valid <= 1'b0;
                    pending_amo   <= 1'b0;
                    m1_txn_is_drain <= 1'b0;
                    m1_txn_is_amo <= 1'b0;
                    lsu_state <= LSU_IDLE;
                    if (is_store || req_amo_is_store_side)
                        lr_reservation_valid_r <= 1'b0;
                end else if (req_valid && req_accept) begin
`ifdef VERBOSE_SIM_LOGS
                    if (is_store && (req_paddr == `DEBUG_BEACON_EVT_ADDR)) begin
                        $display("[DBG_LSU_ACCEPT] t=%0t order=%0d tag=%0d addr=%h wdata=%h func3=%0d tid=%0d",
                                 $time, req_order_id, req_tag, req_addr, req_wdata, req_func3, req_tid);
                    end
`endif
                    `ifdef VERBOSE_SIM_LOGS
                    $display("[LSU ACCEPT] kind=%s tid=%0d order=%0d tag=%0d func3=%0d addr=%h wdata=%h rd=%0d",
                             req_wen ? "STORE" : "LOAD ", req_tid, req_order_id, req_tag,
                             req_func3, req_addr, req_wdata, req_rd);
                    `endif
                    // Capture request metadata
                    pending_valid         <= 1'b1;
                    // pending_tid removed (single-thread)
                    pending_order_id      <= req_order_id;
                    pending_epoch         <= req_epoch;
                    pending_tag           <= req_tag;
                    pending_rd            <= req_rd;
                    pending_func3         <= req_func3;
                    pending_regs_write    <= req_regs_write;
                    pending_fu            <= req_fu;
                    pending_mem2reg       <= req_mem2reg;
                    pending_wen           <= req_wen;
                    pending_amo           <= req_amo;
                    pending_amo_op        <= req_amo_op;
                    pending_addr          <= req_paddr;
                    pending_wdata         <= req_wdata;
                    pending_forward_valid <= is_load && sb_forward_valid;
                    pending_forward_data  <= sb_forward_data;
                    pending_amo_resp_data <= 32'd0;
                    m1_txn_is_drain       <= 1'b0;
                    m1_txn_is_amo         <= req_amo;

                    if (use_mem_subsys && is_amo) begin
                        if (m1_req_ready) begin
                            lsu_state      <= LSU_WAIT_RESP;
                            m1_req_valid_r <= 1'b0;
                        end else begin
                            lsu_state      <= LSU_REQ;
                            m1_req_valid_r <= 1'b1;
                            m1_req_addr_r  <= req_paddr;
                            m1_req_write_r <= 1'b0;
                            m1_req_wdata_r <= 32'd0;
                            m1_req_wen_r   <= 4'b0000;
                        end
                    end else if (use_mem_subsys && is_load && !sb_forward_valid) begin
                        // The load request is already visible on M1 in this
                        // cycle. Only park it if M1 cannot accept it now.
                        if (m1_req_ready) begin
                            lsu_state      <= LSU_WAIT_RESP;
                            m1_req_valid_r <= 1'b0;
                        end else begin
                            lsu_state      <= LSU_REQ;
                            m1_req_valid_r <= 1'b1;
                            m1_req_addr_r  <= req_paddr;
                            m1_req_write_r <= 1'b0;  // Read
                            m1_req_wdata_r <= 32'd0;
                            m1_req_wen_r   <= 4'b0000;
                        end
                    end else if (!use_mem_subsys && is_load && !sb_forward_valid) begin
                        // Legacy load: issue the read only for the accepted request,
                        // then wait one cycle to sample the returned data.
                        lsu_state     <= LSU_REQ;
                    end else if (is_store) begin
                        // Store: complete speculatively as it enters the SB.
                        lsu_state     <= LSU_IDLE;
                        pending_valid <= 1'b0;
                        pending_amo   <= 1'b0;
                        lr_reservation_valid_r <= 1'b0;
                    end else begin
                        // Load with forwarding or legacy mode: single cycle
                        lsu_state     <= LSU_RESP;
                    end
                end else if (req_valid && !req_accept && is_store && (req_addr == `DEBUG_BEACON_EVT_ADDR) &&
                             !dbg_beacon_block_reported_r) begin
`ifdef VERBOSE_SIM_LOGS
                    $display("[DBG_LSU_BLOCK] t=%0t state=%0d idle=%0b sb_accept=%0b count_t0=%0d count_t1=%0d order=%0d tag=%0d addr=%h",
                             $time, lsu_state, state_machine_idle, sb_store_accept,
                             sb_debug_count_t0, sb_debug_count_t1, req_order_id, req_tag, req_addr);
`endif
                    dbg_beacon_block_reported_r <= 1'b1;
                end else if (use_mem_subsys && sb_mem_write_valid_int && sb_mem_write_ready_mux) begin
                    // Drain one committed store-buffer entry through mem_subsys M1.
`ifdef VERBOSE_SIM_LOGS
                    if (sb_mem_write_addr_int == `DEBUG_BEACON_EVT_ADDR) begin
                        $display("[DBG_LSU_DRAIN] t=%0t addr=%h wdata=%h wen=%b",
                                 $time, sb_mem_write_addr_int, sb_mem_write_data_int, sb_mem_write_wen_int);
                    end
`endif
                    pending_valid       <= 1'b0;
                    pending_amo         <= 1'b0;
                    m1_txn_is_drain     <= 1'b1;
                    m1_txn_is_amo       <= 1'b0;
                    lsu_state           <= LSU_REQ;
                    m1_req_valid_r      <= 1'b1;
                    m1_req_addr_r       <= sb_mem_write_addr_int;
                    m1_req_write_r      <= 1'b1;
                    m1_req_wdata_r      <= sb_mem_write_data_int;
                    m1_req_wen_r        <= sb_mem_write_wen_int;
                    lr_reservation_valid_r <= 1'b0;
                end
            end

            LSU_REQ: begin
                if (req_valid && !req_accept && is_store && (req_addr == `DEBUG_BEACON_EVT_ADDR) &&
                    !dbg_beacon_block_reported_r) begin
`ifdef VERBOSE_SIM_LOGS
                    $display("[DBG_LSU_BLOCK] t=%0t state=%0d idle=%0b sb_accept=%0b count_t0=%0d count_t1=%0d order=%0d tag=%0d addr=%h",
                             $time, lsu_state, state_machine_idle, sb_store_accept,
                             sb_debug_count_t0, sb_debug_count_t1, req_order_id, req_tag, req_addr);
`endif
                    dbg_beacon_block_reported_r <= 1'b1;
                end
                if (use_mem_subsys) begin
                    // Waiting for mem_subsys to accept request
                    if (m1_req_ready) begin
`ifdef VERBOSE_SIM_LOGS
                        if (m1_txn_is_drain && (m1_req_addr == `DEBUG_BEACON_EVT_ADDR)) begin
                            $display("[DBG_LSU_REQ_GNT] t=%0t addr=%h wdata=%h wen=%b",
                                     $time, m1_req_addr, m1_req_wdata, m1_req_wen);
                        end
`endif
                        m1_req_valid_r <= 1'b0;
                        lsu_state    <= LSU_WAIT_RESP;
                    end
                end else begin
                    // Legacy load returns through mem_rdata one cycle after the
                    // accepted request pulse. Sample it here to decouple the
                    // response path from any younger speculative requests.
                    raw_mem_rdata <= mem_rdata;
                    lsu_state     <= LSU_RESP;
                end
            end

            LSU_WAIT_RESP: begin
                if (req_valid && !req_accept && is_store && (req_addr == `DEBUG_BEACON_EVT_ADDR) &&
                    !dbg_beacon_block_reported_r) begin
`ifdef VERBOSE_SIM_LOGS
                    $display("[DBG_LSU_BLOCK] t=%0t state=%0d idle=%0b sb_accept=%0b count_t0=%0d count_t1=%0d order=%0d tag=%0d addr=%h",
                             $time, lsu_state, state_machine_idle, sb_store_accept,
                             sb_debug_count_t0, sb_debug_count_t1, req_order_id, req_tag, req_addr);
`endif
                    dbg_beacon_block_reported_r <= 1'b1;
                end
                // Waiting for mem_subsys response
                if (m1_resp_valid) begin
                    lsu_wait_watchdog_r <= 20'd0;
`ifdef VERBOSE_SIM_LOGS
                    if (m1_txn_is_drain && (m1_req_addr == `DEBUG_BEACON_EVT_ADDR)) begin
                        $display("[DBG_LSU_RESP_SEEN] t=%0t drain=%0d addr=%h data=%h",
                                 $time, m1_txn_is_drain, m1_req_addr, m1_resp_data);
                    end
`endif
                    `ifdef VERBOSE_SIM_LOGS
                    $display("[LSU RESP] drain=%0d addr=%h raw=%h shaped=%h",
                             m1_txn_is_drain, pending_addr, m1_resp_data, mem_data_shaped);
                    `endif
                    if (m1_txn_is_amo) begin
                        raw_mem_rdata <= m1_resp_data;
                        if (pending_amo_op == `AMO_LR) begin
                            pending_amo_resp_data <= m1_resp_data;
                            lr_reservation_valid_r <= 1'b1;
                            lr_reservation_word_r  <= pending_addr[31:2];
                            m1_txn_is_amo <= 1'b0;
                            lsu_state <= LSU_RESP;
                        end else if (pending_amo_op == `AMO_SC) begin
                            lr_reservation_valid_r <= 1'b0;
                            if (lr_reservation_match) begin
                                pending_amo_resp_data <= 32'd0;
                                lsu_state       <= LSU_AMO_WRITE_REQ;
                                m1_req_valid_r  <= 1'b1;
                                m1_req_addr_r   <= pending_addr;
                                m1_req_write_r  <= 1'b1;
                                m1_req_wdata_r  <= pending_wdata;
                                m1_req_wen_r    <= 4'b1111;
                            end else begin
                                pending_amo_resp_data <= 32'd1;
                                m1_txn_is_amo <= 1'b0;
                                lsu_state <= LSU_RESP;
                            end
                        end else begin
                            pending_amo_resp_data <= m1_resp_data;
                            lr_reservation_valid_r <= 1'b0;
                            lsu_state       <= LSU_AMO_WRITE_REQ;
                            m1_req_valid_r  <= 1'b1;
                            m1_req_addr_r   <= pending_addr;
                            m1_req_write_r  <= 1'b1;
                            m1_req_wdata_r  <= amo_next_value(pending_amo_op, m1_resp_data, pending_wdata);
                            m1_req_wen_r    <= 4'b1111;
                        end
                    end else if (m1_txn_is_drain) begin
                        lsu_state       <= LSU_IDLE;
                        m1_txn_is_drain <= 1'b0;
                        m1_txn_is_amo   <= 1'b0;
                    end else if (req_valid && req_accept && is_load && !sb_forward_valid) begin
                        // Complete the old load and launch/capture the next
                        // load in the same cycle.  resp_* below still observes
                        // the old pending metadata for this response.
                        pending_valid         <= 1'b1;
                        // pending_tid removed (single-thread)
                        pending_order_id      <= req_order_id;
                        pending_epoch         <= req_epoch;
                        pending_tag           <= req_tag;
                        pending_rd            <= req_rd;
                        pending_func3         <= req_func3;
                        pending_regs_write    <= req_regs_write;
                        pending_fu            <= req_fu;
                        pending_mem2reg       <= req_mem2reg;
                        pending_wen           <= req_wen;
                        pending_amo           <= 1'b0;
                        pending_amo_op        <= 5'd0;
                        pending_addr          <= req_paddr;
                        pending_wdata         <= req_wdata;
                        pending_forward_valid <= 1'b0;
                        pending_forward_data  <= 32'd0;
                        pending_amo_resp_data <= 32'd0;
                        m1_txn_is_drain       <= 1'b0;
                        m1_txn_is_amo         <= 1'b0;
                        if (m1_req_ready) begin
                            lsu_state      <= LSU_WAIT_RESP;
                            m1_req_valid_r <= 1'b0;
                        end else begin
                            lsu_state      <= LSU_REQ;
                            m1_req_valid_r <= 1'b1;
                            m1_req_addr_r  <= req_paddr;
                            m1_req_write_r <= 1'b0;
                            m1_req_wdata_r <= 32'd0;
                            m1_req_wen_r   <= 4'b0000;
                        end
                    end else begin
                        raw_mem_rdata   <= m1_resp_data;
                        lsu_state       <= LSU_IDLE;
                        pending_valid   <= 1'b0;
                        pending_amo     <= 1'b0;
                        m1_txn_is_drain <= 1'b0;
                        m1_txn_is_amo   <= 1'b0;
                        if (m1_resp_l1d_hit) begin
                            m1_cooldown_r <= 1'b0;
                            debug_lsu_cooldown_skipped_l1hit <= 1'b1;
                        end else begin
                            m1_cooldown_r <= 1'b1;
                            debug_lsu_cooldown_set <= 1'b1;
                        end
                    end
                end else if (lsu_wait_watchdog_r == LSU_WAIT_WATCHDOG_MAX) begin
                    lsu_wait_watchdog_r <= 20'd0;
                    if (m1_txn_is_amo) begin
                        pending_amo_resp_data <= 32'hffff_ffff;
                        m1_txn_is_amo <= 1'b0;
                        lsu_state <= LSU_RESP;
                    end else if (m1_txn_is_drain) begin
                        lsu_state       <= LSU_IDLE;
                        m1_txn_is_drain <= 1'b0;
                        m1_txn_is_amo   <= 1'b0;
                    end else begin
                        raw_mem_rdata   <= 32'd0;
                        lsu_state       <= LSU_RESP;
                        m1_txn_is_drain <= 1'b0;
                        m1_txn_is_amo   <= 1'b0;
                        m1_cooldown_r   <= 1'b0;
                    end
                end else begin
                    lsu_wait_watchdog_r <= lsu_wait_watchdog_r + 20'd1;
                end
            end

            LSU_AMO_WRITE_REQ: begin
                if (m1_req_ready) begin
                    m1_req_valid_r <= 1'b0;
                    lsu_state <= LSU_AMO_WRITE_RESP;
                end
            end

            LSU_AMO_WRITE_RESP: begin
                if (m1_resp_valid) begin
                    m1_txn_is_amo <= 1'b0;
                    lsu_state <= LSU_RESP;
                end else if (lsu_wait_watchdog_r == LSU_WAIT_WATCHDOG_MAX) begin
                    m1_txn_is_amo <= 1'b0;
                    lsu_wait_watchdog_r <= 20'd0;
                    lsu_state <= LSU_RESP;
                end else begin
                    lsu_wait_watchdog_r <= lsu_wait_watchdog_r + 20'd1;
                end
            end

            LSU_RESP: begin
                if (req_valid && !req_accept && is_store && (req_addr == `DEBUG_BEACON_EVT_ADDR) &&
                    !dbg_beacon_block_reported_r) begin
`ifdef VERBOSE_SIM_LOGS
                    $display("[DBG_LSU_BLOCK] t=%0t state=%0d idle=%0b sb_accept=%0b count_t0=%0d count_t1=%0d order=%0d tag=%0d addr=%h",
                             $time, lsu_state, state_machine_idle, sb_store_accept,
                             sb_debug_count_t0, sb_debug_count_t1, req_order_id, req_tag, req_addr);
`endif
                    dbg_beacon_block_reported_r <= 1'b1;
                end
                // Response ready, will be consumed by writeback
                lsu_state       <= LSU_IDLE;
                pending_valid   <= 1'b0;
                pending_amo     <= 1'b0;
                m1_txn_is_drain <= 1'b0;
                m1_txn_is_amo   <= 1'b0;
            end

            default: begin
                lsu_state <= LSU_IDLE;
                m1_txn_is_amo <= 1'b0;
            end
        endcase
        end
    end
end

// Legacy memory interface (for use_mem_subsys=0)
assign mem_addr = legacy_load_issue_fire ? req_paddr : pending_addr;
assign mem_read = legacy_load_issue_fire ? 4'b1111 : 4'b0000;

// =============================================================================
// Load Data Shaping (replicated from stage_wb for single-cycle response)
// =============================================================================

wire [1:0]  addr_in_word = pending_addr[1:0];
// Both legacy and mem_subsys paths capture data into raw_mem_rdata before LSU_RESP.
wire [31:0] raw_mem_data = mem_subsys_load_resp_fire ? m1_resp_data : raw_mem_rdata;

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
        resp_valid        <= 1'b0;
        resp_order_id     <= {ORDER_ID_W{1'b0}};
        resp_epoch        <= {EPOCH_W{1'b0}};
        resp_tag          <= {TAG_W{1'b0}};
        resp_rd           <= 5'd0;
        resp_func3        <= 3'd0;
        resp_regs_write   <= 1'b0;
        resp_fu           <= 3'd0;
        resp_rdata        <= 32'd0;
        resp_exc_valid    <= 1'b0;
        resp_exc_cause    <= 32'd0;
        resp_exc_tval     <= 32'd0;
    end else begin
        resp_exc_valid <= 1'b0;
        resp_exc_cause <= 32'd0;
        resp_exc_tval  <= 32'd0;
        if (fault_accept_resp_fire) begin
            resp_valid        <= 1'b1;
            resp_order_id     <= req_order_id;
            resp_epoch        <= req_epoch;
            resp_tag          <= req_tag;
            resp_rd           <= req_rd;
            resp_func3        <= req_func3;
            resp_regs_write   <= 1'b0;
            resp_fu           <= req_fu;
            resp_rdata        <= 32'd0;
            resp_exc_valid    <= 1'b1;
            resp_exc_cause    <= {27'd0, mmu_dtlb_resp_cause};
            resp_exc_tval     <= mmu_dtlb_resp_tval;
        end else if (store_accept_resp_fire) begin
            resp_valid        <= 1'b1;
            resp_valid        <= 1'b1;
            resp_order_id     <= req_order_id;
            resp_epoch        <= req_epoch;
            resp_tag          <= req_tag;
            resp_rd           <= req_rd;
            resp_func3        <= req_func3;
            resp_regs_write   <= 1'b0;
            resp_fu           <= req_fu;
            resp_rdata        <= 32'd0;
        end else if (((lsu_state == LSU_RESP) || mem_subsys_load_resp_fire) &&
                     !pending_flush_kill) begin
            if (pending_amo) begin
                resp_valid        <= 1'b1;
                resp_order_id     <= pending_order_id;
                resp_epoch        <= pending_epoch;
                resp_tag          <= pending_tag;
                resp_rd           <= pending_rd;
                resp_func3        <= pending_func3;
                resp_regs_write   <= pending_regs_write;
                resp_fu           <= pending_fu;
                resp_rdata        <= pending_amo_resp_data;
            end else if (!pending_wen) begin
                // Load response
                resp_valid        <= 1'b1;
                // resp_tid removed (single-thread)
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
                // resp_tid removed (single-thread)
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
