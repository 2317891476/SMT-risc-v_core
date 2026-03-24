#!/usr/bin/env python3
"""
Run riscv-tests and riscv-arch-test on AdamRiscv V2.
Adapts tests to our memory map and testbench format.
Auto-downloads test suites if not present.
"""

import os
import sys
import subprocess
import glob
import urllib.request
import zipfile
import argparse
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
VERIFICATION_DIR = PROJECT_ROOT / "verification"
RISCV_TESTS_DIR = VERIFICATION_DIR / "riscv-tests"
ARCH_TEST_DIR = VERIFICATION_DIR / "riscv-arch-test"
OUTPUT_DIR = VERIFICATION_DIR / "riscv_test_runs"
COMP_TEST_DIR = PROJECT_ROOT / "comp_test"
ROM_DIR = PROJECT_ROOT / "rom"

# RISC-V toolchain
GCC = "riscv-none-elf-gcc"
OBJCOPY = "riscv-none-elf-objcopy"

# Our memory map
TEXT_BASE = "0x00000000"
DATA_BASE = "0x00001000"
TUBE_ADDR = "0x13000000"

# Test suites configuration
TEST_SUITES = {
    "riscv-tests": {
        "url": "https://github.com/riscv-software-src/riscv-tests/archive/refs/heads/master.zip",
        "dir": RISCV_TESTS_DIR,
        "categories": ["rv32ui", "rv32um"],
        "description": "Classic RISC-V tests (RV32I/M)",
    },
    "riscv-arch-test": {
        "url": "https://github.com/riscv/riscv-arch-test/archive/refs/heads/main.zip",
        "dir": ARCH_TEST_DIR,
        "categories": ["rv32i", "rv32im"],
        "description": "Official RISC-V architecture tests (500+)",
    },
}


def create_adapter_linker():
    """Create linker script adapted for our memory map"""
    return f'''
OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{{
  . = {TEXT_BASE};
  .text.init : {{ *(.text.init) }}
  .text : {{ *(.text) }}
  
  . = {DATA_BASE};
  .tohost : {{ *(.tohost) }}
  .data : {{ *(.data) }}
  .bss : {{ *(.bss) }}
  _end = .;
}}
'''


def create_adapter_linker_v1():
    """Create linker script for riscv-tests (uses _start)"""
    return f'''
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{{
  . = {TEXT_BASE};
  .text.init : {{ *(.text.init) }}
  .text : {{ *(.text) }}
  
  . = {DATA_BASE};
  .tohost : {{ *(.tohost) }}
  .data : {{ *(.data) }}
  .bss : {{ *(.bss) }}
  _end = .;
}}
'''


def create_model_test_header():
    """Create model_test.h for riscv-arch-test compatibility"""
    return '''
#ifndef _MODEL_TEST_H
#define _MODEL_TEST_H

// TUBE address for test completion
#define TUBE_ADDR 0x13000000

// Boot code - minimal setup for arch-test
// Note: rvtest_entry_point is defined by the test, we just set up SP
#define RVMODEL_BOOT                                                     \
        li sp, 0x10000;

// Halt code - write PASS to TUBE
#define RVMODEL_HALT                                                     \
        li t0, 0x04;                                                     \
        li t1, TUBE_ADDR;                                                \
        sb t0, 0(t1);                                                    \
1:      j 1b

// Data sections (empty for our simple setup)
#define RVMODEL_DATA_BEGIN                                               \
        .section .tohost;                                                \
        .align 4;

#define RVMODEL_DATA_END

// Fence.i default
#define RVMODEL_FENCEI fence.i

// MTVEC alignment
#define RVMODEL_MTVEC_ALIGN 4

// Block sizes
#define RVMODEL_CBZ_BLOCKSIZE 64
#define RVMODEL_CMO_BLOCKSIZE 64

// Interrupt stubs (not implemented for basic tests)
#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLR_MSW_INT
#define RVMODEL_CLR_MTIMER_INT
#define RVMODEL_CLR_MEXT_INT
#define RVMODEL_SET_SSW_INT
#define RVMODEL_CLR_SSW_INT
#define RVMODEL_CLR_STIMER_INT
#define RVMODEL_CLR_SEXT_INT
#define RVMODEL_SET_VSW_INT
#define RVMODEL_CLR_VSW_INT
#define RVMODEL_CLR_VTIMER_INT
#define RVMODEL_CLR_VEXT_INT

#endif
'''


def create_adapter_header():
    """Create header that adapts test reporting to our TUBE"""
    return '''
#ifndef _ADAM_RISCV_TEST_H
#define _ADAM_RISCV_TEST_H

// TUBE address for test completion
#define TUBE_ADDR 0x13000000

// Simplified pass/fail using memory-mapped I/O
#define RVTEST_PASS                                                     \
        li t0, 0x04;                                                    \
        li t1, TUBE_ADDR;                                               \
        sb t0, 0(t1);                                                   \
1:      j 1b

#define RVTEST_FAIL                                                     \
        li t0, 0xFF;                                                    \
        li t1, TUBE_ADDR;                                               \
        sb t0, 0(t1);                                                   \
1:      j 1b

// Bypass CSR initialization
#define INIT_RNMI
#define INIT_SATP
#define INIT_PMP
#define DELEGATE_NO_TRAPS
#define RISCV_MULTICORE_DISABLE

// Empty init macro
#define RVTEST_RV32U                                                    \
  .macro init;                                                          \
  .endm

#define TESTNUM gp
#define CHECK_XLEN

// Code begin/end
#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .globl _start;                                                  \
_start:                                                                 \
        j reset_vector;                                                 \
        .align 2;                                                       \
reset_vector:                                                           \
        li TESTNUM, 0;

#define RVTEST_CODE_END                                                 \
        unimp

// Data sections
#define RVTEST_DATA_BEGIN                                               \
        .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif
'''


def compile_test(test_path, output_dir, adapter_dir, suite_name="riscv-tests"):
    """Compile a single test with our adapter"""
    test_name = Path(test_path).stem
    test_out_dir = output_dir / test_name
    test_out_dir.mkdir(parents=True, exist_ok=True)
    
    elf_path = test_out_dir / f"{test_name}.elf"
    inst_hex = test_out_dir / "inst.hex"
    
    # Get suite directory for include paths
    if suite_name == "riscv-tests":
        suite_dir = RISCV_TESTS_DIR
        # Include original riscv-tests headers
        cmd = [
            GCC, "-march=rv32im", "-mabi=ilp32", "-static",
            "-mcmodel=medany", "-fvisibility=hidden",
            "-nostdlib", "-nostartfiles", "-g",
            f"-I{adapter_dir}",
            f"-I{suite_dir}/env",
            f"-I{suite_dir}/isa/macros/scalar",
            f"-T{adapter_dir}/link.ld",
            "-DRVTEST_RV32U",
            "-o", str(elf_path),
            test_path
        ]
    else:
        # riscv-arch-test
        suite_dir = ARCH_TEST_DIR
        cmd = [
            GCC, "-march=rv32im", "-mabi=ilp32", "-static",
            "-mcmodel=medany", "-fvisibility=hidden",
            "-nostdlib", "-nostartfiles", "-g",
            f"-I{adapter_dir}",
            f"-I{suite_dir}/riscv-test-suite/env",
            f"-T{adapter_dir}/link.ld",
            "-DXLEN=32",
            "-o", str(elf_path),
            test_path
        ]
    
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=str(test_out_dir))
    
    if result.returncode != 0:
        return False, result.stderr, test_name
    
    # Generate inst.hex
    subprocess.run([OBJCOPY, "-O", "verilog", str(elf_path), str(inst_hex)], 
                   capture_output=True, cwd=str(test_out_dir))
    
    # Copy to ROM directory
    rom_hex = ROM_DIR / "inst.hex"
    if sys.platform == "win32":
        subprocess.run(["cmd", "/c", "copy", "/Y", str(inst_hex), str(rom_hex)], 
                       capture_output=True)
    else:
        subprocess.run(["cp", str(inst_hex), str(rom_hex)], capture_output=True)
    
    return True, "", test_name


def run_simulation():
    """Run the V2 simulation"""
    compile_cmd = (
        "iverilog -g2012 -s tb_v2 -o out_iverilog/bin/tb_v2_riscv_test.out "
        "-I ../module/CORE/RTL_V1_2 ../module/CORE/RTL_V1_2/*.v "
        "../libs/REG_ARRAY/SRAM/ram_bfm.v tb_v2.sv"
    )
    
    result = subprocess.run(compile_cmd, shell=True, capture_output=True, 
                           text=True, cwd=str(COMP_TEST_DIR))
    if result.returncode != 0:
        return False, "Compile failed", ""
    
    run_cmd = "vvp out_iverilog/bin/tb_v2_riscv_test.out"
    try:
        result = subprocess.run(run_cmd, shell=True, capture_output=True, 
                               text=True, cwd=str(COMP_TEST_DIR), timeout=30)
    except subprocess.TimeoutExpired:
        return False, "Timeout", ""
    
    output = result.stdout + result.stderr
    
    if "PASS" in output:
        return True, "PASS", output
    return False, "FAIL", output[-500:] if output else ""


def download_suite(suite_name):
    """Download a test suite if not present"""
    suite = TEST_SUITES.get(suite_name)
    if not suite:
        print(f"Unknown suite: {suite_name}")
        return False
    
    target_dir = suite["dir"]
    if target_dir.exists():
        print(f"  {suite_name} already exists at {target_dir}")
        return True
    
    print(f"\n  Downloading {suite_name}...")
    print(f"    {suite['description']}")
    
    zip_path = VERIFICATION_DIR / f"{suite_name}.zip"
    
    try:
        print(f"    URL: {suite['url']}")
        urllib.request.urlretrieve(suite['url'], zip_path)
        
        print(f"    Extracting...")
        with zipfile.ZipFile(zip_path, 'r') as zf:
            zf.extractall(VERIFICATION_DIR)
        
        # Rename extracted folder
        extracted = list(VERIFICATION_DIR.glob(f"{suite_name}-*"))
        if extracted:
            extracted[0].rename(target_dir)
        
        zip_path.unlink()
        print(f"    Done!")
        return True
    except Exception as e:
        print(f"    Download failed: {e}")
        return False


def run_tests_for_suite(suite_name, categories=None, auto_download=True):
    """Run tests for a specific suite"""
    suite = TEST_SUITES.get(suite_name)
    if not suite:
        print(f"Unknown suite: {suite_name}")
        return []
    
    target_dir = suite["dir"]
    
    # Auto-download if missing
    if not target_dir.exists():
        if auto_download:
            if not download_suite(suite_name):
                return []
        else:
            print(f"\n[SKIP] {suite_name} - not found (use --download to auto-download)")
            return []
    
    if categories is None:
        categories = suite["categories"]
    
    print(f"\n{'='*60}")
    print(f"  {suite_name}")
    print(f"  {suite['description']}")
    print(f"{'='*60}")
    
    # Create adapter directory
    adapter_dir = OUTPUT_DIR / "adapter"
    adapter_dir.mkdir(parents=True, exist_ok=True)
    
    # Write adapter files - use appropriate linker script
    if suite_name == "riscv-tests":
        (adapter_dir / "link.ld").write_text(create_adapter_linker_v1())
    else:
        (adapter_dir / "link.ld").write_text(create_adapter_linker())
    (adapter_dir / "riscv_test.h").write_text(create_adapter_header())
    (adapter_dir / "model_test.h").write_text(create_model_test_header())
    
    results = []
    
    for category in categories:
        # riscv-tests uses: isa/rv32ui, isa/rv32um
        # riscv-arch-test uses: riscv-test-suite/rv32i_m/I/src, riscv-test-suite/rv32i_m/M/src
        test_dir = target_dir / "isa" / category
        if not test_dir.exists():
            # Try arch-test path structure
            # Map category names: rv32i -> I, rv32im -> M, etc.
            arch_category = category.upper().replace("RV32I", "I").replace("RV32IM", "M").replace("RV32M", "M")
            if category.lower() in ["rv32i", "rv32im", "rv32m"]:
                arch_category = "I" if category.lower() == "rv32i" else "M"
            test_dir = target_dir / "riscv-test-suite" / "rv32i_m" / arch_category / "src"
            if not test_dir.exists():
                print(f"\n[SKIP] {category} - directory not found (tried: {test_dir})")
                continue
        
        tests = sorted(glob.glob(str(test_dir / "*.S")))
        if not tests:
            tests = sorted(glob.glob(str(test_dir / "*.s")))
        
        print(f"\n[{category}] Found {len(tests)} tests")
        
        for test_path in tests:
            test_name = Path(test_path).stem
            
            if test_name in ["Makefrag", "Makefile", "link"]:
                continue
            
            print(f"  Testing {test_name}...", end=" ", flush=True)
            
            success, error, name = compile_test(test_path, OUTPUT_DIR / suite_name / category, adapter_dir, suite_name)
            
            if not success:
                print("BUILD_FAIL")
                results.append((name, "BUILD_FAIL", error[:100] if error else ""))
                continue
            
            sim_success, sim_result, sim_output = run_simulation()
            
            if sim_success:
                print("PASS")
                results.append((name, "PASS", ""))
            else:
                print("FAIL")
                results.append((name, "FAIL", sim_output[:200] if sim_output else ""))
    
    return results


def main():
    parser = argparse.ArgumentParser(description="Run RISC-V tests on AdamRiscv V2")
    parser.add_argument("--suite", choices=["riscv-tests", "riscv-arch-test", "all"], 
                        default="riscv-tests", help="Test suite to run")
    parser.add_argument("--download", action="store_true", help="Force download even if exists")
    parser.add_argument("--categories", nargs="+", help="Categories to run")
    args = parser.parse_args()
    
    print("=" * 60)
    print("  RISC-V Tests Runner for AdamRiscv V2")
    print("=" * 60)
    
    all_results = []
    
    if args.suite == "all":
        for suite_name in TEST_SUITES:
            results = run_tests_for_suite(suite_name, auto_download=True)
            all_results.extend(results)
    else:
        results = run_tests_for_suite(args.suite, args.categories, auto_download=True)
        all_results.extend(results)
    
    # Summary
    print("\n" + "=" * 60)
    print("  Summary")
    print("=" * 60)
    
    passed = sum(1 for _, r, _ in all_results if r == "PASS")
    failed = sum(1 for _, r, _ in all_results if r != "PASS")
    total = len(all_results)
    
    print(f"\n  Total: {passed}/{total} passed")
    
    if failed > 0:
        print(f"\n  Failed tests:")
        for name, result, error in all_results:
            if result != "PASS":
                print(f"    {name}: {result}")
                if error:
                    print(f"      {error[:100]}")
    
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())