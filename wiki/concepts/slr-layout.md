# SLR Layout

## AX7203 Note

AX7203 uses an Artix-7 `xc7a200t` device, not a multi-SLR UltraScale-class FPGA. SLR partitioning is not an active design dimension for this board.

## What To Track Instead

- Clock regions and high-fanout reset/control nets.
- MIG/DDR3 placement constraints.
- UART/JTAG/debug logic placement only if a current report points there.
- Core issue/dispatch/ROB placement if route or timing reports identify it as a current problem.
