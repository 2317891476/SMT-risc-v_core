# Repository Guidelines

## Project Structure & Module Organization

SifangCore: A RISC-V Processor Core is an RV32I/M out-of-order dual-issue core that is currently being debugged as a single-thread AX7203 FPGA target. The long-term project goal is a full-stack, competition-grade and industrial-grade dual-issue out-of-order pipeline processor core that can boot Linux and run benchmark/test programs with high performance. `rtl/` contains synthesizable core modules such as `sifang_core.v`, pipeline stages, ROB, caches, CSR, CLINT/PLIC, and UART blocks. `comp_test/` holds SystemVerilog testbenches and simulator support. `rom/` stores bare-metal assembly tests and linker scripts used to generate `inst.hex` and `data.hex`. `verification/` contains Python regression runners and RISCOF setup. `fpga/` contains AX7203 top modules, constraints, Vivado Tcl flow, and UART/benchmark automation. `software/linux/` contains the Linux/OpenSBI/initramfs bring-up staging flow. `wiki/` is the required living design/debug record. `benchmarks/`, `docs/`, and `libs/` hold benchmark ports, design notes, and behavioral RAM models. Treat `build/`, `.Xil/`, `*.vcd`, Vivado logs, and crash dumps as generated outputs.

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
   python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 1 --loader-rom-profile board --benchmark-runtime-profile board --max-cycles 600000000 --require-board-config-match
   python fpga\scripts\run_verilator_mainline.py --mode loader-semantic --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 1 --loader-rom-profile board --benchmark-runtime-profile board --payload-start-gap-cycles 2500 --payload-gap-cycles 2500 --payload-chunk-gap-cycles 40000 --max-cycles 2000000000 --require-board-config-match
   ```

   The loader-semantic gate needs explicit host pacing and a large cycle budget because the board-profile loader intentionally waits through block ACK pacing, final store-drain delays, and board-runtime UART delays before and after the benchmark loop.

   Dhrystone Verilator runs must report whether their configuration matches the current AX7203 board-test baseline: `SMT_MODE=0`, `ENABLE_MEM_SUBSYS=1`, `ENABLE_DDR3=1`, `L2_PASSTHROUGH=1`, `RS_DEPTH=48`, `FETCH_BUFFER_DEPTH=16`, 25 MHz core clock, 115200 UART, `AX7203_DCACHE_MODE=read-only`, `LOADER_ROM_PROFILE=board`, `BENCHMARK_RUNTIME_PROFILE=board`, `DHRYSTONE_RUNS=5000`, and loader-semantic host pacing `payload_start_gap=2500`, `payload_gap=2500`, `payload_chunk_gap=40000`. Use `--loader-rom-profile board`, `--benchmark-runtime-profile board`, and `--require-board-config-match` for board-equivalent gates; this forbids treating a `SIM_FAST_STORE_DRAIN` loader image, C runtime fast path, short Dhrystone run, or fast host pacing as board-ready evidence. The wrapper must write the board-config summary before checking WSL-side tools, so configuration mistakes remain visible even when Verilator itself is unavailable. Boundary runs that intentionally vary a parameter, such as `--dcache-mode full`, `--loader-rom-profile sim-fast`, `--benchmark-runtime-profile verilator-fast`, short Dhrystone run count, or fast loader pacing, must leave the mismatch visible in `summary.txt`/`summary.json` rather than pretending to be board-equivalent.

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

## Dhrystone Debug Loop

The current short-term target is Dhrystone. For Dhrystone work, this loop overrides the generic debug order above:

1. Run WSL Verilator Dhrystone first. Both preload and loader-semantic modes must pass before attempting FPGA implementation:

   ```powershell
   python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 1 --loader-rom-profile board --benchmark-runtime-profile board --max-cycles 600000000 --require-board-config-match
   python fpga\scripts\run_verilator_mainline.py --mode loader-semantic --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 1 --loader-rom-profile board --benchmark-runtime-profile board --payload-start-gap-cycles 2500 --payload-gap-cycles 2500 --payload-chunk-gap-cycles 40000 --max-cycles 2000000000 --require-board-config-match
   ```

2. If Verilator fails, rerun the failing command with `--trace-on-stuck`, inspect `build/verilator/mainline/.../summary.txt` and `summary.json`, fix the RTL/root cause, then run the relevant Icarus directed/basic/`--fpga-config` tests before retrying Verilator.
3. Only after the Verilator gates pass, enter Vivado 2023.2 incremental implementation:

   ```powershell
   python fpga\scripts\run_fpga_benchmark_ddr3.py --benchmark dhrystone --port COM5 --rs-depth 48 --fetch-buffer-depth 16 --core-clk-mhz 25.0 --fpga-impl-mode incremental --capture-seconds 240
   ```

4. If incremental implementation fails once, inspect the current logs and make the smallest environment or RTL fix justified by evidence, then retry once. `--fpga-impl-mode incremental` must fail closed; do not auto-fallback to aggressive implementation from the benchmark script.
5. If incremental implementation fails twice in a row, stop retrying Vivado and fall back to the Verilator boundary matrix:

   ```powershell
   python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 7 --loader-rom-profile board --benchmark-runtime-profile board --max-cycles 1200000000 --require-board-config-match
   python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 5000 --dcache-mode full --mock-latency 1 --benchmark-runtime-profile board --max-cycles 600000000
   python fpga\scripts\run_verilator_mainline.py --mode loader-semantic --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 7 --loader-rom-profile board --benchmark-runtime-profile board --payload-start-gap-cycles 2500 --payload-gap-cycles 2500 --payload-chunk-gap-cycles 40000 --max-cycles 3000000000 --require-board-config-match
   ```

   All boundary runs must pass before returning to incremental implementation. Reset the consecutive incremental failure count only after this Verilator matrix passes. The `full` dcache row is a deliberate non-board-equivalent stress run; its summary must show the dcache mismatch.

## Linux Bring-up Flow

The Linux target is MMU Linux, not NoMMU: `RV32IMA_Zicsr_Zifencei`, S-mode, Sv32, OpenSBI, Linux, and a BusyBox initramfs. Do not claim Linux support from bare-metal Dhrystone or from an image that bypasses S-mode/Sv32.

Linux work is staged:

1. Keep Dhrystone green first. After any RTL change made for Linux, rerun the relevant Icarus directed tests, `--basic`, `--basic --fpga-config`, and the board-equivalent WSL Verilator Dhrystone gates before attempting Linux-specific Verilator runs.
2. Validate Linux prerequisites with directed tests before building images:
   ```powershell
   python verification\run_all_tests.py --tests test_priv_mret_sret_delegation test_amo_lrsc test_plic_s_context_uart_irq test_sbi_timer_injection test_sv32_core_identity --fpga-config
   python verification\run_riscv_tests.py --suite riscv-tests --categories rv32ua
   ```
3. Build Linux staging artifacts through WSL only:
   ```bash
   bash software/linux/scripts/build_linux_payload.sh
   ```
   The staging script may emit DTB/initramfs without a bootable `fw_payload.bin`. Treat `fw_payload.bin` as valid only after the OpenSBI/Linux/BusyBox source/config gate is explicitly enabled and the file is produced under `build/linux/`.
4. First Linux execution gate is Verilator preload:
   ```powershell
   python fpga\scripts\run_verilator_mainline.py --mode linux-preload --linux-payload build\linux\fw_payload.bin --dcache-mode read-only --mock-latency 1 --require-board-config-match
   ```
   Passing requires UART tokens `OpenSBI`, `Boot HART ID: 0`, `Linux version`, `Run /init as init process`, and `SIFANGCORE LINUX PASS`, with no trap/stuck/unexpected UART.
5. Only after `linux-preload` passes may AX7203 Linux board validation start. Use Vivado 2023.2 JTAG and COM5 UART, and fall back to Verilator traces on failure instead of iterating blindly in Vivado.

Current Linux blockers to keep visible until fixed: precise fetch/load/store page faults are not fully plumbed to CSR at ROB commit, and PTW hardware A/D writeback needs a CPU-cache coherence policy before Linux can rely on reading updated PTEs through cached paths.

Do not run `verification/run_all_tests.py`, `verification/run_riscv_tests.py`, or other ROM-generating simulations in parallel unless their output directories are isolated. The current runners rewrite shared `rom/inst.hex` and `rom/data.hex`; parallel runs can create false regressions.

## Commit & Pull Request Guidelines

Recent history uses short imperative summaries, sometimes with subsystem context, such as `Enhance ROB and IF stages`. Keep commits focused and state the behavioral change. Pull requests should describe touched RTL/test areas, list exact commands run and results, note FPGA board status when relevant, and link issues or waveform/log excerpts for bugs.

Wiki and documentation updates are part of the deliverable. Whenever `wiki/`, `AGENTS.md`, `CLAUDE.md`, `README*`, `docs/`, or other project documentation is changed, include those files in the same Git/GitHub submission as the related RTL/script/debug change. If the user has authorized staging, committing, pushing, or PR creation, stage and submit the documentation together with the related change. If commits or pushes are not authorized in the current turn, explicitly report the documentation files that must be included in the next GitHub commit/PR; do not silently leave wiki/docs as local-only changes.

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
- Treat wiki and documentation changes as GitHub submission material. They must travel with the same commit/PR as the code or debug conclusion they document, or be called out explicitly as pending documentation files when the user has not authorized a commit/push.

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
- AX7203 bitstream download must use Vivado JTAG mode, normally through `fpga/program_ax7203_jtag.tcl` or the board automation scripts that call it.
- Recent Vivado 2023.2 implementation attempts have failed at the process level with `The system cannot find the path specified` during place/route or incremental reuse database creation. Treat that as an environment/tool-flow failure until a current Tcl log proves an RTL/DRC/timing failure.
- When retrying Vivado implementation, use explicit `-log`/`-journal` paths and a short local `TEMP`/`TMP` such as `build\vivado_tmp` to avoid overwritten logs and path-related failures.
- Verilator mainline is a WSL flow. Use `python fpga/scripts/run_verilator_mainline.py`; it calls `wsl.exe` and checks for WSL-side `verilator`, `make`, and `g++`. Do not invent a Windows-native Verilator flow. On 2026-05-24, `wsl.exe -l -v` shows `Ubuntu-22.04 Running`, and the wrapper finds Verilator 5.046 at `/usr/local/bin/verilator`, `/usr/bin/make`, and `/usr/bin/g++`.
- COM5 is the expected CP210x UART for AX7203 board work. Only one process can own COM5; close terminals and stale Python scripts before board automation.
