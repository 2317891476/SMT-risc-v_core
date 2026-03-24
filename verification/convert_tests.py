#!/usr/bin/env python3
"""
Convert riscv-tests to AdamRiscv format.
Generates hex files and test manifests for simulation.
"""

import os
import sys
import subprocess
import glob
from pathlib import Path

# Configuration
RISCV_GCC = "riscv-none-elf-gcc"
RISCV_OBJCOPY = "riscv-none-elf-objcopy"
LINKER_SCRIPT = "../rom/harvard_link.ld"

class TestConverter:
    def __init__(self, tests_dir, output_dir):
        self.tests_dir = Path(tests_dir)
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
    def find_tests(self, category="rv32ui"):
        """Find all test files for a category"""
        pattern = str(self.tests_dir / "isa" / category / "*.S")
        return sorted(glob.glob(pattern))
    
    def compile_test(self, test_path, category):
        """Compile a single test to hex files"""
        test_name = Path(test_path).stem
        test_out_dir = self.output_dir / category / test_name
        test_out_dir.mkdir(parents=True, exist_ok=True)
        
        # Compile command
        elf_path = test_out_dir / f"{test_name}.elf"
        inst_hex = test_out_dir / "inst.hex"
        data_hex = test_out_dir / "data.hex"
        
        cmd = [
            RISCV_GCC,
            "-march=rv32im",
            "-mabi=ilp32",
            "-static",
            "-mcmodel=medany",
            "-fvisibility=hidden",
            "-nostdlib",
            "-nostartfiles",
            "-g",
            f"-I{self.tests_dir}/env",
            f"-T{LINKER_SCRIPT}",
            "-o", str(elf_path),
            test_path
        ]
        
        try:
            # Compile
            result = subprocess.run(cmd, capture_output=True, text=True, cwd=str(test_out_dir))
            if result.returncode != 0:
                return False, f"Compile error: {result.stderr}"
            
            # Generate inst.hex
            subprocess.run([
                RISCV_OBJCOPY, "-O", "verilog",
                str(elf_path), str(inst_hex)
            ], capture_output=True)
            
            # Generate data.hex
            subprocess.run([
                RISCV_OBJCOPY, "-O", "verilog",
                "-j", ".data",
                str(elf_path), str(data_hex)
            ], capture_output=True)
            
            return True, str(test_out_dir)
            
        except Exception as e:
            return False, str(e)
    
    def convert_category(self, category):
        """Convert all tests in a category"""
        tests = self.find_tests(category)
        print(f"\n[{category}] Found {len(tests)} tests")
        
        results = []
        for test in tests:
            success, msg = self.compile_test(test, category)
            status = "✓" if success else "✗"
            print(f"  {status} {Path(test).stem}: {msg if not success else 'OK'}")
            results.append((Path(test).stem, success))
        
        return results

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Convert riscv-tests to AdamRiscv format")
    parser.add_argument("--tests-dir", default="../verification/riscv-tests",
                        help="Path to riscv-tests directory")
    parser.add_argument("--output", default="../verification/generated_tests",
                        help="Output directory for generated tests")
    parser.add_argument("--categories", nargs="+", 
                        default=["rv32ui", "rv32um"],
                        help="Test categories to convert")
    args = parser.parse_args()
    
    converter = TestConverter(args.tests_dir, args.output)
    
    print("=" * 60)
    print("  RISC-V Tests Converter for AdamRiscv")
    print("=" * 60)
    
    all_results = {}
    for category in args.categories:
        all_results[category] = converter.convert_category(category)
    
    # Summary
    print("\n" + "=" * 60)
    print("  Summary")
    print("=" * 60)
    total = 0
    passed = 0
    for category, results in all_results.items():
        cat_passed = sum(1 for _, s in results if s)
        total += len(results)
        passed += cat_passed
        print(f"  {category}: {cat_passed}/{len(results)} converted")
    
    print(f"\n  Total: {passed}/{total} tests converted")
    print(f"  Output: {args.output}")
    
    return 0 if passed == total else 1

if __name__ == "__main__":
    sys.exit(main())
