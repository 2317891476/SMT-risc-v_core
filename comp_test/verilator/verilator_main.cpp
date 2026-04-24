#include "Vverilator_mainline_top.h"
#include "verilated.h"
#if VM_TRACE_FST
#include "verilated_fst_c.h"
#elif VM_TRACE
#include "verilated_vcd_c.h"
#endif

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct Config {
    std::string mode = "preload";
    std::string payload_bin;
    std::string summary_json;
    std::string uart_log;
    uint32_t entry_pc = 0x80000000u;
    uint32_t payload_base = 0x80000000u;
    uint64_t max_cycles = 2'000'000ULL;
    uint32_t header_gap_cycles = 16;
    uint32_t payload_gap_cycles = 2;
    uint64_t stuck_pc_threshold = 256ULL;
    uint64_t stall_cycle_threshold = 200'000ULL;
    uint64_t danger_window_instret_threshold = 1024ULL;
    uint32_t danger_window_start = 0x80000D50u;
    uint32_t danger_window_end = 0x80000D80u;
    bool trace = false;
    bool trace_on_stuck = false;
    uint64_t trace_start_cycle = 0ULL;
    uint64_t trace_stop_cycle = 0ULL;
    uint64_t trace_after_stuck_cycles = 4096ULL;
    std::string trace_file;
};

struct Summary {
    std::string mode;
    std::string exit_reason = "timeout";
    bool entry_reached = false;
    bool benchmark_start_seen = false;
    bool benchmark_done_seen = false;
    bool loader_semantic_pass = false;
    bool trap_seen = false;
    uint32_t trap_cause = 0;
    uint64_t cycles = 0;
    uint64_t instret = 0;
    uint32_t ipcx1000 = 0;
    uint32_t last_pc_t0 = 0;
    uint32_t last_pc_t1 = 0;
    uint32_t last_fetch_pc_pending = 0;
    uint32_t last_fetch_pc_out = 0;
    uint32_t last_fetch_if_inst = 0;
    uint32_t last_fetch_if_flags = 0;
    uint32_t last_ic_state_flags = 0;
    uint32_t ic_high_miss_count = 0;
    uint32_t ic_mem_req_count = 0;
    uint32_t ic_mem_resp_count = 0;
    uint32_t ic_cpu_resp_count = 0;
    uint32_t instr_retired_count = 0;
    uint32_t rob_commit0_seen_count = 0;
    uint32_t rob_commit1_seen_count = 0;
    uint32_t last_rob_commit0_order_id = 0;
    uint32_t last_rob_commit1_order_id = 0;
    uint32_t last_rob_count_t0 = 0;
    uint32_t last_rob_count_t1 = 0;
    bool last_rob_head_flushed_t0 = false;
    bool last_rob_head_flushed_t1 = false;
    bool last_rob_recovering = false;
    uint32_t last_rob_recover_tid = 0;
    uint32_t last_rob_recover_ptr = 0;
    uint32_t mem_iss_seen_count = 0;
    uint32_t p1_winner_count = 0;
    uint32_t p1_mem_winner_count = 0;
    uint32_t wb1_mem_count = 0;
    bool last_p1_winner_valid = false;
    uint32_t last_p1_winner = 0;
    bool last_mem_fu_busy = false;
    uint32_t last_mem_fu_order_id = 0;
    uint32_t last_mem_fu_tid = 0;
    bool last_mem_issue_inhibit = false;
    bool last_p1_mem_cand_valid = false;
    uint32_t last_p1_mem_cand_order_id = 0;
    uint32_t last_p1_mem_cand_tag = 0;
    bool last_p1_mem_cand_read = false;
    bool last_p1_mem_cand_write = false;
    bool last_mem_cand_raw_valid = false;
    bool last_mem_cand_clear = false;
    bool last_mem_cand_set = false;
    bool last_iq_mem_sel_found = false;
    uint32_t last_iq_mem_sel_idx = 0;
    bool last_iq_mem_oldest_store_valid_t0 = false;
    bool last_iq_mem_oldest_store_valid_t1 = false;
    uint32_t last_iq_mem_oldest_store_order_id_t0 = 0;
    uint32_t last_iq_mem_oldest_store_order_id_t1 = 0;
    uint32_t last_iq_mem_store_count_t0 = 0;
    uint32_t last_iq_mem_store_count_t1 = 0;
    bool last_flush = false;
    uint32_t last_flush_tid = 0;
    bool last_flush_order_valid = false;
    uint32_t last_flush_order_id = 0;
    bool last_wb0_valid = false;
    uint32_t last_wb0_tag = 0;
    bool last_wb0_regs_write = false;
    bool last_wb1_valid = false;
    uint32_t last_wb1_tag = 0;
    bool last_wb1_regs_write = false;
    uint32_t last_wb1_fu = 0;
    uint32_t uart_status_load_count = 0;
    uint32_t uart_tx_store_count = 0;
    uint32_t uart_tx_byte_seen_count = 0;
    uint32_t last_uart_tx_byte = 0;
    bool unexpected_uart_seen = false;
    uint64_t unexpected_uart_cycle = 0;
    uint32_t unexpected_uart_index = 0;
    uint32_t unexpected_uart_expected = 0;
    uint32_t unexpected_uart_actual = 0;
    uint32_t unexpected_uart_pc_t0 = 0;
    bool unexpected_uart_lsu_req_valid = false;
    bool unexpected_uart_lsu_req_accept = false;
    uint32_t unexpected_uart_lsu_req_order_id = 0;
    uint32_t unexpected_uart_lsu_req_tag = 0;
    uint32_t unexpected_uart_lsu_req_addr = 0;
    uint32_t unexpected_uart_lsu_req_wdata = 0;
    uint32_t unexpected_uart_lsu_req_func3 = 0;
    bool unexpected_uart_lsu_req_wen = false;
    bool unexpected_uart_m1_req_valid = false;
    bool unexpected_uart_m1_req_ready = false;
    uint32_t unexpected_uart_m1_req_addr = 0;
    uint32_t unexpected_uart_m1_req_wdata = 0;
    uint32_t unexpected_uart_m1_req_wen = 0;
    bool unexpected_uart_m1_req_write = false;
    bool unexpected_uart_wb0_valid = false;
    uint32_t unexpected_uart_wb0_tag = 0;
    uint32_t unexpected_uart_wb0_data = 0;
    bool unexpected_uart_wb1_valid = false;
    uint32_t unexpected_uart_wb1_tag = 0;
    uint32_t unexpected_uart_wb1_fu = 0;
    uint32_t unexpected_uart_wb1_data = 0;
    bool bad_uart_store_seen = false;
    uint64_t bad_uart_store_cycle = 0;
    uint32_t bad_uart_store_pc = 0;
    uint32_t bad_uart_store_addr = 0;
    uint32_t bad_uart_store_op_a = 0;
    uint32_t bad_uart_store_op_b = 0;
    uint32_t bad_uart_store_imm = 0;
    uint32_t bad_uart_store_order_id = 0;
    uint32_t bad_uart_store_tag = 0;
    uint32_t bad_uart_store_rd = 0;
    uint32_t bad_uart_store_rs1 = 0;
    uint32_t bad_uart_store_rs2 = 0;
    uint32_t bad_uart_store_src1_tag = 0;
    uint32_t bad_uart_store_src2_tag = 0;
    uint32_t bad_uart_store_prs1 = 0;
    uint32_t bad_uart_store_prs2 = 0;
    uint32_t bad_uart_store_prf_a = 0;
    uint32_t bad_uart_store_prf_b = 0;
    bool bad_uart_store_tagbuf_a_valid = false;
    bool bad_uart_store_tagbuf_b_valid = false;
    uint32_t bad_uart_store_tagbuf_a_data = 0;
    uint32_t bad_uart_store_tagbuf_b_data = 0;
    uint32_t bad_uart_store_fwd_a = 0;
    uint32_t bad_uart_store_fwd_b = 0;
    uint32_t bad_uart_store_func3 = 0;
    uint32_t bad_uart_store_tid = 0;
    bool strcpy_mv_seen = false;
    uint64_t strcpy_mv_cycle = 0;
    uint32_t strcpy_mv_pc = 0;
    uint32_t strcpy_mv_op_a = 0;
    uint32_t strcpy_mv_op_b = 0;
    uint32_t strcpy_mv_order_id = 0;
    uint32_t strcpy_mv_tag = 0;
    uint32_t strcpy_mv_rd = 0;
    uint32_t strcpy_mv_tid = 0;
    uint32_t strcpy_mv_rs1 = 0;
    uint32_t strcpy_mv_rs2 = 0;
    uint32_t strcpy_mv_src1_tag = 0;
    uint32_t strcpy_mv_src2_tag = 0;
    uint32_t strcpy_mv_prd = 0;
    uint32_t strcpy_mv_prs1 = 0;
    uint32_t strcpy_mv_prs2 = 0;
    uint32_t strcpy_mv_prf_a = 0;
    uint32_t strcpy_mv_prf_b = 0;
    bool strcpy_mv_tagbuf_a_valid = false;
    bool strcpy_mv_tagbuf_b_valid = false;
    uint32_t strcpy_mv_tagbuf_a_data = 0;
    uint32_t strcpy_mv_tagbuf_b_data = 0;
    uint32_t strcpy_mv_fwd_a = 0;
    uint32_t strcpy_mv_fwd_b = 0;
    bool strcpy_mv_prf_w0_en = false;
    uint32_t strcpy_mv_prf_w0_addr = 0;
    uint32_t strcpy_mv_prf_w0_data = 0;
    bool strcpy_mv_prf_w1_en = false;
    uint32_t strcpy_mv_prf_w1_addr = 0;
    uint32_t strcpy_mv_prf_w1_data = 0;
    bool main_lw_a0_seen = false;
    uint32_t main_lw_a0_addr = 0;
    uint32_t main_lw_a0_order_id = 0;
    uint32_t main_lw_a0_tag = 0;
    uint32_t main_lw_a0_prd = 0;
    uint32_t main_lw_a0_prs1 = 0;
    uint32_t main_lw_a0_base = 0;
    uint32_t main_lw_a0_imm = 0;
    bool main_lw_a0_wb_seen = false;
    uint32_t main_lw_a0_wb_data = 0;
    uint32_t main_lw_a0_wb_prd = 0;
    bool main_addi_a0_seen = false;
    uint32_t main_addi_a0_op_a = 0;
    uint32_t main_addi_a0_result = 0;
    uint32_t main_addi_a0_order_id = 0;
    uint32_t main_addi_a0_tag = 0;
    uint32_t main_addi_a0_prd = 0;
    uint32_t main_addi_a0_prs1 = 0;
    uint32_t main_addi_a0_src1_tag = 0;
    uint32_t main_addi_a0_prf_a = 0;
    bool main_addi_a0_tagbuf_a_valid = false;
    uint32_t main_addi_a0_tagbuf_a_data = 0;
    uint32_t main_a0_prd_write_count = 0;
    uint32_t main_a0_prd_last_write_port = 0;
    uint32_t main_a0_prd_last_write_data = 0;
    uint32_t main_a0_prd_last_write_tag = 0;
    uint32_t main_a0_prd_last_write_rd = 0;
    uint32_t main_a0_prd_last_write_fu = 0;
    uint32_t main_a0_prd_last_write_pc = 0;
    uint32_t main_a0_prd_last_write_order_id = 0;
    bool main_a0_prd_first_bad_write_seen = false;
    uint32_t main_a0_prd_first_bad_write_port = 0;
    uint32_t main_a0_prd_first_bad_write_data = 0;
    uint32_t main_a0_prd_first_bad_write_tag = 0;
    uint32_t main_a0_prd_first_bad_write_rd = 0;
    uint32_t main_a0_prd_first_bad_write_fu = 0;
    uint32_t main_a0_prd_first_bad_write_pc = 0;
    uint32_t main_a0_prd_first_bad_write_order_id = 0;
    bool main_a0_prd_first_free_seen = false;
    uint32_t main_a0_prd_first_free_port = 0;
    uint32_t main_a0_prd_first_free_rd = 0;
    uint32_t main_a0_prd_first_free_tag = 0;
    uint32_t main_a0_prd_first_free_order_id = 0;
    bool main_addi_a0_wb_seen = false;
    uint64_t main_addi_a0_wb_cycle = 0;
    uint32_t main_addi_a0_wb_port = 0;
    uint32_t main_addi_a0_wb_tid = 0;
    uint32_t main_addi_a0_wb_prd = 0;
    uint32_t main_addi_a0_wb_data = 0;
    bool main_addi_a0_wb_w0_en = false;
    uint32_t main_addi_a0_wb_w0_addr = 0;
    uint32_t main_addi_a0_wb_w0_data = 0;
    bool main_addi_a0_wb_w1_en = false;
    uint32_t main_addi_a0_wb_w1_addr = 0;
    uint32_t main_addi_a0_wb_w1_data = 0;
    uint32_t mock_mem_reads = 0;
    uint32_t mock_mem_writes = 0;
    uint32_t mock_mem_last_read_addr = 0;
    uint32_t mock_mem_last_write_addr = 0;
    uint32_t mock_mem_last_write_data = 0;
    uint32_t mock_mem_range_error_count = 0;
    uint32_t mock_mem_last_range_error_addr = 0;
    uint32_t mock_mem_uninit_read_count = 0;
    uint32_t lsu_req_seen_count = 0;
    uint32_t lsu_req_accept_count = 0;
    uint32_t lsu_resp_seen_count = 0;
    bool last_lsu_m1_cooldown = false;
    bool last_lsu_drain_holdoff = false;
    bool last_lsu_sb_drain_urgent = false;
    bool last_lsu_sb_has_pending_stores = false;
    bool last_lsu_sb_mem_write_valid = false;
    bool store_buffer_empty_last = false;
    uint32_t store_count_t0_last = 0;
    uint32_t store_count_t1_last = 0;
    uint32_t m1_req_seen_count = 0;
    uint32_t m1_req_handshake_count = 0;
    uint32_t last_m1_req_addr = 0;
    bool last_m1_req_write = false;
    uint64_t last_instret_progress_cycle = 0;
    uint64_t last_commit_progress_cycle = 0;
    uint64_t last_lsu_req_accept_cycle = 0;
    uint64_t last_m1_req_handshake_cycle = 0;
    uint64_t loader_bytes_injected = 0;
    uint32_t ddr3_req_seen_count = 0;
    uint32_t ddr3_req_handshake_count = 0;
    uint32_t ddr3_resp_seen_count = 0;
    uint32_t m0_req_seen_count = 0;
    uint32_t m0_req_handshake_count = 0;
    uint32_t m0_resp_seen_count = 0;
    uint64_t last_m0_req_handshake_cycle = 0;
    uint64_t last_m0_resp_cycle = 0;
    uint32_t last_ddr3_req_addr = 0;
    uint32_t last_ddr3_req_wdata = 0;
    uint32_t last_ddr3_resp_data = 0;
    uint32_t last_ddr3_req_wen = 0;
    uint32_t last_m0_req_addr = 0;
    uint32_t last_m0_resp_data = 0;
    uint32_t memsubsys_m0_ddr3_resp_seen_count = 0;
    uint32_t last_memsubsys_m0_ddr3_resp_data = 0;
    uint32_t last_memsubsys_ddr3_arb_state = 0;
    uint32_t last_memsubsys_ddr3_m0_word_idx = 0;
    uint32_t dcache_miss_event_count = 0;
    bool last_dcache_miss_event = false;
    bool last_ddr3_req_write = false;
    bool last_m0_resp_last = false;
    bool last_memsubsys_m0_ddr3_resp_last = false;
    bool stuck_pc_seen = false;
    uint32_t stuck_pc_value = 0;
    uint64_t stuck_pc_repeat_count = 0;
    bool retire_stall_seen = false;
    uint64_t retire_stall_cycles = 0;
    bool danger_window_seen = false;
    uint32_t danger_window_entry_pc = 0;
    uint64_t danger_entry_cycle = 0;
    uint64_t danger_entry_instret = 0;
    uint32_t danger_entry_lsu_req_seen = 0;
    uint32_t danger_entry_lsu_req_accept = 0;
    uint32_t danger_entry_lsu_resp_seen = 0;
    uint32_t danger_entry_m1_req_seen = 0;
    uint32_t danger_entry_m1_req_handshake = 0;
    uint32_t danger_entry_m0_req_seen = 0;
    uint32_t danger_entry_m0_req_handshake = 0;
    uint32_t danger_entry_m0_resp_seen = 0;
    uint32_t danger_entry_mock_mem_writes = 0;
    uint32_t danger_lsu_req_seen_delta = 0;
    uint32_t danger_lsu_req_accept_delta = 0;
    uint32_t danger_lsu_resp_seen_delta = 0;
    uint32_t danger_m1_req_seen_delta = 0;
    uint32_t danger_m1_req_handshake_delta = 0;
    uint32_t danger_m0_req_seen_delta = 0;
    uint32_t danger_m0_req_handshake_delta = 0;
    uint32_t danger_m0_resp_seen_delta = 0;
    uint32_t danger_mock_mem_writes_delta = 0;
    uint32_t last_m1_req_addr_after_danger = 0;
    bool last_m1_req_write_after_danger = false;
    uint32_t last_m0_req_addr_after_danger = 0;
};

std::string json_escape(const std::string& value) {
    std::ostringstream oss;
    for (char ch : value) {
        switch (ch) {
        case '\\': oss << "\\\\"; break;
        case '"': oss << "\\\""; break;
        case '\n': oss << "\\n"; break;
        case '\r': oss << "\\r"; break;
        case '\t': oss << "\\t"; break;
        default:
            if (static_cast<unsigned char>(ch) < 0x20) {
                oss << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                    << static_cast<int>(static_cast<unsigned char>(ch)) << std::dec;
            } else {
                oss << ch;
            }
        }
    }
    return oss.str();
}

void write_summary_json(const Summary& summary, const std::string& path) {
    std::ofstream ofs(path, std::ios::out | std::ios::trunc);
    ofs << "{\n";
    ofs << "  \"Mode\": \"" << json_escape(summary.mode) << "\",\n";
    ofs << "  \"ExitReason\": \"" << json_escape(summary.exit_reason) << "\",\n";
    ofs << "  \"EntryReached\": " << (summary.entry_reached ? "true" : "false") << ",\n";
    ofs << "  \"BenchmarkStartSeen\": " << (summary.benchmark_start_seen ? "true" : "false") << ",\n";
    ofs << "  \"BenchmarkDoneSeen\": " << (summary.benchmark_done_seen ? "true" : "false") << ",\n";
    ofs << "  \"LoaderSemanticPass\": " << (summary.loader_semantic_pass ? "true" : "false") << ",\n";
    ofs << "  \"TrapSeen\": " << (summary.trap_seen ? "true" : "false") << ",\n";
    ofs << "  \"TrapCause\": " << summary.trap_cause << ",\n";
    ofs << "  \"Cycles\": " << summary.cycles << ",\n";
    ofs << "  \"InstRetired\": " << summary.instret << ",\n";
    ofs << "  \"IPCx1000\": " << summary.ipcx1000 << ",\n";
    ofs << "  \"LastPcT0\": " << summary.last_pc_t0 << ",\n";
    ofs << "  \"LastPcT1\": " << summary.last_pc_t1 << ",\n";
    ofs << "  \"LastFetchPcPending\": " << summary.last_fetch_pc_pending << ",\n";
    ofs << "  \"LastFetchPcOut\": " << summary.last_fetch_pc_out << ",\n";
    ofs << "  \"LastFetchIfInst\": " << summary.last_fetch_if_inst << ",\n";
    ofs << "  \"LastFetchIfFlags\": " << summary.last_fetch_if_flags << ",\n";
    ofs << "  \"LastIcStateFlags\": " << summary.last_ic_state_flags << ",\n";
    ofs << "  \"IcHighMissCount\": " << summary.ic_high_miss_count << ",\n";
    ofs << "  \"IcMemReqCount\": " << summary.ic_mem_req_count << ",\n";
    ofs << "  \"IcMemRespCount\": " << summary.ic_mem_resp_count << ",\n";
    ofs << "  \"IcCpuRespCount\": " << summary.ic_cpu_resp_count << ",\n";
    ofs << "  \"InstrRetiredCount\": " << summary.instr_retired_count << ",\n";
    ofs << "  \"RobCommit0SeenCount\": " << summary.rob_commit0_seen_count << ",\n";
    ofs << "  \"RobCommit1SeenCount\": " << summary.rob_commit1_seen_count << ",\n";
    ofs << "  \"LastRobCommit0OrderId\": " << summary.last_rob_commit0_order_id << ",\n";
    ofs << "  \"LastRobCommit1OrderId\": " << summary.last_rob_commit1_order_id << ",\n";
    ofs << "  \"LastRobCountT0\": " << summary.last_rob_count_t0 << ",\n";
    ofs << "  \"LastRobCountT1\": " << summary.last_rob_count_t1 << ",\n";
    ofs << "  \"LastRobHeadFlushedT0\": " << (summary.last_rob_head_flushed_t0 ? "true" : "false") << ",\n";
    ofs << "  \"LastRobHeadFlushedT1\": " << (summary.last_rob_head_flushed_t1 ? "true" : "false") << ",\n";
    ofs << "  \"LastRobRecovering\": " << (summary.last_rob_recovering ? "true" : "false") << ",\n";
    ofs << "  \"LastRobRecoverTid\": " << summary.last_rob_recover_tid << ",\n";
    ofs << "  \"LastRobRecoverPtr\": " << summary.last_rob_recover_ptr << ",\n";
    ofs << "  \"MemIssSeenCount\": " << summary.mem_iss_seen_count << ",\n";
    ofs << "  \"P1WinnerCount\": " << summary.p1_winner_count << ",\n";
    ofs << "  \"P1MemWinnerCount\": " << summary.p1_mem_winner_count << ",\n";
    ofs << "  \"Wb1MemCount\": " << summary.wb1_mem_count << ",\n";
    ofs << "  \"LastP1WinnerValid\": " << (summary.last_p1_winner_valid ? "true" : "false") << ",\n";
    ofs << "  \"LastP1Winner\": " << summary.last_p1_winner << ",\n";
    ofs << "  \"LastMemFuBusy\": " << (summary.last_mem_fu_busy ? "true" : "false") << ",\n";
    ofs << "  \"LastMemFuOrderId\": " << summary.last_mem_fu_order_id << ",\n";
    ofs << "  \"LastMemFuTid\": " << summary.last_mem_fu_tid << ",\n";
    ofs << "  \"LastMemIssueInhibit\": " << (summary.last_mem_issue_inhibit ? "true" : "false") << ",\n";
    ofs << "  \"LastP1MemCandValid\": " << (summary.last_p1_mem_cand_valid ? "true" : "false") << ",\n";
    ofs << "  \"LastP1MemCandOrderId\": " << summary.last_p1_mem_cand_order_id << ",\n";
    ofs << "  \"LastP1MemCandTag\": " << summary.last_p1_mem_cand_tag << ",\n";
    ofs << "  \"LastP1MemCandRead\": " << (summary.last_p1_mem_cand_read ? "true" : "false") << ",\n";
    ofs << "  \"LastP1MemCandWrite\": " << (summary.last_p1_mem_cand_write ? "true" : "false") << ",\n";
    ofs << "  \"LastMemCandRawValid\": " << (summary.last_mem_cand_raw_valid ? "true" : "false") << ",\n";
    ofs << "  \"LastMemCandClear\": " << (summary.last_mem_cand_clear ? "true" : "false") << ",\n";
    ofs << "  \"LastMemCandSet\": " << (summary.last_mem_cand_set ? "true" : "false") << ",\n";
    ofs << "  \"LastIqMemSelFound\": " << (summary.last_iq_mem_sel_found ? "true" : "false") << ",\n";
    ofs << "  \"LastIqMemSelIdx\": " << summary.last_iq_mem_sel_idx << ",\n";
    ofs << "  \"LastIqMemOldestStoreValidT0\": " << (summary.last_iq_mem_oldest_store_valid_t0 ? "true" : "false") << ",\n";
    ofs << "  \"LastIqMemOldestStoreValidT1\": " << (summary.last_iq_mem_oldest_store_valid_t1 ? "true" : "false") << ",\n";
    ofs << "  \"LastIqMemOldestStoreOrderIdT0\": " << summary.last_iq_mem_oldest_store_order_id_t0 << ",\n";
    ofs << "  \"LastIqMemOldestStoreOrderIdT1\": " << summary.last_iq_mem_oldest_store_order_id_t1 << ",\n";
    ofs << "  \"LastIqMemStoreCountT0\": " << summary.last_iq_mem_store_count_t0 << ",\n";
    ofs << "  \"LastIqMemStoreCountT1\": " << summary.last_iq_mem_store_count_t1 << ",\n";
    ofs << "  \"LastFlush\": " << (summary.last_flush ? "true" : "false") << ",\n";
    ofs << "  \"LastFlushTid\": " << summary.last_flush_tid << ",\n";
    ofs << "  \"LastFlushOrderValid\": " << (summary.last_flush_order_valid ? "true" : "false") << ",\n";
    ofs << "  \"LastFlushOrderId\": " << summary.last_flush_order_id << ",\n";
    ofs << "  \"LastWb0Valid\": " << (summary.last_wb0_valid ? "true" : "false") << ",\n";
    ofs << "  \"LastWb0Tag\": " << summary.last_wb0_tag << ",\n";
    ofs << "  \"LastWb0RegsWrite\": " << (summary.last_wb0_regs_write ? "true" : "false") << ",\n";
    ofs << "  \"LastWb1Valid\": " << (summary.last_wb1_valid ? "true" : "false") << ",\n";
    ofs << "  \"LastWb1Tag\": " << summary.last_wb1_tag << ",\n";
    ofs << "  \"LastWb1RegsWrite\": " << (summary.last_wb1_regs_write ? "true" : "false") << ",\n";
    ofs << "  \"LastWb1Fu\": " << summary.last_wb1_fu << ",\n";
    ofs << "  \"UartStatusLoadCount\": " << summary.uart_status_load_count << ",\n";
    ofs << "  \"UartTxStoreCount\": " << summary.uart_tx_store_count << ",\n";
    ofs << "  \"UartTxByteSeenCount\": " << summary.uart_tx_byte_seen_count << ",\n";
    ofs << "  \"LastUartTxByte\": " << summary.last_uart_tx_byte << ",\n";
    ofs << "  \"UnexpectedUartSeen\": " << (summary.unexpected_uart_seen ? "true" : "false") << ",\n";
    ofs << "  \"UnexpectedUartCycle\": " << summary.unexpected_uart_cycle << ",\n";
    ofs << "  \"UnexpectedUartIndex\": " << summary.unexpected_uart_index << ",\n";
    ofs << "  \"UnexpectedUartExpected\": " << summary.unexpected_uart_expected << ",\n";
    ofs << "  \"UnexpectedUartActual\": " << summary.unexpected_uart_actual << ",\n";
    ofs << "  \"UnexpectedUartPcT0\": " << summary.unexpected_uart_pc_t0 << ",\n";
    ofs << "  \"UnexpectedUartLsuReqValid\": " << (summary.unexpected_uart_lsu_req_valid ? "true" : "false") << ",\n";
    ofs << "  \"UnexpectedUartLsuReqAccept\": " << (summary.unexpected_uart_lsu_req_accept ? "true" : "false") << ",\n";
    ofs << "  \"UnexpectedUartLsuReqOrderId\": " << summary.unexpected_uart_lsu_req_order_id << ",\n";
    ofs << "  \"UnexpectedUartLsuReqTag\": " << summary.unexpected_uart_lsu_req_tag << ",\n";
    ofs << "  \"UnexpectedUartLsuReqAddr\": " << summary.unexpected_uart_lsu_req_addr << ",\n";
    ofs << "  \"UnexpectedUartLsuReqWdata\": " << summary.unexpected_uart_lsu_req_wdata << ",\n";
    ofs << "  \"UnexpectedUartLsuReqFunc3\": " << summary.unexpected_uart_lsu_req_func3 << ",\n";
    ofs << "  \"UnexpectedUartLsuReqWen\": " << (summary.unexpected_uart_lsu_req_wen ? "true" : "false") << ",\n";
    ofs << "  \"UnexpectedUartM1ReqValid\": " << (summary.unexpected_uart_m1_req_valid ? "true" : "false") << ",\n";
    ofs << "  \"UnexpectedUartM1ReqReady\": " << (summary.unexpected_uart_m1_req_ready ? "true" : "false") << ",\n";
    ofs << "  \"UnexpectedUartM1ReqAddr\": " << summary.unexpected_uart_m1_req_addr << ",\n";
    ofs << "  \"UnexpectedUartM1ReqWdata\": " << summary.unexpected_uart_m1_req_wdata << ",\n";
    ofs << "  \"UnexpectedUartM1ReqWen\": " << summary.unexpected_uart_m1_req_wen << ",\n";
    ofs << "  \"UnexpectedUartM1ReqWrite\": " << (summary.unexpected_uart_m1_req_write ? "true" : "false") << ",\n";
    ofs << "  \"UnexpectedUartWb0Valid\": " << (summary.unexpected_uart_wb0_valid ? "true" : "false") << ",\n";
    ofs << "  \"UnexpectedUartWb0Tag\": " << summary.unexpected_uart_wb0_tag << ",\n";
    ofs << "  \"UnexpectedUartWb0Data\": " << summary.unexpected_uart_wb0_data << ",\n";
    ofs << "  \"UnexpectedUartWb1Valid\": " << (summary.unexpected_uart_wb1_valid ? "true" : "false") << ",\n";
    ofs << "  \"UnexpectedUartWb1Tag\": " << summary.unexpected_uart_wb1_tag << ",\n";
    ofs << "  \"UnexpectedUartWb1Fu\": " << summary.unexpected_uart_wb1_fu << ",\n";
    ofs << "  \"UnexpectedUartWb1Data\": " << summary.unexpected_uart_wb1_data << ",\n";
    ofs << "  \"BadUartStoreSeen\": " << (summary.bad_uart_store_seen ? "true" : "false") << ",\n";
    ofs << "  \"BadUartStoreCycle\": " << summary.bad_uart_store_cycle << ",\n";
    ofs << "  \"BadUartStorePc\": " << summary.bad_uart_store_pc << ",\n";
    ofs << "  \"BadUartStoreAddr\": " << summary.bad_uart_store_addr << ",\n";
    ofs << "  \"BadUartStoreOpA\": " << summary.bad_uart_store_op_a << ",\n";
    ofs << "  \"BadUartStoreOpB\": " << summary.bad_uart_store_op_b << ",\n";
    ofs << "  \"BadUartStoreImm\": " << summary.bad_uart_store_imm << ",\n";
    ofs << "  \"BadUartStoreOrderId\": " << summary.bad_uart_store_order_id << ",\n";
    ofs << "  \"BadUartStoreTag\": " << summary.bad_uart_store_tag << ",\n";
    ofs << "  \"BadUartStoreRd\": " << summary.bad_uart_store_rd << ",\n";
    ofs << "  \"BadUartStoreRs1\": " << summary.bad_uart_store_rs1 << ",\n";
    ofs << "  \"BadUartStoreRs2\": " << summary.bad_uart_store_rs2 << ",\n";
    ofs << "  \"BadUartStoreSrc1Tag\": " << summary.bad_uart_store_src1_tag << ",\n";
    ofs << "  \"BadUartStoreSrc2Tag\": " << summary.bad_uart_store_src2_tag << ",\n";
    ofs << "  \"BadUartStorePrs1\": " << summary.bad_uart_store_prs1 << ",\n";
    ofs << "  \"BadUartStorePrs2\": " << summary.bad_uart_store_prs2 << ",\n";
    ofs << "  \"BadUartStorePrfA\": " << summary.bad_uart_store_prf_a << ",\n";
    ofs << "  \"BadUartStorePrfB\": " << summary.bad_uart_store_prf_b << ",\n";
    ofs << "  \"BadUartStoreTagbufAValid\": " << (summary.bad_uart_store_tagbuf_a_valid ? "true" : "false") << ",\n";
    ofs << "  \"BadUartStoreTagbufBValid\": " << (summary.bad_uart_store_tagbuf_b_valid ? "true" : "false") << ",\n";
    ofs << "  \"BadUartStoreTagbufAData\": " << summary.bad_uart_store_tagbuf_a_data << ",\n";
    ofs << "  \"BadUartStoreTagbufBData\": " << summary.bad_uart_store_tagbuf_b_data << ",\n";
    ofs << "  \"BadUartStoreFwdA\": " << summary.bad_uart_store_fwd_a << ",\n";
    ofs << "  \"BadUartStoreFwdB\": " << summary.bad_uart_store_fwd_b << ",\n";
    ofs << "  \"BadUartStoreFunc3\": " << summary.bad_uart_store_func3 << ",\n";
    ofs << "  \"BadUartStoreTid\": " << summary.bad_uart_store_tid << ",\n";
    ofs << "  \"StrcpyMvSeen\": " << (summary.strcpy_mv_seen ? "true" : "false") << ",\n";
    ofs << "  \"StrcpyMvCycle\": " << summary.strcpy_mv_cycle << ",\n";
    ofs << "  \"StrcpyMvPc\": " << summary.strcpy_mv_pc << ",\n";
    ofs << "  \"StrcpyMvOpA\": " << summary.strcpy_mv_op_a << ",\n";
    ofs << "  \"StrcpyMvOpB\": " << summary.strcpy_mv_op_b << ",\n";
    ofs << "  \"StrcpyMvOrderId\": " << summary.strcpy_mv_order_id << ",\n";
    ofs << "  \"StrcpyMvTag\": " << summary.strcpy_mv_tag << ",\n";
    ofs << "  \"StrcpyMvRd\": " << summary.strcpy_mv_rd << ",\n";
    ofs << "  \"StrcpyMvTid\": " << summary.strcpy_mv_tid << ",\n";
    ofs << "  \"StrcpyMvRs1\": " << summary.strcpy_mv_rs1 << ",\n";
    ofs << "  \"StrcpyMvRs2\": " << summary.strcpy_mv_rs2 << ",\n";
    ofs << "  \"StrcpyMvSrc1Tag\": " << summary.strcpy_mv_src1_tag << ",\n";
    ofs << "  \"StrcpyMvSrc2Tag\": " << summary.strcpy_mv_src2_tag << ",\n";
    ofs << "  \"StrcpyMvPrd\": " << summary.strcpy_mv_prd << ",\n";
    ofs << "  \"StrcpyMvPrs1\": " << summary.strcpy_mv_prs1 << ",\n";
    ofs << "  \"StrcpyMvPrs2\": " << summary.strcpy_mv_prs2 << ",\n";
    ofs << "  \"StrcpyMvPrfA\": " << summary.strcpy_mv_prf_a << ",\n";
    ofs << "  \"StrcpyMvPrfB\": " << summary.strcpy_mv_prf_b << ",\n";
    ofs << "  \"StrcpyMvTagbufAValid\": " << (summary.strcpy_mv_tagbuf_a_valid ? "true" : "false") << ",\n";
    ofs << "  \"StrcpyMvTagbufBValid\": " << (summary.strcpy_mv_tagbuf_b_valid ? "true" : "false") << ",\n";
    ofs << "  \"StrcpyMvTagbufAData\": " << summary.strcpy_mv_tagbuf_a_data << ",\n";
    ofs << "  \"StrcpyMvTagbufBData\": " << summary.strcpy_mv_tagbuf_b_data << ",\n";
    ofs << "  \"StrcpyMvFwdA\": " << summary.strcpy_mv_fwd_a << ",\n";
    ofs << "  \"StrcpyMvFwdB\": " << summary.strcpy_mv_fwd_b << ",\n";
    ofs << "  \"StrcpyMvPrfW0En\": " << (summary.strcpy_mv_prf_w0_en ? "true" : "false") << ",\n";
    ofs << "  \"StrcpyMvPrfW0Addr\": " << summary.strcpy_mv_prf_w0_addr << ",\n";
    ofs << "  \"StrcpyMvPrfW0Data\": " << summary.strcpy_mv_prf_w0_data << ",\n";
    ofs << "  \"StrcpyMvPrfW1En\": " << (summary.strcpy_mv_prf_w1_en ? "true" : "false") << ",\n";
    ofs << "  \"StrcpyMvPrfW1Addr\": " << summary.strcpy_mv_prf_w1_addr << ",\n";
    ofs << "  \"StrcpyMvPrfW1Data\": " << summary.strcpy_mv_prf_w1_data << ",\n";
    ofs << "  \"MainLwA0Seen\": " << (summary.main_lw_a0_seen ? "true" : "false") << ",\n";
    ofs << "  \"MainLwA0Addr\": " << summary.main_lw_a0_addr << ",\n";
    ofs << "  \"MainLwA0OrderId\": " << summary.main_lw_a0_order_id << ",\n";
    ofs << "  \"MainLwA0Tag\": " << summary.main_lw_a0_tag << ",\n";
    ofs << "  \"MainLwA0Prd\": " << summary.main_lw_a0_prd << ",\n";
    ofs << "  \"MainLwA0Prs1\": " << summary.main_lw_a0_prs1 << ",\n";
    ofs << "  \"MainLwA0Base\": " << summary.main_lw_a0_base << ",\n";
    ofs << "  \"MainLwA0Imm\": " << summary.main_lw_a0_imm << ",\n";
    ofs << "  \"MainLwA0WbSeen\": " << (summary.main_lw_a0_wb_seen ? "true" : "false") << ",\n";
    ofs << "  \"MainLwA0WbData\": " << summary.main_lw_a0_wb_data << ",\n";
    ofs << "  \"MainLwA0WbPrd\": " << summary.main_lw_a0_wb_prd << ",\n";
    ofs << "  \"MainAddiA0Seen\": " << (summary.main_addi_a0_seen ? "true" : "false") << ",\n";
    ofs << "  \"MainAddiA0OpA\": " << summary.main_addi_a0_op_a << ",\n";
    ofs << "  \"MainAddiA0Result\": " << summary.main_addi_a0_result << ",\n";
    ofs << "  \"MainAddiA0OrderId\": " << summary.main_addi_a0_order_id << ",\n";
    ofs << "  \"MainAddiA0Tag\": " << summary.main_addi_a0_tag << ",\n";
    ofs << "  \"MainAddiA0Prd\": " << summary.main_addi_a0_prd << ",\n";
    ofs << "  \"MainAddiA0Prs1\": " << summary.main_addi_a0_prs1 << ",\n";
    ofs << "  \"MainAddiA0Src1Tag\": " << summary.main_addi_a0_src1_tag << ",\n";
    ofs << "  \"MainAddiA0PrfA\": " << summary.main_addi_a0_prf_a << ",\n";
    ofs << "  \"MainAddiA0TagbufAValid\": " << (summary.main_addi_a0_tagbuf_a_valid ? "true" : "false") << ",\n";
    ofs << "  \"MainAddiA0TagbufAData\": " << summary.main_addi_a0_tagbuf_a_data << ",\n";
    ofs << "  \"MainA0PrdWriteCount\": " << summary.main_a0_prd_write_count << ",\n";
    ofs << "  \"MainA0PrdLastWritePort\": " << summary.main_a0_prd_last_write_port << ",\n";
    ofs << "  \"MainA0PrdLastWriteData\": " << summary.main_a0_prd_last_write_data << ",\n";
    ofs << "  \"MainA0PrdLastWriteTag\": " << summary.main_a0_prd_last_write_tag << ",\n";
    ofs << "  \"MainA0PrdLastWriteRd\": " << summary.main_a0_prd_last_write_rd << ",\n";
    ofs << "  \"MainA0PrdLastWriteFu\": " << summary.main_a0_prd_last_write_fu << ",\n";
    ofs << "  \"MainA0PrdLastWritePc\": " << summary.main_a0_prd_last_write_pc << ",\n";
    ofs << "  \"MainA0PrdLastWriteOrderId\": " << summary.main_a0_prd_last_write_order_id << ",\n";
    ofs << "  \"MainA0PrdFirstBadWriteSeen\": " << (summary.main_a0_prd_first_bad_write_seen ? "true" : "false") << ",\n";
    ofs << "  \"MainA0PrdFirstBadWritePort\": " << summary.main_a0_prd_first_bad_write_port << ",\n";
    ofs << "  \"MainA0PrdFirstBadWriteData\": " << summary.main_a0_prd_first_bad_write_data << ",\n";
    ofs << "  \"MainA0PrdFirstBadWriteTag\": " << summary.main_a0_prd_first_bad_write_tag << ",\n";
    ofs << "  \"MainA0PrdFirstBadWriteRd\": " << summary.main_a0_prd_first_bad_write_rd << ",\n";
    ofs << "  \"MainA0PrdFirstBadWriteFu\": " << summary.main_a0_prd_first_bad_write_fu << ",\n";
    ofs << "  \"MainA0PrdFirstBadWritePc\": " << summary.main_a0_prd_first_bad_write_pc << ",\n";
    ofs << "  \"MainA0PrdFirstBadWriteOrderId\": " << summary.main_a0_prd_first_bad_write_order_id << ",\n";
    ofs << "  \"MainA0PrdFirstFreeSeen\": " << (summary.main_a0_prd_first_free_seen ? "true" : "false") << ",\n";
    ofs << "  \"MainA0PrdFirstFreePort\": " << summary.main_a0_prd_first_free_port << ",\n";
    ofs << "  \"MainA0PrdFirstFreeRd\": " << summary.main_a0_prd_first_free_rd << ",\n";
    ofs << "  \"MainA0PrdFirstFreeTag\": " << summary.main_a0_prd_first_free_tag << ",\n";
    ofs << "  \"MainA0PrdFirstFreeOrderId\": " << summary.main_a0_prd_first_free_order_id << ",\n";
    ofs << "  \"MainAddiA0WbSeen\": " << (summary.main_addi_a0_wb_seen ? "true" : "false") << ",\n";
    ofs << "  \"MainAddiA0WbCycle\": " << summary.main_addi_a0_wb_cycle << ",\n";
    ofs << "  \"MainAddiA0WbPort\": " << summary.main_addi_a0_wb_port << ",\n";
    ofs << "  \"MainAddiA0WbTid\": " << summary.main_addi_a0_wb_tid << ",\n";
    ofs << "  \"MainAddiA0WbPrd\": " << summary.main_addi_a0_wb_prd << ",\n";
    ofs << "  \"MainAddiA0WbData\": " << summary.main_addi_a0_wb_data << ",\n";
    ofs << "  \"MainAddiA0WbW0En\": " << (summary.main_addi_a0_wb_w0_en ? "true" : "false") << ",\n";
    ofs << "  \"MainAddiA0WbW0Addr\": " << summary.main_addi_a0_wb_w0_addr << ",\n";
    ofs << "  \"MainAddiA0WbW0Data\": " << summary.main_addi_a0_wb_w0_data << ",\n";
    ofs << "  \"MainAddiA0WbW1En\": " << (summary.main_addi_a0_wb_w1_en ? "true" : "false") << ",\n";
    ofs << "  \"MainAddiA0WbW1Addr\": " << summary.main_addi_a0_wb_w1_addr << ",\n";
    ofs << "  \"MainAddiA0WbW1Data\": " << summary.main_addi_a0_wb_w1_data << ",\n";
    ofs << "  \"MockMemReads\": " << summary.mock_mem_reads << ",\n";
    ofs << "  \"MockMemWrites\": " << summary.mock_mem_writes << ",\n";
    ofs << "  \"MockMemLastReadAddr\": " << summary.mock_mem_last_read_addr << ",\n";
    ofs << "  \"MockMemLastWriteAddr\": " << summary.mock_mem_last_write_addr << ",\n";
    ofs << "  \"MockMemLastWriteData\": " << summary.mock_mem_last_write_data << ",\n";
    ofs << "  \"MockMemRangeErrorCount\": " << summary.mock_mem_range_error_count << ",\n";
    ofs << "  \"MockMemLastRangeErrorAddr\": " << summary.mock_mem_last_range_error_addr << ",\n";
    ofs << "  \"MockMemUninitReadCount\": " << summary.mock_mem_uninit_read_count << ",\n";
    ofs << "  \"LsuReqSeenCount\": " << summary.lsu_req_seen_count << ",\n";
    ofs << "  \"LsuReqAcceptCount\": " << summary.lsu_req_accept_count << ",\n";
    ofs << "  \"LsuRespSeenCount\": " << summary.lsu_resp_seen_count << ",\n";
    ofs << "  \"LastLsuM1Cooldown\": " << (summary.last_lsu_m1_cooldown ? "true" : "false") << ",\n";
    ofs << "  \"LastLsuDrainHoldoff\": " << (summary.last_lsu_drain_holdoff ? "true" : "false") << ",\n";
    ofs << "  \"LastLsuSbDrainUrgent\": " << (summary.last_lsu_sb_drain_urgent ? "true" : "false") << ",\n";
    ofs << "  \"LastLsuSbHasPendingStores\": " << (summary.last_lsu_sb_has_pending_stores ? "true" : "false") << ",\n";
    ofs << "  \"LastLsuSbMemWriteValid\": " << (summary.last_lsu_sb_mem_write_valid ? "true" : "false") << ",\n";
    ofs << "  \"StoreBufferEmptyLast\": " << (summary.store_buffer_empty_last ? "true" : "false") << ",\n";
    ofs << "  \"StoreCountT0Last\": " << summary.store_count_t0_last << ",\n";
    ofs << "  \"StoreCountT1Last\": " << summary.store_count_t1_last << ",\n";
    ofs << "  \"M1ReqSeenCount\": " << summary.m1_req_seen_count << ",\n";
    ofs << "  \"M1ReqHandshakeCount\": " << summary.m1_req_handshake_count << ",\n";
    ofs << "  \"LastM1ReqAddr\": " << summary.last_m1_req_addr << ",\n";
    ofs << "  \"LastM1ReqWrite\": " << (summary.last_m1_req_write ? "true" : "false") << ",\n";
    ofs << "  \"LastInstretProgressCycle\": " << summary.last_instret_progress_cycle << ",\n";
    ofs << "  \"LastCommitProgressCycle\": " << summary.last_commit_progress_cycle << ",\n";
    ofs << "  \"LastLsuReqAcceptCycle\": " << summary.last_lsu_req_accept_cycle << ",\n";
    ofs << "  \"LastM1ReqHandshakeCycle\": " << summary.last_m1_req_handshake_cycle << ",\n";
    ofs << "  \"LoaderBytesInjected\": " << summary.loader_bytes_injected << ",\n";
    ofs << "  \"Ddr3ReqSeenCount\": " << summary.ddr3_req_seen_count << ",\n";
    ofs << "  \"Ddr3ReqHandshakeCount\": " << summary.ddr3_req_handshake_count << ",\n";
    ofs << "  \"Ddr3RespSeenCount\": " << summary.ddr3_resp_seen_count << ",\n";
    ofs << "  \"M0ReqSeenCount\": " << summary.m0_req_seen_count << ",\n";
    ofs << "  \"M0ReqHandshakeCount\": " << summary.m0_req_handshake_count << ",\n";
    ofs << "  \"M0RespSeenCount\": " << summary.m0_resp_seen_count << ",\n";
    ofs << "  \"LastM0ReqHandshakeCycle\": " << summary.last_m0_req_handshake_cycle << ",\n";
    ofs << "  \"LastM0RespCycle\": " << summary.last_m0_resp_cycle << ",\n";
    ofs << "  \"LastDdr3ReqAddr\": " << summary.last_ddr3_req_addr << ",\n";
    ofs << "  \"LastDdr3ReqWdata\": " << summary.last_ddr3_req_wdata << ",\n";
    ofs << "  \"LastDdr3RespData\": " << summary.last_ddr3_resp_data << ",\n";
    ofs << "  \"LastDdr3ReqWen\": " << summary.last_ddr3_req_wen << ",\n";
    ofs << "  \"LastDdr3ReqWrite\": " << (summary.last_ddr3_req_write ? "true" : "false") << ",\n";
    ofs << "  \"LastM0ReqAddr\": " << summary.last_m0_req_addr << ",\n";
    ofs << "  \"LastM0RespData\": " << summary.last_m0_resp_data << ",\n";
    ofs << "  \"LastM0RespLast\": " << (summary.last_m0_resp_last ? "true" : "false") << ",\n";
    ofs << "  \"MemsubsysM0Ddr3RespSeenCount\": " << summary.memsubsys_m0_ddr3_resp_seen_count << ",\n";
    ofs << "  \"LastMemsubsysM0Ddr3RespData\": " << summary.last_memsubsys_m0_ddr3_resp_data << ",\n";
    ofs << "  \"LastMemsubsysM0Ddr3RespLast\": " << (summary.last_memsubsys_m0_ddr3_resp_last ? "true" : "false") << ",\n";
    ofs << "  \"LastMemsubsysDdr3ArbState\": " << summary.last_memsubsys_ddr3_arb_state << ",\n";
    ofs << "  \"LastMemsubsysDdr3M0WordIdx\": " << summary.last_memsubsys_ddr3_m0_word_idx << ",\n";
    ofs << "  \"DCacheMissEventCount\": " << summary.dcache_miss_event_count << ",\n";
    ofs << "  \"LastDCacheMissEvent\": " << (summary.last_dcache_miss_event ? "true" : "false") << ",\n";
    ofs << "  \"StuckPcSeen\": " << (summary.stuck_pc_seen ? "true" : "false") << ",\n";
    ofs << "  \"StuckPcValue\": " << summary.stuck_pc_value << ",\n";
    ofs << "  \"StuckPcRepeatCount\": " << summary.stuck_pc_repeat_count << ",\n";
    ofs << "  \"RetireStallSeen\": " << (summary.retire_stall_seen ? "true" : "false") << ",\n";
    ofs << "  \"RetireStallCycles\": " << summary.retire_stall_cycles << ",\n";
    ofs << "  \"DangerWindowSeen\": " << (summary.danger_window_seen ? "true" : "false") << ",\n";
    ofs << "  \"DangerWindowEntryPc\": " << summary.danger_window_entry_pc << ",\n";
    ofs << "  \"DangerEntryCycle\": " << summary.danger_entry_cycle << ",\n";
    ofs << "  \"DangerEntryInstRet\": " << summary.danger_entry_instret << ",\n";
    ofs << "  \"DangerLsuReqSeenDelta\": " << summary.danger_lsu_req_seen_delta << ",\n";
    ofs << "  \"DangerLsuReqAcceptDelta\": " << summary.danger_lsu_req_accept_delta << ",\n";
    ofs << "  \"DangerLsuRespSeenDelta\": " << summary.danger_lsu_resp_seen_delta << ",\n";
    ofs << "  \"DangerM1ReqSeenDelta\": " << summary.danger_m1_req_seen_delta << ",\n";
    ofs << "  \"DangerM1ReqHandshakeDelta\": " << summary.danger_m1_req_handshake_delta << ",\n";
    ofs << "  \"DangerM0ReqSeenDelta\": " << summary.danger_m0_req_seen_delta << ",\n";
    ofs << "  \"DangerM0ReqHandshakeDelta\": " << summary.danger_m0_req_handshake_delta << ",\n";
    ofs << "  \"DangerM0RespSeenDelta\": " << summary.danger_m0_resp_seen_delta << ",\n";
    ofs << "  \"DangerMockMemWritesDelta\": " << summary.danger_mock_mem_writes_delta << ",\n";
    ofs << "  \"LastM1ReqAddrAfterDanger\": " << summary.last_m1_req_addr_after_danger << ",\n";
    ofs << "  \"LastM1ReqWriteAfterDanger\": " << (summary.last_m1_req_write_after_danger ? "true" : "false") << ",\n";
    ofs << "  \"LastM0ReqAddrAfterDanger\": " << summary.last_m0_req_addr_after_danger << "\n";
    ofs << "}\n";
}

bool parse_u32(const std::string& text, uint32_t& out) {
    try {
        size_t idx = 0;
        unsigned long value = std::stoul(text, &idx, 0);
        if (idx != text.size()) {
            return false;
        }
        out = static_cast<uint32_t>(value);
        return true;
    } catch (...) {
        return false;
    }
}

bool parse_u64(const std::string& text, uint64_t& out) {
    try {
        size_t idx = 0;
        unsigned long long value = std::stoull(text, &idx, 0);
        if (idx != text.size()) {
            return false;
        }
        out = static_cast<uint64_t>(value);
        return true;
    } catch (...) {
        return false;
    }
}

bool parse_args(int argc, char** argv, Config& cfg) {
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto require_value = [&](const std::string& name) -> const char* {
            if (i + 1 >= argc) {
                std::cerr << "Missing value for " << name << "\n";
                return nullptr;
            }
            return argv[++i];
        };

        if (arg == "--mode") {
            const char* value = require_value(arg);
            if (!value) return false;
            cfg.mode = value;
        } else if (!arg.empty() && arg[0] == '+') {
            continue;
        } else if (arg == "--payload-bin") {
            const char* value = require_value(arg);
            if (!value) return false;
            cfg.payload_bin = value;
        } else if (arg == "--summary-json") {
            const char* value = require_value(arg);
            if (!value) return false;
            cfg.summary_json = value;
        } else if (arg == "--uart-log") {
            const char* value = require_value(arg);
            if (!value) return false;
            cfg.uart_log = value;
        } else if (arg == "--entry-pc") {
            const char* value = require_value(arg);
            if (!value || !parse_u32(value, cfg.entry_pc)) return false;
        } else if (arg == "--payload-base") {
            const char* value = require_value(arg);
            if (!value || !parse_u32(value, cfg.payload_base)) return false;
        } else if (arg == "--max-cycles") {
            const char* value = require_value(arg);
            if (!value || !parse_u64(value, cfg.max_cycles)) return false;
        } else if (arg == "--header-gap-cycles") {
            const char* value = require_value(arg);
            if (!value || !parse_u32(value, cfg.header_gap_cycles)) return false;
        } else if (arg == "--payload-gap-cycles") {
            const char* value = require_value(arg);
            if (!value || !parse_u32(value, cfg.payload_gap_cycles)) return false;
        } else if (arg == "--stuck-pc-threshold") {
            const char* value = require_value(arg);
            if (!value || !parse_u64(value, cfg.stuck_pc_threshold)) return false;
        } else if (arg == "--stall-cycle-threshold") {
            const char* value = require_value(arg);
            if (!value || !parse_u64(value, cfg.stall_cycle_threshold)) return false;
        } else if (arg == "--danger-window-instret-threshold") {
            const char* value = require_value(arg);
            if (!value || !parse_u64(value, cfg.danger_window_instret_threshold)) return false;
        } else if (arg == "--danger-window-start") {
            const char* value = require_value(arg);
            if (!value || !parse_u32(value, cfg.danger_window_start)) return false;
        } else if (arg == "--danger-window-end") {
            const char* value = require_value(arg);
            if (!value || !parse_u32(value, cfg.danger_window_end)) return false;
        } else if (arg == "--trace") {
            cfg.trace = true;
        } else if (arg == "--trace-on-stuck") {
            cfg.trace = true;
            cfg.trace_on_stuck = true;
        } else if (arg == "--trace-start-cycle") {
            const char* value = require_value(arg);
            if (!value || !parse_u64(value, cfg.trace_start_cycle)) return false;
        } else if (arg == "--trace-stop-cycle") {
            const char* value = require_value(arg);
            if (!value || !parse_u64(value, cfg.trace_stop_cycle)) return false;
        } else if (arg == "--trace-after-stuck-cycles") {
            const char* value = require_value(arg);
            if (!value || !parse_u64(value, cfg.trace_after_stuck_cycles)) return false;
        } else if (arg == "--trace-file") {
            const char* value = require_value(arg);
            if (!value) return false;
            cfg.trace_file = value;
        } else {
            std::cerr << "Unknown argument: " << arg << "\n";
            return false;
        }
    }
    return !cfg.summary_json.empty();
}

std::vector<uint8_t> read_binary_file(const std::string& path) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) {
        throw std::runtime_error("failed to open payload bin: " + path);
    }
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(ifs), std::istreambuf_iterator<char>());
}

void push_u32_le(std::vector<uint8_t>& bytes, uint32_t value) {
    bytes.push_back(static_cast<uint8_t>(value & 0xFFu));
    bytes.push_back(static_cast<uint8_t>((value >> 8) & 0xFFu));
    bytes.push_back(static_cast<uint8_t>((value >> 16) & 0xFFu));
    bytes.push_back(static_cast<uint8_t>((value >> 24) & 0xFFu));
}

struct LoaderHost {
    enum class Phase {
        Idle,
        Header,
        PayloadChunk,
        WaitChunkAck,
        BlockChecksum,
        WaitChecksumAck,
        WaitBlockReply,
        Done
    };

    explicit LoaderHost(const Config& cfg)
        : payload(read_binary_file(cfg.payload_bin)),
          payload_base(cfg.payload_base),
          entry_pc(cfg.entry_pc),
          header_gap_cycles(cfg.header_gap_cycles),
          payload_gap_cycles(cfg.payload_gap_cycles) {
        header.reserve(20);
        push_u32_le(header, 0x314B4D42u);
        push_u32_le(header, payload_base);
        push_u32_le(header, entry_pc);
        push_u32_le(header, static_cast<uint32_t>(payload.size()));
        uint32_t checksum = 0;
        for (uint8_t byte : payload) checksum += byte;
        push_u32_le(header, checksum);

        const size_t block_count = (payload.size() + 63u) / 64u;
        block_checksums.resize(block_count, 0);
        for (size_t block = 0; block < block_count; ++block) {
            const size_t start = block * 64u;
            const size_t end = std::min(start + 64u, payload.size());
            uint32_t sum = 0;
            for (size_t idx = start; idx < end; ++idx) sum += payload[idx];
            block_checksums[block] = sum;
        }
        block_count_total = block_count;
        phase = Phase::Header;
    }

    bool done() const { return phase == Phase::Done; }
    bool jump_ready() const { return phase == Phase::Done; }
    uint64_t bytes_injected() const { return bytes_sent_total; }

    void observe_tx_byte(uint8_t byte) {
        if (phase == Phase::WaitChunkAck && byte == 0x06u) {
            phase = Phase::PayloadChunk;
            gap_countdown = payload_gap_cycles;
        } else if (phase == Phase::WaitChecksumAck && byte == 0x06u) {
            phase = Phase::WaitBlockReply;
        } else if (phase == Phase::WaitBlockReply && byte == 0x17u) {
            ++current_block;
            block_start = current_block * 64u;
            payload_idx = block_start;
            checksum_idx = 0;
            phase = (current_block >= block_count_total) ? Phase::Done : Phase::PayloadChunk;
            gap_countdown = payload_gap_cycles;
        } else if (phase == Phase::WaitBlockReply && byte == 0x15u) {
            payload_idx = block_start;
            chunk_bytes_sent = 0;
            checksum_idx = 0;
            phase = Phase::PayloadChunk;
            gap_countdown = payload_gap_cycles;
        }
    }

    void drive(bool& byte_valid, uint8_t& byte_data) {
        byte_valid = false;
        byte_data = 0;

        if (gap_countdown != 0) {
            --gap_countdown;
            return;
        }

        switch (phase) {
        case Phase::Idle:
        case Phase::WaitChunkAck:
        case Phase::WaitChecksumAck:
        case Phase::WaitBlockReply:
        case Phase::Done:
            return;

        case Phase::Header:
            if (header_idx < header.size()) {
                byte_valid = true;
                byte_data = header[header_idx++];
                ++bytes_sent_total;
                gap_countdown = header_gap_cycles;
            }
            if (header_idx >= header.size()) {
                phase = Phase::PayloadChunk;
                block_start = 0;
                payload_idx = 0;
                chunk_bytes_sent = 0;
                gap_countdown = payload_gap_cycles;
            }
            return;

        case Phase::PayloadChunk: {
            if (current_block >= block_count_total) {
                phase = Phase::Done;
                return;
            }
            const size_t block_end = std::min(block_start + 64u, payload.size());
            if (payload_idx >= block_end) {
                phase = Phase::BlockChecksum;
                checksum_idx = 0;
                gap_countdown = payload_gap_cycles;
                return;
            }

            byte_valid = true;
            byte_data = payload[payload_idx++];
            ++bytes_sent_total;
            ++chunk_bytes_sent;
            gap_countdown = payload_gap_cycles;

            if (chunk_bytes_sent == 4 || payload_idx >= block_end) {
                chunk_bytes_sent = 0;
                phase = Phase::WaitChunkAck;
            }
            return;
        }

        case Phase::BlockChecksum: {
            const uint32_t checksum = block_checksums[current_block];
            byte_valid = true;
            byte_data = static_cast<uint8_t>((checksum >> (checksum_idx * 8u)) & 0xFFu);
            ++bytes_sent_total;
            ++checksum_idx;
            gap_countdown = payload_gap_cycles;
            if (checksum_idx == 4u) {
                phase = Phase::WaitChecksumAck;
            }
            return;
        }
        }
    }

    std::vector<uint8_t> payload;
    std::vector<uint8_t> header;
    std::vector<uint32_t> block_checksums;
    uint32_t payload_base = 0;
    uint32_t entry_pc = 0;
    uint32_t header_gap_cycles = 16;
    uint32_t payload_gap_cycles = 2;
    Phase phase = Phase::Idle;
    size_t header_idx = 0;
    size_t payload_idx = 0;
    size_t block_start = 0;
    size_t current_block = 0;
    size_t block_count_total = 0;
    uint32_t checksum_idx = 0;
    uint32_t chunk_bytes_sent = 0;
    uint32_t gap_countdown = 0;
    uint64_t bytes_sent_total = 0;
};

std::string format_uart_byte(uint8_t byte) {
    if (byte == '\r') return "<CR>";
    if (byte == '\n') return "<LF>\n";
    if (byte >= 0x20 && byte <= 0x7e) return std::string(1, static_cast<char>(byte));
    std::ostringstream oss;
    oss << "<" << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(byte) << ">";
    return oss.str();
}

bool pc_in_window(uint32_t pc, uint32_t start, uint32_t end) {
    return pc >= start && pc <= end;
}

#if VM_TRACE_FST
using TraceDumper = VerilatedFstC;
#elif VM_TRACE
using TraceDumper = VerilatedVcdC;
#endif

void tick(Vverilator_mainline_top* top, uint64_t& cycles
#if VM_TRACE
    , TraceDumper* tracep, bool trace_active
#endif
) {
    top->sys_clk = 0;
    top->eval();
#if VM_TRACE
    if (tracep != nullptr && trace_active) {
        tracep->dump(static_cast<vluint64_t>(cycles * 2ULL));
    }
#endif
    top->sys_clk = 1;
    top->eval();
#if VM_TRACE
    if (tracep != nullptr && trace_active) {
        tracep->dump(static_cast<vluint64_t>(cycles * 2ULL + 1ULL));
    }
#endif
    ++cycles;
}

}  // namespace

int main(int argc, char** argv) {
    Config cfg;
    if (!parse_args(argc, argv, cfg)) {
        return 2;
    }

    Verilated::commandArgs(argc, argv);
    auto top = std::make_unique<Vverilator_mainline_top>();
#if VM_TRACE
    Verilated::traceEverOn(cfg.trace);
    std::unique_ptr<TraceDumper> trace;
    bool trace_open = false;
    bool trace_active = false;
    uint64_t effective_trace_stop_cycle = cfg.trace_stop_cycle;
    if (cfg.trace) {
        trace = std::make_unique<TraceDumper>();
        top->trace(trace.get(), 99);
    }
#endif

    std::ofstream uart_log;
    if (!cfg.uart_log.empty()) {
        uart_log.open(cfg.uart_log, std::ios::out | std::ios::trunc);
    }

    Summary summary;
    summary.mode = cfg.mode;

    std::unique_ptr<LoaderHost> loader_host;
    if (cfg.mode == "loader-semantic") {
        loader_host = std::make_unique<LoaderHost>(cfg);
    }

    std::string uart_ascii;
    uint64_t cycles = 0;
    uint64_t last_instret = 0;
    uint64_t stagnant_cycles = 0;
    uint32_t last_pc_t0 = 0;
    uint64_t same_pc_counter = 0;
    uint64_t small_window_counter = 0;
    bool prev_uart_tx_byte_valid = false;

    top->sys_rstn = 0;
    top->fast_uart_rx_byte_valid = 0;
    top->fast_uart_rx_byte = 0;
    top->sys_clk = 0;
    top->eval();

    for (int i = 0; i < 32; ++i) {
        tick(top.get(), cycles
#if VM_TRACE
            , trace.get(), trace_active
#endif
        );
    }

    top->sys_rstn = 1;

    while (cycles < cfg.max_cycles) {
#if VM_TRACE
        if (cfg.trace && !trace_open && !cfg.trace_on_stuck && cycles >= cfg.trace_start_cycle) {
            if (cfg.trace_file.empty()) {
#if VM_TRACE_FST
                cfg.trace_file = "trace.fst";
#else
                cfg.trace_file = "trace.vcd";
#endif
            }
            trace->open(cfg.trace_file.c_str());
            trace_open = true;
            trace_active = true;
        }
#endif

        bool inject_valid = false;
        uint8_t inject_byte = 0;
        if (loader_host) {
            loader_host->drive(inject_valid, inject_byte);
        }
        top->fast_uart_rx_byte_valid = inject_valid ? 1 : 0;
        top->fast_uart_rx_byte = inject_byte;

        tick(top.get(), cycles
#if VM_TRACE
            , trace.get(), trace_active
#endif
        );

        const bool uart_byte_fire = (top->debug_uart_tx_byte_valid != 0) && !prev_uart_tx_byte_valid;
        prev_uart_tx_byte_valid = top->debug_uart_tx_byte_valid != 0;
        if (uart_byte_fire) {
            const uint8_t byte = static_cast<uint8_t>(top->debug_uart_tx_byte);
            static const std::string kExpectedUartPrefix = "0\n1\n2\nDH\nDHRYSTONE START\r\n";
            const uint32_t uart_index = summary.uart_tx_byte_seen_count;
            if (!summary.unexpected_uart_seen &&
                uart_index < kExpectedUartPrefix.size() &&
                byte != static_cast<uint8_t>(kExpectedUartPrefix[uart_index])) {
                summary.unexpected_uart_seen = true;
                summary.unexpected_uart_cycle = cycles;
                summary.unexpected_uart_index = uart_index;
                summary.unexpected_uart_expected = static_cast<uint8_t>(kExpectedUartPrefix[uart_index]);
                summary.unexpected_uart_actual = byte;
                summary.unexpected_uart_pc_t0 = top->debug_pc_t0;
                summary.unexpected_uart_lsu_req_valid = top->debug_lsu_req_valid != 0;
                summary.unexpected_uart_lsu_req_accept = top->debug_lsu_req_accept != 0;
                summary.unexpected_uart_lsu_req_order_id = top->debug_lsu_req_order_id;
                summary.unexpected_uart_lsu_req_tag = top->debug_lsu_req_tag;
                summary.unexpected_uart_lsu_req_addr = top->debug_lsu_req_addr;
                summary.unexpected_uart_lsu_req_wdata = top->debug_lsu_req_wdata;
                summary.unexpected_uart_lsu_req_func3 = top->debug_lsu_req_func3;
                summary.unexpected_uart_lsu_req_wen = top->debug_lsu_req_wen != 0;
                summary.unexpected_uart_m1_req_valid = top->debug_m1_req_valid != 0;
                summary.unexpected_uart_m1_req_ready = top->debug_m1_req_ready != 0;
                summary.unexpected_uart_m1_req_addr = top->debug_m1_req_addr;
                summary.unexpected_uart_m1_req_wdata = top->debug_m1_req_wdata;
                summary.unexpected_uart_m1_req_wen = top->debug_m1_req_wen;
                summary.unexpected_uart_m1_req_write = top->debug_m1_req_write != 0;
                summary.unexpected_uart_wb0_valid = top->debug_wb0_valid != 0;
                summary.unexpected_uart_wb0_tag = top->debug_wb0_tag;
                summary.unexpected_uart_wb0_data = top->debug_wb0_data;
                summary.unexpected_uart_wb1_valid = top->debug_wb1_valid != 0;
                summary.unexpected_uart_wb1_tag = top->debug_wb1_tag;
                summary.unexpected_uart_wb1_fu = top->debug_wb1_fu;
                summary.unexpected_uart_wb1_data = top->debug_wb1_data;
            }
            ++summary.uart_tx_byte_seen_count;
            summary.last_uart_tx_byte = byte;
            uart_ascii.push_back(static_cast<char>(byte));
            if (uart_log.is_open()) {
                uart_log << format_uart_byte(byte);
            }
            if (loader_host) {
                loader_host->observe_tx_byte(byte);
            }
        }

        if (!summary.bad_uart_store_seen && top->debug_bad_uart_store_seen) {
            summary.bad_uart_store_seen = true;
            summary.bad_uart_store_cycle = cycles;
            summary.bad_uart_store_pc = top->debug_bad_uart_store_pc;
            summary.bad_uart_store_addr = top->debug_bad_uart_store_addr;
            summary.bad_uart_store_op_a = top->debug_bad_uart_store_op_a;
            summary.bad_uart_store_op_b = top->debug_bad_uart_store_op_b;
            summary.bad_uart_store_imm = top->debug_bad_uart_store_imm;
            summary.bad_uart_store_order_id = top->debug_bad_uart_store_order_id;
            summary.bad_uart_store_tag = top->debug_bad_uart_store_tag;
            summary.bad_uart_store_rd = top->debug_bad_uart_store_rd;
            summary.bad_uart_store_rs1 = top->debug_bad_uart_store_rs1;
            summary.bad_uart_store_rs2 = top->debug_bad_uart_store_rs2;
            summary.bad_uart_store_src1_tag = top->debug_bad_uart_store_src1_tag;
            summary.bad_uart_store_src2_tag = top->debug_bad_uart_store_src2_tag;
            summary.bad_uart_store_prs1 = top->debug_bad_uart_store_prs1;
            summary.bad_uart_store_prs2 = top->debug_bad_uart_store_prs2;
            summary.bad_uart_store_prf_a = top->debug_bad_uart_store_prf_a;
            summary.bad_uart_store_prf_b = top->debug_bad_uart_store_prf_b;
            summary.bad_uart_store_tagbuf_a_valid = top->debug_bad_uart_store_tagbuf_a_valid != 0;
            summary.bad_uart_store_tagbuf_b_valid = top->debug_bad_uart_store_tagbuf_b_valid != 0;
            summary.bad_uart_store_tagbuf_a_data = top->debug_bad_uart_store_tagbuf_a_data;
            summary.bad_uart_store_tagbuf_b_data = top->debug_bad_uart_store_tagbuf_b_data;
            summary.bad_uart_store_fwd_a = top->debug_bad_uart_store_fwd_a;
            summary.bad_uart_store_fwd_b = top->debug_bad_uart_store_fwd_b;
            summary.bad_uart_store_func3 = top->debug_bad_uart_store_func3;
            summary.bad_uart_store_tid = top->debug_bad_uart_store_tid;
        }

        if (!summary.strcpy_mv_seen && top->debug_strcpy_mv_seen) {
            summary.strcpy_mv_seen = true;
            summary.strcpy_mv_cycle = cycles;
            summary.strcpy_mv_pc = top->debug_strcpy_mv_pc;
            summary.strcpy_mv_op_a = top->debug_strcpy_mv_op_a;
            summary.strcpy_mv_op_b = top->debug_strcpy_mv_op_b;
            summary.strcpy_mv_order_id = top->debug_strcpy_mv_order_id;
            summary.strcpy_mv_tag = top->debug_strcpy_mv_tag;
            summary.strcpy_mv_rd = top->debug_strcpy_mv_rd;
            summary.strcpy_mv_tid = top->debug_strcpy_mv_tid;
            summary.strcpy_mv_rs1 = top->debug_strcpy_mv_rs1;
            summary.strcpy_mv_rs2 = top->debug_strcpy_mv_rs2;
            summary.strcpy_mv_src1_tag = top->debug_strcpy_mv_src1_tag;
            summary.strcpy_mv_src2_tag = top->debug_strcpy_mv_src2_tag;
            summary.strcpy_mv_prd = top->debug_strcpy_mv_prd;
            summary.strcpy_mv_prs1 = top->debug_strcpy_mv_prs1;
            summary.strcpy_mv_prs2 = top->debug_strcpy_mv_prs2;
            summary.strcpy_mv_prf_a = top->debug_strcpy_mv_prf_a;
            summary.strcpy_mv_prf_b = top->debug_strcpy_mv_prf_b;
            summary.strcpy_mv_tagbuf_a_valid = top->debug_strcpy_mv_tagbuf_a_valid != 0;
            summary.strcpy_mv_tagbuf_b_valid = top->debug_strcpy_mv_tagbuf_b_valid != 0;
            summary.strcpy_mv_tagbuf_a_data = top->debug_strcpy_mv_tagbuf_a_data;
            summary.strcpy_mv_tagbuf_b_data = top->debug_strcpy_mv_tagbuf_b_data;
            summary.strcpy_mv_fwd_a = top->debug_strcpy_mv_fwd_a;
            summary.strcpy_mv_fwd_b = top->debug_strcpy_mv_fwd_b;
            summary.strcpy_mv_prf_w0_en = top->debug_strcpy_mv_prf_w0_en != 0;
            summary.strcpy_mv_prf_w0_addr = top->debug_strcpy_mv_prf_w0_addr;
            summary.strcpy_mv_prf_w0_data = top->debug_strcpy_mv_prf_w0_data;
            summary.strcpy_mv_prf_w1_en = top->debug_strcpy_mv_prf_w1_en != 0;
            summary.strcpy_mv_prf_w1_addr = top->debug_strcpy_mv_prf_w1_addr;
            summary.strcpy_mv_prf_w1_data = top->debug_strcpy_mv_prf_w1_data;
        }

        summary.main_lw_a0_seen = top->debug_main_lw_a0_seen != 0;
        summary.main_lw_a0_addr = top->debug_main_lw_a0_addr;
        summary.main_lw_a0_order_id = top->debug_main_lw_a0_order_id;
        summary.main_lw_a0_tag = top->debug_main_lw_a0_tag;
        summary.main_lw_a0_prd = top->debug_main_lw_a0_prd;
        summary.main_lw_a0_prs1 = top->debug_main_lw_a0_prs1;
        summary.main_lw_a0_base = top->debug_main_lw_a0_base;
        summary.main_lw_a0_imm = top->debug_main_lw_a0_imm;
        summary.main_lw_a0_wb_seen = top->debug_main_lw_a0_wb_seen != 0;
        summary.main_lw_a0_wb_data = top->debug_main_lw_a0_wb_data;
        summary.main_lw_a0_wb_prd = top->debug_main_lw_a0_wb_prd;
        summary.main_addi_a0_seen = top->debug_main_addi_a0_seen != 0;
        summary.main_addi_a0_op_a = top->debug_main_addi_a0_op_a;
        summary.main_addi_a0_result = top->debug_main_addi_a0_result;
        summary.main_addi_a0_order_id = top->debug_main_addi_a0_order_id;
        summary.main_addi_a0_tag = top->debug_main_addi_a0_tag;
        summary.main_addi_a0_prd = top->debug_main_addi_a0_prd;
        summary.main_addi_a0_prs1 = top->debug_main_addi_a0_prs1;
        summary.main_addi_a0_src1_tag = top->debug_main_addi_a0_src1_tag;
        summary.main_addi_a0_prf_a = top->debug_main_addi_a0_prf_a;
        summary.main_addi_a0_tagbuf_a_valid = top->debug_main_addi_a0_tagbuf_a_valid != 0;
        summary.main_addi_a0_tagbuf_a_data = top->debug_main_addi_a0_tagbuf_a_data;
        summary.main_a0_prd_write_count = top->debug_main_a0_prd_write_count;
        summary.main_a0_prd_last_write_port = top->debug_main_a0_prd_last_write_port;
        summary.main_a0_prd_last_write_data = top->debug_main_a0_prd_last_write_data;
        summary.main_a0_prd_last_write_tag = top->debug_main_a0_prd_last_write_tag;
        summary.main_a0_prd_last_write_rd = top->debug_main_a0_prd_last_write_rd;
        summary.main_a0_prd_last_write_fu = top->debug_main_a0_prd_last_write_fu;
        summary.main_a0_prd_last_write_pc = top->debug_main_a0_prd_last_write_pc;
        summary.main_a0_prd_last_write_order_id = top->debug_main_a0_prd_last_write_order_id;
        summary.main_a0_prd_first_bad_write_seen = top->debug_main_a0_prd_first_bad_write_seen != 0;
        summary.main_a0_prd_first_bad_write_port = top->debug_main_a0_prd_first_bad_write_port;
        summary.main_a0_prd_first_bad_write_data = top->debug_main_a0_prd_first_bad_write_data;
        summary.main_a0_prd_first_bad_write_tag = top->debug_main_a0_prd_first_bad_write_tag;
        summary.main_a0_prd_first_bad_write_rd = top->debug_main_a0_prd_first_bad_write_rd;
        summary.main_a0_prd_first_bad_write_fu = top->debug_main_a0_prd_first_bad_write_fu;
        summary.main_a0_prd_first_bad_write_pc = top->debug_main_a0_prd_first_bad_write_pc;
        summary.main_a0_prd_first_bad_write_order_id = top->debug_main_a0_prd_first_bad_write_order_id;
        summary.main_a0_prd_first_free_seen = top->debug_main_a0_prd_first_free_seen != 0;
        summary.main_a0_prd_first_free_port = top->debug_main_a0_prd_first_free_port;
        summary.main_a0_prd_first_free_rd = top->debug_main_a0_prd_first_free_rd;
        summary.main_a0_prd_first_free_tag = top->debug_main_a0_prd_first_free_tag;
        summary.main_a0_prd_first_free_order_id = top->debug_main_a0_prd_first_free_order_id;
        const bool main_addi_a0_wb_now = top->debug_main_addi_a0_wb_seen != 0;
        if (main_addi_a0_wb_now && !summary.main_addi_a0_wb_seen) {
            summary.main_addi_a0_wb_cycle = cycles;
        }
        summary.main_addi_a0_wb_seen = main_addi_a0_wb_now;
        summary.main_addi_a0_wb_port = top->debug_main_addi_a0_wb_port;
        summary.main_addi_a0_wb_tid = top->debug_main_addi_a0_wb_tid;
        summary.main_addi_a0_wb_prd = top->debug_main_addi_a0_wb_prd;
        summary.main_addi_a0_wb_data = top->debug_main_addi_a0_wb_data;
        summary.main_addi_a0_wb_w0_en = top->debug_main_addi_a0_wb_w0_en != 0;
        summary.main_addi_a0_wb_w0_addr = top->debug_main_addi_a0_wb_w0_addr;
        summary.main_addi_a0_wb_w0_data = top->debug_main_addi_a0_wb_w0_data;
        summary.main_addi_a0_wb_w1_en = top->debug_main_addi_a0_wb_w1_en != 0;
        summary.main_addi_a0_wb_w1_addr = top->debug_main_addi_a0_wb_w1_addr;
        summary.main_addi_a0_wb_w1_data = top->debug_main_addi_a0_wb_w1_data;

        summary.last_pc_t0 = top->debug_pc_t0;
        summary.last_pc_t1 = top->debug_pc_t1;
        summary.last_fetch_pc_pending = top->debug_fetch_pc_pending;
        summary.last_fetch_pc_out = top->debug_fetch_pc_out;
        summary.last_fetch_if_inst = top->debug_fetch_if_inst;
        summary.last_fetch_if_flags = top->debug_fetch_if_flags;
        summary.last_ic_state_flags = top->debug_ic_state_flags;
        summary.ic_high_miss_count = top->debug_ic_high_miss_count;
        summary.ic_mem_req_count = top->debug_ic_mem_req_count;
        summary.ic_mem_resp_count = top->debug_ic_mem_resp_count;
        summary.ic_cpu_resp_count = top->debug_ic_cpu_resp_count;
        summary.instr_retired_count = top->debug_instr_retired_count;
        if (top->debug_rob_commit0_valid) {
            ++summary.rob_commit0_seen_count;
            summary.last_rob_commit0_order_id = top->debug_rob_commit0_order_id;
            summary.last_commit_progress_cycle = cycles;
        }
        if (top->debug_rob_commit1_valid) {
            ++summary.rob_commit1_seen_count;
            summary.last_rob_commit1_order_id = top->debug_rob_commit1_order_id;
            summary.last_commit_progress_cycle = cycles;
        }
        summary.last_rob_count_t0 = top->debug_rob_count_t0;
        summary.last_rob_count_t1 = top->debug_rob_count_t1;
        summary.last_rob_head_flushed_t0 = top->debug_rob_head_flushed_t0 != 0;
        summary.last_rob_head_flushed_t1 = top->debug_rob_head_flushed_t1 != 0;
        summary.last_rob_recovering = top->debug_rob_recovering != 0;
        summary.last_rob_recover_tid = top->debug_rob_recover_tid;
        summary.last_rob_recover_ptr = top->debug_rob_recover_ptr;
        if (top->debug_mem_iss_valid) {
            ++summary.mem_iss_seen_count;
        }
        if (top->debug_p1_winner_valid) {
            ++summary.p1_winner_count;
            if (top->debug_p1_winner == 2) {
                ++summary.p1_mem_winner_count;
            }
        }
        if (top->debug_wb1_valid && (top->debug_wb1_fu == 6 || top->debug_wb1_fu == 7)) {
            ++summary.wb1_mem_count;
        }
        summary.last_p1_winner_valid = top->debug_p1_winner_valid != 0;
        summary.last_p1_winner = top->debug_p1_winner;
        summary.last_mem_fu_busy = top->debug_mem_fu_busy != 0;
        summary.last_mem_fu_order_id = top->debug_mem_fu_order_id;
        summary.last_mem_fu_tid = top->debug_mem_fu_tid;
        summary.last_mem_issue_inhibit = top->debug_mem_issue_inhibit != 0;
        summary.last_p1_mem_cand_valid = top->debug_p1_mem_cand_valid != 0;
        summary.last_p1_mem_cand_order_id = top->debug_p1_mem_cand_order_id;
        summary.last_p1_mem_cand_tag = top->debug_p1_mem_cand_tag;
        summary.last_p1_mem_cand_read = top->debug_p1_mem_cand_mem_read != 0;
        summary.last_p1_mem_cand_write = top->debug_p1_mem_cand_mem_write != 0;
        summary.last_mem_cand_raw_valid = top->debug_mem_cand_raw_valid != 0;
        summary.last_mem_cand_clear = top->debug_mem_cand_clear != 0;
        summary.last_mem_cand_set = top->debug_mem_cand_set != 0;
        summary.last_iq_mem_sel_found = top->debug_iq_mem_sel_found != 0;
        summary.last_iq_mem_sel_idx = top->debug_iq_mem_sel_idx;
        summary.last_iq_mem_oldest_store_valid_t0 = top->debug_iq_mem_oldest_store_valid_t0 != 0;
        summary.last_iq_mem_oldest_store_valid_t1 = top->debug_iq_mem_oldest_store_valid_t1 != 0;
        summary.last_iq_mem_oldest_store_order_id_t0 = top->debug_iq_mem_oldest_store_order_id_t0;
        summary.last_iq_mem_oldest_store_order_id_t1 = top->debug_iq_mem_oldest_store_order_id_t1;
        summary.last_iq_mem_store_count_t0 = top->debug_iq_mem_store_count_t0;
        summary.last_iq_mem_store_count_t1 = top->debug_iq_mem_store_count_t1;
        summary.last_flush = top->debug_flush != 0;
        summary.last_flush_tid = top->debug_flush_tid;
        summary.last_flush_order_valid = top->debug_flush_order_valid != 0;
        summary.last_flush_order_id = top->debug_flush_order_id;
        summary.last_wb0_valid = top->debug_wb0_valid != 0;
        summary.last_wb0_tag = top->debug_wb0_tag;
        summary.last_wb0_regs_write = top->debug_wb0_regs_write != 0;
        summary.last_wb1_valid = top->debug_wb1_valid != 0;
        summary.last_wb1_tag = top->debug_wb1_tag;
        summary.last_wb1_regs_write = top->debug_wb1_regs_write != 0;
        summary.last_wb1_fu = top->debug_wb1_fu;
        summary.uart_status_load_count = top->debug_uart_status_load_count;
        summary.uart_tx_store_count = top->debug_uart_tx_store_count;
        summary.cycles = static_cast<uint64_t>(top->debug_mcycle);
        summary.instret = static_cast<uint64_t>(top->debug_minstret);
        summary.mock_mem_reads = top->mock_mem_read_count;
        summary.mock_mem_writes = top->mock_mem_write_count;
        summary.mock_mem_last_read_addr = top->mock_mem_last_read_addr;
        summary.mock_mem_last_write_addr = top->mock_mem_last_write_addr;
        summary.mock_mem_last_write_data = top->mock_mem_last_write_data;
        summary.mock_mem_range_error_count = top->mock_mem_range_error_count;
        summary.mock_mem_last_range_error_addr = top->mock_mem_last_range_error_addr;
        summary.mock_mem_uninit_read_count = top->mock_mem_uninit_read_count;
        if (top->debug_lsu_req_valid) {
            ++summary.lsu_req_seen_count;
        }
        if (top->debug_lsu_req_valid && top->debug_lsu_req_accept) {
            ++summary.lsu_req_accept_count;
            summary.last_lsu_req_accept_cycle = cycles;
        }
        if (top->debug_lsu_resp_valid) {
            ++summary.lsu_resp_seen_count;
        }
        summary.last_lsu_m1_cooldown = top->debug_lsu_m1_cooldown != 0;
        summary.last_lsu_drain_holdoff = top->debug_lsu_drain_holdoff != 0;
        summary.last_lsu_sb_drain_urgent = top->debug_lsu_sb_drain_urgent != 0;
        summary.last_lsu_sb_has_pending_stores = top->debug_lsu_sb_has_pending_stores != 0;
        summary.last_lsu_sb_mem_write_valid = top->debug_lsu_sb_mem_write_valid != 0;
        summary.store_buffer_empty_last = top->debug_store_buffer_empty != 0;
        summary.store_count_t0_last = top->debug_store_buffer_count_t0;
        summary.store_count_t1_last = top->debug_store_buffer_count_t1;
        if (top->debug_m1_req_valid) {
            ++summary.m1_req_seen_count;
            summary.last_m1_req_addr = top->debug_m1_req_addr;
            summary.last_m1_req_write = top->debug_m1_req_write != 0;
        }
        if (top->debug_m1_req_valid && top->debug_m1_req_ready) {
            ++summary.m1_req_handshake_count;
            summary.last_m1_req_handshake_cycle = cycles;
        }
        if (top->debug_ddr3_req_valid) {
            ++summary.ddr3_req_seen_count;
            summary.last_ddr3_req_addr = top->debug_ddr3_req_addr;
            summary.last_ddr3_req_wdata = top->debug_ddr3_req_wdata;
            summary.last_ddr3_req_wen = top->debug_ddr3_req_wen;
            summary.last_ddr3_req_write = top->debug_ddr3_req_write != 0;
        }
        if (top->debug_ddr3_req_valid && top->debug_ddr3_req_ready) {
            ++summary.ddr3_req_handshake_count;
        }
        if (top->debug_ddr3_resp_valid) {
            ++summary.ddr3_resp_seen_count;
            summary.last_ddr3_resp_data = top->debug_ddr3_resp_data;
        }
        if (top->debug_m0_req_valid) {
            ++summary.m0_req_seen_count;
            summary.last_m0_req_addr = top->debug_m0_req_addr;
        }
        if (top->debug_m0_req_valid && top->debug_m0_req_ready) {
            ++summary.m0_req_handshake_count;
            summary.last_m0_req_handshake_cycle = cycles;
        }
        if (top->debug_m0_resp_valid) {
            ++summary.m0_resp_seen_count;
            summary.last_m0_resp_data = top->debug_m0_resp_data;
            summary.last_m0_resp_last = top->debug_m0_resp_last != 0;
            summary.last_m0_resp_cycle = cycles;
        }
        if (top->debug_memsubsys_m0_ddr3_resp_valid) {
            ++summary.memsubsys_m0_ddr3_resp_seen_count;
            summary.last_memsubsys_m0_ddr3_resp_data = top->debug_memsubsys_m0_ddr3_resp_data;
            summary.last_memsubsys_m0_ddr3_resp_last = top->debug_memsubsys_m0_ddr3_resp_last != 0;
        }
        summary.last_memsubsys_ddr3_arb_state = top->debug_memsubsys_ddr3_arb_state;
        summary.last_memsubsys_ddr3_m0_word_idx = top->debug_memsubsys_ddr3_m0_word_idx;
        if (top->debug_dcache_miss_event) {
            ++summary.dcache_miss_event_count;
        }
        summary.last_dcache_miss_event = top->debug_dcache_miss_event != 0;

        if (!summary.entry_reached && top->debug_pc_t0 >= cfg.entry_pc) {
            summary.entry_reached = true;
        }
        if (!summary.benchmark_start_seen && uart_ascii.find("DHRYSTONE START") != std::string::npos) {
            summary.benchmark_start_seen = true;
        }
        if (!summary.benchmark_done_seen && uart_ascii.find("DHRYSTONE DONE") != std::string::npos) {
            summary.benchmark_done_seen = true;
        }
        if (!summary.trap_seen && top->debug_trap_seen) {
            summary.trap_seen = true;
            summary.trap_cause = top->debug_trap_cause;
        }

        const bool progress_armed = summary.entry_reached && summary.instret > 1024ULL;

        if (!summary.danger_window_seen &&
            pc_in_window(summary.last_pc_t0, cfg.danger_window_start, cfg.danger_window_end)) {
            summary.danger_window_seen = true;
            summary.danger_window_entry_pc = summary.last_pc_t0;
            summary.danger_entry_cycle = cycles;
            summary.danger_entry_instret = summary.instret;
            summary.danger_entry_lsu_req_seen = summary.lsu_req_seen_count;
            summary.danger_entry_lsu_req_accept = summary.lsu_req_accept_count;
            summary.danger_entry_lsu_resp_seen = summary.lsu_resp_seen_count;
            summary.danger_entry_m1_req_seen = summary.m1_req_seen_count;
            summary.danger_entry_m1_req_handshake = summary.m1_req_handshake_count;
            summary.danger_entry_m0_req_seen = summary.m0_req_seen_count;
            summary.danger_entry_m0_req_handshake = summary.m0_req_handshake_count;
            summary.danger_entry_m0_resp_seen = summary.m0_resp_seen_count;
            summary.danger_entry_mock_mem_writes = summary.mock_mem_writes;
        }

        if (summary.danger_window_seen && top->debug_m1_req_valid) {
            summary.last_m1_req_addr_after_danger = top->debug_m1_req_addr;
            summary.last_m1_req_write_after_danger = top->debug_m1_req_write != 0;
        }
        if (summary.danger_window_seen && top->debug_m0_req_valid) {
            summary.last_m0_req_addr_after_danger = top->debug_m0_req_addr;
        }

        const bool retire_progress = (summary.instret != last_instret);
        const bool commit_progress =
            retire_progress ||
            top->debug_rob_commit0_valid ||
            top->debug_rob_commit1_valid;

        if (progress_armed && summary.last_pc_t0 == last_pc_t0 && !commit_progress) {
            ++same_pc_counter;
        } else {
            same_pc_counter = 0;
        }
        if (progress_armed &&
            pc_in_window(summary.last_pc_t0, cfg.danger_window_start, cfg.danger_window_end) &&
            !commit_progress) {
            ++small_window_counter;
        } else {
            small_window_counter = 0;
        }
        last_pc_t0 = summary.last_pc_t0;

        if (retire_progress) {
            last_instret = summary.instret;
            stagnant_cycles = 0;
            summary.last_instret_progress_cycle = cycles;
        } else {
            ++stagnant_cycles;
        }

        if (progress_armed && !summary.stuck_pc_seen &&
            small_window_counter >= cfg.stuck_pc_threshold &&
            (summary.instret - summary.danger_entry_instret) >= cfg.danger_window_instret_threshold) {
            summary.stuck_pc_seen = true;
            summary.stuck_pc_value = summary.last_pc_t0;
            summary.stuck_pc_repeat_count = small_window_counter;
            if (summary.exit_reason == "timeout") {
                summary.exit_reason = pc_in_window(summary.last_pc_t0, cfg.danger_window_start, cfg.danger_window_end)
                    ? "danger_window_spin"
                    : "stuck_pc";
            }
            std::cerr << "DETECTED_STUCK_PC pc=0x" << std::hex << std::setw(8) << std::setfill('0')
                      << summary.last_pc_t0 << std::dec
                      << " repeat=" << summary.stuck_pc_repeat_count << "\n";
#if VM_TRACE
            if (cfg.trace && cfg.trace_on_stuck && !trace_open) {
                if (cfg.trace_file.empty()) {
#if VM_TRACE_FST
                    cfg.trace_file = "trace.fst";
#else
                    cfg.trace_file = "trace.vcd";
#endif
                }
                trace->open(cfg.trace_file.c_str());
                trace_open = true;
                trace_active = true;
                effective_trace_stop_cycle = cycles + cfg.trace_after_stuck_cycles;
            }
#endif
        }

        if (progress_armed && !summary.retire_stall_seen && stagnant_cycles >= cfg.stall_cycle_threshold) {
            summary.retire_stall_seen = true;
            summary.retire_stall_cycles = stagnant_cycles;
            if (summary.exit_reason == "timeout") {
                summary.exit_reason = "retire_stall";
            }
            std::cerr << "DETECTED_RETIRE_STALL cycles=" << stagnant_cycles
                      << " pc=0x" << std::hex << std::setw(8) << std::setfill('0')
                      << summary.last_pc_t0 << std::dec << "\n";
#if VM_TRACE
            if (cfg.trace && cfg.trace_on_stuck && !trace_open) {
                if (cfg.trace_file.empty()) {
#if VM_TRACE_FST
                    cfg.trace_file = "trace.fst";
#else
                    cfg.trace_file = "trace.vcd";
#endif
                }
                trace->open(cfg.trace_file.c_str());
                trace_open = true;
                trace_active = true;
                effective_trace_stop_cycle = cycles + cfg.trace_after_stuck_cycles;
            }
#endif
        }

        if (summary.benchmark_done_seen) {
            summary.exit_reason = "done";
            break;
        }
        if (summary.trap_seen) {
            summary.exit_reason = "trap";
            break;
        }
#if VM_TRACE
        if (trace_active && effective_trace_stop_cycle != 0ULL && cycles >= effective_trace_stop_cycle) {
            break;
        }
#endif
        if ((summary.stuck_pc_seen || summary.retire_stall_seen) && !cfg.trace_on_stuck) {
            break;
        }
    }

    if (loader_host) {
        summary.loader_bytes_injected = loader_host->bytes_injected();
        summary.loader_semantic_pass = summary.entry_reached;
    }

    if (summary.danger_window_seen) {
        summary.danger_lsu_req_seen_delta = summary.lsu_req_seen_count - summary.danger_entry_lsu_req_seen;
        summary.danger_lsu_req_accept_delta = summary.lsu_req_accept_count - summary.danger_entry_lsu_req_accept;
        summary.danger_lsu_resp_seen_delta = summary.lsu_resp_seen_count - summary.danger_entry_lsu_resp_seen;
        summary.danger_m1_req_seen_delta = summary.m1_req_seen_count - summary.danger_entry_m1_req_seen;
        summary.danger_m1_req_handshake_delta = summary.m1_req_handshake_count - summary.danger_entry_m1_req_handshake;
        summary.danger_m0_req_seen_delta = summary.m0_req_seen_count - summary.danger_entry_m0_req_seen;
        summary.danger_m0_req_handshake_delta = summary.m0_req_handshake_count - summary.danger_entry_m0_req_handshake;
        summary.danger_m0_resp_seen_delta = summary.m0_resp_seen_count - summary.danger_entry_m0_resp_seen;
        summary.danger_mock_mem_writes_delta = summary.mock_mem_writes - summary.danger_entry_mock_mem_writes;
    }

    if (summary.cycles != 0) {
        summary.ipcx1000 = static_cast<uint32_t>((summary.instret * 1000ULL) / summary.cycles);
    }
    if (summary.exit_reason == "timeout" && summary.benchmark_done_seen) {
        summary.exit_reason = "done";
    }

#if VM_TRACE
    if (trace_open) {
        trace->flush();
        trace->close();
    }
#endif
    if (uart_log.is_open()) {
        uart_log << "\n";
    }
    write_summary_json(summary, cfg.summary_json);

    if (summary.exit_reason == "done") {
        return 0;
    }
    return 1;
}
