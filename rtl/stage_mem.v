`include "define.v"
module stage_mem(
    input  wire        clk,
    input  wire        rstn,
    input  wire[31:0]  me_regs_data2,
    input  wire[31:0]  me_alu_o,
    input  wire        me_mem_read,
    input  wire        me_mem_write,
    input  wire[2:0]   me_func3_code,
    //forwarding
    input wire         forward_data,
    input wire[31:0]   w_regs_data,

`ifdef FPGA_MODE
    output reg[2:0]    me_led,
`endif
    output wire[31:0]  me_mem_data,

    // ═══════════════════════════════════════════════════════════════════════════
    // Store Buffer Drain Interface (NEW - for commit-gated store drain)
    // ═══════════════════════════════════════════════════════════════════════════
    input  wire        sb_write_valid,     // Store Buffer has a write to drain
    input  wire [31:0] sb_write_addr,
    input  wire [31:0] sb_write_data,
    input  wire [2:0]  sb_write_func3,
    input  wire [3:0]  sb_write_wen,       // Byte-wise write enable
    output wire        sb_write_ready      // Memory accepts write (always ready in this model)
);

reg [31:0]  w_data_mem;//actually wire
wire[31:0]  w_data_mem_pre;
wire[31:0]  r_data_mem;
reg [ 3:0]  w_en_mem;//actually wire
//wire[ 3:0]  r_en_mem;
wire[31:0]  addr_mem;
wire[ 1:0]  addr_in_word;
wire        en_mem;

// Store buffer write takes priority over speculative me_mem_write
// (me_mem_write should be disabled when Store Buffer is in use)
wire        use_sb_write = sb_write_valid;
wire [31:0] final_addr   = use_sb_write ? sb_write_addr  : me_alu_o;
wire [31:0] final_wdata  = use_sb_write ? sb_write_data  : w_data_mem;
wire [ 3:0] final_wen    = use_sb_write ? sb_write_wen   : w_en_mem;
wire        final_en     = me_mem_read || use_sb_write || me_mem_write;

// Store buffer is always ready (combinational memory)
assign sb_write_ready = 1'b1;

data_memory 
#(
    .RAM_SPACE (4096       )
)
u_data_memory(
    .clk        (clk               ),
    //.rstn       (rstn              ),
    .addr_mem   (addr_mem          ),
    .w_data_mem (final_wdata       ),
//    .r_en_mem   (r_en_mem          ),
    .w_en_mem   (final_wen         ),
    .en_mem     (en_mem            ),
    .r_data_mem (r_data_mem        )
);

// Update assignments to use final_* signals
assign w_data_mem_pre = forward_data ? w_regs_data : me_regs_data2; //forwarding for load+store which have data correlation
assign addr_mem       = final_addr;
assign addr_in_word   = addr_mem[1:0];
assign en_mem         = final_en;

/*----------------Read DataMemory---------------------*/
// the data read from mem will be valid at next cycle, so the logic design for L-inst has been moved to stage_wb!

assign me_mem_data = r_data_mem;

/*----------------Write DataMemory---------------------*/
always @(*) begin
    case(me_func3_code[1:0])
    `SB:begin
        case (addr_in_word)
            2'b00:   w_data_mem = {24'd0,w_data_mem_pre[7:0]};
            2'b01:   w_data_mem = {16'd0,w_data_mem_pre[7:0], 8'd0};
            2'b10:   w_data_mem = {8'd0,w_data_mem_pre[7:0], 16'd0};
            2'b11:   w_data_mem = {w_data_mem_pre[7:0],24'd0};
            default: w_data_mem = {32'd0};
        endcase
    end
    `SH:begin
        case (addr_in_word[1])//Half-byte address alignment
            1'b0:    w_data_mem = {16'd0,w_data_mem_pre[15:0]};
            1'b1:    w_data_mem = {w_data_mem_pre[15:0],16'd0};
            default: w_data_mem = {32'd0};
        endcase
    end
    `SW:     w_data_mem = w_data_mem_pre;
    default: w_data_mem = 32'd0;
    endcase
    //$strobe("WRITE DATA MEMORY: Addr %d = %h ,mode:%d", addr_mem,{data[addr_mem+3],data[addr_mem+2],data[addr_mem+1],data[addr_mem]},byte_sel);
end

//write enable with byte selection
always @(*)begin
    if(me_mem_write)
        case(me_func3_code[1:0])
            `SB : w_en_mem = 4'b0001 << addr_in_word;
            `SH : w_en_mem = 4'b0011 << {addr_in_word[1],1'b0};//Half-byte address alignment
            `SW : w_en_mem = 4'b1111;
            default : w_en_mem = 4'b0000;
        endcase
    else
        w_en_mem = 4'b0000;
end

always @(*) begin
    if (me_mem_write) begin
    $strobe("WRITE DATA MEMORY: Addr %d = %h ", addr_mem, w_data_mem);
    end
end

`ifdef FPGA_MODE 
    always @(posedge clk  or negedge rstn) begin
        if (!rstn)begin
            me_led  <= 3'b0;
        end
        else if (me_alu_o == 32'h400) begin
            me_led  <= w_data_mem[2:0];
        end
    end
`endif

endmodule