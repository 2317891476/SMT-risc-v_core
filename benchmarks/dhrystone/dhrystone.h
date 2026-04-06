// AX7203 wrapper around the upstream riscv-tests Dhrystone header.
#ifndef AX7203_DHRYSTONE_WRAPPER_H
#define AX7203_DHRYSTONE_WRAPPER_H

#include "../common_ax7203/ax7203_board_runtime.h"
#include "../../verification/riscv-tests/benchmarks/dhrystone/dhrystone.h"

#ifdef AX7203_DHRYSTONE_RUNS
#undef NUMBER_OF_RUNS
#define NUMBER_OF_RUNS AX7203_DHRYSTONE_RUNS
#endif

#undef HZ
#undef Too_Small_Time
#undef CLOCK_TYPE
#undef Start_Timer
#undef Stop_Timer

#define HZ AX7203_CPU_HZ
#define Too_Small_Time ((AX7203_CPU_HZ) / 20)
#define CLOCK_TYPE "rdcycle()"
#define Start_Timer() Begin_Time = (long)board_read_mcycle64()
#define Stop_Timer() End_Time = (long)board_read_mcycle64()

#endif
