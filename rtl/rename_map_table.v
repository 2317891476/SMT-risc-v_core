`timescale 1ns/1ns
// =============================================================================
// Module : rename_map_table
// Description: Architectural → Physical register rename mapping table.
//   Per-thread LUTRAM-based mapping for RV32I register file (x0-x31).
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
    parameter NUM_PHYS_REG = 48,
    parameter PHYS_REG_W   = 6,
    parameter NUM_THREAD   = 2
)(
    input  wire        clk,
    input  wire        rstn,

    // ─── Rename Lookup (combinational read, one thread at a time) ───
    input  wire [0:0]               tid,
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

    // ─── Ready bit lookup (combinational) ────────────────────────
    output wire        prs0_1_ready,
    output wire        prs0_2_ready,
    output wire        prs1_1_ready,
    output wire        prs1_2_ready,

    // ─── Rename Update (posedge — write new mapping) ─────────────
    input  wire        alloc0_valid,                  // inst0 has rd to rename
    input  wire [ARCH_REG_W-1:0]    alloc0_rd,
    input  wire [PHYS_REG_W-1:0]    alloc0_prd_new,
    input  wire        alloc1_valid,                  // inst1 has rd to rename
    input  wire [ARCH_REG_W-1:0]    alloc1_rd,
    input  wire [PHYS_REG_W-1:0]    alloc1_prd_new,

    // ─── CDB Writeback (mark phys reg as ready) ─────────────────
    input  wire        cdb0_valid,
    input  wire [PHYS_REG_W-1:0]    cdb0_prd,
    input  wire        cdb1_valid,
    input  wire [PHYS_REG_W-1:0]    cdb1_prd,

    // ─── Recovery (ROB walk — one mapping per cycle) ─────────────
    input  wire        recover_en,
    input  wire [ARCH_REG_W-1:0]    recover_rd,
    input  wire [PHYS_REG_W-1:0]    recover_prd,
    input  wire [0:0]               recover_tid,

    // ─── Bulk reset to architectural state (trap flush) ──────────
    input  wire        reset_to_arch,
    input  wire [0:0]  reset_tid
);

    // ═══ Storage: map_table[thread][arch_reg] = phys_reg ═══
    reg [PHYS_REG_W-1:0] map_table [0:NUM_THREAD-1][0:NUM_ARCH_REG-1];

    // Ready bit: 1 if physical register has been written (result available in PRF)
    // Indexed by phys reg number, per thread
    reg [NUM_PHYS_REG-1:0] phys_ready [0:NUM_THREAD-1];

    // ═══ Combinational Rename Lookup ═══

    // Inst 0: direct table read
    assign prs0_1   = (lookup0_rs1 == {ARCH_REG_W{1'b0}}) ? {PHYS_REG_W{1'b0}} : map_table[tid][lookup0_rs1];
    assign prs0_2   = (lookup0_rs2 == {ARCH_REG_W{1'b0}}) ? {PHYS_REG_W{1'b0}} : map_table[tid][lookup0_rs2];
    assign prd0_old = (lookup0_rd  == {ARCH_REG_W{1'b0}}) ? {PHYS_REG_W{1'b0}} : map_table[tid][lookup0_rd];

    // Inst 1: bypass inst0's rename if inst0 writes the same arch reg
    wire i0_writes_i1_rs1 = alloc0_valid && (alloc0_rd != {ARCH_REG_W{1'b0}}) && (alloc0_rd == lookup1_rs1);
    wire i0_writes_i1_rs2 = alloc0_valid && (alloc0_rd != {ARCH_REG_W{1'b0}}) && (alloc0_rd == lookup1_rs2);
    wire i0_writes_i1_rd  = alloc0_valid && (alloc0_rd != {ARCH_REG_W{1'b0}}) && (alloc0_rd == lookup1_rd);

    assign prs1_1   = (lookup1_rs1 == {ARCH_REG_W{1'b0}}) ? {PHYS_REG_W{1'b0}} :
                       i0_writes_i1_rs1                     ? alloc0_prd_new :
                       map_table[tid][lookup1_rs1];

    assign prs1_2   = (lookup1_rs2 == {ARCH_REG_W{1'b0}}) ? {PHYS_REG_W{1'b0}} :
                       i0_writes_i1_rs2                     ? alloc0_prd_new :
                       map_table[tid][lookup1_rs2];

    assign prd1_old = (lookup1_rd == {ARCH_REG_W{1'b0}})   ? {PHYS_REG_W{1'b0}} :
                       i0_writes_i1_rd                      ? alloc0_prd_new :
                       map_table[tid][lookup1_rd];

    // ═══ Ready Bit Lookup ═══
    // x0 is always ready; for others, check phys_ready table
    // Also check CDB bypass: if CDB is broadcasting this cycle for the same prd, it's ready
    wire [PHYS_REG_W-1:0] eff_prs0_1 = prs0_1;
    wire [PHYS_REG_W-1:0] eff_prs0_2 = prs0_2;
    wire [PHYS_REG_W-1:0] eff_prs1_1 = prs1_1;
    wire [PHYS_REG_W-1:0] eff_prs1_2 = prs1_2;

    assign prs0_1_ready = (lookup0_rs1 == {ARCH_REG_W{1'b0}}) ? 1'b1 :
                          phys_ready[tid][eff_prs0_1] ||
                          (cdb0_valid && cdb0_prd == eff_prs0_1) ||
                          (cdb1_valid && cdb1_prd == eff_prs0_1);

    assign prs0_2_ready = (lookup0_rs2 == {ARCH_REG_W{1'b0}}) ? 1'b1 :
                          phys_ready[tid][eff_prs0_2] ||
                          (cdb0_valid && cdb0_prd == eff_prs0_2) ||
                          (cdb1_valid && cdb1_prd == eff_prs0_2);

    // Inst1 sources: if bypassed from inst0's new alloc, they are NOT ready
    // (inst0 hasn't executed yet), UNLESS CDB is delivering that same prd this cycle
    assign prs1_1_ready = (lookup1_rs1 == {ARCH_REG_W{1'b0}}) ? 1'b1 :
                          i0_writes_i1_rs1 ? ((cdb0_valid && cdb0_prd == alloc0_prd_new) ||
                                              (cdb1_valid && cdb1_prd == alloc0_prd_new)) :
                          phys_ready[tid][eff_prs1_1] ||
                          (cdb0_valid && cdb0_prd == eff_prs1_1) ||
                          (cdb1_valid && cdb1_prd == eff_prs1_1);

    assign prs1_2_ready = (lookup1_rs2 == {ARCH_REG_W{1'b0}}) ? 1'b1 :
                          i0_writes_i1_rs2 ? ((cdb0_valid && cdb0_prd == alloc0_prd_new) ||
                                              (cdb1_valid && cdb1_prd == alloc0_prd_new)) :
                          phys_ready[tid][eff_prs1_2] ||
                          (cdb0_valid && cdb0_prd == eff_prs1_2) ||
                          (cdb1_valid && cdb1_prd == eff_prs1_2);

    // ═══ Sequential Update ═══
    integer t, r;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            // Reset: identity mapping (arch reg i → phys reg i)
            for (t = 0; t < NUM_THREAD; t = t + 1) begin
                for (r = 0; r < NUM_ARCH_REG; r = r + 1)
                    map_table[t][r] <= r[PHYS_REG_W-1:0];
                // All architectural registers are ready at reset
                phys_ready[t] <= {NUM_PHYS_REG{1'b1}};
            end
        end
        else begin
            // ── CDB writeback: mark phys reg as ready ──
            // This runs every cycle regardless of other operations
            if (cdb0_valid && cdb0_prd != {PHYS_REG_W{1'b0}}) begin
                phys_ready[0][cdb0_prd] <= 1'b1;
                phys_ready[1][cdb0_prd] <= 1'b1;
            end
            if (cdb1_valid && cdb1_prd != {PHYS_REG_W{1'b0}}) begin
                phys_ready[0][cdb1_prd] <= 1'b1;
                phys_ready[1][cdb1_prd] <= 1'b1;
            end

            if (reset_to_arch) begin
                // Trap flush: restore identity mapping for one thread
                for (r = 0; r < NUM_ARCH_REG; r = r + 1)
                    map_table[reset_tid][r] <= r[PHYS_REG_W-1:0];
            end
            else if (recover_en) begin
                // ROB walk: restore one mapping per cycle
                if (recover_rd != {ARCH_REG_W{1'b0}})
                    map_table[recover_tid][recover_rd] <= recover_prd;
            end
            else begin
                // Normal rename update:
                // inst0 writes first, inst1 writes second
                // If both write same rd, inst1 wins (last writer wins)
                if (alloc0_valid && alloc0_rd != {ARCH_REG_W{1'b0}}) begin
                    map_table[tid][alloc0_rd] <= alloc0_prd_new;
                    // Mark newly allocated phys reg as not ready (in-flight)
                    phys_ready[tid][alloc0_prd_new] <= 1'b0;
                end
                if (alloc1_valid && alloc1_rd != {ARCH_REG_W{1'b0}}) begin
                    map_table[tid][alloc1_rd] <= alloc1_prd_new;
                    phys_ready[tid][alloc1_prd_new] <= 1'b0;
                end
            end
        end
    end

    // ═══ Assertions (simulation only) ═══
    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn) begin
            // x0 must always map to phys 0
            if (map_table[0][0] != {PHYS_REG_W{1'b0}})
                $display("ERROR: rename_map_table T0 x0 mapping corrupted at %0t", $time);
            if (map_table[1][0] != {PHYS_REG_W{1'b0}})
                $display("ERROR: rename_map_table T1 x0 mapping corrupted at %0t", $time);
        end
    end
    // synthesis translate_on

endmodule
