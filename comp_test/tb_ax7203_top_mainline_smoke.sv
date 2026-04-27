`timescale 1ns/1ps

module tb_ax7203_top_mainline_smoke;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;

    integer uart_edge_count;
    integer uart_byte_count;
    integer unexpected_byte_count;
    integer count_u, count_a, count_r, count_t, count_d, count_i, count_g, count_p, count_s;
    reg led1_ready_seen;
    reg led2_retire_seen;
    reg led3_tube_seen;
    reg led4_uart_seen;
    reg saw_space;
    reg saw_cr;
    reg saw_lf;
    reg uart_tx_q;
    wire ext_uart_frame_seen;
    wire [3:0] ext_uart_frame_count;
    wire [7:0] ext_uart_frame_count_rolling;
    wire ext_uart_byte_valid;
    wire [7:0] ext_uart_byte;
    localparam integer TB_TIMEOUT_NS = 20_000_000;

    adam_riscv_ax7203_top dut (
        .sys_clk_p (sys_clk_p),
        .sys_clk_n (sys_clk_n),
        .sys_rst_n (sys_rst_n),
        .uart_tx   (uart_tx  ),
        .uart_rx   (uart_rx  ),
        .led       (led      )
    );

    uart_rx_monitor #(
        .CLK_DIV(1736)
    ) u_ext_uart_monitor (
        .clk                (sys_clk_p                ),
        .rst_n              (dut.core_rst_n           ),
        .rx                 (uart_tx                  ),
        .frame_seen         (ext_uart_frame_seen      ),
        .frame_count        (ext_uart_frame_count     ),
        .frame_count_rolling(ext_uart_frame_count_rolling),
        .byte_valid         (ext_uart_byte_valid      ),
        .byte_data          (ext_uart_byte            )
    );

    initial begin
        sys_clk_p = 1'b0;
        sys_clk_n = 1'b1;
        forever begin
            #2.5;
            sys_clk_p = ~sys_clk_p;
            sys_clk_n = ~sys_clk_n;
        end
    end

    initial begin
        sys_rst_n = 1'b0;
        uart_rx = 1'b1;
        uart_edge_count = 0;
        uart_byte_count = 0;
        unexpected_byte_count = 0;
        count_u = 0;
        count_a = 0;
        count_r = 0;
        count_t = 0;
        count_d = 0;
        count_i = 0;
        count_g = 0;
        count_p = 0;
        count_s = 0;
        led1_ready_seen = 1'b0;
        led2_retire_seen = 1'b0;
        led3_tube_seen = 1'b0;
        led4_uart_seen = 1'b0;
        saw_space = 1'b0;
        saw_cr = 1'b0;
        saw_lf = 1'b0;
        uart_tx_q = 1'b1;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge sys_clk_p) begin
        uart_tx_q <= uart_tx;

        if (sys_rst_n && uart_tx_q !== uart_tx) begin
            uart_edge_count <= uart_edge_count + 1;
            led4_uart_seen <= 1'b1;
        end

        if (led[1] == 1'b0) led1_ready_seen <= 1'b1;
        if (led[2] == 1'b0) led2_retire_seen <= 1'b1;
        if (led[3] == 1'b0) led3_tube_seen <= 1'b1;

        if (ext_uart_byte_valid) begin
            uart_byte_count <= uart_byte_count + 1;
            case (ext_uart_byte)
                8'h55: count_u <= count_u + 1; // U
                8'h41: count_a <= count_a + 1; // A
                8'h52: count_r <= count_r + 1; // R
                8'h54: count_t <= count_t + 1; // T
                8'h44: count_d <= count_d + 1; // D
                8'h49: count_i <= count_i + 1; // I
                8'h47: count_g <= count_g + 1; // G
                8'h50: count_p <= count_p + 1; // P
                8'h53: count_s <= count_s + 1; // S
                8'h20: saw_space <= 1'b1;
                8'h0D: saw_cr <= 1'b1;
                8'h0A: saw_lf <= 1'b1;
                default: unexpected_byte_count <= unexpected_byte_count + 1;
            endcase
        end
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_MAINLINE] TIMEOUT ready=%0b retire=%0b tube=%0b uart=%0b uart_edges=%0d uart_bytes=%0d unexpected=%0d counts U=%0d A=%0d R=%0d T=%0d D=%0d I=%0d G=%0d P=%0d S=%0d frame_count=%0d rolling=%0d led=%b",
                 led1_ready_seen, led2_retire_seen, led3_tube_seen, led4_uart_seen,
                 uart_edge_count, uart_byte_count, unexpected_byte_count,
                 count_u, count_a, count_r, count_t, count_d, count_i, count_g, count_p, count_s,
                 ext_uart_frame_count, ext_uart_frame_count_rolling, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n &&
            led1_ready_seen &&
            led2_retire_seen &&
            led3_tube_seen &&
            led4_uart_seen &&
            unexpected_byte_count == 0 &&
            count_u >= 1 &&
            count_a >= 3 &&
            count_r >= 1 &&
            count_t >= 1 &&
            count_d >= 1 &&
            count_i >= 1 &&
            count_g >= 1 &&
            count_p >= 1 &&
            count_s >= 2 &&
            saw_space &&
            saw_cr &&
            saw_lf &&
            ext_uart_frame_count_rolling >= 8'd16) begin
            $display("[AX7203_MAINLINE] PASS ready=%0b retire=%0b tube=%0b uart=%0b uart_edges=%0d uart_bytes=%0d counts U=%0d A=%0d R=%0d T=%0d D=%0d I=%0d G=%0d P=%0d S=%0d rolling=%0d led=%b",
                     led1_ready_seen, led2_retire_seen, led3_tube_seen, led4_uart_seen,
                     uart_edge_count, uart_byte_count,
                     count_u, count_a, count_r, count_t, count_d, count_i, count_g, count_p, count_s,
                     ext_uart_frame_count_rolling, led);
            $finish;
        end
    end
endmodule
