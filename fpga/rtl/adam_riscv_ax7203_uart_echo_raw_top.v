`ifndef FPGA_MODE
    `define FPGA_MODE 1
`endif

module adam_riscv_ax7203_uart_echo_raw_top (
    input  wire sys_clk_p,
    input  wire sys_clk_n,
    input  wire sys_rst_n,
    output wire uart_tx,
    input  wire uart_rx,
    output wire [4:0] led
);

localparam integer UART_CLK_DIV = 1736;

wire sys_clk_200m;

IBUFGDS clk_ibufgds (
    .O  (sys_clk_200m),
    .I  (sys_clk_p   ),
    .IB (sys_clk_n   )
);

reg [15:0] por_cnt;
reg        por_rst_n;

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

wire       uart_rx_byte_valid;
wire [7:0] uart_rx_byte;
wire       uart_rx_frame_error;

uart_rx #(
    .CLK_DIV(UART_CLK_DIV)
) u_uart_rx (
    .clk        (sys_clk_200m        ),
    .rst_n      (por_rst_n           ),
    .enable     (1'b1                ),
    .rx         (uart_rx             ),
    .byte_valid (uart_rx_byte_valid  ),
    .byte_data  (uart_rx_byte        ),
    .frame_error(uart_rx_frame_error )
);

reg       tx_start_r;
reg [7:0] tx_data_r;
wire      uart_tx_busy;

uart_tx #(
    .CLK_DIV(UART_CLK_DIV)
) u_uart_tx (
    .clk      (sys_clk_200m),
    .rst_n    (por_rst_n   ),
    .tx_start (tx_start_r  ),
    .tx_data  (tx_data_r   ),
    .tx       (uart_tx     ),
    .busy     (uart_tx_busy)
);

reg        pending_valid_r;
reg [7:0]  pending_byte_r;
reg        rx_seen_r;
reg        tx_seen_r;
reg        overrun_r;
reg [1:0]  uart_tx_sync;
wire       uart_tx_edge = uart_tx_sync[1] ^ uart_tx_sync[0];

always @(posedge sys_clk_200m or negedge por_rst_n) begin
    if (!por_rst_n) begin
        tx_start_r      <= 1'b0;
        tx_data_r       <= 8'd0;
        pending_valid_r <= 1'b0;
        pending_byte_r  <= 8'd0;
        rx_seen_r       <= 1'b0;
        tx_seen_r       <= 1'b0;
        overrun_r       <= 1'b0;
        uart_tx_sync    <= 2'b11;
    end else begin
        tx_start_r   <= 1'b0;
        uart_tx_sync <= {uart_tx_sync[0], uart_tx};

        if (uart_tx_edge) begin
            tx_seen_r <= 1'b1;
        end

        if (!uart_tx_busy && pending_valid_r) begin
            tx_data_r       <= pending_byte_r;
            tx_start_r      <= 1'b1;
            pending_valid_r <= 1'b0;
        end

        if (uart_rx_frame_error) begin
            overrun_r <= 1'b1;
        end

        if (uart_rx_byte_valid) begin
            rx_seen_r <= 1'b1;
            if (!uart_tx_busy && !pending_valid_r && !tx_start_r) begin
                tx_data_r  <= uart_rx_byte;
                tx_start_r <= 1'b1;
            end else if (!pending_valid_r) begin
                pending_byte_r  <= uart_rx_byte;
                pending_valid_r <= 1'b1;
            end else begin
                overrun_r <= 1'b1;
            end
        end
    end
end

assign led[0] = ~por_rst_n;
assign led[1] = ~rx_seen_r;
assign led[2] = ~tx_seen_r;
assign led[3] = ~pending_valid_r;
assign led[4] = ~overrun_r;

endmodule
