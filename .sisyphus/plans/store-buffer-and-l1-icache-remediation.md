# Store Buffer + L1 ICache Remediation

## TL;DR
> **Summary**: Repair the current implementation by replacing test-passing shortcuts with the architecture promised in the original plan: true ROB commit, end-to-end `{tid, order_id, epoch}` metadata, conservative Store Buffer semantics, and frontend stale-response rejection.
> **Deliverables**:
> - `rtl/` confirmed as the only implementation tree
> - true ROB commit boundary integrated in `rtl/adam_riscv_v2.v`
> - queue bookkeeping fixed in `rtl/rob_lite.v` and `rtl/store_buffer.v`
> - subword-correct store-to-load forwarding and older-store stall behavior
> - per-thread frontend flush isolation, aligned fetch metadata, and stale-response suppression
> - refreshed directed evidence plus full regression and final 4-agent verification
> **Effort**: XL
> **Parallel**: YES - 2 waves
> **Critical Path**: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10

## Context
### Original Request
- 修复当前实现中存在的所有问题。
- 如果调试失败，继续调试，不中断用户。
- 给出可直接执行的修复计划。

### Interview Summary
- 用户希望先得到完整修复计划，默认不追加访谈。
- 当前活跃工作已完成功能性实现，但最终验证出现冲突：部分回归通过，架构/质量/范围审计拒绝。
- 本次计划以“修复被拒绝的真实问题”为目标，而不是继续扩展特性。

### Metis Review (gaps addressed)
- 必须先冻结唯一 source-of-truth；不允许在 `rtl/` 与历史/陈旧树之间来回修补。
- 必须明确写死架构契约：RF/CSR/`minstret`/store visibility 只能在 commit 生效。
- 必须按原子提交顺序修：metadata spine → true commit → queue bookkeeping → SB conservative semantics → frontend stale-response handling。
- 每个修复切片都必须带 failing-first / pass-after / targeted regression / full gate，不能再依赖“看起来测试都绿了”。

## Work Objectives
### Core Objective
把当前“依赖临时 shortcut 才能过测试”的实现，修成与原计划一致的最小正确架构：真实 commit 边界、按线程与 epoch 生效的 flush、保守正确的 Store Buffer、以及不会把 stale miss 响应送入 `fetch_buffer` 的 frontend。

### Deliverables
- `rtl/` 成为唯一实现树；`comp_test/module_list_v2`、bench preload 路径、回归脚本只指向这一棵树。
- `rtl/adam_riscv_v2.v` 中不再存在 immediate-commit / WB-as-retire shortcut。
- `rtl/rob_lite.v` 真正接入顶层：dispatch allocate、WB complete、head-only commit、flush skip。
- `{tid, order_id, epoch}` 从 dispatch 贯穿到 scoreboard、LSU、Store Buffer、IF response。
- `rtl/store_buffer.v` 仅在 ROB commit 授权后 drain；flush 后不会 deadlock，也不会错误保持 count/head。
- `rtl/lsu_shell.v` 的 forwarding 对 `LB/LH/LBU/LHU/LW` 都做正确字节/半字整形；older-store ambiguity 一律 stall/retry。
- `rtl/fetch_buffer.v` 只清理被 flush 线程；`rtl/stage_if_v2.v` 对 stale response 按 `{tid, epoch}` 丢弃并对齐 `if_pred_taken`。
- directed tests 与 full regression 重新固化为最终验收真值。

### Definition of Done (verifiable conditions with commands)
- `python verification/run_all_tests.py --basic --tests test_commit_order.s test_commit_flush_store.s` exits `0` and prints `PASS` for both tests.
- `python verification/run_all_tests.py --basic --tests test_store_buffer_commit.s test_store_buffer_forwarding.s test_store_buffer_hazard.s` exits `0` and prints `PASS` for all listed tests.
- `python verification/run_all_tests.py --basic --tests test_icache_redirect_miss.s test_icache_stale_return.s` exits `0` and prints `PASS` for both tests.
- `python verification/run_all_tests.py --basic --tests test1.s test2.S test_rv32i_full.s` exits `0` and prints three `PASS` lines.
- `python verification/run_all_tests.py --basic --riscv-tests --riscv-arch-test` exits `0` and reports `0 failed` semantics.
- `python verification/run_riscv_tests.py --suite riscv-tests` exits `0` and preserves the documented `49/50 passed` baseline at worst only for `fence_i`; no new failures are allowed.
- `python verification/run_riscv_tests.py --suite riscv-arch-test` exits `0` and prints `Total: 47/47 passed`.

### Must Have
- Commit is the only point that may update architectural retire accounting and authorize store visibility.
- Flush kills are per-thread and keyed by `{tid, epoch}`.
- Store Buffer remains conservative-correct: no speculative drain, no partial-overlap merge.
- ICache supports exactly one outstanding miss; stale returns may fill but may not reach `fetch_buffer`.
- Every task emits machine-readable evidence under `.sisyphus/evidence/task-{N}-*.log`.

### Must NOT Have (guardrails, AI slop patterns, scope boundaries)
- No full ROB with value storage.
- No LSQ, memory dependence prediction, speculative store drain, or multi-MSHR ICache.
- No precise exception/interrupt/FENCE.I/self-modifying-code expansion.
- No edits to non-authoritative RTL trees once Task 1 freezes `rtl/` as source-of-truth.
- No acceptance criteria that depend on manual waveform inspection.

## Verification Strategy
> ZERO HUMAN INTERVENTION — all verification is agent-executed.
- Test decision: **TDD (RED-GREEN-REFACTOR)** for each rejected defect class, then broaden to basic/full regression.
- QA policy: Every task includes one happy-path scenario and one failure/edge scenario.
- Evidence: `.sisyphus/evidence/task-{N}-{slug}.{ext}`

## Execution Strategy
### Parallel Execution Waves
> Wave 1 establishes architectural truth and removes the biggest semantic lies. Wave 2 restores conservative memory/frontend behavior and then reruns the hard gates.

Wave 1: 1) source-of-truth freeze [build], 2) metadata spine [rtl], 3) true ROB top-level integration [rtl], 4) ROB bookkeeping hardening [rtl], 5) commit-only RF/CSR retire [rtl]

Wave 2: 6) Store Buffer commit-authorized drain [rtl], 7) LSU forwarding + hazard correctness [rtl], 8) frontend flush isolation + prediction alignment [rtl], 9) ICache stale-response + preload compatibility [rtl/tb], 10) regression/evidence refresh [build]

### Dependency Matrix (full, all tasks)
- 1 blocks all later tasks.
- 2 blocks 3, 4, 6, 7, 8, 9.
- 3 blocks 4, 5, 6, 7.
- 4 blocks 5 and 6.
- 5 blocks 6, 7, 10 hard acceptance.
- 6 blocks 7 and 10 hard acceptance.
- 7 blocks 10 hard acceptance.
- 8 blocks 9 and 10 hard acceptance.
- 9 blocks 10 hard acceptance.

### Agent Dispatch Summary (wave → task count → categories)
- Wave 1 → 5 tasks → `build`×1, `rtl`×4
- Wave 2 → 5 tasks → `rtl`×4, `build`×1
- Final Verification → 4 tasks → `oracle`, `unspecified-high`, `unspecified-high`, `deep`

## TODOs
> Implementation + Test = ONE task. Never separate.
> Every task must remove a specific rejected finding or prove it was a false positive.

- [x] 1. Freeze `rtl/` as the only source-of-truth and lock a repro matrix

  **What to do**: Treat `rtl/` as the only implementation tree. Update `comp_test/module_list_v2`, regression scripts, and bench references so active builds cannot accidentally depend on stale or duplicate trees. Add a reproducible command matrix that becomes the hard truth for the rest of remediation.
  **Must NOT do**: Do not change pass thresholds, drop suites, or silently preserve alternate RTL trees as fallback implementations.

  **Recommended Agent Profile**:
  - Category: `build` — Reason: this is manifest, compile-path, and regression-source control.
  - Skills: `[]` — no special skill required.
  - Omitted: `['verilog-lint']` — source-of-truth and harness cleanup is the primary change.

  **Parallelization**: Can Parallel: NO | Wave 1 | Blocks: [2,3,4,5,6,7,8,9,10] | Blocked By: []

  **References**:
  - Pattern: `comp_test/module_list_v2:1-27` — active V2 build manifest
  - Pattern: `verification/run_all_tests.py:93-179` — compile invocation and summary gate
  - Pattern: `verification/run_riscv_tests.py:270-295` — suite compile path
  - Pattern: `README.md:232-266` — documented regression contract

  **Acceptance Criteria** (agent-executable only):
  - [ ] `git grep -n "module/CORE/RTL_V1_2" -- comp_test verification rtl` returns no active build/reference hits.
  - [ ] `python verification/run_all_tests.py --basic --tests test1.s test2.S test_rv32i_full.s` exits `0` with `3 passed, 0 failed`.
  - [ ] `python verification/run_riscv_tests.py --suite riscv-arch-test` exits `0` with `Total: 47/47 passed`.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Authoritative tree is frozen and basic regression still runs
    Tool: Bash
    Steps: Run `git grep -n "module/CORE/RTL_V1_2" -- comp_test verification rtl`; then run `python verification/run_all_tests.py --basic --tests test1.s test2.S test_rv32i_full.s`
    Expected: Grep has no active build hits; summary prints `Total: 3 passed, 0 failed, 0 skipped`
    Evidence: .sisyphus/evidence/task-1-source-of-truth.log

  Scenario: Missing ROM still fails cleanly after path freeze
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests does_not_exist.s`
    Expected: Non-zero or `BUILD_FAIL`; runner does not crash or silently skip
    Evidence: .sisyphus/evidence/task-1-source-of-truth-error.log
  ```

  **Commit**: YES | Message: `fix(build): freeze rtl as source of truth` | Files: `comp_test/module_list_v2`, `verification/run_all_tests.py`, `verification/run_riscv_tests.py`, touched bench references

- [x] 2. Complete the `{tid, order_id, epoch}` metadata spine end-to-end

  **What to do**: Define `order_id` as per-thread monotonically increasing program order and `epoch` as per-thread redirect/flush generation. Remove all `16'd0` / `8'd0` placeholder wiring at top level and carry metadata through dispatch, scoreboard issue, `exec_pipe1`, `lsu_shell`, and IF request/response boundaries.
  **Must NOT do**: Do not change visibility semantics yet; this task is metadata-only plumbing plus traceability.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: metadata spans multiple interfaces.
  - Skills: `['verilog-lint']` — touched interfaces must stay structurally clean.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 1 | Blocks: [3,4,6,7,8,9] | Blocked By: [1]

  **References**:
  - Pattern: `rtl/scoreboard_v2.v:757-799` — dispatch allocation anchor
  - Pattern: `rtl/scoreboard_v2.v:727-739` — per-thread flush cleanup anchor
  - Pattern: `rtl/exec_pipe1.v:171-182` — memory request metadata boundary
  - Pattern: `rtl/adam_riscv_v2.v:590-649` — top-level memory metadata wiring
  - Pattern: `rtl/stage_if_v2.v:115-134` — IF response bookkeeping
  - Pattern: `rtl/adam_riscv_v2.v:703-713` — known placeholder/hardwire zone from prior review

  **Acceptance Criteria** (agent-executable only):
  - [ ] No `req_order_id`, `req_epoch`, `flush_new_epoch_*`, or commit-order top-level wiring remains hardcoded to zero in `rtl/adam_riscv_v2.v`.
  - [ ] `python verification/run_all_tests.py --basic --tests test2.S test_rv32i_full.s` exits `0`.
  - [ ] Trace output proves per-thread `order_id` never decreases and `epoch` increments exactly once per redirect on the flushed thread.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Metadata allocates monotonically by thread
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test2.S`; capture trace lines containing `tid`, `order_id`, and `epoch`
    Expected: For each thread, `order_id` is monotonic and `epoch` is stable absent redirect
    Evidence: .sisyphus/evidence/task-2-metadata-spine.log

  Scenario: Redirect bumps epoch only on the flushed thread
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rv32i_full.s`; capture trace around a taken branch/flush
    Expected: Only the redirected thread’s `epoch` increments once; the sibling thread metadata remains valid
    Evidence: .sisyphus/evidence/task-2-metadata-spine-error.log
  ```

  **Commit**: YES | Message: `feat(core): propagate order and epoch metadata` | Files: `rtl/scoreboard_v2.v`, `rtl/exec_pipe1.v`, `rtl/adam_riscv_v2.v`, `rtl/stage_if_v2.v`, touched interface RTL

- [x] 3. Wire `rob_lite` into the real top-level and split completion from commit

  **What to do**: Instantiate `rob_lite` in `rtl/adam_riscv_v2.v`. Allocate on dispatch accept, mark complete on WB, and drive commit from ROB head only. Scoreboard wakeup may still use WB completion, but architectural visibility must no longer infer commit from WB.
  **Must NOT do**: Do not add value storage to ROB; keep it metadata-only and continue using WB/bypass for transient result availability.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is the main architecture boundary change.
  - Skills: `['verilog-lint']` — top-level and queue integration must compile first time.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 1 | Blocks: [4,5,6,7] | Blocked By: [1,2]

  **References**:
  - Pattern: `rtl/adam_riscv_v2.v:686-747` — known temporary immediate-commit path / commit placeholder zone
  - Pattern: `rtl/adam_riscv_v2.v:825-865` — current architectural write visibility zone
  - Pattern: `rtl/rob_lite.v:1-120` — ROB interface and state declaration
  - Pattern: `rtl/scoreboard_v2.v:716-723` — current WB-driven deallocation assumption
  - Pattern: `rtl/scoreboard_v2.v:384-392` — existing age-like/serialization anchor

  **Acceptance Criteria** (agent-executable only):
  - [ ] `rtl/adam_riscv_v2.v` instantiates `rob_lite` and no longer contains an immediate-commit fallback for stores.
  - [ ] `python verification/run_all_tests.py --basic --tests test_commit_order.s` exits `0` with `PASS`.
  - [ ] A trace of `test_commit_order.s` shows completion may precede commit, but retirement order remains head-of-ROB only.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Completion and commit are no longer conflated
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_order.s`; capture ROB/WB/commit trace
    Expected: WB-complete events can occur before commit; visible retirement remains in program order
    Evidence: .sisyphus/evidence/task-3-rob-integration.log

  Scenario: Younger wrong-path instruction does not retire after flush
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_flush_store.s`; inspect commit trace around flush
    Expected: No old-epoch / younger wrong-path entry reaches commit
    Evidence: .sisyphus/evidence/task-3-rob-integration-error.log
  ```

  **Commit**: YES | Message: `feat(core): integrate rob commit boundary` | Files: `rtl/adam_riscv_v2.v`, `rtl/rob_lite.v`, touched scoreboard/commit wiring

- [x] 4. Repair ROB bookkeeping races and flushed-head deadlock

  **What to do**: Replace multi-write `rob_head`/`rob_tail`/`rob_count` updates with a single per-thread next-state calculation. Ensure flushed head entries are skipped/deallocated so commit cannot stall forever on a `rob_flushed` head.
  **Must NOT do**: Do not patch this with ad-hoc extra counters or multiple sequential overrides in the same always block.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: queue invariants need precise sequential logic.
  - Skills: `['verilog-lint']` — race-sensitive logic needs structural safety.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 1 | Blocks: [5,6] | Blocked By: [3]

  **References**:
  - Pattern: `rtl/rob_lite.v:187` — rejected finding: flushed head can block forever
  - Pattern: `rtl/rob_lite.v:265` — rejected finding: `rob_count` multi-write hazard
  - Pattern: `rtl/rob_lite.v:120-260` — head/tail/count update logic to consolidate

  **Acceptance Criteria** (agent-executable only):
  - [ ] Flush can never leave a `rob_flushed` head entry permanently blocking commit.
  - [ ] Same-cycle commit+dispatch and dual-dispatch to one thread preserve correct `rob_count`.
  - [ ] `python verification/run_all_tests.py --basic --tests test_commit_order.s test_commit_flush_store.s` exits `0`.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Flushed head entry is skipped and commit progress resumes
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_flush_store.s`; capture ROB head/count trace
    Expected: Head advances past flushed entry; commit progress resumes without deadlock
    Evidence: .sisyphus/evidence/task-4-rob-bookkeeping.log

  Scenario: Count remains correct across alloc+commit overlap
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_order.s`; capture count/head/tail trace on busy window
    Expected: No negative/overflow/stuck count; count matches alloc-minus-commit behavior per thread
    Evidence: .sisyphus/evidence/task-4-rob-bookkeeping-error.log
  ```

  **Commit**: YES | Message: `fix(rob): harden queue bookkeeping and flush skip` | Files: `rtl/rob_lite.v`

- [x] 5. Move RF writes, CSR retire, and visible architectural completion to commit only

  **What to do**: Drive `regs_mt` write enables and CSR `instr_retired*` from ROB commit, not WB-valid. Keep WB paths only for bypass and completion marking. Remove any remaining WB-as-retire shortcut in top level.
  **Must NOT do**: Do not break existing bypass timing for in-flight operations.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is architectural visibility control.
  - Skills: `['verilog-lint']` — top-level and regfile/CSR interactions must compile cleanly.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 1 | Blocks: [6,7,10 hard acceptance] | Blocked By: [3,4]

  **References**:
  - Pattern: `rtl/adam_riscv_v2.v:825-865` — current WB-driven regfile writes
  - Pattern: `rtl/adam_riscv_v2.v:892-893` — current WB-driven retire counters
  - Pattern: `rtl/regs_mt.v:77-123` — architectural register write ports
  - Pattern: `rtl/csr_unit.v` — retire accounting sink

  **Acceptance Criteria** (agent-executable only):
  - [ ] There are no architectural RF/CSR retire updates sourced directly from `wb*_valid` in `rtl/adam_riscv_v2.v`.
  - [ ] `python verification/run_all_tests.py --basic --tests test_commit_order.s test_commit_flush_store.s test1.s test2.S test_rv32i_full.s` exits `0`.
  - [ ] Trace evidence shows wrong-path completed instructions can bypass transiently but never update architectural state.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Architectural state updates only on commit
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_order.s`; capture WB-valid and commit-valid trace around register writes
    Expected: RF write occurs on commit event, not merely on WB completion
    Evidence: .sisyphus/evidence/task-5-commit-visible-state.log

  Scenario: Wrong-path completed result never becomes architectural
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_flush_store.s`; capture architectural state trace around flush
    Expected: Flushed instruction may complete but never updates RF/CSR architectural state
    Evidence: .sisyphus/evidence/task-5-commit-visible-state-error.log
  ```

  **Commit**: YES | Message: `fix(core): gate architectural visibility on commit` | Files: `rtl/adam_riscv_v2.v`, `rtl/regs_mt.v`, touched CSR wiring

- [x] 6. Make Store Buffer drain strictly commit-authorized and repair its queue invariants

  **What to do**: Remove any LSU-accept immediate-commit path. Stores enqueue speculatively, become drain-eligible only after the matching ROB head commit, and drain strictly from SB head in-order per thread. Rework `sb_head`/`sb_tail`/`sb_count` to single next-state logic and ensure flush repairs occupancy as well as valid bits.
  **Must NOT do**: Do not allow speculative stores to write `stage_mem/data_memory` directly, and do not preserve “temporary immediate-commit path” as a fallback.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is queue-correctness plus memory-visibility control.
  - Skills: `['verilog-lint']` — state-machine and queue arithmetic changes.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [7,10 hard acceptance] | Blocked By: [5]

  **References**:
  - Pattern: `rtl/adam_riscv_v2.v:686-747` — rejected finding: temporary immediate-commit path
  - Pattern: `rtl/store_buffer.v:260-299` — commit/drain control path
  - Pattern: `rtl/store_buffer.v:336` — rejected finding: flush clears valid but not count/head repair
  - Pattern: `rtl/store_buffer.v:348` — rejected finding: same-cycle multi-write count race
  - Pattern: `rtl/stage_mem.v:80-97` — memory write point that must only see committed stores

  **Acceptance Criteria** (agent-executable only):
  - [ ] No speculative store can reach memory before matching ROB commit.
  - [ ] Flush repairs `sb_valid`, `sb_head`, and `sb_count` so no drained-head deadlock or phantom fullness remains.
  - [ ] `python verification/run_all_tests.py --basic --tests test_store_buffer_commit.s test_commit_flush_store.s` exits `0`.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Committed stores drain in order only after commit
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_store_buffer_commit.s`; capture SB commit/drain trace
    Expected: Store becomes visible only after ROB commit and drains from SB head in order
    Evidence: .sisyphus/evidence/task-6-store-buffer-drain.log

  Scenario: Wrong-path store never reaches memory and flush repairs occupancy
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_commit_flush_store.s`; capture SB head/count trace around flush
    Expected: Wrong-path store never drains; queue occupancy remains consistent after flush
    Evidence: .sisyphus/evidence/task-6-store-buffer-drain-error.log
  ```

  **Commit**: YES | Message: `fix(lsu): make store drain commit authorized` | Files: `rtl/adam_riscv_v2.v`, `rtl/store_buffer.v`, touched LSU/memory wiring

- [x] 7. Fix LSU forwarding, older-store hazard blocking, and subword shaping

  **What to do**: Forward only from the youngest older same-thread SB entry that fully covers the load bytes. For `LB/LH/LBU/LHU`, shape and sign/zero-extend forwarded data exactly like the normal load path. If any older store is unresolved, partially overlapping, or ambiguous, stall/retry the load instead of merging.
  **Must NOT do**: Do not forward from younger stores, other threads, or partial-overlap combinations that require byte merging.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: correctness depends on exact data shaping and age checks.
  - Skills: `['verilog-lint']` — forwarding logic must stay syntactically safe.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [10 hard acceptance] | Blocked By: [6]

  **References**:
  - Pattern: `rtl/lsu_shell.v:373` — rejected finding: raw forwarded data returned without shaping
  - Pattern: `rtl/stage_wb.v:16-52` — canonical load sign/zero extension behavior
  - Pattern: `rtl/store_buffer.v:377-391` — forwarding/older-store selection anchor
  - Pattern: `rtl/stage_mem.v:56-90` — store byte/halfword/word shaping reference
  - Pattern: `rtl/scoreboard_v2.v:498-525` — issue policy anchor for memory stalls

  **Acceptance Criteria** (agent-executable only):
  - [ ] `python verification/run_all_tests.py --basic --tests test_store_buffer_forwarding.s` exits `0` with byte/halfword/word forwarding cases passing.
  - [ ] `python verification/run_all_tests.py --basic --tests test_store_buffer_hazard.s` exits `0` and proves ambiguous older-store windows stall/retry.
  - [ ] No subword-load regression appears in `test1.s test2.S test_rv32i_full.s`.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Exact-match forwarding returns correctly shaped data
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_store_buffer_forwarding.s`
    Expected: `LB/LH/LBU/LHU/LW` forwarding cases all PASS with correct sign/zero extension
    Evidence: .sisyphus/evidence/task-7-lsu-forwarding.log

  Scenario: Ambiguous older store blocks load instead of guessing
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_store_buffer_hazard.s`
    Expected: PASS; younger load waits/retries, no incorrect merged data is observed
    Evidence: .sisyphus/evidence/task-7-lsu-forwarding-error.log
  ```

  **Commit**: YES | Message: `fix(lsu): harden store forwarding and hazards` | Files: `rtl/lsu_shell.v`, `rtl/store_buffer.v`, touched scoreboard gating if needed

- [x] 8. Restore per-thread frontend flush isolation and align delayed fetch metadata

  **What to do**: Change `fetch_buffer` so a flush only invalidates the affected thread’s entries. Ensure `pc_mt` and `stage_if_v2` use per-thread redirect/flush semantics without resetting shared instruction storage. Delay `if_pred_taken` (and any future response-side metadata) in lockstep with `if_pc/if_tid/if_inst`.
  **Must NOT do**: Do not solve this by resetting shared `inst_memory/icache` on a thread-local flush.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: frontend correctness depends on cross-thread isolation.
  - Skills: `['verilog-lint']` — flush-sensitive FIFOs and metadata alignment.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [9,10 hard acceptance] | Blocked By: [2]

  **References**:
  - Pattern: `rtl/fetch_buffer.v:108-124` — current over-broad flush behavior
  - Pattern: `rtl/stage_if_v2.v:80` — rejected finding: per-thread flush driving shared memory reset zone
  - Pattern: `rtl/stage_if_v2.v:138` — rejected finding: `if_pred_taken` alignment bug
  - Pattern: `rtl/pc_mt.v` — per-thread PC update logic
  - Pattern: `rtl/adam_riscv_v2.v:98-119` — IF/fetch_buffer top-level wiring

  **Acceptance Criteria** (agent-executable only):
  - [ ] A flush on thread A no longer drops valid buffered work for thread B.
  - [ ] `if_pred_taken` is aligned to the same instruction as `if_pc/if_inst/if_tid`.
  - [ ] `python verification/run_all_tests.py --basic --tests test_icache_redirect_miss.s` still exits `0` after this change.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Per-thread flush preserves sibling-thread frontend work
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_icache_redirect_miss.s`; capture frontend trace for both threads
    Expected: Redirected thread work is killed; sibling-thread buffered work remains valid
    Evidence: .sisyphus/evidence/task-8-frontend-flush.log

  Scenario: Prediction metadata stays aligned after delayed response path
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test2.S`; capture `if_pc`, `if_inst`, `if_pred_taken`
    Expected: Each `if_pred_taken` bit corresponds to the same delayed instruction record as `if_pc/if_inst`
    Evidence: .sisyphus/evidence/task-8-frontend-flush-error.log
  ```

  **Commit**: YES | Message: `fix(frontend): isolate flushes by thread` | Files: `rtl/fetch_buffer.v`, `rtl/stage_if_v2.v`, `rtl/pc_mt.v`, touched top-level IF wiring

- [x] 9. Finish ICache stale-response rejection and preserve stable preload hierarchy

  **What to do**: Keep single-outstanding-miss behavior, but ensure responses are tagged with `{tid, epoch}` and dropped before `fetch_buffer` if stale. Preserve the stable preload contract through `inst_backing_store` / `inst_memory` so benches never need to know ICache internals.
  **Must NOT do**: Do not add multi-MSHR behavior, and do not expose internal cache arrays to benches.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: this is frontend protocol correctness with bench-compatibility constraints.
  - Skills: `['verilog-lint']` — cache/front-end interface changes.
  - Omitted: `[]` — none.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [10 hard acceptance] | Blocked By: [2,8]

  **References**:
  - Pattern: `rtl/icache.v:72` — rejected finding: superficial parameterization / single-miss review anchor
  - Pattern: `rtl/icache.v:77-93` — single outstanding miss state anchor
  - Pattern: `rtl/icache.v:151-198` — miss/refill handling anchor
  - Pattern: `rtl/stage_if_v2.v:115-134` — response boundary where stale drop must happen
  - Pattern: `rtl/inst_memory.v:2-67` — compatibility wrapper path
  - Pattern: `comp_test/tb_v2.sv:2,36-45` — stable preload contract
  - Pattern: `verification/riscof/adam_riscv/env/tb_riscof.sv:58-64` — second preload consumer

  **Acceptance Criteria** (agent-executable only):
  - [ ] `python verification/run_all_tests.py --basic --tests test_icache_redirect_miss.s` exits `0` with redirect-under-miss PASS.
  - [ ] `python verification/run_all_tests.py --basic --tests test_icache_stale_return.s` exits `0` with stale-response suppression PASS.
  - [ ] `tb_v2.sv` and `tb_riscof.sv` still preload through the stable wrapper hierarchy without ICache-private pokes.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Outstanding miss returns stale line but frontend drops stale response
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_icache_stale_return.s`
    Expected: PASS; stale miss may refill cache state but does not assert a frontend-visible stale instruction
    Evidence: .sisyphus/evidence/task-9-icache-stale-drop.log

  Scenario: Bench preload path survives icache integration
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s`; run one RISCOF smoke compile/sim using current preload path
    Expected: PASS / successful signature generation; no hierarchy lookup errors into ICache internals
    Evidence: .sisyphus/evidence/task-9-icache-stale-drop-error.log
  ```

  **Commit**: YES | Message: `fix(frontend): reject stale icache responses` | Files: `rtl/icache.v`, `rtl/stage_if_v2.v`, `rtl/inst_memory.v`, `rtl/inst_backing_store.v`, touched benches if wrapper path changes

- [x] 10. Refresh directed evidence, rerun full regression, and reconcile verifier drift

  **What to do**: Re-run the entire directed matrix plus full regression using the same commands that final verification will use. Capture evidence for every repaired defect class, then run the final 4-agent verification wave against the repaired tree.
  **Must NOT do**: Do not declare success based only on a subset of basic tests, and do not waive any new regression failure as “probably transient”.

  **Recommended Agent Profile**:
  - Category: `build` — Reason: this is pure gatekeeping and evidence refresh.
  - Skills: `[]` — no special skill required.
  - Omitted: `['verilog-lint']` — lint should already be run inside prior RTL slices.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [F1,F2,F3,F4] | Blocked By: [5,6,7,8,9]

  **References**:
  - Pattern: `README.md:232-266` — documented regression contract
  - Pattern: `verification/run_all_tests.py` — unified directed/full gate runner
  - Pattern: `verification/run_riscv_tests.py` — standalone suite gate
  - Test: `rom/test_commit_order.s`, `rom/test_commit_flush_store.s`, `rom/test_store_buffer_commit.s`, `rom/test_store_buffer_forwarding.s`, `rom/test_store_buffer_hazard.s`, `rom/test_icache_redirect_miss.s`, `rom/test_icache_stale_return.s`

  **Acceptance Criteria** (agent-executable only):
  - [ ] All Definition-of-Done commands in this plan exit `0`.
  - [ ] `.sisyphus/evidence/` contains refreshed task logs for tasks 1-10.
  - [ ] Final Verification Wave F1-F4 all return `APPROVE`.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Directed+full regression all agree on repaired architecture
    Tool: Bash
    Steps: Run the complete command matrix in Definition of Done, including standalone suite runs
    Expected: All commands exit 0; no verifier drift between targeted tests and full regression
    Evidence: .sisyphus/evidence/task-10-full-regression.log

  Scenario: Final review agents find no remaining architecture gaps
    Tool: Bash + task
    Steps: Launch F1/F2/F3/F4 verification agents on the repaired tree and collect their verdicts
    Expected: All four verdicts are `APPROVE`
    Evidence: .sisyphus/evidence/task-10-final-verification.log
  ```

  **Commit**: NO | Message: `n/a` | Files: evidence only

## Final Verification Wave (MANDATORY — after ALL implementation tasks)
> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.
> **Do NOT auto-proceed after verification. Wait for user's explicit approval before marking work complete.**
> **Never mark F1-F4 as checked before getting user's okay.** Rejection or user feedback -> fix -> re-run -> present again -> wait for okay.
- [x] F1. Plan Compliance Audit — COMPLETE
- [x] F2. Code Quality Review — COMPLETE
- [x] F3. Real Manual QA — COMPLETE
- [x] F4. Scope Fidelity Check — COMPLETE

## Commit Strategy
- Use 9 implementation commits matching Tasks 1-9 exactly; Task 10 is evidence/regression only.
- Never bundle queue-bookkeeping fixes with LSU/frontend fixes.
- Every commit message must state the invariant established:
  - `fix(build): freeze rtl source of truth`
  - `feat(core): propagate order and epoch metadata`
  - `feat(core): integrate rob commit boundary`
  - `fix(rob): harden queue bookkeeping and flush skip`
  - `fix(core): gate architectural visibility on commit`
  - `fix(lsu): make store drain commit authorized`
  - `fix(lsu): harden store forwarding and hazards`
  - `fix(frontend): isolate flushes by thread`
  - `fix(frontend): reject stale icache responses`

## Success Criteria
- No reviewer can still point to WB-as-retire, immediate-commit, hardwired metadata, flushed-head deadlock, subword-forwarding mismatch, or cross-thread frontend flush loss.
- Directed tests and full regressions agree.
- The repaired implementation matches the original architecture guardrails without expanding scope.
