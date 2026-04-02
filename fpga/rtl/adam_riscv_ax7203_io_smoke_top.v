// =============================================================================
// Module : adam_riscv_ax7203_io_smoke_top
// Description: Minimal AX7203 board IO smoke top used to validate the physical
// UART/LED path independently from the CPU core.
// =============================================================================

module adam_riscv_ax7203_io_smoke_top (
    input  wire sys_clk_p,
    input  wire sys_clk_n,
    input  wire sys_rst_n,
    output wire uart_tx,
    input  wire uart_rx,
    output wire [4:0] led
);

wire sys_clk_200m;

IBUFGDS clk_ibufgds (
    .O  (sys_clk_200m),
    .I  (sys_clk_p   ),
    .IB (sys_clk_n   )
);

reg [15:0] por_cnt;
reg por_rst_n;

always @(posedge sys_clk_200m) begin
    if (!sys_rst_n) begin
        por_cnt   <= 16'd0;
        por_rst_n <= 1'b0;
    end else if (por_cnt != 16'hFFFF) begin
        por_cnt   <= por_cnt + 16'd1;
        por_rst_n <= 1'b0;
    end else begin
        por_rst_n <= 1'b1;
    end
end

wire tx_line;
uart_tx_autoboot u_uart_tx_autoboot (
    .clk   (sys_clk_200m),
    .rst_n (por_rst_n   ),
    .tx    (tx_line     )
);

assign uart_tx = tx_line;

reg [26:0] blink_cnt;
reg [2:0]  led_phase;
reg [24:0] uart_led_hold_cnt;
reg        uart_led_visible;
reg [1:0]  uart_tx_sync;
wire       uart_tx_edge = uart_tx_sync[1] ^ uart_tx_sync[0];

always @(posedge sys_clk_200m or negedge por_rst_n) begin
    if (!por_rst_n) begin
        blink_cnt <= 27'd0;
        led_phase <= 3'd0;
    end else if (blink_cnt == 27'd49_999_999) begin
        blink_cnt <= 27'd0;
        led_phase <= led_phase + 3'd1;
    end else begin
        blink_cnt <= blink_cnt + 27'd1;
    end
end

always @(posedge sys_clk_200m or negedge por_rst_n) begin
    if (!por_rst_n) begin
        uart_tx_sync      <= 2'b11;
        uart_led_hold_cnt <= 25'd0;
        uart_led_visible  <= 1'b0;
    end else begin
        uart_tx_sync <= {uart_tx_sync[0], tx_line};
        if (uart_tx_edge) begin
            uart_led_hold_cnt <= 25'd19_999_999;
            uart_led_visible  <= 1'b1;
        end else if (uart_led_hold_cnt != 25'd0) begin
            uart_led_hold_cnt <= uart_led_hold_cnt - 25'd1;
            uart_led_visible  <= 1'b1;
        end else begin
            uart_led_visible  <= 1'b0;
        end
    end
end

// Active-low LEDs.
assign led[0] = ~blink_cnt[26];
assign led[1] = ~(por_rst_n);
assign led[2] = ~(led_phase[0]);
assign led[3] = ~(led_phase[1]);
assign led[4] = ~(uart_led_visible);

// Keep the unused RX port visible so the pin remains constrained.
wire _unused_uart_rx = uart_rx;

endmodule
