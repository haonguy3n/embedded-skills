---
name: yocto-build-triage
description: Systematic root-cause loop for failing or misbehaving Yocto/BitBake builds — reading log.do_*/run.do_*, devshell, QA (insane.bbclass) error taxonomy and how to fix each one properly, do_fetch/checksum failures, sysroot and staging errors, do_rootfs dependency conflicts, sstate corruption, "task rebuilt unexpectedly", host-contamination and multilib/arch errors. Use whenever a bitbake command fails, emits ERROR/WARNING QA messages, or produces an image that is missing or broken.
---

# Build failure triage

Work the loop: **read the real log → classify → fix at the right layer → prove it.**
Never "fix" by adding `INSANE_SKIP` or `-f` until you know why.

## 0. The loop

```bash
# 1. Which task failed? bitbake prints the log path — open THAT file, not the console tail.
less tmp/work/<arch>/<pn>/<pv>/temp/log.do_compile
# run.do_compile is the exact generated shell script that ran. Read it when the
# log makes no sense — it shows the real command line and environment.

# 2. Reproduce interactively in the same environment:
bitbake <pn> -c devshell        # shell with cross env, cwd = ${S}
bitbake <pn> -c devpython       # python shell with `d` datastore bound

# 3. Inspect the flattened metadata:
bitbake -e <pn> > /tmp/e.txt    # then grep; the comment trail shows who set what
bitbake-getvar -r <pn> S
bitbake-getvar -r <pn> do_install

# 4. Re-run only the failing task after a fix:
bitbake <pn> -c compile -f && bitbake <pn>
```

Useful directories under `tmp/work/<arch>/<pn>/<pv>/`:

| Dir | Contents |
|---|---|
| `temp/` | `log.do_*`, `run.do_*` (real symlinks to `.pid` variants), `log.task_order` |
| `${S}` (often `git/` or `<pn>-<pv>/`) | unpacked+patched source |
| `${B}` | build dir (== `${S}` unless out-of-tree) |
| `image/` | `${D}` — what `do_install` produced |
| `packages-split/` | post-`do_package` per-package trees — **this is what shipped** |
| `pkgdata/` | per-package metadata |
| `recipe-sysroot`, `recipe-sysroot-native` | the sysroots this recipe compiled against |
| `sysroot-destdir/` | what this recipe contributes to others' sysroots |
| `deploy-*/` | ipk/deb/rpm staged for the feed |

## 1. do_fetch failures

```
ERROR: ... do_fetch: Fetcher failure for URL ... Unable to fetch URL from any source.
```

* Check `SRC_URI` protocol/branch. Git fetches need `;branch=<b>` (mandatory since
  hardknott) and `;protocol=https` for GitHub (git:// is dead).
* Behind a proxy / offline: `BB_NO_NETWORK = "1"` forces DL_DIR/PREMIRRORS only;
  `BB_GENERATE_MIRROR_TARBALLS = "1"` makes git checkouts archivable.
* `do_fetch[network]` — in newer releases only `do_fetch` may touch the network. A recipe
  whose `do_configure` downloads (cargo, npm, go, cmake FetchContent) will fail; vendor the
  deps into `SRC_URI` instead.
* Checksum mismatch:
  ```
  ERROR: ... md5 data is not matching: expected ... got ...
  ```
  **Do not just paste the new sum.** Diff the tarball; upstream re-rolling a release is a
  supply-chain event. Then set `SRC_URI[sha256sum] = "..."` (named form
  `SRC_URI[<name>.sha256sum]` when using `;name=`).
* `rm -rf ${DL_DIR}/<file>*` including the `.done` stamp when a partial download poisons it.

## 2. do_patch failures

```
ERROR: ... do_patch: Command Error: 'quilt push' exited with 1
```
* Look at `${S}/patches/` and `temp/log.do_patch`. Wrong `-p` level → add `;striplevel=1`.
* Patch context drifted after a version bump → refresh it:
  ```bash
  devtool modify <pn>          # patches become git commits
  cd workspace/sources/<pn> && git rebase / fix
  devtool finish <pn> ../meta-mylayer     # regenerates patch files
  ```
* Patch applies but you want it conditional: `SRC_URI:append:soc-family = " file://x.patch"`.
* Missing `Upstream-Status:` header → QA warning (`patch-status`); always add
  `Upstream-Status: Pending|Backport [<url>]|Denied|Inappropriate [reason]` and
  `Signed-off-by:`.

## 3. do_configure / do_compile failures

* **`error: <header>.h: No such file or directory`** → missing `DEPENDS`. Find the provider:
  ```bash
  oe-pkgdata-util find-path '*/zlib.h'
  bitbake-layers show-recipes '*zlib*'
  ```
* **Host contamination**: configure found `/usr/include/...`. Symptoms: works on your
  machine, fails in CI; QA `host-user-contaminated`; `buildpaths` warnings. Fix by adding
  the real `DEPENDS` and by passing an explicit `--with-foo=${STAGING_DIR_HOST}${prefix}`,
  or `PACKAGECONFIG` to disable auto-detection. Never add `-I/usr/include`.
* **Parallel make race**: fails intermittently, passes with `-j1`.
  ```bitbake
  PARALLEL_MAKE = "-j 1"          # diagnosis only
  ```
  Then fix the upstream Makefile dependency and carry a patch. Do not leave `-j1` in.
* **Wrong flags reaching the compiler**: check `run.do_compile` for `CC=`, `CFLAGS`,
  `LDFLAGS`. Recipes that ignore env need `EXTRA_OEMAKE = "CC='${CC}' LD='${LD}'"` or
  `oe_runmake CC="${CC}"`.
* **CMake**: use `inherit cmake`, `EXTRA_OECMAKE`. Never call `cmake` by hand.
  `do_configure` failing with "could not find <Pkg>Config.cmake" → the dep's `-dev` package
  or its cmake config is missing from the sysroot; check `sysroot-destdir`.
* **autotools**: `inherit autotools`, `EXTRA_OECONF`. `autoreconf` failures usually mean
  missing `DEPENDS += "..."` for an m4 macro provider, or a stale `acinclude`. Try
  `inherit autotools-brokensep` when the package cannot build out-of-tree
  (`${B}` != `${S}`) — that is what the class is for.

## 4. do_install / packaging (QA) errors

`insane.bbclass` runs these. Full control:

```bitbake
ERROR_QA   # checks that fail the build
WARN_QA    # checks that only warn
INSANE_SKIP:${PN} = "dev-so ldflags"   # per-package exemption — justify it in a comment
ERROR_QA:remove = "version-going-backwards"
```

### Taxonomy — cause → correct fix

| QA id | Real cause | Correct fix |
|---|---|---|
| `installed-vs-shipped` | files in `${D}` not matched by any `FILES:*` | add to `FILES:${PN}...` or stop installing them |
| `files-invalid` / `empty-dirs` | stray dirs (`/var/run`) | use `volatile` / `systemd-tmpfiles`, don't ship `/var/run` |
| `dev-so` | `.so` symlink outside `-dev` | leave in `${PN}-dev`; only plugins/modules keep bare `.so` (then `FILES:${PN} += "${libdir}/foo/*.so"` and `INSANE_SKIP:${PN} += "dev-so"`) |
| `staticdev` | `.a` in main package | goes to `${PN}-staticdev` |
| `dev-elf` | ELF binary in `-dev` | move it |
| `ldflags` | binary lacks GNU_HASH → recipe dropped `${LDFLAGS}` | pass `LDFLAGS` through the build system |
| `textrel` | text relocations | build with `-fPIC` |
| `already-stripped` | upstream stripped before OE could split debug | disable upstream strip (`INSTALL_PROGRAM`, `-s` flags) |
| `useless-rpaths` | RPATH of `/usr/lib` | fix libtool/cmake `SKIP_RPATH`, or `chrpath` |
| `rpaths` | RPATH points into `${WORKDIR}` | same; hard error, would break on target |
| `buildpaths` | `${TMPDIR}` string embedded in output | breaks reproducibility — patch out `__FILE__`/`-fdebug-prefix-map` gaps |
| `host-user-contaminated` | files owned by build UID | `chown` in `do_install` or use `install -m` properly |
| `arch` | wrong ELF machine/bitness | recipe used host compiler, or wrong `PACKAGE_ARCH` |
| `file-rdeps` | shipped script needs `/bin/bash`, `python3`… | add real `RDEPENDS:${PN}` |
| `build-deps` | package RDEPENDS on something not in DEPENDS | add the `DEPENDS` |
| `la` / `pkgconfig` | `.la`/`.pc` contain `TMPDIR` | usually a broken `do_install`; sed them |
| `version-going-backwards` | PV/PR decreased | bump `PR` or use `PE` |
| `unknown-configure-option` | typo in `EXTRA_OECONF` | fix it — this catches silently-ignored options |
| `packages-list` / `pkgname` | invalid package name | lowercase, no underscores |

Debug what actually landed where:

```bash
ls tmp/work/<arch>/<pn>/<pv>/packages-split/
oe-pkgdata-util list-pkg-files -p <pn>
oe-pkgdata-util find-path /usr/bin/foo
oe-pkgdata-util lookup-recipe <package>
oe-pkgdata-util read-value RDEPENDS <package>
```

## 5. do_rootfs / image failures

```
ERROR: Unable to install packages. ... conflicting requests
ERROR: Nothing RPROVIDES 'foo' (but /path/image.bb RDEPENDS on or otherwise requires it)
```

* `Nothing RPROVIDES` → the package name is wrong or the recipe is not in any layer, or
  `COMPATIBLE_MACHINE` excluded it, or a `PACKAGECONFIG` disabled the sub-package.
  ```bash
  bitbake-layers show-recipes '*foo*'
  bitbake -e <pn> | grep -E '^(PACKAGES|COMPATIBLE_MACHINE|PACKAGE_ARCH)='
  ```
* **Conflicts between two providers** (e.g. `busybox` vs `coreutils`, two `-dev`s) →
  use `RCONFLICTS`/`update-alternatives`, or `PREFERRED_PROVIDER`, or `VIRTUAL-RUNTIME_*`.
* **`RDEPENDS` of a runtime-only package** pulled in a whole toolchain → check
  `IMAGE_INSTALL` vs `IMAGE_FEATURES`; `dev-pkgs`/`dbg-pkgs` explode image size.
* **Image too small**: `IMAGE_ROOTFS_SIZE`, `IMAGE_OVERHEAD_FACTOR` (default 1.3),
  `IMAGE_ROOTFS_EXTRA_SPACE`, `IMAGE_ROOTFS_MAXSIZE`.
* **Read-only rootfs failures** → `read-only-rootfs` in `IMAGE_FEATURES` requires every
  postinst to be `_ondevice`-free; look for
  `Postinstall scriptlets of ... are not executed at rootfs creation time`.
* License blocks: `ERROR: ... is not compatible with INCOMPATIBLE_LICENSE` — see
  `yocto-security-compliance`.

## 6. Sysroot / staging errors

```
ERROR: The file /usr/lib/libfoo.so is installed by both A and B, aborting
```
Two recipes stage the same path. Decide the owner; the other gets `PROVIDES`/`RPROVIDES`
+ `RCONFLICTS`, or drop the duplicate install.

```
ERROR: ... do_prepare_recipe_sysroot: The file ... is missing
```
Usually a stale sysroot after a layer/priority change:
```bash
bitbake <pn> -c cleansstate && bitbake <pn>
```

## 7. sstate and "it rebuilt / it didn't rebuild"

```bash
bitbake -S printdiff <target>        # why sstate missed
bitbake-diffsigs <sigdata_a> <sigdata_b>
bitbake-dumpsig <sigdata>
```

* Task ran when it shouldn't → something in `[vardeps]` changed; find it with diffsigs.
* Task **didn't** run when it should → your change isn't in any signature (e.g. you edited
  a file not in `SRC_URI`, or a `[vardepsexclude]` hides it). Verify with `bitbake-dumpsig`.
* Suspected corrupt sstate:
  ```bash
  bitbake <pn> -c cleansstate     # drops sstate + stamps for this recipe
  bitbake <pn> -c clean           # drops workdir only
  bitbake <pn> -c cleanall        # + downloads. Rarely what you want.
  ```
  Nuking `tmp/` is safe (sstate + downloads survive) and is the correct "reset" — never
  delete `sstate-cache/` or `downloads/` casually.

## 8. Parse-time errors

* `ParseError`, `ExpansionError: Failure expanding variable X` → a `${@...}` raised, or a
  variable is undefined at parse time. `bitbake -e` won't parse either; bisect by
  commenting.
* `Nothing PROVIDES 'x'` at parse → missing layer in `bblayers.conf`, or
  `LAYERSERIES_COMPAT` mismatch silently skipping the layer:
  ```
  ERROR: Layer meta-foo is not compatible with the core layer which only supports these series: kirkstone
  ```
  Fix `LAYERSERIES_COMPAT_<collection>` — but only after confirming the layer really works
  on that release.

## 9. Host-environment problems

* Missing host tools → `sanity.bbclass` reports them; install per the Yocto
  "Required Packages for the Build Host" list. `lz4c`, `zstd`, `pzstd` became mandatory in 3.4.
* Locale/`umask`/`PATH` leakage → `BB_ENV_PASSTHROUGH_ADDITIONS` (was `BB_ENV_EXTRAWHITE`)
  controls what crosses into BitBake. Anything not listed is stripped, on purpose.
* Disk full mid-build produces bizarre errors; check `BB_DISKMON_DIRS` monitoring.

## 10. Prove the fix

```bash
bitbake <pn> -c cleansstate && bitbake <pn>     # clean-room rebuild of the recipe
bitbake <image>
bitbake <image> -c testimage                    # if runtime tests exist
```
And confirm the artifact, not the log: inspect `packages-split/`, or
`wic ls tmp/deploy/images/<machine>/<image>.wic:1/`.
