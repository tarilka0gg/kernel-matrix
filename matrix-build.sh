#!/bin/bash
# matrix-build.sh — sweeps every combination of cpu × gpu × platform × ec × modem
# (or one specific --target), without manually calling build-config.sh
# for each one separately. Parallelized via xargs -P (--worker — an internal
# mode for a single combo, invoked by the script calling itself again).
#
# MODES:
#   matrix-build.sh SRC OUT                        configs for ALL combinations
#   matrix-build.sh SRC OUT --build --yes           same, plus an actual compile
#   matrix-build.sh SRC OUT --target NAME [--build] just one target manifest
#   matrix-build.sh SRC OUT --parallel N            how many combos in parallel
#
# HOW THIS WORKS (and why not make O=...):
#   SRC in this project is usually already built in-tree (trim10/11 etc) —
#   kbuild in that state REFUSES O= builds ("source tree is not
#   clean, please run make mrproper"), and mrproper would destroy the
#   already-working kernel. So:
#     - config generation (without --build) goes directly through
#       scripts/kconfig/conf --olddefconfig with KCONFIG_CONFIG=<target
#       .config> — this does NOT touch SRC/.config and needs no O= at all.
#     - --build makes a hardlinked copy of SRC for each combination
#       (cp -al — unchanged shared files don't take up space twice,
#       the compile of the new .o set goes into the private copy, SRC
#       is never touched).
#   modules_install under --build goes to OUT/<combo>/srctree/modules_root,
#   never to /usr/lib/modules. make install is NEVER called here.
#
# PARALLELISM AND CACHING:
#   --parallel N — how many combos to process at once (xargs -P).
#     Default: without --build = nproc (conf is a light single-threaded
#     tool, no reason not to load every core at once); with --build = 2,
#     since each combo itself loads make -j internally (--jobs is split
#     across the parallel combos so together they don't exceed nproc).
#   CC — if sccache/ccache is on PATH, the compiler is automatically wrapped
#     with it (sccache gcc / ccache gcc). The cache is shared across ALL
#     combos — CFLAGS (hence -march/AVX/SIMD level from the cpu/ fragment)
#     is part of sccache/ccache's own cache key, so different -march values
#     NEVER mix with each other, while identical .c files between
#     "neighboring" combos (e.g. the same cpu, only modem differs) get
#     reused from cache instead of recompiling.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_cc(){
    if [ -n "${CC:-}" ]; then echo "$CC"; return; fi
    if command -v sccache >/dev/null 2>&1; then echo "sccache gcc"; return; fi
    if command -v ccache  >/dev/null 2>&1; then echo "ccache gcc"; return; fi
    echo "gcc"
}
detect_clang(){
    # Fallback compiler for --build: GCC 15.2.1 has a confirmed bug
    # (not specific to our overlay) — it doesn't emit ENDBR64 for a few
    # library functions (ZSTD_isError, HUF_readStats, xor_gen_Nregs, ...)
    # that are called through function-pointer tables, while objtool under
    # CONFIG_X86_KERNEL_IBT=y treats that as a fatal error (Error 255,
    # regardless of OBJTOOL_WERROR). Reproduced deterministically on
    # pop-147-intel-raptorlake-none-desktop-lenovo-none: gcc fails
    # reliably (with lld, with bfd, and without sccache), clang 22 builds clean.
    if command -v clang >/dev/null 2>&1; then command -v clang; return; fi
    for p in /usr/lib/llvm/*/bin/clang; do
        [ -x "$p" ] && { echo "$p"; return; }
    done
    return 1
}
detect_ld(){
    # sccache caches the compile step, not the link. mold does NOT work here:
    # the kernel's scripts/ld-version.sh only recognizes the first tokens
    # "GNU ld"/"LLD" in --version output; mold's ("mold X.Y.Z (compatible
    # with GNU ld)") doesn't match and hits "unknown linker" on EVERY
    # internal syncconfig, not just an explicit olddefconfig. lld is
    # officially recognized by the kernel and is also noticeably faster than bfd.
    if [ -n "${LD:-}" ]; then echo "$LD"; return; fi
    if command -v ld.lld >/dev/null 2>&1; then echo "ld.lld"; return; fi
    for p in /usr/lib/llvm/*/bin/ld.lld; do
        [ -x "$p" ] && { echo "$p"; return; }
    done
    echo "ld.bfd"
}

# --- internal mode: a single combination, invoked via xargs -P ---
if [ "${1:-}" = "--worker" ]; then
    shift
    SRC="$1"; OUT="$2"; BUILD="$3"; JOBS="$4"; CC="$5"; LD="$6"; SEED="$7"; name="$8"
    shift 8
    frags=("$@")

    odir="$OUT/$name"
    mkdir -p "$odir"
    cp "$SEED" "$odir/.config"

    abs_frags=("$HERE"/common/*.config)
    for f in "${frags[@]}"; do abs_frags+=("$HERE/$f.config"); done

    log="$odir/build.log"
    : > "$log"
    echo "=== $name ===" >> "$log"

    REPORT="$OUT/matrix-report.tsv"
    if ! "$SRC/scripts/kconfig/merge_config.sh" -O "$odir" -m "$odir/.config" "${abs_frags[@]}" >>"$log" 2>&1; then
        echo -e "$name\tFAIL_MERGE\t-" >> "$REPORT"
        echo "[FAIL_MERGE] $name — $log" >&2
        exit 0
    fi
    # Kconfig.include (ld-version.sh) doesn't recognize mold's version string —
    # for config RESOLUTION itself it's always ld.bfd, mold is only used for
    # the actual link below (those checks aren't involved there).
    if ! (cd "$SRC" && KCONFIG_CONFIG="$odir/.config" srctree=. ARCH=x86_64 SRCARCH=x86 \
            CC="$CC" HOSTCC="$CC" LD=ld.bfd \
            ./scripts/kconfig/conf --olddefconfig Kconfig) >>"$log" 2>&1
    then
        echo -e "$name\tFAIL_OLDDEFCONFIG\t-" >> "$REPORT"
        echo "[FAIL_OLDDEFCONFIG] $name — $log" >&2
        exit 0
    fi
    cfg_status=OK
    grep -qi 'redefined' "$log" && cfg_status=OK_WARN

    if [ "$BUILD" -eq 1 ]; then
        stree="$odir/srctree"
        if [ ! -d "$stree" ]; then
            echo "hardlinked tree copy -> $stree" >> "$log"
            cp -a --reflink=auto "$SRC" "$stree"
        fi
        cp "$odir/.config" "$stree/.config"
        mkdir -p "$stree/modules_root"
        # The real bottleneck turned out NOT to be modules_install, but the
        # fact that a plain `make -j` (the "all" target) links EACH of the
        # thousands of =m modules separately (CC [M] .../*.mod.o) — this
        # isn't cached by sccache (it's a link, not a compile) and takes
        # longer than the compile itself. Since the modules aren't installed
        # anywhere anyway (SKIP_MODULES=1, --skip-modules), we ask kbuild for
        # ONLY bzImage, so the modules never get compiled or linked at all
        # (not just not installed).
        if [ "${SKIP_MODULES:-0}" = "1" ]; then
            BUILD_TARGET=bzImage
        else
            BUILD_TARGET=
        fi
        mi_with(){ # $1 = compiler to use for modules_install
            [ "${SKIP_MODULES:-0}" = "1" ] && return 0
            make -C "$stree" CC="$1" LD="$LD" INSTALL_MOD_PATH="$stree/modules_root" modules_install
        }
        # For combos with nvidia (the proprietary x11-drivers/nvidia-drivers
        # builds its .ko outside the kernel tree, via /usr/src/linux ->
        # the usual "linux-headers" set), generate <name>-devel.tar.xz —
        # NOT the full tree, only what's needed for `make -C
        # /path/to/devel M=... modules`: .config, Module.symvers,
        # headers, scripts/ (the kbuild machinery), no kernel .c/.o files.
        gen_devel_tar(){ # $1 = the compiler to run modules_prepare with
            case " ${frags[*]} " in *" gpu/nvidia "*) ;; *) return 0 ;; esac
            # `modules_prepare` on its own does NOT generate Module.symvers -- that file
            # is filled in by modpost, which only runs during `make modules`
            # (a full pass over every =m target). When SKIP_MODULES=1, the main build
            # above asks only for bzImage and modpost never runs for the modules at
            # all -- live-tested: the result was a .tar.xz with no Module.symvers
            # inside it at all, and nvidia-drivers' linux-mod-r1.eclass immediately refuses
            # ("built kernel sources are required to build kernel modules") on seeing
            # it missing. `make modules` here covers modules_prepare as its own
            # prerequisite and additionally actually generates a full Module.symvers; if
            # SKIP_MODULES=0 and the modules were already built above, this command is a fast
            # no-op (nothing to recompile).
            make -C "$stree" CC="$1" LD="$LD" -j"$JOBS" modules >>"$log" 2>&1 || return 0
            local dtar="$odir/${name}-devel.tar"
            local keep=()
            for p in .config Makefile Module.symvers Kconfig \
                     scripts include arch/x86/include arch/x86/Makefile arch/x86/Kbuild \
                     tools/objtool/objtool certs; do
                [ -e "$stree/$p" ] && keep+=("$p")
            done
            tar -C "$stree" -cf "$dtar" "${keep[@]}" 2>>"$log" \
                && xz -f "$dtar" && echo "[DEVEL] $name -> $(basename "$dtar").xz" >&2
        }
        if make -C "$stree" CC="$CC" LD=ld.bfd olddefconfig >>"$log" 2>&1 \
           && make -C "$stree" CC="$CC" LD="$LD" -j"$JOBS" $BUILD_TARGET >>"$log" 2>&1 \
           && mi_with "$CC" >>"$log" 2>&1
        then
            gen_devel_tar "$CC"
            echo -e "$name\t$cfg_status\tOK" >> "$REPORT"
        elif CLANG="$(detect_clang)" && {
                echo "=== gcc failed, trying the clang fallback ($CLANG) ===" >>"$log"
                make -C "$stree" CC="$CLANG" LD="$LD" -j"$JOBS" $BUILD_TARGET >>"$log" 2>&1 \
                && mi_with "$CLANG" >>"$log" 2>&1
             }
        then
            gen_devel_tar "$CLANG"
            echo -e "$name\t${cfg_status}_CLANG\tOK" >> "$REPORT"
            echo "[OK via clang fallback] $name" >&2
        else
            echo -e "$name\t$cfg_status\tFAIL_BUILD" >> "$REPORT"
            echo "[FAIL_BUILD] $name (gcc and clang) — $log" >&2
        fi
    else
        echo -e "$name\t$cfg_status\t-" >> "$REPORT"
    fi
    echo "[$cfg_status] $name"
    exit 0
fi

SRC="${1:?path to the kernel tree}"; shift
# Resolve the symlink right here: SRC is often passed as /usr/src/linux
# (a symlink to a specific version) -- `cp -a` on a symlink source (below,
# when creating stree) copies the symlink itself, not the tree it points
# to (live-tested: a combo's stree ended up as a broken symlink to a
# relative path that didn't exist under OUT, instead of a real hardlinked
# copy, and any subsequent build of that combo simply had nowhere to
# get .config/Module.symvers from). Resolve it once here -- every later
# use of $SRC stays a real absolute path.
SRC="$(readlink -f "$SRC")"
OUT="${1:?output directory for all builds}"; shift

BUILD=0
YES=0
TARGET=""
JOBS=""
PARALLEL=""
SEED=""
SKIP_MODULES="${SKIP_MODULES:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --build) BUILD=1 ;;
        --yes) YES=1 ;;
        --target) TARGET="$2"; shift ;;
        --jobs) JOBS="$2"; shift ;;
        --parallel) PARALLEL="$2"; shift ;;
        --seed) SEED="$2"; shift ;;
        --skip-modules) SKIP_MODULES=1 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

CC="$(detect_cc)"
LD="$(detect_ld)"
NPROC="$(nproc)"
if [ "$BUILD" -eq 1 ]; then
    [ -n "$PARALLEL" ] || PARALLEL=2
    [ -n "$JOBS" ] || JOBS=$(( NPROC / PARALLEL )); [ "$JOBS" -ge 1 ] || JOBS=1
    # sccache's default (10G) is too small — for 6 CPU targets the full
    # object-file set for each one is tens of GB, and without headroom the
    # cache is constantly evicted and gives almost no benefit across cpu groups.
    export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-80G}"
fi
# without --build: conf is light and single-threaded, default = nproc (as documented above)
[ -n "$PARALLEL" ] || PARALLEL="$NPROC"

echo "=== CC='$CC'  LD='$LD'  --parallel=$PARALLEL  --jobs(per combo)=$JOBS  SCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE:-(not set without --build)} ==="

[ -f "$SRC/scripts/kconfig/conf" ] || { echo "scripts/kconfig/conf not found in $SRC (has olddefconfig been run at least once?)" >&2; exit 1; }
if [ -z "$SEED" ]; then
    if [ -f "$HERE/seed/default.config" ]; then
        SEED="$HERE/seed/default.config"
    else
        SEED="$SRC/.config"
        echo "WARNING: seed/default.config is missing — the seed is taken from $SRC/.config (depends on the tree's state!)" >&2
    fi
fi
echo "=== SEED='$SEED' ==="
[ -f "$SEED" ] || { echo "no seed .config: $SEED (pass --seed or run 'make defconfig' in $SRC)" >&2; exit 1; }

mkdir -p "$OUT"
REPORT="$OUT/matrix-report.tsv"
echo -e "combo\tconfig\tbuild" > "$REPORT"

SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
export SELF SRC OUT BUILD JOBS CC LD SEED SKIP_MODULES
export TAB=$'\t'

dispatch(){
    # reads tasks from stdin (one combo per line: name<TAB>frag1 frag2 ...)
    # and drives them through xargs -P into --worker. All parameters go
    # through export (not text interpolation into the -c string) — simpler and safer.
    xargs -d '\n' -P "$PARALLEL" -I{} bash -c '
        line="$1"
        name="${line%%$TAB*}"
        frags="${line#*$TAB}"
        "$SELF" --worker "$SRC" "$OUT" "$BUILD" "$JOBS" "$CC" "$LD" "$SEED" "$name" $frags
    ' _ {}
}

if [ -n "$TARGET" ]; then
    TF="$HERE/targets/$TARGET.target"
    [ -f "$TF" ] || { echo "no such target: $TF" >&2; exit 1; }
    mapfile -t frags < <(grep -v '^\s*#' "$TF" | grep -v '^\s*$')
    echo "=== target '$TARGET': ${frags[*]} ==="
    printf '%s\t%s\n' "$TARGET" "${frags[*]}" | dispatch
    echo
    column -t -s $'\t' "$REPORT"
    exit 0
fi

axis(){ local d="$HERE/$1"; for f in "$d"/*.config; do basename "$f" .config; done; }
mapfile -t CPUS    < <(axis cpu)
mapfile -t GPUS    < <(axis gpu)
mapfile -t PLATS   < <(axis platform | grep -vE '^(victus16-r1xxx)$')   # specific models — only via --target
mapfile -t ECS     < <(axis ec)
mapfile -t MODEMS  < <(axis modem)

TOTAL=$(( ${#CPUS[@]} * ${#GPUS[@]} * ${#PLATS[@]} * ${#ECS[@]} * ${#MODEMS[@]} ))
echo "=== sweep axes ==="
echo "cpu:      ${CPUS[*]}"
echo "gpu:      ${GPUS[*]}"
echo "platform: ${PLATS[*]}   (form factor: desktop/laptop/server/handheld)"
echo "ec:       ${ECS[*]}   (vendor embedded-controller/WMI driver)"
echo "modem:    ${MODEMS[*]}"
echo "total combinations: $TOTAL, parallel: $PARALLEL"

if [ "$BUILD" -eq 1 ] && [ "$TOTAL" -gt 6 ] && [ "$YES" -ne 1 ]; then
    echo "A FULL BUILD of $TOTAL combinations will take hours/days (and disk space). Add --yes if that's intentional." >&2
    exit 1
fi

{
for cpu in "${CPUS[@]}"; do
  for gpu in "${GPUS[@]}"; do
    for plat in "${PLATS[@]}"; do
      for ec in "${ECS[@]}"; do
        for modem in "${MODEMS[@]}"; do
          name="${cpu}__${gpu}__${plat}__${ec}__${modem}"
          printf '%s\t%s\n' "$name" "cpu/$cpu gpu/$gpu platform/$plat ec/$ec modem/$modem"
        done
      done
    done
  done
done
} | dispatch

echo
echo "=== report: $REPORT ==="
column -t -s $'\t' "$REPORT"
