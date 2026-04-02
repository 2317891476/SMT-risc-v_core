module uart_issue_probe_beacon (
    input  wire clk,
    input  wire rst_n,
    input  wire core_ready,
    input  wire retire_seen,
    input  wire tube_pass,
    input  wire [7:0] last_iss0_pc_lo,
    input  wire [7:0] last_iss1_pc_lo,
    input  wire branch_pending,
    input  wire br_found_t0,
    input  wire branch_in_flight_t0,
    input  wire [3:0] oldest_br_qj_t0,
    input  wire [7:0] oldest_br_seq_lo_t0,
    input  wire [15:0] rs_flags_flat,
    input  wire [31:0] rs_pc_lo_flat,
    input  wire [15:0] rs_fu_flat,
    input  wire [15:0] rs_qj_flat,
    input  wire [15:0] rs_qk_flat,
    input  wire [31:0] rs_seq_lo_flat,
    output wire tx
);

    localparam integer UART_CLK_DIV = 1736;
    localparam integer LINE_DELAY_CYCLES = 20_000_000;

    localparam [1:0] S_IDLE           = 2'd0;
    localparam [1:0] S_WAIT_BUSY_HIGH = 2'd1;
    localparam [1:0] S_WAIT_BUSY_LOW  = 2'd2;

    reg [1:0]  state;
    reg [6:0]  char_idx;
    reg [24:0] delay_cnt;
    reg [7:0]  tx_data;
    reg        tx_start;
    reg        core_ready_snapshot;
    reg        retire_seen_snapshot;
    reg        tube_pass_snapshot;
    reg [7:0]  last_iss0_pc_lo_snapshot;
    reg [7:0]  last_iss1_pc_lo_snapshot;
    reg        branch_pending_snapshot;
    reg        br_found_t0_snapshot;
    reg        branch_in_flight_t0_snapshot;
    reg [3:0]  oldest_br_qj_t0_snapshot;
    reg [7:0]  oldest_br_seq_lo_t0_snapshot;
    reg [15:0] rs_flags_flat_snapshot;
    reg [31:0] rs_pc_lo_flat_snapshot;
    reg [15:0] rs_fu_flat_snapshot;
    reg [15:0] rs_qj_flat_snapshot;
    reg [15:0] rs_qk_flat_snapshot;
    reg [31:0] rs_seq_lo_flat_snapshot;
    wire       uart_busy;

    function [7:0] hex_char;
        input [3:0] nibble;
        begin
            hex_char = (nibble < 4'd10) ? (8'h30 + nibble) : (8'h41 + nibble - 4'd10);
        end
    endfunction

    function [3:0] slot_nibble;
        input [15:0] flat_bus;
        input [1:0] slot_idx;
        begin
            case (slot_idx)
                2'd0: slot_nibble = flat_bus[3:0];
                2'd1: slot_nibble = flat_bus[7:4];
                2'd2: slot_nibble = flat_bus[11:8];
                default: slot_nibble = flat_bus[15:12];
            endcase
        end
    endfunction

    function [7:0] slot_byte;
        input [31:0] flat_bus;
        input [1:0] slot_idx;
        begin
            case (slot_idx)
                2'd0: slot_byte = flat_bus[7:0];
                2'd1: slot_byte = flat_bus[15:8];
                2'd2: slot_byte = flat_bus[23:16];
                default: slot_byte = flat_bus[31:24];
            endcase
        end
    endfunction

    function [7:0] status_char;
        input [6:0] idx;
        input ready_bit;
        input retire_bit;
        input tube_bit;
        input [7:0] iss0_pc;
        input [7:0] iss1_pc;
        input pending_bit;
        input found_bit;
        input inflight_bit;
        input [3:0] br_qj;
        input [7:0] br_seq;
        input [15:0] rs_flags_i;
        input [31:0] rs_pc_i;
        input [15:0] rs_fu_i;
        input [15:0] rs_qj_i;
        input [15:0] rs_qk_i;
        input [31:0] rs_seq_i;
        reg [1:0] slot_idx;
        reg [3:0] nibble_val;
        reg [7:0] byte_val;
        begin
            if (idx == 7'd0) begin
                status_char = 8'h51; // 'Q'
            end else if (idx == 7'd1) begin
                status_char = ready_bit ? 8'h31 : 8'h30;
            end else if (idx == 7'd2) begin
                status_char = retire_bit ? 8'h31 : 8'h30;
            end else if (idx == 7'd3) begin
                status_char = tube_bit ? 8'h31 : 8'h30;
            end else if (idx == 7'd4) begin
                status_char = 8'h3A;
            end else if (idx == 7'd5) begin
                status_char = hex_char(iss0_pc[7:4]);
            end else if (idx == 7'd6) begin
                status_char = hex_char(iss0_pc[3:0]);
            end else if (idx == 7'd7) begin
                status_char = hex_char(iss1_pc[7:4]);
            end else if (idx == 7'd8) begin
                status_char = hex_char(iss1_pc[3:0]);
            end else if (idx == 7'd9) begin
                status_char = 8'h3A;
            end else if (idx == 7'd10) begin
                status_char = pending_bit ? 8'h31 : 8'h30;
            end else if (idx == 7'd11) begin
                status_char = found_bit ? 8'h31 : 8'h30;
            end else if (idx == 7'd12) begin
                status_char = inflight_bit ? 8'h31 : 8'h30;
            end else if (idx == 7'd13) begin
                status_char = hex_char(br_qj);
            end else if (idx == 7'd14) begin
                status_char = hex_char(br_seq[7:4]);
            end else if (idx == 7'd15) begin
                status_char = hex_char(br_seq[3:0]);
            end else if (idx == 7'd16) begin
                status_char = 8'h3A;
            end else if (idx >= 7'd17 && idx <= 7'd52) begin
                slot_idx = (idx - 7'd17) / 9;
                case ((idx - 7'd17) % 9)
                    4'd0: begin
                        nibble_val = slot_nibble(rs_flags_i, slot_idx);
                        status_char = hex_char(nibble_val);
                    end
                    4'd1: begin
                        byte_val = slot_byte(rs_pc_i, slot_idx);
                        status_char = hex_char(byte_val[7:4]);
                    end
                    4'd2: begin
                        byte_val = slot_byte(rs_pc_i, slot_idx);
                        status_char = hex_char(byte_val[3:0]);
                    end
                    4'd3: begin
                        nibble_val = slot_nibble(rs_fu_i, slot_idx);
                        status_char = hex_char(nibble_val);
                    end
                    4'd4: begin
                        nibble_val = slot_nibble(rs_qj_i, slot_idx);
                        status_char = hex_char(nibble_val);
                    end
                    4'd5: begin
                        nibble_val = slot_nibble(rs_qk_i, slot_idx);
                        status_char = hex_char(nibble_val);
                    end
                    4'd6: begin
                        byte_val = slot_byte(rs_seq_i, slot_idx);
                        status_char = hex_char(byte_val[7:4]);
                    end
                    4'd7: begin
                        byte_val = slot_byte(rs_seq_i, slot_idx);
                        status_char = hex_char(byte_val[3:0]);
                    end
                    default: status_char = 8'h3A;
                endcase
            end else if (idx == 7'd53) begin
                status_char = 8'h0D;
            end else if (idx == 7'd54) begin
                status_char = 8'h0A;
            end else begin
                status_char = 8'h3F;
            end
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
            char_idx <= 7'd0;
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
            oldest_br_qj_t0_snapshot <= 4'd0;
            oldest_br_seq_lo_t0_snapshot <= 8'd0;
            rs_flags_flat_snapshot <= 16'd0;
            rs_pc_lo_flat_snapshot <= 32'd0;
            rs_fu_flat_snapshot <= 16'd0;
            rs_qj_flat_snapshot <= 16'd0;
            rs_qk_flat_snapshot <= 16'd0;
            rs_seq_lo_flat_snapshot <= 32'd0;
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
                        oldest_br_qj_t0_snapshot <= oldest_br_qj_t0;
                        oldest_br_seq_lo_t0_snapshot <= oldest_br_seq_lo_t0;
                        rs_flags_flat_snapshot <= rs_flags_flat;
                        rs_pc_lo_flat_snapshot <= rs_pc_lo_flat;
                        rs_fu_flat_snapshot <= rs_fu_flat;
                        rs_qj_flat_snapshot <= rs_qj_flat;
                        rs_qk_flat_snapshot <= rs_qk_flat;
                        rs_seq_lo_flat_snapshot <= rs_seq_lo_flat;
                        char_idx <= 7'd0;
                        tx_data <= status_char(
                            7'd0,
                            core_ready,
                            retire_seen,
                            tube_pass,
                            last_iss0_pc_lo,
                            last_iss1_pc_lo,
                            branch_pending,
                            br_found_t0,
                            branch_in_flight_t0,
                            oldest_br_qj_t0,
                            oldest_br_seq_lo_t0,
                            rs_flags_flat,
                            rs_pc_lo_flat,
                            rs_fu_flat,
                            rs_qj_flat,
                            rs_qk_flat,
                            rs_seq_lo_flat
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
                        if (char_idx == 7'd54) begin
                            delay_cnt <= LINE_DELAY_CYCLES;
                            state <= S_IDLE;
                        end else begin
                            char_idx <= char_idx + 7'd1;
                            tx_data <= status_char(
                                char_idx + 7'd1,
                                core_ready_snapshot,
                                retire_seen_snapshot,
                                tube_pass_snapshot,
                                last_iss0_pc_lo_snapshot,
                                last_iss1_pc_lo_snapshot,
                                branch_pending_snapshot,
                                br_found_t0_snapshot,
                                branch_in_flight_t0_snapshot,
                                oldest_br_qj_t0_snapshot,
                                oldest_br_seq_lo_t0_snapshot,
                                rs_flags_flat_snapshot,
                                rs_pc_lo_flat_snapshot,
                                rs_fu_flat_snapshot,
                                rs_qj_flat_snapshot,
                                rs_qk_flat_snapshot,
                                rs_seq_lo_flat_snapshot
                            );
                            tx_start <= 1'b1;
                            state <= S_WAIT_BUSY_HIGH;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
