`timescale 1ns/1ps

module tb_ax7203_top_smoke;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;

    integer uart_edge_count;
    integer uart_byte_count;
    reg led1_ready_seen;
    reg led2_retire_seen;
    reg led3_tube_seen;
    reg led4_uart_seen;
    reg uart_tx_q;
    reg uart_prefix_seen;
    reg uart_stream_seen;
    wire ext_uart_frame_seen;
    wire [3:0] ext_uart_frame_count;
    wire ext_uart_byte_valid;
    wire [7:0] ext_uart_byte;

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
        .clk        (sys_clk_p           ),
        .rst_n      (dut.core_rst_n      ),
        .rx         (uart_tx             ),
        .frame_seen (ext_uart_frame_seen ),
        .frame_count(ext_uart_frame_count),
        .byte_valid (ext_uart_byte_valid ),
        .byte_data  (ext_uart_byte       )
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
        led1_ready_seen = 1'b0;
        led2_retire_seen = 1'b0;
        led3_tube_seen = 1'b0;
        led4_uart_seen = 1'b0;
        uart_tx_q = 1'b1;
        uart_prefix_seen = 1'b0;
        uart_stream_seen = 1'b0;
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
            if (uart_byte_count == 0 && ext_uart_byte == 8'h55) uart_prefix_seen <= 1'b1;
            else if (uart_byte_count == 1 && uart_prefix_seen && ext_uart_byte == 8'h41) uart_prefix_seen <= 1'b1;
            else if (uart_byte_count == 2 && uart_prefix_seen && ext_uart_byte == 8'h52) uart_prefix_seen <= 1'b1;
            else if (uart_byte_count == 3 && uart_prefix_seen && ext_uart_byte == 8'h54) begin
                uart_prefix_seen <= 1'b1;
                uart_stream_seen <= 1'b1;
            end else if (uart_byte_count < 4) begin
                uart_prefix_seen <= 1'b0;
            end
        end
    end

    initial begin : timeout_guard
        #8000000;  // 8 ms
        $display("[AX7203_TOP] TIMEOUT led1_ready=%0b led2_retire=%0b led3_tube=%0b led4_uart=%0b uart_edges=%0d uart_bytes=%0d frame_seen=%0b frame_count=%0d stream_seen=%0b led=%b",
                 led1_ready_seen, led2_retire_seen,
                 led3_tube_seen, led4_uart_seen, uart_edge_count, uart_byte_count,
                 ext_uart_frame_seen, ext_uart_frame_count, uart_stream_seen, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n &&
            led1_ready_seen &&
            led2_retire_seen &&
            led3_tube_seen &&
            led4_uart_seen &&
            uart_stream_seen &&
            ext_uart_frame_count >= 4'd4) begin
            $display("[AX7203_TOP] PASS led1_ready=%0b led2_retire=%0b led3_tube=%0b led4_uart=%0b uart_edges=%0d uart_bytes=%0d frame_count=%0d led=%b",
                     led1_ready_seen, led2_retire_seen,
                     led3_tube_seen, led4_uart_seen, uart_edge_count, uart_byte_count, ext_uart_frame_count, led);
            $finish;
        end
    end
endmodule
