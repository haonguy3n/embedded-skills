---
name: yocto-recipe-authoring
description: Writing, upgrading and packaging BitBake recipes — recipe skeleton, naming/PV/PR/PE, SRC_URI fetchers and checksums, S/B/D/WORKDIR, the standard task chain, build-system classes (autotools/cmake/meson/setuptools3/go/cargo/kernel-module), PACKAGECONFIG, PACKAGES/FILES splitting, RDEPENDS, systemd/init scripts, users/groups, update-alternatives, LICENSE and LIC_FILES_CHKSUM, native/nativesdk/BBCLASSEXTEND. Use when creating a new recipe, upgrading a version, splitting packages, or adding a service.
---

# Recipe authoring

## Skeleton that passes review

```bitbake
SUMMARY = "One line, no trailing period, < 80 chars"
DESCRIPTION = "Longer prose. Optional if SUMMARY says it all."
HOMEPAGE = "https://example.org/foo"
BUGTRACKER = "https://example.org/foo/issues"
SECTION = "console/utils"

LICENSE = "MIT & BSD-3-Clause"
LIC_FILES_CHKSUM = "file://COPYING;md5=3da9cfbcb788c80a0384361b4de20420 \
                    file://src/lib.c;beginline=2;endline=20;md5=..."

SRC_URI = "https://example.org/foo/foo-${PV}.tar.xz \
           file://0001-fix-cross-build.patch \
           file://foo.service"
SRC_URI[sha256sum] = "…"

DEPENDS = "zlib openssl"

inherit autotools pkgconfig systemd

PACKAGECONFIG ??= "ssl ${@bb.utils.filter('DISTRO_FEATURES', 'ipv6', d)}"
PACKAGECONFIG[ssl]  = "--with-ssl,--without-ssl,openssl"
PACKAGECONFIG[ipv6] = "--enable-ipv6,--disable-ipv6"

EXTRA_OECONF = "--disable-static"

SYSTEMD_SERVICE:${PN} = "foo.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/foo.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${systemd_system_unitdir}/foo.service"
RDEPENDS:${PN} += "bash"

BBCLASSEXTEND = "native nativesdk"
```

## Naming and versions

* File name is `<pn>_<pv>.bb` → sets `PN` and `PV`. Lowercase, `-` not `_` in `PN`.
* `PR = "r1"` — only needed when you change the *output* without changing `PV` and you ship
  a package feed. Most modern layers omit `PR` entirely (PR server / hash equiv handles it).
* `PE = "1"` — epoch; use when upstream versioning goes backwards.
* Git recipes:
  ```bitbake
  PV = "1.2.3+git${SRCPV}"        # ≤ kirkstone;  newer: PV = "1.2.3+git"
  SRCREV = "0123abcd…"            # pin it. AUTOREV only in development configs.
  SRC_URI = "git://github.com/x/y.git;protocol=https;branch=main"
  S = "${WORKDIR}/git"            # ≤ scarthgap;  5.0+: S = "${UNPACKDIR}/${BP}" style varies
  ```
* Multiple `SRCREV`s: name the URLs and use `SRCREV_<name>`:
  ```bitbake
  SRC_URI = "git://a;name=main;branch=main git://b;name=sub;destsuffix=git/sub;branch=main"
  SRCREV_main = "…"
  SRCREV_sub  = "…"
  SRCREV_FORMAT = "main_sub"
  ```

## SRC_URI fetchers and useful params

| Form | Notes |
|---|---|
| `https://…/x-${PV}.tar.gz` | needs `SRC_URI[sha256sum]` |
| `git://host/repo.git;protocol=https;branch=B;tag=T` | `branch=` mandatory (hardknott+) |
| `file://patch.patch` | found via `FILESPATH`; `;striplevel=`, `;patchdir=`, `;apply=no` |
| `file://dir;subdir=x` | copy a directory |
| `gitsm://…` | git submodules |
| `svn://`, `hg://`, `npm://`, `crate://`, `gomod://` | language fetchers |
| `;name=foo` | names the URL for `SRC_URI[foo.sha256sum]` / `SRCREV_foo` |
| `;unpack=false` | keep the archive intact |
| `;destsuffix=` | where under `${WORKDIR}` it lands |
| `;downloadfilename=` | rename in `DL_DIR` (avoid collisions like `v1.0.tar.gz`) |

## Directory variables

| Var | Meaning |
|---|---|
| `WORKDIR` | `tmp/work/<pkgarch>/<pn>/<pv>` |
| `S` | source dir; default `${WORKDIR}/${BP}` (`${BPN}-${PV}`) |
| `B` | build dir; default `${S}`. cmake/meson set `${WORKDIR}/build` |
| `D` | install destdir for `do_install` |
| `PKGD` / `PKGDEST` | post-`do_package` staging |
| `STAGING_DIR_HOST/NATIVE/TARGET` | sysroots |
| `DEPLOY_DIR_IMAGE` | `tmp/deploy/images/${MACHINE}` |

Never hardcode `/usr`, `/etc`: use `${bindir}`, `${libdir}`, `${sysconfdir}`,
`${datadir}`, `${localstatedir}`, `${systemd_system_unitdir}`, `${nonarch_base_libdir}`.

## Task chain

```
do_fetch → do_unpack → do_patch → do_prepare_recipe_sysroot → do_configure
  → do_compile → do_install → do_populate_sysroot
                            → do_package → do_packagedata → do_package_write_{ipk,deb,rpm}
  → do_populate_lic → do_deploy (deploy class) → do_build
```

Adding tasks:
```bitbake
do_mytask() { … }
addtask mytask after do_compile before do_install
do_mytask[dirs]      = "${B}"          # create & cd into
do_mytask[cleandirs] = "${WORKDIR}/x"  # wipe & create
do_mytask[noexec]    = "1"             # disable a task
do_mytask[depends]  += "openssl-native:do_populate_sysroot"
deltask do_package_qa                  # nuclear; almost always wrong
```

Overriding: prefer `do_install:append()` / `:prepend()` over redefining the whole task.

## Build-system classes

| Class | For |
|---|---|
| `autotools`, `autotools-brokensep` | configure.ac; `brokensep` when `${B}` must equal `${S}` |
| `cmake` (+ `cmake_qemu`) | `EXTRA_OECMAKE` |
| `meson` | `EXTRA_OEMESON`, `MESON_TARGET` |
| `pkgconfig` | anything using pkg-config — add it whenever the build calls `pkg-config` |
| `setuptools3` / `python_setuptools_build_meta` / `python_poetry_core` / `flit_core` | Python |
| `go` / `go-mod` | Go; needs vendored modules or `gomod://` |
| `cargo` / `cargo-update-recipe-crates` | Rust |
| `module` | out-of-tree kernel module |
| `kernel`, `kernel-yocto`, `kernel-fitimage` | kernel |
| `image`, `core-image` | images |
| `bin_package` | prebuilt binaries — no configure/compile, just install |
| `native`, `nativesdk`, `cross`, `crosssdk` | via `BBCLASSEXTEND` |
| `useradd`, `systemd`, `update-rc.d`, `update-alternatives` | integration |
| `allarch` | arch-independent content (scripts, data) — **not** if it ships ELF or depends on arch-specific paths |
| `deploy` | put artifacts in `DEPLOY_DIR_IMAGE` via `do_deploy` |
| `externalsrc` | build from a path outside the build dir (devtool uses this) |
| `insane` | QA (auto-inherited) |

For a pure "no build system" recipe just define `do_install()` and add
`INHIBIT_DEFAULT_DEPS = "1"` if it genuinely needs no toolchain.

## PACKAGECONFIG — the right way to expose options

```bitbake
PACKAGECONFIG[<feature>] = "<enable-opts>,<disable-opts>,<build-deps>,<runtime-deps>,<runtime-recommends>,<conflicting-features>"
PACKAGECONFIG ??= "a b"
PACKAGECONFIG:append:has-gpu = " gpu"
```
Tie to features rather than hardcoding:
```bitbake
PACKAGECONFIG ??= "${@bb.utils.filter('DISTRO_FEATURES', 'wayland x11 systemd', d)}"
```
Never write `EXTRA_OECONF:append = " --enable-x"` for something a downstream layer might
want off — make it a PACKAGECONFIG.

## Packaging and splitting

```bitbake
PACKAGES = "${PN}-dbg ${PN}-staticdev ${PN}-dev ${PN}-doc ${PN}-locale ${PN}-tools ${PN}"
FILES:${PN}       = "${bindir}/foo ${libdir}/libfoo.so.*"
FILES:${PN}-tools = "${bindir}/foo-*"
FILES:${PN}-dev  += "${libdir}/foo/*.la"
CONFFILES:${PN}   = "${sysconfdir}/foo.conf"   # preserved on upgrade
ALLOW_EMPTY:${PN} = "1"                        # ship an empty meta-package
```

Rules:
* Order in `PACKAGES` matters — **first match wins**, left to right. Put narrow packages
  (`-tools`) before `${PN}`.
* Split by *when it is needed*: runtime vs `-dev` (headers, `.so` symlink, `.pc`, cmake
  files) vs `-staticdev` (`.a`) vs `-dbg` (auto) vs `-doc` vs `-locale`.
* Auto-split helpers: `PACKAGES_DYNAMIC = "^${PN}-plugin-.*"` plus
  `do_split_packages()` in a `python populate_packages:prepend()`.
* `PACKAGE_ARCH`: default is `TUNE_PKGARCH`. Set `PACKAGE_ARCH = "${MACHINE_ARCH}"` when
  output depends on the machine (this is what forces a per-machine rebuild). meta-<soc-vendor>
  automates this via `fsl-dynamic-packagearch.bbclass`.
* `RDEPENDS` must name **packages**. Verify: `oe-pkgdata-util list-pkgs | grep foo`.

## Services, users, alternatives

```bitbake
inherit systemd
SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "foo.service foo.socket"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"       # or "disable"

inherit update-rc.d
INITSCRIPT_PACKAGES = "${PN}"
INITSCRIPT_NAME = "foo"
INITSCRIPT_PARAMS = "defaults 90"

inherit useradd
USERADD_PACKAGES = "${PN}"
USERADD_PARAM:${PN}  = "-r -s /sbin/nologin -g foo foo"
GROUPADD_PARAM:${PN} = "-r foo"

inherit update-alternatives
ALTERNATIVE:${PN} = "vi"
ALTERNATIVE_LINK_NAME[vi] = "${bindir}/vi"
ALTERNATIVE_TARGET[vi] = "${bindir}/vim"
ALTERNATIVE_PRIORITY = "100"
```

Support both init systems where the layer targets both:
`SYSTEMD_SERVICE` guarded by `bb.utils.contains('DISTRO_FEATURES','systemd',…)`, or
just inherit both classes — the classes are no-ops when the feature is absent.

Post-install scripts:
```bitbake
pkg_postinst_ontarget:${PN}() {   # runs on first boot (needed if it touches the live system)
    systemctl daemon-reload
}
pkg_postinst:${PN}() {            # runs at rootfs time if possible, else first boot
    :
}
```
`read-only-rootfs` images fail if any `pkg_postinst` defers to the target. Prefer
`_ontarget` only when truly required.

## Licensing

* `LICENSE` uses SPDX identifiers joined with `&` (all apply) and `|` (choice):
  `LICENSE = "GPL-2.0-only & LGPL-2.1-or-later"`. Old-style `GPLv2` was renamed to
  `GPL-2.0-only` in kirkstone — match the tree.
* `LIC_FILES_CHKSUM` pins the license text so a silent relicense breaks the build. Point at
  `COPYING`/`LICENSE`, or at the header block of a source file with
  `;beginline=;endline=;md5=`. Get the md5 by building once and reading the error.
* Per-package licensing: `LICENSE:${PN}-foo = "MIT"`.
* Proprietary/EULA content: `LICENSE_FLAGS = "commercial"` (newer:
  `LICENSE_FLAGS = "<name>"` + `LICENSE_FLAGS_ACCEPTED` in local.conf).
* `NO_GENERIC_LICENSE[<lic>] = "path/in/src"` for non-standard license texts.

## Upgrading a recipe

```bash
devtool upgrade <pn> -V <newver>     # fetches, rebases patches, drops recipe in workspace
devtool build <pn>
devtool finish <pn> ../meta-mylayer  # writes back, regenerates patches
# Fleet-wide:
devtool check-upgrade-status         # what has newer upstream releases
```
After upgrade always: re-verify `LIC_FILES_CHKSUM`, drop patches now upstream (check with
`git log --oneline` in the workspace), re-check `PACKAGECONFIG` options still exist
(`unknown-configure-option` QA catches removals), and diff the shipped file list:
```bash
oe-pkgdata-util list-pkg-files -p <pn>   # before/after
```

## native / nativesdk / multilib

* `BBCLASSEXTEND = "native nativesdk"` generates `<pn>-native` and `nativesdk-<pn>`.
* Differ per variant with `CLASSOVERRIDE`: `DEPENDS:class-native = "…"`,
  `do_install:append:class-target() {…}`.
* A `-native` recipe must not depend on target sysroot content.
* Multilib: `MULTILIBS = "multilib:lib32"`, `DEFAULTTUNE:virtclass-multilib-lib32 = "armv7athf-neon"`;
  packages get a `lib32-` prefix. Recipes needing awareness use `MLPREFIX`.

## Review checklist

- [ ] `SUMMARY`, `HOMEPAGE`, `LICENSE`, `LIC_FILES_CHKSUM`, checksums present
- [ ] `SRCREV` pinned (no `AUTOREV` in a released layer), `branch=` on git URLs
- [ ] every patch has `Upstream-Status:` and `Signed-off-by:`
- [ ] `DEPENDS` complete; no host paths; `pkgconfig` inherited if used
- [ ] `FILES` covers everything installed (`installed-vs-shipped` clean)
- [ ] `RDEPENDS` names packages, not recipes
- [ ] optional features are `PACKAGECONFIG`, not hardcoded
- [ ] `COMPATIBLE_MACHINE` set if hardware-specific
- [ ] `PACKAGE_ARCH` correct (machine-specific output → `${MACHINE_ARCH}`)
- [ ] builds clean from scratch: `bitbake <pn> -c cleansstate && bitbake <pn>`
