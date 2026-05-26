# SifangCore Linux Bring-up

Target path: `RV32IMA_Zicsr_Zifencei` with S-mode, Sv32 MMU, OpenSBI, Linux, and a BusyBox initramfs. This is the MMU Linux route, not NoMMU Linux.

## Current Gate

The RTL has the first Linux prerequisites under directed test:

- S-mode CSR state and delegated S-mode traps.
- RV32A AMO and LR/SC.
- PLIC source 2 UART interrupt through M-context and S-context.
- OpenSBI-style M-mode STIP injection into S-mode timer interrupt.
- Sv32 I/D translation, PTW memory access, commit-ordered `sfence.vma`,
  precise fetch/load/store page faults at ROB commit, and board-baseline PTW
  A/D cache visibility.

The Linux image flow is intentionally not marked as passing yet. The active blocker is producing a real `fw_payload.bin` from OpenSBI, RV32 Linux, BusyBox initramfs, and the SifangCore DTB, then running the Verilator `linux-preload` gate. Full write-back D-cache page-table coherence is still future work; the first Linux target uses the board-equivalent read-only D-cache configuration.

## Expected Build Outputs

The planned WSL build script writes artifacts under `build/linux/`:

- `sifangcore_ax7203.dtb`
- `rootfs.cpio`
- `fw_payload.bin`

`fw_payload.bin` is the image consumed by the future Verilator `linux-preload` mode and later by the AX7203 UART loader.

## Device Tree Baseline

The board model is single hart, DDR3 at `0x80000000`, CLINT at `0x02000000`, PLIC at `0x0C000000`, and a byte-wide ns16550a UART at `0x13001000`.

UART console settings:

```text
clock-frequency = 25000000
current-speed = 115200
reg-shift = 0
reg-io-width = 1
```

## Usage

Run from the repository root. The script must be executed in WSL because it expects Linux build tools and RISC-V cross-compilers:

```bash
bash software/linux/scripts/build_linux_payload.sh
```

The script currently checks tool availability and creates the SifangCore DTB/initramfs staging artifacts. Full OpenSBI/Linux/BusyBox builds are enabled by setting `SIFANGCORE_LINUX_SOURCES_READY=1` after the source trees and configs are prepared.

## First Pass Criteria

The first Linux pass must be in Verilator, not on the board:

```powershell
python fpga\scripts\run_verilator_mainline.py --mode linux-preload --linux-payload build\linux\fw_payload.bin --dcache-mode read-only --mock-latency 1 --require-board-config-match
```

Passing UART tokens:

- `OpenSBI`
- `Boot HART ID: 0`
- `Linux version`
- `Run /init as init process`
- `SIFANGCORE LINUX PASS`

Do not attempt Vivado/JTAG Linux board validation until the Verilator Linux gate is green.
