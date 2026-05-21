# Resource Estimation

## Current Use

Resource estimates are useful for deciding whether to expand ROB/PRF/IQ, add branch prediction structures, or remap memory arrays. They are not currently the primary blocker.

## Recording Rule

When updating resource numbers, record:

- Build ID or checkpoint timestamp.
- Vivado version.
- Top module and major defines.
- LUT, FF, LUTRAM, BRAM, DSP totals.
- Whether the numbers are post-synth or post-route.

Do not mix old signoff utilization with current single-thread UART-loader builds without labeling the source.
