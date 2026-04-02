`timescale 1ns/1ps

module tb_ax7203_io_smoke;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;

    integer uart_edge_count;
    reg led_ready_seen;
    reg led_uart_seen;
    reg uart_tx_q;

    adam_riscv_ax7203_io_smoke_top dut (
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
        led_ready_seen = 1'b0;
        led_uart_seen = 1'b0;
        uart_tx_q = 1'b1;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge sys_clk_p) begin
        uart_tx_q <= uart_tx;

        if (sys_rst_n && uart_tx_q !== uart_tx) begin
            uart_edge_count <= uart_edge_count + 1;
            led_uart_seen <= 1'b1;
        end

        if (led[1] == 1'b0) led_ready_seen <= 1'b1;
    end

    initial begin : timeout_guard
        #30000000;  // 30 ms
        $display("[AX7203_IO_SMOKE] TIMEOUT ready=%0b uart=%0b edges=%0d led=%b",
                 led_ready_seen, led_uart_seen, uart_edge_count, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n &&
            led_ready_seen &&
            led_uart_seen &&
            uart_edge_count > 8) begin
            $display("[AX7203_IO_SMOKE] PASS ready=%0b uart=%0b edges=%0d led=%b",
                     led_ready_seen, led_uart_seen, uart_edge_count, led);
            $finish;
        end
    end
endmodule
