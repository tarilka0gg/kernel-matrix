#!/bin/bash
# verify-fragments.sh <SRC> [--seed FILE] (--target NAME | <frag> <frag> ...)
#   frag = cpu/intel-raptorlake gpu/nvidia platform/laptop ec/hp modem/none (no .config)
#
# Why this exists: `merge_config.sh -m` + `olddefconfig` SILENTLY drop options with
# unsatisfiable dependencies (a disabled gate vendor, a missing select...).
# The script merges fragments the same way matrix-build.sh does, and compares what
# was REQUESTED against what ACTUALLY landed:
#   DEAD         =y/=m was requested, ended up n/absent  -> error (exit 1)
#   DOWNGRADED   =y was requested, =m came out            -> warning
#   RESURRECTED  "is not set" was requested, y/m came out -> info (pulled in by another option's select)
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(readlink -f "${1:?SRC}")"; shift
SEED=""; TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --seed) SEED="$2"; shift ;;
        --target) TARGET="$2"; shift ;;
        *) break ;;
    esac
    shift
done
[ -n "$SEED" ] || SEED="$HERE/seed/default.config"
[ -f "$SEED" ] || SEED="$SRC/.config"
if [ -n "$TARGET" ]; then
    mapfile -t frags < <(grep -v '^\s*#' "$HERE/targets/$TARGET.target" | grep -v '^\s*$')
else
    frags=("$@")
fi
abs=("$HERE"/common/*.config)
for f in "${frags[@]}"; do abs+=("$HERE/$f.config"); done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp "$SEED" "$tmp/.config"
"$SRC/scripts/kconfig/merge_config.sh" -O "$tmp" -m "$tmp/.config" "${abs[@]}" >/dev/null 2>&1
(cd "$SRC" && KCONFIG_CONFIG="$tmp/.config" srctree=. ARCH=x86_64 SRCARCH=x86 \
    CC=gcc HOSTCC=gcc LD=ld.bfd ./scripts/kconfig/conf --olddefconfig Kconfig) >/dev/null 2>&1

awk '/^CONFIG_[A-Za-z0-9_]+=/ {i=index($0,"="); r[substr($0,1,i-1)]=substr($0,i+1)}
     /^# CONFIG_[A-Za-z0-9_]+ is not set/ {r[$2]="n"}
     END {for (k in r) print k "\t" r[k]}' "${abs[@]}" | sort > "$tmp/req.tsv"
awk '/^CONFIG_[A-Za-z0-9_]+=/ {i=index($0,"="); f[substr($0,1,i-1)]=substr($0,i+1)}
     /^# CONFIG_[A-Za-z0-9_]+ is not set/ {f[$2]="n"}
     END {for (k in f) print k "\t" f[k]}' "$tmp/.config" | sort > "$tmp/fin.tsv"

# Dead by design: on desktop/server ACPI_BATTERY/SUSPEND is off, so the laptop
# vendor EC drivers (ec/*.config) and AMD_PMC are unreachable there — not an error.
skip="$tmp/skip.txt"; : > "$skip"
for f in "${frags[@]}"; do
    case "$f" in platform/desktop|platform/server)
        cat "$HERE"/ec/*.config | grep -oE '^CONFIG_[A-Za-z0-9_]+' >> "$skip"
        printf 'CONFIG_AMD_PMC\nCONFIG_AMD_PMF\n' >> "$skip" ;;
    esac
done
dead=0; down=0; res=0; skipped=0
while IFS=$'\t' read -r k want; do
    got="$(awk -F'\t' -v k="$k" '$1==k{print $2; exit}' "$tmp/fin.tsv")"; got="${got:-absent}"
    case "$want" in
        y|m)
            if [ "$got" = "n" ] || [ "$got" = "absent" ]; then
                if grep -qx "$k" "$skip"; then skipped=$((skipped+1)); else echo "DEAD         $k  requested=$want  got=$got"; dead=$((dead+1)); fi
            elif [ "$want" = "y" ] && [ "$got" = "m" ]; then echo "DOWNGRADED   $k  requested=y  got=m"; down=$((down+1)); fi ;;
        n)
            if [ "$got" = "y" ] || [ "$got" = "m" ]; then echo "RESURRECTED  $k  requested=n  got=$got"; res=$((res+1)); fi ;;
    esac
done < "$tmp/req.tsv"
echo "--- ${TARGET:-${frags[*]}}: requested $(wc -l < "$tmp/req.tsv"), DEAD=$dead DOWNGRADED=$down RESURRECTED=$res SKIPPED_BY_DESIGN=$skipped (seed: $(basename "$SEED"))"
[ "$dead" -eq 0 ]
