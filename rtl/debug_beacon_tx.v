module debug_beacon_tx (
    input  wire       clk,
    input  wire       rstn,
    input  wire       evt_valid,
    output wire       evt_ready,
    input  wire [7:0] evt_type,
    input  wire [7:0] evt_arg,
    output wire       byte_valid,
    input  wire       byte_ready,
    output wire [7:0] byte_data
);

    localparam [7:0] SOF_BYTE       = 8'hA5;
    localparam [7:0] EVT_BAD        = 8'hE0;
    localparam [7:0] EVT_CAL_FAIL   = 8'hE1;
    localparam [7:0] EVT_TRAP       = 8'hEF;
    localparam [7:0] EVT_SUMMARY    = 8'hF0;
    localparam [1:0] EVENT_REPEAT   = 2'd2;
    localparam [1:0] ERROR_REPEAT   = 2'd3;
    localparam [3:0] SUMMARY_REPEAT = 4'd12;

    reg        pending_r;
    reg [7:0]  seq_r;
    reg [7:0]  latched_seq_r;
    reg [7:0]  latched_type_r;
    reg [7:0]  latched_arg_r;
    reg [3:0]  repeats_left_r;
    reg [2:0]  byte_idx_r;

    function [3:0] repeat_count;
        input [7:0] kind;
        begin
            case (kind)
                EVT_BAD,
                EVT_CAL_FAIL,
                EVT_TRAP: repeat_count = {2'd0, ERROR_REPEAT};
                EVT_SUMMARY: repeat_count = SUMMARY_REPEAT;
                default: repeat_count = {2'd0, EVENT_REPEAT};
            endcase
        end
    endfunction

    function [7:0] current_byte;
        input [2:0] idx;
        input [7:0] seq;
        input [7:0] kind;
        input [7:0] arg;
        begin
            case (idx)
                3'd0: current_byte = SOF_BYTE;
                3'd1: current_byte = seq;
                3'd2: current_byte = kind;
                3'd3: current_byte = arg;
                default: current_byte = SOF_BYTE ^ seq ^ kind ^ arg;
            endcase
        end
    endfunction

    assign evt_ready = !pending_r;
    assign byte_valid = pending_r;
    assign byte_data = current_byte(byte_idx_r, latched_seq_r, latched_type_r, latched_arg_r);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            pending_r      <= 1'b0;
            seq_r          <= 8'd0;
            latched_seq_r  <= 8'd0;
            latched_type_r <= 8'd0;
            latched_arg_r  <= 8'd0;
            repeats_left_r <= 4'd0;
            byte_idx_r     <= 3'd0;
        end else begin
            if (!pending_r) begin
                if (evt_valid) begin
                    pending_r      <= 1'b1;
                    latched_seq_r  <= seq_r;
                    latched_type_r <= evt_type;
                    latched_arg_r  <= evt_arg;
                    repeats_left_r <= repeat_count(evt_type);
                    byte_idx_r     <= 3'd0;
                end
            end else if (byte_valid && byte_ready) begin
                if (byte_idx_r == 3'd4) begin
                    if (repeats_left_r == 4'd1) begin
                        pending_r      <= 1'b0;
                        repeats_left_r <= 4'd0;
                        byte_idx_r     <= 3'd0;
                        seq_r          <= seq_r + 8'd1;
                    end else begin
                        repeats_left_r <= repeats_left_r - 4'd1;
                        byte_idx_r     <= 3'd0;
                    end
                end else begin
                    byte_idx_r <= byte_idx_r + 3'd1;
                end
            end
        end
    end

endmodule
