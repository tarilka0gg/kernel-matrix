# kernel-matrix

A matrix of Linux kernel configs for popular hardware combinations: **CPU × GPU × platform × embedded controller (EC) × modem**. I use it to build kernels not just for my own laptop (HP Victus 16-r1xxx) but for "other people's" hardware too: one combination's config is a merge of small fragments on top of a shared seed.

The project grew out of my own Gentoo distro: I needed a ready-made `vmlinuz` (and a devel set for nvidia where needed) for every common hardware configuration, without hand-tuning each one. The fragment values are tuned for my own builds (Gentoo, CachyOS kernel 7.1.x), so treat them as a starting point, not a drop-in recipe.

## Contents

1. [How a config is assembled](#1-how-a-config-is-assembled)
2. [Matrix dimensions](#2-matrix-dimensions)
3. [Targets (`targets/`) and the popularity ranking](#3-targets-targets-and-the-popularity-ranking)
4. [Scripts and examples](#4-scripts-and-examples)
5. [How the build works](#5-how-the-build-works)
6. [Seed and shared fragments](#6-seed-and-shared-fragments)
7. [verify-fragments.sh: why it's needed](#7-verify-fragmentssh-why-its-needed)
8. [Kconfig pitfalls](#8-kconfig-pitfalls)
9. [What's been built and verified](#9-whats-been-built-and-verified)
10. [Repository layout](#10-repository-layout)
11. [License](#11-license)

---

## 1. How a config is assembled

For one combination (e.g. `cpu/intel-raptorlake gpu/nvidia platform/laptop ec/hp modem/none`), the order is:

```
seed/default.config
  └─ common/base.config, common/hardware.config     (always)
       └─ cpu/<X>.config
            └─ gpu/<X>.config
                 └─ platform/<X>.config
                      └─ ec/<X>.config
                           └─ modem/<X>.config
```

The merge is done by `scripts/kconfig/merge_config.sh -m` from the kernel tree, then `scripts/kconfig/conf --olddefconfig` resolves dependencies. **Later fragments override earlier ones**, so order matters (e.g. `cpu/intel-raptorlake` disables `X86_NATIVE_CPU`, which the seed enables).

An important property: generating a config **never touches `SRC/.config`** and doesn't need `make O=…`. The scripts call `conf` directly with `KCONFIG_CONFIG=<target .config>`, so an already-built kernel tree stays untouched.

## 2. Matrix dimensions

| Dimension | Count | Fragments (`<dimension>/*.config`) |
|---|---|---|
| **cpu** | 19 | `intel-sandybridge`, `intel-ivybridge`, `intel-haswell`, `intel-skylake`, `intel-icelake`, `intel-rocketlake`, `intel-alderlake`, `intel-raptorlake`, `intel-meteorlake`, `intel-arrowlake`, `amd-btver2`, `amd-bdver4`, `amd-znver1`…`amd-znver5`, `generic-x86-64-v2`, `generic-x86-64-v3` |
| **gpu** | 7 | `intel` (i915), `xe` (Intel Arc/Battlemage), `nvidia` (proprietary driver), `nouveau`, `amd` (amdgpu), `radeon-legacy`, `none` |
| **platform** | 5 | `laptop`, `desktop`, `handheld`, `server`, `victus16-r1xxx` (a specific model) |
| **ec** | 11 | `acer`, `asus`, `dell`, `hp`, `lenovo`, `msi`, `samsung`, `system76`, `toshiba`, `all` (all at once), `none` |
| **modem** | 4 | `mhi-soc`, `usb-wwan-generic`, `all`, `none` |

The full Cartesian product with no filters (platform minus `victus16-r1xxx`, which is only reached via `--target`) gives 19 × 7 × 4 × 11 × 4 = **23,408** combinations. Only a fraction is actually built: see section 3.

**What each dimension enables:**

- `cpu/*`: instruction-set level and micro-architecture tuning (`X86_64_VERSION`, `MZEN4`, etc). For Intel Raptor/Alder Lake: `GENERIC_CPU=y`, `X86_64_VERSION=3`, `X86_NATIVE_CPU` disabled; AMD-specific bits (`PINCTRL_AMD`, PSP, IOMMU, PMF) live in `cpu/amd-*` and in `cpu/generic-x86-64-*` (needed there too, since the generic kernel must also run on AMD).
- `gpu/*`: the DRM driver for the given vendor. For hybrid (Optimus) laptops, `gpu/nvidia` and `gpu/nouveau` also include the iGPU drivers, since the panel is usually wired to the integrated GPU.
- `platform/*`: form factor (`laptop`: `ACPI_BATTERY`, `ACPI_AC`, backlight; `desktop`, `server`, `handheld`). `platform/victus16-r1xxx.config` is an example of a "specific model" layer on top of the rest.
- `ec/*`: vendor laptop drivers (`HP_WMI`, `ACPI_WMI`, the `X86_PLATFORM_DRIVERS_HP` gate option, etc), almost all as modules.
- `modem/*`: WWAN and modem drivers (enables the `WWAN` gate option).

## 3. Targets (`targets/`) and the popularity ranking

A target (`targets/<name>.target`) is a list of fragments, one per line, with comments on top:

```
# Laptop on Intel Core 11 gen desktop (Rocket Lake), no separate GPU driver (...).
# score=120 (popularity priority within top-999999)
cpu/intel-rocketlake
gpu/none
platform/laptop
ec/all
modem/all
```

`targets/` holds **7,614** files from two generations:

| Generation | Count | What it is |
|---|---|---|
| compact targets | 678 | `ec/all` + `modem/all` (every vendor at once, as modules); this is what `gen-popular-targets.py` produces |
| expanded targets | 6,936 | a specific EC × a specific modem in the name (`…-lenovo-none.target`); an older split that produced identical `vmlinux` files |

Why EC and modem were later dropped as axes: their fragments only set `CONFIG_*=m` (modules), and a `bzImage` build doesn't depend on modules at all. Dozens of EC × modem variants produced literally identical `vmlinux` for every cpu/gpu/platform pair. Now every target simply turns on `ec/all` and `modem/all`: hardware support isn't lost, the matrix just isn't multiplied by it.

**Popularity ranking** (`popular-priority.tsv`, 304 rows: `rank`, `name`, `score`, `description`). `gen-popular-targets.py` computes

```
score = weight(cpu) × weight(gpu) × weight(platform)
```

where the weights are set by hand in the script itself (example: Intel Raptor Lake = 10, Zen 4 = 9, Alder Lake = 7; GPU: Intel = 9, NVIDIA = 8, AMD = 8, none = 3; platform: laptop = 10, desktop = 8, handheld = 2). Combinations are sorted by `score`, and the top `N` are taken (147 by default, 304 in the current list). There's one validity rule: handheld only pairs with GPU `amd` or `none`. `server` is dropped from the generator as out of scope, though the fragment itself remains.

The weights are set by hand in the script; no source for the numbers is given in the repo, so treat this as a rough guide, not measured market data.

## 4. Scripts and examples

| Script | Purpose |
|---|---|
| `matrix-build.sh` | generates configs for every combination or a single target (`--target`), optionally builds (`--build`) |
| `build-config.sh` | generate a `.config` for a given set of fragments with no target |
| `build-popular.sh` | batch build from `popular-priority.tsv` with a time budget |
| `build-batch-jobserver.sh` | builds several targets at once through one GNU Make jobserver |
| `gen-popular-targets.py` | generates `targets/pop-*.target` and `popular-priority.tsv` |
| `verify-fragments.sh` | checks requested options against the actual result |

```bash
# 1. Configs only for one target (nothing gets compiled)
./matrix-build.sh /usr/src/linux /var/tmp/out --target pop-001-intel-raptorlake-intel-laptop

# 2. Same, plus a bzImage build with no modules (the fastest way to get a vmlinuz)
./matrix-build.sh /usr/src/linux /var/tmp/out --target pop-001-intel-raptorlake-intel-laptop --build --skip-modules

# 3. Configs for the whole matrix (a huge number of files, no compilation)
./matrix-build.sh /usr/src/linux /var/tmp/out --parallel 24

# 4. Batch build of popular targets: SRC OUT RELEASES [time_budget_s=10800] [batch_size=4]
./build-popular.sh /usr/src/linux /var/tmp/out ~/kernel-releases 10800 4

# 5. One config for specific hardware
./build-config.sh /usr/src/linux cpu/intel-raptorlake gpu/nvidia platform/laptop platform/victus16-r1xxx

# 6. Verify fragments
./verify-fragments.sh /usr/src/linux --target pop-001-intel-raptorlake-intel-laptop
```

Key `matrix-build.sh` options: `--build` (actually compile), `--yes` (confirm a large build, when there are more than 6 combinations), `--target NAME`, `--parallel N`, `--jobs N`, `--seed FILE`, `--skip-modules`. The kernel tree needs to have been configured at least once: `scripts/kconfig/conf` must exist.

## 5. How the build works

- **No `make O=…`.** The kernel tree is usually already built in-tree; kbuild then refuses `O=` builds ("source tree is not clean"), and `make mrproper` would destroy the working kernel. So `--build` makes a hardlinked copy of the tree (`cp -a --reflink=auto`) for each combination, and compiles into that private copy. The original tree is never touched.
- **`bzImage` only.** With `--skip-modules`, the build asks kbuild for `bzImage` only. Reason: a normal `make` links each of the thousands of `=m` modules separately; sccache doesn't cache that step (it's a link, not a compile), and it takes longer than the compile itself. `make install` is never called here; `modules_install` (without `--skip-modules`) goes to `OUT/<combo>/srctree/modules_root`, not `/usr/lib/modules`.
- **Compiler cache.** If `sccache` or `ccache` is on `PATH`, the compiler is wrapped with it. The cache is shared across all combinations; `-march` is part of the cache key, so different micro-architectures don't mix, while "neighboring" combinations (same cpu, different modem) reuse the cache. `--build` sets `SCCACHE_CACHE_SIZE=80G`, since the typical 10G gets evicted fast.
- **Linker.** The script picks `ld.lld`, falling back to `ld.bfd`. `mold` doesn't work: the kernel's `scripts/ld-version.sh` only recognizes "GNU ld" and "LLD" and fails on every `syncconfig` with `mold`.
- **Compiler and a GCC bug.** GCC 15.2.1 (from the overlay I use) doesn't emit `ENDBR64` for a few library functions (`ZSTD_isError`, `HUF_readStats`, `xor_gen_Nregs`, and others) that are called through function-pointer tables. `objtool`, with `CONFIG_X86_KERNEL_IBT=y`, treats this as a fatal error (Error 255). Reproduced deterministically on `pop-147-intel-raptorlake-none-desktop`: GCC fails every time, clang 22 builds clean. So `--build` falls back to clang.
- **Batch builds via jobserver.** `build-batch-jobserver.sh` builds several targets at once under one GNU Make jobserver (`-j24`). While one target is linking (single-threaded), it holds one token and gives the rest to the others. Measured: one target alone ≈ 54 s; two as separate processes ≈ 80 s (worse, oversubscribed); through the jobserver: 2 → 46 s, 4 → 38 s, 6 → 14 s per target.
- **Resilience.** `build-popular.sh` doesn't stop on failures: a failed target is retried separately in the background with a low `--jobs`, without blocking the next batch. The time budget is checked **before** each new batch and never interrupts one already in progress. Every successful build is copied out as `RELEASES/<rank>_<name>.vmlinuz` + `.txt` (hardware description, `kernelrelease`), and `srctree` is deleted right away to save space. Results are written to `status.tsv` and `build-popular.log`.
- **NVIDIA.** For targets with `gpu/nvidia`, a `<name>-devel.tar.xz` is also created: not the full tree, just the minimum needed for `make -C … M=… modules` (`.config`, `Module.symvers`, headers, `scripts/`, `objtool`). Without it, Gentoo's `nvidia-drivers` won't build against this kernel. `Module.symvers` is only populated by `make modules`, so the devel archive always runs it, even with `--skip-modules`.

## 6. Seed and shared fragments

- **`seed/default.config`**: my `trim11` config (kernel 7.1.6, `CONFIG_LOCALVERSION="-tuned"`, `SCHED_BORE=y`, `X86_NATIVE_CPU=y`), 2,816 `=y`/`=m` options. The seed used to come from the build machine's `.config`: anything not on the Victus was silently disabled, and the tree's state "leaked" into the matrix. Now the seed is fixed in the repo; if the file is missing, the script warns and falls back to `SRC/.config`.
- **`common/base.config`** (14 options): hardware-independent (`BTRFS_FS`, `EXT4_FS`, `NVME_CORE`, `BLK_DEV_NVME`, cgroups, etc).
- **`common/hardware.config`** (163 options): a shared hardware baseline for any platform: touchpad bus, Intel Ethernet, Wi-Fi/BT (including MediaTek), SOF/ACP audio, SD reader, thermal. Almost all `=m`, so `vmlinux` barely grows. Without this file, the generated kernels wouldn't have drivers for hardware my own Victus doesn't have.
- **`platform/victus16-r1xxx.config`**: an example of a model-specific fragment (i7-14650HX + RTX 4070 Max-Q, board 8C99), carried over from the `trim10`/`trim11` build process.

## 7. verify-fragments.sh: why it's needed

`merge_config.sh -m` together with `olddefconfig` silently drop options with unsatisfiable dependencies (a disabled gate vendor, a missing `select`, etc), and `merge_config` says nothing about it. The script merges fragments the same way `matrix-build.sh` does, in a temp directory (never touching `SRC/.config`), and compares what was requested against what actually landed:

| Status | Meaning | Action |
|---|---|---|
| `DEAD` | `=y`/`=m` was requested, but it came out `n` or the option doesn't exist | error, exit code 1 |
| `DOWNGRADED` | `=y` was requested, `=m` came out | warning |
| `RESURRECTED` | `is not set` was requested, `y`/`m` came out | info (pulled in by someone else's `select`) |

Laptop vendor EC options on `platform/desktop`/`platform/server` (no `ACPI_BATTERY`) and `AMD_PMC` on `server` are "dead" by design; the verifier skips them. Run it after any fragment edit.

## 8. Kconfig pitfalls

- A `bool` option set to `=m` silently becomes `n` (e.g. `BRCMFMAC_PCIE`, `PINCTRL_AMD`).
- Gate menus need to be enabled explicitly: `X86_PLATFORM_DRIVERS_DELL`/`_HP`, `CRYPTO_HW`, `WWAN`, `WLAN_VENDOR_*`, `NET_VENDOR_*`.
- Naming: `BT`, not `BLUETOOTH`; `USB_NET_CDCETHER`; THC = `INTEL_QUICKI2C`; `ACPI_PLATFORM_PROFILE`.
- Symbol case matters in `scripts/config`: "dead" options that `make olddefconfig` reverts are often caused by exactly this.

## 9. What's been built and verified

**Kernels built.** A batch build on Aug 13-14, 2026 produced **304** `bzImage` files (ranks 1-304), all `kernelrelease 7.1.6-cachyos-trim11-tuned`, ≈9.3 MB each. `build-popular.log` shows 0 `FAIL` and 2 `OK_WARN`. Per the last run's `status.tsv`, the per-batch time was 164-294 s. There are also 38 devel archives for the nvidia targets. The code is here; the built `vmlinuz` files (≈2.8 GB) aren't kept in the repo.

**Verified:**
- These builds were made **before** the 2026-09-19 config fixes (new `common/hardware.config`, a fixed seed, vendor gates in `ec/*`, `WWAN` in `modem/*`, AMD-specific bits in `cpu/amd-*` and `cpu/generic-*`, iGPU drivers in `gpu/nvidia|nouveau`). I haven't rebuilt since those fixes.
- While making the fixes, `verify-fragments.sh` showed `DEAD=0` across all 304 popular targets. That's just config resolution, though — I haven't rerun the check in this repo since.

**Not verified:**
- Compiling the new options (needs a fresh build).
- Booting the kernels on hardware other than mine: I don't have any. A verified `build + boot` exists only for my own Victus configuration.
- The Victus touchpad (`SYNA32E3:00` on Intel Serial IO I2C) doesn't work without `MFD_INTEL_LPSS_PCI`. That option has been added to the matrix; on my own 7.1.8 kernel it's still disabled.

## 10. Repository layout

```
kernel-matrix/
├── cpu/  gpu/  platform/  ec/  modem/     Kconfig fragments (19 / 7 / 5 / 11 / 4)
├── common/base.config, hardware.config    shared baseline (14 + 163 options)
├── seed/default.config                    base config (trim11, 7.1.6)
├── targets/                               7,614 targets (*.target)
├── popular-priority.tsv                   popularity ranking, 304 rows
├── gen-popular-targets.py                 target and ranking generator
├── matrix-build.sh                        build one target / the whole matrix
├── build-config.sh                        config for an arbitrary set of fragments
├── build-popular.sh                       batch build with a time budget
├── build-batch-jobserver.sh               parallel build through one jobserver
└── verify-fragments.sh                    fragment verification
```

Scripts contain `chown tarilka0gg` (that's my user) for output files; change it for yourself.

## 11. License

Scripts: MIT (`LICENSE`). Fragments, the seed, and `.target` files: GPL-2.0-only (`LICENSE-GPL-2.0`), since they're derived from the Linux kernel configuration.
