module uart_main_bridge_beacon (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       core_ready,
    input  wire       retire_seen,
    input  wire       tube_pass,
    input  wire [7:0] core_uart_frame_count_rolling,
    input  wire [7:0] board_tx_start_count,
    input  wire [7:0] board_uart_frame_count_rolling,
    input  wire [3:0] bridge_flags,
    output wire       tx
);

    localparam integer UART_CLK_DIV = 1736;
    localparam integer LINE_DELAY_CYCLES = 20_000_000;

    localparam [1:0] S_IDLE           = 2'd0;
    localparam [1:0] S_WAIT_BUSY_HIGH = 2'd1;
    localparam [1:0] S_WAIT_BUSY_LOW  = 2'd2;

    reg [1:0]  state;
    reg [4:0]  char_idx;
    reg [24:0] delay_cnt;
    reg [7:0]  tx_data;
    reg        tx_start;
    reg        core_ready_snapshot;
    reg        retire_seen_snapshot;
    reg        tube_pass_snapshot;
    reg [7:0]  core_uart_frame_count_snapshot;
    reg [7:0]  board_tx_start_count_snapshot;
    reg [7:0]  board_uart_frame_count_snapshot;
    reg [3:0]  bridge_flags_snapshot;
    wire       uart_busy;

    function [7:0] hex_char;
        input [3:0] nibble;
        begin
            hex_char = (nibble < 4'd10) ? (8'h30 + nibble) : (8'h41 + nibble - 4'd10);
        end
    endfunction

    function [7:0] status_char;
        input [4:0] idx;
        input ready_bit;
        input retire_bit;
        input tube_bit;
        input [7:0] core_count;
        input [7:0] start_count;
        input [7:0] board_count;
        input [3:0] flags;
        begin
            case (idx)
                5'd0:  status_char = 8'h4D; // 'M'
                5'd1:  status_char = ready_bit ? 8'h31 : 8'h30;
                5'd2:  status_char = retire_bit ? 8'h31 : 8'h30;
                5'd3:  status_char = tube_bit ? 8'h31 : 8'h30;
                5'd4:  status_char = 8'h3A; // ':'
                5'd5:  status_char = hex_char(core_count[7:4]);
                5'd6:  status_char = hex_char(core_count[3:0]);
                5'd7:  status_char = 8'h3A; // ':'
                5'd8:  status_char = hex_char(start_count[7:4]);
                5'd9:  status_char = hex_char(start_count[3:0]);
                5'd10: status_char = 8'h3A; // ':'
                5'd11: status_char = hex_char(board_count[7:4]);
                5'd12: status_char = hex_char(board_count[3:0]);
                5'd13: status_char = 8'h3A; // ':'
                5'd14: status_char = hex_char(flags);
                5'd15: status_char = 8'h0D;
                5'd16: status_char = 8'h0A;
                default: status_char = 8'h3F;
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
            state <= S_IDLE;
            char_idx <= 5'd0;
            delay_cnt <= 25'd0;
            tx_data <= 8'h00;
            tx_start <= 1'b0;
            core_ready_snapshot <= 1'b0;
            retire_seen_snapshot <= 1'b0;
            tube_pass_snapshot <= 1'b0;
            core_uart_frame_count_snapshot <= 8'd0;
            board_tx_start_count_snapshot <= 8'd0;
            board_uart_frame_count_snapshot <= 8'd0;
            bridge_flags_snapshot <= 4'd0;
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
                        core_uart_frame_count_snapshot <= core_uart_frame_count_rolling;
                        board_tx_start_count_snapshot <= board_tx_start_count;
                        board_uart_frame_count_snapshot <= board_uart_frame_count_rolling;
                        bridge_flags_snapshot <= bridge_flags;
                        char_idx <= 5'd0;
                        tx_data <= status_char(
                            5'd0,
                            core_ready,
                            retire_seen,
                            tube_pass,
                            core_uart_frame_count_rolling,
                            board_tx_start_count,
                            board_uart_frame_count_rolling,
                            bridge_flags
                        );
                        tx_start <= 1'b1;
                        state <= S_WAIT_BUSY_HIGH;
                    end
                end

                S_WAIT_BUSY_HIGH: begin
                    if (uart_busy) begin
                        state <= S_WAIT_BUSY_LOW;
                    end
                end

                S_WAIT_BUSY_LOW: begin
                    if (!uart_busy) begin
                        if (char_idx == 5'd16) begin
                            delay_cnt <= LINE_DELAY_CYCLES - 1;
                            state <= S_IDLE;
                        end else begin
                            char_idx <= char_idx + 5'd1;
                            tx_data <= status_char(
                                char_idx + 5'd1,
                                core_ready_snapshot,
                                retire_seen_snapshot,
                                tube_pass_snapshot,
                                core_uart_frame_count_snapshot,
                                board_tx_start_count_snapshot,
                                board_uart_frame_count_snapshot,
                                bridge_flags_snapshot
                            );
                            tx_start <= 1'b1;
                            state <= S_WAIT_BUSY_HIGH;
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
