module uart_branch_probe_beacon (
    input  wire clk,
    input  wire rst_n,
    input  wire core_ready,
    input  wire retire_seen,
    input  wire tube_pass,
    input  wire [7:0] last_iss0_pc_lo,
    input  wire [7:0] last_iss1_pc_lo,
    input  wire       branch_pending,
    input  wire       br_found_t0,
    input  wire       branch_in_flight_t0,
    input  wire       oldest_br_ready_t0,
    input  wire       oldest_br_just_woke_t0,
    input  wire [3:0] oldest_br_qj_t0,
    input  wire [3:0] oldest_br_qk_t0,
    input  wire [7:0] uart_status_load_count,
    input  wire [7:0] uart_tx_store_count,
    input  wire [3:0] uart_flags,
    input  wire [3:0] tag2_flags,
    input  wire [3:0] reg_x12_tag_t0,
    output wire tx
);

    // The probe beacon runs in the core clock domain, which is 20 MHz in
    // FPGA_MODE after the internal clk_wiz divider.
    localparam integer UART_CLK_DIV = 174;
    // Insert a small idle gap between characters so the single-byte bridge
    // queue in the board wrapper can relay every byte without dropping frames.
    localparam integer INTER_CHAR_GAP_CYCLES = 348;
    localparam integer LINE_DELAY_CYCLES = 20_000_000;

    localparam [2:0] S_IDLE           = 3'd0;
    localparam [2:0] S_WAIT_BUSY_HIGH = 3'd1;
    localparam [2:0] S_WAIT_BUSY_LOW  = 3'd2;
    localparam [2:0] S_GAP            = 3'd3;

    reg [2:0] state;
    reg [5:0] char_idx;
    reg [24:0] delay_cnt;
    reg [7:0] tx_data;
    reg tx_start;
    reg core_ready_snapshot;
    reg retire_seen_snapshot;
    reg tube_pass_snapshot;
    reg [7:0] last_iss0_pc_lo_snapshot;
    reg [7:0] last_iss1_pc_lo_snapshot;
    reg branch_pending_snapshot;
    reg br_found_t0_snapshot;
    reg branch_in_flight_t0_snapshot;
    reg oldest_br_ready_t0_snapshot;
    reg oldest_br_just_woke_t0_snapshot;
    reg [3:0] oldest_br_qj_t0_snapshot;
    reg [3:0] oldest_br_qk_t0_snapshot;
    reg [7:0] uart_status_load_count_snapshot;
    reg [7:0] uart_tx_store_count_snapshot;
    reg [3:0] uart_flags_snapshot;
    reg [3:0] tag2_flags_snapshot;
    reg [3:0] reg_x12_tag_t0_snapshot;
    wire uart_busy;

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
        input [7:0] iss0_pc;
        input [7:0] iss1_pc;
        input pending_bit;
        input found_bit;
        input inflight_bit;
        input oldest_ready;
        input oldest_just_woke;
        input [3:0] br_qj;
        input [3:0] br_qk;
        input [7:0] uart_status_count;
        input [7:0] uart_store_count;
        input [3:0] uart_flags_i;
        input [3:0] tag2_i;
        input [3:0] x12_tag_i;
        begin
            case (idx)
                6'd0: status_char = 8'h42; // 'B'
                6'd1: status_char = ready_bit ? 8'h31 : 8'h30;
                6'd2: status_char = retire_bit ? 8'h31 : 8'h30;
                6'd3: status_char = tube_bit ? 8'h31 : 8'h30;
                6'd4: status_char = 8'h3A;
                6'd5: status_char = hex_char(iss0_pc[7:4]);
                6'd6: status_char = hex_char(iss0_pc[3:0]);
                6'd7: status_char = hex_char(iss1_pc[7:4]);
                6'd8: status_char = hex_char(iss1_pc[3:0]);
                6'd9: status_char = 8'h3A;
                6'd10: status_char = pending_bit ? 8'h31 : 8'h30;
                6'd11: status_char = found_bit ? 8'h31 : 8'h30;
                6'd12: status_char = inflight_bit ? 8'h31 : 8'h30;
                6'd13: status_char = oldest_ready ? 8'h31 : 8'h30;
                6'd14: status_char = oldest_just_woke ? 8'h31 : 8'h30;
                6'd15: status_char = 8'h3A;
                6'd16: status_char = hex_char(br_qj);
                6'd17: status_char = hex_char(br_qk);
                6'd18: status_char = 8'h3A;
                6'd19: status_char = hex_char(uart_status_count[7:4]);
                6'd20: status_char = hex_char(uart_status_count[3:0]);
                6'd21: status_char = hex_char(uart_store_count[7:4]);
                6'd22: status_char = hex_char(uart_store_count[3:0]);
                6'd23: status_char = hex_char(uart_flags_i);
                6'd24: status_char = 8'h3A;
                6'd25: status_char = hex_char(tag2_i);
                6'd26: status_char = hex_char(x12_tag_i);
                6'd27: status_char = 8'h0D;
                6'd28: status_char = 8'h0A;
                default: status_char = 8'h3F;
            endcase
        end
    endfunction

    uart_tx #(
        .CLK_DIV(UART_CLK_DIV)
    ) u_uart_tx (
        .clk(clk),
        .rst_n(rst_n),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx(tx),
        .busy(uart_busy)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            char_idx <= 6'd0;
            delay_cnt <= 25'd0;
            tx_data <= 8'h00;
            tx_start <= 1'b0;
            core_ready_snapshot <= 1'b0;
            retire_seen_snapshot <= 1'b0;
            tube_pass_snapshot <= 1'b0;
            last_iss0_pc_lo_snapshot <= 8'd0;
            last_iss1_pc_lo_snapshot <= 8'd0;
            branch_pending_snapshot <= 1'b0;
            br_found_t0_snapshot <= 1'b0;
            branch_in_flight_t0_snapshot <= 1'b0;
            oldest_br_ready_t0_snapshot <= 1'b0;
            oldest_br_just_woke_t0_snapshot <= 1'b0;
            oldest_br_qj_t0_snapshot <= 4'd0;
            oldest_br_qk_t0_snapshot <= 4'd0;
            uart_status_load_count_snapshot <= 8'd0;
            uart_tx_store_count_snapshot <= 8'd0;
            uart_flags_snapshot <= 4'd0;
            tag2_flags_snapshot <= 4'd0;
            reg_x12_tag_t0_snapshot <= 4'd0;
        end else begin
            tx_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (delay_cnt != 25'd0) begin
                        delay_cnt <= delay_cnt - 25'd1;
                    end else begin
                        core_ready_snapshot <= core_ready;
                        retire_seen_snapshot <= retire_seen;
                        tube_pass_snapshot <= tube_pass;
                        last_iss0_pc_lo_snapshot <= last_iss0_pc_lo;
                        last_iss1_pc_lo_snapshot <= last_iss1_pc_lo;
                        branch_pending_snapshot <= branch_pending;
                        br_found_t0_snapshot <= br_found_t0;
                        branch_in_flight_t0_snapshot <= branch_in_flight_t0;
                        oldest_br_ready_t0_snapshot <= oldest_br_ready_t0;
                        oldest_br_just_woke_t0_snapshot <= oldest_br_just_woke_t0;
                        oldest_br_qj_t0_snapshot <= oldest_br_qj_t0;
                        oldest_br_qk_t0_snapshot <= oldest_br_qk_t0;
                        uart_status_load_count_snapshot <= uart_status_load_count;
                        uart_tx_store_count_snapshot <= uart_tx_store_count;
                        uart_flags_snapshot <= uart_flags;
                        tag2_flags_snapshot <= tag2_flags;
                        reg_x12_tag_t0_snapshot <= reg_x12_tag_t0;
                        char_idx <= 6'd0;
                        tx_data <= status_char(
                            6'd0,
                            core_ready,
                            retire_seen,
                            tube_pass,
                            last_iss0_pc_lo,
                            last_iss1_pc_lo,
                            branch_pending,
                            br_found_t0,
                            branch_in_flight_t0,
                            oldest_br_ready_t0,
                            oldest_br_just_woke_t0,
                            oldest_br_qj_t0,
                            oldest_br_qk_t0,
                            uart_status_load_count,
                            uart_tx_store_count,
                            uart_flags,
                            tag2_flags,
                            reg_x12_tag_t0
                        );
                        tx_start <= 1'b1;
                        state <= S_WAIT_BUSY_HIGH;
                    end
                end

                S_WAIT_BUSY_HIGH: begin
                    if (uart_busy)
                        state <= S_WAIT_BUSY_LOW;
                end

                S_WAIT_BUSY_LOW: begin
                    if (!uart_busy) begin
                        if (char_idx == 6'd28) begin
                            delay_cnt <= LINE_DELAY_CYCLES;
                            state <= S_IDLE;
                        end else begin
                            delay_cnt <= INTER_CHAR_GAP_CYCLES - 1;
                            state <= S_GAP;
                        end
                    end
                end

                S_GAP: begin
                    if (delay_cnt != 25'd0) begin
                        delay_cnt <= delay_cnt - 25'd1;
                    end else begin
                        char_idx <= char_idx + 6'd1;
                        tx_data <= status_char(
                            char_idx + 6'd1,
                            core_ready_snapshot,
                            retire_seen_snapshot,
                            tube_pass_snapshot,
                            last_iss0_pc_lo_snapshot,
                            last_iss1_pc_lo_snapshot,
                            branch_pending_snapshot,
                            br_found_t0_snapshot,
                            branch_in_flight_t0_snapshot,
                            oldest_br_ready_t0_snapshot,
                            oldest_br_just_woke_t0_snapshot,
                            oldest_br_qj_t0_snapshot,
                            oldest_br_qk_t0_snapshot,
                            uart_status_load_count_snapshot,
                            uart_tx_store_count_snapshot,
                            uart_flags_snapshot,
                            tag2_flags_snapshot,
                            reg_x12_tag_t0_snapshot
                        );
                        tx_start <= 1'b1;
                        state <= S_WAIT_BUSY_HIGH;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
