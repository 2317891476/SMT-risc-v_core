#!/usr/bin/env python3
"""
Local RISCOF test runner for AdamRiscv.
Usage: python run_riscof.py [--suite SUITE] [--env ENV]
"""

import os
import sys
import subprocess
import argparse

def main():
    parser = argparse.ArgumentParser(description='Run RISCOF tests for AdamRiscv')
    parser.add_argument('--suite', default='../riscv-tests/isa', 
                        help='Path to riscv-tests suite')
    parser.add_argument('--env', default='../riscv-tests/env',
                        help='Path to test environment')
    parser.add_argument('--config', default='config.ini',
                        help='RISCOF config file')
    parser.add_argument('--no-run', action='store_true',
                        help='Only compile, do not run')
    args = parser.parse_args()

    # Check dependencies
    print("Checking dependencies...")
    
    # Check RISCOF
    try:
        subprocess.run(['riscof', '--version'], capture_output=True, check=True)
        print("  ✓ RISCOF installed")
    except:
        print("  ✗ RISCOF not found. Install with: pip install riscof")
        return 1
    
    # Check GCC
    try:
        subprocess.run(['riscv-none-elf-gcc', '--version'], capture_output=True, check=True)
        print("  ✓ riscv-none-elf-gcc found")
    except:
        print("  ✗ riscv-none-elf-gcc not found in PATH")
        return 1
    
    # Check iverilog
    try:
        subprocess.run(['iverilog', '-V'], capture_output=True, check=True)
        print("  ✓ iverilog found")
    except:
        print("  ✗ iverilog not found")
        return 1

    # Check riscv-tests
    if not os.path.exists(args.suite):
        print(f"\nriscv-tests not found at {args.suite}")
        print("Clone with: git clone https://github.com/riscv-software-src/riscv-tests.git ../riscv-tests")
        return 1
    
    # Run RISCOF
    print(f"\nRunning RISCOF with config: {args.config}")
    cmd = ['riscof', 'run', '--config', args.config, '--suite', args.suite, '--env', args.env]
    
    if args.no_run:
        # Add flag to only compile
        pass  # RISCOF doesn't have a compile-only flag, would need to modify plugin
    
    try:
        result = subprocess.run(cmd, cwd=os.path.dirname(__file__))
        return result.returncode
    except KeyboardInterrupt:
        print("\nInterrupted by user")
        return 1

if __name__ == '__main__':
    sys.exit(main())
