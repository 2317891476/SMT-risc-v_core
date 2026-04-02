`timescale 1ns/1ps

module tb_fpga_board_stall_diag;
    reg sys_clk;
    reg sys_rstn;
    wire ext_irq_src = 1'b0;
    wire [2:0] led;
    wire [7:0] tube_status;
    wire uart_tx;
    wire debug_core_ready;
    wire debug_retire_seen;
    wire debug_uart_status_busy;
    wire debug_uart_busy;
    wire debug_uart_pending_valid;
    wire [7:0] debug_uart_status_load_count;
    wire [7:0] debug_uart_tx_store_count;
    wire [7:0] debug_last_iss0_pc_lo;
    wire [7:0] debug_last_iss1_pc_lo;
    wire       debug_branch_pending_any;
    wire       debug_br_found_t0;
    wire       debug_branch_in_flight_t0;
    wire       debug_oldest_br_ready_t0;
    wire       debug_oldest_br_just_woke_t0;
    wire [3:0] debug_oldest_br_qj_t0;
    wire [3:0] debug_oldest_br_qk_t0;
    wire [7:0] debug_branch_issue_count;
    wire [7:0] debug_branch_complete_count;

    integer last_uart_store_change;
    integer suspicious_cycles;
    reg [7:0] debug_uart_tx_store_count_q;

    adam_riscv dut (
        .sys_clk(sys_clk),
        .sys_rstn(sys_rstn),
        .ext_irq_src(ext_irq_src),
        .led(led),
        .tube_status(tube_status),
        .uart_tx(uart_tx),
        .debug_core_ready(debug_core_ready),
        .debug_retire_seen(debug_retire_seen),
        .debug_uart_status_busy(debug_uart_status_busy),
        .debug_uart_busy(debug_uart_busy),
        .debug_uart_pending_valid(debug_uart_pending_valid),
        .debug_uart_status_load_count(debug_uart_status_load_count),
        .debug_uart_tx_store_count(debug_uart_tx_store_count),
        .debug_last_iss0_pc_lo(debug_last_iss0_pc_lo),
        .debug_last_iss1_pc_lo(debug_last_iss1_pc_lo),
        .debug_branch_pending_any(debug_branch_pending_any),
        .debug_br_found_t0(debug_br_found_t0),
        .debug_branch_in_flight_t0(debug_branch_in_flight_t0),
        .debug_oldest_br_ready_t0(debug_oldest_br_ready_t0),
        .debug_oldest_br_just_woke_t0(debug_oldest_br_just_woke_t0),
        .debug_oldest_br_qj_t0(debug_oldest_br_qj_t0),
        .debug_oldest_br_qk_t0(debug_oldest_br_qk_t0),
        .debug_branch_issue_count(debug_branch_issue_count),
        .debug_branch_complete_count(debug_branch_complete_count)
    );

    initial begin
        sys_clk = 1'b0;
        forever #2.5 sys_clk = ~sys_clk;
    end

    initial begin
        sys_rstn = 1'b0;
        last_uart_store_change = 0;
        suspicious_cycles = 0;
        debug_uart_tx_store_count_q = 8'd0;
        #100;
        sys_rstn = 1'b1;
    end

    task automatic dump_source_slot;
        integer src_idx;
        begin
            src_idx = debug_oldest_br_qj_t0 - 1;
            $display("[STALL_DIAG] time=%0t stores=%02h loads=%02h br_issue=%02h br_complete=%02h last_iss0=%02h last_iss1=%02h",
                     $time, debug_uart_tx_store_count, debug_uart_status_load_count,
                     debug_branch_issue_count, debug_branch_complete_count,
                     debug_last_iss0_pc_lo, debug_last_iss1_pc_lo);
            $display("[STALL_DIAG] branch pending=%0b found=%0b in_flight=%0b ready=%0b just_woke=%0b qj=%0h qk=%0h",
                     debug_branch_pending_any, debug_br_found_t0, debug_branch_in_flight_t0,
                     debug_oldest_br_ready_t0, debug_oldest_br_just_woke_t0,
                     debug_oldest_br_qj_t0, debug_oldest_br_qk_t0);
            $display("[STALL_DIAG] reg_result[a2]=tag %0d order=%0d tag_ready[2]=%0b just_ready[2]=%0b live_order[2]=%0d",
                     dut.u_scoreboard.reg_result[0][12],
                     dut.u_scoreboard.reg_result_order[0][12],
                     dut.u_scoreboard.tag_result_ready[2],
                     dut.u_scoreboard.tag_result_just_ready[2],
                     dut.u_scoreboard.tag_live_order[2]);
            if (debug_oldest_br_qj_t0 != 4'd0) begin
                $display("[STALL_DIAG] src slot idx=%0d valid=%0b issued=%0b ready=%0b just_woke=%0b br=%0b pc=%h qj=%0d qk=%0d order=%0d",
                         src_idx,
                         dut.u_scoreboard.win_valid[src_idx],
                         dut.u_scoreboard.win_issued[src_idx],
                         dut.u_scoreboard.win_ready[src_idx],
                         dut.u_scoreboard.win_just_woke[src_idx],
                         dut.u_scoreboard.win_br[src_idx],
                         dut.u_scoreboard.win_pc[src_idx],
                         dut.u_scoreboard.win_qj[src_idx],
                         dut.u_scoreboard.win_qk[src_idx],
                         dut.u_scoreboard.win_order_id[src_idx]);
            end
        end
    endtask

    always @(posedge sys_clk) begin
        if (!sys_rstn) begin
            debug_uart_tx_store_count_q <= 8'd0;
            last_uart_store_change <= 0;
            suspicious_cycles <= 0;
        end else begin
            if (debug_uart_tx_store_count != debug_uart_tx_store_count_q) begin
                debug_uart_tx_store_count_q <= debug_uart_tx_store_count;
                last_uart_store_change <= 0;
            end else begin
                last_uart_store_change <= last_uart_store_change + 1;
            end

            if (debug_br_found_t0 &&
                !debug_branch_in_flight_t0 &&
                !debug_oldest_br_ready_t0 &&
                (debug_oldest_br_qj_t0 != 4'd0)) begin
                suspicious_cycles <= suspicious_cycles + 1;
            end else begin
                suspicious_cycles <= 0;
            end

            if (suspicious_cycles == 32'd50000 && last_uart_store_change > 32'd50000) begin
                dump_source_slot();
                $finish;
            end
        end
    end

    initial begin
        #30000000;  // 30 ms
        $display("[STALL_DIAG] TIMEOUT stores=%02h loads=%02h br_found=%0b in_flight=%0b ready=%0b qj=%0h qk=%0h",
                 debug_uart_tx_store_count, debug_uart_status_load_count,
                 debug_br_found_t0, debug_branch_in_flight_t0,
                 debug_oldest_br_ready_t0, debug_oldest_br_qj_t0, debug_oldest_br_qk_t0);
        dump_source_slot();
        $finish;
    end
endmodule
