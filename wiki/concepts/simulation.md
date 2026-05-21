# Simulation

## Current Tools

- Icarus Verilog is the active local simulation workhorse.
- Verilator mainline is a WSL-backed flow. Use `python fpga/scripts/run_verilator_mainline.py`; the wrapper calls `wsl.exe` and expects WSL-side `verilator`, `make`, and `g++`.
- Vivado simulation/top smoke tests are useful for AX7203 wrapper checks, but long loader behavior is currently exercised mainly through Icarus and board scripts.

## Required Order

After RTL changes:

1. Run the narrowest relevant Icarus test, then the basic regression. Add `--fpga-config` for memory subsystem, UART, DDR3, or AX7203-facing changes.
2. Run WSL Verilator mainline through the repo script, using preload and loader-semantic Dhrystone modes as appropriate.
3. Only then proceed to Vivado synthesis/implementation and real board validation.

## Known Passing Areas

- Basic and FPGA-config tests have passed in the current debug line.
- Directed UART16550 and PLIC source 2 tests have passed.
- Store-buffer stress tests for long stream and long drain/poll patterns have passed.
- Loader long simulation with 32-byte blocks passed after the branch-complete duplicate-pulse fix.

## Recording Rule

For every new failure, record command, test name, pass/fail count, first failing PC or event, and whether the ROM image was rebuilt.
