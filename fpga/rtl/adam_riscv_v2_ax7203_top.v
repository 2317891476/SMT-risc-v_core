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
//   - Drives 5 status LEDs
//   - Instantiates adam_riscv_v2 core with FPGA_MODE enabled
//
//   LED Mapping (AX7203):
//   - led[0]: Heartbeat - toggles when core is running
//   - led[1]: Boot Status - ON when boot complete
//   - led[2]: Core LED[0] from adam_riscv_v2 (FPGA_MODE)
//   - led[3]: Core LED[1] from adam_riscv_v2 (FPGA_MODE)
//   - led[4]: Core LED[2] from adam_riscv_v2 (FPGA_MODE)
// =============================================================================

`ifndef FPGA_MODE
    `define FPGA_MODE 1
`endif

module adam_riscv_v2_ax7203_top (
    input  wire sys_clk_p,      // 200MHz differential P (Pin R4, Bank 34)
    input  wire sys_clk_n,      // 200MHz differential N (Pin T4, Bank 34)
    input  wire sys_rst_n,      // Active-low reset (external button)
    // UART (CP2102 USB-UART bridge)
    output wire uart_tx,        // FPGA TX -> PC RX
    input  wire uart_rx,        // FPGA RX <- PC TX
    // LEDs (5 total on AX7203)
    output wire [4:0] led       // Status LEDs
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

uart_tx_autoboot u_uart_tx_autoboot (
    .clk   (sys_clk_200m),
    .rst_n (sys_rst_n    ),
    .tx    (uart_tx_internal)
);

// =============================================================================
// LED Output Mapping
// =============================================================================

// LED assignments:
// - led[4:2]: Direct mapping from core LED outputs (when FPGA_MODE enabled)
// - led[1:0]: Status indicators derived from core signals

assign led[4:2] = core_led;     // Core status LEDs
assign led[1]   = sys_rst_n;    // Boot status: ON when external reset is high (released)
assign led[0]   = tube_status[0]; // Heartbeat from tube_status bit 0

// =============================================================================
// UART Output Assignment
// =============================================================================

// UART TX is driven by the boot message transmitter
// Once message is sent, it stays at idle state (high)
assign uart_tx = uart_tx_internal;

// UART RX is currently not connected to the core
// Wire available for future UART controller integration

endmodule
