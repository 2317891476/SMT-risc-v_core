# P2 Unified L2 Cache + PLIC/CLINT Bring-up

## TL;DR
> **Summary**: Add a shared blocking memory subsystem that introduces a unified L2 cache plus a 2-master arbiter for the active I-side and D-side paths, then layer machine-mode-only CLINT/PLIC interrupt delivery on top of that subsystem.
> **Deliverables**:
> - unified `mem_subsys` + `l2_arbiter` + `l2_cache` integrated into `adam_riscv_v2`
> - `clint` + `plic` MMIO blocks with machine timer and machine external interrupt delivery
> - dedicated targeted ROM/testbench tests for L2 and interrupts
> - updated `run_all_tests.py` basic/full regression flow covering new P2 tests
> **Effort**: XL
> **Parallel**: YES - 3 waves
> **Critical Path**: Task 1 → Task 2 → Task 4 → Task 5 → Task 7 → Task 10 → Task 12

## Context
### Original Request
Create a concrete Sisyphus execution plan to complete roadmap items `P2 | L2 Cache | 统一二级缓存 + 仲裁器` and `P2 | 中断控制器 (PLIC/CLINT) | 支持外部中断 + 定时器中断`, with dedicated tests after each feature and with the new tests folded into the full regression flow.

### Interview Summary
- User requested one execution-ready plan covering both P2 roadmap items.
- Dedicated targeted tests are mandatory after each major feature.
- Those targeted tests must then be integrated into the existing full regression flow and rerun.
- No broader roadmap expansion was requested beyond these two P2 items.

### Metis Review (gaps addressed)
- Freeze P2 cache scope to the active I-side refill path plus the current D-side LSU/store path; do not activate dormant `l1_dcache_nb` or `mmu_sv32` in this plan.
- Freeze P2 interrupt scope to machine-mode only, `SMT_MODE=0` only, direct `mtvec` mode only, and MEIP/MTIP only; exclude MSIP, delegation, vectored mode, and nested interrupt claims.
- Make testbench contract stabilization a first-class task before memory hierarchy changes, because current PASS/FAIL and preload behavior depend on old RAM alias assumptions.
- Require exact regression commands and evidence outputs at each rung; no manual waveform inspection as acceptance.

## Work Objectives
### Core Objective
Land a deterministic P2 implementation that introduces a shared unified L2-backed memory subsystem and machine-mode CLINT/PLIC interrupt support without breaking the existing educational regression harness.

### Deliverables
- `rtl/mem_subsys.v` shared memory subsystem wrapper
- `rtl/l2_arbiter.v` 2-master round-robin arbiter
- `rtl/l2_cache.v` blocking unified L2 cache core
- `rtl/clint.v` machine timer MMIO block (`mtime`, `mtimecmp`)
- `rtl/plic.v` machine external interrupt controller (single machine context)
- top-level integration updates in `rtl/adam_riscv_v2.v`, `rtl/inst_memory.v`, `rtl/lsu_shell.v`, `rtl/stage_is.v`, `rtl/ctrl.v`, `rtl/decoder_dual.v`, and supporting modules
- dedicated ROM tests for L2 and interrupts
- updated `comp_test/tb_v2.sv`, `comp_test/test_content.sv`, and `verification/run_all_tests.py`

### Definition of Done (verifiable conditions with commands)
- `python verification/run_all_tests.py --basic --tests test_l2_icache_refill.s test_l2_i_d_arbiter.s test_l2_mmio_bypass.s` exits 0 and reports all listed L2 tests as PASS.
- `python verification/run_all_tests.py --basic --tests test_clint_timer_interrupt.s test_plic_external_interrupt.s test_interrupt_mask_mret.s` exits 0 and reports all listed interrupt tests as PASS.
- `python verification/run_all_tests.py --basic` exits 0 with all legacy + new targeted tests passing.
- `python verification/run_all_tests.py --basic --riscv-tests --riscv-arch-test` exits 0 with no regressions.
- `grep -n "test_l2_\|test_clint_\|test_plic_\|test_interrupt_" verification/run_all_tests.py` shows the new tests are part of the maintained flow.

### Must Have
- One shared memory subsystem below the active I-side refill path and active D-side LSU path.
- Explicit uncached MMIO decode for TUBE, CLINT, and PLIC.
- Stable testbench preload and completion semantics after the memory refactor.
- Interrupt delivery only after fetch is quiesced and the core reaches a precise drained boundary, and only when `SMT_MODE=0`.
- Dedicated feature tests added before full-regression integration.

### Must NOT Have (guardrails, AI slop patterns, scope boundaries)
- Must NOT activate `l1_dcache_nb`, `mmu_sv32`, PTW AXI, or coherence work in this plan.
- Must NOT add MSIP, delegation, vectored `mtvec`, nested interrupt support, or SMT interrupt delivery claims.
- Must NOT rely on the old `0x1300_0000 -> DRAM[0]` alias for PASS/FAIL after MMIO decode is introduced.
- Must NOT require manual waveform inspection or human interrupt injection to declare success.

## Verification Strategy
> ZERO HUMAN INTERVENTION — all verification is agent-executed.
- Test decision: tests-after using the existing ROM + `tb_v2.sv` harness, with dedicated P2 tests added before full regression.
- QA policy: Every task includes targeted happy-path and failure/edge scenarios.
- Evidence: `.sisyphus/evidence/task-{N}-{slug}.log` or `.txt` captured from `iverilog`, `vvp`, or `python verification/run_all_tests.py ...` commands.

## Execution Strategy
### Parallel Execution Waves
> Target: 5-8 tasks per wave. <3 per wave (except final) = under-splitting.
> Extract shared dependencies as Wave-1 tasks for max parallelism.

Wave 1: regression contract stabilization + precision prerequisites + memory-subsystem scaffold
- Task 1 metadata/flush correctness
- Task 2 testbench compatibility contract
- Task 3 regression harness extension scaffold
- Task 4 `mem_subsys` + shared RAM/MMIO decode scaffold

Wave 2: unified L2 path
- Task 5 I-side export into `mem_subsys`
- Task 6 D-side variable-latency hookup into `mem_subsys`
- Task 7 `l2_cache` + `l2_arbiter` integration
- Task 8 dedicated L2 tests + regression integration

Wave 3: interrupt path
- Task 9 SYSTEM/CSR/trap plumbing
- Task 10 CLINT timer interrupt path
- Task 11 PLIC external interrupt path
- Task 12 dedicated interrupt tests + regression integration

### Dependency Matrix (full, all tasks)
| Task | Depends On | Blocks |
|---|---|---|
| 1 | none | 4, 9, 10, 11 |
| 2 | none | 4, 8, 12 |
| 3 | none | 8, 12 |
| 4 | 1, 2 | 5, 6, 10, 11 |
| 5 | 4 | 7 |
| 6 | 4 | 7 |
| 7 | 5, 6 | 8 |
| 8 | 3, 7 | 12, F1-F4 |
| 9 | 1 | 10, 11, 12 |
| 10 | 4, 9 | 12 |
| 11 | 4, 9 | 12 |
| 12 | 3, 10, 11 | F1-F4 |

### Agent Dispatch Summary (wave → task count → categories)
- Wave 1 → 4 tasks → `verification`, `tb`, `rtl`
- Wave 2 → 4 tasks → `rtl`, `tb`, `verification`, `build`
- Wave 3 → 4 tasks → `rtl`, `verification`, `tb`, `build`

## TODOs
> Implementation + Test = ONE task. Never separate.
> EVERY task MUST have: Agent Profile + Parallelization + QA Scenarios.

- [ ] 1. Stabilize metadata ordering and flush epoch for precise memory/trap behavior

  **What to do**: Fix the pre-existing precision hazards in `rtl/adam_riscv_v2.v` before adding either P2 feature. Make `flush_new_epoch_t0/t1` drive `current_epoch + 1` for the flushed thread, not the old epoch value. Make same-thread dual dispatch allocate unique monotonically increasing `disp0_order_id` / `disp1_order_id` values in one cycle instead of reusing the same counter value. Keep the existing single-counter-per-thread scheme; do not change ROB or scoreboard widths.
  **Must NOT do**: Do not introduce per-thread interrupt state, reorder ROB behavior, or widen metadata fields in this task.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: top-level metadata correctness drives later L2/store-buffer/trap precision.
  - Skills: [`verilog-lint`] — use after edit to catch metadata wiring regressions.
  - Omitted: [`build`] — no full regression until later tasks.

  **Parallelization**: Can Parallel: NO | Wave 1 | Blocks: 4, 9, 10, 11 | Blocked By: none

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `rtl/adam_riscv_v2.v:88-118` — current epoch export is the old epoch value on flush.
  - Pattern: `rtl/adam_riscv_v2.v:270-271` — current same-thread dual-dispatch assigns identical order IDs.
  - Pattern: `rtl/rob_lite.v:64-80` — ROB commit outputs consume order IDs directly for store-buffer commit semantics.
  - Pattern: `rtl/lsu_shell.v:168-220` — LSU/store-buffer depends on `req_order_id`, `req_epoch`, and flush metadata.

  **Acceptance Criteria** (agent-executable only):
  - [ ] `iverilog -g2012 -s tb_v2 -o comp_test/out_iverilog/bin/task1_meta.out -I rtl rtl/*.v libs/REG_ARRAY/SRAM/ram_bfm.v comp_test/tb_v2.sv` exits 0.
  - [ ] `python verification/run_all_tests.py --basic --tests test_store_buffer_commit.s test_commit_flush_store.s` exits 0.
  - [ ] Simulation log proves both tests still PASS after metadata changes.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Flush uses next epoch value consistently
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_flush_store.s 2>&1 | tee .sisyphus/evidence/task-1-metadata-flush.log`
    Expected: Command exits 0 and log contains `[PASS] test_commit_flush_store: PASS`
    Evidence: .sisyphus/evidence/task-1-metadata-flush.log

  Scenario: Store-buffer commit ordering remains stable after unique order IDs
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_store_buffer_commit.s 2>&1 | tee .sisyphus/evidence/task-1-metadata-order.log`
    Expected: Command exits 0 and log contains `[PASS] test_store_buffer_commit: PASS`
    Evidence: .sisyphus/evidence/task-1-metadata-order.log
  ```

  **Commit**: YES | Message: `fix(rtl): stabilize metadata ordering and flush epoch` | Files: [`rtl/adam_riscv_v2.v`]

- [ ] 2. Replace the old bench memory contract with explicit shared-memory + TUBE observability

  **What to do**: Update `comp_test/tb_v2.sv` and `comp_test/test_content.sv` so future MMIO decode no longer depends on the old `0x1300_0000 -> DRAM[0]` alias. Introduce one explicit shared-memory preload target under the future `u_mem_subsys` hierarchy and one explicit `tube_status` observation point. Preserve the current ROM image convention: load `inst.hex` at physical `0x0000_0000`, load `data.hex` at physical `0x0000_1000`, and keep existing golden DRAM result checks readable from the shared RAM array. Convert PASS/FAIL wait logic to watch `tube_status == 8'h04` instead of `TB_DRAM.mem[0][7:0]`.
  **Must NOT do**: Do not change the current ELF/linker base addresses or remove the ability to inspect word-addressed RAM contents from the testbench.

  **Recommended Agent Profile**:
  - Category: `tb` — Reason: testbench contract migration is the prerequisite that prevents MMIO decode from silently breaking all tests.
  - Skills: []
  - Omitted: [`verilog-lint`] — this task is mostly bench/test-content structure, not core RTL logic.

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: 4, 8, 12 | Blocked By: none

  **References**:
  - Pattern: `comp_test/tb_v2.sv:1-60` — current bench has separate `TB_IROM` and `TB_DRAM` preload paths.
  - Pattern: `comp_test/test_content.sv` — PASS/FAIL currently keys off DRAM word 0 alias behavior.
  - Pattern: `rtl/stage_mem.v:39-69` — current D-side backing memory is still direct `data_memory`.
  - Pattern: `README.md:456-464` — these P2 tasks will replace the direct-memory assumption and need an updated bench contract.

  **Acceptance Criteria**:
  - [ ] `iverilog -g2012 -s tb_v2 -o comp_test/out_iverilog/bin/task2_tb.out -I rtl rtl/*.v libs/REG_ARRAY/SRAM/ram_bfm.v comp_test/tb_v2.sv` exits 0.
  - [ ] `python verification/run_all_tests.py --basic --tests test1.s test2.S test_rv32i_full.s` exits 0 using the new explicit `tube_status` pass condition.

  **QA Scenarios**:
  ```
  Scenario: Shared memory preload preserves legacy core tests
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s test2.S test_rv32i_full.s 2>&1 | tee .sisyphus/evidence/task-2-bench-compat.log`
    Expected: Command exits 0 and all three named tests show `[PASS]`
    Evidence: .sisyphus/evidence/task-2-bench-compat.log

  Scenario: PASS marker is driven by explicit TUBE observation logic
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s 2>&1 | tee .sisyphus/evidence/task-2-tube-status.log && grep -n "tube_status" comp_test/tb_v2.sv comp_test/test_content.sv >> .sisyphus/evidence/task-2-tube-status.log`
    Expected: Command exits 0; test1 PASSes; evidence contains `tube_status` references instead of DRAM[0]-based completion logic
    Evidence: .sisyphus/evidence/task-2-tube-status.log
  ```

  **Commit**: YES | Message: `test(tb): migrate preload and completion hooks for shared memory` | Files: [`comp_test/tb_v2.sv`, `comp_test/test_content.sv`]

- [ ] 3. Centralize P2 MMIO address constants for RTL and new ROM tests

  **What to do**: Add one RTL-visible source of truth and one ROM-visible source of truth for the new P2 address map. In RTL, extend `rtl/define_v2.v` with named constants for cacheable RAM window, TUBE MMIO, CLINT low/high words, and PLIC single-context registers. In ROM tests, add `rom/p2_mmio.inc` with matching `.equ` constants. Use these exact addresses: RAM cacheable window `0x0000_0000-0x0000_3FFF`; TUBE `0x1300_0000`; CLINT `mtimecmp_lo=0x02004000`, `mtimecmp_hi=0x02004004`, `mtime_lo=0x0200BFF8`, `mtime_hi=0x0200BFFC`; PLIC `priority1=0x0C000004`, `pending=0x0C001000`, `enable=0x0C002000`, `threshold=0x0C200000`, `claim_complete=0x0C200004`.
  **Must NOT do**: Do not add MSIP or extra PLIC sources in this task.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: constants must be stable before mem_subsys and interrupt ROMs are implemented.
  - Skills: []
  - Omitted: [`tb`] — no bench behavior change in this task.

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: 4, 8, 10, 11, 12 | Blocked By: none

  **References**:
  - Pattern: `rom/harvard_link.ld` — current ROM layout remains `.text=0x0`, `.data=0x1000` and must stay untouched.
  - Pattern: `rtl/stage_mem.v:41-69` — current memory logic has no explicit MMIO decode, so named constants are needed before refactor.
  - External: `https://github.com/riscv/riscv-isa-manual/blob/8fb383a4d78129dc92f5530fa3d927112eccd5c1/src/machine.adoc#L2555-L2627` — timer interrupt semantics and RV32 split-write constraints.
  - External: `https://github.com/riscv/riscv-plic-spec/blob/f8ec1b7e9b1a92c34af8e0ab7eb33838813785a3/riscv-plic.adoc#L203-L246` — PLIC machine-context register model.

  **Acceptance Criteria**:
  - [ ] `grep -n "TUBE\|CLINT\|PLIC\|0x02004000\|0x0C200004" rtl/define_v2.v rom/p2_mmio.inc` returns the centralized constants.
  - [ ] No new ROM test added later hardcodes any of the above addresses outside `rom/p2_mmio.inc`.

  **QA Scenarios**:
  ```
  Scenario: RTL and ROM use the same address map
    Tool: Bash
    Steps: Run `grep -n "0x02004000\|0x0200BFF8\|0x0C000004\|0x13000000" rtl/define_v2.v rom/p2_mmio.inc 2>&1 | tee .sisyphus/evidence/task-3-mmio-map.log`
    Expected: All chosen addresses appear in the two canonical files and nowhere else in new P2 test sources
    Evidence: .sisyphus/evidence/task-3-mmio-map.log

  Scenario: No stray hardcoded addresses in P2 tests
    Tool: Bash
    Steps: After adding the new tests, run `grep -R "02004000\|0200BFF8\|0C200004" rom/ --exclude=p2_mmio.inc 2>&1 | tee .sisyphus/evidence/task-3-no-strays.log`
    Expected: Command prints no stray P2 hardcoded addresses outside the include file
    Evidence: .sisyphus/evidence/task-3-no-strays.log
  ```

  **Commit**: YES | Message: `chore(mmio): centralize p2 address map constants` | Files: [`rtl/define_v2.v`, `rom/p2_mmio.inc`]

- [ ] 4. Introduce `mem_subsys` scaffold with shared RAM and explicit uncached MMIO decode

  **What to do**: Add `rtl/mem_subsys.v` and one shared backing RAM model under it. This wrapper becomes the only lower-memory endpoint used by `adam_riscv_v2`. Implement explicit decode for four address classes: cacheable RAM window, TUBE MMIO, CLINT MMIO region, PLIC MMIO region. In this task, RAM accesses may still bypass L2 and go directly to the shared RAM model; the goal is to establish the permanent interface, shared array hierarchy, and MMIO behavior. Export `tube_status` as an observable register for the testbench. Keep CLINT/PLIC registers stubbed but addressable, returning zero until Tasks 10-11.
  **Must NOT do**: Do not add L2 hit/miss policy here; do not leave any direct `stage_mem` or `inst_backing_store` access path active in top-level after this scaffold lands.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is the permanent subsystem boundary for both roadmap items.
  - Skills: [`verilog-lint`] — lint new wrapper/module boundaries immediately.
  - Omitted: [`verification`] — dedicated feature tests come later.

  **Parallelization**: Can Parallel: NO | Wave 1 | Blocks: 5, 6, 10, 11 | Blocked By: 1, 2, 3

  **References**:
  - Pattern: `rtl/inst_memory.v:41-111` — active I-side path currently owns fill and backing-store behavior.
  - Pattern: `rtl/lsu_shell.v:159-223` — active D-side memory interface and store-buffer drain seam.
  - Pattern: `rtl/stage_mem.v:19-69` — current direct RAM + store-buffer drain behavior to preserve functionally before L2 insertion.
  - Pattern: `comp_test/tb_v2.sv:1-60` — shared memory hierarchy must remain preloadable/inspectable.

  **Acceptance Criteria**:
  - [ ] `iverilog -g2012 -s tb_v2 -o comp_test/out_iverilog/bin/task4_memsubsys.out -I rtl rtl/*.v libs/REG_ARRAY/SRAM/ram_bfm.v comp_test/tb_v2.sv` exits 0.
  - [ ] `python verification/run_all_tests.py --basic --tests test1.s test2.S test_store_buffer_simple.s` exits 0 using `mem_subsys` as the only lower-memory path.

  **QA Scenarios**:
  ```
  Scenario: Shared RAM path preserves old functional tests before L2 is enabled
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s test2.S test_store_buffer_simple.s 2>&1 | tee .sisyphus/evidence/task-4-memsubsys-smoke.log`
    Expected: Command exits 0 and all three tests PASS
    Evidence: .sisyphus/evidence/task-4-memsubsys-smoke.log

  Scenario: TUBE decode exists as an explicit MMIO path in the new subsystem
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s 2>&1 | tee .sisyphus/evidence/task-4-tube-mmio.log && grep -n "tube_status\|TUBE" rtl/mem_subsys.v >> .sisyphus/evidence/task-4-tube-mmio.log`
    Expected: Command exits 0; test1 PASSes; evidence shows explicit TUBE decode/state in `rtl/mem_subsys.v`
    Evidence: .sisyphus/evidence/task-4-tube-mmio.log
  ```

  **Commit**: YES | Message: `feat(mem): add shared memory subsystem scaffold` | Files: [`rtl/mem_subsys.v`, `rtl/adam_riscv_v2.v`, shared RAM helper]

- [ ] 5. Export `inst_memory` refill traffic to top-level and attach it to `mem_subsys`

  **What to do**: Refactor `rtl/inst_memory.v` so the ICache refill interface becomes an external top-level client port instead of being locally terminated by `icache_mem_adapter`. Remove the direct I-side bypass dependency on `inst_backing_store` for normal fetch completion, but preserve the backing-store hierarchy only for preload compatibility if still needed by the bench. In `rtl/adam_riscv_v2.v`, route the new I-side request/response signals into `u_mem_subsys` as master 0.
  **Must NOT do**: Do not change `stage_if_v2` fetch semantics, epoch handling, or fetch-buffer behavior in this task.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is the I-side half of the shared L2/arbiter integration.
  - Skills: [`verilog-lint`] — interface refactor across modules.
  - Omitted: [`tb`] — bench contract already handled in Task 2.

  **Parallelization**: Can Parallel: YES | Wave 2 | Blocks: 7 | Blocked By: 4

  **References**:
  - Pattern: `rtl/adam_riscv_v2.v:132-153` — stage_if_v2 currently hides all I-side downstream routing.
  - Pattern: `rtl/inst_memory.v:41-111` — current ICache refill interface and local adapter termination.
  - Pattern: `verification/run_riscv_tests.py:270-293` — all regressions compile `rtl/*.v`, so new top-level ports are automatically included.

  **Acceptance Criteria**:
  - [ ] `iverilog -g2012 -s tb_v2 -o comp_test/out_iverilog/bin/task5_iport.out -I rtl rtl/*.v libs/REG_ARRAY/SRAM/ram_bfm.v comp_test/tb_v2.sv` exits 0.
  - [ ] `python verification/run_all_tests.py --basic --tests test_rv32i_full.s` exits 0 with the I-side path served through `mem_subsys`.

  **QA Scenarios**:
  ```
  Scenario: I-side fetch path still boots and runs a long instruction stream
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rv32i_full.s 2>&1 | tee .sisyphus/evidence/task-5-iport.log`
    Expected: Command exits 0 and log contains `[PASS] test_rv32i_full: PASS`
    Evidence: .sisyphus/evidence/task-5-iport.log

  Scenario: Inst-memory top-level port export is visible and used
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rv32i_full.s 2>&1 | tee .sisyphus/evidence/task-5-iport-latency.log && grep -n "mem_req\|mem_resp" rtl/inst_memory.v rtl/adam_riscv_v2.v >> .sisyphus/evidence/task-5-iport-latency.log`
    Expected: Command exits 0; test_rv32i_full PASSes; evidence shows top-level I-side request/response plumbing in the modified files
    Evidence: .sisyphus/evidence/task-5-iport-latency.log
  ```

  **Commit**: YES | Message: `refactor(icache): externalize inst_memory refill port` | Files: [`rtl/inst_memory.v`, `rtl/adam_riscv_v2.v`, optional preload helper]

- [ ] 6. Convert the D-side LSU path from fixed-latency RAM reads to `mem_subsys` request/response handshakes

  **What to do**: Change `rtl/lsu_shell.v` and its top-level integration so loads/stores no longer assume the old single-cycle `stage_mem` semantics. Add one outstanding D-side transaction state machine in `lsu_shell`: accept a request only when no prior D request is pending, hold request metadata until `mem_resp_valid`, and allow store-buffer drains to use the same D-side master port arbitration through `mem_subsys`. Replace the old direct `stage_mem` instance in `adam_riscv_v2.v` with the D-side `mem_subsys` client port.
  **Must NOT do**: Do not enable `l1_dcache_nb` or add multiple outstanding D requests.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: LSU latency contract must be made compatible with a real lower-level memory system.
  - Skills: [`verilog-lint`] — handshake/state-machine changes are easy to break.
  - Omitted: [`tb`] — no new bench behavior should be added here.

  **Parallelization**: Can Parallel: YES | Wave 2 | Blocks: 7 | Blocked By: 4

  **References**:
  - Pattern: `rtl/lsu_shell.v:159-223` — current D-side memory contract and store-buffer drain signals.
  - Pattern: `rtl/lsu_shell.v:232-269` — current one-cycle pending request metadata logic.
  - Pattern: `rtl/adam_riscv_v2.v:833-949` — current LSU-to-stage_mem top-level integration.
  - Pattern: `rtl/stage_mem.v:39-69` — old fixed-latency direct RAM semantics being replaced.

  **Acceptance Criteria**:
  - [ ] `iverilog -g2012 -s tb_v2 -o comp_test/out_iverilog/bin/task6_dport.out -I rtl rtl/*.v libs/REG_ARRAY/SRAM/ram_bfm.v comp_test/tb_v2.sv` exits 0.
  - [ ] `python verification/run_all_tests.py --basic --tests test_store_buffer_simple.s test_store_buffer_forwarding.s test_store_buffer_hazard.s` exits 0.

  **QA Scenarios**:
  ```
  Scenario: D-side loads/stores survive variable-latency memory path
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_store_buffer_simple.s test_store_buffer_forwarding.s 2>&1 | tee .sisyphus/evidence/task-6-dport.log`
    Expected: Command exits 0 and both tests PASS
    Evidence: .sisyphus/evidence/task-6-dport.log

  Scenario: Hazard handling still prevents incorrect speculative reads
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_store_buffer_hazard.s 2>&1 | tee .sisyphus/evidence/task-6-dhazard.log`
    Expected: Command exits 0 and log contains `[PASS] test_store_buffer_hazard: PASS`
    Evidence: .sisyphus/evidence/task-6-dhazard.log
  ```

  **Commit**: YES | Message: `refactor(lsu): support variable-latency mem_subsys responses` | Files: [`rtl/lsu_shell.v`, `rtl/adam_riscv_v2.v`]

- [ ] 7. Implement the blocking unified `l2_cache` and 2-master `l2_arbiter` inside `mem_subsys`

  **What to do**: Add `rtl/l2_cache.v` and `rtl/l2_arbiter.v`, then integrate both into `rtl/mem_subsys.v`. Use a blocking, one-outstanding-miss unified cache with 32-byte lines, 4 ways, and 8 KiB total capacity. Arbitration policy is deterministic round-robin between master 0 (I-side refill) and master 1 (D-side LSU/store path), with the grant pointer toggled after each accepted request. RAM-window accesses are cacheable; TUBE/CLINT/PLIC are uncached and bypass the L2 entirely. L2 write policy is write-back + write-allocate for RAM-window stores only.
  **Must NOT do**: Do not add non-blocking misses, multiple MSHRs, PTW traffic, or D-cache integration.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is the core P2 cache deliverable.
  - Skills: [`verilog-lint`] — new cache/arbiter modules require structural validation.
  - Omitted: [`verification`] — dedicated tests come in Task 8.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: 8 | Blocked By: 5, 6

  **References**:
  - Pattern: `rtl/inst_memory.v:64-94` — current ICache refill request/response contract to preserve.
  - Pattern: `rtl/lsu_shell.v:202-227` — store-buffer drain signals that must reach the shared memory path.
  - Pattern: `rtl/stage_mem.v:50-63` — backing RAM width/depth expectations (4096 words, 32-bit words).
  - External: `README.md:463` — roadmap goal explicitly calls for unified L2 + arbiter.

  **Acceptance Criteria**:
  - [ ] `iverilog -g2012 -s tb_v2 -o comp_test/out_iverilog/bin/task7_l2.out -I rtl rtl/*.v libs/REG_ARRAY/SRAM/ram_bfm.v comp_test/tb_v2.sv` exits 0.
  - [ ] `python verification/run_all_tests.py --basic --tests test1.s test2.S test_rv32i_full.s` exits 0 with L2 enabled for the RAM window.
  - [ ] Simulation evidence shows uncached MMIO bypass for TUBE while cacheable RAM traffic uses L2.

  **QA Scenarios**:
  ```
  Scenario: Unified L2 serves both instruction refills and data accesses
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s test_rv32i_full.s 2>&1 | tee .sisyphus/evidence/task-7-l2-smoke.log`
    Expected: Command exits 0 and both tests PASS with L2 enabled
    Evidence: .sisyphus/evidence/task-7-l2-smoke.log

  Scenario: MMIO decode is statically bypassed around the L2
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s 2>&1 | tee .sisyphus/evidence/task-7-mmio-bypass.log && grep -n "uncached\|CLINT\|PLIC\|TUBE" rtl/mem_subsys.v rtl/l2_cache.v >> .sisyphus/evidence/task-7-mmio-bypass.log`
    Expected: Command exits 0; test1 PASSes; evidence shows explicit uncached MMIO decode separate from L2 cacheable RAM path
    Evidence: .sisyphus/evidence/task-7-mmio-bypass.log
  ```

  **Commit**: YES | Message: `feat(cache): add unified blocking l2 and arbiter` | Files: [`rtl/l2_cache.v`, `rtl/l2_arbiter.v`, `rtl/mem_subsys.v`, integration files]

- [ ] 8. Add L2-specific ROM tests and fold them into `run_all_tests.py --basic`

  **What to do**: Add exactly three dedicated L2 tests: `rom/test_l2_icache_refill.s`, `rom/test_l2_i_d_arbiter.s`, and `rom/test_l2_mmio_bypass.s`. Update `comp_test/test_content.sv` to recognize each test and check deterministic memory results plus one deterministic debug signal or counter exported by `mem_subsys`/`l2_arbiter`/`l2_cache`. Update `verification/run_all_tests.py` so these three tests are included in the default `--basic` list after the existing Store Buffer tests.
  **Must NOT do**: Do not hide failures behind generic PASS markers; every new test must have its own signature and its own golden checks.

  **Recommended Agent Profile**:
  - Category: `verification` — Reason: this task is mostly directed ROM coverage and regression flow integration.
  - Skills: []
  - Omitted: [`rtl`] — core cache logic should already exist from Task 7.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: 12, F1-F4 | Blocked By: 2, 3, 7

  **References**:
  - Pattern: `verification/run_all_tests.py:101-147` — current `--basic` list and compile/run loop.
  - Pattern: `comp_test/tb_v2.sv:72-105` — bench includes shared `test_content.sv` pass/fail handling.
  - Pattern: `comp_test/test_content.sv` — existing per-test signature/golden structure to extend.

  **Acceptance Criteria**:
  - [ ] `python verification/run_all_tests.py --basic --tests test_l2_icache_refill.s test_l2_i_d_arbiter.s test_l2_mmio_bypass.s` exits 0.
  - [ ] `python verification/run_all_tests.py --basic` includes all three new L2 tests in the summary and exits 0.

  **QA Scenarios**:
  ```
  Scenario: Dedicated L2 tests pass in isolation
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_l2_icache_refill.s test_l2_i_d_arbiter.s test_l2_mmio_bypass.s 2>&1 | tee .sisyphus/evidence/task-8-l2-tests.log`
    Expected: Command exits 0 and all three new tests report PASS
    Evidence: .sisyphus/evidence/task-8-l2-tests.log

  Scenario: New L2 tests are part of maintained basic regression
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic 2>&1 | tee .sisyphus/evidence/task-8-l2-basic.log`
    Expected: Summary includes the three `test_l2_*` entries and exits 0
    Evidence: .sisyphus/evidence/task-8-l2-basic.log
  ```

  **Commit**: YES | Message: `test(cache): add l2 targeted tests and basic-flow integration` | Files: [`rom/test_l2_*.s`, `comp_test/test_content.sv`, `verification/run_all_tests.py`]

- [ ] 9. Add minimal SYSTEM/CSR/trap plumbing and top-level trap redirect support

  **What to do**: Extend decode/control so `SYSTEM` opcode support exists for `CSRRW`, `CSRRS`, `CSRRC`, `CSRRWI`, `CSRRSI`, `CSRRCI`, and `MRET`. Keep `ECALL`, `EBREAK`, `WFI`, `SFENCE.VMA`, and vectored `mtvec` explicitly out of scope in this task. Add a dedicated smoke ROM `rom/test_csr_mret_smoke.s` for this task only. Wire a live `csr_unit` into `adam_riscv_v2`, route CSR reads/writes through a dedicated serialized path (single issue only; block dual-issue pairing when either slot is a SYSTEM op), and add a separate trap redirect mux that overrides branch redirect when a trap/return is taken. Interrupt/trap support is valid only when `SMT_MODE=0`; when `SMT_MODE=1`, leave interrupts masked and document that behavior in comments/tests.
  **Must NOT do**: Do not add delegation, nested interrupts, or per-thread CSR state.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is the architectural interrupt-enablement prerequisite.
  - Skills: [`verilog-lint`] — decode and top-level control changes must compile cleanly.
  - Omitted: [`build`] — feature tests come after CLINT/PLIC land.

  **Parallelization**: Can Parallel: NO | Wave 3 | Blocks: 10, 11, 12 | Blocked By: 1

  **References**:
  - Pattern: `rtl/stage_is.v:42-115` — current decode only supports ALU/load/store/branch/jump classes.
  - Pattern: `rtl/ctrl.v:15-33` — current control logic has no SYSTEM opcode handling.
  - Pattern: `rtl/decoder_dual.v:177-206` — illegal/invalid instructions are currently dropped rather than trapped; SYSTEM serialization must fit this decoder boundary.
  - Pattern: `rtl/csr_unit.v:41-69` — CSR request interface and trap outputs already exist.
  - Pattern: `rtl/csr_unit.v:109-216` — current trap entry/MRET semantics and CSR storage behavior.
  - Pattern: `rtl/adam_riscv_v2.v:1081-1108` — `csr_unit` is present but tied off today.
  - Pattern: `rtl/adam_riscv_v2.v:132-153` — top-level already has one redirect point to extend.

  **Acceptance Criteria**:
  - [ ] `iverilog -g2012 -s tb_v2 -o comp_test/out_iverilog/bin/task9_csr.out -I rtl rtl/*.v libs/REG_ARRAY/SRAM/ram_bfm.v comp_test/tb_v2.sv` exits 0.
  - [ ] `python verification/run_all_tests.py --basic --tests test_csr_mret_smoke.s` exits 0 after this task adds the smoke ROM.

  **QA Scenarios**:
  ```
  Scenario: CSR writes/readbacks and MRET path function in machine mode
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_csr_mret_smoke.s 2>&1 | tee .sisyphus/evidence/task-9-csr-smoke.log`
    Expected: Command exits 0; `mtvec` readback matches the written value; trap return lands on `mepc`; test PASSes
    Evidence: .sisyphus/evidence/task-9-csr-smoke.log

  Scenario: SYSTEM ops are serialized and do not dual-issue with normal instructions
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_csr_mret_smoke.s 2>&1 | tee .sisyphus/evidence/task-9-csr-serialize.log && grep -n "SYSTEM\|csr\|mret" rtl/stage_is.v rtl/ctrl.v rtl/decoder_dual.v >> .sisyphus/evidence/task-9-csr-serialize.log`
    Expected: Command exits 0 and evidence shows explicit SYSTEM decoding plus serialized handling in the modified decode files
    Evidence: .sisyphus/evidence/task-9-csr-serialize.log
  ```

  **Commit**: YES | Message: `feat(csr): wire system decode and trap redirect path` | Files: [`rtl/stage_is.v`, `rtl/ctrl.v`, `rtl/decoder_dual.v`, `rtl/adam_riscv_v2.v`, `rom/test_csr_mret_smoke.s`, supporting RTL]

- [ ] 10. Implement `clint.v` and machine timer interrupt delivery through `csr_unit`

  **What to do**: Add `rtl/clint.v` with 64-bit `mtime` and 64-bit `mtimecmp`, using the exact addresses from Task 3. Increment `mtime` every clock, implement RV32 split low/high word accesses, and derive MTIP pending when `mtime >= mtimecmp`. Feed MTIP into `csr_unit` by extending `csr_unit` with external pending inputs and internal `mip` maintenance for the MTIP bit. Interrupt entry must use direct-mode `mtvec` and write `mcause = 32'h8000_0007`. When an interrupt is armed, stop new dispatch, drain to a precise boundary, then take the trap under `SMT_MODE=0` only. Add the dedicated module test `rom/test_clint_timer_interrupt.s` in this task, but do not integrate it into the default `--basic` list until Task 12.
  **Must NOT do**: Do not add MSIP or software interrupt handling.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: CLINT is a new MMIO device plus CSR/trap-side integration.
  - Skills: [`verilog-lint`] — multiword register and interrupt wiring changes.
  - Omitted: [`tb`] — bench stimulus is only needed for PLIC, not timer.

  **Parallelization**: Can Parallel: YES | Wave 3 | Blocks: 12 | Blocked By: 4, 9

  **References**:
  - Pattern: `rtl/csr_unit.v:77-107` — `mip`, `mie`, and global interrupt enable live here.
  - Pattern: `rtl/csr_unit.v:179-216` — current trap-entry update behavior to reuse for timer interrupts.
  - External: `https://github.com/riscv/riscv-isa-manual/blob/8fb383a4d78129dc92f5530fa3d927112eccd5c1/src/machine.adoc#L2555-L2627` — machine timer semantics and RV32 split-write rule.
  - External: `https://github.com/riscv/riscv-aclint/blob/4e570bfd3201f2c09e5afd290b5091526b0f099a/riscv-aclint.adoc#L157-L211` — ACLINT-compatible MTIMER register model.

  **Acceptance Criteria**:
  - [ ] `python verification/run_all_tests.py --basic --tests test_clint_timer_interrupt.s` exits 0.
  - [ ] The test proves timer interrupt mask/enable behavior and trap cause `0x80000007` under `SMT_MODE=0`.

  **QA Scenarios**:
  ```
  Scenario: Timer interrupt fires only when enabled and compare expires
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_clint_timer_interrupt.s 2>&1 | tee .sisyphus/evidence/task-10-clint.log`
    Expected: Command exits 0; log shows PASS; golden checks confirm handler execution and `mcause=0x80000007`
    Evidence: .sisyphus/evidence/task-10-clint.log

  Scenario: RV32 split-write sequence does not cause a false early timer interrupt
    Tool: Bash
    Steps: Add a phase in `test_clint_timer_interrupt.s` that writes `mtimecmp` high/low/high using the spec-safe sequence, then rerun and capture output
    Expected: No interrupt is taken before the final intended compare value becomes active
    Evidence: .sisyphus/evidence/task-10-clint-splitwrite.log
  ```

  **Commit**: YES | Message: `feat(clint): add machine timer interrupt path` | Files: [`rtl/clint.v`, `rtl/csr_unit.v`, `rtl/mem_subsys.v`, `rom/test_clint_timer_interrupt.s`, integration files]

- [ ] 11. Implement `plic.v` and machine external interrupt delivery with claim/complete

  **What to do**: Add `rtl/plic.v` for exactly one external source (ID 1) and one machine-mode context. Implement priority register 1, pending bit, enable bit, threshold register, and claim/complete register at the exact addresses from Task 3. Feed MEIP into `csr_unit` by extending pending-bit inputs and trap cause generation for `mcause = 32'h8000_000B`. Update `tb_v2.sv` to drive the external source line only when running `test_plic_external_interrupt.s` or `test_interrupt_mask_mret.s`, based on the ROM signature or an explicit testbench knob. Require claim to clear the pending bit atomically and completion to re-arm the source for the next interrupt. Add the dedicated module test `rom/test_plic_external_interrupt.s` in this task, but do not integrate it into the default `--basic` list until Task 12.
  **Must NOT do**: Do not add multiple PLIC sources or nested priority contexts.

  **Recommended Agent Profile**:
  - Category: `tb` — Reason: this task spans RTL device logic and deterministic external interrupt stimulus.
  - Skills: []
  - Omitted: [`build`] — full-flow rerun belongs to Task 12.

  **Parallelization**: Can Parallel: YES | Wave 3 | Blocks: 12 | Blocked By: 4, 9

  **References**:
  - Pattern: `comp_test/tb_v2.sv:20-23` — top-level instantiation point to extend with an external IRQ input if needed.
  - Pattern: `rtl/csr_unit.v:109-216` — reuse trap state update path once MEIP is exposed.
  - External: `https://github.com/riscv/riscv-plic-spec/blob/f8ec1b7e9b1a92c34af8e0ab7eb33838813785a3/riscv-plic.adoc#L203-L246` — PLIC register blocks.
  - External: `https://github.com/riscv/riscv-plic-spec/blob/f8ec1b7e9b1a92c34af8e0ab7eb33838813785a3/riscv-plic.adoc#L433-L491` — claim/complete and priority semantics.

  **Acceptance Criteria**:
  - [ ] `python verification/run_all_tests.py --basic --tests test_plic_external_interrupt.s` exits 0.
  - [ ] The test proves priority/enable/threshold/claim-complete behavior and trap cause `0x8000000B` under `SMT_MODE=0`.

  **QA Scenarios**:
  ```
  Scenario: External interrupt traps only when enabled and above threshold
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_plic_external_interrupt.s 2>&1 | tee .sisyphus/evidence/task-11-plic.log`
    Expected: Command exits 0; handler executes only after enable + threshold allow source 1; `mcause=0x8000000B`
    Evidence: .sisyphus/evidence/task-11-plic.log

  Scenario: Claim/complete and masked-source edge cases behave correctly
    Tool: Bash
    Steps: In the same or a paired ROM sequence, claim the interrupt, verify pending clears, raise the source again only after completion, and test threshold masking; capture log
    Expected: Claim may return 0 when nothing is pending; masked source does not trap; source 1 retriggers only after completion
    Evidence: .sisyphus/evidence/task-11-plic-claim.log
  ```

  **Commit**: YES | Message: `feat(plic): add machine external interrupt path` | Files: [`rtl/plic.v`, `rtl/csr_unit.v`, `rtl/mem_subsys.v`, `comp_test/tb_v2.sv`, `rom/test_plic_external_interrupt.s`, integration files]

- [ ] 12. Add interrupt-specific ROM tests and integrate all new P2 tests into the maintained regression flow

  **What to do**: Add the final interrupt regression test `rom/test_interrupt_mask_mret.s`, then integrate all three interrupt-directed tests — `rom/test_clint_timer_interrupt.s`, `rom/test_plic_external_interrupt.s`, and `rom/test_interrupt_mask_mret.s` — into the maintained `--basic` flow. The timer test must prove MTIP delivery and spec-safe `mtimecmp` programming. The PLIC test must prove priority/enable/threshold/claim-complete behavior. The mask/MRET test must prove that pending-but-disabled interrupts do not trap, and that `MRET` restores execution to the interrupted PC. Update `comp_test/test_content.sv` with explicit signature detection and per-test goldens. Update `verification/run_all_tests.py` so the three interrupt tests are appended to the default `--basic` list after the three L2 tests. Then rerun the full suite: basic + riscv-tests + riscv-arch-test.
  **Must NOT do**: Do not mark the roadmap complete unless the full combined regression rerun is green.

  **Recommended Agent Profile**:
  - Category: `verification` — Reason: this task is directed coverage plus final regression integration.
  - Skills: []
  - Omitted: [`rtl`] — feature logic should already be complete by Tasks 10-11.

  **Parallelization**: Can Parallel: NO | Wave 3 | Blocks: F1-F4 | Blocked By: 2, 3, 10, 11

  **References**:
  - Pattern: `verification/run_all_tests.py:101-147` — extend the maintained `--basic` list in one place.
  - Pattern: `verification/run_riscv_tests.py:270-293` — full regression still compiles all RTL files through the same bench.
  - Pattern: `comp_test/tb_v2.sv:63-105` — current bench pass/fail behavior and debug print style.
  - Pattern: `README.md:463-464` — these are the two roadmap items being closed out.

  **Acceptance Criteria**:
  - [ ] `python verification/run_all_tests.py --basic --tests test_clint_timer_interrupt.s test_plic_external_interrupt.s test_interrupt_mask_mret.s` exits 0.
  - [ ] `python verification/run_all_tests.py --basic` exits 0 and includes all six new P2 tests (`test_l2_*` + interrupt tests).
  - [ ] `python verification/run_all_tests.py --basic --riscv-tests --riscv-arch-test` exits 0.

  **QA Scenarios**:
  ```
  Scenario: Interrupt-directed tests pass in isolation
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_clint_timer_interrupt.s test_plic_external_interrupt.s test_interrupt_mask_mret.s 2>&1 | tee .sisyphus/evidence/task-12-int-targeted.log`
    Expected: Command exits 0 and all three interrupt tests PASS
    Evidence: .sisyphus/evidence/task-12-int-targeted.log

  Scenario: Full regression stays green after P2 integration
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --riscv-tests --riscv-arch-test 2>&1 | tee .sisyphus/evidence/task-12-full-regression.log`
    Expected: Command exits 0; summary shows the new `test_l2_*` and interrupt tests in `--basic`; riscv-tests and riscv-arch-test remain PASS
    Evidence: .sisyphus/evidence/task-12-full-regression.log
  ```

  **Commit**: YES | Message: `test(interrupts): integrate interrupt tests and rerun full regression` | Files: [`rom/test_interrupt_mask_mret.s`, `comp_test/test_content.sv`, `verification/run_all_tests.py`]

## Final Verification Wave (MANDATORY — after ALL implementation tasks)
> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.
> **Do NOT auto-proceed after verification. Wait for user's explicit approval before marking work complete.**
> **Never mark F1-F4 as checked before getting user's okay.** Rejection or user feedback -> fix -> re-run -> present again -> wait for okay.
- [ ] F1. Plan Compliance Audit — oracle
- [ ] F2. Code Quality Review — unspecified-high
- [ ] F3. Real Manual QA — unspecified-high (+ playwright if UI)
- [ ] F4. Scope Fidelity Check — deep

## Commit Strategy
- Commit 1: stabilize metadata + testbench contract before memory hierarchy changes
- Commit 2: add `mem_subsys` scaffold and shared RAM/MMIO decode without L2 enabled
- Commit 3: export I-side and D-side clients onto the new wrapper
- Commit 4: add `l2_cache` + `l2_arbiter` and land L2-specific tests
- Commit 5: add SYSTEM/CSR/trap plumbing for interrupt enablement
- Commit 6: add `clint` timer path and its dedicated tests
- Commit 7: add `plic` external path and its dedicated tests
- Commit 8: integrate new tests into `run_all_tests.py --basic` and rerun full regression

## Success Criteria
- Existing P0/P1 functionality remains green under the updated memory subsystem.
- The repo gains deterministic, named tests for L2 behavior and interrupt behavior.
- The basic/full regression entrypoints remain the single source of truth for validation.
- The implementation remains inside the explicit P2 boundaries documented above.
