#!/bin/bash
# build-config.sh <path_to_kernel_tree> <cpu-fragment> [gpu-fragment] [platform-fragment...]
#
# Example for this laptop:
#   build-config.sh /usr/src/linux-7.1.6-cachyos0 \
#       cpu/intel-raptorlake gpu/nvidia platform/laptop platform/victus16-r1xxx
#
# Order MATTERS: later fragments can override earlier ones
# (the same principle as the kernel's merge_config.sh, which is called here).
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:?path to the kernel tree}"
shift

[ -f "$SRC/scripts/kconfig/merge_config.sh" ] || { echo "merge_config.sh not found in $SRC" >&2; exit 1; }

FRAGS=("$HERE"/common/*.config)
for f in "$@"; do
    FRAGS+=("$HERE/$f.config")
done

echo "=== fragments (in application order) ==="
printf '  %s\n' "${FRAGS[@]}"

cd "$SRC"
"$SRC/scripts/kconfig/merge_config.sh" -m .config "${FRAGS[@]}"
make olddefconfig

echo
echo "=== scripts/kconfig/merge_config.sh WARNINGS (redefined) above — check them by hand ==="
echo "=== next: make -j\$(nproc) && make modules_install && make install ==="
