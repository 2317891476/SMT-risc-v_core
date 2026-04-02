`timescale 1ns/1ps

module tb_uart_tx_unit;
    localparam integer CLK_DIV = 4;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    reg tx_start = 1'b0;
    reg [7:0] tx_data = 8'h00;
    wire tx;
    wire busy;

    integer i;

    uart_tx #(
        .CLK_DIV(CLK_DIV)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_start (tx_start),
        .tx_data  (tx_data),
        .tx       (tx),
        .busy     (busy)
    );

    always #5 clk = ~clk;

    task expect_tx;
        input expected;
        input integer cycles;
        begin
            for (i = 0; i < cycles; i = i + 1) begin
                @(posedge clk);
                if (tx !== expected) begin
                    $display("UART mismatch at cycle %0d: expected %0b got %0b", i, expected, tx);
                    $fatal(1);
                end
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        tx_data  <= 8'hA5;
        tx_start <= 1'b1;
        @(posedge clk);
        tx_start <= 1'b0;
        #1;

        if (!busy) begin
            $display("UART failed to assert busy after tx_start");
            $fatal(1);
        end

        expect_tx(1'b0, CLK_DIV);  // start
        expect_tx(1'b1, CLK_DIV);  // bit0
        expect_tx(1'b0, CLK_DIV);  // bit1
        expect_tx(1'b1, CLK_DIV);  // bit2
        expect_tx(1'b0, CLK_DIV);  // bit3
        expect_tx(1'b0, CLK_DIV);  // bit4
        expect_tx(1'b1, CLK_DIV);  // bit5
        expect_tx(1'b0, CLK_DIV);  // bit6
        expect_tx(1'b1, CLK_DIV);  // bit7
        expect_tx(1'b1, CLK_DIV);  // stop

        @(posedge clk);
        if (busy || tx !== 1'b1) begin
            $display("UART failed to return idle: busy=%0b tx=%0b", busy, tx);
            $fatal(1);
        end

        $display("tb_uart_tx_unit PASS");
        $finish;
    end
endmodule
