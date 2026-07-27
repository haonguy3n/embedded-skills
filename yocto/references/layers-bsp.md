# Layers, machine/distro confs, and BSP design

Where a setting belongs, and `FILESEXTRAPATHS` / override syntax, are in `SKILL.md`.

## Creating a layer

```bash
bitbake-layers create-layer ../meta-mycompany
bitbake-layers add-layer   ../meta-mycompany
```

`conf/layer.conf` — the full contract:
```bitbake
BBPATH .= ":${LAYERDIR}"
BBFILES += "${LAYERDIR}/recipes-*/*/*.bb ${LAYERDIR}/recipes-*/*/*.bbappend"

BBFILE_COLLECTIONS += "mycompany"
BBFILE_PATTERN_mycompany = "^${LAYERDIR}/"
BBFILE_PRIORITY_mycompany = "10"

LAYERVERSION_mycompany = "1"
LAYERDEPENDS_mycompany = "core meta-<soc-vendor>"      # collection names, optional (>=ver)
LAYERRECOMMENDS_mycompany = "openembedded-layer"
LAYERSERIES_COMPAT_mycompany = "kirkstone scarthgap"   # MUST match the release you support

# Optional: hide recipes until another layer is present
BBFILES_DYNAMIC += "openembedded-layer:${LAYERDIR}/dynamic-layers/openembedded-layer/recipes-*/*/*.bb*"
```
* `BBFILE_PRIORITY` decides which recipe wins when two layers ship the same `PN`, **and** the
  order `.bbappend`s apply (all apply; higher priority applied later).
* `LAYERSERIES_COMPAT` missing/wrong → BitBake refuses the layer. Do not blindly add a new
  release name; verify the layer builds first.
* `dynamic-layers/<collection>/…` ships recipes that only make sense when another layer is in
  `BBLAYERS` (vendor layers use this heavily for `openembedded-layer`, `qt5-layer`,
  `virtualization-layer`).

Validate:
```bash
yocto-check-layer ../meta-mycompany
yocto-check-layer --machines myboard -- ../meta-mycompany          # BSP tests
yocto-check-layer --dependency ../meta-<soc-vendor> -- ../meta-mycompany
```
Checks: README present, layer parses, `LAYERSERIES_COMPAT` set, world build works, **no
signature changes when the layer is merely added** (the important one — a layer must not
change other layers' output just by being present), BSP layers don't set `MACHINE`, distro
layers don't set `DISTRO`, patches have `Upstream-Status`.

## Layout conventions

```
meta-mycompany/
├── COPYING.MIT  README  README.sources
├── conf/
│   ├── layer.conf
│   ├── machine/<board>.conf
│   ├── machine/include/<family>.inc
│   └── distro/<distro>.conf  distro/include/*.inc
├── classes/ *.bbclass
├── recipes-bsp/      u-boot, firmware, formfactor
├── recipes-kernel/   linux/, kernel modules
├── recipes-core/     images, base-files, systemd tweaks
├── recipes-<domain>/ your applications
├── dynamic-layers/<other-collection>/recipes-*/…
├── wic/  *.wks.in
└── scripts/
```
Name layers `meta-*`; tooling assumes it.

## .bbappend rules

* Filename must match the recipe version: `foo_1.2.bbappend` ↔ `foo_1.2.bb`. Use
  `foo_%.bbappend` to match any version — preferred for appends that only add a patch or
  config, so version bumps don't silently drop your append.
* An orphaned `.bbappend` is an error unless listed in `BB_DANGLINGAPPENDS_WARNONLY`.
* Machine-specific files go in a machine subdir so they cannot leak:
  `recipes-bsp/u-boot/u-boot-vendor/myboard/fw_env.config`
* Check what applied: `bitbake-layers show-appends`, `show-overlayed`.

## Machine configuration — board bring-up

```bitbake
#@TYPE: Machine
#@NAME: My Board
#@SOC: <soc-part-number>

MACHINEOVERRIDES =. "<soc-family>:<soc-variant>:"   # `=.` keeps MACHINE right-most
require conf/machine/include/<soc-family>.inc
require conf/machine/include/arm/armv8a/tune-cortexa53.inc

MACHINE_FEATURES += "usbhost usbgadget wifi bluetooth pci rtc alsa"

# Kernel
PREFERRED_PROVIDER_virtual/kernel ?= "linux-<vendor>"
PREFERRED_VERSION_linux-<vendor> ?= "6.6%"
KERNEL_IMAGETYPE = "Image"                      # zImage / uImage / Image / fitImage
KERNEL_DEVICETREE = "<vendor>/<soc>-myboard.dtb <vendor>/<soc>-myboard-cam.dtbo"
KERNEL_CLASSES = "kernel-fitimage"              # if using FIT

# Bootloader
PREFERRED_PROVIDER_virtual/bootloader ?= "u-boot-<vendor>"
UBOOT_MACHINE = "myboard_defconfig"
UBOOT_CONFIG[sd] = "myboard_defconfig,sdcard"
UBOOT_ENTRYPOINT = "0x40480000"
SPL_BINARY = "spl/u-boot-spl.bin"
BOOT_CONTAINER_TARGETS = "flash_myboard"        # vendor stitching-tool target
EXTRA_IMAGEDEPENDS += "virtual/bootloader boot-container"

SERIAL_CONSOLES = "115200;ttyS1"                # pre-3.4: SERIAL_CONSOLE = "115200 ttyS1"

# Images
IMAGE_FSTYPES += "wic.gz wic.bmap tar.zst"
WKS_FILE = "myboard.wks.in"
IMAGE_BOOT_FILES = "Image ${KERNEL_DEVICETREE}"

MACHINE_EXTRA_RRECOMMENDS += "kernel-modules linux-firmware-<wifi-part>"
MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS += "kernel-module-mydriver"
```

| Variable | Purpose |
|---|---|
| `DEFAULTTUNE` / `require .../tune-*.inc` | ISA/ABI selection; drives `TUNE_PKGARCH` |
| `MACHINE_ARCH` | package arch for machine-specific output |
| `MACHINE_FEATURES` | consumed via `bb.utils.contains('MACHINE_FEATURES', …)` |
| `MACHINE_ESSENTIAL_EXTRA_RDEPENDS` | must-have for boot (vs `_RRECOMMENDS`, droppable) |
| `EXTRA_IMAGEDEPENDS` | built for the image but not installed (u-boot, boot-container, ATF) |
| `IMAGE_BOOT_FILES` | what the `bootimg-partition` wic plugin copies to the boot partition |
| `KERNEL_MODULE_AUTOLOAD` / `KERNEL_MODULE_PROBECONF` | modules-load.d / modprobe.d |
| `KMACHINE`, `KBRANCH`, `KERNEL_FEATURES` | linux-yocto machine mapping |
| `PREFERRED_PROVIDER_virtual/{kernel,bootloader,dtb,xserver,egl,libgles2}` | |

## Distro configuration

```bitbake
DISTRO = "mydistro"
DISTRO_NAME = "My Distro"
DISTRO_VERSION = "1.0"
MAINTAINER = "you@example.com"

require conf/distro/include/no-static-libs.inc
require conf/distro/include/security_flags.inc

DISTRO_FEATURES ?= "acl xattr pam systemd usrmerge ipv4 ipv6 wifi bluetooth"
DISTRO_FEATURES:remove = "x11 wayland sysvinit"
INIT_MANAGER = "systemd"                 # shorthand for the VIRTUAL-RUNTIME_* set
VIRTUAL-RUNTIME_init_manager = "systemd"
VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"
VIRTUAL-RUNTIME_dev_manager = "systemd"

PACKAGE_CLASSES ?= "package_ipk"
SDK_VENDOR = "-mysdk"
DISTRO_FEATURES_BACKFILL_CONSIDERED = "sysvinit"
```
`DISTRO_FEATURES` = "do we support this at all"; `MACHINE_FEATURES` = "does this board have
it". Recipes typically require both (`COMBINED_FEATURES` is the intersection).

## bblayers.conf and multi-repo management

Pick one and stick to it:
* **kas** (`kas-container build ci/board.yml`) — YAML pins repo+refs. Best default for new
  projects; what meta-qcom recommends.
* **repo** (`repo init -u … -m default.xml`) — NXP and many SoC vendors ship manifests.
* **git submodules** — fine for a small fixed set.
* `bitbake-layers layerindex-fetch` — convenience only, not for CI.

Always pin exact SHAs or release tags in CI; branch names are not versions.

---

# BSP design patterns

Every serious BSP solves the same problems. The test of a BSP is not "does board #1 build"
but **"what does adding board #4 cost?"** If the answer is more than one small `.conf` file,
the structure is wrong. Vendor layers below are cited as evidence the pattern is real.

## 1. Capability overrides, not board names

Conditioning on `MACHINE` gives an O(boards × recipes) matrix. Push *capabilities* into
`MACHINEOVERRIDES` instead:

```bitbake
# conf/machine/include/<family>.inc
MACHINEOVERRIDES =. "soc-family:soc-variant:"
INHERIT += "machine-overrides-extender"
MACHINEOVERRIDES_EXTENDER_soc-variant = "has-gpu2d:has-vpu:has-crypto"
```
```bitbake
# in a recipe, anywhere in the stack
DEPENDS:append:has-gpu2d = " vendor-gpu-userspace"
PACKAGECONFIG:append:has-vpu = " hwdec"
```
Adding board #4 with the same SoC = zero recipe changes.

*Evidence:* meta-freescale ships `machine-overrides-extender.bbclass` doing exactly this,
plus `MACHINEOVERRIDES_EXTENDER_FILTER_OUT_<ov>` to *remove* capabilities on cut-down
variants. meta-tegra does the coarse version with `MACHINEOVERRIDES =. "cuda:tegra:"`.

* Capability names describe hardware, not products (`has-vpu`, not `supports-netflix`).
* A filter-out mechanism is mandatory once you have SoC variants; otherwise you fork the
  family include.

## 2. Three-level layer nesting

```
meta-<soc>            SoC/silicon: kernel, bootloader, firmware recipes, family .inc
  └─ meta-<vendor>    org-wide policy: distro, common apps, keys, update strategy
       └─ meta-<board>  or  conf/machine/<board>.conf  — pure board data
```
Each level has a clear owner and its own `LAYERDEPENDS`/`LAYERSERIES_COMPAT`.

*Evidence:* OpenBMC nests `meta-aspeed` → `meta-<vendor>` → `meta-<vendor>/meta-<machine>`.
meta-freescale splits SoC support from `meta-freescale-3rdparty` and `meta-freescale-distro`.

* Never fork the SoC layer to change a board — higher `BBFILE_PRIORITY` + `.bbappend`.
* `BBFILE_PRIORITY` encodes *specificity* (core < SoC < vendor < board), never "who wins the
  argument".
* Product decisions (`IMAGE_INSTALL`, `DISTRO_FEATURES`) never appear in the SoC layer.

## 3. A board conf is data, not logic

The board `.conf` contains only what physically differs; everything else is a `require`.
A complete meta-tegra board conf is five lines — two `require`s and three board-specific
values. meta-qcom board confs are ~30 lines, almost all device-tree lists and firmware
packagegroups.

**Rule of thumb:** if a board conf exceeds ~40 lines, the family `.inc` you should have
extracted is hiding inside it. Refactor before adding the next board, not after.

## 4. Shared SoC package architecture

`PACKAGE_ARCH = "${MACHINE_ARCH}"` on SoC-wide binaries (GPU userspace, firmware, DSP blobs)
rebuilds them for every board; leaving it at `TUNE_PKGARCH` wrongly shares board-specific
output. Introduce an intermediate arch:

```bitbake
# family include
SOC_FAMILY_PKGARCH = "${TUNE_PKGARCH}_${SOC_FAMILY}"
PACKAGE_EXTRA_ARCHS:append = " ${SOC_FAMILY_PKGARCH}"
# in an SoC-wide recipe
PACKAGE_ARCH = "${SOC_FAMILY_PKGARCH}"
```
Every board of that SoC now reuses one sstate artifact, and board-specific recipes still get
`MACHINE_ARCH`.

*Evidence:* meta-tegra defines `TEGRA_PKGARCH`/`SOC_FAMILY_PKGARCH`; meta-freescale automates
it with `fsl-dynamic-packagearch.bbclass`.

**Diagnostic:** if adding a second board rebuilds the world, run
`bitbake -e <recipe> | grep '^PACKAGE_ARCH='` across your heavy recipes.

## 5. Licence-gated binary blobs

Vendor firmware is often redistributable only under a click-through licence whose text
changes without notice. Use a `*-eula-unpack` style class that (1) refuses to unpack unless
an explicit acceptance variable is set, with an error naming the variable and the file;
(2) pins the **md5 of the licence text** so a silent relicense breaks the build;
(3) self-extracts the vendor's shell-archive into `${WORKDIR}`.

```bitbake
ACCEPT_VENDOR_EULA = "1"                                   # conf: a legal statement
SRC_URI = "${VENDOR_MIRROR}/firmware-${PV}.bin;vendor-eula=true"
inherit vendor-eula-unpack
```
*Evidence:* meta-freescale's `fsl-eula-unpack.bbclass` — `ACCEPT_FSL_EULA`, a table of
`FSL_EULA_FILE_MD5SUM_*`, and an error string naming exactly what to put in `local.conf`.

* The licence-checksum failure is *signal*. Never update the md5 without reading the diff.
* Record exact blob versions in the SBOM — the least-visible, most-restricted content.
* Keep the acceptance variable in a distro conf under version control, not in a setup
  script's generated `local.conf`.

## 6. Boot container, media offsets, flashing bundles

The bootloader on modern SoCs is a signed container assembled by a vendor tool; one recipe
should own it, and the media offset must have exactly one definition. Full treatment in
`boot.md`. Flashing artifacts belong to the build, not a wiki page:

```bitbake
IMAGE_FSTYPES += "flashbundle.tar.zst"
PARTITION_LAYOUT_TEMPLATE ?= "layout-<soc>-emmc.xml"   # or a .wks.in
```
Two sub-styles, pick per SoC capability: a **partition-table description** (`.wks` for wic
when Linux writes the media; a vendor XML when the SoC ROM/flasher does), or a
**recovery-mode protocol** (USB download mode + host tool — ship the host tool recipe and the
exact command in the bundle).

*Evidence:* meta-tegra emits a `tegraflash` tarball with `doflash.sh`/`initrd-flash` and the
partition XML; meta-qcom selects prebuilt `rawprogram*.xml` sets by SoC+storage; NXP flows
use `uuu` scripts plus a manufacturing initramfs.

* Storage medium (eMMC/UFS/NVMe/SD/NOR) is part of board identity — make it a variable that
  selects the partition description, not a manual step.
* Always ship a `.bmap` alongside raw images.
* Factory provisioning (key injection, fusing, serial-number programming) belongs in a
  dedicated **manufacturing initramfs image**, never in the production rootfs.

## 7. Straddling a mainline and a vendor-fork kernel

Keep the *board description* independent of the kernel choice; give fork-only artefacts their
own variable.

```bitbake
# machine conf — mainline-safe
KERNEL_DEVICETREE ?= "vendor/<soc>-myboard.dtb"
VENDORKERNEL_KERNEL_DEVICETREE ?= "vendor/<soc>-myboard-camera.dtbo"   # fork only
# vendor kernel recipe/bbappend
KERNEL_DEVICETREE:append = " ${VENDORKERNEL_KERNEL_DEVICETREE}"
```
Select with `PREFERRED_PROVIDER_virtual/kernel`; the machine conf stays valid for both.

Related: **out-of-tree modules as the extension point** — ship an essentially mainline kernel
plus vendor `kernel-module-*` recipes and a separate `virtual/dtb` provider, rather than a
3000-patch fork.
```bitbake
MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS += "kernel-module-<soc>-display kernel-module-<soc>-camera"
PREFERRED_PROVIDER_virtual/dtb ?= "<vendor>-kernel-oot-dtb"
```
*Evidence:* meta-qcom carries both `KERNEL_DEVICETREE` and `LINUX_QCOM_KERNEL_DEVICETREE`;
meta-tegra builds DTs in a separate `virtual/dtb` recipe and delivers vendor drivers as
`*-kernel-oot-*` packages.

**Consequence:** when DTs come from a non-kernel recipe, "add a board DT" is not a
`KERNEL_DEVICETREE` edit. Document which model your BSP uses, prominently.

## 8. Describe boards as data, generate the rest

Board topology (sensors, inventory, fan zones, LEDs, pin config, update policy) lives in
JSON/YAML shipped by the board layer; generator classes turn it into config, systemd units
and D-Bus objects at build time. Adding a board becomes writing data.

*Evidence:* OpenBMC is built on this — `phosphor-dbus-yaml`, `phosphor-inventory-manager`,
`phosphor-fan`, `entity-manager` JSON, `obmc-phosphor-systemd`.

**Adopt it when** you have >3 boards sharing an application stack. Below that the generator
costs more than it saves.

## 9. Flash layout and update strategy belong to the distro

One distro-owned image class encodes the layout and update mechanism; the board supplies only
sizes and device names.
```bitbake
# distro layer: myco-image-types.bbclass
IMAGE_TYPES += "myco-static myco-ab"
# board conf
MYCO_ROOTFS_DEVICE = "/dev/mmcblk0"
MYCO_SLOT_SIZE_MB  = "768"
```
*Evidence:* OpenBMC's `image_types_phosphor` + `phosphor-software-manager-{ubi-fs,mmc}` pair
the flash layout with the update backend as distro concerns; boards choose a variant.

* Whatever tracks the active slot / boot counter must be writable by the bootloader and not
  corruptible by a failed rootfs write.
* Decide read-only-rootfs early. Retrofitting it after applications have learned to write
  everywhere is expensive.

## Anti-patterns

| Anti-pattern | Why it hurts | Do instead |
|---|---|---|
| Forking the SoC layer per product | every vendor update becomes a merge | higher-priority layer + `.bbappend` |
| `MACHINE`-name conditionals in recipes | O(boards × recipes) | capability overrides (§1) |
| Board conf that sets `IMAGE_INSTALL` | product policy in a hardware file | distro conf / image recipe |
| Copying a whole recipe to change one line | drifts from upstream | `.bbappend` |
| Setup script as the source of config | config not in git, undiscoverable | generate a *build dir*, keep policy in a distro conf |
| Copying a 200-line reference board conf | inherits settings nobody understands | copy, then delete everything you can't justify |
| `AUTOREV` / floating branches in a BSP | unreproducible; blames the wrong commit | pin SHAs, use a manifest/kas file |
| Media offsets duplicated in wic + docs + scripts | one gets updated, boards brick | one variable, referenced everywhere |
| Missing `PACKAGE_ARCH = "${MACHINE_ARCH}"` on per-board output | board #2 silently reuses board #1's sstate | set it, verify sstate reuse |
| Adding a layer without its `LAYERDEPENDS` | works locally, fails in CI | declare it |
| Vendor blobs with no SBOM entry | least-visible, most-restricted content | record versions and terms per release |

## Review checklist for a BSP layer

- [ ] Adding a board = one `.conf` under ~40 lines that `require`s a family include
- [ ] No `MACHINE`-name conditionals outside `conf/machine/`
- [ ] Capability overrides exist and are documented in the family include
- [ ] SoC-wide recipes use an SoC package arch; board-specific ones use `MACHINE_ARCH`
- [ ] Second board added → sstate reuse verified (the `Sstate summary` line, not vibes)
- [ ] Blob acceptance + licence checksums are in git, not a generated `local.conf`
- [ ] Boot-container components are version-pinned together
- [ ] Media offset / partition layout has exactly one definition
- [ ] Flashing bundle is produced by the build and versioned with the image
- [ ] `yocto-check-layer --machines <each board>` passes
- [ ] Layer set + SHAs pinned in a manifest or kas file that CI actually uses
