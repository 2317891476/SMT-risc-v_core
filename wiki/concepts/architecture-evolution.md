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

## Linux Bring-up Architecture

The Linux route is now fixed as MMU Linux: `RV32IMA_Zicsr_Zifencei`, S-mode, Sv32, OpenSBI, Linux, and BusyBox initramfs. This rejects a NoMMU shortcut.

Implemented foundation:

- `csr_unit` now has the first Linux-critical S-mode CSR set: `mstatus/sstatus`, `mie/sie`, `mip/sip`, delegation registers, `mtvec/stvec`, `mepc/sepc`, `mcause/scause`, `mtval/stval`, scratch CSRs, counter enables, and `satp`.
- Synchronous `ECALL`/`EBREAK`, `MRET`, and `SRET` have a commit-ordered path through the ROB-side system instruction tracking.
- `misa` reports `RV32IMA`, and RV32A AMO/LRSC operations are implemented through the LSU/memory path.
- PLIC is now two-source and two-context. Source 1 remains the existing external interrupt, source 2 is UART16550, and M/S contexts have separate enable/threshold/claim-complete state.
- OpenSBI-style supervisor timer injection is supported by writable `mip/sip` supervisor interrupt bits and S-mode delegated timer delivery.
- `mmu_sv32` now has a simple physical PTW request/response port, 4KB and 4MB Sv32 walking, U/S/SUM/MXR permission checks, hardware A/D PTE writeback, page-fault cause/tval outputs, and full-flush `sfence.vma` coverage in module-level tests.
- The top core now exposes `satp`, `priv_mode`, `mstatus.MXR`, and `mstatus.SUM` from `csr_unit`. I-side fetch queries the MMU with the virtual PC and sends the translated physical address to `inst_memory/icache`; D-side LSU queries the MMU and uses the translated physical address for store-buffer lookup/enqueue and M1 requests.

Known architecture gaps before Linux can boot:

- The PTW simple physical port is still tied off at the top level and needs an integrated endpoint in `mem_subsys` with correct arbitration against DDR3/cache traffic.
- Precise instruction/load/store page-fault causes and `tval` must be carried into CSR at the right ROB point.
- The current no-page-table privilege smoke writes `satp.MODE=0`; actual MODE=1 execution is intentionally covered by Sv32/MMU tests that install page tables first.
- The current S-mode work is single hart only; SMP, FPU, compressed instructions, and device storage are intentionally out of scope for the first Linux pass.
