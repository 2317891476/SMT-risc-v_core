#include "core_portme.h"

#include <stdarg.h>
#include <stdint.h>

#if defined(__has_include)
#if __has_include("coremark.h")
#include "coremark.h"
#define COREMARK_PORT_HAS_HEADER 1
#else
#define COREMARK_PORT_HAS_HEADER 0
#endif
#else
#include "coremark.h"
#define COREMARK_PORT_HAS_HEADER 1
#endif

#if !COREMARK_PORT_HAS_HEADER
typedef int32_t ee_s32;
typedef uint32_t ee_u32;
struct CORE_PORTABLE_S {
    ee_u32 portable_id;
};
#ifndef ITERATIONS
#define ITERATIONS 0
#endif
#endif

volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

static CORETIMETYPE g_start_cycles;
static CORETIMETYPE g_stop_cycles;

static inline CORETIMETYPE read_mcycle64(void) {
    uint32_t hi0;
    uint32_t lo;
    uint32_t hi1;
    do {
        __asm__ volatile("rdcycleh %0" : "=r"(hi0));
        __asm__ volatile("rdcycle %0" : "=r"(lo));
        __asm__ volatile("rdcycleh %0" : "=r"(hi1));
    } while (hi0 != hi1);
    return (((CORETIMETYPE)hi1) << 32) | (CORETIMETYPE)lo;
}

static inline volatile uint32_t *uart_txdata_reg(void) {
    return (volatile uint32_t *)(uintptr_t)(AX7203_UART_BASE + AX7203_UART_TXDATA_OFFSET);
}

static void uart_putc(char ch) {
    volatile uint32_t *txdata = uart_txdata_reg();
    while (((*txdata >> AX7203_UART_FULL_BIT) & 0x1U) != 0U) {
    }
    *txdata = (uint32_t)(uint8_t)ch;
}

/* Implementations for bare-metal environment */

void *memset(void *s, int c, size_t n) {
    unsigned char *p = (unsigned char *)s;
    while (n--) {
        *p++ = (unsigned char)c;
    }
    return s;
}

int puts(const char *s) {
    while (*s) {
        if (*s == '\n') {
            uart_putc('\r');
        }
        uart_putc(*s++);
    }
    uart_putc('\r');
    uart_putc('\n');
    return 0;
}

static char *utoa(unsigned int val, char *buf, int base, int width, char pad) {
    char tmp[32];
    int i = 0;
    int j;

    if (val == 0) {
        tmp[i++] = '0';
    } else {
        while (val > 0) {
            int digit = val % base;
            tmp[i++] = (digit < 10) ? ('0' + digit) : ('a' + digit - 10);
            val /= base;
        }
    }

    /* Padding */
    while (i < width) {
        tmp[i++] = pad;
    }

    /* Reverse */
    for (j = 0; j < i; j++) {
        buf[j] = tmp[i - 1 - j];
    }
    buf[i] = '\0';
    return buf;
}

int vsnprintf(char *str, size_t size, const char *fmt, va_list ap) {
    char *p = str;
    char *end = str + size - 1;
    char buf[32];

    while (*fmt && p < end) {
        if (*fmt != '%') {
            *p++ = *fmt++;
            continue;
        }
        fmt++;

        /* Simple format parsing */
        int width = 0;
        char pad = ' ';

        if (*fmt == '0') {
            pad = '0';
            fmt++;
        }

        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }

        switch (*fmt) {
            case 'd':
            case 'i': {
                int val = va_arg(ap, int);
                if (val < 0) {
                    *p++ = '-';
                    if (p >= end) break;
                    val = -val;
                }
                utoa((unsigned int)val, buf, 10, width, pad);
                char *s = buf;
                while (*s && p < end) *p++ = *s++;
                break;
            }
            case 'u': {
                unsigned int val = va_arg(ap, unsigned int);
                utoa(val, buf, 10, width, pad);
                char *s = buf;
                while (*s && p < end) *p++ = *s++;
                break;
            }
            case 'x':
            case 'X': {
                unsigned int val = va_arg(ap, unsigned int);
                utoa(val, buf, 16, width, pad);
                char *s = buf;
                while (*s && p < end) *p++ = *s++;
                break;
            }
            case 's': {
                const char *s = va_arg(ap, const char *);
                if (!s) s = "(null)";
                while (*s && p < end) *p++ = *s++;
                break;
            }
            case 'c': {
                char c = (char)va_arg(ap, int);
                *p++ = c;
                break;
            }
            case '%':
                *p++ = '%';
                break;
            case 'l': {
                fmt++;
                if (*fmt == 'd' || *fmt == 'i') {
                    long val = va_arg(ap, long);
                    if (val < 0) {
                        *p++ = '-';
                        if (p >= end) break;
                        val = -val;
                    }
                    utoa((unsigned long)val, buf, 10, width, pad);
                    char *s = buf;
                    while (*s && p < end) *p++ = *s++;
                } else if (*fmt == 'u') {
                    unsigned long val = va_arg(ap, unsigned long);
                    utoa((unsigned int)val, buf, 10, width, pad);
                    char *s = buf;
                    while (*s && p < end) *p++ = *s++;
                }
                break;
            }
            default:
                *p++ = '%';
                if (p < end) *p++ = *fmt;
                break;
        }
        fmt++;
    }
    *p = '\0';
    return (int)(p - str);
}

int ee_printf(const char *fmt, ...) {
    char buf[256];
    va_list ap;
    int len;
    int i;

    va_start(ap, fmt);
    len = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    if (len < 0) {
        return len;
    }

    if (len > (int)(sizeof(buf) - 1U)) {
        len = (int)(sizeof(buf) - 1U);
    }

    for (i = 0; i < len; ++i) {
        if (buf[i] == '\n') {
            uart_putc('\r');
        }
        uart_putc(buf[i]);
    }

    return len;
}

void *portable_malloc(ee_size_t size) {
    (void)size;
    return NULL;
}

void portable_free(void *p) {
    (void)p;
}

void *align_mem(void *memblk) {
    /* Align to 8-byte boundary */
    uintptr_t addr = (uintptr_t)memblk;
    addr = (addr + 7U) & ~(uintptr_t)7U;
    return (void *)addr;
}

void start_time(void) {
    g_start_cycles = read_mcycle64();
}

void stop_time(void) {
    g_stop_cycles = read_mcycle64();
}

CORE_TICKS get_time(void) {
    return (CORE_TICKS)(g_stop_cycles - g_start_cycles);
}

secs_ret time_in_secs(CORE_TICKS ticks) {
    return (secs_ret)ticks / (secs_ret)AX7203_CPU_HZ;
}

void portable_init(core_portable *p, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

void portable_fini(core_portable *p) {
    p->portable_id = 0;
}
