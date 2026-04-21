#!/usr/bin/env python3
"""Build AX7203 benchmark ROM images for Dhrystone/CoreMark."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
ROM_DIR = REPO_ROOT / "rom"
BUILD_ROOT = REPO_ROOT / "build" / "benchmark_images"
COREMARK_CACHE = REPO_ROOT / "build" / "benchmark_sources" / "coremark"
COREMARK_FILES = [
    "core_main.c",
    "core_list_join.c",
    "core_matrix.c",
    "core_state.c",
    "core_util.c",
    "coremark.h",
]


def which_required(name: str) -> str:
    resolved = shutil.which(name)
    if not resolved:
        raise SystemExit(f"Missing required executable: {name}")
    return resolved


def run_checked(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    return proc


def parse_section_vmas(elf_path: Path) -> dict[str, tuple[int, int]]:
    objdump = which_required("riscv-none-elf-objdump")
    proc = run_checked([objdump, "-h", str(elf_path)], REPO_ROOT)
    sections: dict[str, tuple[int, int]] = {}
    for line in proc.stdout.splitlines():
        fields = line.split()
        if len(fields) < 6 or not fields[0].isdigit():
            continue
        name = fields[1]
        size = int(fields[2], 16)
        vma = int(fields[3], 16)
        sections[name] = (vma, size)
    return sections


def write_verilog_byte_image(
    elf_path: Path,
    objcopy: str,
    out_path: Path,
    section_names: list[str],
    scratch_dir: Path,
) -> None:
    sections = parse_section_vmas(elf_path)
    image: dict[int, int] = {}

    for section_name in section_names:
        if section_name not in sections:
            continue
        vma, size = sections[section_name]
        if size == 0:
            continue
        tmp_bin = scratch_dir / f"{section_name.lstrip('.')}.bin"
        run_checked([objcopy, "-O", "binary", "-j", section_name, str(elf_path), str(tmp_bin)], REPO_ROOT)
        data = tmp_bin.read_bytes()
        for offset, byte in enumerate(data):
            image[vma + offset] = byte

    if not image:
        out_path.write_text("// empty data image\n00000000\n", encoding="ascii")
        return

    current_addr = None
    with out_path.open("w", encoding="ascii", newline="\n") as fh:
        for addr in sorted(image):
            if current_addr is None or addr != current_addr:
                fh.write(f"@{addr:08X}\n")
            fh.write(f"{image[addr]:02X}\n")
            current_addr = addr + 1


def ensure_coremark_sources() -> Path:
    COREMARK_CACHE.mkdir(parents=True, exist_ok=True)
    if all((COREMARK_CACHE / name).exists() for name in COREMARK_FILES):
        return COREMARK_CACHE

    git = shutil.which("git")
    if git:
        repo_dir = COREMARK_CACHE.parent / "coremark_repo"
        if not repo_dir.exists():
            proc = subprocess.run(
                [git, "clone", "--depth", "1", "https://github.com/eembc/coremark.git", str(repo_dir)],
                capture_output=True,
                text=True,
                check=False,
            )
            if proc.returncode == 0:
                for name in COREMARK_FILES:
                    shutil.copy2(repo_dir / name, COREMARK_CACHE / name)
                return COREMARK_CACHE

    branches = ("main", "master")
    last_error = None
    for branch in branches:
        try:
            for name in COREMARK_FILES:
                url = f"https://raw.githubusercontent.com/eembc/coremark/{branch}/{name}"
                with urllib.request.urlopen(url, timeout=30) as resp:
                    (COREMARK_CACHE / name).write_bytes(resp.read())
            return COREMARK_CACHE
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            last_error = exc
            for name in COREMARK_FILES:
                path = COREMARK_CACHE / name
                if path.exists():
                    path.unlink()

    raise SystemExit(f"Failed to fetch CoreMark upstream sources: {last_error}")


def build_common_flags(cpu_hz: int) -> list[str]:
    return [
        "-march=rv32im",
        "-mabi=ilp32",
        "-msave-restore",
        "-msmall-data-limit=0",
        "-ffunction-sections",
        "-fdata-sections",
        "-fno-common",
        "-fno-builtin",
        f"-DAX7203_CPU_HZ={cpu_hz}",
    ]


def build_dhrystone_sources(cpu_hz: int, runs: int, out_dir: Path) -> tuple[list[str], list[str]]:
    sources = [
        str(REPO_ROOT / "benchmarks" / "common_ax7203" / "ax7203_bare_crt0.S"),
        str(REPO_ROOT / "benchmarks" / "common_ax7203" / "ax7203_board_runtime.c"),
        str(REPO_ROOT / "benchmarks" / "dhrystone" / "dhrystone.c"),
        str(REPO_ROOT / "benchmarks" / "dhrystone" / "dhrystone_main.c"),
    ]
    flags = build_common_flags(cpu_hz) + [
        "-O2",
        "-std=gnu89",
        "-Wno-return-type",
        f"-DAX7203_DHRYSTONE_RUNS={runs}",
        "-I",
        str(REPO_ROOT / "benchmarks" / "common_ax7203"),
        "-I",
        str(REPO_ROOT / "benchmarks" / "dhrystone"),
        "-I",
        str(REPO_ROOT / "verification" / "riscv-tests" / "benchmarks" / "dhrystone"),
    ]
    return sources, flags


def build_coremark_sources(cpu_hz: int, iterations: int, total_data_size: int, out_dir: Path) -> tuple[list[str], list[str]]:
    cache_dir = ensure_coremark_sources()
    sources = [
        str(REPO_ROOT / "benchmarks" / "common_ax7203" / "ax7203_bare_crt0.S"),
        str(REPO_ROOT / "benchmarks" / "common_ax7203" / "ax7203_board_runtime.c"),
        str(REPO_ROOT / "benchmarks" / "coremark" / "core_portme.c"),
        *[str(cache_dir / name) for name in COREMARK_FILES if name.endswith(".c")],
    ]
    flags = build_common_flags(cpu_hz) + [
        "-Os",
        "-std=gnu99",
        f"-DITERATIONS={iterations}",
        f"-DTOTAL_DATA_SIZE={total_data_size}",
        "-DMEM_METHOD=MEM_STATIC",
        "-DMULTITHREAD=1",
        "-DMAIN_HAS_NOARGC=1",
        "-DHAS_FLOAT=0",
        "-DHAS_TIME_H=0",
        "-DUSE_CLOCK=0",
        "-I",
        str(REPO_ROOT / "benchmarks" / "common_ax7203"),
        "-I",
        str(REPO_ROOT / "benchmarks" / "coremark"),
        "-I",
        str(cache_dir),
    ]
    return sources, flags


def parse_size_report(size_output: str) -> tuple[int, int, int]:
    lines = [line.strip() for line in size_output.splitlines() if line.strip()]
    if len(lines) < 2:
        return (0, 0, 0)
    fields = lines[-1].split()
    if len(fields) < 3:
        return (0, 0, 0)
    return (int(fields[0]), int(fields[1]), int(fields[2]))


def parse_symbol_addr(elf_path: Path, symbol_name: str) -> int:
    nm = which_required("riscv-none-elf-nm")
    proc = run_checked([nm, str(elf_path)], REPO_ROOT)
    for line in proc.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[2] == symbol_name:
            return int(fields[0], 16)
    raise SystemExit(f"Symbol not found in {elf_path}: {symbol_name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--benchmark", choices=("dhrystone", "coremark"), required=True)
    parser.add_argument("--cpu-hz", type=int, default=10_000_000)
    parser.add_argument("--dhrystone-runs", type=int, default=5000)
    parser.add_argument("--fixed-dhrystone-runs", type=int, default=None)
    parser.add_argument("--coremark-iterations", type=int, default=10)
    parser.add_argument("--coremark-total-data-size", type=int, default=1200)
    parser.add_argument("--startup-delay-ms", type=int, default=0)
    parser.add_argument(
        "--verilator-mainline",
        action="store_true",
        help="Build the benchmark image with Verilator-only runtime fast paths enabled.",
    )
    parser.add_argument(
        "--ddr3-xip",
        action="store_true",
        help="Link the benchmark for execution from DDR3 at 0x80000000.",
    )
    parser.add_argument(
        "--emit-bin",
        action="store_true",
        help="Emit a flat binary image for the DDR3 UART loader.",
    )
    parser.add_argument(
        "--manifest",
        action="store_true",
        help="Emit a JSON manifest next to the DDR3 binary.",
    )
    args = parser.parse_args()

    gcc = which_required("riscv-none-elf-gcc")
    objcopy = which_required("riscv-none-elf-objcopy")
    size = which_required("riscv-none-elf-size")

    build_dir = BUILD_ROOT / args.benchmark
    build_dir.mkdir(parents=True, exist_ok=True)
    image_suffix = "ddr3" if args.ddr3_xip else "bram"
    elf_path = build_dir / f"{args.benchmark}_{image_suffix}.elf"
    bin_path = build_dir / f"{args.benchmark}_{image_suffix}.bin"
    manifest_path = build_dir / f"{args.benchmark}_{image_suffix}.json"
    inst_hex = ROM_DIR / "inst.hex"
    data_hex = ROM_DIR / "data.hex"

    if args.benchmark == "dhrystone":
        if args.fixed_dhrystone_runs is not None and args.fixed_dhrystone_runs <= 0:
            raise SystemExit(f"fixed dhrystone runs must be positive, got {args.fixed_dhrystone_runs}")
        sources, cflags = build_dhrystone_sources(args.cpu_hz, args.dhrystone_runs, build_dir)
    else:
        sources, cflags = build_coremark_sources(
            args.cpu_hz,
            args.coremark_iterations,
            args.coremark_total_data_size,
            build_dir,
        )

    if args.startup_delay_ms < 0:
        raise SystemExit(f"startup delay must be non-negative, got {args.startup_delay_ms}")
    cflags.append(f"-DAX7203_BENCH_STARTUP_DELAY_MS={args.startup_delay_ms}")
    if args.fixed_dhrystone_runs is not None:
        cflags.append(f"-DAX7203_FIXED_DHRYSTONE_RUNS={args.fixed_dhrystone_runs}")
    if args.verilator_mainline:
        cflags.append("-DVERILATOR_MAINLINE=1")
    if args.ddr3_xip:
        cflags.append("-DAX7203_CLEAR_BSS=1")

    for stale in (inst_hex, data_hex):
        if stale.exists():
            stale.unlink()

    link_script = (
        REPO_ROOT / "benchmarks" / "common_ax7203" / "ax7203_ddr3_xip.ld"
        if args.ddr3_xip
        else REPO_ROOT / "benchmarks" / "common_ax7203" / "ax7203_harvard_bench.ld"
    )

    link_cmd = [
        gcc,
        *cflags,
        "-nostartfiles",
        "-nostdlib",
        "-Wl,--build-id=none",
        "-Wl,--gc-sections",
        f"-Wl,-T,{link_script}",
        *sources,
        "-lgcc",
        "-o",
        str(elf_path),
    ]
    run_checked(link_cmd, ROM_DIR)
    size_proc = run_checked([size, str(elf_path)], ROM_DIR)

    text_size, data_size, bss_size = parse_size_report(size_proc.stdout)
    entry_addr = parse_symbol_addr(elf_path, "_start")

    if args.ddr3_xip:
        if args.emit_bin or args.manifest:
            run_checked([objcopy, "-O", "binary", str(elf_path), str(bin_path)], REPO_ROOT)
        if args.manifest:
            payload = bin_path.read_bytes()
            checksum = sum(payload) & 0xFFFFFFFF
            manifest = {
                "benchmark": args.benchmark,
                "format": "ax7203-ddr3-uart-loader-v1",
                "elf": str(elf_path),
                "bin": str(bin_path),
                "load_addr": 0x80000000,
                "entry": entry_addr,
                "size_bytes": len(payload),
                "checksum32": checksum,
                "cpu_hz": args.cpu_hz,
                "text_size": text_size,
                "data_size": data_size,
                "bss_size": bss_size,
            }
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="ascii")

        print(f"Benchmark DDR3 image built: {args.benchmark}")
        print(f"  cpu_hz  : {args.cpu_hz}")
        print(f"  entry   : 0x{entry_addr:08X}")
        print(f"  text    : {text_size}")
        print(f"  data    : {data_size}")
        print(f"  bss     : {bss_size}")
        if bin_path.exists():
            payload = bin_path.read_bytes()
            print(f"  bin     : {bin_path}")
            print(f"  size    : {len(payload)}")
            print(f"  checksum: 0x{(sum(payload) & 0xFFFFFFFF):08X}")
        if manifest_path.exists():
            print(f"  manifest: {manifest_path}")
        return 0

    if text_size > 16 * 1024:
        raise SystemExit(
            f"{args.benchmark} text image is too large for the 16KB instruction backing store: {text_size} bytes"
        )
    if (data_size + bss_size) > 11 * 1024:
        raise SystemExit(
            f"{args.benchmark} data+bss footprint is too large for the 16KB data RAM budget: {data_size + bss_size} bytes"
        )

    run_checked([objcopy, "-j", ".text", "-O", "verilog", str(elf_path), str(inst_hex)], ROM_DIR)

    write_verilog_byte_image(elf_path, objcopy, data_hex, [".rodata", ".data"], build_dir)

    print(f"Benchmark image built: {args.benchmark}")
    print(f"  cpu_hz  : {args.cpu_hz}")
    print(f"  startup_delay_ms: {args.startup_delay_ms}")
    print(f"  text    : {text_size}")
    print(f"  data    : {data_size}")
    print(f"  bss     : {bss_size}")
    print(f"  inst.hex: {inst_hex}")
    print(f"  data.hex: {data_hex}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
