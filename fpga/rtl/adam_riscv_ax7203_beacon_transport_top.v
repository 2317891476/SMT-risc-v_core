`ifndef FPGA_MODE
    `define FPGA_MODE 1
`endif

module adam_riscv_ax7203_beacon_transport_top (
    input  wire sys_clk_p,
    input  wire sys_clk_n,
    input  wire sys_rst_n,
    output wire uart_tx,
    input  wire uart_rx,
    output wire [4:0] led
);

localparam integer UART_CLK_DIV = 1736;
localparam integer START_DELAY_CYCLES = 40_000_000;
localparam integer RESTART_DELAY_CYCLES = 20_000_000;

localparam [7:0] EVT_READY        = 8'h01;
localparam [7:0] EVT_LOAD_START   = 8'h02;
localparam [7:0] EVT_BLOCK_ACK    = 8'h11;
localparam [7:0] EVT_HDR_B0_RX    = 8'h31;
localparam [7:0] EVT_HDR_B1_RX    = 8'h32;
localparam [7:0] EVT_HDR_B2_RX    = 8'h33;
localparam [7:0] EVT_HDR_B3_RX    = 8'h34;
localparam [7:0] EVT_HDR_MAGIC_OK = 8'h35;
localparam [7:0] EVT_IDLE_OK      = 8'h36;
localparam [7:0] EVT_TRAIN_START  = 8'h37;
localparam [7:0] EVT_TRAIN_DONE   = 8'h38;
localparam [7:0] EVT_FLUSH_DONE   = 8'h39;
localparam [7:0] EVT_HEADER_ENTER = 8'h3A;
localparam [7:0] EVT_SUMMARY      = 8'hF0;

wire sys_clk_200m;
IBUFGDS clk_ibufgds (
    .O  (sys_clk_200m),
    .I  (sys_clk_p),
    .IB (sys_clk_n)
);

reg [15:0] por_cnt;
reg        por_rst_n;
wire       rst_n = por_rst_n;

always @(posedge sys_clk_200m) begin
    if (por_cnt != 16'hFFFF) begin
        por_cnt   <= por_cnt + 16'd1;
        por_rst_n <= 1'b0;
    end else begin
        por_rst_n <= 1'b1;
    end
end

initial begin
    por_cnt = 16'd0;
    por_rst_n = 1'b0;
end

function automatic [15:0] event_word(input [4:0] idx);
    begin
        case (idx)
            5'd0:  event_word = {8'hA1, EVT_READY};
            5'd1:  event_word = {8'hB2, EVT_IDLE_OK};
            5'd2:  event_word = {8'hC3, EVT_TRAIN_START};
            5'd3:  event_word = {8'h14, EVT_TRAIN_DONE};
            5'd4:  event_word = {8'h05, EVT_FLUSH_DONE};
            5'd5:  event_word = {8'hD6, EVT_HEADER_ENTER};
            5'd6:  event_word = {8'h42, EVT_HDR_B0_RX};
            5'd7:  event_word = {8'h4D, EVT_HDR_B1_RX};
            5'd8:  event_word = {8'h4B, EVT_HDR_B2_RX};
            5'd9:  event_word = {8'h31, EVT_HDR_B3_RX};
            5'd10: event_word = {8'hE7, EVT_HDR_MAGIC_OK};
            5'd11: event_word = {8'hF8, EVT_LOAD_START};
            5'd12: event_word = {8'h00, EVT_BLOCK_ACK};
            5'd13: event_word = {8'h0F, EVT_SUMMARY};
            default: event_word = 16'h0000;
        endcase
    end
endfunction

localparam integer DELAY_W = (START_DELAY_CYCLES > RESTART_DELAY_CYCLES)
                           ? $clog2(START_DELAY_CYCLES + 1)
                           : $clog2(RESTART_DELAY_CYCLES + 1);

reg [DELAY_W-1:0] delay_r;
reg [4:0]  evt_idx_r;
reg        evt_valid_r;
reg [7:0]  evt_type_r;
reg [7:0]  evt_arg_r;
wire [15:0] next_event_word_w = event_word(evt_idx_r);

wire       beacon_evt_ready;
wire       beacon_byte_valid;
wire       beacon_byte_ready;
wire [7:0] beacon_byte;

always @(posedge sys_clk_200m or negedge rst_n) begin
    if (!rst_n) begin
        delay_r       <= START_DELAY_CYCLES[DELAY_W-1:0];
        evt_idx_r     <= 5'd0;
        evt_valid_r   <= 1'b0;
        evt_type_r    <= 8'd0;
        evt_arg_r     <= 8'd0;
    end else begin
        if (delay_r != {DELAY_W{1'b0}}) begin
            delay_r <= delay_r - {{(DELAY_W-1){1'b0}}, 1'b1};
        end else if (!evt_valid_r) begin
            evt_type_r  <= next_event_word_w[7:0];
            evt_arg_r   <= next_event_word_w[15:8];
            evt_valid_r <= 1'b1;
        end else if (evt_valid_r && beacon_evt_ready) begin
            evt_valid_r <= 1'b0;
            if (evt_idx_r == 5'd13) begin
                evt_idx_r <= 5'd0;
                delay_r   <= RESTART_DELAY_CYCLES[DELAY_W-1:0];
            end else begin
                evt_idx_r <= evt_idx_r + 5'd1;
            end
        end
    end
end

debug_beacon_tx u_debug_beacon_tx (
    .clk       (sys_clk_200m),
    .rstn      (rst_n),
    .evt_valid (evt_valid_r),
    .evt_ready (beacon_evt_ready),
    .evt_type  (evt_type_r),
    .evt_arg   (evt_arg_r),
    .byte_valid(beacon_byte_valid),
    .byte_ready(beacon_byte_ready),
    .byte_data (beacon_byte)
);

reg       tx_start_r;
reg [7:0] tx_data_r;
wire      uart_busy;

assign beacon_byte_ready = !uart_busy && !tx_start_r;

always @(posedge sys_clk_200m or negedge rst_n) begin
    if (!rst_n) begin
        tx_start_r <= 1'b0;
        tx_data_r  <= 8'd0;
    end else begin
        tx_start_r <= 1'b0;
        if (beacon_byte_valid && beacon_byte_ready) begin
            tx_data_r  <= beacon_byte;
            tx_start_r <= 1'b1;
        end
    end
end

uart_tx #(
    .CLK_DIV(UART_CLK_DIV)
) u_uart_tx (
    .clk      (sys_clk_200m),
    .rst_n    (rst_n),
    .tx_start (tx_start_r),
    .tx_data  (tx_data_r),
    .tx       (uart_tx),
    .busy     (uart_busy)
);

reg [24:0] led_cnt;
reg        led_blink;
reg [24:0] uart_led_hold_cnt;
reg        uart_led_visible;
reg [1:0]  uart_tx_sync;
wire       uart_tx_edge = uart_tx_sync[1] ^ uart_tx_sync[0];

always @(posedge sys_clk_200m or negedge rst_n) begin
    if (!rst_n) begin
        led_cnt   <= 25'd0;
        led_blink <= 1'b0;
    end else if (led_cnt == 25'd19_999_999) begin
        led_cnt   <= 25'd0;
        led_blink <= ~led_blink;
    end else begin
        led_cnt <= led_cnt + 25'd1;
    end
end

always @(posedge sys_clk_200m or negedge rst_n) begin
    if (!rst_n) begin
        uart_tx_sync      <= 2'b11;
        uart_led_hold_cnt <= 25'd0;
        uart_led_visible  <= 1'b0;
    end else begin
        uart_tx_sync <= {uart_tx_sync[0], uart_tx};
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

assign led[0] = ~led_blink;
assign led[1] = ~rst_n;
assign led[2] = ~(delay_r == {DELAY_W{1'b0}});
assign led[3] = ~(evt_idx_r == 5'd0);
assign led[4] = ~uart_led_visible;

wire _unused_sys_rst_n = sys_rst_n;
wire _unused_uart_rx = uart_rx;

endmodule
