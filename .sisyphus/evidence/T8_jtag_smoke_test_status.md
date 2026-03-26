# T8: JTAG Programming and Board Smoke Test

## Status: HARDWARE REQUIRED

This task requires physical access to the ALINX AX7203 board.

## Prerequisites
- ALINX AX7203 board powered on
- USB-JTAG cable connected (Xilinx Platform Cable USB II or compatible)
- Vivado hardware manager access

## Steps

### 1. Program via JTAG
```bash
cd fpga
vivado -mode batch -source program_ax7203_jtag.tcl
```

### 2. Smoke Test Verification
- **LED0**: Should toggle (heartbeat)
- **LED1**: Should be ON (boot complete)
- **LED[4:2]**: Core status indicators
- **UART**: Should see "AdamRiscv AX7203 Boot" message at 115200 baud

### 3. Evidence Collection
After successful programming, capture:
- [ ] Vivado programming log
- [ ] LED behavior video/photo
- [ ] UART output screenshot
- [ ] `fpga/program_jtag.log` generated

## Success Criteria
- JTAG programming completes without errors
- LEDs show expected patterns
- UART outputs boot message
- Board remains stable (no crashes)

## Blockers
- Physical hardware required
- Cannot be completed in simulation environment

## Next Steps
Complete T8 when hardware is available, then proceed to T11 (timing closure) and T12 (CoreMark on board).
