`timescale 1ns/1ps

module tb_fpga_board_smoke;
    reg sys_clk;
    reg sys_rstn;
    wire ext_irq_src = 1'b0;
    wire [2:0] led;
    wire [7:0] tube_status;
    wire uart_tx;
    wire debug_core_ready;
    wire debug_retire_seen;

    integer uart_edge_count;
    reg tube_seen;

    adam_riscv dut (
        .sys_clk          (sys_clk),
        .sys_rstn         (sys_rstn),
        .ext_irq_src      (ext_irq_src),
        .led              (led),
        .tube_status      (tube_status),
        .uart_tx          (uart_tx),
        .debug_core_ready (debug_core_ready),
        .debug_retire_seen(debug_retire_seen)
    );

    initial begin
        sys_clk = 1'b0;
        forever #2.5 sys_clk = ~sys_clk;  // 200 MHz board clock
    end

    initial begin
        sys_rstn = 1'b0;
        uart_edge_count = 0;
        tube_seen = 1'b0;
        #100;
        sys_rstn = 1'b1;
    end

    reg uart_tx_q;
    initial uart_tx_q = 1'b1;

    always @(posedge sys_clk) begin
        uart_tx_q <= uart_tx;
        if (sys_rstn && uart_tx_q !== uart_tx) begin
            uart_edge_count <= uart_edge_count + 1;
        end
    end

    always @(posedge sys_clk) begin
        if (!sys_rstn) begin
            tube_seen <= 1'b0;
        end else if (!tube_seen && tube_status == 8'h04) begin
            tube_seen <= 1'b1;
            $display("[FPGA_SMOKE] tube_status reached 0x04 at %0t", $time);
            if (debug_retire_seen !== 1'b1) begin
                $display("[FPGA_SMOKE] ERROR: tube hit before retire_seen");
                $fatal(1);
            end
        end
    end

    always @(posedge sys_clk) begin
        if (sys_rstn && uart_tx_q !== uart_tx) begin
            if (uart_edge_count == 0) begin
                $display("[FPGA_SMOKE] first UART edge at %0t", $time);
            end
        end
    end

    initial begin : timeout_guard
        #5000000;  // 5 ms
        $display("[FPGA_SMOKE] TIMEOUT: ready=%0b retire=%0b tube=%02h uart_edges=%0d",
                 debug_core_ready, debug_retire_seen, tube_status, uart_edge_count);
        $fatal(1);
    end

    always @(posedge sys_clk) begin
        if (sys_rstn && tube_seen && uart_edge_count > 4) begin
            $display("[FPGA_SMOKE] PASS: ready=%0b retire=%0b tube=%02h uart_edges=%0d",
                     debug_core_ready, debug_retire_seen, tube_status, uart_edge_count);
            $finish;
        end
    end
endmodule
