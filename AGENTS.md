# Repository Guidelines

## Project Structure & Module Organization

AdamRiscv is an RV32I/M out-of-order dual-issue core that is currently being debugged as a single-thread AX7203 FPGA target. The long-term project goal is a full-stack, competition-grade and industrial-grade dual-issue out-of-order pipeline processor core that can boot Linux and run benchmark/test programs with high performance. `rtl/` contains synthesizable core modules such as `adam_riscv.v`, pipeline stages, ROB, caches, CSR, CLINT/PLIC, and UART blocks. `comp_test/` holds SystemVerilog testbenches and simulator support. `rom/` stores bare-metal assembly tests and linker scripts used to generate `inst.hex` and `data.hex`. `verification/` contains Python regression runners and RISCOF setup. `fpga/` contains AX7203 top modules, constraints, Vivado Tcl flow, and UART/benchmark automation. `wiki/` is the required living design/debug record. `benchmarks/`, `docs/`, and `libs/` hold benchmark ports, design notes, and behavioral RAM models. Treat `build/`, `.Xil/`, `*.vcd`, Vivado logs, and crash dumps as generated outputs.

## Build, Test, and Development Commands

- `python verification/run_all_tests.py --basic`: compile ROM tests and run the Icarus Verilog basic regression.
- `python verification/run_all_tests.py --basic --fpga-config`: run basic tests with FPGA-matching simulation defines.
- `python verification/run_all_tests.py --tests test_div_basic test_store_buffer_simple`: run selected basic tests.
- `python verification/run_all_tests.py --riscv-tests`: run the classic RISC-V ISA suite; dependencies may be downloaded.
- `python verification/run_all_tests.py --riscv-arch-test`: run official architecture tests.
- `python fpga/scripts/run_verilator_mainline.py`: run the Verilator mainline flow through WSL. The script invokes `wsl.exe` and expects `verilator`, `make`, and `g++` inside WSL; see the README Verilator section for maintained examples.
- `& 'E:\Xilinx\Vivado\2023.2\bin\vivado.bat' -mode batch -source fpga/impl_aggressive.tcl`: preferred AX7203 implementation flow.

## Coding Style & Naming Conventions

Follow the existing Verilog/SystemVerilog style: 4-space indentation, `snake_case` signals and modules, uppercase parameters/macros, and active-low reset names ending in `_n`. Keep compile-time controls in `rtl/define.v` or explicit script defines. Prefer focused modules and avoid unrelated formatting churn in large RTL files.

## Testing Guidelines

Add directed assembly tests as `rom/test_<feature>.s` and matching testbenches as `comp_test/tb_<feature>.sv` when needed. Tests should signal PASS/FAIL through the existing testbench convention rather than relying on manual waveform inspection. Run `--basic` before submitting RTL changes, and add `--fpga-config` for memory subsystem or AX7203-facing changes. Use `-v` for failed regressions and preserve only minimal logs needed for debugging.

## Required Debug Flow

For RTL-affecting work, use this order unless the user explicitly narrows the task:

1. Icarus Verilog regression first. Start with the smallest relevant directed test, then run `python verification/run_all_tests.py --basic`, and add `--fpga-config` for memory subsystem, AX7203, UART, DDR3, or FPGA-facing changes.
2. Verilator mainline second. Run it through the repository Python wrapper, not a hand-written Windows-native command. The wrapper uses WSL:

   ```powershell
   python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 1 --dcache-mode read-only --mock-latency 1
   python fpga\scripts\run_verilator_mainline.py --mode loader-semantic --benchmark dhrystone --runs 1 --dcache-mode read-only --mock-latency 1
   ```

   If WSL Verilator is unavailable, report that as an environment blocker instead of silently skipping this step.

3. FPGA board validation last. Only after Icarus and Verilator pass, run Vivado 2023.2 synthesis/implementation and download the bitstream over Vivado JTAG. Board validation should use the AX7203 scripts and COM5 UART capture unless the user specifies a different port.

Plain Icarus debug flow:

```powershell
python verification\run_all_tests.py --tests test_name -v
python verification\run_all_tests.py --tests test_name --fpga-config -v
```

Manual Icarus fallback for a specific generated ROM:

```powershell
iverilog -g2012 -DTEST_ID=1 -s tb -o comp_test\out_iverilog\bin\tb_test1.out -I rtl -I comp_test rtl\*.v libs\REG_ARRAY\SRAM\ram_bfm.v comp_test\tb.sv
cd comp_test
vvp out_iverilog\bin\tb_test1.out
```

Run `vvp` from `comp_test\` when using ROM files generated under `rom\`, otherwise relative ROM loads can fail.

## Commit & Pull Request Guidelines

Recent history uses short imperative summaries, sometimes with subsystem context, such as `Enhance ROB and IF stages`. Keep commits focused and state the behavioral change. Pull requests should describe touched RTL/test areas, list exact commands run and results, note FPGA board status when relevant, and link issues or waveform/log excerpts for bugs.

## Agent-Specific Instructions

Before editing shared RTL, check `git status` and avoid overwriting unrelated local changes. Do not commit generated artifacts from `build/`, `.Xil/`, Vivado journals/logs, VCDs, or crash dumps.

## R1 Wiki Synchronization Rule

R1 is mandatory for every coding/debugging agent working in this repository.

Wiki sync triggers:

- Any change to `rtl/`, `rom/`, `comp_test/`, `verification/`, `fpga/`, constraints, Tcl flow, benchmark loader scripts, or board automation must update `wiki/` in the same turn.
- Any durable debug discovery must update `wiki/`, even when no source file changes. Examples: root cause, ruled-out hypothesis, new failing PC, new Vivado/tool failure mode, JTAG/UART behavior, timing/resource result, or board build ID.
- Update `wiki/INDEX.md` when project status, quick commands, environment assumptions, or current blockers change.
- Update the relevant `wiki/concepts/*.md` page when an architectural, timing, memory, simulation, or tool-flow lesson changes.
- Append to the current `wiki/devlog/YYYY-MM.md` entry in reverse chronological order. Devlogs are append-only: do not rewrite old entries except to fix typos that do not change meaning.

R1 anti-patterns:

- Do not say "sync later", "document later", or leave wiki updates for another agent.
- Do not record only generated log paths without the conclusion they support.
- Do not claim board or benchmark status from stale files; include timestamps/build IDs when the distinction matters.
- Do not use Vivado 2024.2 for this AX7203 flow unless the user explicitly changes the rule. This repo is to be implemented with Vivado 2023.2 for consistency.
- Do not hide failed hypotheses. Mark them as ruled out with the evidence that ruled them out.

If a source change truly does not affect the wiki, state that explicitly in the final response and explain why.

## Current Environment Warnings

- Use Vivado 2023.2 for AX7203 synthesis, implementation, bitstream generation, and JTAG. The machine also has Vivado 2024.2 installed, but this project must stay on 2023.2 unless the user explicitly says otherwise.
- Prefer the explicit binary path `E:\Xilinx\Vivado\2023.2\bin\vivado.bat` when running Vivado from automation or shell commands.
- AX7203 bitstream download must use Vivado JTAG mode, normally through `fpga/program_ax7203_jtag.tcl` or the board automation scripts that call it.
- Recent Vivado 2023.2 implementation attempts have failed at the process level with `The system cannot find the path specified` during place/route or incremental reuse database creation. Treat that as an environment/tool-flow failure until a current Tcl log proves an RTL/DRC/timing failure.
- When retrying Vivado implementation, use explicit `-log`/`-journal` paths and a short local `TEMP`/`TMP` such as `build\vivado_tmp` to avoid overwritten logs and path-related failures.
- Verilator mainline is a WSL flow. Use `python fpga/scripts/run_verilator_mainline.py`; it calls `wsl.exe` and checks for WSL-side `verilator`, `make`, and `g++`. Do not invent a Windows-native Verilator flow.
- COM5 is the expected CP210x UART for AX7203 board work. Only one process can own COM5; close terminals and stale Python scripts before board automation.
