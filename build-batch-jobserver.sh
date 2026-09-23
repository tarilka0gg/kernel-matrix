#!/bin/bash
# build-batch-jobserver.sh SRC OUT name1 [name2 ...]
#
# Builds several --target at once through ONE shared GNU Make jobserver (-j24),
# rather than as separate processes with a split --jobs. The difference matters:
# with separate processes (matrix-build.sh --parallel N), each combo HARD-holds
# its share of threads even while it's idle itself (during a single-threaded
# link) — the rest just sit idle. With a jobserver: while a combo is linking
# (single-threaded), it holds only 1 token and RELEASES the other 23 back into
# the shared pool, where another combo that's actively compiling picks them up
# immediately. The CPU never sits idle for no reason.
#
# Technically: we generate a temporary Makefile where each combo is a separate
# target that recursively calls `$(MAKE) -C srctree ... bzImage` (specifically
# $(MAKE), not the literal text "make" — that's the only way GNU Make passes
# the jobserver fd/fifo to the child process). `make -j24 -f temp.mk all` then
# distributes the 24 tokens across all live combos in real time on its own.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:?path to the kernel tree}"; shift
OUT="${1:?output directory}"; shift
NAMES=("$@")
[ "${#NAMES[@]}" -ge 1 ] || { echo "need at least one --target NAME" >&2; exit 1; }

CC="${CC:-}"; [ -n "$CC" ] || { command -v sccache >/dev/null 2>&1 && CC="sccache gcc" || CC=gcc; }
LD="${LD:-}"
if [ -z "$LD" ]; then
    command -v ld.lld >/dev/null 2>&1 && LD=ld.lld || {
        for p in /usr/lib/llvm/*/bin/ld.lld; do [ -x "$p" ] && LD="$p" && break; done
        LD="${LD:-ld.bfd}"
    }
fi
SEED="${SEED:-$HERE/seed/default.config}"
[ -f "$SEED" ] || SEED="$SRC/.config"
JOBS="${JOBS:-$(nproc)}"

echo "=== jobserver-batch: ${#NAMES[@]} combos, shared -j$JOBS, CC='$CC' LD='$LD' ==="

# --- phase 1: prep (config resolution + hardlink copy) — cheap,
# sequential, so they don't fight over I/O while all starting at once ---
declare -a STREES
for name in "${NAMES[@]}"; do
    TF="$HERE/targets/$name.target"
    [ -f "$TF" ] || { echo "no such target: $TF" >&2; exit 1; }
    mapfile -t frags < <(grep -v '^\s*#' "$TF" | grep -v '^\s*$')

    odir="$OUT/$name"
    mkdir -p "$odir"
    cp "$SEED" "$odir/.config"
    abs_frags=("$HERE"/common/*.config)
    for f in "${frags[@]}"; do abs_frags+=("$HERE/$f.config"); done
    "$SRC/scripts/kconfig/merge_config.sh" -O "$odir" -m "$odir/.config" "${abs_frags[@]}" >"$odir/prep.log" 2>&1

    (cd "$SRC" && KCONFIG_CONFIG="$odir/.config" srctree=. ARCH=x86_64 SRCARCH=x86 \
        CC=gcc HOSTCC=gcc LD=ld.bfd ./scripts/kconfig/conf --olddefconfig Kconfig) >>"$odir/prep.log" 2>&1

    stree="$odir/srctree"
    [ -d "$stree" ] || cp -a --reflink=auto "$SRC" "$stree"
    cp "$odir/.config" "$stree/.config"
    make -C "$stree" CC=gcc LD=ld.bfd olddefconfig >>"$odir/prep.log" 2>&1
    STREES+=("$stree")
    echo "  prepared: $name"
done

# --- phase 2: generate a Makefile wrapper and run everything together
# through one shared jobserver ---
MK="$OUT/.batch-$$.mk"
{
    echo "all: $(for n in "${NAMES[@]}"; do echo -n " build-$n"; done)"
    for i in "${!NAMES[@]}"; do
        name="${NAMES[$i]}"
        stree="${STREES[$i]}"
        printf 'build-%s:\n' "$name"
        printf '\t$(MAKE) -C %q CC=%q LD=%q bzImage\n' "$stree" "$CC" "$LD"
        printf '.PHONY: build-%s\n' "$name"
    done
} > "$MK"

echo "=== starting the shared build (make -j$JOBS) ==="
t0=$(date +%s)
make -j"$JOBS" -f "$MK" all
rc=$?
t1=$(date +%s)
echo "=== finished in $((t1-t0))s (rc=$rc) ==="

echo "=== per-target result ==="
for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    bz="${STREES[$i]}/arch/x86/boot/bzImage"
    if [ -f "$bz" ]; then
        echo "  [OK] $name -> $bz"
    else
        echo "  [FAIL] $name — no bzImage, check $OUT/$name/srctree or prep.log"
    fi
done
rm -f "$MK"
