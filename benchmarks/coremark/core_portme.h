#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef AX7203_CPU_HZ
#define AX7203_CPU_HZ 50000000UL
#endif

#ifndef AX7203_UART_BAUD
#define AX7203_UART_BAUD 115200UL
#endif

#ifndef AX7203_UART_BASE
#define AX7203_UART_BASE 0x10000000UL
#endif

#ifndef AX7203_UART_TXDATA_OFFSET
#define AX7203_UART_TXDATA_OFFSET 0x0UL
#endif

#ifndef AX7203_UART_FULL_BIT
#define AX7203_UART_FULL_BIT 31U
#endif

#ifndef HAS_FLOAT
#define HAS_FLOAT 0
#endif

#ifndef HAS_TIME_H
#define HAS_TIME_H 0
#endif

#ifndef USE_CLOCK
#define USE_CLOCK 0
#endif

#ifndef HAS_STDIO
#define HAS_STDIO 1
#endif

#ifndef HAS_PRINTF
#define HAS_PRINTF 1
#endif

#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif

#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

#ifndef MAIN_HAS_NO_MAIN
#define MAIN_HAS_NO_MAIN 0
#endif

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif

#ifndef MEM_METHOD
#define MEM_METHOD MEM_STATIC
#endif

#ifndef MULTITHREAD
#define MULTITHREAD 1
#endif

#ifndef COMPILER_VERSION
#define COMPILER_VERSION "riscv-none-elf-gcc"
#endif

#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS "-O2 -march=rv32im -mabi=ilp32"
#endif

#ifndef MEM_LOCATION
#define MEM_LOCATION "STATIC"
#endif

typedef uint64_t CORETIMETYPE;
typedef uint64_t CORE_TICKS;
typedef double secs_ret;

#define EE_TICKS_PER_SEC ((ee_u32)AX7203_CPU_HZ)

struct CORE_PORTABLE_S;

void portable_init(struct CORE_PORTABLE_S *p, int *argc, char *argv[]);
void portable_fini(struct CORE_PORTABLE_S *p);

void start_time(void);
void stop_time(void);
CORE_TICKS get_time(void);
secs_ret time_in_secs(CORE_TICKS ticks);

void *portable_malloc(size_t size);
void portable_free(void *p);

int ee_printf(const char *fmt, ...);

#ifdef __cplusplus
}
#endif

#endif
