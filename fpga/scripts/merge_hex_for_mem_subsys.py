#!/usr/bin/env python3
"""
Merge inst.hex (.text @ 0x0000) and data.hex (.data @ 0x1000) into a single
mem_subsys_ram.hex for use by $readmemh in mem_subsys.v.

Both input files use byte-addressed Verilog $readmemh format:
    @00000000
    AB
    CD
    ...

Output is word-addressed (32-bit words), little-endian:
    @00000000
    DEADBEEF
    ...

Usage:
    python merge_hex_for_mem_subsys.py [--inst rom/inst.hex] [--data rom/data.hex] [-o rom/mem_subsys_ram.hex]
"""
import argparse
import os


def parse_byte_hex(path):
    """Parse a byte-addressed hex file into {byte_addr: byte_value}."""
    result = {}
    if not os.path.exists(path):
        return result
    addr = 0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('@'):
                addr = int(line[1:], 16)
                continue
            for token in line.split():
                result[addr] = int(token, 16)
                addr += 1
    return result


def merge_and_write(inst_path, data_path, out_path, ram_words=4096):
    """Merge instruction and data hex files into word-addressed output."""
    inst_bytes = parse_byte_hex(inst_path)
    data_bytes = parse_byte_hex(data_path)

    # data.hex addresses are relative to .data base (0x1000 in harvard_link.ld)
    # but the @address in data.hex already reflects that offset, so we just merge.
    all_bytes = {}
    all_bytes.update(inst_bytes)
    all_bytes.update(data_bytes)

    if not all_bytes:
        print(f"WARNING: no data found in {inst_path} or {data_path}")

    # Pack bytes into 32-bit little-endian words
    word_dict = {}
    for byte_addr, byte_val in all_bytes.items():
        word_addr = (byte_addr // 4) * 4
        shift = (byte_addr % 4) * 8
        word_dict[word_addr] = word_dict.get(word_addr, 0) | (byte_val << shift)

    max_word_addr = max(word_dict.keys()) if word_dict else 0
    max_word_idx = min(max_word_addr // 4, ram_words - 1)

    with open(out_path, 'w') as f:
        f.write('@00000000\n')
        for idx in range(max_word_idx + 1):
            word_addr = idx * 4
            f.write(f'{word_dict.get(word_addr, 0):08X}\n')

    total_nonzero = sum(1 for idx in range(max_word_idx + 1)
                        if word_dict.get(idx * 4, 0) != 0)
    print(f"Written {out_path}: {max_word_idx + 1} words "
          f"({total_nonzero} non-zero), "
          f"inst={len(inst_bytes)} bytes, data={len(data_bytes)} bytes")


def main():
    parser = argparse.ArgumentParser(description='Merge inst.hex + data.hex for mem_subsys')
    parser.add_argument('--inst', default='rom/inst.hex', help='Instruction hex file')
    parser.add_argument('--data', default='rom/data.hex', help='Data hex file')
    parser.add_argument('-o', '--output', default='rom/mem_subsys_ram.hex',
                        help='Output combined hex file')
    parser.add_argument('--ram-words', type=int, default=4096,
                        help='RAM size in 32-bit words (default 4096 = 16KB)')
    args = parser.parse_args()
    merge_and_write(args.inst, args.data, args.output, args.ram_words)


if __name__ == '__main__':
    main()
