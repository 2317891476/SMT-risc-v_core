`timescale 1ns/1ps

module verilator_mainline_top (
    input  wire        sys_clk,
    input  wire        sys_rstn,
    input  wire        fast_uart_rx_byte_valid,
    input  wire [7:0]  fast_uart_rx_byte,
    output wire [7:0]  tube_status,
    output wire        debug_core_ready,
    output wire        debug_core_clk,
    output wire        debug_retire_seen,
    output wire        debug_uart_tx_byte_valid,
    output wire [7:0]  debug_uart_tx_byte,
    output wire [7:0]  debug_uart_status_load_count,
    output wire [7:0]  debug_uart_tx_store_count,
    output wire [383:0] debug_ddr3_fetch_bus,
    output wire [31:0] debug_pc_t0,
    output wire [31:0] debug_pc_t1,
    output wire [31:0] debug_fetch_pc_pending,
    output wire [31:0] debug_fetch_pc_out,
    output wire [31:0] debug_fetch_if_inst,
    output wire [7:0]  debug_fetch_if_flags,
    output wire [7:0]  debug_ic_high_miss_count,
    output wire [7:0]  debug_ic_mem_req_count,
    output wire [7:0]  debug_ic_mem_resp_count,
    output wire [7:0]  debug_ic_cpu_resp_count,
    output wire [1:0]  debug_instr_retired_count,
    output wire        debug_branch_pending_any,
    output wire        debug_spec_dispatch0,
    output wire        debug_spec_dispatch1,
    output wire        debug_branch_gated_mem_issue,
    output wire        debug_flush_killed_speculative,
    output wire        debug_commit_suppressed,
    output wire        debug_if_valid,
    output wire        debug_fb_pop0_valid,
    output wire        debug_fb_pop1_valid,
    output wire        debug_dec0_valid,
    output wire        debug_dec1_valid,
    output wire        debug_disp0_accepted,
    output wire        debug_disp1_accepted,
    output wire        debug_iss0_valid,
    output wire        debug_br_redirect_valid,
    output wire [31:0] debug_br_redirect_pc,
    output wire [31:0] debug_br_redirect_target,
    output wire        debug_stall,
    output wire        debug_sb_disp_stall,
    output wire        debug_rob_disp_stall,
    output wire        debug_fl_disp_stall,
    output wire        debug_sys_disp_stall,
    output wire        debug_sb_disp1_blocked,
    output wire        debug_rob_commit0_valid,
    output wire        debug_rob_commit1_valid,
    output wire [15:0] debug_rob_commit0_order_id,
    output wire [15:0] debug_rob_commit1_order_id,
    output wire [3:0]  debug_rob_head_idx_t0,
    output wire [3:0]  debug_rob_head_idx_t1,
    output wire        debug_rob_head_valid_t0,
    output wire        debug_rob_head_valid_t1,
    output wire        debug_rob_head_complete_t0,
    output wire        debug_rob_head_complete_t1,
    output wire [31:0] debug_rob_head_pc_t0,
    output wire [31:0] debug_rob_head_pc_t1,
    output wire [15:0] debug_rob_head_order_id_t0,
    output wire [15:0] debug_rob_head_order_id_t1,
    output wire [4:0]  debug_rob_head_tag_t0,
    output wire [4:0]  debug_rob_head_tag_t1,
    output wire        debug_rob_head_is_store_t0,
    output wire        debug_rob_head_is_store_t1,
    output wire        debug_rob_head_flushed_t0,
    output wire        debug_rob_head_flushed_t1,
    output wire [4:0]  debug_rob_count_t0,
    output wire [4:0]  debug_rob_count_t1,
    output wire        debug_rob_recovering,
    output wire        debug_rob_recover_tid,
    output wire [3:0]  debug_rob_recover_ptr,
    output wire        debug_trap_seen,
    output wire [31:0] debug_trap_cause,
    output wire [63:0] debug_mcycle,
    output wire [63:0] debug_minstret,
    output wire        debug_mem_iss_valid,
    output wire [31:0] debug_mem_iss_pc,
    output wire [15:0] debug_mem_iss_order_id,
    output wire [4:0]  debug_mem_iss_tag,
    output wire        debug_mem_iss_tid,
    output wire        debug_mem_iss_mem_read,
    output wire        debug_mem_iss_mem_write,
    output wire        debug_p1_winner_valid,
    output wire [1:0]  debug_p1_winner,
    output wire        debug_mem_fu_busy,
    output wire [15:0] debug_mem_fu_order_id,
    output wire        debug_mem_fu_tid,
    output wire        debug_mem_issue_inhibit,
    output wire        debug_p1_mem_cand_valid,
    output wire [15:0] debug_p1_mem_cand_order_id,
    output wire [4:0]  debug_p1_mem_cand_tag,
    output wire        debug_p1_mem_cand_mem_read,
    output wire        debug_p1_mem_cand_mem_write,
    output wire        debug_mem_cand_raw_valid,
    output wire        debug_mem_cand_clear,
    output wire        debug_mem_cand_set,
    output wire        debug_iq_mem_sel_found,
    output wire [3:0]  debug_iq_mem_sel_idx,
    output wire        debug_iq_mem_oldest_store_valid_t0,
    output wire        debug_iq_mem_oldest_store_valid_t1,
    output wire [15:0] debug_iq_mem_oldest_store_order_id_t0,
    output wire [15:0] debug_iq_mem_oldest_store_order_id_t1,
    output wire [4:0]  debug_iq_mem_store_count_t0,
    output wire [4:0]  debug_iq_mem_store_count_t1,
    output wire        debug_flush,
    output wire        debug_flush_tid,
    output wire        debug_flush_order_valid,
    output wire [15:0] debug_flush_order_id,
    output wire        debug_wb0_valid,
    output wire [4:0]  debug_wb0_tag,
    output wire        debug_wb0_regs_write,
    output wire [31:0] debug_wb0_data,
    output wire        debug_wb1_valid,
    output wire [4:0]  debug_wb1_tag,
    output wire        debug_wb1_regs_write,
    output wire [2:0]  debug_wb1_fu,
    output wire [31:0] debug_wb1_data,
    output wire        debug_lsu_req_valid,
    output wire        debug_lsu_req_accept,
    output wire [15:0] debug_lsu_req_order_id,
    output wire [4:0]  debug_lsu_req_tag,
    output wire        debug_lsu_req_tid,
    output wire [31:0] debug_lsu_req_addr,
    output wire [31:0] debug_lsu_req_wdata,
    output wire [2:0]  debug_lsu_req_func3,
    output wire        debug_lsu_req_wen,
    output wire        debug_lsu_resp_valid,
    output wire [1:0]  debug_lsu_state,
    output wire        debug_lsu_pending_valid,
    output wire [15:0] debug_lsu_pending_order_id,
    output wire [4:0]  debug_lsu_pending_tag,
    output wire [31:0] debug_lsu_pending_addr,
    output wire        debug_lsu_pending_wen,
    output wire        debug_lsu_pending_tid,
    output wire        debug_lsu_m1_txn_is_drain,
    output wire        debug_lsu_m1_cooldown,
    output wire        debug_lsu_drain_holdoff,
    output wire        debug_lsu_sb_drain_urgent,
    output wire        debug_lsu_sb_has_pending_stores,
    output wire        debug_lsu_sb_mem_write_valid,
    output wire        debug_lsu_sb_forward_valid,
    output wire        debug_lsu_sb_load_hazard,
    output wire        debug_store_buffer_empty,
    output wire [2:0]  debug_store_buffer_count_t0,
    output wire [2:0]  debug_store_buffer_count_t1,
    output wire [1:0]  debug_sb_head_idx_t0,
    output wire [1:0]  debug_sb_head_idx_t1,
    output wire        debug_sb_head_valid_t0,
    output wire        debug_sb_head_valid_t1,
    output wire        debug_sb_head_committed_t0,
    output wire        debug_sb_head_committed_t1,
    output wire [15:0] debug_sb_head_order_id_t0,
    output wire [15:0] debug_sb_head_order_id_t1,
    output wire [31:0] debug_sb_head_addr_t0,
    output wire [31:0] debug_sb_head_addr_t1,
    output wire        debug_m1_req_valid,
    output wire        debug_m1_req_ready,
    output wire [31:0] debug_m1_req_addr,
    output wire        debug_m1_req_write,
    output wire [31:0] debug_m1_req_wdata,
    output wire [3:0]  debug_m1_req_wen,
    output wire        debug_m1_resp_valid,
    output wire [31:0] debug_m1_resp_data,
    output wire        debug_ddr3_req_valid,
    output wire        debug_ddr3_req_ready,
    output wire [31:0] debug_ddr3_req_addr,
    output wire        debug_ddr3_req_write,
    output wire [31:0] debug_ddr3_req_wdata,
    output wire [3:0]  debug_ddr3_req_wen,
    output wire        debug_ddr3_resp_valid,
    output wire [31:0] debug_ddr3_resp_data,
    output wire        debug_m0_req_valid,
    output wire        debug_m0_req_ready,
    output wire [31:0] debug_m0_req_addr,
    output wire        debug_m0_resp_valid,
    output wire [31:0] debug_m0_resp_data,
    output wire        debug_m0_resp_last,
    output wire [7:0]  debug_ic_state_flags,
    output wire        debug_memsubsys_m0_ddr3_resp_valid,
    output wire [31:0] debug_memsubsys_m0_ddr3_resp_data,
    output wire        debug_memsubsys_m0_ddr3_resp_last,
    output wire [1:0]  debug_memsubsys_ddr3_arb_state,
    output wire [2:0]  debug_memsubsys_ddr3_m0_word_idx,
    output wire        debug_dcache_miss_event,
    output wire        debug_bad_uart_store_seen,
    output wire [31:0] debug_bad_uart_store_pc,
    output wire [31:0] debug_bad_uart_store_addr,
    output wire [31:0] debug_bad_uart_store_op_a,
    output wire [31:0] debug_bad_uart_store_op_b,
    output wire [31:0] debug_bad_uart_store_imm,
    output wire [15:0] debug_bad_uart_store_order_id,
    output wire [4:0]  debug_bad_uart_store_tag,
    output wire [4:0]  debug_bad_uart_store_rd,
    output wire [4:0]  debug_bad_uart_store_rs1,
    output wire [4:0]  debug_bad_uart_store_rs2,
    output wire [4:0]  debug_bad_uart_store_src1_tag,
    output wire [4:0]  debug_bad_uart_store_src2_tag,
    output wire [5:0]  debug_bad_uart_store_prs1,
    output wire [5:0]  debug_bad_uart_store_prs2,
    output wire [31:0] debug_bad_uart_store_prf_a,
    output wire [31:0] debug_bad_uart_store_prf_b,
    output wire        debug_bad_uart_store_tagbuf_a_valid,
    output wire        debug_bad_uart_store_tagbuf_b_valid,
    output wire [31:0] debug_bad_uart_store_tagbuf_a_data,
    output wire [31:0] debug_bad_uart_store_tagbuf_b_data,
    output wire [1:0]  debug_bad_uart_store_fwd_a,
    output wire [1:0]  debug_bad_uart_store_fwd_b,
    output wire [2:0]  debug_bad_uart_store_func3,
    output wire        debug_bad_uart_store_tid,
    output wire        debug_strcpy_mv_seen,
    output wire [31:0] debug_strcpy_mv_pc,
    output wire [31:0] debug_strcpy_mv_op_a,
    output wire [31:0] debug_strcpy_mv_op_b,
    output wire [15:0] debug_strcpy_mv_order_id,
    output wire [4:0]  debug_strcpy_mv_tag,
    output wire [4:0]  debug_strcpy_mv_rd,
    output wire        debug_strcpy_mv_tid,
    output wire [4:0]  debug_strcpy_mv_rs1,
    output wire [4:0]  debug_strcpy_mv_rs2,
    output wire [4:0]  debug_strcpy_mv_src1_tag,
    output wire [4:0]  debug_strcpy_mv_src2_tag,
    output wire [5:0]  debug_strcpy_mv_prd,
    output wire [5:0]  debug_strcpy_mv_prs1,
    output wire [5:0]  debug_strcpy_mv_prs2,
    output wire [31:0] debug_strcpy_mv_prf_a,
    output wire [31:0] debug_strcpy_mv_prf_b,
    output wire        debug_strcpy_mv_tagbuf_a_valid,
    output wire        debug_strcpy_mv_tagbuf_b_valid,
    output wire [31:0] debug_strcpy_mv_tagbuf_a_data,
    output wire [31:0] debug_strcpy_mv_tagbuf_b_data,
    output wire [1:0]  debug_strcpy_mv_fwd_a,
    output wire [1:0]  debug_strcpy_mv_fwd_b,
    output wire        debug_strcpy_mv_prf_w0_en,
    output wire [5:0]  debug_strcpy_mv_prf_w0_addr,
    output wire [31:0] debug_strcpy_mv_prf_w0_data,
    output wire        debug_strcpy_mv_prf_w1_en,
    output wire [5:0]  debug_strcpy_mv_prf_w1_addr,
    output wire [31:0] debug_strcpy_mv_prf_w1_data,
    output wire        debug_main_lw_a0_seen,
    output wire [31:0] debug_main_lw_a0_addr,
    output wire [15:0] debug_main_lw_a0_order_id,
    output wire [4:0]  debug_main_lw_a0_tag,
    output wire [5:0]  debug_main_lw_a0_prd,
    output wire [5:0]  debug_main_lw_a0_prs1,
    output wire [31:0] debug_main_lw_a0_base,
    output wire [31:0] debug_main_lw_a0_imm,
    output wire        debug_main_lw_a0_wb_seen,
    output wire [31:0] debug_main_lw_a0_wb_data,
    output wire [5:0]  debug_main_lw_a0_wb_prd,
    output wire        debug_main_addi_a0_seen,
    output wire [31:0] debug_main_addi_a0_op_a,
    output wire [31:0] debug_main_addi_a0_result,
    output wire [15:0] debug_main_addi_a0_order_id,
    output wire [4:0]  debug_main_addi_a0_tag,
    output wire [5:0]  debug_main_addi_a0_prd,
    output wire [5:0]  debug_main_addi_a0_prs1,
    output wire [4:0]  debug_main_addi_a0_src1_tag,
    output wire [31:0] debug_main_addi_a0_prf_a,
    output wire        debug_main_addi_a0_tagbuf_a_valid,
    output wire [31:0] debug_main_addi_a0_tagbuf_a_data,
    output wire [7:0]  debug_main_a0_prd_write_count,
    output wire        debug_main_a0_prd_last_write_port,
    output wire [31:0] debug_main_a0_prd_last_write_data,
    output wire [4:0]  debug_main_a0_prd_last_write_tag,
    output wire [4:0]  debug_main_a0_prd_last_write_rd,
    output wire [2:0]  debug_main_a0_prd_last_write_fu,
    output wire [31:0] debug_main_a0_prd_last_write_pc,
    output wire [15:0] debug_main_a0_prd_last_write_order_id,
    output wire        debug_main_a0_prd_first_bad_write_seen,
    output wire        debug_main_a0_prd_first_bad_write_port,
    output wire [31:0] debug_main_a0_prd_first_bad_write_data,
    output wire [4:0]  debug_main_a0_prd_first_bad_write_tag,
    output wire [4:0]  debug_main_a0_prd_first_bad_write_rd,
    output wire [2:0]  debug_main_a0_prd_first_bad_write_fu,
    output wire [31:0] debug_main_a0_prd_first_bad_write_pc,
    output wire [15:0] debug_main_a0_prd_first_bad_write_order_id,
    output wire        debug_main_a0_prd_first_free_seen,
    output wire        debug_main_a0_prd_first_free_port,
    output wire [4:0]  debug_main_a0_prd_first_free_rd,
    output wire [4:0]  debug_main_a0_prd_first_free_tag,
    output wire [15:0] debug_main_a0_prd_first_free_order_id,
    output wire        debug_main_addi_a0_wb_seen,
    output wire        debug_main_addi_a0_wb_port,
    output wire        debug_main_addi_a0_wb_tid,
    output wire [5:0]  debug_main_addi_a0_wb_prd,
    output wire [31:0] debug_main_addi_a0_wb_data,
    output wire        debug_main_addi_a0_wb_w0_en,
    output wire [5:0]  debug_main_addi_a0_wb_w0_addr,
    output wire [31:0] debug_main_addi_a0_wb_w0_data,
    output wire        debug_main_addi_a0_wb_w1_en,
    output wire [5:0]  debug_main_addi_a0_wb_w1_addr,
    output wire [31:0] debug_main_addi_a0_wb_w1_data,
    output wire [31:0] mock_mem_read_count,
    output wire [31:0] mock_mem_write_count,
    output wire [31:0] mock_mem_last_read_addr,
    output wire [31:0] mock_mem_last_write_addr,
    output wire [31:0] mock_mem_last_write_data,
    output wire [31:0] mock_mem_range_error_count,
    output wire [31:0] mock_mem_last_range_error_addr,
    output wire [31:0] mock_mem_uninit_read_count
);

    wire        ddr3_req_valid;
    wire        ddr3_req_ready;
    wire [31:0] ddr3_req_addr;
    wire        ddr3_req_write;
    wire [31:0] ddr3_req_wdata;
    wire [3:0]  ddr3_req_wen;
    wire        ddr3_resp_valid;
    wire [31:0] ddr3_resp_data;
    wire        ddr3_init_calib_complete;
    wire        uart_tx_unused;
    wire [2:0]  led_unused;
    wire        debug_core_clk_unused;
    wire        debug_uart_status_busy_unused;
    wire        debug_uart_busy_unused;
    wire        debug_uart_pending_valid_unused;
    wire [7:0]  debug_last_iss0_pc_lo_unused;
    wire [7:0]  debug_last_iss1_pc_lo_unused;
    wire        debug_branch_pending_any_unused;
    wire        debug_br_found_t0_unused;
    wire        debug_branch_in_flight_t0_unused;
    wire        debug_oldest_br_ready_t0_unused;
    wire        debug_oldest_br_just_woke_t0_unused;
    wire [3:0]  debug_oldest_br_qj_t0_unused;
    wire [3:0]  debug_oldest_br_qk_t0_unused;
    wire [3:0]  debug_slot1_flags_unused;
    wire [7:0]  debug_slot1_pc_lo_unused;
    wire [3:0]  debug_slot1_qj_unused;
    wire [3:0]  debug_slot1_qk_unused;
    wire [3:0]  debug_tag2_flags_unused;
    wire [3:0]  debug_reg_x12_tag_t0_unused;
    wire [3:0]  debug_slot1_issue_flags_unused;
    wire [3:0]  debug_sel0_idx_unused;
    wire [3:0]  debug_slot1_fu_unused;
    wire [7:0]  debug_oldest_br_seq_lo_t0_unused;
    wire [15:0] debug_rs_flags_flat_unused;
    wire [31:0] debug_rs_pc_lo_flat_unused;
    wire [15:0] debug_rs_fu_flat_unused;
    wire [15:0] debug_rs_qj_flat_unused;
    wire [15:0] debug_rs_qk_flat_unused;
    wire [31:0] debug_rs_seq_lo_flat_unused;
    wire        debug_spec_dispatch0_unused;
    wire        debug_spec_dispatch1_unused;
    wire        debug_branch_gated_mem_issue_unused;
    wire        debug_flush_killed_speculative_unused;
    wire        debug_commit_suppressed_unused;
    wire [7:0]  debug_branch_issue_count_unused;
    wire [7:0]  debug_branch_complete_count_unused;
    wire [3:0]  rob_head_idx_t0 = u_dut.u_rob.rob_head[0];
    wire [3:0]  rob_head_idx_t1 = u_dut.u_rob.rob_head[1];
    wire [1:0]  sb_head_idx_t0 = u_dut.u_lsu_shell.u_store_buffer.sb_head[0];
    wire [1:0]  sb_head_idx_t1 = u_dut.u_lsu_shell.u_store_buffer.sb_head[1];

    adam_riscv u_dut (
        .sys_clk(sys_clk),
        .sys_rstn(sys_rstn),
        .led(led_unused),
        .uart_rx(1'b1),
        .ext_irq_src(1'b0),
        .tube_status(tube_status),
        .uart_tx(uart_tx_unused),
        .debug_core_ready(debug_core_ready),
        .debug_core_clk(debug_core_clk_unused),
        .debug_retire_seen(debug_retire_seen),
        .debug_uart_status_busy(debug_uart_status_busy_unused),
        .debug_uart_busy(debug_uart_busy_unused),
        .debug_uart_pending_valid(debug_uart_pending_valid_unused),
        .debug_uart_status_load_count(debug_uart_status_load_count),
        .debug_uart_tx_store_count(debug_uart_tx_store_count),
        .debug_uart_tx_byte_valid(debug_uart_tx_byte_valid),
        .debug_uart_tx_byte(debug_uart_tx_byte),
        .fast_uart_rx_byte_valid(fast_uart_rx_byte_valid),
        .fast_uart_rx_byte(fast_uart_rx_byte),
        .debug_last_iss0_pc_lo(debug_last_iss0_pc_lo_unused),
        .debug_last_iss1_pc_lo(debug_last_iss1_pc_lo_unused),
        .debug_branch_pending_any(debug_branch_pending_any_unused),
        .debug_br_found_t0(debug_br_found_t0_unused),
        .debug_branch_in_flight_t0(debug_branch_in_flight_t0_unused),
        .debug_oldest_br_ready_t0(debug_oldest_br_ready_t0_unused),
        .debug_oldest_br_just_woke_t0(debug_oldest_br_just_woke_t0_unused),
        .debug_oldest_br_qj_t0(debug_oldest_br_qj_t0_unused),
        .debug_oldest_br_qk_t0(debug_oldest_br_qk_t0_unused),
        .debug_slot1_flags(debug_slot1_flags_unused),
        .debug_slot1_pc_lo(debug_slot1_pc_lo_unused),
        .debug_slot1_qj(debug_slot1_qj_unused),
        .debug_slot1_qk(debug_slot1_qk_unused),
        .debug_tag2_flags(debug_tag2_flags_unused),
        .debug_reg_x12_tag_t0(debug_reg_x12_tag_t0_unused),
        .debug_slot1_issue_flags(debug_slot1_issue_flags_unused),
        .debug_sel0_idx(debug_sel0_idx_unused),
        .debug_slot1_fu(debug_slot1_fu_unused),
        .debug_oldest_br_seq_lo_t0(debug_oldest_br_seq_lo_t0_unused),
        .debug_rs_flags_flat(debug_rs_flags_flat_unused),
        .debug_rs_pc_lo_flat(debug_rs_pc_lo_flat_unused),
        .debug_rs_fu_flat(debug_rs_fu_flat_unused),
        .debug_rs_qj_flat(debug_rs_qj_flat_unused),
        .debug_rs_qk_flat(debug_rs_qk_flat_unused),
        .debug_rs_seq_lo_flat(debug_rs_seq_lo_flat_unused),
        .debug_spec_dispatch0(debug_spec_dispatch0_unused),
        .debug_spec_dispatch1(debug_spec_dispatch1_unused),
        .debug_branch_gated_mem_issue(debug_branch_gated_mem_issue_unused),
        .debug_flush_killed_speculative(debug_flush_killed_speculative_unused),
        .debug_commit_suppressed(debug_commit_suppressed_unused),
        .debug_branch_issue_count(debug_branch_issue_count_unused),
        .debug_branch_complete_count(debug_branch_complete_count_unused),
        .debug_ddr3_fetch_bus(debug_ddr3_fetch_bus),
        .ddr3_req_valid(ddr3_req_valid),
        .ddr3_req_ready(ddr3_req_ready),
        .ddr3_req_addr(ddr3_req_addr),
        .ddr3_req_write(ddr3_req_write),
        .ddr3_req_wdata(ddr3_req_wdata),
        .ddr3_req_wen(ddr3_req_wen),
        .ddr3_resp_valid(ddr3_resp_valid),
        .ddr3_resp_data(ddr3_resp_data),
        .ddr3_init_calib_complete(ddr3_init_calib_complete)
    );

    mock_ddr3_mem u_mock_ddr3_mem (
        .clk(u_dut.clk),
        .rstn(u_dut.rstn),
        .req_valid(ddr3_req_valid),
        .req_ready(ddr3_req_ready),
        .req_addr(ddr3_req_addr),
        .req_write(ddr3_req_write),
        .req_wdata(ddr3_req_wdata),
        .req_wen(ddr3_req_wen),
        .resp_valid(ddr3_resp_valid),
        .resp_data(ddr3_resp_data),
        .init_calib_complete(ddr3_init_calib_complete),
        .debug_read_count(mock_mem_read_count),
        .debug_write_count(mock_mem_write_count),
        .debug_last_read_addr(mock_mem_last_read_addr),
        .debug_last_write_addr(mock_mem_last_write_addr),
        .debug_last_write_data(mock_mem_last_write_data),
        .debug_range_error_count(mock_mem_range_error_count),
        .debug_last_range_error_addr(mock_mem_last_range_error_addr),
        .debug_uninit_read_count(mock_mem_uninit_read_count)
    );

    assign debug_pc_t0 = u_dut.u_stage_if.u_pc_mt.pc[0];
    assign debug_pc_t1 = u_dut.u_stage_if.u_pc_mt.pc[1];
    assign debug_core_clk = u_dut.debug_core_clk;
    assign debug_fetch_pc_pending = u_dut.u_stage_if.fetch_pc_pending;
    assign debug_fetch_pc_out = u_dut.debug_fetch_pc_out;
    assign debug_fetch_if_inst = u_dut.debug_fetch_if_inst;
    assign debug_fetch_if_flags = u_dut.debug_fetch_if_flags;
    assign debug_ic_high_miss_count = u_dut.debug_ic_high_miss_count;
    assign debug_ic_mem_req_count = u_dut.debug_ic_mem_req_count;
    assign debug_ic_mem_resp_count = u_dut.debug_ic_mem_resp_count;
    assign debug_ic_cpu_resp_count = u_dut.debug_ic_cpu_resp_count;
    assign debug_instr_retired_count = u_dut.rob_instr_retired;
    assign debug_branch_pending_any = debug_branch_pending_any_unused;
    assign debug_spec_dispatch0 = debug_spec_dispatch0_unused;
    assign debug_spec_dispatch1 = debug_spec_dispatch1_unused;
    assign debug_branch_gated_mem_issue = debug_branch_gated_mem_issue_unused;
    assign debug_flush_killed_speculative = debug_flush_killed_speculative_unused;
    assign debug_commit_suppressed = debug_commit_suppressed_unused;
    assign debug_if_valid = u_dut.if_valid;
    assign debug_fb_pop0_valid = u_dut.fb_pop0_valid;
    assign debug_fb_pop1_valid = u_dut.fb_pop1_valid;
    assign debug_dec0_valid = u_dut.dec0_valid;
    assign debug_dec1_valid = u_dut.dec1_valid;
    assign debug_disp0_accepted = u_dut.disp0_accepted;
    assign debug_disp1_accepted = u_dut.disp1_accepted;
    assign debug_iss0_valid = u_dut.iss0_valid;
    assign debug_br_redirect_valid = u_dut.pipe0_br_ctrl;
    assign debug_br_redirect_pc = u_dut.pipe0_br_update_pc;
    assign debug_br_redirect_target = u_dut.pipe0_br_addr;
    assign debug_stall = u_dut.stall;
    assign debug_sb_disp_stall = u_dut.sb_disp_stall;
    assign debug_rob_disp_stall = u_dut.rob_disp_stall;
    assign debug_fl_disp_stall = u_dut.fl_disp_stall;
    assign debug_sys_disp_stall = u_dut.sys_disp_stall;
    assign debug_sb_disp1_blocked = u_dut.sb_disp1_blocked;
    assign debug_rob_commit0_valid = u_dut.rob_commit0_valid;
    assign debug_rob_commit1_valid = u_dut.rob_commit1_valid;
    assign debug_rob_commit0_order_id = u_dut.rob_commit0_order_id;
    assign debug_rob_commit1_order_id = u_dut.rob_commit1_order_id;
    assign debug_rob_head_idx_t0 = rob_head_idx_t0;
    assign debug_rob_head_idx_t1 = rob_head_idx_t1;
    assign debug_rob_head_valid_t0 = u_dut.u_rob.rob_valid[0][rob_head_idx_t0];
    assign debug_rob_head_valid_t1 = u_dut.u_rob.rob_valid[1][rob_head_idx_t1];
    assign debug_rob_head_complete_t0 = u_dut.u_rob.rob_complete[0][rob_head_idx_t0];
    assign debug_rob_head_complete_t1 = u_dut.u_rob.rob_complete[1][rob_head_idx_t1];
    assign debug_rob_head_pc_t0 = u_dut.u_rob.rob_pc[0][rob_head_idx_t0];
    assign debug_rob_head_pc_t1 = u_dut.u_rob.rob_pc[1][rob_head_idx_t1];
    assign debug_rob_head_order_id_t0 = u_dut.u_rob.rob_order_id[0][rob_head_idx_t0];
    assign debug_rob_head_order_id_t1 = u_dut.u_rob.rob_order_id[1][rob_head_idx_t1];
    assign debug_rob_head_tag_t0 = u_dut.u_rob.rob_tag[0][rob_head_idx_t0];
    assign debug_rob_head_tag_t1 = u_dut.u_rob.rob_tag[1][rob_head_idx_t1];
    assign debug_rob_head_is_store_t0 = u_dut.u_rob.rob_is_store[0][rob_head_idx_t0];
    assign debug_rob_head_is_store_t1 = u_dut.u_rob.rob_is_store[1][rob_head_idx_t1];
    assign debug_rob_head_flushed_t0 = u_dut.u_rob.rob_flushed[0][rob_head_idx_t0];
    assign debug_rob_head_flushed_t1 = u_dut.u_rob.rob_flushed[1][rob_head_idx_t1];
    assign debug_rob_count_t0 = u_dut.u_rob.rob_count[0];
    assign debug_rob_count_t1 = u_dut.u_rob.rob_count[1];
    assign debug_rob_recovering = u_dut.u_rob.recovering_r;
    assign debug_rob_recover_tid = u_dut.u_rob.recover_tid_r;
    assign debug_rob_recover_ptr = u_dut.u_rob.recover_ptr_r;
    assign debug_trap_seen = u_dut.trap_enter;
    assign debug_trap_cause = u_dut.u_csr_unit.mcause;
    assign debug_mcycle = u_dut.u_csr_unit.mcycle;
    assign debug_minstret = u_dut.u_csr_unit.minstret;
    assign debug_mem_iss_valid = u_dut.u_dispatch_unit.mem_iss_valid;
    assign debug_mem_iss_pc = u_dut.u_dispatch_unit.mem_iss_pc;
    assign debug_mem_iss_order_id = u_dut.u_dispatch_unit.mem_iss_order_id;
    assign debug_mem_iss_tag = u_dut.u_dispatch_unit.mem_iss_tag;
    assign debug_mem_iss_tid = u_dut.u_dispatch_unit.mem_iss_tid;
    assign debug_mem_iss_mem_read = u_dut.u_dispatch_unit.mem_iss_mem_read;
    assign debug_mem_iss_mem_write = u_dut.u_dispatch_unit.mem_iss_mem_write;
    assign debug_p1_winner_valid = u_dut.u_dispatch_unit.p1_winner_valid;
    assign debug_p1_winner = u_dut.u_dispatch_unit.p1_winner;
    assign debug_mem_fu_busy = u_dut.u_dispatch_unit.mem_fu_busy;
    assign debug_mem_fu_order_id = u_dut.u_dispatch_unit.mem_fu_order_id;
    assign debug_mem_fu_tid = u_dut.u_dispatch_unit.mem_fu_tid;
    assign debug_mem_issue_inhibit = u_dut.u_dispatch_unit.mem_issue_inhibit;
    assign debug_p1_mem_cand_valid = u_dut.u_dispatch_unit.p1_mem_cand_valid;
    assign debug_p1_mem_cand_order_id = u_dut.u_dispatch_unit.p1_mem_cand_order_id;
    assign debug_p1_mem_cand_tag = u_dut.u_dispatch_unit.p1_mem_cand_tag;
    assign debug_p1_mem_cand_mem_read = u_dut.u_dispatch_unit.p1_mem_cand_mem_read;
    assign debug_p1_mem_cand_mem_write = u_dut.u_dispatch_unit.p1_mem_cand_mem_write;
    assign debug_mem_cand_raw_valid = u_dut.u_dispatch_unit.mem_cand_raw_valid;
    assign debug_mem_cand_clear = u_dut.u_dispatch_unit.mem_cand_clear;
    assign debug_mem_cand_set = u_dut.u_dispatch_unit.mem_cand_set;
    assign debug_iq_mem_sel_found = u_dut.u_dispatch_unit.u_iq_mem.sel_found;
    assign debug_iq_mem_sel_idx = u_dut.u_dispatch_unit.u_iq_mem.sel_idx;
    assign debug_iq_mem_oldest_store_valid_t0 = u_dut.u_dispatch_unit.u_iq_mem.oldest_store_valid_t0;
    assign debug_iq_mem_oldest_store_valid_t1 = u_dut.u_dispatch_unit.u_iq_mem.oldest_store_valid_t1;
    assign debug_iq_mem_oldest_store_order_id_t0 = u_dut.u_dispatch_unit.u_iq_mem.oldest_store_order_id_t0;
    assign debug_iq_mem_oldest_store_order_id_t1 = u_dut.u_dispatch_unit.u_iq_mem.oldest_store_order_id_t1;
    assign debug_iq_mem_store_count_t0 = u_dut.u_dispatch_unit.u_iq_mem.store_count_t0_r;
    assign debug_iq_mem_store_count_t1 = u_dut.u_dispatch_unit.u_iq_mem.store_count_t1_r;
    assign debug_flush = u_dut.u_dispatch_unit.flush;
    assign debug_flush_tid = u_dut.u_dispatch_unit.flush_tid;
    assign debug_flush_order_valid = u_dut.u_dispatch_unit.flush_order_valid;
    assign debug_flush_order_id = u_dut.u_dispatch_unit.flush_order_id;
    assign debug_wb0_valid = u_dut.u_dispatch_unit.wb0_valid;
    assign debug_wb0_tag = u_dut.u_dispatch_unit.wb0_tag;
    assign debug_wb0_regs_write = u_dut.u_dispatch_unit.wb0_regs_write;
    assign debug_wb0_data = u_dut.wb0_result_data;
    assign debug_wb1_valid = u_dut.u_dispatch_unit.wb1_valid;
    assign debug_wb1_tag = u_dut.u_dispatch_unit.wb1_tag;
    assign debug_wb1_regs_write = u_dut.u_dispatch_unit.wb1_regs_write;
    assign debug_wb1_fu = u_dut.u_dispatch_unit.wb1_fu;
    assign debug_wb1_data = u_dut.wb1_result_data;
    assign debug_lsu_req_valid = u_dut.p1_mem_req_valid;
    assign debug_lsu_req_accept = u_dut.lsu_req_accept;
    assign debug_lsu_req_order_id = u_dut.p1_mem_req_order_id;
    assign debug_lsu_req_tag = u_dut.p1_mem_req_tag;
    assign debug_lsu_req_tid = u_dut.p1_mem_req_tid;
    assign debug_lsu_req_addr = u_dut.p1_mem_req_addr;
    assign debug_lsu_req_wdata = u_dut.p1_mem_req_wdata;
    assign debug_lsu_req_func3 = u_dut.p1_mem_req_func3;
    assign debug_lsu_req_wen = u_dut.p1_mem_req_wen;
    assign debug_lsu_resp_valid = u_dut.lsu_resp_valid;
    assign debug_lsu_state = u_dut.u_lsu_shell.lsu_state;
    assign debug_lsu_pending_valid = u_dut.u_lsu_shell.pending_valid;
    assign debug_lsu_pending_order_id = u_dut.u_lsu_shell.pending_order_id;
    assign debug_lsu_pending_tag = u_dut.u_lsu_shell.pending_tag;
    assign debug_lsu_pending_addr = u_dut.u_lsu_shell.pending_addr;
    assign debug_lsu_pending_wen = u_dut.u_lsu_shell.pending_wen;
    assign debug_lsu_pending_tid = u_dut.u_lsu_shell.pending_tid;
    assign debug_lsu_m1_txn_is_drain = u_dut.u_lsu_shell.m1_txn_is_drain;
    assign debug_lsu_m1_cooldown = u_dut.u_lsu_shell.m1_cooldown_r;
    assign debug_lsu_drain_holdoff = u_dut.u_lsu_shell.m1_drain_holdoff;
    assign debug_lsu_sb_drain_urgent = u_dut.u_lsu_shell.sb_drain_urgent;
    assign debug_lsu_sb_has_pending_stores = u_dut.u_lsu_shell.sb_has_pending_stores;
    assign debug_lsu_sb_mem_write_valid = u_dut.u_lsu_shell.sb_mem_write_valid_int;
    assign debug_lsu_sb_forward_valid = u_dut.u_lsu_shell.sb_forward_valid;
    assign debug_lsu_sb_load_hazard = u_dut.u_lsu_shell.sb_load_hazard;
    assign debug_store_buffer_empty = u_dut.lsu_debug_store_buffer_empty;
    assign debug_store_buffer_count_t0 = u_dut.lsu_debug_store_buffer_count_t0;
    assign debug_store_buffer_count_t1 = u_dut.lsu_debug_store_buffer_count_t1;
    assign debug_sb_head_idx_t0 = sb_head_idx_t0;
    assign debug_sb_head_idx_t1 = sb_head_idx_t1;
    assign debug_sb_head_valid_t0 = u_dut.u_lsu_shell.u_store_buffer.sb_valid[0][sb_head_idx_t0];
    assign debug_sb_head_valid_t1 = u_dut.u_lsu_shell.u_store_buffer.sb_valid[1][sb_head_idx_t1];
    assign debug_sb_head_committed_t0 = u_dut.u_lsu_shell.u_store_buffer.sb_committed[0][sb_head_idx_t0];
    assign debug_sb_head_committed_t1 = u_dut.u_lsu_shell.u_store_buffer.sb_committed[1][sb_head_idx_t1];
    assign debug_sb_head_order_id_t0 = u_dut.u_lsu_shell.u_store_buffer.sb_order_id[0][sb_head_idx_t0];
    assign debug_sb_head_order_id_t1 = u_dut.u_lsu_shell.u_store_buffer.sb_order_id[1][sb_head_idx_t1];
    assign debug_sb_head_addr_t0 = u_dut.u_lsu_shell.u_store_buffer.sb_addr[0][sb_head_idx_t0];
    assign debug_sb_head_addr_t1 = u_dut.u_lsu_shell.u_store_buffer.sb_addr[1][sb_head_idx_t1];
    assign debug_m1_req_valid = u_dut.m1_req_valid;
    assign debug_m1_req_ready = u_dut.m1_req_ready;
    assign debug_m1_req_addr = u_dut.m1_req_addr;
    assign debug_m1_req_write = u_dut.m1_req_write;
    assign debug_m1_req_wdata = u_dut.m1_req_wdata;
    assign debug_m1_req_wen = u_dut.m1_req_wen;
    assign debug_m1_resp_valid = u_dut.m1_resp_valid;
    assign debug_m1_resp_data = u_dut.m1_resp_data;
    assign debug_ddr3_req_valid = ddr3_req_valid;
    assign debug_ddr3_req_ready = ddr3_req_ready;
    assign debug_ddr3_req_addr = ddr3_req_addr;
    assign debug_ddr3_req_write = ddr3_req_write;
    assign debug_ddr3_req_wdata = ddr3_req_wdata;
    assign debug_ddr3_req_wen = ddr3_req_wen;
    assign debug_ddr3_resp_valid = ddr3_resp_valid;
    assign debug_ddr3_resp_data = ddr3_resp_data;
    assign debug_m0_req_valid = u_dut.m0_req_valid;
    assign debug_m0_req_ready = u_dut.m0_req_ready;
    assign debug_m0_req_addr = u_dut.m0_req_addr;
    assign debug_m0_resp_valid = u_dut.m0_resp_valid;
    assign debug_m0_resp_data = u_dut.m0_resp_data;
    assign debug_m0_resp_last = u_dut.m0_resp_last;
    assign debug_ic_state_flags = u_dut.debug_ic_state_flags;
    assign debug_memsubsys_m0_ddr3_resp_valid = u_dut.gen_mem_subsys.u_mem_subsys.m0_ddr3_resp_valid_r;
    assign debug_memsubsys_m0_ddr3_resp_data = u_dut.gen_mem_subsys.u_mem_subsys.m0_ddr3_resp_data_r;
    assign debug_memsubsys_m0_ddr3_resp_last = u_dut.gen_mem_subsys.u_mem_subsys.m0_ddr3_resp_last_r;
    assign debug_memsubsys_ddr3_arb_state = u_dut.gen_mem_subsys.u_mem_subsys.ddr3_arb_state;
    assign debug_memsubsys_ddr3_m0_word_idx = u_dut.gen_mem_subsys.u_mem_subsys.ddr3_m0_word_idx_r;
`ifdef ENABLE_DDR3
    assign debug_dcache_miss_event = u_dut.gen_mem_subsys.u_mem_subsys.dcache_miss_event;
`else
    assign debug_dcache_miss_event = 1'b0;
`endif
    assign debug_bad_uart_store_seen = u_dut.dbg_bad_uart_store_seen_r;
    assign debug_bad_uart_store_pc = u_dut.dbg_bad_uart_store_pc_r;
    assign debug_bad_uart_store_addr = u_dut.dbg_bad_uart_store_addr_r;
    assign debug_bad_uart_store_op_a = u_dut.dbg_bad_uart_store_op_a_r;
    assign debug_bad_uart_store_op_b = u_dut.dbg_bad_uart_store_op_b_r;
    assign debug_bad_uart_store_imm = u_dut.dbg_bad_uart_store_imm_r;
    assign debug_bad_uart_store_order_id = u_dut.dbg_bad_uart_store_order_id_r;
    assign debug_bad_uart_store_tag = u_dut.dbg_bad_uart_store_tag_r;
    assign debug_bad_uart_store_rd = u_dut.dbg_bad_uart_store_rd_r;
    assign debug_bad_uart_store_rs1 = u_dut.dbg_bad_uart_store_rs1_r;
    assign debug_bad_uart_store_rs2 = u_dut.dbg_bad_uart_store_rs2_r;
    assign debug_bad_uart_store_src1_tag = u_dut.dbg_bad_uart_store_src1_tag_r;
    assign debug_bad_uart_store_src2_tag = u_dut.dbg_bad_uart_store_src2_tag_r;
    assign debug_bad_uart_store_prs1 = u_dut.dbg_bad_uart_store_prs1_r;
    assign debug_bad_uart_store_prs2 = u_dut.dbg_bad_uart_store_prs2_r;
    assign debug_bad_uart_store_prf_a = u_dut.dbg_bad_uart_store_prf_a_r;
    assign debug_bad_uart_store_prf_b = u_dut.dbg_bad_uart_store_prf_b_r;
    assign debug_bad_uart_store_tagbuf_a_valid = u_dut.dbg_bad_uart_store_tagbuf_a_valid_r;
    assign debug_bad_uart_store_tagbuf_b_valid = u_dut.dbg_bad_uart_store_tagbuf_b_valid_r;
    assign debug_bad_uart_store_tagbuf_a_data = u_dut.dbg_bad_uart_store_tagbuf_a_data_r;
    assign debug_bad_uart_store_tagbuf_b_data = u_dut.dbg_bad_uart_store_tagbuf_b_data_r;
    assign debug_bad_uart_store_fwd_a = u_dut.dbg_bad_uart_store_fwd_a_r;
    assign debug_bad_uart_store_fwd_b = u_dut.dbg_bad_uart_store_fwd_b_r;
    assign debug_bad_uart_store_func3 = u_dut.dbg_bad_uart_store_func3_r;
    assign debug_bad_uart_store_tid = u_dut.dbg_bad_uart_store_tid_r;
    assign debug_strcpy_mv_seen = u_dut.dbg_strcpy_mv_seen_r;
    assign debug_strcpy_mv_pc = u_dut.dbg_strcpy_mv_pc_r;
    assign debug_strcpy_mv_op_a = u_dut.dbg_strcpy_mv_op_a_r;
    assign debug_strcpy_mv_op_b = u_dut.dbg_strcpy_mv_op_b_r;
    assign debug_strcpy_mv_order_id = u_dut.dbg_strcpy_mv_order_id_r;
    assign debug_strcpy_mv_tag = u_dut.dbg_strcpy_mv_tag_r;
    assign debug_strcpy_mv_rd = u_dut.dbg_strcpy_mv_rd_r;
    assign debug_strcpy_mv_tid = u_dut.dbg_strcpy_mv_tid_r;
    assign debug_strcpy_mv_rs1 = u_dut.dbg_strcpy_mv_rs1_r;
    assign debug_strcpy_mv_rs2 = u_dut.dbg_strcpy_mv_rs2_r;
    assign debug_strcpy_mv_src1_tag = u_dut.dbg_strcpy_mv_src1_tag_r;
    assign debug_strcpy_mv_src2_tag = u_dut.dbg_strcpy_mv_src2_tag_r;
    assign debug_strcpy_mv_prd = u_dut.dbg_strcpy_mv_prd_r;
    assign debug_strcpy_mv_prs1 = u_dut.dbg_strcpy_mv_prs1_r;
    assign debug_strcpy_mv_prs2 = u_dut.dbg_strcpy_mv_prs2_r;
    assign debug_strcpy_mv_prf_a = u_dut.dbg_strcpy_mv_prf_a_r;
    assign debug_strcpy_mv_prf_b = u_dut.dbg_strcpy_mv_prf_b_r;
    assign debug_strcpy_mv_tagbuf_a_valid = u_dut.dbg_strcpy_mv_tagbuf_a_valid_r;
    assign debug_strcpy_mv_tagbuf_b_valid = u_dut.dbg_strcpy_mv_tagbuf_b_valid_r;
    assign debug_strcpy_mv_tagbuf_a_data = u_dut.dbg_strcpy_mv_tagbuf_a_data_r;
    assign debug_strcpy_mv_tagbuf_b_data = u_dut.dbg_strcpy_mv_tagbuf_b_data_r;
    assign debug_strcpy_mv_fwd_a = u_dut.dbg_strcpy_mv_fwd_a_r;
    assign debug_strcpy_mv_fwd_b = u_dut.dbg_strcpy_mv_fwd_b_r;
    assign debug_strcpy_mv_prf_w0_en = u_dut.dbg_strcpy_mv_prf_w0_en_r;
    assign debug_strcpy_mv_prf_w0_addr = u_dut.dbg_strcpy_mv_prf_w0_addr_r;
    assign debug_strcpy_mv_prf_w0_data = u_dut.dbg_strcpy_mv_prf_w0_data_r;
    assign debug_strcpy_mv_prf_w1_en = u_dut.dbg_strcpy_mv_prf_w1_en_r;
    assign debug_strcpy_mv_prf_w1_addr = u_dut.dbg_strcpy_mv_prf_w1_addr_r;
    assign debug_strcpy_mv_prf_w1_data = u_dut.dbg_strcpy_mv_prf_w1_data_r;
    assign debug_main_lw_a0_seen = u_dut.dbg_main_lw_a0_seen_r;
    assign debug_main_lw_a0_addr = u_dut.dbg_main_lw_a0_addr_r;
    assign debug_main_lw_a0_order_id = u_dut.dbg_main_lw_a0_order_id_r;
    assign debug_main_lw_a0_tag = u_dut.dbg_main_lw_a0_tag_r;
    assign debug_main_lw_a0_prd = u_dut.dbg_main_lw_a0_prd_r;
    assign debug_main_lw_a0_prs1 = u_dut.dbg_main_lw_a0_prs1_r;
    assign debug_main_lw_a0_base = u_dut.dbg_main_lw_a0_base_r;
    assign debug_main_lw_a0_imm = u_dut.dbg_main_lw_a0_imm_r;
    assign debug_main_lw_a0_wb_seen = u_dut.dbg_main_lw_a0_wb_seen_r;
    assign debug_main_lw_a0_wb_data = u_dut.dbg_main_lw_a0_wb_data_r;
    assign debug_main_lw_a0_wb_prd = u_dut.dbg_main_lw_a0_wb_prd_r;
    assign debug_main_addi_a0_seen = u_dut.dbg_main_addi_a0_seen_r;
    assign debug_main_addi_a0_op_a = u_dut.dbg_main_addi_a0_op_a_r;
    assign debug_main_addi_a0_result = u_dut.dbg_main_addi_a0_result_r;
    assign debug_main_addi_a0_order_id = u_dut.dbg_main_addi_a0_order_id_r;
    assign debug_main_addi_a0_tag = u_dut.dbg_main_addi_a0_tag_r;
    assign debug_main_addi_a0_prd = u_dut.dbg_main_addi_a0_prd_r;
    assign debug_main_addi_a0_prs1 = u_dut.dbg_main_addi_a0_prs1_r;
    assign debug_main_addi_a0_src1_tag = u_dut.dbg_main_addi_a0_src1_tag_r;
    assign debug_main_addi_a0_prf_a = u_dut.dbg_main_addi_a0_prf_a_r;
    assign debug_main_addi_a0_tagbuf_a_valid = u_dut.dbg_main_addi_a0_tagbuf_a_valid_r;
    assign debug_main_addi_a0_tagbuf_a_data = u_dut.dbg_main_addi_a0_tagbuf_a_data_r;
    assign debug_main_a0_prd_write_count = u_dut.dbg_main_a0_prd_write_count_r;
    assign debug_main_a0_prd_last_write_port = u_dut.dbg_main_a0_prd_last_write_port_r;
    assign debug_main_a0_prd_last_write_data = u_dut.dbg_main_a0_prd_last_write_data_r;
    assign debug_main_a0_prd_last_write_tag = u_dut.dbg_main_a0_prd_last_write_tag_r;
    assign debug_main_a0_prd_last_write_rd = u_dut.dbg_main_a0_prd_last_write_rd_r;
    assign debug_main_a0_prd_last_write_fu = u_dut.dbg_main_a0_prd_last_write_fu_r;
    assign debug_main_a0_prd_last_write_pc = u_dut.dbg_main_a0_prd_last_write_pc_r;
    assign debug_main_a0_prd_last_write_order_id = u_dut.dbg_main_a0_prd_last_write_order_id_r;
    assign debug_main_a0_prd_first_bad_write_seen = u_dut.dbg_main_a0_prd_first_bad_write_seen_r;
    assign debug_main_a0_prd_first_bad_write_port = u_dut.dbg_main_a0_prd_first_bad_write_port_r;
    assign debug_main_a0_prd_first_bad_write_data = u_dut.dbg_main_a0_prd_first_bad_write_data_r;
    assign debug_main_a0_prd_first_bad_write_tag = u_dut.dbg_main_a0_prd_first_bad_write_tag_r;
    assign debug_main_a0_prd_first_bad_write_rd = u_dut.dbg_main_a0_prd_first_bad_write_rd_r;
    assign debug_main_a0_prd_first_bad_write_fu = u_dut.dbg_main_a0_prd_first_bad_write_fu_r;
    assign debug_main_a0_prd_first_bad_write_pc = u_dut.dbg_main_a0_prd_first_bad_write_pc_r;
    assign debug_main_a0_prd_first_bad_write_order_id = u_dut.dbg_main_a0_prd_first_bad_write_order_id_r;
    assign debug_main_a0_prd_first_free_seen = u_dut.dbg_main_a0_prd_first_free_seen_r;
    assign debug_main_a0_prd_first_free_port = u_dut.dbg_main_a0_prd_first_free_port_r;
    assign debug_main_a0_prd_first_free_rd = u_dut.dbg_main_a0_prd_first_free_rd_r;
    assign debug_main_a0_prd_first_free_tag = u_dut.dbg_main_a0_prd_first_free_tag_r;
    assign debug_main_a0_prd_first_free_order_id = u_dut.dbg_main_a0_prd_first_free_order_id_r;
    assign debug_main_addi_a0_wb_seen = u_dut.dbg_main_addi_a0_wb_seen_r;
    assign debug_main_addi_a0_wb_port = u_dut.dbg_main_addi_a0_wb_port_r;
    assign debug_main_addi_a0_wb_tid = u_dut.dbg_main_addi_a0_wb_tid_r;
    assign debug_main_addi_a0_wb_prd = u_dut.dbg_main_addi_a0_wb_prd_r;
    assign debug_main_addi_a0_wb_data = u_dut.dbg_main_addi_a0_wb_data_r;
    assign debug_main_addi_a0_wb_w0_en = u_dut.dbg_main_addi_a0_wb_w0_en_r;
    assign debug_main_addi_a0_wb_w0_addr = u_dut.dbg_main_addi_a0_wb_w0_addr_r;
    assign debug_main_addi_a0_wb_w0_data = u_dut.dbg_main_addi_a0_wb_w0_data_r;
    assign debug_main_addi_a0_wb_w1_en = u_dut.dbg_main_addi_a0_wb_w1_en_r;
    assign debug_main_addi_a0_wb_w1_addr = u_dut.dbg_main_addi_a0_wb_w1_addr_r;
    assign debug_main_addi_a0_wb_w1_data = u_dut.dbg_main_addi_a0_wb_w1_data_r;

endmodule
