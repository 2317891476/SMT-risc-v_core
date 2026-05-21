# Routing Congestion

## Current Evidence

No current report proves routing congestion is the root cause of the latest AX7203 failure. The observed implementation failures are process-level Vivado 2023.2 exits during place/route or incremental reuse with `The system cannot find the path specified`.

## Debug Guidance

- Do not start timing or congestion refactors until a fresh route/timing report identifies a failing path or congested region.
- If route completes but timing fails, record WNS/WHS/TNS/THS and the top failing paths here.
- If route fails before reports, preserve the Tcl log and classify the failure under `vivado-tooling.md`.
