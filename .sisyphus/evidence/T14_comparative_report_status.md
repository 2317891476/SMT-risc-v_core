# T14: Comparative -3 Implementation Report

## Status: SYNTHESIS RUNS REQUIRED

This task requires synthesis on both -2 and -3 speed grade parts for comparison.

## Prerequisites
- T11 complete for -2 part
- Vivado with -3 part support (xc7a200tfbg484-3)

## Comparison Matrix

| Metric | -2 (Primary) | -3 (Compare) | Delta |
|--------|--------------|--------------|-------|
| Part | xc7a200t-2fbg484i | xc7a200tfbg484-3 | - |
| WNS | TBD | TBD | ? |
| TNS | TBD | TBD | ? |
| WHS | TBD | TBD | ? |
| Fmax | TBD | TBD | ? |
| LUTs | TBD | TBD | ? |
| FFs | TBD | TBD | ? |
| BRAM | TBD | TBD | ? |
| DSP | TBD | TBD | ? |

## Steps

### 1. Build -2 (Primary)
```bash
vivado -mode batch -source fpga/create_project_ax7203.tcl
vivado -mode batch -source fpga/build_ax7203_bitstream.tcl
```
Collect: `build/ax7203/reports/*`

### 2. Build -3 (Compare)
```bash
set TARGET_PART=xc7a200tfbg484-3
set COMPARE_BUILD=1
vivado -mode batch -source fpga/create_project_ax7203.tcl
vivado -mode batch -source fpga/build_ax7203_bitstream.tcl
```
Collect: `build/ax7203_compare/reports/*`

### 3. Generate Report
Create `reports/ax7203_comparative_analysis.md` with:
- Timing comparison table
- Utilization comparison
- Fmax analysis
- Recommendations

## Evidence Required
- [ ] Timing reports for both parts
- [ ] Utilization reports for both parts
- [ ] Comparative analysis document

## Blockers
- Requires T11 complete
- Requires Vivado synthesis on both parts
- -3 part is secondary; primary signoff is -2

## Note
As per `board_manifest_ax7203.md`:
- **Primary Target**: xc7a200t-2fbg484i (board realistic)
- **Secondary Compare**: xc7a200tfbg484-3 (user requested)
- -3 results are "compare-only", not primary signoff

## Next Steps
Run when T11 complete and time available for secondary comparison.
