`timescale 1ns/1ns
// =============================================================================
// Module : rename_map_table
// Description: Architectural -> Physical register rename mapping table.
//   Single-thread LUTRAM-based mapping for RV32I register file (x0-x31).
//   Supports:
//   - Dual-dispatch rename (inst0/inst1 same cycle, with bypass for RAW)
//   - Combinational read (single-cycle rename)
//   - ROB walk recovery (one mapping restored per cycle)
//   - Bulk reset to identity mapping (trap flush)
//   - Physical register ready tracking for IQ initialization
//
//   x0 is hardwired: always maps to phys_reg 0 and is always ready.
// =============================================================================
`include "define.v"

module rename_map_table #(
    parameter NUM_ARCH_REG = 32,
    parameter ARCH_REG_W   = 5,
    parameter NUM_PHYS_REG = 64,
    parameter PHYS_REG_W   = 6,
    parameter BR_CKPT_DEPTH = 32,
    parameter BR_CKPT_IDX_W = 5,
    parameter ENABLE_CKPT_QUERY = 1
)(
    input  wire        clk,
    input  wire        rstn,

    // --- Rename Lookup (combinational read) ---
    // Inst 0 operands
    input  wire [ARCH_REG_W-1:0]    lookup0_rs1,
    input  wire [ARCH_REG_W-1:0]    lookup0_rs2,
    input  wire [ARCH_REG_W-1:0]    lookup0_rd,      // For reading old mapping (prd_old)
    // Inst 1 operands
    input  wire [ARCH_REG_W-1:0]    lookup1_rs1,
    input  wire [ARCH_REG_W-1:0]    lookup1_rs2,
    input  wire [ARCH_REG_W-1:0]    lookup1_rd,

    // Inst 0 rename outputs
    output wire [PHYS_REG_W-1:0]    prs0_1,          // phys source 1 for inst0
    output wire [PHYS_REG_W-1:0]    prs0_2,          // phys source 2 for inst0
    output wire [PHYS_REG_W-1:0]    prd0_old,        // old phys dest mapping for inst0

    // Inst 1 rename outputs (with inst0 bypass)
    output wire [PHYS_REG_W-1:0]    prs1_1,          // phys source 1 for inst1
    output wire [PHYS_REG_W-1:0]    prs1_2,          // phys source 2 for inst1
    output wire [PHYS_REG_W-1:0]    prd1_old,        // old phys dest mapping for inst1

    // --- Ready bit lookup (combinational) ---
    output wire        prs0_1_ready,
    output wire        prs0_2_ready,
    output wire        prs1_1_ready,
    output wire        prs1_2_ready,

    // --- Rename Update (posedge -- write new mapping) ---
    input  wire        alloc0_valid,                  // inst0 has rd to rename
    input  wire [ARCH_REG_W-1:0]    alloc0_rd,
    input  wire [PHYS_REG_W-1:0]    alloc0_prd_new,
    input  wire        alloc1_valid,                  // inst1 has rd to rename
    input  wire [ARCH_REG_W-1:0]    alloc1_rd,
    input  wire [PHYS_REG_W-1:0]    alloc1_prd_new,

    // --- CDB Writeback (mark phys reg as ready) ---
    input  wire        cdb0_valid,
    input  wire [PHYS_REG_W-1:0]    cdb0_prd,
    input  wire        cdb1_valid,
    input  wire [PHYS_REG_W-1:0]    cdb1_prd,

    // --- Recovery (ROB walk -- one mapping per cycle) ---
    input  wire        recover_en,
    input  wire [ARCH_REG_W-1:0]    recover_rd,
    input  wire [PHYS_REG_W-1:0]    recover_prd,

    // --- Bulk reset to architectural state (trap flush) ---
    input  wire        reset_to_arch,

    // Reclamation safety query: do not return a physical register to the
    // freelist while it is still named by the architectural map.
    input  wire [PHYS_REG_W-1:0] query0_prd,
    output reg                   query0_mapped,
    input  wire [PHYS_REG_W-1:0] query1_prd,
    output reg                   query1_mapped,
    input  wire [PHYS_REG_W-1:0] ckpt_query0_prd,
    output reg                   ckpt_query0_live,
    input  wire [PHYS_REG_W-1:0] ckpt_query1_prd,
    output reg                   ckpt_query1_live,

    input  wire                  branch_ckpt_capture0_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_capture0_order_id,
    input  wire                  branch_ckpt_capture1_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_capture1_order_id,
    input  wire                  branch_ckpt_restore,
    input  wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_restore_order_id,
    output reg                   branch_ckpt_restore_hit,
    output reg                   branch_ckpt_any_live,
    input  wire                  branch_ckpt_drop0_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_drop0_order_id,
    input  wire                  branch_ckpt_drop1_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_drop1_order_id,
    input  wire                  ckpt_commit0_valid,
    input  wire [ARCH_REG_W-1:0] ckpt_commit0_rd,
    input  wire [PHYS_REG_W-1:0] ckpt_commit0_prd_new,
    input  wire                  ckpt_commit1_valid,
    input  wire [ARCH_REG_W-1:0] ckpt_commit1_rd,
    input  wire [PHYS_REG_W-1:0] ckpt_commit1_prd_new,

    output reg  [NUM_PHYS_REG-1:0] mapped_mask_t0
);

    // === Storage: map_table[arch_reg] = phys_reg ===
    reg [PHYS_REG_W-1:0] map_table [0:NUM_ARCH_REG-1];

    // Ready bit: 1 if physical register has been written (result available in PRF)
    // Indexed by phys reg number
    reg [NUM_PHYS_REG-1:0] phys_ready;

    reg                         ckpt_valid [0:BR_CKPT_DEPTH-1];
    reg [`METADATA_ORDER_ID_W-1:0] ckpt_order_id [0:BR_CKPT_DEPTH-1];
    reg [PHYS_REG_W-1:0]        ckpt_map [0:BR_CKPT_DEPTH-1][0:NUM_ARCH_REG-1];
    reg [BR_CKPT_IDX_W-1:0]     branch_ckpt_restore_slot;

    // === Combinational Rename Lookup ===

    // Inst 0: direct table read
    assign prs0_1   = (lookup0_rs1 == {ARCH_REG_W{1'b0}}) ? {PHYS_REG_W{1'b0}} : map_table[lookup0_rs1];
    assign prs0_2   = (lookup0_rs2 == {ARCH_REG_W{1'b0}}) ? {PHYS_REG_W{1'b0}} : map_table[lookup0_rs2];
    assign prd0_old = (lookup0_rd  == {ARCH_REG_W{1'b0}}) ? {PHYS_REG_W{1'b0}} : map_table[lookup0_rd];

    // Inst 1: bypass inst0's rename if inst0 writes the same arch reg
    wire i0_writes_i1_rs1 = alloc0_valid && (alloc0_rd != {ARCH_REG_W{1'b0}}) && (alloc0_rd == lookup1_rs1);
    wire i0_writes_i1_rs2 = alloc0_valid && (alloc0_rd != {ARCH_REG_W{1'b0}}) && (alloc0_rd == lookup1_rs2);
    wire i0_writes_i1_rd  = alloc0_valid && (alloc0_rd != {ARCH_REG_W{1'b0}}) && (alloc0_rd == lookup1_rd);

    assign prs1_1   = (lookup1_rs1 == {ARCH_REG_W{1'b0}}) ? {PHYS_REG_W{1'b0}} :
                       i0_writes_i1_rs1                     ? alloc0_prd_new :
                       map_table[lookup1_rs1];

    assign prs1_2   = (lookup1_rs2 == {ARCH_REG_W{1'b0}}) ? {PHYS_REG_W{1'b0}} :
                       i0_writes_i1_rs2                     ? alloc0_prd_new :
                       map_table[lookup1_rs2];

    assign prd1_old = (lookup1_rd == {ARCH_REG_W{1'b0}})   ? {PHYS_REG_W{1'b0}} :
                       i0_writes_i1_rd                      ? alloc0_prd_new :
                       map_table[lookup1_rd];

    // === Ready Bit Lookup ===
    // x0 is always ready; for others, check phys_ready table
    // Also check CDB bypass: if CDB is broadcasting this cycle for the same prd, it's ready
    wire [PHYS_REG_W-1:0] eff_prs0_1 = prs0_1;
    wire [PHYS_REG_W-1:0] eff_prs0_2 = prs0_2;
    wire [PHYS_REG_W-1:0] eff_prs1_1 = prs1_1;
    wire [PHYS_REG_W-1:0] eff_prs1_2 = prs1_2;

    assign prs0_1_ready = (lookup0_rs1 == {ARCH_REG_W{1'b0}}) ? 1'b1 :
                          phys_ready[eff_prs0_1] ||
                          (cdb0_valid && cdb0_prd == eff_prs0_1) ||
                          (cdb1_valid && cdb1_prd == eff_prs0_1);

    assign prs0_2_ready = (lookup0_rs2 == {ARCH_REG_W{1'b0}}) ? 1'b1 :
                          phys_ready[eff_prs0_2] ||
                          (cdb0_valid && cdb0_prd == eff_prs0_2) ||
                          (cdb1_valid && cdb1_prd == eff_prs0_2);

    // Inst1 sources: if bypassed from inst0's new alloc, they are NOT ready
    // (inst0 hasn't executed yet), UNLESS CDB is delivering that same prd this cycle
    assign prs1_1_ready = (lookup1_rs1 == {ARCH_REG_W{1'b0}}) ? 1'b1 :
                          i0_writes_i1_rs1 ? ((cdb0_valid && cdb0_prd == alloc0_prd_new) ||
                                              (cdb1_valid && cdb1_prd == alloc0_prd_new)) :
                          phys_ready[eff_prs1_1] ||
                          (cdb0_valid && cdb0_prd == eff_prs1_1) ||
                          (cdb1_valid && cdb1_prd == eff_prs1_1);

    assign prs1_2_ready = (lookup1_rs2 == {ARCH_REG_W{1'b0}}) ? 1'b1 :
                          i0_writes_i1_rs2 ? ((cdb0_valid && cdb0_prd == alloc0_prd_new) ||
                                              (cdb1_valid && cdb1_prd == alloc0_prd_new)) :
                          phys_ready[eff_prs1_2] ||
                          (cdb0_valid && cdb0_prd == eff_prs1_2) ||
                          (cdb1_valid && cdb1_prd == eff_prs1_2);

    // === Sequential Update ===
    integer q0_idx, q1_idx, cq0_idx, cq0_reg, cq1_idx, cq1_reg;
    always @(*) begin
        query0_mapped = 1'b0;
        if (query0_prd != {PHYS_REG_W{1'b0}}) begin
            for (q0_idx = 1; q0_idx < NUM_ARCH_REG; q0_idx = q0_idx + 1) begin
                if (map_table[q0_idx] == query0_prd)
                    query0_mapped = 1'b1;
            end
        end
    end

    always @(*) begin
        query1_mapped = 1'b0;
        if (query1_prd != {PHYS_REG_W{1'b0}}) begin
            for (q1_idx = 1; q1_idx < NUM_ARCH_REG; q1_idx = q1_idx + 1) begin
                if (map_table[q1_idx] == query1_prd)
                    query1_mapped = 1'b1;
            end
        end
    end

    always @(*) begin
        ckpt_query0_live = 1'b0;
        if (ckpt_query0_prd != {PHYS_REG_W{1'b0}}) begin
            if (ENABLE_CKPT_QUERY) begin
                for (cq0_idx = 0; cq0_idx < BR_CKPT_DEPTH; cq0_idx = cq0_idx + 1) begin
                    if (ckpt_valid[cq0_idx]) begin
                        for (cq0_reg = 1; cq0_reg < NUM_ARCH_REG; cq0_reg = cq0_reg + 1) begin
                            if (ckpt_map[cq0_idx][cq0_reg] == ckpt_query0_prd)
                                ckpt_query0_live = 1'b1;
                        end
                    end
                end
            end
        end
    end

    always @(*) begin
        ckpt_query1_live = 1'b0;
        if (ckpt_query1_prd != {PHYS_REG_W{1'b0}}) begin
            if (ENABLE_CKPT_QUERY) begin
                for (cq1_idx = 0; cq1_idx < BR_CKPT_DEPTH; cq1_idx = cq1_idx + 1) begin
                    if (ckpt_valid[cq1_idx]) begin
                        for (cq1_reg = 1; cq1_reg < NUM_ARCH_REG; cq1_reg = cq1_reg + 1) begin
                            if (ckpt_map[cq1_idx][cq1_reg] == ckpt_query1_prd)
                                ckpt_query1_live = 1'b1;
                        end
                    end
                end
            end
        end
    end

    integer ckpt_find_idx;
    always @(*) begin
        branch_ckpt_restore_hit  = 1'b0;
        branch_ckpt_restore_slot = {BR_CKPT_IDX_W{1'b0}};
        branch_ckpt_any_live     = 1'b0;
        for (ckpt_find_idx = 0; ckpt_find_idx < BR_CKPT_DEPTH; ckpt_find_idx = ckpt_find_idx + 1) begin
            if (ckpt_valid[ckpt_find_idx])
                branch_ckpt_any_live = 1'b1;
        end
        if (branch_ckpt_restore) begin
            for (ckpt_find_idx = 0; ckpt_find_idx < BR_CKPT_DEPTH; ckpt_find_idx = ckpt_find_idx + 1) begin
                if (ckpt_valid[ckpt_find_idx] &&
                    (ckpt_order_id[ckpt_find_idx] == branch_ckpt_restore_order_id)) begin
                    branch_ckpt_restore_hit  = 1'b1;
                    branch_ckpt_restore_slot = ckpt_find_idx[BR_CKPT_IDX_W-1:0];
                end
            end
        end
    end

    integer mask_idx;
    always @(*) begin
        mapped_mask_t0 = {NUM_PHYS_REG{1'b0}};
        for (mask_idx = 0; mask_idx < NUM_ARCH_REG; mask_idx = mask_idx + 1) begin
            mapped_mask_t0[map_table[mask_idx]] = 1'b1;
        end
    end

    integer r, c, cap0_slot, cap1_slot;
    reg [PHYS_REG_W-1:0] cap_value;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            // Reset: identity mapping (arch reg i -> phys reg i)
            for (r = 0; r < NUM_ARCH_REG; r = r + 1)
                map_table[r] <= r[PHYS_REG_W-1:0];
            // All architectural registers are ready at reset
            phys_ready <= {NUM_PHYS_REG{1'b1}};
            for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                ckpt_valid[c] <= 1'b0;
                ckpt_order_id[c] <= {`METADATA_ORDER_ID_W{1'b0}};
                for (r = 0; r < NUM_ARCH_REG; r = r + 1)
                    ckpt_map[c][r] <= {PHYS_REG_W{1'b0}};
            end
        end
        else begin
            // -- CDB writeback: mark phys reg as ready --
            // This runs every cycle regardless of other operations
            if (cdb0_valid && cdb0_prd != {PHYS_REG_W{1'b0}}) begin
                phys_ready[cdb0_prd] <= 1'b1;
            end
            if (cdb1_valid && cdb1_prd != {PHYS_REG_W{1'b0}}) begin
                phys_ready[cdb1_prd] <= 1'b1;
            end

            if (reset_to_arch) begin
                // Trap flush: restore identity mapping
                for (r = 0; r < NUM_ARCH_REG; r = r + 1)
                    map_table[r] <= r[PHYS_REG_W-1:0];
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1)
                    ckpt_valid[c] <= 1'b0;
            end
            else if (branch_ckpt_restore && branch_ckpt_restore_hit) begin
                for (r = 0; r < NUM_ARCH_REG; r = r + 1)
                    map_table[r] <= ckpt_map[branch_ckpt_restore_slot][r];
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                    if (ckpt_valid[c] &&
                        (ckpt_order_id[c] >= branch_ckpt_restore_order_id))
                        ckpt_valid[c] <= 1'b0;
                end
            end
            else if (recover_en) begin
                // ROB walk: restore one mapping per cycle
                if (recover_rd != {ARCH_REG_W{1'b0}})
                    map_table[recover_rd] <= recover_prd;
            end
            else begin
                // Normal rename update:
                // inst0 writes first, inst1 writes second
                // If both write same rd, inst1 wins (last writer wins)
                if (alloc0_valid && alloc0_rd != {ARCH_REG_W{1'b0}}) begin
                    map_table[alloc0_rd] <= alloc0_prd_new;
                    // Mark newly allocated phys reg as not ready (in-flight)
                    phys_ready[alloc0_prd_new] <= 1'b0;
                end
                if (alloc1_valid && alloc1_rd != {ARCH_REG_W{1'b0}}) begin
                    map_table[alloc1_rd] <= alloc1_prd_new;
                    phys_ready[alloc1_prd_new] <= 1'b0;
                end
            end

            if (branch_ckpt_drop0_valid) begin
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                    if (ckpt_valid[c] &&
                        (ckpt_order_id[c] <= branch_ckpt_drop0_order_id))
                        ckpt_valid[c] <= 1'b0;
                end
            end
            if (branch_ckpt_drop1_valid) begin
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                    if (ckpt_valid[c] &&
                        (ckpt_order_id[c] <= branch_ckpt_drop1_order_id))
                        ckpt_valid[c] <= 1'b0;
                end
            end

            if (ckpt_commit0_valid && ckpt_commit0_rd != {ARCH_REG_W{1'b0}}) begin
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                    if (ckpt_valid[c])
                        ckpt_map[c][ckpt_commit0_rd] <= ckpt_commit0_prd_new;
                end
            end
            if (ckpt_commit1_valid && ckpt_commit1_rd != {ARCH_REG_W{1'b0}}) begin
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                    if (ckpt_valid[c])
                        ckpt_map[c][ckpt_commit1_rd] <= ckpt_commit1_prd_new;
                end
            end

            cap0_slot = -1;
            if (branch_ckpt_capture0_valid && !(branch_ckpt_restore && branch_ckpt_restore_hit)) begin
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                    if (!ckpt_valid[c] && cap0_slot < 0)
                        cap0_slot = c;
                end
                if (cap0_slot >= 0) begin
                    ckpt_valid[cap0_slot] <= 1'b1;
                    ckpt_order_id[cap0_slot] <= branch_ckpt_capture0_order_id;
                    for (r = 0; r < NUM_ARCH_REG; r = r + 1) begin
                        cap_value = map_table[r];
                        if (alloc0_valid &&
                            (alloc0_rd == r[ARCH_REG_W-1:0]) && (alloc0_rd != {ARCH_REG_W{1'b0}}))
                            cap_value = alloc0_prd_new;
                        ckpt_map[cap0_slot][r] <= cap_value;
                    end
                end
            end

            cap1_slot = -1;
            if (branch_ckpt_capture1_valid && !(branch_ckpt_restore && branch_ckpt_restore_hit)) begin
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                    if (!ckpt_valid[c] &&
                        !(branch_ckpt_capture0_valid && (cap0_slot == c)) &&
                        cap1_slot < 0)
                        cap1_slot = c;
                end
                if (cap1_slot >= 0) begin
                    ckpt_valid[cap1_slot] <= 1'b1;
                    ckpt_order_id[cap1_slot] <= branch_ckpt_capture1_order_id;
                    for (r = 0; r < NUM_ARCH_REG; r = r + 1) begin
                        cap_value = map_table[r];
                        if (alloc0_valid &&
                            (alloc0_rd == r[ARCH_REG_W-1:0]) && (alloc0_rd != {ARCH_REG_W{1'b0}}))
                            cap_value = alloc0_prd_new;
                        if (alloc1_valid &&
                            (alloc1_rd == r[ARCH_REG_W-1:0]) && (alloc1_rd != {ARCH_REG_W{1'b0}}))
                            cap_value = alloc1_prd_new;
                        ckpt_map[cap1_slot][r] <= cap_value;
                    end
                end
            end
        end
    end

    // === Assertions (simulation only) ===
    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn) begin
            // x0 must always map to phys 0
            if (map_table[0] != {PHYS_REG_W{1'b0}})
                $display("ERROR: rename_map_table x0 mapping corrupted at %0t", $time);
        end
    end
    // synthesis translate_on

endmodule
