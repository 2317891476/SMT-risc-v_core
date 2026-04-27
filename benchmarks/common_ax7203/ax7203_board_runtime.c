#include "ax7203_board_runtime.h"

#include <limits.h>

static inline volatile uint32_t *mmio32(uintptr_t addr) {
    return (volatile uint32_t *)addr;
}

static inline void board_mmio_relax(void) {
#ifdef VERILATOR_MAINLINE
    __asm__ volatile("" ::: "memory");
#else
    __asm__ volatile("nop\nnop\nnop");
#endif
}

static inline unsigned char board_relaxed_load_u8(const volatile unsigned char *addr) {
    unsigned char value = *addr;
    board_mmio_relax();
    return value;
}

static inline void board_relaxed_store_u8(volatile unsigned char *addr, unsigned char value) {
    *addr = value;
    board_mmio_relax();
}

static void board_uart_tx_delay(void) {
#ifdef VERILATOR_MAINLINE
    return;
#else
    unsigned long cycles = (AX7203_CPU_HZ / 115200UL) * 12UL;
    while (cycles-- != 0UL) {
        __asm__ volatile("nop");
    }
#endif
}

void board_delay_cycles(uint32_t cycles) {
    while (cycles-- != 0u) {
        __asm__ volatile("nop");
    }
}

void board_delay_ms(uint32_t ms) {
    const uint32_t cycles_per_ms = (uint32_t)(AX7203_CPU_HZ / 1000UL);
    while (ms-- != 0u) {
        board_delay_cycles(cycles_per_ms);
    }
}

static void board_putch(int ch, void **putdat) {
    if (putdat != 0) {
        char *out = (char *)*putdat;
        *out++ = (char)ch;
        *putdat = out;
        return;
    }

    if (ch == '\n') {
        board_uart_putc('\r');
    }
    board_uart_putc((char)ch);
}

static void printnum(
    void (*putch)(int, void **),
    void **putdat,
    unsigned long long num,
    unsigned base,
    int width,
    int padc
) {
    unsigned digs[sizeof(num) * CHAR_BIT];
    int pos = 0;

    while (1) {
        digs[pos++] = (unsigned)(num % base);
        if (num < base) {
            break;
        }
        num /= base;
    }

    while (width-- > pos) {
        putch(padc, putdat);
    }

    while (pos-- > 0) {
        putch((int)(digs[pos] + (digs[pos] >= 10 ? 'a' - 10 : '0')), putdat);
    }
}

static unsigned long long getuint(va_list *ap, int lflag) {
    if (lflag >= 2) {
        return va_arg(*ap, unsigned long long);
    }
    if (lflag == 1) {
        return va_arg(*ap, unsigned long);
    }
    return va_arg(*ap, unsigned int);
}

static long long getint(va_list *ap, int lflag) {
    if (lflag >= 2) {
        return va_arg(*ap, long long);
    }
    if (lflag == 1) {
        return va_arg(*ap, long);
    }
    return va_arg(*ap, int);
}

static int board_vprintfmt(
    void (*putch)(int, void **),
    void **putdat,
    const char *fmt,
    va_list ap
) {
    const char *p;
    const char *last_fmt;
    unsigned long long num;
    int ch;
    int base;
    int lflag;
    int width;
    int precision;
    char padc;
    int count = 0;

    while (1) {
        while ((ch = *(const unsigned char *)fmt) != '%') {
            if (ch == '\0') {
                return count;
            }
            fmt++;
            putch(ch, putdat);
            count++;
        }
        fmt++;

        last_fmt = fmt;
        padc = ' ';
        width = -1;
        precision = -1;
        lflag = 0;

reswitch:
        switch (ch = *(const unsigned char *)fmt++) {
        case '-':
            padc = '-';
            goto reswitch;
        case '0':
            padc = '0';
            goto reswitch;
        case '1':
        case '2':
        case '3':
        case '4':
        case '5':
        case '6':
        case '7':
        case '8':
        case '9':
            for (precision = 0;; ++fmt) {
                precision = precision * 10 + ch - '0';
                ch = *fmt;
                if (ch < '0' || ch > '9') {
                    break;
                }
            }
            goto process_precision;
        case '*':
            precision = va_arg(ap, int);
            goto process_precision;
        case '.':
            if (width < 0) {
                width = 0;
            }
            goto reswitch;
        case '#':
            goto reswitch;
process_precision:
            if (width < 0) {
                width = precision;
                precision = -1;
            }
            goto reswitch;
        case 'l':
            lflag++;
            goto reswitch;
        case 'c':
            putch(va_arg(ap, int), putdat);
            count++;
            break;
        case 's':
            p = va_arg(ap, char *);
            if (p == 0) {
                p = "(null)";
            }
            if (width > 0 && padc != '-') {
                int pad = width - (int)strnlen(p, precision < 0 ? (size_t)-1 : (size_t)precision);
                while (pad-- > 0) {
                    putch(padc, putdat);
                    count++;
                }
            }
            while ((ch = *p) != '\0' && (precision < 0 || precision-- > 0)) {
                putch(ch, putdat);
                p++;
                count++;
                if (width > 0) {
                    width--;
                }
            }
            while (width-- > 0) {
                putch(' ', putdat);
                count++;
            }
            break;
        case 'd':
            num = (unsigned long long)getint(&ap, lflag);
            if ((long long)num < 0) {
                putch('-', putdat);
                count++;
                num = (unsigned long long)(-(long long)num);
            }
            base = 10;
            goto print_number;
        case 'u':
            base = 10;
            num = getuint(&ap, lflag);
            goto print_number;
        case 'o':
            base = 8;
            num = getuint(&ap, lflag);
            goto print_number;
        case 'p':
            lflag = 1;
            putch('0', putdat);
            putch('x', putdat);
            count += 2;
            base = 16;
            num = getuint(&ap, lflag);
            goto print_number;
        case 'x':
        case 'X':
            base = 16;
            num = getuint(&ap, lflag);
print_number:
            printnum(putch, putdat, num, (unsigned)base, width, padc);
            break;
        case '%':
            putch('%', putdat);
            count++;
            break;
        default:
            putch('%', putdat);
            count++;
            fmt = last_fmt;
            break;
        }
    }
}

void board_uart_init(void) {
    *mmio32(AX7203_UART_CTRL_ADDR) =
        AX7203_UART_CTRL_TX_ENABLE |
        AX7203_UART_CTRL_RX_ENABLE |
        AX7203_UART_CTRL_CLEAR_OVERRUN |
        AX7203_UART_CTRL_CLEAR_FRAMEERR |
        AX7203_UART_CTRL_FLUSH_RX;
    *mmio32(AX7203_UART_CTRL_ADDR) =
        AX7203_UART_CTRL_TX_ENABLE |
        AX7203_UART_CTRL_RX_ENABLE;
}

void board_tube_write(uint8_t value) {
    *mmio32(AX7203_TUBE_ADDR) = (uint32_t)value;
}

void board_runtime_init(void) {
#ifdef AX7203_CLEAR_BSS
    unsigned char *p;
    for (p = &__bss_start; p < &__bss_end; ++p) {
        *p = 0;
    }
#endif
    board_uart_init();
    board_tube_write(0x04);
}

void board_uart_putc(char ch) {
    while (!(*mmio32(AX7203_UART_STATUS_ADDR) & AX7203_UART_STATUS_TX_READY)) {
        board_mmio_relax();
    }
    *mmio32(AX7203_UART_TXDATA_ADDR) = (uint32_t)(uint8_t)ch;
    board_uart_tx_delay();
}

void __attribute__((noinline)) board_print_u32(uint32_t val) {
    char buf[10];
    int pos = 0;
    if (val == 0u) {
        board_uart_putc('0');
        return;
    }
    while (val != 0u) {
        buf[pos++] = (char)('0' + (val % 10u));
        val /= 10u;
    }
    while (pos-- > 0) {
        board_uart_putc(buf[pos]);
    }
}

int board_uart_try_getc(uint8_t *byte_out) {
    uint32_t status = *mmio32(AX7203_UART_STATUS_ADDR);
    board_mmio_relax();
    if ((status & AX7203_UART_STATUS_RX_VALID) == 0u) {
        return 0;
    }
    *byte_out = (uint8_t)(*mmio32(AX7203_UART_RXDATA_ADDR) & 0xFFu);
    return 1;
}

uint64_t board_read_mcycle64(void) {
    uint32_t hi0;
    uint32_t lo;
    uint32_t hi1;

    do {
        __asm__ volatile("rdcycleh %0" : "=r"(hi0));
        __asm__ volatile("rdcycle %0" : "=r"(lo));
        __asm__ volatile("rdcycleh %0" : "=r"(hi1));
    } while (hi0 != hi1);

    return (((uint64_t)hi1) << 32) | (uint64_t)lo;
}

uint64_t board_read_minstret64(void) {
    uint32_t hi0;
    uint32_t lo;
    uint32_t hi1;

    do {
        __asm__ volatile("rdinstreth %0" : "=r"(hi0));
        __asm__ volatile("rdinstret %0" : "=r"(lo));
        __asm__ volatile("rdinstreth %0" : "=r"(hi1));
    } while (hi0 != hi1);

    return (((uint64_t)hi1) << 32) | (uint64_t)lo;
}

/* Read mhpmcounterN as 64-bit value via M-mode CSR addresses 0xB03..0xB09 (lo) / 0xB83..0xB89 (hi).
 * Glitch-free read: re-sample hi if it changed across the 32-bit lo read.
 * Surrounded with fence to drain the OoO pipeline and avoid CSR-vs-MMIO ordering hazards. */
#define AX7203_HPM_READ64(LO_CSR, HI_CSR, OUT)                          \
    do {                                                                \
        uint32_t _hi0, _lo, _hi1;                                       \
        __asm__ volatile("fence" ::: "memory");                         \
        do {                                                            \
            __asm__ volatile("csrr %0, " #HI_CSR : "=r"(_hi0));         \
            __asm__ volatile("csrr %0, " #LO_CSR : "=r"(_lo));          \
            __asm__ volatile("csrr %0, " #HI_CSR : "=r"(_hi1));         \
        } while (_hi0 != _hi1);                                         \
        __asm__ volatile("fence" ::: "memory");                         \
        (OUT) = (((uint64_t)_hi1) << 32) | (uint64_t)_lo;               \
    } while (0)

uint64_t board_read_hpmcounter64(int idx) {
    uint64_t v = 0ULL;
    switch (idx) {
        case 3: AX7203_HPM_READ64(0xB03, 0xB83, v); break;
        case 4: AX7203_HPM_READ64(0xB04, 0xB84, v); break;
        case 5: AX7203_HPM_READ64(0xB05, 0xB85, v); break;
        case 6: AX7203_HPM_READ64(0xB06, 0xB86, v); break;
        case 7: AX7203_HPM_READ64(0xB07, 0xB87, v); break;
        case 8: AX7203_HPM_READ64(0xB08, 0xB88, v); break;
        case 9: AX7203_HPM_READ64(0xB09, 0xB89, v); break;
        default: v = 0ULL; break;
    }
    return v;
}

int board_vprintf(const char *fmt, va_list ap) {
    va_list aq;
    int count;

    va_copy(aq, ap);
    count = board_vprintfmt(board_putch, 0, fmt, aq);
    va_end(aq);
    return count;
}

int board_printf(const char *fmt, ...) {
    va_list ap;
    int count;

    va_start(ap, fmt);
    count = board_vprintf(fmt, ap);
    va_end(ap);
    return count;
}

int printf(const char *fmt, ...) {
    va_list ap;
    int count;

    va_start(ap, fmt);
    count = board_vprintf(fmt, ap);
    va_end(ap);
    return count;
}

int sprintf(char *str, const char *fmt, ...) {
    va_list ap;
    char *cursor = str;
    int count;

    va_start(ap, fmt);
    count = board_vprintfmt(board_putch, (void **)&cursor, fmt, ap);
    va_end(ap);

    *cursor = '\0';
    return count;
}

int putchar(int ch) {
    board_putch(ch, (void **)0);
    return ch;
}

void setStats(int enable) {
    (void)enable;
}

void exit(int code) {
    if (code != 0) {
        board_tube_write((uint8_t)(0x80u | ((unsigned)code & 0x7Fu)));
        board_printf("BENCH EXIT %d\n", code);
    }
    while (1) {
    }
}

void abort(void) {
    exit(134);
}

void *memcpy(void *dest, const void *src, size_t len) {
    size_t i;
    volatile unsigned char *d = (volatile unsigned char *)dest;
    const volatile unsigned char *s = (const volatile unsigned char *)src;
    for (i = 0; i < len; ++i) {
        unsigned char value = board_relaxed_load_u8(&s[i]);
        board_relaxed_store_u8(&d[i], value);
    }
    return dest;
}

void *memmove(void *dest, const void *src, size_t len) {
    size_t i;
    volatile unsigned char *d = (volatile unsigned char *)dest;
    const volatile unsigned char *s = (const volatile unsigned char *)src;
    if (d == s || len == 0u) {
        return dest;
    }
    if (d < s) {
        for (i = 0; i < len; ++i) {
            unsigned char value = board_relaxed_load_u8(&s[i]);
            board_relaxed_store_u8(&d[i], value);
        }
    } else {
        for (i = len; i > 0u; --i) {
            unsigned char value = board_relaxed_load_u8(&s[i - 1u]);
            board_relaxed_store_u8(&d[i - 1u], value);
        }
    }
    return dest;
}

void *memset(void *dest, int byte, size_t len) {
    size_t i;
    volatile unsigned char *d = (volatile unsigned char *)dest;
    for (i = 0; i < len; ++i) {
        board_relaxed_store_u8(&d[i], (unsigned char)byte);
    }
    return dest;
}

int memcmp(const void *lhs, const void *rhs, size_t len) {
    size_t i;
    const volatile unsigned char *a = (const volatile unsigned char *)lhs;
    const volatile unsigned char *b = (const volatile unsigned char *)rhs;
    for (i = 0; i < len; ++i) {
        unsigned char lhs_byte = board_relaxed_load_u8(&a[i]);
        unsigned char rhs_byte = board_relaxed_load_u8(&b[i]);
        if (lhs_byte != rhs_byte) {
            return (int)lhs_byte - (int)rhs_byte;
        }
    }
    return 0;
}

size_t strlen(const char *s) {
    const volatile unsigned char *p = (const volatile unsigned char *)s;
    while (board_relaxed_load_u8(p) != '\0') {
        ++p;
    }
    return (size_t)(p - (const volatile unsigned char *)s);
}

size_t strnlen(const char *s, size_t n) {
    const volatile unsigned char *p = (const volatile unsigned char *)s;
    while (n-- != 0u && board_relaxed_load_u8(p) != '\0') {
        ++p;
    }
    return (size_t)(p - (const volatile unsigned char *)s);
}

int strcmp(const char *lhs, const char *rhs) {
    unsigned char a;
    unsigned char b;
    const volatile unsigned char *lp = (const volatile unsigned char *)lhs;
    const volatile unsigned char *rp = (const volatile unsigned char *)rhs;

    do {
        a = board_relaxed_load_u8(lp++);
        b = board_relaxed_load_u8(rp++);
        board_mmio_relax();
    } while (a != 0u && a == b);

    return (int)a - (int)b;
}

char *strcpy(char *dest, const char *src) {
    char *out = dest;
    volatile unsigned char *d = (volatile unsigned char *)dest;
    const volatile unsigned char *s = (const volatile unsigned char *)src;
    while (1) {
        unsigned char value = board_relaxed_load_u8(s);
        board_relaxed_store_u8(d, value);
        ++d;
        ++s;
        if (value == '\0') {
            break;
        }
    }
    return dest;
}
