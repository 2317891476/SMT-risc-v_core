// =============================================================================
// Module : tlb
// Description: Parameterized Translation Lookaside Buffer.
//   Supports fully-associative or set-associative configurations.
//   Each entry stores: {valid, asid, vpn, ppn, permission bits, mega-page flag}
//   Implements SFENCE.VMA-compatible invalidation.
//
//   Lookup: combinational (single-cycle hit/miss)
//   Refill: registered (from PTW)
//   Flush: registered (SFENCE.VMA)
// =============================================================================
module tlb #(
    parameter ENTRIES  = 16,        // Total entries
    parameter WAYS     = 0,         // 0 = fully-associative, >0 = set-associative
    parameter VPN_W    = 20,        // Sv32: 20-bit VPN
    parameter PPN_W    = 22,        // Sv32: 22-bit PPN
    parameter ASID_W   = 9          // ASID width
)(
    input  wire                  clk,
    input  wire                  rstn,

    // ─── Lookup Port (combinational) ────────────────────────────
    input  wire                  lookup_valid,
    input  wire [VPN_W-1:0]      lookup_vpn,
    input  wire [ASID_W-1:0]     lookup_asid,
    output wire                  lookup_hit,
    output wire [PPN_W-1:0]      lookup_ppn,
    output wire                  lookup_is_mega, // 4MB superpage
    output wire [7:0]            lookup_perm,    // {D,A,G,U,X,W,R,V}

    // ─── Refill Port (from PTW, registered) ─────────────────────
    input  wire                  refill_valid,
    input  wire [VPN_W-1:0]      refill_vpn,
    input  wire [ASID_W-1:0]     refill_asid,
    input  wire [PPN_W-1:0]      refill_ppn,
    input  wire                  refill_is_mega,
    input  wire [7:0]            refill_perm,

    // ─── Invalidation (SFENCE.VMA) ──────────────────────────────
    input  wire                  sfence_valid,
    input  wire [VPN_W-1:0]      sfence_vpn,    // 0 = flush all
    input  wire [ASID_W-1:0]     sfence_asid    // 0 = flush all ASIDs
);

localparam IDX_W = $clog2(ENTRIES);

// ─── Entry storage ──────────────────────────────────────────────────────────
reg                  entry_valid   [0:ENTRIES-1];
reg [ASID_W-1:0]     entry_asid    [0:ENTRIES-1];
reg [VPN_W-1:0]      entry_vpn     [0:ENTRIES-1];
reg [PPN_W-1:0]      entry_ppn     [0:ENTRIES-1];
reg                  entry_is_mega [0:ENTRIES-1];
reg [7:0]            entry_perm    [0:ENTRIES-1];

// ─── Replacement: pseudo-LRU (clock-hand for fully-assoc) ───────────────────
reg [IDX_W-1:0]      replace_ptr;

// ─── Lookup logic (fully-associative CAM) ───────────────────────────────────
reg                  hit_found;
reg [IDX_W-1:0]      hit_idx;
integer              i;
reg                  refill_match_found;
reg [IDX_W-1:0]      refill_match_idx;
integer              refill_i;

always @(*) begin
    hit_found = 1'b0;
    hit_idx   = {IDX_W{1'b0}};
    for (i = 0; i < ENTRIES; i = i + 1) begin
        if (!hit_found && entry_valid[i]) begin
            // For mega-pages, only compare VPN[19:10] (upper 10 bits)
            if (entry_is_mega[i]) begin
                if ((entry_vpn[i][VPN_W-1:10] == lookup_vpn[VPN_W-1:10]) &&
                    (entry_asid[i] == lookup_asid || entry_perm[i][5])) begin // G bit = global
                    hit_found = 1'b1;
                    hit_idx   = i[IDX_W-1:0];
                end
            end
            else begin
                if ((entry_vpn[i] == lookup_vpn) &&
                    (entry_asid[i] == lookup_asid || entry_perm[i][5])) begin
                    hit_found = 1'b1;
                    hit_idx   = i[IDX_W-1:0];
                end
            end
        end
    end
end

assign lookup_hit     = hit_found && lookup_valid;
assign lookup_ppn     = hit_found ? entry_ppn[hit_idx]     : {PPN_W{1'b0}};
assign lookup_is_mega = hit_found ? entry_is_mega[hit_idx] : 1'b0;
assign lookup_perm    = hit_found ? entry_perm[hit_idx]    : 8'd0;

always @(*) begin
    refill_match_found = 1'b0;
    refill_match_idx   = {IDX_W{1'b0}};
    for (refill_i = 0; refill_i < ENTRIES; refill_i = refill_i + 1) begin
        if (!refill_match_found && entry_valid[refill_i]) begin
            if ((entry_asid[refill_i] == refill_asid || entry_perm[refill_i][5] || refill_perm[5]) &&
                (entry_is_mega[refill_i] == refill_is_mega)) begin
                if (refill_is_mega) begin
                    if (entry_vpn[refill_i][VPN_W-1:10] == refill_vpn[VPN_W-1:10]) begin
                        refill_match_found = 1'b1;
                        refill_match_idx   = refill_i[IDX_W-1:0];
                    end
                end
                else if (entry_vpn[refill_i] == refill_vpn) begin
                    refill_match_found = 1'b1;
                    refill_match_idx   = refill_i[IDX_W-1:0];
                end
            end
        end
    end
end

// ─── Refill & Invalidation (sequential) ─────────────────────────────────────
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        replace_ptr <= {IDX_W{1'b0}};
        for (i = 0; i < ENTRIES; i = i + 1) begin
            entry_valid[i]   <= 1'b0;
            entry_asid[i]    <= {ASID_W{1'b0}};
            entry_vpn[i]     <= {VPN_W{1'b0}};
            entry_ppn[i]     <= {PPN_W{1'b0}};
            entry_is_mega[i] <= 1'b0;
            entry_perm[i]    <= 8'd0;
        end
    end
    else begin
        // ── SFENCE.VMA ──────────────────────────────────────────
        if (sfence_valid) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                if (sfence_vpn == {VPN_W{1'b0}} && sfence_asid == {ASID_W{1'b0}}) begin
                    // Flush all
                    entry_valid[i] <= 1'b0;
                end
                else if (sfence_vpn == {VPN_W{1'b0}}) begin
                    // Flush by ASID
                    if (entry_asid[i] == sfence_asid && !entry_perm[i][5])
                        entry_valid[i] <= 1'b0;
                end
                else if (sfence_asid == {ASID_W{1'b0}}) begin
                    // Flush by VPN (all ASIDs)
                    if (entry_vpn[i] == sfence_vpn)
                        entry_valid[i] <= 1'b0;
                end
                else begin
                    // Flush by VPN + ASID
                    if (entry_vpn[i] == sfence_vpn && entry_asid[i] == sfence_asid)
                        entry_valid[i] <= 1'b0;
                end
            end
        end

        // ── Refill ──────────────────────────────────────────────
        if (refill_valid) begin
            entry_valid[refill_match_found ? refill_match_idx : replace_ptr]   <= 1'b1;
            entry_asid[refill_match_found ? refill_match_idx : replace_ptr]    <= refill_asid;
            entry_vpn[refill_match_found ? refill_match_idx : replace_ptr]     <= refill_vpn;
            entry_ppn[refill_match_found ? refill_match_idx : replace_ptr]     <= refill_ppn;
            entry_is_mega[refill_match_found ? refill_match_idx : replace_ptr] <= refill_is_mega;
            entry_perm[refill_match_found ? refill_match_idx : replace_ptr]    <= refill_perm;
            if (!refill_match_found)
                replace_ptr <= replace_ptr + 1;
        end
    end
end

endmodule
