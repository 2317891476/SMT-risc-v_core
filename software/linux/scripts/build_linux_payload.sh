#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
build_dir="${repo_root}/build/linux"
dts="${repo_root}/software/linux/dts/sifangcore_ax7203.dts"
init_src="${repo_root}/software/linux/initramfs/init"

mkdir -p "${build_dir}/initramfs/bin"

need_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required tool: $1" >&2
        return 1
    fi
}

need_tool dtc
need_tool cpio

dtc -I dts -O dtb -o "${build_dir}/sifangcore_ax7203.dtb" "${dts}"
install -m 0755 "${init_src}" "${build_dir}/initramfs/init"

(
    cd "${build_dir}/initramfs"
    find . -print0 | cpio --null -ov --format=newc > "${build_dir}/rootfs.cpio"
)

if [[ "${SIFANGCORE_LINUX_SOURCES_READY:-0}" != "1" ]]; then
    cat >&2 <<'EOF'
Created DTB and initramfs staging artifacts.

Full fw_payload.bin generation is intentionally gated. Prepare OpenSBI,
Linux RV32 MMU, BusyBox, and the matching configs, then rerun with:

  SIFANGCORE_LINUX_SOURCES_READY=1 bash software/linux/scripts/build_linux_payload.sh

Expected final output:
  build/linux/fw_payload.bin
EOF
    exit 0
fi

need_tool riscv64-unknown-elf-gcc
need_tool riscv64-linux-gnu-gcc
need_tool make

: "${OPENSBI_DIR:?set OPENSBI_DIR to an OpenSBI source tree}"
: "${LINUX_DIR:?set LINUX_DIR to a Linux source tree}"
: "${BUSYBOX_DIR:?set BUSYBOX_DIR to a BusyBox source tree}"

echo "Source trees are present, but repo-local Linux/OpenSBI configs are not complete yet." >&2
echo "Do not treat this as a bootable Linux image until fw_payload.bin is emitted." >&2
exit 2
