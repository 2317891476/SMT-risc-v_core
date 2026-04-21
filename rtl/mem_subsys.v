// =============================================================================
// Module : mem_subsys
// Description: Shared memory subsystem with unified L2 cache, arbiter, and MMIO.
//   - Serves both I-side (instruction refill) and D-side (LSU/store buffer)
//   - Uses separate l2_arbiter and l2_cache modules
//   - MMIO decode for TUBE, CLINT, PLIC (uncached)
// =============================================================================
`include "define.v"

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
    input  wire [31:0] m0_bypass_addr,
    output wire [31:0] m0_bypass_data,

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
    // Master 2: RoCC DMA interface (AI accelerator memory access)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        m2_req_valid,
    output wire        m2_req_ready,
    input  wire [31:0] m2_req_addr,
    input  wire        m2_req_write,      // 0=read, 1=write
    input  wire [31:0] m2_req_wdata,
    input  wire [3:0]  m2_req_wen,        // Byte-wise write enable
    output wire        m2_resp_valid,
    output wire [31:0] m2_resp_data,

    // ═══════════════════════════════════════════════════════════════════════════
    // Testbench observation interface
    // ═══════════════════════════════════════════════════════════════════════════
    output reg [7:0]   tube_status,       // TUBE MMIO register (observable by tb)

    // ═══════════════════════════════════════════════════════════════════════════
    // External interrupt wiring
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        ext_irq_src,       // Raw PLIC source input (optional TB/device drive)
    output wire        ext_timer_irq,     // CLINT timer interrupt pending (MTIP)
    output wire        ext_external_irq,  // PLIC external interrupt pending (MEIP)

    // ═══════════════════════════════════════════════════════════════════════════
    // UART physical interface
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        uart_rx,           // UART receive pin
    output wire        uart_tx,           // UART transmit pin
    output wire        debug_uart_tx_byte_valid,
    output wire [7:0]  debug_uart_tx_byte,
    output wire [7:0]  debug_uart_status_load_count,
    output wire [7:0]  debug_uart_tx_store_count,
`ifdef VERILATOR_FAST_UART
    input  wire        fast_uart_rx_byte_valid,
    input  wire [7:0]  fast_uart_rx_byte,
`endif
    input  wire        debug_store_buffer_empty,
    input  wire [2:0]  debug_store_buffer_count_t0,
    input  wire [2:0]  debug_store_buffer_count_t1,
    output wire [127:0] debug_ddr3_m0_bus

`ifdef ENABLE_DDR3
    ,
    // ═══════════════════════════════════════════════════════════════════════════
    // DDR3 external memory port (active when addr[31]=1, i.e. >=0x8000_0000)
    // ═══════════════════════════════════════════════════════════════════════════
    output wire        ddr3_req_valid,
    input  wire        ddr3_req_ready,
    output wire [31:0] ddr3_req_addr,
    output wire        ddr3_req_write,
    output wire [31:0] ddr3_req_wdata,
    output wire [3:0]  ddr3_req_wen,
    input  wire        ddr3_resp_valid,
    input  wire [31:0] ddr3_resp_data,
    input  wire        ddr3_init_calib_complete
`endif
);

// ═════════════════════════════════════════════════════════════════════════════
// Shared Backing RAM (4096 x 32-bit words = 16KB)
// ═════════════════════════════════════════════════════════════════════════════
reg [31:0] ram [0:4095];

// RAM initialization: for FPGA builds, preload from combined hex file
// containing both .text (instructions) and .data sections.
// Testbench builds use hierarchical reference to fill ram[] instead.
integer ram_init_idx;
initial begin
    for (ram_init_idx = 0; ram_init_idx < 4096; ram_init_idx = ram_init_idx + 1)
        ram[ram_init_idx] = 32'd0;
`ifdef FPGA_MODE
    $readmemh("mem_subsys_ram.hex", ram);
`elsif VERILATOR_MAINLINE
    $readmemh("mem_subsys_ram.hex", ram);
`endif
end

// ═════════════════════════════════════════════════════════════════════════════
// Internal Wires for Arbiter-Cache Interface
// ═════════════════════════════════════════════════════════════════════════════

// Arbiter to Cache
wire        l2_req_valid;
wire        l2_req_ready;
wire [31:0] l2_req_addr;
wire        l2_req_write;
wire [31:0] l2_req_wdata;
wire [3:0]  l2_req_wen;
wire        l2_req_uncached;
wire        l2_resp_valid;
wire [31:0] l2_resp_data;
wire        l2_resp_last;

// Arbiter status
wire        grant_m0;
wire        grant_m1;
wire        grant_m2;
wire [2:0]  grant_count;

// Cache status
wire [2:0]  cache_state;
wire        cache_hit;
wire        cache_miss;

// Address decode for MMIO (used by arbiter and MMIO handling)
// The 0x1300_xxxx region covers TUBE (test marker) and UART MMIO registers.
wire addr_is_mmio_0x13_m1 = (m1_req_addr[31:16] == 16'h1300);
wire addr_is_tube_m1    = (m1_req_addr == `TUBE_ADDR);
wire addr_is_uart_tx_m1 = (m1_req_addr == `UART_TXDATA_ADDR);
wire addr_is_uart_status_m1 = (m1_req_addr == `UART_STATUS_ADDR);
wire addr_is_uart_rx_m1 = (m1_req_addr == `UART_RXDATA_ADDR);
wire addr_is_uart_ctrl_m1 = (m1_req_addr == `UART_CTRL_ADDR);
wire addr_is_ddr3_status_m1 = (m1_req_addr == `DDR3_STATUS_ADDR);
wire addr_is_debug_beacon_evt_m1 = (m1_req_addr == `DEBUG_BEACON_EVT_ADDR);
wire addr_is_uart_m1    = addr_is_uart_tx_m1 || addr_is_uart_status_m1
                        || addr_is_uart_rx_m1 || addr_is_uart_ctrl_m1
                        || addr_is_debug_beacon_evt_m1;
wire addr_is_clint_m1   = (m1_req_addr >= `CLINT_BASE) && (m1_req_addr <= `CLINT_MTIME_HI);
wire addr_is_plic_m1    = (m1_req_addr >= `PLIC_BASE) && (m1_req_addr <= `PLIC_CLAIM_COMPLETE);
wire addr_is_uncached_m1 = addr_is_mmio_0x13_m1 || addr_is_clint_m1 || addr_is_plic_m1;

// DDR3 region: address bit 31 set (0x8000_0000 - 0xFFFF_FFFF)
`ifdef ENABLE_DDR3
wire addr_is_ddr3_m0 = m0_req_addr[31];
wire m0_ddr3_req     = m0_req_valid && addr_is_ddr3_m0;
wire addr_is_ddr3_m1 = m1_req_addr[31];
wire m1_ddr3_req     = m1_req_valid && addr_is_ddr3_m1;
wire        m0_ddr3_req_ready;
wire        m0_ddr3_resp_valid;
wire [31:0] m0_ddr3_resp_data;
wire        m0_ddr3_resp_last;
wire        m1_ddr3_req_ready;
wire        m1_ddr3_resp_valid;
wire [31:0] m1_ddr3_resp_data;
wire        ddr3_calib_done_w = ddr3_init_calib_complete;
wire        ddr3_bridge_idle_w;
`else
wire addr_is_ddr3_m0 = 1'b0;
wire addr_is_ddr3_m1 = 1'b0;
wire        m0_ddr3_req_ready = 1'b0;
wire        m0_ddr3_resp_valid = 1'b0;
wire [31:0] m0_ddr3_resp_data = 32'd0;
wire        m0_ddr3_resp_last = 1'b0;
wire        m1_ddr3_req_ready = 1'b0;
wire        m1_ddr3_resp_valid = 1'b0;
wire [31:0] m1_ddr3_resp_data = 32'd0;
wire        ddr3_calib_done_w = 1'b0;
wire        ddr3_bridge_idle_w = 1'b1;
// synthesis translate_off
wire m0_ddr3_req     = 1'b0;
wire m1_ddr3_req     = 1'b0;
// synthesis translate_on
`endif

wire [31:0] ddr3_status_word = {
    18'd0,
    debug_store_buffer_count_t1,
    debug_store_buffer_count_t0,
    5'd0,
    ddr3_bridge_idle_w,
    debug_store_buffer_empty,
    ddr3_calib_done_w
};

// M2 (RoCC DMA) address decode - RAM-only access (0x0000_0000 - 0x0000_3FFF)
wire addr_is_ram_m2     = (m2_req_addr >= `RAM_CACHEABLE_BASE) && (m2_req_addr <= `RAM_CACHEABLE_TOP);
wire m2_cached_req      = m2_req_valid && addr_is_ram_m2;

// ═════════════════════════════════════════════════════════════════════════════
// L2 Arbiter Instance (only for cacheable traffic)
// ═════════════════════════════════════════════════════════════════════════════

// M1 cached request - filter out MMIO
wire        m1_cached_req   = m1_req_valid && !addr_is_uncached_m1 && !addr_is_ddr3_m1;
wire        m1_cached_ready;
wire        m0_l2_req_valid = m0_req_valid && !addr_is_ddr3_m0;
wire        m0_l2_req_ready;
wire        m0_l2_resp_valid;
wire [31:0] m0_l2_resp_data;
wire        m0_l2_resp_last;

// M1 ready: MMIO is immediate except for UART TX backpressure and the optional
// Step2-only beacon event mailbox.
wire       debug_beacon_evt_ready_w;
reg        m1_mmio_inflight_r;
`ifdef VERILATOR_MAINLINE
wire       uart_tx_ready_w = uart_tx_enable_r;
`else
wire       uart_tx_ready_w = uart_tx_enable_r && !uart_pending_valid_r;
`endif
wire m1_mmio_ready_core = addr_is_uart_tx_m1 && m1_req_write
                        ? uart_tx_ready_w
                        : (addr_is_debug_beacon_evt_m1 && m1_req_write
                           ? !debug_beacon_req_valid_r
                           : 1'b1);
`ifdef ENABLE_DDR3
assign m1_req_ready = addr_is_ddr3_m1    ? m1_ddr3_req_ready
                   : addr_is_uncached_m1 ? (m1_mmio_req && !m1_mmio_inflight_r && m1_mmio_ready_core)
                   : m1_cached_ready;
`else
assign m1_req_ready = addr_is_uncached_m1 ? (m1_mmio_req && !m1_mmio_inflight_r && m1_mmio_ready_core) : m1_cached_ready;
`endif

assign m0_req_ready  = addr_is_ddr3_m0 ? m0_ddr3_req_ready : m0_l2_req_ready;
assign m0_resp_valid = m0_ddr3_resp_valid ? 1'b1 : m0_l2_resp_valid;
assign m0_resp_data  = m0_ddr3_resp_valid ? m0_ddr3_resp_data : m0_l2_resp_data;
assign m0_resp_last  = m0_ddr3_resp_valid ? m0_ddr3_resp_last : m0_l2_resp_last;

l2_arbiter u_l2_arbiter (
    .clk            (clk),
    .rstn           (rstn),
    
    // Master 0: I-side (always cacheable)
    .m0_req_valid   (m0_l2_req_valid),
    .m0_req_ready   (m0_l2_req_ready),
    .m0_req_addr    (m0_req_addr),
    .m0_resp_valid  (m0_l2_resp_valid),
    .m0_resp_data   (m0_l2_resp_data),
    .m0_resp_last   (m0_l2_resp_last),
    
    // Master 1: D-side (cacheable only - MMIO filtered out)
    .m1_req_valid   (m1_cached_req),
    .m1_req_ready   (m1_cached_ready),
    .m1_req_addr    (m1_req_addr),
    .m1_req_write   (m1_req_write),
    .m1_req_wdata   (m1_req_wdata),
    .m1_req_wen     (m1_req_wen),
    .m1_resp_valid  (m1_resp_valid_int),
    .m1_resp_data   (m1_resp_data_int),
    
    // Master 2: RoCC DMA (RAM-only cacheable access)
    .m2_req_valid   (m2_cached_req),
    .m2_req_ready   (m2_req_ready),
    .m2_req_addr    (m2_req_addr),
    .m2_req_write   (m2_req_write),
    .m2_req_wdata   (m2_req_wdata),
    .m2_req_wen     (m2_req_wen),
    .m2_resp_valid  (m2_resp_valid),
    .m2_resp_data   (m2_resp_data),
    
    // L2 Cache interface
    .l2_req_valid   (l2_req_valid),
    .l2_req_ready   (l2_req_ready),
    .l2_req_addr    (l2_req_addr),
    .l2_req_write   (l2_req_write),
    .l2_req_wdata   (l2_req_wdata),
    .l2_req_wen     (l2_req_wen),
    .l2_req_uncached(l2_req_uncached),
    .l2_resp_valid  (l2_resp_valid),
    .l2_resp_data   (l2_resp_data),
    .l2_resp_last   (l2_resp_last),
    
    // Status
    .grant_m0       (grant_m0),
    .grant_m1       (grant_m1),
    .grant_m2       (grant_m2),
    .grant_count    (grant_count)
);

// ═════════════════════════════════════════════════════════════════════════════
// L2 Cache Instance
// ═════════════════════════════════════════════════════════════════════════════

// RAM interface wires
wire [31:0] ram_addr;
wire        ram_write;
wire [31:0] ram_wdata;
wire [31:0] ram_rdata;
wire [2:0]  ram_word_idx;

// RAM read data assignment
assign ram_rdata = ram[ram_addr[13:2]];
// I-side miss fast path: source the requested instruction word from the
// shared mem_subsys RAM instead of a separate inst_backing_store image.
assign m0_bypass_data = m0_bypass_addr[31] ? 32'd0 : ram[m0_bypass_addr[13:2]];


l2_cache u_l2_cache (
    .clk            (clk),
    .rstn           (rstn),
    
    // Request interface
    .req_valid      (l2_req_valid),
    .req_ready      (l2_req_ready),
    .req_addr       (l2_req_addr),
    .req_write      (l2_req_write),
    .req_wdata      (l2_req_wdata),
    .req_wen        (l2_req_wen),
    .req_uncached   (l2_req_uncached),
    
    // Response interface
    .resp_valid     (l2_resp_valid),
    .resp_data      (l2_resp_data),
    .resp_last      (l2_resp_last),
    
    // RAM interface
    .ram_addr       (ram_addr),
    .ram_write      (ram_write),
    .ram_wdata      (ram_wdata),
    .ram_rdata      (ram_rdata),
    .ram_word_idx   (ram_word_idx),
    
    // Status
    .cache_state    (cache_state),
    .cache_hit      (cache_hit),
    .cache_miss     (cache_miss)
);

// RAM write handling
always @(posedge clk) begin
    if (ram_write) begin
        ram[ram_addr[13:2]] <= ram_wdata;
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// MMIO Bypass Path (deterministic, bypasses L2 entirely)
// ═════════════════════════════════════════════════════════════════════════════

// Detect MMIO requests - these bypass the arbiter/L2 for deterministic access
wire        m1_mmio_req = m1_req_valid && addr_is_uncached_m1;

// CLINT wires - MMIO bypass (no grant needed)
wire        clint_req_valid = addr_is_clint_m1 && m1_mmio_req;
wire [31:0] clint_resp_rdata;
wire        clint_resp_valid;
wire [31:0] clint_read_data;
wire        clint_timer_irq;

clint u_clint (
    .clk         (clk),
    .rstn        (rstn),
    .req_valid   (clint_req_valid),
    .req_addr    (m1_req_addr),
    .req_wen     (m1_req_write),
    .req_wdata   (m1_req_wdata),
    .resp_rdata  (clint_resp_rdata),
    .resp_valid  (clint_resp_valid),
    .read_data   (clint_read_data),
    .timer_irq   (clint_timer_irq)
);

// PLIC wires - MMIO bypass (no grant needed)
wire        plic_req_valid = addr_is_plic_m1 && m1_mmio_req;
wire [31:0] plic_resp_rdata;
wire        plic_resp_valid;
wire [31:0] plic_read_data;
wire        plic_ext_irq;

plic u_plic (
    .clk         (clk),
    .rstn        (rstn),
    .req_valid   (plic_req_valid),
    .req_addr    (m1_req_addr),
    .req_wen     (m1_req_write),
    .req_wdata   (m1_req_wdata),
    .resp_rdata  (plic_resp_rdata),
    .resp_valid  (plic_resp_valid),
    .read_data   (plic_read_data),
    .ext_irq_src (ext_irq_src),
    .external_irq(plic_ext_irq)
);

assign ext_timer_irq    = clint_timer_irq;
assign ext_external_irq = plic_ext_irq;

// ═════════════════════════════════════════════════════════════════════════════
// UART MMIO (TXDATA/STATUS/RXDATA/CTRL) – same register map as legacy_mem_subsys
// ═════════════════════════════════════════════════════════════════════════════

`ifdef FPGA_MODE
    `ifdef FULL_GATE_FAST_UART
localparam integer UART_CLK_DIV = 4;
    `else
        `ifndef FPGA_UART_CLK_DIV
            `define FPGA_UART_CLK_DIV 174
        `endif
localparam integer UART_CLK_DIV = `FPGA_UART_CLK_DIV;
    `endif
`else
localparam integer UART_CLK_DIV = 4;
`endif

reg        uart_tx_start_r;
reg [7:0]  uart_tx_data_r;
reg        uart_tx_launch_valid_r;
reg        uart_pending_valid_r;
reg [7:0]  uart_pending_byte_r;
reg        uart_tx_enable_r;
reg        uart_rx_enable_r;
reg        uart_rx_overrun_r;
reg        uart_rx_frame_err_r;
localparam integer UART_RX_FIFO_DEPTH = 8;
localparam integer UART_RX_FIFO_PTR_W = 3;
// Keep the RX FIFO in discrete registers. The benchmark loader exercises a
// sustained push/pop pattern on FPGA, and LUTRAM-style async read inference
// can introduce board-only read-during-write ambiguity that does not show up
// in RTL simulation.
(* ram_style = "registers", shreg_extract = "no" *) reg [7:0] uart_rx_fifo [0:UART_RX_FIFO_DEPTH-1];
reg [UART_RX_FIFO_PTR_W-1:0] uart_rx_head_r;
reg [UART_RX_FIFO_PTR_W-1:0] uart_rx_tail_r;
reg [UART_RX_FIFO_PTR_W:0]   uart_rx_count_r;
reg [7:0]  debug_uart_status_load_count_r;
reg [7:0]  debug_uart_tx_store_count_r;
reg [7:0]  debug_uart_tx_write_count_r;
reg        debug_uart_tx_write_seen_r;
`ifdef VERILATOR_MAINLINE
reg        verilator_uart_tx_fire_r;
reg [7:0]  verilator_uart_tx_byte_r;
`endif
wire       uart_busy;
wire       uart_status_busy;
wire       uart_rx_byte_valid;
wire [7:0] uart_rx_byte;
wire       uart_rx_frame_error;
wire       uart_rx_serial_byte_valid;
wire [7:0] uart_rx_serial_byte;
wire       uart_rx_serial_frame_error;
wire       uart_stage_pending_byte;
wire       uart_stage_beacon_byte;
wire [7:0] uart_stage_byte_w;
wire       debug_beacon_evt_write;
wire [7:0] debug_beacon_evt_type_req_w;
wire [7:0] debug_beacon_evt_arg_req_w;
wire       debug_beacon_byte_valid_w;
wire       debug_beacon_byte_ready_w;
wire [7:0] debug_beacon_byte_w;
reg        debug_beacon_req_valid_r;
reg [7:0]  debug_beacon_req_type_r;
reg [7:0]  debug_beacon_req_arg_r;
reg        debug_beacon_evt_pending_r;
reg [7:0]  debug_beacon_evt_type_r;
reg [7:0]  debug_beacon_evt_arg_r;
reg        debug_beacon_resp_valid_r;
reg [31:0] debug_beacon_resp_data_r;
`ifdef TRANSPORT_UART_RXDATA_REG_TEST
reg        uart_rx_mmio_resp_valid_r;
reg [31:0] uart_rx_mmio_resp_data_r;
reg        uart_rx_mmio_pending_r;
reg [7:0]  uart_rx_mmio_pending_byte_r;
`endif

assign uart_status_busy =
`ifdef VERILATOR_MAINLINE
                        1'b0
`else
                        uart_busy || uart_pending_valid_r || uart_tx_launch_valid_r || uart_tx_start_r
`ifdef AX7203_STEP2_BEACON_DEBUG
                        || debug_beacon_byte_valid_w
`elsif AX7203_DDR3_LOADER_BEACON_DEBUG
                        || debug_beacon_byte_valid_w
`endif
`endif
                        ;
wire       uart_rx_valid_w = (uart_rx_count_r != 0);
wire       uart_rx_fifo_full_w = (uart_rx_count_r == UART_RX_FIFO_DEPTH);
wire [7:0] uart_rx_head_data = uart_rx_fifo[uart_rx_head_r];

wire [31:0] uart_status_word = {
    25'd0,
    uart_tx_enable_r,
    uart_rx_enable_r,
    uart_rx_frame_err_r,
    uart_rx_overrun_r,
    uart_rx_valid_w,
    (~uart_status_busy && uart_tx_enable_r),
    uart_status_busy
};
wire [31:0] uart_ctrl_word = {29'd0, uart_rx_valid_w, uart_rx_enable_r, uart_tx_enable_r};

// UART write byte extraction: pick the first non-zero byte lane
function [7:0] select_mmio_byte;
    input [7:0] current_value;
    input [31:0] new_word;
    input [3:0]  byte_en;
    begin
        select_mmio_byte = current_value;
        if (byte_en[0]) select_mmio_byte = new_word[7:0];
        else if (byte_en[1]) select_mmio_byte = new_word[15:8];
        else if (byte_en[2]) select_mmio_byte = new_word[23:16];
        else if (byte_en[3]) select_mmio_byte = new_word[31:24];
    end
endfunction

// UART request decode from M1 MMIO path
wire uart_tx_write  = m1_mmio_req && addr_is_uart_tx_m1 && m1_req_write;
wire uart_ctrl_write = m1_mmio_req && addr_is_uart_ctrl_m1 && m1_req_write;
wire uart_rx_read   = m1_mmio_req && addr_is_uart_rx_m1 && !m1_req_write;
assign debug_beacon_evt_write = m1_mmio_req && addr_is_debug_beacon_evt_m1 && m1_req_write;
wire [7:0] uart_write_byte = select_mmio_byte(8'd0, m1_req_wdata, m1_req_wen);
wire [7:0] uart_ctrl_write_byte = select_mmio_byte(8'd0, m1_req_wdata, m1_req_wen);
assign debug_beacon_evt_type_req_w = select_mmio_byte(8'd0, m1_req_wdata, m1_req_wen);
assign debug_beacon_evt_arg_req_w = m1_req_wdata[15:8];
wire uart_rx_fifo_clear = uart_ctrl_write && (!uart_ctrl_write_byte[1] || uart_ctrl_write_byte[4]);
wire uart_rx_read_fire = uart_rx_read && uart_rx_valid_w;
wire uart_rx_push_fire = uart_rx_byte_valid && (!uart_rx_fifo_full_w || uart_rx_read_fire);
wire uart_store_accept = uart_tx_write && uart_tx_ready_w;
wire debug_beacon_evt_accept_w = debug_beacon_evt_write && m1_req_ready;
assign debug_beacon_byte_ready_w = uart_tx_enable_r && !uart_busy && !uart_pending_valid_r && !uart_tx_launch_valid_r && !uart_store_accept;
assign uart_stage_pending_byte = uart_pending_valid_r && !uart_busy && !uart_tx_launch_valid_r;
assign uart_stage_beacon_byte = !uart_stage_pending_byte && debug_beacon_byte_valid_w && debug_beacon_byte_ready_w;
assign uart_stage_byte_w = uart_stage_pending_byte ? uart_pending_byte_r : debug_beacon_byte_w;
wire [7:0] debug_uart_flags = {
    uart_tx_write,
    uart_store_accept,
    uart_pending_valid_r,
    uart_busy,
    uart_status_busy,
    uart_tx_enable_r,
    m1_req_valid,
    m1_req_ready
};
`ifdef VERILATOR_MAINLINE
assign debug_uart_tx_byte_valid = verilator_uart_tx_fire_r || uart_tx_start_r;
assign debug_uart_tx_byte = verilator_uart_tx_fire_r ? verilator_uart_tx_byte_r : uart_tx_data_r;
`else
assign debug_uart_tx_byte_valid = uart_tx_start_r;
assign debug_uart_tx_byte = uart_tx_data_r;
`endif
assign debug_uart_status_load_count = debug_uart_status_load_count_r;
assign debug_uart_tx_store_count = debug_uart_tx_store_count_r;

uart_tx #(
    .CLK_DIV(UART_CLK_DIV)
) u_uart_tx (
    .clk      (clk            ),
    .rst_n    (rstn           ),
    .tx_start (uart_tx_start_r),
    .tx_data  (uart_tx_data_r ),
    .tx       (uart_tx        ),
    .busy     (uart_busy      )
);

uart_rx #(
    .CLK_DIV(UART_CLK_DIV)
) u_uart_rx (
    .clk         (clk                ),
    .rst_n       (rstn               ),
    .enable      (uart_rx_enable_r   ),
    .rx          (uart_rx            ),
    .byte_valid  (uart_rx_serial_byte_valid ),
    .byte_data   (uart_rx_serial_byte       ),
    .frame_error (uart_rx_serial_frame_error)
);

`ifdef VERILATOR_FAST_UART
assign uart_rx_byte_valid  = fast_uart_rx_byte_valid ? 1'b1 : uart_rx_serial_byte_valid;
assign uart_rx_byte        = fast_uart_rx_byte_valid ? fast_uart_rx_byte : uart_rx_serial_byte;
assign uart_rx_frame_error = uart_rx_serial_frame_error;
`else
assign uart_rx_byte_valid  = uart_rx_serial_byte_valid;
assign uart_rx_byte        = uart_rx_serial_byte;
assign uart_rx_frame_error = uart_rx_serial_frame_error;
`endif

`ifdef AX7203_STEP2_BEACON_DEBUG
debug_beacon_tx u_debug_beacon_tx (
    .clk       (clk                    ),
    .rstn      (rstn                   ),
    .evt_valid (debug_beacon_evt_pending_r),
    .evt_ready (debug_beacon_evt_ready_w),
    .evt_type  (debug_beacon_evt_type_r),
    .evt_arg   (debug_beacon_evt_arg_r ),
    .byte_valid(debug_beacon_byte_valid_w),
    .byte_ready(debug_beacon_byte_ready_w),
    .byte_data (debug_beacon_byte_w    )
);
`elsif AX7203_DDR3_LOADER_BEACON_DEBUG
debug_beacon_tx u_debug_beacon_tx (
    .clk       (clk                    ),
    .rstn      (rstn                   ),
    .evt_valid (debug_beacon_evt_pending_r),
    .evt_ready (debug_beacon_evt_ready_w),
    .evt_type  (debug_beacon_evt_type_r),
    .evt_arg   (debug_beacon_evt_arg_r ),
    .byte_valid(debug_beacon_byte_valid_w),
    .byte_ready(debug_beacon_byte_ready_w),
    .byte_data (debug_beacon_byte_w    )
);
`else
assign debug_beacon_evt_ready_w = 1'b1;
assign debug_beacon_byte_valid_w = 1'b0;
assign debug_beacon_byte_w = 8'd0;
`endif

// UART TX pending + RX control FSM
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        uart_tx_start_r      <= 1'b0;
        uart_tx_data_r       <= 8'd0;
        uart_tx_launch_valid_r <= 1'b0;
        uart_pending_valid_r <= 1'b0;
        uart_pending_byte_r  <= 8'd0;
        uart_tx_enable_r     <= 1'b1;
        uart_rx_enable_r     <= 1'b1;
        uart_rx_overrun_r    <= 1'b0;
        uart_rx_frame_err_r  <= 1'b0;
        uart_rx_head_r       <= {UART_RX_FIFO_PTR_W{1'b0}};
        uart_rx_tail_r       <= {UART_RX_FIFO_PTR_W{1'b0}};
        uart_rx_count_r      <= {(UART_RX_FIFO_PTR_W+1){1'b0}};
        m1_mmio_inflight_r   <= 1'b0;
        debug_beacon_req_valid_r <= 1'b0;
        debug_beacon_req_type_r <= 8'd0;
        debug_beacon_req_arg_r <= 8'd0;
        debug_beacon_evt_pending_r <= 1'b0;
        debug_beacon_evt_type_r <= 8'd0;
        debug_beacon_evt_arg_r <= 8'd0;
        debug_beacon_resp_valid_r <= 1'b0;
        debug_beacon_resp_data_r <= 32'd0;
        debug_uart_status_load_count_r <= 8'd0;
        debug_uart_tx_store_count_r <= 8'd0;
        debug_uart_tx_write_count_r <= 8'd0;
        debug_uart_tx_write_seen_r <= 1'b0;
`ifdef VERILATOR_MAINLINE
        verilator_uart_tx_fire_r <= 1'b0;
        verilator_uart_tx_byte_r <= 8'd0;
`endif
`ifdef TRANSPORT_UART_RXDATA_REG_TEST
        uart_rx_mmio_resp_valid_r <= 1'b0;
        uart_rx_mmio_resp_data_r <= 32'd0;
        uart_rx_mmio_pending_r <= 1'b0;
        uart_rx_mmio_pending_byte_r <= 8'd0;
`endif
    end else begin
        uart_tx_start_r <= 1'b0;
        debug_uart_tx_write_seen_r <= uart_tx_write;
`ifdef VERILATOR_MAINLINE
        verilator_uart_tx_fire_r <= 1'b0;
`endif
        debug_beacon_resp_valid_r <= 1'b0;
`ifdef TRANSPORT_UART_RXDATA_REG_TEST
        uart_rx_mmio_resp_valid_r <= 1'b0;
        if (uart_rx_mmio_pending_r) begin
            uart_rx_mmio_resp_valid_r <= 1'b1;
            uart_rx_mmio_resp_data_r <= {24'd0, uart_rx_mmio_pending_byte_r};
            uart_rx_mmio_pending_r <= 1'b0;
        end
`endif
        if (m1_mmio_inflight_r) begin
`ifdef TRANSPORT_UART_RXDATA_REG_TEST
            if (mmio_resp_valid_r || debug_beacon_resp_valid_r || uart_rx_mmio_resp_valid_r) begin
`else
            if (mmio_resp_valid_r || debug_beacon_resp_valid_r) begin
`endif
                m1_mmio_inflight_r <= 1'b0;
            end
        end else if (m1_mmio_req && m1_mmio_ready_core) begin
            m1_mmio_inflight_r <= 1'b1;
        end
        if (debug_beacon_req_valid_r && !debug_beacon_evt_pending_r) begin
            debug_beacon_evt_pending_r <= 1'b1;
            debug_beacon_evt_type_r <= debug_beacon_req_type_r;
            debug_beacon_evt_arg_r <= debug_beacon_req_arg_r;
            debug_beacon_req_valid_r <= 1'b0;
            debug_beacon_resp_valid_r <= 1'b1;
            debug_beacon_resp_data_r <= 32'd0;
        end
        if (debug_beacon_evt_pending_r && debug_beacon_evt_ready_w) begin
            debug_beacon_evt_pending_r <= 1'b0;
        end
        if (debug_beacon_evt_accept_w) begin
            debug_beacon_req_valid_r <= 1'b1;
            debug_beacon_req_type_r <= debug_beacon_evt_type_req_w;
            debug_beacon_req_arg_r <= debug_beacon_evt_arg_req_w;
        end
        // synthesis translate_off
        if (debug_beacon_evt_accept_w) begin
            $display("[DBG_EVT_REQ] t=%0t ready=%0d inflight=%0d wen=%h wdata=%08x type=%02x arg=%02x",
                     $time, m1_req_ready, m1_mmio_inflight_r, m1_req_wen, m1_req_wdata,
                     debug_beacon_evt_type_req_w, debug_beacon_evt_arg_req_w);
        end
        if (debug_beacon_req_valid_r && !debug_beacon_evt_pending_r) begin
            $display("[DBG_EVT_STAGE] t=%0t type=%02x arg=%02x",
                     $time, debug_beacon_req_type_r, debug_beacon_req_arg_r);
        end
        if (debug_beacon_evt_pending_r && debug_beacon_evt_ready_w) begin
            $display("[DBG_EVT_TX] t=%0t type=%02x arg=%02x",
                     $time, debug_beacon_evt_type_r, debug_beacon_evt_arg_r);
        end
        if (debug_beacon_resp_valid_r) begin
            $display("[DBG_EVT_RESP] t=%0t data=%08x",
                     $time, debug_beacon_resp_data_r);
        end
        // synthesis translate_on

        // TX: accept store into pending register
        if (uart_store_accept) begin
`ifdef VERILATOR_MAINLINE
            verilator_uart_tx_fire_r <= 1'b1;
            verilator_uart_tx_byte_r <= uart_write_byte;
`else
            uart_pending_byte_r  <= uart_write_byte;
            uart_pending_valid_r <= 1'b1;
`endif
            debug_uart_tx_store_count_r <= debug_uart_tx_store_count_r + 8'd1;
        end

        if (m1_mmio_req && m1_req_ready && addr_is_uart_status_m1 && !m1_req_write)
            debug_uart_status_load_count_r <= debug_uart_status_load_count_r + 8'd1;

        if (uart_tx_write && !debug_uart_tx_write_seen_r)
            debug_uart_tx_write_count_r <= debug_uart_tx_write_count_r + 8'd1;

        // TX: first stage the byte into a local launch register, then pulse
        // tx_start on the following cycle so the serializer samples stable
        // tx_data instead of a same-edge update.
        if (uart_tx_launch_valid_r && !uart_busy) begin
            uart_tx_start_r <= 1'b1;
            uart_tx_launch_valid_r <= 1'b0;
        end else if (uart_stage_pending_byte || uart_stage_beacon_byte) begin
            uart_tx_data_r <= uart_stage_byte_w;
            uart_tx_launch_valid_r <= 1'b1;
            if (uart_stage_pending_byte) begin
                uart_pending_valid_r <= 1'b0;
            end
        end

        // CTRL register write
        if (uart_ctrl_write) begin
            uart_tx_enable_r <= uart_ctrl_write_byte[0];
            uart_rx_enable_r <= uart_ctrl_write_byte[1];
            if (uart_ctrl_write_byte[2]) uart_rx_overrun_r   <= 1'b0;
            if (uart_ctrl_write_byte[3]) uart_rx_frame_err_r <= 1'b0;
        end

        if (uart_rx_fifo_clear) begin
            uart_rx_head_r  <= {UART_RX_FIFO_PTR_W{1'b0}};
            uart_rx_tail_r  <= {UART_RX_FIFO_PTR_W{1'b0}};
            uart_rx_count_r <= {(UART_RX_FIFO_PTR_W+1){1'b0}};
        end

        // RX frame error latch
        if (uart_rx_frame_error) begin
            uart_rx_frame_err_r <= 1'b1;
        end

`ifdef TRANSPORT_UART_RXDATA_REG_TEST
        // Capture the byte that is actually dequeued from the RX FIFO and
        // return it on the following cycle. This avoids observing a changing
        // FIFO head through the MMIO response mux on FPGA.
        if (uart_rx_read_fire) begin
            uart_rx_mmio_pending_r <= 1'b1;
            uart_rx_mmio_pending_byte_r <= uart_rx_head_data;
        end
`endif

        if (!uart_rx_fifo_clear) begin
            if (uart_rx_byte_valid && !uart_rx_push_fire) begin
                uart_rx_overrun_r <= 1'b1;
            end

            case ({uart_rx_read_fire, uart_rx_push_fire})
                2'b10: begin
                    uart_rx_head_r  <= uart_rx_head_r + {{(UART_RX_FIFO_PTR_W-1){1'b0}}, 1'b1};
                    uart_rx_count_r <= uart_rx_count_r - {{UART_RX_FIFO_PTR_W{1'b0}}, 1'b1};
                end
                2'b01: begin
                    uart_rx_fifo[uart_rx_tail_r] <= uart_rx_byte;
                    uart_rx_tail_r <= uart_rx_tail_r + {{(UART_RX_FIFO_PTR_W-1){1'b0}}, 1'b1};
                    uart_rx_count_r <= uart_rx_count_r + {{UART_RX_FIFO_PTR_W{1'b0}}, 1'b1};
                end
                2'b11: begin
                    uart_rx_fifo[uart_rx_tail_r] <= uart_rx_byte;
                    uart_rx_head_r <= uart_rx_head_r + {{(UART_RX_FIFO_PTR_W-1){1'b0}}, 1'b1};
                    uart_rx_tail_r <= uart_rx_tail_r + {{(UART_RX_FIFO_PTR_W-1){1'b0}}, 1'b1};
                end
                default: begin
                end
            endcase
        end
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// M1 Response Mux (MMIO bypass takes priority over cached L2 path)
// ═════════════════════════════════════════════════════════════════════════════

wire        m1_resp_valid_int;
wire [31:0] m1_resp_data_int;
reg         mmio_resp_valid_r;
reg  [31:0] mmio_resp_data_r;

// Handle TUBE + UART MMIO - deterministic bypass
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        tube_status <= 8'd0;
        mmio_resp_valid_r <= 1'b0;
        mmio_resp_data_r  <= 32'd0;
    end else begin
        mmio_resp_valid_r <= 1'b0;
        if (addr_is_tube_m1 && m1_mmio_req && m1_req_write) begin
            tube_status <= m1_req_wdata[7:0];
        end
        if (m1_mmio_req && m1_req_ready) begin
            if (addr_is_tube_m1 && !m1_req_write) begin
                mmio_resp_valid_r <= 1'b1;
                mmio_resp_data_r <= {24'd0, tube_status};
            end else if (addr_is_clint_m1) begin
                mmio_resp_valid_r <= 1'b1;
                mmio_resp_data_r <= m1_req_write ? 32'd0 : clint_read_data;
            end else if (addr_is_plic_m1) begin
                mmio_resp_valid_r <= 1'b1;
                mmio_resp_data_r <= m1_req_write ? 32'd0 : plic_read_data;
            end else if (addr_is_uart_status_m1 && !m1_req_write) begin
                mmio_resp_valid_r <= 1'b1;
                mmio_resp_data_r <= uart_status_word;
            end else if (addr_is_uart_rx_m1 && !m1_req_write) begin
`ifdef TRANSPORT_UART_RXDATA_REG_TEST
                mmio_resp_valid_r <= 1'b0;
                mmio_resp_data_r <= 32'd0;
`else
                mmio_resp_valid_r <= 1'b1;
                mmio_resp_data_r <= {24'd0, uart_rx_head_data};
`endif
            end else if (addr_is_uart_ctrl_m1 && !m1_req_write) begin
                mmio_resp_valid_r <= 1'b1;
                mmio_resp_data_r <= uart_ctrl_word;
`ifdef ENABLE_DDR3
            end else if (addr_is_ddr3_status_m1 && !m1_req_write) begin
                mmio_resp_valid_r <= 1'b1;
                mmio_resp_data_r <= ddr3_status_word;
            end else if (addr_is_debug_beacon_evt_m1 && m1_req_write) begin
                mmio_resp_valid_r <= 1'b0;
                mmio_resp_data_r <= 32'd0;
`endif
            end else begin
                mmio_resp_valid_r <= 1'b1;
                mmio_resp_data_r <= 32'd0;
            end
        end
    end
end

// Response mux - MMIO returns a registered single-cycle response so LSU_REQ can
// handshake the request first and then observe the completion in LSU_WAIT_RESP.
`ifdef ENABLE_DDR3
`ifdef TRANSPORT_UART_RXDATA_REG_TEST
assign m1_resp_valid = uart_rx_mmio_resp_valid_r ? 1'b1
                    : debug_beacon_resp_valid_r ? 1'b1
                    : mmio_resp_valid_r ? 1'b1
                    : m1_ddr3_resp_valid ? 1'b1
                    : m1_resp_valid_int;
assign m1_resp_data  = uart_rx_mmio_resp_valid_r ? uart_rx_mmio_resp_data_r
                    : debug_beacon_resp_valid_r ? debug_beacon_resp_data_r
                    : mmio_resp_valid_r ? mmio_resp_data_r
                    : m1_ddr3_resp_valid ? m1_ddr3_resp_data
                    : m1_resp_data_int;
`else
assign m1_resp_valid = debug_beacon_resp_valid_r ? 1'b1
                    : mmio_resp_valid_r ? 1'b1
                    : m1_ddr3_resp_valid ? 1'b1
                    : m1_resp_valid_int;
assign m1_resp_data  = debug_beacon_resp_valid_r ? debug_beacon_resp_data_r
                    : mmio_resp_valid_r ? mmio_resp_data_r
                    : m1_ddr3_resp_valid ? m1_ddr3_resp_data
                    : m1_resp_data_int;
`endif
`else
`ifdef TRANSPORT_UART_RXDATA_REG_TEST
assign m1_resp_valid = uart_rx_mmio_resp_valid_r ? 1'b1 : debug_beacon_resp_valid_r ? 1'b1 : mmio_resp_valid_r ? 1'b1 : m1_resp_valid_int;
assign m1_resp_data  = uart_rx_mmio_resp_valid_r ? uart_rx_mmio_resp_data_r : debug_beacon_resp_valid_r ? debug_beacon_resp_data_r : mmio_resp_valid_r ? mmio_resp_data_r : m1_resp_data_int;
`else
assign m1_resp_valid = debug_beacon_resp_valid_r ? 1'b1 : mmio_resp_valid_r ? 1'b1 : m1_resp_valid_int;
assign m1_resp_data  = debug_beacon_resp_valid_r ? debug_beacon_resp_data_r : mmio_resp_valid_r ? mmio_resp_data_r : m1_resp_data_int;
`endif
`endif

// ═════════════════════════════════════════════════════════════════════════════
// DDR3 External Port Assignments
// ═════════════════════════════════════════════════════════════════════════════
`ifdef ENABLE_DDR3
localparam DDR3_ARB_IDLE      = 2'd0;
localparam DDR3_ARB_M0_SEND   = 2'd1;
localparam DDR3_ARB_WAIT_RESP = 2'd2;

localparam DDR3_OWNER_M0 = 1'b0;
localparam DDR3_OWNER_M1 = 1'b1;

reg [1:0]  ddr3_arb_state;
reg        ddr3_owner_r;
reg        ddr3_last_owner_r;
reg [2:0]  ddr3_m0_word_idx_r;
reg [31:0] ddr3_m0_line_base_r;

reg        ddr3_req_valid_r;
reg [31:0] ddr3_req_addr_r;
reg        ddr3_req_write_r;
reg [31:0] ddr3_req_wdata_r;
reg [3:0]  ddr3_req_wen_r;
reg        m0_ddr3_req_ready_r;
reg        m0_ddr3_resp_valid_r;
reg [31:0] m0_ddr3_resp_data_r;
reg        m0_ddr3_resp_last_r;
reg        m1_ddr3_req_ready_r;
reg        m1_ddr3_resp_valid_r;
reg [31:0] m1_ddr3_resp_data_r;
reg        debug_m0_req_seen_r;
reg [7:0]  debug_m0_req_count_r;
reg [7:0]  debug_m0_accept_count_r;
reg [7:0]  debug_m0_resp_count_r;
reg [7:0]  debug_m0_last_count_r;
reg [31:0] debug_m0_last_req_addr_r;
reg [31:0] debug_m0_last_resp_data_r;
reg [7:0]  debug_m1_accept_count_r;

wire ddr3_select_m0 = m0_ddr3_req && (!m1_ddr3_req || ddr3_last_owner_r == DDR3_OWNER_M1);
wire ddr3_select_m1 = m1_ddr3_req && (!m0_ddr3_req || ddr3_last_owner_r == DDR3_OWNER_M0);
wire [7:0] debug_m0_flags = {
    ddr3_arb_state,
    ddr3_owner_r,
    ddr3_m0_word_idx_r,
    ddr3_req_valid_r,
    ddr3_req_ready
};
assign ddr3_bridge_idle_w = (ddr3_arb_state == DDR3_ARB_IDLE) && !ddr3_req_valid_r;

assign ddr3_req_valid = ddr3_req_valid_r;
assign ddr3_req_addr  = ddr3_req_addr_r;
assign ddr3_req_write = ddr3_req_write_r;
assign ddr3_req_wdata = ddr3_req_wdata_r;
assign ddr3_req_wen   = ddr3_req_wen_r;

assign m0_ddr3_req_ready  = m0_ddr3_req_ready_r;
assign m0_ddr3_resp_valid = m0_ddr3_resp_valid_r;
assign m0_ddr3_resp_data  = m0_ddr3_resp_data_r;
assign m0_ddr3_resp_last  = m0_ddr3_resp_last_r;
assign m1_ddr3_req_ready  = m1_ddr3_req_ready_r;
assign m1_ddr3_resp_valid = m1_ddr3_resp_valid_r;
assign m1_ddr3_resp_data  = m1_ddr3_resp_data_r;
assign debug_ddr3_m0_bus = {
    debug_uart_flags,
    debug_uart_tx_write_count_r,
    debug_m1_accept_count_r,
    debug_m0_flags,
    debug_m0_last_resp_data_r,
    debug_m0_last_req_addr_r,
    debug_m0_last_count_r,
    debug_m0_resp_count_r,
    debug_m0_accept_count_r,
    debug_m0_req_count_r
};

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ddr3_arb_state        <= DDR3_ARB_IDLE;
        ddr3_owner_r          <= DDR3_OWNER_M0;
        ddr3_last_owner_r     <= DDR3_OWNER_M1;
        ddr3_m0_word_idx_r    <= 3'd0;
        ddr3_m0_line_base_r   <= 32'd0;
        ddr3_req_valid_r      <= 1'b0;
        ddr3_req_addr_r       <= 32'd0;
        ddr3_req_write_r      <= 1'b0;
        ddr3_req_wdata_r      <= 32'd0;
        ddr3_req_wen_r        <= 4'd0;
        m0_ddr3_req_ready_r   <= 1'b0;
        m0_ddr3_resp_valid_r  <= 1'b0;
        m0_ddr3_resp_data_r   <= 32'd0;
        m0_ddr3_resp_last_r   <= 1'b0;
        m1_ddr3_req_ready_r   <= 1'b0;
        m1_ddr3_resp_valid_r  <= 1'b0;
        m1_ddr3_resp_data_r   <= 32'd0;
        debug_m0_req_seen_r       <= 1'b0;
        debug_m0_req_count_r      <= 8'd0;
        debug_m0_accept_count_r   <= 8'd0;
        debug_m0_resp_count_r     <= 8'd0;
        debug_m0_last_count_r     <= 8'd0;
        debug_m0_last_req_addr_r  <= 32'd0;
        debug_m0_last_resp_data_r <= 32'd0;
        debug_m1_accept_count_r   <= 8'd0;
    end else begin
        m0_ddr3_req_ready_r  <= 1'b0;
        m0_ddr3_resp_valid_r <= 1'b0;
        m0_ddr3_resp_last_r  <= 1'b0;
        m1_ddr3_req_ready_r  <= 1'b0;
        m1_ddr3_resp_valid_r <= 1'b0;
        debug_m0_req_seen_r  <= m0_ddr3_req;

        if (m0_ddr3_req && !debug_m0_req_seen_r) begin
            debug_m0_req_count_r     <= debug_m0_req_count_r + 8'd1;
            debug_m0_last_req_addr_r <= m0_req_addr;
        end

        case (ddr3_arb_state)
            DDR3_ARB_IDLE: begin
                ddr3_req_valid_r <= 1'b0;
                if (ddr3_select_m0) begin
                    ddr3_owner_r        <= DDR3_OWNER_M0;
                    ddr3_m0_word_idx_r  <= 3'd0;
                    ddr3_m0_line_base_r <= {2'b0, m0_req_addr[29:5], 5'b0};
                    ddr3_req_addr_r     <= {2'b0, m0_req_addr[29:5], 5'b0};
                    ddr3_req_write_r    <= 1'b0;
                    ddr3_req_wdata_r    <= 32'd0;
                    ddr3_req_wen_r      <= 4'd0;
                    ddr3_arb_state      <= DDR3_ARB_M0_SEND;
                end else if (ddr3_select_m1) begin
                    ddr3_owner_r        <= DDR3_OWNER_M1;
                    ddr3_req_addr_r     <= {2'b0, m1_req_addr[29:0]};
                    ddr3_req_write_r    <= m1_req_write;
                    ddr3_req_wdata_r    <= m1_req_wdata;
                    ddr3_req_wen_r      <= m1_req_wen;
                    ddr3_arb_state      <= DDR3_ARB_M0_SEND;
                end
            end

            DDR3_ARB_M0_SEND: begin
                if (!ddr3_req_valid_r) begin
                    ddr3_req_valid_r <= 1'b1;
                    if (ddr3_owner_r == DDR3_OWNER_M0) begin
                        ddr3_req_addr_r  <= ddr3_m0_line_base_r + {27'd0, ddr3_m0_word_idx_r, 2'b00};
                        ddr3_req_write_r <= 1'b0;
                        ddr3_req_wdata_r <= 32'd0;
                        ddr3_req_wen_r   <= 4'd0;
                    end
                end else if (ddr3_req_ready) begin
                    ddr3_req_valid_r <= 1'b0;
                    if (ddr3_owner_r == DDR3_OWNER_M0 && ddr3_m0_word_idx_r == 3'd0) begin
                        m0_ddr3_req_ready_r <= 1'b1;
                        debug_m0_accept_count_r <= debug_m0_accept_count_r + 8'd1;
                    end else if (ddr3_owner_r == DDR3_OWNER_M1) begin
                        m1_ddr3_req_ready_r <= 1'b1;
                        debug_m1_accept_count_r <= debug_m1_accept_count_r + 8'd1;
                    end
                    ddr3_arb_state <= DDR3_ARB_WAIT_RESP;
                end
            end

            DDR3_ARB_WAIT_RESP: begin
                ddr3_req_valid_r <= 1'b0;
                if (ddr3_resp_valid) begin
                    if (ddr3_owner_r == DDR3_OWNER_M0) begin
                        m0_ddr3_resp_valid_r <= 1'b1;
                        m0_ddr3_resp_data_r  <= ddr3_resp_data;
                        m0_ddr3_resp_last_r  <= (ddr3_m0_word_idx_r == 3'd7);
                        debug_m0_resp_count_r <= debug_m0_resp_count_r + 8'd1;
                        debug_m0_last_resp_data_r <= ddr3_resp_data;
                        if (ddr3_m0_word_idx_r == 3'd7) begin
                            debug_m0_last_count_r <= debug_m0_last_count_r + 8'd1;
                            ddr3_last_owner_r <= DDR3_OWNER_M0;
                            ddr3_arb_state    <= DDR3_ARB_IDLE;
                        end else begin
                            ddr3_m0_word_idx_r <= ddr3_m0_word_idx_r + 3'd1;
                            ddr3_arb_state     <= DDR3_ARB_M0_SEND;
                        end
                    end else begin
                        m1_ddr3_resp_valid_r <= 1'b1;
                        m1_ddr3_resp_data_r  <= ddr3_resp_data;
                        ddr3_last_owner_r    <= DDR3_OWNER_M1;
                        ddr3_arb_state       <= DDR3_ARB_IDLE;
                    end
                end
            end

            default: begin
                ddr3_arb_state   <= DDR3_ARB_IDLE;
                ddr3_req_valid_r <= 1'b0;
            end
        endcase
    end
end
`endif

// ═════════════════════════════════════════════════════════════════════════════
// RAM Preload Interface (for testbench)
// Testbench can access ram[] array directly via hierarchical reference
// ═════════════════════════════════════════════════════════════════════════════

`ifndef ENABLE_DDR3
assign debug_ddr3_m0_bus = 128'd0;
`endif

endmodule
