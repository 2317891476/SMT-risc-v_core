`timescale 1ns/1ps

module tb_ax7203_core_uart_diag;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;

    integer uart_edge_count;
    integer uart_fall_count;
    reg uart_tx_q;

    adam_riscv_ax7203_top dut (
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
        uart_fall_count = 0;
        uart_tx_q = 1'b1;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge sys_clk_p) begin
        uart_tx_q <= uart_tx;
        if (sys_rst_n && uart_tx_q !== uart_tx) begin
            uart_edge_count <= uart_edge_count + 1;
        end
        if (sys_rst_n && uart_tx_q == 1'b1 && uart_tx == 1'b0) begin
            uart_fall_count <= uart_fall_count + 1;
        end
    end

    initial begin : timeout_guard
        #5000000;  // 5 ms
        $display("[AX7203_CORE_UART] RESULT edges=%0d starts=%0d led=%b ready=%0b retire=%0b tube=%0h",
                 uart_edge_count,
                 uart_fall_count,
                 led,
                 dut.core_ready,
                 dut.core_retire_seen,
                 dut.tube_status);
        if (uart_edge_count > 40 && uart_fall_count > 4) begin
            $display("[AX7203_CORE_UART] PASS");
            $finish;
        end
        $fatal(1, "[AX7203_CORE_UART] FAIL: UART activity too low");
    end
endmodule
