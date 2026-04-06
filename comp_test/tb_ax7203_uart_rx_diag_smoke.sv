`timescale 1ns/1ps

module tb_ax7203_uart_rx_diag_smoke;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;

    reg sent_uart_byte;
    reg echoed_valid;
    reg [7:0] last_uart_byte;
    reg led1_ready_seen;
    reg led2_retire_seen;
    reg led3_tube_seen;
    reg waiting_seen;
    reg valid_marker_seen;

    wire ext_uart_byte_valid;
    wire [7:0] ext_uart_byte;
    wire [3:0] ext_uart_frame_count;

    localparam integer UART_BIT_NS = 8680;
    localparam [7:0] TEST_BYTE = 8'h5A;
    localparam integer TB_TIMEOUT_NS = 36_000_000;

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
        .frame_seen (                    ),
        .frame_count(ext_uart_frame_count),
        .byte_valid (ext_uart_byte_valid ),
        .byte_data  (ext_uart_byte       )
    );

    task automatic send_uart_byte(input [7:0] data);
        integer bit_idx;
        begin
            uart_rx = 1'b0;
            #(UART_BIT_NS);
            for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                uart_rx = data[bit_idx];
                #(UART_BIT_NS);
            end
            uart_rx = 1'b1;
            #(UART_BIT_NS);
        end
    endtask

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
        sent_uart_byte = 1'b0;
        echoed_valid = 1'b0;
        last_uart_byte = 8'd0;
        led1_ready_seen = 1'b0;
        led2_retire_seen = 1'b0;
        led3_tube_seen = 1'b0;
        waiting_seen = 1'b0;
        valid_marker_seen = 1'b0;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge sys_clk_p) begin
        if (led[1] == 1'b0) led1_ready_seen <= 1'b1;
        if (led[2] == 1'b0) led2_retire_seen <= 1'b1;
        if (led[3] == 1'b0) led3_tube_seen <= 1'b1;

        if (!sent_uart_byte && led1_ready_seen) begin
            sent_uart_byte <= 1'b1;
            fork
                begin
                    #(UART_BIT_NS * 8);
                    send_uart_byte(TEST_BYTE);
                end
            join_none
        end

        if (ext_uart_byte_valid) begin
            last_uart_byte <= ext_uart_byte;
            if (ext_uart_byte == "W" || ext_uart_byte == "R") begin
                waiting_seen <= 1'b1;
            end
            if (ext_uart_byte == "V") begin
                valid_marker_seen <= 1'b1;
            end
            if (ext_uart_byte == TEST_BYTE) begin
                echoed_valid <= 1'b1;
            end
        end
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_UART_RX_DIAG] TIMEOUT ready=%0b retire=%0b tube=%0b sent=%0b waiting=%0b valid=%0b echoed=%0b last=%02h frame_count=%0d led=%b",
                 led1_ready_seen, led2_retire_seen, led3_tube_seen, sent_uart_byte,
                 waiting_seen, valid_marker_seen, echoed_valid, last_uart_byte, ext_uart_frame_count, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n &&
            sent_uart_byte &&
            led1_ready_seen &&
            led2_retire_seen &&
            led3_tube_seen &&
            valid_marker_seen &&
            echoed_valid) begin
            $display("[AX7203_UART_RX_DIAG] PASS ready=%0b retire=%0b tube=%0b waiting=%0b valid=%0b echoed=%0b last=%02h frame_count=%0d led=%b",
                     led1_ready_seen, led2_retire_seen, led3_tube_seen,
                     waiting_seen, valid_marker_seen, echoed_valid, last_uart_byte, ext_uart_frame_count, led);
            $finish;
        end
    end
endmodule
