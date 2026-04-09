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
    input  wire [`METADATA_ORDER_ID_W-1:0]  disp0_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]     disp0_epoch,
    // Source dependencies (from rename / reg_result)
    input  wire [RS_TAG_W-1:0]              disp0_src1_tag,  // 0 = ready
    input  wire [RS_TAG_W-1:0]              disp0_src2_tag,

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
    input  wire [`METADATA_ORDER_ID_W-1:0]  disp1_order_id,
    input  wire [`METADATA_EPOCH_W-1:0]     disp1_epoch,
    input  wire [RS_TAG_W-1:0]              disp1_src1_tag,
    input  wire [RS_TAG_W-1:0]              disp1_src2_tag,

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
    input  wire        wb0_regs_write,
    input  wire        wb1_valid,
    input  wire [RS_TAG_W-1:0] wb1_tag,
    input  wire        wb1_regs_write,

    // ─── Commit (deallocation) ───────────────────────────────────
    input  wire        commit0_valid,
    input  wire [RS_TAG_W-1:0] commit0_tag,
    input  wire [0:0]  commit0_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id,
    input  wire        commit1_valid,
    input  wire [RS_TAG_W-1:0] commit1_tag,
    input  wire [0:0]  commit1_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] commit1_order_id,

    // ─── External issue inhibit (e.g. branch_in_flight) ─────────
    input  wire        issue_inhibit_t0,
    input  wire        issue_inhibit_t1
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
    reg [`METADATA_ORDER_ID_W-1:0] e_order_id [0:IQ_DEPTH-1];

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

    // --- Pre-compute oldest pending store sequence per thread (O(N)) ---
    // A "pending store" in the IQ is valid, un-issued, and is a store.
    // Loads are blocked if their seq > oldest pending store seq in same thread.
    reg [`METADATA_ORDER_ID_W-1:0] oldest_store_seq_t0, oldest_store_seq_t1;
    reg                            any_store_t0,         any_store_t1;
    integer ps;

    always @(*) begin
        oldest_store_seq_t0 = {`METADATA_ORDER_ID_W{1'b1}};
        oldest_store_seq_t1 = {`METADATA_ORDER_ID_W{1'b1}};
        any_store_t0        = 1'b0;
        any_store_t1        = 1'b0;
        if (CHECK_LOAD_STORE_ORDER) begin
            for (ps = 0; ps < IQ_DEPTH; ps = ps + 1) begin
                if (e_valid[ps] && e_mem_write[ps]) begin
                    if (e_tid[ps] == 1'b0) begin
                        any_store_t0 = 1'b1;
                        if (e_seq[ps] < oldest_store_seq_t0)
                            oldest_store_seq_t0 = e_seq[ps];
                    end else begin
                        any_store_t1 = 1'b1;
                        if (e_seq[ps] < oldest_store_seq_t1)
                            oldest_store_seq_t1 = e_seq[ps];
                    end
                end
            end
        end
    end

    reg                            sel_found;
    reg [IQ_IDX_W-1:0]            sel_idx;
    reg [`METADATA_ORDER_ID_W-1:0] sel_seq;
    integer si;
    reg has_older_store;

    always @(*) begin
        sel_found = 1'b0;
        sel_idx   = {IQ_IDX_W{1'b0}};
        sel_seq   = {`METADATA_ORDER_ID_W{1'b1}};  // max

        for (si = 0; si < IQ_DEPTH; si = si + 1) begin
            if (e_valid[si] && !e_issued[si] && e_ready[si] && !e_just_woke[si]) begin
                // Check external inhibit per thread
                if ((e_tid[si] == 1'b0 && issue_inhibit_t0) ||
                    (e_tid[si] == 1'b1 && issue_inhibit_t1))
                    ; // skip
                else begin
                    // Load-store ordering (MEM IQ only): O(1) per entry check
                    has_older_store = 1'b0;
                    if (CHECK_LOAD_STORE_ORDER && e_mem_read[si] && !e_mem_write[si]) begin
                        if (e_tid[si] == 1'b0)
                            has_older_store = any_store_t0 && (oldest_store_seq_t0 < e_seq[si]);
                        else
                            has_older_store = any_store_t1 && (oldest_store_seq_t1 < e_seq[si]);
                    end

                    if (!has_older_store && (!sel_found || (e_seq[si] < sel_seq))) begin
                        sel_found = 1'b1;
                        sel_idx   = si[IQ_IDX_W-1:0];
                        sel_seq   = e_seq[si];
                    end
                end
            end
        end
    end

    // ═══ Issue Output Drive ═══
    always @(*) begin
        iss_valid = sel_found;
        if (sel_found) begin
            iss_tag          = e_tag[sel_idx];
            iss_pc           = e_pc[sel_idx];
            iss_imm          = e_imm[sel_idx];
            iss_func3        = e_func3[sel_idx];
            iss_func7        = e_func7[sel_idx];
            iss_rd           = e_rd[sel_idx];
            iss_rs1          = e_rs1[sel_idx];
            iss_rs2          = e_rs2[sel_idx];
            iss_rs1_used     = e_rs1_used[sel_idx];
            iss_rs2_used     = e_rs2_used[sel_idx];
            iss_src1_tag     = e_src1_tag[sel_idx];
            iss_src2_tag     = e_src2_tag[sel_idx];
            iss_br           = e_br[sel_idx];
            iss_mem_read     = e_mem_read[sel_idx];
            iss_mem2reg      = e_mem2reg[sel_idx];
            iss_alu_op       = e_alu_op[sel_idx];
            iss_mem_write    = e_mem_write[sel_idx];
            iss_alu_src1     = e_alu_src1[sel_idx];
            iss_alu_src2     = e_alu_src2[sel_idx];
            iss_br_addr_mode = e_br_addr_mode[sel_idx];
            iss_regs_write   = e_regs_write[sel_idx];
            iss_fu           = e_fu[sel_idx];
            iss_tid          = e_tid[sel_idx];
            iss_is_mret      = e_is_mret[sel_idx];
            iss_order_id     = e_order_id[sel_idx];
            iss_epoch        = e_epoch[sel_idx];
        end
        else begin
            iss_tag = {RS_TAG_W{1'b0}};
            iss_pc  = 32'd0; iss_imm = 32'd0;
            iss_func3 = 3'd0; iss_func7 = 1'b0;
            iss_rd = 5'd0; iss_rs1 = 5'd0; iss_rs2 = 5'd0;
            iss_rs1_used = 1'b0; iss_rs2_used = 1'b0;
            iss_src1_tag = {RS_TAG_W{1'b0}}; iss_src2_tag = {RS_TAG_W{1'b0}};
            iss_br = 1'b0; iss_mem_read = 1'b0; iss_mem2reg = 1'b0;
            iss_alu_op = 3'd0; iss_mem_write = 1'b0;
            iss_alu_src1 = 2'd0; iss_alu_src2 = 2'd0;
            iss_br_addr_mode = 1'b0; iss_regs_write = 1'b0;
            iss_fu = 3'd0; iss_tid = 1'b0; iss_is_mret = 1'b0;
            iss_order_id = {`METADATA_ORDER_ID_W{1'b0}};
            iss_epoch = {`METADATA_EPOCH_W{1'b0}};
        end
    end

    // ═══ Sequential Logic ═══
    integer i;
    reg [RS_TAG_W-1:0] nqj, nqk;
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
                e_just_woke[i] <= 1'b0;
                e_wake_hold[i] <= 2'd0;
            end
            alloc_seq <= {`METADATA_ORDER_ID_W{1'b0}};
        end
        else begin
            // ── Epoch-based flush ──
            if (flush) begin
                for (i = 0; i < IQ_DEPTH; i = i + 1) begin
                    if (e_valid[i] && (e_tid[i] == flush_tid)) begin
                        if (e_epoch[i] != flush_new_epoch) begin
                            e_valid[i] <= 1'b0;
                        end
                        else if (flush_order_valid &&
                                 e_order_id[i] >= flush_order_id) begin
                            e_valid[i] <= 1'b0;
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
                    woke_src = 1'b0;

                    // WB port 0
                    if (wb0_valid && wb0_regs_write && (wb0_tag != {RS_TAG_W{1'b0}})) begin
                        if (nqj == wb0_tag) begin nqj = {RS_TAG_W{1'b0}}; woke_src = 1'b1; end
                        if (nqk == wb0_tag) begin nqk = {RS_TAG_W{1'b0}}; woke_src = 1'b1; end
                    end
                    // WB port 1
                    if (wb1_valid && wb1_regs_write && (wb1_tag != {RS_TAG_W{1'b0}})) begin
                        if (nqj == wb1_tag) begin nqj = {RS_TAG_W{1'b0}}; woke_src = 1'b1; end
                        if (nqk == wb1_tag) begin nqk = {RS_TAG_W{1'b0}}; woke_src = 1'b1; end
                    end

                    e_qj[i]    <= nqj;
                    e_qk[i]    <= nqk;
                    e_ready[i] <= (nqj == {RS_TAG_W{1'b0}}) && (nqk == {RS_TAG_W{1'b0}});

                    // Clear src tags when dependency resolves — prevents stale
                    // tagbuf lookups after the producing tag is recycled.
                    if (nqj == {RS_TAG_W{1'b0}}) e_src1_tag[i] <= {RS_TAG_W{1'b0}};
                    if (nqk == {RS_TAG_W{1'b0}}) e_src2_tag[i] <= {RS_TAG_W{1'b0}};

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
                        if (e_valid[i] && e_tag[i] == commit0_tag && e_tid[i] == commit0_tid)
                            e_valid[i] <= 1'b0;
                end
                if (commit1_valid) begin
                    for (i = 0; i < IQ_DEPTH; i = i + 1)
                        if (e_valid[i] && e_tag[i] == commit1_tag && e_tid[i] == commit1_tid)
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
            end

            // ── Update alloc_seq ──
            if (disp0_valid && disp1_valid)
                alloc_seq <= alloc_seq + 16'd2;
            else if (disp0_valid || disp1_valid)
                alloc_seq <= alloc_seq + 16'd1;
        end
    end

endmodule
