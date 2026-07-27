# Images, wic, and deployables

## Image recipe

```bitbake
SUMMARY = "MyProduct production image"
LICENSE = "MIT"

inherit core-image

IMAGE_FEATURES += "ssh-server-openssh"
# dev-only, keep out of production:
# EXTRA_IMAGE_FEATURES += "debug-tweaks tools-debug dbg-pkgs"

IMAGE_INSTALL += " myapp kernel-modules linux-firmware-bcm43455 tzdata"

IMAGE_LINGUAS = "en-us"
IMAGE_ROOTFS_EXTRA_SPACE = "65536"
IMAGE_OVERHEAD_FACTOR = "1.2"
IMAGE_FSTYPES = "wic.zst wic.bmap tar.zst"

ROOTFS_POSTPROCESS_COMMAND += "my_cleanup; "
my_cleanup() {
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/machine-id
}
```

| Variable | Meaning |
|---|---|
| `IMAGE_INSTALL` | packages you name |
| `IMAGE_FEATURES` | named bundles resolved via `FEATURE_PACKAGES_*`: `ssh-server-dropbear`, `read-only-rootfs`, `package-management`, `splash`, `hwcodecs`, `dev-pkgs`, `dbg-pkgs`, `tools-debug`, `debug-tweaks`, `allow-empty-password`, `empty-root-password`, `post-install-logging` |
| `EXTRA_IMAGE_FEATURES` | set in `local.conf`, added to `IMAGE_FEATURES` — the developer knob |
| `PACKAGE_INSTALL` | the final computed list handed to the package manager; read-only |
| `CORE_IMAGE_EXTRA_INSTALL` | `local.conf`-level addition for `core-image*` |

**`debug-tweaks` implies an empty root password and passwordless SSH.** Never ship it; gate it:
```bitbake
EXTRA_IMAGE_FEATURES:append = "${@bb.utils.contains('DISTRO_FEATURES','production','',' debug-tweaks',d)}"
```

Class chain: `core-image` (adds the `IMAGE_FEATURES` machinery) → `image` (the rootfs /
`do_image_*` engine). `image_types` defines every `IMAGE_FSTYPES` value.

## IMAGE_FSTYPES

Common: `ext4`, `ext4.gz`, `squashfs`, `squashfs-lz4`, `cpio.gz`, `tar.zst`, `wic`, `wic.gz`,
`wic.zst`, `wic.bmap`, `ubifs`, `multiubi`, `hddimg`, `iso`, `container`.

* `wic.bmap` pairs with `bmaptool copy` — dramatically faster flashing (skips holes). Always
  ship it alongside `wic.*`.
* UBI needs `MKUBIFS_ARGS` and `UBINIZE_ARGS` derived from the actual NAND page/erase-block
  geometry, not copied from another board.
* `squashfs` + overlayfs is the standard read-only-rootfs pattern for field devices.

Sizing:
```bitbake
IMAGE_ROOTFS_SIZE        # explicit size in KiB
IMAGE_OVERHEAD_FACTOR    # default 1.3 — multiplies measured rootfs size
IMAGE_ROOTFS_EXTRA_SPACE # KiB added after the factor
IMAGE_ROOTFS_ALIGNMENT
IMAGE_ROOTFS_MAXSIZE     # build fails if exceeded — use it as a CI guardrail
```

## Shrinking an image (ordered by payoff)

1. `INHERIT += "buildhistory"` + `BUILDHISTORY_COMMIT = "1"`, then read
   `buildhistory/images/<machine>/<libc>/<image>/installed-package-sizes.txt`.
2. Drop `dev-pkgs`/`dbg-pkgs`/`package-management`/`tools-*` from `IMAGE_FEATURES`.
3. `DISTRO_FEATURES:remove` for whole subsystems (x11, wayland, bluetooth, pam, nfs…).
4. `PACKAGECONFIG` trims on the biggest recipes.
5. `IMAGE_INSTALL` audit: `oe-pkgdata-util list-pkg-files -p <pkg>`, `buildhistory-diff`.
6. `poky-tiny` / `musl` (`TCLIBC = "musl"`) if chasing single-digit MB.
7. `IMAGE_LINGUAS = ""`, `NO_RECOMMENDATIONS = "1"` (careful: kills `RRECOMMENDS`, which is
   how firmware and modules usually arrive).

## wic

```bash
wic create mywks -e my-image            # cooked mode: uses the build dir + current MACHINE
wic ls   tmp/deploy/images/$MACHINE/my-image.wic
wic ls   tmp/deploy/images/$MACHINE/my-image.wic:1/
wic cp   local.file tmp/deploy/images/$MACHINE/my-image.wic:1/
wic rm   tmp/deploy/images/$MACHINE/my-image.wic:1/oops
wic write tmp/deploy/images/$MACHINE/my-image.wic /dev/sdX
wic list images        # available .wks in the layers
wic list <wks> help    # a wks's own --help
bitbake wic-tools      # if wic complains about missing native tools
```
```bitbake
IMAGE_FSTYPES += "wic wic.bmap"
WKS_FILE = "myboard.wks.in"          # .wks.in gets ${VAR} expansion; .wks does not
WKS_FILE_DEPENDS = "virtual/bootloader boot-container virtual/kernel"
IMAGE_BOOT_FILES = "Image ${KERNEL_DEVICETREE} boot.scr"
```

### .wks syntax

```
# raw bootloader at a fixed offset (see boot.md — one variable, referenced everywhere)
part --source rawcopy --sourceparams="file=boot-container-${MACHINE}.bin" \
     --ondisk mmcblk --no-table --align 1 --offset ${BOOT_MEDIA_OFFSET_KIB}k

# FAT boot partition populated from IMAGE_BOOT_FILES
part /boot --source bootimg-partition --ondisk mmcblk --fstype=vfat --label boot \
     --active --align 4096 --size 64

# rootfs
part / --source rootfs --ondisk mmcblk --fstype=ext4 --label root --align 4096 --use-uuid

# extra data partition, empty
part /data --ondisk mmcblk --fstype=ext4 --label data --align 4096 --size 256 --fixed-size 256

bootloader --ptable msdos --timeout=3 --append="console=ttyS1,115200 rootwait rw"
```

| Option | Meaning |
|---|---|
| `--source` | plugin: `rootfs`, `bootimg-partition`, `bootimg-efi`, `bootimg-pcbios`, `rawcopy`, `empty`, `isoimage-isohybrid` |
| `--sourceparams` | plugin args, e.g. `file=`, `loader=grub-efi`, `rootfs-dir=<image>` |
| `--ondisk` | device basename → sets `/dev/<x>p1` naming |
| `--fstype` | `ext4`, `vfat`, `squashfs`, `swap`, `none` |
| `--label`, `--part-name`, `--part-type` (GPT GUID) | |
| `--align <KiB>`, `--offset` | placement |
| `--size` (min) vs `--fixed-size` (exact; fails if content is bigger) | |
| `--use-uuid` / `--uuid` / `--fsuuid` | PARTUUID-based `root=` |
| `--no-table` | raw region, not in the partition table |
| `--active` | boot flag |
| `--extra-space`, `--overhead-factor` | per-partition sizing |
| `--exclude-path` | drop a subtree from the rootfs partition (e.g. `--exclude-path boot/`) |
| `--rootfs-dir=<image-name>` | pull from a *different* image recipe — how you build multi-rootfs media |

With `bootimg-partition`, the kernel cmdline comes from the boot script/extlinux, not from
`bootloader --append`.

Multi-slot (A/B):
```
part --source rootfs --rootfs-dir=my-image --fstype=ext4 --label rootA --align 4096 --size 512
part --source rootfs --rootfs-dir=my-image --fstype=ext4 --label rootB --align 4096 --size 512
part /data --fstype=ext4 --label data --align 4096 --size 128
```

## initramfs

```bitbake
INITRAMFS_IMAGE = "my-initramfs"
INITRAMFS_IMAGE_BUNDLE = "1"          # embed into the kernel (2-pass kernel build)
INITRAMFS_FSTYPES = "cpio.gz"
INITRAMFS_MAXSIZE = "131072"
```
```bitbake
# my-initramfs.bb
IMAGE_FSTYPES = "${INITRAMFS_FSTYPES}"
IMAGE_INSTALL = "busybox base-passwd initramfs-framework-base ${VIRTUAL-RUNTIME_init_manager}"
IMAGE_LINGUAS = ""
IMAGE_ROOTFS_SIZE = "8192"
IMAGE_NAME_SUFFIX ?= ""
inherit core-image
```
Use `initramfs-framework` modules (`initramfs-module-udev`, `-setup-live`, custom
`/init.d/xx-mymodule`) rather than hand-writing `/init` — testable and composable.

## SDK / eSDK

```bash
bitbake my-image -c populate_sdk        # classic cross toolchain installer
bitbake my-image -c populate_sdk_ext    # extensible SDK (devtool inside)
bitbake meta-toolchain
```
```bitbake
TOOLCHAIN_HOST_TASK += "nativesdk-cmake nativesdk-python3"
TOOLCHAIN_TARGET_TASK += "myapp-dev myapp-staticdev"
SDKMACHINE = "x86_64"
SDK_EXT_TYPE = "minimal"        # eSDK without full sstate
SDK_INCLUDE_TOOLCHAIN = "1"
```
Output in `tmp/deploy/sdk/*.sh`. Consumers `source environment-setup-*` and get `$CC`,
`$CONFIGURE_FLAGS`, `$OECORE_*`.

## Inspecting what you built

```bash
ls tmp/deploy/images/$MACHINE/
buildhistory-diff                            # what changed vs last build
cat buildhistory/images/$MACHINE/*/my-image/{files-in-image.txt,installed-packages.txt,image-info.txt}
runqemu $MACHINE my-image nographic slirp    # if the machine is qemu-able
```
Turn buildhistory on early in a product — the only cheap way to answer "what got bigger / what
package appeared" months later.

## Common image mistakes

* `IMAGE_INSTALL = "…"` (plain `=`) in a `core-image`-based recipe — wipes the base set. Use
  `+=` or `IMAGE_INSTALL:append`.
* `IMAGE_INSTALL:append` in `local.conf` — works, but hides product content outside the layer.
  Use `CORE_IMAGE_EXTRA_INSTALL` for local experiments only.
* Shipping `package-management` "just in case" — drags in the whole package DB.
* `--fixed-size` too small → the build fails late, after a full rootfs. Prefer `--size` plus an
  `IMAGE_ROOTFS_MAXSIZE` guardrail.
* Forgetting `wic.bmap`, then wondering why flashing takes 20 minutes.
* Baking in `/etc/machine-id`, SSH host keys, or `/var/lib/dbus` — they must be generated at
  first boot, otherwise every unit is identical on the network.
