# Bootloader, boot container & secure boot

Platform-neutral. Named SoC families are examples of the pattern — substitute your own stage
names.

## 1. Model the chain before touching anything

```
ROM (mask-programmed, immutable)
  → first-stage loader  (SPL / MLO / XBL / MB1)          ← DDR init lives here
    → secure monitor    (ARM Trusted Firmware BL31)
      → [optional TEE]  (OP-TEE as BL32)
        → main loader   (U-Boot proper / UEFI / ABL)
          → OS loader   (boot script, extlinux, FIT, EFI stub)
            → kernel
```

Before debugging, answer: **which stage produced the last output you saw?** "U-Boot doesn't
boot" is nearly always a failure in a stage *below* U-Boot. Get the SoC's boot chapter from
its reference manual; do not work from forum posts.

Write the chain down in your BSP's README with the recipe that produces each stage — the
single highest-value artifact in a board bring-up.

## 2. U-Boot recipe variables

```bitbake
PREFERRED_PROVIDER_virtual/bootloader = "u-boot-<flavour>"

UBOOT_MACHINE = "myboard_defconfig"       # single config

# or multi-config: one recipe, several outputs
UBOOT_CONFIG ??= "sd emmc"
UBOOT_CONFIG[sd]   = "myboard_sd_defconfig,sdcard"
UBOOT_CONFIG[emmc] = "myboard_emmc_defconfig,wic.gz"

UBOOT_BINARY      = "u-boot.bin"          # what lands in DEPLOY_DIR_IMAGE
UBOOT_SUFFIX      = "bin"
UBOOT_MAKE_TARGET = "u-boot.bin"
UBOOT_ENTRYPOINT  = "0x40480000"          # from the SoC memory map
UBOOT_LOADADDRESS = "0x40480000"
SPL_BINARY        = "spl/u-boot-spl.bin"  # or "MLO" on older TI parts
UBOOT_ENV         = "boot"                # boot.txt → boot.scr via mkimage
UBOOT_LOCALVERSION = "-mycompany"
```

Patch and configure U-Boot exactly like the kernel — `.bbappend` +
`FILESEXTRAPATHS:prepend`, patches in `SRC_URI`, and Kconfig fragments
(`SRC_URI += "file://myboard.cfg"`, applied after the defconfig). Never carry a hand-edited
full defconfig if the tree supports fragments — it makes every vendor bump a merge conflict.

**Put boot policy in the U-Boot defconfig, not in a saved environment.** `CONFIG_BOOTCOMMAND`
and `CONFIG_EXTRA_ENV_SETTINGS` are reproducible and versioned; a `saveenv`-ed environment on
a factory board is not.

## 3. The boot container

On most current SoCs the ROM does not load `u-boot.bin` — it loads a signed container built by
a vendor stitching tool from several components. Give it its own recipe.

```bitbake
# boot-container_1.0.bb
DEPENDS = "vendor-mkimage-native virtual/bootloader vendor-atf vendor-ddr-firmware"
BOOT_CONTAINER_TARGETS ?= "flash_default"

inherit deploy
do_compile() {
    for t in ${BOOT_CONTAINER_TARGETS}; do
        oe_runmake SOC=${SOC_FAMILY} $t
    done
}
do_deploy() {
    install -m 0644 ${B}/out/boot-container-*.bin ${DEPLOYDIR}/
}
addtask deploy after do_compile before do_build
```
```bitbake
# machine conf
BOOT_CONTAINER_TARGETS = "flash_myboard"
EXTRA_IMAGEDEPENDS += "boot-container"
```

* **Component versions are coupled.** DDR/PHY firmware ↔ ATF ↔ bootloader are tested as a set
  by the silicon vendor. Pin all three together in the SoC family include. A mismatched trio
  typically hangs *before any console output* — the worst failure to debug.
* The container, not `u-boot.bin`, is what you flash. Deploying both invites someone to flash
  the wrong one.
* Machines select variants by a target variable, never by patching the recipe.

## 4. Media offsets — one definition, referenced everywhere

The ROM looks for the container at a fixed offset that depends on the **SoC and the boot
medium** (raw eMMC/SD vs boot partition vs NOR vs UFS LUN). Typical values run 1 KiB to
32/33 KiB; get yours from the reference manual, not a forum post. The offset belongs to the
**SoC**, not the board — put it in the family include and override only when a board genuinely
differs.

```bitbake
# SoC family include
BOOT_MEDIA_OFFSET_KIB ?= "33"
```
```
# .wks.in — the same value, expanded
part --source rawcopy --sourceparams="file=boot-container-${MACHINE}.bin" \
     --ondisk mmcblk --no-table --align 1 --offset ${BOOT_MEDIA_OFFSET_KIB}k
```
Any documented `dd` command, flashing script, or CI check must read the same variable.
Duplicated offsets are how boards get bricked six months after bring-up, and a wrong offset is
the #1 unbootable-board cause.

On SoCs that boot from an eMMC **boot partition** rather than the user area, the offset is
different *and* `mmc bootpart enable` / `mmc partconf` must be set — that is board state, so it
belongs in your provisioning step, not a wiki.

## 5. Handing off to the kernel

Pick one per BSP and be consistent.

**Boot script** — `UBOOT_ENV = "boot"` (ships `boot.txt`, deploys `boot.scr`).

**extlinux (distro boot)**
```bitbake
inherit uboot-extlinux-config
UBOOT_EXTLINUX = "1"
UBOOT_EXTLINUX_LABELS = "default"
UBOOT_EXTLINUX_KERNEL_IMAGE:default = "/Image"
UBOOT_EXTLINUX_FDT:default = "/myboard.dtb"
UBOOT_EXTLINUX_ROOT = "root=PARTUUID=..."
UBOOT_EXTLINUX_KERNEL_ARGS = "rootwait rw console=ttyS1,115200 earlycon"
```
The most portable option and the one vendor BSPs increasingly standardise on — it keeps
kernel/DT/initrd selection out of compiled bootloader logic.

**FIT image** — kernel + DT(s) + initramfs in one signed container; see §7.

Whichever you choose, keep `earlycon`/`earlyprintk` in the cmdline during bring-up.

## 6. The bootloader environment at runtime

```bitbake
IMAGE_INSTALL:append = " libubootenv-bin"     # or u-boot-fw-utils on older trees
```
Ship a machine-specific `/etc/fw_env.config`, in a machine subdirectory so it cannot leak to
another board (`recipes-bsp/u-boot/u-boot-fw-utils/myboard/fw_env.config`):
```
# device            offset      env size    sector size
/dev/mmcblk0        0xC0000     0x2000      0x200
/dev/mmcblk0        0xC2000     0x2000      0x200      # redundant copy
```
A wrong offset here silently corrupts the environment on first write. Verify with
`fw_printenv` on a board you can re-flash, before it ships. If anything (update agent, slot
switcher) writes the environment, use the **redundant** two-copy layout — a power cut during a
single-copy write leaves an unbootable board.

## 7. FIT images and verified boot

```bitbake
KERNEL_CLASSES += "kernel-fitimage"
KERNEL_IMAGETYPES = "fitImage"

UBOOT_SIGN_ENABLE = "1"
UBOOT_SIGN_KEYDIR = "${MYCO_KEYDIR}"      # NOT in the layer
UBOOT_SIGN_KEYNAME = "boot-key"           # boot-key.key + boot-key.crt
FIT_SIGN_ALG = "rsa2048"
FIT_HASH_ALG = "sha256"
FIT_SIGN_INDIVIDUAL = "1"
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 2000"
```

The public key is injected into U-Boot's control DTB, so U-Boot must be rebuilt whenever keys
change — and **the U-Boot that verifies the FIT must itself be verified by the stage below
it.** A signed FIT under an unsigned bootloader buys nothing; an attacker replaces U-Boot.

Key handling:
* Private keys never in the layer, never in git. Reference a directory via a variable so the
  build **fails loudly** when it is absent rather than silently producing unsigned output.
* Development and production keys must be visibly different (different `KEYNAME`), and CI must
  be able to assert which one an artifact was signed with.
* Add a build-time check that release images are signed — an unsigned release image that boots
  fine is the easiest mistake to ship.

## 8. SoC-level verified boot (fuses)

Vendors differ in naming (HAB/AHAB, fused OEM keys, eFuse-backed RoT) but the shape is
identical:

1. Generate a key hierarchy with the vendor's signing tool; derive a **key hash** to be fused.
2. Sign the first-stage container; append the signature/certificate structure.
3. Boot the signed image on an **open** (un-fused) part. Use the vendor's status command from
   the bootloader to confirm **zero** verification events. An open part boots signed images
   without checking them — "it booted" proves nothing here.
4. Burn the key-hash fuses. Re-verify signed boot still works, still open.
5. Only then blow the "close/secure" fuse. **This is irreversible.**

* Do steps 3–5 on sacrificial boards first, with a written, reviewed runbook.
* Fusing belongs in a dedicated manufacturing image/initramfs with logging, not in an
  engineer's shell history.
* Keep a permanently-open engineering board set; once you close parts, JTAG and recovery paths
  usually close too.
* Plan key rotation and revocation *before* production. Most SoCs support a small number of key
  slots; if you don't plan it, you get one key forever.

## 9. Update layouts

| Layout | Shape | Trade-off |
|---|---|---|
| Single + recovery | one production slot, one minimal recovery slot | simple, smaller; recovery path rots unless exercised |
| A/B slots | two full slots, bootloader picks by a persisted flag | safe rollback, ~2× media; needs a bootloader-writable marker |
| A/B + shared data | as above with a separate persistent partition | usual production choice |
| Delta/OSTree | filesystem-level versioning | efficient over the air, more moving parts |

Framework layers: `meta-rauc`, `meta-swupdate`, `meta-mender`, `meta-updater`. Whichever you
pick, the invariants are the same:

* The slot marker / boot counter must be **written by the bootloader** and survive a failed
  rootfs write — redundant bootloader env or a dedicated raw region.
* The bootloader must act on the counter *before* handing off, and the OS must confirm health
  after boot — otherwise "rollback" never triggers.
* Test the rollback path in CI by deliberately shipping a broken slot. An untested rollback is
  not a rollback.
* Keep the layout and update backend in the **distro** layer; boards supply device names and
  sizes only.

## 10. Debugging a board that does not boot

| Symptom | Look at |
|---|---|
| No serial output at all | boot-mode pins/fuses, wrong media, container at wrong offset, UART pinmux in the first-stage DT, wrong baud |
| First stage prints, then hangs | DDR firmware/timing mismatch, ATF version mismatch, insufficient power |
| Loader runs, kernel not found | boot script/extlinux paths, partition numbering, filesystem support compiled out |
| "Bad magic" loading the kernel | `KERNEL_IMAGETYPE` vs what the loader expects (`Image` vs `zImage` vs `fitImage`) |
| Kernel starts, silence after "Starting kernel" | wrong DT loaded, or console misconfigured hiding a panic → add `earlycon` |
| "Waiting for root device" | `root=` wrong, partition index off, storage driver not built in, no `rootwait` |
| Boots once then never again | environment corrupted by a bad `fw_env.config`, or a slot flag written wrong |
| Signed image fails after fusing | key hash mismatch, unsigned component in the chain, container rebuilt without re-signing |

Method: bisect by stage. Confirm the container is at the right offset (`dd` it back off the
media and compare), then that each stage's version matches the pinned set, then DT, then
rootfs. Change one variable at a time and keep a known-good image to fall back to.
