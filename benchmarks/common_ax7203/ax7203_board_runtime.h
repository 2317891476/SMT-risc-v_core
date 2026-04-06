#ifndef AX7203_BOARD_RUNTIME_H
#define AX7203_BOARD_RUNTIME_H

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#ifndef AX7203_CPU_HZ
#define AX7203_CPU_HZ 10000000UL
#endif

#ifndef AX7203_BENCH_STARTUP_DELAY_MS
#define AX7203_BENCH_STARTUP_DELAY_MS 0U
#endif

#define AX7203_TUBE_ADDR          0x13000000UL
#define AX7203_UART_TXDATA_ADDR   0x13000010UL
#define AX7203_UART_STATUS_ADDR   0x13000014UL
#define AX7203_UART_RXDATA_ADDR   0x13000018UL
#define AX7203_UART_CTRL_ADDR     0x1300001CUL

#define AX7203_UART_STATUS_BUSY       (1u << 0)
#define AX7203_UART_STATUS_TX_READY   (1u << 1)
#define AX7203_UART_STATUS_RX_VALID   (1u << 2)
#define AX7203_UART_STATUS_RX_OVERRUN (1u << 3)
#define AX7203_UART_STATUS_FRAME_ERR  (1u << 4)
#define AX7203_UART_STATUS_RX_ENABLE  (1u << 5)
#define AX7203_UART_STATUS_TX_ENABLE  (1u << 6)

#define AX7203_UART_CTRL_TX_ENABLE      (1u << 0)
#define AX7203_UART_CTRL_RX_ENABLE      (1u << 1)
#define AX7203_UART_CTRL_CLEAR_OVERRUN  (1u << 2)
#define AX7203_UART_CTRL_CLEAR_FRAMEERR (1u << 3)
#define AX7203_UART_CTRL_FLUSH_RX       (1u << 4)

extern unsigned char __bss_start;
extern unsigned char __bss_end;
extern unsigned char __stack_top;

void board_runtime_init(void);
void board_uart_init(void);
void board_uart_putc(char ch);
int board_uart_try_getc(uint8_t *byte_out);
void board_tube_write(uint8_t value);
uint64_t board_read_mcycle64(void);
void board_delay_cycles(uint32_t cycles);
void board_delay_ms(uint32_t ms);

int board_vprintf(const char *fmt, va_list ap);
int board_printf(const char *fmt, ...);
int printf(const char *fmt, ...);
int sprintf(char *str, const char *fmt, ...);
int putchar(int ch);

void setStats(int enable);
void exit(int code) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));

void *memcpy(void *dest, const void *src, size_t len);
void *memmove(void *dest, const void *src, size_t len);
void *memset(void *dest, int byte, size_t len);
int memcmp(const void *lhs, const void *rhs, size_t len);
size_t strlen(const char *s);
size_t strnlen(const char *s, size_t n);
int strcmp(const char *lhs, const char *rhs);
char *strcpy(char *dest, const char *src);

#endif
