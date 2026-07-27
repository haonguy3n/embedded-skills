# Build failure triage

Work the loop: **read the real log → classify → fix at the right layer → prove it.**
Never "fix" with `INSANE_SKIP` or `-f` until you know why.

BitBake prints the log path — open *that* file, not the console tail. `run.do_<task>` is the
exact generated shell script that ran; read it when the log makes no sense. Reproduce
interactively with `bitbake <pn> -c devshell`. Workdir layout and inspection commands are in
`SKILL.md`.

## do_fetch

```
ERROR: ... do_fetch: Fetcher failure for URL ... Unable to fetch URL from any source.
```
* Git fetches need `;branch=<b>` (mandatory since hardknott) and `;protocol=https`
  (`git://` is dead for GitHub).
* Offline/proxy: `BB_NO_NETWORK = "1"` forces DL_DIR/PREMIRRORS only;
  `BB_GENERATE_MIRROR_TARBALLS = "1"` makes git checkouts archivable.
* `do_fetch[network]` — in newer releases only `do_fetch` may touch the network. A recipe
  whose `do_configure` downloads (cargo, npm, go, cmake FetchContent) fails; vendor the deps
  into `SRC_URI`.
* Checksum mismatch (`md5 data is not matching: expected ... got ...`): **do not just paste
  the new sum.** Diff the tarball — upstream re-rolling a release is a supply-chain event.
  Then set `SRC_URI[sha256sum]` (or `SRC_URI[<name>.sha256sum]` when using `;name=`).
* `rm -rf ${DL_DIR}/<file>*` including the `.done` stamp when a partial download poisons it.

## do_patch

```
ERROR: ... do_patch: Command Error: 'quilt push' exited with 1
```
* Check `${S}/patches/` and `temp/log.do_patch`. Wrong `-p` level → `;striplevel=1`.
* Context drifted after a version bump → refresh via `devtool modify` → rebase →
  `devtool finish` (see `devtool.md`).
* Conditional patch: `SRC_URI:append:soc-family = " file://x.patch"`.
* Missing `Upstream-Status:` → `patch-status` QA warning. Always add
  `Upstream-Status: Pending|Backport [<url>]|Denied|Inappropriate [reason]` + `Signed-off-by:`.

## do_configure / do_compile

* **`error: <header>.h: No such file or directory`** → missing `DEPENDS`. Find the provider:
  ```bash
  oe-pkgdata-util find-path '*/zlib.h'
  bitbake-layers show-recipes '*zlib*'
  ```
* **Host contamination**: configure found `/usr/include/...`. Symptoms: works locally, fails
  in CI; QA `host-user-contaminated`; `buildpaths` warnings. Fix with the real `DEPENDS` and
  an explicit `--with-foo=${STAGING_DIR_HOST}${prefix}`, or `PACKAGECONFIG` to disable
  auto-detection. Never add `-I/usr/include`.
* **Parallel make race**: intermittent, passes with `-j1`. `PARALLEL_MAKE = "-j 1"` is a
  *diagnosis*, not a fix — patch the upstream Makefile dependency.
* **Wrong flags reaching the compiler**: check `run.do_compile` for `CC=`, `CFLAGS`,
  `LDFLAGS`. Recipes that ignore the env need `EXTRA_OEMAKE = "CC='${CC}' LD='${LD}'"` or
  `oe_runmake CC="${CC}"`.
* **CMake**: `inherit cmake`, `EXTRA_OECMAKE`; never call `cmake` by hand. "could not find
  `<Pkg>Config.cmake`" → the dep's `-dev` package or cmake config is missing from the
  sysroot; check `sysroot-destdir`.
* **autotools**: `inherit autotools`, `EXTRA_OECONF`. `autoreconf` failures usually mean a
  missing `DEPENDS` for an m4 macro provider or a stale `acinclude`. Use
  `autotools-brokensep` when the package genuinely cannot build with `${B}` != `${S}`.

## do_install / packaging QA

`insane.bbclass` runs these.
```bitbake
ERROR_QA   # checks that fail the build
WARN_QA    # checks that only warn
INSANE_SKIP:${PN} = "dev-so ldflags"   # per-package exemption — justify it in a comment
ERROR_QA:remove = "version-going-backwards"
```

| QA id | Real cause | Correct fix |
|---|---|---|
| `installed-vs-shipped` | files in `${D}` matched by no `FILES:*` | add to `FILES:${PN}...` or stop installing them |
| `files-invalid` / `empty-dirs` | stray dirs (`/var/run`) | use `volatile`/`systemd-tmpfiles` |
| `dev-so` | `.so` symlink outside `-dev` | leave in `${PN}-dev`; only plugins keep a bare `.so` (then `FILES:${PN} += "${libdir}/foo/*.so"` + `INSANE_SKIP`) |
| `staticdev` | `.a` in the main package | goes to `${PN}-staticdev` |
| `dev-elf` | ELF binary in `-dev` | move it |
| `ldflags` | binary lacks GNU_HASH → recipe dropped `${LDFLAGS}` | pass `LDFLAGS` through the build system |
| `textrel` | text relocations | build with `-fPIC` |
| `already-stripped` | upstream stripped before OE could split debug | disable upstream strip (`INSTALL_PROGRAM`, `-s`) |
| `useless-rpaths` | RPATH of `/usr/lib` | fix libtool/cmake `SKIP_RPATH`, or `chrpath` |
| `rpaths` | RPATH points into `${WORKDIR}` | same; hard error, would break on target |
| `buildpaths` | `${TMPDIR}` embedded in output | breaks reproducibility — patch `__FILE__`/`-fdebug-prefix-map` gaps |
| `host-user-contaminated` | files owned by the build UID | `chown` in `do_install`, or use `install -m` properly |
| `arch` | wrong ELF machine/bitness | host compiler used, or wrong `PACKAGE_ARCH` |
| `file-rdeps` | shipped script needs `/bin/bash`, `python3`… | add the real `RDEPENDS:${PN}` |
| `build-deps` | package RDEPENDS on something not in DEPENDS | add the `DEPENDS` |
| `la` / `pkgconfig` | `.la`/`.pc` contain `TMPDIR` | broken `do_install`; sed them |
| `version-going-backwards` | PV/PR decreased | bump `PR` or use `PE` |
| `unknown-configure-option` | typo in `EXTRA_OECONF` | fix it — catches silently-ignored options |
| `packages-list` / `pkgname` | invalid package name | lowercase, no underscores |

## do_rootfs / image

```
ERROR: Unable to install packages. ... conflicting requests
ERROR: Nothing RPROVIDES 'foo' (but /path/image.bb RDEPENDS on or otherwise requires it)
```
* `Nothing RPROVIDES` → wrong package name, recipe not in any layer, `COMPATIBLE_MACHINE`
  excluded it, or a `PACKAGECONFIG` disabled the sub-package.
  ```bash
  bitbake-layers show-recipes '*foo*'
  bitbake -e <pn> | grep -E '^(PACKAGES|COMPATIBLE_MACHINE|PACKAGE_ARCH)='
  ```
* **Conflicting providers** (`busybox` vs `coreutils`, two `-dev`s) → `RCONFLICTS` /
  `update-alternatives` / `PREFERRED_PROVIDER` / `VIRTUAL-RUNTIME_*`.
* Toolchain pulled in unexpectedly → check `IMAGE_INSTALL` vs `IMAGE_FEATURES`;
  `dev-pkgs`/`dbg-pkgs` explode image size.
* **Image too small**: `IMAGE_ROOTFS_SIZE`, `IMAGE_OVERHEAD_FACTOR` (default 1.3),
  `IMAGE_ROOTFS_EXTRA_SPACE`, `IMAGE_ROOTFS_MAXSIZE`.
* **Read-only rootfs**: `read-only-rootfs` requires every postinst to be `_ondevice`-free.
  Look for `Postinstall scriptlets of ... are not executed at rootfs creation time`.
* `is not compatible with INCOMPATIBLE_LICENSE` → see `security.md`.

## Sysroot / staging

```
ERROR: The file /usr/lib/libfoo.so is installed by both A and B, aborting
```
Two recipes stage the same path. Decide the owner; the other gets `PROVIDES`/`RPROVIDES` +
`RCONFLICTS`, or drops the duplicate install.

```
ERROR: ... do_prepare_recipe_sysroot: The file ... is missing
```
Usually a stale sysroot after a layer/priority change: `bitbake <pn> -c cleansstate`.

## sstate — "it rebuilt / it didn't rebuild"

```bash
bitbake -S printdiff <target>        # why sstate missed
bitbake-diffsigs <sigdata_a> <sigdata_b>
bitbake-dumpsig <sigdata>
```
* Ran when it shouldn't → something in `[vardeps]` changed; find it with diffsigs.
* **Didn't** run when it should → your change isn't in any signature (edited a file not in
  `SRC_URI`, or a `[vardepsexclude]` hides it). Verify with `bitbake-dumpsig`.
* Suspected corruption: `-c cleansstate` (sstate + stamps), `-c clean` (workdir only),
  `-c cleanall` (+ downloads; rarely what you want).
* Nuking `tmp/` is safe and is the correct reset — sstate and downloads survive. Never delete
  `sstate-cache/` or `downloads/` casually.

## Parse-time errors

* `ParseError` / `ExpansionError: Failure expanding variable X` → a `${@...}` raised, or a
  variable is undefined at parse time. `bitbake -e` won't parse either; bisect by commenting.
* `Nothing PROVIDES 'x'` at parse → missing layer in `bblayers.conf`, or a
  `LAYERSERIES_COMPAT` mismatch silently skipping the layer:
  ```
  ERROR: Layer meta-foo is not compatible with the core layer which only supports these series: kirkstone
  ```
  Fix `LAYERSERIES_COMPAT_<collection>` — but only after confirming the layer really works on
  that release.

## Host environment

* Missing host tools → `sanity.bbclass` reports them. `lz4c`, `zstd`, `pzstd` became
  mandatory in 3.4.
* Locale/`umask`/`PATH` leakage → `BB_ENV_PASSTHROUGH_ADDITIONS` (was `BB_ENV_EXTRAWHITE`)
  controls what crosses into BitBake. Anything unlisted is stripped, on purpose.
* Disk full mid-build produces bizarre errors; check `BB_DISKMON_DIRS`.

## Prove the fix

```bash
bitbake <pn> -c cleansstate && bitbake <pn>     # clean-room rebuild of the recipe
bitbake <image>
bitbake <image> -c testimage                    # if runtime tests exist
```
Confirm the artifact, not the log: inspect `packages-split/`, or
`wic ls tmp/deploy/images/<machine>/<image>.wic:1/`.
