// =============================================================================
// Module : adam_riscv_ax7203_top
// Description: AX7203 FPGA Top-Level Wrapper for AdamRISC-V Processor
//   Target Board: ALINX AX7203 (XC7A200T-2FBG484I)
//   Clock: 200MHz differential (SiT9102-200.00MHz)
//
//   This module provides the board-specific wrapper that:
//   - Accepts 200MHz differential system clock (R4/T4)
//   - Instantiates clock wizard to generate core clock (20MHz)
//   - Handles reset synchronization
//   - Exposes UART TX/RX for CP2102 USB-UART bridge
//   - Routes the core's MMIO UART TX to the CP2102 bridge
//   - Stretches UART TX edges onto LED[4] for visible board debug
//   - Instantiates adam_riscv core with FPGA_MODE enabled
// =============================================================================

`ifndef FPGA_MODE
    `define FPGA_MODE 1
`endif

module adam_riscv_ax7203_top (
    input  wire sys_clk_p,      // 200MHz differential P (Pin R4, Bank 34)
    input  wire sys_clk_n,      // 200MHz differential N (Pin T4, Bank 34)
    input  wire sys_rst_n,      // Active-low reset (Pin T6)
    // UART (CP2102 USB-UART bridge)
    output wire uart_tx,        // FPGA TX -> PC RX (Pin N15)
    input  wire uart_rx,        // FPGA RX <- PC TX (Pin P20)
    // LEDs for debug
    output wire [4:0] led       // Active-low LEDs: core-board LED plus ext LED1-4

`ifdef ENABLE_DDR3
    ,
    // ═══════════════════════════════════════════════════════════════════════
    // DDR3 SDRAM physical interface (2x MT41K256M16HA-125, 32-bit bus)
    // ═══════════════════════════════════════════════════════════════════════
    inout  wire [31:0] ddr3_dq,
    inout  wire [3:0]  ddr3_dqs_p,
    inout  wire [3:0]  ddr3_dqs_n,
    output wire [14:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_ck_p,
    output wire        ddr3_ck_n,
    output wire        ddr3_cke,
    output wire        ddr3_reset_n,
    output wire [3:0]  ddr3_dm,
    output wire        ddr3_odt,
    output wire        ddr3_cs_n
`endif
);

// =============================================================================
// Clock Generation
// =============================================================================

// Differential clock input buffer
wire sys_clk_200m;

IBUFGDS clk_ibufgds (
    .O  (sys_clk_200m),
    .I  (sys_clk_p   ),
    .IB (sys_clk_n   )
);

// Note: clk_wiz_0 is instantiated inside adam_riscv when FPGA_MODE is defined
// We use sys_clk_200m directly; the core handles clock generation internally

// =============================================================================
// Power-on Reset Generator
// =============================================================================
// Internal reset since external reset pin has routing issues
reg [15:0] por_cnt;
reg por_rst_n;
wire core_rst_n;

always @(posedge sys_clk_200m) begin
    if (por_cnt != 16'hFFFF) begin
        por_cnt <= por_cnt + 1;
        por_rst_n <= 1'b0;
    end else begin
        por_rst_n <= 1'b1;
    end
end

initial begin
    por_cnt = 0;
    por_rst_n = 0;
end

// The AX7203 reset push-button routing has been unreliable during bring-up.
// Keep the core release deterministic by using the internal POR window only;
// we still constrain the pad, but we do not let an unstable external reset
// pin hold the processor in reset on every configuration cycle.
assign core_rst_n = por_rst_n;

// =============================================================================
// Core Instantiation
// =============================================================================

// Core LED outputs (kept wired for compatibility even though the board wrapper
// currently drives the user LEDs with more explicit bring-up status signals).
wire [2:0] core_led;

// Tube status for debug observation
wire [7:0] tube_status;
wire core_uart_tx;
wire core_clk_dbg;
wire core_ready;
wire core_retire_seen;
wire       core_uart_byte_valid_dbg;
wire [7:0] core_uart_byte_dbg;
wire       core_uart_frame_seen;
wire [3:0] core_uart_frame_count;
wire [7:0] core_uart_frame_count_rolling;
wire       core_uart_byte_valid;
wire [7:0] core_uart_byte;
wire       board_uart_tx;
wire       board_uart_busy;
reg        board_tx_start;
reg [7:0]  board_tx_data;
reg        board_pending_valid;
reg [7:0]  board_pending_byte;

// The core has FPGA_MODE defined internally, which causes it to:
// 1. Instantiate clk_wiz_0 to convert sys_clk (200MHz) to core clock
// 2. Instantiate syn_rst for reset synchronization
// We pass the raw 200MHz clock and external reset to the core.
(* DONT_TOUCH = "TRUE", KEEP_HIERARCHY = "TRUE" *)
adam_riscv u_adam_riscv (
    .sys_clk   (sys_clk_200m),  // 200MHz from IBUFGDS (core has clk_wiz_0 inside)
    .sys_rstn  (core_rst_n  ),  // POR-gated active-low reset into the core
    .uart_rx   (uart_rx     ),
    .ext_irq_src (1'b0      ),  // External interrupt - tied low for now
    .led       (core_led    ),  // FPGA_MODE exposes this port
    .tube_status (tube_status),
    .uart_tx   (core_uart_tx),
    .debug_core_ready(core_ready),
    .debug_core_clk(core_clk_dbg),
    .debug_retire_seen(core_retire_seen),
    .debug_uart_tx_byte_valid(core_uart_byte_valid_dbg),
    .debug_uart_tx_byte(core_uart_byte_dbg)
`ifdef ENABLE_DDR3
    ,
    .ddr3_req_valid  (core_ddr3_req_valid),
    .ddr3_req_ready  (core_ddr3_req_ready),
    .ddr3_req_addr   (core_ddr3_req_addr),
    .ddr3_req_write  (core_ddr3_req_write),
    .ddr3_req_wdata  (core_ddr3_req_wdata),
    .ddr3_req_wen    (core_ddr3_req_wen),
    .ddr3_resp_valid (core_ddr3_resp_valid),
    .ddr3_resp_data  (core_ddr3_resp_data),
    .ddr3_init_calib_complete (mig_init_calib_complete)
`endif
);

uart_tx #(
    .CLK_DIV(1736)
) u_board_uart_tx (
    .clk      (sys_clk_200m  ),
    .rst_n    (core_rst_n    ),
    .tx_start (board_tx_start),
    .tx_data  (board_tx_data ),
    .tx       (board_uart_tx ),
    .busy     (board_uart_busy)
);

uart_rx_monitor #(
    .CLK_DIV(1736)
) u_core_uart_monitor (
    .clk                (sys_clk_200m                ),
    .rst_n              (core_rst_n                  ),
    .rx                 (core_uart_tx                ),
    .frame_seen         (core_uart_frame_seen        ),
    .frame_count        (core_uart_frame_count       ),
    .frame_count_rolling(core_uart_frame_count_rolling),
    .byte_valid         (core_uart_byte_valid        ),
    .byte_data          (core_uart_byte              )
);

// =============================================================================
// UART Routing
// =============================================================================
// Re-serialize the core's byte-level MMIO UART events in the 200 MHz board
// wrapper. This keeps the CPU-visible UART semantics unchanged while avoiding
// a fragile serial-to-serial bridge on the physical board path.
assign uart_tx = board_uart_tx;

// UART RX now feeds the core MMIO UART receiver directly.

// =============================================================================
// Debug LED Output
// =============================================================================

// LED heartbeat to verify FPGA is running
reg [24:0] led_cnt;
reg led_blink;
reg [24:0] uart_led_hold_cnt;
reg uart_led_visible;
(* ASYNC_REG = "TRUE" *) reg [1:0] uart_tx_sync;
wire uart_tx_edge = uart_tx_sync[1] ^ uart_tx_sync[0];

always @(posedge sys_clk_200m or negedge core_rst_n) begin
    if (!core_rst_n) begin
        led_cnt <= 0;
        led_blink <= 0;
    end else begin
        if (led_cnt == 25'd19_999_999) begin  // ~100ms toggle at 200MHz
            led_cnt <= 0;
            led_blink <= ~led_blink;
        end else begin
            led_cnt <= led_cnt + 1;
        end
    end
end

always @(posedge sys_clk_200m or negedge core_rst_n) begin
    if (!core_rst_n) begin
        board_tx_start       <= 1'b0;
        board_tx_data        <= 8'd0;
        board_pending_valid  <= 1'b0;
        board_pending_byte   <= 8'd0;
        uart_tx_sync      <= 2'b11;
        uart_led_hold_cnt <= 25'd0;
        uart_led_visible  <= 1'b0;
    end else begin
        board_tx_start <= 1'b0;

        if (!board_uart_busy && board_pending_valid) begin
            board_tx_data      <= board_pending_byte;
            board_tx_start     <= 1'b1;
            board_pending_valid <= 1'b0;
            if (core_uart_byte_valid) begin
                board_pending_byte  <= core_uart_byte;
                board_pending_valid <= 1'b1;
            end
        end else if (core_uart_byte_valid) begin
            if (!board_uart_busy) begin
                board_tx_data  <= core_uart_byte;
                board_tx_start <= 1'b1;
            end else if (!board_pending_valid) begin
                board_pending_byte  <= core_uart_byte;
                board_pending_valid <= 1'b1;
            end
        end

        uart_tx_sync <= {uart_tx_sync[0], board_uart_tx};
        if (uart_tx_edge) begin
            // Stretch UART line toggles into a visible ~100 ms LED pulse.
            uart_led_hold_cnt <= 25'd19_999_999;
            uart_led_visible  <= 1'b1;
        end else if (uart_led_hold_cnt != 25'd0) begin
            uart_led_hold_cnt <= uart_led_hold_cnt - 1'b1;
            uart_led_visible  <= 1'b1;
        end else begin
            uart_led_visible  <= 1'b0;
        end
    end
end

// Output assignments for debugging
// Board LEDs are active-low, so drive low when the debug condition is true.
// led[0] = board heartbeat on the core-board LED.
// led[1] = ext LED1, core reset synchronizer released.
// led[2] = ext LED2, core has retired at least one instruction.
// led[3] = ext LED3, diagnostic ROM wrote tube_status == 0x04.
// led[4] = ext LED4, visible UART TX edge activity.

assign led[0] = ~led_blink;                // Core-board heartbeat
assign led[1] = ~core_ready;               // ext LED1
`ifdef ENABLE_DDR3
assign led[2] = ~mig_init_calib_complete;  // ext LED2: DDR3 calib (ON=done)
`else
assign led[2] = ~core_retire_seen;         // ext LED2
`endif
assign led[3] = ~(tube_status == 8'h04);   // ext LED3
assign led[4] = ~uart_led_visible;         // ext LED4

wire _unused_core_clk_dbg = core_clk_dbg;
wire _unused_core_uart_byte_valid_dbg = core_uart_byte_valid_dbg;
wire [7:0] _unused_core_uart_byte_dbg = core_uart_byte_dbg;
wire _unused_core_uart_frame_seen = core_uart_frame_seen;
wire [3:0] _unused_core_uart_frame_count = core_uart_frame_count;
wire [7:0] _unused_core_uart_frame_count_rolling = core_uart_frame_count_rolling;

// =============================================================================
// DDR3 SDRAM Controller (MIG 7-Series) + CDC Bridge
// =============================================================================
`ifdef ENABLE_DDR3

// ── Core ↔ DDR3 bridge wires (core clock domain) ──
wire        core_ddr3_req_valid;
wire        core_ddr3_req_ready;
wire [31:0] core_ddr3_req_addr;
wire        core_ddr3_req_write;
wire [31:0] core_ddr3_req_wdata;
wire [3:0]  core_ddr3_req_wen;
wire        core_ddr3_resp_valid;
wire [31:0] core_ddr3_resp_data;

// ── MIG AXI wires (ui_clk domain, 256-bit data) ──
wire        mig_ui_clk;
wire        mig_ui_clk_sync_rst;
wire        mig_init_calib_complete;
wire        mig_ui_rstn = ~mig_ui_clk_sync_rst;

wire        mig_s_axi_awvalid;
wire        mig_s_axi_awready;
wire [3:0]  mig_s_axi_awid;
wire [31:0] mig_s_axi_awaddr;
wire [7:0]  mig_s_axi_awlen;
wire [2:0]  mig_s_axi_awsize;
wire [1:0]  mig_s_axi_awburst;
wire        mig_s_axi_awlock;
wire [3:0]  mig_s_axi_awcache;
wire [2:0]  mig_s_axi_awprot;
wire [3:0]  mig_s_axi_awqos;

wire        mig_s_axi_wvalid;
wire        mig_s_axi_wready;
wire [255:0] mig_s_axi_wdata;
wire [31:0] mig_s_axi_wstrb;
wire        mig_s_axi_wlast;

wire        mig_s_axi_bvalid;
wire        mig_s_axi_bready;
wire [3:0]  mig_s_axi_bid;
wire [1:0]  mig_s_axi_bresp;

wire        mig_s_axi_arvalid;
wire        mig_s_axi_arready;
wire [3:0]  mig_s_axi_arid;
wire [31:0] mig_s_axi_araddr;
wire [7:0]  mig_s_axi_arlen;
wire [2:0]  mig_s_axi_arsize;
wire [1:0]  mig_s_axi_arburst;
wire        mig_s_axi_arlock;
wire [3:0]  mig_s_axi_arcache;
wire [2:0]  mig_s_axi_arprot;
wire [3:0]  mig_s_axi_arqos;

wire        mig_s_axi_rvalid;
wire        mig_s_axi_rready;
wire [3:0]  mig_s_axi_rid;
wire [255:0] mig_s_axi_rdata;
wire [1:0]  mig_s_axi_rresp;
wire        mig_s_axi_rlast;

// ── CDC + AXI Bridge: core clock → MIG ui_clk ──
// The bridge converts the simple req/resp protocol from adam_riscv (core_clk
// domain, ~10 MHz) to AXI4-256 bit transactions on the MIG ui_clk (~100 MHz).
// It handles async handshake CDC and 32-bit ↔ 256-bit lane steering.
ddr3_mem_port #(
    .AXI_DATA_W (256),
    .AXI_ADDR_W (30),
    .AXI_ID_W   (4)
) u_ddr3_mem_port (
    // Core clock domain
    .core_clk           (core_clk_dbg),       // Core clock from adam_riscv debug output
    .core_rstn          (core_ready),          // Core reset from adam_riscv debug output

    .req_valid          (core_ddr3_req_valid),
    .req_ready          (core_ddr3_req_ready),
    .req_addr           (core_ddr3_req_addr),
    .req_write          (core_ddr3_req_write),
    .req_wdata          (core_ddr3_req_wdata),
    .req_wen            (core_ddr3_req_wen),
    .resp_valid         (core_ddr3_resp_valid),
    .resp_data          (core_ddr3_resp_data),

    // MIG UI clock domain
    .ui_clk             (mig_ui_clk),
    .ui_rstn            (mig_ui_rstn),
    .init_calib_complete(mig_init_calib_complete),

    // AXI4 Master → MIG Slave
    .m_axi_awvalid      (mig_s_axi_awvalid),
    .m_axi_awready      (mig_s_axi_awready),
    .m_axi_awid         (mig_s_axi_awid),
    .m_axi_awaddr       (mig_s_axi_awaddr),
    .m_axi_awlen        (mig_s_axi_awlen),
    .m_axi_awsize       (mig_s_axi_awsize),
    .m_axi_awburst      (mig_s_axi_awburst),
    .m_axi_awlock       (mig_s_axi_awlock),
    .m_axi_awcache      (mig_s_axi_awcache),
    .m_axi_awprot       (mig_s_axi_awprot),
    .m_axi_awqos        (mig_s_axi_awqos),

    .m_axi_wvalid       (mig_s_axi_wvalid),
    .m_axi_wready       (mig_s_axi_wready),
    .m_axi_wdata        (mig_s_axi_wdata),
    .m_axi_wstrb        (mig_s_axi_wstrb),
    .m_axi_wlast        (mig_s_axi_wlast),

    .m_axi_bvalid       (mig_s_axi_bvalid),
    .m_axi_bready       (mig_s_axi_bready),
    .m_axi_bid          (mig_s_axi_bid),
    .m_axi_bresp        (mig_s_axi_bresp),

    .m_axi_arvalid      (mig_s_axi_arvalid),
    .m_axi_arready      (mig_s_axi_arready),
    .m_axi_arid         (mig_s_axi_arid),
    .m_axi_araddr       (mig_s_axi_araddr),
    .m_axi_arlen        (mig_s_axi_arlen),
    .m_axi_arsize       (mig_s_axi_arsize),
    .m_axi_arburst      (mig_s_axi_arburst),
    .m_axi_arlock       (mig_s_axi_arlock),
    .m_axi_arcache      (mig_s_axi_arcache),
    .m_axi_arprot       (mig_s_axi_arprot),
    .m_axi_arqos        (mig_s_axi_arqos),

    .m_axi_rvalid       (mig_s_axi_rvalid),
    .m_axi_rready       (mig_s_axi_rready),
    .m_axi_rid          (mig_s_axi_rid),
    .m_axi_rdata        (mig_s_axi_rdata),
    .m_axi_rresp        (mig_s_axi_rresp),
    .m_axi_rlast        (mig_s_axi_rlast)
);

// ── MIG 7-Series DDR3 Controller ──
// Generated by: fpga/ip/create_mig_ax7203.tcl
// SystemClock = "No Buffer" (pre-buffered 200MHz from existing IBUFGDS)
// PHY 4:1 ratio → DDR3 400MHz, UI clock ~100MHz, AXI 256-bit data
mig_7series_0 u_mig (
    // DDR3 Physical Interface
    .ddr3_dq            (ddr3_dq),
    .ddr3_dqs_p         (ddr3_dqs_p),
    .ddr3_dqs_n         (ddr3_dqs_n),
    .ddr3_addr          (ddr3_addr),
    .ddr3_ba            (ddr3_ba),
    .ddr3_ras_n         (ddr3_ras_n),
    .ddr3_cas_n         (ddr3_cas_n),
    .ddr3_we_n          (ddr3_we_n),
    .ddr3_ck_p          (ddr3_ck_p),
    .ddr3_ck_n          (ddr3_ck_n),
    .ddr3_cke           (ddr3_cke),
    .ddr3_reset_n       (ddr3_reset_n),
    .ddr3_dm            (ddr3_dm),
    .ddr3_odt           (ddr3_odt),
    .ddr3_cs_n          (ddr3_cs_n),

    // System Clock & Reset ("No Buffer" mode: pre-buffered clock)
    .sys_clk_i          (sys_clk_200m),     // 200MHz from existing IBUFGDS
    .sys_rst             (core_rst_n),       // Active-low system reset
    .aresetn             (core_rst_n),       // AXI reset (active-low)

    // UI Clock outputs
    .ui_clk              (mig_ui_clk),
    .ui_clk_sync_rst     (mig_ui_clk_sync_rst),
    .mmcm_locked         (),
    .init_calib_complete  (mig_init_calib_complete),

    // App management ports (tie off — not used)
    .app_sr_req          (1'b0),
    .app_ref_req         (1'b0),
    .app_zq_req          (1'b0),
    .app_sr_active       (),
    .app_ref_ack         (),
    .app_zq_ack          (),
    .device_temp         (),

    // AXI4 Slave Interface
    .s_axi_awid          (mig_s_axi_awid),
    .s_axi_awaddr        (mig_s_axi_awaddr),
    .s_axi_awlen         (mig_s_axi_awlen),
    .s_axi_awsize        (mig_s_axi_awsize),
    .s_axi_awburst       (mig_s_axi_awburst),
    .s_axi_awlock        (mig_s_axi_awlock),
    .s_axi_awcache       (mig_s_axi_awcache),
    .s_axi_awprot        (mig_s_axi_awprot),
    .s_axi_awqos         (mig_s_axi_awqos),
    .s_axi_awvalid       (mig_s_axi_awvalid),
    .s_axi_awready       (mig_s_axi_awready),

    .s_axi_wdata         (mig_s_axi_wdata),
    .s_axi_wstrb         (mig_s_axi_wstrb),
    .s_axi_wlast         (mig_s_axi_wlast),
    .s_axi_wvalid        (mig_s_axi_wvalid),
    .s_axi_wready        (mig_s_axi_wready),

    .s_axi_bid           (mig_s_axi_bid),
    .s_axi_bresp         (mig_s_axi_bresp),
    .s_axi_bvalid        (mig_s_axi_bvalid),
    .s_axi_bready        (mig_s_axi_bready),

    .s_axi_arid          (mig_s_axi_arid),
    .s_axi_araddr        (mig_s_axi_araddr),
    .s_axi_arlen         (mig_s_axi_arlen),
    .s_axi_arsize        (mig_s_axi_arsize),
    .s_axi_arburst       (mig_s_axi_arburst),
    .s_axi_arlock        (mig_s_axi_arlock),
    .s_axi_arcache       (mig_s_axi_arcache),
    .s_axi_arprot        (mig_s_axi_arprot),
    .s_axi_arqos         (mig_s_axi_arqos),
    .s_axi_arvalid       (mig_s_axi_arvalid),
    .s_axi_arready       (mig_s_axi_arready),

    .s_axi_rid           (mig_s_axi_rid),
    .s_axi_rdata         (mig_s_axi_rdata),
    .s_axi_rresp         (mig_s_axi_rresp),
    .s_axi_rlast         (mig_s_axi_rlast),
    .s_axi_rvalid        (mig_s_axi_rvalid),
    .s_axi_rready        (mig_s_axi_rready)
);

`else
// When DDR3 is not enabled, declare the wires so the adam_riscv instantiation
// above compiles cleanly (the ifdef in adam_riscv ports removes them anyway).
wire        core_ddr3_req_valid;
wire        core_ddr3_req_ready  = 1'b0;
wire [31:0] core_ddr3_req_addr;
wire        core_ddr3_req_write;
wire [31:0] core_ddr3_req_wdata;
wire [3:0]  core_ddr3_req_wen;
wire        core_ddr3_resp_valid = 1'b0;
wire [31:0] core_ddr3_resp_data  = 32'd0;
`endif  // ENABLE_DDR3

endmodule
