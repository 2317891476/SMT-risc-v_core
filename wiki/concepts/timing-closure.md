# Timing Closure

## Target

- Board: AX7203 `xc7a200tfbg484-2`
- Core clock: 25 MHz
- Required tool: Vivado 2023.2

## Current Status

Vivado 2023.2 synthesis has completed for the current RTL line. The current blocker is implementation process instability, not a proven timing path:

- Aggressive implementation has terminated during place/route with `The system cannot find the path specified`.
- Incremental implementation has terminated while building or reading the reuse database with the same process-level message.
- Existing logs did not show a definitive RTL DRC or negative-slack root cause before termination.

## Triage Rule

For future timing closure work:

- Use current reports, not remembered WNS/WHS values.
- If implementation fails before a timing report, classify it as tool-flow/environment until logs prove otherwise.
- Keep explicit Vivado logs/journals per attempt to avoid overwriting evidence.
- Set `TEMP` and `TMP` to a short local path before reruns if path/tool instability continues.
