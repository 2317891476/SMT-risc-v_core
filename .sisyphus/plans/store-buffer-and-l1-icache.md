# Store Buffer + L1 ICache for AdamRiscv V2

## TL;DR
> **Summary**: Add a minimal commit boundary that makes stores visible only at commit, then layer a conservative Store Buffer and a single-outstanding-miss ICache on top of explicit LSU/IF request-response contracts.
> **Deliverables**:
> - Build/test scripts aligned to real `rtl/` sources and hard regression gates
> - Per-thread `{tid, order_id, epoch}` metadata contract plus ROB-lite commit queue
> - Store Buffer with commit-gated drain, exact-match forwarding, and unresolved-older-store stall
> - ICache wrapper + single-miss hit-under-miss frontend path with stale-response kill
> - Directed ROM tests and evidence for each milestone plus full README regression after each major item
> **Effort**: XL
> **Parallel**: YES - 2 waves
> **Critical Path**: 1 → 2 → 5 → 6 → 7 → 8 → 9 and 3 → 4 → 10

## Context
### Original Request
- Implement P1 Store Buffer to eliminate speculative-store problems.
- Implement P1 L1 ICache to replace direct `inst_memory` fetch.
- After each completed item, run targeted tests plus the existing full regression suites documented in `README.md`.
- Produce a detailed plan for Sisyphus, including routing to subagents.

### Interview Summary
- Scope is fixed to **ROB-style commit boundary + Store Buffer (with forwarding, compatible with OoO execution) + single-outstanding-miss nonblocking L1 ICache**.
- The plan must include **interface refactors first**, because current V2 lacks both a real commit boundary and a ready/replay protocol.
- New directed ROM tests are allowed and required.
- Full regression is mandatory after each major milestone.

### Metis Review (gaps addressed)
- `wb*_valid` currently doubles as retirement, so the plan must split **writeback** from **architectural commit** before any Store Buffer work.
- Existing benches backdoor-load `u_inst_memory`, so ICache work must preserve or replace that preload contract explicitly.
- Acceptance criteria must use concrete commands and success markers, not vague “pipeline still works” language.
- Scope must stay minimal: no full ROB, no LSQ, no multi-miss ICache, no manual-only verification.

## Work Objectives
### Core Objective
Deliver a safe minimum architecture upgrade where speculative stores never reach memory before commit, younger killed work cannot update architectural state, and the frontend fetch path can tolerate one outstanding instruction miss without breaking redirect/flush semantics.

### Deliverables
- `verification/run_all_tests.py` and `verification/run_riscv_tests.py` compile the actual `rtl/` tree and remain the hard gate for milestone completion.
- A per-thread metadata contract `{tid, order_id, epoch}` exists and is carried through dispatch, issue, memory, and fetch-response boundaries.
- A per-thread ROB-lite / commit queue exists and is the only source of retire accounting and store release authorization.
- Store Buffer entries are speculative until commit, drained in-order per thread, and never written to memory on the wrong path.
- Loads either forward from the youngest older fully covering store, or stall/retry if an older store is unresolved or only partially overlaps.
- `stage_if_v2` no longer assumes fixed-latency `inst_memory`; it speaks an explicit request/response contract via a compatibility wrapper and then an ICache.
- `comp_test/tb_v2.sv` and `verification/riscof/adam_riscv/env/tb_riscof.sv` preload instruction backing storage through a stable hierarchy that survives the ICache change.
- Directed ROM tests exist for commit ordering, wrong-path store discard, store forwarding, unresolved-older-store blocking, miss-then-redirect, and stale-response suppression.

### Definition of Done (verifiable conditions with commands)
- `python verification/run_all_tests.py --basic --tests test_commit_order.s test_commit_flush_store.s` exits `0` and prints `PASS` for both tests.
- `python verification/run_all_tests.py --basic --tests test_store_buffer_commit.s test_store_buffer_forwarding.s test_store_buffer_hazard.s` exits `0` and prints `PASS` for all listed tests.
- `python verification/run_all_tests.py --basic --tests test_icache_redirect_miss.s test_icache_stale_return.s` exits `0` and prints `PASS` for both tests.
- `python verification/run_all_tests.py --basic --riscv-tests --riscv-arch-test` exits `0` and prints a final `Total:` line with `0 failed` semantics.
- `python verification/run_riscv_tests.py --suite riscv-tests` exits `0` and prints `Total: X/X passed` or an allowed documented near-total only if explicitly preserved by the repo’s known `fence_i` exception.
- `python verification/run_riscv_tests.py --suite riscv-arch-test` exits `0` and prints `Total: X/X passed`.

### Must Have
- Commit is the only point that may update architectural retire accounting and authorize store visibility.
- Flush kills are per-thread and keyed by `{tid, epoch}`.
- Store Buffer is conservative-correct before it is aggressive.
- ICache supports exactly one outstanding miss and hit-under-miss only when request/response metadata proves safety.
- Every milestone produces `.sisyphus/evidence/task-{N}-*.log` or `.vcd` artifacts.

### Must NOT Have (guardrails, AI slop patterns, scope boundaries)
- No full ROB with value storage.
- No LSQ, memory dependence prediction, speculative store drain, or multi-outstanding ICache misses.
- No precise exception/interrupt/FENCE.I/self-modifying-code support in this series.
- No silent weakening of existing regression gates.
- No plan step that requires manual waveform inspection to decide pass/fail.

## Verification Strategy
> ZERO HUMAN INTERVENTION — all verification is agent-executed.
- Test decision: **TDD (RED-GREEN-REFACTOR)** for directed ROM tests, then full regression.
- QA policy: Every task includes a happy-path scenario and a failure/edge scenario.
- Evidence: `.sisyphus/evidence/task-{N}-{slug}.{ext}`

## Execution Strategy
### Parallel Execution Waves
> Wave 1 builds the reusable contracts, benches, and gates. Wave 2 is intentionally more serial because the same architectural boundary is being changed.

Wave 1: 1) build gate hardening [build], 2) metadata/trace scaffolding [rtl], 3) IROM preload compatibility [tb], 4) IF req/resp shell [rtl], 5) LSU req/resp shell [rtl]

Wave 2: 6) ROB-lite commit queue [rtl], 7) commit-gated architectural state [rtl], 8) Store Buffer v1 [rtl], 9) forwarding + older-store hazards [rtl], 10) single-miss ICache [rtl]

### Dependency Matrix (full, all tasks)
- 1 blocks hard acceptance for all later tasks.
- 2 blocks 4, 5, 6, 7, 8, 9, 10.
- 3 blocks 10 and all ICache regression acceptance.
- 4 blocks 10.
- 5 blocks 8 and 9.
- 6 blocks 7, 8, 9.
- 7 blocks 8, 9, 10.
- 8 blocks 9.
- 9 does not block 10 functionally, but both must pass full regression before final verification.

### Agent Dispatch Summary (wave → task count → categories)
- Wave 1 → 5 tasks → `build`×1, `tb`×1, `rtl`×3
- Wave 2 → 5 tasks → `rtl`×5
- Final Verification → 4 tasks → `oracle`, `unspecified-high`, `unspecified-high`, `deep`

## TODOs
> Implementation + Test = ONE task. Never separate.

- [x] 1. Harden the regression gate to the real RTL tree

  **What to do**: Update `verification/run_all_tests.py`, `verification/run_riscv_tests.py`, and any related compile invocation to use the actual `rtl/` source tree instead of the stale `../module/CORE/RTL_V1_2/*.v` path. Keep the existing suite semantics, preserve `tb_v2.sv`, and capture the exact success markers used later in this plan.
  **Must NOT do**: Do not drop suites, special-case failures away, or change ROM memory-map assumptions.

  **Recommended Agent Profile**:
  - Category: `build` — Reason: this task is pure gatekeeping and flow repair.
  - Skills: `[]` — no special skill required.
  - Omitted: `["verilog-lint"]` — compile scripts, not RTL syntax, are the primary change.

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [6, 7, 8, 9, 10 hard acceptance] | Blocked By: []

  **References**:
  - Pattern: `verification/run_all_tests.py:93-179` — current compile and summary parsing logic
  - Pattern: `verification/run_riscv_tests.py:270-295` — stale V2 simulation compile path
  - Pattern: `comp_test/module_list_v2:1-27` — stale `../module/CORE/RTL_V1_2` source list
  - Pattern: `README.md:232-266` — documented full-regression command and expected summary format
  - API/Type: `rtl/` directory listing — actual source-of-truth RTL location

  **Acceptance Criteria**:
  - [ ] `python verification/run_all_tests.py --basic --tests test1.s test2.S test_rv32i_full.s` exits `0` and prints three `PASS` lines.
  - [ ] `python verification/run_riscv_tests.py --suite riscv-tests` exits `0` and prints `Total:`.
  - [ ] `python verification/run_riscv_tests.py --suite riscv-arch-test` exits `0` and prints `Total:`.

  **QA Scenarios**:
  ```
  Scenario: Basic regression still works through repaired paths
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s test2.S test_rv32i_full.s`
    Expected: Exit code 0; output contains `test1: PASS`, `test2: PASS`, `test_rv32i_full: PASS`
    Evidence: .sisyphus/evidence/task-1-build-gate.log

  Scenario: Missing test file fails cleanly
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests does_not_exist.s`
    Expected: Non-zero exit or `BUILD_FAIL` entry; runner prints a bounded failure message and does not crash
    Evidence: .sisyphus/evidence/task-1-build-gate-error.log
  ```

  **Commit**: YES | Message: `fix(build): point regressions at rtl sources` | Files: `verification/run_all_tests.py`, `verification/run_riscv_tests.py`, related compile manifests

- [x] 2. Add the common `{tid, order_id, epoch}` metadata contract and trace hooks

  **What to do**: Allocate a per-thread `order_id` at dispatch and a per-thread `epoch` that increments on flush/redirect. Carry this metadata through scoreboard allocation, execution/memory request paths, and fetch-response boundaries. Add machine-readable trace prints or dump buses for commit/flush debugging.
  **Must NOT do**: Do not claim commit semantics yet; this task is scaffolding only.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: metadata plumbing touches dispatch/issue/top-level interfaces.
  - Skills: `["verilog-lint"]` — modified RTL must stay syntax-clean.
  - Omitted: `[]` — no omission beyond standard routing.

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [4, 5, 6, 7, 8, 9, 10] | Blocked By: []

  **References**:
  - Pattern: `rtl/scoreboard_v2.v:757-799` — current dispatch allocation and `alloc_seq`
  - Pattern: `rtl/scoreboard_v2.v:727-739` — current per-thread flush cleanup anchor
  - Pattern: `rtl/adam_riscv_v2.v:67-69` — current thread flush generation
  - Pattern: `rtl/adam_riscv_v2.v:590-649` — memory request metadata leaving `exec_pipe1`
  - Pattern: `rtl/stage_if_v2.v:115-134` — current single-cycle-latency IF bookkeeping

  **Acceptance Criteria**:
  - [ ] RTL compiles with the repaired build flow and no syntax errors.
  - [ ] A directed trace run shows monotonic `order_id` allocation per thread and `epoch` increment on flush.
  - [ ] No existing basic test regresses.

  **QA Scenarios**:
  ```
  Scenario: Order IDs allocate monotonically on basic execution
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test2.S`; save trace output that includes `tid`, `order_id`, and `epoch`
    Expected: Per-thread `order_id` never decreases; `epoch` stays stable without flush
    Evidence: .sisyphus/evidence/task-2-metadata-trace.log

  Scenario: Branch flush bumps epoch and kills younger metadata domain
    Tool: Bash
    Steps: Run the existing branch-heavy `test_rv32i_full.s` and capture trace around a taken branch flush
    Expected: The flushed thread’s `epoch` increments once per redirect; no later trace line commits the old epoch
    Evidence: .sisyphus/evidence/task-2-metadata-trace-error.log
  ```

  **Commit**: YES | Message: `feat(core): add order and epoch metadata plumbing` | Files: `rtl/scoreboard_v2.v`, `rtl/adam_riscv_v2.v`, touched interface RTL

- [x] 3. Preserve bench preload compatibility behind a stable instruction backing-store wrapper

  **What to do**: Introduce an instruction backing-store wrapper or equivalent hierarchy so `tb_v2.sv` and `tb_riscof.sv` can preload program words without relying on `u_stage_if_v2.u_inst_memory.u_ram_data.mem[]`. Keep behavior identical to the current `inst_memory` path.
  **Must NOT do**: Do not change fetch semantics yet, and do not require benches to poke ICache internals directly.

  **Recommended Agent Profile**:
  - Category: `tb` — Reason: the key risk is bench and preload contract breakage.
  - Skills: `[]` — no special skill required.
  - Omitted: `["verilog-lint"]` — primary work is bench hierarchy compatibility, not core RTL logic.

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [10 acceptance] | Blocked By: [1]

  **References**:
  - Pattern: `comp_test/tb_v2.sv:2,36-45` — current direct preload macro and memory poke
  - Pattern: `verification/riscof/adam_riscv/env/tb_riscof.sv:58-64` — second direct preload site
  - Pattern: `rtl/stage_if_v2.v:73-80` — current `u_inst_memory` instantiation
  - Pattern: `rtl/inst_memory.v:2-67` — backing storage hierarchy that benches depend on today

  **Acceptance Criteria**:
  - [ ] `tb_v2.sv` can preload instructions through the new stable hierarchy and still pass `test1.s`.
  - [ ] `tb_riscof.sv` can preload instructions through the new stable hierarchy and still generate a signature dump.
  - [ ] No bench references `u_inst_memory.u_ram_data.mem` directly after this task.

  **QA Scenarios**:
  ```
  Scenario: V2 testbench preload compatibility remains intact
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s`
    Expected: Exit code 0; `test1: PASS`; preload uses the wrapper path rather than raw `u_inst_memory`
    Evidence: .sisyphus/evidence/task-3-preload-wrapper.log

  Scenario: RISCOF bench still initializes and dumps signature through the wrapper
    Tool: Bash
    Steps: Run one smoke compile/run of the RISCOF environment using the updated preload path
    Expected: Simulation starts, writes a signature file, and exits without hierarchy lookup errors
    Evidence: .sisyphus/evidence/task-3-preload-wrapper-error.log
  ```

  **Commit**: YES | Message: `refactor(tb): wrap instruction preload hierarchy` | Files: `comp_test/tb_v2.sv`, `verification/riscof/adam_riscv/env/tb_riscof.sv`, wrapper RTL if needed

- [x] 4. Refactor `stage_if_v2` to an explicit request/response shell without changing cache behavior yet

  **What to do**: Split the frontend contract into request accept and response return semantics. PC advances only on request accept. The response path must carry `{pc, tid, order_id/epoch-adjacent metadata as needed, inst}` while the implementation still delegates to the current backing store for now.
  **Must NOT do**: Do not add miss handling or cache state yet; this task only removes fixed-latency assumptions from the interface.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: frontend handshake semantics live in IF/top-level RTL.
  - Skills: `["verilog-lint"]` — frontend RTL changes must stay syntax-clean.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [10] | Blocked By: [2, 3]

  **References**:
  - Pattern: `rtl/stage_if_v2.v:49-52` — current PC stall policy tied only to `fb_ready`
  - Pattern: `rtl/stage_if_v2.v:104-134` — current one-cycle synchronous-RAM alignment logic
  - Pattern: `rtl/adam_riscv_v2.v:98-119` — top-level IF wiring into `fetch_buffer`
  - Pattern: `rtl/fetch_buffer.v:108-124` — current flush behavior at the frontend boundary

  **Acceptance Criteria**:
  - [ ] Existing basic tests still pass with IF request/response shell wrapped around the old backing store.
  - [ ] PC advances only when request accept fires, not merely because `fb_ready` is high.
  - [ ] Flush drops unaccepted or stale responses before they enter `fetch_buffer`.

  **QA Scenarios**:
  ```
  Scenario: Frontend shell preserves basic execution
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s test2.S`
    Expected: Exit code 0; both tests pass with no fetch starvation
    Evidence: .sisyphus/evidence/task-4-if-shell.log

  Scenario: Redirected fetch does not enqueue stale response
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rv32i_full.s` and capture frontend trace around a taken branch
    Expected: Response tagged with pre-flush epoch is dropped before `fetch_buffer` push
    Evidence: .sisyphus/evidence/task-4-if-shell-error.log
  ```

  **Commit**: YES | Message: `refactor(frontend): add explicit fetch req resp shell` | Files: `rtl/stage_if_v2.v`, `rtl/adam_riscv_v2.v`, frontend helper RTL

- [x] 5. Refactor the LSU path to an explicit request/response shell and scoreboard gating

  **What to do**: Replace the fire-and-forget load/store path with an explicit LSU contract: request valid/accept, response valid, and echoed metadata `{tid, order_id, epoch, tag, rd, func3}`. Update issue gating so scoreboard only selects a memory op when the LSU/store-side shell can accept it, or insert a tiny always-accept issue buffer.
  **Must NOT do**: Do not implement the Store Buffer itself yet, and do not bolt `mem_req_ready` onto `exec_pipe1` alone without scoreboard coordination.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is a cross-module contract change spanning issue, pipe1, and memory-stage plumbing.
  - Skills: `["verilog-lint"]` — multiple RTL files change.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [8, 9] | Blocked By: [1, 2]

  **References**:
  - Pattern: `rtl/exec_pipe1.v:171-182` — current combinational mem request export
  - Pattern: `rtl/adam_riscv_v2.v:660-744` — current direct `exec_pipe1 -> stage_mem -> stage_wb` path
  - Pattern: `rtl/scoreboard_v2.v:498-525` — current issue selection for load/store
  - Pattern: `rtl/stage_mem.v:45-53,80-97` — current immediate store visibility and 1-cycle load assumption
  - Pattern: `rtl/stage_wb.v:12-18,55-59` — current load shaping and address-lane dependency

  **Acceptance Criteria**:
  - [ ] Memory ops are only issued when the LSU shell accepts them.
  - [ ] Load responses return with enough metadata to match the correct in-flight op and epoch.
  - [ ] Existing basic tests still pass after the contract refactor.

  **QA Scenarios**:
  ```
  Scenario: LSU shell preserves legacy memory behavior
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s test2.S`
    Expected: Exit code 0; loads/stores still pass through the shell with correct final DRAM values
    Evidence: .sisyphus/evidence/task-5-lsu-shell.log

  Scenario: LSU backpressure never loses a memory request
    Tool: Bash
    Steps: Run a directed stress test with adjacent loads/stores and capture LSU accept/resp trace
    Expected: Every issued mem op has exactly one accept and, for loads, exactly one matching response with the same metadata
    Evidence: .sisyphus/evidence/task-5-lsu-shell-error.log
  ```

  **Commit**: YES | Message: `refactor(lsu): add explicit request response contract` | Files: `rtl/exec_pipe1.v`, `rtl/adam_riscv_v2.v`, `rtl/scoreboard_v2.v`, memory-path RTL

- [x] 6. Implement a per-thread ROB-lite commit queue and move retire accounting to commit

  **What to do**: Add a minimal per-thread commit queue allocated at dispatch. Track `order_id`, `epoch`, completion, flushed state, destination metadata, and `is_store`. Non-stores may still execute and write their result buses, but `instr_retired`/`instr_retired_1` and architectural completion accounting must move from WB to commit. Add directed ROMs `test_commit_order.s` and `test_commit_flush_store.s` in this task.
  **Must NOT do**: Do not store full result values in the ROB-lite, and do not expand into a full value-holding ROB.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is the central architectural change.
  - Skills: `["verilog-lint"]` — major RTL surgery across scoreboard/top-level/retire hooks.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [7, 8, 9] | Blocked By: [1, 2, 5]

  **References**:
  - Pattern: `rtl/scoreboard_v2.v:716-723` — current deallocation on WB tag match that must no longer equal architectural completion
  - Pattern: `rtl/adam_riscv_v2.v:758-821` — current WB-to-regfile and CSR retire accounting hookup
  - Pattern: `rtl/scoreboard_v2.v:384-392` — existing age-like branch serialization anchors
  - Test: `README.md:298-303` — existing basic ROM style and expected PASS model

  **Acceptance Criteria**:
  - [ ] `test_commit_order.s` passes and proves older ops retire before younger ops from the same thread.
  - [ ] `test_commit_flush_store.s` passes and proves a younger wrong-path op never retires after flush.
  - [ ] Full `--basic` regression still passes after retirement accounting moves to commit.

  **QA Scenarios**:
  ```
  Scenario: In-order commit survives out-of-order completion
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_order.s`
    Expected: Exit code 0; test prints `PASS`; commit trace shows head-of-queue retirement order only
    Evidence: .sisyphus/evidence/task-6-commit-queue.log

  Scenario: Younger wrong-path completion never retires
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_flush_store.s`
    Expected: Exit code 0; wrong-path destination register and retire counter remain untouched after flush
    Evidence: .sisyphus/evidence/task-6-commit-queue-error.log
  ```

  **Commit**: YES | Message: `feat(core): add rob lite commit queue` | Files: `rtl/adam_riscv_v2.v`, `rtl/scoreboard_v2.v`, new commit-queue RTL if split out, new ROM tests

- [x] 7. Gate architectural register and CSR visibility on commit, with strict flush kill of younger results

  **What to do**: Ensure wrong-path or younger-than-commit results cannot update architectural RF/CSR-visible state even if the execution result exists. Keep execution/bypass usefulness if needed, but commit decides visibility. Any flushed entry must be impossible to commit.
  **Must NOT do**: Do not break same-cycle bypass for still-live younger ops, and do not reintroduce WB-as-retire shortcuts.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is commit-policy enforcement across regfile and CSR hooks.
  - Skills: `["verilog-lint"]` — multiple RTL points touched.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [8, 9, 10] | Blocked By: [6]

  **References**:
  - Pattern: `rtl/adam_riscv_v2.v:753-793` — current direct regfile write enables from WB paths
  - Pattern: `rtl/adam_riscv_v2.v:798-821` — CSR retire hooks currently driven by WB valid
  - Pattern: `rtl/scoreboard_v2.v:727-739` — flush cleanup that must align with commit queue semantics
  - API/Type: commit-queue metadata introduced in Task 6

  **Acceptance Criteria**:
  - [ ] A killed younger result cannot update the architectural register file.
  - [ ] CSR retire counters increment on commit, not on WB.
  - [ ] Existing basic tests plus `test_commit_flush_store.s` pass.

  **QA Scenarios**:
  ```
  Scenario: Committed result still reaches the architectural register file
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_order.s test2.S`
    Expected: Exit code 0; all checks pass; commit trace and final register state agree
    Evidence: .sisyphus/evidence/task-7-commit-gating.log

  Scenario: Flushed younger writeback is suppressed architecturally
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_flush_store.s`
    Expected: Exit code 0; the younger wrong-path register write is absent in final architectural state
    Evidence: .sisyphus/evidence/task-7-commit-gating-error.log
  ```

  **Commit**: YES | Message: `fix(core): gate architectural state at commit` | Files: `rtl/adam_riscv_v2.v`, commit-related RTL, targeted ROMs/checkers as needed

- [x] 8. Implement Store Buffer v1 with commit-gated drain and wrong-path discard

  **What to do**: Insert a per-thread Store Buffer behind the LSU shell. A store becomes “completed” for execution once inserted, but may drain to memory only when its commit-queue entry reaches the head and is complete. Add directed ROM `test_store_buffer_commit.s` to prove committed stores drain and wrong-path stores do not.
  **Must NOT do**: Do not allow speculative stores to write `stage_mem/data_memory` directly, and do not add memory dependence speculation.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: speculative-memory safety lives in RTL and commit coupling.
  - Skills: `["verilog-lint"]` — Store Buffer RTL and top-level hooks change.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [9] | Blocked By: [5, 6, 7]

  **References**:
  - Pattern: `rtl/exec_pipe1.v:171-182` — current store request emission point
  - Pattern: `rtl/stage_mem.v:80-97` — current immediate memory write behavior to remove
  - Pattern: `rtl/data_memory.v:52-68` — memory write point that must only see committed stores
  - Pattern: `rtl/adam_riscv_v2.v:660-691` — current memory-stage instantiation boundary

  **Acceptance Criteria**:
  - [ ] `test_store_buffer_commit.s` passes and shows committed stores become visible in order.
  - [ ] `test_commit_flush_store.s` still passes and proves wrong-path stores never reach memory.
  - [ ] Full regression passes after Store Buffer v1 lands.

  **QA Scenarios**:
  ```
  Scenario: Committed stores drain only at commit
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_store_buffer_commit.s`
    Expected: Exit code 0; final DRAM matches expected order; trace shows drain only when commit head authorizes it
    Evidence: .sisyphus/evidence/task-8-store-buffer.log

  Scenario: Wrong-path store never updates memory
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_flush_store.s`
    Expected: Exit code 0; memory location targeted by the flushed store retains pre-flush value
    Evidence: .sisyphus/evidence/task-8-store-buffer-error.log
  ```

  **Commit**: YES | Message: `feat(lsu): add commit gated store buffer` | Files: Store Buffer RTL, `rtl/adam_riscv_v2.v`, LSU path RTL, new ROM test

- [x] 9. Add exact-match store-to-load forwarding and unresolved-older-store blocking

  **What to do**: Implement conservative forwarding from the youngest older matching Store Buffer entry only when the entry fully covers the load bytes. If any older store for that thread is unresolved, partially overlapping, or coverage-ambiguous, stall or retry the load instead of merging data. Add directed ROMs `test_store_buffer_forwarding.s` and `test_store_buffer_hazard.s`.
  **Must NOT do**: Do not forward from younger stores, cross-thread stores, or partial-overlap cases that would require byte merging.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: forwarding correctness is a memory-ordering RTL problem.
  - Skills: `["verilog-lint"]` — forwarding logic touches multiple RTL files.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [] | Blocked By: [8]

  **References**:
  - Pattern: `rtl/stage_mem.v:56-90` — existing byte/halfword store shaping to reuse for coverage logic
  - Pattern: `rtl/stage_wb.v:16-52` — existing load sign/zero extension rules to match for forwarded values
  - Pattern: `rtl/scoreboard_v2.v:498-525` — issue policy location for stalling younger loads on older-store uncertainty
  - API/Type: Store Buffer entry metadata from Task 8

  **Acceptance Criteria**:
  - [ ] `test_store_buffer_forwarding.s` passes for byte/halfword/word exact-match forwarding cases.
  - [ ] `test_store_buffer_hazard.s` passes and proves younger loads wait behind unresolved older stores.
  - [ ] Full regression passes with no subword-load regressions.

  **QA Scenarios**:
  ```
  Scenario: Exact-match older store forwards to younger load
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_store_buffer_forwarding.s`
    Expected: Exit code 0; byte/halfword/word loads receive forwarded values with correct sign/zero extension
    Evidence: .sisyphus/evidence/task-9-store-forwarding.log

  Scenario: Ambiguous or unresolved older store blocks the load
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_store_buffer_hazard.s`
    Expected: Exit code 0; the load waits or retries until safe; no incorrect memory+store data merge occurs
    Evidence: .sisyphus/evidence/task-9-store-forwarding-error.log
  ```

  **Commit**: YES | Message: `feat(lsu): add conservative store load forwarding` | Files: Store Buffer / LSU / scoreboard RTL, new ROM tests

- [x] 10. Replace fixed-latency fetch with a single-outstanding-miss nonblocking ICache

  **What to do**: Using the Task 4 shell and Task 3 preload wrapper, implement a single-outstanding-miss ICache with hit-under-miss. Responses must be tagged by thread and epoch so a stale miss return may fill the cache but must never be delivered to `fetch_buffer` after redirect/flush. Add directed ROMs `test_icache_redirect_miss.s` and `test_icache_stale_return.s`.
  **Must NOT do**: Do not add multi-MSHR behavior, do not rely on BPU correctness as proof of ICache correctness, and do not expose cache internals to benches.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is a frontend microarchitecture feature with tight flush coupling.
  - Skills: `["verilog-lint"]` — modified frontend/cache RTL must stay syntax-clean.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [] | Blocked By: [3, 4, 7]

  **References**:
  - Pattern: `rtl/stage_if_v2.v:69-80` — current direct `inst_memory` dependency to replace
  - Pattern: `rtl/stage_if_v2.v:115-134` — current fixed one-cycle response assumption to remove
  - Pattern: `rtl/fetch_buffer.v:108-124` — flush interaction at IF/Decode boundary
  - Pattern: `rtl/l1_dcache_nb.v:125-240` — acceptable structural template only for single-miss FSM behavior
  - Pattern: `comp_test/tb_v2.sv:36-45` and `verification/riscof/adam_riscv/env/tb_riscof.sv:58-64` — benches that must preload backing storage, not cache internals

  **Acceptance Criteria**:
  - [ ] `test_icache_redirect_miss.s` passes and proves correct redirect after a miss is already outstanding.
  - [ ] `test_icache_stale_return.s` passes and proves stale miss responses are dropped before frontend consumption.
  - [ ] Full regression passes after ICache lands.

  **QA Scenarios**:
  ```
  Scenario: Redirect during miss returns the correct post-redirect instruction stream
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_icache_redirect_miss.s`
    Expected: Exit code 0; test prints `PASS`; trace shows redirected PC accepted and stale pre-redirect response not consumed
    Evidence: .sisyphus/evidence/task-10-icache.log

  Scenario: Stale miss response fills cache but is never delivered to the wrong epoch
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_icache_stale_return.s`
    Expected: Exit code 0; no wrong-path fetch enters `fetch_buffer`; stale response is explicitly dropped by epoch check
    Evidence: .sisyphus/evidence/task-10-icache-error.log
  ```

  **Commit**: YES | Message: `feat(frontend): add single miss icache` | Files: ICache RTL, `rtl/stage_if_v2.v`, `rtl/adam_riscv_v2.v`, bench preload integration, new ROM tests

## Final Verification Wave (MANDATORY — after ALL implementation tasks)
> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit `okay` before completing.
- [ ] F1. Plan Compliance Audit — oracle
- [ ] F2. Code Quality Review — unspecified-high
- [ ] F3. Real Manual QA — unspecified-high (+ playwright if UI)
- [ ] F4. Scope Fidelity Check — deep

## Commit Strategy
- One green commit per numbered task.
- Each commit must include the task’s directed tests and evidence update, not just code.
- Run full regression after Tasks 6, 8/9 (as one Store Buffer milestone), and 10.
- If a task needs follow-up because pre-existing script drift blocks it, fix the blocker in the earliest blocking task rather than papering over it later.

## Success Criteria
- Speculative stores cannot reach `data_memory` before commit.
- Wrong-path younger work cannot update architectural RF/CSR/memory state.
- Load/store behavior remains correct for existing tests and new forwarding/hazard tests.
- Frontend survives one outstanding miss and one redirect/flush without stale instruction consumption.
- All targeted tests and full regression suites pass through the hardened build flow.
