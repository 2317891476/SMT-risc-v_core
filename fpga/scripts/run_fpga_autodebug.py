#!/usr/bin/env python3
"""Run the AX7203 FPGA board-debug flow with automatic diagnostics."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_DIR = REPO_ROOT / "build"
BOARD_FEEDBACK = REPO_ROOT / "fpga" / "scripts" / "run_board_feedback.py"

MAIN_PROFILES = ("core_diag", "uart_echo")
DIAGNOSTIC_PROFILES = ("core_status", "issue_probe", "branch_probe", "main_bridge_probe")


def run_logged(
    cmd: list[str],
    *,
    log_path: Path,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
) -> int:
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
    return proc.returncode


def parse_summary(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip()
    return data


def board_summary_path(profile: str) -> Path:
    return BUILD_DIR / f"board_feedback_{profile}" / "summary.txt"


def run_board_profile(
    profile: str,
    *,
    port: str,
    capture_seconds: int,
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    log_path: Path,
) -> tuple[int, Path, dict[str, str]]:
    summary_path = board_summary_path(profile)
    if summary_path.exists():
        summary_path.unlink()
    cmd = [
        sys.executable,
        str(BOARD_FEEDBACK),
        "--profile",
        profile,
        "--port",
        port,
        "--capture-seconds",
        str(capture_seconds),
        "--rs-depth",
        str(rs_depth),
        "--fetch-buffer-depth",
        str(fetch_buffer_depth),
        "--core-clk-mhz",
        f"{core_clk_mhz:.3f}",
    ]
    rc = run_logged(cmd, cwd=REPO_ROOT, log_path=log_path, timeout=7200)
    return rc, summary_path, parse_summary(summary_path)


def write_overall_summary(
    path: Path,
    *,
    rs_depth: int,
    fetch_buffer_depth: int,
    core_clk_mhz: float,
    uart_clk_div: int,
    basic_rc: int,
    main_results: list[tuple[str, int, Path, Path, dict[str, str]]],
    diag_results: list[tuple[str, int, Path, Path, dict[str, str]]],
    failed_stage: str,
) -> None:
    rs_idx_w = 1 if rs_depth <= 1 else (rs_depth - 1).bit_length()
    lines = [
        "Flow: AX7203 FPGA AutoDebug",
        f"RSDepth: {rs_depth}",
        f"RSIdxW: {rs_idx_w}",
        f"FetchBufferDepth: {fetch_buffer_depth}",
        f"CoreClkMHz: {core_clk_mhz:.3f}",
        f"UartClkDiv: {uart_clk_div}",
        f"BasicReturnCode: {basic_rc}",
        f"FailedStage: {failed_stage}",
        f"MainPass: {failed_stage == 'none'}",
        "MainProfiles:",
    ]

    for profile, rc, log_path, summary_path, summary in main_results:
        lines.extend(
            [
                f"  - {profile}: rc={rc}",
                f"    Log: {log_path}",
                f"    Summary: {summary_path}",
                f"    BuildID: {summary.get('BuildID', 'N/A')}",
                f"    UartBytes: {summary.get('UartBytes', 'N/A')}",
            ]
        )

    if diag_results:
        lines.append("DiagnosticProfiles:")
        for profile, rc, log_path, summary_path, summary in diag_results:
            lines.extend(
                [
                    f"  - {profile}: rc={rc}",
                    f"    Log: {log_path}",
                    f"    Summary: {summary_path}",
                    f"    BuildID: {summary.get('BuildID', 'N/A')}",
                    f"    UartBytes: {summary.get('UartBytes', 'N/A')}",
                ]
            )

    lines.extend(
        [
            f"TimingReport: {BUILD_DIR / 'ax7203' / 'reports' / 'timing_summary.rpt'}",
            f"UtilizationReport: {BUILD_DIR / 'ax7203' / 'reports' / 'utilization.rpt'}",
            f"SynthUtilizationReport: {BUILD_DIR / 'ax7203' / 'reports' / 'synth_utilization.rpt'}",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="COM5")
    parser.add_argument("--rs-depth", type=int, default=48)
    parser.add_argument("--fetch-buffer-depth", type=int, default=16)
    parser.add_argument("--core-clk-mhz", type=float, default=10.0)
    parser.add_argument("--main-capture-seconds", type=int, default=4)
    parser.add_argument("--diag-capture-seconds", type=int, default=8)
    args = parser.parse_args()

    logs_dir = BUILD_DIR / "fpga_autodebug"
    logs_dir.mkdir(parents=True, exist_ok=True)

    basic_log = logs_dir / "01_basic.log"
    basic_cmd = [sys.executable, str(REPO_ROOT / "verification" / "run_all_tests.py"), "--basic"]
    basic_rc = run_logged(basic_cmd, cwd=REPO_ROOT, log_path=basic_log, timeout=1800)

    main_results: list[tuple[str, int, Path, Path, dict[str, str]]] = []
    diag_results: list[tuple[str, int, Path, Path, dict[str, str]]] = []
    failed_stage = "none"

    if basic_rc == 0:
        for idx, profile in enumerate(MAIN_PROFILES, start=2):
            log_path = logs_dir / f"{idx:02d}_{profile}.log"
            rc, summary_path, summary = run_board_profile(
                profile,
                port=args.port,
                capture_seconds=args.main_capture_seconds,
                rs_depth=args.rs_depth,
                fetch_buffer_depth=args.fetch_buffer_depth,
                core_clk_mhz=args.core_clk_mhz,
                log_path=log_path,
            )
            main_results.append((profile, rc, log_path, summary_path, summary))
            if rc != 0:
                failed_stage = profile
                break
    else:
        failed_stage = "basic"

    if failed_stage in {"core_diag", "uart_echo"}:
        for idx, profile in enumerate(DIAGNOSTIC_PROFILES, start=10):
            log_path = logs_dir / f"{idx:02d}_{profile}.log"
            rc, summary_path, summary = run_board_profile(
                profile,
                port=args.port,
                capture_seconds=args.diag_capture_seconds,
                rs_depth=args.rs_depth,
                fetch_buffer_depth=args.fetch_buffer_depth,
                core_clk_mhz=args.core_clk_mhz,
                log_path=log_path,
            )
            diag_results.append((profile, rc, log_path, summary_path, summary))

    overall_summary = logs_dir / "summary.txt"
    write_overall_summary(
        overall_summary,
        rs_depth=args.rs_depth,
        fetch_buffer_depth=args.fetch_buffer_depth,
        core_clk_mhz=args.core_clk_mhz,
        uart_clk_div=max(1, round((args.core_clk_mhz * 1_000_000.0) / 115200.0)),
        basic_rc=basic_rc,
        main_results=main_results,
        diag_results=diag_results,
        failed_stage=failed_stage,
    )

    print(overall_summary)
    return 0 if failed_stage == "none" else 1


if __name__ == "__main__":
    raise SystemExit(main())
