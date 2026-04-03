# P2 MMIO Address Map Constants (assembly version)
# Include this file in P2 test ROMs: .include "p2_mmio.inc"

# Cacheable RAM window (first 16KB)
.equ RAM_CACHEABLE_BASE,  0x00000000
.equ RAM_CACHEABLE_TOP,   0x00003FFF

# TUBE MMIO (test completion marker)
.equ TUBE_ADDR,           0x13000000
.equ UART_TXDATA_ADDR,    0x13000010
.equ UART_STATUS_ADDR,    0x13000014
.equ UART_RXDATA_ADDR,    0x13000018
.equ UART_CTRL_ADDR,      0x1300001C

.equ UART_STATUS_TX_BUSY_MASK,      0x01
.equ UART_STATUS_TX_READY_MASK,     0x02
.equ UART_STATUS_RX_VALID_MASK,     0x04
.equ UART_STATUS_RX_OVERRUN_MASK,   0x08
.equ UART_STATUS_RX_FRAME_ERR_MASK, 0x10
.equ UART_STATUS_RX_EN_MASK,        0x20
.equ UART_STATUS_TX_EN_MASK,        0x40

.equ UART_CTRL_TX_EN_MASK,          0x01
.equ UART_CTRL_RX_EN_MASK,          0x02
.equ UART_CTRL_CLR_RX_OVERRUN_MASK, 0x04
.equ UART_CTRL_CLR_RX_FRAME_ERR_MASK, 0x08
.equ UART_CTRL_FLUSH_RX_MASK,       0x10

# CLINT (Core Local Interruptor) - Machine Timer
.equ CLINT_BASE,          0x02000000
.equ CLINT_MTIMECMP_LO,   0x02004000
.equ CLINT_MTIMECMP_HI,   0x02004004
.equ CLINT_MTIME_LO,      0x0200BFF8
.equ CLINT_MTIME_HI,      0x0200BFFC

# PLIC (Platform Level Interrupt Controller) - Single source, single context
.equ PLIC_BASE,           0x0C000000
.equ PLIC_PRIORITY1,      0x0C000004
.equ PLIC_PENDING,        0x0C001000
.equ PLIC_ENABLE,         0x0C002000
.equ PLIC_THRESHOLD,      0x0C200000
.equ PLIC_CLAIM_COMPLETE, 0x0C200004
