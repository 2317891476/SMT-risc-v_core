---
active: true
iteration: 2
completion_promise: "DONE"
initial_completion_promise: "DONE"
started_at: "2026-03-25T13:35:34.411Z"
session_id: "ses_2dc31500effeAdKyz4G51CNvnj"
ultrawork: true
strategy: "continue"
message_count_at_start: 460
---
Plan Generated: p3-rocc-dma-gemm-pipeline
Key Decisions
- RoCC integration uses serialized single-outstanding execution, not a new parallel OoO FU.
- DMA lands on a dedicated M2 master in mem_subsys / l2_arbiter, not LSU/M1 reuse.
- P3 scope is RAM-only, deterministic, single-beat DMA for fixed 8x8 GEMM.
- RoCC completion must be flush-safe and retire through existing WB/ROB machinery only.
- New RoCC tests require explicit RAM/status goldens, not TUBE-only pass markers.
Scope
- IN: CUSTOM0 decode, top-level RoCC hookup, M2 DMA path, GEMM load/compute/storeback, directed tests, full regression, README update, commit/push.
- OUT: MMIO DMA, burst DMA, coherency, VM translation, multi-outstanding RoCC, interrupt-driven completion.
Guardrails
- No fake GEMM path bypassing mem_req/mem_resp
- No direct regfile write from accelerator
- No stale completion after flush/tag reuse
- No GitHub push before full regression is green
Defaults Applied
- .insn-based custom ROM encoding
- Final full verification command: python verification/run_all_tests.py
