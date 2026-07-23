---
name: yocto-bsp-patterns
description: Platform-neutral design patterns for structuring a BSP or board-support layer that must scale to many boards and SoCs — SoC-family capability overrides, three-level layer nesting, shared SoC package architecture, licence-gated binary blob handling, multi-stage boot container assembly, mainline-vs-fork kernel straddling, data-driven board description, flashing-artifact generation, and firmware update layouts. Distilled from how meta-freescale, meta-imx, meta-tegra, meta-qcom and OpenBMC solve the same problems. Use when designing or refactoring a BSP layer, adding the second/third board, or judging whether an existing BSP is well structured.
---

# BSP design patterns

Every serious BSP solves the same six problems. This skill is the *shape* of each solution,
independent of silicon vendor. Vendor layers are cited only as evidence that the pattern is
real and battle-tested.

The test of a BSP is not "does board #1 build". It is **"what does adding board #4 cost?"**
If the answer is more than one small `.conf` file, the structure is wrong.

---

## Pattern 1 — Capability overrides, not board names

**Problem.** Recipes need to behave differently per SoC block (GPU, VPU, crypto engine,
display controller). Conditioning on `MACHINE` gives you an O(boards × recipes) matrix.

**Pattern.** Push *capabilities* into `MACHINEOVERRIDES`, and condition recipes on those.

```bitbake
# conf/machine/include/<family>.inc
MACHINEOVERRIDES =. "soc-family:soc-variant:"      # `=.` : prepend, no space —
                                                  # MACHINE stays right-most = highest priority

# a capability-expansion table
MACHINEOVERRIDES_EXTENDER_soc-variant = "has-gpu2d:has-vpu:has-crypto"
```
```bitbake
# in a recipe, anywhere in the stack
DEPENDS:append:has-gpu2d = " vendor-gpu-userspace"
PACKAGECONFIG:append:has-vpu = " hwdec"
```

Adding board #4 with the same SoC = zero recipe changes.

*Evidence:* meta-freescale ships `machine-overrides-extender.bbclass` doing exactly this
(`MACHINEOVERRIDES_EXTENDER_<soc> = "imxfbdev:imxipu:imxvpu:imxgpu2d:…"`, plus
`MACHINEOVERRIDES_EXTENDER_FILTER_OUT_<ov>` to *remove* capabilities on cut-down variants).
meta-tegra does the coarse version with `MACHINEOVERRIDES =. "cuda:tegra:"`.

**Rules.**
* Capability names describe hardware, not products (`has-vpu`, not `supports-netflix`).
* Never `MACHINEOVERRIDES = "…"` (plain assign) — always prepend, or you lose the machine.
* A filter-out mechanism is mandatory once you have SoC variants; otherwise you fork the
  family include.

---

## Pattern 2 — Three-level layer nesting

**Problem.** One layer per board doesn't scale; one layer for everything becomes unownable.

**Pattern.**
```
meta-<soc>            SoC/silicon support: kernel, bootloader, firmware recipes, family .inc
  └─ meta-<vendor>    organisation-wide policy: distro, common apps, keys, update strategy
       └─ meta-<board>  or  conf/machine/<board>.conf  — pure board data
```
Each level has a clear owner and its own `LAYERDEPENDS`/`LAYERSERIES_COMPAT`. Boards below,
policy in the middle, silicon at the bottom.

*Evidence:* OpenBMC nests `meta-aspeed` (SoC) → `meta-<vendor>` → `meta-<vendor>/meta-<machine>`.
meta-freescale splits SoC support from `meta-freescale-3rdparty` (non-reference boards) and
`meta-freescale-distro` (products).

**Rules.**
* Never fork the SoC layer to change a board. Higher `BBFILE_PRIORITY` + `.bbappend`.
* `BBFILE_PRIORITY` encodes *specificity* (core < SoC < vendor < board), never "who wins
  the argument".
* Product decisions (`IMAGE_INSTALL`, `DISTRO_FEATURES`) never appear in the SoC layer.

---

## Pattern 3 — A board conf is data, not logic

**Problem.** Board confs accrete until nobody can tell what's board-specific.

**Pattern.** The board `.conf` contains only what physically differs. Everything else is a
`require`.

```bitbake
#@TYPE: Machine
#@NAME: MyBoard rev C
#@SOC: <soc>
require conf/machine/include/<soc>.inc
require conf/machine/include/<carrier-options>.inc

KERNEL_DEVICETREE  = "vendor/<soc>-myboard.dtb vendor/<soc>-myboard-cam.dtbo"
UBOOT_MACHINE      = "myboard_defconfig"
SERIAL_CONSOLES    = "115200;ttyS1"
MACHINE_FEATURES  += "wifi bluetooth rtc"
BOOT_MEDIA_OFFSET  = "33"                     # board-specific placement
```

*Evidence:* a complete meta-tegra board conf is five lines — two `require`s and three
board-specific values (boot device, media size, partition-layout template). meta-qcom board
confs are ~30 lines, almost all of it device-tree lists and firmware packagegroups.

**Rule of thumb.** If a board conf exceeds ~40 lines, the family `.inc` you should have
extracted is hiding inside it. Refactor before adding the next board, not after.

---

## Pattern 4 — Shared SoC package architecture

**Problem.** Setting `PACKAGE_ARCH = "${MACHINE_ARCH}"` on SoC-wide binaries (GPU userspace,
firmware, DSP blobs) rebuilds them for every board. Leaving it at `TUNE_PKGARCH` wrongly
shares board-specific output.

**Pattern.** Introduce an intermediate architecture between tune and machine:

```bitbake
# family include
SOC_FAMILY_PKGARCH = "${TUNE_PKGARCH}_${SOC_FAMILY}"
PACKAGE_EXTRA_ARCHS:append = " ${SOC_FAMILY_PKGARCH}"
```
```bitbake
# in an SoC-wide recipe
PACKAGE_ARCH = "${SOC_FAMILY_PKGARCH}"
```

Now every board of that SoC reuses one sstate artifact, and board-specific recipes still get
`MACHINE_ARCH`.

*Evidence:* meta-tegra defines `TEGRA_PKGARCH`/`SOC_FAMILY_PKGARCH` and appends both to
`PACKAGE_EXTRA_ARCHS`. meta-freescale automates the assignment from the other end with
`fsl-dynamic-packagearch.bbclass`.

**Diagnostic.** If adding a second board rebuilds the world, dump
`bitbake -e <recipe> | grep '^PACKAGE_ARCH='` across your heavy recipes — one of them is
`MACHINE_ARCH` when it shouldn't be, or vice versa.

---

## Pattern 5 — Licence-gated binary blobs

**Problem.** Vendor firmware/userspace is redistributable only under a click-through
licence, and the licence text itself changes without notice.

**Pattern.** A `*-eula-unpack` style class that:
1. refuses to unpack unless an explicit acceptance variable is set, with an actionable
   error message naming the variable and the file;
2. pins the **md5 of the licence text** so a silent relicense breaks the build;
3. self-extracts the vendor's shell-archive into `${WORKDIR}`.

```bitbake
# conf (a legal statement, not a build flag)
ACCEPT_VENDOR_EULA = "1"
```
```bitbake
# recipe
SRC_URI = "${VENDOR_MIRROR}/firmware-${PV}.bin;vendor-eula=true"
inherit vendor-eula-unpack
```

*Evidence:* meta-freescale's `fsl-eula-unpack.bbclass` — `ACCEPT_FSL_EULA`, a table of
`FSL_EULA_FILE_MD5SUM_*` values, and an error string that tells you exactly what to put in
`local.conf`. NVIDIA and Qualcomm binaries have equivalent gating.

**Rules.**
* The licence-checksum failure is *signal*. Never "fix" it by updating the md5 without
  reading the diff.
* Record exact blob versions in the SBOM; they are the part of your image with the least
  visibility and the most restrictive terms.
* Keep blob recipes in the SoC layer, and the acceptance variable in a distro conf under
  version control — not in a setup script's generated `local.conf`.

---

## Pattern 6 — The boot container is a first-class build product

**Problem.** On modern SoCs the bootloader is not one binary. It is a signed container
assembled from ROM-stage loader + DDR/PHY firmware + secure-monitor (ATF/BL31) + optional
TEE (BL32) + U-Boot/UEFI, produced by a vendor stitching tool.

**Pattern.** One recipe owns the container, depends on each component, and deploys the
result. Machines select variants by a target variable, not by patching the recipe.

```bitbake
# boot-container_x.y.bb
DEPENDS = "vendor-mkimage-native virtual/bootloader vendor-atf vendor-ddr-firmware"
BOOT_CONTAINER_TARGETS ?= "flash_default"
inherit deploy
do_compile() {
    for t in ${BOOT_CONTAINER_TARGETS}; do oe_runmake SOC=${SOC_FAMILY} $t; done
}
do_deploy() { install -m 0644 ${B}/out/*.bin ${DEPLOYDIR}/; }
addtask deploy after do_compile before do_build
```
```bitbake
# machine conf
BOOT_CONTAINER_TARGETS = "flash_myboard"
EXTRA_IMAGEDEPENDS += "boot-container"
BOOT_MEDIA_OFFSET = "33"       # KiB — from the SoC reference manual, not a forum post
```

**Rules.**
* The media offset belongs to the **SoC**, not the board — put it in the family include and
  only override it when a board genuinely differs.
* Component versions are coupled (DDR firmware ↔ ATF ↔ bootloader). Pin them together in
  the family include; a mismatched trio hangs before any console output.
* Getting the offset wrong is the #1 unbootable-board cause. Make it a named variable used
  by both the wic stanza and any `dd` instructions, so there is exactly one source of truth.

---

## Pattern 7 — Straddling a mainline and a vendor-fork kernel

**Problem.** The vendor fork has the features; mainline has the future. Boards need both,
sometimes simultaneously.

**Pattern.** Keep the *board description* independent of the kernel choice, and give the
fork-only artefacts their own variable.

```bitbake
# machine conf — mainline-safe
KERNEL_DEVICETREE ?= "vendor/<soc>-myboard.dtb"
# only exists in the vendor fork
VENDORKERNEL_KERNEL_DEVICETREE ?= "vendor/<soc>-myboard-camera.dtbo"
```
```bitbake
# vendor kernel recipe/bbappend
KERNEL_DEVICETREE:append = " ${VENDORKERNEL_KERNEL_DEVICETREE}"
```
Select with `PREFERRED_PROVIDER_virtual/kernel`; the machine conf stays valid for both.

Related pattern: **out-of-tree modules as the extension point**. Ship an essentially
mainline kernel plus vendor `kernel-module-*` recipes and a separate `virtual/dtb` provider,
rather than a 3000-patch fork.

```bitbake
MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS += "kernel-module-<soc>-display kernel-module-<soc>-camera"
PREFERRED_PROVIDER_virtual/dtb ?= "<vendor>-kernel-oot-dtb"
```

*Evidence:* meta-qcom carries both `KERNEL_DEVICETREE` and `LINUX_QCOM_KERNEL_DEVICETREE`.
meta-tegra builds device trees in a separate `virtual/dtb` recipe and delivers vendor
drivers as `*-kernel-oot-*` module packages.

**Consequence to plan for:** when DTs come from a non-kernel recipe, "add a board DT" is not
a `KERNEL_DEVICETREE` edit — it is a change to the DT provider recipe. Document which model
your BSP uses, prominently.

---

## Pattern 8 — Describe boards as data, generate the rest

**Problem.** Per-board C/C++/recipe logic multiplies with the fleet.

**Pattern.** Board topology (sensors, inventory, fan zones, LEDs, pin config, update policy)
lives in JSON/YAML shipped by the board layer; generator classes turn it into config,
systemd units, and D-Bus objects at build time. Adding a board becomes writing data.

```bitbake
# board layer
SRC_URI += "file://myboard-sensors.json file://myboard-inventory.yaml"
inherit platform-config-generator
```

*Evidence:* OpenBMC is built on this — `phosphor-dbus-yaml`, `phosphor-inventory-manager`,
`phosphor-fan`, `entity-manager` JSON, `obmc-phosphor-systemd` all consume declarative
descriptions rather than per-platform code.

**Adopt it when** you have >3 boards sharing an application stack. Below that the generator
costs more than it saves.

---

## Pattern 9 — Flashing artifacts are a build output, not a wiki page

**Problem.** "How do I flash it" lives in tribal knowledge and drifts from the build.

**Pattern.** The image build produces a **self-contained flashing bundle**: binaries +
partition description + a script, versioned together.

```bitbake
IMAGE_FSTYPES += "flashbundle.tar.zst"
PARTITION_LAYOUT_TEMPLATE ?= "layout-<soc>-emmc.xml"   # or a .wks.in
```
Two sub-styles, pick per SoC capability:
* **Partition-table description** (`.wks` for wic, or a vendor XML consumed by the flashing
  tool). Wic when Linux writes the media; vendor XML when the SoC ROM/flasher does.
* **Recovery-mode protocol** (USB download mode + host tool). Ship the host tool recipe and
  the exact command in the bundle.

*Evidence:* meta-tegra emits a `tegraflash` tarball containing `doflash.sh`/`initrd-flash`
and the partition XML; meta-qcom selects prebuilt `rawprogram*.xml` partition sets by
SoC+storage; NXP flows use `uuu` scripts plus a manufacturing initramfs.

**Rules.**
* Storage medium (eMMC / UFS / NVMe / SD / NOR) is part of board identity — make it a
  variable that selects the partition description, not a manual step.
* Always ship a `.bmap` alongside raw images.
* Factory provisioning (key injection, fusing, serial-number programming) belongs in a
  dedicated **manufacturing initramfs image**, never in the production rootfs.

---

## Pattern 10 — Flash layout and update strategy belong to the distro, not the board

**Problem.** A/B slots, read-only rootfs + overlay, and recovery partitions get reinvented
per board and diverge.

**Pattern.** One distro-owned image class encodes the layout and the update mechanism; the
board supplies only sizes and device names.

```bitbake
# distro layer: myco-image-types.bbclass
IMAGE_TYPES += "myco-static myco-ab"
# board conf
MYCO_ROOTFS_DEVICE = "/dev/mmcblk0"
MYCO_SLOT_SIZE_MB  = "768"
```

*Evidence:* OpenBMC's `image_types_phosphor` + `phosphor-software-manager-{ubi-fs,mmc}` pair
the flash layout with the update backend as distro-level concerns; boards choose a variant.

**Rules.**
* Whatever tracks the active slot / boot counter must be writable by the bootloader and
  *not* corruptible by a failed rootfs write (redundant bootloader env, or a dedicated raw
  region).
* Decide read-only-rootfs early. Retrofitting it after applications have learned to write
  everywhere is expensive.

---

## Anti-patterns (all observed in real BSPs)

| Anti-pattern | Why it hurts | Do instead |
|---|---|---|
| Forking the SoC layer per product | every vendor update becomes a merge | higher-priority layer + `.bbappend` |
| `MACHINE`-name conditionals in recipes | O(boards × recipes) | capability overrides (Pattern 1) |
| Board conf that sets `IMAGE_INSTALL` | product policy in a hardware file | distro conf / image recipe |
| Setup script as the source of config | config not in git, undiscoverable | generate a *build dir*, keep policy in a distro conf |
| Copying a 200-line reference board conf | inherits settings nobody understands | copy, then delete everything you can't justify |
| `AUTOREV` / floating branches in a BSP | unreproducible; blames the wrong commit | pin SHAs, use a manifest/kas file |
| Media offsets duplicated in wic + docs + scripts | one gets updated, boards brick | one variable, referenced everywhere |
| Vendor blobs with no SBOM entry | the least-visible, most-restricted content | record versions and terms per release |

---

## Review checklist for a BSP layer

- [ ] Adding a board = one `.conf` under ~40 lines that `require`s a family include
- [ ] No `MACHINE`-name conditionals outside `conf/machine/`
- [ ] Capability overrides exist and are documented in the family include
- [ ] SoC-wide recipes use an SoC package arch; board-specific ones use `MACHINE_ARCH`
- [ ] Second board added → sstate reuse verified (`Sstate summary` line, not vibes)
- [ ] Blob acceptance + licence checksums are in git, not a generated `local.conf`
- [ ] Boot-container components are version-pinned together
- [ ] Media offset / partition layout has exactly one definition
- [ ] Flashing bundle is produced by the build and versioned with the image
- [ ] `yocto-check-layer --machines <each board>` passes
- [ ] Layer set + SHAs pinned in a manifest or kas file that CI actually uses
