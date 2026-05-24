# Vivado Tooling

## Required Version

Use Vivado 2023.2 for this repository:

```powershell
& 'E:\Xilinx\Vivado\2023.2\bin\vivado.bat' -mode batch -source fpga\run_ax7203_synth.tcl
& 'E:\Xilinx\Vivado\2023.2\bin\vivado.bat' -mode batch -source fpga\impl_aggressive.tcl
```

Vivado 2024.2 is installed on the machine, but it must not be used for AX7203 implementation unless the user explicitly changes that rule.

Bitstream download to AX7203 must use Vivado JTAG mode, normally via `fpga/program_ax7203_jtag.tcl` or a board automation script that calls it.

## Current Tooling Issue

Earlier Vivado 2023.2 implementation attempts failed with:

```text
The system cannot find the path specified.
```

That happened during aggressive place/route and during incremental checkpoint reuse. Treat that specific signature as an environment/tool-flow failure unless a current log proves otherwise.

The latest post-Verilator incremental runs got past reuse DB creation and failed inside placement:

```text
ERROR: [Place 30-99] Placer failed with error: 'failed to commit all instances'
ERROR: Incremental place_design failed: ERROR: [Common 17-69] Command failed: Placer could not place all instances
```

The first run used the default `RuntimeOptimized` incremental directive. The second retry used `TimingClosure`, reached `Phase 3.3 Place Remaining`, then failed after about 55:40 elapsed in placement. After board-config Verilator checking was added, another `TimingClosure` incremental run again reached `Phase 3.3 Place Remaining`, warned that the changed die area had few free physical sites, and failed with the same `failed to commit all instances` error after about 1:09:56 elapsed in placement. Reuse reports showed 89.00% current cell reuse before placement and 77.63% current cell reuse after failed placement; 22.36% of cells were non-reused after placement, including 11.59% discarded to improve timing. This is an incremental placement/congestion failure, not a Dhrystone functional failure.

## Dhrystone Incremental Rule

For the current Dhrystone target, Vivado incremental implementation is only entered after both WSL Verilator Dhrystone gates pass. If incremental implementation fails twice consecutively, stop retrying Vivado and return to the Verilator boundary matrix documented in `simulation.md`. Do not spend repeated implementation cycles without fresh simulation evidence.

The Verilator gates used to authorize Vivado must be board-equivalent. Check `BoardConfigMatch: True` in the Verilator summary before starting synthesis or implementation. The required comparison includes RS depth 48, fetch buffer depth 16, 25 MHz core clock, UART divider 217, SMT disabled, DDR3 enabled, read-only dcache, loader ROM profile `board`, benchmark runtime profile `board`, fixed Dhrystone 5000 runs, and loader-semantic host pacing `payload_start_gap=2500`, `payload_gap=2500`, `payload_chunk_gap=40000`. A deliberate stress simulation such as `--dcache-mode full`, `--loader-rom-profile sim-fast`, `--benchmark-runtime-profile verilator-fast`, short Dhrystone run count, or fast host pacing is useful coverage but must not be treated as the board-equivalent gate.

As of 2026-05-24, WSL Verilator is available again after the Ubuntu-22.04 distro was started externally. The board-equivalent 5000-run preload and loader-semantic Dhrystone gates now pass with `BENCHMARK_RUNTIME_PROFILE=board`, so board-only or incremental Vivado work can proceed from current simulation evidence.

`--fpga-impl-mode incremental` must fail closed. It should not automatically start `impl_aggressive.tcl`; run aggressive explicitly only when the debug loop allows it. `fpga/impl_incremental.tcl` also exits without launching aggressive and points back to the Dhrystone debug loop.

`fpga/impl_aggressive.tcl` must return a non-zero process exit code when implementation does not reach `SUCCESS`, so automation does not accidentally treat a failed aggressive run as usable. This is only a fallback/signoff path after the Verilator gates justify spending a full implementation cycle.

The latest board-only run of bitstream `0x6A12D692` passed. Vivado 2023.2 JTAG programming reported DONE/EOS, USR_ACCESS and USERCODE both read back `0x6A12D692`, loader smoke printed `DHRYSTONE DONE`, and the baseline 5000-run payload printed `DHRYSTONE DONE`. The earlier 240-second baseline miss is superseded by this clean rerun.

## Retry Checklist

- Use explicit `-log` and `-journal` paths under `build\ax7203\logs\`.
- Set `TEMP` and `TMP` to a short local directory such as `build\vivado_tmp`.
- Keep `AX7203_IMPL_JOBS` conservative.
- For the one allowed incremental retry after a placement-commit failure, prefer a directive relaxation before changing RTL: set `AX7203_INCREMENTAL_DIRECTIVE=TimingClosure`, `AX7203_INCREMENTAL_PLACE_DIRECTIVE=ExtraNetDelay_high`, and `AX7203_INCREMENTAL_ROUTE_DIRECTIVE=Explore`.
- Do not kill unrelated Vivado processes outside this repo.
- If a mistaken repo-owned Vivado 2024.2 run is started, stop only that process tree and restart with 2023.2.

## Fast Flow Files

- `fpga/synth_ooc_module.tcl`: OOC synthesis for local RTL checks.
- `fpga/impl_incremental.tcl`: incremental implementation from a post-synth checkpoint and a routed reference checkpoint.
- `fpga/scripts/run_fpga_benchmark_ddr3.py`: supports `--fpga-impl-mode aggressive|incremental|synth-only|board-only`.
