# RTL Coding Rules

## Single-Thread Debug Rules

- Keep the active design single-thread. Do not restore SMT behavior to make tests pass.
- Tie removed or unused TID paths to `1'b0` intentionally; do not leave top-level TID wires floating.
- Avoid broad generated rewrites in shared RTL. Make small, reviewable changes and run focused tests.
- Before editing shared RTL, check `git status` and avoid overwriting unrelated changes.

## Debug Instrumentation

- Prefer low-risk status/beacon wiring over adding wide new debug ports through timing-critical modules.
- Remove temporary `$display` debugging once the evidence has been captured.
- Record durable debug lessons in this wiki under R1.

## Branch Tracking Caution

In FPGA mode, do not duplicate branch completion pulses into scoreboard/dispatch branch tracking. A duplicate completion pulse can pop a newly pushed branch and leave dispatch stuck behind stale speculative state.
