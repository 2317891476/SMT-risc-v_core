module scoreboard(
    input  wire        clk,
    input  wire        rstn,
    input  wire        flush,      // flush request (any thread)
    input  wire [0:0]  flush_tid,  // which thread is being flushed

    // IS -> Scoreboard (push)
    input  wire        is_push,
    input  wire[31:0]  is_pc,
    input  wire[31:0]  is_imm,
    input  wire[2:0]   is_func3_code,
    input  wire        is_func7_code,
    input  wire[4:0]   is_rd,
    input  wire        is_br,
    input  wire        is_mem_read,
    input  wire        is_mem2reg,
    input  wire[2:0]   is_alu_op,
    input  wire        is_mem_write,
    input  wire[1:0]   is_alu_src1,
    input  wire[1:0]   is_alu_src2,
    input  wire        is_br_addr_mode,
    input  wire        is_regs_write,
    input  wire[4:0]   is_rs1,
    input  wire[4:0]   is_rs2,
    input  wire        is_rs1_used,
    input  wire        is_rs2_used,
    input  wire[2:0]   is_fu,
    input  wire[0:0]   is_tid,        // SMT: which thread is pushing
    output wire        rs_full,

    // Scoreboard -> RO select
    output reg         ro_issue_valid,
    output reg[31:0]   ro_issue_pc,
    output reg[31:0]   ro_issue_imm,
    output reg[2:0]    ro_issue_func3_code,
    output reg         ro_issue_func7_code,
    output reg[4:0]    ro_issue_rd,
    output reg         ro_issue_br,
    output reg         ro_issue_mem_read,
    output reg         ro_issue_mem2reg,
    output reg[2:0]    ro_issue_alu_op,
    output reg         ro_issue_mem_write,
    output reg[1:0]    ro_issue_alu_src1,
    output reg[1:0]    ro_issue_alu_src2,
    output reg         ro_issue_br_addr_mode,
    output reg         ro_issue_regs_write,
    output reg[4:0]    ro_issue_rs1,
    output reg[4:0]    ro_issue_rs2,
    output reg         ro_issue_rs1_used,
    output reg         ro_issue_rs2_used,
    output reg[2:0]    ro_issue_fu,
    output reg[3:0]    ro_issue_sb_tag,
    output reg[0:0]    ro_issue_tid,  // SMT: thread of issued instruction

    // WB broadcast
    input  wire[2:0]   wb_fu,
    input  wire[4:0]   wb_rd,
    input  wire        wb_regs_write,
    input  wire[3:0]   wb_sb_tag,
    input  wire[0:0]   wb_tid          // SMT: which thread is writing back
);

localparam RS_DEPTH = 8;
localparam RS_IDX_W = 3;
localparam RS_TAG_W = 4;

reg        fu_busy [1:7];
// Per-thread reg_result_status: [thread_id][reg_addr]
reg [RS_TAG_W-1:0] reg_result_status [0:1][0:31];

reg        win_tid   [0:RS_DEPTH-1]; // SMT: thread owner of each RS slot

reg        win_valid [0:RS_DEPTH-1];
reg        win_issued [0:RS_DEPTH-1];
reg [3:0]  win_tag [0:RS_DEPTH-1];
reg [15:0] win_seq [0:RS_DEPTH-1];
reg [31:0] win_pc [0:RS_DEPTH-1];
reg [31:0] win_imm [0:RS_DEPTH-1];
reg [2:0]  win_func3_code [0:RS_DEPTH-1];
reg        win_func7_code [0:RS_DEPTH-1];
reg [4:0]  win_rd [0:RS_DEPTH-1];
reg        win_br [0:RS_DEPTH-1];
reg        win_mem_read [0:RS_DEPTH-1];
reg        win_mem2reg [0:RS_DEPTH-1];
reg [2:0]  win_alu_op [0:RS_DEPTH-1];
reg        win_mem_write [0:RS_DEPTH-1];
reg [1:0]  win_alu_src1 [0:RS_DEPTH-1];
reg [1:0]  win_alu_src2 [0:RS_DEPTH-1];
reg        win_br_addr_mode [0:RS_DEPTH-1];
reg        win_regs_write [0:RS_DEPTH-1];
reg [4:0]  win_rs1 [0:RS_DEPTH-1];
reg [4:0]  win_rs2 [0:RS_DEPTH-1];
reg        win_rs1_used [0:RS_DEPTH-1];
reg        win_rs2_used [0:RS_DEPTH-1];
reg [2:0]  win_fu [0:RS_DEPTH-1];
reg [RS_TAG_W-1:0] win_qj [0:RS_DEPTH-1];
reg [RS_TAG_W-1:0] win_qk [0:RS_DEPTH-1];
reg [RS_TAG_W-1:0] win_qd [0:RS_DEPTH-1];
reg        win_ready [0:RS_DEPTH-1];

reg                    free_found;
reg [RS_IDX_W-1:0]     free_idx;
wire[RS_TAG_W-1:0]     alloc_tag;

reg                    sel_found;
reg [RS_IDX_W-1:0]     sel_idx;
reg [15:0]             sel_seq;
reg                    war_block;

reg [RS_TAG_W-1:0] src1_tag_init;
reg [RS_TAG_W-1:0] src2_tag_init;
reg [RS_TAG_W-1:0] dst_tag_init;
reg [RS_TAG_W-1:0] qj_next;
reg [RS_TAG_W-1:0] qk_next;
reg [RS_TAG_W-1:0] qd_next;
reg [15:0] alloc_seq;
integer i;
integer j;

assign alloc_tag = win_tag[free_idx];
assign rs_full   = !free_found;

always @(*) begin
    free_found = 1'b0;
    free_idx   = {RS_IDX_W{1'b0}};
    for (i = 0; i < RS_DEPTH; i = i + 1) begin
        if (!free_found && !win_valid[i]) begin
            free_found = 1'b1;
            free_idx   = i;
        end
    end
end

always @(*) begin
    src1_tag_init = {RS_TAG_W{1'b0}};
    src2_tag_init = {RS_TAG_W{1'b0}};
    dst_tag_init  = {RS_TAG_W{1'b0}};

    // Dependency lookup scoped to the same thread (is_tid)
    if (is_rs1_used && (is_rs1 != 5'd0)) begin
        src1_tag_init = reg_result_status[is_tid][is_rs1];
        if (wb_regs_write && (wb_sb_tag != 4'd0) && (wb_tid == is_tid) &&
            (src1_tag_init == wb_sb_tag)) begin
            src1_tag_init = {RS_TAG_W{1'b0}};
        end
    end

    if (is_rs2_used && (is_rs2 != 5'd0)) begin
        src2_tag_init = reg_result_status[is_tid][is_rs2];
        if (wb_regs_write && (wb_sb_tag != 4'd0) && (wb_tid == is_tid) &&
            (src2_tag_init == wb_sb_tag)) begin
            src2_tag_init = {RS_TAG_W{1'b0}};
        end
    end

    if (is_regs_write && (is_rd != 5'd0)) begin
        dst_tag_init = reg_result_status[is_tid][is_rd];
        if (wb_regs_write && (wb_sb_tag != 4'd0) && (wb_tid == is_tid) &&
            (dst_tag_init == wb_sb_tag)) begin
            dst_tag_init = {RS_TAG_W{1'b0}};
        end
    end
end

always @(*) begin
    sel_found             = 1'b0;
    sel_idx               = {RS_IDX_W{1'b0}};
    sel_seq               = 16'hffff;
    ro_issue_valid        = 1'b0;
    ro_issue_pc           = 32'd0;
    ro_issue_imm          = 32'd0;
    ro_issue_func3_code   = 3'd0;
    ro_issue_func7_code   = 1'b0;
    ro_issue_rd           = 5'd0;
    ro_issue_br           = 1'b0;
    ro_issue_mem_read     = 1'b0;
    ro_issue_mem2reg      = 1'b0;
    ro_issue_alu_op       = 3'd0;
    ro_issue_mem_write    = 1'b0;
    ro_issue_alu_src1     = 2'd0;
    ro_issue_alu_src2     = 2'd0;
    ro_issue_br_addr_mode = 1'b0;
    ro_issue_regs_write   = 1'b0;
    ro_issue_rs1          = 5'd0;
    ro_issue_rs2          = 5'd0;
    ro_issue_rs1_used     = 1'b0;
    ro_issue_rs2_used     = 1'b0;
    ro_issue_fu           = 3'd0;
    ro_issue_sb_tag       = 4'd0;
    ro_issue_tid          = 1'b0;

    for (i = 0; i < RS_DEPTH; i = i + 1) begin
        war_block = 1'b0;
        if (win_valid[i] &&
            !win_issued[i] &&
            win_ready[i] &&
            (win_fu[i] != 3'd0) &&
            !fu_busy[win_fu[i]]) begin

            if (win_regs_write[i] && (win_rd[i] != 5'd0)) begin
                for (j = 0; j < RS_DEPTH; j = j + 1) begin
                    if (!war_block &&
                        win_valid[j] &&
                        !win_issued[j] &&
                        (win_tid[j] == win_tid[i]) &&  // WAR only within same thread
                        (win_seq[j] < win_seq[i]) &&
                        ((win_rs1_used[j] && (win_rs1[j] == win_rd[i])) ||
                         (win_rs2_used[j] && (win_rs2[j] == win_rd[i])))) begin
                        war_block = 1'b1;
                    end
                end
            end

            if (!war_block && (!sel_found || (win_seq[i] < sel_seq))) begin
                sel_found             = 1'b1;
                sel_idx               = i;
                sel_seq               = win_seq[i];
                ro_issue_valid        = 1'b1;
                ro_issue_pc           = win_pc[i];
                ro_issue_imm          = win_imm[i];
                ro_issue_func3_code   = win_func3_code[i];
                ro_issue_func7_code   = win_func7_code[i];
                ro_issue_rd           = win_rd[i];
                ro_issue_br           = win_br[i];
                ro_issue_mem_read     = win_mem_read[i];
                ro_issue_mem2reg      = win_mem2reg[i];
                ro_issue_alu_op       = win_alu_op[i];
                ro_issue_mem_write    = win_mem_write[i];
                ro_issue_alu_src1     = win_alu_src1[i];
                ro_issue_alu_src2     = win_alu_src2[i];
                ro_issue_br_addr_mode = win_br_addr_mode[i];
                ro_issue_regs_write   = win_regs_write[i];
                ro_issue_rs1          = win_rs1[i];
                ro_issue_rs2          = win_rs2[i];
                ro_issue_rs1_used     = win_rs1_used[i];
                ro_issue_rs2_used     = win_rs2_used[i];
                ro_issue_fu           = win_fu[i];
                ro_issue_sb_tag       = win_tag[i];
                ro_issue_tid          = win_tid[i];
            end
        end
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        alloc_seq <= 16'd0;
        for (i = 1; i <= 7; i = i + 1) begin
            fu_busy[i] <= 1'b0;
        end
        for (i = 0; i < 32; i = i + 1) begin
            reg_result_status[0][i] <= {RS_TAG_W{1'b0}};
            reg_result_status[1][i] <= {RS_TAG_W{1'b0}};
        end
        for (i = 0; i < RS_DEPTH; i = i + 1) begin
            win_tid[i]          <= 1'b0;
            win_valid[i]        <= 1'b0;
            win_issued[i]       <= 1'b0;
            win_tag[i]          <= i + 1;
            win_seq[i]          <= 16'd0;
            win_pc[i]           <= 32'd0;
            win_imm[i]          <= 32'd0;
            win_func3_code[i]   <= 3'd0;
            win_func7_code[i]   <= 1'b0;
            win_rd[i]           <= 5'd0;
            win_br[i]           <= 1'b0;
            win_mem_read[i]     <= 1'b0;
            win_mem2reg[i]      <= 1'b0;
            win_alu_op[i]       <= 3'd0;
            win_mem_write[i]    <= 1'b0;
            win_alu_src1[i]     <= 2'd0;
            win_alu_src2[i]     <= 2'd0;
            win_br_addr_mode[i] <= 1'b0;
            win_regs_write[i]   <= 1'b0;
            win_rs1[i]          <= 5'd0;
            win_rs2[i]          <= 5'd0;
            win_rs1_used[i]     <= 1'b0;
            win_rs2_used[i]     <= 1'b0;
            win_fu[i]           <= 3'd0;
            win_qj[i]           <= {RS_TAG_W{1'b0}};
            win_qk[i]           <= {RS_TAG_W{1'b0}};
            win_qd[i]           <= {RS_TAG_W{1'b0}};
            win_ready[i]        <= 1'b0;
        end
    end
    else begin
        if (wb_fu != 3'd0) begin
            fu_busy[wb_fu] <= 1'b0;
        end

        if (wb_regs_write &&
            (wb_rd != 5'd0) &&
            (wb_sb_tag != 4'd0) &&
            (reg_result_status[wb_tid][wb_rd] == wb_sb_tag)) begin
            reg_result_status[wb_tid][wb_rd] <= {RS_TAG_W{1'b0}};
        end

        for (i = 0; i < RS_DEPTH; i = i + 1) begin
            if (win_valid[i]) begin
                qj_next = win_qj[i];
                qk_next = win_qk[i];
                qd_next = win_qd[i];
                if (wb_regs_write && (wb_sb_tag != 4'd0)) begin
                    if (qj_next == wb_sb_tag) begin
                        qj_next = {RS_TAG_W{1'b0}};
                    end
                    if (qk_next == wb_sb_tag) begin
                        qk_next = {RS_TAG_W{1'b0}};
                    end
                    if (qd_next == wb_sb_tag) begin
                        qd_next = {RS_TAG_W{1'b0}};
                    end
                end
                win_qj[i]    <= qj_next;
                win_qk[i]    <= qk_next;
                win_qd[i]    <= qd_next;
                win_ready[i] <= (qj_next == {RS_TAG_W{1'b0}}) &&
                                (qk_next == {RS_TAG_W{1'b0}}) &&
                                (qd_next == {RS_TAG_W{1'b0}});
            end
            else begin
                win_qj[i]    <= {RS_TAG_W{1'b0}};
                win_qk[i]    <= {RS_TAG_W{1'b0}};
                win_qd[i]    <= {RS_TAG_W{1'b0}};
                win_ready[i] <= 1'b0;
            end
        end

        if (wb_sb_tag != 4'd0) begin
            for (i = 0; i < RS_DEPTH; i = i + 1) begin
                if (win_valid[i] && (win_tag[i] == wb_sb_tag)) begin
                    win_valid[i]  <= 1'b0;
                    win_issued[i] <= 1'b0;
                    win_qj[i]     <= {RS_TAG_W{1'b0}};
                    win_qk[i]     <= {RS_TAG_W{1'b0}};
                    win_qd[i]     <= {RS_TAG_W{1'b0}};
                    win_ready[i]  <= 1'b0;
                end
            end
        end

        if (flush) begin
            alloc_seq <= 16'd0;
            for (i = 0; i < RS_DEPTH; i = i + 1) begin
                // Only flush RS entries that belong to the flushing thread
                if (win_valid[i] && (win_tid[i] == flush_tid)) begin
                    if (win_regs_write[i] &&
                        (win_rd[i] != 5'd0) &&
                        (reg_result_status[win_tid[i]][win_rd[i]] == win_tag[i])) begin
                        reg_result_status[win_tid[i]][win_rd[i]] <= {RS_TAG_W{1'b0}};
                    end
                    win_valid[i] <= 1'b0;
                    win_issued[i] <= 1'b0;
                    win_seq[i]   <= 16'd0;
                    win_qj[i]    <= {RS_TAG_W{1'b0}};
                    win_qk[i]    <= {RS_TAG_W{1'b0}};
                    win_qd[i]    <= {RS_TAG_W{1'b0}};
                    win_ready[i] <= 1'b0;
                end
            end
        end
        else begin
            if (sel_found) begin
                win_issued[sel_idx] <= 1'b1;
                win_ready[sel_idx]  <= 1'b0;
                if (win_fu[sel_idx] != 3'd0) begin
                    fu_busy[win_fu[sel_idx]] <= 1'b1;
                end
            end

            if (is_push && !rs_full) begin
                win_seq[free_idx]          <= alloc_seq;
                win_valid[free_idx]        <= 1'b1;
                win_issued[free_idx]       <= 1'b0;
                win_pc[free_idx]           <= is_pc;
                win_imm[free_idx]          <= is_imm;
                win_func3_code[free_idx]   <= is_func3_code;
                win_func7_code[free_idx]   <= is_func7_code;
                win_rd[free_idx]           <= is_rd;
                win_br[free_idx]           <= is_br;
                win_mem_read[free_idx]     <= is_mem_read;
                win_mem2reg[free_idx]      <= is_mem2reg;
                win_alu_op[free_idx]       <= is_alu_op;
                win_mem_write[free_idx]    <= is_mem_write;
                win_alu_src1[free_idx]     <= is_alu_src1;
                win_alu_src2[free_idx]     <= is_alu_src2;
                win_br_addr_mode[free_idx] <= is_br_addr_mode;
                win_regs_write[free_idx]   <= is_regs_write;
                win_rs1[free_idx]          <= is_rs1;
                win_rs2[free_idx]          <= is_rs2;
                win_rs1_used[free_idx]     <= is_rs1_used;
                win_rs2_used[free_idx]     <= is_rs2_used;
                win_fu[free_idx]           <= is_fu;
                win_tid[free_idx]          <= is_tid;  // SMT: tag which thread owns this slot
                win_qj[free_idx]           <= src1_tag_init;
                win_qk[free_idx]           <= src2_tag_init;
                win_qd[free_idx]           <= dst_tag_init;
                win_ready[free_idx]        <= (src1_tag_init == {RS_TAG_W{1'b0}}) &&
                                              (src2_tag_init == {RS_TAG_W{1'b0}}) &&
                                              (dst_tag_init == {RS_TAG_W{1'b0}});

                if (is_regs_write && (is_rd != 5'd0)) begin
                    reg_result_status[is_tid][is_rd] <= alloc_tag;  // SMT: per-thread reg status
                end

                alloc_seq <= alloc_seq + 16'd1;
            end
        end
    end
end

endmodule
