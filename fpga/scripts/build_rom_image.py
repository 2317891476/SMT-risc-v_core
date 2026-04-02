#!/usr/bin/env python3
"""Build the board ROM image used by the AX7203 FPGA flow.

This keeps `rom/inst.hex` / `rom/data.hex` deterministic before Vivado runs,
so board builds do not accidentally inherit the last simulation test image.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def infer_march(asm_path: Path) -> str:
    name = asm_path.name.lower()
    if any(token in name for token in ("csr", "interrupt", "clint", "plic")):
        return "rv32i_zicsr"
    return "rv32i"


def run_checked(cmd: list[str], cwd: Path) -> None:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)


def main() -> int:
    repo_root = Path(__file__).resolve().parents[2]
    rom_dir = repo_root / "rom"

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--asm",
        type=Path,
        default=rom_dir / "test_fpga_uart_board_diag.s",
        help="Assembly source to compile into rom/inst.hex and rom/data.hex",
    )
    parser.add_argument(
        "--march",
        default=None,
        help="Optional -march override. Defaults to an inferred value from the file name.",
    )
    args = parser.parse_args()

    asm_path = args.asm
    if not asm_path.is_absolute():
        asm_path = (repo_root / asm_path).resolve()
    if not asm_path.exists():
        raise SystemExit(f"ROM source not found: {asm_path}")

    march = args.march or infer_march(asm_path)
    gcc = shutil.which("riscv-none-elf-gcc")
    objcopy = shutil.which("riscv-none-elf-objcopy")
    if not gcc or not objcopy:
        raise SystemExit("Missing riscv-none-elf-gcc or riscv-none-elf-objcopy in PATH")

    elf_path = rom_dir / f"{asm_path.stem}.elf"
    inst_hex = rom_dir / "inst.hex"
    data_hex = rom_dir / "data.hex"

    for stale in (inst_hex, data_hex):
        if stale.exists():
            stale.unlink()

    run_checked(
        [
            gcc,
            "-nostdlib",
            "-nostartfiles",
            "-Wl,--build-id=none",
            "-Wl,-T,harvard_link.ld",
            f"-march={march}",
            "-mabi=ilp32",
            str(asm_path),
            "-o",
            str(elf_path),
        ],
        cwd=rom_dir,
    )

    run_checked(
        [objcopy, "-j", ".text", "-O", "verilog", str(elf_path), str(inst_hex)],
        cwd=rom_dir,
    )

    data_proc = subprocess.run(
        [objcopy, "-j", ".data", "-O", "verilog", str(elf_path), str(data_hex)],
        cwd=rom_dir,
        capture_output=True,
        text=True,
    )
    if data_proc.returncode != 0:
        sys.stderr.write(data_proc.stdout)
        sys.stderr.write(data_proc.stderr)
        raise SystemExit(data_proc.returncode)

    if not data_hex.exists():
        data_hex.write_text("// empty data image\n00000000\n", encoding="ascii")

    print(f"ROM image built from {asm_path}")
    print(f"  march   : {march}")
    print(f"  inst.hex: {inst_hex}")
    print(f"  data.hex: {data_hex}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
