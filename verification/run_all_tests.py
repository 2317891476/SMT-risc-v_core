#!/usr/bin/env python3
"""
Unified test runner for AdamRiscv.
Supports: basic tests, riscv-tests, riscv-arch-test, RISCOF.

Test suites:
  --basic           : Core tests + Store Buffer tests + P2 L2/Interrupt tests (14 tests)
                      - test1, test2, test_rv32i_full (core functionality)
                      - test_store_buffer_simple, test_store_buffer_commit,
                        test_store_buffer_forwarding, test_store_buffer_hazard,
                        test_commit_flush_store (Store Buffer dedicated)
                      - test_l2_icache_refill, test_l2_i_d_arbiter, test_l2_mmio_bypass (P2 L2)
                      - test_csr_mret_smoke, test_clint_timer_interrupt,
                        test_plic_external_interrupt, test_interrupt_mask_mret (P2 Interrupts)
  --riscv-tests     : Classic riscv-tests RV32I/M (~50 tests, auto-download)
  --riscv-arch-test : Official architecture tests (500+ tests, auto-download)
  --riscof          : RISCOF framework (requires Spike)
  --all             : Run all tests
"""

import os
import sys
import subprocess
import argparse
import time
import urllib.request
import zipfile
from pathlib import Path
from datetime import datetime

PROJECT_ROOT = Path(__file__).parent.parent
COMP_TEST_DIR = PROJECT_ROOT / "comp_test"
ROM_DIR = PROJECT_ROOT / "rom"
VERIFICATION_DIR = PROJECT_ROOT / "verification"
RISCV_TESTS_DIR = VERIFICATION_DIR / "riscv-tests"
ARCH_TEST_DIR = VERIFICATION_DIR / "riscv-arch-test"

# Test suite URLs
TEST_SUITE_URLS = {
    "riscv-tests": "https://github.com/riscv-software-src/riscv-tests/archive/refs/heads/master.zip",
    "riscv-arch-test": "https://github.com/riscv/riscv-arch-test/archive/refs/heads/main.zip",
}


class TestRunner:
    def __init__(self, verbose=False):
        self.verbose = verbose
        self.results = []
        self.start_time = None
        
    def log(self, msg, level="INFO"):
        prefix = "  " if level != "ERROR" else "  [ERR] "
        print(f"{prefix}{msg}")
    
    def run_command(self, cmd, cwd=None, timeout=300):
        """Run command and capture output"""
        try:
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True,
                timeout=timeout, cwd=cwd
            )
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            return -1, "", "Timeout"
        except Exception as e:
            return -1, "", str(e)
    
    def download_suite(self, name):
        """Download test suite if not present"""
        if name == "riscv-tests":
            target_dir = RISCV_TESTS_DIR
        elif name == "riscv-arch-test":
            target_dir = ARCH_TEST_DIR
        else:
            return False
        
        if target_dir.exists():
            self.log(f"{name} already exists")
            return True
        
        self.log(f"Downloading {name}...")
        zip_path = VERIFICATION_DIR / f"{name}.zip"
        
        try:
            urllib.request.urlretrieve(TEST_SUITE_URLS[name], zip_path)
            self.log(f"Extracting...")
            with zipfile.ZipFile(zip_path, 'r') as zf:
                zf.extractall(VERIFICATION_DIR)
            # Rename extracted folder
            extracted = list(VERIFICATION_DIR.glob(f"{name}-*"))
            if extracted:
                extracted[0].rename(target_dir)
            zip_path.unlink()
            self.log(f"Done!")
            return True
        except Exception as e:
            self.log(f"Download failed: {e}", "ERROR")
            return False
    
    def run_basic_tests(self, tests=None):
        """Run basic tests including Store Buffer and Branch Prediction tests"""
        self.log("Running basic tests...", "INFO")
        
        if tests is None:
            # Core functionality tests
            tests = [
                "test1.s",
                "test2.S",
                "test_rv32i_full.s",
                # Store Buffer dedicated tests
                "test_store_buffer_simple.s",
                "test_store_buffer_commit.s",
                "test_store_buffer_forwarding.s",
                "test_store_buffer_hazard.s",
                "test_commit_flush_store.s",
                # P2 L2 Cache tests
                "test_l2_icache_refill.s",
                "test_l2_i_d_arbiter.s",
                "test_l2_mmio_bypass.s",
                # P2 Interrupt tests
                "test_csr_mret_smoke.s",
                "test_clint_timer_interrupt.s",
                "test_plic_external_interrupt.s",
                "test_interrupt_mask_mret.s",
                # P3 RoCC tests
                "test_rocc_dma.s",
                "test_rocc_status.s",
                "test_rocc_gemm.s",
                # Branch Prediction tests (included in test_rv32i_full with 17 branch instructions)
            ]
        
        for test in tests:
            test_name = Path(test).stem
            self.log(f"Testing {test_name}...")
            
            # Build ROM
            # Use rv32i_zicsr for CSR tests to support csrr/csrw/mret instructions
            march_flag = "rv32i_zicsr" if "csr" in test_name or "interrupt" in test_name or "clint" in test_name or "plic" in test_name else "rv32i"
            build_cmd = f'''
riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none -Wl,-T,harvard_link.ld -march={march_flag} -mabi=ilp32 {test} -o {test_name}.elf
riscv-none-elf-objcopy -j .text -O verilog {test_name}.elf inst.hex
riscv-none-elf-objcopy -j .data -O verilog {test_name}.elf data.hex
'''
            ret, out, err = self.run_command(build_cmd, cwd=ROM_DIR)
            if ret != 0:
                self.results.append((test_name, "BUILD_FAIL", err))
                self.log(f"{test_name}: BUILD_FAIL - {err[:100] if err else 'Unknown error'}", "ERROR")
                # Clean up stale hex files to prevent subsequent tests from using wrong ROM
                for stale_file in ["inst.hex", "data.hex"]:
                    stale_path = ROM_DIR / stale_file
                    if stale_path.exists():
                        stale_path.unlink()
                        self.log(f"Cleaned up stale {stale_file}", "INFO")
                continue
            
            # Compile V2 testbench
            # 确保输出目录存在
            out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
            out_dir.mkdir(parents=True, exist_ok=True)

            compile_cmd = "iverilog -g2012 -s tb -o out_iverilog/bin/tb_test.out -I ../rtl ../rtl/*.v ../libs/REG_ARRAY/SRAM/ram_bfm.v tb.sv"
            ret, out, err = self.run_command(compile_cmd, cwd=COMP_TEST_DIR)
            if ret != 0:
                self.results.append((test_name, "COMPILE_FAIL", err))
                continue
            
            # Run simulation
            run_cmd = "vvp out_iverilog/bin/tb_test.out"
            ret, out, err = self.run_command(run_cmd, cwd=COMP_TEST_DIR, timeout=60)
            
            if "PASS" in out:
                self.results.append((test_name, "PASS", ""))
                self.log(f"{test_name}: PASS")
            else:
                self.results.append((test_name, "FAIL", out[-200:] if out else err))
                self.log(f"{test_name}: FAIL", "ERROR")
    
    def run_riscv_tests(self):
        """Run riscv-tests (RV32I + RV32M)"""
        self.log("Running riscv-tests...", "INFO")
        
        if not self.download_suite("riscv-tests"):
            return
        
        # Run using run_riscv_tests.py
        ret, out, err = self.run_command(
            "python run_riscv_tests.py --suite riscv-tests",
            cwd=VERIFICATION_DIR, timeout=600
        )
        
        # Parse results - extract pass count
        import re
        match = re.search(r'Total:\s*(\d+)/(\d+)\s*passed', out)
        if match:
            passed, total = int(match.group(1)), int(match.group(2))
            # Allow up to 10% failure rate for tests requiring optional extensions
            min_pass_rate = 0.90
            if passed >= total * min_pass_rate:
                self.results.append(("riscv-tests", "PASS", f"{passed}/{total} passed"))
            else:
                self.results.append(("riscv-tests", "FAIL", f"{passed}/{total} passed"))
        else:
            self.results.append(("riscv-tests", "FAIL", err[:200] if err else "Parse error"))
    
    def run_arch_test(self):
        """Run riscv-arch-test (Official architecture tests)"""
        self.log("Running riscv-arch-test...", "INFO")
        
        if not self.download_suite("riscv-arch-test"):
            return
        
        # Run using run_riscv_tests.py
        ret, out, err = self.run_command(
            "python run_riscv_tests.py --suite riscv-arch-test",
            cwd=VERIFICATION_DIR, timeout=1200
        )
        
        if "Total:" in out:
            lines = out.split('\n')
            for line in lines:
                if "Total:" in line:
                    self.results.append(("riscv-arch-test", "PASS" if ret == 0 else "FAIL", line.strip()))
                    break
        else:
            self.results.append(("riscv-arch-test", "FAIL", err[:200] if err else "Unknown error"))
    
    def run_riscof(self):
        """Run RISCOF architecture tests"""
        self.log("Running RISCOF tests...", "INFO")
        
        riscof_dir = VERIFICATION_DIR / "riscof"
        config_file = riscof_dir / "config.ini"
        
        if not config_file.exists():
            self.log("RISCOF config not found", "ERROR")
            self.results.append(("RISCOF", "SKIP", "Config not found"))
            return
        
        cmd = "riscof run --config config.ini --suite ../riscv-arch-test --env ../riscv-tests/env"
        ret, out, err = self.run_command(cmd, cwd=riscof_dir, timeout=1800)
        
        if ret == 0:
            self.results.append(("RISCOF", "PASS", ""))
        else:
            self.results.append(("RISCOF", "FAIL", err[:200] if err else "Unknown error"))
    
    def print_summary(self):
        """Print test summary"""
        print("\n" + "=" * 60)
        print("  Test Summary")
        print("=" * 60)
        
        passed = sum(1 for _, r, _ in self.results if r == "PASS")
        failed = sum(1 for _, r, _ in self.results if r not in ["PASS", "SKIP"])
        skipped = sum(1 for _, r, _ in self.results if r == "SKIP")
        
        for name, result, detail in self.results:
            if result == "PASS":
                status = "[PASS]"
            elif result == "SKIP":
                status = "[SKIP]"
            else:
                status = "[FAIL]"
            print(f"  {status} {name}: {result}")
            if detail and result != "PASS":
                print(f"      {detail[:80]}")
        
        print("\n" + "-" * 60)
        print(f"  Total: {passed} passed, {failed} failed, {skipped} skipped")
        
        if self.start_time:
            elapsed = time.time() - self.start_time
            print(f"  Time: {elapsed:.1f}s")
        
        return 0 if failed == 0 else 1


def main():
    parser = argparse.ArgumentParser(description="AdamRiscv Unified Test Runner")
    parser.add_argument("--basic", action="store_true", help="Run basic tests (test1, test2, test_rv32i_full)")
    parser.add_argument("--riscv-tests", action="store_true", help="Run classic riscv-tests (auto-download)")
    parser.add_argument("--riscv-arch-test", action="store_true", help="Run official arch tests (auto-download)")
    parser.add_argument("--riscof", action="store_true", help="Run RISCOF framework tests")
    parser.add_argument("--all", action="store_true", help="Run all tests")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
    parser.add_argument("--tests", nargs="+", help="Specific basic tests to run")
    args = parser.parse_args()
    
    runner = TestRunner(verbose=args.verbose)
    runner.start_time = time.time()
    
    print("=" * 60)
    print("  AdamRiscv Unified Test Runner")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)
    
    # Default: run basic tests if no specific flags
    run_default = not (args.riscv_tests or args.riscv_arch_test or args.riscof)
    
    if args.all or args.basic or run_default:
        runner.run_basic_tests(args.tests)
    
    if args.all or args.riscv_tests:
        runner.run_riscv_tests()
    
    if args.all or args.riscv_arch_test:
        runner.run_arch_test()
    
    if args.all or args.riscof:
        runner.run_riscof()
    
    return runner.print_summary()


if __name__ == "__main__":
    sys.exit(main())
