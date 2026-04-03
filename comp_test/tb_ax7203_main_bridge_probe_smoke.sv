`timescale 1ns/1ps

module tb_ax7203_main_bridge_probe_smoke;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;
    wire probe_uart_frame_seen;
    wire [3:0] probe_uart_frame_count;

    reg led1_ready_seen;
    reg led2_retire_seen;
    reg led3_tube_seen;
    reg led4_uart_seen;
    reg uart_tx_q;
    localparam integer TB_TIMEOUT_NS = 20_000_000;

    adam_riscv_ax7203_main_bridge_probe_top dut (
        .sys_clk_p(sys_clk_p),
        .sys_clk_n(sys_clk_n),
        .sys_rst_n(sys_rst_n),
        .uart_tx(uart_tx),
        .uart_rx(uart_rx),
        .led(led)
    );

    uart_rx_monitor #(
        .CLK_DIV(1736)
    ) u_probe_uart_monitor (
        .clk                (sys_clk_p            ),
        .rst_n              (dut.core_rst_n       ),
        .rx                 (uart_tx              ),
        .frame_seen         (probe_uart_frame_seen),
        .frame_count        (probe_uart_frame_count),
        .frame_count_rolling(),
        .byte_valid         (),
        .byte_data          ()
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
        led1_ready_seen = 1'b0;
        led2_retire_seen = 1'b0;
        led3_tube_seen = 1'b0;
        led4_uart_seen = 1'b0;
        uart_tx_q = 1'b1;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge sys_clk_p) begin
        uart_tx_q <= uart_tx;

        if (sys_rst_n && uart_tx_q !== uart_tx) begin
            led4_uart_seen <= 1'b1;
        end

        if (led[1] == 1'b0) led1_ready_seen <= 1'b1;
        if (led[2] == 1'b0) led2_retire_seen <= 1'b1;
        if (led[3] == 1'b0) led3_tube_seen <= 1'b1;
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_MAIN_BRIDGE_PROBE] TIMEOUT led1_ready=%0b led2_retire=%0b led3_tube=%0b led4_uart=%0b core_frames=%0d board_tx_starts=%0d board_frames=%0d probe_frames=%0d led=%b",
                 led1_ready_seen, led2_retire_seen, led3_tube_seen, led4_uart_seen,
                 dut.core_uart_frame_count_rolling, dut.board_tx_start_count,
                 dut.board_uart_frame_count_rolling, probe_uart_frame_count, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n &&
            led1_ready_seen &&
            led2_retire_seen &&
            led3_tube_seen &&
            led4_uart_seen &&
            dut.core_uart_frame_count_rolling >= 8'd4 &&
            dut.board_tx_start_count >= 8'd4 &&
            dut.board_uart_frame_count_rolling >= 8'd4 &&
            probe_uart_frame_count >= 4'd2) begin
            $display("[AX7203_MAIN_BRIDGE_PROBE] PASS led1_ready=%0b led2_retire=%0b led3_tube=%0b led4_uart=%0b core_frames=%0d board_tx_starts=%0d board_frames=%0d probe_frames=%0d led=%b",
                     led1_ready_seen, led2_retire_seen, led3_tube_seen, led4_uart_seen,
                     dut.core_uart_frame_count_rolling, dut.board_tx_start_count,
                     dut.board_uart_frame_count_rolling, probe_uart_frame_count, led);
            $finish;
        end
    end
endmodule
