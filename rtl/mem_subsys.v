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
// Address Decode
// ═════════════════════════════════════════════════════════════════════════════

// Address regions (from define_v2.v)
// RAM cacheable: 0x0000_0000 - 0x0000_3FFF
// TUBE MMIO:     0x1300_0000
// CLINT MMIO:    0x0200_0000 - 0x0200_BFFC
// PLIC MMIO:     0x0C00_0000 - 0x0C20_0004

wire addr_is_ram     = (m1_req_addr >= `RAM_CACHEABLE_BASE) && (m1_req_addr <= `RAM_CACHEABLE_TOP);
wire addr_is_tube    = (m1_req_addr == `TUBE_ADDR);
wire addr_is_clint   = (m1_req_addr >= `CLINT_BASE) && (m1_req_addr <= `CLINT_MTIME_HI);
wire addr_is_plic    = (m1_req_addr >= `PLIC_BASE) && (m1_req_addr <= `PLIC_CLAIM_COMPLETE);
wire addr_is_uncached = addr_is_tube || addr_is_clint || addr_is_plic;

// For simplicity in Task 4: all accesses go directly to RAM (L2 bypassed)
// Task 7 will add the actual L2 cache

// ═════════════════════════════════════════════════════════════════════════════
// Shared Backing RAM (4096 x 32-bit words = 16KB)
// ═════════════════════════════════════════════════════════════════════════════

reg [31:0] ram [0:4095];
reg [31:0] ram_rdata;

// Word address for RAM (bits [13:2] of byte address)
wire [11:0] ram_word_addr_m0 = m0_req_addr[13:2];
wire [11:0] ram_word_addr_m1 = m1_req_addr[13:2];

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
// Simple Arbitration: Priority to M0 (I-side), then M1 (D-side)
// Task 7 will replace with round-robin L2 arbiter
// ═════════════════════════════════════════════════════════════════════════════

wire m0_active = m0_req_valid;
wire m1_active = m1_req_valid;

// Grant signals
wire grant_m0 = m0_active;  // M0 has priority
wire grant_m1 = !m0_active && m1_active;

// Ready signals
assign m0_req_ready = grant_m0;
assign m1_req_ready = grant_m1;

// ═════════════════════════════════════════════════════════════════════════════
// M1 (D-side) Response Logic with MMIO decode
// ═════════════════════════════════════════════════════════════════════════════

reg        m1_resp_valid_r;
reg [31:0] m1_resp_data_r;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        m1_resp_valid_r <= 1'b0;
        m1_resp_data_r  <= 32'd0;
        tube_status     <= 8'd0;
        clint_mtime     <= 64'd0;
        clint_mtimecmp  <= 64'd0;
        plic_priority1  <= 3'd0;
        plic_pending    <= 1'b0;
        plic_enable     <= 1'b0;
        plic_threshold  <= 3'd0;
        plic_claim      <= 32'd0;
    end else begin
        m1_resp_valid_r <= 1'b0;
        clint_mtime <= clint_mtime + 64'd1;  // Always increment time

        if (grant_m1) begin
            m1_resp_valid_r <= 1'b1;

            if (addr_is_tube) begin
                // TUBE MMIO: writes set tube_status, reads return 0
                if (m1_req_write) begin
                    tube_status <= m1_req_wdata[7:0];
                end
                m1_resp_data_r <= 32'd0;
            end
            else if (addr_is_clint) begin
                // CLINT MMIO: stubbed (returns 0, writes ignored)
                // Full implementation in Task 10
                m1_resp_data_r <= 32'd0;
            end
            else if (addr_is_plic) begin
                // PLIC MMIO: stubbed (returns 0, writes ignored)
                // Full implementation in Task 11
                m1_resp_data_r <= 32'd0;
            end
            else if (addr_is_ram) begin
                // RAM access
                if (m1_req_write) begin
                    // Byte-wise write
                    if (m1_req_wen[0]) ram[ram_word_addr_m1][7:0]   <= m1_req_wdata[7:0];
                    if (m1_req_wen[1]) ram[ram_word_addr_m1][15:8]  <= m1_req_wdata[15:8];
                    if (m1_req_wen[2]) ram[ram_word_addr_m1][23:16] <= m1_req_wdata[23:16];
                    if (m1_req_wen[3]) ram[ram_word_addr_m1][31:24] <= m1_req_wdata[31:24];
                end
                m1_resp_data_r <= ram[ram_word_addr_m1];
            end
            else begin
                // Unmapped address
                m1_resp_data_r <= 32'd0;
            end
        end
    end
end

assign m1_resp_valid = m1_resp_valid_r;
assign m1_resp_data  = m1_resp_data_r;

// ═════════════════════════════════════════════════════════════════════════════
// M0 (I-side) Response Logic: Simple RAM read
// ═════════════════════════════════════════════════════════════════════════════

reg        m0_resp_valid_r;
reg [31:0] m0_resp_data_r;
reg [1:0]  m0_beat_cnt;  // For 4-beat refill (32B line / 4B per beat = 8 beats, but use 4 for now)

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        m0_resp_valid_r <= 1'b0;
        m0_resp_data_r  <= 32'd0;
        m0_beat_cnt     <= 2'd0;
    end else begin
        if (grant_m0) begin
            m0_resp_valid_r <= 1'b1;
            // For now: single-beat response (4 bytes)
            // Task 7 will implement multi-beat refill for 32B cache lines
            m0_resp_data_r <= ram[ram_word_addr_m0 + m0_beat_cnt];
            m0_beat_cnt <= m0_beat_cnt + 1;
        end else begin
            m0_resp_valid_r <= 1'b0;
            m0_beat_cnt <= 2'd0;
        end
    end
end

assign m0_resp_valid = m0_resp_valid_r;
assign m0_resp_data  = m0_resp_data_r;
assign m0_resp_last  = (m0_beat_cnt == 2'd3);  // Last beat after 4 transfers

// ═════════════════════════════════════════════════════════════════════════════
// RAM Preload Interface (for testbench)
// Testbench can access ram[] array directly via hierarchical reference
// ═════════════════════════════════════════════════════════════════════════════

endmodule
