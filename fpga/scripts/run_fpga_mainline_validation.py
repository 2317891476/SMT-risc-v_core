#!/usr/bin/env python3
"""Validate the current AX7203 25MHz SMT mainline end-to-end."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_DIR = REPO_ROOT / "build"
COMP_TEST_DIR = REPO_ROOT / "comp_test"
ROM_DIR = REPO_ROOT / "rom"
RTL_DIR = REPO_ROOT / "rtl"
FPGA_RTL_DIR = REPO_ROOT / "fpga" / "rtl"
LIB_RAM_BFM = REPO_ROOT / "libs" / "REG_ARRAY" / "SRAM" / "ram_bfm.v"
MAINLINE_ROM = ROM_DIR / "test_fpga_ddr3_mainline.s"
MAINLINE_TB = COMP_TEST_DIR / "tb_ax7203_top_mainline_ddr3_smoke.sv"
MAINLINE_TB_TOP = "tb_ax7203_top_mainline_ddr3_smoke"
MAINLINE_EXPECT_TOKEN = "[AX7203_MAINLINE_DDR3] PASS"
MAINLINE_TOP_MODULE = "adam_riscv_ax7203_top"
MIG_STUB = COMP_TEST_DIR / "mig_7series_0_stub.v"
PROJECT_DIR = BUILD_DIR / "ax7203"
TIMING_SUMMARY_AGGR = PROJECT_DIR / "reports" / "timing_summary_aggressive.rpt"
TIMING_DETAIL_AGGR = PROJECT_DIR / "reports" / "timing_detail_aggressive.rpt"
UTILIZATION_AGGR = PROJECT_DIR / "reports" / "utilization_aggressive.rpt"
BUILD_ID_FILE = PROJECT_DIR / "adam_riscv_ax7203_bitstream_id.txt"
UART_CAPTURE_FILE = BUILD_DIR / "uart_test_rs16.txt"


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
    if depth <= 1:
        return 1
    return (depth - 1).bit_length()


def derive_clk_wiz_half_div(core_clk_mhz: float) -> int:
    if core_clk_mhz <= 0.0:
        raise RuntimeError(f"Core clock must be positive, got {core_clk_mhz}")
    return max(1, round(100.0 / core_clk_mhz))


def derive_uart_clk_div(core_clk_mhz: float, baud: int = 115200) -> int:
    if core_clk_mhz <= 0.0:
        raise RuntimeError(f"Core clock must be positive, got {core_clk_mhz}")
    if baud <= 0:
        raise RuntimeError(f"UART baud must be positive, got {baud}")
    return max(1, round((core_clk_mhz * 1_000_000.0) / float(baud)))


def parse_build_id(path: Path) -> str:
    if not path.exists():
        return "N/A"
    text = read_text(path)
    match = re.search(r"BUILD_ID=(0x[0-9A-Fa-f]+)", text)
    return match.group(1) if match else "N/A"


def parse_timing_summary(path: Path) -> dict[str, str]:
    result = {"wns": "N/A", "tns": "N/A", "whs": "N/A", "ths": "N/A", "constraints_met": "False"}
    if not path.exists():
        return result

    text = read_text(path)
    match = re.search(r"\n\s*([-0-9.]+)\s+([-0-9.]+)\s+[0-9]+\s+[0-9]+\s+([-0-9.]+)\s+([-0-9.]+)", text)
    if match:
        result["wns"], result["tns"], result["whs"], result["ths"] = match.groups()
    result["constraints_met"] = str("All user specified timing constraints are met." in text)
    return result


def analyze_uart_capture(path: Path) -> dict[str, object]:
    text = read_text(path) if path.exists() else ""
    saw_cal = "CAL=1" in text
    saw_ddr3_pass = "DDR3 PASS" in text
    counts = {ch: text.count(ch) for ch in "UARTDIGPS"}
    counts["A"] = text.count("A")
    counts["S"] = text.count("S")
    base_chars = ["U", "R", "T", "D", "I", "G", "P"]
    valid_char_total = sum(counts[ch] for ch in ["U", "A", "R", "T", "D", "I", "G", "P", "S"])

    base = min(counts[ch] for ch in base_chars) if all(counts[ch] > 0 for ch in base_chars) else 0
    ratio_ok = False
    if base >= 100:
        base_tol = max(8, round(base * 0.10))
        a_expected = 3 * base
        s_expected = 2 * base
        a_tol = max(16, round(a_expected * 0.10))
        s_tol = max(12, round(s_expected * 0.10))
        ratio_ok = (
            all(abs(counts[ch] - base) <= base_tol for ch in base_chars) and
            abs(counts["A"] - a_expected) <= a_tol and
            abs(counts["S"] - s_expected) <= s_tol
        )

    return {
        "valid_char_total": valid_char_total,
        "counts": counts,
        "base_count": base,
        "ratio_ok": ratio_ok,
        "file_size": len(text),
        "saw_cal": saw_cal,
        "saw_ddr3_pass": saw_ddr3_pass,
    }


def build_env(rs_depth: int, fetch_buffer_depth: int, core_clk_mhz: float) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "AX7203_ENABLE_MEM_SUBSYS": "1",
            "AX7203_ENABLE_ROCC": "0",
            "AX7203_ENABLE_DDR3": "1",
            "AX7203_SMT_MODE": "1",
            "AX7203_RS_DEPTH": str(rs_depth),
            "AX7203_RS_IDX_W": str(derive_idx_width(rs_depth)),
            "AX7203_FETCH_BUFFER_DEPTH": str(fetch_buffer_depth),
            "AX7203_CORE_CLK_MHZ": f"{core_clk_mhz:.1f}",
            "AX7203_UART_CLK_DIV": str(derive_uart_clk_div(core_clk_mhz)),
            "AX7203_ROM_ASM": str(MAINLINE_ROM),
            "AX7203_TOP_MODULE": MAINLINE_TOP_MODULE,
            "AX7203_MAX_THREADS": "4",
            "AX7203_SYNTH_JOBS": "4",
            "AX7203_IMPL_JOBS": "4",
        }
    )
    return env


def run_top_sim(logs_dir: Path, *, rs_depth: int, fetch_buffer_depth: int, core_clk_mhz: float) -> Path:
    out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{MAINLINE_TB_TOP}.out"

    run_logged(
        [
            sys.executable,
            str(REPO_ROOT / "fpga" / "scripts" / "build_rom_image.py"),
            "--asm",
            str(MAINLINE_ROM),
            "--merge-mem-subsys",
        ],
        cwd=REPO_ROOT,
        log_path=logs_dir / "03_build_rom.log",
        timeout=300,
    )

    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        "-DENABLE_MEM_SUBSYS=1",
        "-DENABLE_DDR3=1",
        "-DL2_PASSTHROUGH=1",
        "-DENABLE_ROCC_ACCEL=0",
        "-DSMT_MODE=1",
        "-DTB_SHORT_TIMEOUT_NS=8000000",
        f"-DFPGA_SCOREBOARD_RS_DEPTH={rs_depth}",
        f"-DFPGA_SCOREBOARD_RS_IDX_W={derive_idx_width(rs_depth)}",
        f"-DFPGA_FETCH_BUFFER_DEPTH={fetch_buffer_depth}",
        f"-DFPGA_CLK_WIZ_HALF_DIV={derive_clk_wiz_half_div(core_clk_mhz)}",
        f"-DFPGA_UART_CLK_DIV={derive_uart_clk_div(core_clk_mhz)}",
        "-s",
        MAINLINE_TB_TOP,
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
        str(MAINLINE_TB),
    ]
    run_logged(compile_cmd, cwd=REPO_ROOT, log_path=logs_dir / "04_compile_top_sim.log", timeout=300)
    sim_log = logs_dir / "05_run_top_sim.log"
    run_logged([which_required("vvp"), str(out_file)], cwd=ROM_DIR, log_path=sim_log, timeout=900)

    sim_text = read_text(sim_log)
    if MAINLINE_EXPECT_TOKEN not in sim_text:
        raise RuntimeError(f"Mainline top-level simulation did not reach PASS token; see {sim_log}")
    return sim_log


def write_summary(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="COM5")
    parser.add_argument("--rs-depth", type=int, default=48)
    parser.add_argument("--fetch-buffer-depth", type=int, default=16)
    parser.add_argument("--core-clk-mhz", type=float, default=25.0)
    parser.add_argument("--capture-seconds", type=int, default=10)
    args = parser.parse_args()

    logs_dir = BUILD_DIR / "fpga_mainline_validation"
    logs_dir.mkdir(parents=True, exist_ok=True)

    failed_stage = "none"
    failure_detail = ""
    current_stage = "init"
    sim_log_path = logs_dir / "05_run_top_sim.log"
    basic_default_log = logs_dir / "01_basic.log"
    basic_fpga_log = logs_dir / "02_basic_fpga_config.log"
    create_log = logs_dir / "06_create_project.log"
    synth_log = logs_dir / "07_run_synth.log"
    impl_log = logs_dir / "08_impl_aggressive.log"
    program_log = logs_dir / "09_program_jtag.log"
    capture_log = logs_dir / "10_capture_uart.log"
    build_id = "N/A"
    uart_analysis: dict[str, object] = {"valid_char_total": 0, "counts": {}, "base_count": 0, "ratio_ok": False, "file_size": 0}

    env = build_env(args.rs_depth, args.fetch_buffer_depth, args.core_clk_mhz)

    try:
        current_stage = "basic"
        run_logged(
            [sys.executable, str(REPO_ROOT / "verification" / "run_all_tests.py"), "--basic"],
            cwd=REPO_ROOT,
            log_path=basic_default_log,
            timeout=3600,
        )

        current_stage = "basic_fpga_config"
        run_logged(
            [sys.executable, str(REPO_ROOT / "verification" / "run_all_tests.py"), "--basic", "--fpga-config"],
            cwd=REPO_ROOT,
            log_path=basic_fpga_log,
            timeout=3600,
        )

        current_stage = "fpga_top_sim"
        run_top_sim(
            logs_dir,
            rs_depth=args.rs_depth,
            fetch_buffer_depth=args.fetch_buffer_depth,
            core_clk_mhz=args.core_clk_mhz,
        )

        vivado = which_required("vivado.bat", "vivado")
        current_stage = "create_project"
        run_logged(
            [vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "create_project_ax7203.tcl")],
            cwd=REPO_ROOT,
            env=env,
            log_path=create_log,
            timeout=3600,
        )
        current_stage = "synth"
        run_logged(
            [vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "run_ax7203_synth.tcl")],
            cwd=REPO_ROOT,
            env=env,
            log_path=synth_log,
            timeout=7200,
        )
        current_stage = "impl_aggressive"
        run_logged(
            [vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "impl_aggressive.tcl")],
            cwd=REPO_ROOT,
            env=env,
            log_path=impl_log,
            timeout=7200,
        )

        timing = parse_timing_summary(TIMING_SUMMARY_AGGR)
        if timing["constraints_met"] != "True":
            raise RuntimeError(f"Aggressive implementation did not meet timing; see {TIMING_SUMMARY_AGGR}")
        if float(timing["wns"]) < 0.0 or float(timing["whs"]) < 0.0:
            raise RuntimeError(f"Aggressive implementation has negative slack; see {TIMING_SUMMARY_AGGR}")

        powershell = which_required("powershell.exe", "powershell")
        capture_window_seconds = max(args.capture_seconds + 60, 75)
        capture_cmd = [
            powershell,
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(REPO_ROOT / "fpga" / "scripts" / "capture_uart_once.ps1"),
            "-Port",
            args.port,
            "-OutFile",
            str(UART_CAPTURE_FILE),
            "-Seconds",
            str(capture_window_seconds),
            "-OpenDelayMs",
            "0",
        ]

        current_stage = "uart_capture_prearm"
        capture_log.parent.mkdir(parents=True, exist_ok=True)
        with capture_log.open("w", encoding="utf-8", newline="\n") as cap_fh:
            cap_fh.write(f"$ {' '.join(capture_cmd)}\n\n")
            cap_fh.flush()
            capture_proc = subprocess.Popen(
                capture_cmd,
                cwd=REPO_ROOT,
                stdout=cap_fh,
                stderr=subprocess.STDOUT,
                text=True,
            )

            current_stage = "program_jtag"
            try:
                run_logged(
                    [vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / "program_ax7203_jtag.tcl")],
                    cwd=REPO_ROOT,
                    env=env,
                    log_path=program_log,
                    timeout=1800,
                )
            except Exception:
                capture_proc.terminate()
                try:
                    capture_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    capture_proc.kill()
                raise

            build_id = parse_build_id(BUILD_ID_FILE)
            current_stage = "uart_capture"
            capture_rc = capture_proc.wait(timeout=capture_window_seconds + 30)
            if capture_rc != 0:
                raise RuntimeError(f"UART capture failed ({capture_rc}); see {capture_log}")

        uart_analysis = analyze_uart_capture(UART_CAPTURE_FILE)
        if not uart_analysis["saw_cal"]:
            raise RuntimeError(f"UART capture is missing CAL=1; see {UART_CAPTURE_FILE}")
        if not uart_analysis["saw_ddr3_pass"]:
            raise RuntimeError(f"UART capture is missing DDR3 PASS; see {UART_CAPTURE_FILE}")
        if not uart_analysis["ratio_ok"]:
            raise RuntimeError(f"UART capture does not match expected dual-thread ratio; see {UART_CAPTURE_FILE}")
    except Exception as exc:  # noqa: BLE001
        if failed_stage == "none":
            failed_stage = current_stage
        failure_detail = str(exc)

    timing = parse_timing_summary(TIMING_SUMMARY_AGGR)
    counts = uart_analysis.get("counts", {})
    summary_lines = [
        "Flow: AX7203 25MHz SMT Mainline Validation",
        f"Result: {'PASS' if failed_stage == 'none' else 'FAIL'}",
        f"FailedStage: {failed_stage}",
        f"FailureDetail: {failure_detail or 'none'}",
        f"RSDepth: {args.rs_depth}",
        f"RSIdxW: {derive_idx_width(args.rs_depth)}",
        f"FetchBufferDepth: {args.fetch_buffer_depth}",
        f"CoreClkMHz: {args.core_clk_mhz:.1f}",
        f"UartClkDiv: {derive_uart_clk_div(args.core_clk_mhz)}",
        "EnableMemSubsys: 1",
        "EnableDDR3: 1",
        "L2Passthrough: 1",
        f"BuildID: {build_id}",
        f"BasicLog: {basic_default_log}",
        f"BasicFpgaConfigLog: {basic_fpga_log}",
        f"TopSimLog: {sim_log_path}",
        f"CreateProjectLog: {create_log}",
        f"SynthLog: {synth_log}",
        f"ImplAggressiveLog: {impl_log}",
        f"ProgramLog: {program_log}",
        f"UartCaptureLog: {capture_log}",
        f"UartCaptureFile: {UART_CAPTURE_FILE}",
        f"TimingSummaryAggressive: {TIMING_SUMMARY_AGGR}",
        f"TimingDetailAggressive: {TIMING_DETAIL_AGGR}",
        f"UtilizationAggressive: {UTILIZATION_AGGR}",
        f"WNS: {timing['wns']}",
        f"WHS: {timing['whs']}",
        f"ConstraintsMet: {timing['constraints_met']}",
        f"UartValidChars: {uart_analysis.get('valid_char_total', 0)}",
        f"UartBaseCount: {uart_analysis.get('base_count', 0)}",
        f"UartRatioOK: {uart_analysis.get('ratio_ok', False)}",
        f"SawCAL1: {uart_analysis.get('saw_cal', False)}",
        f"SawDDR3PASS: {uart_analysis.get('saw_ddr3_pass', False)}",
        f"CountU: {counts.get('U', 0)}",
        f"CountA: {counts.get('A', 0)}",
        f"CountR: {counts.get('R', 0)}",
        f"CountT: {counts.get('T', 0)}",
        f"CountD: {counts.get('D', 0)}",
        f"CountI: {counts.get('I', 0)}",
        f"CountG: {counts.get('G', 0)}",
        f"CountP: {counts.get('P', 0)}",
        f"CountS: {counts.get('S', 0)}",
    ]
    summary_path = logs_dir / "summary.txt"
    write_summary(summary_path, summary_lines)
    print(summary_path)
    return 0 if failed_stage == "none" else 1


if __name__ == "__main__":
    raise SystemExit(main())
