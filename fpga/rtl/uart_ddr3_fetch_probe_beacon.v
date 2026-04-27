module uart_ddr3_fetch_probe_beacon #(
    parameter integer CLK_DIV = 217
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        core_ready,
    input  wire        ddr3_calib_done,
    input  wire        core_uart_byte_valid,
    input  wire [7:0]  core_uart_byte,
    input  wire [383:0] debug_bus,
    output wire        tx,
    output wire        active,
    output reg         debug_byte_valid,
    output reg  [7:0]  debug_byte
);

`ifdef DDR3_FETCH_PROBE_FAST
    localparam integer IDLE_TIMEOUT_CYCLES = 5_000;
    localparam integer LINE_DELAY_CYCLES   = 25_000;
`else
    localparam integer IDLE_TIMEOUT_CYCLES = 500_000;
    localparam integer LINE_DELAY_CYCLES   = 2_500_000;
`endif

    localparam [71:0] JUMP_TOKEN = 72'h4A554D502044445233; // "JUMP DDR3"
    localparam [7:0]  LINE_LAST_IDX = 8'd166;
    localparam [24:0] IDLE_TIMEOUT_COUNT = IDLE_TIMEOUT_CYCLES[24:0];
    localparam [24:0] LINE_DELAY_COUNT   = LINE_DELAY_CYCLES[24:0];
    localparam [15:0] UART_GAP_COUNT     = CLK_DIV[15:0];

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_WAIT_BUSY_HIGH = 2'd1;
    localparam [1:0] S_WAIT_BUSY_LOW = 2'd2;
    localparam [1:0] S_GAP = 2'd3;

    reg [1:0]  state;
    reg        jump_seen;
    reg [71:0] core_shift;
    reg [24:0] idle_cnt;
    reg [24:0] line_delay_cnt;
    reg [15:0] gap_cnt;
    reg [7:0]  char_idx;
    reg        tx_start;
    reg [7:0]  tx_data;
    wire       uart_busy;

    reg [7:0]  rq_s;
    reg [7:0]  ac_s;
    reg [7:0]  rs_s;
    reg [7:0]  ls_s;
    reg [31:0] addr_s;
    reg [31:0] data_s;
    reg [7:0]  im_s;
    reg [7:0]  id_s;
    reg [7:0]  ic_s;
    reg [31:0] fpc_s;
    reg [7:0]  if_s;
    reg [7:0]  mf_s;
    reg [7:0]  cf_s;
    reg [7:0]  flow_s;
    reg [7:0]  ifcnt_s;
    reg [7:0]  fbcnt_s;
    reg [7:0]  deccnt_s;
    reg [7:0]  dispcnt_s;
    reg [7:0]  retcnt_s;
    reg [7:0]  m1q_s;
    reg [7:0]  m1r_s;
    reg [31:0] pc_out_s;
    reg [31:0] inst_s;
    reg [31:0] uart_s;
    reg [31:0] uart_flags_s;
    reg [7:0]  base_ifcnt;
    reg [7:0]  base_fbcnt;
    reg [7:0]  base_deccnt;
    reg [7:0]  base_dispcnt;
    reg [7:0]  base_retcnt;
    reg [7:0]  base_m1q;
    reg [7:0]  base_m1r;

    assign active = jump_seen && (idle_cnt >= IDLE_TIMEOUT_COUNT);

    uart_tx #(
        .CLK_DIV(CLK_DIV)
    ) u_uart_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_start (tx_start),
        .tx_data  (tx_data),
        .tx       (tx),
        .busy     (uart_busy)
    );

    function [7:0] hex_char;
        input [3:0] nibble;
        begin
            hex_char = (nibble < 4'd10) ? (8'h30 + nibble) : (8'h41 + nibble - 4'd10);
        end
    endfunction

    function [3:0] word_nibble;
        input [31:0] value;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: word_nibble = value[31:28];
                3'd1: word_nibble = value[27:24];
                3'd2: word_nibble = value[23:20];
                3'd3: word_nibble = value[19:16];
                3'd4: word_nibble = value[15:12];
                3'd5: word_nibble = value[11:8];
                3'd6: word_nibble = value[7:4];
                default: word_nibble = value[3:0];
            endcase
        end
    endfunction

    function [7:0] hex8_char;
        input [7:0] value;
        input       high;
        begin
            hex8_char = hex_char(high ? value[7:4] : value[3:0]);
        end
    endfunction

    function [7:0] hex32_char;
        input [31:0] value;
        input [2:0]  idx;
        begin
            hex32_char = hex_char(word_nibble(value, idx));
        end
    endfunction

    function [7:0] status_char;
        input [7:0] idx;
        begin
            if (idx >= 8'd102 && idx <= 8'd109) begin
                status_char = hex32_char({m1r_s, m1q_s, retcnt_s, dispcnt_s}, idx - 8'd102);
            end else if (idx >= 8'd113 && idx <= 8'd120) begin
                status_char = hex32_char({deccnt_s, fbcnt_s, ifcnt_s, flow_s}, idx - 8'd113);
            end else if (idx >= 8'd124 && idx <= 8'd131) begin
                status_char = hex32_char(pc_out_s, idx - 8'd124);
            end else if (idx >= 8'd135 && idx <= 8'd142) begin
                status_char = hex32_char(inst_s, idx - 8'd135);
            end else if (idx >= 8'd146 && idx <= 8'd153) begin
                status_char = hex32_char(uart_s, idx - 8'd146);
            end else if (idx >= 8'd157 && idx <= 8'd164) begin
                status_char = hex32_char(uart_flags_s, idx - 8'd157);
            end else begin
            case (idx)
                7'd0:  status_char = 8'h4D; // M
                7'd1:  status_char = 8'h30; // 0
                7'd2:  status_char = 8'h44; // D
                7'd3:  status_char = 8'h20;
                7'd4:  status_char = 8'h52; // R
                7'd5:  status_char = 8'h51; // Q
                7'd6:  status_char = 8'h3D;
                7'd7:  status_char = hex8_char(rq_s, 1'b1);
                7'd8:  status_char = hex8_char(rq_s, 1'b0);
                7'd9:  status_char = 8'h20;
                7'd10: status_char = 8'h41; // A
                7'd11: status_char = 8'h43; // C
                7'd12: status_char = 8'h3D;
                7'd13: status_char = hex8_char(ac_s, 1'b1);
                7'd14: status_char = hex8_char(ac_s, 1'b0);
                7'd15: status_char = 8'h20;
                7'd16: status_char = 8'h52; // R
                7'd17: status_char = 8'h53; // S
                7'd18: status_char = 8'h3D;
                7'd19: status_char = hex8_char(rs_s, 1'b1);
                7'd20: status_char = hex8_char(rs_s, 1'b0);
                7'd21: status_char = 8'h20;
                7'd22: status_char = 8'h4C; // L
                7'd23: status_char = 8'h53; // S
                7'd24: status_char = 8'h3D;
                7'd25: status_char = hex8_char(ls_s, 1'b1);
                7'd26: status_char = hex8_char(ls_s, 1'b0);
                7'd27: status_char = 8'h20;
                7'd28: status_char = 8'h49; // I
                7'd29: status_char = 8'h4D; // M
                7'd30: status_char = 8'h3D;
                7'd31: status_char = hex8_char(im_s, 1'b1);
                7'd32: status_char = hex8_char(im_s, 1'b0);
                7'd33: status_char = 8'h20;
                7'd34: status_char = 8'h49; // I
                7'd35: status_char = 8'h44; // D
                7'd36: status_char = 8'h3D;
                7'd37: status_char = hex8_char(id_s, 1'b1);
                7'd38: status_char = hex8_char(id_s, 1'b0);
                7'd39: status_char = 8'h20;
                7'd40: status_char = 8'h49; // I
                7'd41: status_char = 8'h43; // C
                7'd42: status_char = 8'h3D;
                7'd43: status_char = hex8_char(ic_s, 1'b1);
                7'd44: status_char = hex8_char(ic_s, 1'b0);
                7'd45: status_char = 8'h20;
                7'd46: status_char = 8'h50; // P
                7'd47: status_char = 8'h43; // C
                7'd48: status_char = 8'h3D;
                7'd49: status_char = hex32_char(fpc_s, 3'd0);
                7'd50: status_char = hex32_char(fpc_s, 3'd1);
                7'd51: status_char = hex32_char(fpc_s, 3'd2);
                7'd52: status_char = hex32_char(fpc_s, 3'd3);
                7'd53: status_char = hex32_char(fpc_s, 3'd4);
                7'd54: status_char = hex32_char(fpc_s, 3'd5);
                7'd55: status_char = hex32_char(fpc_s, 3'd6);
                7'd56: status_char = hex32_char(fpc_s, 3'd7);
                7'd57: status_char = 8'h20;
                7'd58: status_char = 8'h41; // A
                7'd59: status_char = 8'h3D;
                7'd60: status_char = hex32_char(addr_s, 3'd0);
                7'd61: status_char = hex32_char(addr_s, 3'd1);
                7'd62: status_char = hex32_char(addr_s, 3'd2);
                7'd63: status_char = hex32_char(addr_s, 3'd3);
                7'd64: status_char = hex32_char(addr_s, 3'd4);
                7'd65: status_char = hex32_char(addr_s, 3'd5);
                7'd66: status_char = hex32_char(addr_s, 3'd6);
                7'd67: status_char = hex32_char(addr_s, 3'd7);
                7'd68: status_char = 8'h20;
                7'd69: status_char = 8'h44; // D
                7'd70: status_char = 8'h3D;
                7'd71: status_char = hex32_char(data_s, 3'd0);
                7'd72: status_char = hex32_char(data_s, 3'd1);
                7'd73: status_char = hex32_char(data_s, 3'd2);
                7'd74: status_char = hex32_char(data_s, 3'd3);
                7'd75: status_char = hex32_char(data_s, 3'd4);
                7'd76: status_char = hex32_char(data_s, 3'd5);
                7'd77: status_char = hex32_char(data_s, 3'd6);
                7'd78: status_char = hex32_char(data_s, 3'd7);
                7'd79: status_char = 8'h20;
                7'd80: status_char = 8'h46; // F
                7'd81: status_char = 8'h3D;
                7'd82: status_char = hex8_char(if_s, 1'b1);
                7'd83: status_char = hex8_char(if_s, 1'b0);
                7'd84: status_char = 8'h20;
                7'd85: status_char = 8'h53; // S
                7'd86: status_char = 8'h3D;
                7'd87: status_char = hex8_char(mf_s, 1'b1);
                7'd88: status_char = hex8_char(mf_s, 1'b0);
                7'd89: status_char = 8'h20;
                7'd90: status_char = 8'h43; // C
                7'd91: status_char = 8'h3D;
                7'd92: status_char = hex8_char(cf_s, 1'b1);
                7'd93: status_char = hex8_char(cf_s, 1'b0);
                8'd94:  status_char = 8'h20;
                8'd95:  status_char = 8'h47; // G
                8'd96:  status_char = 8'h3D;
                8'd97:  status_char = hex8_char(flow_s, 1'b1);
                8'd98:  status_char = hex8_char(flow_s, 1'b0);
                8'd99:  status_char = 8'h20;
                8'd100: status_char = 8'h4E; // N
                8'd101: status_char = 8'h3D;
                8'd110: status_char = 8'h20;
                8'd111: status_char = 8'h50; // P
                8'd112: status_char = 8'h3D;
                8'd121: status_char = 8'h20;
                8'd122: status_char = 8'h4F; // O
                8'd123: status_char = 8'h3D;
                8'd132: status_char = 8'h20;
                8'd133: status_char = 8'h49; // I
                8'd134: status_char = 8'h3D;
                8'd143: status_char = 8'h20;
                8'd144: status_char = 8'h55; // U
                8'd145: status_char = 8'h3D;
                8'd154: status_char = 8'h20;
                8'd155: status_char = 8'h56; // V
                8'd156: status_char = 8'h3D;
                8'd165: status_char = 8'h0D;
                8'd166: status_char = 8'h0A;
                default: status_char = 8'h3F;
            endcase
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            jump_seen <= 1'b0;
            core_shift <= 72'd0;
            idle_cnt <= 25'd0;
            line_delay_cnt <= 25'd0;
            gap_cnt <= 16'd0;
            char_idx <= 8'd0;
            tx_start <= 1'b0;
            tx_data <= 8'd0;
            debug_byte_valid <= 1'b0;
            debug_byte <= 8'd0;
            rq_s <= 8'd0;
            ac_s <= 8'd0;
            rs_s <= 8'd0;
            ls_s <= 8'd0;
            addr_s <= 32'd0;
            data_s <= 32'd0;
            im_s <= 8'd0;
            id_s <= 8'd0;
            ic_s <= 8'd0;
            fpc_s <= 32'd0;
            if_s <= 8'd0;
            mf_s <= 8'd0;
            cf_s <= 8'd0;
            flow_s <= 8'd0;
            ifcnt_s <= 8'd0;
            fbcnt_s <= 8'd0;
            deccnt_s <= 8'd0;
            dispcnt_s <= 8'd0;
            retcnt_s <= 8'd0;
            m1q_s <= 8'd0;
            m1r_s <= 8'd0;
            pc_out_s <= 32'd0;
            inst_s <= 32'd0;
            uart_s <= 32'd0;
            uart_flags_s <= 32'd0;
            base_ifcnt <= 8'd0;
            base_fbcnt <= 8'd0;
            base_deccnt <= 8'd0;
            base_dispcnt <= 8'd0;
            base_retcnt <= 8'd0;
            base_m1q <= 8'd0;
            base_m1r <= 8'd0;
        end else begin
            tx_start <= 1'b0;
            debug_byte_valid <= 1'b0;

            if (core_uart_byte_valid) begin
                core_shift <= {core_shift[63:0], core_uart_byte};
                idle_cnt <= 25'd0;
                if ({core_shift[63:0], core_uart_byte} == JUMP_TOKEN) begin
                    jump_seen <= 1'b1;
                    line_delay_cnt <= 25'd0;
                    base_ifcnt <= debug_bus[271:264];
                    base_fbcnt <= debug_bus[279:272];
                    base_deccnt <= debug_bus[287:280];
                    base_dispcnt <= debug_bus[295:288];
                    base_retcnt <= debug_bus[303:296];
                    base_m1q <= debug_bus[311:304];
                    base_m1r <= debug_bus[319:312];
                end
            end else if (jump_seen && idle_cnt != IDLE_TIMEOUT_COUNT) begin
                idle_cnt <= idle_cnt + 25'd1;
            end

            case (state)
                S_IDLE: begin
                    if (active) begin
                        if (line_delay_cnt != 25'd0) begin
                            line_delay_cnt <= line_delay_cnt - 25'd1;
                        end else if (core_ready && ddr3_calib_done && !uart_busy) begin
                            rq_s   <= debug_bus[7:0];
                            ac_s   <= debug_bus[15:8];
                            rs_s   <= debug_bus[23:16];
                            ls_s   <= debug_bus[31:24];
                            addr_s <= debug_bus[63:32];
                            data_s <= debug_bus[95:64];
                            im_s   <= debug_bus[111:104];
                            id_s   <= debug_bus[119:112];
                            ic_s   <= debug_bus[127:120];
                            fpc_s  <= debug_bus[159:128];
                            if_s   <= debug_bus[199:192];
                            mf_s   <= debug_bus[207:200];
                            cf_s   <= debug_bus[215:208];
                            flow_s <= debug_bus[263:256];
                            ifcnt_s <= debug_bus[271:264] - base_ifcnt;
                            fbcnt_s <= debug_bus[279:272] - base_fbcnt;
                            deccnt_s <= debug_bus[287:280] - base_deccnt;
                            dispcnt_s <= debug_bus[295:288] - base_dispcnt;
                            retcnt_s <= debug_bus[303:296] - base_retcnt;
                            m1q_s <= debug_bus[311:304] - base_m1q;
                            m1r_s <= debug_bus[319:312] - base_m1r;
                            pc_out_s <= debug_bus[191:160];
                            inst_s <= debug_bus[247:216];
                            uart_s <= debug_bus[383:352];
                            uart_flags_s <= debug_bus[351:320];
                            char_idx <= 8'd0;
                            tx_data <= status_char(7'd0);
                            debug_byte <= status_char(7'd0);
                            tx_start <= 1'b1;
                            debug_byte_valid <= 1'b1;
                            state <= S_WAIT_BUSY_HIGH;
                        end
                    end
                end

                S_WAIT_BUSY_HIGH: begin
                    if (uart_busy) begin
                        state <= S_WAIT_BUSY_LOW;
                    end
                end

                S_WAIT_BUSY_LOW: begin
                    if (!uart_busy) begin
                        gap_cnt <= UART_GAP_COUNT;
                        state <= S_GAP;
                    end
                end

                S_GAP: begin
                    if (gap_cnt != 16'd0) begin
                        gap_cnt <= gap_cnt - 16'd1;
                    end else if (char_idx == LINE_LAST_IDX) begin
                        line_delay_cnt <= LINE_DELAY_COUNT;
                        state <= S_IDLE;
                    end else begin
                        char_idx <= char_idx + 8'd1;
                        tx_data <= status_char(char_idx + 8'd1);
                        debug_byte <= status_char(char_idx + 8'd1);
                        tx_start <= 1'b1;
                        debug_byte_valid <= 1'b1;
                        state <= S_WAIT_BUSY_HIGH;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
