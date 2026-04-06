`timescale 1ns/1ps

module tb_ax7203_status_diag_smoke;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;

    integer uart_edge_count;
    reg led1_ready_seen;
    reg led2_retire_seen;
    reg led4_uart_seen;
    reg uart_tx_q;
    localparam integer TB_TIMEOUT_NS = 20_000_000;

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
        led4_uart_seen = 1'b0;
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
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_STATUS_DIAG] TIMEOUT led1_ready=%0b led2_retire=%0b led4_uart=%0b status_frame_count=%0d uart_edges=%0d led=%b",
                 led1_ready_seen, led2_retire_seen, led4_uart_seen, dut.status_uart_frame_count, uart_edge_count, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n &&
            led1_ready_seen &&
            led2_retire_seen &&
            led4_uart_seen &&
            dut.status_uart_frame_count >= 4'd2 &&
            uart_edge_count > 8) begin
            $display("[AX7203_STATUS_DIAG] PASS led1_ready=%0b led2_retire=%0b led4_uart=%0b status_frame_count=%0d uart_edges=%0d led=%b",
                     led1_ready_seen, led2_retire_seen, led4_uart_seen, dut.status_uart_frame_count, uart_edge_count, led);
            $finish;
        end
    end
endmodule
