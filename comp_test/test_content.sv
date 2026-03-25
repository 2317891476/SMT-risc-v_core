
integer test_id;
reg pass;

// test_id:
//   1 -> rom/test1.s
//   2 -> rom/test2.S
//   0 -> unknown image
initial begin
    #1ns;
    if (`TB_IROM.mem[0] === 32'h00100093)
        test_id = 1;
    else if (`TB_IROM.mem[0] === 32'h01500093)
        test_id = 2;
    else if (`TB_IROM.mem[0] === 32'h00001237)   // test_smt: lui x4, 1 (0x00001237)
        test_id = 3;
    else if (`TB_IROM.mem[0] === 32'h06400093)   // test_rv32i_full: addi x1, x0, 100 (0x064_000_93)
        test_id = 4;
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
            && (`TB_DRAM.mem[1024] === 32'h00000001)
            && (`TB_DRAM.mem[1025] === 32'hf7f6f5f4)
            && (`TB_DRAM.mem[1026] === 32'hfbfaf9f8)
            && (`TB_DRAM.mem[1027] === 32'hfffefdfc);
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
            && (`TB_DRAM.mem[1024] === 32'hf3f2f21a)
            && (`TB_DRAM.mem[1025] === 32'hf7f6f5f4)
            && (`TB_DRAM.mem[1026] === 32'hfbfaf9f8)
            && (`TB_DRAM.mem[1027] === 32'hfffefdfc);
    end
    else if (test_id == 3) begin
        // test_smt.s  - SMT smoke test
        // Thread 0: sum 1..10 = 55 = 0x37  -> stored to DRAM word [1152] (byte addr 0x1200)
        // Thread 1: 10*3  = 30 = 0x1E      -> stored to DRAM word [1153] (byte addr 0x1204)
        pass = pass
            && (`TB_DRAM.mem[1152]     === 32'h00000037)  // T0 sum = 55
            && (`TB_DRAM.mem[1153]     === 32'h0000001E)  // T1 product = 30
            && (`TUBE_STATUS           === 8'h04);        // TUBE end marker
    end
    else if (test_id == 4) begin
        // test_rv32i_full.s — comprehensive RV32I instruction test
        // Debug output
        $display("test_rv32i_full Debug:");
        $display("DRAM[1029] BEQ  = %h, expected 0x01", `TB_DRAM.mem[1029]);
        $display("DRAM[1030] BNE  = %h, expected 0x02", `TB_DRAM.mem[1030]);
        $display("DRAM[1031] BLT  = %h, expected 0x03", `TB_DRAM.mem[1031]);
        $display("DRAM[1032] BGE  = %h, expected 0x04", `TB_DRAM.mem[1032]);
        $display("DRAM[1033] BLTU = %h, expected 0x05", `TB_DRAM.mem[1033]);
        $display("DRAM[1034] BGEU = %h, expected 0x06", `TB_DRAM.mem[1034]);
        $display("DRAM[1035] JAL  = %h, expected 0x07", `TB_DRAM.mem[1035]);
        $display("DRAM[1036] JALR = %h, expected 0x08", `TB_DRAM.mem[1036]);
        $display("DRAM[1037] LUI  = %h, expected 0xDEADB000", `TB_DRAM.mem[1037]);
        // Check branch-pass markers stored to DRAM by the test
        pass = pass
            && (`TUBE_STATUS   === 8'h04)        // TUBE end marker
            && (`TB_DRAM.mem[1029]      === 32'h00000001)  // BEQ  passed
            && (`TB_DRAM.mem[1030]      === 32'h00000002)  // BNE  passed
            && (`TB_DRAM.mem[1031]      === 32'h00000003)  // BLT  passed
            && (`TB_DRAM.mem[1032]      === 32'h00000004)  // BGE  passed
            && (`TB_DRAM.mem[1033]      === 32'h00000005)  // BLTU passed
            && (`TB_DRAM.mem[1034]      === 32'h00000006)  // BGEU passed
            && (`TB_DRAM.mem[1035]      === 32'h00000007)  // JAL  passed
            && (`TB_DRAM.mem[1036]      === 32'h00000008)  // JALR passed
            && (`TB_DRAM.mem[1037]      === 32'hDEADB000); // LUI  result
    end
    else begin
        // Generic test: just check DRAM[0] == 0x04 (pass marker)
        $display("Unknown ROM signature, TB_IROM.mem[0]=%h - treating as generic test", `TB_IROM.mem[0]);
        pass = pass && (`TUBE_STATUS === 8'h04);
    end

    if (pass)
        TEST_PASS;
    else
        TEST_FAIL;
end

//Timeout Error
initial begin
    #200us;
    $display("\n----------------------------------------\n");
    $display("\t Timeout Error !!!!\n");
    TEST_FAIL;
end
