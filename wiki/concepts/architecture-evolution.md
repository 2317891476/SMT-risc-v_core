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
- The post-rename SifangCore Dhrystone board-only run passed with Vivado 2023.2 JTAG and COM5 UART using the `sifang_core_ax7203` flow. Linux work still remains simulation-first until `linux-preload` passes.

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
- `mem_subsys` now services the MMU PTW physical port. Low physical addresses access the shared 16KB backing RAM below the L2 RAM write port; high physical addresses arbitrate into the DDR3 bridge below normal I/D traffic, with an aging counter so PTW is not starved indefinitely.
- `sfence.vma` is now tracked as a serializing SYSTEM instruction. The first integrated version waits for ROB commit and an empty store buffer, then issues a full TLB flush to `mmu_sv32`; selective ASID/VPN operands are intentionally ignored for v1.
- A core-level Sv32 identity test now installs page tables in local RAM, executes `sfence.vma` in M-mode and S-mode, enters S-mode with Sv32 enabled, fetches through the I-side MMU, performs D-side translated store/load, and writes PASS through an identity-mapped MMIO megapage.
- D-side load/store page faults now complete through the LSU without issuing memory or enqueuing stores, record cause/tval by RS tag, and enter `csr_unit` only when the corresponding ROB entry commits. `test_sv32_core_page_fault` validates delegated S-mode load/store page faults with `scause`, `stval`, and `sepc`.
- I-side instruction page faults now enter the same ROB-commit exception path. `stage_if` injects a fault-marked NOP into the fetch buffer instead of issuing an instruction memory request; the fetch/fault metadata rides through decode, dispatch, and the tag exception sideband until the ROB commits the faulting entry. The synthetic uop uses the MMU faulting VA as its ROB PC, so `csr_unit` writes precise `sepc` while `stval` carries the same faulting address. `test_sv32_core_fetch_page_fault` validates delegated S-mode instruction page fault `scause=12`, `stval`, `sepc`, and `sret` recovery.

Known architecture gaps before Linux can boot:

- PTW A/D writeback currently updates the physical backing store/DDR3 path, but it does not invalidate or update CPU cache lines that may already contain the same PTE. The standalone MMU test verifies hardware A/D behavior at the PTW memory interface; OS-visible PTE coherence still needs a shared cache path or invalidation policy before Linux can rely on A/D bits under cached page-table reads.
- The Linux `fw_payload.bin` build is not yet complete. The next software gate is producing OpenSBI + RV32 Linux + BusyBox initramfs + DTB and then running Verilator `--mode linux-preload`.
- The current no-page-table privilege smoke writes `satp.MODE=0`; actual MODE=1 execution is intentionally covered by Sv32/MMU tests that install page tables first.
- The current S-mode work is single hart only; SMP, FPU, compressed instructions, and device storage are intentionally out of scope for the first Linux pass.
