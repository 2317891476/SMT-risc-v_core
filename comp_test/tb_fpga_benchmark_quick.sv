`timescale 1ns/1ps

module tb_fpga_benchmark_quick;
    reg sys_clk;
    reg sys_rstn;

    wire [2:0] led;
    wire [7:0] tube_status;
    wire uart_tx;
    wire debug_core_ready;
    wire debug_retire_seen;
    wire debug_uart_status_busy;
    wire [7:0] debug_uart_status_load_count;
    wire [7:0] debug_uart_tx_store_count;
    wire debug_uart_tx_byte_valid;
    wire [7:0] debug_uart_tx_byte;
    wire [7:0] debug_last_iss0_pc_lo;
    wire [7:0] debug_last_iss1_pc_lo;
    wire debug_branch_pending_any;
    wire debug_br_found_t0;
    wire debug_branch_in_flight_t0;
    wire debug_oldest_br_ready_t0;
    wire debug_oldest_br_just_woke_t0;
    wire [3:0] debug_oldest_br_qj_t0;
    wire [3:0] debug_oldest_br_qk_t0;
    wire [15:0] debug_rs_flags_flat;
    wire [31:0] debug_rs_pc_lo_flat;
    wire [15:0] debug_rs_qj_flat;
    wire [15:0] debug_rs_qk_flat;
    wire legacy_uart_write_fire = dut.gen_legacy_mem.u_legacy_mem_subsys.uart_write_fire;
    wire [7:0] legacy_uart_store_count = dut.gen_legacy_mem.u_legacy_mem_subsys.debug_uart_tx_store_count;
    wire [7:0] legacy_uart_status_load_count = dut.gen_legacy_mem.u_legacy_mem_subsys.debug_uart_status_load_count;
    wire [5:0] sp_tag_t0 = dut.u_scoreboard.reg_result[0][2];
    wire [15:0] sp_tag_order_t0 = dut.u_scoreboard.reg_result_order[0][2];
    wire [31:0] sp_arch_t0 = dut.u_regs_mt.reg_bank[0][2];
    wire [31:0] x10_a0_t0 = dut.u_regs_mt.reg_bank[0][10];
    wire [31:0] x11_a1_t0 = dut.u_regs_mt.reg_bank[0][11];
    wire [31:0] x14_a4_t0 = dut.u_regs_mt.reg_bank[0][14];
    wire [31:0] x15_a5_t0 = dut.u_regs_mt.reg_bank[0][15];
    wire [2:0] lsu_state = {1'b0, dut.u_lsu_shell.lsu_state};
    wire lsu_pending_valid = dut.u_lsu_shell.pending_valid;
    wire lsu_pending_wen = dut.u_lsu_shell.pending_wen;
    wire [31:0] lsu_pending_addr = dut.u_lsu_shell.pending_addr;
    wire [31:0] lsu_mem_addr = dut.lsu_mem_addr;
    wire [3:0] lsu_mem_read = dut.lsu_mem_read;
    wire sb_mem_write_valid = dut.sb_mem_write_valid;
    wire [31:0] sb_mem_write_addr = dut.sb_mem_write_addr;
    wire [31:0] sb_mem_write_data = dut.sb_mem_write_data;
    wire sb_mem_write_ready = dut.sb_mem_write_ready;
    wire [4:0] sb_count_t0 = dut.u_lsu_shell.u_store_buffer.sb_count[0];
    wire [4:0] sb_count_t1 = dut.u_lsu_shell.u_store_buffer.sb_count[1];
    wire [3:0] sb_head_t0 = dut.u_lsu_shell.u_store_buffer.sb_head[0];
    wire [3:0] sb_tail_t0 = dut.u_lsu_shell.u_store_buffer.sb_tail[0];
    wire [4:0] rob_count_t0 = dut.u_rob_lite.rob_count[0];
    wire [4:0] rob_count_t1 = dut.u_rob_lite.rob_count[1];
    wire lsu_resp_valid = dut.lsu_resp_valid;
    wire store_enqueue_fire = dut.u_lsu_shell.store_enqueue_fire;
    wire rob_commit0_valid = dut.rob_commit0_valid;
    wire rob_commit1_valid = dut.rob_commit1_valid;

    integer legacy_uart_fire_count;
    integer lsu_resp_count;
    integer store_enqueue_count;
    integer rob_commit_count_t0;
    integer rob_commit_count_t1;
    integer sb_drain_count;
    integer rs_idx;

    integer uart_byte_count;
    reg [31:0] uart_token_shift;
    reg bench_done_seen;
    localparam integer TB_TIMEOUT_NS = 50_000_000;

    adam_riscv dut (
        .sys_clk                   (sys_clk                 ),
        .sys_rstn                  (sys_rstn                ),
        .uart_rx                   (1'b1                    ),
        .ext_irq_src               (1'b0                    ),
        .led                       (led                     ),
        .tube_status               (tube_status             ),
        .uart_tx                   (uart_tx                 ),
        .debug_core_ready          (debug_core_ready        ),
        .debug_core_clk            (                       ),
        .debug_retire_seen         (debug_retire_seen       ),
        .debug_uart_status_busy    (debug_uart_status_busy  ),
        .debug_uart_busy           (                       ),
        .debug_uart_pending_valid  (                       ),
        .debug_uart_status_load_count(debug_uart_status_load_count),
        .debug_uart_tx_store_count (debug_uart_tx_store_count),
        .debug_uart_tx_byte_valid  (debug_uart_tx_byte_valid),
        .debug_uart_tx_byte        (debug_uart_tx_byte      ),
        .debug_last_iss0_pc_lo     (debug_last_iss0_pc_lo  ),
        .debug_last_iss1_pc_lo     (debug_last_iss1_pc_lo  ),
        .debug_branch_pending_any  (debug_branch_pending_any),
        .debug_br_found_t0         (debug_br_found_t0      ),
        .debug_branch_in_flight_t0 (debug_branch_in_flight_t0),
        .debug_oldest_br_ready_t0  (debug_oldest_br_ready_t0),
        .debug_oldest_br_just_woke_t0(debug_oldest_br_just_woke_t0),
        .debug_oldest_br_qj_t0     (debug_oldest_br_qj_t0  ),
        .debug_oldest_br_qk_t0     (debug_oldest_br_qk_t0  ),
        .debug_slot1_flags         (                       ),
        .debug_slot1_pc_lo         (                       ),
        .debug_slot1_qj            (                       ),
        .debug_slot1_qk            (                       ),
        .debug_tag2_flags          (                       ),
        .debug_reg_x12_tag_t0      (                       ),
        .debug_slot1_issue_flags   (                       ),
        .debug_sel0_idx            (                       ),
        .debug_slot1_fu            (                       ),
        .debug_oldest_br_seq_lo_t0 (                       ),
        .debug_rs_flags_flat       (debug_rs_flags_flat    ),
        .debug_rs_pc_lo_flat       (debug_rs_pc_lo_flat    ),
        .debug_rs_fu_flat          (                       ),
        .debug_rs_qj_flat          (debug_rs_qj_flat       ),
        .debug_rs_qk_flat          (debug_rs_qk_flat       ),
        .debug_rs_seq_lo_flat      (                       ),
        .debug_branch_issue_count  (                       ),
        .debug_branch_complete_count()
    );

    initial begin
        sys_clk = 1'b0;
        forever #2.5 sys_clk = ~sys_clk;
    end

    initial begin
        sys_rstn = 1'b0;
        uart_byte_count = 0;
        uart_token_shift = 32'd0;
        bench_done_seen = 1'b0;
        legacy_uart_fire_count = 0;
        lsu_resp_count = 0;
        store_enqueue_count = 0;
        rob_commit_count_t0 = 0;
        rob_commit_count_t1 = 0;
        sb_drain_count = 0;
        #100;
        sys_rstn = 1'b1;
    end

    always @(posedge sys_clk) begin
        if (legacy_uart_write_fire) begin
            legacy_uart_fire_count <= legacy_uart_fire_count + 1;
        end
        if (debug_uart_tx_byte_valid) begin
            uart_byte_count <= uart_byte_count + 1;
            uart_token_shift <= {uart_token_shift[23:0], debug_uart_tx_byte};
            if ({uart_token_shift[23:0], debug_uart_tx_byte} == 32'h444F4E45) begin
                bench_done_seen <= 1'b1;
            end
        end
        if (lsu_resp_valid) begin
            lsu_resp_count <= lsu_resp_count + 1;
        end
        if (store_enqueue_fire) begin
            store_enqueue_count <= store_enqueue_count + 1;
        end
        if (rob_commit0_valid) begin
            rob_commit_count_t0 <= rob_commit_count_t0 + 1;
        end
        if (rob_commit1_valid) begin
            rob_commit_count_t1 <= rob_commit_count_t1 + 1;
        end
        if (sb_mem_write_valid && sb_mem_write_ready) begin
            sb_drain_count <= sb_drain_count + 1;
        end
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[FPGA_BENCH_QUICK] TIMEOUT ready=%0b retire=%0b tube=%02h uart_bytes=%0d done_seen=%0b pc0_lo=%02h pc1_lo=%02h uart_busy=%0b uart_status_loads=%0d uart_tx_stores=%0d legacy_status_loads=%0d legacy_tx_stores=%0d legacy_fire=%0d",
                 debug_core_ready, debug_retire_seen, tube_status, uart_byte_count, bench_done_seen,
                 debug_last_iss0_pc_lo, debug_last_iss1_pc_lo,
                 debug_uart_status_busy, debug_uart_status_load_count, debug_uart_tx_store_count,
                 legacy_uart_status_load_count, legacy_uart_store_count, legacy_uart_fire_count);
        $display("[FPGA_BENCH_QUICK] BR pending=%0b found=%0b inflight=%0b oldest_ready=%0b just_woke=%0b qj=%0d qk=%0d rs_flags=%h rs_pc=%h rs_qj=%h rs_qk=%h",
                 debug_branch_pending_any, debug_br_found_t0, debug_branch_in_flight_t0,
                 debug_oldest_br_ready_t0, debug_oldest_br_just_woke_t0,
                 debug_oldest_br_qj_t0, debug_oldest_br_qk_t0,
                 debug_rs_flags_flat, debug_rs_pc_lo_flat, debug_rs_qj_flat, debug_rs_qk_flat);
        $display("[FPGA_BENCH_QUICK] LSU state=%0d pending_valid=%0b pending_wen=%0b pending_addr=%08h mem_addr=%08h mem_read=%b sb_valid=%0b sb_addr=%08h sb_data=%08h",
                 lsu_state, lsu_pending_valid, lsu_pending_wen, lsu_pending_addr,
                 lsu_mem_addr, lsu_mem_read, sb_mem_write_valid, sb_mem_write_addr, sb_mem_write_data);
        $display("[FPGA_BENCH_QUICK] EP1 slot0 v=%0b tag=%0d ord=%0d addr=%08h wen=%0b | slot1 v=%0b tag=%0d ord=%0d addr=%08h wen=%0b",
                 dut.u_exec_pipe1.mem_req_valid_r,
                 dut.u_exec_pipe1.mem_req_tag_r,
                 dut.u_exec_pipe1.mem_req_order_id_r,
                 dut.u_exec_pipe1.mem_req_addr_r,
                 dut.u_exec_pipe1.mem_req_wen_r,
                 dut.u_exec_pipe1.mem_req_q1_valid_r,
                 dut.u_exec_pipe1.mem_req_q1_tag_r,
                 dut.u_exec_pipe1.mem_req_q1_order_id_r,
                 dut.u_exec_pipe1.mem_req_q1_addr_r,
                 dut.u_exec_pipe1.mem_req_q1_wen_r);
        $display("[FPGA_BENCH_QUICK] SP arch=%08h tag=%0d tag_order=%0d sb_count_t0=%0d sb_head_t0=%0d sb_tail_t0=%0d sb_count_t1=%0d rob_count_t0=%0d rob_count_t1=%0d",
                 sp_arch_t0, sp_tag_t0, sp_tag_order_t0,
                 sb_count_t0, sb_head_t0, sb_tail_t0, sb_count_t1, rob_count_t0, rob_count_t1);
        $display("[FPGA_BENCH_QUICK] REGS a0=%08h a1=%08h a4=%08h a5=%08h",
                 x10_a0_t0, x11_a1_t0, x14_a4_t0, x15_a5_t0);
        $display("[FPGA_BENCH_QUICK] COUNTS lsu_resp=%0d store_enqueue=%0d rob_commit_t0=%0d rob_commit_t1=%0d sb_drain=%0d",
                 lsu_resp_count, store_enqueue_count, rob_commit_count_t0, rob_commit_count_t1, sb_drain_count);
        $display("[FPGA_BENCH_QUICK] ROB_HEAD t0 idx=%0d valid=%0b complete=%0b flushed=%0b is_store=%0b tag=%0d order=%0d rd=%0d",
                 dut.u_rob_lite.rob_head[0],
                 dut.u_rob_lite.rob_valid[0][dut.u_rob_lite.rob_head[0]],
                 dut.u_rob_lite.rob_complete[0][dut.u_rob_lite.rob_head[0]],
                 dut.u_rob_lite.rob_flushed[0][dut.u_rob_lite.rob_head[0]],
                 dut.u_rob_lite.rob_is_store[0][dut.u_rob_lite.rob_head[0]],
                 dut.u_rob_lite.rob_tag[0][dut.u_rob_lite.rob_head[0]],
                 dut.u_rob_lite.rob_order_id[0][dut.u_rob_lite.rob_head[0]],
                 dut.u_rob_lite.rob_rd[0][dut.u_rob_lite.rob_head[0]]);
        $display("[FPGA_BENCH_QUICK] SB_HEAD t0 idx=%0d valid=%0b committed=%0b addr=%08h data=%08h func3=%0d order=%0d",
                 dut.u_lsu_shell.u_store_buffer.sb_head[0],
                 dut.u_lsu_shell.u_store_buffer.sb_valid[0][dut.u_lsu_shell.u_store_buffer.sb_head[0]],
                 dut.u_lsu_shell.u_store_buffer.sb_committed[0][dut.u_lsu_shell.u_store_buffer.sb_head[0]],
                 dut.u_lsu_shell.u_store_buffer.sb_addr[0][dut.u_lsu_shell.u_store_buffer.sb_head[0]],
                 dut.u_lsu_shell.u_store_buffer.sb_data[0][dut.u_lsu_shell.u_store_buffer.sb_head[0]],
                 dut.u_lsu_shell.u_store_buffer.sb_func3[0][dut.u_lsu_shell.u_store_buffer.sb_head[0]],
                 dut.u_lsu_shell.u_store_buffer.sb_order_id[0][dut.u_lsu_shell.u_store_buffer.sb_head[0]]);
        $display("[FPGA_BENCH_QUICK] ROB0[0] v=%0b c=%0b s=%0b tag=%0d ord=%0d | ROB0[1] v=%0b c=%0b s=%0b tag=%0d ord=%0d",
                 dut.u_rob_lite.rob_valid[0][0], dut.u_rob_lite.rob_complete[0][0], dut.u_rob_lite.rob_is_store[0][0], dut.u_rob_lite.rob_tag[0][0], dut.u_rob_lite.rob_order_id[0][0],
                 dut.u_rob_lite.rob_valid[0][1], dut.u_rob_lite.rob_complete[0][1], dut.u_rob_lite.rob_is_store[0][1], dut.u_rob_lite.rob_tag[0][1], dut.u_rob_lite.rob_order_id[0][1]);
        $display("[FPGA_BENCH_QUICK] ROB0[2] v=%0b c=%0b s=%0b tag=%0d ord=%0d | ROB0[3] v=%0b c=%0b s=%0b tag=%0d ord=%0d",
                 dut.u_rob_lite.rob_valid[0][2], dut.u_rob_lite.rob_complete[0][2], dut.u_rob_lite.rob_is_store[0][2], dut.u_rob_lite.rob_tag[0][2], dut.u_rob_lite.rob_order_id[0][2],
                 dut.u_rob_lite.rob_valid[0][3], dut.u_rob_lite.rob_complete[0][3], dut.u_rob_lite.rob_is_store[0][3], dut.u_rob_lite.rob_tag[0][3], dut.u_rob_lite.rob_order_id[0][3]);
        $display("[FPGA_BENCH_QUICK] ROB0[4] v=%0b c=%0b s=%0b tag=%0d ord=%0d | ROB0[5] v=%0b c=%0b s=%0b tag=%0d ord=%0d",
                 dut.u_rob_lite.rob_valid[0][4], dut.u_rob_lite.rob_complete[0][4], dut.u_rob_lite.rob_is_store[0][4], dut.u_rob_lite.rob_tag[0][4], dut.u_rob_lite.rob_order_id[0][4],
                 dut.u_rob_lite.rob_valid[0][5], dut.u_rob_lite.rob_complete[0][5], dut.u_rob_lite.rob_is_store[0][5], dut.u_rob_lite.rob_tag[0][5], dut.u_rob_lite.rob_order_id[0][5]);
        $display("[FPGA_BENCH_QUICK] ROB0[6] v=%0b c=%0b s=%0b tag=%0d ord=%0d | ROB0[7] v=%0b c=%0b s=%0b tag=%0d ord=%0d",
                 dut.u_rob_lite.rob_valid[0][6], dut.u_rob_lite.rob_complete[0][6], dut.u_rob_lite.rob_is_store[0][6], dut.u_rob_lite.rob_tag[0][6], dut.u_rob_lite.rob_order_id[0][6],
                 dut.u_rob_lite.rob_valid[0][7], dut.u_rob_lite.rob_complete[0][7], dut.u_rob_lite.rob_is_store[0][7], dut.u_rob_lite.rob_tag[0][7], dut.u_rob_lite.rob_order_id[0][7]);
        $display("[FPGA_BENCH_QUICK] SB0[0] v=%0b c=%0b tag? ord=%0d addr=%08h | SB0[1] v=%0b c=%0b ord=%0d addr=%08h",
                 dut.u_lsu_shell.u_store_buffer.sb_valid[0][0], dut.u_lsu_shell.u_store_buffer.sb_committed[0][0], dut.u_lsu_shell.u_store_buffer.sb_order_id[0][0], dut.u_lsu_shell.u_store_buffer.sb_addr[0][0],
                 dut.u_lsu_shell.u_store_buffer.sb_valid[0][1], dut.u_lsu_shell.u_store_buffer.sb_committed[0][1], dut.u_lsu_shell.u_store_buffer.sb_order_id[0][1], dut.u_lsu_shell.u_store_buffer.sb_addr[0][1]);
        $display("[FPGA_BENCH_QUICK] SB0[2] v=%0b c=%0b ord=%0d addr=%08h | SB0[3] v=%0b c=%0b ord=%0d addr=%08h",
                 dut.u_lsu_shell.u_store_buffer.sb_valid[0][2], dut.u_lsu_shell.u_store_buffer.sb_committed[0][2], dut.u_lsu_shell.u_store_buffer.sb_order_id[0][2], dut.u_lsu_shell.u_store_buffer.sb_addr[0][2],
                 dut.u_lsu_shell.u_store_buffer.sb_valid[0][3], dut.u_lsu_shell.u_store_buffer.sb_committed[0][3], dut.u_lsu_shell.u_store_buffer.sb_order_id[0][3], dut.u_lsu_shell.u_store_buffer.sb_addr[0][3]);
        for (rs_idx = 0; rs_idx < 16; rs_idx = rs_idx + 1) begin
            if (dut.u_scoreboard.win_valid[rs_idx] &&
                ((dut.u_scoreboard.win_tag[rs_idx] == 5'd6) || (dut.u_scoreboard.win_tag[rs_idx] == 5'd7))) begin
                $display("[FPGA_BENCH_QUICK] RS[%0d] tag=%0d issued=%0b ready=%0b tid=%0d pc=%08h ord=%0d fu=%0d memw=%0b memr=%0b qj=%0d qk=%0d rs1=%0d rs2=%0d",
                         rs_idx,
                         dut.u_scoreboard.win_tag[rs_idx],
                         dut.u_scoreboard.win_issued[rs_idx],
                         dut.u_scoreboard.win_ready[rs_idx],
                         dut.u_scoreboard.win_tid[rs_idx],
                         dut.u_scoreboard.win_pc[rs_idx],
                         dut.u_scoreboard.win_order_id[rs_idx],
                         dut.u_scoreboard.win_fu[rs_idx],
                         dut.u_scoreboard.win_mem_write[rs_idx],
                         dut.u_scoreboard.win_mem_read[rs_idx],
                         dut.u_scoreboard.win_qj[rs_idx],
                         dut.u_scoreboard.win_qk[rs_idx],
                         dut.u_scoreboard.win_rs1[rs_idx],
                         dut.u_scoreboard.win_rs2[rs_idx]);
            end
        end
        $fatal(1);
    end

    always @(posedge sys_clk) begin
        if (sys_rstn &&
            debug_core_ready &&
            debug_retire_seen &&
            (tube_status == 8'h04) &&
            ((bench_done_seen && (uart_byte_count >= 16)) ||
             (uart_byte_count >= 64 && legacy_uart_fire_count >= 64))) begin
            $display("[FPGA_BENCH_QUICK] PASS ready=%0b retire=%0b tube=%02h uart_bytes=%0d done_seen=%0b",
                     debug_core_ready, debug_retire_seen, tube_status, uart_byte_count, bench_done_seen);
            $finish;
        end
    end
endmodule
