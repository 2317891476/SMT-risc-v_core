#!/usr/bin/env python3
"""Build and run the Verilator + mock-memory mainline environment via WSL."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = REPO_ROOT / "rtl"
ROM_DIR = REPO_ROOT / "rom"
COMP_TEST_DIR = REPO_ROOT / "comp_test"
VERILATOR_DIR = COMP_TEST_DIR / "verilator"
BUILD_ROOT = REPO_ROOT / "build" / "verilator" / "mainline"
LIB_RAM_BFM = REPO_ROOT / "libs" / "REG_ARRAY" / "SRAM" / "ram_bfm.v"
CLK_WIZ_STUB = COMP_TEST_DIR / "clk_wiz_0_stub.v"
PRELOAD_ROM = REPO_ROOT / "rom" / "test_verilator_ddr3_preload.s"
LOADER_ROM = REPO_ROOT / "rom" / "test_fpga_ddr3_loader.s"
RTL_FILELIST = COMP_TEST_DIR / "rtl_files.txt"


def which_required(name: str) -> str:
    resolved = shutil.which(name)
    if not resolved:
        raise SystemExit(f"Missing required executable: {name}")
    return resolved


def run_checked(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    return proc


def to_wsl_path(path: Path) -> str:
    resolved = path.resolve()
    drive = resolved.drive.rstrip(":").lower()
    tail = resolved.as_posix().split(":/", 1)[1]
    return f"/mnt/{drive}/{tail}"


def quote_wsl(path: str) -> str:
    return shlex.quote(path)


def run_wsl(
    command: str,
    *,
    cwd: Path,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
) -> subprocess.CompletedProcess[str]:
    env_prefix = ""
    if env:
        env_prefix = " ".join(f"{key}={shlex.quote(value)}" for key, value in env.items()) + " "
    wsl_cwd = to_wsl_path(cwd)
    proc = subprocess.run(
        ["wsl.exe", "bash", "-lc", f"cd {quote_wsl(wsl_cwd)} && {env_prefix}{command}"],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    return proc


def which_required_wsl(*names: str) -> None:
    for name in names:
        proc = run_wsl(f"command -v {shlex.quote(name)}", cwd=REPO_ROOT, timeout=30)
        if proc.returncode != 0:
            raise SystemExit(f"Missing required WSL executable: {name}")


def load_manifest(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def parse_summary_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_rtl_sources() -> list[Path]:
    sources: list[Path] = []
    for raw_line in RTL_FILELIST.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//"):
            continue
        name = Path(line).name
        if name == "ddr3_mem_port.v":
            continue
        candidate = REPO_ROOT / line
        if not candidate.exists():
            candidate = RTL_DIR / name
        if candidate.exists():
            sources.append(candidate.resolve())
    debug_beacon = RTL_DIR / "debug_beacon_tx.v"
    if debug_beacon.exists() and debug_beacon.resolve() not in sources:
        sources.append(debug_beacon.resolve())
    return sources


def write_preload_hex(binary_path: Path, output_path: Path) -> None:
    data = binary_path.read_bytes()
    words: list[str] = []
    for idx in range(0, len(data), 4):
        chunk = data[idx : idx + 4]
        word = 0
        for byte_idx, byte in enumerate(chunk):
            word |= byte << (8 * byte_idx)
        words.append(f"{word:08x}")
    output_path.write_text("\n".join(words) + ("\n" if words else ""), encoding="ascii")


def build_benchmark_image(benchmark: str, runs: int, cpu_hz: int, out_dir: Path) -> dict[str, object]:
    cmd = [
        sys.executable,
        str(REPO_ROOT / "fpga" / "scripts" / "build_benchmark_image.py"),
        "--benchmark",
        benchmark,
        "--cpu-hz",
        str(cpu_hz),
        "--ddr3-xip",
        "--emit-bin",
        "--manifest",
        "--verilator-mainline",
    ]
    if benchmark == "dhrystone":
        cmd.extend(["--dhrystone-runs", str(runs)])
    else:
        raise SystemExit(f"Unsupported benchmark for first-pass Verilator flow: {benchmark}")
    run_checked(cmd, cwd=REPO_ROOT, timeout=600)
    manifest = load_manifest(REPO_ROOT / "build" / "benchmark_images" / benchmark / f"{benchmark}_ddr3.json")
    out_dir.mkdir(parents=True, exist_ok=True)
    cloned = dict(manifest)
    for key in ("elf", "bin"):
        src = Path(str(manifest[key]))
        dst = out_dir / src.name
        shutil.copy2(src, dst)
        cloned[key] = str(dst)
    manifest_path = out_dir / f"{benchmark}_ddr3.json"
    manifest_path.write_text(json.dumps(cloned, indent=2), encoding="utf-8")
    cloned["manifest"] = str(manifest_path)
    return cloned


def build_rom_image(mode: str) -> None:
    asm = PRELOAD_ROM if mode == "preload" else LOADER_ROM
    cmd = [
        sys.executable,
        str(REPO_ROOT / "fpga" / "scripts" / "build_rom_image.py"),
        "--asm",
        str(asm),
        "--merge-mem-subsys",
    ]
    if mode == "preload":
        cmd.extend(["--march", "rv32i_zicsr"])
    run_checked(cmd, cwd=REPO_ROOT, timeout=300)


def build_verilator_command(
    *,
    obj_dir: Path,
    exe_name: str,
    harness_cpp: Path,
    top_sv: Path,
    mock_sv: Path,
    dcache_mode: str,
    preload_direct_boot: bool,
    enable_trace: bool,
) -> str:
    rtl_sources = load_rtl_sources()
    source_list = [
        *rtl_sources,
        LIB_RAM_BFM,
        CLK_WIZ_STUB,
        mock_sv,
        top_sv,
    ]
    parts = [
        "verilator",
        "--cc",
        "--sv",
        "--exe",
        "--build",
        "--timing",
        "-j",
        "0",
        "--top-module",
        "verilator_mainline_top",
        "--Mdir",
        to_wsl_path(obj_dir),
        "-o",
        exe_name,
        "-Wno-fatal",
        "-CFLAGS",
        shlex.quote("-std=c++17 -O2"),
        "+incdir+" + to_wsl_path(RTL_DIR),
        "+incdir+" + to_wsl_path(VERILATOR_DIR),
        "-DFPGA_MODE=1",
        "-DVERILATOR_MAINLINE=1",
        "-DVERILATOR_FAST_UART=1",
        "-DENABLE_MEM_SUBSYS=1",
        "-DENABLE_DDR3=1",
        "-DL2_PASSTHROUGH=1",
        "-DSMT_MODE=1",
        "-DENABLE_ROCC_ACCEL=0",
    ]
    if dcache_mode == "passthrough":
        parts.append("-DDCACHE_PASSTHROUGH=1")
    elif dcache_mode == "registered-pt":
        parts.append("-DDCACHE_REGISTERED_PT=1")
    elif dcache_mode == "read-only":
        parts.append("-DDCACHE_READ_ONLY=1")
    if enable_trace:
        parts.append("--trace-fst")
    if preload_direct_boot:
        parts.append("-DVERILATOR_MAINLINE_PRELOAD_BOOT=1")
    parts.extend(quote_wsl(to_wsl_path(path)) for path in source_list)
    parts.append(quote_wsl(to_wsl_path(harness_cpp)))
    return " ".join(parts)


def maybe_decode_pc_window(
    *,
    summary: dict[str, object],
    elf_path: Path,
    run_dir: Path,
    window: int = 0x20,
) -> dict[str, object]:
    result: dict[str, object] = {
        "LastPcDecodedAvailable": False,
        "LastPcDecodedInstruction": "",
        "LastPcDecodedContextPath": "",
    }
    objdump = shutil.which("riscv-none-elf-objdump")
    if not objdump or not elf_path.exists():
        return result

    try:
        pc = int(summary.get("LastPcT0", 0))
    except (TypeError, ValueError):
        pc = 0
    try:
        pending_pc = int(summary.get("LastFetchPcPending", 0))
    except (TypeError, ValueError):
        pending_pc = 0
    targets = [("LastPcT0", pc)]
    if pending_pc and pending_pc != pc:
        targets.append(("LastFetchPcPending", pending_pc))
    if all(target_pc == 0 for _, target_pc in targets):
        return result

    context_path = run_dir / "pc_window.objdump.txt"
    result["LastPcDecodedContextPath"] = str(context_path)
    inst_re = re.compile(r"^\s*([0-9a-fA-F]+):\s+[0-9a-fA-F]+\s+(.+)$")
    sections: list[str] = []
    for target_name, target_pc in targets:
        start = max(0, target_pc - window)
        stop = target_pc + window + 4
        cmd = [
            objdump,
            "-d",
            "-S",
            f"--start-address=0x{start:x}",
            f"--stop-address=0x{stop:x}",
            str(elf_path),
        ]
        proc = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        sections.append(f"===== {target_name}=0x{target_pc:08X} =====\n")
        sections.append(proc.stdout + proc.stderr)
        if proc.returncode != 0:
            continue
        if target_name != "LastPcT0":
            continue
        target_hex = f"{target_pc:x}"
        for line in proc.stdout.splitlines():
            match = inst_re.match(line)
            if not match:
                continue
            if match.group(1).lower() == target_hex.lower():
                result["LastPcDecodedAvailable"] = True
                result["LastPcDecodedInstruction"] = match.group(2).strip()
                break
    context_path.write_text("\n".join(sections), encoding="utf-8", errors="replace")
    return result


def format_summary(
    summary: dict[str, object], *, benchmark: str, mode: str, runs: int, budget_cycles: int
) -> str:
    instret = int(summary.get("InstRetired", 0) or 0)
    global_ipc_vs_budget = (instret / budget_cycles) if budget_cycles else 0.0
    lines = [
        f"Mode: {mode}",
        f"DCacheMode: {summary.get('DCacheMode', 'full')}",
        f"MockLatency: {summary.get('MockLatency', 1)}",
        f"Benchmark: {benchmark}",
        f"Runs: {runs}",
        f"ConfiguredRuns: {summary.get('ConfiguredRuns', runs)}",
        f"EffectiveRuns: {summary.get('EffectiveRuns', runs)}",
        f"VerilatorFixedRuns: {summary.get('VerilatorFixedRuns', False)}",
        f"ExitReason: {summary.get('ExitReason', 'N/A')}",
        f"EntryReached: {summary.get('EntryReached', False)}",
        f"BenchmarkStartSeen: {summary.get('BenchmarkStartSeen', False)}",
        f"BenchmarkDoneSeen: {summary.get('BenchmarkDoneSeen', False)}",
        f"LoaderSemanticPass: {summary.get('LoaderSemanticPass', False)}",
        f"TrapSeen: {summary.get('TrapSeen', False)}",
        f"TrapCause: {summary.get('TrapCause', 0)}",
        f"Cycles: {summary.get('Cycles', 0)}",
        f"InstRetired: {summary.get('InstRetired', 0)}",
        f"IPCx1000: {summary.get('IPCx1000', 0)}",
        f"GlobalIPCvsBudget: {global_ipc_vs_budget:.6f}",
        f"LastPcT0: 0x{int(summary.get('LastPcT0', 0)):08X}",
        f"LastPcT1: 0x{int(summary.get('LastPcT1', 0)):08X}",
        f"LastFetchPcPending: 0x{int(summary.get('LastFetchPcPending', 0)):08X}",
        f"LastFetchPcOut: 0x{int(summary.get('LastFetchPcOut', 0)):08X}",
        f"LastFetchIfInst: 0x{int(summary.get('LastFetchIfInst', 0)):08X}",
        f"LastFetchIfFlags: 0x{int(summary.get('LastFetchIfFlags', 0)):02X}",
        f"LastIcStateFlags: 0x{int(summary.get('LastIcStateFlags', 0)):02X}",
        f"IcHighMissCount: {summary.get('IcHighMissCount', 0)}",
        f"IcMemReqCount: {summary.get('IcMemReqCount', 0)}",
        f"IcMemRespCount: {summary.get('IcMemRespCount', 0)}",
        f"IcCpuRespCount: {summary.get('IcCpuRespCount', 0)}",
        f"InstrRetiredCount: {summary.get('InstrRetiredCount', 0)}",
        f"SpecMmioLoadBlockedCycles: {summary.get('SpecMmioLoadBlockedCycles', 0)}",
        f"SpecMmioLoadViolationCount: {summary.get('SpecMmioLoadViolationCount', 0)}",
        f"MmioLoadAtRobHeadCount: {summary.get('MmioLoadAtRobHeadCount', 0)}",
        f"OlderStoreBlockedMmioLoadCycles: {summary.get('OlderStoreBlockedMmioLoadCycles', 0)}",
        f"RobCommit0SeenCount: {summary.get('RobCommit0SeenCount', 0)}",
        f"RobCommit1SeenCount: {summary.get('RobCommit1SeenCount', 0)}",
        f"LastRobCommit0OrderId: {summary.get('LastRobCommit0OrderId', 0)}",
        f"LastRobCommit1OrderId: {summary.get('LastRobCommit1OrderId', 0)}",
        f"LastRobCountT0: {summary.get('LastRobCountT0', 0)}",
        f"LastRobCountT1: {summary.get('LastRobCountT1', 0)}",
        f"LastRobHeadFlushedT0: {summary.get('LastRobHeadFlushedT0', False)}",
        f"LastRobHeadFlushedT1: {summary.get('LastRobHeadFlushedT1', False)}",
        f"LastRobRecovering: {summary.get('LastRobRecovering', False)}",
        f"LastRobRecoverTid: {summary.get('LastRobRecoverTid', 0)}",
        f"LastRobRecoverPtr: {summary.get('LastRobRecoverPtr', 0)}",
        f"MemIssSeenCount: {summary.get('MemIssSeenCount', 0)}",
        f"P1WinnerCount: {summary.get('P1WinnerCount', 0)}",
        f"P1MemWinnerCount: {summary.get('P1MemWinnerCount', 0)}",
        f"Wb1MemCount: {summary.get('Wb1MemCount', 0)}",
        f"LastP1WinnerValid: {summary.get('LastP1WinnerValid', False)}",
        f"LastP1Winner: {summary.get('LastP1Winner', 0)}",
        f"LastMemFuBusy: {summary.get('LastMemFuBusy', False)}",
        f"LastMemFuOrderId: {summary.get('LastMemFuOrderId', 0)}",
        f"LastMemFuTid: {summary.get('LastMemFuTid', 0)}",
        f"LastMemIssueInhibit: {summary.get('LastMemIssueInhibit', False)}",
        f"LastP1MemCandValid: {summary.get('LastP1MemCandValid', False)}",
        f"LastP1MemCandOrderId: {summary.get('LastP1MemCandOrderId', 0)}",
        f"LastP1MemCandTag: {summary.get('LastP1MemCandTag', 0)}",
        f"LastP1MemCandRead: {summary.get('LastP1MemCandRead', False)}",
        f"LastP1MemCandWrite: {summary.get('LastP1MemCandWrite', False)}",
        f"LastMemCandRawValid: {summary.get('LastMemCandRawValid', False)}",
        f"LastMemCandClear: {summary.get('LastMemCandClear', False)}",
        f"LastMemCandSet: {summary.get('LastMemCandSet', False)}",
        f"LastIqMemSelFound: {summary.get('LastIqMemSelFound', False)}",
        f"LastIqMemSelIdx: {summary.get('LastIqMemSelIdx', 0)}",
        f"LastIqMemOldestStoreValidT0: {summary.get('LastIqMemOldestStoreValidT0', False)}",
        f"LastIqMemOldestStoreValidT1: {summary.get('LastIqMemOldestStoreValidT1', False)}",
        f"LastIqMemOldestStoreOrderIdT0: {summary.get('LastIqMemOldestStoreOrderIdT0', 0)}",
        f"LastIqMemOldestStoreOrderIdT1: {summary.get('LastIqMemOldestStoreOrderIdT1', 0)}",
        f"LastIqMemStoreCountT0: {summary.get('LastIqMemStoreCountT0', 0)}",
        f"LastIqMemStoreCountT1: {summary.get('LastIqMemStoreCountT1', 0)}",
        f"LastFlush: {summary.get('LastFlush', False)}",
        f"LastFlushTid: {summary.get('LastFlushTid', 0)}",
        f"LastFlushOrderValid: {summary.get('LastFlushOrderValid', False)}",
        f"LastFlushOrderId: {summary.get('LastFlushOrderId', 0)}",
        f"LastWb0Valid: {summary.get('LastWb0Valid', False)}",
        f"LastWb0Tag: {summary.get('LastWb0Tag', 0)}",
        f"LastWb0RegsWrite: {summary.get('LastWb0RegsWrite', False)}",
        f"LastWb1Valid: {summary.get('LastWb1Valid', False)}",
        f"LastWb1Tag: {summary.get('LastWb1Tag', 0)}",
        f"LastWb1RegsWrite: {summary.get('LastWb1RegsWrite', False)}",
        f"LastWb1Fu: {summary.get('LastWb1Fu', 0)}",
        f"UartStatusLoadCount: {summary.get('UartStatusLoadCount', 0)}",
        f"UartTxStoreCount: {summary.get('UartTxStoreCount', 0)}",
        f"UartTxByteSeenCount: {summary.get('UartTxByteSeenCount', 0)}",
        f"LastUartTxByte: 0x{int(summary.get('LastUartTxByte', 0)):02X}",
        f"UnexpectedUartSeen: {summary.get('UnexpectedUartSeen', False)}",
        f"UnexpectedUartCycle: {summary.get('UnexpectedUartCycle', 0)}",
        f"UnexpectedUartIndex: {summary.get('UnexpectedUartIndex', 0)}",
        f"UnexpectedUartExpected: 0x{int(summary.get('UnexpectedUartExpected', 0)):02X}",
        f"UnexpectedUartActual: 0x{int(summary.get('UnexpectedUartActual', 0)):02X}",
        f"UnexpectedUartPcT0: 0x{int(summary.get('UnexpectedUartPcT0', 0)):08X}",
        f"UnexpectedUartLsuReq: valid={summary.get('UnexpectedUartLsuReqValid', False)} accept={summary.get('UnexpectedUartLsuReqAccept', False)} order={summary.get('UnexpectedUartLsuReqOrderId', 0)} tag={summary.get('UnexpectedUartLsuReqTag', 0)} addr=0x{int(summary.get('UnexpectedUartLsuReqAddr', 0)):08X} wdata=0x{int(summary.get('UnexpectedUartLsuReqWdata', 0)):08X} func3={summary.get('UnexpectedUartLsuReqFunc3', 0)} wen={summary.get('UnexpectedUartLsuReqWen', False)}",
        f"UnexpectedUartM1Req: valid={summary.get('UnexpectedUartM1ReqValid', False)} ready={summary.get('UnexpectedUartM1ReqReady', False)} addr=0x{int(summary.get('UnexpectedUartM1ReqAddr', 0)):08X} wdata=0x{int(summary.get('UnexpectedUartM1ReqWdata', 0)):08X} wen=0x{int(summary.get('UnexpectedUartM1ReqWen', 0)):X} write={summary.get('UnexpectedUartM1ReqWrite', False)}",
        f"UnexpectedUartWB: wb0_valid={summary.get('UnexpectedUartWb0Valid', False)} wb0_tag={summary.get('UnexpectedUartWb0Tag', 0)} wb0_data=0x{int(summary.get('UnexpectedUartWb0Data', 0)):08X} wb1_valid={summary.get('UnexpectedUartWb1Valid', False)} wb1_tag={summary.get('UnexpectedUartWb1Tag', 0)} wb1_fu={summary.get('UnexpectedUartWb1Fu', 0)} wb1_data=0x{int(summary.get('UnexpectedUartWb1Data', 0)):08X}",
        f"BadUartStoreSeen: {summary.get('BadUartStoreSeen', False)}",
        f"BadUartStoreCycle: {summary.get('BadUartStoreCycle', 0)}",
        f"BadUartStore: pc=0x{int(summary.get('BadUartStorePc', 0)):08X} addr=0x{int(summary.get('BadUartStoreAddr', 0)):08X} op_a=0x{int(summary.get('BadUartStoreOpA', 0)):08X} op_b=0x{int(summary.get('BadUartStoreOpB', 0)):08X} imm=0x{int(summary.get('BadUartStoreImm', 0)):08X} order={summary.get('BadUartStoreOrderId', 0)} tag={summary.get('BadUartStoreTag', 0)} func3={summary.get('BadUartStoreFunc3', 0)} tid={summary.get('BadUartStoreTid', 0)}",
        f"BadUartStoreSrc: rd=x{summary.get('BadUartStoreRd', 0)} rs1=x{summary.get('BadUartStoreRs1', 0)}/p{summary.get('BadUartStorePrs1', 0)}/tag{summary.get('BadUartStoreSrc1Tag', 0)} rs2=x{summary.get('BadUartStoreRs2', 0)}/p{summary.get('BadUartStorePrs2', 0)}/tag{summary.get('BadUartStoreSrc2Tag', 0)}",
        f"BadUartStoreDataSrc: prf_a=0x{int(summary.get('BadUartStorePrfA', 0)):08X} prf_b=0x{int(summary.get('BadUartStorePrfB', 0)):08X} tagbuf_a={summary.get('BadUartStoreTagbufAValid', False)}:0x{int(summary.get('BadUartStoreTagbufAData', 0)):08X} tagbuf_b={summary.get('BadUartStoreTagbufBValid', False)}:0x{int(summary.get('BadUartStoreTagbufBData', 0)):08X} fwd_a={summary.get('BadUartStoreFwdA', 0)} fwd_b={summary.get('BadUartStoreFwdB', 0)}",
        f"StrcpyMvSeen: {summary.get('StrcpyMvSeen', False)}",
        f"StrcpyMvCycle: {summary.get('StrcpyMvCycle', 0)}",
        f"StrcpyMv: pc=0x{int(summary.get('StrcpyMvPc', 0)):08X} op_a=0x{int(summary.get('StrcpyMvOpA', 0)):08X} op_b=0x{int(summary.get('StrcpyMvOpB', 0)):08X} order={summary.get('StrcpyMvOrderId', 0)} tag={summary.get('StrcpyMvTag', 0)} tid={summary.get('StrcpyMvTid', 0)} rd=x{summary.get('StrcpyMvRd', 0)}/p{summary.get('StrcpyMvPrd', 0)}",
        f"StrcpyMvSrc: rs1=x{summary.get('StrcpyMvRs1', 0)}/p{summary.get('StrcpyMvPrs1', 0)}/tag{summary.get('StrcpyMvSrc1Tag', 0)} rs2=x{summary.get('StrcpyMvRs2', 0)}/p{summary.get('StrcpyMvPrs2', 0)}/tag{summary.get('StrcpyMvSrc2Tag', 0)}",
        f"StrcpyMvDataSrc: prf_a=0x{int(summary.get('StrcpyMvPrfA', 0)):08X} prf_b=0x{int(summary.get('StrcpyMvPrfB', 0)):08X} tagbuf_a={summary.get('StrcpyMvTagbufAValid', False)}:0x{int(summary.get('StrcpyMvTagbufAData', 0)):08X} tagbuf_b={summary.get('StrcpyMvTagbufBValid', False)}:0x{int(summary.get('StrcpyMvTagbufBData', 0)):08X} fwd_a={summary.get('StrcpyMvFwdA', 0)} fwd_b={summary.get('StrcpyMvFwdB', 0)}",
        f"StrcpyMvPrfW: w0={summary.get('StrcpyMvPrfW0En', False)} p{summary.get('StrcpyMvPrfW0Addr', 0)}=0x{int(summary.get('StrcpyMvPrfW0Data', 0)):08X} w1={summary.get('StrcpyMvPrfW1En', False)} p{summary.get('StrcpyMvPrfW1Addr', 0)}=0x{int(summary.get('StrcpyMvPrfW1Data', 0)):08X}",
        f"MainLwA0: seen={summary.get('MainLwA0Seen', False)} addr=0x{int(summary.get('MainLwA0Addr', 0)):08X} base=0x{int(summary.get('MainLwA0Base', 0)):08X} imm=0x{int(summary.get('MainLwA0Imm', 0)):08X} order={summary.get('MainLwA0OrderId', 0)} tag={summary.get('MainLwA0Tag', 0)} rd_p{summary.get('MainLwA0Prd', 0)} rs1_p{summary.get('MainLwA0Prs1', 0)}",
        f"MainLwA0WB: seen={summary.get('MainLwA0WbSeen', False)} data=0x{int(summary.get('MainLwA0WbData', 0)):08X} prd={summary.get('MainLwA0WbPrd', 0)}",
        f"MainAddiA0: seen={summary.get('MainAddiA0Seen', False)} op_a=0x{int(summary.get('MainAddiA0OpA', 0)):08X} result=0x{int(summary.get('MainAddiA0Result', 0)):08X} order={summary.get('MainAddiA0OrderId', 0)} tag={summary.get('MainAddiA0Tag', 0)} rd_p{summary.get('MainAddiA0Prd', 0)} rs1_p{summary.get('MainAddiA0Prs1', 0)} src1_tag={summary.get('MainAddiA0Src1Tag', 0)}",
        f"MainAddiA0DataSrc: prf_a=0x{int(summary.get('MainAddiA0PrfA', 0)):08X} tagbuf_a={summary.get('MainAddiA0TagbufAValid', False)}:0x{int(summary.get('MainAddiA0TagbufAData', 0)):08X}",
        f"MainA0PrdLastWrite: count={summary.get('MainA0PrdWriteCount', 0)} port={summary.get('MainA0PrdLastWritePort', 0)} pc=0x{int(summary.get('MainA0PrdLastWritePc', 0)):08X} order={summary.get('MainA0PrdLastWriteOrderId', 0)} tag={summary.get('MainA0PrdLastWriteTag', 0)} rd=x{summary.get('MainA0PrdLastWriteRd', 0)} fu={summary.get('MainA0PrdLastWriteFu', 0)} data=0x{int(summary.get('MainA0PrdLastWriteData', 0)):08X}",
        f"MainA0PrdFirstBadWrite: seen={summary.get('MainA0PrdFirstBadWriteSeen', False)} port={summary.get('MainA0PrdFirstBadWritePort', 0)} pc=0x{int(summary.get('MainA0PrdFirstBadWritePc', 0)):08X} order={summary.get('MainA0PrdFirstBadWriteOrderId', 0)} tag={summary.get('MainA0PrdFirstBadWriteTag', 0)} rd=x{summary.get('MainA0PrdFirstBadWriteRd', 0)} fu={summary.get('MainA0PrdFirstBadWriteFu', 0)} data=0x{int(summary.get('MainA0PrdFirstBadWriteData', 0)):08X}",
        f"MainA0PrdFirstFree: seen={summary.get('MainA0PrdFirstFreeSeen', False)} port={summary.get('MainA0PrdFirstFreePort', 0)} order={summary.get('MainA0PrdFirstFreeOrderId', 0)} tag={summary.get('MainA0PrdFirstFreeTag', 0)} rd=x{summary.get('MainA0PrdFirstFreeRd', 0)}",
        f"MainAddiA0WB: seen={summary.get('MainAddiA0WbSeen', False)} cycle={summary.get('MainAddiA0WbCycle', 0)} port={summary.get('MainAddiA0WbPort', 0)} tid={summary.get('MainAddiA0WbTid', 0)} prd={summary.get('MainAddiA0WbPrd', 0)} data=0x{int(summary.get('MainAddiA0WbData', 0)):08X} w0={summary.get('MainAddiA0WbW0En', False)} p{summary.get('MainAddiA0WbW0Addr', 0)}=0x{int(summary.get('MainAddiA0WbW0Data', 0)):08X} w1={summary.get('MainAddiA0WbW1En', False)} p{summary.get('MainAddiA0WbW1Addr', 0)}=0x{int(summary.get('MainAddiA0WbW1Data', 0)):08X}",
        f"MockMemReads: {summary.get('MockMemReads', 0)}",
        f"MockMemWrites: {summary.get('MockMemWrites', 0)}",
        f"MockMemRangeErrorCount: {summary.get('MockMemRangeErrorCount', 0)}",
        f"MockMemLastRangeErrorAddr: 0x{int(summary.get('MockMemLastRangeErrorAddr', 0)):08X}",
        f"MockMemUninitReadCount: {summary.get('MockMemUninitReadCount', 0)}",
        f"LsuReqSeenCount: {summary.get('LsuReqSeenCount', 0)}",
        f"LsuReqAcceptCount: {summary.get('LsuReqAcceptCount', 0)}",
        f"LsuRespSeenCount: {summary.get('LsuRespSeenCount', 0)}",
        f"LastLsuM1Cooldown: {summary.get('LastLsuM1Cooldown', False)}",
        f"LastLsuDrainHoldoff: {summary.get('LastLsuDrainHoldoff', False)}",
        f"LastLsuSbDrainUrgent: {summary.get('LastLsuSbDrainUrgent', False)}",
        f"LastLsuSbHasPendingStores: {summary.get('LastLsuSbHasPendingStores', False)}",
        f"LastLsuSbMemWriteValid: {summary.get('LastLsuSbMemWriteValid', False)}",
        f"StoreBufferEmptyLast: {summary.get('StoreBufferEmptyLast', False)}",
        f"StoreCountT0Last: {summary.get('StoreCountT0Last', 0)}",
        f"StoreCountT1Last: {summary.get('StoreCountT1Last', 0)}",
        f"M1ReqSeenCount: {summary.get('M1ReqSeenCount', 0)}",
        f"M1ReqHandshakeCount: {summary.get('M1ReqHandshakeCount', 0)}",
        f"LastM1ReqAddr: 0x{int(summary.get('LastM1ReqAddr', 0)):08X}",
        f"LastM1ReqWrite: {summary.get('LastM1ReqWrite', False)}",
        f"LastInstretProgressCycle: {summary.get('LastInstretProgressCycle', 0)}",
        f"LastCommitProgressCycle: {summary.get('LastCommitProgressCycle', 0)}",
        f"LastLsuReqAcceptCycle: {summary.get('LastLsuReqAcceptCycle', 0)}",
        f"LastM1ReqHandshakeCycle: {summary.get('LastM1ReqHandshakeCycle', 0)}",
        f"TraceStartCycle: {summary.get('TraceStartCycle', 0)}",
        f"TraceStopCycle: {summary.get('TraceStopCycle', 0)}",
        f"Ddr3ReqSeenCount: {summary.get('Ddr3ReqSeenCount', 0)}",
        f"Ddr3ReqHandshakeCount: {summary.get('Ddr3ReqHandshakeCount', 0)}",
        f"Ddr3RespSeenCount: {summary.get('Ddr3RespSeenCount', 0)}",
        f"M0ReqSeenCount: {summary.get('M0ReqSeenCount', 0)}",
        f"M0ReqHandshakeCount: {summary.get('M0ReqHandshakeCount', 0)}",
        f"M0RespSeenCount: {summary.get('M0RespSeenCount', 0)}",
        f"LastM0ReqHandshakeCycle: {summary.get('LastM0ReqHandshakeCycle', 0)}",
        f"LastM0RespCycle: {summary.get('LastM0RespCycle', 0)}",
        f"LastDdr3ReqAddr: 0x{int(summary.get('LastDdr3ReqAddr', 0)):08X}",
        f"LastDdr3ReqWdata: 0x{int(summary.get('LastDdr3ReqWdata', 0)):08X}",
        f"LastDdr3RespData: 0x{int(summary.get('LastDdr3RespData', 0)):08X}",
        f"LastDdr3ReqWen: 0x{int(summary.get('LastDdr3ReqWen', 0)):X}",
        f"LastDdr3ReqWrite: {summary.get('LastDdr3ReqWrite', False)}",
        f"LastM0ReqAddr: 0x{int(summary.get('LastM0ReqAddr', 0)):08X}",
        f"LastM0RespData: 0x{int(summary.get('LastM0RespData', 0)):08X}",
        f"LastM0RespLast: {summary.get('LastM0RespLast', False)}",
        f"MemsubsysM0Ddr3RespSeenCount: {summary.get('MemsubsysM0Ddr3RespSeenCount', 0)}",
        f"LastMemsubsysM0Ddr3RespData: 0x{int(summary.get('LastMemsubsysM0Ddr3RespData', 0)):08X}",
        f"LastMemsubsysM0Ddr3RespLast: {summary.get('LastMemsubsysM0Ddr3RespLast', False)}",
        f"LastMemsubsysDdr3ArbState: {summary.get('LastMemsubsysDdr3ArbState', 0)}",
        f"LastMemsubsysDdr3M0WordIdx: {summary.get('LastMemsubsysDdr3M0WordIdx', 0)}",
        f"DCacheMissEventCount: {summary.get('DCacheMissEventCount', 0)}",
        f"LastDCacheMissEvent: {summary.get('LastDCacheMissEvent', False)}",
        f"StuckPcSeen: {summary.get('StuckPcSeen', False)}",
        f"StuckPcValue: 0x{int(summary.get('StuckPcValue', 0)):08X}",
        f"StuckPcRepeatCount: {summary.get('StuckPcRepeatCount', 0)}",
        f"RetireStallSeen: {summary.get('RetireStallSeen', False)}",
        f"RetireStallCycles: {summary.get('RetireStallCycles', 0)}",
        f"DangerWindowSeen: {summary.get('DangerWindowSeen', False)}",
        f"DangerWindowEntryPc: 0x{int(summary.get('DangerWindowEntryPc', 0)):08X}",
        f"DangerEntryCycle: {summary.get('DangerEntryCycle', 0)}",
        f"DangerEntryInstRet: {summary.get('DangerEntryInstRet', 0)}",
        f"DangerLsuReqSeenDelta: {summary.get('DangerLsuReqSeenDelta', 0)}",
        f"DangerLsuReqAcceptDelta: {summary.get('DangerLsuReqAcceptDelta', 0)}",
        f"DangerLsuRespSeenDelta: {summary.get('DangerLsuRespSeenDelta', 0)}",
        f"DangerM1ReqSeenDelta: {summary.get('DangerM1ReqSeenDelta', 0)}",
        f"DangerM1ReqHandshakeDelta: {summary.get('DangerM1ReqHandshakeDelta', 0)}",
        f"DangerM0ReqSeenDelta: {summary.get('DangerM0ReqSeenDelta', 0)}",
        f"DangerM0ReqHandshakeDelta: {summary.get('DangerM0ReqHandshakeDelta', 0)}",
        f"DangerM0RespSeenDelta: {summary.get('DangerM0RespSeenDelta', 0)}",
        f"DangerMockMemWritesDelta: {summary.get('DangerMockMemWritesDelta', 0)}",
        f"LastM1ReqAddrAfterDanger: 0x{int(summary.get('LastM1ReqAddrAfterDanger', 0)):08X}",
        f"LastM1ReqWriteAfterDanger: {summary.get('LastM1ReqWriteAfterDanger', False)}",
        f"LastM0ReqAddrAfterDanger: 0x{int(summary.get('LastM0ReqAddrAfterDanger', 0)):08X}",
        f"LastPcDecodedAvailable: {summary.get('LastPcDecodedAvailable', False)}",
        f"LastPcDecodedInstruction: {summary.get('LastPcDecodedInstruction', '')}",
        f"LastPcDecodedContextPath: {summary.get('LastPcDecodedContextPath', '')}",
        f"LoaderBytesInjected: {summary.get('LoaderBytesInjected', 0)}",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("preload", "loader-semantic"), default="preload")
    parser.add_argument("--benchmark", choices=("dhrystone",), default="dhrystone")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--cpu-hz", type=int, default=25_000_000)
    parser.add_argument("--mock-latency", type=int, default=1)
    parser.add_argument(
        "--dcache-mode",
        choices=("full", "passthrough", "registered-pt", "read-only"),
        default="full",
    )
    parser.add_argument("--max-cycles", type=int, default=20_000_000)
    parser.add_argument("--header-gap-cycles", type=int, default=16)
    parser.add_argument("--payload-gap-cycles", type=int, default=2)
    parser.add_argument("--stuck-pc-threshold", type=int, default=256)
    parser.add_argument("--stall-cycle-threshold", type=int, default=200_000)
    parser.add_argument("--danger-window-instret-threshold", type=int, default=1024)
    parser.add_argument("--trace", action="store_true")
    parser.add_argument("--trace-on-stuck", action="store_true")
    parser.add_argument("--trace-start-cycle", type=int, default=0)
    parser.add_argument("--trace-stop-cycle", type=int, default=0)
    parser.add_argument("--trace-after-stuck-cycles", type=int, default=4096)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--print-wsl-cmd", action="store_true")
    args = parser.parse_args()

    which_required("wsl")
    which_required_wsl("verilator", "make", "g++")

    run_dir = BUILD_ROOT / args.mode / f"{args.benchmark}_runs{args.runs}_lat{args.mock_latency}_{args.dcache_mode}"
    obj_dir = run_dir / ("obj_dir_trace" if (args.trace or args.trace_on_stuck) else "obj_dir")
    logs_dir = run_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    manifest = build_benchmark_image(args.benchmark, args.runs, args.cpu_hz, run_dir)
    build_rom_image(args.mode)

    summary_json = run_dir / "summary.json"
    summary_txt = run_dir / "summary.txt"
    uart_log = run_dir / "uart.log"
    preload_hex = run_dir / "payload_preload.hex"
    trace_path = run_dir / ("trace.fst" if (args.trace or args.trace_on_stuck) else "trace.fst")
    if (args.trace or args.trace_on_stuck) and trace_path.exists():
        trace_path.unlink()

    if args.mode == "preload":
        write_preload_hex(Path(str(manifest["bin"])), preload_hex)
        preload_hex_wsl = to_wsl_path(preload_hex)
    else:
        preload_hex_wsl = ""

    top_sv = VERILATOR_DIR / "verilator_mainline_top.sv"
    mock_sv = VERILATOR_DIR / "mock_ddr3_mem.sv"
    harness_cpp = VERILATOR_DIR / "verilator_main.cpp"
    exe_name = "sim_mainline"

    build_cmd = build_verilator_command(
        obj_dir=obj_dir,
        exe_name=exe_name,
        harness_cpp=harness_cpp,
        top_sv=top_sv,
        mock_sv=mock_sv,
        dcache_mode=args.dcache_mode,
        preload_direct_boot=(args.mode == "preload"),
        enable_trace=(args.trace or args.trace_on_stuck),
    )
    if args.print_wsl_cmd:
        print(build_cmd)
    build_proc = run_wsl(build_cmd, cwd=REPO_ROOT, timeout=3600)
    (logs_dir / "01_build.log").write_text(build_proc.stdout + build_proc.stderr, encoding="utf-8")
    if build_proc.returncode != 0:
        sys.stderr.write(build_proc.stdout)
        sys.stderr.write(build_proc.stderr)
        return build_proc.returncode

    if args.build_only:
        summary_txt.write_text("BuildOnly: true\n", encoding="utf-8")
        print(summary_txt)
        return 0

    sim_exe_wsl = to_wsl_path(obj_dir / exe_name)
    summary_json_wsl = to_wsl_path(summary_json)
    uart_log_wsl = to_wsl_path(uart_log)
    payload_bin_wsl = to_wsl_path(Path(str(manifest["bin"])))
    sim_args = [
        quote_wsl(sim_exe_wsl),
        "--mode",
        shlex.quote(args.mode),
        "--payload-bin",
        quote_wsl(payload_bin_wsl),
        "--summary-json",
        quote_wsl(summary_json_wsl),
        "--uart-log",
        quote_wsl(uart_log_wsl),
        "--entry-pc",
        shlex.quote(str(int(manifest["entry"]))),
        "--payload-base",
        shlex.quote(str(int(manifest["load_addr"]))),
        "--max-cycles",
        shlex.quote(str(args.max_cycles)),
        "--header-gap-cycles",
        shlex.quote(str(args.header_gap_cycles)),
        "--payload-gap-cycles",
        shlex.quote(str(args.payload_gap_cycles)),
        "--stuck-pc-threshold",
        shlex.quote(str(args.stuck_pc_threshold)),
        "--stall-cycle-threshold",
        shlex.quote(str(args.stall_cycle_threshold)),
        "--danger-window-instret-threshold",
        shlex.quote(str(args.danger_window_instret_threshold)),
        f"+MOCK_DDR3_FORCE_LATENCY={args.mock_latency}",
    ]
    if args.trace or args.trace_on_stuck:
        sim_args.extend(
            [
                "--trace-file",
                quote_wsl(to_wsl_path(trace_path)),
            ]
        )
    if args.trace:
        sim_args.append("--trace")
    if args.trace_on_stuck:
        sim_args.append("--trace-on-stuck")
    if args.trace_start_cycle:
        sim_args.extend(["--trace-start-cycle", shlex.quote(str(args.trace_start_cycle))])
    if args.trace_stop_cycle:
        sim_args.extend(["--trace-stop-cycle", shlex.quote(str(args.trace_stop_cycle))])
    if args.trace_after_stuck_cycles:
        sim_args.extend(["--trace-after-stuck-cycles", shlex.quote(str(args.trace_after_stuck_cycles))])
    if args.mode == "preload":
        sim_args.append(f"+MOCK_DDR3_PRELOAD_HEX={quote_wsl(preload_hex_wsl)}")
    sim_cmd = " ".join(sim_args)
    if args.print_wsl_cmd:
        print(sim_cmd)
    sim_proc = run_wsl(sim_cmd, cwd=ROM_DIR, timeout=3600)
    (logs_dir / "02_run.log").write_text(sim_proc.stdout + sim_proc.stderr, encoding="utf-8")

    if sim_proc.returncode != 0 and not summary_json.exists():
        sys.stderr.write(sim_proc.stdout)
        sys.stderr.write(sim_proc.stderr)
        return sim_proc.returncode

    summary = parse_summary_json(summary_json)
    effective_runs = args.runs
    verilator_fixed_runs = False
    if args.benchmark == "dhrystone":
        effective_runs = 10
        verilator_fixed_runs = True
    summary["ConfiguredRuns"] = args.runs
    summary["EffectiveRuns"] = effective_runs
    summary["VerilatorFixedRuns"] = verilator_fixed_runs
    summary["DCacheMode"] = args.dcache_mode
    summary["MockLatency"] = args.mock_latency
    summary["TraceStartCycle"] = int(args.trace_start_cycle or 0)
    summary["TraceStopCycle"] = int(args.trace_stop_cycle or 0)
    summary.update(
        maybe_decode_pc_window(
            summary=summary,
            elf_path=Path(str(manifest["elf"])),
            run_dir=run_dir,
        )
    )
    summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    summary_txt.write_text(
        format_summary(
            summary,
            benchmark=args.benchmark,
            mode=args.mode,
            runs=args.runs,
            budget_cycles=args.max_cycles,
        ),
        encoding="utf-8",
    )
    print(summary_txt)

    if sim_proc.returncode != 0:
        sys.stderr.write(sim_proc.stdout)
        sys.stderr.write(sim_proc.stderr)
        return sim_proc.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
