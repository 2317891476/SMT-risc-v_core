#!/usr/bin/env python3
"""Convert rom/inst.hex and rom/data.hex into Xilinx COE files.

Default inputs:
  - rom/inst.hex
  - rom/data.hex

Default outputs:
  - fpga/bram_init/inst_mem.coe
  - fpga/bram_init/data_mem.coe
"""

from __future__ import annotations

import argparse
from pathlib import Path


def parse_verilog_hex(path: Path) -> dict[int, int]:
    data: dict[int, int] = {}
    if not path.exists():
        raise FileNotFoundError(f"Input file not found: {path}")

    current_addr = 0
    with path.open("r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("//") or line.startswith("#"):
                continue
            if line.startswith("@"):
                current_addr = int(line[1:], 16)
                continue

            for token in line.split():
                token = token.strip()
                if not token:
                    continue
                if len(token) % 2 != 0:
                    token = "0" + token
                for i in range(0, len(token), 2):
                    byte_val = int(token[i : i + 2], 16)
                    data[current_addr] = byte_val
                    current_addr += 1

    return data


def byte_map_to_words(
    byte_map: dict[int, int], depth_words: int, base_addr: int, allow_auto_rebase: bool
) -> list[int]:
    words = [0] * depth_words
    if not byte_map:
        return words

    addresses = sorted(byte_map.keys())
    use_rebase = allow_auto_rebase and any(addr >= base_addr for addr in addresses)

    for addr, value in byte_map.items():
        eff_addr = addr - base_addr if use_rebase else addr
        if eff_addr < 0:
            continue

        word_idx = eff_addr // 4
        byte_lane = eff_addr % 4
        if word_idx >= depth_words:
            continue

        words[word_idx] |= (value & 0xFF) << (8 * byte_lane)

    return words


def write_coe(path: Path, words: list[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        for i, word in enumerate(words):
            suffix = ";\n" if i == len(words) - 1 else ",\n"
            f.write(f"{word:08X}{suffix}")


def build_arg_parser() -> argparse.ArgumentParser:
    repo_root = Path(__file__).resolve().parents[2]

    p = argparse.ArgumentParser(description="Generate Xilinx COE files from verilog hex.")
    p.add_argument("--inst-input", type=Path, default=repo_root / "rom" / "inst.hex")
    p.add_argument("--data-input", type=Path, default=repo_root / "rom" / "data.hex")
    p.add_argument(
        "--inst-output",
        type=Path,
        default=repo_root / "fpga" / "bram_init" / "inst_mem.coe",
    )
    p.add_argument(
        "--data-output",
        type=Path,
        default=repo_root / "fpga" / "bram_init" / "data_mem.coe",
    )
    p.add_argument(
        "--depth",
        type=int,
        default=8192,
        choices=[8192, 16384],
        help="BRAM depth in 32-bit words (8192=32KB, 16384=64KB)",
    )
    p.add_argument(
        "--data-base",
        type=lambda x: int(x, 0),
        default=0x1000,
        help="Data region base address used for rebasing (default: 0x1000)",
    )
    return p


def main() -> int:
    args = build_arg_parser().parse_args()

    inst_bytes = parse_verilog_hex(args.inst_input)
    data_bytes = parse_verilog_hex(args.data_input)

    inst_words = byte_map_to_words(
        byte_map=inst_bytes,
        depth_words=args.depth,
        base_addr=0x0,
        allow_auto_rebase=False,
    )
    data_words = byte_map_to_words(
        byte_map=data_bytes,
        depth_words=args.depth,
        base_addr=args.data_base,
        allow_auto_rebase=True,
    )

    write_coe(args.inst_output, inst_words)
    write_coe(args.data_output, data_words)

    print(f"Generated: {args.inst_output}")
    print(f"Generated: {args.data_output}")
    print(f"Depth(words): {args.depth}")
    print("Memory map: inst@0x00000000, data@0x00001000 (default rebasing)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
