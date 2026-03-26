# T12: Run BRAM-First CoreMark on Board

## Status: HARDWARE + COREMARK PORT REQUIRED

This task requires:
1. CoreMark ported (T9 - in progress)
2. Physical AX7203 board programmed (T8)
3. UART connected for result capture

## Prerequisites
- T9 complete: CoreMark compiled for AX7203
- T8 complete: Board programmed via JTAG
- USB-UART cable connected (CP2102)
- Serial terminal (PuTTY/minicom/screen) at 115200 8N1

## Steps

### 1. Load CoreMark BRAM Image
```bash
# Generate CoreMark COE
python fpga/scripts/generate_coe.py --coremark

# Create project with CoreMark
vivado -mode batch -source fpga/create_project_ax7203.tcl

# Build bitstream
vivado -mode batch -source fpga/build_ax7203_bitstream.tcl

# Program board
vivado -mode batch -source fpga/program_ax7203_jtag.tcl
```

### 2. Capture CoreMark Results
Open serial terminal at 115200 baud. Expected output:
```
AdamRiscv AX7203 Boot
CoreMark Benchmark
Iterations: 2000
Total Ticks: <X>
Checksum: <CRC>
CoreMark Score: <Y.YY>
CoreMark/MHz: <Z.ZZ>
```

### 3. Calculate Score
Expected performance:
- 50MHz core clock
- ~2000 iterations
- Target: 0.5-2.0 CoreMark/MHz (depending on optimization)

## Success Criteria
- [ ] CoreMark completes without crash
- [ ] Checksum validates correctly
- [ ] Score is reasonable for 50MHz RISC-V (reference: 25-100 CoreMark total)
- [ ] UART output captured to file

## Evidence Required
- [ ] UART log file: `coremark_results_ax7203.txt`
- [ ] Screenshot of terminal showing complete run
- [ ] Score calculation verification

## Blockers
- Requires T9 (CoreMark port)
- Requires T8 (board programming)
- Requires physical hardware

## Next Steps
Complete when T8, T9, T10 done and hardware available.
