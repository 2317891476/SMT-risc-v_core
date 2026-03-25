# Learnings

- Task 1 regression gate now compiles V2 through `comp_test/module_list_v2` instead of hardcoded `../module/CORE/RTL_V1_2/*.v`; the manifest now points at `../rtl` and keeps the curated V2 source subset plus `../libs/REG_ARRAY/SRAM/ram_bfm.v`.
- `verification/run_all_tests.py --basic --tests test1.s test2.S test_rv32i_full.s` now completes with the machine-parseable summary marker `Total: 3 passed, 0 failed, 0 skipped` after printing `test1: PASS`, `test2: PASS`, and `test_rv32i_full: PASS`.
- `python verification/run_riscv_tests.py --suite riscv-tests` compiles against the repaired V2 manifest-backed RTL path and reaches the summary marker `Total: 49/50 passed`.
- `python verification/run_riscv_tests.py --suite riscv-arch-test` reaches the summary marker `Total: 47/47 passed` after the suite download succeeds.

## Task 3: Instruction Backing-Store Wrapper (2026-03-25)

### Summary
Created `inst_backing_store.v` as a stable wrapper hierarchy for bench preload compatibility. This allows testbenches to preload instructions without depending on deep RTL internals that may change when ICache is introduced.

### Stable Preload Path
```
// Old (fragile, implementation-dependent):
u_stage_if_v2.u_inst_memory.u_ram_data.mem[]

// New (stable, wrapper-based):
u_stage_if_v2.u_inst_memory.u_inst_backing_store.u_ram.mem[]
```

### Files Modified
- `rtl/inst_backing_store.v` (new) - Wrapper module with ram_bfm instance
- `rtl/inst_memory.v` - Uses wrapper for REG_ARRAY case
- `comp_test/tb_v2.sv` - Updated TB_IROM macro
- `verification/riscof/adam_riscv/env/tb_riscof.sv` - Updated preload path
- `comp_test/module_list_v2` - Added inst_backing_store.v

### Design Decisions
1. Wrapper only contains RAM instance - no logic changes to fetch path
2. Maintains identical behavior for normal reads
3. Provides clean abstraction boundary for future ICache integration
4. Minimal intrusion - only changes preload macro paths in benches

### Verification
Minimal test `tb_inst_backing_store.sv` verified:
- Preload through stable hierarchy works correctly
- Readback through inst_memory interface produces expected data
- All 4 test patterns passed (0xdeadbeef, 0xcafebabe, 0x12345678, 0xabcdef01)

### Pre-existing Blocker
Full test suite blocked by duplicate declaration in `rtl/scoreboard_v2.v`:
- `win_order_id` declared at both lines 169 and 198
- This is a pre-existing RTL bug unrelated to preload wrapper changes
- Minimal isolated test confirms wrapper functionality

## Task IF-Refactor: Request/Response Shell for stage_if_v2 (2026-03-25)

### Summary
Refactored `stage_if_v2` to use explicit request/response semantics instead of implicit fixed-latency assumptions. This prepares the IF stage for future integration with a non-blocking ICache while maintaining backward compatibility with existing tests.

### Key Changes

#### Request Phase
- `req_valid`: Asserted when IF wants to issue a fetch request
- `req_ready`: Indicates backing store can accept (hardcoded to 1'b1 for now)
- `req_accept`: `req_valid && req_ready` - PC only advances on acceptance
- `req_pc`, `req_tid`: Request metadata from PC management

#### Response Phase  
- `resp_valid`: Response has valid data (filtered by flush)
- `resp_pc`, `resp_tid`, `resp_inst`: Response metadata from latched request
- `resp_order_id`: Per-thread instruction counter for ordering/epoch tracking
- Response carries metadata to detect stale entries on flush

#### Flush Handling
- `flush_snapshot`: Captures flush state at request time
- `resp_flush_detected`: Compares snapshot to current flush state
- Responses are dropped if flush occurred for their thread
- Alternative detection: direct invalidation when flush happens

#### PC Advancement
- Old: `pc_stall_combined = pc_stall || !fb_ready`
- New: `pc_stall_combined = pc_stall || !req_ready`
- PC only advances when `req_accept` is high
- Decouples PC control from fetch buffer backpressure

### Verification Results
All basic tests pass:
- test1.s: PASS
- test2.S: PASS  
- test_rv32i_full.s: PASS

### Files Modified
- `rtl/stage_if_v2.v` - Complete refactoring with req/resp shell
- `rtl/scoreboard_v2.v` - Fixed duplicate `win_order_id` declaration
- `rtl/adam_riscv_v2.v` - Added `include "define_v2.v"` and removed duplicate `mem_wb_valid`

### Design Decisions
1. Maintained synchronous RAM timing (1-cycle latency) - no behavioral change
2. Response still uses latched PC/TID to match RAM output timing
3. BPU prediction uses request PC (not response PC) for correct timing
4. Order ID counter per thread for epoch-style tracking
5. Interface is ready for future ICache with variable latency

### Pre-existing Issues Fixed
1. Duplicate `win_order_id` in `scoreboard_v2.v` (lines 169 and 198)
2. Missing `define_v2.v` include in `adam_riscv_v2.v`
3. Duplicate `mem_wb_valid` declaration in `adam_riscv_v2.v`


## Task: LSU Path Refactor to Explicit Request/Response Shell

### Date: 2026-03-25

### Summary
Refactored the load/store path from fire-and-forget to an explicit LSU contract with request/accept/response handshakes and scoreboard gating.

### Changes Made

1. **Created `rtl/lsu_shell.v`** - New LSU shell module providing:
   - Request interface: `req_valid`/`req_accept` handshake
   - Full metadata on request: `{tid, order_id, epoch, tag, rd, func3, addr, wdata, wen}`
   - Response interface: `resp_valid` with echoed metadata
   - Load data shaping (replicated from stage_wb for single-cycle response)
   - Pass-through to stage_mem for current simulation

2. **Updated `rtl/exec_pipe1.v`**:
   - Added `lsu_req_ready` input from LSU
   - Added `mem_req_accept` output to scoreboard
   - Modified `mem_req_valid` to only assert when LSU is ready
   - Added `order_id` and `epoch` inputs/metadata outputs

3. **Updated `rtl/scoreboard_v2.v`**:
   - Added `lsu_req_ready` input
   - Updated issue gating for port 1 (LOAD/STORE): only issue when `lsu_req_ready` is high
   - Already had `order_id` and `epoch` outputs in place

4. **Updated `rtl/adam_riscv_v2.v`**:
   - Integrated LSU shell between exec_pipe1 and stage_mem
   - Updated writeback path to use LSU response signals
   - Updated bypass networks to use new LSU response wires
   - Removed old MEM/WB register stage (now handled by LSU shell)

5. **Updated `comp_test/module_list_v2`**:
   - Added `lsu_shell.v` to the compilation list
   - Added `define_v2.v` before `define.v` for proper macro resolution

### Key Design Decisions

- **Always-ready LSU**: For now, `req_accept` is hardcoded to 1'b1 since stage_mem is combinational. This will change when Store Buffer is implemented.
- **Response timing**: Loads return data 1 cycle after request (same as before). Stores complete immediately.
- **Metadata preservation**: The full metadata contract `{tid, order_id, epoch, tag, rd, func3}` flows through the LSU and is echoed back in the response for proper matching.

### Verification
- All basic tests pass: `test1.s`, `test2.S`, `test_rv32i_full.s`
- iverilog syntax check passes (with expected warnings for multi-file project)

### Notes for Future Store Buffer Integration

The LSU shell interface is now ready for Store Buffer integration:
- `req_accept` can be driven by Store Buffer capacity checks
- `order_id` will be used for memory ordering enforcement
- `epoch` will be used for speculation management (flush on mispredict)
- Response path already handles the 1-cycle latency for loads


## Task 7: Commit-Gated Architectural State Updates (2026-03-25)

### Summary
Implemented commit-gated register file writes to ensure architectural state only updates on commit, not on writeback. This prevents wrong-path (flushed) or younger-than-commit results from updating the architectural register file, while preserving bypass network functionality for in-flight operations.

### Problem
The original design wrote results to the register file at Write-Back (WB) time:
```verilog
// OLD: WB-time regfile writes (wrong-path results could update arch state)
assign w_regs_en_0 = p0_ex_valid && p0_ex_rd_wen;
assign w_regs_en_1 = wb1_from_mul ? p1_mul_regs_write : ...;
```

This allowed flushed instructions (wrong-path) to update the architectural state if they reached WB before the flush was detected.

### Solution

#### 1. Extended `rob_lite.v` with commit metadata outputs:
```verilog
output wire [4:0] commit0_rd,      // Destination register for thread 0
output wire [4:0] commit1_rd,      // Destination register for thread 1
output wire [4:0] commit0_tag,     // Tag of committing instruction T0
output wire [4:0] commit1_tag,     // Tag of committing instruction T1
```

#### 2. Added WB Result Buffer in `adam_riscv_v2.v`:
- 32-entry buffer indexed by tag (matches scoreboard tag space)
- Stores result data, rd, tid at WB time
- Entry cleared at commit time

#### 3. Commit-Gated Regfile Writes:
```verilog
// NEW: Commit-time regfile writes (flushed instructions cannot commit)
assign w_regs_en_0 = rob_commit0_valid && (rob_commit0_rd != 5'd0);
assign w_regs_addr_0 = rob_commit0_rd;
assign w_regs_data_0 = wb_result_data[rob_commit0_tag];
assign w_regs_tid_0 = 1'b0;  // Thread 0

assign w_regs_en_1 = rob_commit1_valid && (rob_commit1_rd != 5'd0);
assign w_regs_addr_1 = rob_commit1_rd;
assign w_regs_data_1 = wb_result_data[rob_commit1_tag];
assign w_regs_tid_1 = 1'b1;  // Thread 1
```

#### 4. Preserved Bypass Network:
The bypass network continues to use WB valid signals for forwarding:
```verilog
// Bypass network (unchanged - uses WB valid for in-flight ops)
assign mem_wb_valid = lsu_resp_valid;
assign wb0_valid = p0_ex_valid;
assign wb1_valid = wb1_from_mul || wb1_from_mem || wb1_from_alu;
```

### Key Design Decisions

1. **Separate concerns**: WB handles bypass/completion; Commit handles architectural state
2. **Per-thread commit ports**: Port 0 for T0 commits, Port 1 for T1 commits
3. **Result buffering**: Tag-indexed buffer holds WB results until commit
4. **Strict flush semantics**: Flushed entries marked in ROB; cannot reach commit
5. **CSR retire counters**: Already driven by `instr_retired` from ROB (no change needed)

### Verification

All tests pass:
- `test_commit_order.s`: PASS - Commit order verification
- `test_commit_flush_store.s`: PASS - Flushed stores cannot commit
- `test1.s`: PASS - Basic ALU + Load/Store
- `test2.S`: PASS - Scoreboard RAW hazards
- `test_rv32i_full.s`: PASS - RV32I full instruction coverage

### Files Modified
- `rtl/rob_lite.v` - Added commit metadata outputs (rd, tag)
- `rtl/adam_riscv_v2.v` - Added WB result buffer; changed regfile writes to commit-gated

### Architectural Invariants

1. **Bypass Network**: Uses WB valid (for in-flight data forwarding)
2. **Regfile Writes**: Use commit valid (for architectural state updates)
3. **CSR Retire**: Uses ROB `instr_retired` (already on commit)
4. **Flush Kill**: Flushed ROB entries cannot commit (by `rob_flushed` flag)
