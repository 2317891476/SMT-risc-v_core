`timescale 1ns/1ps

module tb_ax7203_issue_probe_smoke;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;

    integer uart_edge_count;
    reg ready_seen;
    reg retire_seen;
    reg tube_seen;
    reg uart_tx_q;
    localparam integer TB_TIMEOUT_NS = 20_000_000;

    adam_riscv_ax7203_issue_probe_top dut (
        .sys_clk_p(sys_clk_p),
        .sys_clk_n(sys_clk_n),
        .sys_rst_n(sys_rst_n),
        .uart_tx(uart_tx),
        .uart_rx(uart_rx),
        .led(led)
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
        ready_seen = 1'b0;
        retire_seen = 1'b0;
        tube_seen = 1'b0;
        uart_tx_q = 1'b1;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge sys_clk_p) begin
        uart_tx_q <= uart_tx;
        if (sys_rst_n && uart_tx_q !== uart_tx)
            uart_edge_count <= uart_edge_count + 1;
        if (dut.core_ready)
            ready_seen <= 1'b1;
        if (dut.core_retire_seen)
            retire_seen <= 1'b1;
        if (dut.tube_status == 8'h04)
            tube_seen <= 1'b1;
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_ISSUE_PROBE] TIMEOUT ready=%0b retire=%0b tube=%0b uart_edges=%0d led=%b",
                 ready_seen, retire_seen, tube_seen, uart_edge_count, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n && ready_seen && retire_seen && tube_seen && uart_edge_count > 8) begin
            $display("[AX7203_ISSUE_PROBE] PASS ready=%0b retire=%0b tube=%0b uart_edges=%0d led=%b",
                     ready_seen, retire_seen, tube_seen, uart_edge_count, led);
            $finish;
        end
    end
endmodule
