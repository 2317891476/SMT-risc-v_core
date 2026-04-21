// =============================================================================
// Module: uart_rx
// Description: UART receiver (8N1)
//   - CLK_DIV >= 16: 16x oversampling with start-bit qualification and
//     3-sample majority vote at oversample points 7/8/9.
//   - CLK_DIV < 16: legacy single-sample receiver retained for fast sim paths.
// =============================================================================

module uart_rx #(
    parameter integer CLK_DIV = 434
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    input  wire       rx,
    output reg        byte_valid,
    output reg [7:0]  byte_data,
    output reg        frame_error
);

    reg [2:0] rx_sync;
    reg       rx_filtered_prev;
    wire      rx_filtered = (rx_sync[2] & rx_sync[1]) |
                            (rx_sync[2] & rx_sync[0]) |
                            (rx_sync[1] & rx_sync[0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync <= 3'b111;
            rx_filtered_prev <= 1'b1;
        end else begin
            rx_sync <= {rx_sync[1:0], rx};
            rx_filtered_prev <= rx_filtered;
        end
    end

    generate
        if (CLK_DIV >= 16) begin : gen_uart_rx_oversampled
            localparam integer OS_RATE = 16;
            localparam [1:0] S_IDLE  = 2'd0;
            localparam [1:0] S_START = 2'd1;
            localparam [1:0] S_DATA  = 2'd2;
            localparam [1:0] S_STOP  = 2'd3;
            localparam integer OS_ACC_W = ((CLK_DIV + OS_RATE + 1) <= 1) ? 1 : $clog2(CLK_DIV + OS_RATE + 1);
            localparam [OS_ACC_W:0] CLK_DIV_VAL = CLK_DIV;
            localparam [OS_ACC_W:0] OS_RATE_VAL = OS_RATE;

            reg [1:0] state;
            reg [OS_ACC_W-1:0] os_acc;
            reg [3:0] os_idx;
            reg [2:0] bit_idx;
            reg [7:0] data_shift;
            reg [1:0] sample_sum;
            reg [1:0] start_low_count;
            reg [4:0] idle_high_count;
            reg       idle_armed;

            wire [OS_ACC_W:0] os_sum = {1'b0, os_acc} + OS_RATE_VAL;
            wire              os_tick = (os_sum >= CLK_DIV_VAL);
            wire [OS_ACC_W-1:0] os_acc_advance =
                os_tick ? (os_sum - CLK_DIV_VAL) : os_sum[OS_ACC_W-1:0];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    state <= S_IDLE;
                    os_acc <= {OS_ACC_W{1'b0}};
                    os_idx <= 4'd0;
                    bit_idx <= 3'd0;
                    data_shift <= 8'd0;
                    sample_sum <= 2'd0;
                    start_low_count <= 2'd0;
                    idle_high_count <= 5'd0;
                    idle_armed <= 1'b0;
                    byte_valid <= 1'b0;
                    byte_data <= 8'd0;
                    frame_error <= 1'b0;
                end else begin
                    byte_valid <= 1'b0;
                    frame_error <= 1'b0;

                    if (!enable) begin
                        state <= S_IDLE;
                        os_acc <= {OS_ACC_W{1'b0}};
                        os_idx <= 4'd0;
                        bit_idx <= 3'd0;
                        sample_sum <= 2'd0;
                        start_low_count <= 2'd0;
                        idle_high_count <= 5'd0;
                        idle_armed <= 1'b0;
                    end else begin
                        os_acc <= os_acc_advance;

                        if (os_tick) begin
                            case (state)
                                S_IDLE: begin
                                    os_idx <= 4'd0;
                                    bit_idx <= 3'd0;
                                    sample_sum <= 2'd0;
                                    start_low_count <= 2'd0;
                                    if (rx_filtered) begin
                                        if (idle_high_count != 5'd16)
                                            idle_high_count <= idle_high_count + 5'd1;
                                        if (idle_high_count >= 5'd15)
                                            idle_armed <= 1'b1;
                                    end else begin
                                        idle_high_count <= 5'd0;
                                        idle_armed <= 1'b0;
                                    end
                                    if (idle_armed && !rx_filtered) begin
                                        state <= S_START;
                                    end
                                end

                                S_START: begin
                                    idle_high_count <= 5'd0;
                                    idle_armed <= 1'b0;
                                    if (os_idx <= 4'd2 && !rx_filtered) begin
                                        if (start_low_count != 2'd3)
                                            start_low_count <= start_low_count + 2'd1;
                                    end
                                    if (os_idx >= 4'd7 && os_idx <= 4'd9 && rx_filtered) begin
                                        if (sample_sum != 2'd3)
                                            sample_sum <= sample_sum + 2'd1;
                                    end

                                    if (os_idx == 4'd15) begin
                                        if ((start_low_count == 2'd3) && (sample_sum <= 2'd1)) begin
                                            state <= S_DATA;
                                            os_idx <= 4'd0;
                                            bit_idx <= 3'd0;
                                            sample_sum <= 2'd0;
                                            start_low_count <= 2'd0;
                                        end else begin
                                            state <= S_IDLE;
                                            os_idx <= 4'd0;
                                            sample_sum <= 2'd0;
                                            start_low_count <= 2'd0;
                                        end
                                    end else begin
                                        os_idx <= os_idx + 4'd1;
                                    end
                                end

                                S_DATA: begin
                                    idle_high_count <= 5'd0;
                                    idle_armed <= 1'b0;
                                    if (os_idx >= 4'd7 && os_idx <= 4'd9 && rx_filtered) begin
                                        if (sample_sum != 2'd3)
                                            sample_sum <= sample_sum + 2'd1;
                                    end

                                    if (os_idx == 4'd15) begin
                                        data_shift[bit_idx] <= (sample_sum >= 2'd2);
                                        os_idx <= 4'd0;
                                        sample_sum <= 2'd0;
                                        if (bit_idx == 3'd7) begin
                                            state <= S_STOP;
                                        end else begin
                                            bit_idx <= bit_idx + 3'd1;
                                        end
                                    end else begin
                                        os_idx <= os_idx + 4'd1;
                                    end
                                end

                                S_STOP: begin
                                    if (os_idx >= 4'd7 && os_idx <= 4'd9 && rx_filtered) begin
                                        if (sample_sum != 2'd3)
                                            sample_sum <= sample_sum + 2'd1;
                                    end

                                    if (os_idx == 4'd15) begin
                                        state <= S_IDLE;
                                        os_idx <= 4'd0;
                                        sample_sum <= 2'd0;
                                        if (sample_sum >= 2'd2) begin
                                            // A valid stop bit already provides the required
                                            // idle-high qualification for the immediately
                                            // following start bit in a back-to-back UART stream.
                                            idle_high_count <= 5'd16;
                                            idle_armed <= 1'b1;
                                            byte_valid <= 1'b1;
                                            byte_data <= data_shift;
                                        end else begin
                                            idle_high_count <= 5'd0;
                                            idle_armed <= 1'b0;
                                            frame_error <= 1'b1;
                                        end
                                    end else begin
                                        idle_high_count <= 5'd0;
                                        idle_armed <= 1'b0;
                                        os_idx <= os_idx + 4'd1;
                                    end
                                end

                                default: begin
                                    state <= S_IDLE;
                                    os_idx <= 4'd0;
                                    sample_sum <= 2'd0;
                                    start_low_count <= 2'd0;
                                    idle_high_count <= 5'd0;
                                    idle_armed <= 1'b0;
                                end
                            endcase
                        end
                    end
                end
            end
        end else begin : gen_uart_rx_legacy
            localparam integer HALF_DIV = (CLK_DIV / 2);
            localparam [1:0] S_IDLE  = 2'd0;
            localparam [1:0] S_START = 2'd1;
            localparam [1:0] S_DATA  = 2'd2;
            localparam [1:0] S_STOP  = 2'd3;
            localparam integer CNT_W = (CLK_DIV <= 1) ? 1 : $clog2(CLK_DIV + 1);
            localparam [CNT_W-1:0] HALF_DIV_CNT = HALF_DIV;
            localparam [CNT_W-1:0] FULL_DIV_CNT = CLK_DIV - 1;

            reg [1:0] state;
            reg [CNT_W-1:0] sample_cnt;
            reg [2:0] bit_idx;
            reg [7:0] data_shift;
            reg [CNT_W-1:0] idle_high_cnt;
            reg             idle_ready_r;
            localparam integer IDLE_ARM_INT = (CLK_DIV <= 1) ? 0 : (CLK_DIV - 2);
            localparam [CNT_W-1:0] IDLE_ARM_CNT = IDLE_ARM_INT;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    state <= S_IDLE;
                    sample_cnt <= {CNT_W{1'b0}};
                    bit_idx <= 3'd0;
                    data_shift <= 8'd0;
                    idle_high_cnt <= {CNT_W{1'b0}};
                    idle_ready_r <= 1'b0;
                    byte_valid <= 1'b0;
                    byte_data <= 8'd0;
                    frame_error <= 1'b0;
                end else begin
                    byte_valid <= 1'b0;
                    frame_error <= 1'b0;

                    if (!enable) begin
                        state <= S_IDLE;
                        sample_cnt <= {CNT_W{1'b0}};
                        bit_idx <= 3'd0;
                        idle_high_cnt <= {CNT_W{1'b0}};
                        idle_ready_r <= 1'b0;
                    end else begin
                        case (state)
                            S_IDLE: begin
                                if (rx_filtered_prev && !rx_filtered && idle_ready_r) begin
                                    state <= S_START;
                                    sample_cnt <= HALF_DIV_CNT;
                                    idle_high_cnt <= {CNT_W{1'b0}};
                                    idle_ready_r <= 1'b0;
                                end else if (!rx_filtered) begin
                                    idle_high_cnt <= {CNT_W{1'b0}};
                                    idle_ready_r <= 1'b0;
                                end else begin
                                    if (idle_high_cnt != FULL_DIV_CNT)
                                        idle_high_cnt <= idle_high_cnt + {{(CNT_W-1){1'b0}}, 1'b1};
                                    if (idle_high_cnt >= IDLE_ARM_CNT)
                                        idle_ready_r <= 1'b1;
                                end
                            end

                            S_START: begin
                                idle_high_cnt <= {CNT_W{1'b0}};
                                idle_ready_r <= 1'b0;
                                if (sample_cnt != {CNT_W{1'b0}}) begin
                                    sample_cnt <= sample_cnt - {{(CNT_W-1){1'b0}}, 1'b1};
                                end else if (!rx_filtered) begin
                                    state <= S_DATA;
                                    sample_cnt <= FULL_DIV_CNT;
                                    bit_idx <= 3'd0;
                                end else begin
                                    state <= S_IDLE;
                                end
                            end

                            S_DATA: begin
                                idle_high_cnt <= {CNT_W{1'b0}};
                                idle_ready_r <= 1'b0;
                                if (sample_cnt != {CNT_W{1'b0}}) begin
                                    sample_cnt <= sample_cnt - {{(CNT_W-1){1'b0}}, 1'b1};
                                end else if (bit_idx == 3'd7) begin
                                    data_shift[bit_idx] <= rx_filtered;
                                    state <= S_STOP;
                                    sample_cnt <= FULL_DIV_CNT;
                                end else begin
                                    data_shift[bit_idx] <= rx_filtered;
                                    bit_idx <= bit_idx + 3'd1;
                                    sample_cnt <= FULL_DIV_CNT;
                                end
                            end

                            S_STOP: begin
                                if (sample_cnt != {CNT_W{1'b0}}) begin
                                    idle_high_cnt <= {CNT_W{1'b0}};
                                    idle_ready_r <= 1'b0;
                                    sample_cnt <= sample_cnt - {{(CNT_W-1){1'b0}}, 1'b1};
                                end else begin
                                    state <= S_IDLE;
                                    if (rx_filtered) begin
                                        // A valid stop bit should arm the receiver for the next
                                        // start bit immediately, otherwise standard back-to-back
                                        // UART bytes are dropped.
                                        idle_high_cnt <= FULL_DIV_CNT;
                                        idle_ready_r <= 1'b1;
                                        byte_valid <= 1'b1;
                                        byte_data <= data_shift;
                                    end else begin
                                        idle_high_cnt <= {CNT_W{1'b0}};
                                        idle_ready_r <= 1'b0;
                                        frame_error <= 1'b1;
                                    end
                                end
                            end

                            default: begin
                                state <= S_IDLE;
                                idle_high_cnt <= {CNT_W{1'b0}};
                                idle_ready_r <= 1'b0;
                            end
                        endcase
                    end
                end
            end
        end
    endgenerate

endmodule
