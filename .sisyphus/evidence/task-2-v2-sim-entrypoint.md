# Task 2 V2 simulation entrypoint dry-run

- Generated: 2026-03-28 01:05:50 +08:00
- Flow: V2
- Module list: E:\SMT-risc-v_core\comp_test\module_list_v2
- Testbench: E:\SMT-risc-v_core\comp_test\tb_v2.sv
- Top module: tb_v2
- Dry-run only: True
- NoGtkWave requested: True
- Tests: test1.s, test2.S, test_smt.s

## Include directories
- E:\SMT-risc-v_core\comp_test
- E:\SMT-risc-v_core\rtl\

## Resolved source manifest
1. E:\SMT-risc-v_core\rtl\adam_riscv_v2.v
2. E:\SMT-risc-v_core\rtl\stage_if_v2.v
3. E:\SMT-risc-v_core\rtl\bpu_bimodal.v
4. E:\SMT-risc-v_core\rtl\fetch_buffer.v
5. E:\SMT-risc-v_core\rtl\decoder_dual.v
6. E:\SMT-risc-v_core\rtl\inst_memory.v
7. E:\SMT-risc-v_core\rtl\icache.v
8. E:\SMT-risc-v_core\rtl\icache_mem_adapter.v
9. E:\SMT-risc-v_core\rtl\inst_backing_store.v
10. E:\SMT-risc-v_core\rtl\scoreboard_v2.v
11. E:\SMT-risc-v_core\rtl\rob_lite.v
12. E:\SMT-risc-v_core\rtl\bypass_network.v
13. E:\SMT-risc-v_core\rtl\exec_pipe0.v
14. E:\SMT-risc-v_core\rtl\exec_pipe1.v
15. E:\SMT-risc-v_core\rtl\mul_unit.v
16. E:\SMT-risc-v_core\rtl\lsu_shell.v
17. E:\SMT-risc-v_core\rtl\store_buffer.v
18. E:\SMT-risc-v_core\rtl\data_memory.v
19. E:\SMT-risc-v_core\rtl\csr_unit.v
20. E:\SMT-risc-v_core\rtl\syn_rst.v
21. E:\SMT-risc-v_core\rtl\thread_scheduler.v
22. E:\SMT-risc-v_core\rtl\pc_mt.v
23. E:\SMT-risc-v_core\rtl\regs_mt.v
24. E:\SMT-risc-v_core\rtl\stage_is.v
25. E:\SMT-risc-v_core\rtl\ctrl.v
26. E:\SMT-risc-v_core\rtl\imm_gen.v
27. E:\SMT-risc-v_core\rtl\alu.v
28. E:\SMT-risc-v_core\rtl\alu_control.v
29. E:\SMT-risc-v_core\rtl\stage_mem.v
30. E:\SMT-risc-v_core\rtl\stage_wb.v
31. E:\SMT-risc-v_core\libs\REG_ARRAY\SRAM\ram_bfm.v

## test1.s
- ROM source: E:\SMT-risc-v_core\rom\test1.s
- Simulation binary: E:\SMT-risc-v_core\comp_test\out_iverilog\bin\tb_test1.out
- Log path: E:\SMT-risc-v_core\comp_test\out_iverilog\logs\test1.log
- Wave path: E:\SMT-risc-v_core\comp_test\out_iverilog\waves\test1.vcd
- GCC: riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,E:\SMT-risc-v_core\rom\harvard_link.ld -Wl,-Map,E:\SMT-risc-v_core\rom\main_s.map -march=rv32i -mabi=ilp32 E:\SMT-risc-v_core\rom\test1.s -o E:\SMT-risc-v_core\rom\main_s.elf
- Objcopy (ELF): riscv-none-elf-objcopy E:\SMT-risc-v_core\rom\main_s.elf -O elf32-littleriscv E:\SMT-risc-v_core\rom\main_s.o
- Objdump: riscv-none-elf-objdump -S -l E:\SMT-risc-v_core\rom\main_s.elf -M no-aliases,numeric
- Objcopy (inst.hex): riscv-none-elf-objcopy -j .text -O verilog E:\SMT-risc-v_core\rom\main_s.elf E:\SMT-risc-v_core\rom\inst.hex
- Objcopy (data.hex): riscv-none-elf-objcopy -j .data -j .sdata -O verilog E:\SMT-risc-v_core\rom\main_s.elf E:\SMT-risc-v_core\rom\data.hex
- Iverilog: iverilog -g2012 -s tb_v2 -o E:\SMT-risc-v_core\comp_test\out_iverilog\bin\tb_test1.out -I E:\SMT-risc-v_core\comp_test -I E:\SMT-risc-v_core\rtl\ E:\SMT-risc-v_core\rtl\adam_riscv_v2.v E:\SMT-risc-v_core\rtl\stage_if_v2.v E:\SMT-risc-v_core\rtl\bpu_bimodal.v E:\SMT-risc-v_core\rtl\fetch_buffer.v E:\SMT-risc-v_core\rtl\decoder_dual.v E:\SMT-risc-v_core\rtl\inst_memory.v E:\SMT-risc-v_core\rtl\icache.v E:\SMT-risc-v_core\rtl\icache_mem_adapter.v E:\SMT-risc-v_core\rtl\inst_backing_store.v E:\SMT-risc-v_core\rtl\scoreboard_v2.v E:\SMT-risc-v_core\rtl\rob_lite.v E:\SMT-risc-v_core\rtl\bypass_network.v E:\SMT-risc-v_core\rtl\exec_pipe0.v E:\SMT-risc-v_core\rtl\exec_pipe1.v E:\SMT-risc-v_core\rtl\mul_unit.v E:\SMT-risc-v_core\rtl\lsu_shell.v E:\SMT-risc-v_core\rtl\store_buffer.v E:\SMT-risc-v_core\rtl\data_memory.v E:\SMT-risc-v_core\rtl\csr_unit.v E:\SMT-risc-v_core\rtl\syn_rst.v E:\SMT-risc-v_core\rtl\thread_scheduler.v E:\SMT-risc-v_core\rtl\pc_mt.v E:\SMT-risc-v_core\rtl\regs_mt.v E:\SMT-risc-v_core\rtl\stage_is.v E:\SMT-risc-v_core\rtl\ctrl.v E:\SMT-risc-v_core\rtl\imm_gen.v E:\SMT-risc-v_core\rtl\alu.v E:\SMT-risc-v_core\rtl\alu_control.v E:\SMT-risc-v_core\rtl\stage_mem.v E:\SMT-risc-v_core\rtl\stage_wb.v E:\SMT-risc-v_core\libs\REG_ARRAY\SRAM\ram_bfm.v E:\SMT-risc-v_core\comp_test\tb_v2.sv
- VVP: vvp E:\SMT-risc-v_core\comp_test\out_iverilog\bin\tb_test1.out

## test2.S
- ROM source: E:\SMT-risc-v_core\rom\test2.S
- Simulation binary: E:\SMT-risc-v_core\comp_test\out_iverilog\bin\tb_test2.out
- Log path: E:\SMT-risc-v_core\comp_test\out_iverilog\logs\test2.log
- Wave path: E:\SMT-risc-v_core\comp_test\out_iverilog\waves\test2.vcd
- GCC: riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,E:\SMT-risc-v_core\rom\harvard_link.ld -Wl,-Map,E:\SMT-risc-v_core\rom\main_s.map -march=rv32i -mabi=ilp32 E:\SMT-risc-v_core\rom\test2.S -o E:\SMT-risc-v_core\rom\main_s.elf
- Objcopy (ELF): riscv-none-elf-objcopy E:\SMT-risc-v_core\rom\main_s.elf -O elf32-littleriscv E:\SMT-risc-v_core\rom\main_s.o
- Objdump: riscv-none-elf-objdump -S -l E:\SMT-risc-v_core\rom\main_s.elf -M no-aliases,numeric
- Objcopy (inst.hex): riscv-none-elf-objcopy -j .text -O verilog E:\SMT-risc-v_core\rom\main_s.elf E:\SMT-risc-v_core\rom\inst.hex
- Objcopy (data.hex): riscv-none-elf-objcopy -j .data -j .sdata -O verilog E:\SMT-risc-v_core\rom\main_s.elf E:\SMT-risc-v_core\rom\data.hex
- Iverilog: iverilog -g2012 -s tb_v2 -o E:\SMT-risc-v_core\comp_test\out_iverilog\bin\tb_test2.out -I E:\SMT-risc-v_core\comp_test -I E:\SMT-risc-v_core\rtl\ E:\SMT-risc-v_core\rtl\adam_riscv_v2.v E:\SMT-risc-v_core\rtl\stage_if_v2.v E:\SMT-risc-v_core\rtl\bpu_bimodal.v E:\SMT-risc-v_core\rtl\fetch_buffer.v E:\SMT-risc-v_core\rtl\decoder_dual.v E:\SMT-risc-v_core\rtl\inst_memory.v E:\SMT-risc-v_core\rtl\icache.v E:\SMT-risc-v_core\rtl\icache_mem_adapter.v E:\SMT-risc-v_core\rtl\inst_backing_store.v E:\SMT-risc-v_core\rtl\scoreboard_v2.v E:\SMT-risc-v_core\rtl\rob_lite.v E:\SMT-risc-v_core\rtl\bypass_network.v E:\SMT-risc-v_core\rtl\exec_pipe0.v E:\SMT-risc-v_core\rtl\exec_pipe1.v E:\SMT-risc-v_core\rtl\mul_unit.v E:\SMT-risc-v_core\rtl\lsu_shell.v E:\SMT-risc-v_core\rtl\store_buffer.v E:\SMT-risc-v_core\rtl\data_memory.v E:\SMT-risc-v_core\rtl\csr_unit.v E:\SMT-risc-v_core\rtl\syn_rst.v E:\SMT-risc-v_core\rtl\thread_scheduler.v E:\SMT-risc-v_core\rtl\pc_mt.v E:\SMT-risc-v_core\rtl\regs_mt.v E:\SMT-risc-v_core\rtl\stage_is.v E:\SMT-risc-v_core\rtl\ctrl.v E:\SMT-risc-v_core\rtl\imm_gen.v E:\SMT-risc-v_core\rtl\alu.v E:\SMT-risc-v_core\rtl\alu_control.v E:\SMT-risc-v_core\rtl\stage_mem.v E:\SMT-risc-v_core\rtl\stage_wb.v E:\SMT-risc-v_core\libs\REG_ARRAY\SRAM\ram_bfm.v E:\SMT-risc-v_core\comp_test\tb_v2.sv
- VVP: vvp E:\SMT-risc-v_core\comp_test\out_iverilog\bin\tb_test2.out

## test_smt.s
- ROM source: E:\SMT-risc-v_core\rom\test_smt.s
- Simulation binary: E:\SMT-risc-v_core\comp_test\out_iverilog\bin\tb_test_smt.out
- Log path: E:\SMT-risc-v_core\comp_test\out_iverilog\logs\test_smt.log
- Wave path: E:\SMT-risc-v_core\comp_test\out_iverilog\waves\test_smt.vcd
- GCC: riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,E:\SMT-risc-v_core\rom\harvard_link.ld -Wl,-Map,E:\SMT-risc-v_core\rom\main_s.map -march=rv32i -mabi=ilp32 E:\SMT-risc-v_core\rom\test_smt.s -o E:\SMT-risc-v_core\rom\main_s.elf
- Objcopy (ELF): riscv-none-elf-objcopy E:\SMT-risc-v_core\rom\main_s.elf -O elf32-littleriscv E:\SMT-risc-v_core\rom\main_s.o
- Objdump: riscv-none-elf-objdump -S -l E:\SMT-risc-v_core\rom\main_s.elf -M no-aliases,numeric
- Objcopy (inst.hex): riscv-none-elf-objcopy -j .text -O verilog E:\SMT-risc-v_core\rom\main_s.elf E:\SMT-risc-v_core\rom\inst.hex
- Objcopy (data.hex): riscv-none-elf-objcopy -j .data -j .sdata -O verilog E:\SMT-risc-v_core\rom\main_s.elf E:\SMT-risc-v_core\rom\data.hex
- Iverilog: iverilog -g2012 -s tb_v2 -o E:\SMT-risc-v_core\comp_test\out_iverilog\bin\tb_test_smt.out -I E:\SMT-risc-v_core\comp_test -I E:\SMT-risc-v_core\rtl\ E:\SMT-risc-v_core\rtl\adam_riscv_v2.v E:\SMT-risc-v_core\rtl\stage_if_v2.v E:\SMT-risc-v_core\rtl\bpu_bimodal.v E:\SMT-risc-v_core\rtl\fetch_buffer.v E:\SMT-risc-v_core\rtl\decoder_dual.v E:\SMT-risc-v_core\rtl\inst_memory.v E:\SMT-risc-v_core\rtl\icache.v E:\SMT-risc-v_core\rtl\icache_mem_adapter.v E:\SMT-risc-v_core\rtl\inst_backing_store.v E:\SMT-risc-v_core\rtl\scoreboard_v2.v E:\SMT-risc-v_core\rtl\rob_lite.v E:\SMT-risc-v_core\rtl\bypass_network.v E:\SMT-risc-v_core\rtl\exec_pipe0.v E:\SMT-risc-v_core\rtl\exec_pipe1.v E:\SMT-risc-v_core\rtl\mul_unit.v E:\SMT-risc-v_core\rtl\lsu_shell.v E:\SMT-risc-v_core\rtl\store_buffer.v E:\SMT-risc-v_core\rtl\data_memory.v E:\SMT-risc-v_core\rtl\csr_unit.v E:\SMT-risc-v_core\rtl\syn_rst.v E:\SMT-risc-v_core\rtl\thread_scheduler.v E:\SMT-risc-v_core\rtl\pc_mt.v E:\SMT-risc-v_core\rtl\regs_mt.v E:\SMT-risc-v_core\rtl\stage_is.v E:\SMT-risc-v_core\rtl\ctrl.v E:\SMT-risc-v_core\rtl\imm_gen.v E:\SMT-risc-v_core\rtl\alu.v E:\SMT-risc-v_core\rtl\alu_control.v E:\SMT-risc-v_core\rtl\stage_mem.v E:\SMT-risc-v_core\rtl\stage_wb.v E:\SMT-risc-v_core\libs\REG_ARRAY\SRAM\ram_bfm.v E:\SMT-risc-v_core\comp_test\tb_v2.sv
- VVP: vvp E:\SMT-risc-v_core\comp_test\out_iverilog\bin\tb_test_smt.out
