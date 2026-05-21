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

Latest Vivado 2023.2 implementation attempts failed with:

```text
The system cannot find the path specified.
```

This happened during aggressive place/route and during incremental checkpoint reuse. Treat it as an environment/tool-flow failure unless a current log proves otherwise.

## Retry Checklist

- Use explicit `-log` and `-journal` paths under `build\ax7203\logs\`.
- Set `TEMP` and `TMP` to a short local directory such as `build\vivado_tmp`.
- Keep `AX7203_IMPL_JOBS` conservative.
- Do not kill unrelated Vivado processes outside this repo.
- If a mistaken repo-owned Vivado 2024.2 run is started, stop only that process tree and restart with 2023.2.

## Fast Flow Files

- `fpga/synth_ooc_module.tcl`: OOC synthesis for local RTL checks.
- `fpga/impl_incremental.tcl`: incremental implementation from a post-synth checkpoint and a routed reference checkpoint.
- `fpga/scripts/run_fpga_benchmark_ddr3.py`: supports `--fpga-impl-mode aggressive|incremental|synth-only|board-only`.
