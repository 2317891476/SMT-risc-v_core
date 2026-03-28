# V2 Simulation Debug Status

## Summary
V2 simulation infrastructure has been fixed to correctly fetch instructions through the icache with mem_subsys. However, register writeback issues remain that prevent tests from passing.

## Changes Made

### 1. rtl/inst_memory_v2.v
- Fixed bypass data timing by registering inst_addr to match icache's internal registered address
- This ensures bypass_data aligns with icache miss detection timing

### 2. rtl/stage_if_v2.v
- Added pc_out_r register to delay ext_mem_bypass_addr by 1 cycle
- This matches mem_subsys RAM's 1-cycle read latency

### 3. rtl/icache.v
- Fixed resp_valid_r to be valid on first cycle of miss (when state == S_IDLE && !hit)
- Ensures bypass_data is accepted on the first miss

### 4. rtl/adam_riscv_v2.v
- Changed USE_MEM_SUBSYS from 0 to 1 to enable mem_subsys for TUBE write detection

### 5. comp_test/tb_v2.sv
- Added init_mem_subsys to preload mem_subsys.ram with instruction data
- This is required for external refill bypass to work

## Current Status

### Working:
- Instructions are fetched correctly through icache
- mem_subsys RAM is properly initialized with instructions
- Bypass data timing is aligned (CYCLE40-42 show correct if_inst values)
- TUBE write instruction (SB) is decoded at correct PC (0x70)

### Not Working:
- Register x4 has wrong value (0x02 instead of 0x13000000)
- LUI instruction at PC=0x48 either not executed or not writing correct value
- TUBE write goes to wrong address (0x02 instead of 0x13000000)
- TUBE_STATUS never updates, causing test timeout

## Root Cause Analysis

The issue appears to be in the execution/writeback stage:
1. PC=0x48 (LUI x4, 0x13000) is issued via SB_ISSUE1 (port 1)
2. But no EXEC1 logging exists to confirm execution
3. Register x4 ends up with value 0x02 (from earlier ADDI) instead of 0x13000000

Possible causes:
- Port 1 execution not completing
- Register file write conflict between port 0 and port 1
- ROB commit ordering issue
- Scoreboard bypass network issue

## Next Steps for Debug

1. Add EXEC1 logging to exec_pipe1.v to verify port 1 execution
2. Check register file write enables for both ports
3. Verify ROB commit logic handles dual-issue correctly
4. Check if LUI result is being bypassed correctly

## Test Results

All three smoke tests fail with timeout:
- test1.s: FAIL (timeout)
- test2.S: FAIL (timeout)
- test_smt.s: FAIL (timeout)

The tests execute instructions but never complete due to TUBE_STATUS not being updated.
