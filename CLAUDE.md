# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Out-of-order dual-issue RV32I/M processor with 2-thread SMT, targeting Xilinx 7-series FPGA (AX7203 board). 8-stage pipeline: IF → FetchBuffer → DualDecode → Dispatch(Rename+IQ) → ReadOperand → Execute → Memory → WriteBack.

## Build & Test Commands

### Run all simulation tests (Icarus Verilog)
```bash
python verification/run_all_tests.py --basic          # 28 core tests
python verification/run_all_tests.py --riscv-tests     # 50 riscv-tests (auto-downloads)
python verification/run_all_tests.py --riscv-arch-test # 47 arch compliance tests
python verification/run_all_tests.py --all             # all suites
```

### Run a single test
```bash
cd verification
# Compile test assembly to hex
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -T ../rom/link.ld -o test.elf ../rom/test_name.s
riscv-none-elf-objcopy -O verilog --verilog-data-width=4 test.elf inst.hex
# Simulate with iverilog
iverilog -g2012 -o sim.vvp -I ../rtl ../comp_test/tb.sv ../rtl/*.v -DSIM_MODE
vvp sim.vvp
```

### FPGA synthesis (Vivado, AX7203)
```bash
python fpga/scripts/run_fpga_mainline_validation.py --port COM5
```

### Verilator simulation (WSL)
```bash
python fpga/scripts/run_verilator_mainline.py
```

## Test Verification

Tests write to TUBE address `0x1300_0000`: value `0x04` = PASS, anything else = FAIL. The testbench (`comp_test/tb.sv`) monitors this address and terminates simulation on write.

## Architecture — Key Modules

### Pipeline Data Path (in `rtl/`)
- **stage_if.v** — Fetch + BPU integration, per-thread PC select
- **fetch_buffer.v** — 16-entry FIFO, dual-pop for dual-decode
- **decoder_dual.v** — 2-wide decode with structural hazard detection (dual-branch, dual-mem, WAW)
- **dispatch_unit.v** — Central OoO engine: rename_map_table + freelist + 3×issue_queue (INT/MEM/MUL) + pipe1_arbiter + ROB allocation. ~3000 lines, most complex module
- **rob.v** — 16-entry reorder buffer, 2-stage pipelined commit
- **exec_pipe0.v** — ALU + branch resolution (port 0)
- **exec_pipe1.v** — ALU + MUL(3-cycle) + DIV(33-cycle) + AGU (port 1), selected by iq_pipe1_arbiter
- **phys_regfile.v** — 48-entry 4R2W PRF (32 arch + 16 rename per thread)

### Memory Subsystem
- **lsu_shell.v** — Load/Store Unit + D-TLB interface
- **store_buffer.v** — 32-entry with write coalescing
- **mem_subsys.v** — Central memory arbitration (ICache/DCache/RoCC → L2/RAM)
- **l1_dcache_m1.v** — 4KB 4-way write-back DCache
- **icache.v** — 8KB direct-mapped ICache
- **ddr3_mem_port.v** — Clock-domain crossing bridge (core↔DDR3 controller)

### Control
- **csr_unit.v** — Machine-mode CSRs + HPM counters (mhpmcounter3–9)
- **clint.v** / **plic.v** — Timer and external interrupt controllers
- **pc_mt.v** — Per-thread PC management for SMT

## Compile-Time Configuration

Key defines (passed via `-D` to iverilog/Vivado, set in `rtl/define.v`):

| Define | Purpose |
|--------|---------|
| `SMT_MODE` | 0=single-thread, 1=dual-thread SMT |
| `ENABLE_MEM_SUBSYS` | 0=legacy path, 1=full mem_subsys |
| `ENABLE_DDR3` | 1=DDR3 external memory |
| `L2_PASSTHROUGH` | 1=bypass L2, direct to RAM |
| `ENABLE_ROCC_ACCEL` | 1=enable RoCC AI accelerator |
| `FPGA_MODE` | 1=FPGA board, 0=simulation |
| `FPGA_SCOREBOARD_RS_DEPTH` | MEM issue queue depth (default 16) |

## Memory Map

| Address | Device |
|---------|--------|
| `0x0000_0000` | Instruction ROM / ICache |
| `0x0001_0000` | Data SRAM |
| `0x1200_0000` | UART TX/RX (MMIO) |
| `0x1300_0000` | TUBE (test output) |
| `0x1400_0000` | CLINT (timer) |
| `0x1500_0000` | PLIC (external IRQ) |
| `0x8000_0000+` | DDR3 (1GB, FPGA only) |

## Flush & Recovery

Branch mispredicts detected in exec_pipe0 trigger: epoch increment → flush fetch/decode/IQ → ROB speculative entries squashed → rename map table checkpoint restore → freelist recovery. All per-thread isolated in SMT mode.

## Current FPGA Baseline

25 MHz on AX7203, WNS=+0.448ns. Dhrystone: 2.74 DMIPS, IPC ~0.19. Major bottleneck is 81% issue bubbles (ROB window too small to hide DDR3 latency) and ~55% branch mispredict rate (bimodal BPU).
