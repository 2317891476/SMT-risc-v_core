`timescale 1ns/1ps

module tb_ax7203_benchmark_smoke;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;
    wire core_uart_byte_valid_dbg = dut.core_uart_byte_valid_dbg;
    wire [7:0] core_uart_byte_dbg = dut.core_uart_byte_dbg;

    integer uart_byte_count;
    reg led1_ready_seen;
    reg led2_retire_seen;
    reg led3_tube_seen;
    reg led4_uart_seen;
    reg [31:0] uart_token_shift;
    reg bench_done_seen;
    localparam integer TB_TIMEOUT_NS = 100_000_000;

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
        uart_byte_count = 0;
        led1_ready_seen = 1'b0;
        led2_retire_seen = 1'b0;
        led3_tube_seen = 1'b0;
        led4_uart_seen = 1'b0;
        uart_token_shift = 32'd0;
        bench_done_seen = 1'b0;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge sys_clk_p) begin
        if (led[1] == 1'b0) led1_ready_seen <= 1'b1;
        if (led[2] == 1'b0) led2_retire_seen <= 1'b1;
        if (led[3] == 1'b0) led3_tube_seen <= 1'b1;
        if (core_uart_byte_valid_dbg) begin
            led4_uart_seen <= 1'b1;
            uart_byte_count <= uart_byte_count + 1;
            uart_token_shift <= {uart_token_shift[23:0], core_uart_byte_dbg};
            if ({uart_token_shift[23:0], core_uart_byte_dbg} == 32'h444F4E45) begin
                bench_done_seen <= 1'b1;
            end
        end
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_BENCH] TIMEOUT led1_ready=%0b led2_retire=%0b led3_tube=%0b led4_uart=%0b uart_bytes=%0d done_seen=%0b led=%b",
                 led1_ready_seen, led2_retire_seen, led3_tube_seen, led4_uart_seen,
                 uart_byte_count, bench_done_seen, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n &&
            led1_ready_seen &&
            led2_retire_seen &&
            led3_tube_seen &&
            led4_uart_seen &&
            bench_done_seen &&
            uart_byte_count >= 16) begin
            $display("[AX7203_BENCH] PASS led1_ready=%0b led2_retire=%0b led3_tube=%0b led4_uart=%0b uart_bytes=%0d frame_count=%0d led=%b",
                     led1_ready_seen, led2_retire_seen, led3_tube_seen, led4_uart_seen,
                     uart_byte_count, 0, led);
            $finish;
        end
    end
endmodule
