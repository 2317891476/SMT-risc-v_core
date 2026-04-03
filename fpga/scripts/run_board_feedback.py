#!/usr/bin/env python3
"""Run the AX7203 board feedback flow end-to-end.

This script validates the observable feedback chain in the same order we use
for board bring-up:
1. Top-level simulation with the selected board profile.
2. Vivado project recreation.
3. <=15 minute synthesis.
4. Skip-opt bitstream generation with a stamped build ID.
5. JTAG programming with build-ID readback verification.
6. UART capture from the selected COM port.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_DIR = REPO_ROOT / "build"
COMP_TEST_DIR = REPO_ROOT / "comp_test"


PROFILES = {
    "core_diag": {
        "top": "adam_riscv_ax7203_top",
        "tb": "tb_ax7203_top_smoke",
        "tb_file": COMP_TEST_DIR / "tb_ax7203_top_smoke.sv",
        "rom": REPO_ROOT / "rom" / "test_fpga_uart_board_diag_gap.s",
        "expect_token": "[AX7203_TOP] PASS",
    },
    "core_status": {
        "top": "adam_riscv_ax7203_status_top",
        "tb": "tb_ax7203_status_top_smoke",
        "tb_file": COMP_TEST_DIR / "tb_ax7203_status_top_smoke.sv",
        "rom": REPO_ROOT / "rom" / "test_fpga_uart_board_diag_pollsafe.s",
        "expect_token": "[AX7203_STATUS] PASS",
    },
    "issue_probe": {
        "top": "adam_riscv_ax7203_issue_probe_top",
        "tb": "tb_ax7203_issue_probe_smoke",
        "tb_file": COMP_TEST_DIR / "tb_ax7203_issue_probe_smoke.sv",
        "rom": REPO_ROOT / "rom" / "test_fpga_uart_board_diag_pollsafe.s",
        "expect_token": "[AX7203_ISSUE_PROBE] PASS",
    },
    "branch_probe": {
        "top": "adam_riscv_ax7203_branch_probe_top",
        "tb": "tb_ax7203_branch_probe_smoke",
        "tb_file": COMP_TEST_DIR / "tb_ax7203_branch_probe_smoke.sv",
        "rom": REPO_ROOT / "rom" / "test_fpga_uart_board_diag_pollsafe.s",
        "expect_token": "[AX7203_BRANCH_PROBE] PASS",
    },
    "main_bridge_probe": {
        "top": "adam_riscv_ax7203_main_bridge_probe_top",
        "tb": "tb_ax7203_main_bridge_probe_smoke",
        "tb_file": COMP_TEST_DIR / "tb_ax7203_main_bridge_probe_smoke.sv",
        "rom": REPO_ROOT / "rom" / "test_fpga_uart_board_diag.s",
        "expect_token": "[AX7203_MAIN_BRIDGE_PROBE] PASS",
    },
    "io_smoke": {
        "top": "adam_riscv_ax7203_io_smoke_top",
        "tb": "tb_ax7203_io_smoke",
        "tb_file": COMP_TEST_DIR / "tb_ax7203_io_smoke.sv",
        "rom": None,
        "expect_token": "[AX7203_IO_SMOKE] PASS",
    },
    "uart_echo": {
        "top": "adam_riscv_ax7203_top",
        "tb": "tb_ax7203_uart_echo_smoke",
        "tb_file": COMP_TEST_DIR / "tb_ax7203_uart_echo_smoke.sv",
        "rom": REPO_ROOT / "rom" / "test_fpga_uart_echo.s",
        "expect_token": "[AX7203_UART_ECHO] PASS",
        "uart_send_text": "Z",
        "uart_expect_text": "Z",
        "uart_send_delay_ms": 800,
    },
}


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
        raise SystemExit(f"Command failed ({proc.returncode}): {' '.join(cmd)}\nSee log: {log_path}")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def collect_verilog(root: Path) -> list[str]:
    return [str(path) for path in sorted(root.glob("*.v"))]


def run_top_sim(profile: dict[str, object], logs_dir: Path) -> Path:
    python_bin = sys.executable
    sim_cwd = REPO_ROOT
    if profile["rom"] is not None:
        run_logged(
            [
                python_bin,
                str(REPO_ROOT / "fpga" / "scripts" / "build_rom_image.py"),
                "--asm",
                str(profile["rom"]),
            ],
            cwd=REPO_ROOT,
            log_path=logs_dir / "01_build_rom.log",
        )
        sim_cwd = REPO_ROOT / "rom"

    out_dir = COMP_TEST_DIR / "out_iverilog" / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{profile['tb']}.out"
    compile_log = logs_dir / "02_compile_top_sim.log"
    sim_log = logs_dir / "03_run_top_sim.log"

    compile_cmd = [
        which_required("iverilog"),
        "-g2012",
        "-DFPGA_MODE=1",
        "-DENABLE_MEM_SUBSYS=0",
        "-DENABLE_ROCC_ACCEL=0",
        "-DSMT_MODE=0",
        "-s",
        str(profile["tb"]),
        "-o",
        str(out_file),
        "-I",
        str(REPO_ROOT / "rtl"),
        "-I",
        str(REPO_ROOT / "fpga" / "rtl"),
        *collect_verilog(REPO_ROOT / "rtl"),
        *collect_verilog(REPO_ROOT / "fpga" / "rtl"),
        str(REPO_ROOT / "libs" / "REG_ARRAY" / "SRAM" / "ram_bfm.v"),
        str(COMP_TEST_DIR / "clk_wiz_0_stub.v"),
        str(COMP_TEST_DIR / "ibufgds_stub.v"),
        str(profile["tb_file"]),
    ]
    run_logged(compile_cmd, cwd=REPO_ROOT, log_path=compile_log, timeout=300)
    run_logged([which_required("vvp"), str(out_file)], cwd=sim_cwd, log_path=sim_log, timeout=300)

    sim_text = read_text(sim_log)
    if str(profile["expect_token"]) not in sim_text:
        raise SystemExit(f"Top-level simulation did not reach PASS token. See log: {sim_log}")
    return sim_log


def run_vivado(script_name: str, *, env: dict[str, str], logs_dir: Path, step_name: str, timeout: int) -> Path:
    vivado = which_required("vivado.bat", "vivado")
    log_path = logs_dir / f"{step_name}.log"
    run_logged(
        [vivado, "-mode", "batch", "-source", str(REPO_ROOT / "fpga" / script_name)],
        cwd=REPO_ROOT,
        env=env,
        log_path=log_path,
        timeout=timeout,
    )
    return log_path


def resolve_generated_synth_script(top_module: str) -> Path:
    runs_dir = REPO_ROOT / "build" / "ax7203" / "adam_riscv_ax7203.runs" / "synth_1"
    candidates = [
        runs_dir / f"{top_module}.tcl",
        runs_dir / "adam_riscv_ax7203_top.tcl",
        runs_dir / "adam_riscv_ax7203_top.tcl",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise SystemExit(f"Failed to locate generated synth Tcl under {runs_dir}")


def finalize_synth_outputs(top_module: str) -> None:
    project_dir = REPO_ROOT / "build" / "ax7203"
    runs_dir = project_dir / "adam_riscv_ax7203.runs" / "synth_1"
    checkpoint_dir = project_dir / "checkpoints"
    report_dir = project_dir / "reports"
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    report_dir.mkdir(parents=True, exist_ok=True)

    dcp_candidates = [
        runs_dir / f"{top_module}.dcp",
        runs_dir / "adam_riscv_ax7203_top.dcp",
        runs_dir / "adam_riscv_ax7203_top.dcp",
    ]
    synth_dcp = next((path for path in dcp_candidates if path.exists()), None)
    if synth_dcp is None:
        raise SystemExit(f"Failed to locate synthesized checkpoint under {runs_dir}")
    shutil.copy2(synth_dcp, checkpoint_dir / "adam_riscv_ax7203_post_synth.dcp")

    util_candidates = [
        runs_dir / f"{top_module}_utilization_synth.rpt",
        runs_dir / "adam_riscv_ax7203_top_utilization_synth.rpt",
    ]
    util_rpt = next((path for path in util_candidates if path.exists()), None)
    if util_rpt is not None:
        shutil.copy2(util_rpt, report_dir / "synth_utilization.rpt")


def run_direct_synth(*, env: dict[str, str], logs_dir: Path, top_module: str, timeout: int) -> Path:
    return run_vivado(
        "run_ax7203_synth.tcl",
        env=env,
        logs_dir=logs_dir,
        step_name="05_run_synth",
        timeout=timeout,
    )


def parse_build_id(path: Path) -> str:
    if not path.exists():
        raise SystemExit(f"Missing build manifest: {path}")
    for line in read_text(path).splitlines():
        if line.startswith("BUILD_ID="):
            return line.split("=", 1)[1].strip()
    raise SystemExit(f"Failed to parse BUILD_ID from {path}")


def capture_uart(
    port: str,
    out_file: Path,
    seconds: int,
    logs_dir: Path,
    *,
    send_text: str = "",
    send_hex: str = "",
    send_delay_ms: int = 0,
) -> Path:
    powershell = which_required("powershell")
    log_path = logs_dir / "07_capture_uart.log"
    cmd = [
        powershell,
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(REPO_ROOT / "fpga" / "scripts" / "capture_uart_once.ps1"),
        "-Port",
        port,
        "-OutFile",
        str(out_file),
        "-Seconds",
        str(seconds),
    ]
    if send_text:
        cmd.extend(["-SendText", send_text])
    if send_hex:
        cmd.extend(["-SendHex", send_hex])
    if send_delay_ms:
        cmd.extend(["-SendDelayMs", str(send_delay_ms)])
    run_logged(
        cmd,
        cwd=REPO_ROOT,
        log_path=log_path,
        timeout=max(60, seconds + 30),
    )
    return log_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", choices=sorted(PROFILES), default="io_smoke")
    parser.add_argument("--port", default="COM5")
    parser.add_argument("--capture-seconds", type=int, default=8)
    parser.add_argument("--rom", type=Path, default=None)
    parser.add_argument("--allow-empty-serial", action="store_true")
    parser.add_argument("--send-text", default="")
    parser.add_argument("--send-hex", default="")
    parser.add_argument("--expect-text", default="")
    args = parser.parse_args()

    profile = dict(PROFILES[args.profile])
    if args.rom is not None:
        profile["rom"] = args.rom.resolve()
    logs_dir = BUILD_DIR / f"board_feedback_{args.profile}"
    logs_dir.mkdir(parents=True, exist_ok=True)

    sim_log = run_top_sim(profile, logs_dir)

    env = os.environ.copy()
    env["AX7203_ENABLE_MEM_SUBSYS"] = "0"
    env["AX7203_ENABLE_ROCC"] = "0"
    env["AX7203_SMT_MODE"] = "0"
    env["AX7203_TOP_MODULE"] = str(profile["top"])
    if profile["rom"] is not None:
        env["AX7203_ROM_ASM"] = str(profile["rom"])

    run_vivado("create_project_ax7203.tcl", env=env, logs_dir=logs_dir, step_name="04_create_project", timeout=600)
    run_direct_synth(env=env, logs_dir=logs_dir, top_module=str(profile["top"]), timeout=1200)
    run_vivado("build_ax7203_bitstream.tcl", env=env, logs_dir=logs_dir, step_name="06_build_bitstream", timeout=3600)

    project_dir = REPO_ROOT / "build" / "ax7203"
    top_module = str(profile["top"])
    if top_module == "adam_riscv_ax7203_top":
        build_id_file = project_dir / "adam_riscv_ax7203_bitstream_id.txt"
        uart_capture = BUILD_DIR / f"ax7203_{args.profile}_uart_capture.txt"
    else:
        build_id_file = project_dir / f"adam_riscv_ax7203_{top_module}_bitstream_id.txt"
        uart_capture = BUILD_DIR / f"ax7203_{args.profile}_uart_capture.txt"

    build_id = parse_build_id(build_id_file)
    program_log = run_vivado("program_ax7203_jtag.tcl", env=env, logs_dir=logs_dir, step_name="07_program_jtag", timeout=600)
    capture_log = capture_uart(
        args.port,
        uart_capture,
        args.capture_seconds,
        logs_dir,
        send_text=args.send_text or str(profile.get("uart_send_text", "")),
        send_hex=args.send_hex,
        send_delay_ms=int(profile.get("uart_send_delay_ms", 0)),
    )

    uart_text = read_text(uart_capture) if uart_capture.exists() else ""
    expect_text = args.expect_text or str(profile.get("uart_expect_text", ""))
    summary_path = logs_dir / "summary.txt"
    summary_path.write_text(
        "\n".join(
            [
                f"Profile: {args.profile}",
                f"TopModule: {top_module}",
                f"BuildID: {build_id}",
                f"SimulationLog: {sim_log}",
                f"ProgramLog: {program_log}",
                f"CaptureLog: {capture_log}",
                f"UartCapture: {uart_capture}",
                f"UartBytes: {len(uart_text.encode('utf-8'))}",
                f"ExpectText: {expect_text}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    if not uart_text and not args.allow_empty_serial:
        raise SystemExit(f"UART capture is empty. See summary: {summary_path}")
    if expect_text and expect_text not in uart_text:
        raise SystemExit(f"UART capture missing expected text {expect_text!r}. See summary: {summary_path}")

    print(summary_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
