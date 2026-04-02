`timescale 1ns/1ps

module tb_ax7203_status_top_smoke;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;

    integer uart_edge_count;
    reg led1_ready_seen;
    reg led2_retire_seen;
    reg led3_tube_seen;
    reg led4_uart_seen;
    reg frame_seen;
    reg multi_frame_seen;
    reg uart_tx_q;

    adam_riscv_ax7203_status_top dut (
        .sys_clk_p (sys_clk_p),
        .sys_clk_n (sys_clk_n),
        .sys_rst_n (sys_rst_n),
        .uart_tx   (uart_tx  ),
        .uart_rx   (uart_rx  ),
        .led       (led      )
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
        led1_ready_seen = 1'b0;
        led2_retire_seen = 1'b0;
        led3_tube_seen = 1'b0;
        led4_uart_seen = 1'b0;
        frame_seen = 1'b0;
        multi_frame_seen = 1'b0;
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
        if (dut.core_uart_frame_seen) frame_seen <= 1'b1;
        if (dut.core_uart_frame_count >= 4'd2) multi_frame_seen <= 1'b1;
    end

    initial begin : timeout_guard
        #6000000;  // 6 ms
        $display("[AX7203_STATUS] TIMEOUT led1_ready=%0b led2_retire=%0b led3_tube=%0b led4_uart=%0b frame_seen=%0b multi_frame=%0b frame_count=%0d uart_edges=%0d led=%b",
                 led1_ready_seen, led2_retire_seen, led3_tube_seen, led4_uart_seen, frame_seen, multi_frame_seen, dut.core_uart_frame_count, uart_edge_count, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n &&
            led1_ready_seen &&
            led2_retire_seen &&
            led3_tube_seen &&
            frame_seen &&
            multi_frame_seen &&
            led4_uart_seen &&
            uart_edge_count > 8) begin
            $display("[AX7203_STATUS] PASS led1_ready=%0b led2_retire=%0b led3_tube=%0b led4_uart=%0b frame_seen=%0b multi_frame=%0b frame_count=%0d uart_edges=%0d led=%b",
                     led1_ready_seen, led2_retire_seen, led3_tube_seen, led4_uart_seen, frame_seen, multi_frame_seen, dut.core_uart_frame_count, uart_edge_count, led);
            $finish;
        end
    end
endmodule
