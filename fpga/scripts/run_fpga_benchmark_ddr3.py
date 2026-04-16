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
TINY_PAYLOAD_ROM = ROM_DIR / "test_fpga_ddr3_exec_payload.s"
LOADER_TB = COMP_TEST_DIR / "tb_ax7203_top_ddr3_loader_smoke.sv"
LOADER_TB_TOP = "tb_ax7203_top_ddr3_loader_smoke"
FETCH_PROBE_TB = COMP_TEST_DIR / "tb_ax7203_top_ddr3_fetch_probe_smoke.sv"
FETCH_PROBE_TB_TOP = "tb_ax7203_top_ddr3_fetch_probe_smoke"
MIG_STUB = COMP_TEST_DIR / "mig_7series_0_stub.v"
PAYLOAD_HEX = ROM_DIR / "ddr3_loader_payload.hex"
TIMING_SUMMARY_AGGR = PROJECT_DIR / "reports" / "timing_summary_aggressive.rpt"
TIMING_DETAIL_AGGR = PROJECT_DIR / "reports" / "timing_detail_aggressive.rpt"
UTILIZATION_AGGR = PROJECT_DIR / "reports" / "utilization_aggressive.rpt"
BUILD_ID_FILE = PROJECT_DIR / "adam_riscv_ax7203_bitstream_id.txt"
UART_CAPTURE_FILE = BUILD_DIR / "dhrystone_ddr3_uart_capture.txt"
UART_PAYLOAD_CHUNK_BYTES = 4
UART_PAYLOAD_ACK = 0x06
UART_PAYLOAD_ACK_TIMEOUT_S = 2.0
UART_HEADER_BYTE_DELAY_S = 0.002


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


def build_env(rs_depth: int, fetch_buffer_depth: int, core_clk_mhz: float, *, fetch_debug: bool = False) -> dict[str, str]:
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
            "AX7203_UART_CLK_DIV": str(derive_uart_clk_div(core_clk_mhz)),
            "AX7203_ROM_ASM": str(LOADER_ROM),
            "AX7203_TOP_MODULE": "adam_riscv_ax7203_top",
            "AX7203_DDR3_FETCH_DEBUG": "1" if fetch_debug else "0",
            "AX7203_MAX_THREADS": "4",
            "AX7203_SYNTH_JOBS": "4",
            "AX7203_IMPL_JOBS": "4",
        }
    )
    return env


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
    payload = binary.read_bytes()
    PAYLOAD_HEX.write_text("".join(f"{byte:02x}\n" for byte in payload), encoding="ascii")


def run_loader_top_sim(logs_dir: Path, *, rs_depth: int, fetch_buffer_depth: int, core_clk_mhz: float, fetch_debug: bool = False) -> Path:
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
    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        "-DENABLE_MEM_SUBSYS=1",
        "-DENABLE_DDR3=1",
        "-DL2_PASSTHROUGH=1",
        *debug_defines,
        "-DENABLE_ROCC_ACCEL=0",
        "-DSMT_MODE=1",
        "-DTB_SHORT_TIMEOUT_NS=30000000",
        "-DTB_UART_BIT_NS=8680",
        f"-DFPGA_SCOREBOARD_RS_DEPTH={rs_depth}",
        f"-DFPGA_SCOREBOARD_RS_IDX_W={derive_idx_width(rs_depth)}",
        f"-DFPGA_FETCH_BUFFER_DEPTH={fetch_buffer_depth}",
        f"-DFPGA_CLK_WIZ_HALF_DIV={derive_clk_wiz_half_div(core_clk_mhz)}",
        f"-DFPGA_UART_CLK_DIV={derive_uart_clk_div(core_clk_mhz)}",
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
    start = time.monotonic()
    blind_header_deadline = start + 1.0
    deadline = start + capture_seconds
    log_path.parent.mkdir(parents=True, exist_ok=True)
    payload_ack_timeout = False

    def wait_payload_ack() -> bool:
        end = time.monotonic() + UART_PAYLOAD_ACK_TIMEOUT_S
        while time.monotonic() < end:
            ack_chunk = ser.read(4096)
            if ack_chunk:
                text_bytes.extend(ack_chunk)
                if UART_PAYLOAD_ACK in ack_chunk:
                    return True
            else:
                time.sleep(0.001)
        return False

    def write_payload_with_ack() -> None:
        nonlocal payload_ack_timeout
        for off in range(0, len(payload), UART_PAYLOAD_CHUNK_BYTES):
            ser.write(payload[off : off + UART_PAYLOAD_CHUNK_BYTES])
            ser.flush()
            if not wait_payload_ack():
                payload_ack_timeout = True
                break

    def write_header_slow() -> None:
        for byte in header:
            ser.write(bytes([byte]))
            ser.flush()
            time.sleep(UART_HEADER_BYTE_DELAY_S)

    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            text_bytes.extend(chunk)
            text = text_bytes.decode("latin1", errors="ignore")
            session_start = text.rfind("BENCH LOADER")
            active_text = text[session_start:] if session_start >= 0 else text
            if (not sent_header) and "BOOT DDR3 READY" in active_text:
                time.sleep(0.2)
                write_header_slow()
                sent_header = True
            if sent_header and (not sent_payload) and "LOAD START" in active_text:
                time.sleep(0.2)
                write_payload_with_ack()
                sent_payload = True
                deadline = max(deadline, time.monotonic() + capture_seconds)
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

    log_path.write_bytes(bytes(text_bytes))
    text = text_bytes.decode("latin1", errors="ignore")
    session_start = text.rfind("BENCH LOADER")
    active_text = text[session_start:] if session_start >= 0 else text
    fetch_probe = parse_fetch_probe(active_text)
    return {
        "sent_header": sent_header,
        "sent_payload": sent_payload,
        "payload_ack_timeout": payload_ack_timeout,
        "saw_ready": "BOOT DDR3 READY" in active_text,
        "saw_load_ok": "LOAD OK" in active_text,
        "saw_probe": bool(fetch_probe.get("lines")),
        "fetch_probe": fetch_probe,
        "saw_start": "DHRYSTONE START" in active_text,
        "saw_done": "DHRYSTONE DONE" in active_text,
        "saw_bad": any(token in active_text for token in ("BAD MAGIC", "LOAD BAD", "CAL FAIL")),
        "dhrystones_per_second": re.findall(r"Dhrystones per Second:\s+([0-9]+)", active_text),
        "microseconds_per_run": re.findall(r"Microseconds for one run through Dhrystone:\s+([0-9]+)", active_text),
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
    parser.add_argument("--dhrystone-runs", type=int, default=5000)
    parser.add_argument("--fetch-debug", action="store_true", help="Build a DDR3 fetch-probe bitstream and stop after UART beacon diagnosis.")
    parser.add_argument("--skip-vivado", action="store_true", help="Stop after RTL/top simulation and payload build.")
    args = parser.parse_args()

    logs_dir = BUILD_DIR / "fpga_benchmark_ddr3"
    logs_dir.mkdir(parents=True, exist_ok=True)
    failed_stage = "none"
    failure_detail = ""
    current_stage = "init"
    manifest: dict[str, object] = {}
    uart_result: dict[str, object] = {}
    build_id = "N/A"

    env = build_env(args.rs_depth, args.fetch_buffer_depth, args.core_clk_mhz, fetch_debug=args.fetch_debug)
    try:
        current_stage = "basic"
        run_logged([sys.executable, str(REPO_ROOT / "verification" / "run_all_tests.py"), "--basic"], cwd=REPO_ROOT, log_path=logs_dir / "01_basic.log", timeout=3600)
        current_stage = "basic_fpga_config"
        run_logged([sys.executable, str(REPO_ROOT / "verification" / "run_all_tests.py"), "--basic", "--fpga-config"], cwd=REPO_ROOT, log_path=logs_dir / "02_basic_fpga_config.log", timeout=3600)
        current_stage = "loader_top_sim"
        sim_log = run_loader_top_sim(logs_dir, rs_depth=args.rs_depth, fetch_buffer_depth=args.fetch_buffer_depth, core_clk_mhz=args.core_clk_mhz, fetch_debug=args.fetch_debug)
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
            current_stage = "program_jtag"
            run_logged([vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "program_ax7203_jtag.tcl")], cwd=REPO_ROOT, env=env, log_path=logs_dir / "10_program_jtag.log", timeout=1800)
            build_id = parse_build_id(BUILD_ID_FILE)
            current_stage = "uart_load_and_capture"
            try:
                import serial  # type: ignore
            except ImportError as exc:  # pragma: no cover - depends on local environment
                raise RuntimeError("pyserial is required for board benchmark UART loading") from exc
            with serial.Serial(args.port, 115200, timeout=0.05) as ser:
                ser.reset_input_buffer()
                ser.reset_output_buffer()
                uart_result = drive_uart_loader(ser, manifest, args.capture_seconds, UART_CAPTURE_FILE, expect_dhrystone=not args.fetch_debug)
            if not uart_result.get("saw_ready") and not uart_result.get("saw_load_ok"):
                raise RuntimeError(f"UART missing BOOT DDR3 READY; see {UART_CAPTURE_FILE}")
            if not uart_result.get("sent_payload"):
                raise RuntimeError(f"Payload was not sent; see {UART_CAPTURE_FILE}")
            if not uart_result.get("saw_load_ok"):
                raise RuntimeError(f"UART missing LOAD OK; see {UART_CAPTURE_FILE}")
            if args.fetch_debug:
                if not uart_result.get("saw_probe"):
                    raise RuntimeError(f"UART missing M0D fetch probe beacon; see {UART_CAPTURE_FILE}")
            else:
                if not uart_result.get("saw_start"):
                    raise RuntimeError(f"UART missing DHRYSTONE START; see {UART_CAPTURE_FILE}")
                if not uart_result.get("saw_done"):
                    raise RuntimeError(f"UART missing DHRYSTONE DONE; see {UART_CAPTURE_FILE}")
            if uart_result.get("saw_bad"):
                raise RuntimeError(f"UART reported a loader error; see {UART_CAPTURE_FILE}")
        else:
            sim_log = logs_dir / "05_run_loader_top_sim.log"
    except Exception as exc:  # noqa: BLE001
        failed_stage = current_stage
        failure_detail = str(exc)
        sim_log = logs_dir / "05_run_loader_top_sim.log"

    timing = parse_timing_summary(TIMING_SUMMARY_AGGR)
    fetch_probe = uart_result.get("fetch_probe", {}) if isinstance(uart_result.get("fetch_probe", {}), dict) else {}
    summary_lines = [
        "Flow: AX7203 DDR3 Benchmark Loader",
        f"Result: {'PASS' if failed_stage == 'none' else 'FAIL'}",
        f"FailedStage: {failed_stage}",
        f"FailureDetail: {failure_detail or 'none'}",
        f"Benchmark: {args.benchmark}",
        f"RSDepth: {args.rs_depth}",
        f"FetchBufferDepth: {args.fetch_buffer_depth}",
        f"CoreClkMHz: {args.core_clk_mhz:.1f}",
        "EnableMemSubsys: 1",
        "EnableDDR3: 1",
        "L2Passthrough: 1",
        f"FetchDebug: {args.fetch_debug}",
        f"BuildID: {build_id}",
        f"LoaderTopSimLog: {sim_log}",
        f"BenchmarkManifest: {manifest.get('bin', 'N/A')}",
        f"TimingSummaryAggressive: {TIMING_SUMMARY_AGGR}",
        f"TimingDetailAggressive: {TIMING_DETAIL_AGGR}",
        f"UtilizationAggressive: {UTILIZATION_AGGR}",
        f"WNS: {timing['wns']}",
        f"WHS: {timing['whs']}",
        f"ConstraintsMet: {timing['constraints_met']}",
        f"UartCaptureFile: {UART_CAPTURE_FILE}",
        f"UartSawReady: {uart_result.get('saw_ready', False)}",
        f"UartSawLoadOK: {uart_result.get('saw_load_ok', False)}",
        f"UartSawFetchProbe: {uart_result.get('saw_probe', False)}",
        f"FetchProbeClassification: {fetch_probe.get('classification', 'N/A')}",
        f"FetchProbeLastLine: {fetch_probe.get('last_line', 'N/A')}",
        f"UartSawDhrystoneStart: {uart_result.get('saw_start', False)}",
        f"UartSawDhrystoneDone: {uart_result.get('saw_done', False)}",
        f"UartCaptureBytes: {uart_result.get('capture_bytes', 0)}",
        f"DhrystonesPerSecond: {','.join(uart_result.get('dhrystones_per_second', []))}",
        f"MicrosecondsPerRun: {','.join(uart_result.get('microseconds_per_run', []))}",
    ]
    summary_path = logs_dir / "summary.txt"
    write_summary(summary_path, summary_lines)
    print(summary_path)
    return 0 if failed_stage == "none" else 1


if __name__ == "__main__":
    raise SystemExit(main())
