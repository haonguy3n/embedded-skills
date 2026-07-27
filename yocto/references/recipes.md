# Recipe authoring

## Skeleton that passes review

```bitbake
SUMMARY = "One line, no trailing period, < 80 chars"
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
(On styhead 5.1+, `file://` entries unpack to `${UNPACKDIR}`, not `${WORKDIR}` — see
`migration.md`.)

## Naming and versions

* File name `<pn>_<pv>.bb` sets `PN` and `PV`. Lowercase; `-` not `_` in `PN`.
* `PR = "r1"` — only when you change the *output* without changing `PV` and you ship a feed.
  Most modern layers omit `PR` (PR server / hash equivalence handles it).
* `PE = "1"` — epoch; when upstream versioning goes backwards.
* Git recipes:
  ```bitbake
  PV = "1.2.3+git${SRCPV}"        # ≤ kirkstone;  newer: PV = "1.2.3+git"
  SRCREV = "0123abcd…"            # pin it. AUTOREV only in development configs.
  SRC_URI = "git://github.com/x/y.git;protocol=https;branch=main"
  S = "${WORKDIR}/git"            # ≤ scarthgap; 5.0+ conventions vary
  ```
* Multiple `SRCREV`s — name the URLs:
  ```bitbake
  SRC_URI = "git://a;name=main;branch=main git://b;name=sub;destsuffix=git/sub;branch=main"
  SRCREV_main = "…"
  SRCREV_sub  = "…"
  SRCREV_FORMAT = "main_sub"
  ```

## SRC_URI fetchers and params

| Form | Notes |
|---|---|
| `https://…/x-${PV}.tar.gz` | needs `SRC_URI[sha256sum]` |
| `git://host/repo.git;protocol=https;branch=B;tag=T` | `branch=` mandatory (hardknott+) |
| `file://patch.patch` | via `FILESPATH`; `;striplevel=`, `;patchdir=`, `;apply=no` |
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

Never hardcode `/usr` or `/etc`: use `${bindir}`, `${libdir}`, `${sysconfdir}`,
`${datadir}`, `${localstatedir}`, `${systemd_system_unitdir}`, `${nonarch_base_libdir}`.

The task chain and `addtask`/task-flag syntax are in `bitbake.md`.

## Build-system classes

| Class | For |
|---|---|
| `autotools`, `autotools-brokensep` | configure.ac; `brokensep` when `${B}` must equal `${S}` |
| `cmake` (+ `cmake_qemu`) | `EXTRA_OECMAKE` |
| `meson` | `EXTRA_OEMESON`, `MESON_TARGET` |
| `pkgconfig` | anything calling `pkg-config` — add it whenever the build does |
| `setuptools3` / `python_setuptools_build_meta` / `python_poetry_core` / `flit_core` | Python |
| `go` / `go-mod` | Go; needs vendored modules or `gomod://` |
| `cargo` / `cargo-update-recipe-crates` | Rust |
| `module` | out-of-tree kernel module |
| `kernel`, `kernel-yocto`, `kernel-fitimage` | kernel |
| `image`, `core-image` | images |
| `bin_package` | prebuilt binaries — no configure/compile, just install |
| `native`, `nativesdk`, `cross`, `crosssdk` | via `BBCLASSEXTEND` |
| `useradd`, `systemd`, `update-rc.d`, `update-alternatives` | integration |
| `allarch` | arch-independent content — **not** if it ships ELF or arch-specific paths |
| `deploy` | put artifacts in `DEPLOY_DIR_IMAGE` via `do_deploy` |
| `externalsrc` | build from a path outside the build dir (devtool uses this) |

For a "no build system" recipe, define `do_install()` and add `INHIBIT_DEFAULT_DEPS = "1"`
if it genuinely needs no toolchain.

## PACKAGECONFIG

```bitbake
PACKAGECONFIG[<feature>] = "<enable>,<disable>,<build-deps>,<rdeps>,<rrecommends>,<conflicts>"
PACKAGECONFIG ??= "a b"
PACKAGECONFIG:append:has-gpu = " gpu"
PACKAGECONFIG ??= "${@bb.utils.filter('DISTRO_FEATURES', 'wayland x11 systemd', d)}"
```
Never write `EXTRA_OECONF:append = " --enable-x"` for something a downstream layer might want
off — make it a PACKAGECONFIG.

## Packaging and splitting

```bitbake
PACKAGES = "${PN}-dbg ${PN}-staticdev ${PN}-dev ${PN}-doc ${PN}-locale ${PN}-tools ${PN}"
FILES:${PN}       = "${bindir}/foo ${libdir}/libfoo.so.*"
FILES:${PN}-tools = "${bindir}/foo-*"
FILES:${PN}-dev  += "${libdir}/foo/*.la"
CONFFILES:${PN}   = "${sysconfdir}/foo.conf"   # preserved on upgrade
ALLOW_EMPTY:${PN} = "1"                        # ship an empty meta-package
```
* Order in `PACKAGES` matters — **first match wins**, left to right. Narrow packages
  (`-tools`) before `${PN}`.
* Split by *when it is needed*: runtime vs `-dev` (headers, `.so` symlink, `.pc`, cmake
  files) vs `-staticdev` (`.a`) vs `-dbg` (auto) vs `-doc` vs `-locale`.
* Auto-split: `PACKAGES_DYNAMIC = "^${PN}-plugin-.*"` plus `do_split_packages()` in a
  `python populate_packages:prepend()`.
* `PACKAGE_ARCH` defaults to `TUNE_PKGARCH`. Set `${MACHINE_ARCH}` when the output depends on
  the machine — this is what forces a per-machine rebuild. See `layers-bsp.md` for the
  SoC-family middle ground.
* `RDEPENDS` must name **packages**: `oe-pkgdata-util list-pkgs | grep foo`.

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
To support both init systems, inherit both classes — they are no-ops when the feature is
absent — or guard with `bb.utils.contains('DISTRO_FEATURES','systemd',…)`.

```bitbake
pkg_postinst_ontarget:${PN}() { systemctl daemon-reload }   # first boot
pkg_postinst:${PN}() { : }                                  # rootfs time if possible
```
`read-only-rootfs` images fail if any `pkg_postinst` defers to the target. Use `_ontarget`
only when truly required.

## Licensing

* `LICENSE` uses SPDX identifiers joined with `&` (all apply) and `|` (choice):
  `LICENSE = "GPL-2.0-only & LGPL-2.1-or-later"`. Old-style `GPLv2` was renamed in kirkstone
  — match the tree.
* `LIC_FILES_CHKSUM` pins the licence text so a silent relicense breaks the build. Point at
  `COPYING`/`LICENSE`, or a source header block with `;beginline=;endline=;md5=`. Get the md5
  by building once and reading the error.
* Per-package: `LICENSE:${PN}-foo = "MIT"`.
* Proprietary/EULA: `LICENSE_FLAGS = "<name>"` + `LICENSE_FLAGS_ACCEPTED` in local.conf
  (older trees: `LICENSE_FLAGS = "commercial"`).
* `NO_GENERIC_LICENSE[<lic>] = "path/in/src"` for non-standard licence texts.

## Upgrading a recipe

```bash
devtool upgrade <pn> -V <newver>     # fetches, rebases patches, drops recipe in workspace
devtool build <pn>
devtool finish <pn> ../meta-mylayer  # writes back, regenerates patches
devtool check-upgrade-status         # fleet-wide: what has newer upstream releases
```
After every upgrade: re-verify `LIC_FILES_CHKSUM`; drop patches now upstream; re-check
`PACKAGECONFIG` options still exist (`unknown-configure-option` QA catches removals); and
diff the shipped file list with `oe-pkgdata-util list-pkg-files -p <pn>` before/after.

## native / nativesdk / multilib

* `BBCLASSEXTEND = "native nativesdk"` generates `<pn>-native` and `nativesdk-<pn>`.
* Differ per variant with `CLASSOVERRIDE`: `DEPENDS:class-native`,
  `do_install:append:class-target()`.
* A `-native` recipe must not depend on target sysroot content.
* Multilib: `MULTILIBS = "multilib:lib32"`,
  `DEFAULTTUNE:virtclass-multilib-lib32 = "armv7athf-neon"`; packages get a `lib32-` prefix.
  Recipes needing awareness use `MLPREFIX`.

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
- [ ] builds clean: `bitbake <pn> -c cleansstate && bitbake <pn>`
