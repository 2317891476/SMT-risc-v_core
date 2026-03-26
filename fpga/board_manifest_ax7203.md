# AX7203 Board Manifest
# ALINX AX7203 FPGA Development Board Specification
# Primary Target: xc7a200t-2fbg484i (Board Realistic)
# Secondary Compare: xc7a200tfbg484-3 (User Requested)

## Board Identity
- Board Model: ALINX AX7203
- FPGA Device (Primary): XC7A200T-2FBG484I
- FPGA Device (Secondary Compare): XC7A200TFBG484-3
- Package: FBG484
- Speed Grade: -2 (Primary), -3 (Secondary)
- Temperature: Industrial (-40°C to 85°C)

## Clock Resources
- System Clock: 200MHz differential (SiT9102-200.00MHz)
  - Pins: SYS_CLK_P (R4), SYS_CLK_N (T4)
  - Bank: 34
- GTP Reference: 125MHz differential (SiT9102-125MHz)
  - Used for: PCIe/Transceivers (optional for bring-up)

## Memory Resources
- DDR3 SDRAM: 1GB (2x 512MB, 32-bit bus)
  - Speed: Up to 800Mbps (400MHz clock)
  - Banks: 34, 35
  - Voltage: 1.5V
- QSPI Flash: 16MB (W25Q256FVEI or equivalent)
  - Voltage: 3.3V
  - Purpose: FPGA configuration, persistent boot

## Communication Interfaces
- USB-UART: CP2102GM USB-to-UART bridge
  - Interface: Mini USB
  - Purpose: Debug console, CoreMark result capture
- JTAG: 10-pin 2.54mm standard header
  - Purpose: Programming and debug

## User I/O
- LEDs: 5 total
  - 1 on core board
  - 4 on expansion board
- Keys: 2 user keys + 1 reset key (on core board)
- Expansion: 2x 40-pin headers (2.54mm pitch, 34 IOs each)

## Power
- Input: 12V DC barrel jack (2.1 x 5.5mm)
- Max Current: 2A

## Signoff Policy
### Primary Target (MANDATORY for board bring-up)
- Part: xc7a200t-2fbg484i
- Purpose: Real AX7203 board validation
- Success Criteria:
  - Timing: setup WNS >= 0, hold WNS >= 0
  - Constraints: 0 unconstrained paths, 0 failing endpoints
  - Programming: JTAG download success
  - Boot: Flash persistent boot success
  - CoreMark: UART output with checksum, iterations, ticks, score

### Secondary Compare (OPTIONAL, for reference only)
- Part: xc7a200tfbg484-3
- Purpose: Comparative timing/utilization analysis
- Constraint: MUST NOT be used to claim AX7203 board success
- Output: Separate timing/utilization reports with explicit "compare-only" label

## First Milestone Strategy (BRAM-First)
- Storage for first bring-up: BRAM only
- DDR3: Out of scope for first success definition
- Memory initialization: via inst.hex/data.hex preload
- CoreMark: BRAM-first build, UART output

## Observability Contract
### UART Configuration
- Baud Rate: 115200
- Data: 8 bits
- Parity: None
- Stop: 1 bit
- Flow Control: None

### Output Formats
1. Smoke Test Banner:
   ```
   AdamRiscv AX7203 Boot
   SYS_CLK: 200MHz
   Status: OK
   ```

2. CoreMark Result Block (REQUIRED fields):
   ```
   CoreMark Benchmark
   Iterations: <N>
   Total Ticks: <T>
   Checksum: <CRC>
   CoreMark Score: <X.XX>
   CoreMark/MHz: <Y.YY>
   ```

### LED Semantics
- LED0 (Heartbeat): Toggle every 500ms when running
- LED1 (Boot Status): ON = boot complete, OFF = boot in progress
- LED2 (Test Pass): ON = test passed
- LED3 (Test Fail): ON = test failed

## Resource Allocation (First Milestone)
- Used: UART, LEDs, JTAG, QSPI, Clock/Reset
- Reserved (not in first milestone): DDR3, PCIe, HDMI, GTP, SD Card, EEPROM

## References
- AX7203B User Manual: https://alinx.com/public/upload/file/AX7203B_UG.pdf
- ALINX Product Page: https://www.en.alinx.com/detail/613
