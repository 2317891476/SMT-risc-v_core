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

/* CoreMark base types */
typedef uint8_t  ee_u8;
typedef uint16_t ee_u16;
typedef uint32_t ee_u32;
typedef uint64_t ee_u64;
typedef int8_t   ee_s8;
typedef int16_t  ee_s16;
typedef int32_t  ee_s32;
typedef int64_t  ee_s64;
typedef size_t   ee_size_t;
typedef intptr_t ee_ptr_int;

typedef uint64_t CORETIMETYPE;
typedef uint64_t CORE_TICKS;

#define EE_TICKS_PER_SEC ((ee_u32)AX7203_CPU_HZ)

/* Portable context structure for multithreading */
typedef struct CORE_PORTABLE_S {
    ee_u32 portable_id;
} core_portable;

/* Default number of contexts (for multithread support) */
#define default_num_contexts MULTITHREAD

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

/* Memory alignment helper */
void *align_mem(void *memblk);

void start_time(void);
void stop_time(void);
CORE_TICKS get_time(void);

void *portable_malloc(ee_size_t size);
void portable_free(void *p);

#if HAS_PRINTF
#include <stdio.h>
#endif

#ifdef __cplusplus
}
#endif

#endif
