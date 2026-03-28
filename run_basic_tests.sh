#!/bin/bash

ROM_DIR="C:\Users\23178\.local\share\opencode\worktree\2d6c11695b7338d0bd9bb170c1dead1cc1689785\quick-panda\rom"
COMP_DIR="C:\Users\23178\.local\share\opencode\worktree\2d6c11695b7338d0bd9bb170c1dead1cc1689785\quick-panda\comp_test"

cd "$ROM_DIR"

echo "========================================"
echo "  Running all Basic Tests (V2)"
echo "========================================"

test1() {
    echo -n "test1... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i -mabi=ilp32 test1.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test2() {
    echo -n "test2... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i -mabi=ilp32 test2.S -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_rv32i_full() {
    echo -n "test_rv32i_full... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i -mabi=ilp32 test_rv32i_full.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_smt() {
    echo -n "test_smt... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i -mabi=ilp32 test_smt.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_l2_icache_refill() {
    echo -n "test_l2_icache_refill... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i -mabi=ilp32 test_l2_icache_refill.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_l2_i_d_arbiter() {
    echo -n "test_l2_i_d_arbiter... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i -mabi=ilp32 test_l2_i_d_arbiter.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_l2_mmio_bypass() {
    echo -n "test_l2_mmio_bypass... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i -mabi=ilp32 test_l2_mmio_bypass.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_csr_mret_smoke() {
    echo -n "test_csr_mret_smoke... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i_zicsr -mabi=ilp32 test_csr_mret_smoke.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_clint_timer_interrupt() {
    echo -n "test_clint_timer_interrupt... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i_zicsr -mabi=ilp32 test_clint_timer_interrupt.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_plic_external_interrupt() {
    echo -n "test_plic_external_interrupt... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i_zicsr -mabi=ilp32 test_plic_external_interrupt.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_interrupt_mask_mret() {
    echo -n "test_interrupt_mask_mret... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i_zicsr -mabi=ilp32 test_interrupt_mask_mret.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_rocc_dma() {
    echo -n "test_rocc_dma... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i -mabi=ilp32 test_rocc_dma.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_rocc_status() {
    echo -n "test_rocc_status... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i -mabi=ilp32 test_rocc_status.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test_rocc_gemm() {
    echo -n "test_rocc_gemm... "
    riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march=rv32i -mabi=ilp32 test_rocc_gemm.s -o test.elf 2>/dev/null
    riscv-none-elf-objcopy -j .text -O verilog test.elf inst.hex 2>/dev/null
    riscv-none-elf-objcopy -j .data -O verilog test.elf data.hex 2>/dev/null
    cd "$COMP_DIR" && timeout 30 vvp out_iverilog/bin/tb_v2_test.out 2>&1 | grep -q "PASS" && echo "✅ PASS" || echo "⏱️ TIMEOUT"
    cd "$ROM_DIR"
}

test1
test2
test_rv32i_full
test_smt
test_l2_icache_refill
test_l2_i_d_arbiter
test_l2_mmio_bypass
test_csr_mret_smoke
test_clint_timer_interrupt
test_plic_exte
