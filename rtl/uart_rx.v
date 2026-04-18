// =============================================================================
// Module: uart_rx
// Description: Simple UART receiver (8N1)
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

    localparam integer HALF_DIV = (CLK_DIV / 2);
    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;
    localparam integer CNT_W = (CLK_DIV <= 1) ? 1 : $clog2(CLK_DIV + 1);
    localparam [CNT_W-1:0] HALF_DIV_CNT = HALF_DIV;
    localparam [CNT_W-1:0] FULL_DIV_CNT = CLK_DIV - 1;

    reg [2:0] rx_sync;
    reg       rx_filtered_prev;
    reg [1:0] state;
    reg [CNT_W-1:0] sample_cnt;
    reg [2:0] bit_idx;
    reg [7:0] data_shift;
    wire      rx_filtered = (rx_sync[2] & rx_sync[1]) |
                            (rx_sync[2] & rx_sync[0]) |
                            (rx_sync[1] & rx_sync[0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync     <= 3'b111;
            rx_filtered_prev <= 1'b1;
            state       <= S_IDLE;
            sample_cnt  <= {CNT_W{1'b0}};
            bit_idx     <= 3'd0;
            data_shift  <= 8'd0;
            byte_valid  <= 1'b0;
            byte_data   <= 8'd0;
            frame_error <= 1'b0;
        end else begin
            rx_sync     <= {rx_sync[1:0], rx};
            rx_filtered_prev <= rx_filtered;
            byte_valid  <= 1'b0;
            frame_error <= 1'b0;

            if (!enable) begin
                state      <= S_IDLE;
                sample_cnt <= {CNT_W{1'b0}};
                bit_idx    <= 3'd0;
            end else begin
                case (state)
                    S_IDLE: begin
                        if (rx_filtered_prev && !rx_filtered) begin
                            state      <= S_START;
                            sample_cnt <= HALF_DIV_CNT;
                        end
                    end

                    S_START: begin
                        if (sample_cnt != {CNT_W{1'b0}}) begin
                            sample_cnt <= sample_cnt - {{(CNT_W-1){1'b0}}, 1'b1};
                        end else if (!rx_filtered) begin
                            state      <= S_DATA;
                            sample_cnt <= FULL_DIV_CNT;
                            bit_idx    <= 3'd0;
                        end else begin
                            state <= S_IDLE;
                        end
                    end

                    S_DATA: begin
                        if (sample_cnt != {CNT_W{1'b0}}) begin
                            sample_cnt <= sample_cnt - {{(CNT_W-1){1'b0}}, 1'b1};
                        end else if (bit_idx == 3'd7) begin
                            data_shift[bit_idx] <= rx_filtered;
                            state      <= S_STOP;
                            sample_cnt <= FULL_DIV_CNT;
                        end else begin
                            data_shift[bit_idx] <= rx_filtered;
                            bit_idx    <= bit_idx + 3'd1;
                            sample_cnt <= FULL_DIV_CNT;
                        end
                    end

                    S_STOP: begin
                        if (sample_cnt != {CNT_W{1'b0}}) begin
                            sample_cnt <= sample_cnt - {{(CNT_W-1){1'b0}}, 1'b1};
                        end else begin
                            state <= S_IDLE;
                            if (rx_filtered) begin
                                byte_valid <= 1'b1;
                                byte_data  <= data_shift;
                            end else begin
                                frame_error <= 1'b1;
                            end
                        end
                    end

                    default: begin
                        state <= S_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
