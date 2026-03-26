// =============================================================================
// Module: uart_tx
// Description: Simple UART Transmitter (8N1, 115200 baud @ 50MHz)
//   - 115200 baud @ 50MHz clock = 434 cycles per bit
//   - 8 data bits, no parity, 1 stop bit (8N1)
//   - Simple state machine implementation
//   - Active-high busy signal
// =============================================================================

module uart_tx #(
    parameter CLK_DIV = 434  // Default for 50MHz / 115200 baud
) (
    input  wire        clk,         // System clock
    input  wire        rst_n,       // Active-low reset
    input  wire        tx_start,    // Start transmission (pulse)
    input  wire [7:0]  tx_data,     // Data to transmit
    output reg         tx,          // UART TX line
    output reg         busy         // High when transmitting
);

    // Baud rate calculation: clk_freq / baud_rate
    // For 50MHz / 115200 = 434
    // For 200MHz / 115200 = 1736
    localparam CLK_DIV_BITS = 9;  // 2^9 = 512 > 434

    // State machine states
    localparam [2:0] STATE_IDLE  = 3'b000;
    localparam [2:0] STATE_START = 3'b001;
    localparam [2:0] STATE_DATA  = 3'b010;
    localparam [2:0] STATE_STOP  = 3'b011;
    localparam [2:0] STATE_DONE  = 3'b100;

    // State registers
    reg [2:0] state;
    reg [CLK_DIV_BITS-1:0] bit_cnt;    // Clock divider counter
    reg [3:0] bit_idx;                  // Current bit index (0-7)
    reg [7:0] tx_shift;                 // Shift register for data

    // Sequential logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= STATE_IDLE;
            tx       <= 1'b1;  // Idle state is high
            busy     <= 1'b0;
            bit_cnt  <= 0;
            bit_idx  <= 0;
            tx_shift <= 8'h00;
        end else begin
            case (state)
                STATE_IDLE: begin
                    tx <= 1'b1;  // Keep line idle
                    if (tx_start && !busy) begin
                        tx_shift <= tx_data;
                        state    <= STATE_START;
                        busy     <= 1'b1;
                        bit_cnt  <= 0;
                    end
                end

                STATE_START: begin
                    tx <= 1'b0;  // Start bit (low)
                    if (bit_cnt == CLK_DIV - 1) begin
                        bit_cnt <= 0;
                        bit_idx <= 0;
                        state   <= STATE_DATA;
                    end else begin
                        bit_cnt <= bit_cnt + 1;
                    end
                end

                STATE_DATA: begin
                    tx <= tx_shift[bit_idx];  // LSB first
                    if (bit_cnt == CLK_DIV - 1) begin
                        bit_cnt <= 0;
                        if (bit_idx == 7) begin
                            state <= STATE_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end else begin
                        bit_cnt <= bit_cnt + 1;
                    end
                end

                STATE_STOP: begin
                    tx <= 1'b1;  // Stop bit (high)
                    if (bit_cnt == CLK_DIV - 1) begin
                        bit_cnt <= 0;
                        state   <= STATE_DONE;
                    end else begin
                        bit_cnt <= bit_cnt + 1;
                    end
                end

                STATE_DONE: begin
                    busy <= 1'b0;
                    if (!tx_start) begin
                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule

// =============================================================================
// Module: uart_tx_autoboot
// Description: UART Transmitter with auto-boot message
//   Transmits "AdamRiscv AX7203 Boot\r\n" on startup
// =============================================================================

module uart_tx_autoboot (
    input  wire        clk,         // System clock (200MHz)
    input  wire        rst_n,       // Active-low reset
    output wire        tx           // UART TX line
);

    // Boot message: "AdamRiscv AX7203 Boot\r\n"
    localparam MSG_LEN = 24;
    localparam [MSG_LEN*8-1:0] BOOT_MSG = {
        8'h0A,  // \n
        8'h0D,  // \r
        8'h74,  // t
        8'h6F,  // o
        8'h6F,  // o
        8'h42,  // B
        8'h20,  // (space)
        8'h33,  // 3
        8'h30,  // 0
        8'h32,  // 2
        8'h37,  // 7
        8'h58,  // X
        8'h41,  // A
        8'h20,  // (space)
        8'h76,  // v
        8'h69,  // i
        8'h73,  // s
        8'h63,  // c
        8'h52,  // R
        8'h6D,  // m
        8'h61,  // a
        8'h64,  // d
        8'h41,  // A
        8'h0D   // \r
    };

    // State machine
    localparam [2:0] S_IDLE    = 3'b000;
    localparam [2:0] S_START   = 3'b001;
    localparam [2:0] S_WAIT    = 3'b010;
    localparam [2:0] S_NEXT    = 3'b011;
    localparam [2:0] S_DONE    = 3'b100;

    reg [2:0] state;
    reg [4:0] char_idx;      // Character index (0-23)
    reg [7:0] tx_data;
    wire      uart_busy;
    reg       tx_start;

    // UART transmitter instance
    uart_tx #(
        .CLK_DIV(1736)  // 200MHz / 115200 baud
    ) u_uart_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .tx_start  (tx_start),
        .tx_data   (tx_data),
        .tx        (tx),
        .busy      (uart_busy)
    );

    // State machine to send boot message
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            char_idx <= 0;
            tx_data  <= 8'h00;
            tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;  // Default to low

            case (state)
                S_IDLE: begin
                    char_idx <= 0;
                    state    <= S_START;
                end

                S_START: begin
                    // Load character from message
                    case (char_idx)
                        5'd0:  tx_data <= 8'h41;  // A
                        5'd1:  tx_data <= 8'h64;  // d
                        5'd2:  tx_data <= 8'h61;  // a
                        5'd3:  tx_data <= 8'h6D;  // m
                        5'd4:  tx_data <= 8'h52;  // R
                        5'd5:  tx_data <= 8'h69;  // i
                        5'd6:  tx_data <= 8'h73;  // s
                        5'd7:  tx_data <= 8'h63;  // c
                        5'd8:  tx_data <= 8'h76;  // v
                        5'd9:  tx_data <= 8'h20;  // (space)
                        5'd10: tx_data <= 8'h41;  // A
                        5'd11: tx_data <= 8'h58;  // X
                        5'd12: tx_data <= 8'h37;  // 7
                        5'd13: tx_data <= 8'h32;  // 2
                        5'd14: tx_data <= 8'h30;  // 0
                        5'd15: tx_data <= 8'h33;  // 3
                        5'd16: tx_data <= 8'h20;  // (space)
                        5'd17: tx_data <= 8'h42;  // B
                        5'd18: tx_data <= 8'h6F;  // o
                        5'd19: tx_data <= 8'h6F;  // o
                        5'd20: tx_data <= 8'h74;  // t
                        5'd21: tx_data <= 8'h0D;  // \r
                        5'd22: tx_data <= 8'h0A;  // \n
                        5'd23: tx_data <= 8'h00;  // null
                        default: tx_data <= 8'h00;
                    endcase
                    tx_start <= 1'b1;
                    state    <= S_WAIT;
                end

                S_WAIT: begin
                    if (!uart_busy) begin
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    if (char_idx < MSG_LEN - 1) begin
                        char_idx <= char_idx + 1;
                        state    <= S_START;
                    end else begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    // Message sent, stay here
                    state <= S_DONE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
