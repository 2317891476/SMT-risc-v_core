# AdamRiscv Debug Wiki

This wiki is the required living record for the AX7203 single-thread bring-up. Keep it synchronized under the R1 rule in `AGENTS.md` and `CLAUDE.md`.

## Quick Card

- Active baseline: single-thread RV32IM/OoO AX7203 debug flow. Do not restore SMT.
- Board: AX7203, `xc7a200tfbg484-2`, core clock 25 MHz, UART 115200 8N1 on COM5.
- Required Vivado: 2023.2 via `E:\Xilinx\Vivado\2023.2\bin\vivado.bat`.
- Do not use Vivado 2024.2 for this repo unless the user explicitly changes the rule.
- Verilator mainline is invoked through WSL by `python fpga/scripts/run_verilator_mainline.py`; do not use an ad hoc Windows-native Verilator command.
- Required debug order after RTL edits: Icarus first, WSL Verilator second, Vivado/JTAG/COM5 board validation last.
- Generated output policy: `build/`, `.Xil/`, VCDs, Vivado logs/journals, crash dumps, and bitstreams are generated and should not be committed.

## Current Debug Stage

Status as of 2026-05-21 20:49 +08:00:

- SMT removal/single-thread RTL debugging is past the basic simulation bring-up stage.
- Basic Icarus regressions and FPGA-config directed tests have passed in the current debug line, including UART16550/PLIC source 2 and long store-buffer tests.
- A 16550A-compatible UART subset exists at `0x1300_1000`, while the legacy UART window remains available.
- PLIC has been extended to keep source 1 for the existing external interrupt and use source 2 for UART IRQ.
- Loader long simulation with 32-byte blocks passed after the branch-complete duplicate-pulse fix.
- Vivado 2023.2 synthesis completed and wrote `build\ax7203\checkpoints\adam_riscv_ax7203_post_synth.dcp`.
- Current blocker: Vivado 2023.2 implementation is failing at process/tool level with `The system cannot find the path specified` during place/route or incremental reuse, before a fresh bitstream with the latest RTL fix is produced.
- Board Dhrystone is not yet validated with the latest RTL. Old bitstreams do not contain the latest branch-complete fix and should not be used as proof of current status.

## Standard Commands

```powershell
python verification\run_all_tests.py --basic
python verification\run_all_tests.py --basic --fpga-config
python verification\run_all_tests.py --tests test_uart16550_polling test_uart16550_plic_irq test_store_buffer_simple --fpga-config
python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 1 --dcache-mode read-only --mock-latency 1
python fpga\scripts\run_verilator_mainline.py --mode loader-semantic --benchmark dhrystone --runs 1 --dcache-mode read-only --mock-latency 1
```

```powershell
& 'E:\Xilinx\Vivado\2023.2\bin\vivado.bat' -mode batch -source fpga\run_ax7203_synth.tcl
& 'E:\Xilinx\Vivado\2023.2\bin\vivado.bat' -mode batch -source fpga\impl_aggressive.tcl
```

Board run after a fresh bitstream exists:

```powershell
python fpga\scripts\run_fpga_benchmark_ddr3.py --benchmark dhrystone --port COM5 --rs-depth 48 --fetch-buffer-depth 16 --core-clk-mhz 25.0 --fpga-impl-mode board-only --capture-seconds 240
```

## Wiki Map

- `concepts/architecture-evolution.md`: SMT removal and single-thread architecture state.
- `concepts/timing-closure.md`: timing constraints, known reports, and current implementation blocker.
- `concepts/routing-congestion.md`: placement/routing observations and congestion triage.
- `concepts/resource-estimation.md`: utilization tracking and resource tradeoffs.
- `concepts/ram-mapping-tradeoff.md`: LUTRAM/BRAM/MMI tradeoffs and ROM loader init caveats.
- `concepts/slr-layout.md`: layout notes; AX7203 Artix-7 has no SLR partitioning.
- `concepts/simulation.md`: Icarus/Verilator/Vivado simulation status.
- `concepts/rtl-coding-rules.md`: coding rules for single-thread RTL and debug instrumentation.
- `concepts/vivado-tooling.md`: Vivado 2023.2 flow, OOC/incremental flow, environment issues.
- `concepts/asic-extrapolation.md`: FPGA-to-ASIC caveats.
- `concepts/rtl-asic-port.md`: RTL portability notes.
- `devlog/2026-05.md`: append-only current-month debug log.

## Timeline

- 2026-05-21: User locked AX7203 implementation flow to Vivado 2023.2 despite 2024.2 also being installed.
- 2026-05-21: User clarified the mandatory debug ladder: Icarus, then WSL Verilator through the repo script, then real AX7203 board validation via Vivado JTAG.
- 2026-05-21: Vivado 2023.2 synthesis succeeded after reverting temporary dispatch debug ports that had triggered a synth crash.
- 2026-05-21: Branch-complete duplicate pulse in FPGA scoreboard path was fixed; loader long sim passed, but fresh bitstream is still pending.
- 2026-05-21: 16550A-compatible UART subset and PLIC source 2 are already in the active debug baseline.
