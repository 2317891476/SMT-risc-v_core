// =============================================================================
// Module : adam_riscv_v2_ax7203_top
// Description: AX7203 FPGA Top-Level Wrapper for AdamRISC-V V2 Processor
//   Target Board: ALINX AX7203 (XC7A200T-2FBG484I)
//   Clock: 200MHz differential (SiT9102-200.00MHz)
//
//   This module provides the board-specific wrapper that:
//   - Accepts 200MHz differential system clock (R4/T4)
//   - Instantiates clock wizard to generate core clock (50MHz)
//   - Handles reset synchronization
//   - Exposes UART TX/RX for CP2102 USB-UART bridge
//   - Transmits "AdamRiscv AX7203 Boot\r\n" on startup via UART
//   - Instantiates adam_riscv_v2 core with FPGA_MODE enabled
// =============================================================================

`ifndef FPGA_MODE
    `define FPGA_MODE 1
`endif

module adam_riscv_v2_ax7203_top (
    input  wire sys_clk_p,      // 200MHz differential P (Pin R4, Bank 34)
    input  wire sys_clk_n,      // 200MHz differential N (Pin T4, Bank 34)
    input  wire sys_rst_n,      // Active-low reset (Pin T6)
    // UART (CP2102 USB-UART bridge)
    output wire uart_tx,        // FPGA TX -> PC RX (Pin N15)
    input  wire uart_rx,        // FPGA RX <- PC TX (Pin P20)
    // LEDs for debug
    output wire [4:0] led       // LED[0-2]=core, LED[3]=heartbeat, LED[4]=uart_tx
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

// Note: clk_wiz_0 is instantiated inside adam_riscv_v2 when FPGA_MODE is defined
// We use sys_clk_200m directly; the core handles clock generation internally

// =============================================================================
// Power-on Reset Generator
// =============================================================================
// Internal reset since external reset pin has routing issues
reg [15:0] por_cnt;
reg por_rst_n;

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

// =============================================================================
// Core Instantiation
// =============================================================================

// Core LED outputs (3 LEDs when FPGA_MODE is defined)
wire [2:0] core_led;

// Tube status for debug observation
wire [7:0] tube_status;

// The core has FPGA_MODE defined internally, which causes it to:
// 1. Instantiate clk_wiz_0 to convert sys_clk (200MHz) to core clock
// 2. Instantiate syn_rst for reset synchronization
// We pass the raw 200MHz clock and external reset to the core.
adam_riscv_v2 u_adam_riscv_v2 (
    .sys_clk   (sys_clk_200m),  // 200MHz from IBUFGDS (core has clk_wiz_0 inside)
    .sys_rstn  (sys_rst_n   ),  // External active-low reset (core has syn_rst inside)
    .ext_irq_src (1'b0      ),  // External interrupt - tied low for now
    .led       (core_led    ),  // FPGA_MODE exposes this port
    .tube_status (tube_status)
);

// =============================================================================
// UART Controller (Boot Message)
// =============================================================================

// UART transmitter with auto-boot message
// Transmits "AdamRiscv AX7203 Boot\r\n" on startup
// Uses 200MHz clock; uart_tx_autoboot handles internal clock division
wire uart_tx_internal;

// Use simple UART for testing
uart_tx_simple u_uart_tx_simple (
    .clk   (sys_clk_200m),
    .rst_n (sys_rst_n ),
    .tx    (uart_tx_internal)
);

// =============================================================================
// UART Output Assignment
// =============================================================================

// UART TX is driven by the boot message transmitter
assign uart_tx = uart_tx_internal;

// UART RX is currently not connected to the core
// Wire available for future UART controller integration

// =============================================================================
// Debug LED Output
// =============================================================================

// LED heartbeat to verify FPGA is running
reg [24:0] led_cnt;
reg led_blink;

always @(posedge sys_clk_200m or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
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

// Output assignments for debugging
// led[0] = core_led[0] (if available)
// led[1] = core_led[1] (if available)
// led[2] = core_led[2] (if available)
// led[3] = LED blink heartbeat
// led[4] = uart_tx_internal (to see TX activity)

// Route core LEDs if available, otherwise tie to debug signals
assign led[0] = core_led[0];
assign led[1] = core_led[1];
assign led[2] = core_led[2];
assign led[3] = led_blink;           // Heartbeat
assign led[4] = uart_tx_internal;    // UART TX activity

endmodule
