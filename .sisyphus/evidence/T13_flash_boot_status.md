# T13: QSPI/Flash Persistent Boot

## Status: HARDWARE REQUIRED

This task requires programming the QSPI Flash on the AX7203 board.

## Prerequisites
- T8 complete: JTAG programming verified
- T11 complete: Timing-closed bitstream
- QSPI Flash: W25Q256FVEI (16MB)

## Steps

### 1. Generate Configuration Memory File
```bash
vivado -mode batch -source fpga/write_ax7203_cfgmem.tcl
```
Generates: `build/ax7203/adam_riscv_ax7203_primary.mcs`

### 2. Program Flash
```bash
vivado -mode batch -source fpga/program_ax7203_flash.tcl
```

### 3. Power Cycle Test
1. Disconnect JTAG
2. Power cycle board
3. Verify boot from Flash:
   - LEDs show boot pattern
   - UART shows "AdamRiscv AX7203 Boot"

### 4. Reboot Command
```bash
vivado -mode batch -source fpga/reboot_ax7203_after_flash.tcl
```

## Success Criteria
- [ ] Flash programming completes without errors
- [ ] Board boots from Flash after power cycle
- [ ] JTAG not required for subsequent boots
- [ ] Boot time < 5 seconds

## Evidence Required
- [ ] `fpga/program_flash.log` showing SUCCESS
- [ ] Video of power cycle boot
- [ ] UART capture showing successful boot from Flash

## Blockers
- Requires physical board
- Requires timing-closed bitstream (T11)

## Next Steps
Complete when T8 and T11 done and hardware available.
