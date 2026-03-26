# AX7203 Hardware Observability Contract
# Defines the minimum observability requirements for board bring-up

## Overview
This document specifies the observability interfaces required for AX7203 FPGA bring-up, validation, and CoreMark benchmarking.

## UART Configuration

### Serial Parameters
- **Baud Rate**: 115200
- **Data Bits**: 8
- **Parity**: None
- **Stop Bits**: 1
- **Flow Control**: None

### Hardware Interface
- **Connector**: Mini USB (USB-UART bridge: CP2102GM)
- **FPGA Pins**: To be defined in ax7203_uart_led.xdc
- **Voltage**: 3.3V LVCMOS

## LED Assignments

### LED0 - Heartbeat
- **Purpose**: Indicates the system is running
- **Behavior**: Toggle every 500ms (2Hz) when CPU is executing
- **Pattern**: Regular blink = OK; Stuck = possible hang

### LED1 - Boot Status
- **Purpose**: Indicates boot completion
- **Behavior**: 
  - OFF = Boot in progress
  - ON = Boot complete, system ready

### LED2 - Test Pass
- **Purpose**: Indicates successful test completion
- **Behavior**: ON when smoke test or CoreMark completes successfully

### LED3 - Test Fail
- **Purpose**: Indicates test failure
- **Behavior**: ON when smoke test or CoreMark fails

## Output Formats

### 1. Smoke Test Banner
Minimum required output on boot:
```
================================
AdamRiscv AX7203 Boot
================================
SYS_CLK: 200MHz
DDR: SKIP (BRAM mode)
UART: 115200 8N1
Status: OK
Test: Smoke
================================
```

### 2. CoreMark Result Block (MANDATORY Fields)
All of the following fields MUST be present in UART output:

```
================================
CoreMark Benchmark
================================
Iterations: <N>           (e.g., 1000)
Total Ticks: <T>          (CPU cycles or timer ticks)
Total Time: <S>s          (wall clock seconds, alternative to ticks)
Checksum: <CRC>           (CoreMark CRC, validates correct execution)
CoreMark Score: <X.XX>    (iterations/sec)
CoreMark/MHz: <Y.YY>      (normalized score)
Frequency: <F>MHz         (actual CPU frequency)
================================
PASS
================================
```

### Required Fields Checklist
- [ ] Iterations count
- [ ] Total Ticks OR Total Time
- [ ] Checksum (CoreMark CRC)
- [ ] CoreMark Score (iterations/sec)
- [ ] CoreMark/MHz (normalized)
- [ ] Frequency (MHz)
- [ ] PASS/FAIL indicator

### Invalid Output Examples (MUST REJECT)
```
CoreMark: PASS                    # Missing all data
Score: 1000                       # Missing checksum, context
Result: 1500 iterations/sec       # Missing CRC, frequency
```

## Evidence Collection

### UART Log Capture
All board tests must capture full UART output to:
`.sisyphus/evidence/task-{N}-{description}.uart.log`

### Log Validation Script
A validation script must parse the UART log and verify:
1. All required fields are present
2. Checksum is valid
3. Score is non-zero and reasonable (>0)
4. No ERROR/FAIL indicators (unless testing failure path)

### Timing Requirements
- Boot to banner: < 5 seconds
- CoreMark execution: depends on iterations (typically 10-60 seconds)
- UART timeout: 120 seconds maximum wait for result

## Pass/Fail Criteria

### Smoke Test Pass
- UART banner received within 5 seconds
- Heartbeat LED blinking
- Boot Status LED ON

### CoreMark Pass
- All required fields present in UART output
- Valid checksum
- Non-zero score
- No crash/hang during execution

### Board Bring-up Success
- JTAG programming: Device detected and programmed
- Flash programming: MCS written and verified
- Flash boot: Device boots without JTAG
- CoreMark: Valid score captured via UART

## Version Control
- Contract Version: 1.0
- Date: 2026-03-26
- Target: AX7203 BRAM-first bring-up
