module uart_status_beacon (
    input  wire clk,
    input  wire rst_n,
    input  wire core_ready,
    input  wire retire_seen,
    input  wire tube_pass,
    input  wire core_uart_seen,
    input  wire core_uart_frame_seen,
    input  wire [7:0] core_uart_frame_count_rolling,
    input  wire [7:0] bridge_uart_frame_count_rolling,
    input  wire [7:0] debug_uart_status_load_count,
    input  wire [7:0] debug_uart_tx_store_count,
    input  wire [3:0] debug_uart_flags,
    input  wire [7:0] debug_last_iss0_pc_lo,
    input  wire [7:0] debug_last_iss1_pc_lo,
    input  wire       debug_branch_pending_any,
    input  wire       debug_br_found_t0,
    input  wire       debug_branch_in_flight_t0,
    input  wire       debug_oldest_br_ready_t0,
    input  wire       debug_oldest_br_just_woke_t0,
    input  wire [3:0] debug_oldest_br_qj_t0,
    input  wire [3:0] debug_oldest_br_qk_t0,
    input  wire [3:0] debug_slot1_flags,
    input  wire [7:0] debug_slot1_pc_lo,
    input  wire [3:0] debug_slot1_qj,
    input  wire [3:0] debug_slot1_qk,
    input  wire [3:0] debug_tag2_flags,
    input  wire [3:0] debug_reg_x12_tag_t0,
    input  wire [3:0] debug_slot1_issue_flags,
    input  wire [3:0] debug_sel0_idx,
    input  wire [3:0] debug_slot1_fu,
    input  wire [7:0] debug_branch_issue_count,
    input  wire [7:0] debug_branch_complete_count,
    output wire tx
);

    localparam integer UART_CLK_DIV = 1736;
    localparam integer LINE_DELAY_CYCLES = 20_000_000;

    localparam [2:0] S_IDLE           = 3'd0;
    localparam [2:0] S_ASSERT_START   = 3'd1;
    localparam [2:0] S_WAIT_BUSY_HIGH = 3'd2;
    localparam [2:0] S_WAIT_BUSY_LOW  = 3'd3;

    reg [2:0]  state;
    reg [5:0]  char_idx;
    reg [24:0] delay_cnt;
    reg [7:0]  tx_data;
    reg        tx_start;
    reg        ready_snapshot;
    reg        retire_snapshot;
    reg        tube_snapshot;
    reg        uart_snapshot;
    reg        uart_frame_snapshot;
    reg [7:0]  uart_frame_count_snapshot;
    reg [7:0]  bridge_frame_count_snapshot;
    reg [7:0]  uart_status_load_count_snapshot;
    reg [7:0]  uart_tx_store_count_snapshot;
    reg [3:0]  uart_flags_snapshot;
    reg [7:0]  last_iss0_pc_lo_snapshot;
    reg [7:0]  last_iss1_pc_lo_snapshot;
    reg        branch_pending_snapshot;
    reg        br_found_t0_snapshot;
    reg        branch_in_flight_t0_snapshot;
    reg        oldest_br_ready_t0_snapshot;
    reg        oldest_br_just_woke_t0_snapshot;
    reg [3:0]  oldest_br_qj_t0_snapshot;
    reg [3:0]  oldest_br_qk_t0_snapshot;
    reg [3:0]  slot1_flags_snapshot;
    reg [7:0]  slot1_pc_lo_snapshot;
    reg [3:0]  slot1_qj_snapshot;
    reg [3:0]  slot1_qk_snapshot;
    reg [3:0]  tag2_flags_snapshot;
    reg [3:0]  reg_x12_tag_t0_snapshot;
    reg [3:0]  slot1_issue_flags_snapshot;
    reg [3:0]  sel0_idx_snapshot;
    reg [3:0]  slot1_fu_snapshot;
    reg [7:0]  branch_issue_count_snapshot;
    reg [7:0]  branch_complete_count_snapshot;
    wire       uart_busy;

    function [7:0] hex_char;
        input [3:0] nibble;
        begin
            hex_char = (nibble < 4'd10) ? (8'h30 + nibble) : (8'h41 + nibble - 4'd10);
        end
    endfunction

    function [7:0] status_char;
        input [5:0] idx;
        input ready_bit;
        input retire_bit;
        input tube_bit;
        input uart_bit;
        input uart_frame_bit;
        input [7:0] uart_frame_count;
        input [7:0] bridge_frame_count;
        input [7:0] uart_status_load_count;
        input [7:0] uart_tx_store_count;
        input [3:0] uart_flags;
        input [7:0] last_iss0_pc_lo;
        input [7:0] last_iss1_pc_lo;
        input branch_pending;
        input br_found_t0;
        input branch_in_flight_t0;
        input oldest_br_ready_t0;
        input oldest_br_just_woke_t0;
        input [3:0] oldest_br_qj_t0;
        input [3:0] oldest_br_qk_t0;
        input [3:0] slot1_flags;
        input [7:0] slot1_pc_lo;
        input [3:0] slot1_qj;
        input [3:0] slot1_qk;
        input [3:0] tag2_flags;
        input [3:0] reg_x12_tag_t0;
        input [3:0] slot1_issue_flags;
        input [3:0] sel0_idx;
        input [3:0] slot1_fu;
        input [7:0] branch_issue_count;
        input [7:0] branch_complete_count;
        begin
            case (idx)
                6'd0: status_char = 8'h53;  // 'S'
                6'd1: status_char = ready_bit  ? 8'h31 : 8'h30;
                6'd2: status_char = retire_bit ? 8'h31 : 8'h30;
                6'd3: status_char = tube_bit   ? 8'h31 : 8'h30;
                6'd4: status_char = uart_bit   ? 8'h31 : 8'h30;
                6'd5: status_char = uart_frame_bit ? 8'h31 : 8'h30;
                6'd6: status_char = 8'h3A; // ':'
                6'd7: status_char = hex_char(uart_frame_count[7:4]);
                6'd8: status_char = hex_char(uart_frame_count[3:0]);
                6'd9: status_char = 8'h3A; // ':'
                6'd10: status_char = hex_char(bridge_frame_count[7:4]);
                6'd11: status_char = hex_char(bridge_frame_count[3:0]);
                6'd12: status_char = 8'h3A; // ':'
                6'd13: status_char = hex_char(uart_status_load_count[7:4]);
                6'd14: status_char = hex_char(uart_status_load_count[3:0]);
                6'd15: status_char = 8'h3A; // ':'
                6'd16: status_char = hex_char(uart_tx_store_count[7:4]);
                6'd17: status_char = hex_char(uart_tx_store_count[3:0]);
                6'd18: status_char = 8'h3A; // ':'
                6'd19: status_char = hex_char(uart_flags);
                6'd20: status_char = 8'h3A; // ':'
                6'd21: status_char = hex_char(last_iss0_pc_lo[7:4]);
                6'd22: status_char = hex_char(last_iss0_pc_lo[3:0]);
                6'd23: status_char = 8'h3A; // ':'
                6'd24: status_char = hex_char(last_iss1_pc_lo[7:4]);
                6'd25: status_char = hex_char(last_iss1_pc_lo[3:0]);
                6'd26: status_char = 8'h3A; // ':'
                6'd27: status_char = branch_pending ? 8'h31 : 8'h30;
                6'd28: status_char = 8'h3A; // ':'
                6'd29: status_char = hex_char(branch_issue_count[7:4]);
                6'd30: status_char = hex_char(branch_issue_count[3:0]);
                6'd31: status_char = 8'h3A; // ':'
                6'd32: status_char = hex_char(branch_complete_count[7:4]);
                6'd33: status_char = hex_char(branch_complete_count[3:0]);
                6'd34: status_char = 8'h3A; // ':'
                6'd35: status_char = br_found_t0 ? 8'h31 : 8'h30;
                6'd36: status_char = branch_in_flight_t0 ? 8'h31 : 8'h30;
                6'd37: status_char = 8'h3A; // ':'
                6'd38: status_char = oldest_br_ready_t0 ? 8'h31 : 8'h30;
                6'd39: status_char = oldest_br_just_woke_t0 ? 8'h31 : 8'h30;
                6'd40: status_char = 8'h3A; // ':'
                6'd41: status_char = hex_char(oldest_br_qj_t0);
                6'd42: status_char = hex_char(oldest_br_qk_t0);
                6'd43: status_char = 8'h3A; // ':'
                6'd44: status_char = hex_char(slot1_flags);
                6'd45: status_char = 8'h3A; // ':'
                6'd46: status_char = hex_char(slot1_pc_lo[7:4]);
                6'd47: status_char = hex_char(slot1_pc_lo[3:0]);
                6'd48: status_char = 8'h3A; // ':'
                6'd49: status_char = hex_char(slot1_qj);
                6'd50: status_char = hex_char(slot1_qk);
                6'd51: status_char = 8'h3A; // ':'
                6'd52: status_char = hex_char(tag2_flags);
                6'd53: status_char = hex_char(reg_x12_tag_t0);
                6'd54: status_char = 8'h3A; // ':'
                6'd55: status_char = hex_char(slot1_issue_flags);
                6'd56: status_char = hex_char(sel0_idx);
                6'd57: status_char = 8'h3A; // ':'
                6'd58: status_char = hex_char(slot1_fu);
                6'd59: status_char = 8'h0D;
                6'd60: status_char = 8'h0A;
                default: status_char = 8'h3F; // '?'
            endcase
        end
    endfunction

    uart_tx #(
        .CLK_DIV(UART_CLK_DIV)
    ) u_uart_tx (
        .clk      (clk     ),
        .rst_n    (rst_n   ),
        .tx_start (tx_start),
        .tx_data  (tx_data ),
        .tx       (tx      ),
        .busy     (uart_busy)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            char_idx        <= 6'd0;
            delay_cnt       <= 25'd0;
            tx_data         <= 8'h00;
            tx_start        <= 1'b0;
            ready_snapshot  <= 1'b0;
            retire_snapshot <= 1'b0;
            tube_snapshot   <= 1'b0;
            uart_snapshot   <= 1'b0;
            uart_frame_snapshot <= 1'b0;
            uart_frame_count_snapshot <= 8'd0;
            bridge_frame_count_snapshot <= 8'd0;
            uart_status_load_count_snapshot <= 8'd0;
            uart_tx_store_count_snapshot <= 8'd0;
            uart_flags_snapshot <= 4'd0;
            last_iss0_pc_lo_snapshot <= 8'd0;
            last_iss1_pc_lo_snapshot <= 8'd0;
            branch_pending_snapshot <= 1'b0;
            br_found_t0_snapshot <= 1'b0;
            branch_in_flight_t0_snapshot <= 1'b0;
            oldest_br_ready_t0_snapshot <= 1'b0;
            oldest_br_just_woke_t0_snapshot <= 1'b0;
            oldest_br_qj_t0_snapshot <= 4'd0;
            oldest_br_qk_t0_snapshot <= 4'd0;
            slot1_flags_snapshot <= 4'd0;
            slot1_pc_lo_snapshot <= 8'd0;
            slot1_qj_snapshot <= 4'd0;
            slot1_qk_snapshot <= 4'd0;
            tag2_flags_snapshot <= 4'd0;
            reg_x12_tag_t0_snapshot <= 4'd0;
            slot1_issue_flags_snapshot <= 4'd0;
            sel0_idx_snapshot <= 4'd0;
            slot1_fu_snapshot <= 4'd0;
            branch_issue_count_snapshot <= 8'd0;
            branch_complete_count_snapshot <= 8'd0;
        end else begin
            tx_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (delay_cnt != 25'd0) begin
                        delay_cnt <= delay_cnt - 25'd1;
                    end else begin
                        ready_snapshot  <= core_ready;
                        retire_snapshot <= retire_seen;
                        tube_snapshot   <= tube_pass;
                        uart_snapshot   <= core_uart_seen;
                        uart_frame_snapshot <= core_uart_frame_seen;
                        uart_frame_count_snapshot <= core_uart_frame_count_rolling;
                        bridge_frame_count_snapshot <= bridge_uart_frame_count_rolling;
                        uart_status_load_count_snapshot <= debug_uart_status_load_count;
                        uart_tx_store_count_snapshot <= debug_uart_tx_store_count;
                        uart_flags_snapshot <= debug_uart_flags;
                        last_iss0_pc_lo_snapshot <= debug_last_iss0_pc_lo;
                        last_iss1_pc_lo_snapshot <= debug_last_iss1_pc_lo;
                        branch_pending_snapshot <= debug_branch_pending_any;
                        br_found_t0_snapshot <= debug_br_found_t0;
                        branch_in_flight_t0_snapshot <= debug_branch_in_flight_t0;
                        oldest_br_ready_t0_snapshot <= debug_oldest_br_ready_t0;
                        oldest_br_just_woke_t0_snapshot <= debug_oldest_br_just_woke_t0;
                        oldest_br_qj_t0_snapshot <= debug_oldest_br_qj_t0;
                        oldest_br_qk_t0_snapshot <= debug_oldest_br_qk_t0;
                        slot1_flags_snapshot <= debug_slot1_flags;
                        slot1_pc_lo_snapshot <= debug_slot1_pc_lo;
                        slot1_qj_snapshot <= debug_slot1_qj;
                        slot1_qk_snapshot <= debug_slot1_qk;
                        tag2_flags_snapshot <= debug_tag2_flags;
                        reg_x12_tag_t0_snapshot <= debug_reg_x12_tag_t0;
                        slot1_issue_flags_snapshot <= debug_slot1_issue_flags;
                        sel0_idx_snapshot <= debug_sel0_idx;
                        slot1_fu_snapshot <= debug_slot1_fu;
                        branch_issue_count_snapshot <= debug_branch_issue_count;
                        branch_complete_count_snapshot <= debug_branch_complete_count;
                        char_idx        <= 6'd0;
                        tx_data         <= status_char(6'd0, core_ready, retire_seen, tube_pass, core_uart_seen, core_uart_frame_seen, core_uart_frame_count_rolling, bridge_uart_frame_count_rolling, debug_uart_status_load_count, debug_uart_tx_store_count, debug_uart_flags, debug_last_iss0_pc_lo, debug_last_iss1_pc_lo, debug_branch_pending_any, debug_br_found_t0, debug_branch_in_flight_t0, debug_oldest_br_ready_t0, debug_oldest_br_just_woke_t0, debug_oldest_br_qj_t0, debug_oldest_br_qk_t0, debug_slot1_flags, debug_slot1_pc_lo, debug_slot1_qj, debug_slot1_qk, debug_tag2_flags, debug_reg_x12_tag_t0, debug_slot1_issue_flags, debug_sel0_idx, debug_slot1_fu, debug_branch_issue_count, debug_branch_complete_count);
                        tx_start        <= 1'b1;
                        state           <= S_WAIT_BUSY_HIGH;
                    end
                end

                S_WAIT_BUSY_HIGH: begin
                    if (uart_busy) begin
                        state <= S_WAIT_BUSY_LOW;
                    end
                end

                S_WAIT_BUSY_LOW: begin
                    if (!uart_busy) begin
                        if (char_idx == 6'd60) begin
                            delay_cnt <= LINE_DELAY_CYCLES - 1;
                            state     <= S_IDLE;
                        end else begin
                            char_idx <= char_idx + 6'd1;
                            tx_data  <= status_char(char_idx + 6'd1, ready_snapshot, retire_snapshot, tube_snapshot, uart_snapshot, uart_frame_snapshot, uart_frame_count_snapshot, bridge_frame_count_snapshot, uart_status_load_count_snapshot, uart_tx_store_count_snapshot, uart_flags_snapshot, last_iss0_pc_lo_snapshot, last_iss1_pc_lo_snapshot, branch_pending_snapshot, br_found_t0_snapshot, branch_in_flight_t0_snapshot, oldest_br_ready_t0_snapshot, oldest_br_just_woke_t0_snapshot, oldest_br_qj_t0_snapshot, oldest_br_qk_t0_snapshot, slot1_flags_snapshot, slot1_pc_lo_snapshot, slot1_qj_snapshot, slot1_qk_snapshot, tag2_flags_snapshot, reg_x12_tag_t0_snapshot, slot1_issue_flags_snapshot, sel0_idx_snapshot, slot1_fu_snapshot, branch_issue_count_snapshot, branch_complete_count_snapshot);
                            tx_start <= 1'b1;
                            state    <= S_WAIT_BUSY_HIGH;
                        end
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
