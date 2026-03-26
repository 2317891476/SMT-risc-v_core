# T11: Timing Closure for AX7203 -2 Target

## Status: SYNTHESIS RUN REQUIRED

This task requires running Vivado synthesis and implementation.

## Prerequisites
- Vivado installed and licensed
- Complete RTL sources (T1-T7)
- Constraints files (T5)

## Steps

### 1. Create Project and Run Synthesis
```bash
vivado -mode batch -source fpga/create_project_ax7203.tcl
vivado -mode batch -source fpga/build_ax7203_bitstream.tcl
```

### 2. Review Timing Reports
Generated in `build/ax7203/reports/`:
- `timing_summary.rpt` - WNS, TNS, WHS
- `timing_detail.rpt` - Top 100 failing paths
- `clock_interaction.rpt` - Clock domain crossings

### 3. Success Criteria
| Metric | Target | Acceptable |
|--------|--------|------------|
| WNS (Setup) | ≥ 0 ns | ≥ -0.5 ns |
| WHS (Hold) | ≥ 0 ns | ≥ -0.2 ns |
| Unconstrained Paths | 0 | 0 |

### 4. Timing Closure Process
If violations exist:
1. Review failing paths in `timing_detail.rpt`
2. Add pipeline stages to long combinational paths
3. Adjust constraints if overly tight
4. Re-run synthesis/implementation
5. Iterate until closure

## Evidence Required
- [ ] `build/ax7203/reports/timing_summary.rpt` showing WNS ≥ 0
- [ ] `build/ax7203/reports/utilization.rpt`
- [ ] `.sisyphus/evidence/task-2-build-bitstream.log` showing SUCCESS

## Blockers
- Requires Vivado synthesis run
- Physical hardware not required, but synthesis takes 30-60 minutes

## Next Steps
Run synthesis when Vivado is available. If timing fails, iterate on constraints or RTL.
