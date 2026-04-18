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
TRANSPORT_ROM = ROM_DIR / "test_fpga_uart_loader_transport.s"
BRIDGE_STRESS_ROM = ROM_DIR / "test_fpga_ddr3_bridge_stress.s"
BRIDGE_STEPS_ROM = ROM_DIR / "test_fpga_ddr3_bridge_steps.s"
STEP2_ONLY_ROM = ROM_DIR / "test_fpga_ddr3_bridge_step2_only.s"
TINY_PAYLOAD_ROM = ROM_DIR / "test_fpga_ddr3_exec_payload.s"
LOADER_TB = COMP_TEST_DIR / "tb_ax7203_top_ddr3_loader_smoke.sv"
LOADER_TB_TOP = "tb_ax7203_top_ddr3_loader_smoke"
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
TRANSPORT_CAPTURE_FILE = BUILD_DIR / "uart_loader_transport_capture.txt"
BRIDGE_CAPTURE_FILE = BUILD_DIR / "ddr3_bridge_audit_uart_capture.txt"
BRIDGE_STEPS_CAPTURE_FILE = BUILD_DIR / "ddr3_bridge_audit_steps_uart_capture.txt"
STEP2_ONLY_CAPTURE_FILE = BUILD_DIR / "ddr3_bridge_audit_step2_only_uart_capture.txt"
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


def build_env(
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    *,
    fetch_debug: bool = False,
    bridge_audit: bool = False,
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
            "AX7203_SMT_MODE": "1",
            "AX7203_RS_DEPTH": str(rs_depth),
            "AX7203_RS_IDX_W": str(derive_idx_width(rs_depth)),
            "AX7203_FETCH_BUFFER_DEPTH": str(fetch_buffer_depth),
            "AX7203_CORE_CLK_MHZ": f"{core_clk_mhz:.1f}",
            "AX7203_UART_CLK_DIV": str(derive_uart_clk_div(core_clk_mhz, uart_baud)),
            "AX7203_ROM_ASM": str(LOADER_ROM),
            "AX7203_TOP_MODULE": "adam_riscv_ax7203_top",
            "AX7203_DDR3_FETCH_DEBUG": "1" if fetch_debug else "0",
            "AX7203_DDR3_BRIDGE_AUDIT": "1" if bridge_audit else "0",
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


def run_loader_top_sim(
    logs_dir: Path,
    *,
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    fetch_debug: bool = False,
    uart_baud: int = 115200,
) -> Path:
    tiny = compile_ddr3_asm_payload(TINY_PAYLOAD_ROM, logs_dir / "tiny_payload", "ddr3_exec_payload")
    write_payload_hex(Path(tiny["bin"]))
    run_logged(
        [
            sys.executable,
            str(REPO_ROOT / "fpga" / "scripts" / "build_rom_image.py"),
            "--asm",
            str(LOADER_ROM),
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
    tb_uart_bit_ns = max(1, round(1_000_000_000.0 / float(uart_baud)))
    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        "-DENABLE_MEM_SUBSYS=1",
        "-DENABLE_DDR3=1",
        "-DL2_PASSTHROUGH=1",
        "-DTRANSPORT_UART_RXDATA_REG_TEST=1",
        *debug_defines,
        "-DENABLE_ROCC_ACCEL=0",
        "-DSMT_MODE=1",
        "-DTB_SHORT_TIMEOUT_NS=30000000",
        f"-DTB_UART_BIT_NS={tb_uart_bit_ns}",
        f"-DFPGA_SCOREBOARD_RS_DEPTH={rs_depth}",
        f"-DFPGA_SCOREBOARD_RS_IDX_W={derive_idx_width(rs_depth)}",
        f"-DFPGA_FETCH_BUFFER_DEPTH={fetch_buffer_depth}",
        f"-DFPGA_CLK_WIZ_HALF_DIV={derive_clk_wiz_half_div(core_clk_mhz)}",
        f"-DFPGA_UART_CLK_DIV={derive_uart_clk_div(core_clk_mhz, uart_baud)}",
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
    sim_log = logs_dir / "05_run_loader_top_sim.log"
    run_logged(
        [
            which_required("vvp"),
            str(out_file),
            f"+PAYLOAD_SIZE={tiny['size_bytes']}",
            f"+PAYLOAD_CHECKSUM={tiny['checksum32']}",
        ],
        cwd=ROM_DIR,
        log_path=sim_log,
        timeout=1200,
    )
    expect_token = "[AX7203_DDR3_FETCH_PROBE] PASS" if fetch_debug else "[AX7203_DDR3_LOADER] PASS"
    if expect_token not in read_text(sim_log):
        raise RuntimeError(f"DDR3 loader top simulation did not pass; see {sim_log}")
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


def build_dhrystone_payload(logs_dir: Path, *, cpu_hz: int, runs: int) -> dict[str, object]:
    run_logged(
        [
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
        ],
        cwd=REPO_ROOT,
        log_path=logs_dir / "06_build_dhrystone_payload.log",
        timeout=600,
    )
    manifest_path = BUILD_DIR / "benchmark_images" / "dhrystone" / "dhrystone_ddr3.json"
    return json.loads(manifest_path.read_text(encoding="ascii"))


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


def analyze_step2_only_bad_line(text: str) -> dict[str, object]:
    matches = re.findall(
        r"(S2 BAD C=([0-9]) P=([0-9]) A=([0-9A-Fa-f]{8}) E=([0-9A-Fa-f]{8}) R=([0-9A-Fa-f]{8}) "
        r"W0_A=([0-9A-Fa-f]{8}) W0_D=([0-9A-Fa-f]{8}) W1_A=([0-9A-Fa-f]{8}) W1_D=([0-9A-Fa-f]{8}) "
        r"DR=([01]) ID=([01]) SBE=([01]) C0=([0-7]) C1=([0-7]) ST=([0-9A-Fa-f]{8}))",
        text,
    )
    if not matches:
        return {}
    (
        line,
        case_s,
        phase_s,
        addr_s,
        exp_s,
        act_s,
        w0_addr_s,
        w0_data_s,
        w1_addr_s,
        w1_data_s,
        drain_s,
        idle_s,
        sbe_s,
        c0_s,
        c1_s,
        status_s,
    ) = matches[-1]
    return {
        "line": line,
        "case": int(case_s),
        "phase": int(phase_s),
        "addr": int(addr_s, 16),
        "expected": int(exp_s, 16),
        "actual": int(act_s, 16),
        "write0_addr": int(w0_addr_s, 16),
        "write0_data": int(w0_data_s, 16),
        "write1_addr": int(w1_addr_s, 16),
        "write1_data": int(w1_data_s, 16),
        "drain_ready": int(drain_s),
        "bridge_idle": int(idle_s),
        "store_buffer_empty": int(sbe_s),
        "store_count_t0": int(c0_s),
        "store_count_t1": int(c1_s),
        "status_word": int(status_s, 16),
    }


def analyze_step2_only_last_phase(text: str) -> dict[str, object]:
    matches = re.findall(r"(S2 PH C=([0-9]) P=([0-9]))", text)
    if not matches:
        return {}
    line, case_s, phase_s = matches[-1]
    return {
        "line": line,
        "case": int(case_s),
        "phase": int(phase_s),
    }


def analyze_step2_only_last_progress(text: str) -> dict[str, object]:
    pattern = re.compile(
        r"(S2 START C=([1-5]))"
        r"|"
        r"(S2 AFTER WRITE C=([3-5]))"
        r"|"
        r"(S2 OK C=([1-5]))"
        r"|"
        r"(S2 PH C=([0-9]) P=([0-9]))"
    )
    last_match: dict[str, object] = {}
    for match in pattern.finditer(text):
        if match.group(1):
            last_match = {
                "line": match.group(1),
                "kind": "start",
                "case": int(match.group(2)),
            }
        elif match.group(3):
            last_match = {
                "line": match.group(3),
                "kind": "after_write",
                "case": int(match.group(4)),
            }
        elif match.group(5):
            last_match = {
                "line": match.group(5),
                "kind": "ok",
                "case": int(match.group(6)),
            }
        elif match.group(7):
            last_match = {
                "line": match.group(7),
                "kind": "phase",
                "case": int(match.group(8)),
                "phase": int(match.group(9)),
            }
    if not last_match:
        return {}
    return last_match


def step2_case_window(text: str, case_num: int) -> str:
    start_token = f"S2 START C={case_num}"
    start_idx = text.find(start_token)
    if start_idx < 0:
        return ""
    end_candidates: list[int] = []
    for next_case in range(case_num + 1, 6):
        idx = text.find(f"S2 START C={next_case}", start_idx + len(start_token))
        if idx >= 0:
            end_candidates.append(idx)
    all_ok_idx = text.find("S2 ALL OK", start_idx + len(start_token))
    if all_ok_idx >= 0:
        end_candidates.append(all_ok_idx)
    noisy_all_ok_idx = text.find("S2 AALL OK", start_idx + len(start_token))
    if noisy_all_ok_idx >= 0:
        end_candidates.append(noisy_all_ok_idx)
    end_idx = min(end_candidates) if end_candidates else len(text)
    return text[start_idx:end_idx]


def step2_window_has_start(window: str, case_num: int) -> bool:
    return f"S2 START C={case_num}" in window


def step2_window_has_after_write(window: str, case_num: int) -> bool:
    if case_num < 3:
        return False
    if f"S2 AFTER WRITE C={case_num}" in window:
        return True
    return "S2 AFTER WRITE C=" in window


def step2_window_has_ok(window: str, case_num: int) -> bool:
    if f"S2 OK C={case_num}" in window:
        return True
    return re.search(r"S2 OK C=+[0-9]", window) is not None


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
    text_bytes = bytearray()
    ready_seen = False
    saw_start_case1 = False
    case1_pass = False
    saw_start_case2 = False
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
    all_ok_seen = False
    saw_bad = False
    saw_trap = False
    bad_reason = "none"
    bad_detail: dict[str, object] = {}
    last_phase_detail: dict[str, object] = {}
    last_progress_detail: dict[str, object] = {}

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
            ready_seen = "S2 READY" in text
            active_text = slice_after_last_token(text, "S2 READY")
            case1_window = step2_case_window(active_text, 1)
            case2_window = step2_case_window(active_text, 2)
            case3_window = step2_case_window(active_text, 3)
            case4_window = step2_case_window(active_text, 4)
            case5_window = step2_case_window(active_text, 5)
            saw_start_case1 = step2_window_has_start(case1_window, 1)
            case1_pass = step2_window_has_ok(case1_window, 1)
            saw_start_case2 = step2_window_has_start(case2_window, 2)
            case2_pass = step2_window_has_ok(case2_window, 2)
            saw_start_case3 = step2_window_has_start(case3_window, 3)
            saw_after_write_case3 = step2_window_has_after_write(case3_window, 3)
            case3_pass = step2_window_has_ok(case3_window, 3)
            saw_start_case4 = step2_window_has_start(case4_window, 4)
            saw_after_write_case4 = step2_window_has_after_write(case4_window, 4)
            case4_pass = step2_window_has_ok(case4_window, 4)
            saw_start_case5 = step2_window_has_start(case5_window, 5)
            saw_after_write_case5 = step2_window_has_after_write(case5_window, 5)
            case5_pass = step2_window_has_ok(case5_window, 5)
            all_ok_seen = ("S2 ALL OK" in active_text) or ("S2 AALL OK" in active_text)
            last_phase_detail = analyze_step2_only_last_phase(active_text)
            last_progress_detail = analyze_step2_only_last_progress(active_text)
            bad_detail = analyze_step2_only_bad_line(active_text)
            saw_trap = "S2 TRAP" in active_text
            if bad_detail:
                saw_bad = True
                bad_reason = "step2_bad"
                break
            if saw_trap:
                bad_reason = "step2_trap"
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
        "saw_start_case1": saw_start_case1,
        "case1_pass": case1_pass,
        "saw_start_case2": saw_start_case2,
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
        "all_ok_seen": all_ok_seen,
        "saw_bad": saw_bad,
        "saw_trap": saw_trap,
        "bad_reason": bad_reason,
        "bad_detail": bad_detail,
        "last_phase_detail": last_phase_detail,
        "last_progress_detail": last_progress_detail,
        "capture_bytes": len(text_bytes),
    }


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
    log_path: Path,
    *,
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

    text_bytes = bytearray()
    sent_header = False
    sent_payload = False
    header_sent_at = 0.0
    start = time.monotonic()
    blind_header_deadline = start + 1.0
    deadline = start + capture_seconds
    log_path.parent.mkdir(parents=True, exist_ok=True)
    payload_ack_timeout = False
    payload_ack_credit = 0
    payload_ack_count = 0
    payload_chunks_sent = 0
    payload_block_ack_count = 0
    payload_block_nack_count = 0
    payload_block_retry_count = 0
    payload_block_retry_limit_hit = False
    payload_failed_block = -1
    active_text = ""
    pending_block_reply = ""

    def active_text_from_text_bytes() -> str:
        text = text_bytes.decode("latin1", errors="ignore")
        session_start = text.rfind("BENCH LOADER")
        return text[session_start:] if session_start >= 0 else text

    def ingest_serial_bytes(chunk: bytes) -> str:
        nonlocal payload_ack_credit, payload_ack_count, pending_block_reply
        if chunk:
            text_bytes.extend(chunk)
            ack_hits = chunk.count(UART_PAYLOAD_ACK)
            if ack_hits:
                payload_ack_credit += ack_hits
                payload_ack_count += ack_hits
            if UART_BLOCK_NACK in chunk:
                pending_block_reply = "nack"
            elif UART_BLOCK_ACK in chunk and not pending_block_reply:
                pending_block_reply = "ack"
        return active_text_from_text_bytes()

    def wait_payload_ack() -> bool:
        nonlocal payload_ack_credit
        if payload_ack_credit > 0:
            payload_ack_credit -= 1
            return True
        end = time.monotonic() + UART_PAYLOAD_ACK_TIMEOUT_S
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
        nonlocal pending_block_reply
        if pending_block_reply:
            reply = pending_block_reply
            pending_block_reply = ""
            return reply
        end = time.monotonic() + UART_BLOCK_REPLY_TIMEOUT_S
        while time.monotonic() < end:
            reply_chunk = ser.read(4096)
            if reply_chunk:
                ingest_serial_bytes(reply_chunk)
                if pending_block_reply:
                    reply = pending_block_reply
                    pending_block_reply = ""
                    return reply
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
            active_text = ingest_serial_bytes(chunk)
            if (not sent_header) and "BOOT DDR3 READY" in active_text:
                time.sleep(0.2)
                write_header_slow()
                sent_header = True
                header_sent_at = time.monotonic()
            if expect_dhrystone and sent_payload and "DHRYSTONE DONE" in active_text:
                break
            last_load_ok = active_text.rfind("LOAD OK")
            last_probe = active_text.rfind("M0D ")
            probe_region = active_text[last_load_ok:] if last_load_ok >= 0 else ""
            if (
                (not expect_dhrystone)
                and sent_payload
                and last_load_ok >= 0
                and last_probe > last_load_ok
                and probe_region.count("M0D ") >= 3
                and "\n" in active_text[last_probe:]
            ):
                break
        elif (not sent_header) and time.monotonic() >= blind_header_deadline:
            # The loader waits for the header after printing BOOT DDR3 READY.
            # Opening the serial port after JTAG may miss that short banner, so
            # send the header once after a quiet grace period.
            write_header_slow()
            sent_header = True
            header_sent_at = time.monotonic()

        if (
            sent_header
            and (not sent_payload)
            and (
                ("LOAD START" in active_text)
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

    log_path.write_bytes(bytes(text_bytes))
    active_text = active_text_from_text_bytes()
    fetch_probe = parse_fetch_probe(active_text)
    bad_block = analyze_loader_bad_block(active_text, payload)
    bad_checksum = analyze_loader_bad_checksum(active_text)
    write_blocks = analyze_loader_write_blocks(active_text, payload)
    benchmark_counters = parse_benchmark_counters(active_text)
    bad_reason = "none"
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
        if token in active_text:
            bad_reason = token
            break
    if bad_reason == "none" and payload_block_retry_limit_hit:
        bad_reason = "BLOCK RETRY LIMIT"
    if bad_reason == "none" and payload_ack_timeout and payload_failed_block >= 0:
        bad_reason = "BLOCK ACK TIMEOUT"
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
        "saw_ready": "BOOT DDR3 READY" in active_text,
        "saw_load_start": "LOAD START" in active_text,
        "saw_load_ok": "LOAD OK" in active_text,
        "saw_probe": bool(fetch_probe.get("lines")),
        "fetch_probe": fetch_probe,
        "bad_block": bad_block,
        "bad_checksum": bad_checksum,
        "write_blocks": write_blocks,
        "bad_reason": bad_reason,
        "saw_start": "DHRYSTONE START" in active_text,
        "saw_done": "DHRYSTONE DONE" in active_text,
        "saw_bad": any(
            token in active_text
            for token in ("BAD MAGIC", "LOAD BAD", "BAD_BYTE", "CAL FAIL", "RX OVERRUN", "RX FRAME ERR", "DRAIN TIMEOUT")
        ),
        "dhrystones_per_second": re.findall(r"Dhrystones per Second:\s+([0-9]+)", active_text),
        "microseconds_per_run": re.findall(r"Microseconds for one run through Dhrystone:\s+([0-9]+)", active_text),
        "bench_cycles": benchmark_counters["cycles"],
        "bench_instret": benchmark_counters["instret"],
        "bench_ipc_x1000": benchmark_counters["ipc_x1000"],
        "capture_bytes": len(text_bytes),
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


def run_uart_loader_capture(port: str, manifest: dict[str, object], capture_seconds: int, log_path: Path) -> dict[str, object]:
    try:
        import serial  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on local environment
        raise RuntimeError("pyserial is required for board benchmark UART loading") from exc

    with serial.Serial(port, 115200, timeout=0.05) as ser:
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        return drive_uart_loader(ser, manifest, capture_seconds, log_path)


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
    parser.add_argument("--transport-jitter-pct", type=int, default=4, help="Bit-period jitter percentage used by the minimal transport TB.")
    parser.add_argument("--transport-byte-gap", type=int, default=6, help="Maximum extra idle bit-times inserted between bytes in the transport TB.")
    parser.add_argument("--transport-ack-mode", choices=("tight", "loose"), default="loose", help="ACK pacing style for transport-only disturbance cases.")
    parser.add_argument("--transport-seeds", type=int, default=3, help="Number of combo disturbance seeds to run for 1KB transport TB coverage.")
    parser.add_argument("--skip-vivado", action="store_true", help="Stop after RTL/top simulation and payload build.")
    args = parser.parse_args()

    active_modes = [mode for mode in (args.fetch_debug, args.transport_only, args.bridge_audit, args.bridge_audit_steps, args.bridge_audit_step2_only) if mode]
    if len(active_modes) > 1:
        raise SystemExit("--fetch-debug, --transport-only, --bridge-audit, --bridge-audit-steps, and --bridge-audit-step2-only are mutually exclusive")

    logs_dir = BUILD_DIR / (
        "fpga_bridge_audit_step2_only"
        if args.bridge_audit_step2_only
        else ("fpga_bridge_audit_steps" if args.bridge_audit_steps else ("fpga_bridge_audit" if args.bridge_audit else "fpga_benchmark_ddr3"))
    )
    logs_dir.mkdir(parents=True, exist_ok=True)
    failed_stage = "none"
    failure_detail = ""
    current_stage = "init"
    manifest: dict[str, object] = {}
    transport_manifests: list[dict[str, object]] = []
    transport_tb_results: list[dict[str, object]] = []
    bridge_tb_results: list[dict[str, object]] = []
    uart_result: dict[str, object] = {}
    build_id = "N/A"
    sim_log = logs_dir / "not_run.log"
    capture_file = (
        STEP2_ONLY_CAPTURE_FILE
        if args.bridge_audit_step2_only
        else (BRIDGE_STEPS_CAPTURE_FILE if args.bridge_audit_steps else (BRIDGE_CAPTURE_FILE if args.bridge_audit else (TRANSPORT_CAPTURE_FILE if args.transport_only else UART_CAPTURE_FILE)))
    )
    flow_name = (
        "AX7203 DDR3 Bridge Audit Step2 Only"
        if args.bridge_audit_step2_only
        else (
        "AX7203 DDR3 Bridge Audit Steps"
        if args.bridge_audit_steps
        else ("AX7203 DDR3 Bridge Audit"
        if args.bridge_audit
        else ("AX7203 UART Loader Transport" if args.transport_only else "AX7203 DDR3 Benchmark Loader")))
    )

    env = build_env(
        args.rs_depth,
        args.fetch_buffer_depth,
        args.core_clk_mhz,
        fetch_debug=args.fetch_debug and not args.transport_only,
        bridge_audit=args.bridge_audit or args.bridge_audit_steps or args.bridge_audit_step2_only,
        uart_baud=args.uart_baud,
        rom_asm=STEP2_ONLY_ROM if args.bridge_audit_step2_only else (BRIDGE_STEPS_ROM if args.bridge_audit_steps else (BRIDGE_STRESS_ROM if args.bridge_audit else (TRANSPORT_ROM if args.transport_only else LOADER_ROM))),
        rom_march="rv32i_zicsr" if (args.transport_only or args.bridge_audit or args.bridge_audit_steps or args.bridge_audit_step2_only) else None,
        transport_uart_rxdata_reg_test=USE_REGISTERED_UART_RXDATA,
    )
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
            current_stage = "loader_top_sim"
            sim_log = logs_dir / "05_run_loader_top_sim.log"
            sim_log = run_loader_top_sim(
                logs_dir,
                rs_depth=args.rs_depth,
                fetch_buffer_depth=args.fetch_buffer_depth,
                core_clk_mhz=args.core_clk_mhz,
                fetch_debug=args.fetch_debug,
                uart_baud=args.uart_baud,
            )
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
            else:
                current_stage = "build_dhrystone_payload"
                manifest = build_dhrystone_payload(logs_dir, cpu_hz=int(args.core_clk_mhz * 1_000_000), runs=args.dhrystone_runs)

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
            if args.bridge_audit or args.bridge_audit_steps or args.bridge_audit_step2_only:
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
                current_stage = "program_jtag"
                run_logged([vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "program_ax7203_jtag.tcl")], cwd=REPO_ROOT, env=env, log_path=logs_dir / "10_program_jtag.log", timeout=1800)
                build_id = parse_build_id(BUILD_ID_FILE)
                current_stage = "uart_load_and_capture"
                try:
                    import serial  # type: ignore
                except ImportError as exc:  # pragma: no cover - depends on local environment
                    raise RuntimeError("pyserial is required for board benchmark UART loading") from exc
                with serial.Serial(args.port, args.uart_baud, timeout=0.05) as ser:
                    ser.reset_input_buffer()
                    ser.reset_output_buffer()
                    if args.transport_only:
                        uart_result = drive_uart_transport_sessions(ser, transport_manifests, args.capture_seconds, capture_file)
                    else:
                        uart_result = drive_uart_loader(ser, manifest, args.capture_seconds, capture_file, expect_dhrystone=not args.fetch_debug)
            if args.bridge_audit_step2_only:
                if uart_result.get("saw_bad") or uart_result.get("saw_trap"):
                    raise RuntimeError(f"DDR3 step2-only board profile reported failure ({uart_result.get('bad_reason', 'unknown')}); see {capture_file}")
                if not uart_result.get("ready_seen"):
                    raise RuntimeError(f"DDR3 step2-only board profile did not print S2 READY; see {capture_file}")
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
                if not uart_result.get("all_ok_seen"):
                    raise RuntimeError(f"DDR3 step2-only board profile did not print S2 ALL OK; see {capture_file}")
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
                if uart_result.get("saw_bad"):
                    raise RuntimeError(f"UART reported loader error ({uart_result.get('bad_reason', 'unknown')}); see {capture_file}")
                if not uart_result.get("saw_ready") and not uart_result.get("saw_load_start"):
                    raise RuntimeError(f"UART missing BOOT DDR3 READY/LOAD START; see {capture_file}")
                if not uart_result.get("sent_payload"):
                    raise RuntimeError(f"Payload was not sent; see {capture_file}")
                if not uart_result.get("saw_load_ok"):
                    raise RuntimeError(f"UART missing LOAD OK; see {capture_file}")
                if args.fetch_debug:
                    if not uart_result.get("saw_probe"):
                        raise RuntimeError(f"UART missing M0D fetch probe beacon; see {capture_file}")
                else:
                    if not uart_result.get("saw_start"):
                        raise RuntimeError(f"UART missing DHRYSTONE START; see {capture_file}")
                    if not uart_result.get("saw_done"):
                        raise RuntimeError(f"UART missing DHRYSTONE DONE; see {capture_file}")
    except Exception as exc:  # noqa: BLE001
        failed_stage = current_stage
        failure_detail = str(exc)

    timing = parse_timing_summary(TIMING_SUMMARY_AGGR)
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
        f"BenchmarkManifest: {manifest.get('bin', 'N/A')}",
        f"TransportBoardPayloadCount: {len(transport_manifests)}",
        f"TransportTbCaseCount: {len(transport_tb_results)}",
        f"BridgeTbCaseCount: {len(bridge_tb_results)}",
        f"TimingSummaryAggressive: {TIMING_SUMMARY_AGGR}",
        f"TimingDetailAggressive: {TIMING_DETAIL_AGGR}",
        f"UtilizationAggressive: {UTILIZATION_AGGR}",
        f"WNS: {timing['wns']}",
        f"WHS: {timing['whs']}",
        f"ConstraintsMet: {timing['constraints_met']}",
        f"UartCaptureFile: {capture_file}",
        f"UartSawReady: {uart_result.get('saw_ready', uart_result.get('ready_seen', False))}",
        f"UartSawLoadStart: {uart_result.get('saw_load_start', False)}",
        f"UartSawLoadOK: {uart_result.get('saw_load_ok', False)}",
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
        f"Step2TrapSeen: {uart_result.get('saw_trap', False)}",
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
