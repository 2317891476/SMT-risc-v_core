#!/usr/bin/env python3
"""
Download and setup RISC-V test suites for AdamRiscv.
Usage: python download_tests.py
"""

import os
import sys
import subprocess
import urllib.request
import zipfile
from pathlib import Path

TESTS_DIR = Path(__file__).parent.parent / "verification" / "test_suites"

TEST_SUITES = {
    "riscv-tests": {
        "url": "https://github.com/riscv-software-src/riscv-tests/archive/refs/heads/master.zip",
        "description": "Official RISC-V test suite (RV32I/M/A/F/D/C)",
        "tests_count": "~100+",
    },
    "riscv-arch-test": {
        "url": "https://github.com/riscv/riscv-arch-test/archive/refs/heads/main.zip",
        "description": "RISC-V Architecture Certification Tests",
        "tests_count": "500+",
    },
    "riscv-torture": {
        "url": "https://github.com/ucb-bar/riscv-torture/archive/refs/heads/master.zip",
        "description": "Random instruction generator for stress testing",
        "tests_count": "Unlimited (generated)",
    },
}

def download_file(url, dest):
    """Download file with progress indicator"""
    print(f"  Downloading {url}...")
    try:
        urllib.request.urlretrieve(url, dest)
        return True
    except Exception as e:
        print(f"  ✗ Failed: {e}")
        return False

def extract_zip(zip_path, dest_dir):
    """Extract zip file"""
    print(f"  Extracting...")
    with zipfile.ZipFile(zip_path, 'r') as zf:
        zf.extractall(dest_dir)
    os.remove(zip_path)
    return True

def download_suite(name, info):
    """Download and extract a test suite"""
    print(f"\n{'='*60}")
    print(f"  {name}")
    print(f"  {info['description']}")
    print(f"  Tests: {info['tests_count']}")
    print(f"{'='*60}")
    
    dest_dir = TESTS_DIR / name
    if dest_dir.exists():
        print(f"  ✓ Already exists at {dest_dir}")
        return True
    
    TESTS_DIR.mkdir(parents=True, exist_ok=True)
    
    zip_path = TESTS_DIR / f"{name}.zip"
    
    if download_file(info['url'], zip_path):
        extract_zip(zip_path, TESTS_DIR)
        # Rename extracted folder
        extracted = list(TESTS_DIR.glob(f"{name}-*"))
        if extracted:
            extracted[0].rename(dest_dir)
        print(f"  ✓ Installed at {dest_dir}")
        return True
    return False

def main():
    print("=" * 60)
    print("  RISC-V Test Suite Downloader for AdamRiscv")
    print("=" * 60)
    
    results = {}
    for name, info in TEST_SUITES.items():
        results[name] = download_suite(name, info)
    
    print("\n" + "=" * 60)
    print("  Summary")
    print("=" * 60)
    for name, success in results.items():
        status = "✓ Installed" if success else "✗ Failed"
        print(f"  {name}: {status}")
    
    if all(results.values()):
        print("\n  All test suites installed successfully!")
        print(f"  Location: {TESTS_DIR}")
        return 0
    return 1

if __name__ == "__main__":
    sys.exit(main())
