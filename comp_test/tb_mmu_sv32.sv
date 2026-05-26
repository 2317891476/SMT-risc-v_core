`timescale 1ns/1ps

module tb_mmu_sv32;

localparam [1:0] PRIV_U = 2'b00;
localparam [1:0] PRIV_S = 2'b01;
localparam [1:0] PRIV_M = 2'b11;

localparam [4:0] CAUSE_INST_PAGE_FAULT  = 5'd12;
localparam [4:0] CAUSE_LOAD_PAGE_FAULT  = 5'd13;
localparam [4:0] CAUSE_STORE_PAGE_FAULT = 5'd15;

localparam [7:0] PTE_V = 8'h01;
localparam [7:0] PTE_R = 8'h02;
localparam [7:0] PTE_W = 8'h04;
localparam [7:0] PTE_X = 8'h08;
localparam [7:0] PTE_U = 8'h10;
localparam [7:0] PTE_A = 8'h40;
localparam [7:0] PTE_D = 8'h80;

localparam [31:0] ROOT_BASE = 32'h0002_0000;
localparam [31:0] L0_BASE   = 32'h0002_1000;
localparam [31:0] L0U_BASE  = 32'h0002_2000;
localparam [21:0] ROOT_PPN  = ROOT_BASE[31:12];
localparam [21:0] L0_PPN    = L0_BASE[31:12];
localparam [21:0] L0U_PPN   = L0U_BASE[31:12];

reg clk;
reg rstn;

reg [31:0] satp;
reg [1:0]  priv_mode;
reg        mstatus_mxr;
reg        mstatus_sum;
reg        sfence_valid;
reg [31:0] sfence_vaddr;
reg [8:0]  sfence_asid;

reg        itlb_req_valid;
reg [31:0] itlb_req_vaddr;
wire       itlb_resp_hit;
wire [31:0] itlb_resp_paddr;
wire       itlb_resp_fault;
wire [4:0] itlb_resp_cause;
wire [31:0] itlb_resp_tval;
wire       itlb_busy;

reg        dtlb_req_valid;
reg [31:0] dtlb_req_vaddr;
reg        dtlb_req_store;
wire       dtlb_resp_hit;
wire [31:0] dtlb_resp_paddr;
wire       dtlb_resp_fault;
wire [4:0] dtlb_resp_cause;
wire [31:0] dtlb_resp_tval;
wire       dtlb_busy;

wire       ptw_req_valid;
wire       ptw_req_ready;
wire       ptw_req_write;
wire [31:0] ptw_req_addr;
wire [31:0] ptw_req_wdata;
wire [3:0]  ptw_req_wen;
reg        ptw_resp_valid;
reg [31:0] ptw_resp_rdata;

reg [31:0] mem [0:131071];
reg        ptw_pending;
reg [31:0] ptw_pending_rdata;
integer    idx;

assign ptw_req_ready = 1'b1;

mmu_sv32 #(
    .ITLB_ENTRIES(4),
    .DTLB_ENTRIES(4)
) u_mmu (
    .clk             (clk),
    .rstn            (rstn),
    .satp            (satp),
    .priv_mode       (priv_mode),
    .dtlb_priv_mode  (priv_mode),
    .mstatus_mxr     (mstatus_mxr),
    .mstatus_sum     (mstatus_sum),
    .sfence_valid    (sfence_valid),
    .sfence_vaddr    (sfence_vaddr),
    .sfence_asid     (sfence_asid),
    .itlb_req_valid  (itlb_req_valid),
    .itlb_req_vaddr  (itlb_req_vaddr),
    .itlb_resp_hit   (itlb_resp_hit),
    .itlb_resp_paddr (itlb_resp_paddr),
    .itlb_resp_fault (itlb_resp_fault),
    .itlb_resp_cause (itlb_resp_cause),
    .itlb_resp_tval  (itlb_resp_tval),
    .itlb_busy       (itlb_busy),
    .dtlb_req_valid  (dtlb_req_valid),
    .dtlb_req_vaddr  (dtlb_req_vaddr),
    .dtlb_req_store  (dtlb_req_store),
    .dtlb_resp_hit   (dtlb_resp_hit),
    .dtlb_resp_paddr (dtlb_resp_paddr),
    .dtlb_resp_fault (dtlb_resp_fault),
    .dtlb_resp_cause (dtlb_resp_cause),
    .dtlb_resp_tval  (dtlb_resp_tval),
    .dtlb_busy       (dtlb_busy),
    .ptw_req_valid   (ptw_req_valid),
    .ptw_req_ready   (ptw_req_ready),
    .ptw_req_write   (ptw_req_write),
    .ptw_req_addr    (ptw_req_addr),
    .ptw_req_wdata   (ptw_req_wdata),
    .ptw_req_wen     (ptw_req_wen),
    .ptw_resp_valid  (ptw_resp_valid),
    .ptw_resp_rdata  (ptw_resp_rdata)
);

always #5 clk = ~clk;

function automatic [31:0] make_pte(input [21:0] ppn, input [7:0] flags);
    begin
        make_pte = {ppn, 2'b00, flags};
    end
endfunction

function automatic integer mem_index(input [31:0] addr);
    begin
        mem_index = addr[18:2];
    end
endfunction

task automatic fail(input [1023:0] msg);
    begin
        $display("========= Test FAILED !!! %0s", msg);
        $finish;
    end
endtask

task automatic pulse_sfence_all;
    begin
        sfence_vaddr = 32'd0;
        sfence_asid  = 9'd0;
        sfence_valid = 1'b1;
        @(posedge clk); #1;
        sfence_valid = 1'b0;
        @(posedge clk); #1;
    end
endtask

task automatic expect_i_translate(input [31:0] vaddr, input [31:0] paddr);
    integer cycles;
    reg done;
    begin
        itlb_req_vaddr = vaddr;
        itlb_req_valid = 1'b1;
        done = 1'b0;
        for (cycles = 0; cycles < 200 && !done; cycles = cycles + 1) begin
            @(posedge clk); #1;
            if (itlb_resp_fault)
                fail("unexpected I page fault");
            if (itlb_resp_hit) begin
                if (itlb_resp_paddr !== paddr) begin
                    $display("I translate mismatch va=%h got=%h expected=%h", vaddr, itlb_resp_paddr, paddr);
                    fail("I paddr mismatch");
                end
                done = 1'b1;
            end
        end
        if (!done)
            fail("I translate timeout");
        itlb_req_valid = 1'b0;
        @(posedge clk); #1;
    end
endtask

task automatic expect_d_translate(input [31:0] vaddr, input store, input [31:0] paddr);
    integer cycles;
    reg done;
    begin
        dtlb_req_vaddr = vaddr;
        dtlb_req_store = store;
        dtlb_req_valid = 1'b1;
        done = 1'b0;
        for (cycles = 0; cycles < 240 && !done; cycles = cycles + 1) begin
            @(posedge clk); #1;
            if (dtlb_resp_fault)
                fail("unexpected D page fault");
            if (dtlb_resp_hit) begin
                if (dtlb_resp_paddr !== paddr) begin
                    $display("D translate mismatch va=%h got=%h expected=%h", vaddr, dtlb_resp_paddr, paddr);
                    fail("D paddr mismatch");
                end
                done = 1'b1;
            end
        end
        if (!done)
            fail("D translate timeout");
        dtlb_req_valid = 1'b0;
        @(posedge clk); #1;
    end
endtask

task automatic expect_i_fault(input [31:0] vaddr);
    integer cycles;
    reg done;
    begin
        itlb_req_vaddr = vaddr;
        itlb_req_valid = 1'b1;
        done = 1'b0;
        for (cycles = 0; cycles < 200 && !done; cycles = cycles + 1) begin
            @(posedge clk); #1;
            if (itlb_resp_hit)
                fail("unexpected I hit");
            if (itlb_resp_fault) begin
                if (itlb_resp_cause !== CAUSE_INST_PAGE_FAULT || itlb_resp_tval !== vaddr)
                    fail("bad I fault metadata");
                done = 1'b1;
            end
        end
        if (!done)
            fail("I fault timeout");
        itlb_req_valid = 1'b0;
        @(posedge clk); #1;
    end
endtask

task automatic expect_d_fault(input [31:0] vaddr, input store, input [4:0] cause);
    integer cycles;
    reg done;
    begin
        dtlb_req_vaddr = vaddr;
        dtlb_req_store = store;
        dtlb_req_valid = 1'b1;
        done = 1'b0;
        for (cycles = 0; cycles < 240 && !done; cycles = cycles + 1) begin
            @(posedge clk); #1;
            if (dtlb_resp_hit)
                fail("unexpected D hit");
            if (dtlb_resp_fault) begin
                if (dtlb_resp_cause !== cause || dtlb_resp_tval !== vaddr)
                    fail("bad D fault metadata");
                done = 1'b1;
            end
        end
        if (!done)
            fail("D fault timeout");
        dtlb_req_valid = 1'b0;
        @(posedge clk); #1;
    end
endtask

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ptw_pending     <= 1'b0;
        ptw_pending_rdata <= 32'd0;
        ptw_resp_valid  <= 1'b0;
        ptw_resp_rdata  <= 32'd0;
    end
    else begin
        ptw_resp_valid <= ptw_pending;
        ptw_resp_rdata <= ptw_pending_rdata;
        ptw_pending    <= 1'b0;

        if (ptw_req_valid && ptw_req_ready) begin
            ptw_pending <= 1'b1;
            ptw_pending_rdata <= mem[mem_index(ptw_req_addr)];
            if (ptw_req_write) begin
                if (ptw_req_wen[0]) mem[mem_index(ptw_req_addr)][7:0]   <= ptw_req_wdata[7:0];
                if (ptw_req_wen[1]) mem[mem_index(ptw_req_addr)][15:8]  <= ptw_req_wdata[15:8];
                if (ptw_req_wen[2]) mem[mem_index(ptw_req_addr)][23:16] <= ptw_req_wdata[23:16];
                if (ptw_req_wen[3]) mem[mem_index(ptw_req_addr)][31:24] <= ptw_req_wdata[31:24];
                ptw_pending_rdata <= ptw_req_wdata;
            end
        end
    end
end

initial begin
    clk = 1'b0;
    rstn = 1'b0;
    satp = 32'd0;
    priv_mode = PRIV_S;
    mstatus_mxr = 1'b0;
    mstatus_sum = 1'b0;
    sfence_valid = 1'b0;
    sfence_vaddr = 32'd0;
    sfence_asid = 9'd0;
    itlb_req_valid = 1'b0;
    itlb_req_vaddr = 32'd0;
    dtlb_req_valid = 1'b0;
    dtlb_req_vaddr = 32'd0;
    dtlb_req_store = 1'b0;

    for (idx = 0; idx < 131072; idx = idx + 1)
        mem[idx] = 32'd0;

    repeat (5) @(posedge clk);
    rstn = 1'b1;
    @(posedge clk); #1;

    // Bare mode and M-mode bypass.
    satp = 32'd0;
    priv_mode = PRIV_S;
    expect_i_translate(32'h1234_5678, 32'h1234_5678);
    satp = {1'b1, 9'd0, ROOT_PPN};
    priv_mode = PRIV_M;
    expect_d_translate(32'h8765_4320, 1'b0, 32'h8765_4320);

    // Root page table:
    // VPN1=1 -> L0 table, VPN1=2 -> 4MB megapage, VPN1=3 -> user executable page.
    priv_mode = PRIV_S;
    mem[mem_index(ROOT_BASE + (32'd1 << 2))] = make_pte(L0_PPN, PTE_V);
    mem[mem_index(ROOT_BASE + (32'd2 << 2))] = make_pte(22'h00400, PTE_V | PTE_R | PTE_X | PTE_A | PTE_D);
    mem[mem_index(ROOT_BASE + (32'd3 << 2))] = make_pte(L0U_PPN, PTE_V);
    mem[mem_index(L0_BASE + (32'd0 << 2))]   = make_pte(22'h00080, PTE_V | PTE_R | PTE_W);
    mem[mem_index(L0_BASE + (32'd1 << 2))]   = make_pte(22'h00082, PTE_V | PTE_R | PTE_X | PTE_A);
    mem[mem_index(L0U_BASE + (32'd0 << 2))]  = make_pte(22'h00090, PTE_V | PTE_X | PTE_U | PTE_A);
    pulse_sfence_all();

    // 4KB page: first load sets A, later store detects stale D=0 TLB entry and updates D.
    mstatus_mxr = 1'b0;
    mstatus_sum = 1'b0;
    expect_d_translate(32'h0040_0123, 1'b0, 32'h0008_0123);
    if ((mem[mem_index(L0_BASE)][7:0] & PTE_A) == 8'd0)
        fail("load did not set A bit");
    if ((mem[mem_index(L0_BASE)][7:0] & PTE_D) != 8'd0)
        fail("load unexpectedly set D bit");
    expect_d_translate(32'h0040_0123, 1'b1, 32'h0008_0123);
    if ((mem[mem_index(L0_BASE)][7:0] & PTE_D) == 8'd0)
        fail("store did not set D bit");

    // 4KB instruction translation and 4MB megapage.
    expect_i_translate(32'h0040_1004, 32'h0008_2004);
    expect_i_translate(32'h0080_1234, 32'h0040_1234);

    // S-mode cannot access U page without SUM; with SUM+MXR, load may read X-only page.
    mstatus_mxr = 1'b1;
    mstatus_sum = 1'b0;
    expect_d_fault(32'h00C0_0020, 1'b0, CAUSE_LOAD_PAGE_FAULT);
    mstatus_sum = 1'b1;
    expect_d_translate(32'h00C0_0020, 1'b0, 32'h0009_0020);
    expect_i_fault(32'h00C0_0020);

    // Missing root PTE faults with correct load/store causes.
    expect_d_fault(32'h0100_0000, 1'b0, CAUSE_LOAD_PAGE_FAULT);
    expect_d_fault(32'h0100_0000, 1'b1, CAUSE_STORE_PAGE_FAULT);

    // SFENCE.VMA full flush makes a changed PTE visible.
    mstatus_mxr = 1'b0;
    mstatus_sum = 1'b0;
    mem[mem_index(L0_BASE + (32'd0 << 2))] = make_pte(22'h00081, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D);
    expect_d_translate(32'h0040_0123, 1'b0, 32'h0008_0123);
    pulse_sfence_all();
    expect_d_translate(32'h0040_0123, 1'b0, 32'h0008_1123);

    $display("========= Test PASS !!!");
    $finish;
end

endmodule
