---
name: yocto
description: Yocto/BitBake/OpenEmbedded embedded Linux engineering — recipes, layers, BSPs, machine and distro confs, kernel and device trees, bootloaders and secure boot, images and wic, devtool, build failures, sstate performance, CVE/SBOM compliance, testing, and release migration. Use for any .bb/.bbclass/.conf/.bbappend work, board bring-up, or a failing bitbake command.
---

# Yocto / BitBake

Platform-neutral senior practice. Examples use `<soc>` / `myboard` / `linux-vendor`
placeholders; substitute your silicon. Vendor layers are named only as evidence a pattern is
real.

**Load only the reference you need** — each file below is self-contained.

| Task | Read |
|---|---|
| A build failed; QA errors; "why did it rebuild" | `references/triage.md` |
| Writing/upgrading/packaging a recipe | `references/recipes.md` |
| Layers, machine/distro confs, BSP structure, board bring-up | `references/layers-bsp.md` |
| Kernel config, drivers, device trees, out-of-tree modules | `references/kernel.md` |
| Boot chain, U-Boot, boot containers, signing, secure boot, A/B | `references/boot.md` |
| Image recipes, IMAGE_FSTYPES, wic/.wks, initramfs, SDK | `references/images.md` |
| Fast edit-build-test iteration, patch rebasing | `references/devtool.md` |
| Slow builds, sstate misses, CI caching, reproducibility | `references/performance.md` |
| CVE triage, SBOM/SPDX, licence compliance, hardening | `references/security.md` |
| ptest, testimage, oe-selftest, CI gates | `references/testing.md` |
| Moving between Yocto releases | `references/migration.md` |
| Deeper BitBake semantics: Python, datastore, signatures, deps | `references/bitbake.md` |

---

## 0. First: which override syntax does this tree use?

```bash
grep -r LAYERSERIES_COMPAT */conf/layer.conf
bitbake-getvar DISTRO_VERSION 2>/dev/null || bitbake -e | grep '^DISTRO_VERSION'
```
* **≤ 3.3** (zeus, dunfell, gatesgarth, hardknott): `VAR_append`, `FILES_${PN}`, `SRC_URI_soc-family`
* **≥ 3.4** (honister →): `VAR:append`, `FILES:${PN}`, `SRC_URI:soc-family`

Never mix them. A honister+ BitBake treats `FOO_append` as a *different variable*, silently.
Examples throughout use `:` — match the tree you are editing.

## 1. Assignment operators — expansion timing is the whole game

| Operator | Meaning | Expanded when |
|---|---|---|
| `=` | plain assign | lazily, at use |
| `:=` | immediate assign | **at parse time** |
| `?=` | default; first parsed wins | lazily |
| `??=` | weak default; loses to `?=` and `=` | lazily |
| `+=` / `=+` | append/prepend **with** a space | lazily |
| `.=` / `=.` | append/prepend **without** a space | lazily |
| `:append` / `:prepend` | applied **after all parsing** | override-application time |
| `:remove` | remove whitespace-delimited items, applied last of all | override-application time |

* `+=` in a `.bbappend` races with `+=` in the recipe — parse order decides. `:append` does
  not race: all `:append`s apply after the base value is final. Prefer `:append` in appends.
* `:remove` wins over every `:append`, always.
* `?=` in a `.conf` parsed *later* is a no-op if already `=`-assigned. This is why
  `local.conf` (parsed last, plain `=`) beats machine/distro `?=`.
* `:append` without a leading space glues onto the previous item. Always `" file://x"`.
* `:=` captures a value that changes per parsed file — the canonical case, required in every
  `.bbappend` that adds files:
  ```bitbake
  FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
  SRC_URI += "file://0001-x.patch"
  ```

## 2. OVERRIDES

Colon-separated list. Anything matching `VAR:<entry-in-OVERRIDES>` replaces `VAR`.
**Right-most entry has highest precedence.**

```
OVERRIDES = "${TARGET_OS}:${TRANSLATED_TARGET_ARCH}:build-${BUILD_OS}:pn-${PN}:${MACHINEOVERRIDES}:${DISTROOVERRIDES}:${CLASSOVERRIDE}:forcevariable"
MACHINEOVERRIDES = "soc-family:soc-variant:myboard"
```

* `forcevariable` is last → beats everything. Escape hatch only.
* `CLASSOVERRIDE` = `class-target`/`class-native`/`class-nativesdk`/`class-cross`; how you
  differ per `BBCLASSEXTEND` variant.
* `pn-${PN}` lets a config file target one recipe: `EXTRA_OECONF:pn-busybox` in `local.conf`.
* Write `VAR:append:<override>`, not `VAR:<override>:append`.
* `MACHINEOVERRIDES =. "soc-family:soc-variant:"` — always prepend (`=.`), never assign, or
  the machine name loses its right-most/highest-priority position.

## 3. Where does a setting belong?

| Setting kind | Home | Example |
|---|---|---|
| Hardware fact | `conf/machine/<machine>.conf` | `KERNEL_DEVICETREE`, `UBOOT_MACHINE`, `SERIAL_CONSOLES`, `MACHINE_FEATURES` |
| Product/policy | `conf/distro/<distro>.conf` | `DISTRO_FEATURES`, init system, package format, `PREFERRED_VERSION` |
| What's in the image | image recipe | `IMAGE_INSTALL`, `IMAGE_FEATURES`, `IMAGE_FSTYPES` |
| Recipe behaviour | recipe / `.bbappend` | `PACKAGECONFIG`, patches |
| Developer-local | `conf/local.conf` | `BB_NUMBER_THREADS`, `SSTATE_DIR`, `INHERIT += "rm_work"` |

`IMAGE_INSTALL:append` in a machine conf is always wrong — machine confs describe *the
board*, not *the product*.

## 4. Inspection — the commands that answer most questions

```bash
bitbake -e <recipe> > /tmp/e.txt   # flattened datastore; above each variable is the
                                   # file/line trail of everything that touched it
bitbake-getvar -r <recipe> <VAR>   # same trail, targeted
bitbake -g <target>                # pn-buildlist, task-depends.dot, recipe-depends.dot
bitbake <recipe> -c listtasks
bitbake -S printdiff <recipe>      # why sstate missed / why it rebuilt
bitbake <recipe> -c devshell       # shell with the cross env, cwd = ${S}
bitbake <recipe> -c devpython      # python shell with `d` bound

bitbake-layers show-layers | show-appends | show-overlayed | show-recipes <pn>
oe-pkgdata-util list-pkgs | list-pkg-files -p <pn> | find-path <path> | lookup-recipe <pkg>
```

Execution control:
```bash
bitbake <r> -c <task> -f     # force rerun this task
bitbake <r> -C <task>        # invalidate <task>, then run do_build (cascades!)
bitbake -k                   # keep going after failure
bitbake -b path/to.bb        # this file ONLY, no deps — debugging only
bitbake -D/-DD/-DDD -v       # debug verbosity (provider selection etc.)
```

## 5. Where things live under `tmp/work/<arch>/<pn>/<pv>/`

| Dir | Contents |
|---|---|
| `temp/` | `log.do_*`, `run.do_*` (the real generated script), `log.task_order` |
| `${S}` (often `git/`) | unpacked + patched source |
| `${B}` | build dir (`== ${S}` unless out-of-tree) |
| `image/` | `${D}` — what `do_install` produced |
| `packages-split/` | post-`do_package` per-package trees — **this is what shipped** |
| `recipe-sysroot`, `-native` | the sysroots this recipe compiled against |
| `sysroot-destdir/` | what this recipe contributes to others' sysroots |

Other paths: `tmp/deploy/images/${MACHINE}` (`DEPLOY_DIR_IMAGE`), `tmp/deploy/licenses/`,
`tmp/deploy/cve/`, `tmp/deploy/sdk/`, `tmp/stamps/`.

## 6. Universal rules

* Never edit files under `tmp/work/` and expect them to persist — use `devtool modify`.
* Never "fix" a failure with `INSANE_SKIP`, a pasted checksum, or `-f` until you know why.
* `RDEPENDS` names **packages**, not recipes.
* Pin `SRCREV`; no `AUTOREV` or floating branches in a released layer or CI.
* Every patch carries `Upstream-Status:` and `Signed-off-by:` (plus `CVE:` if it fixes one).
* Prove a fix against the artifact, not the log: `packages-split/`, `wic ls`, `dmesg`.
