#!/usr/bin/env python3
"""Analyze Verilator preload stall traces and classify likely root cause."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

SUMMARY_FILE = "summary.json"
TRACE_FILE = "trace.fst"

SELECTED_SIGNALS = {
    "sys_clk",
    "debug_core_clk",
    "debug_pc_t0",
    "debug_minstret",
    "debug_rob_head_idx_t0",
    "debug_rob_head_valid_t0",
    "debug_rob_head_complete_t0",
    "debug_rob_head_pc_t0",
    "debug_rob_head_order_id_t0",
    "debug_rob_head_tag_t0",
    "debug_rob_head_is_store_t0",
    "debug_rob_count_t0",
    "debug_rob_head_idx_t1",
    "debug_rob_head_valid_t1",
    "debug_rob_head_complete_t1",
    "debug_rob_head_pc_t1",
    "debug_rob_head_order_id_t1",
    "debug_rob_head_tag_t1",
    "debug_rob_head_is_store_t1",
    "debug_rob_count_t1",
    "debug_mem_iss_valid",
    "debug_mem_iss_pc",
    "debug_mem_iss_order_id",
    "debug_mem_iss_tag",
    "debug_mem_iss_tid",
    "debug_mem_iss_mem_read",
    "debug_mem_iss_mem_write",
    "debug_lsu_req_valid",
    "debug_lsu_req_accept",
    "debug_lsu_req_order_id",
    "debug_lsu_req_tag",
    "debug_lsu_req_tid",
    "debug_lsu_req_addr",
    "debug_lsu_req_wen",
    "debug_lsu_resp_valid",
    "debug_lsu_state",
    "debug_lsu_pending_valid",
    "debug_lsu_pending_order_id",
    "debug_lsu_pending_tag",
    "debug_lsu_pending_addr",
    "debug_lsu_pending_wen",
    "debug_lsu_pending_tid",
    "debug_lsu_m1_txn_is_drain",
    "debug_lsu_sb_forward_valid",
    "debug_lsu_sb_load_hazard",
    "debug_store_buffer_empty",
    "debug_store_buffer_count_t0",
    "debug_store_buffer_count_t1",
    "debug_sb_head_idx_t0",
    "debug_sb_head_valid_t0",
    "debug_sb_head_committed_t0",
    "debug_sb_head_order_id_t0",
    "debug_sb_head_addr_t0",
    "debug_sb_head_idx_t1",
    "debug_sb_head_valid_t1",
    "debug_sb_head_committed_t1",
    "debug_sb_head_order_id_t1",
    "debug_sb_head_addr_t1",
    "debug_m1_req_valid",
    "debug_m1_req_ready",
    "debug_m1_req_addr",
    "debug_m1_req_write",
    "debug_m1_resp_valid",
    "debug_m1_resp_data",
    "debug_m0_req_valid",
    "debug_m0_req_ready",
    "debug_m0_req_addr",
    "debug_m0_resp_valid",
    "debug_m0_resp_data",
    "debug_m0_resp_last",
    "debug_fetch_pc_pending",
    "debug_fetch_pc_out",
    "debug_fetch_if_inst",
    "debug_fetch_if_flags",
    "debug_ic_state_flags",
    "debug_ddr3_req_valid",
    "debug_ddr3_req_ready",
    "debug_ddr3_req_addr",
    "debug_ddr3_req_write",
    "debug_ddr3_resp_valid",
    "mock_mem_write_count",
    "mock_mem_last_write_addr",
    "mock_mem_last_write_data",
}

CSV_FIELDS = [
    "time",
    "cycle",
    "debug_pc_t0",
    "debug_minstret",
    "debug_rob_head_valid_t0",
    "debug_rob_head_complete_t0",
    "debug_rob_head_pc_t0",
    "debug_rob_head_order_id_t0",
    "debug_rob_head_tag_t0",
    "debug_rob_head_is_store_t0",
    "debug_rob_count_t0",
    "debug_mem_iss_valid",
    "debug_mem_iss_pc",
    "debug_mem_iss_order_id",
    "debug_mem_iss_tag",
    "debug_mem_iss_tid",
    "debug_mem_iss_mem_read",
    "debug_mem_iss_mem_write",
    "debug_lsu_req_valid",
    "debug_lsu_req_accept",
    "debug_lsu_req_order_id",
    "debug_lsu_req_tag",
    "debug_lsu_req_tid",
    "debug_lsu_req_addr",
    "debug_lsu_req_wen",
    "debug_lsu_resp_valid",
    "debug_lsu_state",
    "debug_lsu_pending_valid",
    "debug_lsu_pending_order_id",
    "debug_lsu_pending_tag",
    "debug_lsu_pending_addr",
    "debug_lsu_pending_wen",
    "debug_lsu_pending_tid",
    "debug_lsu_m1_txn_is_drain",
    "debug_lsu_sb_forward_valid",
    "debug_lsu_sb_load_hazard",
    "debug_store_buffer_empty",
    "debug_store_buffer_count_t0",
    "debug_store_buffer_count_t1",
    "debug_sb_head_valid_t0",
    "debug_sb_head_committed_t0",
    "debug_sb_head_order_id_t0",
    "debug_sb_head_addr_t0",
    "debug_m1_req_valid",
    "debug_m1_req_ready",
    "debug_m1_req_addr",
    "debug_m1_req_write",
    "debug_m1_resp_valid",
    "debug_m1_resp_data",
    "debug_m0_req_valid",
    "debug_m0_req_ready",
    "debug_m0_req_addr",
    "debug_m0_resp_valid",
    "debug_m0_resp_data",
    "debug_m0_resp_last",
    "debug_fetch_pc_pending",
    "debug_fetch_pc_out",
    "debug_fetch_if_inst",
    "debug_fetch_if_flags",
    "debug_ic_state_flags",
    "mock_mem_write_count",
    "mock_mem_last_write_addr",
    "mock_mem_last_write_data",
]


def to_wsl_path(path: Path) -> str:
    resolved = path.resolve()
    drive = resolved.drive.rstrip(":").lower()
    tail = resolved.as_posix().split(":/", 1)[1]
    return f"/mnt/{drive}/{tail}"


def run_wsl(command: str, *, cwd: Path, timeout: int | None = None) -> subprocess.CompletedProcess[str]:
    wsl_cwd = to_wsl_path(cwd)
    return subprocess.run(
        ["wsl.exe", "bash", "-lc", f"cd {shlex_quote(wsl_cwd)} && {command}"],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def shlex_quote(text: str) -> str:
    return "'" + text.replace("'", "'\"'\"'") + "'"


def which_required_wsl(name: str) -> None:
    proc = run_wsl(f"command -v {shlex_quote(name)}", cwd=REPO_ROOT, timeout=30)
    if proc.returncode != 0:
        raise SystemExit(f"Missing required WSL executable: {name}")


def parse_scalar(text: str) -> int | None:
    if not text:
        return None
    if any(ch in text for ch in "xXzZ"):
        return None
    try:
        return int(text, 2)
    except ValueError:
        return None


def parse_vcd_samples(vcd_path: Path) -> tuple[list[dict[str, int | None]], dict[str, str]]:
    id_to_signal: dict[str, str] = {}
    signal_to_id: dict[str, str] = {}
    scope_stack: list[str] = []
    values: dict[str, int | None] = {}
    selected_ids: set[str] = set()
    samples: list[dict[str, int | None]] = []
    header_done = False
    current_time = 0
    prev_clk = 0
    cycle = 0

    def finalize_timestamp() -> None:
        nonlocal prev_clk, cycle
        clk_signal = "debug_core_clk" if "debug_core_clk" in signal_to_id else "sys_clk"
        clk = values.get(signal_to_id.get(clk_signal, ""), prev_clk)
        if prev_clk == 0 and clk == 1:
            cycle += 1
            sample: dict[str, int | None] = {"time": current_time, "cycle": cycle}
            for signal in SELECTED_SIGNALS:
                sig_id = signal_to_id.get(signal)
                sample[signal] = values.get(sig_id) if sig_id else None
            samples.append(sample)
        if clk is not None:
            prev_clk = clk

    with vcd_path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue

            if not header_done:
                if line.startswith("$scope"):
                    parts = line.split()
                    if len(parts) >= 3:
                        scope_stack.append(parts[2])
                    continue
                if line.startswith("$upscope"):
                    if scope_stack:
                        scope_stack.pop()
                    continue
                if line.startswith("$var"):
                    parts = line.split()
                    if len(parts) >= 5:
                        sig_id = parts[3]
                        sig_name = parts[4]
                        if sig_name in SELECTED_SIGNALS:
                            full_name = ".".join(scope_stack + [sig_name])
                            id_to_signal[sig_id] = sig_name
                            signal_to_id[sig_name] = sig_id
                            selected_ids.add(sig_id)
                            values[sig_id] = 0 if sig_name == "sys_clk" else None
                    continue
                if line.startswith("$enddefinitions"):
                    header_done = True
                    continue
                continue

            if line.startswith("#"):
                finalize_timestamp()
                current_time = int(line[1:])
                continue

            if line[0] in "01xXzZ":
                sig_id = line[1:]
                if sig_id in selected_ids:
                    values[sig_id] = parse_scalar("1" if line[0] == "1" else "0" if line[0] == "0" else line[0])
                continue

            if line[0] in "bBrR":
                parts = line.split()
                if len(parts) != 2:
                    continue
                value_text = parts[0][1:]
                sig_id = parts[1]
                if sig_id in selected_ids:
                    values[sig_id] = parse_scalar(value_text)
                continue

    if header_done:
        finalize_timestamp()
    return samples, signal_to_id


def format_hex(value: int | None, width: int = 8) -> str:
    if value is None:
        return "NA"
    return f"0x{value:0{width}X}"


def sanitize_sample(sample: dict[str, int | None]) -> dict[str, object]:
    return {key: (int(value) if isinstance(value, int) else value) for key, value in sample.items()}


def pick_head(sample: dict[str, int | None]) -> dict[str, int | None]:
    if sample.get("debug_rob_head_valid_t0"):
        return {
            "thread": 0,
            "idx": sample.get("debug_rob_head_idx_t0"),
            "valid": sample.get("debug_rob_head_valid_t0"),
            "complete": sample.get("debug_rob_head_complete_t0"),
            "pc": sample.get("debug_rob_head_pc_t0"),
            "order_id": sample.get("debug_rob_head_order_id_t0"),
            "tag": sample.get("debug_rob_head_tag_t0"),
            "is_store": sample.get("debug_rob_head_is_store_t0"),
        }
    return {
        "thread": 1,
        "idx": sample.get("debug_rob_head_idx_t1"),
        "valid": sample.get("debug_rob_head_valid_t1"),
        "complete": sample.get("debug_rob_head_complete_t1"),
        "pc": sample.get("debug_rob_head_pc_t1"),
        "order_id": sample.get("debug_rob_head_order_id_t1"),
        "tag": sample.get("debug_rob_head_tag_t1"),
        "is_store": sample.get("debug_rob_head_is_store_t1"),
    }


def decode_instruction(elf_path: Path, pc: int | None, window: int = 0x20) -> dict[str, object]:
    result = {"available": False, "instruction": "", "context": ""}
    if pc is None or pc == 0:
        return result
    objdump = shutil.which("riscv-none-elf-objdump")
    if not objdump or not elf_path.exists():
        return result
    start = max(0, pc - window)
    stop = pc + window + 4
    proc = subprocess.run(
        [
            objdump,
            "-d",
            "-S",
            f"--start-address=0x{start:x}",
            f"--stop-address=0x{stop:x}",
            str(elf_path),
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if proc.returncode != 0:
        return result
    result["context"] = proc.stdout
    inst_re = re.compile(r"^\s*([0-9a-fA-F]+):\s+[0-9a-fA-F]+\s+(.+)$")
    target_hex = f"{pc:x}"
    for line in proc.stdout.splitlines():
        match = inst_re.match(line)
        if match and match.group(1).lower() == target_hex.lower():
            result["available"] = True
            result["instruction"] = match.group(2).strip()
            break
    return result


def choose_stall_window(samples: list[dict[str, int | None]], summary: dict[str, object]) -> list[dict[str, int | None]]:
    trace_start_cycle = int(summary.get("TraceStartCycle", 0) or 0)

    def localize_cycle(absolute_cycle: int) -> int:
        if absolute_cycle <= 0:
            return 0
        if trace_start_cycle <= 0:
            return absolute_cycle
        return max(0, absolute_cycle - trace_start_cycle)

    last_instret_cycle = int(summary.get("LastInstretProgressCycle", 0) or 0)
    if last_instret_cycle:
        start_cycle = max(0, localize_cycle(last_instret_cycle) - 4096)
        window = [sample for sample in samples if (sample.get("cycle") or 0) >= start_cycle]
        if window:
            return window
    last_commit_cycle = int(summary.get("LastCommitProgressCycle", 0) or 0)
    if last_commit_cycle:
        start_cycle = max(0, localize_cycle(last_commit_cycle) - 4096)
        window = [sample for sample in samples if (sample.get("cycle") or 0) >= start_cycle]
        if window:
            return window
    danger_cycle = int(summary.get("DangerEntryCycle", 0) or 0)
    if danger_cycle:
        start_cycle = localize_cycle(danger_cycle)
        window = [sample for sample in samples if (sample.get("cycle") or 0) >= start_cycle]
        if window:
            return window
    danger_instret = int(summary.get("DangerEntryInstRet", 0) or 0)
    if danger_instret:
        window = [sample for sample in samples if (sample.get("debug_minstret") or 0) >= danger_instret]
        if window:
            return window
    start = int(summary.get("DangerWindowEntryPc", 0) or 0)
    if start:
        window = [sample for sample in samples if (sample.get("debug_pc_t0") or 0) >= start]
        if window:
            return window
    return samples


def event_key_from_sample(sample: dict[str, int | None]) -> tuple[int, int, int, int, int, int]:
    return (
        int(sample.get("debug_mem_iss_pc") or 0),
        int(sample.get("debug_mem_iss_order_id") or 0),
        int(sample.get("debug_mem_iss_tag") or 0),
        int(sample.get("debug_mem_iss_tid") or 0),
        int(sample.get("debug_mem_iss_mem_read") or 0),
        int(sample.get("debug_mem_iss_mem_write") or 0),
    )


def req_key_from_sample(sample: dict[str, int | None]) -> tuple[int, int, int, int, int]:
    return (
        int(sample.get("debug_lsu_req_order_id") or 0),
        int(sample.get("debug_lsu_req_tag") or 0),
        int(sample.get("debug_lsu_req_tid") or 0),
        int(sample.get("debug_lsu_req_addr") or 0),
        int(sample.get("debug_lsu_req_wen") or 0),
    )


def classify(
    head: dict[str, int | None],
    top_replay: tuple[tuple[int, int, int, int, int, int], int] | None,
    top_accept: tuple[tuple[int, int, int, int, int], int] | None,
    stall_samples: list[dict[str, int | None]],
) -> tuple[str, list[str]]:
    reasons: list[str] = []
    head_order = int(head.get("order_id") or 0)
    head_tag = int(head.get("tag") or 0)
    head_store = bool(head.get("is_store"))
    head_complete_seen = any(sample.get("debug_rob_head_complete_t0") for sample in stall_samples)
    sb_hazard_seen = any(sample.get("debug_lsu_sb_load_hazard") for sample in stall_samples)
    m1_resp_seen = any(sample.get("debug_m1_resp_valid") for sample in stall_samples)
    last_sample = stall_samples[-1]
    sb_head_order_t0 = int(last_sample.get("debug_sb_head_order_id_t0") or 0)
    sb_head_committed_t0 = bool(last_sample.get("debug_sb_head_committed_t0"))
    rob_empty_last = not bool(last_sample.get("debug_rob_head_valid_t0")) and int(last_sample.get("debug_rob_count_t0") or 0) == 0
    fetch_flags_last = int(last_sample.get("debug_fetch_if_flags") or 0)
    fetch_req_active_last = bool(fetch_flags_last & 0x80)
    icache_resp_valid_last = bool(fetch_flags_last & 0x20)
    icache_final_valid_last = bool(fetch_flags_last & 0x10)
    icache_response_stale_last = bool(fetch_flags_last & 0x08)
    m0_req_seen = any(sample.get("debug_m0_req_valid") for sample in stall_samples)
    m0_handshake_seen = any(sample.get("debug_m0_req_valid") and sample.get("debug_m0_req_ready") for sample in stall_samples)
    m0_resp_seen = any(sample.get("debug_m0_resp_valid") for sample in stall_samples)

    if head_store and top_accept is not None:
        key, count = top_accept
        order_id, tag, _tid, _addr, wen = key
        if wen == 1 and order_id == head_order and tag == head_tag and not head_complete_seen:
            reasons.append("ROB head is a store.")
            reasons.append("LSU repeatedly accepts a store with matching order_id/tag.")
            reasons.append("Head entry never becomes complete inside the stall window.")
            return "store_completion_lost", reasons

    if (
        head_store
        and not head_complete_seen
        and head_order >= 0xFF00
        and sb_head_order_t0 <= 0x00FF
        and not sb_head_committed_t0
    ):
        reasons.append("ROB head is an older incomplete store near the 16-bit order_id wrap point.")
        reasons.append("Store-buffer head already points at a much smaller wrapped order_id that is still uncommitted.")
        reasons.append("This is consistent with age comparisons using raw < and > on 16-bit order_ids after wraparound.")
        return "order_id_wrap_age_inversion", reasons

    if top_replay is not None:
        key, _count = top_replay
        _pc, _order_id, _tag, _tid, mem_read, mem_write = key
        if mem_read and sb_hazard_seen:
            reasons.append("Replay source is a load.")
            reasons.append("LSU/store-buffer reports load hazard inside the stall window.")
            return "load_store_forward_hazard_loop", reasons
        if mem_read and m1_resp_seen and not head_complete_seen:
            reasons.append("Replay source is a load.")
            reasons.append("M1 responses are observed, but the head entry still does not complete.")
            return "mem_resp_wakeup_lost", reasons
        if mem_write and not head_complete_seen:
            reasons.append("Replay source is a store-like MEM issue.")
            reasons.append("No head completion observed after repeated MEM activity.")
            return "store_completion_lost", reasons

    if rob_empty_last and fetch_req_active_last and not icache_resp_valid_last and not icache_final_valid_last:
        reasons.append("ROB is empty at the terminal sample; retirement is not blocked by an uncleared head entry.")
        reasons.append("IF still has fetch_req_active=1, but inst_memory/icache is not producing resp_valid/final_valid.")
        if icache_response_stale_last:
            reasons.append("The terminal fetch response is marked stale by epoch filtering.")
            return "frontend_stale_fetch_loop", reasons
        if not m0_req_seen and not m0_handshake_seen and not m0_resp_seen:
            reasons.append("No M0 request/response activity is visible in the stall window for the stuck fetch.")
            return "frontend_fetch_request_lost", reasons
        reasons.append("M0/fill activity exists in the window, but the final fetch still never completes.")
        return "frontend_fetch_stall", reasons

    reasons.append("No single branch satisfied the fixed classifier.")
    reasons.append("Use the generated CSV plus trace.fst for manual wave review.")
    return "unknown_needs_wave", reasons


def write_csv(path: Path, samples: list[dict[str, int | None]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for sample in samples:
            row = {}
            for field in CSV_FIELDS:
                value = sample.get(field)
                if isinstance(value, int):
                    row[field] = f"0x{value:X}" if ("addr" in field.lower() or field.endswith("_pc") or field.endswith("_data") or field.endswith("_tag")) else value
                elif value is None:
                    row[field] = ""
                else:
                    row[field] = value
            writer.writerow(row)


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def write_text_report(path: Path, report: dict[str, object]) -> None:
    lines = [
        f"Classification: {report['classification']}",
        f"TracePath: {report['trace_path']}",
        f"SummaryPath: {report['summary_path']}",
        f"ElfPath: {report['elf_path']}",
        "",
        "ROB Head:",
    ]
    head = report["rob_head"]
    lines.extend(
        [
            f"  Thread: {head['thread']}",
            f"  Valid: {head['valid']}",
            f"  Complete: {head['complete']}",
            f"  PC: {head['pc_text']}",
            f"  OrderId: {head['order_id']}",
            f"  Tag: {head['tag']}",
            f"  IsStore: {head['is_store']}",
            f"  Instruction: {head['instruction']}",
        ]
    )

    if report["top_replay_source"] is not None:
        replay = report["top_replay_source"]
        lines.extend(
            [
                "",
                "Replay Source:",
                f"  Count: {replay['count']}",
                f"  PC: {replay['pc_text']}",
                f"  OrderId: {replay['order_id']}",
                f"  Tag: {replay['tag']}",
                f"  Tid: {replay['tid']}",
                f"  MemRead: {replay['mem_read']}",
                f"  MemWrite: {replay['mem_write']}",
                f"  Instruction: {replay['instruction']}",
            ]
        )

    if report["top_lsu_accept"] is not None:
        accept = report["top_lsu_accept"]
        lines.extend(
            [
                "",
                "Top LSU Accept:",
                f"  Count: {accept['count']}",
                f"  OrderId: {accept['order_id']}",
                f"  Tag: {accept['tag']}",
                f"  Tid: {accept['tid']}",
                f"  Addr: {accept['addr_text']}",
                f"  StoreWen: {accept['wen']}",
            ]
        )

    state = report["state_summary"]
    lines.extend(
        [
            "",
            "LSU/StoreBuffer Summary:",
            f"  LSUStateHistogram: {state['lsu_state_histogram']}",
            f"  PendingValidSeen: {state['pending_valid_seen']}",
            f"  PendingOrderIds: {state['pending_order_ids']}",
            f"  PendingTags: {state['pending_tags']}",
            f"  PendingAddrs: {state['pending_addrs']}",
            f"  SbLoadHazardSeen: {state['sb_load_hazard_seen']}",
            f"  SbForwardValidSeen: {state['sb_forward_valid_seen']}",
            f"  SbHeadOrderIdsT0: {state['sb_head_order_ids_t0']}",
            f"  SbHeadAddrsT0: {state['sb_head_addrs_t0']}",
            f"  SbHeadCommittedT0Seen: {state['sb_head_committed_t0_seen']}",
            f"  M1ReqHandshakes: {state['m1_req_handshake_count']}",
            f"  M1RespCount: {state['m1_resp_count']}",
        ]
    )
    front = report["frontend_summary"]
    lines.extend(
        [
            "",
            "Front-end Summary:",
            f"  RobCountT0Start: {front['rob_count_t0_start']}",
            f"  RobCountT0End: {front['rob_count_t0_end']}",
            f"  FetchPcPendingStart: {front['fetch_pc_pending_start']}",
            f"  FetchPcPendingEnd: {front['fetch_pc_pending_end']}",
            f"  FetchPcOutEnd: {front['fetch_pc_out_end']}",
            f"  FetchReqActiveEnd: {front['fetch_req_active_end']}",
            f"  IcacheRespValidEnd: {front['icache_resp_valid_end']}",
            f"  IcacheFinalValidEnd: {front['icache_final_valid_end']}",
            f"  IcacheRespStaleEnd: {front['icache_response_stale_end']}",
            f"  LastIcStateFlags: {front['last_ic_state_flags']}",
            f"  M0ReqSeen: {front['m0_req_seen']}",
            f"  M0ReqHandshakeCount: {front['m0_req_handshake_count']}",
            f"  M0RespCount: {front['m0_resp_count']}",
            f"  LastM0ReqAddr: {front['last_m0_req_addr']}",
        ]
    )
    lines.append("")
    lines.append("Classifier Reasons:")
    for reason in report["classifier_reasons"]:
        lines.append(f"  - {reason}")
    lines.append("")
    lines.append(f"CSV: {report['stall_window_csv']}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--trace")
    parser.add_argument("--summary")
    parser.add_argument("--elf")
    parser.add_argument("--keep-vcd", action="store_true")
    args = parser.parse_args()

    run_dir = Path(args.run_dir).resolve()
    trace_path = Path(args.trace).resolve() if args.trace else run_dir / TRACE_FILE
    summary_path = Path(args.summary).resolve() if args.summary else run_dir / SUMMARY_FILE
    summary = json.loads(summary_path.read_text(encoding="utf-8"))

    if args.elf:
        elf_path = Path(args.elf).resolve()
    else:
        benchmark = "dhrystone"
        elf_candidates = sorted(run_dir.glob(f"{benchmark}*.elf"))
        if not elf_candidates:
            raise SystemExit(f"Could not locate ELF under {run_dir}")
        elf_path = elf_candidates[0]

    which_required_wsl("fst2vcd")
    with tempfile.NamedTemporaryFile(prefix="verilator_stall_", suffix=".vcd", dir=run_dir, delete=False) as temp_vcd:
        vcd_path = Path(temp_vcd.name)

    proc = run_wsl(
        f"fst2vcd {shlex_quote(to_wsl_path(trace_path))} > {shlex_quote(to_wsl_path(vcd_path))}",
        cwd=REPO_ROOT,
        timeout=600,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)

    try:
        samples, _signal_map = parse_vcd_samples(vcd_path)
    finally:
        if not args.keep_vcd and vcd_path.exists():
            vcd_path.unlink()

    if not samples:
        raise SystemExit("No sampled data found in converted VCD.")

    stall_samples = choose_stall_window(samples, summary)
    if not stall_samples:
        raise SystemExit("Could not derive a stall window from trace + summary.")

    head_start = pick_head(stall_samples[0])
    head_decode = decode_instruction(elf_path, head_start.get("pc"))

    replay_hist = Counter()
    accept_hist = Counter()
    lsu_state_hist = Counter()
    pending_order_ids: set[int] = set()
    pending_tags: set[int] = set()
    pending_addrs: set[int] = set()
    sb_head_order_ids_t0: set[int] = set()
    sb_head_addrs_t0: set[int] = set()
    sb_head_committed_t0_seen = False
    sb_load_hazard_seen = False
    sb_forward_valid_seen = False
    m1_req_handshake_count = 0
    m1_resp_count = 0
    m0_req_seen = False
    m0_req_handshake_count = 0
    m0_resp_count = 0
    last_m0_req_addr = 0
    pending_valid_seen = False

    for sample in stall_samples:
        if sample.get("debug_mem_iss_valid"):
            replay_hist[event_key_from_sample(sample)] += 1
        if sample.get("debug_lsu_req_valid") and sample.get("debug_lsu_req_accept"):
            accept_hist[req_key_from_sample(sample)] += 1
        lsu_state_hist[int(sample.get("debug_lsu_state") or 0)] += 1
        if sample.get("debug_lsu_pending_valid"):
            pending_valid_seen = True
            if sample.get("debug_lsu_pending_order_id") is not None:
                pending_order_ids.add(int(sample["debug_lsu_pending_order_id"]))
            if sample.get("debug_lsu_pending_tag") is not None:
                pending_tags.add(int(sample["debug_lsu_pending_tag"]))
            if sample.get("debug_lsu_pending_addr") is not None:
                pending_addrs.add(int(sample["debug_lsu_pending_addr"]))
        if sample.get("debug_sb_head_order_id_t0") is not None:
            sb_head_order_ids_t0.add(int(sample["debug_sb_head_order_id_t0"]))
        if sample.get("debug_sb_head_addr_t0") is not None:
            sb_head_addrs_t0.add(int(sample["debug_sb_head_addr_t0"]))
        if sample.get("debug_sb_head_committed_t0"):
            sb_head_committed_t0_seen = True
        if sample.get("debug_lsu_sb_load_hazard"):
            sb_load_hazard_seen = True
        if sample.get("debug_lsu_sb_forward_valid"):
            sb_forward_valid_seen = True
        if sample.get("debug_m1_req_valid") and sample.get("debug_m1_req_ready"):
            m1_req_handshake_count += 1
        if sample.get("debug_m1_resp_valid"):
            m1_resp_count += 1
        if sample.get("debug_m0_req_valid"):
            m0_req_seen = True
            last_m0_req_addr = int(sample.get("debug_m0_req_addr") or 0)
        if sample.get("debug_m0_req_valid") and sample.get("debug_m0_req_ready"):
            m0_req_handshake_count += 1
        if sample.get("debug_m0_resp_valid"):
            m0_resp_count += 1

    top_replay = replay_hist.most_common(1)[0] if replay_hist else None
    top_accept = accept_hist.most_common(1)[0] if accept_hist else None

    classification, classifier_reasons = classify(head_start, top_replay, top_accept, stall_samples)

    replay_payload = None
    if top_replay is not None:
        replay_key, replay_count = top_replay
        replay_decode = decode_instruction(elf_path, replay_key[0])
        replay_payload = {
            "count": replay_count,
            "pc": replay_key[0],
            "pc_text": format_hex(replay_key[0]),
            "order_id": replay_key[1],
            "tag": replay_key[2],
            "tid": replay_key[3],
            "mem_read": replay_key[4],
            "mem_write": replay_key[5],
            "instruction": replay_decode["instruction"],
        }

    accept_payload = None
    if top_accept is not None:
        accept_key, accept_count = top_accept
        accept_payload = {
            "count": accept_count,
            "order_id": accept_key[0],
            "tag": accept_key[1],
            "tid": accept_key[2],
            "addr": accept_key[3],
            "addr_text": format_hex(accept_key[3]),
            "wen": accept_key[4],
        }

    report = {
        "classification": classification,
        "classifier_reasons": classifier_reasons,
        "trace_path": str(trace_path),
        "summary_path": str(summary_path),
        "elf_path": str(elf_path),
        "stall_window_start_time": int(stall_samples[0]["time"]),
        "stall_window_end_time": int(stall_samples[-1]["time"]),
        "stall_window_start_cycle": int(stall_samples[0]["cycle"]),
        "stall_window_end_cycle": int(stall_samples[-1]["cycle"]),
        "stall_sample_count": len(stall_samples),
        "rob_head": {
            "thread": head_start["thread"],
            "idx": head_start["idx"],
            "valid": bool(head_start["valid"]),
            "complete": bool(head_start["complete"]),
            "pc": head_start["pc"],
            "pc_text": format_hex(head_start["pc"]),
            "order_id": head_start["order_id"],
            "tag": head_start["tag"],
            "is_store": bool(head_start["is_store"]),
            "instruction": head_decode["instruction"],
        },
        "top_replay_source": replay_payload,
        "top_lsu_accept": accept_payload,
        "state_summary": {
            "lsu_state_histogram": dict(sorted(lsu_state_hist.items())),
            "pending_valid_seen": pending_valid_seen,
            "pending_order_ids": sorted(pending_order_ids),
            "pending_tags": sorted(pending_tags),
            "pending_addrs": [format_hex(addr) for addr in sorted(pending_addrs)],
            "sb_load_hazard_seen": sb_load_hazard_seen,
            "sb_forward_valid_seen": sb_forward_valid_seen,
            "sb_head_order_ids_t0": sorted(sb_head_order_ids_t0),
            "sb_head_addrs_t0": [format_hex(addr) for addr in sorted(sb_head_addrs_t0)],
            "sb_head_committed_t0_seen": sb_head_committed_t0_seen,
            "m1_req_handshake_count": m1_req_handshake_count,
            "m1_resp_count": m1_resp_count,
        },
        "frontend_summary": {
            "rob_count_t0_start": int(stall_samples[0].get("debug_rob_count_t0") or 0),
            "rob_count_t0_end": int(stall_samples[-1].get("debug_rob_count_t0") or 0),
            "fetch_pc_pending_start": format_hex(int(stall_samples[0].get("debug_fetch_pc_pending") or 0)),
            "fetch_pc_pending_end": format_hex(int(stall_samples[-1].get("debug_fetch_pc_pending") or 0)),
            "fetch_pc_out_end": format_hex(int(stall_samples[-1].get("debug_fetch_pc_out") or 0)),
            "fetch_req_active_end": bool(int(stall_samples[-1].get("debug_fetch_if_flags") or 0) & 0x80),
            "icache_resp_valid_end": bool(int(stall_samples[-1].get("debug_fetch_if_flags") or 0) & 0x20),
            "icache_final_valid_end": bool(int(stall_samples[-1].get("debug_fetch_if_flags") or 0) & 0x10),
            "icache_response_stale_end": bool(int(stall_samples[-1].get("debug_fetch_if_flags") or 0) & 0x08),
            "last_ic_state_flags": f"0x{int(stall_samples[-1].get('debug_ic_state_flags') or 0):02X}",
            "m0_req_seen": m0_req_seen,
            "m0_req_handshake_count": m0_req_handshake_count,
            "m0_resp_count": m0_resp_count,
            "last_m0_req_addr": format_hex(last_m0_req_addr),
        },
    }

    report_json = run_dir / "stall_report.json"
    report_txt = run_dir / "stall_report.txt"
    report_csv = run_dir / "stall_window.csv"
    report["stall_window_csv"] = str(report_csv)

    write_json(report_json, report)
    write_text_report(report_txt, report)
    write_csv(report_csv, stall_samples)

    print(report_json)
    print(report_txt)
    print(report_csv)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
