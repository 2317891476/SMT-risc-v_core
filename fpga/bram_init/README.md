# BRAM-first initialization flow (AX7203)

This directory contains the first FPGA milestone memory flow for AX7203: use on-chip Xilinx BRAM instead of DDR3.

## Goal

- Bring up `adam_riscv_v2_ax7203_top` with a simple BRAM-backed memory image.
- Keep the memory path minimal for synthesis/debug before external DDR3 integration.

## Strategy

1. Convert software images from `rom/inst.hex` and `rom/data.hex` into Xilinx COE files.
2. Generate Block Memory Generator IP in Vivado.
3. Initialize BRAM from COE at synthesis time.

## Memory organization (first milestone)

- BRAM type: Block Memory Generator (`blk_mem_gen`)
- Data width: 32-bit
- Depth: 8192 words (32 KB) by default (set `BRAM_DEPTH=16384` for 64 KB)
- Access model: dual-port
  - Port A: instruction fetch (read-only usage)
  - Port B: data access (read/write usage)

Address map:

- Instruction region base: `0x0000_0000`
- Data region base: `0x0000_1000`

## Files

- `create_bram_ip.tcl` — creates BRAM IP (`bram_mem_0`) and binds COE initialization.
- `inst_mem.coe` — instruction image COE (generated).
- `data_mem.coe` — data image COE (generated for map visibility and future split-memory extension).

## Generate COE files

From repo root:

```bash
python fpga/scripts/generate_coe.py
```

Optional 64 KB image:

```bash
python fpga/scripts/generate_coe.py --depth 16384
```

## Generate BRAM IP in Vivado

Standalone usage:

```bash
vivado -mode batch -source fpga/bram_init/create_bram_ip.tcl
```

When sourced from `fpga/create_project_ax7203.tcl`, IP generation is integrated into project creation.
