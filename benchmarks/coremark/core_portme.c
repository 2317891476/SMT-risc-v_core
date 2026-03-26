#include "core_portme.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

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

ee_u32 default_num_contexts = 1;

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

void *portable_malloc(size_t size) {
    (void)size;
    return NULL;
}

void portable_free(void *p) {
    (void)p;
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

void portable_init(struct CORE_PORTABLE_S *p, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

void portable_fini(struct CORE_PORTABLE_S *p) {
    p->portable_id = 0;
}
