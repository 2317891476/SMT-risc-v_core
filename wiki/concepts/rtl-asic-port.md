# RTL ASIC Port Notes

## Portability Watchlist

- Reset strategy and async reset release paths.
- Inferred memories and initialization files.
- Clock-domain crossings around DDR3/MIG wrappers.
- FPGA-only UART/JTAG/debug beacons.
- Vendor-specific RAM/IP wrappers under `libs/` and `fpga/ip/`.

## Current Rule

Do not modify RTL for hypothetical ASIC portability while AX7203 board Dhrystone is still blocked. Record issues here, but prioritize the current FPGA bring-up path.
