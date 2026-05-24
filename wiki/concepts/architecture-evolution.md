# Architecture Evolution

## Current Direction

The active debug baseline is SifangCore single-thread RV32IM/OoO for AX7203. Historical SMT/T0/T1 structure still exists in some internal organization, but new fixes must not restore dual-thread behavior or depend on a second thread.

The long-term goal is broader than the current bring-up target: build a full-stack, competition-grade and industrial-grade dual-issue out-of-order processor core that can boot Linux and run benchmark/test workloads with high performance.

## SMT Removal Lessons

- Removed or dangling TID signals can turn into `x` propagation. Tie unused thread IDs to `1'b0` deliberately and verify with warnings/tests.
- Width loss from automated edits is a real risk. One known issue was `rmt_mapped_mask_t0` losing its explicit width and becoming an implicit 1-bit wire.
- Branch tracking needs special care because duplicated completion pulses can corrupt speculative dispatch state in single-thread FPGA mode.

## Current Functional State

- Basic single-thread Icarus tests are past the all-timeout phase.
- UART16550 and PLIC source 2 are part of the current architecture.
- The latest pre-rename Dhrystone board-only run passed with Vivado 2023.2 JTAG and COM5 UART. After the SifangCore structural rename, fresh simulation and a new `sifang_core_ax7203` implementation are required before claiming post-rename board status.
