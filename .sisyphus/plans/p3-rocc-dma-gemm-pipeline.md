# P3 RoCC DMA GEMM Pipeline Completion

## TL;DR
> **Summary**: Complete the currently standalone RoCC accelerator by wiring CUSTOM0 decode through the active V2 pipeline, adding a dedicated M2 DMA path into `mem_subsys`, finishing the GEMM DMA FSM, and shipping deterministic directed tests plus full regression and GitHub sync.
> **Deliverables**:
> - End-to-end integrated `rocc_ai_accelerator` in `adam_riscv_v2`
> - Dedicated RoCC DMA M2 master in `mem_subsys` / `l2_arbiter`
> - Real RAM-backed GEMM load/compute/storeback pipeline
> - New directed RoCC DMA/GEMM tests in `--basic` with explicit goldens
> - Full regression evidence, README update, commit, and GitHub push
> **Effort**: XL
> **Parallel**: YES - 4 waves
> **Critical Path**: 1 → 2 → 4 → 5 → 6 → 7 → 9 → 10 → 11

## Context
### Original Request
- P3	RoCC DMA 完善	完整 GEMM 数据搬运流水
- 完成后新增针对性的测试到基础测试集里
- 运行完整的测试流程
- 最后同步到github
- 生成给西西弗斯的详细计划

### Interview Summary
- No preference tradeoff remained after exploration; default to the safest architecture that matches the existing V2 core.
- Scope includes RTL integration, directed verification, full regression, README update, and GitHub sync.
- This is architecture-tier work because RoCC is present only as a standalone RTL skeleton and must be integrated across decode, issue/retire, memory topology, and regression.

### Metis Review (gaps addressed)
- Freeze the CUSTOM0/RoCC contract before any RTL changes.
- Add deterministic test identification before depending on new directed tests.
- Add explicit flush/tag-reuse protection for long-latency RoCC completion.
- Require RAM-result goldens; TUBE-only pass markers are insufficient.
- Stage work as a vertical slice: contract → decode/control → retire-safe completion → M2 DMA infra → GEMM DMA path → directed tests → full regression → docs/sync.

## Work Objectives
### Core Objective
Turn `rtl/rocc_ai_accelerator.v` from an unintegrated placeholder into a fully integrated, serialized, single-outstanding RoCC engine that performs real RAM-backed DMA load/compute/store for GEMM and retires safely through the existing V2 WB/ROB path.

### Deliverables
- CUSTOM0 decode/control propagation for RoCC commands
- Serialized single-outstanding RoCC command path with flush-safe completion
- Dedicated M2 DMA master path through `mem_subsys` / `l2_arbiter`
- Completed RoCC internal FSM for RAM-only DMA copy + GEMM storeback
- New directed ROM tests for DMA movement, GEMM result, busy/serialization, and flush safety
- `verification/run_all_tests.py --basic` updated to include the new tests
- README updated with P3 feature and test status
- Final commits and push to GitHub

### Definition of Done (verifiable conditions with commands)
- `python verification/run_all_tests.py --basic` completes with all legacy and new directed tests passing.
- `python verification/run_all_tests.py --basic --riscv-tests --riscv-arch-test` completes successfully with the repo’s accepted pass thresholds.
- Targeted RoCC tests verify RAM-side source/destination movement and GEMM result memory, not just TUBE completion.
- `README.md` documents the RoCC DMA/GEMM path, new directed tests, and final pass counts.
- Work is committed and pushed to the tracked GitHub branch without leaving uncommitted implementation changes.

### Must Have
- Serialized single-outstanding RoCC issue model
- Dedicated M2 DMA master; no LSU/M1 reuse
- Flush/tag-reuse protection on RoCC completion
- Completion through existing WB/ROB machinery only
- RAM-only deterministic DMA for P3
- Explicit directed tests with unique signatures and memory goldens
- Full regression after targeted tests pass

### Must NOT Have (guardrails, AI slop patterns, scope boundaries)
- No fake GEMM path that bypasses `mem_req_*` / `mem_resp_*`
- No direct architectural regfile write from accelerator
- No MMIO DMA, no cache coherency, no VM translation, no burst DMA, no multi-outstanding RoCC commands
- No interrupt-first completion model for P3
- No generic “TUBE == 0x04” only acceptance for new RoCC tests
- No opportunistic refactor of unrelated decode/scoreboard/memory code

## Verification Strategy
> ZERO HUMAN INTERVENTION — all verification is agent-executed.
- Test decision: tests-after with deterministic directed ROMs plus full suite regression
- Framework: `comp_test/tb_v2.sv` + `comp_test/test_content.sv` + `verification/run_all_tests.py`
- QA policy: Every task has agent-executed scenarios
- Evidence: `.sisyphus/evidence/task-{N}-{slug}.{ext}`
- Directed-test rule: each RoCC test must validate concrete RAM words and/or status words in `test_content.sv`
- Regression rule: targeted tests first, then `--basic`, then full `--basic --riscv-tests --riscv-arch-test`

## Execution Strategy
### Parallel Execution Waves
> Target: 5-8 tasks per wave. <3 per wave (except final) = under-splitting.
> Extract shared dependencies as Wave-1 tasks for max parallelism.

Wave 1: contract + decode metadata + test harness groundwork (Tasks 1-3)
Wave 2: retire-safe top-level integration + M2 memory path + DMA engine basics (Tasks 4-6)
Wave 3: GEMM completion + directed tests + negative-path coverage (Tasks 7-10)
Wave 4: full regression + docs + commit/push (Task 11)

### Dependency Matrix (full, all tasks)
- 1 blocks 2, 4, 6, 7, 8, 9
- 2 blocks 4, 7, 8, 9
- 3 blocks 8, 9, 10
- 4 blocks 7, 8, 9, 10
- 5 blocks 6, 7, 8, 9, 10
- 6 blocks 7, 8, 9
- 7 blocks 9, 11
- 8 blocks 11
- 9 blocks 11
- 10 blocks 11

### Agent Dispatch Summary (wave → task count → categories)
- Wave 1 → 3 tasks → `rtl`, `verification`, `tb`
- Wave 2 → 3 tasks → `rtl`, `rtl`, `rtl`
- Wave 3 → 4 tasks → `rtl`, `tb`, `verification`, `verification`
- Wave 4 → 1 task → `build`, `doc`

## TODOs
> Implementation + Test = ONE task. Never separate.
> EVERY task MUST have: Agent Profile + Parallelization + QA Scenarios.

- [ ] 1. Freeze the RoCC CUSTOM0 / DMA / GEMM contract

  **What to do**: Define the P3 architectural contract before any RTL edit. In `rtl/define_v2.v`, add the canonical CUSTOM0 opcode/funct7 names used by the active core path. In `rtl/rocc_ai_accelerator.v`, document the exact meanings of `rs1`, `rs2`, `rd`, legal addresses, alignment rules, RAM-only restriction, fixed 8x8 GEMM shape, single-outstanding semantics, and the definition of `STATUS.READ` fields (`busy`, `done`, `error`, optional reserved bits). Freeze flush behavior: if the RoCC op is flushed, ongoing work may finish internally but its completion must be suppressed architecturally by kill/epoch logic. Freeze completion meaning: the instruction is complete only after DMA storeback finishes and WB-safe response is emitted.
  **Must NOT do**: Do not add burst DMA, VM/coherency semantics, MMIO DMA, interrupt-driven completion, variable tile shapes, or a speculative “we can decide later” contract.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: contract lands in active RTL constants and module headers
  - Skills: `[]` — no extra skill needed
  - Omitted: `verification` — testing follows after contract freeze

  **Parallelization**: Can Parallel: NO | Wave 1 | Blocks: [2, 4, 6, 7, 8, 9] | Blocked By: []

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `rtl/rocc_ai_accelerator.v` — existing standalone cmd/resp + DMA-style interface and TODO placeholders
  - Pattern: `rtl/define_v2.v` — existing opcode/funct definitions and memory-map constants
  - Pattern: `README.md` — current roadmap claims P3 exists conceptually but not fully integrated
  - External: `https://riscv.org/wp-content/uploads/2019/06/riscv-custom-ext-workshop-june19.pdf` — CUSTOM opcode usage background (use only for opcode convention sanity, not to expand scope)

  **Acceptance Criteria** (agent-executable only):
  - [ ] `rtl/define_v2.v` contains named CUSTOM0/RoCC constants used by the active implementation path.
  - [ ] `rtl/rocc_ai_accelerator.v` header/comments define operand contract, completion semantics, RAM-only restriction, and fixed 8x8 GEMM behavior.
  - [ ] No new TODO/FIXME placeholders are introduced for unresolved RoCC semantics.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Contract freeze is machine-readable
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s`
    Expected: Existing baseline still compiles/runs after constant/header updates
    Evidence: .sisyphus/evidence/task-1-contract-baseline.log

  Scenario: No unresolved semantics left behind
    Tool: Bash
    Steps: Run `git diff -- rtl/define_v2.v rtl/rocc_ai_accelerator.v`
    Expected: Diff shows explicit contract additions without vague TODO placeholders
    Evidence: .sisyphus/evidence/task-1-contract-diff.log
  ```

  **Commit**: YES | Message: `feat(rocc): freeze custom0 dma gemm contract` | Files: [`rtl/define_v2.v`, `rtl/rocc_ai_accelerator.v`]

- [ ] 2. Add serialized RoCC decode and dispatch metadata path

  **What to do**: Extend `rtl/stage_is.v`, `rtl/ctrl.v`, and `rtl/decoder_dual.v` so CUSTOM0 is recognized as `is_rocc` with full funct7 payload preserved through active decode metadata. Add serializer rules so a RoCC instruction cannot dual-issue alongside another instruction and cannot dispatch while another RoCC is outstanding. If additional metadata plumbing is required in scoreboard/top-level decode buses, add it now rather than burying it in later tasks. Define the default toolchain ROM encoding approach as `.insn`-based custom instructions for new tests.
  **Must NOT do**: Do not model RoCC as a third OoO execution lane, do not discard funct7 bits, and do not allow RoCC μops to bypass existing dispatch/ROB tagging.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: decode/control/dispatch plumbing is RTL-centric
  - Skills: `[]`
  - Omitted: `tb` — no bench edits belong in this task

  **Parallelization**: Can Parallel: NO | Wave 1 | Blocks: [4, 7, 8, 9] | Blocked By: [1]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `rtl/stage_is.v` — active decode classification seam, currently no CUSTOM0 path
  - Pattern: `rtl/ctrl.v` — control decode seam, currently no RoCC control outputs
  - Pattern: `rtl/decoder_dual.v` — existing serialization logic for special instructions; extend this instead of inventing a separate ad hoc gate
  - Pattern: `rtl/adam_riscv_v2.v` — top-level decode/issue plumbing endpoint for added metadata
  - Pattern: `rtl/rocc_ai_accelerator.v` — funct7 command inventory to preserve end to end

  **Acceptance Criteria** (agent-executable only):
  - [ ] CUSTOM0 instructions decode into an explicit RoCC path with full funct7 preserved.
  - [ ] Decoder/dispatch enforces single-issue/serialized behavior for RoCC instructions.
  - [ ] Non-RoCC legacy tests remain buildable via `run_all_tests.py --basic --tests test1.s test2.S`.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Legacy decode still works
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test1.s test2.S`
    Expected: Both directed legacy tests pass after decode/control changes
    Evidence: .sisyphus/evidence/task-2-legacy-decode.log

  Scenario: RoCC serialization path compiles
    Tool: Bash
    Steps: Add/compile a minimal RoCC directed ROM using `.insn` and run `python verification/run_all_tests.py --basic --tests test_rocc_decode_serialize.s`
    Expected: Simulation completes and the test proves a second back-to-back CUSTOM0 does not dual-issue or overtake while busy
    Evidence: .sisyphus/evidence/task-2-rocc-serialize.log
  ```

  **Commit**: YES | Message: `feat(rocc): add serialized custom decode path` | Files: [`rtl/stage_is.v`, `rtl/ctrl.v`, `rtl/decoder_dual.v`, `rtl/adam_riscv_v2.v`, `rom/test_rocc_decode_serialize.s`]

- [ ] 3. Harden the directed-test harness for RoCC-specific goldens

  **What to do**: Extend `comp_test/tb_v2.sv`, `comp_test/test_content.sv`, and `verification/run_all_tests.py` so new RoCC tests have unique signatures, deterministic identification, and explicit RAM/register/status goldens. Reserve concrete test names up front in the `--basic` list: `test_rocc_dma_copy_basic.s`, `test_rocc_gemm_dma_basic.s`, `test_rocc_busy_serialize.s`, and `test_rocc_flush_kill.s`. If RoCC tests need bench-side observability (for example a busy probe or signature memory window), add it here. Keep all verdicts executable and binary.
  **Must NOT do**: Do not leave RoCC tests on the generic P2-style TUBE-only path and do not use collision-prone first-instruction IDs without a unique signature rule.

  **Recommended Agent Profile**:
  - Category: `tb` — Reason: primary work is in testbench/golden logic
  - Skills: `[]`
  - Omitted: `rtl` — no feature RTL behavior should be changed here beyond observability hooks

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [8, 9, 10, 11] | Blocked By: [1]

  **References** (executor has NO interview context — be exhaustive):
  - Test: `comp_test/tb_v2.sv:37-85` — preload contract and stimulus pattern reference
  - Test: `comp_test/test_content.sv:9-141` — current test ID dispatch and golden-check structure
  - Test: `verification/run_all_tests.py:104-160` — maintained `--basic` list and per-ROM build/run flow
  - Pattern: `rom/test_l2_mmio_bypass.s` — self-check + TUBE pattern with include constants
  - Pattern: `rom/test_plic_external_interrupt.s` — testbench stimulus-dependent directed test pattern

  **Acceptance Criteria** (agent-executable only):
  - [ ] `run_all_tests.py --basic` includes placeholder entries for all new RoCC tests.
  - [ ] `test_content.sv` contains explicit, unique dispatch and goldens for each new RoCC test.
  - [ ] `tb_v2.sv` exposes any new deterministic observability or stimulus needed by RoCC tests.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Harness recognizes each RoCC test uniquely
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_dma_copy_basic.s test_rocc_gemm_dma_basic.s test_rocc_busy_serialize.s test_rocc_flush_kill.s`
    Expected: Each test is identified by its explicit branch in `test_content.sv`; no generic fallback path is used
    Evidence: .sisyphus/evidence/task-3-harness-identification.log

  Scenario: Legacy harness behavior remains intact
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rv32i_full.s test_l2_mmio_bypass.s`
    Expected: Existing non-RoCC tests still pass with no regression in bench dispatch/golden logic
    Evidence: .sisyphus/evidence/task-3-harness-regression.log
  ```

  **Commit**: YES | Message: `test(tb): harden rocc directed harness and basic list` | Files: [`comp_test/tb_v2.sv`, `comp_test/test_content.sv`, `verification/run_all_tests.py`]

- [ ] 4. Integrate RoCC into top-level issue/retire with flush-safe completion

  **What to do**: Instantiate `rtl/rocc_ai_accelerator.v` in `rtl/adam_riscv_v2.v` and connect it to the active V2 command path using the metadata added in Task 2. Implement a serialized single-outstanding command launcher and a WB/ROB-safe response merge. Add explicit flush/kill or epoch protection so a stale RoCC completion after branch mispredict/trap/reset cannot complete a reused tag. Define arbitration against existing WB paths so RoCC completion never silently collides with current `wb1` sources. Suppress architectural write when `rd == x0` while still completing the instruction correctly.
  **Must NOT do**: Do not write RoCC results directly into the regfile, do not rely on raw tag identity without kill/epoch protection, and do not allow more than one in-flight RoCC command.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: top-level issue/retire integration and flush safety are RTL-critical
  - Skills: `[]`
  - Omitted: `tb` — tests come later

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [7, 8, 9, 10] | Blocked By: [1, 2]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `rtl/adam_riscv_v2.v` — active WB/ROB/top-level integration point, currently lacks accelerator instantiation
  - Pattern: `rtl/rocc_ai_accelerator.v:89` — `accel_interrupt` currently TODO/tied low
  - Pattern: `rtl/rocc_ai_accelerator.v:189` — unimplemented op handling placeholder
  - Pattern: `rtl/rocc_ai_accelerator.v:203` — GEMM accumulator placeholder seam
  - Pattern: existing WB/ROB tag flow in `rtl/adam_riscv_v2.v`, `rtl/scoreboard_v2.v`, and execution-pipe result plumbing
  - Pattern: `rtl/exec_pipe1.v` / `rtl/lsu_shell.v` — current long-latency request/response metadata handling reference

  **Acceptance Criteria** (agent-executable only):
  - [ ] `adam_riscv_v2` instantiates `rocc_ai_accelerator` and emits RoCC commands only when serialized/allowed.
  - [ ] A RoCC response completes through the existing WB/ROB machinery and cannot retire after flush if killed.
  - [ ] `rd == x0` RoCC commands complete without corrupting architectural register state.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: RoCC completion writes back safely
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_busy_serialize.s`
    Expected: Single-outstanding behavior holds and the final result/status reaches architectural state only once
    Evidence: .sisyphus/evidence/task-4-rocc-retire.log

  Scenario: Flushed RoCC response is suppressed
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_flush_kill.s`
    Expected: After a forced flush, stale RoCC completion does not update registers, ROB completion, or pass signature incorrectly
    Evidence: .sisyphus/evidence/task-4-rocc-flush-kill.log
  ```

  **Commit**: YES | Message: `feat(rocc): integrate serialized issue and safe completion` | Files: [`rtl/adam_riscv_v2.v`, `rtl/rocc_ai_accelerator.v`, related scoreboard/WB plumbing files]

- [ ] 5. Add a dedicated M2 RoCC DMA master to the lower-memory path

  **What to do**: Extend `rtl/mem_subsys.v`, `rtl/l2_arbiter.v`, and any required support logic so RoCC DMA becomes a first-class M2 master. Preserve current M0 I-side and M1 D-side behavior. Define deterministic arbitration order and fairness (round-robin over active M0/M1/M2 is the default). Keep P3 DMA RAM-only: reject or ignore MMIO/uncached address regions explicitly per the frozen contract. If `l2_cache.v` needs request-ID-neutral adjustments for M2, make them here. Ensure M2 responses can stall safely without deadlock.
  **Must NOT do**: Do not tunnel DMA through LSU/store-buffer/M1, do not add MMIO DMA support, and do not weaken existing M0/M1 behavior to “make tests pass.”

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: memory hierarchy and arbitration changes are RTL-heavy
  - Skills: `[]`
  - Omitted: `verification` — verification consumes this infrastructure later

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [6, 7, 8, 9, 10] | Blocked By: [1]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `rtl/mem_subsys.v` — current 2-master memory subsystem seam
  - Pattern: `rtl/l2_arbiter.v` — current 2-master arbitration point, must be generalized to M2
  - Pattern: `rtl/l2_cache.v` — current unified blocking L2 behind arbiter
  - Pattern: `rtl/lsu_shell.v` — existing variable-latency request/response handshakes to mirror for DMA semantics, not to reuse for transport
  - Pattern: `rtl/inst_memory.v` — current M0-side refill behavior reference

  **Acceptance Criteria** (agent-executable only):
  - [ ] `mem_subsys` exposes a dedicated RoCC DMA master interface and top-level wiring point.
  - [ ] `l2_arbiter` services three masters without starvation in the directed contention tests.
  - [ ] Existing M0/M1 tests still pass after M2 is added.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: M2 can move RAM data independently of LSU path
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_dma_copy_basic.s`
    Expected: DMA source RAM words are copied to destination RAM words through the M2 path and match explicit goldens
    Evidence: .sisyphus/evidence/task-5-m2-dma-copy.log

  Scenario: M0/M1/M2 contention does not deadlock
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_gemm_dma_contention.s test_l2_i_d_arbiter.s`
    Expected: Both tests complete; legacy I/D arbitration still functions while M2 is active
    Evidence: .sisyphus/evidence/task-5-m2-contention.log
  ```

  **Commit**: YES | Message: `feat(mem): add dedicated rocc dma m2 path` | Files: [`rtl/mem_subsys.v`, `rtl/l2_arbiter.v`, `rtl/l2_cache.v`, `rtl/adam_riscv_v2.v`]

- [ ] 6. Finish the RoCC DMA engine for RAM-backed data movement and status semantics

  **What to do**: Complete the internal `rocc_ai_accelerator.v` FSM for deterministic RAM-only DMA movement. Implement real `SCRATCH.LOAD`, `SCRATCH.STORE`, `STATUS.READ`, and the internal load/store substeps needed by GEMM. Define exact busy/done/error behavior and clear behavior for a new command while busy. The DMA engine should support the fixed P3 data movement needed to fetch A/B tiles into local storage/scratchpad and to write result C back, one deterministic beat at a time.
  **Must NOT do**: Do not claim DMA completion before storeback finishes, do not wire fake success paths, and do not expand P3 into generic burst or variable-length DMA.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: accelerator FSM and status behavior are internal RTL logic
  - Skills: `[]`
  - Omitted: `tb` — bench updates are already handled separately

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [7, 8, 9] | Blocked By: [1, 5]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `rtl/rocc_ai_accelerator.v` — current scratchpad, vector lanes, GEMM accumulators, and TODO seams
  - Pattern: `rtl/rocc_ai_accelerator.v:89,189,203` — explicit TODO/placeholder markers to retire
  - Pattern: `rtl/mem_subsys.v` / `rtl/l2_arbiter.v` — M2 request/response contract established in Task 5
  - Pattern: `rtl/exec_pipe1.v` / `rtl/lsu_shell.v` — reference request/response timing style for variable-latency operations

  **Acceptance Criteria** (agent-executable only):
  - [ ] `SCRATCH.LOAD`, `SCRATCH.STORE`, and `STATUS.READ` execute against real DMA traffic/state.
  - [ ] Busy/done/error semantics are deterministic and exposed through the frozen status contract.
  - [ ] No placeholder GEMM/DMA TODO branches remain in `rocc_ai_accelerator.v` for the P3 path.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: DMA copy and status reporting are consistent
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_dma_copy_basic.s test_rocc_busy_serialize.s`
    Expected: Copy result RAM words match goldens, busy is asserted during work, done is not visible before final completion
    Evidence: .sisyphus/evidence/task-6-dma-status.log

  Scenario: Illegal address region is rejected per contract
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_dma_illegal_addr.s`
    Expected: Test observes the defined failure/error behavior for MMIO or out-of-range DMA access without corrupting RAM
    Evidence: .sisyphus/evidence/task-6-dma-illegal.log
  ```

  **Commit**: YES | Message: `feat(rocc): implement dma engine and status semantics` | Files: [`rtl/rocc_ai_accelerator.v`, related top-level/status plumbing files]

- [ ] 7. Complete the real 8x8 GEMM load/compute/storeback pipeline

  **What to do**: Finish the actual GEMM path in `rocc_ai_accelerator.v` so `GEMM.START` performs: DMA load A tile from RAM, DMA load B tile from RAM, compute the 8x8 INT8/INT32 accumulation over local buffers/accumulators, then DMA store the C tile back to destination RAM. Reuse the frozen operand contract for base addresses and destination/result layout. Ensure `done` becomes visible only after final storeback completion and response emission.
  **Must NOT do**: Do not short-circuit compute by fabricating the result, do not skip RAM-backed inputs, and do not mark GEMM complete before C is written back.

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: accelerator datapath/FSM completion
  - Skills: `[]`
  - Omitted: `build` — full suite comes later

  **Parallelization**: Can Parallel: NO | Wave 3 | Blocks: [9, 11] | Blocked By: [4, 5, 6]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `rtl/rocc_ai_accelerator.v` — existing GEMM accumulator arrays and vector/local storage
  - Pattern: frozen contract from Task 1 — exact A/B/C layout and shape
  - Pattern: `verification/riscv-tests/benchmarks/vec-sgemm/vec-sgemm.S` — optional algorithm sanity reference only; do not copy benchmark harness structure into directed tests

  **Acceptance Criteria** (agent-executable only):
  - [ ] `GEMM.START` consumes real RAM-backed A/B tiles and stores back a deterministic C tile.
  - [ ] Result RAM words match the expected 8x8 GEMM output for at least one fixed fixture.
  - [ ] Busy/done/status sequencing remains correct during full GEMM execution.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: End-to-end GEMM produces the expected matrix
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_gemm_dma_basic.s`
    Expected: Destination RAM words equal the precomputed 8x8 GEMM golden matrix; TUBE reports pass only after storeback
    Evidence: .sisyphus/evidence/task-7-gemm-basic.log

  Scenario: Back-to-back GEMM requests remain serialized
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_busy_serialize.s`
    Expected: Second RoCC command does not overtake or start a second in-flight GEMM while busy is asserted
    Evidence: .sisyphus/evidence/task-7-gemm-serialize.log
  ```

  **Commit**: YES | Message: `feat(rocc): complete gemm load compute storeback path` | Files: [`rtl/rocc_ai_accelerator.v`, any associated top-level plumbing]

- [ ] 8. Add directed DMA movement and status tests to the basic suite

  **What to do**: Implement `rom/test_rocc_dma_copy_basic.s` and `rom/test_rocc_busy_serialize.s` using the frozen CUSTOM0 `.insn` contract. Extend `comp_test/test_content.sv` so these tests validate exact destination RAM words and/or status-register observations. Ensure `verification/run_all_tests.py` includes both tests in the default `--basic` list, and that any toolchain flags required for `.insn`-based custom op assembly are wired deterministically.
  **Must NOT do**: Do not accept a test that passes only because the ROM writes `0x04` to TUBE; every new test must check memory/status goldens.

  **Recommended Agent Profile**:
  - Category: `verification` — Reason: this task is dominated by directed ROMs and runner integration
  - Skills: `[]`
  - Omitted: `rtl` — no new feature logic should be introduced here beyond what prior tasks enabled

  **Parallelization**: Can Parallel: YES | Wave 3 | Blocks: [11] | Blocked By: [3, 4, 5, 6]

  **References** (executor has NO interview context — be exhaustive):
  - Test: `verification/run_all_tests.py:104-160` — explicit `--basic` list and per-ROM flow
  - Test: `comp_test/test_content.sv:9-141` — explicit signature/golden style to extend, avoiding generic fallback
  - Test: `rom/test_l2_mmio_bypass.s`, `rom/test_csr_mret_smoke.s` — representative directed self-check style
  - Pattern: `rom/p2_mmio.inc` — include-style constant organization if a `p3_rocc.inc` helper is introduced

  **Acceptance Criteria** (agent-executable only):
  - [ ] `test_rocc_dma_copy_basic.s` passes and proves source RAM words moved to destination RAM via real DMA.
  - [ ] `test_rocc_busy_serialize.s` passes and proves busy/single-outstanding behavior.
  - [ ] `python verification/run_all_tests.py --basic` includes both tests by default.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: DMA copy directed test passes with RAM goldens
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_dma_copy_basic.s`
    Expected: Bench goldens confirm the destination RAM block exactly matches the expected copied data
    Evidence: .sisyphus/evidence/task-8-dma-copy-basic.log

  Scenario: Busy/serialize directed test passes with explicit status checks
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_busy_serialize.s`
    Expected: Bench goldens confirm busy stays asserted during the first op and the second op does not complete early
    Evidence: .sisyphus/evidence/task-8-busy-serialize.log
  ```

  **Commit**: YES | Message: `test(rocc): add dma copy and serialize basic tests` | Files: [`rom/test_rocc_dma_copy_basic.s`, `rom/test_rocc_busy_serialize.s`, `comp_test/test_content.sv`, `verification/run_all_tests.py`]

- [ ] 9. Add end-to-end GEMM, contention, and storeback tests to the basic suite

  **What to do**: Implement `rom/test_rocc_gemm_dma_basic.s` and `rom/test_rocc_gemm_dma_contention.s` (or equivalent exact names if contractually frozen) and extend the bench goldens so they verify preloaded A/B data, final C RAM words, and that M0/M1 traffic continues correctly under M2 pressure. The contention test must intentionally overlap instruction fetch / regular memory activity with RoCC DMA to validate the M2 arbiter integration. If a separate `test_rocc_gemm_storeback_only.s` is useful for isolation, include it, but do not explode the suite beyond what is needed.
  **Must NOT do**: Do not use randomly generated matrices or manual waveform inspection as the primary pass criterion.

  **Recommended Agent Profile**:
  - Category: `verification` — Reason: directed ROM + bench golden focus
  - Skills: `[]`
  - Omitted: `doc` — README waits until full regression

  **Parallelization**: Can Parallel: YES | Wave 3 | Blocks: [11] | Blocked By: [3, 4, 5, 6, 7]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `rom/test_l2_i_d_arbiter.s` — mixed pressure/concurrency directed-test style
  - Pattern: `rom/test_rocc_dma_copy_basic.s` — basic DMA command style established in Task 8
  - Test: `comp_test/tb_v2.sv` — preload contract for deterministic matrix fixtures
  - Test: `comp_test/test_content.sv` — RAM goldens for explicit result words

  **Acceptance Criteria** (agent-executable only):
  - [ ] `test_rocc_gemm_dma_basic.s` verifies exact destination RAM words for a fixed GEMM fixture.
  - [ ] `test_rocc_gemm_dma_contention.s` verifies M2 DMA can coexist with normal core traffic without deadlock or corruption.
  - [ ] Both tests are included in default `--basic`.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: GEMM storeback is correct
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_gemm_dma_basic.s`
    Expected: All destination RAM golden words for the 8x8 result matrix match exactly
    Evidence: .sisyphus/evidence/task-9-gemm-basic.log

  Scenario: GEMM under contention still completes safely
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_gemm_dma_contention.s test_l2_i_d_arbiter.s`
    Expected: Both tests pass; no deadlock/starvation/regression appears in mixed I/D/M2 activity
    Evidence: .sisyphus/evidence/task-9-gemm-contention.log
  ```

  **Commit**: YES | Message: `test(rocc): add gemm dma and contention tests` | Files: [`rom/test_rocc_gemm_dma_basic.s`, `rom/test_rocc_gemm_dma_contention.s`, `comp_test/test_content.sv`, `verification/run_all_tests.py`]

- [ ] 10. Add negative-path coverage for flush/kill and illegal DMA behavior

  **What to do**: Implement `rom/test_rocc_flush_kill.s` and `rom/test_rocc_dma_illegal_addr.s` (or the exact frozen equivalents) so the suite proves stale RoCC completion cannot retire after flush and RAM-only restrictions are enforced. Extend bench checks to validate that no incorrect register write, status completion, or destination RAM corruption occurs. If needed, add deterministic branch/trap stimulus in the ROM or bench to force a flush while RoCC work is in flight.
  **Must NOT do**: Do not treat “no PASS” as enough; these tests need positive goldens that prove the forbidden behavior did not occur.

  **Recommended Agent Profile**:
  - Category: `verification` — Reason: negative-path directed verification
  - Skills: `[]`
  - Omitted: `rtl` — feature mechanisms should already exist by now

  **Parallelization**: Can Parallel: YES | Wave 3 | Blocks: [11] | Blocked By: [3, 4, 5, 6]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `rom/test_interrupt_mask_mret.s` — negative-path state validation style
  - Pattern: flush/redirect logic in active V2 path through `rtl/adam_riscv_v2.v`
  - Test: `comp_test/test_content.sv` — explicit RAM/register/status goldens required
  - Guardrail: Oracle-approved stale-tag/flush protection requirement from planning notes

  **Acceptance Criteria** (agent-executable only):
  - [ ] `test_rocc_flush_kill.s` proves a flushed RoCC op cannot retire stale completion.
  - [ ] `test_rocc_dma_illegal_addr.s` proves illegal MMIO/out-of-range DMA is rejected per contract.
  - [ ] New negative tests are listed in `--basic` and fail if protections are removed.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Flushed RoCC op cannot commit stale result
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_flush_kill.s`
    Expected: Bench goldens show no architectural destination update and no pass signature from a stale completion path
    Evidence: .sisyphus/evidence/task-10-flush-kill.log

  Scenario: Illegal DMA target is blocked
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --tests test_rocc_dma_illegal_addr.s`
    Expected: Status/error reflects rejection and protected RAM/MMIO state remains unchanged
    Evidence: .sisyphus/evidence/task-10-illegal-dma.log
  ```

  **Commit**: YES | Message: `test(rocc): add flush safety and illegal dma coverage` | Files: [`rom/test_rocc_flush_kill.s`, `rom/test_rocc_dma_illegal_addr.s`, `comp_test/test_content.sv`, `verification/run_all_tests.py`]

- [ ] 11. Run full regression, update README, commit, and push to GitHub

  **What to do**: Run the complete verification ladder after all targeted RoCC tests are green: targeted RoCC tests, full `--basic`, then full `--basic --riscv-tests --riscv-arch-test`. Capture evidence logs. Update `README.md` to reflect the real P3 architecture, new tests, and final counts/commands. Stage only intended files, create the planned commits, and push to the tracked remote branch. If any regression fails, fix before docs/commit/push. Do not leave generated ROM hex artifacts or ad hoc debug files staged unless this repo explicitly tracks them.
  **Must NOT do**: Do not update README before regression is stable, do not push with failing full regression, and do not hide failures by weakening the runner or tests.

  **Recommended Agent Profile**:
  - Category: `build` — Reason: this is primarily regression gatekeeping and integration proof
  - Skills: `[]`
  - Omitted: `rtl` — feature work should already be complete

  **Parallelization**: Can Parallel: NO | Wave 4 | Blocks: [] | Blocked By: [3, 7, 8, 9, 10]

  **References** (executor has NO interview context — be exhaustive):
  - Test: `verification/run_all_tests.py:104-160,231-259` — maintained list and summary/exit behavior
  - Test: `comp_test/tb_v2.sv:95-117` — PASS/FAIL task output used by the runner
  - Test: `README.md` — architecture, test list, roadmap, and verification-status sections to update
  - Pattern: prior P2 README/test updates already landed in repo and should be mirrored stylistically

  **Acceptance Criteria** (agent-executable only):
  - [ ] `python verification/run_all_tests.py --basic` passes with legacy + new RoCC tests included.
  - [ ] `python verification/run_all_tests.py --basic --riscv-tests --riscv-arch-test` completes successfully with accepted suite thresholds.
  - [ ] `README.md` documents P3 RoCC DMA/GEMM functionality, new tests, and final counts.
  - [ ] Git history contains the planned commits and `git push origin main` succeeds.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```
  Scenario: Full directed/basic regression is green
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic`
    Expected: Summary reports all legacy and new RoCC directed tests passing
    Evidence: .sisyphus/evidence/task-11-basic-regression.log

  Scenario: Full repository regression is green
    Tool: Bash
    Steps: Run `python verification/run_all_tests.py --basic --riscv-tests --riscv-arch-test`
    Expected: Script exits successfully and reports acceptable pass counts for all suites
    Evidence: .sisyphus/evidence/task-11-full-regression.log
  ```

  **Commit**: YES | Message: `docs(readme): finalize p3 rocc dma status` | Files: [`README.md`, regression evidence, committed implementation files]; push after final verification approvals

## Final Verification Wave (MANDATORY — after ALL implementation tasks)
> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.
> **Do NOT auto-proceed after verification. Wait for user's explicit approval before marking work complete.**
> **Never mark F1-F4 as checked before getting user's okay.** Rejection or user feedback -> fix -> re-run -> present again -> wait for okay.
- [ ] F1. Plan Compliance Audit — oracle
- [ ] F2. Code Quality Review — unspecified-high
- [ ] F3. Real Manual QA — unspecified-high (+ playwright if UI)
- [ ] F4. Scope Fidelity Check — deep

## Commit Strategy
- Preferred execution commits:
  1. `feat(rocc): add custom decode and serialized issue contract`
  2. `feat(mem): add dedicated rocc dma master path`
  3. `feat(rocc): complete gemm dma pipeline and directed tests`
  4. `docs(readme): document p3 rocc dma and regression status`
- Push only after full regression is green and final verification wave passes.
- Push target: tracked remote branch (`origin/main`) because the user explicitly requested GitHub sync.

## Success Criteria
- New RoCC DMA/GEMM functionality is integrated into the active V2 path, not left standalone.
- New tests are listed in `run_all_tests.py --basic` and are backed by deterministic bench goldens.
- Legacy basic regression remains green after adding M2.
- Full regression command completes and is captured as evidence.
- README and Git history accurately describe the final P3 state.
