#!/usr/bin/env python3
"""Build and run an AX7203 DDR3 benchmark payload through the UART loader."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import threading
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_DIR = REPO_ROOT / "build"
ROM_DIR = REPO_ROOT / "rom"
RTL_DIR = REPO_ROOT / "rtl"
FPGA_RTL_DIR = REPO_ROOT / "fpga" / "rtl"
COMP_TEST_DIR = REPO_ROOT / "comp_test"
LIB_RAM_BFM = REPO_ROOT / "libs" / "REG_ARRAY" / "SRAM" / "ram_bfm.v"
PROJECT_DIR = BUILD_DIR / "ax7203"
LOADER_ROM = ROM_DIR / "test_fpga_ddr3_loader.s"
EARLY_AUDIT_ROM = ROM_DIR / "test_fpga_ddr3_loader_early_audit.s"
BEACON_SELFTEST_ROM = ROM_DIR / "test_fpga_ddr3_loader_beacon_selftest.s"
TRANSPORT_ROM = ROM_DIR / "test_fpga_uart_loader_transport.s"
BRIDGE_STRESS_ROM = ROM_DIR / "test_fpga_ddr3_bridge_stress.s"
BRIDGE_STEPS_ROM = ROM_DIR / "test_fpga_ddr3_bridge_steps.s"
STEP2_ONLY_ROM = ROM_DIR / "test_fpga_ddr3_bridge_step2_only.s"
TINY_PAYLOAD_ROM = ROM_DIR / "test_fpga_ddr3_exec_payload.s"
LOADER_TB = COMP_TEST_DIR / "tb_ax7203_top_ddr3_loader_smoke.sv"
LOADER_TB_TOP = "tb_ax7203_top_ddr3_loader_smoke"
BEACON_SELFTEST_TB = COMP_TEST_DIR / "tb_ax7203_top_loader_beacon_selftest.sv"
BEACON_SELFTEST_TB_TOP = "tb_ax7203_top_loader_beacon_selftest"
TRANSPORT_TB = COMP_TEST_DIR / "tb_uart_loader_transport.sv"
TRANSPORT_TB_TOP = "tb_uart_loader_transport"
TRANSPORT_TOP_SMOKE_TB = COMP_TEST_DIR / "tb_ax7203_top_uart_loader_transport_smoke.sv"
TRANSPORT_TOP_SMOKE_TB_TOP = "tb_ax7203_top_uart_loader_transport_smoke"
BRIDGE_STRESS_TB = COMP_TEST_DIR / "tb_ddr3_mem_port_async_stress.sv"
BRIDGE_STRESS_TB_TOP = "tb_ddr3_mem_port_async_stress"
BRIDGE_TOP_SMOKE_TB = COMP_TEST_DIR / "tb_ax7203_top_ddr3_bridge_stress_smoke.sv"
BRIDGE_TOP_SMOKE_TB_TOP = "tb_ax7203_top_ddr3_bridge_stress_smoke"
BRIDGE_STEPS_TOP_SMOKE_TB = COMP_TEST_DIR / "tb_ax7203_top_ddr3_bridge_steps_smoke.sv"
BRIDGE_STEPS_TOP_SMOKE_TB_TOP = "tb_ax7203_top_ddr3_bridge_steps_smoke"
STEP2_ONLY_TOP_SMOKE_TB = COMP_TEST_DIR / "tb_ax7203_top_ddr3_bridge_step2_only_smoke.sv"
STEP2_ONLY_TOP_SMOKE_TB_TOP = "tb_ax7203_top_ddr3_bridge_step2_only_smoke"
FETCH_PROBE_TB = COMP_TEST_DIR / "tb_ax7203_top_ddr3_fetch_probe_smoke.sv"
FETCH_PROBE_TB_TOP = "tb_ax7203_top_ddr3_fetch_probe_smoke"
MIG_STUB = COMP_TEST_DIR / "mig_7series_0_stub.v"
PAYLOAD_HEX = ROM_DIR / "ddr3_loader_payload.hex"
TRANSPORT_PAYLOAD_HEX = ROM_DIR / "uart_loader_transport_payload.hex"
TIMING_SUMMARY_AGGR = PROJECT_DIR / "reports" / "timing_summary_aggressive.rpt"
TIMING_DETAIL_AGGR = PROJECT_DIR / "reports" / "timing_detail_aggressive.rpt"
UTILIZATION_AGGR = PROJECT_DIR / "reports" / "utilization_aggressive.rpt"
BUILD_ID_FILE = PROJECT_DIR / "adam_riscv_ax7203_bitstream_id.txt"
UART_CAPTURE_FILE = BUILD_DIR / "dhrystone_ddr3_uart_capture.txt"
UART_CAPTURE_RAW_FILE = BUILD_DIR / "dhrystone_ddr3_uart_capture.bin"
UART_CAPTURE_LOADER_DECODED_FILE = BUILD_DIR / "dhrystone_ddr3_uart_capture.loader.decoded.txt"
UART_EARLY_AUDIT_CAPTURE_FILE = BUILD_DIR / "loader_early_audit_uart_capture.txt"
UART_EARLY_AUDIT_CAPTURE_RAW_FILE = BUILD_DIR / "loader_early_audit_uart_capture.bin"
UART_EARLY_AUDIT_CAPTURE_DECODED_FILE = BUILD_DIR / "loader_early_audit_uart_capture.loader.decoded.txt"
UART_EARLY_AUDIT_CAPTURE_SESSIONS_FILE = BUILD_DIR / "loader_early_audit_sessions.json"
EARLY_AUDIT_SWEEP_DIR = BUILD_DIR / "fpga_loader_early_audit_sweep"
UART_BEACON_SELFTEST_CAPTURE_FILE = BUILD_DIR / "loader_beacon_selftest_uart_capture.txt"
UART_BEACON_SELFTEST_CAPTURE_RAW_FILE = BUILD_DIR / "loader_beacon_selftest_uart_capture.bin"
UART_BEACON_SELFTEST_CAPTURE_DECODED_FILE = BUILD_DIR / "loader_beacon_selftest_uart_capture.loader.decoded.txt"
UART_BEACON_SELFTEST_CAPTURE_SESSIONS_FILE = BUILD_DIR / "loader_beacon_selftest_sessions.json"
UART_SMOKE_CAPTURE_FILE = BUILD_DIR / "dhrystone_ddr3_smoke_uart_capture.txt"
UART_SMOKE_CAPTURE_RAW_FILE = BUILD_DIR / "dhrystone_ddr3_smoke_uart_capture.bin"
UART_SMOKE_CAPTURE_LOADER_DECODED_FILE = BUILD_DIR / "dhrystone_ddr3_smoke_uart_capture.loader.decoded.txt"
TRANSPORT_CAPTURE_FILE = BUILD_DIR / "uart_loader_transport_capture.txt"
BRIDGE_CAPTURE_FILE = BUILD_DIR / "ddr3_bridge_audit_uart_capture.txt"
BRIDGE_STEPS_CAPTURE_FILE = BUILD_DIR / "ddr3_bridge_audit_steps_uart_capture.txt"
STEP2_ONLY_CAPTURE_FILE = BUILD_DIR / "ddr3_bridge_audit_step2_only_uart_capture.bin"
STEP2_ONLY_CAPTURE_DECODED_FILE = BUILD_DIR / "ddr3_bridge_audit_step2_only_uart_capture.decoded.txt"
UART_PAYLOAD_CHUNK_BYTES = 4
UART_PAYLOAD_ACK = 0x06
UART_BLOCK_CHECKSUM_BYTES = 64
UART_BLOCK_ACK = 0x17
UART_BLOCK_NACK = 0x15
UART_PAYLOAD_ACK_TIMEOUT_S = 5.0
UART_BLOCK_REPLY_TIMEOUT_S = 5.0
UART_HEADER_BYTE_DELAY_S = 0.002
UART_HEADER_TO_PAYLOAD_GRACE_S = 0.75
UART_BOARD_PAYLOAD_BYTE_DELAY_S = 0.002
UART_BOARD_PAYLOAD_CHUNK_GAP_S = 0.020
UART_BOARD_PRE_BLOCK_CHECKSUM_GAP_S = 0.050
UART_BOARD_BLOCK_CHECKSUM_BYTE_DELAY_S = 0.003
UART_BOARD_BLOCK_GAP_S = 0.050
UART_BOARD_BLOCK_RETRY_GAP_S = 0.500
UART_BLOCK_RETRY_LIMIT = 8
UART_MAINLINE_PAYLOAD_ACK_TIMEOUT_S = 8.0
UART_MAINLINE_BLOCK_REPLY_TIMEOUT_S = 8.0
UART_MAINLINE_PAYLOAD_BYTE_DELAY_S = 0.002
UART_MAINLINE_PAYLOAD_CHUNK_GAP_S = 0.030
UART_MAINLINE_PRE_BLOCK_CHECKSUM_GAP_S = 0.080
UART_MAINLINE_BLOCK_CHECKSUM_BYTE_DELAY_S = 0.003
UART_MAINLINE_BLOCK_GAP_S = 0.080
UART_MAINLINE_BLOCK_RETRY_GAP_S = 1.000
UART_MAINLINE_BLOCK_RETRY_LIMIT = 10
EARLY_AUDIT_TRAINING_BYTE = 0x55
EARLY_AUDIT_TRAINING_COUNT_SIM = 16
EARLY_AUDIT_TRAINING_COUNT_BOARD = 32
FULL_GATE_FAST_UART_CLK_DIV = 4
LOADER_FULL_PREFIX1_BLOCKS = 1
LOADER_FULL_PREFIX4_BLOCKS = 4
LOADER_FULL_PREFIX16_BLOCKS = 16
USE_REGISTERED_UART_RXDATA = True
BLOCK_CHECKSUM_BYTES = 64
TRANSPORT_CASE_SIZES = [16, 64, 256, 1024]
TRANSPORT_READY_TOKEN = "BOOT TRANSPORT READY"
TRANSPORT_TOP_SIM_TIMEOUT_S = 600
TRANSPORT_TOP_SIM_TB_TIMEOUT_NS = 35_000_000
BRIDGE_TOP_SIM_TIMEOUT_S = 300
BRIDGE_TOP_SIM_TB_TIMEOUT_NS = 30_000_000
BRIDGE_STEPS_TOP_SIM_TIMEOUT_S = 300
BRIDGE_STEPS_TOP_SIM_TB_TIMEOUT_NS = 1_000_000
STEP2_ONLY_TOP_SIM_TIMEOUT_S = 300
STEP2_ONLY_TOP_SIM_TB_TIMEOUT_NS = 2_000_000
STEP2_BEACON_SOF = 0xA5
STEP2_EVT_READY = 0x01
STEP2_EVT_C1_OK = 0x11
STEP2_EVT_C2_OK = 0x12
STEP2_EVT_C3_START = 0x31
STEP2_EVT_C3_AFTER = 0x32
STEP2_EVT_C3_OK = 0x33
STEP2_EVT_C4_START = 0x41
STEP2_EVT_C4_AFTER = 0x42
STEP2_EVT_C4_OK = 0x43
STEP2_EVT_C5_START = 0x51
STEP2_EVT_C5_AFTER = 0x52
STEP2_EVT_C5_OK = 0x53
STEP2_EVT_BAD = 0xE0
STEP2_EVT_CAL_FAIL = 0xE1
STEP2_EVT_TRAP = 0xEF
STEP2_EVT_SUMMARY = 0xF0
LOADER_EVT_READY = 0x01
LOADER_EVT_LOAD_START = 0x02
LOADER_EVT_BLOCK_ACK = 0x11
LOADER_EVT_BLOCK_NACK = 0x12
LOADER_EA_EVT_HDR_B0_RX = 0x31
LOADER_EA_EVT_HDR_B1_RX = 0x32
LOADER_EA_EVT_HDR_B2_RX = 0x33
LOADER_EA_EVT_HDR_B3_RX = 0x34
LOADER_EA_EVT_HDR_MAGIC_OK = 0x35
LOADER_EA_EVT_IDLE_OK = 0x36
LOADER_EA_EVT_TRAIN_START = 0x37
LOADER_EA_EVT_TRAIN_DONE = 0x38
LOADER_EA_EVT_FLUSH_DONE = 0x39
LOADER_EA_EVT_HEADER_ENTER = 0x3A
LOADER_EVT_READ_OK = 0x21
LOADER_EVT_LOAD_OK = 0x22
LOADER_EVT_JUMP = 0x23
LOADER_EVT_CAL_FAIL = 0xE0
LOADER_EVT_BAD_MAGIC = 0xE1
LOADER_EVT_CHECKSUM_FAIL = 0xE2
LOADER_EVT_READBACK_FAIL = 0xE3
LOADER_EVT_READBACK_BLOCK_FAIL = 0xE4
LOADER_EVT_RX_OVERRUN = 0xE5
LOADER_EVT_RX_FRAME_ERR = 0xE6
LOADER_EVT_DRAIN_TIMEOUT = 0xE7
LOADER_EVT_SIZE_TOO_BIG = 0xE8
LOADER_EA_EVT_TRAIN_TIMEOUT = 0xE9
LOADER_EA_EVT_FLUSH_TIMEOUT = 0xEA
LOADER_EVT_TRAP = 0xEF
LOADER_EVT_SUMMARY = 0xF0
LOADER_SUM_READY = 0x01
LOADER_SUM_LOAD_START = 0x02
LOADER_SUM_READ_OK = 0x04
LOADER_SUM_LOAD_OK = 0x08
LOADER_SUM_JUMP = 0x10
LOADER_SUM_ANY_BAD = 0x80
LOADER_EA_SUM_READY = 0x01
LOADER_EA_SUM_HDR_MAGIC_OK = 0x02
LOADER_EA_SUM_LOAD_START = 0x04
LOADER_EA_SUM_FIRST_BLOCK_ACK = 0x08
EARLY_AUDIT_SWEEP_TRIALS = (
    ("Q100_H0", 100, 0),
    ("Q200_H0", 200, 0),
    ("Q100_H10", 100, 10),
)
BEACON_SELFTEST_TOP_SIM_TB_TIMEOUT_NS = 120_000_000
BEACON_SELFTEST_TOP_SIM_TIMEOUT_S = 600
BEACON_SELFTEST_EXPECTED_SEQUENCE = (
    (LOADER_EVT_READY, 0xA1),
    (LOADER_EA_EVT_IDLE_OK, 0xB2),
    (LOADER_EA_EVT_TRAIN_START, 0xC3),
    (LOADER_EA_EVT_TRAIN_DONE, 0x14),
    (LOADER_EA_EVT_FLUSH_DONE, 0x05),
    (LOADER_EA_EVT_HEADER_ENTER, 0xD6),
    (LOADER_EA_EVT_HDR_B0_RX, 0x42),
    (LOADER_EA_EVT_HDR_B1_RX, 0x4D),
    (LOADER_EA_EVT_HDR_B2_RX, 0x4B),
    (LOADER_EA_EVT_HDR_B3_RX, 0x31),
    (LOADER_EA_EVT_HDR_MAGIC_OK, 0xE7),
    (LOADER_EVT_LOAD_START, 0xF8),
    (LOADER_EVT_BLOCK_ACK, 0x00),
    (LOADER_EVT_SUMMARY, 0x0F),
)


def which_required(*names: str) -> str:
    for name in names:
        resolved = shutil.which(name)
        if resolved:
            return resolved
    raise SystemExit(f"Missing required executable: one of {', '.join(names)}")


def run_logged(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    log_path: Path,
    timeout: int | None = None,
) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"$ {' '.join(cmd)}\n\n")
        fh.flush()
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            env=env,
            stdout=fh,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
    if proc.returncode != 0:
        raise RuntimeError(f"Command failed ({proc.returncode}): {' '.join(cmd)}; see {log_path}")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def collect_verilog(root: Path) -> list[str]:
    return [str(path) for path in sorted(root.glob("*.v"))]


def derive_idx_width(depth: int) -> int:
    return 1 if depth <= 1 else (depth - 1).bit_length()


def derive_clk_wiz_half_div(core_clk_mhz: float) -> int:
    return max(1, round(100.0 / core_clk_mhz))


def derive_uart_clk_div(core_clk_mhz: float, baud: int = 115200) -> int:
    return max(1, round((core_clk_mhz * 1_000_000.0) / float(baud)))


def parse_build_id(path: Path) -> str:
    if not path.exists():
        return "N/A"
    match = re.search(r"BUILD_ID=(0x[0-9A-Fa-f]+)", read_text(path))
    return match.group(1) if match else "N/A"


def parse_timing_summary(path: Path) -> dict[str, str]:
    result = {"wns": "N/A", "whs": "N/A", "constraints_met": "False"}
    if not path.exists():
        return result
    text = read_text(path)
    match = re.search(r"\n\s*([-0-9.]+)\s+[-0-9.]+\s+[0-9]+\s+[0-9]+\s+([-0-9.]+)\s+[-0-9.]+", text)
    if match:
        result["wns"], result["whs"] = match.groups()
    result["constraints_met"] = str("All user specified timing constraints are met." in text)
    return result


def fmt_optional_hex(value: object) -> str:
    if isinstance(value, int):
        return f"0x{value:08X}"
    return str(value)


def clone_manifest_outputs(manifest: dict[str, object], out_dir: Path, stem: str) -> dict[str, object]:
    out_dir.mkdir(parents=True, exist_ok=True)
    cloned = dict(manifest)
    for key in ("elf", "bin"):
        value = manifest.get(key)
        if not value:
            continue
        src = Path(str(value))
        dst = out_dir / f"{stem}{src.suffix}"
        shutil.copy2(src, dst)
        cloned[key] = str(dst)
    return cloned


def build_env(
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    *,
    smt_mode: int = 1,
    fetch_debug: bool = False,
    bridge_audit: bool = False,
    step2_beacon_debug: bool = False,
    loader_beacon_debug: bool = False,
    uart_baud: int = 115200,
    rom_asm: Path | None = None,
    rom_march: str | None = None,
    transport_uart_rxdata_reg_test: bool = USE_REGISTERED_UART_RXDATA,
) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "AX7203_ENABLE_MEM_SUBSYS": "1",
            "AX7203_ENABLE_DDR3": "1",
            "AX7203_ENABLE_ROCC": "0",
            "AX7203_SMT_MODE": str(smt_mode),
            "AX7203_RS_DEPTH": str(rs_depth),
            "AX7203_RS_IDX_W": str(derive_idx_width(rs_depth)),
            "AX7203_FETCH_BUFFER_DEPTH": str(fetch_buffer_depth),
            "AX7203_CORE_CLK_MHZ": f"{core_clk_mhz:.1f}",
            "AX7203_UART_CLK_DIV": str(derive_uart_clk_div(core_clk_mhz, uart_baud)),
            "AX7203_ROM_ASM": str(LOADER_ROM),
            "AX7203_TOP_MODULE": "adam_riscv_ax7203_top",
            "AX7203_DDR3_FETCH_DEBUG": "1" if fetch_debug else "0",
            "AX7203_DDR3_BRIDGE_AUDIT": "1" if bridge_audit else "0",
            "AX7203_STEP2_BEACON_DEBUG": "1" if step2_beacon_debug else "0",
            "AX7203_DDR3_LOADER_BEACON_DEBUG": "1" if loader_beacon_debug else "0",
            "AX7203_TRANSPORT_UART_RXDATA_REG_TEST": "1" if transport_uart_rxdata_reg_test else "0",
            "AX7203_MAX_THREADS": "4",
            "AX7203_SYNTH_JOBS": "4",
            "AX7203_IMPL_JOBS": "4",
        }
    )
    if rom_asm is not None:
        env["AX7203_ROM_ASM"] = str(rom_asm)
    if rom_march is not None:
        env["AX7203_ROM_MARCH"] = rom_march
    return env


def transport_payload_bytes(size_bytes: int, seed: int) -> bytes:
    del seed
    return bytes((idx & 0xFF) for idx in range(size_bytes))


def materialize_transport_payload(out_dir: Path, *, size_bytes: int, seed: int, stem: str) -> dict[str, object]:
    out_dir.mkdir(parents=True, exist_ok=True)
    payload = transport_payload_bytes(size_bytes, seed)
    bin_path = out_dir / f"{stem}.bin"
    bin_path.write_bytes(payload)
    return {
        "bin": str(bin_path),
        "entry": 0,
        "load_addr": 0,
        "size_bytes": len(payload),
        "checksum32": sum(payload) & 0xFFFFFFFF,
        "seed": seed,
    }


def write_hex_bytes(path: Path, payload: bytes) -> None:
    path.write_text("".join(f"{byte:02x}\n" for byte in payload), encoding="ascii")


def compile_ddr3_asm_payload(source: Path, out_dir: Path, name: str) -> dict[str, int | Path]:
    gcc = which_required("riscv-none-elf-gcc")
    objcopy = which_required("riscv-none-elf-objcopy")
    nm = which_required("riscv-none-elf-nm")
    out_dir.mkdir(parents=True, exist_ok=True)
    elf = out_dir / f"{name}.elf"
    binary = out_dir / f"{name}.bin"
    run_logged(
        [
            gcc,
            "-nostdlib",
            "-nostartfiles",
            "-Wl,--build-id=none",
            f"-Wl,-T,{REPO_ROOT / 'benchmarks' / 'common_ax7203' / 'ax7203_ddr3_xip.ld'}",
            "-march=rv32i",
            "-mabi=ilp32",
            str(source),
            "-o",
            str(elf),
        ],
        cwd=ROM_DIR,
        log_path=out_dir / f"{name}_compile.log",
        timeout=300,
    )
    run_logged([objcopy, "-O", "binary", str(elf), str(binary)], cwd=REPO_ROOT, log_path=out_dir / f"{name}_objcopy.log", timeout=120)
    nm_proc = subprocess.run([nm, str(elf)], cwd=REPO_ROOT, capture_output=True, text=True, check=False)
    if nm_proc.returncode != 0:
        raise RuntimeError(nm_proc.stderr)
    entry = 0x80000000
    for line in nm_proc.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[2] == "_start":
            entry = int(fields[0], 16)
            break
    payload = binary.read_bytes()
    return {
        "elf": elf,
        "bin": binary,
        "entry": entry,
        "load_addr": 0x80000000,
        "size_bytes": len(payload),
        "checksum32": sum(payload) & 0xFFFFFFFF,
    }


def write_payload_hex(binary: Path) -> None:
    write_hex_bytes(PAYLOAD_HEX, binary.read_bytes())


def loader_full_gate_profile(block_target: int, core_clk_mhz: float) -> dict[str, int]:
    prefix_payload_size = block_target * UART_BLOCK_CHECKSUM_BYTES
    tb_uart_bit_ns = max(1, round(FULL_GATE_FAST_UART_CLK_DIV * (1000.0 / core_clk_mhz)))
    return {
        "uart_clk_div": FULL_GATE_FAST_UART_CLK_DIV,
        "fast_uart_profile": 1,
        "fast_uart_inject": 0,
        "initial_header_wait_bits": 384,
        "initial_payload_wait_bits": 128,
        "inter_u32_gap_bits": 96,
        "chunk_ack_gap_bits": 16,
        "block_done_gap_bits": 16,
        "tb_timeout_ns": max(24_000_000, min(int((prefix_payload_size + 512) * 14 * tb_uart_bit_ns * 8), 120_000_000)),
        "sim_timeout_s": 840,
    }


def run_loader_top_sim(
    logs_dir: Path,
    manifest: dict[str, object],
    *,
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    expect_exec_pass: bool,
    full_gate_prefix_enable: bool = False,
    full_gate_prefix_block_ack_target: int = LOADER_FULL_PREFIX1_BLOCKS,
    fetch_debug: bool = False,
    uart_baud: int = 115200,
    smt_mode: int = 1,
    log_name: str = "05_run_loader_top_sim.log",
    fast_uart_profile: bool = False,
    fast_uart_inject: int | None = None,
    initial_header_wait_bits: int | None = None,
    initial_payload_wait_bits: int | None = None,
    inter_u32_gap_bits: int | None = None,
    chunk_ack_gap_bits: int | None = None,
    block_done_gap_bits: int | None = None,
    tb_timeout_ns: int | None = None,
    sim_timeout_s: int | None = None,
    rom_asm: Path | None = None,
    early_audit_enable: bool = False,
    early_audit_bad_magic_byte: int = -1,
    beacon_selftest_enable: bool = False,
) -> Path:
    write_payload_hex(Path(str(manifest["bin"])))
    rom_to_build = rom_asm if rom_asm is not None else LOADER_ROM
    run_logged(
        [
            sys.executable,
            str(REPO_ROOT / "fpga" / "scripts" / "build_rom_image.py"),
            "--asm",
            str(rom_to_build),
            "--define",
            "SIM_FAST_STORE_DRAIN=1",
            "--merge-mem-subsys",
        ],
        cwd=REPO_ROOT,
        log_path=logs_dir / "03_build_loader_rom.log",
        timeout=300,
    )

    out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    tb_top = FETCH_PROBE_TB_TOP if fetch_debug else LOADER_TB_TOP
    tb_file = FETCH_PROBE_TB if fetch_debug else LOADER_TB
    out_file = out_dir / f"{tb_top}.out"
    debug_defines = ["-DDDR3_FETCH_DEBUG=1", "-DDDR3_FETCH_PROBE_FAST=1"] if fetch_debug else []
    if beacon_selftest_enable:
        sim_uart_clk_div = 4
        fast_uart_inject = 0 if fast_uart_inject is None else fast_uart_inject
        initial_header_wait_bits = 4 if initial_header_wait_bits is None else initial_header_wait_bits
        initial_payload_wait_bits = 4 if initial_payload_wait_bits is None else initial_payload_wait_bits
        inter_u32_gap_bits = 1 if inter_u32_gap_bits is None else inter_u32_gap_bits
        chunk_ack_gap_bits = 1 if chunk_ack_gap_bits is None else chunk_ack_gap_bits
        block_done_gap_bits = 1 if block_done_gap_bits is None else block_done_gap_bits
    elif early_audit_enable:
        sim_uart_clk_div = 4
        fast_uart_inject = 1 if fast_uart_inject is None else fast_uart_inject
        initial_header_wait_bits = 4 if initial_header_wait_bits is None else initial_header_wait_bits
        initial_payload_wait_bits = 4 if initial_payload_wait_bits is None else initial_payload_wait_bits
        inter_u32_gap_bits = 1 if inter_u32_gap_bits is None else inter_u32_gap_bits
        chunk_ack_gap_bits = 1 if chunk_ack_gap_bits is None else chunk_ack_gap_bits
        block_done_gap_bits = 1 if block_done_gap_bits is None else block_done_gap_bits
    elif fetch_debug or expect_exec_pass:
        sim_uart_clk_div = 4
        fast_uart_inject = 0 if fast_uart_inject is None else fast_uart_inject
        initial_header_wait_bits = 80 if initial_header_wait_bits is None else initial_header_wait_bits
        initial_payload_wait_bits = 80 if initial_payload_wait_bits is None else initial_payload_wait_bits
        inter_u32_gap_bits = 64 if inter_u32_gap_bits is None else inter_u32_gap_bits
        chunk_ack_gap_bits = 4 if chunk_ack_gap_bits is None else chunk_ack_gap_bits
        block_done_gap_bits = 8 if block_done_gap_bits is None else block_done_gap_bits
    else:
        sim_uart_clk_div = FULL_GATE_FAST_UART_CLK_DIV if fast_uart_profile else 4
        fast_uart_inject = 0 if fast_uart_inject is None else fast_uart_inject
        initial_header_wait_bits = 8 if initial_header_wait_bits is None else initial_header_wait_bits
        initial_payload_wait_bits = 8 if initial_payload_wait_bits is None else initial_payload_wait_bits
        inter_u32_gap_bits = 2 if inter_u32_gap_bits is None else inter_u32_gap_bits
        chunk_ack_gap_bits = 1 if chunk_ack_gap_bits is None else chunk_ack_gap_bits
        block_done_gap_bits = 1 if block_done_gap_bits is None else block_done_gap_bits
    tb_uart_bit_ns = max(1, round(sim_uart_clk_div * (1000.0 / core_clk_mhz)))
    payload_size = int(manifest["size_bytes"])
    if beacon_selftest_enable:
        if tb_timeout_ns is None:
            tb_timeout_ns = 1_000_000
        if sim_timeout_s is None:
            sim_timeout_s = 180
    elif early_audit_enable:
        if tb_timeout_ns is None:
            tb_timeout_ns = 3_000_000
        if sim_timeout_s is None:
            sim_timeout_s = 180
    elif expect_exec_pass:
        if tb_timeout_ns is None:
            tb_timeout_ns = max(5_000_000, int((payload_size + 512) * 14 * tb_uart_bit_ns * 6))
            tb_timeout_ns = min(tb_timeout_ns, 20_000_000)
        if sim_timeout_s is None:
            sim_timeout_s = 1200
    elif full_gate_prefix_enable:
        if tb_timeout_ns is None:
            prefix_payload_size = min(payload_size, full_gate_prefix_block_ack_target * UART_BLOCK_CHECKSUM_BYTES)
            tb_timeout_ns = max(12_000_000, int((prefix_payload_size + 512) * 14 * tb_uart_bit_ns * 4))
            tb_timeout_ns = min(tb_timeout_ns, 60_000_000)
        if sim_timeout_s is None:
            sim_timeout_s = 300
    else:
        if tb_timeout_ns is None:
            tb_timeout_ns = max(40_000_000, int((payload_size + 1024) * 14 * tb_uart_bit_ns * 3))
            tb_timeout_ns = min(tb_timeout_ns, 200_000_000)
        if sim_timeout_s is None:
            sim_timeout_s = 1200
    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        "-DENABLE_MEM_SUBSYS=1",
        "-DENABLE_DDR3=1",
        "-DAX7203_DDR3_LOADER_BEACON_DEBUG=1",
        "-DL2_PASSTHROUGH=1",
        "-DTRANSPORT_UART_RXDATA_REG_TEST=1",
        *(["-DFULL_GATE_FAST_UART=1"] if fast_uart_profile else []),
        *debug_defines,
        "-DENABLE_ROCC_ACCEL=0",
        f"-DSMT_MODE={int(smt_mode)}",
        f"-DTB_SHORT_TIMEOUT_NS={tb_timeout_ns}",
        f"-DTB_UART_BIT_NS={tb_uart_bit_ns}",
        f"-DFPGA_SCOREBOARD_RS_DEPTH={rs_depth}",
        f"-DFPGA_SCOREBOARD_RS_IDX_W={derive_idx_width(rs_depth)}",
        f"-DFPGA_FETCH_BUFFER_DEPTH={fetch_buffer_depth}",
        f"-DFPGA_CLK_WIZ_HALF_DIV={derive_clk_wiz_half_div(core_clk_mhz)}",
        f"-DFPGA_UART_CLK_DIV={sim_uart_clk_div}",
        "-s",
        tb_top,
        "-o",
        str(out_file),
        "-I",
        str(RTL_DIR),
        "-I",
        str(FPGA_RTL_DIR),
        *collect_verilog(RTL_DIR),
        *collect_verilog(FPGA_RTL_DIR),
        str(LIB_RAM_BFM),
        str(COMP_TEST_DIR / "clk_wiz_0_stub.v"),
        str(COMP_TEST_DIR / "ibufgds_stub.v"),
        str(MIG_STUB),
        str(tb_file),
    ]
    run_logged(compile_cmd, cwd=REPO_ROOT, log_path=logs_dir / "04_compile_loader_top_sim.log", timeout=300)
    sim_log = logs_dir / log_name
    run_logged(
        [
            which_required("vvp"),
            str(out_file),
            f"+PAYLOAD_SIZE={int(manifest['size_bytes'])}",
            f"+PAYLOAD_CHECKSUM={int(manifest['checksum32'])}",
            f"+EXPECT_EXEC_PASS={1 if expect_exec_pass else 0}",
            f"+FULL_GATE_PREFIX_ENABLE={1 if full_gate_prefix_enable else 0}",
            f"+FULL_GATE_PREFIX_BLOCK_ACK_TARGET={full_gate_prefix_block_ack_target}",
            f"+FAST_UART_INJECT={fast_uart_inject}",
            f"+INITIAL_HEADER_WAIT_BITS={initial_header_wait_bits}",
            f"+INITIAL_PAYLOAD_WAIT_BITS={initial_payload_wait_bits}",
            f"+INTER_U32_GAP_BITS={inter_u32_gap_bits}",
            f"+CHUNK_ACK_GAP_BITS={chunk_ack_gap_bits}",
            f"+BLOCK_DONE_GAP_BITS={block_done_gap_bits}",
            f"+EARLY_AUDIT_ENABLE={1 if early_audit_enable else 0}",
            f"+EARLY_AUDIT_BAD_MAGIC_BYTE={early_audit_bad_magic_byte}",
            f"+BEACON_SELFTEST_ENABLE={1 if beacon_selftest_enable else 0}",
        ],
        cwd=ROM_DIR,
        log_path=sim_log,
        timeout=sim_timeout_s,
    )
    sim_text = read_text(sim_log)
    expect_token = "[AX7203_DDR3_FETCH_PROBE] PASS" if fetch_debug else "[AX7203_DDR3_LOADER] PASS"
    if expect_token not in sim_text:
        raise RuntimeError(f"DDR3 loader top simulation did not pass; see {sim_log}")
    if not fetch_debug:
        if beacon_selftest_enable:
            sim_result = analyze_loader_beacon_selftest_sim_log(sim_text)
            if not bool(sim_result.get("pass", False)):
                raise RuntimeError(f"DDR3 loader beacon selftest sim did not produce the exact fixed sequence; see {sim_log}")
        elif early_audit_enable:
            sim_result = analyze_loader_early_audit_sim_log(sim_text)
            if early_audit_bad_magic_byte >= 0:
                if not (
                    sim_result.get("ready_seen", False)
                    and sim_result.get("bad_magic_seen", False)
                    and sim_result.get("bad_magic_byte_index") == early_audit_bad_magic_byte
                    and sim_result.get("summary_seen", False)
                    and isinstance(sim_result.get("summary_mask"), int)
                    and (int(sim_result["summary_mask"]) & LOADER_SUM_ANY_BAD) != 0
                ):
                    raise RuntimeError(
                        f"DDR3 loader early-audit sim did not report BAD_MAGIC byte {early_audit_bad_magic_byte}; see {sim_log}"
                    )
            else:
                if not (
                    sim_result.get("ready_seen", False)
                    and sim_result.get("header_magic_ok", False)
                    and sim_result.get("load_start_seen", False)
                    and sim_result.get("first_block_ack_seen", False)
                    and sim_result.get("summary_ok_seen", False)
                ):
                    raise RuntimeError(f"DDR3 loader early-audit sim did not complete header/first-block path; see {sim_log}")
        else:
            sim_result = analyze_loader_sim_log(sim_text)
            if full_gate_prefix_enable:
                if not loader_prefix_target_ok(sim_result, full_gate_prefix_block_ack_target):
                    raise RuntimeError(
                        f"DDR3 loader full-prefix gate did not reach target {full_gate_prefix_block_ack_target}; see {sim_log}"
                    )
            elif expect_exec_pass and not sim_result.get("saw_exec_pass", False):
                raise RuntimeError(f"DDR3 loader quick gate missing EXEC_PASS; see {sim_log}")
    return sim_log


def run_loader_beacon_selftest_top_sim(
    logs_dir: Path,
    *,
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    uart_baud: int,
    smt_mode: int = 1,
    log_name: str = "05_run_loader_beacon_selftest_top_sim.log",
    rom_asm: Path | None = None,
    tb_timeout_ns: int | None = None,
    sim_timeout_s: int | None = None,
) -> Path:
    rom_to_build = rom_asm if rom_asm is not None else BEACON_SELFTEST_ROM
    run_logged(
        [
            sys.executable,
            str(REPO_ROOT / "fpga" / "scripts" / "build_rom_image.py"),
            "--asm",
            str(rom_to_build),
            "--define",
            "SIM_FAST_STORE_DRAIN=1",
            "--merge-mem-subsys",
        ],
        cwd=REPO_ROOT,
        log_path=logs_dir / "03_build_loader_rom.log",
        timeout=300,
    )
    out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{BEACON_SELFTEST_TB_TOP}.out"
    if tb_timeout_ns is None:
        tb_timeout_ns = BEACON_SELFTEST_TOP_SIM_TB_TIMEOUT_NS
    if sim_timeout_s is None:
        sim_timeout_s = BEACON_SELFTEST_TOP_SIM_TIMEOUT_S
    sim_uart_clk_div = FULL_GATE_FAST_UART_CLK_DIV
    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        "-DENABLE_MEM_SUBSYS=1",
        "-DENABLE_DDR3=1",
        "-DAX7203_DDR3_LOADER_BEACON_DEBUG=1",
        "-DL2_PASSTHROUGH=1",
        "-DTRANSPORT_UART_RXDATA_REG_TEST=1",
        "-DENABLE_ROCC_ACCEL=0",
        f"-DSMT_MODE={int(smt_mode)}",
        f"-DTB_SHORT_TIMEOUT_NS={tb_timeout_ns}",
        f"-DFPGA_SCOREBOARD_RS_DEPTH={rs_depth}",
        f"-DFPGA_SCOREBOARD_RS_IDX_W={derive_idx_width(rs_depth)}",
        f"-DFPGA_FETCH_BUFFER_DEPTH={fetch_buffer_depth}",
        f"-DFPGA_CLK_WIZ_HALF_DIV={derive_clk_wiz_half_div(core_clk_mhz)}",
        f"-DFPGA_UART_CLK_DIV={sim_uart_clk_div}",
        "-s",
        BEACON_SELFTEST_TB_TOP,
        "-o",
        str(out_file),
        "-I",
        str(RTL_DIR),
        "-I",
        str(FPGA_RTL_DIR),
        *collect_verilog(RTL_DIR),
        *collect_verilog(FPGA_RTL_DIR),
        str(LIB_RAM_BFM),
        str(COMP_TEST_DIR / "clk_wiz_0_stub.v"),
        str(COMP_TEST_DIR / "ibufgds_stub.v"),
        str(MIG_STUB),
        str(BEACON_SELFTEST_TB),
    ]
    run_logged(compile_cmd, cwd=REPO_ROOT, log_path=logs_dir / "04_compile_loader_beacon_selftest_top_sim.log", timeout=300)
    sim_log = logs_dir / log_name
    run_logged(
        [which_required("vvp"), str(out_file)],
        cwd=ROM_DIR,
        log_path=sim_log,
        timeout=sim_timeout_s,
    )
    sim_text = read_text(sim_log)
    if "[AX7203_LOADER_BEACON_SELFTEST] PASS" not in sim_text:
        raise RuntimeError(f"DDR3 loader beacon selftest top simulation did not pass; see {sim_log}")
    sim_result = analyze_loader_beacon_selftest_sim_log(sim_text)
    if not bool(sim_result.get("pass", False)):
        raise RuntimeError(f"DDR3 loader beacon selftest sim did not produce the exact fixed sequence; see {sim_log}")
    return sim_log


def transport_case_specs(*, jitter_pct: int, byte_gap_bits: int, ack_mode: str, seeds: int) -> list[dict[str, object]]:
    loose_ack_bits = 16 if ack_mode == "loose" else 0
    cases: list[dict[str, object]] = [
        {"name": "nominal_16", "payload_size": 16, "seed": 1, "jitter_pct": 0, "byte_gap_bits": 0, "ack_extra_bits": 0},
        {"name": "nominal_64", "payload_size": 64, "seed": 1, "jitter_pct": 0, "byte_gap_bits": 0, "ack_extra_bits": 0},
        {"name": "nominal_256", "payload_size": 256, "seed": 1, "jitter_pct": 0, "byte_gap_bits": 0, "ack_extra_bits": 0},
        {"name": "nominal_1024", "payload_size": 1024, "seed": 1, "jitter_pct": 0, "byte_gap_bits": 0, "ack_extra_bits": 0},
        {"name": "jitter_1024", "payload_size": 1024, "seed": 1, "jitter_pct": jitter_pct, "byte_gap_bits": 0, "ack_extra_bits": 0},
        {"name": "gap_1024", "payload_size": 1024, "seed": 1, "jitter_pct": 0, "byte_gap_bits": byte_gap_bits, "ack_extra_bits": 0},
        {"name": "ack_1024", "payload_size": 1024, "seed": 1, "jitter_pct": 0, "byte_gap_bits": 0, "ack_extra_bits": loose_ack_bits},
    ]
    for seed_idx in range(max(1, seeds)):
        cases.append(
            {
                "name": f"combo_1024_seed{seed_idx + 1}",
                "payload_size": 1024,
                "seed": seed_idx + 1,
                "jitter_pct": jitter_pct,
                "byte_gap_bits": byte_gap_bits,
                "ack_extra_bits": loose_ack_bits,
            }
        )
    return cases


def run_transport_tb_matrix(
    logs_dir: Path,
    *,
    core_clk_mhz: float,
    uart_baud: int,
    jitter_pct: int,
    byte_gap_bits: int,
    ack_mode: str,
    seeds: int,
) -> list[dict[str, object]]:
    out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{TRANSPORT_TB_TOP}.out"
    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        f"-DFPGA_UART_CLK_DIV={derive_uart_clk_div(core_clk_mhz, uart_baud)}",
        "-DTRANSPORT_UART_RXDATA_REG_TEST",
        f"-DTB_CLK_PERIOD_NS={max(1, round(1000.0 / core_clk_mhz))}",
        f"-DTB_UART_BIT_NS={max(1, round(1_000_000_000.0 / float(uart_baud)))}",
        "-s",
        TRANSPORT_TB_TOP,
        "-o",
        str(out_file),
        "-I",
        str(RTL_DIR),
        *collect_verilog(RTL_DIR),
        str(TRANSPORT_TB),
    ]
    run_logged(compile_cmd, cwd=REPO_ROOT, log_path=logs_dir / "03_transport_tb_compile.log", timeout=300)

    results: list[dict[str, object]] = []
    for case in transport_case_specs(jitter_pct=jitter_pct, byte_gap_bits=byte_gap_bits, ack_mode=ack_mode, seeds=seeds):
        case_name = str(case["name"])
        case_log = logs_dir / f"03_transport_tb_{case_name}.log"
        run_logged(
            [
                which_required("vvp"),
                str(out_file),
                f"+CASE_NAME={case_name}",
                f"+PAYLOAD_SIZE={int(case['payload_size'])}",
                f"+TEST_SEED={int(case['seed'])}",
                f"+JITTER_PCT={int(case['jitter_pct'])}",
                f"+BYTE_GAP_BITS={int(case['byte_gap_bits'])}",
                f"+ACK_EXTRA_BITS={int(case['ack_extra_bits'])}",
            ],
            cwd=ROM_DIR,
            log_path=case_log,
            timeout=300,
        )
        case_text = read_text(case_log)
        if "[TRANSPORT_TB] PASS" not in case_text:
            raise RuntimeError(f"Transport TB case failed: {case_name}; see {case_log}")
        results.append(
            {
                "name": case_name,
                "payload_size": int(case["payload_size"]),
                "seed": int(case["seed"]),
                "jitter_pct": int(case["jitter_pct"]),
                "byte_gap_bits": int(case["byte_gap_bits"]),
                "ack_extra_bits": int(case["ack_extra_bits"]),
                "log": str(case_log),
            }
        )
    return results


def run_bridge_stress_tb(logs_dir: Path) -> list[dict[str, object]]:
    out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{BRIDGE_STRESS_TB_TOP}.out"
    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DDDR3_BRIDGE_AUDIT=1",
        "-I",
        str(RTL_DIR),
        "-s",
        BRIDGE_STRESS_TB_TOP,
        "-o",
        str(out_file),
        str(RTL_DIR / "ddr3_mem_port.v"),
        str(BRIDGE_STRESS_TB),
    ]
    run_logged(compile_cmd, cwd=REPO_ROOT, log_path=logs_dir / "03_bridge_tb_compile.log", timeout=300)

    cases = [
        {"name": "25to100", "core_clk_ns": 40, "ui_clk_ns": 10, "seed": 1},
        {"name": "20to100", "core_clk_ns": 50, "ui_clk_ns": 10, "seed": 2},
        {"name": "30to100", "core_clk_ns": 33, "ui_clk_ns": 10, "seed": 3},
        {"name": "25to200", "core_clk_ns": 40, "ui_clk_ns": 5, "seed": 4},
    ]
    results: list[dict[str, object]] = []
    for case in cases:
        case_log = logs_dir / f"03_bridge_tb_{case['name']}.log"
        run_logged(
            [
                which_required("vvp"),
                str(out_file),
                f"+CORE_CLK_NS={case['core_clk_ns']}",
                f"+UI_CLK_NS={case['ui_clk_ns']}",
                "+AXI_STALL_PCT=35",
                "+RESP_LAT_MIN=1",
                "+RESP_LAT_MAX=8",
                "+OP_COUNT=256",
                f"+TEST_SEED={case['seed']}",
            ],
            cwd=REPO_ROOT,
            log_path=case_log,
            timeout=300,
        )
        case_text = read_text(case_log)
        if "[DDR3_BRIDGE_TB] PASS" not in case_text:
            raise RuntimeError(f"DDR3 bridge TB case failed: {case['name']}; see {case_log}")
        results.append({**case, "log": str(case_log)})
    return results


def run_bridge_top_sim(
    logs_dir: Path,
    *,
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    uart_baud: int = 115200,
) -> Path:
    run_logged(
        [
            sys.executable,
            str(REPO_ROOT / "fpga" / "scripts" / "build_rom_image.py"),
            "--asm",
            str(BRIDGE_STRESS_ROM),
            "--march",
            "rv32i_zicsr",
            "--define",
            "SIM_FAST_BRIDGE_STRESS=1",
            "--merge-mem-subsys",
        ],
        cwd=REPO_ROOT,
        log_path=logs_dir / "04_build_bridge_rom.log",
        timeout=300,
    )

    out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{BRIDGE_TOP_SMOKE_TB_TOP}.out"
    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        "-DENABLE_MEM_SUBSYS=1",
        "-DENABLE_DDR3=1",
        "-DL2_PASSTHROUGH=1",
        "-DENABLE_ROCC_ACCEL=0",
        "-DSMT_MODE=1",
        "-DDDR3_BRIDGE_AUDIT=1",
        f"-DTB_SHORT_TIMEOUT_NS={BRIDGE_TOP_SIM_TB_TIMEOUT_NS}",
        f"-DFPGA_SCOREBOARD_RS_DEPTH={rs_depth}",
        f"-DFPGA_SCOREBOARD_RS_IDX_W={derive_idx_width(rs_depth)}",
        f"-DFPGA_FETCH_BUFFER_DEPTH={fetch_buffer_depth}",
        f"-DFPGA_CLK_WIZ_HALF_DIV={derive_clk_wiz_half_div(core_clk_mhz)}",
        f"-DFPGA_UART_CLK_DIV={derive_uart_clk_div(core_clk_mhz, uart_baud)}",
        "-s",
        BRIDGE_TOP_SMOKE_TB_TOP,
        "-o",
        str(out_file),
        "-I",
        str(RTL_DIR),
        "-I",
        str(FPGA_RTL_DIR),
        *collect_verilog(RTL_DIR),
        *collect_verilog(FPGA_RTL_DIR),
        str(LIB_RAM_BFM),
        str(COMP_TEST_DIR / "clk_wiz_0_stub.v"),
        str(COMP_TEST_DIR / "ibufgds_stub.v"),
        str(MIG_STUB),
        str(BRIDGE_TOP_SMOKE_TB),
    ]
    run_logged(compile_cmd, cwd=REPO_ROOT, log_path=logs_dir / "05_compile_bridge_top_sim.log", timeout=300)
    sim_log = logs_dir / "06_run_bridge_top_sim.log"
    run_logged(
        [which_required("vvp"), str(out_file)],
        cwd=ROM_DIR,
        log_path=sim_log,
        timeout=BRIDGE_TOP_SIM_TIMEOUT_S,
    )
    if "[AX7203_DDR3_BRIDGE] PASS" not in read_text(sim_log):
        raise RuntimeError(f"DDR3 bridge top simulation did not pass; see {sim_log}")
    return sim_log


def run_bridge_steps_top_sim(
    logs_dir: Path,
    *,
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    uart_baud: int = 115200,
) -> Path:
    sim_uart_clk_div = 2
    run_logged(
        [
            sys.executable,
            str(REPO_ROOT / "fpga" / "scripts" / "build_rom_image.py"),
            "--asm",
            str(BRIDGE_STEPS_ROM),
            "--march",
            "rv32i_zicsr",
            "--define",
            "SIM_FAST_BRIDGE_STEPS=1",
            "--merge-mem-subsys",
        ],
        cwd=REPO_ROOT,
        log_path=logs_dir / "04_build_bridge_steps_rom.log",
        timeout=300,
    )

    out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{BRIDGE_STEPS_TOP_SMOKE_TB_TOP}.out"
    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        "-DENABLE_MEM_SUBSYS=1",
        "-DENABLE_DDR3=1",
        "-DL2_PASSTHROUGH=1",
        "-DENABLE_ROCC_ACCEL=0",
        "-DSMT_MODE=1",
        "-DDDR3_BRIDGE_AUDIT=1",
        f"-DTB_SHORT_TIMEOUT_NS={BRIDGE_STEPS_TOP_SIM_TB_TIMEOUT_NS}",
        f"-DFPGA_SCOREBOARD_RS_DEPTH={rs_depth}",
        f"-DFPGA_SCOREBOARD_RS_IDX_W={derive_idx_width(rs_depth)}",
        f"-DFPGA_FETCH_BUFFER_DEPTH={fetch_buffer_depth}",
        f"-DFPGA_CLK_WIZ_HALF_DIV={derive_clk_wiz_half_div(core_clk_mhz)}",
        f"-DFPGA_UART_CLK_DIV={sim_uart_clk_div}",
        "-s",
        BRIDGE_STEPS_TOP_SMOKE_TB_TOP,
        "-o",
        str(out_file),
        "-I",
        str(RTL_DIR),
        "-I",
        str(FPGA_RTL_DIR),
        *collect_verilog(RTL_DIR),
        *collect_verilog(FPGA_RTL_DIR),
        str(LIB_RAM_BFM),
        str(COMP_TEST_DIR / "clk_wiz_0_stub.v"),
        str(COMP_TEST_DIR / "ibufgds_stub.v"),
        str(MIG_STUB),
        str(BRIDGE_STEPS_TOP_SMOKE_TB),
    ]
    run_logged(compile_cmd, cwd=REPO_ROOT, log_path=logs_dir / "05_compile_bridge_steps_top_sim.log", timeout=300)
    sim_log = logs_dir / "06_run_bridge_steps_top_sim.log"
    run_logged(
        [which_required("vvp"), str(out_file)],
        cwd=ROM_DIR,
        log_path=sim_log,
        timeout=BRIDGE_STEPS_TOP_SIM_TIMEOUT_S,
    )
    if "[AX7203_DDR3_BSTEPS] PASS" not in read_text(sim_log):
        raise RuntimeError(f"DDR3 bridge-steps top simulation did not pass; see {sim_log}")
    return sim_log


def run_step2_only_top_sim(
    logs_dir: Path,
    *,
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    uart_baud: int = 115200,
) -> Path:
    sim_uart_clk_div = 2
    run_logged(
        [
            sys.executable,
            str(REPO_ROOT / "fpga" / "scripts" / "build_rom_image.py"),
            "--asm",
            str(STEP2_ONLY_ROM),
            "--march",
            "rv32i_zicsr",
            "--merge-mem-subsys",
        ],
        cwd=REPO_ROOT,
        log_path=logs_dir / "04_build_step2_only_rom.log",
        timeout=300,
    )

    out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{STEP2_ONLY_TOP_SMOKE_TB_TOP}.out"
    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        "-DENABLE_MEM_SUBSYS=1",
        "-DENABLE_DDR3=1",
        "-DL2_PASSTHROUGH=1",
        "-DENABLE_ROCC_ACCEL=0",
        "-DSMT_MODE=1",
        "-DDDR3_BRIDGE_AUDIT=1",
        "-DAX7203_STEP2_BEACON_DEBUG=1",
        f"-DTB_SHORT_TIMEOUT_NS={STEP2_ONLY_TOP_SIM_TB_TIMEOUT_NS}",
        f"-DFPGA_SCOREBOARD_RS_DEPTH={rs_depth}",
        f"-DFPGA_SCOREBOARD_RS_IDX_W={derive_idx_width(rs_depth)}",
        f"-DFPGA_FETCH_BUFFER_DEPTH={fetch_buffer_depth}",
        f"-DFPGA_CLK_WIZ_HALF_DIV={derive_clk_wiz_half_div(core_clk_mhz)}",
        f"-DFPGA_UART_CLK_DIV={sim_uart_clk_div}",
        "-s",
        STEP2_ONLY_TOP_SMOKE_TB_TOP,
        "-o",
        str(out_file),
        "-I",
        str(RTL_DIR),
        "-I",
        str(FPGA_RTL_DIR),
        *collect_verilog(RTL_DIR),
        *collect_verilog(FPGA_RTL_DIR),
        str(LIB_RAM_BFM),
        str(COMP_TEST_DIR / "clk_wiz_0_stub.v"),
        str(COMP_TEST_DIR / "ibufgds_stub.v"),
        str(MIG_STUB),
        str(STEP2_ONLY_TOP_SMOKE_TB),
    ]
    run_logged(compile_cmd, cwd=REPO_ROOT, log_path=logs_dir / "05_compile_step2_only_top_sim.log", timeout=300)
    sim_log = logs_dir / "06_run_step2_only_top_sim.log"
    run_logged(
        [which_required("vvp"), str(out_file)],
        cwd=ROM_DIR,
        log_path=sim_log,
        timeout=STEP2_ONLY_TOP_SIM_TIMEOUT_S,
    )
    if "[AX7203_DDR3_S2] PASS" not in read_text(sim_log):
        raise RuntimeError(f"DDR3 step2-only top simulation did not pass; see {sim_log}")
    return sim_log


def run_transport_top_sim(
    logs_dir: Path,
    *,
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    uart_baud: int = 115200,
    transport_seed: int = 1,
) -> tuple[Path, dict[str, object]]:
    manifest = materialize_transport_payload(logs_dir / "transport_payload", size_bytes=64, seed=transport_seed, stem="uart_loader_transport")
    write_hex_bytes(TRANSPORT_PAYLOAD_HEX, Path(str(manifest["bin"])).read_bytes())
    run_logged(
        [
            sys.executable,
            str(REPO_ROOT / "fpga" / "scripts" / "build_rom_image.py"),
            "--asm",
            str(TRANSPORT_ROM),
            "--march",
            "rv32i_zicsr",
            "--merge-mem-subsys",
        ],
        cwd=REPO_ROOT,
        log_path=logs_dir / "04_build_transport_rom.log",
        timeout=300,
    )

    out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{TRANSPORT_TOP_SMOKE_TB_TOP}.out"
    tb_uart_bit_ns = max(1, round(1_000_000_000.0 / float(uart_baud)))
    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        "-DENABLE_MEM_SUBSYS=1",
        "-DENABLE_DDR3=1",
        "-DL2_PASSTHROUGH=1",
        "-DENABLE_ROCC_ACCEL=0",
        "-DSMT_MODE=1",
        "-DTRANSPORT_UART_RXDATA_REG_TEST=1",
        f"-DTB_SHORT_TIMEOUT_NS={TRANSPORT_TOP_SIM_TB_TIMEOUT_NS}",
        f"-DTB_UART_BIT_NS={tb_uart_bit_ns}",
        f"-DFPGA_SCOREBOARD_RS_DEPTH={rs_depth}",
        f"-DFPGA_SCOREBOARD_RS_IDX_W={derive_idx_width(rs_depth)}",
        f"-DFPGA_FETCH_BUFFER_DEPTH={fetch_buffer_depth}",
        f"-DFPGA_CLK_WIZ_HALF_DIV={derive_clk_wiz_half_div(core_clk_mhz)}",
        f"-DFPGA_UART_CLK_DIV={derive_uart_clk_div(core_clk_mhz, uart_baud)}",
        "-s",
        TRANSPORT_TOP_SMOKE_TB_TOP,
        "-o",
        str(out_file),
        "-I",
        str(RTL_DIR),
        "-I",
        str(FPGA_RTL_DIR),
        *collect_verilog(RTL_DIR),
        *collect_verilog(FPGA_RTL_DIR),
        str(LIB_RAM_BFM),
        str(COMP_TEST_DIR / "clk_wiz_0_stub.v"),
        str(COMP_TEST_DIR / "ibufgds_stub.v"),
        str(MIG_STUB),
        str(TRANSPORT_TOP_SMOKE_TB),
    ]
    run_logged(compile_cmd, cwd=REPO_ROOT, log_path=logs_dir / "05_compile_transport_top_sim.log", timeout=300)
    sim_log = logs_dir / "06_run_transport_top_sim.log"
    run_logged(
        [
            which_required("vvp"),
            str(out_file),
            f"+PAYLOAD_SIZE={int(manifest['size_bytes'])}",
            f"+PAYLOAD_CHECKSUM={int(manifest['checksum32'])}",
        ],
        cwd=ROM_DIR,
        log_path=sim_log,
        timeout=TRANSPORT_TOP_SIM_TIMEOUT_S,
    )
    if "[AX7203_UART_TRANSPORT] PASS" not in read_text(sim_log):
        raise RuntimeError(f"Transport top simulation did not pass; see {sim_log}")
    return sim_log, manifest


def build_dhrystone_payload(
    logs_dir: Path,
    *,
    cpu_hz: int,
    runs: int,
    stem: str,
    fixed_runs: int | None = None,
) -> dict[str, object]:
    cmd = [
        sys.executable,
        str(REPO_ROOT / "fpga" / "scripts" / "build_benchmark_image.py"),
        "--benchmark",
        "dhrystone",
        "--cpu-hz",
        str(cpu_hz),
        "--dhrystone-runs",
        str(runs),
        "--ddr3-xip",
        "--emit-bin",
        "--manifest",
    ]
    if fixed_runs is not None:
        cmd.extend(["--fixed-dhrystone-runs", str(fixed_runs)])
    run_logged(
        cmd,
        cwd=REPO_ROOT,
        log_path=logs_dir / "06_build_dhrystone_payload.log",
        timeout=600,
    )
    manifest_path = BUILD_DIR / "benchmark_images" / "dhrystone" / "dhrystone_ddr3.json"
    manifest = json.loads(manifest_path.read_text(encoding="ascii"))
    return clone_manifest_outputs(manifest, logs_dir / "payload_manifests", stem)


def build_early_audit_manifest(logs_dir: Path, full_manifest: dict[str, object], *, stem: str) -> dict[str, object]:
    payload = Path(str(full_manifest["bin"])).read_bytes()[:UART_BLOCK_CHECKSUM_BYTES]
    out_dir = logs_dir / "payload_manifests"
    out_dir.mkdir(parents=True, exist_ok=True)
    bin_path = out_dir / f"{stem}.bin"
    bin_path.write_bytes(payload)
    manifest = dict(full_manifest)
    manifest["bin"] = str(bin_path)
    manifest["size_bytes"] = len(payload)
    manifest["checksum32"] = sum(payload) & 0xFFFFFFFF
    return manifest


def load_existing_early_audit_manifest(logs_dir: Path, *, stem: str = "dhrystone_loader_early_audit") -> dict[str, object]:
    full_manifest_path = BUILD_DIR / "benchmark_images" / "dhrystone" / "dhrystone_ddr3.json"
    if not full_manifest_path.exists():
        raise RuntimeError(
            f"Existing benchmark manifest not found: {full_manifest_path}. Run --loader-early-audit once first."
        )
    bin_path = logs_dir / "payload_manifests" / f"{stem}.bin"
    if not bin_path.exists():
        raise RuntimeError(
            f"Existing early-audit payload not found: {bin_path}. Run --loader-early-audit once first."
        )
    full_manifest = json.loads(full_manifest_path.read_text(encoding="ascii"))
    payload = bin_path.read_bytes()
    manifest = dict(full_manifest)
    manifest["bin"] = str(bin_path)
    manifest["size_bytes"] = len(payload)
    manifest["checksum32"] = sum(payload) & 0xFFFFFFFF
    return manifest


def early_audit_passed(result: dict[str, object]) -> bool:
    return bool(
        result.get("loader_ready_seen")
        and result.get("loader_header_magic_ok")
        and result.get("loader_load_start_seen")
        and result.get("loader_first_block_ack_seen")
        and result.get("loader_summary_seen")
        and result.get("loader_summary_ok")
        and not result.get("loader_bad_seen")
        and not result.get("loader_bad_magic_seen")
        and not result.get("loader_session_start_not_found")
    )


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_beacon_selftest_summary(path: Path, result: dict[str, object], *, build_id: str, failure_stage: str, failure_detail: str, jtag_log: Path) -> None:
    lines = [
        "Flow: AX7203 Loader Beacon Selftest",
        f"Pass: {bool(result.get('loader_beacon_selftest_pass', False)) and failure_stage == 'none'}",
        f"BuildID: {build_id}",
        f"FailureStage: {failure_stage}",
        f"FailureDetail: {failure_detail or 'none'}",
        f"SessionCount: {result.get('loader_session_count', 0)}",
        f"PassSessionCount: {result.get('loader_pass_session_count', 0)}",
        f"GoodFrames: {result.get('loader_good_frames', 0)}",
        f"BadFrames: {result.get('loader_bad_frames', 0)}",
        f"SessionClassification: {result.get('loader_session_classification', 'N/A')}",
        f"ChosenSessionIndex: {result.get('loader_chosen_session_index', 'N/A')}",
        f"ChosenSessionOffset: {fmt_optional_hex(result.get('loader_chosen_session_start_offset', 'N/A'))}",
        f"ChosenSessionReadyArg: {fmt_optional_hex(result.get('loader_chosen_session_ready_arg', 'N/A'))}",
        f"ChosenSessionFirstEvents: {','.join(result.get('loader_chosen_session_first_events', []))}",
        f"ChosenSessionMatchedPrefixLen: {result.get('loader_chosen_session_matched_prefix_len', 0)}",
        f"ChosenSessionEventCount: {result.get('loader_chosen_session_event_count', 0)}",
        f"ChosenSessionOrderValid: {result.get('loader_chosen_session_order_valid', False)}",
        f"ChosenSessionOrderError: {result.get('loader_chosen_session_order_error', '')}",
        f"CaptureFile: {result.get('uart_capture_text_file', 'N/A')}",
        f"CaptureRawFile: {result.get('uart_capture_raw_file', 'N/A')}",
        f"DecodedFile: {result.get('loader_decoded_log_path', 'N/A')}",
        f"SessionsFile: {result.get('loader_sessions_json_path', 'N/A')}",
        f"JtagLog: {jtag_log}",
    ]
    write_summary(path, lines)


def run_loader_beacon_selftest_board(
    logs_dir: Path,
    *,
    port: str,
    uart_baud: int,
    capture_seconds: int,
    vivado: str,
    env: dict[str, str],
) -> tuple[dict[str, object], str, str, str, Path]:
    capture_file = UART_BEACON_SELFTEST_CAPTURE_FILE
    capture_raw_file = UART_BEACON_SELFTEST_CAPTURE_RAW_FILE
    decoded_file = UART_BEACON_SELFTEST_CAPTURE_DECODED_FILE
    sessions_file = UART_BEACON_SELFTEST_CAPTURE_SESSIONS_FILE
    jtag_log = logs_dir / "10_program_jtag.log"
    result: dict[str, object] = {}
    build_id = "N/A"
    failure_stage = "none"
    failure_detail = ""
    try:
        import serial  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on local environment
        raise RuntimeError("pyserial is required for board beacon selftest capture") from exc
    try:
        with serial.Serial(port, uart_baud, timeout=0.05) as ser:
            ser.reset_input_buffer()
            ser.reset_output_buffer()
            raw_bytes = bytearray()
            capture_stop = threading.Event()
            capture_error: list[str] = []

            def capture_worker() -> None:
                try:
                    while not capture_stop.is_set():
                        chunk = ser.read(4096)
                        if chunk:
                            raw_bytes.extend(chunk)
                        else:
                            time.sleep(0.001)
                except Exception as exc:  # noqa: BLE001
                    capture_error.append(str(exc))

            worker = threading.Thread(target=capture_worker, name="beacon-selftest-uart-capture", daemon=True)
            worker.start()
            run_logged(
                [vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "program_ax7203_jtag.tcl")],
                cwd=REPO_ROOT,
                env=env,
                log_path=jtag_log,
                timeout=1800,
            )
            build_id = parse_build_id(BUILD_ID_FILE)
            deadline = time.monotonic() + capture_seconds
            analysis = analyze_loader_beacon_selftest_beacon(bytes(raw_bytes))
            while time.monotonic() < deadline:
                if capture_error:
                    raise RuntimeError(f"Beacon selftest UART capture failed: {capture_error[-1]}")
                analysis = analyze_loader_beacon_selftest_beacon(bytes(raw_bytes))
                if analysis.get("pass") or analysis.get("summary_seen"):
                    break
                time.sleep(0.010)
            capture_stop.set()
            worker.join(timeout=1.0)
            result = finalize_loader_beacon_selftest_capture(
                raw_bytes,
                capture_file,
                raw_log_path=capture_raw_file,
                loader_decoded_path=decoded_file,
                sessions_json_path=sessions_file,
            )
            if not bool(result.get("loader_beacon_selftest_pass", False)):
                raise RuntimeError(
                    f"Beacon selftest capture mismatch ({result.get('loader_session_classification', 'unknown')}); see {decoded_file}"
                )
    except Exception as exc:  # noqa: BLE001
        failure_stage = "uart_capture_beacon_selftest" if Path(jtag_log).exists() else "program_jtag"
        failure_detail = str(exc)
    write_beacon_selftest_summary(logs_dir / "summary.txt", result, build_id=build_id, failure_stage=failure_stage, failure_detail=failure_detail, jtag_log=jtag_log)
    return result, build_id, failure_stage, failure_detail, jtag_log


def write_early_audit_trial_summary(path: Path, trial: dict[str, object]) -> None:
    lines = [
        "Flow: AX7203 Loader Early Audit Board-Only Trial",
        f"TrialName: {trial['trial_name']}",
        f"PostJtagQuietMs: {trial['post_jtag_quiet_ms']}",
        f"HeaderSendDelayMs: {trial['header_send_delay_ms']}",
        f"BuildID: {trial.get('build_id', 'N/A')}",
        f"Pass: {trial['pass']}",
        f"FailureStage: {trial.get('failure_stage', 'none')}",
        f"FailureDetail: {trial.get('failure_detail', 'none')}",
        f"SessionStartNotFound: {trial.get('session_start_not_found', False)}",
        f"SessionClassification: {trial.get('session_classification', 'N/A')}",
        f"ChosenSessionReadyArg: {trial.get('chosen_session_ready_arg', 'N/A')}",
        f"ChosenSessionFirstEvents: {','.join(trial.get('chosen_session_first_events', []))}",
        f"HeaderByte0: {fmt_optional_hex(trial.get('header_byte0', 'N/A'))}",
        f"HeaderByte1: {fmt_optional_hex(trial.get('header_byte1', 'N/A'))}",
        f"BadMagicSeen: {trial.get('bad_magic_seen', False)}",
        f"BadMagicByteIndex: {trial.get('bad_magic_byte_index', 'N/A')}",
        f"BadReason: {trial.get('bad_reason', 'none')}",
        f"SummaryMask: {fmt_optional_hex(trial.get('summary_mask', 'N/A'))}",
        f"CaptureFile: {trial.get('capture_file', 'N/A')}",
        f"CaptureRawFile: {trial.get('capture_raw_file', 'N/A')}",
        f"DecodedFile: {trial.get('decoded_file', 'N/A')}",
        f"SessionsFile: {trial.get('sessions_file', 'N/A')}",
        f"JtagLog: {trial.get('jtag_log', 'N/A')}",
    ]
    write_summary(path, lines)


def run_loader_early_audit_board_trial(
    trial_dir: Path,
    *,
    trial_name: str,
    manifest: dict[str, object],
    port: str,
    uart_baud: int,
    capture_seconds: int,
    post_jtag_quiet_ms: int,
    header_send_delay_ms: int,
    vivado: str,
    env: dict[str, str],
) -> dict[str, object]:
    capture_file = trial_dir / "capture.txt"
    capture_raw_file = trial_dir / "capture.bin"
    decoded_file = trial_dir / "capture.loader.decoded.txt"
    sessions_file = trial_dir / "sessions.json"
    jtag_log = trial_dir / "program_jtag.log"
    trial_dir.mkdir(parents=True, exist_ok=True)
    trial: dict[str, object] = {
        "trial_name": trial_name,
        "post_jtag_quiet_ms": post_jtag_quiet_ms,
        "header_send_delay_ms": header_send_delay_ms,
        "build_id": "N/A",
        "pass": False,
        "failure_stage": "none",
        "failure_detail": "none",
        "session_start_not_found": False,
        "session_classification": "N/A",
        "chosen_session_ready_arg": "N/A",
        "chosen_session_first_events": [],
        "header_byte0": "N/A",
        "header_byte1": "N/A",
        "bad_magic_seen": False,
        "bad_magic_byte_index": "N/A",
        "bad_reason": "none",
        "summary_mask": "N/A",
        "capture_file": str(capture_file),
        "capture_raw_file": str(capture_raw_file),
        "decoded_file": str(decoded_file),
        "sessions_file": str(sessions_file),
        "jtag_log": str(jtag_log),
    }
    try:
        import serial  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on local environment
        raise RuntimeError("pyserial is required for board early-audit sweep") from exc
    try:
        with serial.Serial(port, uart_baud, timeout=0.05) as ser:
            ser.reset_input_buffer()
            ser.reset_output_buffer()
            run_logged(
                [vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "program_ax7203_jtag.tcl")],
                cwd=REPO_ROOT,
                env=env,
                log_path=jtag_log,
                timeout=1800,
            )
            trial["build_id"] = parse_build_id(BUILD_ID_FILE)
            result = run_uart_loader_early_audit_capture(
                None,
                manifest,
                capture_seconds,
                capture_file,
                uart_baud=uart_baud,
                raw_log_path=capture_raw_file,
                loader_decoded_path=decoded_file,
                sessions_json_path=sessions_file,
                ser=ser,
                wait_for_fresh_ready_only=True,
                allow_blind_header_fallback=False,
                post_jtag_quiet_ms=post_jtag_quiet_ms,
                header_send_delay_ms=header_send_delay_ms,
                training_count=EARLY_AUDIT_TRAINING_COUNT_BOARD,
            )
        trial["session_start_not_found"] = bool(result.get("loader_session_start_not_found", False))
        trial["session_classification"] = result.get("loader_session_classification", "N/A")
        trial["chosen_session_ready_arg"] = result.get("loader_chosen_session_ready_arg", "N/A")
        trial["chosen_session_first_events"] = list(result.get("loader_chosen_session_first_events", []))
        trial["header_byte0"] = result.get("loader_header_byte0", "N/A")
        trial["header_byte1"] = result.get("loader_header_byte1", "N/A")
        trial["bad_magic_seen"] = bool(result.get("loader_bad_magic_seen", False))
        trial["bad_magic_byte_index"] = result.get("loader_bad_magic_byte_index", "N/A")
        trial["bad_reason"] = result.get("bad_reason", "none")
        trial["summary_mask"] = result.get("loader_summary_mask", "N/A")
        trial["pass"] = early_audit_passed(result)
    except Exception as exc:  # noqa: BLE001
        trial["failure_stage"] = "program_jtag" if not Path(jtag_log).exists() else "uart_load_and_capture_early_audit"
        trial["failure_detail"] = str(exc)
    write_early_audit_trial_summary(trial_dir / "summary.txt", trial)
    return trial


def run_loader_early_audit_board_sweep(
    logs_dir: Path,
    *,
    manifest: dict[str, object],
    port: str,
    uart_baud: int,
    capture_seconds: int,
    vivado: str,
    env: dict[str, str],
) -> int:
    logs_dir.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, object]] = []
    winning_trial = "none"
    for trial_name, post_jtag_quiet_ms, header_send_delay_ms in EARLY_AUDIT_SWEEP_TRIALS:
        trial_dir = logs_dir / trial_name
        trial = run_loader_early_audit_board_trial(
            trial_dir,
            trial_name=trial_name,
            manifest=manifest,
            port=port,
            uart_baud=uart_baud,
            capture_seconds=capture_seconds,
            post_jtag_quiet_ms=post_jtag_quiet_ms,
            header_send_delay_ms=header_send_delay_ms,
            vivado=vivado,
            env=env,
        )
        results.append(trial)
        if trial["pass"]:
            winning_trial = trial_name
            break
    sweep_summary = {
        "EarlyStopOnPass": True,
        "WinningTrial": winning_trial,
        "Trials": results,
    }
    write_json(logs_dir / "sweep_summary.json", sweep_summary)
    lines = [
        "Flow: AX7203 Loader Early Audit Board-Only 3-Point Sweep",
        f"WinningTrial: {winning_trial}",
        "EarlyStopOnPass: True",
    ]
    for trial in results:
        lines.extend(
            [
                "",
                f"TrialName: {trial['trial_name']}",
                f"PostJtagQuietMs: {trial['post_jtag_quiet_ms']}",
                f"HeaderSendDelayMs: {trial['header_send_delay_ms']}",
                f"BuildID: {trial.get('build_id', 'N/A')}",
                f"Pass: {trial['pass']}",
                f"FailureStage: {trial.get('failure_stage', 'none')}",
                f"FailureDetail: {trial.get('failure_detail', 'none')}",
                f"SessionStartNotFound: {trial.get('session_start_not_found', False)}",
                f"SessionClassification: {trial.get('session_classification', 'N/A')}",
                f"ChosenSessionFirstEvents: {','.join(trial.get('chosen_session_first_events', []))}",
                f"HeaderByte0: {fmt_optional_hex(trial.get('header_byte0', 'N/A'))}",
                f"HeaderByte1: {fmt_optional_hex(trial.get('header_byte1', 'N/A'))}",
                f"BadMagicSeen: {trial.get('bad_magic_seen', False)}",
                f"BadMagicByteIndex: {trial.get('bad_magic_byte_index', 'N/A')}",
                f"BadReason: {trial.get('bad_reason', 'none')}",
                f"SummaryMask: {fmt_optional_hex(trial.get('summary_mask', 'N/A'))}",
                f"TrialSummary: {logs_dir / trial['trial_name'] / 'summary.txt'}",
            ]
        )
    write_summary(logs_dir / "sweep_summary.txt", lines)
    return 0 if winning_trial != "none" else 1


def parse_fetch_probe(text: str) -> dict[str, object]:
    lines = [line.strip() for line in text.splitlines() if line.strip().startswith("M0D ")]
    result: dict[str, object] = {"lines": lines, "last_line": lines[-1] if lines else "", "classification": "no_probe"}
    if not lines:
        return result
    last = lines[-1]
    fields = {
        key: int(value, 16)
        for key, value in re.findall(r"\b(RQ|AC|RS|LS|IM|ID|IC|F|S|C|G)=([0-9A-Fa-f]+)", last)
    }
    for key in ("A", "D", "PC", "N", "P", "O", "I", "U", "V"):
        match = re.search(rf"\b{key}=([0-9A-Fa-f]{{8}})", last)
        if match:
            fields[key] = int(match.group(1), 16)
    result["fields"] = fields
    if fields.get("RQ", 0) == 0:
        result["classification"] = "pc_jump_or_stage_if_no_m0_request"
    elif fields.get("AC", 0) == 0:
        result["classification"] = "mem_subsys_ddr3_arb_no_accept"
    elif fields.get("LS", 0) != 0 and fields.get("IC", 0) != 0:
        result["classification"] = "m0_fetch_path_reached_icache_response"
    elif fields.get("RS", 0) == 0:
        result["classification"] = "ddr3_bridge_or_mig_no_response"
    elif fields.get("IM", 0) == 0:
        result["classification"] = "icache_no_mem_request_count"
    elif fields.get("ID", 0) == 0:
        result["classification"] = "mem_subsys_response_not_seen_by_icache"
    elif fields.get("IC", 0) == 0:
        result["classification"] = "icache_refill_no_cpu_response"
    else:
        result["classification"] = "m0_fetch_path_reached_icache_response"
    return result


def analyze_loader_bad_block(text: str, payload: bytes) -> dict[str, object]:
    matches = re.findall(r"LOAD BAD BLK=([0-9A-Fa-f]{8}) W=([0-9A-Fa-f]{8}) R=([0-9A-Fa-f]{8})", text)
    if not matches:
        return {}
    block_hex, write_hex, read_hex = matches[-1]
    block_idx = int(block_hex, 16)
    write_sum = int(write_hex, 16)
    read_sum = int(read_hex, 16)
    start = block_idx * BLOCK_CHECKSUM_BYTES
    end = min(start + BLOCK_CHECKSUM_BYTES, len(payload))
    host_sum = sum(payload[start:end]) & 0xFFFFFFFF
    if write_sum != host_sum:
        cause = "uart_rx_or_loader_pack_corruption"
    elif read_sum != write_sum:
        cause = "ddr3_write_read_path_corruption"
    else:
        cause = "indeterminate_block_match"
    return {
        "block_index": block_idx,
        "host_checksum32": host_sum,
        "write_checksum32": write_sum,
        "read_checksum32": read_sum,
        "cause": cause,
    }


def analyze_loader_bad_checksum(text: str) -> dict[str, int]:
    matches = re.findall(r"LOAD BAD CHECKSUM E=([0-9A-Fa-f]{8}) R=([0-9A-Fa-f]{8})", text)
    if not matches:
        return {}
    expected_hex, actual_hex = matches[-1]
    expected = int(expected_hex, 16)
    actual = int(actual_hex, 16)
    return {
        "expected_checksum32": expected,
        "actual_checksum32": actual,
        "delta_signed": actual - expected,
    }


def analyze_loader_write_blocks(text: str, payload: bytes) -> dict[str, object]:
    matches = re.findall(r"WRBLK=([0-9A-Fa-f]{8}) C=([0-9A-Fa-f]{8})", text)
    if not matches:
        return {}
    first_mismatch: dict[str, int] | None = None
    dumped_blocks = 0
    for block_hex, device_hex in matches:
        dumped_blocks += 1
        block_idx = int(block_hex, 16)
        device_sum = int(device_hex, 16)
        start = block_idx * BLOCK_CHECKSUM_BYTES
        end = min(start + BLOCK_CHECKSUM_BYTES, len(payload))
        host_sum = sum(payload[start:end]) & 0xFFFFFFFF
        if first_mismatch is None and host_sum != device_sum:
            first_mismatch = {
                "block_index": block_idx,
                "host_checksum32": host_sum,
                "device_checksum32": device_sum,
            }
    result: dict[str, object] = {"dumped_blocks": dumped_blocks}
    if first_mismatch is not None:
        result.update(first_mismatch)
    return result


def parse_benchmark_counters(text: str) -> dict[str, str]:
    cycles = re.findall(r"BENCH CYCLES:\s+([0-9]+)", text)
    instret = re.findall(r"BENCH INSTRET:\s+([0-9]+)", text)
    ipc_x1000 = re.findall(r"BENCH IPC_X1000:\s+([0-9]+)", text)
    return {
        "cycles": cycles[-1] if cycles else "",
        "instret": instret[-1] if instret else "",
        "ipc_x1000": ipc_x1000[-1] if ipc_x1000 else "",
    }


def slice_after_last_token(text: str, token: str) -> str:
    idx = text.rfind(token)
    return text[idx:] if idx >= 0 else text


def analyze_bridge_steps_bad_line(text: str) -> dict[str, object]:
    matches = re.findall(
        r"(BSTEP BAD S=([0-9]) N=([0-9]) A=([0-9A-Fa-f]{8}) E=([0-9A-Fa-f]{8}) R=([0-9A-Fa-f]{8}) "
        r"LW_A=([0-9A-Fa-f]{8}) LW_D=([0-9A-Fa-f]{8}) DR=([01]) ID=([01]) ST=([0-9A-Fa-f]{8}))",
        text,
    )
    if not matches:
        return {}
    line, step_s, words_s, addr_s, exp_s, act_s, last_addr_s, last_data_s, drain_s, idle_s, status_s = matches[-1]
    return {
        "line": line,
        "step": int(step_s),
        "words": int(words_s),
        "addr": int(addr_s, 16),
        "expected": int(exp_s, 16),
        "actual": int(act_s, 16),
        "last_write_addr": int(last_addr_s, 16),
        "last_write_data": int(last_data_s, 16),
        "drain_ready": int(drain_s),
        "bridge_idle": int(idle_s),
        "status_word": int(status_s, 16),
    }


def step2_event_name(evt_type: int) -> str:
    names = {
        STEP2_EVT_READY: "READY",
        STEP2_EVT_C1_OK: "C1_OK",
        STEP2_EVT_C2_OK: "C2_OK",
        STEP2_EVT_C3_START: "C3_START",
        STEP2_EVT_C3_AFTER: "C3_AFTER",
        STEP2_EVT_C3_OK: "C3_OK",
        STEP2_EVT_C4_START: "C4_START",
        STEP2_EVT_C4_AFTER: "C4_AFTER",
        STEP2_EVT_C4_OK: "C4_OK",
        STEP2_EVT_C5_START: "C5_START",
        STEP2_EVT_C5_AFTER: "C5_AFTER",
        STEP2_EVT_C5_OK: "C5_OK",
        STEP2_EVT_BAD: "BAD",
        STEP2_EVT_CAL_FAIL: "CAL_FAIL",
        STEP2_EVT_TRAP: "TRAP",
        STEP2_EVT_SUMMARY: "SUMMARY",
    }
    return names.get(evt_type, f"TYPE_{evt_type:02X}")


def analyze_step2_only_beacon(raw_bytes: bytes) -> dict[str, object]:
    ready_seen = False
    case1_pass = False
    case2_pass = False
    saw_start_case3 = False
    saw_after_write_case3 = False
    case3_pass = False
    saw_start_case4 = False
    saw_after_write_case4 = False
    case4_pass = False
    saw_start_case5 = False
    saw_after_write_case5 = False
    case5_pass = False
    summary_seen = False
    summary_mask: int | None = None
    saw_bad = False
    saw_trap = False
    saw_cal_fail = False
    bad_detail: dict[str, object] = {}
    last_progress_detail: dict[str, object] = {}
    good_frames = 0
    bad_frames = 0
    dropped_duplicates = 0
    session_active = False
    session_complete = False
    seen_seq: set[int] = set()
    decoded_lines: list[str] = []

    idx = 0
    while idx + 4 < len(raw_bytes):
        if raw_bytes[idx] != STEP2_BEACON_SOF:
            idx += 1
            continue

        seq = raw_bytes[idx + 1]
        evt_type = raw_bytes[idx + 2]
        evt_arg = raw_bytes[idx + 3]
        evt_chk = raw_bytes[idx + 4]
        expected_chk = STEP2_BEACON_SOF ^ seq ^ evt_type ^ evt_arg
        event_name = step2_event_name(evt_type)

        if evt_chk != expected_chk:
            bad_frames += 1
            decoded_lines.append(
                f"BAD_FRAME off=0x{idx:04X} seq=0x{seq:02X} type=0x{evt_type:02X} arg=0x{evt_arg:02X} "
                f"chk=0x{evt_chk:02X} exp=0x{expected_chk:02X}"
            )
            idx += 1
            continue

        line = f"EVT off=0x{idx:04X} seq=0x{seq:02X} {event_name} arg=0x{evt_arg:02X}"
        decoded_lines.append(line)

        if evt_type == STEP2_EVT_READY:
            ready_seen = True
            case1_pass = False
            case2_pass = False
            saw_start_case3 = False
            saw_after_write_case3 = False
            case3_pass = False
            saw_start_case4 = False
            saw_after_write_case4 = False
            case4_pass = False
            saw_start_case5 = False
            saw_after_write_case5 = False
            case5_pass = False
            summary_seen = False
            summary_mask = None
            saw_bad = False
            saw_trap = False
            saw_cal_fail = False
            bad_detail = {}
            last_progress_detail = {"kind": "ready", "line": line}
            good_frames = 1
            bad_frames = 0
            dropped_duplicates = 0
            seen_seq = {seq}
            session_active = True
            session_complete = False
            idx += 5
            continue

        if not session_active or session_complete:
            idx += 5
            continue

        if seq in seen_seq:
            dropped_duplicates += 1
            decoded_lines.append(
                f"DUP_FRAME off=0x{idx:04X} seq=0x{seq:02X} {event_name} arg=0x{evt_arg:02X}"
            )
            idx += 5
            continue

        seen_seq.add(seq)
        good_frames += 1

        if evt_type == STEP2_EVT_C1_OK:
            case1_pass = True
            last_progress_detail = {"kind": "ok", "case": 1, "line": line}
        elif evt_type == STEP2_EVT_C2_OK:
            case2_pass = True
            last_progress_detail = {"kind": "ok", "case": 2, "line": line}
        elif evt_type == STEP2_EVT_C3_START:
            saw_start_case3 = True
            last_progress_detail = {"kind": "start", "case": 3, "line": line}
        elif evt_type == STEP2_EVT_C3_AFTER:
            saw_after_write_case3 = True
            last_progress_detail = {"kind": "after_write", "case": 3, "line": line}
        elif evt_type == STEP2_EVT_C3_OK:
            case3_pass = True
            last_progress_detail = {"kind": "ok", "case": 3, "line": line}
        elif evt_type == STEP2_EVT_C4_START:
            saw_start_case4 = True
            last_progress_detail = {"kind": "start", "case": 4, "line": line}
        elif evt_type == STEP2_EVT_C4_AFTER:
            saw_after_write_case4 = True
            last_progress_detail = {"kind": "after_write", "case": 4, "line": line}
        elif evt_type == STEP2_EVT_C4_OK:
            case4_pass = True
            last_progress_detail = {"kind": "ok", "case": 4, "line": line}
        elif evt_type == STEP2_EVT_C5_START:
            saw_start_case5 = True
            last_progress_detail = {"kind": "start", "case": 5, "line": line}
        elif evt_type == STEP2_EVT_C5_AFTER:
            saw_after_write_case5 = True
            last_progress_detail = {"kind": "after_write", "case": 5, "line": line}
        elif evt_type == STEP2_EVT_C5_OK:
            case5_pass = True
            last_progress_detail = {"kind": "ok", "case": 5, "line": line}
        elif evt_type == STEP2_EVT_BAD:
            saw_bad = True
            bad_detail = {
                "case": evt_arg & 0x0F,
                "phase": (evt_arg >> 4) & 0x0F,
                "line": line,
            }
            last_progress_detail = {
                "kind": "bad",
                "case": evt_arg & 0x0F,
                "phase": (evt_arg >> 4) & 0x0F,
                "line": line,
            }
        elif evt_type == STEP2_EVT_CAL_FAIL:
            saw_cal_fail = True
            last_progress_detail = {"kind": "cal_fail", "line": line}
        elif evt_type == STEP2_EVT_TRAP:
            saw_trap = True
            last_progress_detail = {"kind": "trap", "line": line}
        elif evt_type == STEP2_EVT_SUMMARY:
            summary_seen = True
            summary_mask = evt_arg
            last_progress_detail = {"kind": "summary", "line": line}
            session_complete = True

        idx += 5

    all_ok_seen = bool(summary_seen and summary_mask is not None and (summary_mask & 0x1F) == 0x1F and (summary_mask & 0x80) == 0)
    return {
        "ready_seen": ready_seen,
        "saw_start_case1": False,
        "case1_pass": case1_pass,
        "saw_start_case2": False,
        "case2_pass": case2_pass,
        "saw_start_case3": saw_start_case3,
        "saw_after_write_case3": saw_after_write_case3,
        "case3_pass": case3_pass,
        "saw_start_case4": saw_start_case4,
        "saw_after_write_case4": saw_after_write_case4,
        "case4_pass": case4_pass,
        "saw_start_case5": saw_start_case5,
        "saw_after_write_case5": saw_after_write_case5,
        "case5_pass": case5_pass,
        "summary_seen": summary_seen,
        "summary_mask": summary_mask,
        "all_ok_seen": all_ok_seen,
        "saw_bad": saw_bad,
        "saw_trap": saw_trap,
        "saw_cal_fail": saw_cal_fail,
        "bad_reason": "step2_bad" if saw_bad else ("step2_trap" if saw_trap else ("step2_cal_fail" if saw_cal_fail else "none")),
        "bad_detail": bad_detail,
        "last_phase_detail": {},
        "last_progress_detail": last_progress_detail,
        "good_frames": good_frames,
        "bad_frames": bad_frames,
        "dropped_duplicate_frames": dropped_duplicates,
        "decoded_text": "\n".join(decoded_lines) + ("\n" if decoded_lines else ""),
    }


def analyze_step2_only_sim_log(text: str) -> dict[str, object]:
    summary_match = re.findall(r"EVT SUMMARY seq=\d+ mask=([0-9A-Fa-f]{2})", text)
    pass_line = re.findall(r"(\[AX7203_DDR3_S2\] PASS .*)", text)
    pass_text = pass_line[-1] if pass_line else ""
    summary_mask = int(summary_match[-1], 16) if summary_match else (int(re.findall(r"mask=([0-9A-Fa-f]{2})", pass_text)[-1], 16) if re.findall(r"mask=([0-9A-Fa-f]{2})", pass_text) else None)
    good_frames = int(re.findall(r"good=(\d+)", pass_text)[-1]) if re.findall(r"good=(\d+)", pass_text) else 0
    bad_frames = int(re.findall(r"bad=(\d+)", pass_text)[-1]) if re.findall(r"bad=(\d+)", pass_text) else 0
    dropped_duplicates = int(re.findall(r"dup=(\d+)", pass_text)[-1]) if re.findall(r"dup=(\d+)", pass_text) else 0
    all_ok_seen = bool("[AX7203_DDR3_S2] PASS" in text and summary_mask is not None and (summary_mask & 0x1F) == 0x1F and (summary_mask & 0x80) == 0)
    return {
        "ready_seen": "[AX7203_DDR3_S2] EVT READY" in text,
        "saw_start_case1": False,
        "case1_pass": "[AX7203_DDR3_S2] EVT C1_OK" in text,
        "saw_start_case2": False,
        "case2_pass": "[AX7203_DDR3_S2] EVT C2_OK" in text,
        "saw_start_case3": "[AX7203_DDR3_S2] EVT C3_START" in text,
        "saw_after_write_case3": "[AX7203_DDR3_S2] EVT C3_AFTER" in text,
        "case3_pass": "[AX7203_DDR3_S2] EVT C3_OK" in text,
        "saw_start_case4": "[AX7203_DDR3_S2] EVT C4_START" in text,
        "saw_after_write_case4": "[AX7203_DDR3_S2] EVT C4_AFTER" in text,
        "case4_pass": "[AX7203_DDR3_S2] EVT C4_OK" in text,
        "saw_start_case5": "[AX7203_DDR3_S2] EVT C5_START" in text,
        "saw_after_write_case5": "[AX7203_DDR3_S2] EVT C5_AFTER" in text,
        "case5_pass": "[AX7203_DDR3_S2] EVT C5_OK" in text,
        "summary_seen": bool(summary_match),
        "summary_mask": summary_mask,
        "all_ok_seen": all_ok_seen,
        "saw_bad": "[AX7203_DDR3_S2] EVT BAD" in text,
        "saw_trap": "[AX7203_DDR3_S2] EVT TRAP" in text,
        "saw_cal_fail": "[AX7203_DDR3_S2] EVT CAL_FAIL" in text,
        "bad_reason": "step2_bad" if "[AX7203_DDR3_S2] EVT BAD" in text else ("step2_trap" if "[AX7203_DDR3_S2] EVT TRAP" in text else ("step2_cal_fail" if "[AX7203_DDR3_S2] EVT CAL_FAIL" in text else "none")),
        "bad_detail": {},
        "last_phase_detail": {},
        "last_progress_detail": {"kind": "sim_pass", "line": "[AX7203_DDR3_S2] PASS"} if "[AX7203_DDR3_S2] PASS" in text else {},
        "good_frames": good_frames,
        "bad_frames": bad_frames,
        "dropped_duplicate_frames": dropped_duplicates,
        "capture_bytes": 0,
        "decoded_log_path": "",
    }


def loader_event_name(evt_type: int) -> str:
    names = {
        LOADER_EVT_READY: "READY",
        LOADER_EVT_LOAD_START: "LOAD_START",
        LOADER_EVT_BLOCK_ACK: "BLOCK_ACK",
        LOADER_EVT_BLOCK_NACK: "BLOCK_NACK",
        LOADER_EA_EVT_HDR_B0_RX: "HDR_B0_RX",
        LOADER_EA_EVT_HDR_B1_RX: "HDR_B1_RX",
        LOADER_EA_EVT_HDR_B2_RX: "HDR_B2_RX",
        LOADER_EA_EVT_HDR_B3_RX: "HDR_B3_RX",
        LOADER_EA_EVT_HDR_MAGIC_OK: "HDR_MAGIC_OK",
        LOADER_EA_EVT_IDLE_OK: "IDLE_OK",
        LOADER_EA_EVT_TRAIN_START: "TRAIN_START",
        LOADER_EA_EVT_TRAIN_DONE: "TRAIN_DONE",
        LOADER_EA_EVT_FLUSH_DONE: "FLUSH_DONE",
        LOADER_EA_EVT_HEADER_ENTER: "HEADER_ENTER",
        LOADER_EVT_READ_OK: "READ_OK",
        LOADER_EVT_LOAD_OK: "LOAD_OK",
        LOADER_EVT_JUMP: "JUMP",
        LOADER_EVT_CAL_FAIL: "CAL_FAIL",
        LOADER_EVT_BAD_MAGIC: "BAD_MAGIC",
        LOADER_EVT_CHECKSUM_FAIL: "CHECKSUM_FAIL",
        LOADER_EVT_READBACK_FAIL: "READBACK_FAIL",
        LOADER_EVT_READBACK_BLOCK_FAIL: "READBACK_BLOCK_FAIL",
        LOADER_EVT_RX_OVERRUN: "RX_OVERRUN",
        LOADER_EVT_RX_FRAME_ERR: "RX_FRAME_ERR",
        LOADER_EVT_DRAIN_TIMEOUT: "DRAIN_TIMEOUT",
        LOADER_EVT_SIZE_TOO_BIG: "SIZE_TOO_BIG",
        LOADER_EA_EVT_TRAIN_TIMEOUT: "TRAIN_TIMEOUT",
        LOADER_EA_EVT_FLUSH_TIMEOUT: "FLUSH_TIMEOUT",
        LOADER_EVT_TRAP: "TRAP",
        LOADER_EVT_SUMMARY: "SUMMARY",
    }
    return names.get(evt_type, f"TYPE_{evt_type:02X}")


def loader_summary_ok(summary_mask: object) -> bool:
    return isinstance(summary_mask, int) and (summary_mask & 0x1F) == 0x1F and (summary_mask & LOADER_SUM_ANY_BAD) == 0


def loader_early_audit_summary_ok(summary_mask: object) -> bool:
    return isinstance(summary_mask, int) and (summary_mask & 0x0F) == 0x0F and (summary_mask & LOADER_SUM_ANY_BAD) == 0


def loader_prefix_target_ok(loader_result: dict[str, object], target: int) -> bool:
    max_block_ack = loader_result.get("max_block_ack_arg")
    return (
        bool(loader_result.get("ready_seen", False))
        and bool(loader_result.get("load_start_seen", False))
        and int(loader_result.get("block_ack_events", 0)) >= target
        and isinstance(max_block_ack, int)
        and max_block_ack >= (target - 1)
        and int(loader_result.get("block_nack_events", 0)) == 0
        and not bool(loader_result.get("bad_seen", False))
    )


def split_loader_session(
    events: list[tuple[int, int, int, int]],
    *,
    require_ready_seq0: bool,
) -> dict[str, object]:
    session_start_idx = -1
    session_ready_seq: int | None = None
    session_start_offset: int | None = None
    for idx, (offset, seq, evt_type, _evt_arg) in enumerate(events):
        if evt_type == LOADER_EVT_READY and seq == 0:
            session_start_idx = idx
            session_ready_seq = seq
            session_start_offset = offset
    if session_start_idx < 0 and not require_ready_seq0:
        for idx, (offset, seq, evt_type, _evt_arg) in enumerate(events):
            if evt_type == LOADER_EVT_READY:
                session_start_idx = idx
                session_ready_seq = seq
                session_start_offset = offset
    if session_start_idx < 0:
        return {
            "session_events": [],
            "pre_session_frame_count": len(events),
            "session_start_offset": None,
            "session_ready_seq": None,
            "session_start_not_found": True,
        }
    return {
        "session_events": events[session_start_idx:],
        "pre_session_frame_count": session_start_idx,
        "session_start_offset": session_start_offset,
        "session_ready_seq": session_ready_seq,
        "session_start_not_found": False,
    }


def decode_loader_beacon_frames(raw_bytes: bytes) -> dict[str, object]:
    events: list[tuple[int, int, int, int]] = []
    decoded_lines: list[str] = []
    passthrough = bytearray()
    bad_frames = 0
    idx = 0
    while idx < len(raw_bytes):
        if raw_bytes[idx] != STEP2_BEACON_SOF:
            passthrough.append(raw_bytes[idx])
            idx += 1
            continue
        if idx + 4 >= len(raw_bytes):
            break
        seq = raw_bytes[idx + 1]
        evt_type = raw_bytes[idx + 2]
        evt_arg = raw_bytes[idx + 3]
        evt_chk = raw_bytes[idx + 4]
        exp_chk = STEP2_BEACON_SOF ^ seq ^ evt_type ^ evt_arg
        if evt_chk != exp_chk:
            bad_frames += 1
            decoded_lines.append(
                f"BAD_FRAME off=0x{idx:04X} seq=0x{seq:02X} type=0x{evt_type:02X} "
                f"arg=0x{evt_arg:02X} chk=0x{evt_chk:02X} exp=0x{exp_chk:02X}"
            )
            passthrough.append(raw_bytes[idx])
            idx += 1
            continue
        decoded_lines.append(f"EVT off=0x{idx:04X} seq=0x{seq:02X} {loader_event_name(evt_type)} arg=0x{evt_arg:02X}")
        events.append((idx, seq, evt_type, evt_arg))
        idx += 5
    return {
        "events": events,
        "decoded_lines": decoded_lines,
        "passthrough_bytes": bytes(passthrough),
        "bad_frames": bad_frames,
    }


def reduce_loader_events(
    events: list[tuple[int, int, int, int]],
    *,
    pre_session_frame_count: int,
    session_start_offset: int | None,
    session_ready_seq: int | None,
    session_start_not_found: bool,
    decoded_lines: list[str] | None = None,
    bad_frames: int = 0,
) -> dict[str, object]:
    ready_seen = False
    load_start_seen = False
    read_ok_seen = False
    load_ok_seen = False
    jump_seen = False
    summary_seen = False
    summary_mask: int | None = None
    bad_seen = False
    bad_code: int | None = None
    bad_block: int | None = None
    first_bad_event_offset: int | None = None
    block_ack_events = 0
    block_nack_events = 0
    max_block_ack_arg: int | None = None
    good_frames = 0
    dropped_duplicates = 0
    seen_seq: set[int] = set()

    for event_idx, (_offset, seq, evt_type, evt_arg) in enumerate(events):
        if evt_type == LOADER_EVT_READY:
            ready_seen = True
        if session_start_not_found:
            continue
        if seq in seen_seq:
            dropped_duplicates += 1
            continue
        seen_seq.add(seq)
        good_frames += 1

        if evt_type == LOADER_EVT_READY:
            pass
        elif evt_type == LOADER_EVT_LOAD_START:
            load_start_seen = True
        elif evt_type == LOADER_EVT_BLOCK_ACK:
            block_ack_events += 1
            if max_block_ack_arg is None or evt_arg > max_block_ack_arg:
                max_block_ack_arg = evt_arg
        elif evt_type == LOADER_EVT_BLOCK_NACK:
            block_nack_events += 1
        elif evt_type == LOADER_EVT_READ_OK:
            read_ok_seen = True
        elif evt_type == LOADER_EVT_LOAD_OK:
            load_ok_seen = True
        elif evt_type == LOADER_EVT_JUMP:
            jump_seen = True
        elif evt_type == LOADER_EVT_SUMMARY:
            summary_seen = True
            summary_mask = evt_arg
        else:
            bad_seen = True
            bad_code = evt_type
            bad_block = evt_arg
            if first_bad_event_offset is None:
                first_bad_event_offset = event_idx

    bad_reason = loader_event_name(bad_code) if bad_seen and bad_code is not None else "none"
    return {
        "ready_seen": ready_seen,
        "load_start_seen": load_start_seen,
        "read_ok_seen": read_ok_seen,
        "load_ok_seen": load_ok_seen,
        "jump_seen": jump_seen,
        "summary_seen": summary_seen,
        "summary_mask": summary_mask,
        "summary_ok_seen": loader_summary_ok(summary_mask),
        "bad_seen": bad_seen,
        "bad_code": bad_code,
        "bad_block": bad_block,
        "first_bad_event_offset": first_bad_event_offset,
        "bad_reason": bad_reason,
        "block_ack_events": block_ack_events,
        "block_nack_events": block_nack_events,
        "max_block_ack_arg": max_block_ack_arg,
        "good_frames": good_frames,
        "bad_frames": bad_frames,
        "dropped_duplicate_frames": dropped_duplicates,
        "pre_session_frame_count": pre_session_frame_count,
        "session_start_offset": session_start_offset,
        "session_ready_seq": session_ready_seq,
        "session_start_not_found": session_start_not_found,
        "decoded_text": "\n".join(decoded_lines or []) + ("\n" if decoded_lines else ""),
    }


def analyze_loader_beacon(raw_bytes: bytes) -> dict[str, object]:
    decoded = decode_loader_beacon_frames(raw_bytes)
    session = split_loader_session(decoded["events"], require_ready_seq0=False)
    if bool(session["session_start_not_found"]) and decoded["events"]:
        session = {
            "session_events": decoded["events"],
            "pre_session_frame_count": 0,
            "session_start_offset": decoded["events"][0][0],
            "session_ready_seq": None,
            "session_start_not_found": False,
        }
    result = reduce_loader_events(
        session["session_events"],
        pre_session_frame_count=int(session["pre_session_frame_count"]),
        session_start_offset=session["session_start_offset"],
        session_ready_seq=session["session_ready_seq"],
        session_start_not_found=bool(session["session_start_not_found"]),
        decoded_lines=list(decoded["decoded_lines"]),
        bad_frames=int(decoded["bad_frames"]),
    )
    result["passthrough_bytes"] = decoded["passthrough_bytes"]
    return result


def analyze_loader_sim_log(text: str) -> dict[str, object]:
    events: list[tuple[int, int, int, int]] = []
    decoded_lines: list[str] = []
    for event_idx, (seq_s, type_s, arg_s) in enumerate(
        re.findall(
            r"\[AX7203_DDR3_LOADER_EVT\]\s+seq=([0-9A-Fa-f]{2})\s+type=([0-9A-Fa-f]{2})\s+arg=([0-9A-Fa-f]{2})",
            text,
        )
    ):
        seq = int(seq_s, 16)
        evt_type = int(type_s, 16)
        evt_arg = int(arg_s, 16)
        decoded_lines.append(f"EVT seq=0x{seq:02X} {loader_event_name(evt_type)} arg=0x{evt_arg:02X}")
        events.append((event_idx * 5, seq, evt_type, evt_arg))
    session = split_loader_session(events, require_ready_seq0=False)
    if bool(session["session_start_not_found"]) and events:
        session = {
            "session_events": events,
            "pre_session_frame_count": 0,
            "session_start_offset": events[0][0],
            "session_ready_seq": None,
            "session_start_not_found": False,
        }
    result = reduce_loader_events(
        session["session_events"],
        pre_session_frame_count=int(session["pre_session_frame_count"]),
        session_start_offset=session["session_start_offset"],
        session_ready_seq=session["session_ready_seq"],
        session_start_not_found=bool(session["session_start_not_found"]),
        decoded_lines=decoded_lines,
        bad_frames=0,
    )
    result["passthrough_bytes"] = b""
    result["capture_bytes"] = 0
    result["saw_exec_pass"] = ("DDR3 EXEC PASS" in text) or bool(re.search(r"\bexec_pass=1\b", text))
    result["decoded_log_path"] = ""
    return result


def reduce_loader_early_audit_events(
    events: list[tuple[int, int, int, int]],
    *,
    pre_session_frame_count: int,
    session_start_offset: int | None,
    session_ready_seq: int | None,
    session_start_not_found: bool,
    decoded_lines: list[str] | None = None,
    bad_frames: int = 0,
) -> dict[str, object]:
    header_bytes: list[int | None] = [None, None, None, None]
    ready_seen = False
    idle_ok_seen = False
    train_start_seen = False
    train_done_seen = False
    train_done_count: int | None = None
    flush_done_seen = False
    flush_done_count: int | None = None
    header_enter_seen = False
    train_timeout_seen = False
    train_timeout_count: int | None = None
    flush_timeout_seen = False
    flush_timeout_count: int | None = None
    header_magic_ok = False
    load_start_seen = False
    first_block_ack_seen = False
    summary_seen = False
    summary_mask: int | None = None
    bad_magic_seen = False
    bad_magic_byte_index: int | None = None
    bad_seen = False
    bad_code: int | None = None
    seen_seq: set[int] = set()
    good_frames = 0
    dropped_duplicates = 0

    for _offset, seq, evt_type, evt_arg in events:
        if evt_type == LOADER_EVT_READY:
            ready_seen = True
        if session_start_not_found:
            continue
        if seq in seen_seq:
            dropped_duplicates += 1
            continue
        seen_seq.add(seq)
        good_frames += 1
        if evt_type == LOADER_EA_EVT_HDR_B0_RX:
            header_bytes[0] = evt_arg
        elif evt_type == LOADER_EA_EVT_IDLE_OK:
            idle_ok_seen = True
        elif evt_type == LOADER_EA_EVT_TRAIN_START:
            train_start_seen = True
        elif evt_type == LOADER_EA_EVT_TRAIN_DONE:
            train_done_seen = True
            train_done_count = evt_arg
        elif evt_type == LOADER_EA_EVT_FLUSH_DONE:
            flush_done_seen = True
            flush_done_count = evt_arg
        elif evt_type == LOADER_EA_EVT_HEADER_ENTER:
            header_enter_seen = True
        elif evt_type == LOADER_EA_EVT_HDR_B1_RX:
            header_bytes[1] = evt_arg
        elif evt_type == LOADER_EA_EVT_HDR_B2_RX:
            header_bytes[2] = evt_arg
        elif evt_type == LOADER_EA_EVT_HDR_B3_RX:
            header_bytes[3] = evt_arg
        elif evt_type == LOADER_EA_EVT_HDR_MAGIC_OK:
            header_magic_ok = True
        elif evt_type == LOADER_EVT_LOAD_START:
            load_start_seen = True
        elif evt_type == LOADER_EVT_BLOCK_ACK and evt_arg == 0:
            first_block_ack_seen = True
        elif evt_type == LOADER_EVT_BAD_MAGIC:
            bad_magic_seen = True
            bad_magic_byte_index = evt_arg
            bad_seen = True
            bad_code = evt_type
        elif evt_type == LOADER_EA_EVT_TRAIN_TIMEOUT:
            train_timeout_seen = True
            train_timeout_count = evt_arg
            bad_seen = True
            bad_code = evt_type
        elif evt_type == LOADER_EA_EVT_FLUSH_TIMEOUT:
            flush_timeout_seen = True
            flush_timeout_count = evt_arg
            bad_seen = True
            bad_code = evt_type
        elif evt_type == LOADER_EVT_SUMMARY:
            summary_seen = True
            summary_mask = evt_arg
        elif evt_type == LOADER_EVT_TRAP:
            bad_seen = True
            bad_code = evt_type
        elif evt_type in (
            LOADER_EVT_BLOCK_NACK,
            LOADER_EVT_CAL_FAIL,
            LOADER_EVT_CHECKSUM_FAIL,
            LOADER_EVT_READBACK_FAIL,
            LOADER_EVT_READBACK_BLOCK_FAIL,
            LOADER_EVT_RX_OVERRUN,
            LOADER_EVT_RX_FRAME_ERR,
            LOADER_EVT_DRAIN_TIMEOUT,
            LOADER_EVT_SIZE_TOO_BIG,
        ):
            bad_seen = True
            bad_code = evt_type

    return {
        "ready_seen": ready_seen,
        "idle_ok_seen": idle_ok_seen,
        "train_start_seen": train_start_seen,
        "train_done_seen": train_done_seen,
        "train_done_count": train_done_count,
        "flush_done_seen": flush_done_seen,
        "flush_done_count": flush_done_count,
        "header_enter_seen": header_enter_seen,
        "train_timeout_seen": train_timeout_seen,
        "train_timeout_count": train_timeout_count,
        "flush_timeout_seen": flush_timeout_seen,
        "flush_timeout_count": flush_timeout_count,
        "header_byte0": header_bytes[0],
        "header_byte1": header_bytes[1],
        "header_byte2": header_bytes[2],
        "header_byte3": header_bytes[3],
        "header_magic_ok": header_magic_ok,
        "load_start_seen": load_start_seen,
        "first_block_ack_seen": first_block_ack_seen,
        "summary_seen": summary_seen,
        "summary_mask": summary_mask,
        "summary_ok_seen": loader_early_audit_summary_ok(summary_mask),
        "bad_magic_seen": bad_magic_seen,
        "bad_magic_byte_index": bad_magic_byte_index,
        "bad_seen": bad_seen,
        "bad_code": bad_code,
        "bad_reason": loader_event_name(bad_code) if bad_code is not None else "none",
        "good_frames": good_frames,
        "bad_frames": bad_frames,
        "dropped_duplicate_frames": dropped_duplicates,
        "pre_session_frame_count": pre_session_frame_count,
        "session_start_offset": session_start_offset,
        "session_ready_seq": session_ready_seq,
        "session_start_not_found": session_start_not_found,
        "decoded_text": "\n".join(decoded_lines or []) + ("\n" if decoded_lines else ""),
    }


def validate_loader_early_audit_session_order(
    dedup_events: list[tuple[int, int, int, int]],
) -> tuple[bool, str]:
    seen: set[int] = set()
    singletons = {
        LOADER_EVT_READY,
        LOADER_EA_EVT_IDLE_OK,
        LOADER_EA_EVT_TRAIN_START,
        LOADER_EA_EVT_TRAIN_DONE,
        LOADER_EA_EVT_TRAIN_TIMEOUT,
        LOADER_EA_EVT_FLUSH_DONE,
        LOADER_EA_EVT_FLUSH_TIMEOUT,
        LOADER_EA_EVT_HEADER_ENTER,
        LOADER_EA_EVT_HDR_MAGIC_OK,
        LOADER_EVT_LOAD_START,
        LOADER_EVT_SUMMARY,
    }

    for _offset, _seq, evt_type, _evt_arg in dedup_events:
        if evt_type in singletons:
            if evt_type in seen:
                return False, f"duplicate_{loader_event_name(evt_type)}"
            seen.add(evt_type)
        if evt_type == LOADER_EA_EVT_TRAIN_DONE and LOADER_EA_EVT_TRAIN_START not in seen:
            return False, "train_done_before_train_start"
        if evt_type == LOADER_EA_EVT_TRAIN_TIMEOUT and LOADER_EA_EVT_TRAIN_START not in seen:
            return False, "train_timeout_before_train_start"
        if evt_type == LOADER_EA_EVT_FLUSH_DONE and not (
            LOADER_EA_EVT_TRAIN_DONE in seen or LOADER_EA_EVT_TRAIN_TIMEOUT in seen
        ):
            return False, "flush_done_before_train_done"
        if evt_type == LOADER_EA_EVT_FLUSH_TIMEOUT and not (
            LOADER_EA_EVT_TRAIN_DONE in seen or LOADER_EA_EVT_TRAIN_TIMEOUT in seen
        ):
            return False, "flush_timeout_before_train_done"
        if evt_type == LOADER_EA_EVT_HEADER_ENTER and not (
            LOADER_EA_EVT_FLUSH_DONE in seen or LOADER_EA_EVT_FLUSH_TIMEOUT in seen
        ):
            return False, "header_enter_before_flush_done"
        if evt_type == LOADER_EA_EVT_HDR_B0_RX and LOADER_EA_EVT_HEADER_ENTER not in seen:
            return False, "hdr_b0_before_header_enter"
        if evt_type == LOADER_EA_EVT_HDR_B1_RX and LOADER_EA_EVT_HDR_B0_RX not in seen:
            return False, "hdr_b1_before_hdr_b0"
        if evt_type == LOADER_EA_EVT_HDR_B2_RX and LOADER_EA_EVT_HDR_B1_RX not in seen:
            return False, "hdr_b2_before_hdr_b1"
        if evt_type == LOADER_EA_EVT_HDR_B3_RX and LOADER_EA_EVT_HDR_B2_RX not in seen:
            return False, "hdr_b3_before_hdr_b2"
        if evt_type == LOADER_EA_EVT_HDR_MAGIC_OK and LOADER_EA_EVT_HDR_B3_RX not in seen:
            return False, "hdr_magic_ok_before_hdr_b3"
        if evt_type == LOADER_EVT_LOAD_START and LOADER_EA_EVT_HDR_MAGIC_OK not in seen:
            return False, "load_start_before_hdr_magic_ok"
        if evt_type == LOADER_EVT_BLOCK_ACK and LOADER_EVT_LOAD_START not in seen:
            return False, "block_ack_before_load_start"
    return True, ""


def summarize_loader_early_audit_session(events: list[tuple[int, int, int, int]], session_index: int) -> dict[str, object]:
    header_bytes: list[int | None] = [None, None, None, None]
    seen_seq: set[int] = set()
    dedup_events: list[tuple[int, int, int, int]] = []
    bad_magic_seen = False
    bad_magic_byte_index: int | None = None
    summary_mask: int | None = None
    bad_code: int | None = None
    idle_ok_seen = False
    train_start_seen = False
    train_done_seen = False
    train_done_count: int | None = None
    flush_done_seen = False
    flush_done_count: int | None = None
    header_enter_seen = False
    train_timeout_seen = False
    train_timeout_count: int | None = None
    flush_timeout_seen = False
    flush_timeout_count: int | None = None
    ready_arg: int | None = None

    for offset, seq, evt_type, evt_arg in events:
        if seq in seen_seq:
            continue
        seen_seq.add(seq)
        dedup_events.append((offset, seq, evt_type, evt_arg))
        if evt_type == LOADER_EVT_READY:
            ready_arg = evt_arg
        elif evt_type == LOADER_EA_EVT_IDLE_OK:
            idle_ok_seen = True
        elif evt_type == LOADER_EA_EVT_TRAIN_START:
            train_start_seen = True
        elif evt_type == LOADER_EA_EVT_TRAIN_DONE:
            train_done_seen = True
            train_done_count = evt_arg
        elif evt_type == LOADER_EA_EVT_FLUSH_DONE:
            flush_done_seen = True
            flush_done_count = evt_arg
        elif evt_type == LOADER_EA_EVT_HEADER_ENTER:
            header_enter_seen = True
        elif evt_type == LOADER_EA_EVT_HDR_B0_RX:
            header_bytes[0] = evt_arg
        elif evt_type == LOADER_EA_EVT_HDR_B1_RX:
            header_bytes[1] = evt_arg
        elif evt_type == LOADER_EA_EVT_HDR_B2_RX:
            header_bytes[2] = evt_arg
        elif evt_type == LOADER_EA_EVT_HDR_B3_RX:
            header_bytes[3] = evt_arg
        elif evt_type == LOADER_EVT_BAD_MAGIC:
            bad_magic_seen = True
            bad_magic_byte_index = evt_arg
            bad_code = evt_type
        elif evt_type == LOADER_EA_EVT_TRAIN_TIMEOUT:
            train_timeout_seen = True
            train_timeout_count = evt_arg
            bad_code = evt_type
        elif evt_type == LOADER_EA_EVT_FLUSH_TIMEOUT:
            flush_timeout_seen = True
            flush_timeout_count = evt_arg
            bad_code = evt_type
        elif evt_type == LOADER_EVT_SUMMARY:
            summary_mask = evt_arg
        elif evt_type == LOADER_EVT_TRAP:
            bad_code = evt_type
        elif evt_type in (
            LOADER_EVT_BLOCK_NACK,
            LOADER_EVT_CAL_FAIL,
            LOADER_EVT_CHECKSUM_FAIL,
            LOADER_EVT_READBACK_FAIL,
            LOADER_EVT_READBACK_BLOCK_FAIL,
            LOADER_EVT_RX_OVERRUN,
            LOADER_EVT_RX_FRAME_ERR,
            LOADER_EVT_DRAIN_TIMEOUT,
            LOADER_EVT_SIZE_TOO_BIG,
        ):
            bad_code = evt_type

    first_event_types = [loader_event_name(evt_type) for _offset, _seq, evt_type, _arg in dedup_events[:8]]
    header_magic_ok = any(evt_type == LOADER_EA_EVT_HDR_MAGIC_OK for _offset, _seq, evt_type, _arg in dedup_events)
    load_start_seen = any(evt_type == LOADER_EVT_LOAD_START for _offset, _seq, evt_type, _arg in dedup_events)
    first_block_ack_seen = any(
        evt_type == LOADER_EVT_BLOCK_ACK and evt_arg == 0 for _offset, _seq, evt_type, evt_arg in dedup_events
    )
    summary_seen = summary_mask is not None
    header_rx_count = sum(
        1
        for _offset, _seq, evt_type, _arg in dedup_events
        if evt_type in (
            LOADER_EA_EVT_HDR_B0_RX,
            LOADER_EA_EVT_HDR_B1_RX,
            LOADER_EA_EVT_HDR_B2_RX,
            LOADER_EA_EVT_HDR_B3_RX,
        )
    )
    event_order_valid, event_order_error = validate_loader_early_audit_session_order(dedup_events)

    if not dedup_events:
        classification = "empty_session"
    elif not event_order_valid:
        classification = "beacon_transport_corruption"
    elif header_magic_ok and load_start_seen and first_block_ack_seen and loader_early_audit_summary_ok(summary_mask):
        classification = "pass"
    elif train_timeout_seen:
        classification = "train_timeout"
    elif flush_timeout_seen:
        classification = "flush_timeout"
    elif any(
        evt_type == LOADER_EVT_RX_OVERRUN for _offset, _seq, evt_type, _arg in dedup_events
    ) and not header_magic_ok:
        classification = "rx_overrun_before_magic_complete"
    elif (
        header_bytes[0] in (0x00, 0x4D, 0x4B)
        or header_bytes[1] == 0x31
    ):
        classification = "leading_zero_or_shifted_magic"
    elif bad_code == LOADER_EVT_TRAP:
        classification = "trap_fail"
    elif bad_magic_seen:
        classification = "magic_byte_fail"
    elif header_enter_seen and header_rx_count == 0:
        classification = "stuck_before_header_byte0"
    elif header_rx_count > 0 and not header_magic_ok:
        classification = "magic_byte_fail"
    elif flush_done_seen and not header_enter_seen:
        classification = "stuck_in_flush"
    elif train_done_seen and not (flush_done_seen or flush_timeout_seen):
        classification = "stuck_in_flush"
    elif train_start_seen and not (train_done_seen or train_timeout_seen):
        classification = "stuck_in_train"
    elif idle_ok_seen and not train_start_seen:
        classification = "stuck_in_train"
    elif summary_seen:
        classification = "ready_then_summary_only"
    elif not idle_ok_seen:
        classification = "stuck_before_idle_ok"
    else:
        classification = "other"

    return {
        "session_index": session_index,
        "start_offset": dedup_events[0][0] if dedup_events else None,
        "ready_seq": dedup_events[0][1] if dedup_events else None,
        "ready_arg": ready_arg,
        "first_event_types": first_event_types,
        "idle_ok_seen": idle_ok_seen,
        "train_start_seen": train_start_seen,
        "train_done_seen": train_done_seen,
        "train_done_count": train_done_count,
        "flush_done_seen": flush_done_seen,
        "flush_done_count": flush_done_count,
        "header_enter_seen": header_enter_seen,
        "train_timeout_seen": train_timeout_seen,
        "train_timeout_count": train_timeout_count,
        "flush_timeout_seen": flush_timeout_seen,
        "flush_timeout_count": flush_timeout_count,
        "header_byte0": header_bytes[0],
        "header_byte1": header_bytes[1],
        "header_byte2": header_bytes[2],
        "header_byte3": header_bytes[3],
        "header_magic_ok": header_magic_ok,
        "load_start_seen": load_start_seen,
        "first_block_ack_seen": first_block_ack_seen,
        "bad_magic_seen": bad_magic_seen,
        "bad_magic_byte_index": bad_magic_byte_index,
        "summary_mask": summary_mask,
        "event_count": len(dedup_events),
        "classification": classification,
        "bad_code": bad_code,
        "event_order_valid": event_order_valid,
        "event_order_error": event_order_error,
    }


def loader_early_audit_session_progress_key(session: dict[str, object]) -> tuple[int, ...]:
    header_rx_count = sum(
        1
        for key in ("header_byte0", "header_byte1", "header_byte2", "header_byte3")
        if isinstance(session.get(key), int)
    )
    return (
        1 if bool(session.get("header_magic_ok")) and bool(session.get("load_start_seen")) and bool(session.get("first_block_ack_seen")) and loader_early_audit_summary_ok(session.get("summary_mask")) else 0,
        1 if bool(session.get("first_block_ack_seen")) else 0,
        1 if bool(session.get("load_start_seen")) else 0,
        1 if bool(session.get("header_magic_ok")) else 0,
        header_rx_count,
        1 if bool(session.get("header_enter_seen")) else 0,
        1 if bool(session.get("flush_done_seen")) or bool(session.get("flush_timeout_seen")) else 0,
        1 if bool(session.get("train_done_seen")) or bool(session.get("train_timeout_seen")) else 0,
        1 if bool(session.get("train_start_seen")) else 0,
        1 if bool(session.get("idle_ok_seen")) else 0,
        1 if isinstance(session.get("summary_mask"), int) else 0,
        1 if bool(session.get("bad_magic_seen")) or session.get("bad_code") is not None else 0,
        int(session.get("event_count", 0)),
        int(session.get("start_offset", -1)),
    )


def build_loader_early_audit_sessions(events: list[tuple[int, int, int, int]]) -> list[dict[str, object]]:
    sessions: list[dict[str, object]] = []
    current: list[tuple[int, int, int, int]] = []
    prev_ready_sig: tuple[int, int] | None = None
    for offset, seq, evt_type, evt_arg in events:
        if evt_type == LOADER_EVT_READY:
            ready_sig = (seq, evt_arg)
            if current and prev_ready_sig != ready_sig:
                sessions.append(summarize_loader_early_audit_session(current, len(sessions)))
                current = []
            prev_ready_sig = ready_sig
        current.append((offset, seq, evt_type, evt_arg))
    if current:
        sessions.append(summarize_loader_early_audit_session(current, len(sessions)))
    return sessions


def choose_loader_early_audit_session(
    sessions: list[dict[str, object]],
    *,
    session_start_offset: int | None,
    session_ready_seq: int | None,
) -> dict[str, object] | None:
    candidates: list[dict[str, object]] = []
    for item in sessions:
        start_offset = item.get("start_offset")
        if not isinstance(start_offset, int):
            continue
        if session_start_offset is not None and start_offset < session_start_offset:
            continue
        candidates.append(item)
    if not candidates and session_ready_seq is not None:
        for item in sessions:
            if item.get("ready_seq") == session_ready_seq:
                candidates.append(item)
    if not candidates:
        candidates = [item for item in sessions if isinstance(item.get("start_offset"), int)]
    if not candidates:
        return None
    return max(candidates, key=loader_early_audit_session_progress_key)


def analyze_loader_early_audit_beacon(raw_bytes: bytes) -> dict[str, object]:
    decoded = decode_loader_beacon_frames(raw_bytes)
    sessions = build_loader_early_audit_sessions(decoded["events"])
    session = split_loader_session(decoded["events"], require_ready_seq0=True)
    result = reduce_loader_early_audit_events(
        session["session_events"],
        pre_session_frame_count=int(session["pre_session_frame_count"]),
        session_start_offset=session["session_start_offset"],
        session_ready_seq=session["session_ready_seq"],
        session_start_not_found=bool(session["session_start_not_found"]),
        decoded_lines=list(decoded["decoded_lines"]),
        bad_frames=int(decoded["bad_frames"]),
    )
    result["passthrough_bytes"] = decoded["passthrough_bytes"]
    result["sessions"] = sessions
    chosen_session = choose_loader_early_audit_session(
        sessions,
        session_start_offset=session["session_start_offset"],
        session_ready_seq=session["session_ready_seq"],
    )
    result["chosen_session_index"] = chosen_session.get("session_index") if isinstance(chosen_session, dict) else None
    result["chosen_session_start_offset"] = chosen_session.get("start_offset") if isinstance(chosen_session, dict) else None
    result["chosen_session_ready_arg"] = chosen_session.get("ready_arg") if isinstance(chosen_session, dict) else None
    result["chosen_session_first_event_types"] = chosen_session.get("first_event_types", []) if isinstance(chosen_session, dict) else []
    result["chosen_session_order_valid"] = chosen_session.get("event_order_valid", False) if isinstance(chosen_session, dict) else False
    result["chosen_session_order_error"] = chosen_session.get("event_order_error", "") if isinstance(chosen_session, dict) else ""
    result["session_classification"] = chosen_session.get("classification", "session_start_not_found" if bool(session["session_start_not_found"]) else "other") if isinstance(chosen_session, dict) else ("session_start_not_found" if bool(session["session_start_not_found"]) else "other")
    return result


def analyze_loader_early_audit_sim_log(text: str) -> dict[str, object]:
    events: list[tuple[int, int, int, int]] = []
    decoded_lines: list[str] = []
    for event_idx, (seq_s, type_s, arg_s) in enumerate(
        re.findall(
            r"\[AX7203_DDR3_LOADER_EVT\]\s+seq=([0-9A-Fa-f]{2})\s+type=([0-9A-Fa-f]{2})\s+arg=([0-9A-Fa-f]{2})",
            text,
        )
    ):
        seq = int(seq_s, 16)
        evt_type = int(type_s, 16)
        evt_arg = int(arg_s, 16)
        decoded_lines.append(f"EVT seq=0x{seq:02X} {loader_event_name(evt_type)} arg=0x{evt_arg:02X}")
        events.append((event_idx * 5, seq, evt_type, evt_arg))
    sessions = build_loader_early_audit_sessions(events)
    session = split_loader_session(events, require_ready_seq0=True)
    result = reduce_loader_early_audit_events(
        session["session_events"],
        pre_session_frame_count=int(session["pre_session_frame_count"]),
        session_start_offset=session["session_start_offset"],
        session_ready_seq=session["session_ready_seq"],
        session_start_not_found=bool(session["session_start_not_found"]),
        decoded_lines=decoded_lines,
        bad_frames=0,
    )
    result["passthrough_bytes"] = b""
    result["capture_bytes"] = 0
    result["decoded_log_path"] = ""
    result["sessions"] = sessions
    chosen_session = choose_loader_early_audit_session(
        sessions,
        session_start_offset=session["session_start_offset"],
        session_ready_seq=session["session_ready_seq"],
    )
    result["chosen_session_index"] = chosen_session.get("session_index") if isinstance(chosen_session, dict) else None
    result["chosen_session_start_offset"] = chosen_session.get("start_offset") if isinstance(chosen_session, dict) else None
    result["chosen_session_ready_arg"] = chosen_session.get("ready_arg") if isinstance(chosen_session, dict) else None
    result["chosen_session_first_event_types"] = chosen_session.get("first_event_types", []) if isinstance(chosen_session, dict) else []
    result["chosen_session_order_valid"] = chosen_session.get("event_order_valid", False) if isinstance(chosen_session, dict) else False
    result["chosen_session_order_error"] = chosen_session.get("event_order_error", "") if isinstance(chosen_session, dict) else ""
    result["session_classification"] = chosen_session.get("classification", "session_start_not_found" if bool(session["session_start_not_found"]) else "other") if isinstance(chosen_session, dict) else ("session_start_not_found" if bool(session["session_start_not_found"]) else "other")
    return result


def collapse_exact_duplicate_beacon_frames(
    events: list[tuple[int, int, int, int]]
) -> tuple[list[tuple[int, int, int, int]], int]:
    collapsed: list[tuple[int, int, int, int]] = []
    duplicate_count = 0
    for item in events:
        if collapsed and item[1:] == collapsed[-1][1:]:
            duplicate_count += 1
            continue
        collapsed.append(item)
    return collapsed, duplicate_count


def summarize_loader_beacon_selftest_session(
    events: list[tuple[int, int, int, int]],
    session_index: int,
) -> dict[str, object]:
    collapsed_events, duplicate_frame_count = collapse_exact_duplicate_beacon_frames(events)
    dedup_events: list[tuple[int, int, int, int]] = []
    seen_seq: dict[int, tuple[int, int]] = {}
    ready_arg: int | None = None
    mismatch_detail = ""
    matched_prefix_len = 0
    for offset, seq, evt_type, evt_arg in collapsed_events:
        prev = seen_seq.get(seq)
        if prev is not None:
            mismatch_detail = f"duplicate_seq_{seq:02X}_{loader_event_name(evt_type)}_{evt_arg:02X}"
            break
        seen_seq[seq] = (evt_type, evt_arg)
        dedup_events.append((offset, seq, evt_type, evt_arg))
        if evt_type == LOADER_EVT_READY and ready_arg is None:
            ready_arg = evt_arg

    for idx, (_offset, _seq, evt_type, evt_arg) in enumerate(dedup_events):
        if idx >= len(BEACON_SELFTEST_EXPECTED_SEQUENCE):
            mismatch_detail = f"extra_event_{loader_event_name(evt_type)}"
            break
        exp_type, exp_arg = BEACON_SELFTEST_EXPECTED_SEQUENCE[idx]
        if evt_type != exp_type or evt_arg != exp_arg:
            mismatch_detail = (
                f"idx{idx}_{loader_event_name(evt_type)}_{evt_arg:02X}"
                f"_expected_{loader_event_name(exp_type)}_{exp_arg:02X}"
            )
            break
        matched_prefix_len += 1

    first_event_types = [loader_event_name(evt_type) for _offset, _seq, evt_type, _arg in dedup_events[:8]]
    pass_seen = (
        matched_prefix_len == len(BEACON_SELFTEST_EXPECTED_SEQUENCE)
        and len(dedup_events) == len(BEACON_SELFTEST_EXPECTED_SEQUENCE)
        and mismatch_detail == ""
    )
    classification = "pass" if pass_seen else ("beacon_transport_corruption" if mismatch_detail else "incomplete_sequence")
    return {
        "session_index": session_index,
        "start_offset": dedup_events[0][0] if dedup_events else None,
        "ready_seq": dedup_events[0][1] if dedup_events else None,
        "ready_arg": ready_arg,
        "first_event_types": first_event_types,
        "matched_prefix_len": matched_prefix_len,
        "event_count": len(dedup_events),
        "duplicate_frame_count": duplicate_frame_count,
        "event_order_valid": mismatch_detail == "",
        "event_order_error": mismatch_detail,
        "classification": classification,
        "pass_seen": pass_seen,
        "summary_seen": any(evt_type == LOADER_EVT_SUMMARY for _offset, _seq, evt_type, _arg in dedup_events),
    }


def build_loader_beacon_selftest_sessions(events: list[tuple[int, int, int, int]]) -> list[dict[str, object]]:
    sessions: list[dict[str, object]] = []
    current: list[tuple[int, int, int, int]] = []
    for item in events:
        if item[2] == LOADER_EVT_READY:
            if current and any(evt_type == LOADER_EVT_SUMMARY for _offset, _seq, evt_type, _arg in current):
                sessions.append(summarize_loader_beacon_selftest_session(current, len(sessions)))
                current = [item]
                continue
        if current:
            current.append(item)
        else:
            current = [item]
    if current:
        sessions.append(summarize_loader_beacon_selftest_session(current, len(sessions)))
    return sessions


def loader_beacon_selftest_session_progress_key(session: dict[str, object]) -> tuple[int, ...]:
    return (
        1 if bool(session.get("pass_seen")) else 0,
        int(session.get("matched_prefix_len", 0)),
        1 if bool(session.get("summary_seen")) else 0,
        int(session.get("event_count", 0)),
        int(session.get("start_offset", -1)),
    )


def choose_loader_beacon_selftest_session(sessions: list[dict[str, object]]) -> dict[str, object] | None:
    candidates = [item for item in sessions if isinstance(item.get("start_offset"), int)]
    if not candidates:
        return None
    return max(candidates, key=loader_beacon_selftest_session_progress_key)


def analyze_loader_beacon_selftest_events(
    events: list[tuple[int, int, int, int]],
    *,
    decoded_lines: list[str],
    bad_frames: int,
    passthrough_bytes: bytes,
) -> dict[str, object]:
    sessions = build_loader_beacon_selftest_sessions(events)
    chosen_session = choose_loader_beacon_selftest_session(sessions)
    pass_session_count = sum(1 for item in sessions if item.get("pass_seen"))
    overall_pass = (
        bad_frames == 0
        and len(sessions) == 1
        and pass_session_count == 1
        and isinstance(chosen_session, dict)
        and bool(chosen_session.get("pass_seen"))
    )
    classification = (
        "pass"
        if overall_pass
        else chosen_session.get("classification", "no_ready_session")
        if isinstance(chosen_session, dict)
        else "no_ready_session"
    )
    if bad_frames > 0 and classification == "pass":
        classification = "bad_frame"
    elif bad_frames > 0 and classification == "no_ready_session":
        classification = "bad_frame"
    return {
        "pass": overall_pass,
        "session_count": len(sessions),
        "pass_session_count": pass_session_count,
        "bad_frames": bad_frames,
        "good_frames": len(events),
        "decoded_text": "\n".join(decoded_lines) + ("\n" if decoded_lines else ""),
        "passthrough_bytes": passthrough_bytes,
        "sessions": sessions,
        "chosen_session_index": chosen_session.get("session_index") if isinstance(chosen_session, dict) else None,
        "chosen_session_start_offset": chosen_session.get("start_offset") if isinstance(chosen_session, dict) else None,
        "chosen_session_ready_arg": chosen_session.get("ready_arg") if isinstance(chosen_session, dict) else None,
        "chosen_session_first_event_types": chosen_session.get("first_event_types", []) if isinstance(chosen_session, dict) else [],
        "chosen_session_matched_prefix_len": chosen_session.get("matched_prefix_len", 0) if isinstance(chosen_session, dict) else 0,
        "chosen_session_event_count": chosen_session.get("event_count", 0) if isinstance(chosen_session, dict) else 0,
        "chosen_session_order_valid": chosen_session.get("event_order_valid", False) if isinstance(chosen_session, dict) else False,
        "chosen_session_order_error": chosen_session.get("event_order_error", "") if isinstance(chosen_session, dict) else "",
        "session_classification": classification,
        "summary_seen": bool(isinstance(chosen_session, dict) and chosen_session.get("summary_seen")),
    }


def analyze_loader_beacon_selftest_beacon(raw_bytes: bytes) -> dict[str, object]:
    decoded = decode_loader_beacon_frames(raw_bytes)
    return analyze_loader_beacon_selftest_events(
        decoded["events"],
        decoded_lines=list(decoded["decoded_lines"]),
        bad_frames=int(decoded["bad_frames"]),
        passthrough_bytes=decoded["passthrough_bytes"],
    )


def analyze_loader_beacon_selftest_sim_log(text: str) -> dict[str, object]:
    events: list[tuple[int, int, int, int]] = []
    decoded_lines: list[str] = []
    for event_idx, (seq_s, type_s, arg_s) in enumerate(
        re.findall(
            r"\[AX7203_DDR3_LOADER_EVT\]\s+seq=([0-9A-Fa-f]{2})\s+type=([0-9A-Fa-f]{2})\s+arg=([0-9A-Fa-f]{2})",
            text,
        )
    ):
        seq = int(seq_s, 16)
        evt_type = int(type_s, 16)
        evt_arg = int(arg_s, 16)
        decoded_lines.append(f"EVT seq=0x{seq:02X} {loader_event_name(evt_type)} arg=0x{evt_arg:02X}")
        events.append((event_idx * 5, seq, evt_type, evt_arg))
    result = analyze_loader_beacon_selftest_events(
        events,
        decoded_lines=decoded_lines,
        bad_frames=0,
        passthrough_bytes=b"",
    )
    result["capture_bytes"] = 0
    result["decoded_log_path"] = ""
    return result


def capture_bridge_audit_stream(
    ser,
    capture_seconds: int,
    log_path: Path,
    *,
    reset_buffers: bool = True,
) -> dict[str, object]:
    text_bytes = bytearray()
    ready_seen = False
    ok_count = 0
    saw_bad = False
    bad_reason = "none"
    last_bad_line = ""

    if reset_buffers:
        ser.reset_input_buffer()
        ser.reset_output_buffer()
    start = time.monotonic()
    deadline = start + capture_seconds
    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            text_bytes.extend(chunk)
            text = text_bytes.decode("latin1", errors="ignore")
            ready_seen = "BRIDGE READY" in text
            ok_count = text.count("BRIDGE OK")
            bad_matches = re.findall(r"BRIDGE BAD BLK=.*", text)
            if bad_matches:
                saw_bad = True
                bad_reason = "bridge_bad_compare"
                last_bad_line = bad_matches[-1]
                break
            if ok_count >= 2:
                break
        else:
            time.sleep(0.001)

    text = text_bytes.decode("latin1", errors="ignore")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(text, encoding="latin1", errors="ignore")
    return {
        "ready_seen": ready_seen,
        "ok_count": ok_count,
        "saw_bad": saw_bad,
        "bad_reason": bad_reason,
        "last_bad_line": last_bad_line,
        "capture_bytes": len(text_bytes),
    }


def capture_bridge_audit_steps_stream(
    ser,
    capture_seconds: int,
    log_path: Path,
    *,
    reset_buffers: bool = True,
) -> dict[str, object]:
    text_bytes = bytearray()
    ready_seen = False
    step1_pass = False
    step2_pass = False
    step3_2_pass = False
    step3_4_pass = False
    step3_pass = False
    all_ok_seen = False
    saw_bad = False
    bad_reason = "none"
    bad_detail: dict[str, object] = {}

    if reset_buffers:
        ser.reset_input_buffer()
        ser.reset_output_buffer()
    start = time.monotonic()
    deadline = start + capture_seconds
    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            text_bytes.extend(chunk)
            text = text_bytes.decode("latin1", errors="ignore")
            ready_seen = "BSTEP READY" in text
            step1_pass = "BSTEP OK S=1 N=1" in text
            step2_pass = "BSTEP OK S=2 N=2" in text
            step3_2_pass = "BSTEP OK S=3 N=2" in text
            step3_4_pass = "BSTEP OK S=3 N=4" in text
            step3_pass = step3_2_pass and step3_4_pass
            all_ok_seen = "BSTEP ALL OK" in text
            bad_detail = analyze_bridge_steps_bad_line(text)
            if bad_detail:
                saw_bad = True
                bad_reason = "bridge_steps_bad"
                break
            if all_ok_seen:
                break
        else:
            time.sleep(0.001)

    text = text_bytes.decode("latin1", errors="ignore")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(text, encoding="latin1", errors="ignore")
    return {
        "ready_seen": ready_seen,
        "step1_pass": step1_pass,
        "step2_pass": step2_pass,
        "step3_2_pass": step3_2_pass,
        "step3_4_pass": step3_4_pass,
        "step3_pass": step3_pass,
        "all_ok_seen": all_ok_seen,
        "saw_bad": saw_bad,
        "bad_reason": bad_reason,
        "bad_detail": bad_detail,
        "capture_bytes": len(text_bytes),
    }


def capture_step2_only_stream(
    ser,
    capture_seconds: int,
    log_path: Path,
    *,
    reset_buffers: bool = True,
) -> dict[str, object]:
    raw_bytes = bytearray()
    analysis = analyze_step2_only_beacon(b"")

    if reset_buffers:
        ser.reset_input_buffer()
        ser.reset_output_buffer()
    start = time.monotonic()
    deadline = start + capture_seconds
    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            raw_bytes.extend(chunk)
            analysis = analyze_step2_only_beacon(bytes(raw_bytes))
            if analysis.get("summary_seen"):
                break
        else:
            time.sleep(0.001)

    analysis = analyze_step2_only_beacon(bytes(raw_bytes))
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_bytes(bytes(raw_bytes))
    decoded_path = STEP2_ONLY_CAPTURE_DECODED_FILE if log_path == STEP2_ONLY_CAPTURE_FILE else log_path.with_suffix(".decoded.txt")
    decoded_path.write_text(str(analysis.get("decoded_text", "")), encoding="utf-8")
    analysis["capture_bytes"] = len(raw_bytes)
    analysis["decoded_log_path"] = str(decoded_path)
    return analysis


def capture_bridge_audit(port: str, capture_seconds: int, log_path: Path, *, uart_baud: int = 115200) -> dict[str, object]:
    try:
        import serial  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on local environment
        raise RuntimeError("pyserial is required for bridge-audit UART capture") from exc

    with serial.Serial(port, uart_baud, timeout=0.05) as ser:
        return capture_bridge_audit_stream(ser, capture_seconds, log_path)


def write_uart_bytes_slow(ser, payload: bytes, *, byte_delay_s: float) -> None:
    for byte in payload:
        ser.write(bytes([byte]))
        ser.flush()
        time.sleep(byte_delay_s)


def write_uart_u32_le_slow(ser, value: int, *, byte_delay_s: float) -> None:
    write_uart_bytes_slow(ser, struct.pack("<I", value & 0xFFFFFFFF), byte_delay_s=byte_delay_s)


def send_uart_payload_with_ack(
    ser,
    payload: bytes,
    *,
    wait_for_ack,
    chunk_bytes: int = UART_PAYLOAD_CHUNK_BYTES,
    byte_delay_s: float = UART_BOARD_PAYLOAD_BYTE_DELAY_S,
    chunk_gap_s: float = UART_BOARD_PAYLOAD_CHUNK_GAP_S,
) -> dict[str, int | bool]:
    payload_chunks_sent = 0
    payload_ack_timeout = False

    for off in range(0, len(payload), chunk_bytes):
        write_uart_bytes_slow(ser, payload[off : off + chunk_bytes], byte_delay_s=byte_delay_s)
        payload_chunks_sent += 1
        if not wait_for_ack():
            payload_ack_timeout = True
            break
        time.sleep(chunk_gap_s)

    return {
        "payload_chunks_sent": payload_chunks_sent,
        "payload_ack_timeout": payload_ack_timeout,
    }


def send_uart_payload_with_block_checksums(
    ser,
    payload: bytes,
    *,
    wait_for_chunk_ack,
    wait_for_block_reply,
    after_block_nack=None,
    chunk_bytes: int = UART_PAYLOAD_CHUNK_BYTES,
    block_bytes: int = UART_BLOCK_CHECKSUM_BYTES,
    byte_delay_s: float = UART_BOARD_PAYLOAD_BYTE_DELAY_S,
    chunk_gap_s: float = UART_BOARD_PAYLOAD_CHUNK_GAP_S,
    pre_block_checksum_gap_s: float = UART_BOARD_PRE_BLOCK_CHECKSUM_GAP_S,
    checksum_byte_delay_s: float = UART_BOARD_BLOCK_CHECKSUM_BYTE_DELAY_S,
    block_gap_s: float = UART_BOARD_BLOCK_GAP_S,
    block_retry_gap_s: float = UART_BOARD_BLOCK_RETRY_GAP_S,
    retry_limit: int = UART_BLOCK_RETRY_LIMIT,
) -> dict[str, int | bool | str]:
    payload_chunks_sent = 0
    payload_ack_timeout = False
    payload_block_ack_count = 0
    payload_block_nack_count = 0
    payload_block_retry_count = 0
    payload_block_retry_limit_hit = False
    payload_failed_block = -1

    for block_idx, block_start in enumerate(range(0, len(payload), block_bytes)):
        block = payload[block_start : block_start + block_bytes]
        block_checksum = sum(block) & 0xFFFFFFFF
        block_done = False
        for attempt in range(retry_limit):
            send_result = send_uart_payload_with_ack(
                ser,
                block,
                wait_for_ack=wait_for_chunk_ack,
                chunk_bytes=chunk_bytes,
                byte_delay_s=byte_delay_s,
                chunk_gap_s=chunk_gap_s,
            )
            payload_chunks_sent += int(send_result["payload_chunks_sent"])
            if bool(send_result["payload_ack_timeout"]):
                payload_ack_timeout = True
                payload_failed_block = block_idx
                break
            time.sleep(pre_block_checksum_gap_s)
            write_uart_u32_le_slow(ser, block_checksum, byte_delay_s=checksum_byte_delay_s)
            if not wait_for_chunk_ack():
                payload_ack_timeout = True
                payload_failed_block = block_idx
                break
            reply = wait_for_block_reply()
            if reply == "ack":
                payload_block_ack_count += 1
                block_done = True
                time.sleep(block_gap_s)
                break
            if reply == "nack":
                payload_block_nack_count += 1
                payload_block_retry_count += 1
                if after_block_nack is not None:
                    after_block_nack()
                time.sleep(block_retry_gap_s)
                continue
            payload_ack_timeout = True
            payload_failed_block = block_idx
            break
        if payload_ack_timeout:
            break
        if not block_done:
            payload_block_retry_limit_hit = True
            payload_failed_block = block_idx
            break

    return {
        "payload_chunks_sent": payload_chunks_sent,
        "payload_ack_timeout": payload_ack_timeout,
        "payload_block_ack_count": payload_block_ack_count,
        "payload_block_nack_count": payload_block_nack_count,
        "payload_block_retry_count": payload_block_retry_count,
        "payload_block_retry_limit_hit": payload_block_retry_limit_hit,
        "payload_failed_block": payload_failed_block,
    }


def drive_uart_loader(
    ser,
    manifest: dict[str, object],
    capture_seconds: int,
    text_log_path: Path,
    *,
    raw_log_path: Path,
    loader_decoded_path: Path,
    expect_dhrystone: bool = True,
) -> dict[str, object]:
    payload = Path(str(manifest["bin"])).read_bytes()
    header = struct.pack(
        "<IIIII",
        0x314B4D42,
        int(manifest["load_addr"]),
        int(manifest["entry"]),
        len(payload),
        int(manifest["checksum32"]),
    )

    raw_bytes = bytearray()
    loader_analysis = analyze_loader_beacon(b"")
    passthrough_len = 0
    sent_header = False
    sent_payload = False
    header_sent_at = 0.0
    start = time.monotonic()
    blind_header_deadline = start + 1.0
    deadline = start + capture_seconds
    text_log_path.parent.mkdir(parents=True, exist_ok=True)
    raw_log_path.parent.mkdir(parents=True, exist_ok=True)
    loader_decoded_path.parent.mkdir(parents=True, exist_ok=True)
    payload_ack_timeout = False
    payload_ack_credit = 0
    payload_ack_count = 0
    payload_chunks_sent = 0
    payload_block_ack_count = 0
    payload_block_nack_count = 0
    payload_block_retry_count = 0
    payload_block_retry_limit_hit = False
    payload_failed_block = -1
    pending_block_replies: list[str] = []

    def active_text() -> str:
        return bytes(loader_analysis.get("passthrough_bytes", b"")).decode("latin1", errors="ignore")

    def ingest_serial_bytes(chunk: bytes) -> str:
        nonlocal loader_analysis, passthrough_len, payload_ack_credit, payload_ack_count
        if chunk:
            raw_bytes.extend(chunk)
            loader_analysis = analyze_loader_beacon(bytes(raw_bytes))
            passthrough = bytes(loader_analysis.get("passthrough_bytes", b""))
            new_passthrough = passthrough[passthrough_len:]
            passthrough_len = len(passthrough)
            for byte in new_passthrough:
                if byte == UART_PAYLOAD_ACK:
                    payload_ack_credit += 1
                    payload_ack_count += 1
                elif byte == UART_BLOCK_ACK:
                    pending_block_replies.append("ack")
                elif byte == UART_BLOCK_NACK:
                    pending_block_replies.append("nack")
        return active_text()

    def wait_payload_ack() -> bool:
        nonlocal payload_ack_credit
        if payload_ack_credit > 0:
            payload_ack_credit -= 1
            return True
        end = time.monotonic() + UART_MAINLINE_PAYLOAD_ACK_TIMEOUT_S
        while time.monotonic() < end:
            ack_chunk = ser.read(4096)
            if ack_chunk:
                ingest_serial_bytes(ack_chunk)
                if payload_ack_credit > 0:
                    payload_ack_credit -= 1
                    return True
            else:
                time.sleep(0.001)
        return False

    def wait_block_reply() -> str:
        if pending_block_replies:
            return pending_block_replies.pop(0)
        end = time.monotonic() + UART_MAINLINE_BLOCK_REPLY_TIMEOUT_S
        while time.monotonic() < end:
            reply_chunk = ser.read(4096)
            if reply_chunk:
                ingest_serial_bytes(reply_chunk)
                if pending_block_replies:
                    return pending_block_replies.pop(0)
            else:
                time.sleep(0.001)
        return "timeout"

    def drain_serial_quiet(quiet_s: float) -> None:
        end = time.monotonic() + quiet_s
        while time.monotonic() < end:
            reply_chunk = ser.read(4096)
            if reply_chunk:
                ingest_serial_bytes(reply_chunk)
                end = time.monotonic() + quiet_s
            else:
                time.sleep(0.001)

    def write_header_slow() -> None:
        write_uart_bytes_slow(ser, header, byte_delay_s=UART_HEADER_BYTE_DELAY_S)

    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            current_text = ingest_serial_bytes(chunk)
            if (not sent_header) and bool(loader_analysis.get("ready_seen", False)):
                time.sleep(0.2)
                write_header_slow()
                sent_header = True
                header_sent_at = time.monotonic()
            if expect_dhrystone and sent_payload and "DHRYSTONE DONE" in current_text:
                break
            if (
                (not expect_dhrystone)
                and sent_payload
                and bool(loader_analysis.get("summary_ok_seen", False))
            ):
                break
            if bool(loader_analysis.get("bad_seen", False)):
                break
        elif (not sent_header) and time.monotonic() >= blind_header_deadline:
            write_header_slow()
            sent_header = True
            header_sent_at = time.monotonic()

        if (
            sent_header
            and (not sent_payload)
            and (
                bool(loader_analysis.get("load_start_seen", False))
                or (header_sent_at != 0.0 and time.monotonic() >= (header_sent_at + UART_HEADER_TO_PAYLOAD_GRACE_S))
            )
        ):
            time.sleep(0.2)
            send_result = send_uart_payload_with_block_checksums(
                ser,
                payload,
                wait_for_chunk_ack=wait_payload_ack,
                wait_for_block_reply=wait_block_reply,
                after_block_nack=lambda: drain_serial_quiet(0.100),
                byte_delay_s=UART_MAINLINE_PAYLOAD_BYTE_DELAY_S,
                chunk_gap_s=UART_MAINLINE_PAYLOAD_CHUNK_GAP_S,
                pre_block_checksum_gap_s=UART_MAINLINE_PRE_BLOCK_CHECKSUM_GAP_S,
                checksum_byte_delay_s=UART_MAINLINE_BLOCK_CHECKSUM_BYTE_DELAY_S,
                block_gap_s=UART_MAINLINE_BLOCK_GAP_S,
                block_retry_gap_s=UART_MAINLINE_BLOCK_RETRY_GAP_S,
                retry_limit=UART_MAINLINE_BLOCK_RETRY_LIMIT,
            )
            payload_chunks_sent += int(send_result["payload_chunks_sent"])
            payload_ack_timeout = bool(send_result["payload_ack_timeout"])
            payload_block_ack_count = int(send_result["payload_block_ack_count"])
            payload_block_nack_count = int(send_result["payload_block_nack_count"])
            payload_block_retry_count = int(send_result["payload_block_retry_count"])
            payload_block_retry_limit_hit = bool(send_result["payload_block_retry_limit_hit"])
            payload_failed_block = int(send_result["payload_failed_block"])
            sent_payload = True
            deadline = max(deadline, time.monotonic() + capture_seconds)
            if payload_ack_timeout or payload_block_retry_limit_hit or bool(loader_analysis.get("bad_seen", False)):
                break

    loader_analysis = analyze_loader_beacon(bytes(raw_bytes))
    passthrough_bytes = bytes(loader_analysis.get("passthrough_bytes", b""))
    current_text = passthrough_bytes.decode("latin1", errors="ignore")
    text_log_path.write_text(current_text, encoding="latin1", errors="ignore")
    raw_log_path.write_bytes(bytes(raw_bytes))
    loader_decoded_path.write_text(str(loader_analysis.get("decoded_text", "")), encoding="utf-8")

    fetch_probe = parse_fetch_probe(current_text)
    bad_block = analyze_loader_bad_block(current_text, payload)
    bad_checksum = analyze_loader_bad_checksum(current_text)
    write_blocks = analyze_loader_write_blocks(current_text, payload)
    benchmark_counters = parse_benchmark_counters(current_text)
    bad_reason = "none"
    if bool(loader_analysis.get("bad_seen", False)):
        bad_reason = str(loader_analysis.get("bad_reason", "none"))
    elif payload_block_retry_limit_hit:
        bad_reason = "BLOCK RETRY LIMIT"
    elif payload_ack_timeout and payload_failed_block >= 0:
        bad_reason = "BLOCK ACK TIMEOUT"
    elif any(token in current_text for token in ("BAD MAGIC", "LOAD BAD", "BAD_BYTE", "CAL FAIL", "RX OVERRUN", "RX FRAME ERR", "DRAIN TIMEOUT")):
        for token in ("LOAD BAD CHECKSUM", "LOAD BAD BLK", "LOAD BAD READ", "BAD_BYTE", "DRAIN TIMEOUT", "BAD MAGIC", "CAL FAIL", "RX OVERRUN", "RX FRAME ERR"):
            if token in current_text:
                bad_reason = token
                break

    return {
        "sent_header": sent_header,
        "sent_payload": sent_payload,
        "payload_ack_timeout": payload_ack_timeout,
        "payload_ack_count": payload_ack_count,
        "payload_ack_credit_remaining": payload_ack_credit,
        "payload_chunks_sent": payload_chunks_sent,
        "payload_block_ack_count": payload_block_ack_count,
        "payload_block_nack_count": payload_block_nack_count,
        "payload_block_retry_count": payload_block_retry_count,
        "payload_block_retry_limit_hit": payload_block_retry_limit_hit,
        "payload_failed_block": payload_failed_block,
        "payload_size_bytes": len(payload),
        "saw_ready": bool(loader_analysis.get("ready_seen", False)),
        "saw_load_start": bool(loader_analysis.get("load_start_seen", False)),
        "saw_read_ok": bool(loader_analysis.get("read_ok_seen", False)),
        "saw_load_ok": bool(loader_analysis.get("load_ok_seen", False)),
        "saw_jump": bool(loader_analysis.get("jump_seen", False)),
        "loader_summary_seen": bool(loader_analysis.get("summary_seen", False)),
        "loader_summary_mask": loader_analysis.get("summary_mask"),
        "loader_summary_ok": bool(loader_analysis.get("summary_ok_seen", False)),
        "loader_bad_seen": bool(loader_analysis.get("bad_seen", False)),
        "loader_bad_code": loader_analysis.get("bad_code"),
        "loader_bad_block": loader_analysis.get("bad_block"),
        "loader_good_frames": int(loader_analysis.get("good_frames", 0)),
        "loader_bad_frames": int(loader_analysis.get("bad_frames", 0)),
        "loader_dropped_duplicate_frames": int(loader_analysis.get("dropped_duplicate_frames", 0)),
        "loader_block_ack_events": int(loader_analysis.get("block_ack_events", 0)),
        "loader_block_nack_events": int(loader_analysis.get("block_nack_events", 0)),
        "loader_decoded_log_path": str(loader_decoded_path),
        "uart_capture_raw_file": str(raw_log_path),
        "uart_capture_text_file": str(text_log_path),
        "saw_probe": bool(fetch_probe.get("lines")),
        "fetch_probe": fetch_probe,
        "bad_block": bad_block,
        "bad_checksum": bad_checksum,
        "write_blocks": write_blocks,
        "bad_reason": bad_reason,
        "saw_start": "DHRYSTONE START" in current_text,
        "saw_done": "DHRYSTONE DONE" in current_text,
        "saw_bad": any(
            token in current_text
            for token in ("BAD MAGIC", "LOAD BAD", "BAD_BYTE", "CAL FAIL", "RX OVERRUN", "RX FRAME ERR", "DRAIN TIMEOUT")
        ),
        "dhrystones_per_second": re.findall(r"Dhrystones per Second:\s+([0-9]+)", current_text),
        "microseconds_per_run": re.findall(r"Microseconds for one run through Dhrystone:\s+([0-9]+)", current_text),
        "bench_cycles": benchmark_counters["cycles"],
        "bench_instret": benchmark_counters["instret"],
        "bench_ipc_x1000": benchmark_counters["ipc_x1000"],
        "capture_bytes": len(raw_bytes),
    }


def drive_uart_loader_early_audit(
    ser,
    manifest: dict[str, object],
    capture_seconds: int,
    text_log_path: Path,
    *,
    raw_log_path: Path,
    loader_decoded_path: Path,
    sessions_json_path: Path | None = None,
    wait_for_fresh_ready_only: bool = False,
    allow_blind_header_fallback: bool = True,
    post_jtag_quiet_ms: int = 100,
    header_send_delay_ms: int = 0,
    training_count: int = EARLY_AUDIT_TRAINING_COUNT_SIM,
) -> dict[str, object]:
    payload = Path(str(manifest["bin"])).read_bytes()[:UART_BLOCK_CHECKSUM_BYTES]
    header = struct.pack(
        "<IIIII",
        0x314B4D42,
        int(manifest["load_addr"]),
        int(manifest["entry"]),
        len(payload),
        int(sum(payload) & 0xFFFFFFFF),
    )
    header_wire = bytes([EARLY_AUDIT_TRAINING_BYTE]) * training_count + header

    raw_bytes = bytearray()
    loader_analysis = analyze_loader_early_audit_beacon(b"")
    passthrough_len = 0
    sent_header = False
    sent_payload = False
    header_sent_at = 0.0
    start = time.monotonic()
    blind_header_deadline = start + 1.0
    deadline = start + capture_seconds
    text_log_path.parent.mkdir(parents=True, exist_ok=True)
    raw_log_path.parent.mkdir(parents=True, exist_ok=True)
    loader_decoded_path.parent.mkdir(parents=True, exist_ok=True)
    if sessions_json_path is not None:
        sessions_json_path.parent.mkdir(parents=True, exist_ok=True)
    payload_ack_timeout = False
    payload_ack_credit = 0
    payload_ack_count = 0
    payload_chunks_sent = 0
    payload_block_ack_count = 0
    payload_block_nack_count = 0
    payload_block_retry_count = 0
    payload_block_retry_limit_hit = False
    payload_failed_block = -1
    pending_block_replies: list[str] = []

    def active_text() -> str:
        return bytes(loader_analysis.get("passthrough_bytes", b"")).decode("latin1", errors="ignore")

    def ingest_serial_bytes(chunk: bytes) -> str:
        nonlocal loader_analysis, passthrough_len, payload_ack_credit, payload_ack_count
        if chunk:
            raw_bytes.extend(chunk)
            loader_analysis = analyze_loader_early_audit_beacon(bytes(raw_bytes))
            passthrough = bytes(loader_analysis.get("passthrough_bytes", b""))
            new_passthrough = passthrough[passthrough_len:]
            passthrough_len = len(passthrough)
            for byte in new_passthrough:
                if byte == UART_PAYLOAD_ACK:
                    payload_ack_credit += 1
                    payload_ack_count += 1
                elif byte == UART_BLOCK_ACK:
                    pending_block_replies.append("ack")
                elif byte == UART_BLOCK_NACK:
                    pending_block_replies.append("nack")
        return active_text()

    def wait_payload_ack() -> bool:
        nonlocal payload_ack_credit
        if payload_ack_credit > 0:
            payload_ack_credit -= 1
            return True
        end = time.monotonic() + UART_MAINLINE_PAYLOAD_ACK_TIMEOUT_S
        while time.monotonic() < end:
            ack_chunk = ser.read(4096)
            if ack_chunk:
                ingest_serial_bytes(ack_chunk)
                if payload_ack_credit > 0:
                    payload_ack_credit -= 1
                    return True
            else:
                time.sleep(0.001)
        return False

    def wait_block_reply() -> str:
        if pending_block_replies:
            return pending_block_replies.pop(0)
        end = time.monotonic() + UART_MAINLINE_BLOCK_REPLY_TIMEOUT_S
        while time.monotonic() < end:
            reply_chunk = ser.read(4096)
            if reply_chunk:
                ingest_serial_bytes(reply_chunk)
                if pending_block_replies:
                    return pending_block_replies.pop(0)
            else:
                time.sleep(0.001)
        return "timeout"

    def drain_serial_quiet(quiet_s: float) -> None:
        end = time.monotonic() + quiet_s
        while time.monotonic() < end:
            reply_chunk = ser.read(4096)
            if reply_chunk:
                ingest_serial_bytes(reply_chunk)
                end = time.monotonic() + quiet_s
            else:
                time.sleep(0.001)

    def write_header_slow() -> None:
        write_uart_bytes_slow(ser, header_wire, byte_delay_s=UART_HEADER_BYTE_DELAY_S)

    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            ingest_serial_bytes(chunk)
            if (not sent_header) and bool(loader_analysis.get("ready_seen", False)) and (
                (not wait_for_fresh_ready_only) or loader_analysis.get("session_ready_seq") == 0
            ):
                drain_serial_quiet(max(0.0, post_jtag_quiet_ms / 1000.0))
                if header_send_delay_ms > 0:
                    time.sleep(header_send_delay_ms / 1000.0)
                write_header_slow()
                sent_header = True
                header_sent_at = time.monotonic()
            if sent_payload and bool(loader_analysis.get("summary_seen", False)):
                break
            if bool(loader_analysis.get("bad_seen", False)) and sent_header:
                break
        elif (not sent_header) and allow_blind_header_fallback and time.monotonic() >= blind_header_deadline:
            write_header_slow()
            sent_header = True
            header_sent_at = time.monotonic()

        if (
            sent_header
            and (not sent_payload)
            and (
                bool(loader_analysis.get("load_start_seen", False))
                or (header_sent_at != 0.0 and time.monotonic() >= (header_sent_at + UART_HEADER_TO_PAYLOAD_GRACE_S))
            )
        ):
            time.sleep(0.1)
            send_result = send_uart_payload_with_block_checksums(
                ser,
                payload,
                wait_for_chunk_ack=wait_payload_ack,
                wait_for_block_reply=wait_block_reply,
                after_block_nack=lambda: drain_serial_quiet(0.050),
                byte_delay_s=UART_MAINLINE_PAYLOAD_BYTE_DELAY_S,
                chunk_gap_s=UART_MAINLINE_PAYLOAD_CHUNK_GAP_S,
                pre_block_checksum_gap_s=UART_MAINLINE_PRE_BLOCK_CHECKSUM_GAP_S,
                checksum_byte_delay_s=UART_MAINLINE_BLOCK_CHECKSUM_BYTE_DELAY_S,
                block_gap_s=UART_MAINLINE_BLOCK_GAP_S,
                block_retry_gap_s=UART_MAINLINE_BLOCK_RETRY_GAP_S,
                retry_limit=1,
            )
            payload_chunks_sent += int(send_result["payload_chunks_sent"])
            payload_ack_timeout = bool(send_result["payload_ack_timeout"])
            payload_block_ack_count = int(send_result["payload_block_ack_count"])
            payload_block_nack_count = int(send_result["payload_block_nack_count"])
            payload_block_retry_count = int(send_result["payload_block_retry_count"])
            payload_block_retry_limit_hit = bool(send_result["payload_block_retry_limit_hit"])
            payload_failed_block = int(send_result["payload_failed_block"])
            sent_payload = True
            deadline = max(deadline, time.monotonic() + capture_seconds)
            if payload_ack_timeout or payload_block_retry_limit_hit or bool(loader_analysis.get("bad_seen", False)):
                break

    loader_analysis = analyze_loader_early_audit_beacon(bytes(raw_bytes))
    passthrough_bytes = bytes(loader_analysis.get("passthrough_bytes", b""))
    current_text = passthrough_bytes.decode("latin1", errors="ignore")
    text_log_path.write_text(current_text, encoding="latin1", errors="ignore")
    raw_log_path.write_bytes(bytes(raw_bytes))
    loader_decoded_path.write_text(str(loader_analysis.get("decoded_text", "")), encoding="utf-8")
    if sessions_json_path is not None:
        sessions_json_path.write_text(
            json.dumps(loader_analysis.get("sessions", []), indent=2),
            encoding="utf-8",
        )

    return {
        "sent_header": sent_header,
        "sent_payload": sent_payload,
        "payload_ack_timeout": payload_ack_timeout,
        "payload_ack_count": payload_ack_count,
        "payload_ack_credit_remaining": payload_ack_credit,
        "payload_chunks_sent": payload_chunks_sent,
        "payload_block_ack_count": payload_block_ack_count,
        "payload_block_nack_count": payload_block_nack_count,
        "payload_block_retry_count": payload_block_retry_count,
        "payload_block_retry_limit_hit": payload_block_retry_limit_hit,
        "payload_failed_block": payload_failed_block,
        "payload_size_bytes": len(payload),
        "loader_ready_seen": bool(loader_analysis.get("ready_seen", False)),
        "loader_header_byte0": loader_analysis.get("header_byte0"),
        "loader_header_byte1": loader_analysis.get("header_byte1"),
        "loader_header_byte2": loader_analysis.get("header_byte2"),
        "loader_header_byte3": loader_analysis.get("header_byte3"),
        "loader_header_magic_ok": bool(loader_analysis.get("header_magic_ok", False)),
        "loader_load_start_seen": bool(loader_analysis.get("load_start_seen", False)),
        "loader_first_block_ack_seen": bool(loader_analysis.get("first_block_ack_seen", False)),
        "loader_summary_seen": bool(loader_analysis.get("summary_seen", False)),
        "loader_summary_mask": loader_analysis.get("summary_mask"),
        "loader_summary_ok": bool(loader_analysis.get("summary_ok_seen", False)),
        "loader_bad_magic_seen": bool(loader_analysis.get("bad_magic_seen", False)),
        "loader_bad_magic_byte_index": loader_analysis.get("bad_magic_byte_index"),
        "loader_bad_seen": bool(loader_analysis.get("bad_seen", False)),
        "loader_bad_code": loader_analysis.get("bad_code"),
        "loader_good_frames": int(loader_analysis.get("good_frames", 0)),
        "loader_bad_frames": int(loader_analysis.get("bad_frames", 0)),
        "loader_dropped_duplicate_frames": int(loader_analysis.get("dropped_duplicate_frames", 0)),
        "loader_pre_session_frame_count": int(loader_analysis.get("pre_session_frame_count", 0)),
        "loader_session_start_offset": loader_analysis.get("session_start_offset"),
        "loader_session_ready_seq": loader_analysis.get("session_ready_seq"),
        "loader_session_start_not_found": bool(loader_analysis.get("session_start_not_found", False)),
        "loader_session_count": len(loader_analysis.get("sessions", [])),
        "loader_chosen_session_index": loader_analysis.get("chosen_session_index"),
        "loader_chosen_session_start_offset": loader_analysis.get("chosen_session_start_offset"),
        "loader_chosen_session_ready_arg": loader_analysis.get("chosen_session_ready_arg"),
        "loader_chosen_session_first_events": loader_analysis.get("chosen_session_first_event_types", []),
        "loader_chosen_session_order_valid": loader_analysis.get("chosen_session_order_valid", False),
        "loader_chosen_session_order_error": loader_analysis.get("chosen_session_order_error", ""),
        "loader_session_classification": loader_analysis.get("session_classification", "other"),
        "loader_sessions_json_path": str(sessions_json_path) if sessions_json_path is not None else "",
        "loader_decoded_log_path": str(loader_decoded_path),
        "uart_capture_raw_file": str(raw_log_path),
        "uart_capture_text_file": str(text_log_path),
        "bad_reason": str(loader_analysis.get("bad_reason", "none")),
        "capture_bytes": len(raw_bytes),
    }


def drive_uart_transport_sessions(ser, manifests: list[dict[str, object]], capture_seconds: int, log_path: Path) -> dict[str, object]:
    text_bytes = bytearray()
    payload_ack_timeout = False
    payload_ack_credit = 0
    payload_ack_count = 0
    payload_chunks_sent = 0
    session_results: list[dict[str, object]] = []
    bad_reason = "none"

    def active_text() -> str:
        return text_bytes.decode("latin1", errors="ignore")

    def update_bad_reason(text: str) -> str:
        for token in (
            "LOAD BAD CHECKSUM",
            "LOAD BAD BLK",
            "LOAD BAD READ",
            "BAD_BYTE",
            "DRAIN TIMEOUT",
            "BAD MAGIC",
            "CAL FAIL",
            "RX OVERRUN",
            "RX FRAME ERR",
        ):
            if token in text:
                return token
        return "none"

    def ingest_serial_bytes(chunk: bytes) -> str:
        nonlocal payload_ack_credit, payload_ack_count
        if chunk:
            text_bytes.extend(chunk)
            ack_hits = chunk.count(UART_PAYLOAD_ACK)
            if ack_hits:
                payload_ack_credit += ack_hits
                payload_ack_count += ack_hits
        return active_text()

    def wait_for_payload_ack() -> bool:
        nonlocal payload_ack_credit
        if payload_ack_credit > 0:
            payload_ack_credit -= 1
            return True
        end = time.monotonic() + UART_PAYLOAD_ACK_TIMEOUT_S
        while time.monotonic() < end:
            ack_chunk = ser.read(4096)
            if ack_chunk:
                text = ingest_serial_bytes(ack_chunk)
                if update_bad_reason(text) != "none":
                    return False
                if payload_ack_credit > 0:
                    payload_ack_credit -= 1
                    return True
            else:
                time.sleep(0.001)
        return False

    def write_header_slow(header: bytes) -> None:
        write_uart_bytes_slow(ser, header, byte_delay_s=UART_HEADER_BYTE_DELAY_S)

    def wait_for_token_growth(token: str, previous_count: int, timeout_s: float) -> str:
        end = time.monotonic() + timeout_s
        text = active_text()
        while time.monotonic() < end:
            chunk = ser.read(4096)
            if chunk:
                text = ingest_serial_bytes(chunk)
            else:
                time.sleep(0.001)
            if update_bad_reason(text) != "none":
                return text
            if text.count(token) > previous_count:
                return text
        return text

    start = time.monotonic()
    ready_deadline = start + 2.0
    ready_seen = False
    while time.monotonic() < ready_deadline:
        chunk = ser.read(4096)
        if chunk:
            text = ingest_serial_bytes(chunk)
            if TRANSPORT_READY_TOKEN in text:
                ready_seen = True
                break
        else:
            time.sleep(0.001)

    for session_idx, manifest in enumerate(manifests):
        payload = Path(str(manifest["bin"])).read_bytes()
        header = struct.pack(
            "<IIIII",
            0x314B4D42,
            int(manifest["load_addr"]),
            int(manifest["entry"]),
            len(payload),
            int(manifest["checksum32"]),
        )
        text = active_text()
        prev_load_start = text.count("LOAD START")
        prev_read_ok = text.count("READ OK")
        prev_load_ok = text.count("LOAD OK")

        if session_idx == 0:
            time.sleep(0.3 if ready_seen else 0.8)
        write_header_slow(header)
        text = wait_for_token_growth("LOAD START", prev_load_start, 5.0)
        bad_reason = update_bad_reason(text)
        if bad_reason != "none":
            break
        if text.count("LOAD START") <= prev_load_start:
            bad_reason = "LOAD START TIMEOUT"
            break
        time.sleep(0.2)

        send_result = send_uart_payload_with_ack(ser, payload, wait_for_ack=wait_for_payload_ack)
        payload_chunks_sent += int(send_result["payload_chunks_sent"])
        payload_ack_timeout = bool(send_result["payload_ack_timeout"])
        if payload_ack_timeout:
            bad_reason = update_bad_reason(active_text())
            if bad_reason == "none":
                bad_reason = "PAYLOAD ACK TIMEOUT"
        if bad_reason != "none":
            break

        text = wait_for_token_growth("LOAD OK", prev_load_ok, 10.0)
        bad_reason = update_bad_reason(text)
        if bad_reason != "none":
            break
        if text.count("READ OK") <= prev_read_ok:
            bad_reason = "READ OK TIMEOUT"
            break
        if text.count("LOAD OK") <= prev_load_ok:
            bad_reason = "LOAD OK TIMEOUT"
            break

        session_results.append(
            {
                "index": session_idx,
                "size_bytes": len(payload),
                "checksum32": int(manifest["checksum32"]),
                "seed": int(manifest.get("seed", session_idx + 1)),
            }
        )
        time.sleep(0.1)

    log_path.write_bytes(bytes(text_bytes))
    return {
        "ready_seen": ready_seen,
        "saw_load_start": "LOAD START" in active_text(),
        "saw_load_ok": "LOAD OK" in active_text(),
        "saw_bad": bad_reason != "none",
        "session_results": session_results,
        "session_count": len(session_results),
        "expected_sessions": len(manifests),
        "payload_ack_timeout": payload_ack_timeout,
        "payload_ack_count": payload_ack_count,
        "payload_ack_credit_remaining": payload_ack_credit,
        "payload_chunks_sent": payload_chunks_sent,
        "bad_reason": bad_reason,
        "capture_bytes": len(text_bytes),
    }


def run_uart_loader_capture(
    port: str,
    manifest: dict[str, object],
    capture_seconds: int,
    text_log_path: Path,
    *,
    uart_baud: int = 115200,
    raw_log_path: Path,
    loader_decoded_path: Path,
    expect_dhrystone: bool = True,
) -> dict[str, object]:
    try:
        import serial  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on local environment
        raise RuntimeError("pyserial is required for board benchmark UART loading") from exc

    with serial.Serial(port, uart_baud, timeout=0.05) as ser:
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        return drive_uart_loader(
            ser,
            manifest,
            capture_seconds,
            text_log_path,
            raw_log_path=raw_log_path,
            loader_decoded_path=loader_decoded_path,
            expect_dhrystone=expect_dhrystone,
        )


def run_uart_loader_early_audit_capture(
    port: str | None,
    manifest: dict[str, object],
    capture_seconds: int,
    text_log_path: Path,
    *,
    uart_baud: int = 115200,
    raw_log_path: Path,
    loader_decoded_path: Path,
    sessions_json_path: Path | None = None,
    ser=None,
    wait_for_fresh_ready_only: bool = False,
    allow_blind_header_fallback: bool = True,
    post_jtag_quiet_ms: int = 100,
    header_send_delay_ms: int = 0,
    training_count: int = EARLY_AUDIT_TRAINING_COUNT_SIM,
) -> dict[str, object]:
    if ser is not None:
        return drive_uart_loader_early_audit(
            ser,
            manifest,
            capture_seconds,
            text_log_path,
            raw_log_path=raw_log_path,
            loader_decoded_path=loader_decoded_path,
            sessions_json_path=sessions_json_path,
            wait_for_fresh_ready_only=wait_for_fresh_ready_only,
            allow_blind_header_fallback=allow_blind_header_fallback,
            post_jtag_quiet_ms=post_jtag_quiet_ms,
            header_send_delay_ms=header_send_delay_ms,
            training_count=training_count,
        )

    try:
        import serial  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on local environment
        raise RuntimeError("pyserial is required for board early-audit UART loading") from exc

    if port is None:
        raise RuntimeError("Serial port must be provided when no open serial object is passed")
    with serial.Serial(port, uart_baud, timeout=0.05) as open_ser:
        open_ser.reset_input_buffer()
        open_ser.reset_output_buffer()
        return drive_uart_loader_early_audit(
            open_ser,
            manifest,
            capture_seconds,
            text_log_path,
            raw_log_path=raw_log_path,
            loader_decoded_path=loader_decoded_path,
            sessions_json_path=sessions_json_path,
            wait_for_fresh_ready_only=wait_for_fresh_ready_only,
            allow_blind_header_fallback=allow_blind_header_fallback,
            post_jtag_quiet_ms=post_jtag_quiet_ms,
            header_send_delay_ms=header_send_delay_ms,
            training_count=training_count,
        )


def capture_loader_beacon_selftest_stream(
    ser,
    capture_seconds: int,
    text_log_path: Path,
    *,
    raw_log_path: Path,
    loader_decoded_path: Path,
    sessions_json_path: Path | None = None,
    reset_buffers: bool = True,
) -> dict[str, object]:
    raw_bytes = bytearray()
    if reset_buffers:
        ser.reset_input_buffer()
        ser.reset_output_buffer()
    deadline = time.monotonic() + capture_seconds
    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            raw_bytes.extend(chunk)
            analysis = analyze_loader_beacon_selftest_beacon(bytes(raw_bytes))
            if analysis.get("summary_seen"):
                break
        else:
            time.sleep(0.001)
    return finalize_loader_beacon_selftest_capture(
        raw_bytes,
        text_log_path,
        raw_log_path=raw_log_path,
        loader_decoded_path=loader_decoded_path,
        sessions_json_path=sessions_json_path,
    )


def finalize_loader_beacon_selftest_capture(
    raw_bytes: bytes | bytearray,
    text_log_path: Path,
    *,
    raw_log_path: Path,
    loader_decoded_path: Path,
    sessions_json_path: Path | None = None,
) -> dict[str, object]:
    raw_blob = bytes(raw_bytes)
    analysis = analyze_loader_beacon_selftest_beacon(raw_blob)
    text_log_path.parent.mkdir(parents=True, exist_ok=True)
    raw_log_path.parent.mkdir(parents=True, exist_ok=True)
    loader_decoded_path.parent.mkdir(parents=True, exist_ok=True)
    text_log_path.write_text(bytes(analysis.get("passthrough_bytes", b"")).decode("latin1", errors="ignore"), encoding="latin1", errors="ignore")
    raw_log_path.write_bytes(raw_blob)
    loader_decoded_path.write_text(str(analysis.get("decoded_text", "")), encoding="utf-8")
    if sessions_json_path is not None:
        write_json(sessions_json_path, analysis.get("sessions", []))
    return {
        "loader_beacon_selftest_pass": bool(analysis.get("pass", False)),
        "loader_session_count": int(analysis.get("session_count", 0)),
        "loader_pass_session_count": int(analysis.get("pass_session_count", 0)),
        "loader_bad_frames": int(analysis.get("bad_frames", 0)),
        "loader_good_frames": int(analysis.get("good_frames", 0)),
        "loader_session_classification": analysis.get("session_classification", "no_ready_session"),
        "loader_chosen_session_index": analysis.get("chosen_session_index"),
        "loader_chosen_session_start_offset": analysis.get("chosen_session_start_offset"),
        "loader_chosen_session_ready_arg": analysis.get("chosen_session_ready_arg"),
        "loader_chosen_session_first_events": list(analysis.get("chosen_session_first_event_types", [])),
        "loader_chosen_session_matched_prefix_len": int(analysis.get("chosen_session_matched_prefix_len", 0)),
        "loader_chosen_session_event_count": int(analysis.get("chosen_session_event_count", 0)),
        "loader_chosen_session_order_valid": bool(analysis.get("chosen_session_order_valid", False)),
        "loader_chosen_session_order_error": str(analysis.get("chosen_session_order_error", "")),
        "loader_decoded_log_path": str(loader_decoded_path),
        "loader_sessions_json_path": str(sessions_json_path) if sessions_json_path is not None else "N/A",
        "uart_capture_raw_file": str(raw_log_path),
        "uart_capture_text_file": str(text_log_path),
        "capture_bytes": len(raw_blob),
        "bad_reason": "none" if bool(analysis.get("pass", False)) else str(analysis.get("session_classification", "no_ready_session")),
    }


def run_uart_loader_beacon_selftest_capture(
    port: str,
    capture_seconds: int,
    text_log_path: Path,
    *,
    uart_baud: int = 115200,
    raw_log_path: Path,
    loader_decoded_path: Path,
    sessions_json_path: Path | None = None,
) -> dict[str, object]:
    try:
        import serial  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on local environment
        raise RuntimeError("pyserial is required for board beacon selftest UART capture") from exc

    with serial.Serial(port, uart_baud, timeout=0.05) as ser:
        return capture_loader_beacon_selftest_stream(
            ser,
            capture_seconds,
            text_log_path,
            raw_log_path=raw_log_path,
            loader_decoded_path=loader_decoded_path,
            sessions_json_path=sessions_json_path,
            reset_buffers=True,
        )


def write_summary(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--benchmark", choices=("dhrystone",), default="dhrystone")
    parser.add_argument("--port", default="COM5")
    parser.add_argument("--rs-depth", type=int, default=16)
    parser.add_argument("--fetch-buffer-depth", type=int, default=16)
    parser.add_argument("--core-clk-mhz", type=float, default=25.0)
    parser.add_argument("--capture-seconds", type=int, default=120)
    parser.add_argument("--uart-baud", type=int, default=115200)
    parser.add_argument("--dhrystone-runs", type=int, default=5000)
    parser.add_argument("--fetch-debug", action="store_true", help="Build a DDR3 fetch-probe bitstream and stop after UART beacon diagnosis.")
    parser.add_argument("--transport-only", action="store_true", help="Run the transport-only UART RX/FIFO/MMIO validation branch.")
    parser.add_argument("--bridge-audit", action="store_true", help="Run the isolated DDR3 bridge CDC/handshake audit branch.")
    parser.add_argument("--bridge-audit-steps", action="store_true", help="Run the layered bridge-only single-word/small-burst audit branch.")
    parser.add_argument("--bridge-audit-step2-only", action="store_true", help="Run the focused Step-2-only adjacent-word bridge audit branch.")
    parser.add_argument("--loader-early-audit", action="store_true", help="Run the header/first-block-only loader BAD_MAGIC audit branch.")
    parser.add_argument("--loader-early-audit-board-only", action="store_true", help="Reuse the existing early-audit bitstream and payload, then run only board JTAG + UART capture.")
    parser.add_argument("--loader-beacon-selftest", action="store_true", help="Run the fixed beacon transport selftest branch.")
    parser.add_argument("--loader-beacon-selftest-board-only", action="store_true", help="Reuse the existing beacon selftest bitstream and run only board JTAG + UART capture.")
    parser.add_argument("--early-audit-sweep-3point", action="store_true", help="Run the 3-point board-only early-audit timing sweep (Q100_H0, Q200_H0, Q100_H10).")
    parser.add_argument("--early-audit-bad-magic-byte", type=int, default=-1, help="For top-sim fault injection, corrupt magic byte index 0..3. Default runs all four injected cases automatically in loader-early-audit mode.")
    parser.add_argument("--early-audit-header-send-delay-ms", type=int, default=0, help="Board-only early-audit delay between fresh READY seq=0 and header transmission.")
    parser.add_argument("--early-audit-post-jtag-quiet-ms", type=int, default=100, help="Board-only early-audit quiet wait after JTAG before reacting to the first fresh READY seq=0.")
    parser.add_argument("--transport-jitter-pct", type=int, default=4, help="Bit-period jitter percentage used by the minimal transport TB.")
    parser.add_argument("--transport-byte-gap", type=int, default=6, help="Maximum extra idle bit-times inserted between bytes in the transport TB.")
    parser.add_argument("--transport-ack-mode", choices=("tight", "loose"), default="loose", help="ACK pacing style for transport-only disturbance cases.")
    parser.add_argument("--transport-seeds", type=int, default=3, help="Number of combo disturbance seeds to run for 1KB transport TB coverage.")
    parser.add_argument("--run-loader-long-sim", action="store_true", help="Also run the non-blocking prefix16 loader full-payload simulation.")
    parser.add_argument("--skip-vivado", action="store_true", help="Stop after RTL/top simulation and payload build.")
    args = parser.parse_args()

    active_modes = [
        mode
        for mode in (
            args.fetch_debug,
            args.transport_only,
            args.bridge_audit,
            args.bridge_audit_steps,
            args.bridge_audit_step2_only,
            args.loader_early_audit,
            args.loader_early_audit_board_only,
            args.loader_beacon_selftest,
            args.loader_beacon_selftest_board_only,
        )
        if mode
    ]
    if len(active_modes) > 1:
        raise SystemExit("--fetch-debug, --transport-only, --bridge-audit, --bridge-audit-steps, --bridge-audit-step2-only, --loader-early-audit, --loader-early-audit-board-only, --loader-beacon-selftest, and --loader-beacon-selftest-board-only are mutually exclusive")
    if args.early_audit_sweep_3point and not args.loader_early_audit_board_only:
        raise SystemExit("--early-audit-sweep-3point requires --loader-early-audit-board-only")

    logs_dir_name = (
        "fpga_bridge_audit_step2_only"
        if args.bridge_audit_step2_only
        else "fpga_bridge_audit_steps"
        if args.bridge_audit_steps
        else "fpga_bridge_audit"
        if args.bridge_audit
        else "fpga_loader_beacon_selftest"
        if args.loader_beacon_selftest
        else "fpga_loader_beacon_selftest_board_only"
        if args.loader_beacon_selftest_board_only
        else "fpga_loader_early_audit"
        if args.loader_early_audit
        else "fpga_loader_early_audit_sweep"
        if args.loader_early_audit_board_only
        else "fpga_benchmark_ddr3"
    )
    logs_dir = BUILD_DIR / logs_dir_name
    logs_dir.mkdir(parents=True, exist_ok=True)
    diagnostic_single_thread = not (
        args.transport_only
        or args.bridge_audit
        or args.bridge_audit_steps
        or args.bridge_audit_step2_only
    )
    diagnostic_smt_mode = 0 if diagnostic_single_thread else 1
    failed_stage = "none"
    failure_detail = ""
    current_stage = "init"
    manifest: dict[str, object] = {}
    early_audit_manifest: dict[str, object] = {}
    smoke_manifest: dict[str, object] = {}
    baseline_manifest: dict[str, object] = {}
    transport_manifests: list[dict[str, object]] = []
    transport_tb_results: list[dict[str, object]] = []
    bridge_tb_results: list[dict[str, object]] = []
    uart_result: dict[str, object] = {}
    uart_smoke_result: dict[str, object] = {}
    early_audit_fault_logs: list[str] = []
    build_id = "N/A"
    sim_log = logs_dir / "not_run.log"
    loader_quick_sim_log = logs_dir / "not_run.log"
    loader_full_prefix1_sim_log = logs_dir / "not_run.log"
    loader_full_prefix4_sim_log = logs_dir / "not_run.log"
    loader_full_long_sim_log = logs_dir / "not_run.log"
    loader_full_prefix4_failure_detail = ""
    loader_full_long_failure_detail = ""
    capture_file = (
        STEP2_ONLY_CAPTURE_FILE
        if args.bridge_audit_step2_only
        else (BRIDGE_STEPS_CAPTURE_FILE if args.bridge_audit_steps else (BRIDGE_CAPTURE_FILE if args.bridge_audit else (TRANSPORT_CAPTURE_FILE if args.transport_only else (UART_BEACON_SELFTEST_CAPTURE_FILE if (args.loader_beacon_selftest or args.loader_beacon_selftest_board_only) else (UART_EARLY_AUDIT_CAPTURE_FILE if args.loader_early_audit else UART_CAPTURE_FILE)))))
    )
    flow_name = (
        "AX7203 DDR3 Bridge Audit Step2 Only"
        if args.bridge_audit_step2_only
        else "AX7203 DDR3 Bridge Audit Steps"
        if args.bridge_audit_steps
        else "AX7203 DDR3 Bridge Audit"
        if args.bridge_audit
        else "AX7203 Loader Beacon Selftest"
        if args.loader_beacon_selftest
        else "AX7203 Loader Beacon Selftest Board-Only"
        if args.loader_beacon_selftest_board_only
        else "AX7203 UART Loader Transport"
        if args.transport_only
        else "AX7203 DDR3 Loader Early Audit"
        if args.loader_early_audit
        else "AX7203 DDR3 Loader Early Audit Board Sweep"
        if args.loader_early_audit_board_only
        else "AX7203 DDR3 Benchmark Loader"
    )

    env = build_env(
        args.rs_depth,
        args.fetch_buffer_depth,
        args.core_clk_mhz,
        smt_mode=diagnostic_smt_mode,
        fetch_debug=args.fetch_debug and not args.transport_only,
        bridge_audit=args.bridge_audit or args.bridge_audit_steps or args.bridge_audit_step2_only,
        step2_beacon_debug=args.bridge_audit_step2_only,
        loader_beacon_debug=not (args.transport_only or args.bridge_audit or args.bridge_audit_steps or args.bridge_audit_step2_only),
        uart_baud=args.uart_baud,
        rom_asm=STEP2_ONLY_ROM if args.bridge_audit_step2_only else (BRIDGE_STEPS_ROM if args.bridge_audit_steps else (BRIDGE_STRESS_ROM if args.bridge_audit else (TRANSPORT_ROM if args.transport_only else (BEACON_SELFTEST_ROM if (args.loader_beacon_selftest or args.loader_beacon_selftest_board_only) else (EARLY_AUDIT_ROM if (args.loader_early_audit or args.loader_early_audit_board_only) else LOADER_ROM))))),
        rom_march="rv32i_zicsr" if (args.transport_only or args.bridge_audit or args.bridge_audit_steps or args.bridge_audit_step2_only) else None,
        transport_uart_rxdata_reg_test=USE_REGISTERED_UART_RXDATA,
    )
    if args.loader_beacon_selftest_board_only:
        vivado = which_required("vivado.bat", "vivado")
        result, build_id, failed_stage, failure_detail, _jtag_log = run_loader_beacon_selftest_board(
            logs_dir,
            port=args.port,
            uart_baud=args.uart_baud,
            capture_seconds=args.capture_seconds,
            vivado=vivado,
            env=env,
        )
        write_json(
            logs_dir / "summary.json",
            {
                "Flow": flow_name,
                "BuildID": build_id,
                "FailedStage": failed_stage,
                "FailureDetail": failure_detail,
                **result,
            },
        )
        return 0 if (failed_stage == "none" and bool(result.get("loader_beacon_selftest_pass", False))) else 1
    if args.loader_early_audit_board_only:
        manifest = load_existing_early_audit_manifest(BUILD_DIR / "fpga_loader_early_audit")
        vivado = which_required("vivado.bat", "vivado")
        if args.early_audit_sweep_3point:
            return run_loader_early_audit_board_sweep(
                logs_dir,
                manifest=manifest,
                port=args.port,
                uart_baud=args.uart_baud,
                capture_seconds=args.capture_seconds,
                vivado=vivado,
                env=env,
            )
        single_trial = run_loader_early_audit_board_trial(
            logs_dir / "single",
            trial_name="single",
            manifest=manifest,
            port=args.port,
            uart_baud=args.uart_baud,
            capture_seconds=args.capture_seconds,
            post_jtag_quiet_ms=args.early_audit_post_jtag_quiet_ms,
            header_send_delay_ms=args.early_audit_header_send_delay_ms,
            vivado=vivado,
            env=env,
        )
        write_json(logs_dir / "summary.json", single_trial)
        write_summary(
            logs_dir / "summary.txt",
            [
                "Flow: AX7203 Loader Early Audit Board-Only",
                f"Pass: {single_trial['pass']}",
                f"TrialName: {single_trial['trial_name']}",
                f"PostJtagQuietMs: {single_trial['post_jtag_quiet_ms']}",
                f"HeaderSendDelayMs: {single_trial['header_send_delay_ms']}",
                f"BuildID: {single_trial.get('build_id', 'N/A')}",
                f"FailureStage: {single_trial.get('failure_stage', 'none')}",
                f"FailureDetail: {single_trial.get('failure_detail', 'none')}",
                f"SessionStartNotFound: {single_trial.get('session_start_not_found', False)}",
                f"SessionClassification: {single_trial.get('session_classification', 'N/A')}",
                f"ChosenSessionFirstEvents: {','.join(single_trial.get('chosen_session_first_events', []))}",
                f"HeaderByte0: {fmt_optional_hex(single_trial.get('header_byte0', 'N/A'))}",
                f"HeaderByte1: {fmt_optional_hex(single_trial.get('header_byte1', 'N/A'))}",
                f"BadMagicSeen: {single_trial.get('bad_magic_seen', False)}",
                f"BadMagicByteIndex: {single_trial.get('bad_magic_byte_index', 'N/A')}",
                f"BadReason: {single_trial.get('bad_reason', 'none')}",
                f"SummaryMask: {fmt_optional_hex(single_trial.get('summary_mask', 'N/A'))}",
                f"TrialSummary: {logs_dir / 'single' / 'summary.txt'}",
            ],
        )
        return 0 if single_trial["pass"] else 1
    try:
        current_stage = "basic"
        run_logged([sys.executable, str(REPO_ROOT / "verification" / "run_all_tests.py"), "--basic"], cwd=REPO_ROOT, log_path=logs_dir / "01_basic.log", timeout=3600)
        current_stage = "basic_fpga_config"
        run_logged([sys.executable, str(REPO_ROOT / "verification" / "run_all_tests.py"), "--basic", "--fpga-config"], cwd=REPO_ROOT, log_path=logs_dir / "02_basic_fpga_config.log", timeout=3600)
        if args.transport_only:
            current_stage = "transport_tb_matrix"
            transport_tb_results = run_transport_tb_matrix(
                logs_dir,
                core_clk_mhz=args.core_clk_mhz,
                uart_baud=args.uart_baud,
                jitter_pct=args.transport_jitter_pct,
                byte_gap_bits=args.transport_byte_gap,
                ack_mode=args.transport_ack_mode,
                seeds=args.transport_seeds,
            )
            current_stage = "transport_top_sim"
            sim_log = logs_dir / "06_run_transport_top_sim.log"
            sim_log, manifest = run_transport_top_sim(
                logs_dir,
                rs_depth=args.rs_depth,
                fetch_buffer_depth=args.fetch_buffer_depth,
                core_clk_mhz=args.core_clk_mhz,
                uart_baud=args.uart_baud,
                transport_seed=1,
            )
            current_stage = "build_transport_board_payloads"
            transport_manifests = [
                materialize_transport_payload(
                    logs_dir / "transport_board_payloads",
                    size_bytes=size_bytes,
                    seed=session_idx + 1,
                    stem=f"transport_{size_bytes}b",
                )
                for session_idx, size_bytes in enumerate(TRANSPORT_CASE_SIZES)
            ]
        elif args.bridge_audit_steps:
            current_stage = "bridge_stress_tb"
            bridge_tb_results = run_bridge_stress_tb(logs_dir)
            current_stage = "bridge_steps_top_sim"
            sim_log = logs_dir / "06_run_bridge_steps_top_sim.log"
            sim_log = run_bridge_steps_top_sim(
                logs_dir,
                rs_depth=args.rs_depth,
                fetch_buffer_depth=args.fetch_buffer_depth,
                core_clk_mhz=args.core_clk_mhz,
                uart_baud=args.uart_baud,
            )
        elif args.bridge_audit_step2_only:
            current_stage = "bridge_stress_tb"
            bridge_tb_results = run_bridge_stress_tb(logs_dir)
            current_stage = "step2_only_top_sim"
            sim_log = logs_dir / "06_run_step2_only_top_sim.log"
            sim_log = run_step2_only_top_sim(
                logs_dir,
                rs_depth=args.rs_depth,
                fetch_buffer_depth=args.fetch_buffer_depth,
                core_clk_mhz=args.core_clk_mhz,
                uart_baud=args.uart_baud,
            )
            if args.skip_vivado:
                uart_result = analyze_step2_only_sim_log(read_text(sim_log))
                uart_result["decoded_log_path"] = str(sim_log)
        elif args.loader_beacon_selftest:
            current_stage = "loader_beacon_selftest_top_sim"
            sim_log = logs_dir / "05_run_loader_beacon_selftest_top_sim.log"
            sim_log = run_loader_beacon_selftest_top_sim(
                logs_dir,
                rs_depth=args.rs_depth,
                fetch_buffer_depth=args.fetch_buffer_depth,
                core_clk_mhz=args.core_clk_mhz,
                uart_baud=args.uart_baud,
                smt_mode=diagnostic_smt_mode,
                log_name="05_run_loader_beacon_selftest_top_sim.log",
                rom_asm=BEACON_SELFTEST_ROM,
            )
            if args.skip_vivado:
                uart_result = analyze_loader_beacon_selftest_sim_log(read_text(sim_log))
                uart_result["decoded_log_path"] = str(sim_log)
        elif args.loader_early_audit:
            current_stage = "build_dhrystone_payload"
            manifest = build_dhrystone_payload(
                logs_dir,
                cpu_hz=int(round(args.core_clk_mhz * 1_000_000.0)),
                runs=args.dhrystone_runs,
                stem="dhrystone_loader_early_audit_source",
            )
            current_stage = "build_loader_early_audit_manifest"
            early_audit_manifest = build_early_audit_manifest(logs_dir, manifest, stem="dhrystone_loader_early_audit")
            current_stage = "loader_early_audit_top_sim"
            sim_log = logs_dir / "05_run_loader_early_audit_top_sim.log"
            sim_log = run_loader_top_sim(
                logs_dir,
                early_audit_manifest,
                rs_depth=args.rs_depth,
                fetch_buffer_depth=args.fetch_buffer_depth,
                core_clk_mhz=args.core_clk_mhz,
                expect_exec_pass=False,
                uart_baud=args.uart_baud,
                smt_mode=diagnostic_smt_mode,
                log_name="05_run_loader_early_audit_top_sim.log",
                rom_asm=EARLY_AUDIT_ROM,
                early_audit_enable=True,
                early_audit_bad_magic_byte=-1,
            )
            for bad_idx in range(4):
                current_stage = f"loader_early_audit_fault_b{bad_idx}"
                fault_log = run_loader_top_sim(
                    logs_dir / f"fault_b{bad_idx}",
                    early_audit_manifest,
                    rs_depth=args.rs_depth,
                    fetch_buffer_depth=args.fetch_buffer_depth,
                    core_clk_mhz=args.core_clk_mhz,
                    expect_exec_pass=False,
                    uart_baud=args.uart_baud,
                    smt_mode=diagnostic_smt_mode,
                    log_name=f"06_run_loader_early_audit_fault_b{bad_idx}.log",
                    rom_asm=EARLY_AUDIT_ROM,
                    early_audit_enable=True,
                    early_audit_bad_magic_byte=bad_idx,
                )
                early_audit_fault_logs.append(str(fault_log))
            if args.skip_vivado:
                uart_result = analyze_loader_early_audit_sim_log(read_text(sim_log))
                uart_result["decoded_log_path"] = str(sim_log)
        elif args.bridge_audit:
            current_stage = "bridge_stress_tb"
            bridge_tb_results = run_bridge_stress_tb(logs_dir)
            current_stage = "bridge_top_sim"
            sim_log = logs_dir / "06_run_bridge_top_sim.log"
            sim_log = run_bridge_top_sim(
                logs_dir,
                rs_depth=args.rs_depth,
                fetch_buffer_depth=args.fetch_buffer_depth,
                core_clk_mhz=args.core_clk_mhz,
                uart_baud=args.uart_baud,
            )
        else:
            if args.fetch_debug:
                current_stage = "build_fetch_probe_payload"
                probe_payload = compile_ddr3_asm_payload(TINY_PAYLOAD_ROM, logs_dir / "fetch_probe_payload", "ddr3_fetch_probe_payload")
                manifest = {
                    "bin": str(probe_payload["bin"]),
                    "entry": int(probe_payload["entry"]),
                    "load_addr": int(probe_payload["load_addr"]),
                    "size_bytes": int(probe_payload["size_bytes"]),
                    "checksum32": int(probe_payload["checksum32"]),
                }
                current_stage = "loader_top_sim"
                sim_log = logs_dir / "05_run_loader_top_sim.log"
                sim_log = run_loader_top_sim(
                    logs_dir,
                    manifest,
                    rs_depth=args.rs_depth,
                    fetch_buffer_depth=args.fetch_buffer_depth,
                    core_clk_mhz=args.core_clk_mhz,
                    expect_exec_pass=False,
                    full_gate_prefix_enable=False,
                    fetch_debug=True,
                    uart_baud=args.uart_baud,
                    smt_mode=diagnostic_smt_mode,
                    log_name="05_run_loader_top_sim.log",
                )
            else:
                current_stage = "build_loader_quick_payload"
                quick_payload = compile_ddr3_asm_payload(TINY_PAYLOAD_ROM, logs_dir / "loader_quick_payload", "ddr3_loader_quick_payload")
                quick_manifest = {
                    "bin": str(quick_payload["bin"]),
                    "entry": int(quick_payload["entry"]),
                    "load_addr": int(quick_payload["load_addr"]),
                    "size_bytes": int(quick_payload["size_bytes"]),
                    "checksum32": int(quick_payload["checksum32"]),
                }
                current_stage = "loader_quick_sim"
                loader_quick_sim_log = logs_dir / "loader_quick" / "05_run_loader_quick_sim.log"
                sim_log = loader_quick_sim_log
                loader_quick_sim_log = run_loader_top_sim(
                    logs_dir / "loader_quick",
                    quick_manifest,
                    rs_depth=args.rs_depth,
                    fetch_buffer_depth=args.fetch_buffer_depth,
                    core_clk_mhz=args.core_clk_mhz,
                    expect_exec_pass=True,
                    full_gate_prefix_enable=False,
                    uart_baud=args.uart_baud,
                    smt_mode=diagnostic_smt_mode,
                    log_name="05_run_loader_quick_sim.log",
                )
                current_stage = "build_dhrystone_smoke_payload"
                smoke_manifest = build_dhrystone_payload(
                    logs_dir,
                    cpu_hz=int(args.core_clk_mhz * 1_000_000),
                    runs=1,
                    stem="dhrystone_smoke",
                    fixed_runs=10,
                )
                current_stage = "loader_full_payload_prefix1_sim"
                prefix1_profile = loader_full_gate_profile(LOADER_FULL_PREFIX1_BLOCKS, args.core_clk_mhz)
                loader_full_prefix1_sim_log = logs_dir / "loader_full_prefix1" / "06_run_loader_full_payload_prefix1_sim.log"
                sim_log = loader_full_prefix1_sim_log
                loader_full_prefix1_sim_log = run_loader_top_sim(
                    logs_dir / "loader_full_prefix1",
                    smoke_manifest,
                    rs_depth=args.rs_depth,
                    fetch_buffer_depth=args.fetch_buffer_depth,
                    core_clk_mhz=args.core_clk_mhz,
                    expect_exec_pass=False,
                    full_gate_prefix_enable=True,
                    full_gate_prefix_block_ack_target=LOADER_FULL_PREFIX1_BLOCKS,
                    uart_baud=args.uart_baud,
                    smt_mode=diagnostic_smt_mode,
                    log_name="06_run_loader_full_payload_prefix1_sim.log",
                    fast_uart_profile=bool(prefix1_profile["fast_uart_profile"]),
                    fast_uart_inject=prefix1_profile["fast_uart_inject"],
                    initial_header_wait_bits=prefix1_profile["initial_header_wait_bits"],
                    initial_payload_wait_bits=prefix1_profile["initial_payload_wait_bits"],
                    inter_u32_gap_bits=prefix1_profile["inter_u32_gap_bits"],
                    chunk_ack_gap_bits=prefix1_profile["chunk_ack_gap_bits"],
                    block_done_gap_bits=prefix1_profile["block_done_gap_bits"],
                    tb_timeout_ns=prefix1_profile["tb_timeout_ns"],
                    sim_timeout_s=prefix1_profile["sim_timeout_s"],
                )
                if args.run_loader_long_sim:
                    prefix16_profile = loader_full_gate_profile(LOADER_FULL_PREFIX16_BLOCKS, args.core_clk_mhz)
                    prefix4_profile = loader_full_gate_profile(LOADER_FULL_PREFIX4_BLOCKS, args.core_clk_mhz)
                    loader_full_prefix4_sim_log = logs_dir / "loader_full_prefix4" / "07_run_loader_full_payload_prefix4_sim.log"
                    current_stage = "loader_full_payload_prefix4_sim"
                    loader_full_long_sim_log = logs_dir / "loader_full_long" / "08_run_loader_full_payload_long_sim.log"
                    try:
                        sim_log = loader_full_prefix4_sim_log
                        loader_full_prefix4_sim_log = run_loader_top_sim(
                            logs_dir / "loader_full_prefix4",
                            smoke_manifest,
                            rs_depth=args.rs_depth,
                            fetch_buffer_depth=args.fetch_buffer_depth,
                            core_clk_mhz=args.core_clk_mhz,
                            expect_exec_pass=False,
                            full_gate_prefix_enable=True,
                            full_gate_prefix_block_ack_target=LOADER_FULL_PREFIX4_BLOCKS,
                            uart_baud=args.uart_baud,
                            smt_mode=diagnostic_smt_mode,
                            log_name="07_run_loader_full_payload_prefix4_sim.log",
                            fast_uart_profile=bool(prefix4_profile["fast_uart_profile"]),
                            fast_uart_inject=prefix4_profile["fast_uart_inject"],
                            initial_header_wait_bits=prefix4_profile["initial_header_wait_bits"],
                            initial_payload_wait_bits=prefix4_profile["initial_payload_wait_bits"],
                            inter_u32_gap_bits=prefix4_profile["inter_u32_gap_bits"],
                            chunk_ack_gap_bits=prefix4_profile["chunk_ack_gap_bits"],
                            block_done_gap_bits=prefix4_profile["block_done_gap_bits"],
                            tb_timeout_ns=prefix4_profile["tb_timeout_ns"],
                            sim_timeout_s=prefix4_profile["sim_timeout_s"],
                        )
                    except Exception as prefix4_exc:  # noqa: BLE001
                        loader_full_prefix4_failure_detail = str(prefix4_exc)
                    try:
                        current_stage = "loader_full_payload_long_sim"
                        sim_log = loader_full_long_sim_log
                        loader_full_long_sim_log = run_loader_top_sim(
                            logs_dir / "loader_full_long",
                            smoke_manifest,
                            rs_depth=args.rs_depth,
                            fetch_buffer_depth=args.fetch_buffer_depth,
                            core_clk_mhz=args.core_clk_mhz,
                            expect_exec_pass=False,
                            full_gate_prefix_enable=True,
                            full_gate_prefix_block_ack_target=LOADER_FULL_PREFIX16_BLOCKS,
                            uart_baud=args.uart_baud,
                            smt_mode=diagnostic_smt_mode,
                            log_name="08_run_loader_full_payload_long_sim.log",
                            fast_uart_profile=bool(prefix16_profile["fast_uart_profile"]),
                            fast_uart_inject=prefix16_profile["fast_uart_inject"],
                            initial_header_wait_bits=prefix16_profile["initial_header_wait_bits"],
                            initial_payload_wait_bits=prefix16_profile["initial_payload_wait_bits"],
                            inter_u32_gap_bits=prefix16_profile["inter_u32_gap_bits"],
                            chunk_ack_gap_bits=prefix16_profile["chunk_ack_gap_bits"],
                            block_done_gap_bits=prefix16_profile["block_done_gap_bits"],
                            tb_timeout_ns=prefix16_profile["tb_timeout_ns"],
                            sim_timeout_s=prefix16_profile["sim_timeout_s"],
                        )
                    except Exception as long_exc:  # noqa: BLE001
                        loader_full_long_failure_detail = str(long_exc)
                    finally:
                        current_stage = "loader_full_payload_prefix1_sim"
                        sim_log = loader_full_prefix1_sim_log
                current_stage = "build_dhrystone_baseline_payload"
                baseline_manifest = (
                    smoke_manifest
                    if args.dhrystone_runs == 1
                    else build_dhrystone_payload(
                        logs_dir,
                        cpu_hz=int(args.core_clk_mhz * 1_000_000),
                        runs=args.dhrystone_runs,
                        stem="dhrystone_baseline",
                    )
                )
                manifest = baseline_manifest
                if args.skip_vivado:
                    uart_result = analyze_loader_sim_log(read_text(loader_full_prefix1_sim_log))
                    uart_result["decoded_log_path"] = str(loader_full_prefix1_sim_log)
                    capture_file = loader_full_prefix1_sim_log

        if not args.skip_vivado:
            vivado = which_required("vivado.bat", "vivado")
            current_stage = "create_project"
            if PROJECT_DIR.exists():
                shutil.rmtree(PROJECT_DIR)
            run_logged([vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "create_project_ax7203.tcl")], cwd=REPO_ROOT, env=env, log_path=logs_dir / "07_create_project.log", timeout=3600)
            current_stage = "synth"
            run_logged([vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "run_ax7203_synth.tcl")], cwd=REPO_ROOT, env=env, log_path=logs_dir / "08_run_synth.log", timeout=7200)
            current_stage = "impl_aggressive"
            run_logged([vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "impl_aggressive.tcl")], cwd=REPO_ROOT, env=env, log_path=logs_dir / "09_impl_aggressive.log", timeout=7200)
            timing = parse_timing_summary(TIMING_SUMMARY_AGGR)
            if timing["constraints_met"] != "True" or float(timing["wns"]) < 0.0 or float(timing["whs"]) < 0.0:
                raise RuntimeError(f"Aggressive implementation timing failed; see {TIMING_SUMMARY_AGGR}")
            if args.loader_beacon_selftest:
                board_result, build_id, board_failed_stage, board_failure_detail, _jtag_log = run_loader_beacon_selftest_board(
                    logs_dir,
                    port=args.port,
                    uart_baud=args.uart_baud,
                    capture_seconds=args.capture_seconds,
                    vivado=vivado,
                    env=env,
                )
                uart_result = board_result
                current_stage = board_failed_stage
                if board_failed_stage != "none":
                    raise RuntimeError(board_failure_detail)
            elif args.bridge_audit or args.bridge_audit_steps or args.bridge_audit_step2_only:
                try:
                    import serial  # type: ignore
                except ImportError as exc:  # pragma: no cover - depends on local environment
                    raise RuntimeError("pyserial is required for bridge-audit UART capture") from exc
                with serial.Serial(args.port, args.uart_baud, timeout=0.05) as ser:
                    ser.reset_input_buffer()
                    ser.reset_output_buffer()
                    current_stage = "program_jtag"
                    run_logged([vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "program_ax7203_jtag.tcl")], cwd=REPO_ROOT, env=env, log_path=logs_dir / "10_program_jtag.log", timeout=1800)
                    build_id = parse_build_id(BUILD_ID_FILE)
                    current_stage = "uart_load_and_capture"
                    if args.bridge_audit_step2_only:
                        uart_result = capture_step2_only_stream(
                            ser,
                            args.capture_seconds,
                            capture_file,
                            reset_buffers=False,
                        )
                    elif args.bridge_audit_steps:
                        uart_result = capture_bridge_audit_steps_stream(
                            ser,
                            args.capture_seconds,
                            capture_file,
                            reset_buffers=False,
                        )
                    else:
                        uart_result = capture_bridge_audit_stream(
                            ser,
                            args.capture_seconds,
                            capture_file,
                            reset_buffers=False,
                        )
            else:
                try:
                    import serial  # type: ignore
                except ImportError as exc:  # pragma: no cover - depends on local environment
                    raise RuntimeError("pyserial is required for board benchmark UART loading") from exc
                if args.loader_early_audit:
                    with serial.Serial(args.port, args.uart_baud, timeout=0.05) as ser:
                        ser.reset_input_buffer()
                        ser.reset_output_buffer()
                        current_stage = "program_jtag"
                        run_logged([vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "program_ax7203_jtag.tcl")], cwd=REPO_ROOT, env=env, log_path=logs_dir / "10_program_jtag.log", timeout=1800)
                        build_id = parse_build_id(BUILD_ID_FILE)
                        current_stage = "uart_load_and_capture_early_audit"
                        uart_result = run_uart_loader_early_audit_capture(
                            None,
                            early_audit_manifest,
                            args.capture_seconds,
                            UART_EARLY_AUDIT_CAPTURE_FILE,
                            uart_baud=args.uart_baud,
                            raw_log_path=UART_EARLY_AUDIT_CAPTURE_RAW_FILE,
                            loader_decoded_path=UART_EARLY_AUDIT_CAPTURE_DECODED_FILE,
                            sessions_json_path=UART_EARLY_AUDIT_CAPTURE_SESSIONS_FILE,
                            ser=ser,
                            wait_for_fresh_ready_only=True,
                            allow_blind_header_fallback=False,
                            post_jtag_quiet_ms=args.early_audit_post_jtag_quiet_ms,
                            header_send_delay_ms=args.early_audit_header_send_delay_ms,
                            training_count=EARLY_AUDIT_TRAINING_COUNT_SIM,
                        )
                        capture_file = UART_EARLY_AUDIT_CAPTURE_FILE
                else:
                    current_stage = "program_jtag"
                    run_logged([vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "program_ax7203_jtag.tcl")], cwd=REPO_ROOT, env=env, log_path=logs_dir / "10_program_jtag.log", timeout=1800)
                    build_id = parse_build_id(BUILD_ID_FILE)
                if args.transport_only:
                    current_stage = "uart_load_and_capture"
                    with serial.Serial(args.port, args.uart_baud, timeout=0.05) as ser:
                        ser.reset_input_buffer()
                        ser.reset_output_buffer()
                        uart_result = drive_uart_transport_sessions(ser, transport_manifests, args.capture_seconds, capture_file)
                elif args.fetch_debug:
                    current_stage = "uart_load_and_capture"
                    uart_result = run_uart_loader_capture(
                        args.port,
                        manifest,
                        args.capture_seconds,
                        UART_CAPTURE_FILE,
                        uart_baud=args.uart_baud,
                        raw_log_path=UART_CAPTURE_RAW_FILE,
                        loader_decoded_path=UART_CAPTURE_LOADER_DECODED_FILE,
                        expect_dhrystone=False,
                    )
                elif args.loader_early_audit:
                    pass
                else:
                    current_stage = "uart_load_and_capture_smoke"
                    uart_smoke_result = run_uart_loader_capture(
                        args.port,
                        smoke_manifest,
                        args.capture_seconds,
                        UART_SMOKE_CAPTURE_FILE,
                        uart_baud=args.uart_baud,
                        raw_log_path=UART_SMOKE_CAPTURE_RAW_FILE,
                        loader_decoded_path=UART_SMOKE_CAPTURE_LOADER_DECODED_FILE,
                        expect_dhrystone=True,
                    )
                    if uart_smoke_result.get("loader_bad_seen"):
                        raise RuntimeError(f"Smoke loader beacon reported failure ({uart_smoke_result.get('bad_reason', 'unknown')}); see {UART_SMOKE_CAPTURE_FILE}")
                    if not uart_smoke_result.get("loader_summary_seen"):
                        raise RuntimeError(f"Smoke loader beacon missing SUMMARY; see {UART_SMOKE_CAPTURE_FILE}")
                    if not uart_smoke_result.get("loader_summary_ok"):
                        raise RuntimeError(f"Smoke loader SUMMARY indicates failure; see {UART_SMOKE_CAPTURE_FILE}")
                    if not uart_smoke_result.get("saw_start"):
                        raise RuntimeError(f"Smoke board run missing DHRYSTONE START; see {UART_SMOKE_CAPTURE_FILE}")
                    if not uart_smoke_result.get("saw_done"):
                        raise RuntimeError(f"Smoke board run missing DHRYSTONE DONE; see {UART_SMOKE_CAPTURE_FILE}")
                    if args.dhrystone_runs == 1:
                        uart_result = dict(uart_smoke_result)
                        capture_file = UART_SMOKE_CAPTURE_FILE
                    else:
                        current_stage = "program_jtag_baseline"
                        run_logged([vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "program_ax7203_jtag.tcl")], cwd=REPO_ROOT, env=env, log_path=logs_dir / "11_program_jtag_baseline.log", timeout=1800)
                        build_id = parse_build_id(BUILD_ID_FILE)
                        current_stage = "uart_load_and_capture_baseline"
                        uart_result = run_uart_loader_capture(
                            args.port,
                            baseline_manifest,
                            args.capture_seconds,
                            UART_CAPTURE_FILE,
                            uart_baud=args.uart_baud,
                            raw_log_path=UART_CAPTURE_RAW_FILE,
                            loader_decoded_path=UART_CAPTURE_LOADER_DECODED_FILE,
                            expect_dhrystone=True,
                        )
                        capture_file = UART_CAPTURE_FILE
            if args.bridge_audit_step2_only:
                if uart_result.get("saw_bad") or uart_result.get("saw_trap") or uart_result.get("saw_cal_fail"):
                    raise RuntimeError(f"DDR3 step2-only board profile reported failure ({uart_result.get('bad_reason', 'unknown')}); see {capture_file}")
                if not uart_result.get("ready_seen"):
                    raise RuntimeError(f"DDR3 step2-only board profile did not emit READY beacon; see {capture_file}")
                if not uart_result.get("case1_pass"):
                    raise RuntimeError(f"DDR3 step2-only board profile did not complete case1; see {capture_file}")
                if not uart_result.get("case2_pass"):
                    raise RuntimeError(f"DDR3 step2-only board profile did not complete case2; see {capture_file}")
                if not uart_result.get("case3_pass"):
                    raise RuntimeError(f"DDR3 step2-only board profile did not complete case3; see {capture_file}")
                if not uart_result.get("case4_pass"):
                    raise RuntimeError(f"DDR3 step2-only board profile did not complete case4; see {capture_file}")
                if not uart_result.get("case5_pass"):
                    raise RuntimeError(f"DDR3 step2-only board profile did not complete case5; see {capture_file}")
                if not uart_result.get("summary_seen"):
                    raise RuntimeError(f"DDR3 step2-only board profile did not emit SUMMARY beacon; see {capture_file}")
                if not uart_result.get("all_ok_seen"):
                    raise RuntimeError(f"DDR3 step2-only board profile emitted a failing SUMMARY mask; see {capture_file}")
            elif args.bridge_audit_steps:
                if uart_result.get("saw_bad"):
                    raise RuntimeError(f"DDR3 bridge-steps board profile reported compare failure; see {capture_file}")
                if not uart_result.get("ready_seen"):
                    raise RuntimeError(f"DDR3 bridge-steps board profile did not print BSTEP READY; see {capture_file}")
                if not uart_result.get("step1_pass"):
                    raise RuntimeError(f"DDR3 bridge-steps board profile did not complete step1; see {capture_file}")
                if not uart_result.get("step2_pass"):
                    raise RuntimeError(f"DDR3 bridge-steps board profile did not complete step2; see {capture_file}")
                if not uart_result.get("step3_pass"):
                    raise RuntimeError(f"DDR3 bridge-steps board profile did not complete step3; see {capture_file}")
                if not uart_result.get("all_ok_seen"):
                    raise RuntimeError(f"DDR3 bridge-steps board profile did not print BSTEP ALL OK; see {capture_file}")
            elif args.bridge_audit:
                if uart_result.get("saw_bad"):
                    raise RuntimeError(f"DDR3 bridge board profile reported compare failure; see {capture_file}")
                if int(uart_result.get("ok_count", 0)) < 2:
                    raise RuntimeError(f"DDR3 bridge board profile did not produce enough BRIDGE OK tokens; see {capture_file}")
            elif args.transport_only:
                if uart_result.get("bad_reason", "none") != "none":
                    raise RuntimeError(f"UART reported transport error ({uart_result.get('bad_reason', 'unknown')}); see {capture_file}")
                if int(uart_result.get("session_count", 0)) != len(transport_manifests):
                    raise RuntimeError(f"Transport board session count mismatch ({uart_result.get('session_count', 0)}/{len(transport_manifests)}); see {capture_file}")
            else:
                if args.fetch_debug:
                    if uart_result.get("loader_bad_seen"):
                        raise RuntimeError(f"Fetch-debug loader beacon reported failure ({uart_result.get('bad_reason', 'unknown')}); see {capture_file}")
                    if not uart_result.get("loader_summary_seen"):
                        raise RuntimeError(f"Fetch-debug loader beacon missing SUMMARY; see {capture_file}")
                    if not uart_result.get("loader_summary_ok"):
                        raise RuntimeError(f"Fetch-debug loader SUMMARY indicates failure; see {capture_file}")
                    if not uart_result.get("saw_probe"):
                        raise RuntimeError(f"UART missing M0D fetch probe beacon; see {capture_file}")
                elif args.loader_beacon_selftest:
                    if not bool(uart_result.get("loader_beacon_selftest_pass", False)):
                        raise RuntimeError(
                            f"Beacon selftest mismatch ({uart_result.get('loader_session_classification', 'unknown')}); see {capture_file}"
                        )
                    if int(uart_result.get("loader_bad_frames", 0)) != 0:
                        raise RuntimeError(f"Beacon selftest saw bad frames; see {capture_file}")
                    if int(uart_result.get("loader_session_count", 0)) != 1:
                        raise RuntimeError(f"Beacon selftest expected exactly one session; see {capture_file}")
                elif args.loader_early_audit:
                    if uart_result.get("loader_session_start_not_found"):
                        raise RuntimeError(f"Early-audit session start not found; see {capture_file}")
                    if uart_result.get("loader_bad_seen") or uart_result.get("loader_bad_magic_seen"):
                        raise RuntimeError(
                            f"Early-audit loader reported failure ({uart_result.get('bad_reason', 'unknown')}, "
                            f"byte={uart_result.get('loader_bad_magic_byte_index', 'N/A')}); see {capture_file}"
                        )
                    if not uart_result.get("loader_ready_seen"):
                        raise RuntimeError(f"Early-audit missing READY; see {capture_file}")
                    if not uart_result.get("loader_header_magic_ok"):
                        raise RuntimeError(
                            f"Early-audit missing HDR_MAGIC_OK ({uart_result.get('loader_session_classification', 'other')}); see {capture_file}"
                        )
                    if not uart_result.get("loader_load_start_seen"):
                        raise RuntimeError(
                            f"Early-audit missing LOAD_START ({uart_result.get('loader_session_classification', 'other')}); see {capture_file}"
                        )
                    if not uart_result.get("loader_first_block_ack_seen"):
                        raise RuntimeError(
                            f"Early-audit missing BLOCK_ACK(0) ({uart_result.get('loader_session_classification', 'other')}); see {capture_file}"
                        )
                    if not uart_result.get("loader_summary_seen"):
                        raise RuntimeError(f"Early-audit missing SUMMARY; see {capture_file}")
                    if not uart_result.get("loader_summary_ok"):
                        raise RuntimeError(f"Early-audit SUMMARY indicates failure; see {capture_file}")
                else:
                    if uart_result.get("loader_bad_seen"):
                        raise RuntimeError(f"Loader beacon reported failure ({uart_result.get('bad_reason', 'unknown')}); see {capture_file}")
                    if not uart_result.get("loader_summary_seen"):
                        raise RuntimeError(f"Loader beacon missing SUMMARY; see {capture_file}")
                    if not uart_result.get("loader_summary_ok"):
                        raise RuntimeError(f"Loader SUMMARY indicates failure; see {capture_file}")
                    if not uart_result.get("saw_start"):
                        raise RuntimeError(f"UART missing DHRYSTONE START; see {capture_file}")
                    if not uart_result.get("saw_done"):
                        raise RuntimeError(f"UART missing DHRYSTONE DONE; see {capture_file}")
    except Exception as exc:  # noqa: BLE001
        failed_stage = current_stage
        failure_detail = str(exc)

    timing = parse_timing_summary(TIMING_SUMMARY_AGGR)
    loader_quick_sim_result = (
        analyze_loader_sim_log(read_text(loader_quick_sim_log))
        if loader_quick_sim_log and loader_quick_sim_log.exists()
        else {}
    )
    loader_full_prefix1_sim_result = (
        analyze_loader_sim_log(read_text(loader_full_prefix1_sim_log))
        if loader_full_prefix1_sim_log and loader_full_prefix1_sim_log.exists()
        else {}
    )
    loader_full_prefix4_sim_result = (
        analyze_loader_sim_log(read_text(loader_full_prefix4_sim_log))
        if loader_full_prefix4_sim_log and loader_full_prefix4_sim_log.exists()
        else {}
    )
    loader_full_long_sim_result = (
        analyze_loader_sim_log(read_text(loader_full_long_sim_log))
        if loader_full_long_sim_log and loader_full_long_sim_log.exists()
        else {}
    )
    fetch_probe = uart_result.get("fetch_probe", {}) if isinstance(uart_result.get("fetch_probe", {}), dict) else {}
    bad_block = uart_result.get("bad_block", {}) if isinstance(uart_result.get("bad_block", {}), dict) else {}
    bad_checksum = uart_result.get("bad_checksum", {}) if isinstance(uart_result.get("bad_checksum", {}), dict) else {}
    write_blocks = uart_result.get("write_blocks", {}) if isinstance(uart_result.get("write_blocks", {}), dict) else {}
    transport_sessions = uart_result.get("session_results", []) if isinstance(uart_result.get("session_results", []), list) else []
    bridge_steps_bad = uart_result.get("bad_detail", {}) if isinstance(uart_result.get("bad_detail", {}), dict) else {}
    step2_only_bad = uart_result.get("bad_detail", {}) if isinstance(uart_result.get("bad_detail", {}), dict) else {}
    step2_last_phase = uart_result.get("last_phase_detail", {}) if isinstance(uart_result.get("last_phase_detail", {}), dict) else {}
    step2_last_progress = uart_result.get("last_progress_detail", {}) if isinstance(uart_result.get("last_progress_detail", {}), dict) else {}
    summary_lines = [
        f"Flow: {flow_name}",
        f"Result: {'PASS' if failed_stage == 'none' else 'FAIL'}",
        f"FailedStage: {failed_stage}",
        f"FailureDetail: {failure_detail or 'none'}",
        f"Benchmark: {args.benchmark}",
        f"TransportOnly: {args.transport_only}",
        f"BridgeAudit: {args.bridge_audit}",
        f"BridgeAuditSteps: {args.bridge_audit_steps}",
        f"BridgeAuditStep2Only: {args.bridge_audit_step2_only}",
        f"RSDepth: {args.rs_depth}",
        f"FetchBufferDepth: {args.fetch_buffer_depth}",
        f"CoreClkMHz: {args.core_clk_mhz:.1f}",
        f"UartBaud: {args.uart_baud}",
        "EnableMemSubsys: 1",
        "EnableDDR3: 1",
        "L2Passthrough: 1",
        f"FetchDebug: {args.fetch_debug}",
        f"TransportJitterPct: {args.transport_jitter_pct}",
        f"TransportByteGapBits: {args.transport_byte_gap}",
        f"TransportAckMode: {args.transport_ack_mode}",
        f"TransportSeeds: {args.transport_seeds}",
        f"RegisteredUartRxdata: {USE_REGISTERED_UART_RXDATA}",
        f"BuildID: {build_id}",
        f"TopSimLog: {sim_log}",
        f"LoaderQuickSimLog: {loader_quick_sim_log}",
        f"LoaderFullPrefix1SimLog: {loader_full_prefix1_sim_log}",
        f"LoaderFullPrefix4SimLog: {loader_full_prefix4_sim_log}",
        f"LoaderFullPayloadSimLog: {loader_full_prefix4_sim_log}",
        f"LoaderFullLongSimLog: {loader_full_long_sim_log}",
        "LoaderFullGateMode: prefix1",
        f"LoaderFullGateTargetBlocks: {LOADER_FULL_PREFIX1_BLOCKS}",
        f"BenchmarkManifest: {manifest.get('bin', 'N/A')}",
        f"SmokeManifest: {smoke_manifest.get('bin', 'N/A')}",
        f"BaselineManifest: {baseline_manifest.get('bin', 'N/A')}",
        f"EarlyAuditManifest: {early_audit_manifest.get('bin', 'N/A')}",
        f"EarlyAuditFaultLogs: {','.join(early_audit_fault_logs) if early_audit_fault_logs else 'N/A'}",
        f"TransportBoardPayloadCount: {len(transport_manifests)}",
        f"TransportTbCaseCount: {len(transport_tb_results)}",
        f"BridgeTbCaseCount: {len(bridge_tb_results)}",
        f"TimingSummaryAggressive: {TIMING_SUMMARY_AGGR}",
        f"TimingDetailAggressive: {TIMING_DETAIL_AGGR}",
        f"UtilizationAggressive: {UTILIZATION_AGGR}",
        f"WNS: {timing['wns']}",
        f"WHS: {timing['whs']}",
        f"ConstraintsMet: {timing['constraints_met']}",
        f"UartCaptureFile: {capture_file if capture_file.exists() else (sim_log if sim_log else 'N/A')}",
        f"UartCaptureRawFile: {uart_result.get('uart_capture_raw_file', 'N/A')}",
        f"LoaderDecodedCaptureFile: {uart_result.get('loader_decoded_log_path', uart_result.get('decoded_log_path', 'N/A'))}",
        f"LoaderEarlyAuditSessionsFile: {uart_result.get('loader_sessions_json_path', 'N/A')}",
        f"LoaderBeaconSelftestSessionsFile: {uart_result.get('loader_sessions_json_path', 'N/A')}",
        f"SmokeCaptureFile: {UART_SMOKE_CAPTURE_FILE if UART_SMOKE_CAPTURE_FILE.exists() else 'N/A'}",
        f"SmokeCaptureRawFile: {UART_SMOKE_CAPTURE_RAW_FILE if UART_SMOKE_CAPTURE_RAW_FILE.exists() else 'N/A'}",
        f"SmokeLoaderDecodedFile: {UART_SMOKE_CAPTURE_LOADER_DECODED_FILE if UART_SMOKE_CAPTURE_LOADER_DECODED_FILE.exists() else 'N/A'}",
        f"SmokePassed: {bool(uart_smoke_result.get('loader_summary_ok', False) and uart_smoke_result.get('saw_start', False) and uart_smoke_result.get('saw_done', False))}",
        f"SmokeLoaderSummaryMask: {fmt_optional_hex(uart_smoke_result.get('loader_summary_mask', 'N/A'))}",
        f"SmokeSawDhrystoneStart: {uart_smoke_result.get('saw_start', False)}",
        f"SmokeSawDhrystoneDone: {uart_smoke_result.get('saw_done', False)}",
        f"BaselineCaptureFile: {UART_CAPTURE_FILE if UART_CAPTURE_FILE.exists() else 'N/A'}",
        f"BaselineCaptureRawFile: {UART_CAPTURE_RAW_FILE if UART_CAPTURE_RAW_FILE.exists() else 'N/A'}",
        f"BaselineLoaderDecodedFile: {UART_CAPTURE_LOADER_DECODED_FILE if UART_CAPTURE_LOADER_DECODED_FILE.exists() else 'N/A'}",
        f"BaselinePassed: {bool(uart_result.get('loader_summary_ok', False) and uart_result.get('saw_start', False) and uart_result.get('saw_done', False))}",
        f"UartSawReady: {uart_result.get('saw_ready', uart_result.get('ready_seen', False))}",
        f"UartSawLoadStart: {uart_result.get('saw_load_start', False)}",
        f"UartSawReadOK: {uart_result.get('saw_read_ok', False)}",
        f"UartSawLoadOK: {uart_result.get('saw_load_ok', False)}",
        f"UartSawJump: {uart_result.get('saw_jump', False)}",
        f"UartBadReason: {uart_result.get('bad_reason', 'none')}",
        f"UartPayloadAckTimeout: {uart_result.get('payload_ack_timeout', False)}",
        f"UartPayloadChunksSent: {uart_result.get('payload_chunks_sent', 0)}",
        f"UartPayloadAckCount: {uart_result.get('payload_ack_count', 0)}",
        f"UartPayloadAckCreditRemaining: {uart_result.get('payload_ack_credit_remaining', 0)}",
        f"UartPayloadBlockAckCount: {uart_result.get('payload_block_ack_count', 0)}",
        f"UartPayloadBlockNackCount: {uart_result.get('payload_block_nack_count', 0)}",
        f"UartPayloadBlockRetryCount: {uart_result.get('payload_block_retry_count', 0)}",
        f"UartPayloadBlockRetryLimitHit: {uart_result.get('payload_block_retry_limit_hit', False)}",
        f"UartPayloadFailedBlock: {uart_result.get('payload_failed_block', -1)}",
        f"LoaderReadySeen: {uart_result.get('saw_ready', False)}",
        f"LoaderLoadStartSeen: {uart_result.get('saw_load_start', False)}",
        f"LoaderReadOkSeen: {uart_result.get('saw_read_ok', False)}",
        f"LoaderLoadOkSeen: {uart_result.get('saw_load_ok', False)}",
        f"LoaderJumpSeen: {uart_result.get('saw_jump', False)}",
        f"LoaderSummarySeen: {uart_result.get('loader_summary_seen', False)}",
        f"LoaderSummaryMask: {fmt_optional_hex(uart_result.get('loader_summary_mask', 'N/A'))}",
        f"LoaderSummaryOk: {uart_result.get('loader_summary_ok', False)}",
        f"LoaderBadSeen: {uart_result.get('loader_bad_seen', False)}",
        f"LoaderBadCode: {fmt_optional_hex(uart_result.get('loader_bad_code', 'N/A'))}",
        f"LoaderBadBlock: {uart_result.get('loader_bad_block', 'N/A')}",
        f"LoaderGoodFrames: {uart_result.get('loader_good_frames', 0)}",
        f"LoaderBadFrames: {uart_result.get('loader_bad_frames', 0)}",
        f"LoaderDroppedDuplicateFrames: {uart_result.get('loader_dropped_duplicate_frames', 0)}",
        f"LoaderBlockAckEvents: {uart_result.get('loader_block_ack_events', 0)}",
        f"LoaderBlockNackEvents: {uart_result.get('loader_block_nack_events', 0)}",
        f"LoaderPreSessionFrameCount: {uart_result.get('loader_pre_session_frame_count', uart_result.get('pre_session_frame_count', 'N/A'))}",
        f"LoaderSessionStartOffset: {fmt_optional_hex(uart_result.get('loader_session_start_offset', uart_result.get('session_start_offset', 'N/A')))}",
        f"LoaderSessionReadySeq: {uart_result.get('loader_session_ready_seq', uart_result.get('session_ready_seq', 'N/A'))}",
        f"LoaderSessionStartNotFound: {uart_result.get('loader_session_start_not_found', uart_result.get('session_start_not_found', False))}",
        f"LoaderEarlyAuditSessionCount: {uart_result.get('loader_session_count', len(uart_result.get('sessions', [])) if isinstance(uart_result.get('sessions'), list) else 'N/A')}",
        f"LoaderEarlyAuditChosenSessionIndex: {uart_result.get('loader_chosen_session_index', 'N/A')}",
        f"LoaderEarlyAuditChosenSessionOffset: {fmt_optional_hex(uart_result.get('loader_chosen_session_start_offset', uart_result.get('loader_session_start_offset', uart_result.get('session_start_offset', 'N/A'))))}",
        f"LoaderEarlyAuditChosenSessionReadyArg: {uart_result.get('loader_chosen_session_ready_arg', 'N/A')}",
        f"LoaderEarlyAuditChosenSessionFirstEvents: {','.join(uart_result.get('loader_chosen_session_first_events', [])) if isinstance(uart_result.get('loader_chosen_session_first_events', []), list) else 'N/A'}",
        f"LoaderEarlyAuditChosenSessionOrderValid: {uart_result.get('loader_chosen_session_order_valid', 'N/A')}",
        f"LoaderEarlyAuditChosenSessionOrderError: {uart_result.get('loader_chosen_session_order_error', '')}",
        f"LoaderEarlyAuditSessionClassification: {uart_result.get('loader_session_classification', 'N/A')}",
        f"LoaderEarlyAuditReadySeen: {uart_result.get('loader_ready_seen', uart_result.get('ready_seen', False))}",
        f"LoaderEarlyAuditIdleOkSeen: {uart_result.get('loader_idle_ok_seen', uart_result.get('idle_ok_seen', False))}",
        f"LoaderEarlyAuditTrainStartSeen: {uart_result.get('loader_train_start_seen', uart_result.get('train_start_seen', False))}",
        f"LoaderEarlyAuditTrainDoneSeen: {uart_result.get('loader_train_done_seen', uart_result.get('train_done_seen', False))}",
        f"LoaderEarlyAuditTrainDoneCount: {uart_result.get('loader_train_done_count', uart_result.get('train_done_count', 'N/A'))}",
        f"LoaderEarlyAuditFlushDoneSeen: {uart_result.get('loader_flush_done_seen', uart_result.get('flush_done_seen', False))}",
        f"LoaderEarlyAuditFlushDoneCount: {uart_result.get('loader_flush_done_count', uart_result.get('flush_done_count', 'N/A'))}",
        f"LoaderEarlyAuditHeaderEnterSeen: {uart_result.get('loader_header_enter_seen', uart_result.get('header_enter_seen', False))}",
        f"LoaderEarlyAuditTrainTimeoutSeen: {uart_result.get('loader_train_timeout_seen', uart_result.get('train_timeout_seen', False))}",
        f"LoaderEarlyAuditTrainTimeoutCount: {uart_result.get('loader_train_timeout_count', uart_result.get('train_timeout_count', 'N/A'))}",
        f"LoaderEarlyAuditFlushTimeoutSeen: {uart_result.get('loader_flush_timeout_seen', uart_result.get('flush_timeout_seen', False))}",
        f"LoaderEarlyAuditFlushTimeoutCount: {uart_result.get('loader_flush_timeout_count', uart_result.get('flush_timeout_count', 'N/A'))}",
        f"LoaderEarlyAuditHeaderByte0: {fmt_optional_hex(uart_result.get('loader_header_byte0', uart_result.get('header_byte0', 'N/A')))}",
        f"LoaderEarlyAuditHeaderByte1: {fmt_optional_hex(uart_result.get('loader_header_byte1', uart_result.get('header_byte1', 'N/A')))}",
        f"LoaderEarlyAuditHeaderByte2: {fmt_optional_hex(uart_result.get('loader_header_byte2', uart_result.get('header_byte2', 'N/A')))}",
        f"LoaderEarlyAuditHeaderByte3: {fmt_optional_hex(uart_result.get('loader_header_byte3', uart_result.get('header_byte3', 'N/A')))}",
        f"LoaderEarlyAuditBadMagicSeen: {uart_result.get('loader_bad_magic_seen', uart_result.get('bad_magic_seen', False))}",
        f"LoaderEarlyAuditBadMagicByteIndex: {uart_result.get('loader_bad_magic_byte_index', uart_result.get('bad_magic_byte_index', 'N/A'))}",
        f"LoaderEarlyAuditHeaderMagicOk: {uart_result.get('loader_header_magic_ok', uart_result.get('header_magic_ok', False))}",
        f"LoaderEarlyAuditLoadStartSeen: {uart_result.get('loader_load_start_seen', uart_result.get('load_start_seen', False))}",
        f"LoaderEarlyAuditFirstBlockAckSeen: {uart_result.get('loader_first_block_ack_seen', uart_result.get('first_block_ack_seen', False))}",
        f"LoaderEarlyAuditSummaryMask: {fmt_optional_hex(uart_result.get('loader_summary_mask', uart_result.get('summary_mask', 'N/A')))}",
        f"LoaderEarlyAuditPass: {bool(uart_result.get('loader_ready_seen', uart_result.get('ready_seen', False)) and uart_result.get('loader_header_magic_ok', uart_result.get('header_magic_ok', False)) and uart_result.get('loader_load_start_seen', uart_result.get('load_start_seen', False)) and uart_result.get('loader_first_block_ack_seen', uart_result.get('first_block_ack_seen', False)) and uart_result.get('loader_summary_ok', uart_result.get('summary_ok_seen', False)) and not uart_result.get('loader_bad_seen', uart_result.get('bad_seen', False)) and not uart_result.get('loader_session_start_not_found', uart_result.get('session_start_not_found', False)))}",
        f"LoaderBeaconSelftestPass: {uart_result.get('loader_beacon_selftest_pass', False)}",
        f"LoaderBeaconSelftestSessionCount: {uart_result.get('loader_session_count', 'N/A')}",
        f"LoaderBeaconSelftestPassSessionCount: {uart_result.get('loader_pass_session_count', 'N/A')}",
        f"LoaderBeaconSelftestGoodFrames: {uart_result.get('loader_good_frames', 0)}",
        f"LoaderBeaconSelftestBadFrames: {uart_result.get('loader_bad_frames', 0)}",
        f"LoaderBeaconSelftestClassification: {uart_result.get('loader_session_classification', 'N/A')}",
        f"LoaderBeaconSelftestChosenSessionIndex: {uart_result.get('loader_chosen_session_index', 'N/A')}",
        f"LoaderBeaconSelftestChosenSessionOffset: {fmt_optional_hex(uart_result.get('loader_chosen_session_start_offset', 'N/A'))}",
        f"LoaderBeaconSelftestChosenSessionReadyArg: {fmt_optional_hex(uart_result.get('loader_chosen_session_ready_arg', 'N/A'))}",
        f"LoaderBeaconSelftestChosenSessionFirstEvents: {','.join(uart_result.get('loader_chosen_session_first_events', [])) if isinstance(uart_result.get('loader_chosen_session_first_events', []), list) else 'N/A'}",
        f"LoaderBeaconSelftestChosenSessionMatchedPrefixLen: {uart_result.get('loader_chosen_session_matched_prefix_len', 'N/A')}",
        f"LoaderBeaconSelftestChosenSessionEventCount: {uart_result.get('loader_chosen_session_event_count', 'N/A')}",
        f"LoaderBeaconSelftestChosenSessionOrderValid: {uart_result.get('loader_chosen_session_order_valid', 'N/A')}",
        f"LoaderBeaconSelftestChosenSessionOrderError: {uart_result.get('loader_chosen_session_order_error', '')}",
        f"LoaderFullPrefix1Pass: {loader_prefix_target_ok(loader_full_prefix1_sim_result, LOADER_FULL_PREFIX1_BLOCKS)}",
        f"LoaderFullPrefix1AckEvents: {loader_full_prefix1_sim_result.get('block_ack_events', 0)}",
        f"LoaderFullPrefix1MaxAckBlock: {loader_full_prefix1_sim_result.get('max_block_ack_arg', 'N/A')}",
        f"LoaderFullPrefix1NackEvents: {loader_full_prefix1_sim_result.get('block_nack_events', 0)}",
        f"LoaderFullGateAckEvents: {loader_full_prefix1_sim_result.get('block_ack_events', 0)}",
        f"LoaderFullGateMaxAckBlock: {loader_full_prefix1_sim_result.get('max_block_ack_arg', 'N/A')}",
        f"LoaderFullGateNackEvents: {loader_full_prefix1_sim_result.get('block_nack_events', 0)}",
        f"LoaderFullGatePass: {loader_prefix_target_ok(loader_full_prefix1_sim_result, LOADER_FULL_PREFIX1_BLOCKS)}",
        f"LoaderFullGateBadSeen: {loader_full_prefix1_sim_result.get('bad_seen', False)}",
        f"LoaderFullGateBadCode: {fmt_optional_hex(loader_full_prefix1_sim_result.get('bad_code', 'N/A'))}",
        f"LoaderFullGateBadBlock: {loader_full_prefix1_sim_result.get('bad_block', 'N/A')}",
        f"LoaderFullGateFirstBadEventOffset: {loader_full_prefix1_sim_result.get('first_bad_event_offset', 'N/A')}",
        f"LoaderFullPrefix4Pass: {loader_prefix_target_ok(loader_full_prefix4_sim_result, LOADER_FULL_PREFIX4_BLOCKS) if args.run_loader_long_sim else False}",
        f"LoaderFullPrefix4AckEvents: {loader_full_prefix4_sim_result.get('block_ack_events', 0)}",
        f"LoaderFullPrefix4MaxAckBlock: {loader_full_prefix4_sim_result.get('max_block_ack_arg', 'N/A')}",
        f"LoaderFullPrefix4NackEvents: {loader_full_prefix4_sim_result.get('block_nack_events', 0)}",
        f"LoaderFullLongRequested: {args.run_loader_long_sim}",
        f"LoaderFullLongPass: {loader_prefix_target_ok(loader_full_long_sim_result, LOADER_FULL_PREFIX16_BLOCKS) if args.run_loader_long_sim else False}",
        f"LoaderFullLongTargetBlocks: {LOADER_FULL_PREFIX16_BLOCKS}",
        f"LoaderFullLongAckEvents: {loader_full_long_sim_result.get('block_ack_events', 0)}",
        f"LoaderFullLongMaxAckBlock: {loader_full_long_sim_result.get('max_block_ack_arg', 'N/A')}",
        f"LoaderFullLongNackEvents: {loader_full_long_sim_result.get('block_nack_events', 0)}",
        f"LoaderFullPrefix4FailureDetail: {loader_full_prefix4_failure_detail or 'none'}",
        f"LoaderFullLongFailureDetail: {loader_full_long_failure_detail or 'none'}",
        f"LoaderFullLongLog: {loader_full_long_sim_log}",
        f"LoaderQuickGateExecPassSeen: {loader_quick_sim_result.get('saw_exec_pass', False)}",
        f"UartSawFetchProbe: {uart_result.get('saw_probe', False)}",
        f"FetchProbeClassification: {fetch_probe.get('classification', 'N/A')}",
        f"FetchProbeLastLine: {fetch_probe.get('last_line', 'N/A')}",
        f"LoaderBadBlockIndex: {bad_block.get('block_index', 'N/A')}",
        f"LoaderBadBlockHostChecksum: {bad_block.get('host_checksum32', 'N/A')}",
        f"LoaderBadBlockWriteChecksum: {bad_block.get('write_checksum32', 'N/A')}",
        f"LoaderBadBlockReadChecksum: {bad_block.get('read_checksum32', 'N/A')}",
        f"LoaderBadBlockCause: {bad_block.get('cause', 'N/A')}",
        f"LoaderBadChecksumExpected: {bad_checksum.get('expected_checksum32', 'N/A')}",
        f"LoaderBadChecksumActual: {bad_checksum.get('actual_checksum32', 'N/A')}",
        f"LoaderBadChecksumDeltaSigned: {bad_checksum.get('delta_signed', 'N/A')}",
        f"LoaderWriteBlocksDumped: {write_blocks.get('dumped_blocks', 'N/A')}",
        f"LoaderWriteBlockFirstMismatch: {write_blocks.get('block_index', 'N/A')}",
        f"LoaderWriteBlockHostChecksum: {write_blocks.get('host_checksum32', 'N/A')}",
        f"LoaderWriteBlockDeviceChecksum: {write_blocks.get('device_checksum32', 'N/A')}",
        f"UartSawDhrystoneStart: {uart_result.get('saw_start', False)}",
        f"UartSawDhrystoneDone: {uart_result.get('saw_done', False)}",
        f"TransportBoardReadySeen: {uart_result.get('ready_seen', False)}",
        f"TransportBoardSessionsOK: {uart_result.get('session_count', 0)}",
        f"TransportBoardSessionsExpected: {uart_result.get('expected_sessions', 0)}",
        f"BridgeBoardReadySeen: {uart_result.get('ready_seen', False)}",
        f"BridgeBoardOkCount: {uart_result.get('ok_count', 0)}",
        f"BridgeBoardBadSeen: {uart_result.get('saw_bad', False)}",
        f"BridgeBoardBadReason: {uart_result.get('bad_reason', 'none')}",
        f"BridgeBoardBadLine: {uart_result.get('last_bad_line', '')}",
        f"BridgeStepsReadySeen: {uart_result.get('ready_seen', False)}",
        f"BridgeStep1Pass: {uart_result.get('step1_pass', False)}",
        f"BridgeStep2Pass: {uart_result.get('step2_pass', False)}",
        f"BridgeStep3Pass: {uart_result.get('step3_pass', False)}",
        f"BridgeStep3_2WordPass: {uart_result.get('step3_2_pass', False)}",
        f"BridgeStep3_4WordPass: {uart_result.get('step3_4_pass', False)}",
        f"BridgeStepsAllOkSeen: {uart_result.get('all_ok_seen', False)}",
        f"BridgeBadStep: {bridge_steps_bad.get('step', 'N/A')}",
        f"BridgeBadWords: {bridge_steps_bad.get('words', 'N/A')}",
        f"BridgeBadAddr: {fmt_optional_hex(bridge_steps_bad.get('addr', 'N/A'))}",
        f"BridgeBadExpected: {fmt_optional_hex(bridge_steps_bad.get('expected', 'N/A'))}",
        f"BridgeBadActual: {fmt_optional_hex(bridge_steps_bad.get('actual', 'N/A'))}",
        f"BridgeLastWriteAddr: {fmt_optional_hex(bridge_steps_bad.get('last_write_addr', 'N/A'))}",
        f"BridgeLastWriteData: {fmt_optional_hex(bridge_steps_bad.get('last_write_data', 'N/A'))}",
        f"BridgeDrainReady: {bridge_steps_bad.get('drain_ready', 'N/A')}",
        f"BridgeBridgeIdle: {bridge_steps_bad.get('bridge_idle', 'N/A')}",
        f"BridgeStatusWord: {fmt_optional_hex(bridge_steps_bad.get('status_word', 'N/A'))}",
        f"BridgeStepsBadLine: {bridge_steps_bad.get('line', '')}",
        f"Step2ReadySeen: {uart_result.get('ready_seen', False)}",
        f"Step2SawStartCase1: {uart_result.get('saw_start_case1', False)}",
        f"Step2Case1Pass: {uart_result.get('case1_pass', False)}",
        f"Step2SawStartCase2: {uart_result.get('saw_start_case2', False)}",
        f"Step2Case2Pass: {uart_result.get('case2_pass', False)}",
        f"Step2SawStartCase3: {uart_result.get('saw_start_case3', False)}",
        f"Step2SawAfterWriteCase3: {uart_result.get('saw_after_write_case3', False)}",
        f"Step2Case3Pass: {uart_result.get('case3_pass', False)}",
        f"Step2SawStartCase4: {uart_result.get('saw_start_case4', False)}",
        f"Step2SawAfterWriteCase4: {uart_result.get('saw_after_write_case4', False)}",
        f"Step2Case4Pass: {uart_result.get('case4_pass', False)}",
        f"Step2SawStartCase5: {uart_result.get('saw_start_case5', False)}",
        f"Step2SawAfterWriteCase5: {uart_result.get('saw_after_write_case5', False)}",
        f"Step2Case5Pass: {uart_result.get('case5_pass', False)}",
        "Step2VariantCase3: base",
        "Step2VariantCase4: nop_pad",
        "Step2VariantCase5: load_barrier",
        f"Step2AllOkSeen: {uart_result.get('all_ok_seen', False)}",
        f"Step2SummarySeen: {uart_result.get('summary_seen', False)}",
        f"Step2SummaryMask: {fmt_optional_hex(uart_result.get('summary_mask', 'N/A'))}",
        f"Step2TrapSeen: {uart_result.get('saw_trap', False)}",
        f"Step2CalFailSeen: {uart_result.get('saw_cal_fail', False)}",
        f"Step2BadSeen: {uart_result.get('saw_bad', False)}",
        f"Step2BadCase: {step2_only_bad.get('case', 'N/A')}",
        f"Step2BadPhase: {step2_only_bad.get('phase', 'N/A')}",
        f"Step2BadAddr: {fmt_optional_hex(step2_only_bad.get('addr', 'N/A'))}",
        f"Step2BadExpected: {fmt_optional_hex(step2_only_bad.get('expected', 'N/A'))}",
        f"Step2BadActual: {fmt_optional_hex(step2_only_bad.get('actual', 'N/A'))}",
        f"Step2Write0Addr: {fmt_optional_hex(step2_only_bad.get('write0_addr', 'N/A'))}",
        f"Step2Write0Data: {fmt_optional_hex(step2_only_bad.get('write0_data', 'N/A'))}",
        f"Step2Write1Addr: {fmt_optional_hex(step2_only_bad.get('write1_addr', 'N/A'))}",
        f"Step2Write1Data: {fmt_optional_hex(step2_only_bad.get('write1_data', 'N/A'))}",
        f"Step2DrainReady: {step2_only_bad.get('drain_ready', 'N/A')}",
        f"Step2BridgeIdle: {step2_only_bad.get('bridge_idle', 'N/A')}",
        f"Step2StoreBufferEmpty: {step2_only_bad.get('store_buffer_empty', 'N/A')}",
        f"Step2StoreCountT0: {step2_only_bad.get('store_count_t0', 'N/A')}",
        f"Step2StoreCountT1: {step2_only_bad.get('store_count_t1', 'N/A')}",
        f"Step2StatusWord: {fmt_optional_hex(step2_only_bad.get('status_word', 'N/A'))}",
        f"Step2BadLine: {step2_only_bad.get('line', '')}",
        f"Step2LastPhaseCase: {step2_last_phase.get('case', 'N/A')}",
        f"Step2LastPhase: {step2_last_phase.get('phase', 'N/A')}",
        f"Step2LastPhaseLine: {step2_last_phase.get('line', '')}",
        f"Step2LastProgressKind: {step2_last_progress.get('kind', 'N/A')}",
        f"Step2LastProgressCase: {step2_last_progress.get('case', 'N/A')}",
        f"Step2LastProgressPhase: {step2_last_progress.get('phase', 'N/A')}",
        f"Step2LastProgressLine: {step2_last_progress.get('line', '')}",
        f"Step2GoodFrames: {uart_result.get('good_frames', 0)}",
        f"Step2BadFrames: {uart_result.get('bad_frames', 0)}",
        f"Step2DroppedDuplicateFrames: {uart_result.get('dropped_duplicate_frames', 0)}",
        f"Step2DecodedCaptureFile: {uart_result.get('decoded_log_path', 'N/A')}",
        f"UartCaptureBytes: {uart_result.get('capture_bytes', 0)}",
        f"BenchCycles: {uart_result.get('bench_cycles', '')}",
        f"BenchInstRetired: {uart_result.get('bench_instret', '')}",
        f"BenchIPCx1000: {uart_result.get('bench_ipc_x1000', '')}",
        f"DhrystonesPerSecond: {','.join(uart_result.get('dhrystones_per_second', []))}",
        f"MicrosecondsPerRun: {','.join(uart_result.get('microseconds_per_run', []))}",
    ]
    for tb_case in transport_tb_results:
        summary_lines.append(
            "TransportTbCase: "
            f"{tb_case.get('name')} size={tb_case.get('payload_size')} seed={tb_case.get('seed')} "
            f"jitter={tb_case.get('jitter_pct')} gap={tb_case.get('byte_gap_bits')} ack_extra={tb_case.get('ack_extra_bits')} "
            f"log={tb_case.get('log')}"
        )
    for tb_case in bridge_tb_results:
        summary_lines.append(
            "BridgeTbCase: "
            f"{tb_case.get('name')} core_clk_ns={tb_case.get('core_clk_ns')} ui_clk_ns={tb_case.get('ui_clk_ns')} "
            f"seed={tb_case.get('seed')} log={tb_case.get('log')}"
        )
    for session in transport_sessions:
        summary_lines.append(
            "TransportBoardSession: "
            f"index={session.get('index')} size={session.get('size_bytes')} checksum32={session.get('checksum32')} seed={session.get('seed')}"
        )
    summary_path = logs_dir / "summary.txt"
    write_summary(summary_path, summary_lines)
    print(summary_path)
    return 0 if failed_stage == "none" else 1


if __name__ == "__main__":
    raise SystemExit(main())
