#!/usr/bin/env python3
# gen-popular-targets.py — generates up to N of the most popular (by real
# hardware prevalence) combinations from the cpu×gpu×platform matrix, writes
# each one as kernel-configs/targets/pop-XXX-<id>.target (compatible with
# matrix-build.sh --target) plus a description, and priority-list.tsv —
# an ordered list for build-popular.sh.
#
# EC (vendor WMI/EC) and MODEM are NOT axes of the matrix: all of their
# fragments (kernel-configs/ec/*.config, modem/*.config) only set
# CONFIG_*=m (modules), and --skip-modules in matrix-build.sh doesn't
# build modules at all — meaning they don't affect the bzImage, and
# 10 EC × 3 modem variants produced 30x literally IDENTICAL vmlinux
# files for every cpu/gpu/platform. Instead every combo always includes
# ec/all.config + modem/all.config (every vendor at once, as modules) —
# hardware support isn't lost, it just doesn't multiply the matrix.
import itertools, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGETS_DIR = os.path.join(HERE, "targets")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 147

CPU = {
    "intel-raptorlake":  (10, "Intel Core 12-14 gen (Raptor/Raptor Refresh Lake)"),
    "amd-znver4":        (9,  "AMD Ryzen 7000/8000 (Zen 4)"),
    "intel-alderlake":   (7,  "Intel Core 12 gen (Alder Lake)"),
    "amd-znver3":        (6,  "AMD Ryzen 5000 (Zen 3)"),
    "intel-skylake":     (6,  "Intel Core 6-10 gen (Skylake/Kaby/Coffee/Comet Lake)"),
    "amd-znver2":        (5,  "AMD Ryzen 3000/4000 (Zen 2)"),
    "intel-meteorlake":  (5,  "Intel Core Ultra 1 (Meteor Lake)"),
    "intel-icelake":     (4,  "Intel Core 10 gen mobile (Ice Lake)"),
    "amd-znver5":        (4,  "AMD Ryzen 9000 (Zen 5)"),
    "intel-rocketlake":  (4,  "Intel Core 11 gen desktop (Rocket Lake)"),
    "intel-arrowlake":   (4,  "Intel Core Ultra 2 (Arrow Lake)"),
    "amd-znver1":        (3,  "AMD Ryzen 1000/2000 (Zen 1)"),
    "intel-haswell":     (3,  "Intel Core 4-5 gen (Haswell/Broadwell)"),
    "intel-ivybridge":   (2,  "Intel Core 3 gen (Ivy Bridge)"),
    "intel-sandybridge": (2,  "Intel Core 2 gen (Sandy Bridge)"),
    "amd-bdver4":        (2,  "AMD Excavator/Bulldozer line (bdver4, A-series/FX)"),
    "amd-btver2":        (1,  "AMD Jaguar (btver2, low-voltage APUs)"),
    "generic-x86-64-v3": (4,  "any x86-64-v3 CPU (safe fallback)"),
    "generic-x86-64-v2": (2,  "any x86-64-v2 CPU (broad compatibility)"),
}
GPU = {
    "intel":         (9, "integrated Intel (i915)"),
    "nvidia":        (8, "discrete NVIDIA (proprietary driver)"),
    "amd":           (8, "AMD (iGPU/APU or discrete, amdgpu)"),
    "none":          (3, "no separate GPU driver"),
    "xe":            (2, "Intel Arc/Battlemage+ (new Xe driver)"),
    "nouveau":       (2, "discrete NVIDIA (open nouveau driver)"),
    "radeon-legacy": (1, "older AMD/ATI cards pre-GCN (radeon)"),
}
PLATFORM = {
    # server dropped — not this distro's target audience
    "laptop":  (10, "laptop"),
    "desktop": (8,  "desktop"),
    "handheld":(2,  "handheld"),
}
def valid(cpu, gpu, plat):
    if plat == "handheld" and gpu not in ("amd", "none"):
        return False
    return True

rows = []
for cpu, gpu, plat in itertools.product(CPU, GPU, PLATFORM):
    if not valid(cpu, gpu, plat):
        continue
    score = (CPU[cpu][0] * GPU[gpu][0] * PLATFORM[plat][0])
    rows.append((score, cpu, gpu, plat))

rows.sort(key=lambda r: -r[0])
rows = rows[:N]

os.makedirs(TARGETS_DIR, exist_ok=True)
index_path = os.path.join(HERE, "popular-priority.tsv")
with open(index_path, "w") as idx:
    idx.write("rank\tname\tscore\tdescription\n")
    for i, (score, cpu, gpu, plat) in enumerate(rows, 1):
        name = f"pop-{i:03d}-{cpu}-{gpu}-{plat}"
        desc = (f"{PLATFORM[plat][1].capitalize()} on {CPU[cpu][1]}, "
                f"{GPU[gpu][1]} (all vendor EC/WMI and modem "
                f"drivers included as modules).")
        tpath = os.path.join(TARGETS_DIR, name + ".target")
        with open(tpath, "w") as f:
            f.write(f"# {desc}\n")
            f.write(f"# score={score} (popularity priority within top-{N})\n")
            f.write(f"cpu/{cpu}\n")
            f.write(f"gpu/{gpu}\n")
            f.write(f"platform/{plat}\n")
            f.write(f"ec/all\n")
            f.write(f"modem/all\n")
        idx.write(f"{i}\t{name}\t{score}\t{desc}\n")

print(f"generated {len(rows)} target manifests in {TARGETS_DIR}")
print(f"priority list: {index_path}")
