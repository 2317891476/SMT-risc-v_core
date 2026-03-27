// Simple UART TX test - sends "AX7203 " repeatedly
module uart_tx_simple (
    input  wire clk,
    input  wire rst_n,
    output reg  tx
);
    // Baud rate: 115200 @ 200MHz = 1736 cycles per bit
    localparam BIT_TIME = 11'd1736;
    localparam CHAR_GAP = 16'd50000;  // Gap between characters
    
    reg [10:0] bit_cnt;
    reg [15:0] gap_cnt;
    reg [3:0] bit_idx;   // 0-9: start bit + 8 data bits + stop bit
    reg [4:0] char_idx;  // 0-22: which character
    reg [7:0] tx_byte;
    reg busy;
    
    // Characters to send: "AdamRiscv AX7203 Boot\r\n"
    always @(*) begin
        case (char_idx)
            5'd0:  tx_byte = 8'h41;  // 'A'
            5'd1:  tx_byte = 8'h64;  // 'd'
            5'd2:  tx_byte = 8'h61;  // 'a'
            5'd3:  tx_byte = 8'h6D;  // 'm'
            5'd4:  tx_byte = 8'h52;  // 'R'
            5'd5:  tx_byte = 8'h69;  // 'i'
            5'd6:  tx_byte = 8'h73;  // 's'
            5'd7:  tx_byte = 8'h63;  // 'c'
            5'd8:  tx_byte = 8'h76;  // 'v'
            5'd9:  tx_byte = 8'h20;  // ' '
            5'd10: tx_byte = 8'h41;  // 'A'
            5'd11: tx_byte = 8'h58;  // 'X'
            5'd12: tx_byte = 8'h37;  // '7'
            5'd13: tx_byte = 8'h32;  // '2'
            5'd14: tx_byte = 8'h30;  // '0'
            5'd15: tx_byte = 8'h33;  // '3'
            5'd16: tx_byte = 8'h20;  // ' '
            5'd17: tx_byte = 8'h42;  // 'B'
            5'd18: tx_byte = 8'h6F;  // 'o'
            5'd19: tx_byte = 8'h6F;  // 'o'
            5'd20: tx_byte = 8'h74;  // 't'
            5'd21: tx_byte = 8'h0D;  // '\r'
            5'd22: tx_byte = 8'h0A;  // '\n'
            default: tx_byte = 8'h3F; // '?'
        endcase
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx <= 1'b1;
            bit_cnt <= 0;
            gap_cnt <= 0;
            bit_idx <= 0;
            char_idx <= 0;
            busy <= 0;
        end else begin
            if (!busy) begin
                // Gap between characters
                if (gap_cnt < CHAR_GAP) begin
                    gap_cnt <= gap_cnt + 1;
                    tx <= 1'b1;  // Idle
                end else begin
                    gap_cnt <= 0;
                    busy <= 1;
                    bit_idx <= 0;
                end
            end else begin
                // Transmitting a character
                if (bit_cnt < BIT_TIME - 1) begin
                    bit_cnt <= bit_cnt + 1;
                end else begin
                    bit_cnt <= 0;
                    if (bit_idx == 4'd9) begin
                        // Done with this character
                        busy <= 0;
                        char_idx <= (char_idx == 5'd22) ? 0 : char_idx + 1;
                    end else begin
                        bit_idx <= bit_idx + 1;
                    end
                end
                
                // Output based on bit index
                case (bit_idx)
                    4'd0: tx <= 1'b0;  // Start bit
                    4'd1: tx <= tx_byte[0];
                    4'd2: tx <= tx_byte[1];
                    4'd3: tx <= tx_byte[2];
                    4'd4: tx <= tx_byte[3];
                    4'd5: tx <= tx_byte[4];
                    4'd6: tx <= tx_byte[5];
                    4'd7: tx <= tx_byte[6];
                    4'd8: tx <= tx_byte[7];
                    4'd9: tx <= 1'b1;  // Stop bit
                    default: tx <= 1'b1;
                endcase
            end
        end
    end
endmodule
