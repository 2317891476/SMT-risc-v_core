# ASIC Extrapolation

## Scope

Current work targets AX7203 FPGA bring-up, not ASIC signoff. ASIC extrapolation must be clearly labeled as an estimate and must not replace FPGA evidence.

## Caveats

- FPGA LUTRAM/BRAM choices do not map directly to ASIC SRAM/compiler choices.
- FPGA reset, clocking, MIG DDR3, UART loader, and JTAG behavior are board-specific.
- Timing closure at 25 MHz on Artix-7 is not an ASIC frequency estimate.

Use this page for future notes only after the FPGA baseline is stable.
