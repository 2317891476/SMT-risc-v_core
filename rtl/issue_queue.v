`timescale 1ns/1ns
// =============================================================================
// Module : issue_queue
// Description: Parameterized Issue Queue for split-IQ OoO backend.
//   A single queue with N entries, 2 dispatch ports, 1 issue port.
//   Supports CDB wakeup (2 WB + 2 commit ports), epoch-based flush,
//   oldest-first selection, and 1-cycle wake-to-issue hold.
//
//   Instantiate once per FU class: INT(8), MEM(16), MUL(4).
//   For INT: both pipe0 and pipe1 can consume; for MEM/MUL: pipe1 only.
//   DEALLOC_AT_COMMIT=1 keeps entries until commit (needed for MEM ordering).
//   CHECK_LOAD_STORE_ORDER=1 prevents loads from bypassing older stores.
// =============================================================================
`include "define.v"

module issue_queue #(
    parameter IQ_DEPTH     = 8,
    parameter IQ_IDX_W     = 3,       // clog2(IQ_DEPTH)
    parameter RS_TAG_W     = 5,
    parameter NUM_THREAD   = 2,
    parameter WAKE_HOLD    = 1,       // cycles between wakeup and eligible-to-issue
    parameter DEALLOC_AT_COMMIT    = 0, // 0=free at issue, 1=free at commit
    parameter CHECK_LOAD_STORE_ORDER = 0  // 1=loads wait for older stores
)(
    input  wire        clk,
    input  wire        rstn,

    // ─── Flush ───────────────────────────────────────────────────
    input  wire        flush,
    input  wire [0:0]  flush_tid,
    input  wire [`METADATA_EPOCH_W-1:0] flush_new_epoch,
    input  wire        flush_order_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] flush_order_id,

    // ─── Dispatch Port 0 ────────────────────────────────────────
    input  wire        disp0_valid,
    input  wire [RS_TAG_W-1:0]              disp0_tag,
    input  wire [31:0]                      disp0_pc,
    input  wire [31:0]                      disp0_imm,
    input  wire [2:0]                       disp0_func3,
    input  wire                             disp0_func7,
    input  wire [4:0]                       disp0_rd,
    input  wire                             disp0_br,
    input  wire                             disp0_mem_read,
    input  wire                             disp0_mem2reg,
    input  wire [2:0]                       disp0_alu_op,
    input  wire                             disp0_mem_write,
    input  wire [1:0]                       disp0_alu_src1,
    input  wire [1:0]                       disp0_alu_src2,
    input  wire                             disp0_br_addr_mode,
    input  wire                             disp0_regs_write,
    input  wire [4:0]                       disp0_rs1,
    input  wire [4:0]                       disp0_rs2,
    input  wire                             disp0_rs1_used,
    input  wire                             disp0_rs2_used,
    input  wire [2:0]                       disp0_fu,
    input  wire [0:0]                       disp0_tid,
    input  wire                             disp0_is_mret,
    input  wire                             disp0_side_effect,
    input  wire [`METADATA_ORDER_ID_W-1:0]  disp0_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]     disp0_epoch,
    // Source dependencies (from rename / reg_result)
    input  wire [RS_TAG_W-1:0]              disp0_src1_tag,  // 0 = ready
    input  wire [RS_TAG_W-1:0]              disp0_src2_tag,
    input  wire [`METADATA_ORDER_ID_W-1:0]  disp0_src1_order_id,
    input  wire [`METADATA_ORDER_ID_W-1:0]  disp0_src2_order_id,

    // ─── Dispatch Port 1 ────────────────────────────────────────
    input  wire        disp1_valid,
    input  wire [RS_TAG_W-1:0]              disp1_tag,
    input  wire [31:0]                      disp1_pc,
    input  wire [31:0]                      disp1_imm,
    input  wire [2:0]                       disp1_func3,
    input  wire                             disp1_func7,
    input  wire [4:0]                       disp1_rd,
    input  wire                             disp1_br,
    input  wire                             disp1_mem_read,
    input  wire                             disp1_mem2reg,
    input  wire [2:0]                       disp1_alu_op,
    input  wire                             disp1_mem_write,
    input  wire [1:0]                       disp1_alu_src1,
    input  wire [1:0]                       disp1_alu_src2,
    input  wire                             disp1_br_addr_mode,
    input  wire                             disp1_regs_write,
    input  wire [4:0]                       disp1_rs1,
    input  wire [4:0]                       disp1_rs2,
    input  wire                             disp1_rs1_used,
    input  wire                             disp1_rs2_used,
    input  wire [2:0]                       disp1_fu,
    input  wire [0:0]                       disp1_tid,
    input  wire                             disp1_is_mret,
    input  wire                             disp1_side_effect,
    input  wire [`METADATA_ORDER_ID_W-1:0]  disp1_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]     disp1_epoch,
    input  wire [RS_TAG_W-1:0]              disp1_src1_tag,
    input  wire [RS_TAG_W-1:0]              disp1_src2_tag,
    input  wire [`METADATA_ORDER_ID_W-1:0]  disp1_src1_order_id,
    input  wire [`METADATA_ORDER_ID_W-1:0]  disp1_src2_order_id,

    // ─── Stall / Capacity ────────────────────────────────────────
    output wire        iq_full,           // cannot accept even 1
    output wire        iq_almost_full,    // cannot accept 2

    // ─── Issue Port (single oldest-ready winner) ─────────────────
    output reg                              iss_valid,
    output reg  [RS_TAG_W-1:0]             iss_tag,
    output reg  [31:0]                     iss_pc,
    output reg  [31:0]                     iss_imm,
    output reg  [2:0]                      iss_func3,
    output reg                             iss_func7,
    output reg  [4:0]                      iss_rd,
    output reg  [4:0]                      iss_rs1,
    output reg  [4:0]                      iss_rs2,
    output reg                             iss_rs1_used,
    output reg                             iss_rs2_used,
    output reg  [RS_TAG_W-1:0]            iss_src1_tag,
    output reg  [RS_TAG_W-1:0]            iss_src2_tag,
    output reg                             iss_br,
    output reg                             iss_mem_read,
    output reg                             iss_mem2reg,
    output reg  [2:0]                      iss_alu_op,
    output reg                             iss_mem_write,
    output reg  [1:0]                      iss_alu_src1,
    output reg  [1:0]                      iss_alu_src2,
    output reg                             iss_br_addr_mode,
    output reg                             iss_regs_write,
    output reg  [2:0]                      iss_fu,
    output reg  [0:0]                      iss_tid,
    output reg                             iss_is_mret,
    output reg  [`METADATA_ORDER_ID_W-1:0] iss_order_id,
    output reg  [`METADATA_EPOCH_W-1:0]    iss_epoch,

    // ─── Wakeup / CDB ports ─────────────────────────────────────
    input  wire        wb0_valid,
    input  wire [RS_TAG_W-1:0] wb0_tag,
    input  wire [0:0]  wb0_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] wb0_order_id,
    input  wire        wb0_regs_write,
    input  wire        wb1_valid,
    input  wire [RS_TAG_W-1:0] wb1_tag,
    input  wire [0:0]  wb1_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] wb1_order_id,
    input  wire        wb1_regs_write,

    input  wire        early_wakeup_valid,
    input  wire [RS_TAG_W-1:0] early_wakeup_tag,

    // ─── Commit (deallocation) ───────────────────────────────────
    input  wire        commit0_valid,
    input  wire [RS_TAG_W-1:0] commit0_tag,
    input  wire [0:0]  commit0_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id,
    input  wire        commit1_valid,
    input  wire [RS_TAG_W-1:0] commit1_tag,
    input  wire [0:0]  commit1_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] commit1_order_id,
    input  wire                             older_store_valid_t0,
    input  wire [`METADATA_ORDER_ID_W-1:0]  older_store_order_id_t0,
    input  wire                             older_store_valid_t1,
    input  wire [`METADATA_ORDER_ID_W-1:0]  older_store_order_id_t1,

    // ─── External issue inhibit (e.g. branch_in_flight) ─────────
    input  wire        issue_inhibit_t0,
    input  wire        issue_inhibit_t1,
    input  wire                             issue_after_order_block_valid_t0,
    input  wire [`METADATA_ORDER_ID_W-1:0]  issue_after_order_block_id_t0,
    input  wire                             issue_after_order_block_valid_t1,
    input  wire [`METADATA_ORDER_ID_W-1:0]  issue_after_order_block_id_t1,
    input  wire                             issue_side_effect_block_valid_t0,
    input  wire [`METADATA_ORDER_ID_W-1:0]  issue_side_effect_block_id_t0,
    input  wire                             issue_side_effect_block_valid_t1,
    input  wire [`METADATA_ORDER_ID_W-1:0]  issue_side_effect_block_id_t1,
    output wire                            oldest_store_valid_t0,
    output wire [`METADATA_ORDER_ID_W-1:0] oldest_store_order_id_t0,
    output wire                            oldest_store_valid_t1,
    output wire [`METADATA_ORDER_ID_W-1:0] oldest_store_order_id_t1,
    output wire                            debug_order_blocked_any,
    output reg                             debug_flush_killed_any
);

    // ═══ Entry Storage ═══
    reg                              e_valid  [0:IQ_DEPTH-1];
    reg                              e_issued [0:IQ_DEPTH-1];
    reg  [RS_TAG_W-1:0]             e_tag    [0:IQ_DEPTH-1];
    reg  [`METADATA_ORDER_ID_W-1:0] e_seq    [0:IQ_DEPTH-1];
    reg  [0:0]                       e_tid    [0:IQ_DEPTH-1];
    reg  [`METADATA_EPOCH_W-1:0]    e_epoch  [0:IQ_DEPTH-1];
    reg  [RS_TAG_W-1:0]             e_qj     [0:IQ_DEPTH-1]; // src1 dep
    reg  [RS_TAG_W-1:0]             e_qk     [0:IQ_DEPTH-1]; // src2 dep
    reg  [`METADATA_ORDER_ID_W-1:0] e_qj_order [0:IQ_DEPTH-1];
    reg  [`METADATA_ORDER_ID_W-1:0] e_qk_order [0:IQ_DEPTH-1];
    reg                              e_ready  [0:IQ_DEPTH-1];
    reg  [1:0]                       e_wake_hold [0:IQ_DEPTH-1];
    reg                              e_just_woke [0:IQ_DEPTH-1];

    // Payload (latched at dispatch, read at issue)
    reg [31:0]                     e_pc       [0:IQ_DEPTH-1];
    reg [31:0]                     e_imm      [0:IQ_DEPTH-1];
    reg [2:0]                      e_func3    [0:IQ_DEPTH-1];
    reg                            e_func7    [0:IQ_DEPTH-1];
    reg [4:0]                      e_rd       [0:IQ_DEPTH-1];
    reg [4:0]                      e_rs1      [0:IQ_DEPTH-1];
    reg [4:0]                      e_rs2      [0:IQ_DEPTH-1];
    reg                            e_rs1_used [0:IQ_DEPTH-1];
    reg                            e_rs2_used [0:IQ_DEPTH-1];
    reg [RS_TAG_W-1:0]            e_src1_tag [0:IQ_DEPTH-1];
    reg [RS_TAG_W-1:0]            e_src2_tag [0:IQ_DEPTH-1];
    reg                            e_br       [0:IQ_DEPTH-1];
    reg                            e_mem_read [0:IQ_DEPTH-1];
    reg                            e_mem2reg  [0:IQ_DEPTH-1];
    reg [2:0]                      e_alu_op   [0:IQ_DEPTH-1];
    reg                            e_mem_write[0:IQ_DEPTH-1];
    reg [1:0]                      e_alu_src1 [0:IQ_DEPTH-1];
    reg [1:0]                      e_alu_src2 [0:IQ_DEPTH-1];
    reg                            e_br_addr_mode [0:IQ_DEPTH-1];
    reg                            e_regs_write [0:IQ_DEPTH-1];
    reg [2:0]                      e_fu       [0:IQ_DEPTH-1];
    reg                            e_is_mret  [0:IQ_DEPTH-1];
    reg                            e_side_effect [0:IQ_DEPTH-1];
    reg [`METADATA_ORDER_ID_W-1:0] e_order_id [0:IQ_DEPTH-1];

    localparam STORE_PTR_W = (IQ_DEPTH <= 1) ? 1 : $clog2(IQ_DEPTH);
    localparam STORE_COUNT_W = STORE_PTR_W + 1;

    reg [IQ_IDX_W-1:0]             store_slot_t0_r  [0:IQ_DEPTH-1];
    reg [`METADATA_ORDER_ID_W-1:0] store_order_t0_r [0:IQ_DEPTH-1];
    reg [IQ_IDX_W-1:0]             store_slot_t1_r  [0:IQ_DEPTH-1];
    reg [`METADATA_ORDER_ID_W-1:0] store_order_t1_r [0:IQ_DEPTH-1];

    reg [IQ_IDX_W-1:0]             store_slot_t0_n  [0:IQ_DEPTH-1];
    reg [`METADATA_ORDER_ID_W-1:0] store_order_t0_n [0:IQ_DEPTH-1];
    reg [IQ_IDX_W-1:0]             store_slot_t1_n  [0:IQ_DEPTH-1];
    reg [`METADATA_ORDER_ID_W-1:0] store_order_t1_n [0:IQ_DEPTH-1];

    reg [STORE_PTR_W-1:0]          store_head_ptr_t0_r;
    reg [STORE_PTR_W-1:0]          store_tail_ptr_t0_r;
    reg [STORE_COUNT_W-1:0]        store_count_t0_r;
    reg [`METADATA_ORDER_ID_W-1:0] store_head_order_id_t0_r;
    reg [STORE_PTR_W-1:0]          store_head_ptr_t1_r;
    reg [STORE_PTR_W-1:0]          store_tail_ptr_t1_r;
    reg [STORE_COUNT_W-1:0]        store_count_t1_r;
    reg [`METADATA_ORDER_ID_W-1:0] store_head_order_id_t1_r;

    reg [STORE_PTR_W-1:0]          store_head_ptr_t0_n;
    reg [STORE_PTR_W-1:0]          store_tail_ptr_t0_n;
    reg [STORE_COUNT_W-1:0]        store_count_t0_n;
    reg [`METADATA_ORDER_ID_W-1:0] store_head_order_id_t0_n;
    reg [STORE_PTR_W-1:0]          store_head_ptr_t1_n;
    reg [STORE_PTR_W-1:0]          store_tail_ptr_t1_n;
    reg [STORE_COUNT_W-1:0]        store_count_t1_n;
    reg [`METADATA_ORDER_ID_W-1:0] store_head_order_id_t1_n;

    // Sequence counter (for age ordering)
    reg [`METADATA_ORDER_ID_W-1:0] alloc_seq;

    // ═══ Free Slot Finding (combinational) ═══
    reg                   free0_found, free1_found;
    reg [IQ_IDX_W-1:0]   free0_idx,   free1_idx;
    integer fi;

    always @(*) begin
        free0_found = 1'b0;
        free1_found = 1'b0;
        free0_idx   = {IQ_IDX_W{1'b0}};
        free1_idx   = {IQ_IDX_W{1'b0}};
        for (fi = 0; fi < IQ_DEPTH; fi = fi + 1) begin
            if (!e_valid[fi] && !free0_found) begin
                free0_found = 1'b1;
                free0_idx   = fi[IQ_IDX_W-1:0];
            end
            else if (!e_valid[fi] && free0_found && !free1_found) begin
                free1_found = 1'b1;
                free1_idx   = fi[IQ_IDX_W-1:0];
            end
        end
    end

    wire can_accept_1 = free0_found;
    wire can_accept_2 = free0_found && free1_found;

    assign iq_full        = !can_accept_1;
    assign iq_almost_full = !can_accept_2;

    // ═══ Issue Selection: Oldest Ready (combinational) ═══
    // With load-store ordering: a load cannot issue while an older
    // store from the same thread is still pending (valid & not issued).

    // --- Pre-compute oldest pending store sequence per thread ---
    // Tree-based min reduction: O(log2 N) depth instead of O(N) cascading.

    // Shared tree parameters (used by both store min-tree and issue selection tree)
    localparam TREE_N = 1 << $clog2(IQ_DEPTH);
    localparam TREE_LEVELS = $clog2(TREE_N);

    function [STORE_PTR_W-1:0] store_ptr_inc;
        input [STORE_PTR_W-1:0] ptr;
        begin
            if (ptr == IQ_DEPTH-1)
                store_ptr_inc = {STORE_PTR_W{1'b0}};
            else
                store_ptr_inc = ptr + {{(STORE_PTR_W-1){1'b0}}, 1'b1};
        end
    endfunction

    function [STORE_PTR_W-1:0] store_ptr_dec;
        input [STORE_PTR_W-1:0] ptr;
        begin
            if (ptr == {STORE_PTR_W{1'b0}})
                store_ptr_dec = IQ_DEPTH-1;
            else
                store_ptr_dec = ptr - {{(STORE_PTR_W-1){1'b0}}, 1'b1};
        end
    endfunction

    wire                            any_store_t0        = (store_count_t0_r != {STORE_COUNT_W{1'b0}});
    wire [`METADATA_ORDER_ID_W-1:0] oldest_store_ord_t0 = store_head_order_id_t0_r;
    wire                            any_store_t1        = (store_count_t1_r != {STORE_COUNT_W{1'b0}});
    wire [`METADATA_ORDER_ID_W-1:0] oldest_store_ord_t1 = store_head_order_id_t1_r;

    assign oldest_store_valid_t0    = any_store_t0;
    assign oldest_store_order_id_t0 = store_head_order_id_t0_r;
    assign oldest_store_valid_t1    = any_store_t1;
    assign oldest_store_order_id_t1 = store_head_order_id_t1_r;

    // --- Binary Tournament Tree: O(log2 N) selection ---
    // Candidate word: {valid(1), seq(ORDER_ID_W), idx(IQ_IDX_W)}
    localparam CAND_W = 1 + `METADATA_ORDER_ID_W + IQ_IDX_W;
    localparam ISSUE_BUNDLE_W = (RS_TAG_W * 3) + 32 + 32 + 3 + 1 +
                                5 + 5 + 5 + 1 + 1 +
                                1 + 1 + 1 + 3 + 1 + 2 + 2 + 1 + 1 +
                                3 + 1 + 1 +
                                `METADATA_ORDER_ID_W + `METADATA_EPOCH_W;

    // pick_older: return the older (lower seq) valid candidate
    function [CAND_W-1:0] pick_older;
        input [CAND_W-1:0] a;
        input [CAND_W-1:0] b;
        reg a_v, b_v;
        reg [`METADATA_ORDER_ID_W-1:0] a_seq, b_seq;
        begin
            a_v   = a[CAND_W-1];
            b_v   = b[CAND_W-1];
            a_seq = a[CAND_W-2 -: `METADATA_ORDER_ID_W];
            b_seq = b[CAND_W-2 -: `METADATA_ORDER_ID_W];
            if (!a_v && !b_v)     pick_older = a;       // both invalid
            else if (!a_v)        pick_older = b;
            else if (!b_v)        pick_older = a;
            else if (a_seq <= b_seq) pick_older = a;    // a is older or equal
            else                  pick_older = b;
        end
    endfunction

    // Step 1: Per-entry parallel eligibility + candidate packing
    wire [CAND_W-1:0] cand [0:TREE_N-1];
    wire [TREE_N-1:0] order_blocked_vec;
    reg  [ISSUE_BUNDLE_W-1:0] sel_bundle;

    genvar ci;
    generate
        for (ci = 0; ci < TREE_N; ci = ci + 1) begin : gen_cand
            if (ci < IQ_DEPTH) begin : real_entry
                wire inhibited = (e_tid[ci] == 1'b0 && issue_inhibit_t0) ||
                                 (e_tid[ci] == 1'b1 && issue_inhibit_t1);
                wire order_blocked = (e_tid[ci] == 1'b0) ?
                    (issue_after_order_block_valid_t0 &&
                     (e_order_id[ci] > issue_after_order_block_id_t0)) :
                    (issue_after_order_block_valid_t1 &&
                     (e_order_id[ci] > issue_after_order_block_id_t1));
                wire side_effect_blocked = e_side_effect[ci] &&
                    ((e_tid[ci] == 1'b0) ?
                     (issue_side_effect_block_valid_t0 &&
                      (e_order_id[ci] > issue_side_effect_block_id_t0)) :
                     (issue_side_effect_block_valid_t1 &&
                      (e_order_id[ci] > issue_side_effect_block_id_t1)));
                wire is_load_no_store = CHECK_LOAD_STORE_ORDER &&
                                        e_mem_read[ci] && !e_mem_write[ci];
                wire is_store_ordered = CHECK_LOAD_STORE_ORDER &&
                                        e_mem_write[ci];
                wire older_store_blocks =
                    is_load_no_store && (
                        (e_tid[ci] == 1'b0) ? (any_store_t0 && (oldest_store_ord_t0 < e_order_id[ci])) :
                                              (any_store_t1 && (oldest_store_ord_t1 < e_order_id[ci]))
                    );
                wire older_store_blocks_store =
                    is_store_ordered && (
                        (e_tid[ci] == 1'b0) ? (any_store_t0 && (oldest_store_ord_t0 < e_order_id[ci])) :
                                              (any_store_t1 && (oldest_store_ord_t1 < e_order_id[ci]))
                    );
                wire older_store_blocks_mret =
                    e_is_mret[ci] && (
                        (e_tid[ci] == 1'b0) ? (older_store_valid_t0 && (older_store_order_id_t0 < e_order_id[ci])) :
                                              (older_store_valid_t1 && (older_store_order_id_t1 < e_order_id[ci]))
                    );
                wire eligible = e_valid[ci] && !e_issued[ci] && e_ready[ci]
                                && !e_just_woke[ci] && !inhibited
                                && !order_blocked
                                && !side_effect_blocked
                                && !older_store_blocks
                                && !older_store_blocks_store
                                && !older_store_blocks_mret;
                assign order_blocked_vec[ci] = e_valid[ci] && !e_issued[ci] &&
                                               e_ready[ci] && !e_just_woke[ci] &&
                                               (order_blocked || side_effect_blocked);
                assign cand[ci] = {eligible, e_seq[ci], ci[IQ_IDX_W-1:0]};
            end else begin : pad_entry
                assign cand[ci] = {1'b0, {`METADATA_ORDER_ID_W{1'b1}}, {IQ_IDX_W{1'b0}}};
                assign order_blocked_vec[ci] = 1'b0;
            end
        end
    endgenerate

    assign debug_order_blocked_any = |order_blocked_vec;

    // Step 2: Binary tournament tree reduction (log2 levels)
    wire [CAND_W-1:0] tree [0:2*TREE_N-2];  // flat array: leaves=[TREE_N-1 .. 2*TREE_N-2], root=[0]

    genvar ti;
    generate
        // Leaves: copy candidates
        for (ti = 0; ti < TREE_N; ti = ti + 1) begin : gen_leaf
            assign tree[TREE_N - 1 + ti] = cand[ti];
        end
        // Internal nodes: pick_older of children
        for (ti = TREE_N - 2; ti >= 0; ti = ti - 1) begin : gen_node
            assign tree[ti] = pick_older(tree[2*ti + 1], tree[2*ti + 2]);
        end
    endgenerate

    // Step 3: Extract winner
    wire                            sel_found = tree[0][CAND_W-1];
    wire [IQ_IDX_W-1:0]            sel_idx   = tree[0][IQ_IDX_W-1:0];
    // winner-level bundle is formed locally to keep the issue boundary simple

    // ═══ Issue Output Drive ═══
    always @(*) begin
        iss_valid = sel_found;
        sel_bundle = {ISSUE_BUNDLE_W{1'b0}};
        if (sel_found) begin
            sel_bundle = {
                e_tag[sel_idx], e_pc[sel_idx], e_imm[sel_idx], e_func3[sel_idx], e_func7[sel_idx],
                e_rd[sel_idx], e_rs1[sel_idx], e_rs2[sel_idx], e_rs1_used[sel_idx], e_rs2_used[sel_idx],
                e_src1_tag[sel_idx], e_src2_tag[sel_idx], e_br[sel_idx], e_mem_read[sel_idx], e_mem2reg[sel_idx],
                e_alu_op[sel_idx], e_mem_write[sel_idx], e_alu_src1[sel_idx], e_alu_src2[sel_idx],
                e_br_addr_mode[sel_idx], e_regs_write[sel_idx], e_fu[sel_idx], e_tid[sel_idx],
                e_is_mret[sel_idx], e_order_id[sel_idx], e_epoch[sel_idx]
            };
        end
        {
            iss_tag,
            iss_pc,
            iss_imm,
            iss_func3,
            iss_func7,
            iss_rd,
            iss_rs1,
            iss_rs2,
            iss_rs1_used,
            iss_rs2_used,
            iss_src1_tag,
            iss_src2_tag,
            iss_br,
            iss_mem_read,
            iss_mem2reg,
            iss_alu_op,
            iss_mem_write,
            iss_alu_src1,
            iss_alu_src2,
            iss_br_addr_mode,
            iss_regs_write,
            iss_fu,
            iss_tid,
            iss_is_mret,
            iss_order_id,
            iss_epoch
        } = sel_found ? sel_bundle : {ISSUE_BUNDLE_W{1'b0}};
    end

    // ═══ Sequential Logic ═══
    integer i;
    reg [RS_TAG_W-1:0] nqj, nqk;
    reg [`METADATA_ORDER_ID_W-1:0] nqj_order, nqk_order;
    reg woke_src;
    reg [1:0] next_wake_hold;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (i = 0; i < IQ_DEPTH; i = i + 1) begin
                e_valid[i]     <= 1'b0;
                e_issued[i]    <= 1'b0;
                e_ready[i]     <= 1'b0;
                e_qj[i]        <= {RS_TAG_W{1'b0}};
                e_qk[i]        <= {RS_TAG_W{1'b0}};
                e_qj_order[i]  <= {`METADATA_ORDER_ID_W{1'b0}};
                e_qk_order[i]  <= {`METADATA_ORDER_ID_W{1'b0}};
                e_just_woke[i] <= 1'b0;
                e_wake_hold[i] <= 2'd0;
                e_side_effect[i] <= 1'b0;
            end
            alloc_seq <= {`METADATA_ORDER_ID_W{1'b0}};
            debug_flush_killed_any <= 1'b0;
        end
        else begin
            debug_flush_killed_any <= 1'b0;
            // ── Epoch-based flush ──
            if (flush) begin
                for (i = 0; i < IQ_DEPTH; i = i + 1) begin
                    if (e_valid[i] && (e_tid[i] == flush_tid)) begin
                        if (!flush_order_valid) begin
                            e_valid[i] <= 1'b0;
                            debug_flush_killed_any <= 1'b1;
                        end else if (e_order_id[i] > flush_order_id) begin
                            e_valid[i] <= 1'b0;
                            debug_flush_killed_any <= 1'b1;
                        end
                    end
                end
            end

            // ── Issue: mark issued ──
            if (sel_found) begin
                e_issued[sel_idx] <= 1'b1;
                if (!DEALLOC_AT_COMMIT)
                    e_valid[sel_idx] <= 1'b0;  // free at issue
            end

            // ── Wakeup ──
            for (i = 0; i < IQ_DEPTH; i = i + 1) begin
                if (e_valid[i] && !e_issued[i]) begin
                    nqj = e_qj[i];
                    nqk = e_qk[i];
                    nqj_order = e_qj_order[i];
                    nqk_order = e_qk_order[i];
                    woke_src = 1'b0;

                    // WB port 0
                    if (wb0_valid && wb0_regs_write && (wb0_tag != {RS_TAG_W{1'b0}})) begin
                        if ((nqj == wb0_tag) && (e_tid[i] == wb0_tid) && (nqj_order == wb0_order_id)) begin
                            nqj = {RS_TAG_W{1'b0}};
                            nqj_order = {`METADATA_ORDER_ID_W{1'b0}};
                            woke_src = 1'b1;
                        end
                        if ((nqk == wb0_tag) && (e_tid[i] == wb0_tid) && (nqk_order == wb0_order_id)) begin
                            nqk = {RS_TAG_W{1'b0}};
                            nqk_order = {`METADATA_ORDER_ID_W{1'b0}};
                            woke_src = 1'b1;
                        end
                    end
                    // WB port 1
                    if (wb1_valid && wb1_regs_write && (wb1_tag != {RS_TAG_W{1'b0}})) begin
                        if ((nqj == wb1_tag) && (e_tid[i] == wb1_tid) && (nqj_order == wb1_order_id)) begin
                            nqj = {RS_TAG_W{1'b0}};
                            nqj_order = {`METADATA_ORDER_ID_W{1'b0}};
                            woke_src = 1'b1;
                        end
                        if ((nqk == wb1_tag) && (e_tid[i] == wb1_tid) && (nqk_order == wb1_order_id)) begin
                            nqk = {RS_TAG_W{1'b0}};
                            nqk_order = {`METADATA_ORDER_ID_W{1'b0}};
                            woke_src = 1'b1;
                        end
                    end

                    // Early wakeup (LSU load response)
                    if (early_wakeup_valid && (early_wakeup_tag != {RS_TAG_W{1'b0}})) begin
                        if (nqj == early_wakeup_tag) begin
                            nqj = {RS_TAG_W{1'b0}};
                            nqj_order = {`METADATA_ORDER_ID_W{1'b0}};
                            woke_src = 1'b1;
                        end
                        if (nqk == early_wakeup_tag) begin
                            nqk = {RS_TAG_W{1'b0}};
                            nqk_order = {`METADATA_ORDER_ID_W{1'b0}};
                            woke_src = 1'b1;
                        end
                    end

                    e_qj[i]    <= nqj;
                    e_qk[i]    <= nqk;
                    e_qj_order[i] <= nqj_order;
                    e_qk_order[i] <= nqk_order;
                    e_ready[i] <= (nqj == {RS_TAG_W{1'b0}}) && (nqk == {RS_TAG_W{1'b0}});

                    // Clear src tags when dependency resolves — prevents stale
                    // tagbuf lookups after the producing tag is recycled.
                    if (nqj == {RS_TAG_W{1'b0}}) begin
                        e_src1_tag[i] <= {RS_TAG_W{1'b0}};
                        e_qj_order[i] <= {`METADATA_ORDER_ID_W{1'b0}};
                    end
                    if (nqk == {RS_TAG_W{1'b0}}) begin
                        e_src2_tag[i] <= {RS_TAG_W{1'b0}};
                        e_qk_order[i] <= {`METADATA_ORDER_ID_W{1'b0}};
                    end

                    // Wake hold counter
                    next_wake_hold = e_wake_hold[i];
                    if (woke_src)
                        next_wake_hold = WAKE_HOLD[1:0];
                    else if (next_wake_hold != 2'd0)
                        next_wake_hold = next_wake_hold - 2'd1;
                    e_wake_hold[i] <= next_wake_hold;
                    e_just_woke[i] <= (next_wake_hold != 2'd0);
                end
            end

            // ── Commit-based deallocation (only when DEALLOC_AT_COMMIT=1) ──
            if (DEALLOC_AT_COMMIT) begin
                if (commit0_valid) begin
                    for (i = 0; i < IQ_DEPTH; i = i + 1)
                        if (e_valid[i] && e_tag[i] == commit0_tag && e_tid[i] == commit0_tid &&
                            e_order_id[i] == commit0_order_id)
                            e_valid[i] <= 1'b0;
                end
                if (commit1_valid) begin
                    for (i = 0; i < IQ_DEPTH; i = i + 1)
                        if (e_valid[i] && e_tag[i] == commit1_tag && e_tid[i] == commit1_tid &&
                            e_order_id[i] == commit1_order_id)
                            e_valid[i] <= 1'b0;
                end
            end

            // ── Dispatch 0 ──
            if (disp0_valid && free0_found) begin
                e_valid[free0_idx]     <= 1'b1;
                e_issued[free0_idx]    <= 1'b0;
                e_tag[free0_idx]       <= disp0_tag;
                e_tid[free0_idx]       <= disp0_tid;
                e_epoch[free0_idx]     <= disp0_epoch;
                e_order_id[free0_idx]  <= disp0_order_id;
                e_seq[free0_idx]       <= alloc_seq;
                e_qj[free0_idx]        <= disp0_rs1_used ? disp0_src1_tag : {RS_TAG_W{1'b0}};
                e_qk[free0_idx]        <= disp0_rs2_used ? disp0_src2_tag : {RS_TAG_W{1'b0}};
                e_qj_order[free0_idx]  <= (disp0_rs1_used && (disp0_src1_tag != {RS_TAG_W{1'b0}})) ? disp0_src1_order_id :
                                          {`METADATA_ORDER_ID_W{1'b0}};
                e_qk_order[free0_idx]  <= (disp0_rs2_used && (disp0_src2_tag != {RS_TAG_W{1'b0}})) ? disp0_src2_order_id :
                                          {`METADATA_ORDER_ID_W{1'b0}};
                e_ready[free0_idx]     <= (!disp0_rs1_used || disp0_src1_tag == {RS_TAG_W{1'b0}}) &&
                                          (!disp0_rs2_used || disp0_src2_tag == {RS_TAG_W{1'b0}});
                e_just_woke[free0_idx] <= 1'b0;
                e_wake_hold[free0_idx] <= 2'd0;
                // Payload
                e_pc[free0_idx]       <= disp0_pc;
                e_imm[free0_idx]      <= disp0_imm;
                e_func3[free0_idx]    <= disp0_func3;
                e_func7[free0_idx]    <= disp0_func7;
                e_rd[free0_idx]       <= disp0_rd;
                e_rs1[free0_idx]      <= disp0_rs1;
                e_rs2[free0_idx]      <= disp0_rs2;
                e_rs1_used[free0_idx] <= disp0_rs1_used;
                e_rs2_used[free0_idx] <= disp0_rs2_used;
                e_src1_tag[free0_idx] <= disp0_rs1_used ? disp0_src1_tag : {RS_TAG_W{1'b0}};
                e_src2_tag[free0_idx] <= disp0_rs2_used ? disp0_src2_tag : {RS_TAG_W{1'b0}};
                e_br[free0_idx]       <= disp0_br;
                e_mem_read[free0_idx] <= disp0_mem_read;
                e_mem2reg[free0_idx]  <= disp0_mem2reg;
                e_alu_op[free0_idx]   <= disp0_alu_op;
                e_mem_write[free0_idx]<= disp0_mem_write;
                e_alu_src1[free0_idx] <= disp0_alu_src1;
                e_alu_src2[free0_idx] <= disp0_alu_src2;
                e_br_addr_mode[free0_idx] <= disp0_br_addr_mode;
                e_regs_write[free0_idx]   <= disp0_regs_write;
                e_fu[free0_idx]       <= disp0_fu;
                e_is_mret[free0_idx]  <= disp0_is_mret;
                e_side_effect[free0_idx] <= disp0_side_effect;
            end

            // ── Dispatch 1 ──
            if (disp1_valid && free1_found) begin
                e_valid[free1_idx]     <= 1'b1;
                e_issued[free1_idx]    <= 1'b0;
                e_tag[free1_idx]       <= disp1_tag;
                e_tid[free1_idx]       <= disp1_tid;
                e_epoch[free1_idx]     <= disp1_epoch;
                e_order_id[free1_idx]  <= disp1_order_id;
                e_seq[free1_idx]       <= alloc_seq + (disp0_valid ? 16'd1 : 16'd0);
                e_qj[free1_idx]        <= disp1_rs1_used ? disp1_src1_tag : {RS_TAG_W{1'b0}};
                e_qk[free1_idx]        <= disp1_rs2_used ? disp1_src2_tag : {RS_TAG_W{1'b0}};
                e_qj_order[free1_idx]  <= (disp1_rs1_used && (disp1_src1_tag != {RS_TAG_W{1'b0}})) ? disp1_src1_order_id :
                                          {`METADATA_ORDER_ID_W{1'b0}};
                e_qk_order[free1_idx]  <= (disp1_rs2_used && (disp1_src2_tag != {RS_TAG_W{1'b0}})) ? disp1_src2_order_id :
                                          {`METADATA_ORDER_ID_W{1'b0}};
                e_ready[free1_idx]     <= (!disp1_rs1_used || disp1_src1_tag == {RS_TAG_W{1'b0}}) &&
                                          (!disp1_rs2_used || disp1_src2_tag == {RS_TAG_W{1'b0}});
                e_just_woke[free1_idx] <= 1'b0;
                e_wake_hold[free1_idx] <= 2'd0;
                // Payload
                e_pc[free1_idx]       <= disp1_pc;
                e_imm[free1_idx]      <= disp1_imm;
                e_func3[free1_idx]    <= disp1_func3;
                e_func7[free1_idx]    <= disp1_func7;
                e_rd[free1_idx]       <= disp1_rd;
                e_rs1[free1_idx]      <= disp1_rs1;
                e_rs2[free1_idx]      <= disp1_rs2;
                e_rs1_used[free1_idx] <= disp1_rs1_used;
                e_rs2_used[free1_idx] <= disp1_rs2_used;
                e_src1_tag[free1_idx] <= disp1_rs1_used ? disp1_src1_tag : {RS_TAG_W{1'b0}};
                e_src2_tag[free1_idx] <= disp1_rs2_used ? disp1_src2_tag : {RS_TAG_W{1'b0}};
                e_br[free1_idx]       <= disp1_br;
                e_mem_read[free1_idx] <= disp1_mem_read;
                e_mem2reg[free1_idx]  <= disp1_mem2reg;
                e_alu_op[free1_idx]   <= disp1_alu_op;
                e_mem_write[free1_idx]<= disp1_mem_write;
                e_alu_src1[free1_idx] <= disp1_alu_src1;
                e_alu_src2[free1_idx] <= disp1_alu_src2;
                e_br_addr_mode[free1_idx] <= disp1_br_addr_mode;
                e_regs_write[free1_idx]   <= disp1_regs_write;
                e_fu[free1_idx]       <= disp1_fu;
                e_is_mret[free1_idx]  <= disp1_is_mret;
                e_side_effect[free1_idx] <= disp1_side_effect;
            end

            // ── Update alloc_seq ──
            if (disp0_valid && disp1_valid)
                alloc_seq <= alloc_seq + 16'd2;
            else if (disp0_valid || disp1_valid)
                alloc_seq <= alloc_seq + 16'd1;
        end
    end

    integer lsi;
    reg [IQ_IDX_W-1:0] head_slot_idx;
    reg [STORE_PTR_W-1:0] queue_write_ptr;

    always @(*) begin
        for (lsi = 0; lsi < IQ_DEPTH; lsi = lsi + 1) begin
            store_slot_t0_n[lsi]  = store_slot_t0_r[lsi];
            store_order_t0_n[lsi] = store_order_t0_r[lsi];
            store_slot_t1_n[lsi]  = store_slot_t1_r[lsi];
            store_order_t1_n[lsi] = store_order_t1_r[lsi];
        end

        store_head_ptr_t0_n      = store_head_ptr_t0_r;
        store_tail_ptr_t0_n      = store_tail_ptr_t0_r;
        store_count_t0_n         = store_count_t0_r;
        store_head_order_id_t0_n = store_head_order_id_t0_r;
        store_head_ptr_t1_n      = store_head_ptr_t1_r;
        store_tail_ptr_t1_n      = store_tail_ptr_t1_r;
        store_count_t1_n         = store_count_t1_r;
        store_head_order_id_t1_n = store_head_order_id_t1_r;

        if (flush && !flush_order_valid) begin
            if (flush_tid == 1'b0) begin
                store_head_ptr_t0_n      = {STORE_PTR_W{1'b0}};
                store_tail_ptr_t0_n      = {STORE_PTR_W{1'b0}};
                store_count_t0_n         = {STORE_COUNT_W{1'b0}};
                store_head_order_id_t0_n = {`METADATA_ORDER_ID_W{1'b0}};
            end else begin
                store_head_ptr_t1_n      = {STORE_PTR_W{1'b0}};
                store_tail_ptr_t1_n      = {STORE_PTR_W{1'b0}};
                store_count_t1_n         = {STORE_COUNT_W{1'b0}};
                store_head_order_id_t1_n = {`METADATA_ORDER_ID_W{1'b0}};
            end
        end

        if (store_count_t0_n != {STORE_COUNT_W{1'b0}}) begin
            head_slot_idx = store_slot_t0_n[store_head_ptr_t0_n];
            if ((!e_valid[head_slot_idx]) || !e_mem_write[head_slot_idx] ||
                (e_order_id[head_slot_idx] != store_head_order_id_t0_n) ||
                (flush && flush_order_valid && (flush_tid == 1'b0) &&
                 (store_head_order_id_t0_n > flush_order_id))) begin
                if (store_count_t0_n == {{(STORE_COUNT_W-1){1'b0}}, 1'b1}) begin
                    store_head_ptr_t0_n      = {STORE_PTR_W{1'b0}};
                    store_tail_ptr_t0_n      = {STORE_PTR_W{1'b0}};
                    store_count_t0_n         = {STORE_COUNT_W{1'b0}};
                    store_head_order_id_t0_n = {`METADATA_ORDER_ID_W{1'b0}};
                end else begin
                    store_head_ptr_t0_n = store_ptr_inc(store_head_ptr_t0_n);
                    store_count_t0_n    = store_count_t0_n - {{(STORE_COUNT_W-1){1'b0}}, 1'b1};
                end
            end
        end

        if (store_count_t1_n != {STORE_COUNT_W{1'b0}}) begin
            head_slot_idx = store_slot_t1_n[store_head_ptr_t1_n];
            if ((!e_valid[head_slot_idx]) || !e_mem_write[head_slot_idx] ||
                (e_order_id[head_slot_idx] != store_head_order_id_t1_n) ||
                (flush && flush_order_valid && (flush_tid == 1'b1) &&
                 (store_head_order_id_t1_n > flush_order_id))) begin
                if (store_count_t1_n == {{(STORE_COUNT_W-1){1'b0}}, 1'b1}) begin
                    store_head_ptr_t1_n      = {STORE_PTR_W{1'b0}};
                    store_tail_ptr_t1_n      = {STORE_PTR_W{1'b0}};
                    store_count_t1_n         = {STORE_COUNT_W{1'b0}};
                    store_head_order_id_t1_n = {`METADATA_ORDER_ID_W{1'b0}};
                end else begin
                    store_head_ptr_t1_n = store_ptr_inc(store_head_ptr_t1_n);
                    store_count_t1_n    = store_count_t1_n - {{(STORE_COUNT_W-1){1'b0}}, 1'b1};
                end
            end
        end

        if (commit0_valid && (commit0_tid == 1'b0) && (store_count_t0_n != {STORE_COUNT_W{1'b0}})) begin
            head_slot_idx = store_slot_t0_n[store_head_ptr_t0_n];
            if (e_valid[head_slot_idx] && e_mem_write[head_slot_idx] &&
                (e_tag[head_slot_idx] == commit0_tag) &&
                (e_order_id[head_slot_idx] == commit0_order_id)) begin
                if (store_count_t0_n == {{(STORE_COUNT_W-1){1'b0}}, 1'b1}) begin
                    store_head_ptr_t0_n      = {STORE_PTR_W{1'b0}};
                    store_tail_ptr_t0_n      = {STORE_PTR_W{1'b0}};
                    store_count_t0_n         = {STORE_COUNT_W{1'b0}};
                    store_head_order_id_t0_n = {`METADATA_ORDER_ID_W{1'b0}};
                end else begin
                    store_head_ptr_t0_n = store_ptr_inc(store_head_ptr_t0_n);
                    store_count_t0_n    = store_count_t0_n - {{(STORE_COUNT_W-1){1'b0}}, 1'b1};
                end
            end
        end
        if (commit1_valid && (commit1_tid == 1'b0) && (store_count_t0_n != {STORE_COUNT_W{1'b0}})) begin
            head_slot_idx = store_slot_t0_n[store_head_ptr_t0_n];
            if (e_valid[head_slot_idx] && e_mem_write[head_slot_idx] &&
                (e_tag[head_slot_idx] == commit1_tag) &&
                (e_order_id[head_slot_idx] == commit1_order_id)) begin
                if (store_count_t0_n == {{(STORE_COUNT_W-1){1'b0}}, 1'b1}) begin
                    store_head_ptr_t0_n      = {STORE_PTR_W{1'b0}};
                    store_tail_ptr_t0_n      = {STORE_PTR_W{1'b0}};
                    store_count_t0_n         = {STORE_COUNT_W{1'b0}};
                    store_head_order_id_t0_n = {`METADATA_ORDER_ID_W{1'b0}};
                end else begin
                    store_head_ptr_t0_n = store_ptr_inc(store_head_ptr_t0_n);
                    store_count_t0_n    = store_count_t0_n - {{(STORE_COUNT_W-1){1'b0}}, 1'b1};
                end
            end
        end

        if (commit0_valid && (commit0_tid == 1'b1) && (store_count_t1_n != {STORE_COUNT_W{1'b0}})) begin
            head_slot_idx = store_slot_t1_n[store_head_ptr_t1_n];
            if (e_valid[head_slot_idx] && e_mem_write[head_slot_idx] &&
                (e_tag[head_slot_idx] == commit0_tag) &&
                (e_order_id[head_slot_idx] == commit0_order_id)) begin
                if (store_count_t1_n == {{(STORE_COUNT_W-1){1'b0}}, 1'b1}) begin
                    store_head_ptr_t1_n      = {STORE_PTR_W{1'b0}};
                    store_tail_ptr_t1_n      = {STORE_PTR_W{1'b0}};
                    store_count_t1_n         = {STORE_COUNT_W{1'b0}};
                    store_head_order_id_t1_n = {`METADATA_ORDER_ID_W{1'b0}};
                end else begin
                    store_head_ptr_t1_n = store_ptr_inc(store_head_ptr_t1_n);
                    store_count_t1_n    = store_count_t1_n - {{(STORE_COUNT_W-1){1'b0}}, 1'b1};
                end
            end
        end
        if (commit1_valid && (commit1_tid == 1'b1) && (store_count_t1_n != {STORE_COUNT_W{1'b0}})) begin
            head_slot_idx = store_slot_t1_n[store_head_ptr_t1_n];
            if (e_valid[head_slot_idx] && e_mem_write[head_slot_idx] &&
                (e_tag[head_slot_idx] == commit1_tag) &&
                (e_order_id[head_slot_idx] == commit1_order_id)) begin
                if (store_count_t1_n == {{(STORE_COUNT_W-1){1'b0}}, 1'b1}) begin
                    store_head_ptr_t1_n      = {STORE_PTR_W{1'b0}};
                    store_tail_ptr_t1_n      = {STORE_PTR_W{1'b0}};
                    store_count_t1_n         = {STORE_COUNT_W{1'b0}};
                    store_head_order_id_t1_n = {`METADATA_ORDER_ID_W{1'b0}};
                end else begin
                    store_head_ptr_t1_n = store_ptr_inc(store_head_ptr_t1_n);
                    store_count_t1_n    = store_count_t1_n - {{(STORE_COUNT_W-1){1'b0}}, 1'b1};
                end
            end
        end

        if (disp0_valid && free0_found && disp0_mem_write) begin
            if (disp0_tid == 1'b0) begin
                queue_write_ptr = (store_count_t0_n == {STORE_COUNT_W{1'b0}}) ? {STORE_PTR_W{1'b0}}
                                                                               : store_ptr_inc(store_tail_ptr_t0_n);
                store_slot_t0_n[queue_write_ptr]  = free0_idx;
                store_order_t0_n[queue_write_ptr] = disp0_order_id;
                if (store_count_t0_n == {STORE_COUNT_W{1'b0}})
                    store_head_ptr_t0_n = queue_write_ptr;
                store_tail_ptr_t0_n = queue_write_ptr;
                store_count_t0_n    = store_count_t0_n + {{(STORE_COUNT_W-1){1'b0}}, 1'b1};
            end else begin
                queue_write_ptr = (store_count_t1_n == {STORE_COUNT_W{1'b0}}) ? {STORE_PTR_W{1'b0}}
                                                                               : store_ptr_inc(store_tail_ptr_t1_n);
                store_slot_t1_n[queue_write_ptr]  = free0_idx;
                store_order_t1_n[queue_write_ptr] = disp0_order_id;
                if (store_count_t1_n == {STORE_COUNT_W{1'b0}})
                    store_head_ptr_t1_n = queue_write_ptr;
                store_tail_ptr_t1_n = queue_write_ptr;
                store_count_t1_n    = store_count_t1_n + {{(STORE_COUNT_W-1){1'b0}}, 1'b1};
            end
        end

        if (disp1_valid && free1_found && disp1_mem_write) begin
            if (disp1_tid == 1'b0) begin
                queue_write_ptr = (store_count_t0_n == {STORE_COUNT_W{1'b0}}) ? {STORE_PTR_W{1'b0}}
                                                                               : store_ptr_inc(store_tail_ptr_t0_n);
                store_slot_t0_n[queue_write_ptr]  = free1_idx;
                store_order_t0_n[queue_write_ptr] = disp1_order_id;
                if (store_count_t0_n == {STORE_COUNT_W{1'b0}})
                    store_head_ptr_t0_n = queue_write_ptr;
                store_tail_ptr_t0_n = queue_write_ptr;
                store_count_t0_n    = store_count_t0_n + {{(STORE_COUNT_W-1){1'b0}}, 1'b1};
            end else begin
                queue_write_ptr = (store_count_t1_n == {STORE_COUNT_W{1'b0}}) ? {STORE_PTR_W{1'b0}}
                                                                               : store_ptr_inc(store_tail_ptr_t1_n);
                store_slot_t1_n[queue_write_ptr]  = free1_idx;
                store_order_t1_n[queue_write_ptr] = disp1_order_id;
                if (store_count_t1_n == {STORE_COUNT_W{1'b0}})
                    store_head_ptr_t1_n = queue_write_ptr;
                store_tail_ptr_t1_n = queue_write_ptr;
                store_count_t1_n    = store_count_t1_n + {{(STORE_COUNT_W-1){1'b0}}, 1'b1};
            end
        end

        if (store_count_t0_n != {STORE_COUNT_W{1'b0}})
            store_head_order_id_t0_n = store_order_t0_n[store_head_ptr_t0_n];
        else
            store_head_order_id_t0_n = {`METADATA_ORDER_ID_W{1'b0}};

        if (store_count_t1_n != {STORE_COUNT_W{1'b0}})
            store_head_order_id_t1_n = store_order_t1_n[store_head_ptr_t1_n];
        else
            store_head_order_id_t1_n = {`METADATA_ORDER_ID_W{1'b0}};
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (lsi = 0; lsi < IQ_DEPTH; lsi = lsi + 1) begin
                store_slot_t0_r[lsi]  <= {IQ_IDX_W{1'b0}};
                store_order_t0_r[lsi] <= {`METADATA_ORDER_ID_W{1'b0}};
                store_slot_t1_r[lsi]  <= {IQ_IDX_W{1'b0}};
                store_order_t1_r[lsi] <= {`METADATA_ORDER_ID_W{1'b0}};
            end
            store_head_ptr_t0_r      <= {STORE_PTR_W{1'b0}};
            store_tail_ptr_t0_r      <= {STORE_PTR_W{1'b0}};
            store_count_t0_r         <= {STORE_COUNT_W{1'b0}};
            store_head_order_id_t0_r <= {`METADATA_ORDER_ID_W{1'b0}};
            store_head_ptr_t1_r      <= {STORE_PTR_W{1'b0}};
            store_tail_ptr_t1_r      <= {STORE_PTR_W{1'b0}};
            store_count_t1_r         <= {STORE_COUNT_W{1'b0}};
            store_head_order_id_t1_r <= {`METADATA_ORDER_ID_W{1'b0}};
        end else begin
            for (lsi = 0; lsi < IQ_DEPTH; lsi = lsi + 1) begin
                store_slot_t0_r[lsi]  <= store_slot_t0_n[lsi];
                store_order_t0_r[lsi] <= store_order_t0_n[lsi];
                store_slot_t1_r[lsi]  <= store_slot_t1_n[lsi];
                store_order_t1_r[lsi] <= store_order_t1_n[lsi];
            end
            store_head_ptr_t0_r      <= store_head_ptr_t0_n;
            store_tail_ptr_t0_r      <= store_tail_ptr_t0_n;
            store_count_t0_r         <= store_count_t0_n;
            store_head_order_id_t0_r <= store_head_order_id_t0_n;
            store_head_ptr_t1_r      <= store_head_ptr_t1_n;
            store_tail_ptr_t1_r      <= store_tail_ptr_t1_n;
            store_count_t1_r         <= store_count_t1_n;
            store_head_order_id_t1_r <= store_head_order_id_t1_n;
        end
    end

endmodule
