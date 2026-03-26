# CoreMark Port for AdamRiscv AX7203 (BRAM Bare-Metal)

This directory contains the CoreMark platform port for **adam_riscv_v2 (RV32IM)** on the **AX7203 FPGA** target.

The port is designed for:

- **Bare-metal execution** (no OS)
- **Integer-only CoreMark run**
- **Static memory allocation** (no heap use for benchmark data)
- **UART result output** at **115200 baud**
- **BRAM-first deployment** (32KB or 64KB)

## Files

- `core_portme.h`: CoreMark platform configuration and compile-time options
- `core_portme.c`: platform implementations (timer, UART output, init/fini, malloc hooks)
- `Makefile.ax7203`: AX7203 build flow with `riscv-none-elf-gcc`

## Prerequisites

1. Copy upstream CoreMark sources (`core_main.c`, `core_list_join.c`, `core_matrix.c`, `core_state.c`, `core_util.c`, `coremark.h`) into this directory.
2. Install toolchain in `PATH`:
   - `riscv-none-elf-gcc`
   - `riscv-none-elf-objcopy`
   - `riscv-none-elf-objdump`

## Build

```bash
make -f Makefile.ax7203
```

Outputs:

- `build_ax7203/coremark_ax7203.elf`
- `build_ax7203/coremark_ax7203.bin`
- `build_ax7203/coremark_ax7203.dis`
- `build_ax7203/coremark_ax7203.map`

## Run-time assumptions

- Core clock default: `50 MHz` (`AX7203_CPU_HZ=50000000`)
- UART MMIO base default: `0x10000000` (SiFive-style TXDATA full bit in bit31)
- UART speed target: `115200`

If your AX7203 SoC wrapper uses different UART registers/base, override in build:

```bash
make -f Makefile.ax7203 \
  AX7203_UART_BASE=0x13000000 \
  AX7203_UART_TXDATA_OFFSET=0x0 \
  AX7203_UART_FULL_BIT=31
```

## BRAM size guidance

- 32KB BRAM: keep `TOTAL_DATA_SIZE` conservative (e.g. 1200~1800)
- 64KB BRAM: `TOTAL_DATA_SIZE=2000` typically fits

Example:

```bash
make -f Makefile.ax7203 TOTAL_DATA_SIZE=1600
```

## Notes

- This port intentionally keeps CoreMark benchmark data in static storage by setting `MEM_METHOD=MEM_STATIC`.
- The timer uses `mcycle/mcycleh` CSR for cycle-accurate timing.
- `ee_printf()` is routed to UART and supports integer-oriented formatting through `vsnprintf`.
