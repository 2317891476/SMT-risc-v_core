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
    .ext_irq_src (1'b0      ),  // External interrupt - tied low for now
    .led       (core_led    ),  // FPGA_MODE exposes this port
    .tube_status (tube_status),
    .uart_tx   (core_uart_tx),
    .debug_core_ready(core_ready),
    .debug_core_clk(core_clk_dbg),
    .debug_retire_seen(core_retire_seen),
    .debug_uart_tx_byte_valid(core_uart_byte_valid_dbg),
    .debug_uart_tx_byte(core_uart_byte_dbg)
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

// UART RX is not consumed yet; keep the pin exposed for future RX/MMIO support.

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
assign led[2] = ~core_retire_seen;         // ext LED2
assign led[3] = ~(tube_status == 8'h04);   // ext LED3
assign led[4] = ~uart_led_visible;         // ext LED4

wire _unused_core_clk_dbg = core_clk_dbg;
wire _unused_core_uart_byte_valid_dbg = core_uart_byte_valid_dbg;
wire [7:0] _unused_core_uart_byte_dbg = core_uart_byte_dbg;
wire _unused_core_uart_frame_seen = core_uart_frame_seen;
wire [3:0] _unused_core_uart_frame_count = core_uart_frame_count;
wire [7:0] _unused_core_uart_frame_count_rolling = core_uart_frame_count_rolling;

endmodule
