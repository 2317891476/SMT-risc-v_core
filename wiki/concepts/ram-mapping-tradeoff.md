# RAM Mapping Tradeoff

## Current Lessons

- Loader ROM contents are part of the bitstream path. Rebuild `rom/inst.hex`, `rom/data.hex`, and `rom/mem_subsys_ram.hex` before synthesis when changing loader firmware.
- `updatemem` should not be assumed to work for the current memory mapping; previous attempts did not provide a safe shortcut.
- Do not convert `mem_subsys` RAM initialization or timing style just to make bitstream patching easier without re-running basic and FPGA-config regressions.

## Open Questions

- Whether selected memories should move from LUTRAM to BRAM depends on current utilization and timing reports, not generic preference.
- Any RAM remapping must preserve Icarus tests, top simulation, and board loader behavior.
