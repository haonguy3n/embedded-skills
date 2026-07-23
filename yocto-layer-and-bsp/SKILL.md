---
name: yocto-layer-and-bsp
description: Layer and BSP engineering — creating layers, conf/layer.conf (BBFILE_COLLECTIONS, BBFILE_PRIORITY, LAYERDEPENDS, LAYERSERIES_COMPAT), bbappend rules and FILESEXTRAPATHS, dynamic-layers, machine .conf variables for board bring-up (kernel/bootloader/tune/devicetree/serial/wic), distro conf vs machine conf vs local.conf, MACHINEOVERRIDES families, yocto-check-layer, and repo/kas/submodule layer management. Use when adding a board, creating or restructuring a layer, or deciding where a setting belongs.
---

# Layers and BSPs

## Where does a setting belong?

| Setting kind | Home | Example |
|---|---|---|
| Hardware fact | `conf/machine/<machine>.conf` | `KERNEL_DEVICETREE`, `UBOOT_MACHINE`, `SERIAL_CONSOLES`, `MACHINE_FEATURES` |
| Product/policy | `conf/distro/<distro>.conf` | `DISTRO_FEATURES`, init system, package format, `PREFERRED_VERSION` policy |
| What's in the image | image recipe | `IMAGE_INSTALL`, `IMAGE_FEATURES`, `IMAGE_FSTYPES` |
| Recipe behaviour | recipe / `.bbappend` | `PACKAGECONFIG`, patches |
| Developer-local | `conf/local.conf` | `BB_NUMBER_THREADS`, `SSTATE_DIR`, `INHERIT += "rm_work"` |

If you find yourself putting `IMAGE_INSTALL:append` in a machine conf, stop — that's a
distro/image decision. Machine confs describe *the board*, not *the product*.

## Creating a layer

```bash
bitbake-layers create-layer ../meta-mycompany
bitbake-layers add-layer   ../meta-mycompany
bitbake-layers show-layers
```

`conf/layer.conf` — the full contract:

```bitbake
BBPATH .= ":${LAYERDIR}"
BBFILES += "${LAYERDIR}/recipes-*/*/*.bb ${LAYERDIR}/recipes-*/*/*.bbappend"

BBFILE_COLLECTIONS += "mycompany"
BBFILE_PATTERN_mycompany = "^${LAYERDIR}/"
BBFILE_PRIORITY_mycompany = "10"

LAYERVERSION_mycompany = "1"
LAYERDEPENDS_mycompany = "core meta-<soc-vendor>"        # collection names, optional (>=ver)
LAYERRECOMMENDS_mycompany = "openembedded-layer"
LAYERSERIES_COMPAT_mycompany = "kirkstone scarthgap"  # MUST match the release you support

# Optional: hide recipes until another layer is present
BBFILES_DYNAMIC += "openembedded-layer:${LAYERDIR}/dynamic-layers/openembedded-layer/recipes-*/*/*.bb*"
```

* `BBFILE_PRIORITY` decides which recipe wins when two layers ship the same `PN`, **and**
  the order `.bbappend`s are applied (all apply; higher priority applied later).
* `LAYERSERIES_COMPAT` missing/wrong → BitBake refuses the layer with a clear error. Do not
  blindly add a new release name; verify the layer builds first.
* `dynamic-layers/<collection>/…` is the standard way to ship recipes that only make sense
  when another layer is in `BBLAYERS` (meta-<soc-vendor> uses this heavily for
  `openembedded-layer`, `qt5-layer`, `virtualization-layer`).

Validate:
```bash
source oe-init-build-env
yocto-check-layer ../meta-mycompany
yocto-check-layer --machines myboard -- ../meta-mycompany     # BSP tests
yocto-check-layer --dependency ../meta-<soc-vendor> -- ../meta-mycompany
```

## Layer layout conventions

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

Name layers `meta-*`; tooling assumes it. Keep BSP (`meta-<soc>-bsp`) separate from product
(`meta-<product>`) when more than one product shares a SoC.

## .bbappend rules

* Filename must match the recipe version: `foo_1.2.bbappend` ↔ `foo_1.2.bb`.
  Use `foo_%.bbappend` to match any version — preferred for appends that only add a patch
  or a config, so version bumps don't silently drop your append.
* An orphaned `.bbappend` (no matching recipe) is an error unless listed in
  `BB_DANGLINGAPPENDS_WARNONLY`.
* To add files, always:
  ```bitbake
  FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
  SRC_URI += "file://0001-x.patch"
  ```
  `:=` is mandatory (captures `THISDIR` now); the trailing `:` keeps the list separated.
* Machine-specific files go in a machine subdir so they only apply there:
  `recipes-bsp/u-boot/u-boot-vendor/myboard/fw_env.config`
* Check what's applied:
  ```bash
  bitbake-layers show-appends | grep -A3 u-boot
  bitbake-layers show-overlayed
  ```

## Machine configuration — board bring-up checklist

```bitbake
#@TYPE: Machine
#@NAME: My Board
#@SOC: <soc-part-number>
#@DESCRIPTION: Machine configuration for MyBoard

MACHINEOVERRIDES =. "<soc-family>:<soc-variant>:"   # join the SoC family; `=.` keeps
                                                    # MACHINE right-most (highest priority)
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

# Serial / console
SERIAL_CONSOLES = "115200;ttyS1"
# pre-3.4 / some trees: SERIAL_CONSOLE = "115200 ttyS1"

# Images
IMAGE_FSTYPES += "wic.gz wic.bmap tar.zst"
WKS_FILE = "myboard.wks.in"
IMAGE_BOOT_FILES = "Image ${KERNEL_DEVICETREE}"

MACHINE_EXTRA_RRECOMMENDS += "kernel-modules linux-firmware-<wifi-part>"
MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS += "kernel-module-mydriver"
```

Aim for a board conf under ~40 lines. Anything longer means the SoC-family `.inc` you should
have factored out is hiding inside it — see `yocto-bsp-patterns`.

Other variables worth knowing:

| Variable | Purpose |
|---|---|
| `DEFAULTTUNE` / `require .../tune-*.inc` | ISA/ABI selection; drives `TUNE_PKGARCH` |
| `MACHINE_ARCH` | package arch for machine-specific output |
| `MACHINE_FEATURES` | consumed by recipes via `bb.utils.contains('MACHINE_FEATURES', …)` |
| `MACHINE_ESSENTIAL_EXTRA_RDEPENDS` | must-have for boot (vs `_RRECOMMENDS`, droppable) |
| `EXTRA_IMAGEDEPENDS` | built for the image but not installed (u-boot, boot-container, atf) |
| `IMAGE_BOOT_FILES` | what `bootimg-partition` wic plugin copies to the boot partition |
| `UBOOT_CONFIG` / `UBOOT_MACHINE` | u-boot defconfig selection |
| `KERNEL_MODULE_AUTOLOAD` / `KERNEL_MODULE_PROBECONF` | modules-load.d / modprobe.d generation |
| `KMACHINE`, `KBRANCH`, `KERNEL_FEATURES` | linux-yocto machine mapping |
| `PREFERRED_PROVIDER_virtual/{kernel,bootloader,xserver,egl,libgles2}` | |
| `MACHINEOVERRIDES` | family grouping — extend, never replace |

### MACHINEOVERRIDES family idiom

Group boards by SoC capability so recipes never mention a board name:
```bitbake
MACHINEOVERRIDES =. "<soc-family>:<soc-variant>:"
# optional capability expansion (meta-<soc-vendor> ships a class for this):
MACHINEOVERRIDES_EXTENDER_<soc-variant> = "has-gpu2d:has-vpu:has-crypto"
```
Recipes then say `DEPENDS:append:has-gpu2d = " vendor-gl-userspace"`, which applies to every
board with that block. Adding a board to an existing family costs nothing in recipe space.

`=.` (prepend without a space) matters — the machine name must stay right-most, i.e. highest
priority. Full treatment in `yocto-bsp-patterns` (Pattern 1).

## Distro configuration

```bitbake
DISTRO = "mydistro"
DISTRO_NAME = "My Distro"
DISTRO_VERSION = "1.0"
DISTRO_CODENAME = "vulcan"
MAINTAINER = "you@example.com"

require conf/distro/include/no-static-libs.inc
require conf/distro/include/security_flags.inc

DISTRO_FEATURES ?= "acl xattr pam systemd usrmerge ipv4 ipv6 wifi bluetooth"
DISTRO_FEATURES:remove = "x11 wayland sysvinit"
VIRTUAL-RUNTIME_init_manager = "systemd"
VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"
VIRTUAL-RUNTIME_dev_manager = "systemd"
INIT_MANAGER = "systemd"                 # newer shorthand for the above

PACKAGE_CLASSES ?= "package_ipk"
SDK_VENDOR = "-mysdk"
DISTRO_FEATURES_BACKFILL_CONSIDERED = "sysvinit"
PREFERRED_VERSION_linux-vendor ?= "5.15%"
```

`DISTRO_FEATURES` vs `MACHINE_FEATURES`: distro = "do we support this at all";
machine = "does this board have it". Recipes typically require both
(`COMBINED_FEATURES` is the intersection).

## bblayers.conf and multi-repo management

```bitbake
BBLAYERS ?= " \
  ${TOPDIR}/../poky/meta \
  ${TOPDIR}/../poky/meta-poky \
  ${TOPDIR}/../meta-openembedded/meta-oe \
  ${TOPDIR}/../meta-<soc-vendor> \
  ${TOPDIR}/../meta-<soc>-3rdparty \
  ${TOPDIR}/../meta-mycompany \
"
```

Pick one and stick to it for reproducibility:
* **kas** (`kas-container build ci/board.yml`) — YAML pins repo+refs; what meta-qcom
  recommends. Best default for new projects.
* **repo** (`repo init -u … -m default.xml`) — NXP and many SoC vendors ship manifests.
* **git submodules** — simple, fine for a small fixed set.
* **`bitbake-layers layerindex-fetch <layer>`** — convenience only, not for CI.

Always pin exact SHAs or release tags in CI; "branch names" are not versions.

## Common layer mistakes

* Copying a whole recipe into your layer to change one line — use a `.bbappend`.
* Setting `MACHINE` or `DISTRO` from inside a layer (`yocto-check-layer` fails you for it).
* `BBFILE_PRIORITY` escalation wars — priority should encode *specificity*
  (core < BSP < product), not "make my change win".
* Machine-specific files in a non-machine subdir → they leak into other machines' builds.
* Forgetting `PACKAGE_ARCH = "${MACHINE_ARCH}"` on a recipe whose output varies per board —
  the second board silently reuses the first board's sstate artifact.
* Adding a layer without adding its `LAYERDEPENDS` — works on your machine, fails in CI.
