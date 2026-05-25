# Simulation

## Current Tools

- Icarus Verilog is the active local simulation workhorse.
- Verilator mainline is a WSL-backed flow. Use `python fpga/scripts/run_verilator_mainline.py`; the wrapper calls `wsl.exe` and expects WSL-side `verilator`, `make`, and `g++`. On 2026-05-24 the current Codex session initially saw no registered distro, but after Ubuntu-22.04 was started externally the wrapper found Verilator 5.046 plus `make` and `g++`.
- Vivado simulation/top smoke tests are useful for AX7203 wrapper checks, but long loader behavior is currently exercised mainly through Icarus and board scripts.

## Required Order

After RTL changes:

1. Run the narrowest relevant Icarus test, then the basic regression. Add `--fpga-config` for memory subsystem, UART, DDR3, or AX7203-facing changes.
2. Run WSL Verilator mainline through the repo script, using preload and loader-semantic Dhrystone modes as appropriate.
3. Only then proceed to Vivado synthesis/implementation and real board validation.

The SifangCore structural rename is RTL-affecting because module names, testbench hierarchy paths, filelists, and FPGA tops changed. It therefore requires the same Icarus -> WSL Verilator -> Vivado/JTAG ladder before post-rename Dhrystone status can replace the pre-rename bitstream evidence.

## Dhrystone Current Loop

For the current Dhrystone objective, run these Verilator gates before any incremental implementation:

```powershell
python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 1 --loader-rom-profile board --benchmark-runtime-profile board --max-cycles 600000000 --require-board-config-match
python fpga\scripts\run_verilator_mainline.py --mode loader-semantic --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 1 --loader-rom-profile board --benchmark-runtime-profile board --payload-start-gap-cycles 2500 --payload-gap-cycles 2500 --payload-chunk-gap-cycles 40000 --max-cycles 2000000000 --require-board-config-match
```

The explicit loader-semantic pacing avoids a protocol race between host payload bytes and loader-side FIFO management. The 2.0B eval-cycle budget is required because the board-profile loader intentionally includes block ACK pacing, final store-drain delays, and board-runtime UART delays.

Observed passing short Dhrystone gates on 2026-05-24 after host pacing was added to board-config checking:

- Preload/read-only/mock-latency1 with the previous implicit 10-run Verilator image: `BoardConfigMatch=True`, `ExitReason=done`, benchmark pass, no trap.
- Loader-semantic/read-only/mock-latency1 with the previous implicit 10-run Verilator image and `--payload-start-gap-cycles 2500 --payload-gap-cycles 2500 --payload-chunk-gap-cycles 40000 --max-cycles 1200000000`: `BoardConfigMatch=True`, `LoaderSemanticPass=True`, 126 blocks ACKed, benchmark START/DONE seen, no trap and no unexpected UART.

Those short-run results no longer authorize board implementation by themselves. The board baseline uses a fixed 5000-run Dhrystone image and the board C runtime; the wrapper now passes `--fixed-dhrystone-runs <runs>` into the benchmark build, defaults to `--benchmark-runtime-profile board`, and includes `DHRYSTONE_RUNS=5000` plus `BENCHMARK_RUNTIME_PROFILE=board` in `BoardConfigMatch`.

On 2026-05-24, the 5000-run board-equivalent preload and loader-semantic gates passed. The loader-semantic pass required `--max-cycles 2000000000`; a 1.2B run timed out while still retiring because board-runtime UART delays consumed too much of the old budget.

## Verilator Board Config Check

The Verilator wrapper now records a board-configuration comparison in `summary.txt` and `summary.json`. Board-equivalent Dhrystone runs must show `BoardConfigMatch: True`; otherwise do not use the run as evidence for AX7203 board readiness.

The checked baseline is the current board flow: `SMT_MODE=0`, `ENABLE_MEM_SUBSYS=1`, `ENABLE_DDR3=1`, `L2_PASSTHROUGH=1`, RS depth 48, RS index width 6, fetch buffer depth 16, 25 MHz core clock, 115200 UART, UART divider 217, `AX7203_DCACHE_MODE=read-only`, loader ROM profile `board`, benchmark runtime profile `board`, fixed Dhrystone 5000 runs, and loader-semantic host pacing `payload_start_gap=2500`, `payload_gap=2500`, `payload_chunk_gap=40000`. A `SIM_FAST_STORE_DRAIN` loader image, `--loader-rom-profile sim-fast`, `--benchmark-runtime-profile verilator-fast`, short Dhrystone run count, or fast host pacing run is useful only as a directed simulation shortcut; it is not board-equivalent.

Use `--require-board-config-match` on preload and loader-semantic gates that are meant to authorize synthesis/implementation. Boundary stress rows that intentionally vary one dimension should omit the flag and leave the mismatch visible; for example the `--dcache-mode full` row is not board-equivalent by design.

The wrapper writes the board-config summary before checking WSL-side `verilator`, `make`, and `g++`. This is intentional: an environment failure must not mask a configuration failure. A 2026-05-24 negative check with default fast loader pacing wrote `BoardConfigMatch: False` and reported the expected `PAYLOAD_*_GAP_CYCLES` mismatches before building Verilator.

If incremental implementation fails twice consecutively, return to this boundary matrix before trying Vivado again:

```powershell
python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 7 --loader-rom-profile board --benchmark-runtime-profile board --max-cycles 1200000000 --require-board-config-match
python fpga\scripts\run_verilator_mainline.py --mode preload --benchmark dhrystone --runs 5000 --dcache-mode full --mock-latency 1 --benchmark-runtime-profile board --max-cycles 600000000
python fpga\scripts\run_verilator_mainline.py --mode loader-semantic --benchmark dhrystone --runs 5000 --dcache-mode read-only --mock-latency 7 --loader-rom-profile board --benchmark-runtime-profile board --payload-start-gap-cycles 2500 --payload-gap-cycles 2500 --payload-chunk-gap-cycles 40000 --max-cycles 3000000000 --require-board-config-match
```

As of 2026-05-22 10:03 +08:00, the boundary matrix above passed after two consecutive Vivado 2023.2 incremental placement failures. The read-only rows passed with `BoardConfigMatch=True`; the full-dcache stress row passed while correctly reporting only the expected `DCACHE_MODE` mismatch.

## Known Passing Areas

- Basic and FPGA-config tests have passed in the current debug line.
- Directed UART16550 and PLIC source 2 tests have passed.
- Linux prerequisite directed tests now pass: `test_priv_mret_sret_delegation`, `test_amo_lrsc`, `test_plic_s_context_uart_irq`, and `test_sbi_timer_injection`.
- Sv32 module-level tests now pass through the unified runner: `test_sv32_translation`, `test_sv32_page_faults`, and `test_sfence_vma`. These cover bare/M-mode bypass, 4KB and 4MB translations, U/S/SUM/MXR permission checks, load/store/fetch page-fault metadata, hardware A/D PTE updates, and full-flush `sfence.vma`.
- Classic `riscv-tests` now includes `rv32ua`; `python verification\run_riscv_tests.py --suite riscv-tests --categories rv32ua` passes 10/10 after extending the riscv-tests testbench timeout for the long LR/SC loop.
- Store-buffer stress tests for long stream and long drain/poll patterns have passed.
- Loader long simulation with 32-byte blocks passed after the branch-complete duplicate-pulse fix.
- After I/D MMU insertion, board-equivalent 5000-run Verilator Dhrystone still passes in both preload and loader-semantic modes. The loader-semantic run reported `BoardConfigMatch=True`, `LoaderSemanticPass=True`, 128 block ACKs, benchmark START/DONE, no trap, no unexpected UART, and no stuck PC.
- Verilator wrapper WSL stderr/stdout decoding is now tolerant of localized UTF-16LE WSL errors, so missing-distro or missing-tool failures are visible as environment blockers instead of Python decode exceptions.

## Linux Preload Gate

Linux bring-up uses a separate Verilator mode:

```powershell
python fpga\scripts\run_verilator_mainline.py --mode linux-preload --linux-payload build\linux\fw_payload.bin --dcache-mode read-only --mock-latency 1 --require-board-config-match
```

This mode preloads `fw_payload.bin` at `0x80000000`, starts the core at DDR3, disables the Dhrystone UART-prefix checker, and looks for Linux boot tokens in UART output. The pass condition is:

- `OpenSBI`
- `Boot HART ID: 0`
- `Linux version`
- `Run /init as init process`
- `SIFANGCORE LINUX PASS`

As of 2026-05-25, the mode is wired into the wrapper/harness but cannot pass because `build\linux\fw_payload.bin` is not produced yet and the MMU still needs a `mem_subsys` PTW endpoint plus ROB-precise page-fault delivery. The command correctly fails early with a missing-payload message when the image is absent.

## Recording Rule

For every new failure, record command, test name, pass/fail count, first failing PC or event, and whether the ROM image was rebuilt.
