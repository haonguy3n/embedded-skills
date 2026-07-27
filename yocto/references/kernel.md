# Kernel development

## Which kernel model are you in?

| Model | How you know | Config mechanism |
|---|---|---|
| **linux-yocto** (`inherit kernel kernel-yocto`) | `KBRANCH`, `KMACHINE`, `.scc` files, a `kernel-meta` repo in `SRC_URI` | `.scc` features + `.cfg` fragments, merged by `do_kernel_metadata`/`do_kernel_configme` |
| **Vendor kernel** (`inherit kernel`) | `KBUILD_DEFCONFIG`, or a `defconfig` in `SRC_URI` | in-tree defconfig + `.cfg` fragments |
| **linux-yocto-custom** | your own tree | `defconfig` file in `SRC_URI` |

```bash
bitbake -e virtual/kernel | grep -E '^(PN|KBRANCH|KMACHINE|KBUILD_DEFCONFIG|LINUX_VERSION|SRCREV)='
bitbake virtual/kernel -c listtasks | grep kernel_
```

## Config: the correct workflow

**Never** edit `.config` in `tmp/work` and expect it to stick. Never commit a full `defconfig`
produced by `menuconfig` unless the recipe genuinely uses one.

```bash
bitbake virtual/kernel -c kernel_configme -f   # 1. baseline
bitbake virtual/kernel -c menuconfig           # 2. change interactively
bitbake virtual/kernel -c diffconfig           # 3. → ${WORKDIR}/fragment.cfg,
                                               #    only the CONFIG_ lines that changed
```
4. Install the fragment into your layer:
```bitbake
# recipes-kernel/linux/linux-vendor_%.bbappend
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
SRC_URI += " \
    file://myboard-wifi.cfg \
    file://myboard-security.cfg \
    file://0001-mydriver-fix.patch \
"
```
(For `linux-yocto` the fragment must *also* be listed in a `.scc`, or pulled via
`KERNEL_FEATURES`.)

5. **Verify it took effect** — the step people skip:
```bash
bitbake virtual/kernel -c kernel_configcheck -f
# Reports fragments whose options were not set / were overridden / were "invalid"
grep CONFIG_CFG80211 tmp/work/<mach>/linux-vendor/*/linux-*-build/.config
```
Silent drops happen when an option's `depends on` is unmet — `kernel_configcheck` is the only
thing that tells you.

### linux-yocto `.scc` features

`recipes-kernel/linux/linux-yocto/myfeature.scc`:
```
define KFEATURE_DESCRIPTION "My board feature"
define KFEATURE_COMPATIBILITY board

kconf hardware myfeature.cfg
patch 0001-something.patch
```
```bitbake
SRC_URI += "file://myfeature.scc file://myfeature.cfg file://0001-something.patch"
KERNEL_FEATURES:append = " myfeature.scc"
```
Built-in features live in `yocto-kernel-cache` (`features/`, `bsp/`, `cfg/`), e.g.
`KERNEL_FEATURES:append = " features/netfilter/netfilter.scc cfg/debug/ftrace.scc"`.

### In-tree defconfig (vendor kernels)

```bitbake
KBUILD_DEFCONFIG = "vendor_v8_defconfig"          # a file in arch/*/configs/
KBUILD_DEFCONFIG:myboard = "myboard_defconfig"
SRC_URI += "file://extra.cfg"
```
Order: `KBUILD_DEFCONFIG` (or `file://defconfig`) → then all `.cfg` fragments in `SRC_URI`
order. Fragments win.

## Machine mapping (linux-yocto)

```bitbake
COMPATIBLE_MACHINE:myboard = "myboard"
KMACHINE:myboard  = "myboard"
KBRANCH:myboard   = "v6.6/standard/base"
SRCREV_machine:myboard = "<sha>"
SRCREV_meta = "<sha of yocto-kernel-cache>"
LINUX_VERSION:myboard = "6.6.32"
LINUX_VERSION_EXTENSION = "-mycompany"     # shows in `uname -r`
```
`COMPATIBLE_MACHINE` is a **regex** matched against `MACHINEOVERRIDES`, e.g.
`"(soc-a|soc-b|soc-c)"`. Getting it wrong yields `ERROR: Nothing PROVIDES 'virtual/kernel'`.

## Patching

```bash
devtool modify virtual/kernel
cd build/workspace/sources/linux-vendor
git add -A && git commit -s -m "mydriver: fix X"
devtool build virtual/kernel && devtool build-image core-image-minimal
devtool finish virtual/kernel ../meta-mycompany      # emits patches + bbappend edits
```
Manual equivalent: `git format-patch -1` into
`meta-mycompany/recipes-kernel/linux/linux-vendor/` and add to `SRC_URI`. Every patch needs
`Upstream-Status:` and `Signed-off-by:`.

## Device trees

```bitbake
KERNEL_DEVICETREE = "vendor/soc-myboard.dtb"
KERNEL_DEVICETREE:append = " vendor/soc-myboard-cam.dtbo"
KERNEL_DEVICETREE_BUNDLE = "1"        # append dtb to the kernel image (some BSPs)
```
* Your board `.dts` goes into `arch/<arch>/boot/dts/...` via a patch, or use
  `devicetree.bbclass` (kirkstone+) to build out-of-tree DTs:
  ```bitbake
  inherit devicetree
  SRC_URI = "file://myboard-overlay.dts"
  ```
* Overlays: build `.dtbo`, ship via `IMAGE_BOOT_FILES`, apply from U-Boot (`fdt apply` /
  `fdtoverlays` in extlinux.conf) or via the BSP's overlay mechanism.
* Debug on target: `dtc -I fs -O dts /sys/firmware/devicetree/base` dumps the live DT.
* If your BSP delivers DTs from a separate `virtual/dtb` recipe, adding a board DT is *not* a
  `KERNEL_DEVICETREE` edit — see `layers-bsp.md` §7.

## Out-of-tree modules

`recipes-kernel/mydrv/mydrv_1.0.bb`:
```bitbake
SUMMARY = "My out-of-tree driver"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=…"

inherit module

SRC_URI = "file://Makefile file://mydrv.c file://COPYING"
S = "${WORKDIR}"

EXTRA_OEMAKE += "KERNEL_SRC=${STAGING_KERNEL_DIR}"
KERNEL_MODULE_AUTOLOAD += "mydrv"
KERNEL_MODULE_PROBECONF += "mydrv"
module_conf_mydrv = "options mydrv debug=1"
```
Makefile pattern the `module` class expects:
```makefile
obj-m := mydrv.o
SRC := $(shell pwd)
all:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC)
modules_install:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC) modules_install
```
`module.bbclass` sets `KERNEL_SRC`/`KERNEL_PATH` to `${STAGING_KERNEL_DIR}` and packages as
`kernel-module-mydrv`. Install with `MACHINE_EXTRA_RRECOMMENDS += "kernel-module-mydrv"`, or
`IMAGE_INSTALL:append`, or everything via
`MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS += "kernel-modules"`.
Reference implementation: `meta-skeleton/recipes-kernel/hello-mod`.

* The module must be signed if `CONFIG_MODULE_SIG_FORCE` — set `MODULE_SIGN_KEY` plumbing or
  disable the option.
* `kernel-devsrc` on target (`/usr/src/kernel` + `make scripts`) is for on-target builds only,
  not a dev loop.

## Image types and packaging

```bitbake
KERNEL_IMAGETYPE  = "Image"                     # single
KERNEL_IMAGETYPES = "Image Image.gz fitImage"   # multiple (kirkstone+)
KERNEL_CLASSES += "kernel-fitimage"
UBOOT_ENTRYPOINT / UBOOT_LOADADDRESS
INITRAMFS_IMAGE = "core-image-minimal-initramfs"
INITRAMFS_IMAGE_BUNDLE = "1"      # bundle initramfs INTO the kernel (2-pass build)
```
FIT signing (`UBOOT_SIGN_ENABLE`, `UBOOT_SIGN_KEYDIR`, `FIT_*`) is covered in `boot.md`.

Packages produced: `kernel`, `kernel-base`, `kernel-image-<type>`, `kernel-modules`,
`kernel-module-<name>`, `kernel-devicetree`, `kernel-vmlinux`, `kernel-dev`, `kernel-devsrc`.
Set `RDEPENDS:kernel-base = ""` to keep the kernel image out of the rootfs when it lives on a
raw partition.

## Version bump procedure

1. Bump `LINUX_VERSION`, `SRCREV`/`SRCREV_machine`, `KBRANCH`, and the recipe filename.
2. `bitbake virtual/kernel -c cleansstate`.
3. Refresh patches (`devtool modify` → rebase → `devtool finish`); drop patches now upstream.
4. `-c kernel_configme -f && -c kernel_configcheck -f` — fix every dropped/invalid fragment
   option; renamed Kconfig symbols are the usual cause.
5. Diff the effective config: `scripts/diffconfig old.config new.config` (from the kernel tree).
6. Rebuild, boot, and check `dmesg` for newly-missing drivers.

## Debugging

```bash
bitbake -c devshell virtual/kernel; cat .config     # what did we actually build?
tmp/work/<mach>/linux-*/…/vmlinux                   # symbols / addr2line
# on target:
dmesg -w
zcat /proc/config.gz | grep FOO                     # needs CONFIG_IKCONFIG_PROC
```
Useful debug fragments: `cfg/debug/ftrace.scc`, `features/kgdb/kgdb.scc`, `cfg/systemd.scc`.
For KGDB add `kgdboc=ttyS1,115200` to `bootargs`. For crash dumps enable
`CONFIG_KEXEC`/`CONFIG_CRASH_DUMP` and ship `kexec-tools`.

```bitbake
EXTRA_IMAGE_FEATURES += "tools-debug dbg-pkgs"
IMAGE_GEN_DEBUGFS = "1"
IMAGE_FSTYPES_DEBUGFS = "tar.bz2"
```

## Checklist for a driver enablement request

- [ ] fragment `.cfg` added to a layer (not a hand-edited defconfig)
- [ ] `kernel_configcheck` clean — option really set, no unmet deps
- [ ] DT node added/enabled and `KERNEL_DEVICETREE` updated
- [ ] module packaged (`kernel-module-*`) and pulled into the image
- [ ] autoload configured if the driver isn't bound by DT compatible
- [ ] firmware blob recipe (`linux-firmware-*` or custom) in `IMAGE_INSTALL`
- [ ] verified on hardware from `dmesg`, not from "it compiled"
