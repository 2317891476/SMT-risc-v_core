`ifndef FPGA_MODE
    `define FPGA_MODE 1
`endif

module adam_riscv_ax7203_main_bridge_probe_top (
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
wire core_rst_n;

always @(posedge sys_clk_200m) begin
    if (por_cnt != 16'hFFFF) begin
        por_cnt <= por_cnt + 16'd1;
        por_rst_n <= 1'b0;
    end else begin
        por_rst_n <= 1'b1;
    end
end

initial begin
    por_cnt = 16'd0;
    por_rst_n = 1'b0;
end

assign core_rst_n = por_rst_n;

wire [2:0] core_led;
wire [7:0] tube_status;
wire       core_uart_tx;
wire       core_clk_dbg;
wire       core_ready;
wire       core_retire_seen;
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
wire       board_uart_frame_seen;
wire [3:0] board_uart_frame_count;
wire [7:0] board_uart_frame_count_rolling;
reg [7:0]  board_tx_start_count;
wire       status_uart_tx;

(* DONT_TOUCH = "TRUE", KEEP_HIERARCHY = "TRUE" *)
adam_riscv u_adam_riscv (
    .sys_clk   (sys_clk_200m),
    .sys_rstn  (core_rst_n  ),
    .uart_rx   (uart_rx     ),
    .ext_irq_src (1'b0      ),
    .led       (core_led    ),
    .tube_status (tube_status),
    .uart_tx   (core_uart_tx),
    .debug_core_ready(core_ready),
    .debug_core_clk(core_clk_dbg),
    .debug_retire_seen(core_retire_seen),
    .debug_uart_tx_byte_valid(core_uart_byte_valid_dbg),
    .debug_uart_tx_byte(core_uart_byte_dbg)
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
) u_board_uart_monitor (
    .clk                (sys_clk_200m                 ),
    .rst_n              (core_rst_n                   ),
    .rx                 (board_uart_tx                ),
    .frame_seen         (board_uart_frame_seen        ),
    .frame_count        (board_uart_frame_count       ),
    .frame_count_rolling(board_uart_frame_count_rolling),
    .byte_valid         (                              ),
    .byte_data          (                              )
);

uart_main_bridge_beacon u_bridge_beacon (
    .clk                        (sys_clk_200m                 ),
    .rst_n                      (core_rst_n                   ),
    .core_ready                 (core_ready                   ),
    .retire_seen                (core_retire_seen             ),
    .tube_pass                  (tube_status == 8'h04         ),
    .core_uart_frame_count_rolling(core_uart_frame_count_rolling),
    .board_tx_start_count       (board_tx_start_count         ),
    .board_uart_frame_count_rolling(board_uart_frame_count_rolling),
    .bridge_flags               ({board_pending_valid, board_uart_busy, core_uart_frame_seen, board_uart_frame_seen}),
    .tx                         (status_uart_tx               )
);

assign uart_tx = status_uart_tx;

reg [24:0] led_cnt;
reg        led_blink;
reg [24:0] uart_led_hold_cnt;
reg        uart_led_visible;
reg [1:0]  uart_tx_sync;
wire       uart_tx_edge = uart_tx_sync[1] ^ uart_tx_sync[0];

always @(posedge sys_clk_200m or negedge core_rst_n) begin
    if (!core_rst_n) begin
        led_cnt <= 25'd0;
        led_blink <= 1'b0;
    end else if (led_cnt == 25'd19_999_999) begin
        led_cnt <= 25'd0;
        led_blink <= ~led_blink;
    end else begin
        led_cnt <= led_cnt + 25'd1;
    end
end

always @(posedge sys_clk_200m or negedge core_rst_n) begin
    if (!core_rst_n) begin
        board_tx_start <= 1'b0;
        board_tx_data <= 8'd0;
        board_pending_valid <= 1'b0;
        board_pending_byte <= 8'd0;
        board_tx_start_count <= 8'd0;
        uart_tx_sync <= 2'b11;
        uart_led_hold_cnt <= 25'd0;
        uart_led_visible <= 1'b0;
    end else begin
        board_tx_start <= 1'b0;

        if (!board_uart_busy && board_pending_valid) begin
            board_tx_data <= board_pending_byte;
            board_tx_start <= 1'b1;
            board_pending_valid <= 1'b0;
            board_tx_start_count <= board_tx_start_count + 8'd1;
            if (core_uart_byte_valid) begin
                board_pending_byte <= core_uart_byte;
                board_pending_valid <= 1'b1;
            end
        end else if (core_uart_byte_valid) begin
            if (!board_uart_busy) begin
                board_tx_data <= core_uart_byte;
                board_tx_start <= 1'b1;
                board_tx_start_count <= board_tx_start_count + 8'd1;
            end else if (!board_pending_valid) begin
                board_pending_byte <= core_uart_byte;
                board_pending_valid <= 1'b1;
            end
        end

        uart_tx_sync <= {uart_tx_sync[0], status_uart_tx};
        if (uart_tx_edge) begin
            uart_led_hold_cnt <= 25'd19_999_999;
            uart_led_visible <= 1'b1;
        end else if (uart_led_hold_cnt != 25'd0) begin
            uart_led_hold_cnt <= uart_led_hold_cnt - 25'd1;
            uart_led_visible <= 1'b1;
        end else begin
            uart_led_visible <= 1'b0;
        end
    end
end

assign led[0] = ~led_blink;
assign led[1] = ~core_ready;
assign led[2] = ~core_retire_seen;
assign led[3] = ~(tube_status == 8'h04);
assign led[4] = ~uart_led_visible;

wire _unused_uart_rx = uart_rx;
wire _unused_core_clk_dbg = core_clk_dbg;
wire _unused_core_uart_byte_valid_dbg = core_uart_byte_valid_dbg;
wire [7:0] _unused_core_uart_byte_dbg = core_uart_byte_dbg;
wire [3:0] _unused_core_uart_frame_count = core_uart_frame_count;
wire [3:0] _unused_board_uart_frame_count = board_uart_frame_count;

endmodule
