# SifangCore Debug Wiki

This wiki is the required living record for the AX7203 single-thread bring-up. Keep it synchronized under the R1 rule in `AGENTS.md` and `CLAUDE.md`.

## Quick Card

- Active baseline: single-thread RV32IM/OoO AX7203 debug flow. Do not restore SMT.
- Project identity: SifangCore: A RISC-V Processor Core. Source identifiers use `sifang_core`; no legacy compatibility entrypoints are kept.
- Board: AX7203, `xc7a200tfbg484-2`, core clock 25 MHz, UART 115200 8N1 on COM5.
- Required Vivado: 2023.2 via `E:\Xilinx\Vivado\2023.2\bin\vivado.bat`.
- Do not use Vivado 2024.2 for this repo unless the user explicitly changes the rule.
- Verilator mainline is invoked through WSL by `python fpga/scripts/run_verilator_mainline.py`; do not use an ad hoc Windows-native Verilator command.
- Board-equivalent Verilator Dhrystone runs must report `BoardConfigMatch: True` against the AX7203 board-test baseline: RS depth 48, fetch buffer depth 16, 25 MHz, 115200 UART, SMT disabled, DDR3 enabled, read-only dcache, loader ROM profile `board`, benchmark runtime profile `board`, Dhrystone 5000 runs, and loader-semantic host pacing `2500/2500/40000`.
- Required debug order after RTL edits: Icarus first, WSL Verilator second, Vivado/JTAG/COM5 board validation last.
- Current Dhrystone target uses a stricter loop: WSL Verilator Dhrystone first, then Vivado 2023.2 incremental implementation. Two consecutive incremental failures force a return to the Verilator boundary matrix.
- Linux target: MMU Linux through `RV32IMA_Zicsr_Zifencei`, S-mode, Sv32, OpenSBI, Linux, and BusyBox initramfs. NoMMU Linux and bare-metal Dhrystone are not Linux support evidence.
- Linux first execution gate is WSL Verilator `--mode linux-preload` with `build\linux\fw_payload.bin`; board validation comes only after UART shows OpenSBI, Linux, `/init`, and `SIFANGCORE LINUX PASS`.
- Wiki and documentation updates must be included in the same GitHub commit/PR as the related code or debug change; if no commit/push is authorized, list the pending documentation files explicitly.
- Generated output policy: `build/`, `.Xil/`, VCDs, Vivado logs/journals, crash dumps, and bitstreams are generated and should not be committed.
- Do not run ROM-generating regressions in parallel unless their output paths are isolated; current runners share `rom/inst.hex` and `rom/data.hex`.

## Current Debug Stage

Status as of 2026-05-26 +08:00:

- Linux bring-up has started. Implemented and tested prerequisites: S-mode CSR/trap/delegation, SRET/MRET privilege transitions, RV32A AMO/LRSC, PLIC UART source 2 through S-context, and OpenSBI-style STIP injection into S-mode timer interrupt.
- New Linux staging files live under `software/linux/`: AX7203 DTB, minimal initramfs `/init`, and a WSL build script that currently emits DTB/initramfs staging artifacts and intentionally gates full `fw_payload.bin` generation until OpenSBI/Linux/BusyBox source/configs are ready.
- Current Linux blockers: I/D translation, the `mem_subsys` PTW endpoint, commit-ordered full-flush `sfence.vma`, precise ROB-commit fetch/load/store page-fault delivery, and board-baseline PTW A/D cache visibility are integrated. Remaining blockers are full `fw_payload.bin` production, then OpenSBI/Linux token bring-up under `linux-preload`, plus the newly exposed `rv32si` gaps below.
- Verification on 2026-05-26 after PTW A/D snoop-invalidate wiring and riscv-tests supervisor adapter repair: `test_sv32_translation`, `test_sv32_page_faults`, and `test_sfence_vma` pass under `--fpga-config`; Linux directed tests including `test_sv32_core_identity`, `test_sv32_core_page_fault`, and `test_sv32_core_fetch_page_fault` pass 7/7 under `--fpga-config`; `--basic` and `--basic --fpga-config` both pass 44/44; `rv32ua` riscv-tests pass 10/10; `rv32si` now builds and runs with 4/6 passing.
- `rv32si` status: `csr`, `sbreak`, `scall`, and `wfi` pass. The previous harness blocker was missing `zicsr` in `-march` plus missing supervisor adapter constants and an incorrect `MPP=M` S-mode entry. Remaining failures are `dirty` and `ma_fetch`, which are now real architecture bring-up targets: MPRV/Sv32 A/D behavior and instruction-address-misaligned/fetch trap behavior.
- Board-equivalent WSL Verilator Dhrystone after PTW A/D snoop-invalidate wiring passes in both 5000-run modes: preload has `BoardConfigMatch=True`, `PreloadBenchmarkPass=True`, no trap/stuck/unexpected UART, and `Cycles=28837429`; loader-semantic has `BoardConfigMatch=True`, `LoaderSemanticPass=True`, 128 block ACKs, `DHRYSTONE DONE`, no trap/stuck/unexpected UART, and `Cycles=166376270`.
- The repository is being fully renamed to SifangCore. RTL, FPGA top modules, RISCOF plugin names, Tcl/Python default stems, documentation, and UART boot banners now use `sifang_core` / `SifangCore`.
- SMT removal/single-thread RTL debugging is past the basic simulation bring-up stage.
- Basic Icarus regressions and FPGA-config directed tests have passed in the current debug line, including UART16550/PLIC source 2 and long store-buffer tests.
- A 16550A-compatible UART subset exists at `0x1300_1000`, while the legacy UART window remains available.
- PLIC has been extended to keep source 1 for the existing external interrupt and use source 2 for UART IRQ.
- Loader long simulation with 32-byte blocks passed after the branch-complete duplicate-pulse fix.
- Vivado 2023.2 synthesis completed and wrote `build\ax7203\checkpoints\sifang_core_ax7203_post_synth.dcp`.
- WSL Verilator is available again after the Ubuntu-22.04 distro was started externally. `wsl.exe -l -v` now shows `Ubuntu-22.04 Running`, and the wrapper finds Verilator 5.046, `make`, and `g++`.
- The latest fresh bitstream is build ID `0x6A12D692`, generated by Vivado 2023.2 incremental implementation, with timing met (`WNS=0.292`, `WHS=0.051`). Vivado JTAG programmed/read back both USERCODE and USR_ACCESS as `0x6A12D692`.
- Current board status: board-only validation of bitstream `0x6A12D692` passes. Vivado 2023.2 JTAG readback matches, UART loader smoke reaches `DHRYSTONE DONE`, and the 5000-run baseline reaches `DHRYSTONE DONE`.
- Current Verilator status: board-equivalent 5000-run preload and loader-semantic gates pass with `BoardConfigMatch=True`, `BENCHMARK_RUNTIME_PROFILE=board`, no trap, no unexpected UART, no stuck PC, and `DHRYSTONE DONE`.
- Post-rename board status: SifangCore bitstream `0x6A132BA3` was generated with Vivado 2023.2 aggressive implementation (`WNS=+0.403`, `WHS=+0.051`). Board-only validation passed over Vivado JTAG and COM5 UART: USR_ACCESS/USERCODE matched `0x6A132BA3`, loader summary mask was `0x1F`, and both smoke and 5000-run baseline reached `DHRYSTONE DONE`.

## Standard Commands

```powershell
python verification\run_all_tests.py --basic
python verification\run_all_tests.py --basic --fpga-config
python verification\run_all_tests.py --tests test_priv_mret_sret_delegation test_amo_lrsc test_plic_s_context_uart_irq test_sbi_timer_injection test_sv32_core_identity test_sv32_core_page_fault test_sv32_core_fetch_page_fault --fpga-config
python verification\run_all_tests.py --tests test_sv32_translation test_sv32_page_faults test_sfence_vma --fpga-config -v
python verification\run_riscv_tests.py --suite riscv-tests --categories rv32ua
python verification\run_riscv_tests.py --suite riscv-tests --categories rv32si
python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 1 --loader-rom-profile board --benchmark-runtime-profile board --max-cycles 600000000 --require-board-config-match
python fpga\scripts\run_verilator_mainline.py --mode loader-semantic --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 1 --loader-rom-profile board --benchmark-runtime-profile board --payload-start-gap-cycles 2500 --payload-gap-cycles 2500 --payload-chunk-gap-cycles 40000 --max-cycles 2000000000 --require-board-config-match
python fpga\scripts\run_verilator_mainline.py --mode linux-preload --linux-payload build\linux\fw_payload.bin --dcache-mode read-only --mock-latency 1 --require-board-config-match
python fpga\scripts\run_fpga_benchmark_ddr3.py --benchmark dhrystone --port COM5 --rs-depth 48 --fetch-buffer-depth 16 --core-clk-mhz 25.0 --fpga-impl-mode incremental --capture-seconds 240
```

Second incremental retry knobs after a placement-commit failure:

```powershell
$env:AX7203_INCREMENTAL_DIRECTIVE='TimingClosure'
$env:AX7203_INCREMENTAL_PLACE_DIRECTIVE='ExtraNetDelay_high'
$env:AX7203_INCREMENTAL_ROUTE_DIRECTIVE='Explore'
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

- 2026-05-26: `rv32si` riscv-tests harness now builds supervisor tests with `rv32ima_zicsr_zifencei`, local privileged constants, and correct S-mode entry through `MPP=S`. `rv32si` improved from build-layer failure to 4/6 passing; remaining `dirty` and `ma_fetch` failures expose real MPRV/Sv32 A/D and instruction-misaligned fetch gaps.
- 2026-05-26: PTW A/D writebacks now snoop-invalidate matching local L2 lines and board-baseline read-only D-cache lines. `test_sv32_core_identity` now caches a cold PTE before PTW update and then verifies the CPU sees A/D set through a later load. Basic remains 44/44 and board-equivalent WSL Verilator Dhrystone remains green.
- 2026-05-26: I-side Sv32 instruction page faults now enter the same ROB-commit exception path as D-side faults. The fetch path injects a fault-marked NOP with the MMU faulting VA as the ROB PC so `sepc`, `scause`, and `stval` are precise. New `test_sv32_core_fetch_page_fault` passes; basic is now 44/44 and board-equivalent WSL Verilator Dhrystone remains green.
- 2026-05-25: D-side Sv32 load/store page faults now produce LSU exception completions, are recorded by tag, and enter CSR only when the faulting ROB entry commits. New `test_sv32_core_page_fault` passes; basic is now 43/43 and board-equivalent WSL Verilator Dhrystone remains green.
- 2026-05-25: `sfence.vma` is now wired as a commit-ordered full TLB flush in the core. The core-level Sv32 identity test executes it in both M-mode and S-mode; Icarus, rv32ua, and board-equivalent WSL Verilator Dhrystone remain green.
- 2026-05-25: `mem_subsys` gained the integrated Sv32 PTW physical endpoint, with local RAM service and low-priority DDR3 arbitration. Core-level Sv32 identity execution now passes, and board-equivalent WSL Verilator Dhrystone remains green.
- 2026-05-25: `mmu_sv32` was rewritten around a simple physical PTW port, hardware A/D update, U/S/SUM/MXR permission checks, page-fault metadata, and full-flush `sfence.vma`; module-level Sv32 tests pass and the MMU is instantiated in the core as a bare-mode scaffold.
- 2026-05-25: Linux MMU bring-up started: S-mode CSR/trap, RV32A, PLIC S-context UART IRQ, and SBI timer-injection directed tests pass; Linux DTB/initramfs staging flow and Verilator `linux-preload` entry were added. Full Linux boot remains blocked on Sv32/MMU/PTW/page-fault integration.
- 2026-05-24: WSL Verilator became available after Ubuntu-22.04 was started externally; preload and full loader-semantic Dhrystone now pass with board ROM profile and board-safe host pacing.
- 2026-05-24: Verilator board-config checking was tightened to include loader ROM profile `board` and loader-semantic host pacing; `SIM_FAST_STORE_DRAIN`/`sim-fast` or fast-pacing loader runs are not board-equivalent evidence, and config mismatch summaries are written before WSL tool probing.
- 2026-05-22: Verilator wrapper gained board-config checking; board-equivalent Dhrystone gates must show `BoardConfigMatch: True` before Vivado implementation.
- 2026-05-22: Board-matched Dhrystone Verilator preload and loader-semantic gates passed, and the post-incremental-failure boundary matrix passed under the new config reporting.
- 2026-05-22: Incremental implementation after board-config checking failed again at `Phase 3.3 Place Remaining`; evidence points to local site shortage and low post-place reuse rather than RTL or environment failure.
- 2026-05-22: Old bitstream `0x6A0ED6D5` still programs and reads back over JTAG, but UART loader smoke fails in block 0; it is stale evidence and a fresh implementation is required.
- 2026-05-22: Verilator boundary matrix passed after two incremental placement failures; implementation remains blocked by Vivado placement congestion rather than Dhrystone RTL behavior.
- 2026-05-22: Second incremental retry with `TimingClosure` also failed in placement commit; the flow returned to the Verilator boundary matrix.
- 2026-05-21: User locked AX7203 implementation flow to Vivado 2023.2 despite 2024.2 also being installed.
- 2026-05-21: First post-Verilator Vivado 2023.2 incremental attempt failed in placement commit, not in synthesis or reuse DB creation; automatic aggressive fallback was disabled for incremental benchmark mode.
- 2026-05-21: Dhrystone short-term debug loop was fixed as Verilator-first, incremental second, with two consecutive incremental failures forcing a Verilator boundary-matrix fallback.
- 2026-05-21: Loader-semantic Verilator Dhrystone passed with `--max-cycles 60000000`; the default 20M budget can timeout during readback and is not a functional failure by itself.
- 2026-05-21: User clarified the mandatory debug ladder: Icarus, then WSL Verilator through the repo script, then real AX7203 board validation via Vivado JTAG.
- 2026-05-21: Vivado 2023.2 synthesis succeeded after reverting temporary dispatch debug ports that had triggered a synth crash.
- 2026-05-21: Branch-complete duplicate pulse in FPGA scoreboard path was fixed; loader long sim passed, but fresh bitstream is still pending.
- 2026-05-21: 16550A-compatible UART subset and PLIC source 2 are already in the active debug baseline.
