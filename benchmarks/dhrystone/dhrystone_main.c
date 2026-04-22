// Derived from verification/riscv-tests/benchmarks/dhrystone/dhrystone_main.c
#pragma GCC optimize ("no-inline")

#include "dhrystone.h"
#include "util.h"

#include <alloca.h>

#define debug_printf board_printf

Rec_Pointer Ptr_Glob, Next_Ptr_Glob;
int Int_Glob;
Boolean Bool_Glob;
char Ch_1_Glob, Ch_2_Glob;
int Arr_1_Glob[50];
int Arr_2_Glob[50][50];

Enumeration Func_1 ();

#ifndef REG
Boolean Reg = false;
#define REG
#else
Boolean Reg = true;
#undef REG
#define REG register
#endif

Boolean Done;

long Begin_Time, End_Time, User_Time;
long Microseconds, Dhrystones_Per_Second;
unsigned long long Bench_Start_Cycles, Bench_Stop_Cycles;
unsigned long long Bench_Start_Instret, Bench_Stop_Instret;
unsigned long long Bench_Total_Cycles, Bench_Total_Instret;
unsigned long Bench_Ipc_X1000;

/* HPM event counters (mhpmcounter3..9) */
unsigned long long Bench_Start_HPM[7], Bench_Stop_HPM[7];
unsigned long long Bench_Total_HPM[7];

/* Inline HPM reads (avoid jump table / indirect branch pattern that triggers
 * an OoO core hazard when multiple HPM reads appear back-to-back). */
#define DHRY_HPM_READ64(LO, HI, OUT)                                           \
    do {                                                                       \
        uint32_t _h0, _l, _h1;                                                 \
        do {                                                                   \
            __asm__ volatile("csrr %0, " #HI : "=r"(_h0));                     \
            __asm__ volatile("csrr %0, " #LO : "=r"(_l));                      \
            __asm__ volatile("csrr %0, " #HI : "=r"(_h1));                     \
        } while (_h0 != _h1);                                                  \
        (OUT) = (((unsigned long long)_h1) << 32) | (unsigned long long)_l;    \
    } while (0)

static void dhry_sample_hpm(unsigned long long *dst) {
    DHRY_HPM_READ64(0xB03, 0xB83, dst[0]);
    DHRY_HPM_READ64(0xB04, 0xB84, dst[1]);
    DHRY_HPM_READ64(0xB05, 0xB85, dst[2]);
    DHRY_HPM_READ64(0xB06, 0xB86, dst[3]);
    DHRY_HPM_READ64(0xB07, 0xB87, dst[4]);
    DHRY_HPM_READ64(0xB08, 0xB88, dst[5]);
    DHRY_HPM_READ64(0xB09, 0xB89, dst[6]);
}

#if defined(AX7203_FIXED_DHRYSTONE_RUNS)
#define AX7203_DHRYSTONE_EFFECTIVE_FIXED_RUNS AX7203_FIXED_DHRYSTONE_RUNS
#elif defined(VERILATOR_MAINLINE)
#define AX7203_DHRYSTONE_EFFECTIVE_FIXED_RUNS 10
#endif

int main (int argc, char **argv)
{
  One_Fifty Int_1_Loc;
  REG One_Fifty Int_2_Loc;
  One_Fifty Int_3_Loc;
  REG char Ch_Index;
  Enumeration Enum_Loc;
  Str_30 Str_1_Loc;
  Str_30 Str_2_Loc;
  unsigned long long instret_delta;
  REG int Run_Index;
  REG int Number_Of_Runs;

  (void)argc;
  (void)argv;

  if (AX7203_BENCH_STARTUP_DELAY_MS != 0U) {
    board_delay_ms(AX7203_BENCH_STARTUP_DELAY_MS);
  }
  board_uart_putc('0');
  board_uart_putc('\n');

  Number_Of_Runs = NUMBER_OF_RUNS;
#ifdef AX7203_DHRYSTONE_EFFECTIVE_FIXED_RUNS
  Number_Of_Runs = AX7203_DHRYSTONE_EFFECTIVE_FIXED_RUNS;
#endif

  Next_Ptr_Glob = (Rec_Pointer)alloca(sizeof(Rec_Type));
  Ptr_Glob = (Rec_Pointer)alloca(sizeof(Rec_Type));
  board_uart_putc('1');
  board_uart_putc('\n');

  Ptr_Glob->Ptr_Comp = Next_Ptr_Glob;
  Ptr_Glob->Discr = Ident_1;
  Ptr_Glob->variant.var_1.Enum_Comp = Ident_3;
  Ptr_Glob->variant.var_1.Int_Comp = 40;
  strcpy(Ptr_Glob->variant.var_1.Str_Comp, "DHRYSTONE PROGRAM, SOME STRING");
  strcpy(Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING");

  Arr_2_Glob[8][7] = 10;
  board_uart_putc('2');
  board_uart_putc('\n');

  board_uart_putc('D');
  board_uart_putc('H');
  board_uart_putc('\n');
  board_printf("DHRYSTONE START\n");
  debug_printf("\n");
  debug_printf("Dhrystone Benchmark, Version %s\n", Version);
  if (Reg) {
    debug_printf("Program compiled with 'register' attribute\n");
  } else {
    debug_printf("Program compiled without 'register' attribute\n");
  }
  debug_printf("Using %s, HZ=%d\n", CLOCK_TYPE, HZ);
  debug_printf("\n");

  Done = false;
  while (!Done) {
    debug_printf("Trying %d runs through Dhrystone:\n", Number_Of_Runs);

    Bench_Start_Cycles = board_read_mcycle64();
    Bench_Start_Instret = board_read_minstret64();
    dhry_sample_hpm(Bench_Start_HPM);
    setStats(1);
    Start_Timer();

    for (Run_Index = 1; Run_Index <= Number_Of_Runs; ++Run_Index) {
      Proc_5();
      Proc_4();
      Int_1_Loc = 2;
      Int_2_Loc = 3;
      strcpy(Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING");
      Enum_Loc = Ident_2;
      Bool_Glob = !Func_2(Str_1_Loc, Str_2_Loc);
      while (Int_1_Loc < Int_2_Loc) {
        Int_3_Loc = 5 * Int_1_Loc - Int_2_Loc;
        Proc_7(Int_1_Loc, Int_2_Loc, &Int_3_Loc);
        Int_1_Loc += 1;
      }
      Proc_8(Arr_1_Glob, Arr_2_Glob, Int_1_Loc, Int_3_Loc);
      Proc_1(Ptr_Glob);
      for (Ch_Index = 'A'; Ch_Index <= Ch_2_Glob; ++Ch_Index) {
        if (Enum_Loc == Func_1(Ch_Index, 'C')) {
          Proc_6(Ident_1, &Enum_Loc);
          strcpy(Str_2_Loc, "DHRYSTONE PROGRAM, 3'RD STRING");
          Int_2_Loc = Run_Index;
          Int_Glob = Run_Index;
        }
      }
      Int_2_Loc = Int_2_Loc * Int_1_Loc;
      Int_1_Loc = Int_2_Loc / Int_3_Loc;
      Int_2_Loc = 7 * (Int_2_Loc - Int_3_Loc) - Int_1_Loc;
      Proc_2(&Int_1_Loc);
    }

    Stop_Timer();
    setStats(0);
    Bench_Stop_Cycles = board_read_mcycle64();
    Bench_Stop_Instret = board_read_minstret64();
    dhry_sample_hpm(Bench_Stop_HPM);
    {
      int _h;
      for (_h = 0; _h < 7; ++_h) {
        Bench_Total_HPM[_h] = Bench_Stop_HPM[_h] - Bench_Start_HPM[_h];
      }
    }

    User_Time = End_Time - Begin_Time;
    Bench_Total_Cycles = Bench_Stop_Cycles - Bench_Start_Cycles;
    Bench_Total_Instret = Bench_Stop_Instret - Bench_Start_Instret;

    if (User_Time < Too_Small_Time) {
#ifdef AX7203_DHRYSTONE_EFFECTIVE_FIXED_RUNS
      Done = true;
#else
      printf("Measured time too small to obtain meaningful results\n");
      Number_Of_Runs = Number_Of_Runs * 10;
      printf("\n");
#endif
    } else {
      Done = true;
    }
  }

#ifndef AX7203_DHRYSTONE_EFFECTIVE_FIXED_RUNS
  debug_printf("Final values of the variables used in the benchmark:\n");
  debug_printf("\n");
  debug_printf("Int_Glob:            %d\n", Int_Glob);
  debug_printf("        should be:   %d\n", 5);
  debug_printf("Bool_Glob:           %d\n", Bool_Glob);
  debug_printf("        should be:   %d\n", 1);
  debug_printf("Ch_1_Glob:           %c\n", Ch_1_Glob);
  debug_printf("        should be:   %c\n", 'A');
  debug_printf("Ch_2_Glob:           %c\n", Ch_2_Glob);
  debug_printf("        should be:   %c\n", 'B');
  debug_printf("Arr_1_Glob[8]:       %d\n", Arr_1_Glob[8]);
  debug_printf("        should be:   %d\n", 7);
  debug_printf("Arr_2_Glob[8][7]:    %d\n", Arr_2_Glob[8][7]);
  debug_printf("        should be:   Number_Of_Runs + 10\n");
  debug_printf("Ptr_Glob->\n");
  debug_printf("  Ptr_Comp:          %d\n", (long)Ptr_Glob->Ptr_Comp);
  debug_printf("        should be:   (implementation-dependent)\n");
  debug_printf("  Discr:             %d\n", Ptr_Glob->Discr);
  debug_printf("        should be:   %d\n", 0);
  debug_printf("  Enum_Comp:         %d\n", Ptr_Glob->variant.var_1.Enum_Comp);
  debug_printf("        should be:   %d\n", 2);
  debug_printf("  Int_Comp:          %d\n", Ptr_Glob->variant.var_1.Int_Comp);
  debug_printf("        should be:   %d\n", 17);
  debug_printf("  Str_Comp:          %s\n", Ptr_Glob->variant.var_1.Str_Comp);
  debug_printf("        should be:   DHRYSTONE PROGRAM, SOME STRING\n");
  debug_printf("Next_Ptr_Glob->\n");
  debug_printf("  Ptr_Comp:          %d\n", (long)Next_Ptr_Glob->Ptr_Comp);
  debug_printf("        should be:   (implementation-dependent), same as above\n");
  debug_printf("  Discr:             %d\n", Next_Ptr_Glob->Discr);
  debug_printf("        should be:   %d\n", 0);
  debug_printf("  Enum_Comp:         %d\n", Next_Ptr_Glob->variant.var_1.Enum_Comp);
  debug_printf("        should be:   %d\n", 1);
  debug_printf("  Int_Comp:          %d\n", Next_Ptr_Glob->variant.var_1.Int_Comp);
  debug_printf("        should be:   %d\n", 18);
  debug_printf("  Str_Comp:          %s\n", Next_Ptr_Glob->variant.var_1.Str_Comp);
  debug_printf("        should be:   DHRYSTONE PROGRAM, SOME STRING\n");
  debug_printf("Int_1_Loc:           %d\n", Int_1_Loc);
  debug_printf("        should be:   %d\n", 5);
  debug_printf("Int_2_Loc:           %d\n", Int_2_Loc);
  debug_printf("        should be:   %d\n", 13);
  debug_printf("Int_3_Loc:           %d\n", Int_3_Loc);
  debug_printf("        should be:   %d\n", 7);
  debug_printf("Enum_Loc:            %d\n", Enum_Loc);
  debug_printf("        should be:   %d\n", 1);
  debug_printf("Str_1_Loc:           %s\n", Str_1_Loc);
  debug_printf("        should be:   DHRYSTONE PROGRAM, 1'ST STRING\n");
  debug_printf("Str_2_Loc:           %s\n", Str_2_Loc);
  debug_printf("        should be:   DHRYSTONE PROGRAM, 2'ND STRING\n");
  debug_printf("\n");
#endif

  instret_delta = Bench_Total_Instret;
#ifdef AX7203_DHRYSTONE_EFFECTIVE_FIXED_RUNS
  Microseconds = 0;
  Dhrystones_Per_Second = 0;
#else
  Microseconds = ((User_Time / Number_Of_Runs) * Mic_secs_Per_Second) / HZ;
  Dhrystones_Per_Second = (HZ * Number_Of_Runs) / User_Time;
#endif
  if (Bench_Total_Cycles != 0ULL) {
    Bench_Ipc_X1000 = (unsigned long)((instret_delta * 1000ULL) / Bench_Total_Cycles);
  } else {
    Bench_Ipc_X1000 = 0UL;
  }

  printf("BENCH CYCLES: %u\n", (unsigned)Bench_Total_Cycles);
  printf("BENCH INSTRET: %u\n", (unsigned)Bench_Total_Instret);
  printf("BENCH IPC_X1000: %u\n", (unsigned)Bench_Ipc_X1000);
  printf("BENCH BR_MISPREDICT: %u\n", (unsigned)Bench_Total_HPM[0]);
  printf("BENCH ICACHE_MISS: %u\n",   (unsigned)Bench_Total_HPM[1]);
  printf("BENCH DCACHE_MISS: %u\n",   (unsigned)Bench_Total_HPM[2]);
  printf("BENCH L2_MISS: %u\n",       (unsigned)Bench_Total_HPM[3]);
  printf("BENCH SB_STALL: %u\n",      (unsigned)Bench_Total_HPM[4]);
  printf("BENCH ISSUE_BUBBLE: %u\n",  (unsigned)Bench_Total_HPM[5]);
  printf("BENCH ROCC_BUSY: %u\n",     (unsigned)Bench_Total_HPM[6]);
#ifndef AX7203_DHRYSTONE_EFFECTIVE_FIXED_RUNS
  printf("Microseconds for one run through Dhrystone: %ld\n", Microseconds);
  printf("Dhrystones per Second:                      %ld\n", Dhrystones_Per_Second);
#endif
  printf("DHRYSTONE DONE\n");
#ifdef AX7203_DHRYSTONE_EFFECTIVE_FIXED_RUNS
  return 0;
#else
  for (;;) {
    board_delay_ms(250);
    printf("BENCH CYCLES: %u\n", (unsigned)Bench_Total_Cycles);
    printf("BENCH INSTRET: %u\n", (unsigned)Bench_Total_Instret);
    printf("BENCH IPC_X1000: %u\n", (unsigned)Bench_Ipc_X1000);
    printf("Microseconds for one run through Dhrystone: %ld\n", Microseconds);
    printf("Dhrystones per Second:                      %ld\n", Dhrystones_Per_Second);
    printf("DHRYSTONE DONE\n");
  }
#endif
}

Proc_1 (Ptr_Val_Par)
REG Rec_Pointer Ptr_Val_Par;
{
  REG Rec_Pointer Next_Record = Ptr_Val_Par->Ptr_Comp;

  structassign(*Ptr_Val_Par->Ptr_Comp, *Ptr_Glob);
  Ptr_Val_Par->variant.var_1.Int_Comp = 5;
  Next_Record->variant.var_1.Int_Comp = Ptr_Val_Par->variant.var_1.Int_Comp;
  Next_Record->Ptr_Comp = Ptr_Val_Par->Ptr_Comp;
  Proc_3(&Next_Record->Ptr_Comp);
  if (Next_Record->Discr == Ident_1)
  {
    Next_Record->variant.var_1.Int_Comp = 6;
    Proc_6(Ptr_Val_Par->variant.var_1.Enum_Comp, &Next_Record->variant.var_1.Enum_Comp);
    Next_Record->Ptr_Comp = Ptr_Glob->Ptr_Comp;
    Proc_7(Next_Record->variant.var_1.Int_Comp, 10, &Next_Record->variant.var_1.Int_Comp);
  }
  else
    structassign(*Ptr_Val_Par, *Ptr_Val_Par->Ptr_Comp);
}

Proc_2 (Int_Par_Ref)
One_Fifty *Int_Par_Ref;
{
  One_Fifty Int_Loc;
  Enumeration Enum_Loc;

  Int_Loc = *Int_Par_Ref + 10;
  do
    if (Ch_1_Glob == 'A')
    {
      Int_Loc -= 1;
      *Int_Par_Ref = Int_Loc - Int_Glob;
      Enum_Loc = Ident_1;
    }
  while (Enum_Loc != Ident_1);
}

Proc_3 (Ptr_Ref_Par)
Rec_Pointer *Ptr_Ref_Par;
{
  if (Ptr_Glob != Null)
    *Ptr_Ref_Par = Ptr_Glob->Ptr_Comp;
  Proc_7(10, Int_Glob, &Ptr_Glob->variant.var_1.Int_Comp);
}

Proc_4 ()
{
  Boolean Bool_Loc;

  Bool_Loc = Ch_1_Glob == 'A';
  Bool_Glob = Bool_Loc | Bool_Glob;
  Ch_2_Glob = 'B';
}

Proc_5 ()
{
  Ch_1_Glob = 'A';
  Bool_Glob = false;
}
