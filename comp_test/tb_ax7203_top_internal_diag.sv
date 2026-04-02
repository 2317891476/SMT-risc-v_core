`timescale 1ns/1ps

module tb_ax7203_top_internal_diag;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;
    wire board_uart_frame_seen;
    wire [3:0] board_uart_frame_count;
    wire board_uart_byte_valid;
    wire [7:0] board_uart_byte;

    integer core_serial_bytes;
    integer board_tx_starts;
    integer board_busy_cycles;
    integer board_serial_bytes;

    adam_riscv_ax7203_top dut (
        .sys_clk_p(sys_clk_p),
        .sys_clk_n(sys_clk_n),
        .sys_rst_n(sys_rst_n),
        .uart_tx(uart_tx),
        .uart_rx(uart_rx),
        .led(led)
    );

    uart_rx_monitor #(
        .CLK_DIV(1736)
    ) u_board_uart_monitor (
        .clk        (sys_clk_p             ),
        .rst_n      (dut.core_rst_n        ),
        .rx         (uart_tx               ),
        .frame_seen (board_uart_frame_seen ),
        .frame_count(board_uart_frame_count),
        .frame_count_rolling(),
        .byte_valid (board_uart_byte_valid ),
        .byte_data  (board_uart_byte       )
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
        core_serial_bytes = 0;
        board_tx_starts = 0;
        board_busy_cycles = 0;
        board_serial_bytes = 0;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge sys_clk_p) begin
        if (dut.board_tx_start) begin
            board_tx_starts <= board_tx_starts + 1;
        end
        if (dut.board_uart_busy) begin
            board_busy_cycles <= board_busy_cycles + 1;
        end
        if (dut.core_uart_byte_valid) begin
            core_serial_bytes <= core_serial_bytes + 1;
        end
        if (board_uart_byte_valid) begin
            board_serial_bytes <= board_serial_bytes + 1;
        end
    end

    initial begin
        #1_000_000;
        $display("[AX7203_TOP_INT] core_serial_bytes=%0d board_tx_starts=%0d board_busy_cycles=%0d board_serial_bytes=%0d led=%b pending=%0b frame_count=%0d",
                 core_serial_bytes, board_tx_starts, board_busy_cycles, board_serial_bytes, led,
                 dut.board_pending_valid, board_uart_frame_count);
        $finish;
    end
endmodule
