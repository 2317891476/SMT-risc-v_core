# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Out-of-order dual-issue RV32I/M processor with 2-thread SMT, targeting Xilinx 7-series FPGA on the ALINX AX7203 board (`XC7A200T-2FBG484I`). The core uses an 8-stage pipeline:

```text
IF -> FetchBuffer -> DualDecode -> Dispatch(Rename+IQ) -> ReadOperand -> Execute -> Memory -> WriteBack
```

The current project focus is single-thread FPGA board validation and Dhrystone reproducibility after removing SMT behavior from the active debug baseline. Basic Icarus regressions are passing, the 16550A-compatible UART subset and PLIC source 2 are implemented, and the current blocker is producing and validating a fresh AX7203 bitstream with the latest RTL fixes. Do not restore SMT as a shortcut.

## R1 Wiki Synchronization Rule

R1 is mandatory for every coding/debugging agent working in this repository.

Wiki sync triggers:

- Any change to `rtl/`, `rom/`, `comp_test/`, `verification/`, `fpga/`, constraints, Tcl flow, benchmark loader scripts, or board automation must update `wiki/` in the same turn.
- Any durable debug discovery must update `wiki/`, even when no source file changes. Examples: root cause, ruled-out hypothesis, new failing PC, new Vivado/tool failure mode, JTAG/UART behavior, timing/resource result, or board build ID.
- Update `wiki/INDEX.md` when project status, quick commands, environment assumptions, or current blockers change.
- Update the relevant `wiki/concepts/*.md` page when an architectural, timing, memory, simulation, or tool-flow lesson changes.
- Append to the current `wiki/devlog/YYYY-MM.md` entry in reverse chronological order. Devlogs are append-only: do not rewrite old entries except to fix typos that do not change meaning.
- Treat wiki and documentation updates as GitHub submission material. Whenever `wiki/`, `AGENTS.md`, `CLAUDE.md`, `README*`, `docs/`, or other project documentation changes, include those files in the same Git/GitHub commit or PR as the related RTL/script/debug change. If commits or pushes are not authorized in the current turn, explicitly report the documentation files that must be included in the next GitHub submission.

R1 anti-patterns:

- Do not say "sync later", "document later", or leave wiki updates for another agent.
- Do not record only generated log paths without the conclusion they support.
- Do not claim board or benchmark status from stale files; include timestamps/build IDs when the distinction matters.
- Do not update wiki/docs locally and then omit them from the GitHub commit/PR for the same change.
- Do not use Vivado 2024.2 for this AX7203 flow unless the user explicitly changes the rule. This repo is to be implemented with Vivado 2023.2 for consistency.
- Do not hide failed hypotheses. Mark them as ruled out with the evidence that ruled them out.

If a source change truly does not affect the wiki, state that explicitly in the final response and explain why.

## Current Environment Warnings

- Use Vivado 2023.2 for AX7203 synthesis, implementation, bitstream generation, and JTAG. The machine also has Vivado 2024.2 installed, but this project must stay on 2023.2 unless the user explicitly says otherwise.
- Prefer the explicit binary path `E:\Xilinx\Vivado\2023.2\bin\vivado.bat` when running Vivado from automation or shell commands.
- Earlier Vivado 2023.2 implementation attempts failed at the process level with `The system cannot find the path specified` during place/route or incremental reuse database creation. Treat that exact signature as an environment/tool-flow failure until a current Tcl log proves an RTL/DRC/timing failure.
- The latest Vivado 2023.2 incremental Dhrystone attempt passed reuse DB creation and failed in placement with `failed to commit all instances`; treat that as an incremental placement/congestion failure, not as a Dhrystone RTL functional failure.
- When retrying Vivado implementation, use explicit `-log`/`-journal` paths and a short local `TEMP`/`TMP` such as `build\vivado_tmp` to avoid overwritten logs and path-related failures.
- Verilator mainline is a WSL flow. Use `python fpga/scripts/run_verilator_mainline.py`; it calls `wsl.exe` and checks WSL-side `verilator`, `make`, and `g++`. Do not invent a Windows-native Verilator flow. On 2026-05-24, `wsl.exe -l -v` shows `Ubuntu-22.04 Running`, and the wrapper finds Verilator 5.046 at `/usr/local/bin/verilator`, `/usr/bin/make`, and `/usr/bin/g++`.
- COM5 is the expected CP210x UART for AX7203 board work. Only one process can own COM5; close terminals and stale Python scripts before board automation.

## Dhrystone Debug Loop

The current short-term target is Dhrystone. This loop overrides generic FPGA bring-up habits:

1. Run WSL Verilator Dhrystone first:

   ```powershell
   python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 1 --loader-rom-profile board --benchmark-runtime-profile board --max-cycles 600000000 --require-board-config-match
   python fpga\scripts\run_verilator_mainline.py --mode loader-semantic --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 1 --loader-rom-profile board --benchmark-runtime-profile board --payload-start-gap-cycles 2500 --payload-gap-cycles 2500 --payload-chunk-gap-cycles 40000 --max-cycles 2000000000 --require-board-config-match
   ```

2. Board-equivalent Verilator Dhrystone gates must report `BoardConfigMatch: True` in `summary.txt`/`summary.json`. The checked baseline is `SMT_MODE=0`, DDR3/mem_subsys enabled, RS depth 48, fetch buffer depth 16, 25 MHz core clock, 115200 UART, `AX7203_DCACHE_MODE=read-only`, `LOADER_ROM_PROFILE=board`, `BENCHMARK_RUNTIME_PROFILE=board`, `DHRYSTONE_RUNS=5000`, and loader-semantic host pacing `payload_start_gap=2500`, `payload_gap=2500`, `payload_chunk_gap=40000`. Do not treat `SIM_FAST_STORE_DRAIN`, `--loader-rom-profile sim-fast`, `--benchmark-runtime-profile verilator-fast`, short Dhrystone runs, or fast loader host pacing as board-equivalent evidence. The config summary should be written before WSL-side tool checks so a missing WSL environment cannot hide a board-profile mismatch.
3. Only after both Verilator gates pass, run Vivado 2023.2 incremental implementation.
4. `--fpga-impl-mode incremental` must fail closed; do not automatically fall back to aggressive implementation.
5. If incremental implementation fails twice in a row, stop retrying Vivado and return to the Verilator boundary matrix in `wiki/concepts/simulation.md`.
6. Bitstream download to AX7203 must use Vivado JTAG, normally through `fpga/program_ax7203_jtag.tcl` or a board script that calls it.

## Current Repository State

- Mainline branch: `main`, synced to `origin/main`.
- Legacy gitlink/submodule references `boom_ref`, `cva6_ref`, and `opentitan_ref` have been removed from the main branch.
- `tomasulo` remains as a local/remote branch but the active baseline is `main`.
- Do not assume old helper scripts exist if they were generated during an earlier session and then discarded; verify file existence before referencing them.

## Build & Test Commands

### Run simulation tests (Icarus Verilog)

```bash
python verification/run_all_tests.py --basic          # core regression
python verification/run_all_tests.py --riscv-tests     # riscv-tests suite
python verification/run_all_tests.py --riscv-arch-test # arch compliance suite
python verification/run_all_tests.py --all             # all suites
```

### Run a single assembly test

```bash
cd verification
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -T ../rom/link.ld -o test.elf ../rom/test_name.s
riscv-none-elf-objcopy -O verilog --verilog-data-width=4 test.elf inst.hex
iverilog -g2012 -o sim.vvp -I ../rtl ../comp_test/tb.sv ../rtl/*.v -DSIM_MODE
vvp sim.vvp
```

### FPGA mainline validation (AX7203)

```bash
python fpga/scripts/run_fpga_mainline_validation.py --port COM5
```

This runs the board-oriented regression chain and writes logs under:

```text
build/fpga_mainline_validation/
```

### Vivado FPGA flow

```bash
& 'E:\Xilinx\Vivado\2023.2\bin\vivado.bat' -mode batch -source fpga/create_project_ax7203.tcl
& 'E:\Xilinx\Vivado\2023.2\bin\vivado.bat' -mode batch -source fpga/run_ax7203_synth.tcl
& 'E:\Xilinx\Vivado\2023.2\bin\vivado.bat' -mode batch -source fpga/impl_incremental.tcl
& 'E:\Xilinx\Vivado\2023.2\bin\vivado.bat' -mode batch -source fpga/program_ax7203_jtag.tcl
```

`impl_incremental.tcl` is the current Dhrystone debug implementation flow after Verilator passes. `impl_aggressive.tcl` is reserved for explicit signoff or when the documented fallback loop allows it.

### Verilator simulation (WSL)

```bash
python fpga/scripts/run_verilator_mainline.py
```

## Test Verification

Simulation tests write to TUBE address `0x1300_0000`: value `0x04` = PASS, anything else = FAIL. The testbench (`comp_test/tb.sv`) monitors this address and terminates simulation on write.

On FPGA, UART is the main observation channel:

```text
COM5, 115200 baud, 8 data bits, no parity, 1 stop bit, no flow control
```

Only one process can own COM5 at a time. Close PuTTY/Tera Term/etc. before running Python UART scripts, and close Python scripts before opening a third-party terminal.

## Architecture — Key Modules

### Pipeline Data Path (`rtl/`)

- `stage_if.v` — Fetch + BPU integration, per-thread PC select.
- `fetch_buffer.v` — 16-entry FIFO, dual-pop for dual-decode.
- `decoder_dual.v` — 2-wide decode with structural hazard detection.
- `dispatch_unit.v` — Central OoO engine: rename map table + freelist + INT/MEM/MUL issue queues + pipe1 arbiter + ROB allocation. This is the most complex module.
- `rob.v` — 16-entry reorder buffer, 2-stage pipelined commit.
- `exec_pipe0.v` — ALU + branch resolution.
- `exec_pipe1.v` — ALU + MUL + DIV + AGU.
- `phys_regfile.v` — 48-entry, 4R2W physical register file.

### Memory Subsystem

- `lsu_shell.v` — Load/store shell + D-TLB interface.
- `store_buffer.v` — 32-entry store buffer with write coalescing.
- `mem_subsys.v` — ICache/DCache/RoCC arbitration toward L2/RAM/DDR3.
- `l1_dcache_m1.v` — 4 KB 4-way write-back L1 DCache.
- `icache.v` — 8 KB direct-mapped ICache in the current non-FPGA-large configuration; FPGA-specific values are controlled by compile-time parameters/branches.
- `ddr3_mem_port.v` — CDC bridge between 25 MHz core clock and MIG `ui_clk` domain.

### Control and Interrupts

- `csr_unit.v` — Machine-mode CSRs. Some Dhrystone signoff builds disable extended HPM counters to reduce timing/resource pressure.
- `clint.v` / `plic.v` — Timer and external interrupt controllers.
- `pc_mt.v` — Per-thread PC management for SMT.

## Compile-Time Configuration

Key defines passed via iverilog/Vivado and configured in `rtl/define.v`:

| Define | Purpose |
|--------|---------|
| `SMT_MODE` | 0=single-thread, 1=dual-thread SMT |
| `ENABLE_MEM_SUBSYS` | 0=legacy path, 1=full memory subsystem |
| `ENABLE_DDR3` | 1=enable AX7203 DDR3 path |
| `L2_PASSTHROUGH` | 1=bypass L2 and go directly to RAM/DDR3 path |
| `ENABLE_ROCC_ACCEL` | 1=enable RoCC AI accelerator |
| `FPGA_MODE` | 1=FPGA board build, 0=simulation build |
| `FPGA_SCOREBOARD_RS_DEPTH` | FPGA issue queue / RS depth knob |
| `FPGA_FETCH_BUFFER_DEPTH` | FPGA fetch buffer depth knob |
| `FPGA_UART_CLK_DIV` | UART divider; 25 MHz core uses 217 for 115200 baud |

Preserve the soft separation between FPGA-trimmed configuration and large simulation configuration. Do not remove the FPGA/simulation branches just to simplify code.

## Memory Map

| Address | Device |
|---------|--------|
| `0x0000_0000` | Instruction ROM / ICache backing |
| `0x0001_0000` | Data SRAM / scratch region |
| `0x1200_0010` | UART TXDATA MMIO |
| `0x1200_0014` | UART STATUS MMIO |
| `0x1300_0000` | TUBE / board status MMIO |
| `0x1400_0000` | CLINT |
| `0x1500_0000` | PLIC |
| `0x8000_0000+` | DDR3 payload / benchmark region |

## FPGA Board Baseline

Reference timing/resource signoff should use:

```text
build/ax7203_dhrystone_noHPM_backup_0x69E8BEAF/reports/
BUILD_ID = 0x69E8BEAF
```

Important signoff numbers from that build:

| Metric | Value |
|--------|------:|
| WNS | +0.276 ns |
| TNS | 0.000 ns |
| Setup failing endpoints | 0 |
| WHS | +0.031 ns |
| THS | 0.000 ns |
| Hold failing endpoints | 0 |
| Slice LUTs | 68,007 / 133,800 = 50.83% |
| LUT as Logic | 62,804 = 46.94% |
| LUT as Memory | 5,203 = 11.26% |
| Slice Registers | 95,943 / 269,200 = 35.64% |
| DSPs | 4 / 740 = 0.54% |
| Block RAM Tile | 0 / 365 = 0.00% |

Worst global timing path is an async reset release path:

```text
por_rst_n_reg/C -> u_adam_riscv/post_lock_ready_reg/CLR
```

Worst core-domain synchronous paths are in dispatch/IQ/MEM candidate selection and still meet the 25 MHz target. Do not treat L1D or OoO core datapaths as the primary timing blockers unless a current report proves otherwise.

## Dhrystone Board Run Status

The validated board Dhrystone flow is **UART loader mode**:

1. BRAM ROM contains `rom/test_fpga_ddr3_loader.s`.
2. The host uploads `build/benchmark_images/dhrystone/dhrystone_ddr3.bin` over UART.
3. The loader writes the payload to DDR3 at `0x8000_0000`.
4. The loader emits `LOAD_OK` and `JUMP`, then jumps to the Dhrystone entry point.
5. The Dhrystone runtime prints results over UART.

### Critical ROM rule

Before synthesis/implementation for a Dhrystone loader bitstream, ensure:

```bash
python fpga/scripts/build_rom_image.py --asm rom/test_fpga_ddr3_loader.s --merge-mem-subsys
```

This regenerates:

```text
rom/inst.hex
rom/data.hex
rom/mem_subsys_ram.hex
```

The loader `rom/inst.hex` is approximately 15.7 KB / 1280 instructions. If `rom/inst.hex` is only a few hundred bytes or corresponds to `test_fpga_ddr3_mainline.s` / CSR tests, the bitstream will not respond to the Dhrystone loader protocol.

After changing `rom/inst.hex`, Vivado must re-read the memory initialization. Safest path:

```text
Reset Implementation -> Run Synthesis -> Run Implementation -> Generate Bitstream -> Program Device
```

### One-command Dhrystone run

```bash
python build/run_dhrystone_board.py COM5 120
```

This script owns COM5, uploads the payload, captures UART, decodes loader beacons, parses Dhrystone text, and writes:

```text
build/dhrystone_board_direct_uart.txt          # passthrough text
build/dhrystone_board_direct_uart.bin          # raw UART bytes
build/dhrystone_board_direct_uart.decoded.txt  # loader beacon event decode
```

The script does not read old result text to fake output. It opens serial with pyserial, resets input/output buffers, reads `ser.read(4096)` in a loop, and overwrites the three output files when the run completes. If the script is interrupted before final write, stale files can remain; check file modification time or delete the files before rerunning.

### UART loader protocol summary

The board emits 5-byte beacon frames:

```text
A5 seq type arg xor
xor = A5 ^ seq ^ type ^ arg
```

Important event types:

| Type | Meaning |
|------|---------|
| `0x01` | READY |
| `0x02` | LOAD_START |
| `0x11` | BLOCK_ACK |
| `0x12` | BLOCK_NACK |
| `0x21` | READ_OK |
| `0x22` | LOAD_OK |
| `0x23` | JUMP |
| `0xE1` | BAD_MAGIC |
| `0xE2` | CHECKSUM_FAIL |
| `0xE3` | READBACK_FAIL |
| `0xE8` | SIZE_TOO_BIG |
| `0xEF` | TRAP |

Host sends a 20-byte little-endian header:

```text
u32 magic      = 0x314B4D42  # BMK1
u32 load_addr  = 0x80000000
u32 entry      = 0x80000000
u32 size_bytes = payload size
u32 checksum32 = sum(payload bytes) mod 2^32
```

Payload is sent in 4-byte chunks, grouped into 64-byte blocks. The board replies with:

```text
0x06  PAYLOAD_ACK
0x17  BLOCK_ACK
0x15  BLOCK_NACK
```

This is a custom protocol, not XMODEM/YMODEM/Kermit. Third-party serial terminals can observe output but cannot upload the payload unless they implement this protocol.

### Reset behavior

In loader mode, pressing board reset restarts the BRAM loader. It does **not** automatically rerun the Dhrystone payload in DDR3. To rerun Dhrystone, upload the payload again with the host script.

Default Dhrystone payloads can finish too quickly for manual PuTTY capture. For manual observation, build a longer payload:

```bash
python fpga/scripts/build_benchmark_image.py dhrystone --dhrystone-runs 1000000 --cpu-hz 25000000
```

## Known Bottlenecks and Next Optimization Direction

Board Dhrystone is functional, but IPC is still limited by microarchitectural pressure:

- Issue bubbles are high because ROB/PRF/IQ windows are small relative to DDR3 latency.
- Bimodal BPU misprediction rate is a major IPC limiter on Dhrystone-like control flow.
- Current resource utilization leaves enough FPGA headroom for BPU upgrades and modest ROB/PRF/IQ expansion.

Recommended optimization order:

1. Upgrade branch prediction (`bpu_bimodal.v` -> larger bimodal/gshare/RAS-lite).
2. Expand ROB and PRF windows.
3. Expand MEM IQ after ROB/PRF changes.
4. Consider moving cache/tag/data arrays from LUTRAM to BRAM if LUT pressure rises.
5. Pipeline dispatch/IQ long chains if pushing beyond 25 MHz.

## Safety / Workflow Notes for Claude

- Prefer current reports over remembered numbers. If citing timing/resource data, read the relevant report under `build/.../reports/` first.
- Do not destructively reset or clean the repo unless the user explicitly approves.
- Do not assume `rom/inst.hex` still matches the desired profile; inspect or rebuild it before FPGA synthesis.
- Do not claim PuTTY/third-party terminal can trigger Dhrystone. It can only observe unless the payload has already been uploaded.
- Do not commit unless the user explicitly asks.
