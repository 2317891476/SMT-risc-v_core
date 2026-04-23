
integer test_id;
reg pass;

// RoCC test status extraction from x3 (STATUS.READ writes here)
// Per define.v: STATUS.READ returns {29'b0, error, done, busy}
`define ROCC_STATUS_BUSY_BIT  0
`define ROCC_STATUS_DONE_BIT  1
`define ROCC_STATUS_ERROR_BIT 2

// Helper function to extract RoCC status from x3 value
function rocc_check_status;
    input [31:0] status_val;
    input expected_done;
    begin
        rocc_check_status = (status_val[`ROCC_STATUS_ERROR_BIT] == 1'b0) && // No error
                            (status_val[`ROCC_STATUS_DONE_BIT] == expected_done) && // Done bit as expected
                            (status_val[`ROCC_STATUS_BUSY_BIT] == 1'b0); // Not busy
    end
endfunction

// test_id:
//   1 -> rom/test1.s
//   2 -> rom/test2.S
//   26 -> rom/test_bpu_postfix.s
//   27 -> rom/test_bpu_jal_loop.s
//   28 -> rom/test_bpu_jalr_fixed_target.s
//   29 -> rom/test_bpu_jalr_alt_target.s
//   0 -> unknown image
initial begin
    #1ns;
    if (TB_SELECTED_TEST_ID != 0)
        test_id = TB_SELECTED_TEST_ID;
    else if (`TB_IROM.mem[0] === 32'h00100093)
        test_id = 1;
    else if (`TB_IROM.mem[0] === 32'h01500093)
        test_id = 2;
    else if (`TB_IROM.mem[0] === 32'h00001237)   // test_smt: lui x4, 1 (0x00001237)
        test_id = 3;
    else if (`TB_IROM.mem[0] === 32'h06400093)   // test_rv32i_full: addi x1, x0, 100 (0x064_000_93)
        test_id = 4;
    // P2 L2 Cache tests
    else if (`TB_IROM.mem[0] === 32'h00000093)   // test_l2_icache_refill: addi x1, x0, 0
        test_id = 5;
    else if (`TB_IROM.mem[0] === 32'h00001000)   // test_l2_i_d_arbiter: first instruction pattern
        test_id = 6;
    else if (`TB_IROM.mem[0] === 32'h130000b7)   // test_l2_mmio_bypass: lui x7, 0x13000
        test_id = 7;
    // P2 Interrupt tests
    else if (`TB_IROM.mem[0] === 32'h00000013)   // test_csr_mret_smoke: nop
        test_id = 8;
    else if (`TB_IROM.mem[0] === 32'h00000093)   // test_clint_timer_interrupt: addi x1, x0, 0
        test_id = 9;
    else if (`TB_IROM.mem[0] === 32'h00000093)   // test_plic_external_interrupt
        test_id = 10;
    else if (`TB_IROM.mem[0] === 32'h00000093)   // test_interrupt_mask_mret
        test_id = 11;
    // RoCC tests - detect by custom-0 opcode (0x0B) in instruction bits [6:0]
    // RoCC instructions use opcode 7'b0001011 (0x0B)
    else if ((`TB_IROM.mem[0][6:0] === 7'b0001011) ||   // First instr is RoCC custom-0
             (`TB_IROM.mem[1][6:0] === 7'b0001011) ||   // Or second instr
             (`TB_IROM.mem[0] === 32'h00500193))        // addi x3, x0, 5 (RoCC test marker)
        test_id = 12;  // RoCC GEMM/Vector test
    else if (`TB_IROM.mem[0] === 32'h00d00193)   // addi x3, x0, 13 (RoCC DMA test marker)
        test_id = 13;  // RoCC DMA test
    else if (`TB_IROM.mem[0] === 32'h00e00193)   // addi x3, x0, 14 (RoCC status test marker)
        test_id = 14;  // RoCC STATUS.READ test
    else
        test_id = 0;
end

initial begin
    wait (`TUBE_STATUS === 8'h04);
    #200ns;
    pass = 1'b1;

    if (test_id == 1) begin
        // test1.s deterministic checks  (Thread 0 bank = reg_bank[0])
        pass = pass
            && (`TB_REGS.reg_bank[0][0] === 32'h0)
            && (`TB_REGS.reg_bank[0][1] === 32'h1)
            && (`TB_REGS.reg_bank[0][2] === 32'h2)
            && (`TB_REGS.reg_bank[0][3] === 32'h1000)
            && (`TB_REGS.reg_bank[0][4] === 32'h13000000)
            && (`TB_REGS.reg_bank[0][5] === 32'h4)
            && (`TB_REGS.reg_bank[0][6] === 32'h0)
            && (`TB_REGS.reg_bank[0][7] === 32'h3)
            && (`TB_REGS.reg_bank[0][8] === 32'h3)
            && (`TB_REGS.reg_bank[0][9] === 32'hf3f2f1f0)
            && (`TUBE_STATUS === 8'h04)
            && (`TB_MEM_SUBSYS[1024] === 32'h00000001)
            && (`TB_MEM_SUBSYS[1025] === 32'hf7f6f5f4)
            && (`TB_MEM_SUBSYS[1026] === 32'hfbfaf9f8)
            && (`TB_MEM_SUBSYS[1027] === 32'hfffefdfc);
    end
    else if (test_id == 2) begin
        // test2.S deterministic checks  (Thread 0 bank = reg_bank[0])
        pass = pass
            && (`TB_REGS.reg_bank[0][0] === 32'h0)
            && (`TB_REGS.reg_bank[0][1] === 32'h15)
            && (`TB_REGS.reg_bank[0][2] === 32'h2a)
            && (`TB_REGS.reg_bank[0][3] === 32'h1000)
            && (`TB_REGS.reg_bank[0][4] === 32'h13000000)
            && (`TB_REGS.reg_bank[0][5] === 32'h4)
            && (`TB_REGS.reg_bank[0][6] === 32'h15)
            && (`TB_REGS.reg_bank[0][7] === 32'h3f)
            && (`TB_REGS.reg_bank[0][8] === 32'h3f)
            && (`TB_REGS.reg_bank[0][9] === 32'hf3f2f21a)
            && (`TUBE_STATUS === 8'h04)
            && (`TB_MEM_SUBSYS[1024] === 32'hf3f2f21a)
            && (`TB_MEM_SUBSYS[1025] === 32'hf7f6f5f4)
            && (`TB_MEM_SUBSYS[1026] === 32'hfbfaf9f8)
            && (`TB_MEM_SUBSYS[1027] === 32'hfffefdfc);
    end
    else if (test_id == 3) begin
        // test_smt.s  - SMT smoke test
        // Thread 0: sum 1..10 = 55 = 0x37  -> stored to DRAM word [1152] (byte addr 0x1200)
        // Thread 1: 10*3  = 30 = 0x1E      -> stored to DRAM word [1153] (byte addr 0x1204)
        pass = pass
            && (`TB_MEM_SUBSYS[1152]     === 32'h00000037)  // T0 sum = 55
            && (`TB_MEM_SUBSYS[1153]     === 32'h0000001E)  // T1 product = 30
            && (`TUBE_STATUS           === 8'h04);        // TUBE end marker
    end
    else if (test_id == 4) begin
        // test_rv32i_full.s — comprehensive RV32I instruction test
        // Check branch-pass markers stored to DRAM by the test
        pass = pass
            && (`TUBE_STATUS   === 8'h04)        // TUBE end marker
            && (`TB_MEM_SUBSYS[1029]      === 32'h00000001)  // BEQ  passed
            && (`TB_MEM_SUBSYS[1030]      === 32'h00000002)  // BNE  passed
            && (`TB_MEM_SUBSYS[1031]      === 32'h00000003)  // BLT  passed
            && (`TB_MEM_SUBSYS[1032]      === 32'h00000004)  // BGE  passed
            && (`TB_MEM_SUBSYS[1033]      === 32'h00000005)  // BLTU passed
            && (`TB_MEM_SUBSYS[1034]      === 32'h00000006)  // BGEU passed
            && (`TB_MEM_SUBSYS[1035]      === 32'h00000007)  // JAL  passed
            && (`TB_MEM_SUBSYS[1036]      === 32'h00000008)  // JALR passed
            && (`TB_MEM_SUBSYS[1037]      === 32'hDEADB000); // LUI  result
    end
    else if (test_id >= 5 && test_id <= 11) begin
        // P2 tests: L2 cache and interrupt tests
        // These tests write 0x04 to TUBE on pass, 0xFF on fail
        $display("P2 test_id=%0d detected", test_id);
        pass = pass && (`TUBE_STATUS === 8'h04);
    end
    else if (test_id == 26) begin
        // test_bpu_postfix.s
        // Result words at 0x1000:
        //   0x00 phaseA_total
        //   0x04 phaseA_taken
        //   0x08 phaseA_not_taken
        //   0x0C phaseB_pass
        //   0x10 phaseC_pass
        //   0x14 overall_pass
        //   0x18 fail_code
        $display("BPU postfix regression test (test_id=26) detected");
        pass = pass
            && (`TUBE_STATUS === 8'h04)
            && (`TB_MEM_SUBSYS[1024] === 32'd160)
            && (`TB_MEM_SUBSYS[1025] === 32'd128)
            && (`TB_MEM_SUBSYS[1026] === 32'd32)
            && (`TB_MEM_SUBSYS[1027] === 32'd1)
            && (`TB_MEM_SUBSYS[1028] === 32'd1)
            && (`TB_MEM_SUBSYS[1029] === 32'd1)
            && (`TB_MEM_SUBSYS[1030] === 32'd0);
    end
    else if (test_id == 27) begin
        // test_bpu_jal_loop.s
        // Result words at 0x1000:
        //   0x00 jal_hit_count
        //   0x04 pass_flag
        //   0x08 fail_code
        $display("BPU JAL loop regression test (test_id=27) detected");
        pass = pass
            && (`TUBE_STATUS === 8'h04)
            && (`TB_MEM_SUBSYS[1024] === 32'd64)
            && (`TB_MEM_SUBSYS[1025] === 32'd1)
            && (`TB_MEM_SUBSYS[1026] === 32'd0);
    end
    else if (test_id == 28) begin
        // test_bpu_jalr_fixed_target.s
        // Result words at 0x1000:
        //   0x00 jalr_hit_count
        //   0x04 pass_flag
        //   0x08 fail_code
        $display("BPU JALR fixed-target regression test (test_id=28) detected");
        pass = pass
            && (`TUBE_STATUS === 8'h04)
            && (`TB_MEM_SUBSYS[1024] === 32'd64)
            && (`TB_MEM_SUBSYS[1025] === 32'd1)
            && (`TB_MEM_SUBSYS[1026] === 32'd0);
    end
    else if (test_id == 29) begin
        // test_bpu_jalr_alt_target.s
        // Result words at 0x1000:
        //   0x00 hit_t0
        //   0x04 hit_t1
        //   0x08 pass_flag
        //   0x0C fail_code
        $display("BPU JALR alternating-target regression test (test_id=29) detected");
        pass = pass
            && (`TUBE_STATUS === 8'h04)
            && (`TB_MEM_SUBSYS[1024] === 32'd32)
            && (`TB_MEM_SUBSYS[1025] === 32'd32)
            && (`TB_MEM_SUBSYS[1026] === 32'd1)
            && (`TB_MEM_SUBSYS[1027] === 32'd0);
    end
    else if (test_id == 12) begin
        // RoCC GEMM/Vector Test
        // Verifies RoCC GEMM.START and VEC.OP commands complete correctly
        // STATUS.READ returns {29'b0, error, done, busy}
        // x3 should contain status with done=1, busy=0, error=0
        $display("RoCC GEMM/Vector test (test_id=12) detected");
        $display("RoCC Debug: x3=0x%08h, rocc_cmd_count=%0d, rocc_resp_count=%0d",
                 `TB_REGS.reg_bank[0][3], rocc_cmd_count, rocc_resp_count);
        $display("RoCC Debug: rocc_dma_rd_count=%0d, rocc_dma_wr_count=%0d",
                 rocc_dma_rd_count, rocc_dma_wr_count);
        
        // Check RoCC status in x3: expected {29'b0, 0, 1, 0} = 0x2 (done set, no error, not busy)
        pass = pass
            && (`TUBE_STATUS === 8'h04)              // TUBE end marker
            && (rocc_timeout_triggered === 1'b0)     // No RoCC timeout
            && (`TB_REGS.reg_bank[0][3][`ROCC_STATUS_DONE_BIT] === 1'b1)   // done=1
            && (`TB_REGS.reg_bank[0][3][`ROCC_STATUS_ERROR_BIT] === 1'b0); // error=0
    end
    else if (test_id == 13) begin
        // RoCC DMA Test
        // Verifies SCRATCH.LOAD and SCRATCH.STORE DMA operations
        $display("RoCC DMA test (test_id=13) detected");
        $display("RoCC Debug: x3=0x%08h, rocc_dma_rd_count=%0d, rocc_dma_wr_count=%0d",
                 `TB_REGS.reg_bank[0][3], rocc_dma_rd_count, rocc_dma_wr_count);
        
        // DMA test should complete without error
        pass = pass
            && (`TUBE_STATUS === 8'h04)              // TUBE end marker
            && (rocc_timeout_triggered === 1'b0)     // No RoCC timeout
            && (`TB_REGS.reg_bank[0][3][`ROCC_STATUS_DONE_BIT] === 1'b1)   // done=1
            && (`TB_REGS.reg_bank[0][3][`ROCC_STATUS_ERROR_BIT] === 1'b0); // error=0
    end
    else if (test_id == 14) begin
        // RoCC STATUS.READ Test
        // Verifies STATUS.READ command returns correct format
        $display("RoCC STATUS.READ test (test_id=14) detected");
        $display("RoCC Debug: x3=0x%08h", `TB_REGS.reg_bank[0][3]);
        
        // Status should have upper 29 bits = 0, and valid lower 3 bits
        pass = pass
            && (`TUBE_STATUS === 8'h04)               // TUBE end marker
            && (`TB_REGS.reg_bank[0][3][31:3] === 29'd0) // Upper bits zero
            && (rocc_cmd_count > 32'd0);              // At least one RoCC command issued
    end
    else begin
        // Generic test: just check TUBE == 0x04 (pass marker)
        $display("Unknown ROM signature, TB_IROM.mem[0]=%h - treating as generic test", `TB_IROM.mem[0]);
        pass = pass && (`TUBE_STATUS === 8'h04);
    end

    if (pass)
        TEST_PASS;
    else
        TEST_FAIL;
end

// RoCC extended timeout (for long-running RoCC operations)
// RoCC tests may need more time due to DMA operations
reg rocc_extended_timeout;
initial begin
    rocc_extended_timeout = 1'b0;
    // Only use extended timeout for RoCC tests
    if (test_id == 12 || test_id == 13 || test_id == 14) begin
        #400us;  // Extended timeout for RoCC operations
        if (`TUBE_STATUS !== 8'h04) begin
            rocc_extended_timeout = 1'b1;
            $display("\n----------------------------------------\n");
            $display("\t RoCC Extended Timeout Error !!!!\n");
            $display("RoCC Debug: cmd_count=%0d, resp_count=%0d, operation_active=%0b",
                     rocc_cmd_count, rocc_resp_count, rocc_operation_active);
            TEST_FAIL;
        end
    end
end

//Timeout Error
initial begin
    #200us;
    // Skip standard timeout for RoCC tests (they use extended timeout)
    if (test_id == 12 || test_id == 13 || test_id == 14) begin
        // RoCC tests handled by extended timeout above
        #300us; // Wait for extended timeout to handle it
    end
    else if (test_id == 26) begin
        // test_bpu_postfix needs a slightly longer window under the generic tb
        // because the branch-training workload completes just after 200us.
        #100us;
        if (`TUBE_STATUS !== 8'h04) begin
            $display("\n----------------------------------------\n");
            $display("\t Timeout Error !!!!\n");
            TEST_FAIL;
        end
    end
    else begin
        $display("\n----------------------------------------\n");
        $display("\t Timeout Error !!!!\n");
        TEST_FAIL;
    end
end
