`timescale 1ns/1ns

// RISCOF Testbench for AdamRiscv
// This testbench loads hex files, runs simulation, and extracts signature

module tb_riscof;

reg clk;
reg rst;

// Signature file path (passed via plusargs)
string signature_file;
integer signature_depth = 0;
reg [31:0] signature_mem [0:1023];
integer sig_ptr = 0;

// Memory instances
reg [7:0] inst_bytes [0:16383];
reg [7:0] data_bytes [0:16383];
reg [31:0] irom [0:4095];
reg [31:0] dram [0:4095];

// Instantiate DUT
adam_riscv u_dut (
    .sys_clk  (clk),
    .sys_rstn (rst)
);

// Clock generation
always #25 clk = ~clk;

// Initialize memories
initial begin
    integer i;
    
    // Initialize
    for (i = 0; i < 4096; i = i + 1) begin
        irom[i] = 32'd0;
        dram[i] = 32'd0;
    end
    
    // Load instruction hex
    if ($test$plusargs("signature")) begin
        $value$plusargs("signature=%s", signature_file);
        $display("Signature file: %s", signature_file);
    end
    
    // Read hex files
    $readmemh("inst.hex", inst_bytes);
    $readmemh("data.hex", data_bytes);
    
    // Convert bytes to words
    for (i = 0; i < 4096; i = i + 1) begin
        irom[i] = {inst_bytes[i*4+3], inst_bytes[i*4+2], inst_bytes[i*4+1], inst_bytes[i*4]};
        dram[i] = {data_bytes[i*4+3], data_bytes[i*4+2], data_bytes[i*4+1], data_bytes[i*4]};
    end
    
    // Initialize DUT memories
    for (i = 0; i < 4096; i = i + 1) begin
        u_dut.u_stage_if.u_inst_memory.u_ram_data.mem[i] = irom[i];
    end
    for (i = 0; i < 4096; i = i + 1) begin
        u_dut.u_stage_mem.u_data_memory.u_ram_data.mem[i] = dram[i];
    end
end

// Test sequence
initial begin
    clk = 1;
    rst = 0;
    #100 rst = 1;
    $display("RISCOF Test Started at time %0t", $time);
end

// Monitor for completion (write to TUBE address 0x13000000)
// In RISCOF tests, completion is typically indicated by writing to a signature region
// For now, we timeout after a reasonable number of cycles
initial begin
    #100000;  // 100us timeout
    
    // Write signature from DRAM[signature_start:signature_end]
    // RISCOF tests write signature to tohost region or specific memory location
    // For simplicity, dump DRAM starting from address 0x1000 (data segment)
    
    if (signature_file.len() > 0) begin
        integer fd;
        fd = $fopen(signature_file, "w");
        
        // Dump signature words (typically first 128 words of data segment)
        for (integer i = 0; i < 128; i = i + 1) begin
            $fdisplay(fd, "%h", u_dut.u_stage_mem.u_data_memory.u_ram_data.mem[1024 + i]);
        end
        $fclose(fd);
        $display("Signature written to %s", signature_file);
    end
    
    $display("RISCOF Test Completed at time %0t", $time);
    $finish;
end

// Wave dump (optional)
initial begin
    $dumpfile("tb_riscof.vcd");
    $dumpvars(0, tb_riscof);
end

endmodule
